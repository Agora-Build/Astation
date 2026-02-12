import CStationCore
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
    let timeSync = TimeSync()
    lazy var sessionLinkManager = SessionLinkManager(hubManager: self)
    @Published var projectLoadError: String?

    /// Opaque handle to the C core engine (VAD + signaling pipeline).
    private var coreHandle: OpaquePointer?

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
        Log.info("Initializing Astation Hub Manager")
        setupCore()
        setupRTCManager()
        checkCredentialStatus()
        loadProjects()
    }

    deinit {
        if let core = coreHandle {
            astation_core_destroy(core)
            coreHandle = nil
        }
    }

    // MARK: - Core Pipeline Setup

    private func setupCore() {
        var config = AStationCoreConfig()
        // Defaults for VAD: 16 kHz, 20 ms frames, 600 ms silence, 30 s inactivity
        config.vad_sample_rate = 16000
        config.vad_frame_duration_ms = 20
        config.vad_silence_duration_ms = 600
        config.inactivity_timeout_ms = 30000

        var callbacks = AStationCoreCallbacks()
        callbacks.on_log = { level, message, _ in
            guard let msg = message.map({ String(cString: $0) }) else { return }
            switch level {
            case ASTATION_LOG_ERROR: Log.error("[Core] \(msg)")
            case ASTATION_LOG_WARN:  Log.warn("[Core] \(msg)")
            case ASTATION_LOG_INFO:  Log.info("[Core] \(msg)")
            default:                 Log.debug("[Core] \(msg)")
            }
        }

        callbacks.on_transcription = { _, text, _, _ in
            guard let text = text.map({ String(cString: $0) }) else { return }
            Log.info("[Core] Transcription: \(text)")
        }

        // No signaling adapter for now — voice commands are routed via WebSocket
        coreHandle = astation_core_create(&config, &callbacks, nil)
        if coreHandle != nil {
            Log.info("Core engine initialized (VAD pipeline ready)")
        } else {
            Log.warn("Core engine creation returned nil — audio pipeline disabled")
        }
    }

    // MARK: - RTC Setup

    private func setupRTCManager() {
        // Wire RTC audio frames into the VAD/ASR pipeline.
        // The Agora RTC SDK delivers mic audio via on_audio_frame; forward to the core.
        rtcManager.onAudioFrame = { [weak self] data, samples, channels, sampleRate in
            guard let self = self, let core = self.coreHandle else { return }
            // Feed PCM16 audio into the VAD pipeline
            astation_core_feed_audio_frame(core, data, samples, UInt32(sampleRate))
            _ = channels // channels is implicit in sample interleaving
        }

        rtcManager.onJoinSuccess = { channel, uid in
            Log.info("RTC joined channel=\(channel) uid=\(uid)")
        }

        rtcManager.onLeave = {
            Log.info("RTC left channel")
        }

        rtcManager.onError = { code, message in
            Log.error("RTC error \(code): \(message)")
        }

        rtcManager.onUserJoined = { uid in
            Log.info("Remote user joined: \(uid)")
        }

        rtcManager.onUserLeft = { uid in
            Log.info("Remote user left: \(uid)")
        }
    }

    /// Initialize the RTC engine using the App ID from the first available project.
    func initializeRTC(appId: String) {
        do {
            try rtcManager.initialize(appId: appId)
            Log.info("RTC engine initialized")
        } catch {
            Log.error("Failed to initialize RTC: \(error)")
        }
    }

    /// Join an RTC channel (generates a real token and joins).
    func joinRTCChannel(channel: String, uid: Int, projectId: String? = nil) {
        guard uid >= 0, uid <= Int(UInt32.max) else {
            Log.warn(" Invalid UID for RTC join: '\(uid)'")
            return
        }
        let uidNum = UInt32(uid)
        Task {
            let tokenResponse = await generateRTCToken(channel: channel, uid: uid, projectId: projectId)
            rtcManager.joinChannel(token: tokenResponse.token, channel: channel, uid: uidNum)
        }
    }

    /// Leave the current RTC channel and revoke all share links.
    func leaveRTCChannel() {
        Task { await sessionLinkManager.revokeAll() }
        rtcManager.leaveChannel()
    }
    
    // MARK: - Credentials
    
    func getCredentials() -> AgoraCredentials? {
        return credentialManager.load()
    }
    
    func checkCredentialStatus() {
        if credentialManager.hasCredentials {
            Log.info("[AstationHub] Credentials found in encrypted storage")
        } else {
            Log.info("[AstationHub] No credentials configured. Open Settings to add Agora credentials.")
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
            Log.info("[AstationHub] No credentials — cannot fetch projects. Open Settings to configure.")
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
                    Log.info(" Loaded \(fetched.count) projects from Agora Console API")
                }
            } catch {
                await MainActor.run {
                    self.projects = []
                    self.projectLoadError = error.localizedDescription
                    Log.error(" Failed to fetch projects: \(error)")
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
    
    func generateRTCToken(channel: String, uid: String, projectId: String? = nil) async -> TokenResponse {
        guard let uidInt = Int(uid) else {
            Log.warn(" Invalid UID for RTC token generation: '\(uid)'")
            return TokenResponse(token: "", channel: channel, uid: uid, expiresIn: "0")
        }
        return await generateRTCToken(channel: channel, uid: uidInt, projectId: projectId)
    }

    func generateRTCToken(channel: String, uid: Int, projectId: String? = nil) async -> TokenResponse {
        // Find the project to get appId + appCertificate
        let project: AgoraProject?
        if let projectId = projectId {
            project = projects.first(where: { $0.id == projectId || $0.vendorKey == projectId })
        } else {
            project = projects.first
        }

        guard let project = project, !project.signKey.isEmpty else {
            Log.warn(" No project with certificate found — returning empty token")
            return TokenResponse(token: "", channel: channel, uid: String(uid), expiresIn: "0")
        }

        guard uid >= 0, uid <= Int(UInt32.max) else {
            Log.warn(" Invalid UID for RTC token generation: '\(uid)'")
            return TokenResponse(token: "", channel: channel, uid: String(uid), expiresIn: "0")
        }
        let uidNum = UInt32(uid)

        let tokenExpireSeconds: UInt32 = 3600
        let privilegeExpireSeconds: UInt32 = 3600
        let role: Int32 = 1 // publisher

        let token: String
        let tokenPtr = astation_rtc_build_token(
            project.vendorKey,
            project.signKey,
            channel,
            uidNum,
            role,
            tokenExpireSeconds,
            privilegeExpireSeconds
        )
        if let tokenPtr {
            token = String(cString: tokenPtr)
            astation_token_free(tokenPtr)
        } else {
            token = ""
        }

        if token.isEmpty {
            Log.warn(" RTC token generation failed for channel '\(channel)', uid '\(uid)'")
        } else {
            Log.info(" Generated RTC token for channel '\(channel)', uid '\(uid)'")
        }

        return TokenResponse(
            token: token,
            channel: channel,
            uid: String(uid),
            expiresIn: "\(tokenExpireSeconds)s"
        )
    }
    
    // MARK: - Client Management
    
    func addClient(_ client: ConnectedClient) {
        DispatchQueue.main.async {
            self.connectedClients.append(client)
            Log.info(" Client connected: \(client.id) (\(client.clientType))")
            self.broadcastInstanceList()
        }
    }

    func removeClient(withId clientId: String) {
        DispatchQueue.main.async {
            self.connectedClients.removeAll { $0.id == clientId }
            Log.info(" Client disconnected: \(clientId)")
            self.broadcastInstanceList()
        }
    }
    
    func getConnectedClientCount() -> Int {
        return connectedClients.count
    }
    
    // MARK: - Claude Code Integration
    
    func launchClaudeCode(withContext context: String? = nil) -> Bool {
        Log.info(" Launching Claude Code...")
        
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
            Log.info(" Claude Code launched successfully")
            return true
        } catch {
            Log.error(" Failed to launch Claude Code: \(error)")
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
            Log.info(" Project list requested by client: \(clientId)")
            return .projectListResponse(projects: getProjects(), timestamp: Date())
            
        case .tokenRequest(let channel, let uid, let projectId):
            Log.info(" Token requested by client: \(clientId) for \(channel)/\(uid)")
            Task {
                let tokenResponse = await generateRTCToken(channel: channel, uid: uid, projectId: projectId)
                let response = AstationMessage.tokenResponse(
                    token: tokenResponse.token, channel: tokenResponse.channel,
                    uid: tokenResponse.uid, expiresIn: tokenResponse.expiresIn, timestamp: Date())
                self.sendHandler?(response, clientId)
            }
            return nil
            
        case .userCommand(let command, let context):
            Log.info(" User command from \(clientId): \(command)")
            handleUserCommand(command, context: context)
            return nil
            
        case .statusUpdate(let status, let data):
            Log.info(" Status update from \(clientId): \(status)")
            // Capture hostname/tag from the status update to track this Atem instance
            updateClientActivity(
                clientId: clientId,
                hostname: data["hostname"],
                tag: data["tag"]
            )
            return nil

        case .authRequest(let sessionId, let hostname, let otp, let timestamp):
            Log.info(" Auth request from \(clientId): session=\(sessionId), host=\(hostname)")
            let request = AuthRequest(sessionId: sessionId, hostname: hostname, otp: otp, timestamp: timestamp)
            DispatchQueue.main.async {
                let session = self.authGrantController.handleAuthRequest(request)
                self.handleAuthResult(session)
            }
            return nil  // Response sent asynchronously via notification

        case .markTaskNotify(let taskId, let status, let description):
            Log.info(" Mark task notify: \(taskId) — \(description)")
            handleMarkTaskNotify(taskId: taskId, status: status, description: description)
            return nil

        case .markTaskResult(let taskId, let success, let message):
            Log.info(" Mark task result: \(taskId) success=\(success) — \(message)")
            handleMarkTaskResult(taskId: taskId, success: success, message: message)
            return nil

        default:
            Log.debug(" Unhandled message type from client: \(clientId)")
            return nil
        }
    }
    
    // MARK: - Auth Grant Flow

    func handleAuthResult(_ session: AuthSession) {
        guard let granted = session.granted else {
            Log.info("[AstationHub] Auth session \(session.request.sessionId) still pending")
            return
        }

        if granted {
            Log.info(" Auth granted for \(session.request.hostname), token: \(session.sessionToken?.prefix(8) ?? "nil")...")

            let response = AstationMessage.authResponse(
                sessionId: session.request.sessionId,
                success: true,
                token: session.sessionToken,
                timestamp: Date()
            )
            broadcastAuthResponse(response, sessionId: session.request.sessionId)
        } else {
            Log.error(" Auth denied for \(session.request.hostname)")

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
        Log.info("[AstationHub] Voice toggled: \(voiceActive ? "active" : "muted")")
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
        Log.info("[AstationHub] Video toggled: \(videoActive ? "sharing" : "off")")
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
            Log.info(" No Atem connected — voice command dropped: \(text)")
            return
        }

        let message = AstationMessage.voiceCommand(text: text, isFinal: isFinal)
        sendHandler?(message, clientId)
        Log.info(" Voice command → \(clientId): \(text)\(isFinal ? " [final]" : "")")
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
        Log.info(" Mark task \(taskId) finished: \(success ? "completed" : "failed") — \(message)")
    }

    private func routeMarkTask(taskId: String) {
        guard let clientId = routeToFocusedAtem() else {
            Log.info(" No Atem connected — mark task \(taskId) stays pending")
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
        Log.info(" Mark task \(taskId) assigned to \(clientId)")
    }

    private func handleUserCommand(_ command: String, context: [String: String]) {
        // Handle special commands
        if command.lowercased().contains("claude") || command.lowercased().contains("help") {
            let contextString = context.isEmpty ? command : "\(command) with context: \(context)"
            _ = launchClaudeCode(withContext: contextString)
        }
    }

    // MARK: - Local RTC Dev Commands

    /// Handle local dev console commands for RTC testing.
    /// Supported:
    ///   /rtc status
    ///   /rtc join <channel> <uid> [project name]
    ///   /rtc leave
    ///   /rtc mic on|off|toggle
    ///   /rtc screen on|off [displayId]
    func handleLocalRtcCommand(_ command: String) -> String {
        let parts = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 2 else {
            return "RTC: invalid command. Try: /rtc help"
        }

        let action = parts[1].lowercased()
        switch action {
        case "help":
            return "RTC: /rtc status | /rtc join <channel> <uid> [project] | /rtc leave | /rtc mic on|off|toggle | /rtc screen on|off [displayId]"
        case "status":
            let channel = rtcManager.currentChannel ?? "none"
            return "RTC: inChannel=\(rtcManager.isInChannel) channel=\(channel) uid=\(rtcManager.currentUid) micMuted=\(rtcManager.isMicMuted) screenSharing=\(rtcManager.isScreenSharing)"
        case "join":
            guard parts.count >= 4 else {
                return "RTC: usage /rtc join <channel> <uid> [project]"
            }
            let channel = parts[2]
            guard let uid = Int(parts[3]) else {
                return "RTC: uid must be numeric"
            }
            guard uid >= 0 else {
                return "RTC: uid must be non-negative"
            }
            let projects = getProjects()
            guard !projects.isEmpty else {
                return "RTC: no projects loaded. Add credentials in Settings."
            }
            let projectName = parts.count >= 5 ? parts[4...].joined(separator: " ") : nil
            let project = projectName.flatMap { name in
                projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            } ?? projects[0]
            initializeRTC(appId: project.vendorKey)
            joinRTCChannel(channel: channel, uid: uid, projectId: project.id)
            return "RTC: joining channel=\(channel) uid=\(uid) project=\(project.name)"
        case "leave":
            leaveRTCChannel()
            return "RTC: leaving channel"
        case "mic":
            guard parts.count >= 3 else {
                return "RTC: usage /rtc mic on|off|toggle"
            }
            let mode = parts[2].lowercased()
            switch mode {
            case "on":
                rtcManager.muteMic(false)
                return "RTC: mic unmuted"
            case "off":
                rtcManager.muteMic(true)
                return "RTC: mic muted"
            case "toggle":
                rtcManager.muteMic(!rtcManager.isMicMuted)
                return "RTC: mic \(rtcManager.isMicMuted ? "muted" : "unmuted")"
            default:
                return "RTC: usage /rtc mic on|off|toggle"
            }
        case "screen":
            guard parts.count >= 3 else {
                return "RTC: usage /rtc screen on|off [displayId]"
            }
            let mode = parts[2].lowercased()
            switch mode {
            case "on":
                let displayId = parts.count >= 4 ? UInt32(parts[3]) ?? 0 : 0
                rtcManager.startScreenShare(displayId: displayId)
                return "RTC: screen share started (displayId=\(displayId))"
            case "off":
                rtcManager.stopScreenShare()
                return "RTC: screen share stopped"
            default:
                return "RTC: usage /rtc screen on|off [displayId]"
            }
        default:
            return "RTC: unknown command. Try: /rtc help"
        }
    }

    // MARK: - Dev Console Command Dispatch

    /// Send a userCommand to a specific Atem instance.
    func sendCommandToClient(_ command: String, action: String, clientId: String) {
        let context = ["action": action]
        let message = AstationMessage.userCommand(command: command, context: context)
        sendHandler?(message, clientId)
        Log.info("[AstationHub] Sent command [\(action)] to \(clientId.prefix(8))...: \(command.prefix(80))")
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

        Log.info("[AstationHub] Connecting to relay: \(wsUrl)")

        // Open a WebSocket to the relay and bridge messages
        guard let url = URL(string: wsUrl) else {
            Log.info("[AstationHub] Invalid relay URL: \(wsUrl)")
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
        sendHandler = { [weak task] message, targetId in
            if targetId == relayClientId {
                // Send to relay WebSocket
                if let jsonData = try? JSONEncoder().encode(message),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    task?.send(.string(jsonString)) { error in
                        if let error = error {
                            Log.info("[AstationHub] Relay send error: \(error)")
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
                Log.info("[AstationHub] Relay connection closed: \(error)")
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
