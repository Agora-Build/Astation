import XCTest
import NIO
@testable import Menubar

final class AndroidSharingServerTests: XCTestCase {
    func testMultiMegabyteTransferAndHalfCloseAcrossConcurrentConnections() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { backend.shutdown() }
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        let port = try await proxy.start(address: "127.0.0.1", port: 0)
        let bytes = (0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) }
        let first = expectation(description: "First stream receives all bytes after half close")
        let second = expectation(description: "Second concurrent stream receives all bytes")
        var clients: [Channel] = []
        for done in [first, second] {
            let client = try await ClientBootstrap(group: backend.group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(AndroidCollectHandler(expected: bytes, done: done))
                }
                .connect(host: "127.0.0.1", port: port).get()
            clients.append(client)
            var buffer = client.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await client.writeAndFlush(buffer).get()
            try await client.close(mode: .output).get()
        }
        await fulfillment(of: [first, second], timeout: 10)
        for client in clients { try? await client.close().get() }
        await proxy.stop()
    }

    func testStopClosesLiveStreamsAndPreservesBackend() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { backend.shutdown() }
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        let port = try await proxy.start(address: "127.0.0.1", port: 0)
        let client = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: port).get()
        let closed = expectation(description: "Stop closes remote stream")
        client.closeFuture.whenComplete { _ in closed.fulfill() }
        await proxy.stop()
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertTrue(backend.channel.isActive)
        let local = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: backend.port).get()
        try await local.close().get()
        // A stopped sharing port can be used again without touching the backend.
        let restarted = try await proxy.start(address: "127.0.0.1", port: port)
        XCTAssertEqual(restarted, port)
    }

    func testPortCollisionAndWildcardRejection() async throws {
        let occupied = try AndroidTCPFixture { channel in channel.eventLoop.makeSucceededFuture(()) }
        defer { occupied.shutdown() }
        let proxy = AndroidSharingServer()
        defer { proxy.shutdown() }
        do { _ = try await proxy.start(address: "127.0.0.1", port: occupied.port); XCTFail("Expected occupied port") }
        catch { XCTAssertTrue(occupied.channel.isActive) }
        do { _ = try await proxy.start(address: "0.0.0.0", port: 0); XCTFail("Expected explicit address") }
        catch { XCTAssertTrue(error.localizedDescription.contains("specific")) }
    }

    func testForwardedPortsRouteConcurrentStreamsToTheirOwnLoopbackTargets() async throws {
        let backends = try [UInt8(0xAD), 0xF1, 0xF2].map { prefix in
            try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler(prefix: [prefix])) }
        }
        defer { backends.forEach { $0.shutdown() } }
        let ports = try availablePorts(3)
        let proxy = AndroidSharingServer(backendPort: backends[0].port)
        defer { proxy.shutdown() }
        let forwards = [AndroidForwardedPort(sharedPort: ports[1], localPort: backends[1].port),
                        AndroidForwardedPort(sharedPort: ports[2], localPort: backends[2].port)]
        let bound = try await proxy.start(address: "127.0.0.1", port: ports[0], forwardedPorts: forwards)
        XCTAssertEqual(bound, ports[0])
        let payload = (0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) }
        var clients: [Channel] = []
        var completed: [XCTestExpectation] = []
        for (port, prefix) in zip(ports, [UInt8(0xAD), 0xF1, 0xF2]) {
            let done = expectation(description: "Distinct target for port \(port) returns all bytes")
            completed.append(done)
            let client = try await ClientBootstrap(group: backends[0].group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(AndroidCollectHandler(expected: [prefix] + payload, done: done))
                }.connect(host: "127.0.0.1", port: port).get()
            clients.append(client)
            var buffer = client.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            try await client.writeAndFlush(buffer).get()
            try await client.close(mode: .output).get()
        }
        await fulfillment(of: completed, timeout: 10)
        for client in clients { try? await client.close().get() }
    }

    func testLaterForwardConflictRollsBackADBAndEarlierForwards() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { backend.shutdown() }
        let occupied = try AndroidTCPFixture { channel in channel.eventLoop.makeSucceededFuture(()) }
        defer { occupied.shutdown() }
        let ports = try availablePorts(2)
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        let forwards = [AndroidForwardedPort(sharedPort: ports[1], localPort: backend.port),
                        AndroidForwardedPort(sharedPort: occupied.port, localPort: backend.port)]
        do {
            _ = try await proxy.start(address: "127.0.0.1", port: ports[0], forwardedPorts: forwards)
            XCTFail("Expected the second forward to conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(String(occupied.port)))
        }
        XCTAssertTrue(occupied.channel.isActive)
        for port in ports {
            let probe = try AndroidTCPFixture(port: port) { channel in channel.eventLoop.makeSucceededFuture(()) }
            probe.shutdown()
        }
        try await occupied.channel.close().get()
        let restarted = try await proxy.start(address: "127.0.0.1", port: ports[0], forwardedPorts: forwards)
        XCTAssertEqual(restarted, ports[0])
    }

    func testLateScrcpyTargetCanConnectWithoutRestartingSharing() async throws {
        let ports = try availablePorts(2)
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { backend.shutdown() }
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        _ = try await proxy.start(address: "127.0.0.1", port: 0,
                                  forwardedPorts: [.init(sharedPort: ports[0], localPort: ports[1])])
        let early = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: ports[0]).get()
        let refused = expectation(description: "Missing scrcpy target closes only that connection")
        early.closeFuture.whenComplete { _ in refused.fulfill() }
        await fulfillment(of: [refused], timeout: 4)
        let scrcpy = try AndroidTCPFixture(port: ports[1]) { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { scrcpy.shutdown() }
        let done = expectation(description: "A later scrcpy listener is reachable through the existing mapping")
        let bytes: [UInt8] = [1, 7, 9, 0, 255]
        let client = try await ClientBootstrap(group: backend.group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(AndroidCollectHandler(expected: bytes, done: done))
            }.connect(host: "127.0.0.1", port: ports[0]).get()
        var buffer = client.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await client.writeAndFlush(buffer).get()
        try await client.close(mode: .output).get()
        await fulfillment(of: [done], timeout: 3)
    }

    func testStopClosesAllForwardedStreamsAndAllowsSamePortsToRestart() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { backend.shutdown() }
        let ports = try availablePorts(3)
        let forwards = ports.dropFirst().map { AndroidForwardedPort(sharedPort: $0, localPort: backend.port) }
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        _ = try await proxy.start(address: "127.0.0.1", port: ports[0], forwardedPorts: forwards)
        var closures: [XCTestExpectation] = []
        for port in ports {
            let client = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: port).get()
            let closed = expectation(description: "Stop closes port \(port)'s connection")
            client.closeFuture.whenComplete { _ in closed.fulfill() }
            closures.append(closed)
        }
        await proxy.stop()
        await fulfillment(of: closures, timeout: 3)
        XCTAssertTrue(backend.channel.isActive)
        let restarted = try await proxy.start(address: "127.0.0.1", port: ports[0], forwardedPorts: forwards)
        XCTAssertEqual(restarted, ports[0])
    }

    func testLoopbackForwardCannotPointBackAtTheSharingListener() async throws {
        let port = try availablePorts(1)[0]
        let proxy = AndroidSharingServer()
        defer { proxy.shutdown() }
        do {
            _ = try await proxy.start(address: "127.0.0.1", port: 0,
                                      forwardedPorts: [.init(sharedPort: port, localPort: port)])
            XCTFail("Expected self-forwarding to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("loopback"))
        }
    }

    func testVersionProbeHandlesFragmentedResponseAndMissingBackend() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidVersionFixtureHandler()) }
        let proxy = AndroidSharingServer(backendPort: backend.port)
        defer { proxy.shutdown() }
        let version = try await proxy.backendVersion()
        XCTAssertEqual(version, 41)
        backend.shutdown()
        let absent = try await proxy.backendVersion()
        XCTAssertNil(absent)
        let port = try await proxy.start(address: "127.0.0.1", port: 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdown(group) }
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
        let closed = expectation(description: "Refused backend closes client")
        client.closeFuture.whenComplete { _ in closed.fulfill() }
        await fulfillment(of: [closed], timeout: 4)
    }

    @MainActor
    func testManagerStopsSharingWhenSelectedAddressDisappears() async throws {
        let backend = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidVersionFixtureHandler()) }
        defer { backend.shutdown() }
        let portProbe = try AndroidTCPFixture { channel in channel.eventLoop.makeSucceededFuture(()) }
        let sharingPort = portProbe.port
        let forwardProbe = try AndroidTCPFixture { channel in channel.eventLoop.makeSucceededFuture(()) }
        let forwardedPort = forwardProbe.port
        let scrcpy = try AndroidTCPFixture { channel in channel.pipeline.addHandler(AndroidEchoHandler()) }
        defer { scrcpy.shutdown() }
        portProbe.shutdown()
        forwardProbe.shutdown()
        let suite = "android-manager-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let adb = FileManager.default.temporaryDirectory.appendingPathComponent("fake-adb-\(UUID().uuidString)")
        try Data("""
        #!/bin/sh
        if [ "$5" = version ]; then
          printf 'Android Debug Bridge version 1.0.41\\n'
        elif [ "$5" = devices ]; then
          printf 'List of devices attached\\nUSB123 device usb:1 model:Pixel_9\\n'
        else
          exit 9
        fi

        """.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        defer { try? FileManager.default.removeItem(at: adb) }
        defaults.set(adb.path, forKey: "androidSharing.adbPath")
        let address = AndroidNetworkAddress(interface: "test-vpn", address: "127.0.0.1")
        var assigned = [address]
        let manager = AndroidDeviceManager(defaults: defaults,
            server: AndroidSharingServer(backendPort: backend.port), addressProvider: { assigned })
        defer { manager.shutdown() }
        manager.selectedAddressID = address.id
        manager.portText = String(sharingPort)
        manager.portForwards = [AndroidPortForward(sharedPort: String(forwardedPort), localPort: String(scrcpy.port))]
        manager.startMonitoring()
        try await waitUntil { manager.isReady }
        XCTAssertEqual(manager.devices.first?.serial, "USB123")
        manager.startSharing()
        try await waitUntil { manager.isSharing && !manager.isBusy }
        XCTAssertEqual(manager.endpoint, "127.0.0.1:\(sharingPort)")
        XCTAssertEqual(manager.boundForwardedPorts, [.init(sharedPort: forwardedPort, localPort: scrcpy.port)])
        XCTAssertTrue(manager.scrcpyCommand(for: manager.devices[0], forward: manager.boundForwardedPorts[0])?.contains("--tunnel-port=\(forwardedPort)") == true)
        let originalForwards = manager.portForwards
        manager.addPortForward()
        manager.removePortForward(id: originalForwards[0].id)
        XCTAssertEqual(manager.portForwards, originalForwards)
        let client = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: sharingPort).get()
        let stream = try await ClientBootstrap(group: backend.group).connect(host: "127.0.0.1", port: forwardedPort).get()
        let closed = expectation(description: "VPN loss closes established remote stream")
        let forwardClosed = expectation(description: "VPN loss also closes the scrcpy stream")
        client.closeFuture.whenComplete { _ in closed.fulfill() }
        stream.closeFuture.whenComplete { _ in forwardClosed.fulfill() }
        assigned = []
        try await waitUntil { !manager.isSharing && manager.sharingError != nil }
        await fulfillment(of: [closed, forwardClosed], timeout: 3)
        XCTAssertNil(manager.shellSetup)
        XCTAssertTrue(manager.boundForwardedPorts.isEmpty)
        XCTAssertTrue(backend.channel.isActive)
        XCTAssertTrue(scrcpy.channel.isActive)
        XCTAssertEqual(manager.portText, String(sharingPort))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            if Date() >= deadline { XCTFail("State did not settle before timeout"); throw AndroidSharingError.message("Test timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func shutdown(_ group: MultiThreadedEventLoopGroup) { try? group.syncShutdownGracefully() }

    private func availablePorts(_ count: Int) throws -> [Int] {
        let probes = try (0..<count).map { _ in
            try AndroidTCPFixture { channel in channel.eventLoop.makeSucceededFuture(()) }
        }
        let ports = probes.map(\.port)
        probes.forEach { $0.shutdown() }
        return ports
    }
}

private final class AndroidTCPFixture {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: Channel
    var port: Int { channel.localAddress!.port! }
    init(port: Int = 0, initializer: @escaping (Channel) -> EventLoopFuture<Void>) throws {
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer(initializer)
            .bind(host: "127.0.0.1", port: port).wait()
    }
    func shutdown() { try? channel.close().wait(); try? group.syncShutdownGracefully() }
}

private final class AndroidEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var pending = 0
    private var eof = false
    private let prefix: [UInt8]
    init(prefix: [UInt8] = []) { self.prefix = prefix }
    func channelActive(context: ChannelHandlerContext) {
        if !prefix.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: prefix.count)
            buffer.writeBytes(prefix)
            context.writeAndFlush(NIOAny(buffer), promise: nil)
        }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        pending += 1
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { _ in
            self.pending -= 1
            if self.eof && self.pending == 0 { context.close(mode: .output, promise: nil) }
        }
        context.writeAndFlush(data, promise: promise)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            eof = true
            if pending == 0 { context.close(mode: .output, promise: nil) }
        }
    }
}

private final class AndroidCollectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let expected: [UInt8]
    let done: XCTestExpectation
    var received: [UInt8] = []
    var completed = false
    init(expected: [UInt8], done: XCTestExpectation) { self.expected = expected; self.done = done }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += unwrapInboundIn(data).readableBytesView
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            finish()
            context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { finish() }
    private func finish() {
        guard !completed else { return }
        completed = true
        XCTAssertEqual(received.count, expected.count)
        XCTAssertTrue(received == expected, "Forwarded bytes must be identical")
        done.fulfill()
    }
}

private final class AndroidVersionFixtureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var request = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        request += String(decoding: unwrapInboundIn(data).readableBytesView, as: UTF8.self)
        guard request.count >= 16 else { return }
        XCTAssertEqual(request, "000chost:version")
        var first = context.channel.allocator.buffer(capacity: 5)
        first.writeString("OKAY0")
        context.writeAndFlush(NIOAny(first), promise: nil)
        let channel = context.channel
        context.eventLoop.scheduleTask(in: .milliseconds(10)) {
            var rest = channel.allocator.buffer(capacity: 7)
            rest.writeString("0040029")
            channel.writeAndFlush(rest, promise: nil)
        }
    }
}
