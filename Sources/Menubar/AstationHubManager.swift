import Foundation

// Hub Manager - Contains all business logic for Agora projects, tokens, etc.
class AstationHubManager: ObservableObject {
    @Published var connectedClients: [ConnectedClient] = []
    @Published var projects: [AgoraProject] = []
    @Published var isClaudeRunning = false
    @Published var startTime = Date()
    @Published var voiceActive = false
    @Published var videoActive = false
    @Published var markTasks: [MarkTask] = []

    private var hubStartTime = Date()
    let credentialManager = CredentialManager()
    let apiClient = AgoraAPIClient()
    let rtcManager = RTCManager()
    let authGrantController = AuthGrantController()
    @Published var projectLoadError: String?

    /// Station relay URL. Priority: AGORA_STATION_RELAY_URL env var > UserDefaults > default.
    var stationRelayUrl: String {
        SettingsWindowController.currentStationURL
    }

    /// Callback for broadcasting messages to all connected Atem clients.
    /// Set by AstationApp after wiring up the WebSocket server.
    var broadcastHandler: ((AstationMessage) -> Void)?

    /// Callback for sending a message to a specific client by ID.
    /// Set by AstationApp after wiring up the WebSocket server.
    var sendHandler: ((AstationMessage, String) -> Void)?

    init() {
        print("[AstationHub] Initializing Astation Hub Manager")
        setupRTCManager()
        checkCredentialStatus()
        loadProjects()
    }

    // MARK: - RTC Setup

    private func setupRTCManager() {
        // Wire RTC audio frames into the VAD/ASR pipeline.
        // When the real Agora RTC SDK delivers audio, on_audio_frame fires and
        // the samples can be forwarded to astation_core_feed_audio_frame().
        rtcManager.onAudioFrame = { [weak self] data, samples, channels, sampleRate in
            guard self != nil else { return }
            // TODO: Forward PCM to astation_core_feed_audio_frame() once core is wired in Swift.
            // For now the stub RTC engine does not produce real audio frames.
            _ = (data, samples, channels, sampleRate)
        }

        rtcManager.onJoinSuccess = { channel, uid in
            print("[AstationHub] RTC joined channel=\(channel) uid=\(uid)")
        }

        rtcManager.onLeave = {
            print("[AstationHub] RTC left channel")
        }

        rtcManager.onError = { code, message in
            print("[AstationHub] RTC error \(code): \(message)")
        }

        rtcManager.onUserJoined = { uid in
            print("[AstationHub] Remote user joined: \(uid)")
        }

        rtcManager.onUserLeft = { uid in
            print("[AstationHub] Remote user left: \(uid)")
        }
    }

    /// Initialize the RTC engine using the App ID from the first available project.
    func initializeRTC(appId: String) {
        do {
            try rtcManager.initialize(appId: appId)
            print("[AstationHub] RTC engine initialized")
        } catch {
            print("[AstationHub] Failed to initialize RTC: \(error)")
        }
    }

    /// Join an RTC channel (generates a token and joins).
    func joinRTCChannel(channel: String, uid: UInt32, projectId: String? = nil) {
        let tokenResponse = generateRTCToken(channel: channel, uid: String(uid), projectId: projectId)
        rtcManager.joinChannel(token: tokenResponse.token, channel: channel, uid: uid)
    }

    /// Leave the current RTC channel.
    func leaveRTCChannel() {
        rtcManager.leaveChannel()
    }
    
    // MARK: - Credentials
    
    func getCredentials() -> AgoraCredentials? {
        return credentialManager.load()
    }
    
    func checkCredentialStatus() {
        if credentialManager.hasCredentials {
            print("[AstationHub] Credentials found in encrypted storage")
        } else {
            print("[AstationHub] No credentials configured. Open Settings to add Agora credentials.")
        }
    }

    func reloadCredentials() {
        checkCredentialStatus()
        refreshProjects()
    }
    
    // MARK: - Projects Management

