import Foundation
import WebSocketKit
import NIO
import NIOHTTP1
import NIOWebSocket

class AstationWebSocketServer {
    private var eventLoopGroup: EventLoopGroup!
    private var channel: Channel?
    private let hubManager: AstationHubManager
    private var connectedClients: [String: WebSocket] = [:]
    
    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
    }
    
    func start(host: String, port: Int) throws {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                return WebSocket.server(on: channel) { ws in
                    self.handleWebSocketConnection(ws)
                }
            }
        )
        
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler()
                let config = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        let serverChannel = try bootstrap.bind(host: host, port: port).wait()
        self.channel = serverChannel
        
        print("🌐 WebSocket server bound to \(host):\(port)")
    }
    
    func stop() {
        channel?.close(promise: nil)
        try? eventLoopGroup?.syncShutdownGracefully()
        print("🛑 WebSocket server stopped")
    }
    
    private func handleWebSocketConnection(_ ws: WebSocket) {
        let clientId = UUID().uuidString
        connectedClients[clientId] = ws
        
        // Add client to hub manager
        let client = ConnectedClient(
            id: clientId,
            clientType: "Atem",
            connectedAt: Date()
        )
        hubManager.addClient(client)
        
        print("🔌 New WebSocket connection: \(clientId)")
        
        // Handle incoming messages
        ws.onText { ws, text in
            self.handleIncomingMessage(text, from: clientId, ws: ws)
        }
        
        ws.onBinary { ws, buffer in
            // Handle binary messages if needed
            print("📦 Binary message received from \(clientId)")
        }
        
        // Handle connection close
        ws.onClose.whenComplete { _ in
            self.connectedClients.removeValue(forKey: clientId)
            self.hubManager.removeClient(withId: clientId)
            print("🔌 WebSocket connection closed: \(clientId)")
        }
        
        // Send welcome message
        let welcomeMessage = AstationMessage.statusUpdate(
            status: "connected",
            data: ["clientId": clientId, "serverTime": ISO8601DateFormatter().string(from: Date())]
        )
        sendMessage(welcomeMessage, to: clientId)
    }
    
    private func handleIncomingMessage(_ text: String, from clientId: String, ws: WebSocket) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(AstationMessage.self, from: data) else {
            print("❌ Failed to decode message from \(clientId): \(text)")
            return
        }
        
        print("📨 Received message from \(clientId): \(message)")
        
        // Process message through hub manager
        if let response = hubManager.handleMessage(message, from: clientId) {
            sendMessage(response, to: clientId)
        }
    }
    
    private func sendMessage(_ message: AstationMessage, to clientId: String) {
        guard let ws = connectedClients[clientId],
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            print("❌ Failed to send message to \(clientId)")
            return
        }
        
        ws.send(text)
        print("📤 Sent message to \(clientId): \(message)")
    }
    
    func sendMessageToClient(_ message: AstationMessage, clientId: String) {
        sendMessage(message, to: clientId)
    }

    func broadcastMessage(_ message: AstationMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            print("❌ Failed to encode broadcast message")
            return
        }
        
        for (clientId, ws) in connectedClients {
            ws.send(text)
            print("📢 Broadcast message to \(clientId)")
        }
    }
    
    func getConnectedClientsCount() -> Int {
        return connectedClients.count
    }
}

// Simple HTTP handler for WebSocket upgrade
private class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)
        
        switch reqPart {
        case .head(let request):
            if request.uri != "/ws" {
                // Send 404 for non-WebSocket requests
                let headers = HTTPHeaders([("content-length", "0")])
                let head = HTTPResponseHead(version: request.version, status: .notFound, headers: headers)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        case .body, .end:
            break
        }
    }
}