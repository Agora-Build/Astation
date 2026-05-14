import Foundation
import NIO
import NIOHTTP1

/// One-shot HTTP/1 loopback listener that accepts a single OAuth callback,
/// validates the `state`, replies with a success HTML page, and surfaces
/// the (code, loginId) pair.
///
/// Lifetime: bind() → awaitCallback() → channel closes automatically.
/// The instance is single-use.
final class SsoLoopbackListener {
    let port: Int
    private let group: EventLoopGroup
    private let channel: Channel
    private let promise: EventLoopPromise<SsoCallbackQuery>
    private let timeout: TimeAmount
    private var timeoutTask: Scheduled<Void>?

    private init(group: EventLoopGroup, channel: Channel, port: Int,
                 promise: EventLoopPromise<SsoCallbackQuery>, timeout: TimeAmount) {
        self.group = group
        self.channel = channel
        self.port = port
        self.promise = promise
        self.timeout = timeout
    }

    static func bind(timeout: TimeAmount, expectedState: String) async throws -> SsoLoopbackListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: SsoCallbackQuery.self)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(SsoCallbackHandler(
                        expectedState: expectedState,
                        promise: promise
                    ))
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw SsoError.loopbackBindFailed(String(describing: error))
        }

        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw SsoError.loopbackBindFailed("no local address")
        }

        let listener = SsoLoopbackListener(group: group, channel: channel, port: port,
                                           promise: promise, timeout: timeout)
        listener.timeoutTask = group.next().scheduleTask(in: timeout) {
            promise.fail(SsoError.timeout)
        }
        return listener
    }

    func awaitCallback() async throws -> SsoCallbackQuery {
        defer {
            timeoutTask?.cancel()
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
        }
        return try await promise.futureResult.get()
    }
}

/// Reads one HTTP request, parses `code/state/loginId`, replies with HTML.
final class SsoCallbackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    private let expectedState: String
    private let promise: EventLoopPromise<SsoCallbackQuery>
    private var path: String?

    init(expectedState: String, promise: EventLoopPromise<SsoCallbackQuery>) {
        self.expectedState = expectedState
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
        case .body:
            break
        case .end:
            let uri = path ?? ""
            let query = uri.split(separator: "?", maxSplits: 1).count == 2
                ? String(uri.split(separator: "?", maxSplits: 1)[1])
                : ""
            let parsed = SsoCallbackQuery.parse(query)

            let html = Self.successHTML
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
            headers.add(name: "Content-Length", value: String(html.utf8.count))
            headers.add(name: "Connection", value: "close")
            let resp = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(resp)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: html.utf8.count)
            buf.writeString(html)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            context.close(promise: nil)

            if parsed.state != expectedState {
                promise.fail(SsoError.stateMismatch)
                return
            }
            if parsed.code.isEmpty {
                promise.fail(SsoError.tokenExchangeFailed(status: 0, body: "no code in callback"))
                return
            }
            promise.succeed(parsed)
        }
    }

}

extension SsoCallbackHandler {
    static let successHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>Login successful</title>
    <style>
      body{min-height:100vh;display:flex;align-items:center;justify-content:center;
           background:#0f0f11;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0}
      .card{text-align:center;padding:48px 56px;max-width:560px;width:100%;
            background:#18181b;border:1px solid #2a2a2e;border-radius:16px}
      .icon{font-size:36px;color:#22c55e;margin-bottom:20px}
      h1{font-size:20px;font-weight:600;color:#f4f4f5;margin-bottom:8px}
      p{font-size:14px;color:#71717a}
    </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#x2713;</div>
        <h1>Login successful</h1>
        <p>Return to Astation to continue.</p>
      </div>
    </body>
    </html>
    """
}