    /// Load projects: try real API first, fall back to empty list with error message.
    private func loadProjects() {
        guard let credentials = credentialManager.load() else {
            print("[AstationHub] No credentials — cannot fetch projects. Open Settings to configure.")
            DispatchQueue.main.async {
                self.projects = []
                self.projectLoadError = "No credentials configured"
            }
            return
        }

        Task {
            do {
                let fetched = try await apiClient.fetchProjects(credentials: credentials)
                await MainActor.run {
                    self.projects = fetched
                    self.projectLoadError = nil
                    print("📋 Loaded \(fetched.count) projects from Agora Console API")
                }
            } catch {
                await MainActor.run {
                    self.projects = []
                    self.projectLoadError = error.localizedDescription
                    print("❌ Failed to fetch projects: \(error)")
                }
            }
        }
    }

    /// Re-fetch projects from the API (e.g. after credentials change).
    func refreshProjects() {
        loadProjects()
    }
    
    func getProjects() -> [AgoraProject] {
        return projects
    }
    
    // MARK: - Token Management
    
    func generateRTCToken(channel: String, uid: String, projectId: String? = nil) -> TokenResponse {
        let tokenPayload: [String: Any] = [
            "uid": uid,
            "channel": channel,
            "exp": Int(Date().timeIntervalSince1970) + 3600, // 1 hour from now
            "iat": Int(Date().timeIntervalSince1970),
            "uuid": UUID().uuidString
        ]
        
        // Create fake base64 token (in production, use real Agora token generation)
        let jsonData = try! JSONSerialization.data(withJSONObject: tokenPayload)
        let token = jsonData.base64EncodedString()
        
        print("🔑 Generated RTC token for channel '\(channel)', uid '\(uid)'")
        
        return TokenResponse(
            token: token,
            channel: channel,
            uid: uid,
            expiresIn: "1 hour"
        )
    }
    
    // MARK: - Client Management
    
    func addClient(_ client: ConnectedClient) {
        DispatchQueue.main.async {
            self.connectedClients.append(client)
            print("👥 Client connected: \(client.id) (\(client.clientType))")
            self.broadcastInstanceList()
        }
    }

    func removeClient(withId clientId: String) {
        DispatchQueue.main.async {
            self.connectedClients.removeAll { $0.id == clientId }
            print("👋 Client disconnected: \(clientId)")
            self.broadcastInstanceList()
        }
    }
    
    func getConnectedClientCount() -> Int {
        return connectedClients.count
    }
    
    // MARK: - Claude Code Integration
    
    func launchClaudeCode(withContext context: String? = nil) -> Bool {
        print("🤖 Launching Claude Code...")
        
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["claude"]
        
        if let context = context {
            task.arguments?.append(contentsOf: ["--prompt", context])
        }
        
        do {
            try task.run()
            DispatchQueue.main.async {
                self.isClaudeRunning = true
            }
            print("✅ Claude Code launched successfully")
            return true
        } catch {
            print("❌ Failed to launch Claude Code: \(error)")
            return false
        }
    }
    
    // MARK: - System Status
    
    func getSystemStatus() -> SystemStatus {
        let uptime = Date().timeIntervalSince(hubStartTime)
        
        return SystemStatus(
            connectedClients: getConnectedClientCount(),
            claudeRunning: isClaudeRunning,
            uptimeSeconds: UInt64(uptime),
            projects: projects.count
        )
    }
    
    // MARK: - Message Handling
    
    func handleMessage(_ message: AstationMessage, from clientId: String) -> AstationMessage? {
        switch message {
        case .projectListRequest:
            print("📋 Project list requested by client: \(clientId)")
            return .projectListResponse(projects: getProjects(), timestamp: Date())
            
        case .tokenRequest(let channel, let uid, let projectId):
            print("🔑 Token requested by client: \(clientId) for \(channel)/\(uid)")
            let tokenResponse = generateRTCToken(channel: channel, uid: uid, projectId: projectId)
            return .tokenResponse(token: tokenResponse.token, channel: tokenResponse.channel, uid: tokenResponse.uid, expiresIn: tokenResponse.expiresIn, timestamp: Date())
            
        case .userCommand(let command, let context):
            print("💻 User command from \(clientId): \(command)")
            handleUserCommand(command, context: context)
            return nil
            
        case .statusUpdate(let status, let data):
            print("📊 Status update from \(clientId): \(status)")
            // Capture hostname/tag from the status update to track this Atem instance
            updateClientActivity(
                clientId: clientId,
                hostname: data["hostname"],
                tag: data["tag"]
            )
            return nil

        case .authRequest(let sessionId, let hostname, let otp, let timestamp):
            print("🔐 Auth request from \(clientId): session=\(sessionId), host=\(hostname)")
            let request = AuthRequest(sessionId: sessionId, hostname: hostname, otp: otp, timestamp: timestamp)
            DispatchQueue.main.async {
                let session = self.authGrantController.handleAuthRequest(request)
                self.handleAuthResult(session)
            }
            return nil  // Response sent asynchronously via notification

        case .markTaskNotify(let taskId, let status, let description):
            print("📌 Mark task notify: \(taskId) — \(description)")
            handleMarkTaskNotify(taskId: taskId, status: status, description: description)
            return nil

        case .markTaskResult(let taskId, let success, let message):
            print("📌 Mark task result: \(taskId) success=\(success) — \(message)")
            handleMarkTaskResult(taskId: taskId, success: success, message: message)
            return nil

        default:
            print("ℹ️ Unhandled message type from client: \(clientId)")
            return nil
        }
    }
    
