import Foundation
import NIO

/// All listener, connection, and generation state is confined to one event loop.
final class AndroidSharingServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let loop: EventLoop
    private var listener: Channel?
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var generation = 0
    private var activeClients = 0
    private let backendPort: Int
    private let maximumConnections: Int

    init(backendPort: Int = 5037, maximumConnections: Int = 32) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        self.loop = group.next()
        self.backendPort = backendPort
        self.maximumConnections = maximumConnections
    }

    func start(address: String, port: Int) async throws -> Int {
        // The UI validates interface ownership; reject wildcard binds at the transport too.
        guard AndroidNetworkInterfaces.isIPv4(address), address != "0.0.0.0" else {
            throw AndroidSharingError.message("Choose a specific local IPv4 address.")
        }
        let backendAddress = try SocketAddress(ipAddress: "127.0.0.1", port: backendPort)
        let eventLoop = loop
        return try await eventLoop.flatSubmit {
            guard self.listener == nil else {
                return eventLoop.makeFailedFuture(AndroidSharingError.message("Sharing is already running."))
            }
            self.generation += 1
            let generation = self.generation
            return ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 65_536))
                .childChannelInitializer { channel in
                    guard self.generation == generation, self.activeClients < self.maximumConnections else {
                        return channel.close()
                    }
                    self.activeClients += 1
                    channel.closeFuture.whenComplete { _ in self.activeClients -= 1 }
                    self.track(channel)
                    let pair = AndroidProxyPair(front: channel)
                    return channel.pipeline.addHandler(AndroidProxyHandler(pair: pair, isFront: true) {
                        ClientBootstrap(group: eventLoop)
                            .connectTimeout(.seconds(3))
                            .channelOption(ChannelOptions.autoRead, value: false)
                            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
                            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                            .channelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 65_536))
                            .channelInitializer { backend in
                                guard self.generation == generation, channel.isActive else { return backend.close() }
                                self.track(backend)
                                pair.back = backend
                                return backend.pipeline.addHandler(AndroidProxyHandler(pair: pair, isFront: false))
                            }
                            .connect(to: backendAddress)
                            .whenComplete { result in
                                switch result {
                                case .success(let backend):
                                    guard self.generation == generation, channel.isActive else { pair.close(); return }
                                    channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in pair.close() }
                                    backend.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in pair.close() }
                                case .failure: pair.close()
                                }
                            }
                    })
                }
                .bind(host: address, port: port)
                .flatMap { channel in
                    guard self.generation == generation else {
                        return channel.close().flatMapThrowing { throw CancellationError() }
                    }
                    self.listener = channel
                    return eventLoop.makeSucceededFuture(channel.localAddress!.port!)
                }
        }.get()
    }

    private func track(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        connections[key] = channel
        channel.closeFuture.whenComplete { _ in self.connections.removeValue(forKey: key) }
    }

    func stop() async {
        try? await closeAll().get()
    }

    private func closeAll() -> EventLoopFuture<Void> {
        let eventLoop = loop
        return eventLoop.flatSubmit {
            self.generation += 1
            let channels = Array(self.connections.values) + (self.listener.map { [$0] } ?? [])
            self.listener = nil
            return EventLoopFuture.andAllComplete(channels.map { $0.close() }, on: eventLoop)
        }
    }

    func shutdown() {
        try? closeAll().wait()
        try? group.syncShutdownGracefully()
    }

    /// Query the server directly so checking compatibility cannot restart another tool's ADB.
    func backendVersion() async throws -> Int? {
        let eventLoop = loop
        let promise = eventLoop.makePromise(of: Int.self)
        let handler = ADBVersionHandler(promise: promise)
        do {
            let channel = try await ClientBootstrap(group: eventLoop)
                .connectTimeout(.seconds(2))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
                .connect(to: SocketAddress(ipAddress: "127.0.0.1", port: backendPort)).get()
            let deadline = eventLoop.scheduleTask(in: .seconds(2)) {
                handler.finish(.failure(AndroidSharingError.message("Local ADB server did not respond.")))
                channel.close(promise: nil)
            }
            defer { deadline.cancel(); channel.close(promise: nil) }
            return try await promise.futureResult.get()
        } catch let error as IOError where error.errnoCode == ECONNREFUSED {
            // No protocol handler was installed on a refused connection.
            eventLoop.execute { handler.finish(.failure(error)) }
            return nil
        } catch {
            eventLoop.execute { handler.finish(.failure(error)) }
            throw error
        }
    }
}

