import Foundation
import AstationRemote
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
    private var authenticatedSessionIds: [String: String] = [:]
    private var pendingAuthentication: [String: DirectAuthenticationContext] = [:]
    private var pairingClients: Set<String> = []
    private final class SocketIdentity {
        var id = UUID().uuidString
        let scope: DirectConnectionScope
        init(scope: DirectConnectionScope) { self.scope = scope }
    }
    private var socketIdentities: [String: SocketIdentity] = [:]
    private var proxyChallenged: Set<String> = []
    private var channelHandles: [String: Set<String>] = [:]
    private var localControlAPI: LocalControlAPI?

    func configureLocalControlAPI(_ api: LocalControlAPI) {
        executeOnStateEventLoop { self.localControlAPI = api }
    }

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
                let httpHandler = HTTPHandler(api: { [weak self] in self?.localControlAPI })
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
        let identity = SocketIdentity(scope: scope)
        let clientId = identity.id
        socketIdentities[clientId] = identity
        connectedClients[clientId] = ws
        let challenge = DeviceAuthentication.makeChallenge()
        pendingAuthentication[clientId] = DirectAuthenticationContext(
            scope: scope,
            challenge: challenge
        )

        Log.info("New \(scope.rawValue) WebSocket connection: \(clientId.prefix(8))")

        // Handle incoming messages
        ws.onText { ws, text in
            self.handleIncomingMessage(text, from: identity.id, ws: ws)
        }

        ws.onBinary { ws, buffer in
            NetworkDebugLogger.logWebSocketBinary(direction: "recv", context: "local \(clientId)", size: buffer.readableBytes)
        }

        // Handle connection close
        ws.onClose.whenComplete { _ in
            let clientId = identity.id
            self.connectedClients.removeValue(forKey: clientId)
            self.authenticatedClients.remove(clientId)
            self.authenticatedSessionIds.removeValue(forKey: clientId)
            self.pendingAuthentication.removeValue(forKey: clientId)
            self.pairingClients.remove(clientId)
            self.socketIdentities.removeValue(forKey: clientId)
            self.proxyChallenged.remove(clientId)
            self.channelHandles.removeValue(forKey: clientId)
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
        if let fields = try? AtemSessionJSON.validatePacket(Data(text.utf8)), fields["type"]?.string == "relay" {
            guard hasCurrentSession(clientId) else { return }
            Task { @MainActor in self.hubManager.receiveLocalStationProxy(Data(text.utf8), clientID: clientId) }
            return
        }
        if RemoteStationRoute.isEnvelope(Data(text.utf8)) {
            guard hasCurrentSession(clientId) else { _ = ws.close(code: .policyViolation); return }
            let bytes = Data(text.utf8)
            Task { @MainActor in
                self.hubManager.receiveStationRoute(bytes, clientID: clientId, connectionID: clientId)
            }
            return
        }
        if RemoteRelayEnvelope.isChannel(Data(text.utf8)) {
            guard hasCurrentSession(clientId) else { _ = ws.close(code: .policyViolation); return }
            let bytes = Data(text.utf8)
            if case .close(let handle, _) = try? RemoteChannelEnvelope.readHost(bytes) {
                channelHandles[clientId]?.remove(handle)
            }
            Task { @MainActor in
                self.hubManager.receiveR9Envelope(bytes, clientID: clientId, connectionID: clientId)
            }
            return
        }
        NetworkDebugLogger.logWebSocket(direction: "recv", context: "local \(clientId.prefix(8))", message: text)

        guard let data = text.data(using: .utf8),
              let message = try? AstationMessage.decodePacket(data) else {
            Log.error("❌ Failed to decode message from \(clientId.prefix(8)) (\(text.utf8.count) bytes)")
            return
        }

        // Check if client is authenticated
        if !authenticatedClients.contains(clientId) {
            // Client not authenticated - check if this is an auth message
            handleAuthMessage(message, from: clientId, ws: ws)
            return
        }

        if message.isPrivateAgentTraffic, !hasCurrentSession(clientId) {
            _ = ws.close(code: .policyViolation)
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
                registerClient(clientId, hostname: session.hostname, atemId: atemId, sessionId: session.id)

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
        registerClient(clientId, hostname: hostname, atemId: atemId, sessionId: session.id)
        Log.info("Loopback client \(clientId.prefix(8)) authenticated without interactive pairing")
    }

    private func registerClient(_ clientId: String, hostname: String, atemId: String?, sessionId: String) {
        authenticatedSessionIds[clientId] = sessionId
        hubManager.addClient(ConnectedClient(
            id: clientId,
            clientType: "Atem",
            connectedAt: Date(),
            hostname: hostname,
            atemId: atemId,
            authenticationSessionId: sessionId
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
                    self.registerClient(clientId, hostname: hostname, atemId: atemId, sessionId: session.id)
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
        if message.isPrivateAgentTraffic, !hasCurrentSession(clientId) {
            _ = connectedClients[clientId]?.close(code: .policyViolation)
            return
        }
        guard let ws = connectedClients[clientId],
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            Log.error("Failed to send message to \(clientId)")
            return
        }

        ws.send(text)
        NetworkDebugLogger.logWebSocket(direction: "send", context: "local \(clientId)", message: text)
    }

    private func hasCurrentSession(_ clientId: String) -> Bool {
        guard authenticatedClients.contains(clientId), let sessionId = authenticatedSessionIds[clientId],
              let session = sessionStore.get(sessionId: sessionId) else { return false }
        return session.isValid
    }
    
    func sendMessageToClient(_ message: AstationMessage, clientId: String) {
        executeOnStateEventLoop {
            self.sendMessage(message, to: clientId)
        }
    }

    func sendChannel(_ bytes: Data, clientID: String, completion: @escaping (Error?) -> Void) {
        guard stateEventLoop != nil else { completion(RemoteChannelError.staleLink); return }
        executeOnStateEventLoop {
            guard self.hasCurrentSession(clientID), let ws = self.connectedClients[clientID], !ws.isClosed,
                  bytes.count <= RemoteChannelEnvelope.maximumBytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                completion(RemoteChannelError.staleLink); return
            }
            let promise = ws.eventLoop.makePromise(of: Void.self)
            if let fields = try? AtemSessionJSON.validatePacket(bytes), fields["type"]?.string == "channel",
               let handle = fields["channel"]?.string {
                if fields["event"]?.string == "open" { self.channelHandles[clientID, default: []].insert(handle) }
                if fields["event"]?.string == "close" { self.channelHandles[clientID]?.remove(handle) }
            }
            promise.futureResult.whenComplete { result in
                switch result { case .success: completion(nil); case .failure(let error): completion(error) }
            }
            ws.send(text, promise: promise)
        }
    }

    func sendStationProxy(_ bytes: Data, clientID: String, completion: @escaping (Error?) -> Void) {
        executeOnStateEventLoop {
            guard self.hasCurrentSession(clientID) else { completion(RemoteChannelError.staleLink); return }
            if let fields = try? AtemSessionJSON.validatePacket(bytes), fields["type"]?.string == "relay",
               fields["op"]?.string == "host_challenge" {
                // Atem signs once per authentication generation. A new Station
                // nonce requires fresh local authentication, never proof replay.
                if !self.proxyChallenged.insert(clientID).inserted {
                    self.reauthenticate(clientID)
                    completion(RemoteChannelError.staleLink); return
                }
            }
            self.sendChannel(bytes, clientID: clientID, completion: completion)
        }
    }

    private func reauthenticate(_ clientID: String) {
        guard let ws = connectedClients.removeValue(forKey: clientID), !ws.isClosed,
              let identity = socketIdentities.removeValue(forKey: clientID) else { return }
        for handle in channelHandles.removeValue(forKey: clientID) ?? [] {
            if let route = try? RemoteChannelRoute(linkGeneration: UUID(), handle: handle) {
                ws.send(String(decoding: RemoteChannelEnvelope.close(route: route), as: UTF8.self))
            }
        }
        authenticatedClients.remove(clientID); authenticatedSessionIds.removeValue(forKey: clientID)
        pendingAuthentication.removeValue(forKey: clientID); proxyChallenged.remove(clientID)
        hubManager.removeClient(withId: clientID)
        identity.id = UUID().uuidString
        let next = identity.id, challenge = DeviceAuthentication.makeChallenge()
        connectedClients[next] = ws; socketIdentities[next] = identity
        pendingAuthentication[next] = DirectAuthenticationContext(scope: identity.scope, challenge: challenge)
        sendMessage(.statusUpdate(status: "auth_required", data: ["clientId": next,
            "astation_id": AstationIdentity.shared.id, "challenge": challenge,
            "transport": identity.scope.rawValue, "protocol": DeviceAuthentication.protocolVersion]), to: next)
        ws.eventLoop.scheduleTask(in: .seconds(10)) {
            if self.pendingAuthentication[next] != nil { _ = ws.close(code: .policyViolation) }
        }
    }

    func disconnectClients(authenticatedWith sessionIds: [String]) {
        executeOnStateEventLoop {
            let removed = Set(sessionIds)
            for (clientId, sessionId) in self.authenticatedSessionIds where removed.contains(sessionId) {
                _ = self.connectedClients[clientId]?.close(code: .policyViolation)
            }
        }
    }

    func disconnectClientForSessionReset(_ clientId: String) {
        executeOnStateEventLoop {
            guard self.authenticatedClients.contains(clientId) else { return }
            _ = self.connectedClients[clientId]?.close(code: .goingAway)
        }
    }

    func broadcastMessage(_ message: AstationMessage) {
        executeOnStateEventLoop {
            self.broadcastMessageOnEventLoop(message)
        }
    }

    private func broadcastMessageOnEventLoop(_ message: AstationMessage) {
        if message.isPrivateAgentTraffic { return }
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

enum DirectConnectionScope: String {
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
    private let api: () -> LocalControlAPI?
    private var acceptedAPI: LocalControlAPI?
    private var request: HTTPRequestHead?
    private var body = Data()
    private var responding = false

    init(api: @escaping () -> LocalControlAPI?) { self.api = api }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        let reqPart = unwrapInboundIn(data)
        
        switch reqPart {
        case .head(let request):
            guard self.request == nil else { respond(.error("invalid_request", status: .badRequest), context: context); return }
            guard request.uri.hasPrefix("/api/v1/"), let api = api() else {
                respond(.error("not_found", status: .notFound), context: context); return
            }
            guard api.key.authorizes(request, peerAddress: context.remoteAddress?.ipAddress) else {
                respond(.error("unauthorized", status: .unauthorized), context: context); return
            }
            if request.method == .POST, request.headers["content-type"] != ["application/json"] {
                respond(.error("json_required", status: .unsupportedMediaType), context: context); return
            }
            self.request = request
            acceptedAPI = api
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= LocalControlAPI.maximumBody else {
                respond(.error("body_too_large", status: .payloadTooLarge), context: context); return
            }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let request, let api = acceptedAPI else { return }
            responding = true
            let body = self.body
            let channel = context.channel
            DispatchQueue.main.async {
                let response = api.handle(method: request.method, path: request.uri, body: body)
                channel.eventLoop.execute { self.write(response, channel: channel) }
            }
        }
    }

    private func respond(_ response: LocalAPIResponse, context: ChannelHandlerContext) {
        responding = true
        write(response, channel: context.channel)
    }

    private func write(_ response: LocalAPIResponse, channel: Channel) {
        let headers = HTTPHeaders([("content-type", "application/json"), ("content-length", String(response.body.count)),
                                   ("cache-control", "no-store"), ("connection", "close"), ("x-content-type-options", "nosniff")])
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)), promise: nil)
        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}