    // MARK: - Auth Grant Flow

    func handleAuthResult(_ session: AuthSession) {
        guard let granted = session.granted else {
            print("[AstationHub] Auth session \(session.request.sessionId) still pending")
            return
        }

        if granted {
            print("✅ Auth granted for \(session.request.hostname), token: \(session.sessionToken?.prefix(8) ?? "nil")...")

            let response = AstationMessage.authResponse(
                sessionId: session.request.sessionId,
                success: true,
                token: session.sessionToken,
                timestamp: Date()
            )
            broadcastAuthResponse(response, sessionId: session.request.sessionId)
        } else {
            print("❌ Auth denied for \(session.request.hostname)")

            let response = AstationMessage.authResponse(
                sessionId: session.request.sessionId,
                success: false,
                token: nil,
                timestamp: Date()
            )
            broadcastAuthResponse(response, sessionId: session.request.sessionId)
        }
    }

    private func broadcastAuthResponse(_ message: AstationMessage, sessionId: String) {
        // Post a notification so the WebSocket server can deliver the response
        // to the appropriate client(s).
        NotificationCenter.default.post(
            name: .authResponseReady,
            object: nil,
            userInfo: ["message": message, "sessionId": sessionId]
        )
    }

    // MARK: - Voice / Video Toggle (driven by global hotkeys)

    /// Toggle voice (mic mute/unmute) and broadcast state to all connected Atems.
    func toggleVoice() {
        voiceActive.toggle()

        if rtcManager.isInChannel {
            // Unmute mic when voice is active, mute when inactive
            rtcManager.muteMic(!voiceActive)
        }

        let message = AstationMessage.voiceToggle(active: voiceActive)
        broadcastHandler?(message)
        print("[AstationHub] Voice toggled: \(voiceActive ? "active" : "muted")")
    }

    /// Toggle video (screen share) and broadcast state to all connected Atems.
    func toggleVideo() {
        videoActive.toggle()

        if rtcManager.isInChannel {
            if videoActive {
                rtcManager.startScreenShare(displayId: 0)
            } else {
                rtcManager.stopScreenShare()
            }
        }

        let message = AstationMessage.videoToggle(active: videoActive)
        broadcastHandler?(message)
        print("[AstationHub] Video toggled: \(videoActive ? "sharing" : "off")")
    }

    // MARK: - Atem Instance Management

    /// Update a connected client's metadata from a status update.
    func updateClientActivity(clientId: String, hostname: String?, tag: String?) {
        DispatchQueue.main.async {
            guard let index = self.connectedClients.firstIndex(where: { $0.id == clientId }) else { return }

            if let hostname = hostname {
                self.connectedClients[index].hostname = hostname
            }
            if let tag = tag {
                self.connectedClients[index].tag = tag
            }
            self.connectedClients[index].lastActivity = Date()

            // Focus follows most-recent activity
            self.updateFocus(activeClientId: clientId)
        }
    }

    /// Mark the most-recently-active client as focused, unfocus others.
    private func updateFocus(activeClientId: String) {
        for i in connectedClients.indices {
            connectedClients[i].isFocused = (connectedClients[i].id == activeClientId)
        }
        broadcastInstanceList()
    }