private final class AndroidProxyPair {
    let front: Channel
    var back: Channel?
    var frontEOF = false
    var backEOF = false
    init(front: Channel) { self.front = front }
    func close() { front.close(promise: nil); back?.close(promise: nil) }
}

private final class AndroidProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let pair: AndroidProxyPair
    private let isFront: Bool
    private var onActive: (() -> Void)?
    private var pendingWrites = 0
    private var pendingEOF = false
    private var eofForwarded = false

    init(pair: AndroidProxyPair, isFront: Bool, onActive: (() -> Void)? = nil) {
        self.pair = pair
        self.isFront = isFront
        self.onActive = onActive
    }

    private var peer: Channel? { isFront ? pair.back : pair.front }

    func channelActive(context: ChannelHandlerContext) {
        onActive?()
        onActive = nil
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer else { pair.close(); return }
        pendingWrites += 1
        // Pause the source when the destination reaches its bounded write watermark.
        peer.writeAndFlush(unwrapInboundIn(data)).whenComplete { result in
            self.pendingWrites -= 1
            switch result {
            case .failure: self.pair.close()
            case .success:
                if self.pendingEOF { self.finishEOF() }
            }
        }
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in self.pair.close() }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        peer?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in self.pair.close() }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            pendingEOF = true
            finishEOF()
        } else { context.fireUserInboundEventTriggered(event) }
    }

    private func finishEOF() {
        guard pendingWrites == 0, !eofForwarded else { return }
        guard let peer else { pair.close(); return }
        eofForwarded = true
        if isFront { pair.frontEOF = true } else { pair.backEOF = true }
        peer.close(mode: .output).whenComplete { _ in
            if self.pair.frontEOF && self.pair.backEOF { self.pair.close() }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // NIO emits inactive instead of inputClosed when output was already shut.
        // Let writes already queued to the peer drain before forwarding this EOF.
        pendingEOF = true
        finishEOF()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { pair.close() }
}

// Created before connect, then accessed exclusively on that channel's event loop.
private final class ADBVersionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<Int>
    private var buffer = ByteBufferAllocator().buffer(capacity: 16)
    private var finished = false
    init(promise: EventLoopPromise<Int>) { self.promise = promise }

    func channelActive(context: ChannelHandlerContext) {
        var request = context.channel.allocator.buffer(capacity: 16)
        request.writeString("000chost:version")
        context.writeAndFlush(NIOAny(request), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes <= 4096 else { fail(context); return }
        guard buffer.readableBytes >= 8 else { return }
        guard buffer.getString(at: 0, length: 4) == "OKAY",
              let lengthText = buffer.getString(at: 4, length: 4),
              let length = Int(lengthText, radix: 16), length == 4 else { fail(context); return }
        guard buffer.readableBytes >= 8 + length else { return }
        guard let versionText = buffer.getString(at: 8, length: length),
              let version = Int(versionText, radix: 16) else { fail(context); return }
        finish(.success(version))
        context.close(promise: nil)
    }

    private func fail(_ context: ChannelHandlerContext) {
        finish(.failure(AndroidSharingError.message("The local endpoint did not return a valid ADB server version.")))
        context.close(promise: nil)
    }
    func finish(_ result: Result<Int, Error>) {
        guard !finished else { return }
        finished = true
        promise.completeWith(result)
    }
    func channelInactive(context: ChannelHandlerContext) { finish(.failure(AndroidSharingError.message("Local ADB server disconnected."))) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { finish(.failure(error)); context.close(promise: nil) }
}
