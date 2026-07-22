import Foundation
import AppKit
import WebSocketKit
import NIO
import NIOHTTP1
import NIOWebSocket

class AstationWebSocketServer {
    private var eventLoopGroup: EventLoopGroup!
    private var stateEventLoop: EventLoop?
    private var channel: Channel?
    private let hubManager: AstationHubManager
    private var connectedClients: [String: WebSocket] = [:]
    private let sessionStore: SessionStore
    private let localBootstrapStore: LocalBootstrapStore?
    private var authenticatedClients: Set<String> = []  // Client IDs that have been authenticated
    private var pendingAuthentication: [String: DirectAuthenticationContext] = [:]
    private var pairingClients: Set<String> = []

    init(
        hubManager: AstationHubManager,
        sessionStore: SessionStore = SessionStore(),
        localBootstrapStore: LocalBootstrapStore? = nil
    ) {
        self.hubManager = hubManager
        self.sessionStore = sessionStore
        self.localBootstrapStore = localBootstrapStore ?? (try? LocalBootstrapStore())
        if self.localBootstrapStore == nil {
            Log.error("Local Atem authentication is unavailable: bootstrap secret could not be loaded")
        }
    }
    
    func start(host: String, port: Int) throws {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        stateEventLoop = eventLoopGroup.next()
        
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                let scope = DirectConnectionScope(peerAddress: channel.remoteAddress?.ipAddress)
                return WebSocket.server(on: channel) { ws in
                    self.handleWebSocketConnection(ws, scope: scope)
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
    
    private func handleWebSocketConnection(_ ws: WebSocket, scope: DirectConnectionScope) {
        preconditionOnStateEventLoop()
        let clientId = UUID().uuidString
        connectedClients[clientId] = ws
        let challenge = DeviceAuthentication.makeChallenge()
        pendingAuthentication[clientId] = DirectAuthenticationContext(
            scope: scope,
            challenge: challenge
        )

        Log.info("New \(scope.rawValue) WebSocket connection: \(clientId.prefix(8))")

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
            self.pendingAuthentication.removeValue(forKey: clientId)
            self.pairingClients.remove(clientId)
            self.hubManager.removeClient(withId: clientId)
            Log.info("WebSocket connection closed: \(clientId.prefix(8))")
        }

        // Send auth challenge - client must respond with session or pairing code
        let authChallenge = AstationMessage.statusUpdate(
            status: "auth_required",
            data: [
                "clientId": clientId,
                "astation_id": AstationIdentity.shared.id,
                "challenge": challenge,
                "transport": scope.rawValue,
                "protocol": DeviceAuthentication.protocolVersion
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

        // Check if client is authenticated
        if !authenticatedClients.contains(clientId) {
            // Client not authenticated - check if this is an auth message
            handleAuthMessage(message, from: clientId, ws: ws)
            return
        }

        if case .statusUpdate(let status, let messageData) = message, status == "session_verify_request" {
            // This legacy control message is deliberately protected by v2 authentication.
            handleSessionVerifyRequest(messageData, from: clientId)
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
        guard !pairingClients.contains(clientId) else {
            sendMessage(.error(message: "Pairing approval is already pending"), to: clientId)
            return
        }

        // Extract auth credentials from message
        guard case .statusUpdate(let status, let authInfo) = message, status == "auth" else {
            // Not an auth message - reject
            Log.warn("⚠️  Unauthenticated client \(clientId.prefix(8)) sent non-auth message - rejecting")
            let errorMsg = AstationMessage.error(message: "Authentication required")
            sendMessage(errorMsg, to: clientId)
            _ = ws.close(code: .policyViolation)
            return
        }

        guard let context = pendingAuthentication[clientId] else {
            sendMessage(.error(message: "Authentication challenge expired"), to: clientId)
            _ = ws.close(code: .policyViolation)
            return
        }

        if context.scope == .loopback {
            authenticateLoopback(authInfo, context: context, clientId: clientId, ws: ws)
            return
        }

        if let sessionId = authInfo["session_id"],
           let atemId = authInfo["atem_id"],
           let proof = authInfo["proof"],
           let session = sessionStore.authenticate(
                sessionId: sessionId,
                atemId: atemId,
                challenge: context.challenge,
                proof: proof,
                astationId: AstationIdentity.shared.id
           ) {
                authenticateClient(clientId, sessionId: sessionId)
                pendingAuthentication.removeValue(forKey: clientId)

                let successMsg = AstationMessage.statusUpdate(
                    status: "authenticated",
                    data: [
                        "method": "session_proof",
                        "session_id": sessionId,
                        "protocol": DeviceAuthentication.protocolVersion
                    ]
                )
                sendMessage(successMsg, to: clientId)
                registerClient(clientId, hostname: session.hostname, atemId: atemId)

                Log.info("Client \(clientId.prefix(8)) authenticated via LAN session proof")
                return
        } else if authInfo["session_id"] != nil {
            Log.warn("Invalid session proof from LAN client \(clientId.prefix(8))")
            sendMessage(.error(message: "Session proof invalid - pairing required"), to: clientId)
            return
        }

        if let pairingCode = authInfo["pairing_code"],
           let rawHostname = authInfo["hostname"],
           let atemId = authInfo["atem_id"],
           DeviceAuthentication.isValidPairingCode(pairingCode),
           DeviceAuthentication.isValidAtemId(atemId) {
            pairingClients.insert(clientId)
            showPairingDialog(
                code: pairingCode,
                hostname: DeviceAuthentication.deviceLabel(rawHostname),
                atemId: atemId,
                clientId: clientId,
                ws: ws
            )
            return
        }

        // No valid auth credentials
        Log.warn("⚠️  Client \(clientId.prefix(8)) sent invalid auth message")
        let errorMsg = AstationMessage.error(message: "Invalid auth credentials")
        sendMessage(errorMsg, to: clientId)
        _ = ws.close(code: .policyViolation)
    }

    private func authenticateLoopback(
        _ authInfo: [String: String],
        context: DirectAuthenticationContext,
        clientId: String,
        ws: WebSocket
    ) {
        guard authInfo["method"] == "local_proof",
              let store = localBootstrapStore,
              let atemId = authInfo["atem_id"],
              let rawHostname = authInfo["hostname"],
              let proof = authInfo["proof"],
              DeviceAuthentication.verify(
                proof: proof,
                token: store.token,
                challenge: context.challenge,
                astationId: AstationIdentity.shared.id,
                atemId: atemId,
                sessionId: "local"
              ) else {
            Log.warn("Invalid same-user proof from loopback client \(clientId.prefix(8))")
            sendMessage(.error(message: "Local authentication failed"), to: clientId)
            _ = ws.close(code: .policyViolation)
            return
        }

        let hostname = DeviceAuthentication.deviceLabel(rawHostname)
        let session = sessionStore.createOrRefreshLocal(hostname: hostname, atemId: atemId)
        authenticatedClients.insert(clientId)
        pendingAuthentication.removeValue(forKey: clientId)
        sendMessage(.auth(info: [
            "status": "granted",
            "method": "local_proof",
            "session_id": session.id,
            "token": session.token,
            "protocol": DeviceAuthentication.protocolVersion
        ]), to: clientId)
        registerClient(clientId, hostname: hostname, atemId: atemId)
        Log.info("Loopback client \(clientId.prefix(8)) authenticated without interactive pairing")
    }

    private func registerClient(_ clientId: String, hostname: String, atemId: String?) {
        hubManager.addClient(ConnectedClient(
            id: clientId,
            clientType: "Atem",
            connectedAt: Date(),
            hostname: hostname,
            atemId: atemId
        ))
    }

    private func authenticateClient(_ clientId: String, sessionId: String) {
        authenticatedClients.insert(clientId)
        sessionStore.refresh(sessionId: sessionId)
    }

    private func handleSessionVerifyRequest(_ data: [String: String], from clientId: String) {
        guard let sessionId = data["session_id"],
              let requestId = data["request_id"],
              DeviceAuthentication.isValidSessionId(sessionId),
              DeviceAuthentication.isValidRequestId(requestId) else {
            Log.warn("⚠️  Session verify request missing required fields")
            return
        }

        Log.info("🔍 Session verification request from \(clientId.prefix(8)): session=\(sessionId.prefix(12))")

        // Check if session is valid in our SessionStore
        let isValid = sessionStore.validate(sessionId: sessionId)

        // Get astation_id if session is valid
        var astationId: String? = nil
        if isValid, sessionStore.get(sessionId: sessionId) != nil {
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

    private func showPairingDialog(
        code: String,
        hostname: String,
        atemId: String,
        clientId: String,
        ws: WebSocket
    ) {
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

            ws.eventLoop.execute {
                self.pairingClients.remove(clientId)
                guard self.connectedClients[clientId] != nil else { return }
                if response == .alertFirstButtonReturn {
                    let session = self.sessionStore.create(hostname: hostname, atemId: atemId)
                    self.authenticatedClients.insert(clientId)
                    self.pendingAuthentication.removeValue(forKey: clientId)
                    self.sendMessage(.auth(info: [
                        "status": "granted",
                        "session_id": session.id,
                        "token": session.token,
                        "protocol": DeviceAuthentication.protocolVersion
                    ]), to: clientId)
                    self.registerClient(clientId, hostname: hostname, atemId: atemId)
                    Log.info("✅ Pairing approved for \(hostname) (\(clientId.prefix(8)))")
                } else {
                    self.sendMessage(.error(message: "Pairing denied by user"), to: clientId)
                    _ = ws.close(code: .policyViolation)
                    Log.info("❌ Pairing denied for \(hostname) (\(clientId.prefix(8)))")
                }
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
        executeOnStateEventLoop {
            self.sendMessage(message, to: clientId)
        }
    }

    func broadcastMessage(_ message: AstationMessage) {
        executeOnStateEventLoop {
            self.broadcastMessageOnEventLoop(message)
        }
    }

    private func broadcastMessageOnEventLoop(_ message: AstationMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            Log.error("Failed to encode broadcast message")
            return
        }
        
        for clientId in authenticatedClients {
            guard let ws = connectedClients[clientId] else { continue }
            ws.send(text)
            NetworkDebugLogger.logWebSocket(direction: "send", context: "local \(clientId)", message: text)
        }
    }
    
    func getConnectedClientsCount() -> Int {
        guard let eventLoop = stateEventLoop else { return 0 }
        if eventLoop.inEventLoop {
            return connectedClients.count
        }
        return (try? eventLoop.submit { self.connectedClients.count }.wait()) ?? 0
    }

    private func executeOnStateEventLoop(_ operation: @escaping () -> Void) {
        guard let eventLoop = stateEventLoop else { return }
        if eventLoop.inEventLoop {
            operation()
        } else {
            eventLoop.execute(operation)
        }
    }

    private func preconditionOnStateEventLoop() {
        precondition(stateEventLoop?.inEventLoop == true, "Direct connection state left its NIO event loop")
    }

    var listeningPort: Int? {
        channel?.localAddress?.port
    }
}

private enum DirectConnectionScope: String {
    case loopback
    case lan

    init(peerAddress: String?) {
        switch peerAddress?.lowercased() {
        case "127.0.0.1", "::1", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1":
            self = .loopback
        default:
            self = .lan
        }
    }
}

private struct DirectAuthenticationContext {
    let scope: DirectConnectionScope
    let challenge: String
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