    /// Build and broadcast the current Atem instance list to all clients.
    func broadcastInstanceList() {
        let instances = connectedClients.map { client in
            AtemInstanceInfo(
                id: client.id,
                hostname: client.hostname,
                tag: client.tag,
                isFocused: client.isFocused
            )
        }
        let message = AstationMessage.atemInstanceList(instances: instances)
        broadcastHandler?(message)
    }

    /// Get the currently focused Atem client, if any.
    func focusedClient() -> ConnectedClient? {
        return connectedClients.first(where: { $0.isFocused })
    }

    /// Pick the target Atem for routing: focused client, or first connected.
    /// Returns the client ID, or nil if no Atem is connected.
    func routeToFocusedAtem() -> String? {
        return (focusedClient() ?? connectedClients.first)?.id
    }

    // MARK: - Voice Command Routing

    /// Send a voice command to the focused Atem instance.
    /// Called by the transcription pipeline when speech-to-text produces text.
    func sendVoiceCommand(text: String, isFinal: Bool) {
        guard let clientId = routeToFocusedAtem() else {
            print("🎤 No Atem connected — voice command dropped: \(text)")
            return
        }

        let message = AstationMessage.voiceCommand(text: text, isFinal: isFinal)
        sendHandler?(message, clientId)
        print("🎤 Voice command → \(clientId): \(text)\(isFinal ? " [final]" : "")")
    }

    // MARK: - Mark Task Routing

    private func handleMarkTaskNotify(taskId: String, status: String, description: String) {
        let task = MarkTask(taskId: taskId, description: description, receivedAt: Date(), status: status)
        DispatchQueue.main.async {
            self.markTasks.append(task)
        }
        routeMarkTask(taskId: taskId)
    }

    private func handleMarkTaskResult(taskId: String, success: Bool, message: String) {
        DispatchQueue.main.async {
            if let index = self.markTasks.firstIndex(where: { $0.taskId == taskId }) {
                self.markTasks[index].status = success ? "completed" : "failed"
                self.markTasks[index].resultMessage = message
            }
        }
        print("📌 Mark task \(taskId) finished: \(success ? "completed" : "failed") — \(message)")
    }

    private func routeMarkTask(taskId: String) {
        guard let clientId = routeToFocusedAtem() else {
            print("📌 No Atem connected — mark task \(taskId) stays pending")
            return
        }

        // Derive receivedAtMs from the stored MarkTask.receivedAt
        let receivedAtMs: UInt64
        if let index = markTasks.firstIndex(where: { $0.taskId == taskId }) {
            receivedAtMs = UInt64(markTasks[index].receivedAt.timeIntervalSince1970 * 1000)
        } else {
            receivedAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
        }

        let assignment = AstationMessage.markTaskAssignment(taskId: taskId, receivedAtMs: receivedAtMs)
        sendHandler?(assignment, clientId)

        DispatchQueue.main.async {
            if let index = self.markTasks.firstIndex(where: { $0.taskId == taskId }) {
                self.markTasks[index].status = "assigned"
                self.markTasks[index].assignedTo = clientId
            }
        }
        print("📌 Mark task \(taskId) assigned to \(clientId)")
    }

    private func handleUserCommand(_ command: String, context: [String: String]) {
        // Handle special commands
        if command.lowercased().contains("claude") || command.lowercased().contains("help") {
            let contextString = context.isEmpty ? command : "\(command) with context: \(context)"
            _ = launchClaudeCode(withContext: contextString)
        }
    }

    // MARK: - Dev Console Command Dispatch

    /// Send a userCommand to a specific Atem instance.
    func sendCommandToClient(_ command: String, action: String, clientId: String) {
        let context = ["action": action]
        let message = AstationMessage.userCommand(command: command, context: context)
        sendHandler?(message, clientId)
        print("[AstationHub] Sent command [\(action)] to \(clientId.prefix(8))...: \(command.prefix(80))")
    }

    // MARK: - Relay Pairing

