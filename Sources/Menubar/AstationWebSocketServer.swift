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
    private let sessionStore = SessionStore()
    private var authenticatedClients: Set<String> = []  // Client IDs that have been authenticated

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
        
        Log.info("WebSocket server bound to \(host):\(port)")
    }
    
    func stop() {
        channel?.close(promise: nil)
        try? eventLoopGroup?.syncShutdownGracefully()
        Log.info("WebSocket server stopped")
    }
    
    private func handleWebSocketConnection(_ ws: WebSocket) {
        let clientId = UUID().uuidString
        connectedClients[clientId] = ws

        Log.info("🔌 New WebSocket connection: \(clientId.prefix(8))")

        // Handle incoming messages
        ws.onText { ws, text in
            self.handleIncomingMessage(text, from: clientId, ws: ws)
        }

        ws.onBinary { ws, buffer in
            NetworkDebugLogger.logWebSocketBinary(direction: "recv", context: "local \(clientId)", size: buffer.readableBytes)
        }

        // Handle connection close
        ws.onClose.whenComplete { _ in
            self.connectedClients.removeValue(forKey: clientId)
            self.authenticatedClients.remove(clientId)
            self.hubManager.removeClient(withId: clientId)
            Log.info("🔌 WebSocket connection closed: \(clientId.prefix(8))")
        }

        // Send auth challenge - client must respond with session or pairing code
        let authChallenge = AstationMessage.statusUpdate(
            status: "auth_required",
            data: [
                "clientId": clientId,
                "astation_id": AstationIdentity.shared.id
            ]
        )
        sendMessage(authChallenge, to: clientId)
    }
    
    private func handleIncomingMessage(_ text: String, from clientId: String, ws: WebSocket) {
        NetworkDebugLogger.logWebSocket(direction: "recv", context: "local \(clientId.prefix(8))", message: text)

        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(AstationMessage.self, from: data) else {
            Log.error("❌ Failed to decode message from \(clientId.prefix(8)): \(text.prefix(100))")
            return
        }

        // Handle session verification requests (from relay server)
        if case .statusUpdate(let status, let messageData) = message, status == "session_verify_request" {
            handleSessionVerifyRequest(messageData, from: clientId)
            return
        }

        // Check if client is authenticated
        if !authenticatedClients.contains(clientId) {
            // Client not authenticated - check if this is an auth message
            handleAuthMessage(message, from: clientId, ws: ws)
            return
        }

        // Client is authenticated - refresh session activity
        if case .statusUpdate(let status, let messageData) = message {
            if status == "auth", let sessionId = messageData["session_id"] {
                sessionStore.refresh(sessionId: sessionId)
            }
        }

        // Process message through hub manager
        if let response = hubManager.handleMessage(message, from: clientId) {
            sendMessage(response, to: clientId)
        }
    }

    private func handleAuthMessage(_ message: AstationMessage, from clientId: String, ws: WebSocket) {
        // Extract auth credentials from message
        guard case .statusUpdate(let status, let authInfo) = message, status == "auth" else {
            // Not an auth message - reject
            Log.warn("⚠️  Unauthenticated client \(clientId.prefix(8)) sent non-auth message - rejecting")
            let errorMsg = AstationMessage.error(message: "Authentication required")
            sendMessage(errorMsg, to: clientId)
            ws.close(code: .policyViolation)
            return
        }

        // Check for session-based auth
        if let sessionId = authInfo["session_id"] as? String {
            if sessionStore.validate(sessionId: sessionId) {
                // Session valid - authenticate client
                authenticateClient(clientId, sessionId: sessionId)

                // Add to hub manager
                if let hostname = sessionStore.get(sessionId: sessionId)?.hostname {
                    let client = ConnectedClient(
                        id: clientId,
                        clientType: "Atem",
                        connectedAt: Date(),
                        hostname: hostname
                    )
                    hubManager.addClient(client)
                }

                // Send success response
                let successMsg = AstationMessage.statusUpdate(
                    status: "authenticated",
                    data: ["method": "session"]
                )
                sendMessage(successMsg, to: clientId)

                Log.info("✅ Client \(clientId.prefix(8)) authenticated via session")
                return
            } else {
                // Session invalid or expired
                Log.warn("❌ Invalid/expired session from \(clientId.prefix(8))")
                let errorMsg = AstationMessage.error(message: "Session expired - pairing required")
                sendMessage(errorMsg, to: clientId)
                ws.close(code: .policyViolation)
                return
            }
        }

        // Check for pairing-based auth
        if let pairingCode = authInfo["pairing_code"] as? String,
           let hostname = authInfo["hostname"] as? String {
            // Show pairing dialog to user
            showPairingDialog(code: pairingCode, hostname: hostname, clientId: clientId)
            return
        }

        // No valid auth credentials
        Log.warn("⚠️  Client \(clientId.prefix(8)) sent invalid auth message")
        let errorMsg = AstationMessage.error(message: "Invalid auth credentials")
        sendMessage(errorMsg, to: clientId)
        ws.close(code: .policyViolation)
    }

    private func authenticateClient(_ clientId: String, sessionId: String) {
        authenticatedClients.insert(clientId)
        sessionStore.refresh(sessionId: sessionId)
    }

    private func handleSessionVerifyRequest(_ data: [String: String], from clientId: String) {
        guard let sessionId = data["session_id"],
              let requestId = data["request_id"] else {
            Log.warn("⚠️  Session verify request missing required fields")
            return
        }

        Log.info("🔍 Session verification request from \(clientId.prefix(8)): session=\(sessionId.prefix(12))")

        // Check if session is valid in our SessionStore
        let isValid = sessionStore.validate(sessionId: sessionId)

        // Get astation_id if session is valid
        var astationId: String? = nil
        if isValid, let sessionInfo = sessionStore.get(sessionId: sessionId) {
            astationId = AstationIdentity.shared.id
            // Refresh the session since it's being used
            sessionStore.refresh(sessionId: sessionId)
        }

        // Send verification response back to relay
        var responseData: [String: String] = [
            "session_id": sessionId,
            "request_id": requestId,
            "valid": isValid ? "true" : "false"
        ]

        if let astationId = astationId {
            responseData["astation_id"] = astationId
        }

        let response = AstationMessage.statusUpdate(
            status: "session_verify_response",
            data: responseData
        )

        sendMessage(response, to: clientId)

        Log.info("✅ Session verification response sent: valid=\(isValid)")
    }

    private func showPairingDialog(code: String, hostname: String, clientId: String) {
        // Show pairing approval dialog on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let alert = NSAlert()
            alert.messageText = "Atem Pairing Request"
            alert.informativeText = """
            Device: \(hostname)
            Code: \(code)

            Allow this Atem to connect?
            """
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            alert.alertStyle = .informational

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                // User approved - create session
                let session = self.sessionStore.create(hostname: hostname)

                // Authenticate client
                self.authenticatedClients.insert(clientId)

                // Add to hub manager
                let client = ConnectedClient(
                    id: clientId,
                    clientType: "Atem",
                    connectedAt: Date(),
                    hostname: hostname
                )
                self.hubManager.addClient(client)

                // Send success with session info
                let successMsg = AstationMessage.auth(info: [
                    "status": "granted",
                    "session_id": session.id,
                    "token": session.token
                ])
                self.sendMessage(successMsg, to: clientId)

                Log.info("✅ Pairing approved for \(hostname) (\(clientId.prefix(8)))")
            } else {
                // User denied
                let errorMsg = AstationMessage.error(message: "Pairing denied by user")
                self.sendMessage(errorMsg, to: clientId)

                if let ws = self.connectedClients[clientId] {
                    ws.close(code: .policyViolation)
                }

                Log.info("❌ Pairing denied for \(hostname) (\(clientId.prefix(8)))")
            }
        }
    }
    
    private func sendMessage(_ message: AstationMessage, to clientId: String) {
        guard let ws = connectedClients[clientId],
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            Log.error("Failed to send message to \(clientId)")
            return
        }

        ws.send(text)
        NetworkDebugLogger.logWebSocket(direction: "send", context: "local \(clientId)", message: text)
    }
    
    func sendMessageToClient(_ message: AstationMessage, clientId: String) {
        sendMessage(message, to: clientId)
    }

    func broadcastMessage(_ message: AstationMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            Log.error("Failed to encode broadcast message")
            return
        }
        
        for (clientId, ws) in connectedClients {
            ws.send(text)
            NetworkDebugLogger.logWebSocket(direction: "send", context: "local \(clientId)", message: text)
        }
    }
    
    func getConnectedClientsCount() -> Int {
        return connectedClients.count
    }
}

// Simple HTTP handler for WebSocket upgrade
private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
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
