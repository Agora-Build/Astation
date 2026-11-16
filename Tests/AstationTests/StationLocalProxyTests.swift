import AstationRemote
import AtemClient
import Foundation
import XCTest
@testable import Menubar

@MainActor
final class StationLocalProxyTests: XCTestCase {
    private let origin = "https://station-dev.agora.build"
    private let feed = "9df0ff8e-2bbe-46da-8e1e-27e3291a405f"
    private let request = "f5c21c37-d7f5-44f4-8065-d77dce95fb62"

    func testTokenStaysInHeaderAndSelectedStationAndLocalGenerationAreBound() throws {
        let generation = UUID().uuidString
        let request = try XCTUnwrap(StationLocalProxy.request(station: origin, room: "native-room",
            host: "Genie-host", session: "paired-session", generation: generation, token: "test-token"))
        XCTAssertEqual(request.url?.host, "station-dev.agora.build")
        XCTAssertEqual(request.url?.path, "/ws/proxy")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
        XCTAssertTrue(request.url!.absoluteString.contains(generation))
        XCTAssertNil(StationLocalProxy.request(station: origin + "?server=evil", room: "n", host: "h",
            session: "s", generation: generation, token: "token"))
    }

    func testEarlyChallengeDroppedAndProofAndVerdictStayOnAuthenticatedGeneration() async throws {
        let f = Fixture()
        await f.start()
        f.proxy.receiveStation(Data(#"{"type":"relay","op":"host_challenge","v":1,"room":"native"}"#.utf8))
        XCTAssertTrue(f.local.isEmpty)
        f.authenticateNative()
        let challenge = Data(#"{"type":"relay","op":"host_challenge","v":1,"room":"native","nonce":"nonce"}"#.utf8)
        f.proxy.receiveStation(challenge)
        await drain()
        XCTAssertEqual(f.local, [challenge])
        let proof = Data(#"{"type":"relay","op":"host_route","v":1,"proof":{"body":{"type":"atem-host-route-proxy"},"sig":"opaque"}}"#.utf8)
        XCTAssertTrue(f.proxy.receiveHost(proof))
        await drain()
        XCTAssertTrue(f.socket.sent.contains(proof))
        f.current = false
        f.proxy.receiveStation(Data(#"{"type":"relay","op":"host_route_ok","v":1}"#.utf8))
        await drain()
        XCTAssertEqual(f.local, [challenge], "A stale Station verdict cannot restore local authority")
        f.proxy.close()
    }

    func testEncryptedChannelsRetainBytesAndNeverCaptureNativeChannels() async throws {
        let f = Fixture()
        await f.ready()
        let open = Data(#"{"type":"channel","event":"open","channel":"station_1","transport":"relay"}"#.utf8)
        f.proxy.receiveStation(open)
        await drain()
        XCTAssertEqual(f.local.last, open)
        let reply = Data(#"{ "type":"channel", "event":"frame", "channel":"station_1", "frame":{ "n":1e3,"large":9007199254740991,"ct":"\u0061" } }"#.utf8)
        XCTAssertTrue(f.proxy.receiveHost(reply))
        await drain()
        XCTAssertEqual(f.socket.sent.last, reply)
        let privateNative = Data(#"{"type":"channel","event":"frame","channel":"native_1","frame":{"ct":"native-only"}}"#.utf8)
        XCTAssertFalse(f.proxy.receiveHost(privateNative))
        XCTAssertFalse(f.socket.sent.contains(privateNative))
        f.proxy.close()
        XCTAssertEqual((try AtemSessionJSON.validatePacket(try XCTUnwrap(f.local.last)))["event"]?.string, "close")
    }

    func testControlSyncUsesSharedCorrelationAndAnnouncedFeedAndRejectsOldReplies() async throws {
        let f = Fixture()
        await f.ready()
        let head = LogHead(seq: 1, hash: String(repeating: "a", count: 64))
        let heads = try relayHeads(feeds: [RelayFeedHead(origin: origin, feedId: feed, head: 0, stationTime: 1)], membership: head)
        f.proxy.receiveStation(Data(heads.utf8))
        await drain()
        let call = try relayControlSync(requestId: request, origin: origin, feedId: nil, after: 0)
        XCTAssertTrue(f.proxy.receiveHost(Data(call.utf8)))
        await drain()
        let before = f.local.count
        let old = try relayControlSyncResult(requestId: UUID().uuidString.lowercased(), origin: origin,
            feedId: feed, after: 0, head: 0, stationTime: 1, records: [])
        f.proxy.receiveStation(Data(old.utf8))
        let wrongFeed = try relayControlSyncResult(requestId: request, origin: origin,
            feedId: UUID().uuidString.lowercased(), after: 0, head: 0, stationTime: 1, records: [])
        f.proxy.receiveStation(Data(wrongFeed.utf8))
        await drain()
        XCTAssertEqual(f.local.count, before)
        let valid = try relayControlSyncResult(requestId: request, origin: origin,
            feedId: feed, after: 0, head: 0, stationTime: 1, records: [])
        f.proxy.receiveStation(Data(valid.utf8))
        await drain()
        XCTAssertEqual(f.local.last, Data(valid.utf8))
        f.proxy.receiveStation(Data(valid.utf8))
        await drain()
        XCTAssertEqual(f.local.count, before + 1, "A duplicate result has no live call")
        f.proxy.close()
    }

    func testRefusalStopsOnlyProxyAndUnrelatedLocalTrafficRemainsUsable() async {
        let f = Fixture()
        await f.start(); f.authenticateNative()
        f.proxy.receiveStation(Data(#"{"type":"relay","op":"host_challenge","v":1,"room":"native"}"#.utf8))
        await drain()
        f.proxy.receiveStation(Data(#"{"type":"relay","op":"host_route_refused","v":1,"code":"unknown_host"}"#.utf8))
        await drain()
        XCTAssertEqual(f.proxy.phase, .refused)
        XCTAssertTrue(f.socket.cancelled)
        XCTAssertTrue(f.current)
        XCTAssertFalse(f.proxy.receiveHost(Data(#"{"type":"channel","event":"frame","channel":"native_1","frame":{}}"#.utf8)))
        f.proxy.start()
        XCTAssertEqual(f.proxy.phase, .refused, "No automatic proof retry after a definitive refusal")
    }

    func testBoundedBackpressureClosesProxyWithoutClosingLocalSocket() async {
        let f = Fixture()
        await f.ready()
        for index in 0..<140 {
            f.proxy.receiveHost(Data("{\"type\":\"relay\",\"op\":\"control_ack\",\"invalid\":\(index)}".utf8))
        }
        // Malformed control calls are rejected by the shared reader.
        XCTAssertEqual(f.proxy.phase, .ready)
        f.proxy.receiveStation(Data(#"{"type":"channel","event":"open","channel":"station_1","transport":"relay"}"#.utf8))
        await drain()
        f.socket.holdWrites = true
        for _ in 0..<140 {
            f.proxy.receiveHost(Data(#"{"type":"channel","event":"frame","channel":"station_1","frame":{"ct":"opaque"}}"#.utf8))
        }
        XCTAssertEqual(f.proxy.phase, .connecting)
        XCTAssertTrue(f.socket.cancelled)
        XCTAssertTrue(f.current)
        f.proxy.close()
    }

    func testRefusalReachesLocalHostEvenWhenAnEarlierWriteCompletionIsPending() async {
        let f = Fixture()
        await f.start(); f.authenticateNative()
        f.holdLocalWrites = true
        let challenge = Data(#"{"type":"relay","op":"host_challenge","v":1,"room":"native"}"#.utf8)
        let refusal = Data(#"{"type":"relay","op":"host_route_refused","v":1,"code":"unknown_host"}"#.utf8)
        f.proxy.receiveStation(challenge)
        f.proxy.receiveStation(refusal)
        XCTAssertEqual(f.local, [challenge, refusal])
        XCTAssertEqual(f.proxy.phase, .refused)
        for done in f.localCompletions { done(nil) }
        await drain()
        XCTAssertEqual(f.local, [challenge, refusal], "An old completion cannot revive a retired queue")
    }

    func testRetiringAccountOrStationStillClosesOnlyItsCapturedProxyChannels() async throws {
        let f = Fixture()
        await f.ready()
        f.proxy.receiveStation(Data(#"{"type":"channel","event":"open","channel":"station_1","transport":"relay"}"#.utf8))
        await drain()
        let before = f.local.count
        f.current = false
        f.proxy.close()
        let closed = try f.local.dropFirst(before).map { try RemoteChannelEnvelope.readHost($0) }
        XCTAssertEqual(closed.count, 1)
        guard case .close(let handle, _) = closed.first else { return XCTFail("Expected proxy channel close") }
        XCTAssertEqual(handle, "station_1")
        XCTAssertTrue(f.socket.cancelled)
        f.proxy.close()
        XCTAssertEqual(f.local.count, before + 1, "Retirement cannot close channels twice")
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    @MainActor private final class Fixture {
        var current = true
        let socket = ProxySocket()
        var local: [Data] = []
        var holdLocalWrites = false
        var localCompletions: [(Error?) -> Void] = []
        lazy var proxy = StationLocalProxy(current: { [weak self] in self?.current == true },
            connect: { [unowned self] in self.socket }, sign: { _ in #"{"type":"relayAuth"}"# },
            writeLocal: { [unowned self] bytes, done in
                self.local.append(bytes)
                if self.holdLocalWrites { self.localCompletions.append(done) }
                else { done(nil) }
            }, closeLocal: { [unowned self] bytes in self.local.append(bytes) })

        func start() async {
            proxy.start()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(proxy.phase, .native)
        }

        func authenticateNative() {
            proxy.receiveStation(Data(#"{"type":"relayAuthResult","status":"verified","message":"ok"}"#.utf8))
            XCTAssertEqual(proxy.phase, .proof)
        }

        func ready() async {
            await start(); authenticateNative()
            proxy.receiveStation(Data(#"{"type":"relay","op":"host_challenge","v":1,"room":"native"}"#.utf8))
            for _ in 0..<30 { await Task.yield() }
            proxy.receiveStation(Data(#"{"type":"relay","op":"host_route_ok","v":1}"#.utf8))
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(proxy.phase, .ready)
        }
    }
}

private final class ProxySocket: IdentityRelaySocket, @unchecked Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data?
    var sent: [Data] = []
    var cancelled = false
    var holdWrites = false
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message { sent.append(Data(text.utf8)) }
        if !holdWrites { completionHandler(nil) }
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {}
}