    /// Connect to a remote Atem via the relay service using a pairing code.
    func connectToRelay(code: String) {
        let wsScheme: String
        if stationRelayUrl.hasPrefix("https://") {
            wsScheme = stationRelayUrl.replacingOccurrences(of: "https://", with: "wss://")
        } else {
            wsScheme = stationRelayUrl.replacingOccurrences(of: "http://", with: "ws://")
        }
        let wsUrl = "\(wsScheme)/ws?role=astation&code=\(code)"

        print("[AstationHub] Connecting to relay: \(wsUrl)")

        // Open a WebSocket to the relay and bridge messages
        guard let url = URL(string: wsUrl) else {
            print("[AstationHub] Invalid relay URL: \(wsUrl)")
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        // Generate a synthetic client ID for this relay connection
        let relayClientId = "relay-\(code)"

        // Add as connected client
        let client = ConnectedClient(
            id: relayClientId,
            clientType: "Atem",
            connectedAt: Date(),
            hostname: "relay:\(code)"
        )
        addClient(client)

        // Start reading messages from the relay
        readRelayMessages(task: task, clientId: relayClientId)

        // Wire send handler to also forward to relay
        let originalSend = sendHandler
        sendHandler = { [weak self, weak task] message, targetId in
            if targetId == relayClientId {
                // Send to relay WebSocket
                if let jsonData = try? JSONEncoder().encode(message),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    task?.send(.string(jsonString)) { error in
                        if let error = error {
                            print("[AstationHub] Relay send error: \(error)")
                        }
                    }
                }
            } else {
                // Forward to original handler (local WebSocket)
                originalSend?(message, targetId)
            }
        }
    }

    private func readRelayMessages(task: URLSessionWebSocketTask, clientId: String) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let msg = try? JSONDecoder().decode(AstationMessage.self, from: data) {
                        DispatchQueue.main.async {
                            let response = self?.handleMessage(msg, from: clientId)
                            // If there's a response, send it back via relay
                            if let response = response,
                               let jsonData = try? JSONEncoder().encode(response),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                task.send(.string(jsonString)) { _ in }
                            }
                        }
                    }
                default:
                    break
                }
                // Continue reading
                self?.readRelayMessages(task: task, clientId: clientId)

            case .failure(let error):
                print("[AstationHub] Relay connection closed: \(error)")
                DispatchQueue.main.async {
                    self?.removeClient(withId: clientId)
                }
            }
        }
    }
}

// MARK: - Data Models

struct ConnectedClient: Identifiable {
    let id: String
    let clientType: String
    let connectedAt: Date
    var hostname: String = "unknown"
    var tag: String = ""
    var lastActivity: Date = Date()
    var isFocused: Bool = false
}

struct MarkTask {
    let taskId: String
    let description: String
    let receivedAt: Date
    var status: String          // "pending", "assigned", "completed", "failed"
    var assignedTo: String?     // client ID
    var resultMessage: String?
}

struct AgoraProject: Codable, Identifiable {
    let id: String
    let name: String
    let vendorKey: String   // app_id
    let signKey: String     // app_certificate
    let status: String
    let created: UInt64     // Unix timestamp

    // Computed properties for backward-compatible WebSocket serialization
    var description: String { name }
    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created)) }

    enum CodingKeys: String, CodingKey {
        case id, name, vendorKey = "vendor_key", signKey = "sign_key", status, created
        // Also encode the fields Atem expects
        case description, createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(vendorKey, forKey: .vendorKey)
        try container.encode(signKey, forKey: .signKey)
        try container.encode(status, forKey: .status)
        try container.encode(created, forKey: .created)
        // Include fields Atem expects over WebSocket
        try container.encode(name, forKey: .description)
        try container.encode(formatUnixTimestamp(created), forKey: .createdAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        vendorKey = try container.decodeIfPresent(String.self, forKey: .vendorKey) ?? id
        signKey = try container.decodeIfPresent(String.self, forKey: .signKey) ?? ""
        status = try container.decode(String.self, forKey: .status)
        created = try container.decodeIfPresent(UInt64.self, forKey: .created) ?? 0
    }

    init(id: String, name: String, vendorKey: String, signKey: String, status: String, created: UInt64) {
        self.id = id
        self.name = name
        self.vendorKey = vendorKey
        self.signKey = signKey
        self.status = status
        self.created = created
    }
}

private func formatUnixTimestamp(_ ts: UInt64) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

struct TokenResponse {
    let token: String
    let channel: String
    let uid: String
    let expiresIn: String
}

struct SystemStatus {
    let connectedClients: Int
    let claudeRunning: Bool
    let uptimeSeconds: UInt64
    let projects: Int
}

// MARK: - Notification Names

extension Notification.Name {
    static let authResponseReady = Notification.Name("authResponseReady")
}