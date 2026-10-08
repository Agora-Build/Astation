import CStationCore
import AppKit
import Foundation
import Network

// Hub Manager - Contains all business logic for Agora projects, tokens, etc.
class AstationHubManager: ObservableObject {
    @Published var connectedClients: [ConnectedClient] = []
    @Published var projects: [AgoraProject] = []
    @Published var selectedProject: AgoraProject?
    @Published var isClaudeRunning = false
    @Published var startTime = Date()
    @Published var voiceActive = false
    @Published var videoActive = false
    @Published var markTasks: [MarkTask] = []

    /// Agents reported by each Atem, keyed by clientId.
    @Published var agentsByClientId: [String: [AtemAgentInfo]] = [:]
    /// User-pinned active client ID. Overrides focus-based routing when set.
    @Published var pinnedClientId: String?

    private var hubStartTime = Date()
    let sessionStore: SsoSessionStore
    let tokenProvider: SsoTokenProvider
    let apiClient = AgoraAPIClient()
    let rtcManager = RTCManager()
    let authGrantController = AuthGrantController()
    let deviceSessionStore: SessionStore
    let timeSync = TimeSync()
    lazy var sessionLinkManager = SessionLinkManager(hubManager: self)
    lazy var voiceCodingManager = VoiceCodingManager(hubManager: self)
    @Published var projectLoadError: String?

    /// Opaque handle to the C core engine (VAD + signaling pipeline).
    private var coreHandle: OpaquePointer?

    /// Used by tests to inject a mock relay URL without touching UserDefaults.
    var _testRelayUrlOverride: String? = nil

    /// Guards against concurrent identity relay reconnect attempts.
    private var identityRelayActive = false
    /// Backoff is reset only after the relay verifies this Astation's key.
    private var identityRelayReconnectPolicy = IdentityRelayReconnectPolicy()
    /// Invalidates delayed retries left behind by an older socket generation.
    private var identityRelayReconnectGeneration = 0
    /// NWPathMonitor for the identity relay — fires when network becomes available,
    /// enabling immediate reconnect without polling. Created once and reused.
    private var identityRelayPathMonitor: NWPathMonitor?
    private var identityRelayAuthentication = IdentityRelayAuthenticationState()
    /// The current identity relay socket. Relay control frames are only
    /// accepted from, and binding messages only sent on, this socket. Main thread.
    private var identityRelayTask: IdentityRelaySocket?
    private let makeIdentityRelayTask: (URL) -> IdentityRelaySocket
    /// Installed once; relay sends resolve identityRelayTask when they execute.
    private var identityRelaySendHandlerInstalled = false
    /// True once the relay answered `relayAuthResult` registered|verified on
    /// `identityRelayTask`. Binding messages are only sent while verified. Main thread.
    private(set) var identityRelayVerified = false
    /// Relay identity key, preloaded off the main thread (Keychain / Secure Enclave).
    /// The challenge handler only signs with the cached key. Main thread.
    private let relayIdentityKeyManager: RelayIdentityKeyManager
    private let relayIdentityRepairDefaults: UserDefaults
    private var relayIdentityRepairReconnectRequested = false
    private var relayIdentityKeyRejected = false
    private var relayIdentityKeyRepairRecord: RelayIdentityKeyRepairRecord?
    @Published private(set) var relayIdentityKeyRepairPending = false
    /// A challenge that arrived while the key was still loading; answered when the
    /// load finishes (the relay allows 10 s). Main thread.
    private var pendingRelayChallenge: (challenge: String, task: IdentityRelaySocket)?
    /// Hourly expiry sweep so expired pairing sessions are unbound on the relay.
    private var sessionExpiryTimer: Timer?
    /// Relay identity problem shown in the menu (nil when fine).
    @Published var relayIdentityStatusMessage: String?
    @Published private(set) var relayAccountDevices: [RelayAccountDevice] = []
    @Published private(set) var relayMergeRequests: [RelayMergeRequest] = []
    @Published private(set) var relayAccountStatusMessage: String?
    @Published private(set) var relayEncryptionState: RelayEncryptionState?
    @Published var relayEncryptionStatusMessage: String?
    private var encryptionMigrationRetryDelay: TimeInterval = 1

    /// Station relay URL. Priority: test override > ASTATION_RELAY_URL env var > UserDefaults > default.
    var stationRelayUrl: String {
        StationRelayURL.normalizedBase(_testRelayUrlOverride ?? SettingsWindowController.currentAstationRelayUrl)
    }

    /// Callback for broadcasting messages to all connected Atem clients.
    /// Set by AstationApp after wiring up the WebSocket server.
    var broadcastHandler: ((AstationMessage) -> Void)?

    /// Callback for sending a message to a specific client by ID.
    /// Set by AstationApp after wiring up the WebSocket server.
    var sendHandler: ((AstationMessage, String) -> Void)?

    init(
        skipProjectLoad: Bool = false,
        deviceSessionStore: SessionStore = SessionStore(),
        sessionStore: SsoSessionStore = SsoSessionStore(),
        relayIdentityKeyManager: RelayIdentityKeyManager = RelayIdentityKeyManager(),
        relayIdentityRepairDefaults: UserDefaults = .standard,
        makeIdentityRelayTask: @escaping (URL) -> IdentityRelaySocket = { URLSession.shared.webSocketTask(with: $0) }
    ) {
        self.deviceSessionStore = deviceSessionStore
        self.sessionStore = sessionStore
        self.makeIdentityRelayTask = makeIdentityRelayTask
        self.relayIdentityKeyManager = relayIdentityKeyManager
        self.relayIdentityRepairDefaults = relayIdentityRepairDefaults
        self.tokenProvider = SsoTokenProvider(
            store: sessionStore,
            refresher: SsoNetworkRefresher(),
            ssoUrl: { SsoConfig.currentSsoUrl }
        )
        Log.info("Initializing Astation Hub Manager")
        deviceSessionStore.onSessionGranted = { [weak self] sessionId in
            self?.sendRelayBind(sessionId: sessionId)
        }
        deviceSessionStore.onSessionsRemoved = { [weak self] sessionIds in
            self?.sendRelayUnbind(sessionIds: sessionIds)
        }
        setupCore()
        setupRTCManager()
        checkSessionStatus()
        if !skipProjectLoad {
            loadProjects()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCredentialsChanged),
            name: .credentialsChanged,
            object: nil
        )
        self.relayIdentityKeyManager.onChange = { [weak self] state in
            self?.finishRelayIdentityKeyLoad(state)
        }
        relayIdentityKeyRepairRecord = RelayIdentityKeyRepairRecord.load(
            astationId: AstationIdentity.shared.id, relayURL: stationRelayUrl,
            defaults: relayIdentityRepairDefaults
        )
        relayIdentityKeyRepairPending = relayIdentityKeyRepairRecord != nil
        if relayIdentityKeyRepairPending {
            relayIdentityStatusMessage = "Device key recovery is paused. Complete the relay reset in Settings > Security, then reconnect."
        }
    }

    @objc private func handleCredentialsChanged() {
        reloadSession()
    }

    deinit {
        sessionExpiryTimer?.invalidate()
        identityRelayPathMonitor?.cancel()
        identityRelayTask?.cancel(with: .goingAway, reason: nil)
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
            // Notify voice coding manager of speech activity (for hands-free silence detection)
            self.voiceCodingManager.notifySpeechActivity()
        }

        rtcManager.onJoinSuccess = { channel, uid in
            Log.info("RTC joined channel=\(channel) uid=\(uid)")
            NotificationCenter.default.post(
                name: .rtcJoinSuccess,
                object: nil,
                userInfo: ["channel": channel, "uid": uid]
            )
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
        rtcManager.onTokenRenewalNeeded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let channel = self.rtcManager.currentChannel,
                      let appId = self.rtcManager.appId else { return }
                let uid = self.rtcManager.currentUid
                let response = await self.generateRTCToken(channel: channel, uid: Int(uid), projectId: appId)
                guard self.rtcManager.currentChannel == channel, self.rtcManager.currentUid == uid,
                      self.rtcManager.appId == appId else { return }
                self.rtcManager.renewToken(response.token)
            }
        }
    }

    /// Initialize the RTC engine using the App ID from the first available project.
    func initializeRTC(appId: String, geoFence: RTCGeoFence = .noFence) {
        do {
            try rtcManager.initialize(appId: appId, geoFence: geoFence)
            Log.info("RTC engine initialized")
        } catch {
            Log.error("Failed to initialize RTC: \(error)")
        }
    }

    /// Join an RTC channel (generates a real token and joins).
    func joinRTCChannel(
        channel: String,
        uid: Int,
        projectId: String? = nil,
        joinOptions: RTCJoinOptions = .standard
    ) {
        guard uid >= 0, uid <= Int(UInt32.max) else {
            Log.warn(" Invalid UID for RTC join: '\(uid)'")
            return
        }
        let uidNum = UInt32(uid)
        Task {
            let tokenResponse = await generateRTCToken(channel: channel, uid: uid, projectId: projectId)
            rtcManager.joinChannel(
                token: tokenResponse.token,
                channel: channel,
                uid: uidNum,
                joinOptions: joinOptions
            )
        }
    }

    /// Leave the current RTC channel and revoke all share links.
    func leaveRTCChannel() {
        Task { await sessionLinkManager.revokeAll() }
        rtcManager.leaveChannel()
    }
    
    // MARK: - SSO Session

    /// Whether an SSO session is on disk. Used by the UI to render
    /// "Signed in" vs "Sign in".
    var hasSession: Bool { sessionStore.hasSession }

    /// Loaded session (no refresh). Use `tokenProvider.validToken()` if you
    /// need a fresh access token for a network call.
    func currentSession() -> SsoSession? { sessionStore.load() }

    func checkSessionStatus() {
        if hasSession {
            Log.info("[AstationHub] SSO session found")
        } else {
            Log.info("[AstationHub] No SSO session. Open Settings → Sign in with Agora.")
        }
    }

    func reloadSession() {
        checkSessionStatus()
        refreshProjects()
        broadcastCredentials()
        registerRelayAccountIfPossible()
    }

    /// Broadcast a refreshed-on-use credentialSync to every connected Atem.
    func broadcastCredentials() {
        Task { await pushCredentials(targetClientId: nil) }
    }

    /// Send credentialSync to one specific Atem (e.g. just-connected).
    func sendCredentials(toClientId clientId: String, relayConnectionId: String? = nil) {
        Task {
            await pushCredentials(
                targetClientId: clientId,
                relayConnectionId: relayConnectionId
            )
        }
    }

    private func pushCredentials(
        targetClientId: String?,
        relayConnectionId: String? = nil
    ) async {
        do { _ = try await tokenProvider.validToken() }
        catch {
            Log.info("[AstationHub] No session — skipping credentialSync (\(error.localizedDescription))")
            return
        }
        guard let session = sessionStore.load() else { return }
        let msg = AstationMessage.credentialSync(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            loginId: session.loginId,
            astationId: AstationIdentity.shared.id,
            saveCredentials: false
        )
        if let id = targetClientId {
            sendMessage(msg, to: id, expectedRelayConnectionId: relayConnectionId)
            Log.info("[AstationHub] Sent credentialSync to \(id.prefix(8))…")
        } else {
            broadcastHandler?(msg)
            Log.info("[AstationHub] Broadcast credentialSync to all Atems")
        }
    }
    
    // MARK: - Projects Management

    /// Load projects from the BFF using the SSO access token.
    private func loadProjects() {
        Task {
            let token: String
            do { token = try await tokenProvider.validToken() }
            catch SsoError.notSignedIn {
                await MainActor.run {
                    self.projects = []
                    self.projectLoadError = "Not signed in. Open Settings → Sign in with Agora."
                    Log.info("[AstationHub] Cannot load projects: not signed in")
                }
                return
            } catch {
                await MainActor.run {
                    self.projects = []
                    self.projectLoadError = "Session expired — please sign in again."
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    Log.info("[AstationHub] Session expired, cleared: \(error.localizedDescription)")
                }
                return
            }
            do {
                let fetched = try await apiClient.fetchProjects(accessToken: token,
                                                                bffUrl: SsoConfig.currentBffUrl)
                await MainActor.run {
                    self.projects = fetched
                    self.projectLoadError = nil
                    if self.selectedProject == nil || !fetched.contains(where: { $0.id == self.selectedProject?.id }) {
                        self.selectedProject = fetched.first
                    }
                    Log.info(" Loaded \(fetched.count) projects from BFF")
                }
            } catch AgoraAPIError.unauthorized {
                try? self.sessionStore.delete()
                await MainActor.run {
                    self.projects = []
                    self.projectLoadError = "Session expired — please sign in again."
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
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

    /// The project to use for RTC, ConvoAI, and token generation.
    var effectiveProject: AgoraProject? {
        selectedProject ?? projects.first
    }

    func selectProject(id: String) {
        guard let project = projects.first(where: { $0.id == id }) else {
            Log.warn("[AstationHub] selectProject: no project with id \(id)")
            return
        }
        selectedProject = project
        Log.info("[AstationHub] Selected project: \(project.name)")
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
            project = effectiveProject
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
    
    // MARK: - ConvoAI Agent Support

    /// Generate an RTC token for the ConvoAI agent (UID 1001) in the given channel.
    func generateTokenForConvoAIAgent(channel: String) async -> String? {
        let response = await generateRTCToken(channel: channel, uid: "1001")
        return response.token.isEmpty ? nil : response.token
    }

    // MARK: - Client Management
    
    func addClient(_ client: ConnectedClient, relayConnectionId: String? = nil) {
        DispatchQueue.main.async {
            if let relayConnectionId {
                guard self.identityRelayAuthentication.isAuthenticated(
                    clientId: client.id,
                    connectionId: relayConnectionId
                ) else {
                    Log.warn("[AstationHub] Ignored stale relay client registration")
                    return
                }
            }
            self.connectedClients.append(client)
            Log.info(" Client connected: \(client.id) (\(client.clientType))")

            self.sendEncryptionMode(to: client.id, relayConnectionId: relayConnectionId)

            // Send credentials immediately after connection
            self.sendCredentials(
                toClientId: client.id,
                relayConnectionId: relayConnectionId
            )

            self.broadcastInstanceList()
        }
    }

    func removeClient(withId clientId: String) {
        DispatchQueue.main.async {
            self.connectedClients.removeAll { $0.id == clientId }
            self.agentsByClientId.removeValue(forKey: clientId)
            // If the pinned client disconnected, clear the pin
            if self.pinnedClientId == clientId {
                self.pinnedClientId = nil
            }
            Log.info("🔌 Client disconnected and removed: \(clientId.prefix(8))")
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
    
    func handleMessage(
        _ message: AstationMessage,
        from clientId: String,
        relayConnectionId: String? = nil
    ) -> AstationMessage? {
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
                self.sendMessage(
                    response,
                    to: clientId,
                    expectedRelayConnectionId: relayConnectionId
                )
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
                tag: data["tag"],
                relayConnectionId: relayConnectionId
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

        case .agentListResponse(let agents):
            Log.info("[AstationHub] Agent list from \(clientId.prefix(8))…: \(agents.count) agent(s)")
            DispatchQueue.main.async {
                self.agentsByClientId[clientId] = agents
            }
            return nil

        case .commandResponse(let output, let success, _):
            Log.info("[AstationHub] Command response from \(clientId.prefix(8))…: success=\(success)")
            // Post notification so Dev Console can display the response
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CommandResponseReceived"),
                    object: nil,
                    userInfo: ["clientId": clientId, "output": output, "success": success]
                )
            }
            return nil

        case .voiceResponse(let sessionId, let success, let message):
            Log.info("[AstationHub] Voice response from \(clientId.prefix(8))…: session=\(sessionId) success=\(success)")
            voiceCodingManager.handleVoiceResponse(sessionId: sessionId, success: success, message: message)
            return nil

        case .keyRequest(let publicKey):
            handleEncryptionKeyRequest(
                publicKey: publicKey,
                clientId: clientId,
                relayConnectionId: relayConnectionId
            )
            return nil

        case .encryptionMigrationComplete(let mode, let kid):
            handleEncryptionMigrationComplete(mode: mode, kid: kid)
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

            // Notify the relay server so atem login polling receives "granted".
            postGrantToRelayServer(sessionId: session.request.sessionId, otp: session.request.otp)

            let response = AstationMessage.authResponse(
                sessionId: session.request.sessionId,
                success: true,
                token: session.sessionToken,
                timestamp: Date()
            )
            broadcastAuthResponse(response, sessionId: session.request.sessionId)
        } else {
            Log.error(" Auth denied for \(session.request.hostname)")

            // Notify the relay server so atem login polling receives "denied".
            postDenyToRelayServer(sessionId: session.request.sessionId)

            let response = AstationMessage.authResponse(
                sessionId: session.request.sessionId,
                success: false,
                token: nil,
                timestamp: Date()
            )
            broadcastAuthResponse(response, sessionId: session.request.sessionId)
        }
    }

    /// POST /api/sessions/{id}/grant to the relay server so the polling atem login
    /// receives the granted status and session token.
    func postGrantToRelayServer(sessionId: String, otp: String) {
        guard let request = makeGrantRequest(sessionId: sessionId, otp: otp) else {
            return
        }

        NetworkDebugLogger.logRequest(request, label: "RelayGrant")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NetworkDebugLogger.logError(error, label: "RelayGrant")
                Log.error("[AstationHub] Grant POST failed: \(error)")
                return
            }
            NetworkDebugLogger.logResponse(response, data: data, label: "RelayGrant")
            if let http = response as? HTTPURLResponse {
                Log.info("[AstationHub] Grant POST status: \(http.statusCode)")
            }
        }.resume()
    }

    /// POST /api/sessions/{id}/deny to the relay server so the polling atem login
    /// receives the denied status.
    func postDenyToRelayServer(sessionId: String) {
        guard let request = makeDenyRequest(sessionId: sessionId) else {
            return
        }

        NetworkDebugLogger.logRequest(request, label: "RelayDeny")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NetworkDebugLogger.logError(error, label: "RelayDeny")
                Log.error("[AstationHub] Deny POST failed: \(error)")
                return
            }
            NetworkDebugLogger.logResponse(response, data: data, label: "RelayDeny")
            if let http = response as? HTTPURLResponse {
                Log.info("[AstationHub] Deny POST status: \(http.statusCode)")
            }
        }.resume()
    }

    func makeGrantRequest(sessionId: String, otp: String) -> URLRequest? {
        let urlString = "\(stationRelayUrl)/api/sessions/\(sessionId)/grant"
        guard let url = URL(string: urlString) else {
            Log.error("[AstationHub] Invalid grant URL: \(urlString)")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["otp": otp])
        return request
    }

    func makeDenyRequest(sessionId: String) -> URLRequest? {
        let urlString = "\(stationRelayUrl)/api/sessions/\(sessionId)/deny"
        guard let url = URL(string: urlString) else {
            Log.error("[AstationHub] Invalid deny URL: \(urlString)")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
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
        Task { @MainActor in
            if rtcManager.isScreenSharing || rtcManager.isScreenShareStarting {
                rtcManager.stopScreenShare()
            } else if rtcManager.isInChannel {
                await rtcManager.startScreenShare(displayId: 0)
            }
            videoActive = rtcManager.isScreenSharing
            broadcastHandler?(.videoToggle(active: videoActive))
            Log.info("[AstationHub] Video toggled: \(videoActive ? "sharing" : "off")")
        }
    }

    // MARK: - Atem Instance Management

    /// Update a connected client's metadata from a status update.
    func updateClientActivity(
        clientId: String,
        hostname: String?,
        tag: String?,
        relayConnectionId: String? = nil
    ) {
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

        // Ask this Atem to send its current agent list.
        sendMessage(
            AstationMessage.agentListRequest,
            to: clientId,
            expectedRelayConnectionId: relayConnectionId
        )

        // Push credentials to the newly connected Atem.
        sendCredentials(toClientId: clientId, relayConnectionId: relayConnectionId)
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

    /// Pick the target Atem for routing: pinned → focused → first connected.
    /// Returns the client ID, or nil if no Atem is connected.
    func routeToFocusedAtem() -> String? {
        if let pinned = pinnedClientId,
           connectedClients.contains(where: { $0.id == pinned }) {
            return pinned
        }
        return (focusedClient() ?? connectedClients.first)?.id
    }

    // MARK: - Client & Agent Management

    /// Explicitly pin a client as the active routing target.
    func pinClient(id: String) {
        DispatchQueue.main.async { self.pinnedClientId = id }
    }

    /// Clear the pin, reverting to focus-based routing.
    func unpinClient() {
        DispatchQueue.main.async { self.pinnedClientId = nil }
    }


    /// Ask a specific Atem to push its current agent list.
    func requestAgentList(from clientId: String) {
        sendHandler?(AstationMessage.agentListRequest, clientId)
        Log.info("[AstationHub] Requested agent list from \(clientId.prefix(8))…")
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

    // MARK: - Remote Agent Control

    /// Send a text instruction to an Atem agent (written to its PTY stdin + Enter).
    /// When no client or agent is specified, the focused Atem and its focused agent are used.
    func sendAgentText(_ text: String, agentId: String? = nil, clientId: String? = nil) {
        guard let targetClientId = clientId ?? routeToFocusedAtem() else {
            Log.info("[AgentInput] No Atem connected — text dropped: \(text)")
            return
        }
        guard connectedClients.contains(where: { $0.id == targetClientId }) else {
            Log.info("[AgentInput] Target Atem offline — text dropped: \(targetClientId)")
            return
        }
        let message = AstationMessage.agentInput(agentId: agentId, kind: "text", text: text, key: nil)
        sendHandler?(message, targetClientId)
        Log.info("[AgentInput] text → \(targetClientId): \(text)")
    }

    /// Send a control key to an Atem agent (written raw to its PTY).
    /// `key` is one of: enter, esc, ctrl-c, up, down, y, n.
    func sendAgentKey(_ key: String, agentId: String? = nil, clientId: String? = nil) {
        guard let targetClientId = clientId ?? routeToFocusedAtem() else {
            Log.info("[AgentInput] No Atem connected — key dropped: \(key)")
            return
        }
        guard connectedClients.contains(where: { $0.id == targetClientId }) else {
            Log.info("[AgentInput] Target Atem offline — key dropped: \(targetClientId)")
            return
        }
        let message = AstationMessage.agentInput(agentId: agentId, kind: "key", text: nil, key: key)
        sendHandler?(message, targetClientId)
        Log.info("[AgentInput] key → \(targetClientId): \(key)")
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
                let displayId = parts.count >= 4 ? Int64(parts[3]) ?? 0 : 0
                Task { @MainActor in
                    await rtcManager.startScreenShare(displayId: displayId)
                }
                return "RTC: starting screen share (displayId=\(displayId))"
            case "off":
                Task { @MainActor in rtcManager.stopScreenShare() }
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
        // Open a WebSocket to the relay and bridge messages
        guard let url = StationRelayURL.webSocketURL(base: stationRelayUrl, code: code) else {
            Log.info("[AstationHub] Invalid relay URL: \(stationRelayUrl)")
            return
        }
        Log.info("[AstationHub] Connecting to relay: \(url.absoluteString)")

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
                    NetworkDebugLogger.logWebSocket(direction: "send", context: "relay \(relayClientId)", message: jsonString)
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
                    NetworkDebugLogger.logWebSocket(direction: "recv", context: "relay \(clientId)", message: text)
                    if let data = text.data(using: .utf8),
                       let msg = try? JSONDecoder().decode(AstationMessage.self, from: data) {
                        DispatchQueue.main.async {
                            let response = self?.handleMessage(msg, from: clientId)
                            // If there's a response, send it back via relay
                            if let response = response,
                               let jsonData = try? JSONEncoder().encode(response),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                NetworkDebugLogger.logWebSocket(direction: "send", context: "relay \(clientId)", message: jsonString)
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

    // MARK: - Identity Relay (persistent background relay for TUI auto-reconnect)

    /// Connect to the relay using this Astation's own identity as the room code.
    /// Atem stores the identity after first pairing and uses it for TUI auto-connect.
    func startIdentityRelay() {
        guard !identityRelayActive else { return }

        // Start NWPathMonitor once — fires when network comes back, enabling
        // immediate reconnect without polling. No battery overhead while offline.
        startIdentityRelayMonitorIfNeeded()
        relayIdentityKeyManager.loadIfNeeded()
        guard !identityRelayActive,
              !relayIdentityKeyRepairPending || relayIdentityRepairReconnectRequested else { return }
        if case .failed = relayIdentityKeyManager.state { return }
        identityRelayActive = true
        identityRelayReconnectGeneration &+= 1

        let identityCode = AstationIdentity.shared.id
        guard let url = StationRelayURL.webSocketURL(base: stationRelayUrl, code: identityCode) else {
            Log.error("[AstationHub] Invalid identity relay URL: \(stationRelayUrl)")
            identityRelayActive = false
            return
        }

        let task = makeIdentityRelayTask(url)
        task.resume()
        identityRelayTask = task
        identityRelayVerified = false
        pendingRelayChallenge = nil
        startSessionExpiryTimerIfNeeded()
        installIdentityRelaySendHandlerIfNeeded()

        Log.info("[AstationHub] Identity relay connecting: \(url.absoluteString)")
        readIdentityRelayMessages(task: task)
    }

    private func installIdentityRelaySendHandlerIfNeeded() {
        guard !identityRelaySendHandlerInstalled else { return }
        identityRelaySendHandlerInstalled = true
        let localSend = sendHandler
        sendHandler = { [weak self] message, targetId in
            if targetId.hasPrefix("relay-") {
                let sendToRelay = { [weak self] in
                    let atemId = String(targetId.dropFirst(6)) // strip "relay-" prefix
                    guard let self,
                          let task = self.identityRelayTask,
                          let connectionId = self.identityRelayAuthentication.connectionId(for: targetId) else {
                        Log.warn("[AstationHub] Cannot route to relay client without an active connection")
                        return
                    }
                    guard self.identityRelayAuthentication.isAuthenticated(
                        clientId: targetId,
                        connectionId: connectionId
                    ) || Self.isRelayAuthenticationControl(message) else {
                        Log.warn("[AstationHub] Dropped application message for unauthenticated relay client")
                        return
                    }
                    guard let payloadData = try? JSONEncoder().encode(message),
                          let payloadObj = try? JSONSerialization.jsonObject(with: payloadData),
                          let envelope = try? JSONSerialization.data(withJSONObject: [
                            "atem_id": atemId,
                            "connection_id": connectionId,
                            "payload": payloadObj
                          ]),
                          let envelopeStr = String(data: envelope, encoding: .utf8) else { return }
                    NetworkDebugLogger.logWebSocket(direction: "send", context: "identity-relay:\(atemId)", message: envelopeStr)
                    task.send(.string(envelopeStr)) { _ in }
                }
                if Thread.isMainThread {
                    sendToRelay()
                } else {
                    DispatchQueue.main.async(execute: sendToRelay)
                }
            } else {
                localSend?(message, targetId)
            }
        }
    }

    /// Start the network path monitor if not already running.
    /// The monitor fires `startIdentityRelay()` immediately when the network
    /// becomes available — no polling, no battery drain while offline.
    private func startIdentityRelayMonitorIfNeeded() {
        guard identityRelayPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        identityRelayPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                DispatchQueue.main.async {
                    if !self.identityRelayActive {
                        Log.info("[AstationHub] Network available — retrying identity relay immediately")
                        self.startIdentityRelay()
                    }
                }
            }
        }
        // Use a background queue so the monitor doesn't block the main thread
        monitor.start(queue: DispatchQueue.global(qos: .background))
    }

    private func readIdentityRelayMessages(task: IdentityRelaySocket) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    NetworkDebugLogger.logWebSocket(direction: "recv", context: "identity-relay", message: text)
                    if let frame = RelayIdentityProtocol.parseControlFrame(text) {
                        // Raw relay control frame (relay-auth-1), not an Atem envelope.
                        DispatchQueue.main.async {
                            self?.handleRelayControlFrame(frame, task: task)
                        }
                    } else if let data = text.data(using: .utf8),
                       let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let atemId = envelope["atem_id"] as? String,
                       DeviceAuthentication.isValidAtemId(atemId),
                       let connectionId = envelope["connection_id"] as? String,
                       DeviceAuthentication.isValidRelayConnectionId(connectionId) {
                        // The relay binds each envelope to its current Atem WebSocket generation.
                        let relayClientId = "relay-\(atemId)"
                        if let event = envelope["relay_event"] as? String {
                            DispatchQueue.main.async {
                                guard let self, self.identityRelayTask === task else {
                                    Log.debug("[AstationHub] Ignored event from a replaced identity relay socket")
                                    return
                                }
                                self.handleIdentityRelayConnectionEvent(
                                    event,
                                    clientId: relayClientId,
                                    connectionId: connectionId
                                )
                            }
                        } else if let payloadObj = envelope["payload"],
                                  let payloadData = try? JSONSerialization.data(withJSONObject: payloadObj),
                                  let msg = try? JSONDecoder().decode(AstationMessage.self, from: payloadData) {
                            DispatchQueue.main.async {
                                guard let self, self.identityRelayTask === task else {
                                    Log.debug("[AstationHub] Ignored message from a replaced identity relay socket")
                                    return
                                }
                                self.handleIdentityRelayMessage(
                                    msg,
                                    clientId: relayClientId,
                                    connectionId: connectionId
                                )
                            }
                        }
                    }
                default:
                    break
                }
                self?.readIdentityRelayMessages(task: task)

            case .failure(let error):
                let closeCode = Self.usableRelayCloseCode(task.closeCode)
                let closeReason = task.closeReason
                    .flatMap { String(data: $0, encoding: .utf8) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                DispatchQueue.main.async {
                    self?.handleIdentityRelayDisconnect(
                        task: task,
                        error: error,
                        closeCode: closeCode,
                        closeReason: closeReason
                    )
                }
            }
        }
    }

    private func handleIdentityRelayDisconnect(
        task: IdentityRelaySocket,
        error: Error?,
        closeCode: Int?,
        closeReason: String?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard identityRelayTask === task else {
            Log.debug("[AstationHub] Ignored disconnect from a replaced identity relay socket")
            return
        }

        let closeDescription = closeCode.map(String.init) ?? "none"
        let reasonDescription = closeReason.map { " reason=\($0)" } ?? ""
        let errorDescription = error.map { " error=\($0)" } ?? ""
        Log.info(
            "[AstationHub] Identity relay disconnected: " +
                "code=\(closeDescription)\(reasonDescription)\(errorDescription)"
        )

        connectedClients
            .filter { $0.id.hasPrefix("relay-") }
            .forEach { removeClient(withId: $0.id) }
        identityRelayAuthentication.removeAll()
        let wasVerified = identityRelayVerified
        identityRelayTask = nil
        identityRelayVerified = false
        pendingRelayChallenge = nil
        identityRelayActive = false

        // CFNetwork commonly reports peer close frames as 1005/invalid. An
        // established, verified socket gets the prompt restart path; a socket
        // that failed before verification gets the try-again backoff path.
        let delay = identityRelayReconnectPolicy.delay(
            observedCloseCode: closeCode,
            wasVerified: wasVerified,
            unitJitter: Double.random(in: 0...1)
        )
        identityRelayReconnectGeneration &+= 1
        let generation = identityRelayReconnectGeneration
        Log.info(
            "[AstationHub] Identity relay retry scheduled in \(String(format: "%.1f", delay))s " +
                "after close code \(closeDescription) (wasVerified=\(wasVerified))"
        )

        // NWPathMonitor starts immediately when connectivity returns. This timer
        // covers relay failures that happen while the network path stays online.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self,
                  self.identityRelayReconnectGeneration == generation,
                  !self.identityRelayActive else { return }
            guard self.identityRelayPathMonitor?.currentPath.status == .satisfied else { return }
            Log.info("[AstationHub] Retrying identity relay")
            self.startIdentityRelay()
        }
    }

    private static func usableRelayCloseCode(
        _ closeCode: URLSessionWebSocketTask.CloseCode
    ) -> Int? {
        switch closeCode {
        case .invalid, .noStatusReceived:
            return nil
        default:
            return Int(closeCode.rawValue)
        }
    }

    // MARK: - Relay identity (proof-of-possession + durable pairing bindings)

    private func handleRelayControlFrame(_ frame: RelayControlFrame, task: IdentityRelaySocket) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard task === identityRelayTask else {
            Log.debug("[RelayIdentity] Ignored control frame from a replaced identity relay socket")
            return
        }
        switch frame {
        case .authChallenge(let challenge):
            answerRelayAuthChallenge(challenge, task: task)
        case .authResult(let status, let message):
            handleRelayAuthResult(status: status, message: message)
        case .ack(let forType, let ok, let message):
            if ok {
                Log.debug("[RelayIdentity] Relay acknowledged \(forType)")
                if forType.hasPrefix("relayMerge") ||
                    forType == "relayLeaveGroup" ||
                    forType == "relayRemoveAstation" ||
                    forType == "relayRegisterAccount" {
                    relayAccountStatusMessage = "Account change accepted by the relay."
                    NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
                } else if forType == "relayEncryptionSet" {
                    encryptionMigrationRetryDelay = 1
                    relayEncryptionStatusMessage = "Encryption change accepted; waiting for migration status."
                    NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
                }
            } else {
                Log.warn("[RelayIdentity] Relay refused \(forType): \(message ?? "no message")")
                if forType.hasPrefix("relayMerge") ||
                    forType == "relayLeaveGroup" ||
                    forType == "relayRemoveAstation" ||
                    forType == "relayRegisterAccount" ||
                    forType == "relayAccountList" {
                    relayAccountStatusMessage = message ?? "The relay refused the account change."
                    NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
                } else if forType == "relayEncryptionSet" || forType == "relayEncryptionGet" {
                    relayEncryptionStatusMessage = message ?? "The relay refused the encryption change."
                    NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
                    if forType == "relayEncryptionSet",
                       message?.contains("migration is incomplete") == true {
                        scheduleEncryptionMigrationRetry()
                    }
                }
            }
        case .accountState(let devices, let requests):
            relayAccountDevices = devices
            relayMergeRequests = requests
            relayAccountStatusMessage = nil
            NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
            requestRelayEncryptionState()
        case .mergeApproval(let approval):
            showMergeApproval(approval)
        case .accountChanged(let reason, _):
            relayAccountStatusMessage = Self.accountChangeMessage(reason)
            NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
            requestRelayAccountState()
            requestRelayEncryptionState()
        case .encryptionState(let state):
            let previousState = relayEncryptionState
            relayEncryptionState = state
            relayEncryptionStatusMessage = nil
            do {
                if state.mode == "off" {
                    try DataEncryptionKeyManager.shared.delete(dataAccount: state.dataAccount)
                } else if let kid = state.kid {
                    try DataEncryptionKeyManager.shared.makeAvailable(
                        dataAccount: state.dataAccount,
                        kid: kid,
                        preferredDataAccount: previousState?.dataAccount
                    )
                    if state.mode == "on" {
                        try DataEncryptionKeyManager.shared.retainOnly(
                            kid: kid,
                            dataAccount: state.dataAccount
                        )
                    }
                }
            } catch {
                relayEncryptionStatusMessage = error.localizedDescription
            }
            broadcastEncryptionMode(state)
            NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
        case .encryptionChanged:
            requestRelayEncryptionState()
        }
    }

    var relayIdentityKeyIsBusy: Bool { relayIdentityKeyManager.isBusy }
    var relayIdentityMenuMessage: String? {
        guard relayIdentityStatusMessage != nil else { return nil }
        if case .failed(let failure) = relayIdentityKeyManager.state { return failure.menuDescription }
        if relayIdentityKeyIsBusy { return "Loading this Mac's relay device key" }
        if relayIdentityKeyRepairPending { return "Complete relay device key recovery in Security settings" }
        return "Relay device key verification needs attention in Security settings"
    }
    var relayIdentityKeyCanRepair: Bool { relayIdentityKeyManager.canRepair }
    var relayIdentityKeyCanResetRelayTrust: Bool {
        guard relayIdentityKeyRejected, !relayIdentityKeyRepairPending, !identityRelayVerified else { return false }
        if case .loaded = relayIdentityKeyManager.state { return true }
        return false
    }
    var relayIdentityKeyCanReconnectAfterRepair: Bool {
        guard relayIdentityKeyRepairPending else { return false }
        if case .loaded = relayIdentityKeyManager.state { return true }
        return false
    }

    func retryRelayIdentityKey() {
        guard !relayIdentityKeyIsBusy else { return }
        pauseIdentityRelay()
        relayIdentityKeyManager.retry()
    }

    func repairRelayIdentityKey(completion: @escaping (RelayIdentityKeyError?) -> Void) {
        guard relayIdentityKeyCanRepair else { completion(.repairNotNeeded); return }
        let record: RelayIdentityKeyRepairRecord
        switch beginRelayIdentityKeyRecoveryPause() {
        case .success(let saved): record = saved
        case .failure(let failure): completion(failure); return
        }
        relayIdentityKeyManager.repair { [weak self] failure in
            if let self, failure != nil {
                record.clear(from: self.relayIdentityRepairDefaults)
                self.relayIdentityKeyRepairRecord = nil
                self.relayIdentityKeyRepairPending = false
                NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            }
            completion(failure)
        }
    }

    func prepareRelayIdentityTrustReset() -> RelayIdentityKeyError? {
        guard relayIdentityKeyCanResetRelayTrust else { return .repairNotNeeded }
        switch beginRelayIdentityKeyRecoveryPause() {
        case .failure(let failure): return failure
        case .success:
            relayIdentityStatusMessage = "Relay trust recovery is paused. Complete the relay reset in Settings > Security, then reconnect."
            NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            return nil
        }
    }

    private func beginRelayIdentityKeyRecoveryPause() -> Result<RelayIdentityKeyRepairRecord, RelayIdentityKeyError> {
        let record = RelayIdentityKeyRepairRecord(
            astationId: AstationIdentity.shared.id, relayURL: stationRelayUrl
        )
        // Persist the pause before updating the key, including across app crashes.
        guard record.save(to: relayIdentityRepairDefaults) else {
            relayIdentityStatusMessage = RelayIdentityKeyError.repairStateUnavailable.localizedDescription
            NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            return .failure(.repairStateUnavailable)
        }
        relayIdentityKeyRepairRecord = record
        relayIdentityKeyRepairPending = true
        relayIdentityRepairReconnectRequested = false
        pauseIdentityRelay()
        return .success(record)
    }

    func reconnectAfterRelayIdentityKeyRepair() {
        guard relayIdentityKeyCanReconnectAfterRepair,
              RelayIdentityKeyRepairRecord.load(
                astationId: AstationIdentity.shared.id, relayURL: stationRelayUrl,
                defaults: relayIdentityRepairDefaults
              ) == relayIdentityKeyRepairRecord else { return }
        relayIdentityRepairReconnectRequested = true
        relayIdentityStatusMessage = "Verifying this Mac's device key after the relay reset..."
        startIdentityRelay()
        NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
    }

    private func pauseIdentityRelay() {
        let task = identityRelayTask
        identityRelayTask = nil
        identityRelayVerified = false
        identityRelayActive = false
        pendingRelayChallenge = nil
        identityRelayReconnectGeneration &+= 1
        connectedClients.filter { $0.id.hasPrefix("relay-") }.forEach { removeClient(withId: $0.id) }
        identityRelayAuthentication.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func finishRelayIdentityKeyLoad(_ state: RelayIdentityKeyLoadState) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch state {
        case .loaded:
            relayIdentityKeyRejected = false
            if relayIdentityKeyRepairPending && !relayIdentityRepairReconnectRequested {
                relayIdentityStatusMessage = "Device key recovery is paused. Complete the relay reset in Settings > Security, then reconnect."
                break
            }
            relayIdentityStatusMessage = nil
            if let pending = pendingRelayChallenge {
                pendingRelayChallenge = nil
                if pending.task === identityRelayTask {
                    answerRelayAuthChallenge(pending.challenge, task: pending.task)
                }
            }
            if !identityRelayActive { startIdentityRelay() }
        case .failed(let failure):
            pauseIdentityRelay()
            relayIdentityStatusMessage = failure.localizedDescription
            Log.error("[RelayIdentity] \(failure.localizedDescription)")
        case .loading:
            relayIdentityKeyRejected = false
            relayIdentityStatusMessage = "Loading this Mac's relay device key..."
        case .notLoaded: break
        }
        NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
    }

    private func answerRelayAuthChallenge(_ challenge: String, task: IdentityRelaySocket) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Keychain access runs off-main; only the cached key answers the challenge.
        let key: RelayIdentityKey
        switch relayIdentityKeyManager.state {
        case .loaded(let loaded):
            key = loaded
        case .loading:
            pendingRelayChallenge = (challenge: challenge, task: task)
            Log.info("[RelayIdentity] Relay challenge received while the key is loading — answering when ready")
            return
        case .notLoaded, .failed:
            Log.warn("[RelayIdentity] No relay identity key available for this connection")
            return
        }
        let astationId = AstationIdentity.shared.id
        let signature: String
        do {
            signature = try key.sign(challenge: challenge, astationId: astationId)
        } catch {
            relayIdentityKeyManager.signingFailed(error)
            return
        }
        guard let text = RelayIdentityProtocol.authMessage(
            astationId: astationId,
            publicKeyHex: key.publicKeyHex,
            signatureHex: signature
        ) else {
            Log.error("[RelayIdentity] Failed to encode relayAuth")
            return
        }
        identityRelayVerified = false
        task.send(.string(text)) { error in
            if let error {
                Log.warn("[RelayIdentity] Failed to send relayAuth: \(error)")
            }
        }
        Log.info("[RelayIdentity] Answered relay identity challenge (secureEnclave=\(key.isHardwareBacked))")
    }

    private func handleRelayAuthResult(status: String, message: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch status {
        case RelayIdentityProtocol.statusRegistered, RelayIdentityProtocol.statusVerified:
            relayIdentityKeyRejected = false
            identityRelayVerified = true
            identityRelayReconnectPolicy.reset()
            relayIdentityStatusMessage = nil
            if relayIdentityKeyRepairPending {
                relayIdentityKeyRepairRecord?.clear(from: relayIdentityRepairDefaults)
                relayIdentityKeyRepairRecord = nil
                relayIdentityKeyRepairPending = false
                relayIdentityRepairReconnectRequested = false
            }
            NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            Log.info("[RelayIdentity] Relay \(status) this Astation's key")
            sendRelaySessionsResync()
            requestRelayAccountState()
            requestRelayEncryptionState()
            registerRelayAccountIfPossible()
        case RelayIdentityProtocol.statusRejected:
            relayIdentityKeyRejected = true
            identityRelayVerified = false
            relayIdentityStatusMessage = RelayIdentityProtocol.rejectedMenuMessage
            if relayIdentityKeyRepairPending {
                relayIdentityRepairReconnectRequested = false
                pauseIdentityRelay()
            }
            NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            Log.error("[RelayIdentity] Relay rejected this Astation's key: \(message ?? "no message")")
        default:
            Log.warn("[RelayIdentity] Ignored unknown relayAuthResult status: \(status)")
        }
    }

    /// Full resync: the relay sets this Astation's bindings to exactly these sessions.
    private func sendRelaySessionsResync() {
        let sessionIds = deviceSessionStore.getAllActive().map { $0.id }
        guard let text = RelayIdentityProtocol.sessionsMessage(sessionIds: sessionIds) else { return }
        sendRelayIdentityControl(text, label: "relaySessions(\(sessionIds.count))")
    }

    func requestRelayAccountState() {
        guard let text = RelayIdentityProtocol.accountListMessage() else { return }
        sendRelayIdentityControl(text, label: "relayAccountList")
    }

    func requestRelayEncryptionState() {
        guard let text = RelayIdentityProtocol.encryptionStateMessage() else { return }
        sendRelayIdentityControl(text, label: "relayEncryptionGet")
    }

    func setRelayEncryption(mode: String, kid: String?) {
        guard let text = RelayIdentityProtocol.encryptionSetMessage(mode: mode, kid: kid) else { return }
        relayEncryptionStatusMessage = "Updating encryption…"
        NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
        sendRelayIdentityControl(text, label: "relayEncryptionSet")
    }

    private func scheduleEncryptionMigrationRetry() {
        let delay = encryptionMigrationRetryDelay
        encryptionMigrationRetryDelay = min(delay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.identityRelayVerified else { return }
            self.requestRelayEncryptionState()
        }
    }

    func prepareEncryptionKeyForCurrentAccount(reuseExisting: Bool) throws -> (AccountDataKey, String) {
        let account = relayEncryptionState?.dataAccount ?? currentDataAccount
        let value = if reuseExisting,
                       let existing = try DataEncryptionKeyManager.shared.load(dataAccount: account) {
            existing
        } else {
            try DataEncryptionKeyManager.shared.generate()
        }
        return (value, try DataEncryptionKeyManager.shared.recoveryKey(for: value))
    }

    func installEncryptionKey(_ value: AccountDataKey) throws {
        try DataEncryptionKeyManager.shared.install(
            value,
            dataAccount: relayEncryptionState?.dataAccount ?? currentDataAccount
        )
    }

    func encryptionRecoveryKey() throws -> String {
        let account = relayEncryptionState?.dataAccount ?? currentDataAccount
        guard let value = try DataEncryptionKeyManager.shared.load(
            dataAccount: account,
            kid: relayEncryptionState?.kid
        ) else {
            throw DataEncryptionKeyError.invalidKey
        }
        return try DataEncryptionKeyManager.shared.recoveryKey(for: value)
    }

    func restoreEncryptionKey(_ text: String) throws {
        let account = relayEncryptionState?.dataAccount ?? currentDataAccount
        let value = try DataEncryptionKeyManager.decodeRecoveryKey(text)
        if let state = relayEncryptionState, state.kid != nil, state.kid != value.kid {
            throw DataEncryptionKeyError.invalidRecoveryKey
        }
        try DataEncryptionKeyManager.shared.install(value, dataAccount: account)
        if let state = relayEncryptionState, state.mode == "off" {
            setRelayEncryption(mode: "enabling", kid: value.kid)
        } else if let state = relayEncryptionState {
            broadcastEncryptionMode(state)
        }
    }

    func discardEncryptionKeyForCurrentAccount() throws {
        try DataEncryptionKeyManager.shared.delete(
            dataAccount: relayEncryptionState?.dataAccount ?? currentDataAccount
        )
    }

    private var currentDataAccount: String {
        relayAccountDevices
            .first(where: { $0.astationId == AstationIdentity.shared.id })?
            .dataAccount ?? AstationIdentity.shared.id
    }

    private func broadcastEncryptionMode(_ state: RelayEncryptionState) {
        let message = AstationMessage.encryptionMode(
            mode: state.mode,
            kid: state.kid,
            dataAccount: state.dataAccount,
            astationId: AstationIdentity.shared.id
        )
        broadcastHandler?(message)
        broadcastToAuthenticatedIdentityRelayClients(message)
    }

    private func sendEncryptionMode(to clientId: String, relayConnectionId: String?) {
        guard let state = relayEncryptionState else { return }
        sendMessage(
            .encryptionMode(
                mode: state.mode,
                kid: state.kid,
                dataAccount: state.dataAccount,
                astationId: AstationIdentity.shared.id
            ),
            to: clientId,
            expectedRelayConnectionId: relayConnectionId
        )
    }

    private func handleEncryptionKeyRequest(
        publicKey: String,
        clientId: String,
        relayConnectionId: String?
    ) {
        guard let state = relayEncryptionState,
              state.mode != "off",
              let kid = state.kid,
              let fingerprint = DataEncryptionKeyManager.fingerprint(publicKeyBase64: publicKey) else {
            sendMessage(.error(message: "Encryption key request is invalid"),
                        to: clientId, expectedRelayConnectionId: relayConnectionId)
            return
        }
        var trusted = UserDefaults.standard.dictionary(forKey: "AstationEncryptionFingerprints") as? [String: String] ?? [:]
        if trusted[clientId] != fingerprint {
            let alert = NSAlert()
            alert.messageText = trusted[clientId] == nil
                ? "Verify Atem Encryption Key"
                : "Atem Encryption Key Changed"
            alert.informativeText = "Compare this fingerprint with the one printed by atem pair:\n\n\(fingerprint)\n\nDevice: \(clientId)"
            alert.alertStyle = trusted[clientId] == nil ? .informational : .warning
            alert.addButton(withTitle: "Fingerprint Matches")
            alert.addButton(withTitle: "Deny")
            guard alert.runModal() == .alertFirstButtonReturn else {
                sendMessage(.error(message: "Encryption fingerprint was not approved"),
                            to: clientId, expectedRelayConnectionId: relayConnectionId)
                return
            }
            trusted[clientId] = fingerprint
            UserDefaults.standard.set(trusted, forKey: "AstationEncryptionFingerprints")
        }
        do {
            guard let value = try DataEncryptionKeyManager.shared.load(
                dataAccount: state.dataAccount,
                kid: kid
            ) else {
                throw DataEncryptionKeyError.invalidKey
            }
            let grant = try DataEncryptionKeyManager.shared.wrap(
                value,
                to: publicKey,
                dataAccount: state.dataAccount
            )
            sendMessage(
                .keyGrant(kid: grant.kid, wrappedKey: grant.wrappedKey, dataAccount: state.dataAccount),
                to: clientId,
                expectedRelayConnectionId: relayConnectionId
            )
        } catch {
            relayEncryptionStatusMessage = error.localizedDescription
            NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
            sendMessage(.error(message: "Astation cannot access the account encryption key"),
                        to: clientId, expectedRelayConnectionId: relayConnectionId)
        }
    }

    private func handleEncryptionMigrationComplete(mode: String, kid: String) {
        guard let state = relayEncryptionState, state.kid == kid else { return }
        if state.mode == "enabling", mode == "on" {
            setRelayEncryption(mode: "on", kid: kid)
        } else if state.mode == "disabling", mode == "off" {
            setRelayEncryption(mode: "off", kid: kid)
        }
    }

    func requestRelayMerge(targetAstationId: String, freshAccessToken: String? = nil) {
        guard let text = RelayIdentityProtocol.mergeRequestMessage(
            targetAstationId: targetAstationId,
            freshAccessToken: freshAccessToken
        ) else { return }
        relayAccountStatusMessage = "Requesting merge…"
        NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
        sendRelayIdentityControl(text, label: "relayMergeRequest")
    }

    func cancelRelayMerge(requestId: String) {
        guard let text = RelayIdentityProtocol.mergeCancelMessage(requestId: requestId) else { return }
        sendRelayIdentityControl(text, label: "relayMergeCancel")
    }

    func leaveRelayAccountGroup() {
        guard let text = RelayIdentityProtocol.leaveGroupMessage() else { return }
        sendRelayIdentityControl(text, label: "relayLeaveGroup")
    }

    func removeRelayAstation(astationId: String) {
        guard let text = RelayIdentityProtocol.removeAstationMessage(astationId: astationId) else { return }
        sendRelayIdentityControl(text, label: "relayRemoveAstation")
    }

    private func registerRelayAccountIfPossible() {
        guard identityRelayVerified else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await tokenProvider.validToken()
                guard let session = sessionStore.load() else { return }
                let rawLabel = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                let label = DeviceAuthentication.deviceLabel(rawLabel)
                guard let text = RelayIdentityProtocol.registerAccountMessage(
                    accessToken: session.accessToken,
                    label: label
                ) else { return }
                await MainActor.run {
                    self.sendRelayIdentityControl(text, label: "relayRegisterAccount")
                }
            } catch {
                Log.debug("[RelayAccount] Registration deferred: \(error.localizedDescription)")
            }
        }
    }

    private func showMergeApproval(_ approval: RelayMergeApproval) {
        dispatchPrecondition(condition: .onQueue(.main))
        let alert = NSAlert()
        alert.messageText = "Merge Astation data?"
        alert.informativeText = "\(approval.requesterLabel) wants to merge its memories, skills and vaults with this Mac. Both Astations will then use one shared data account."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Approve Merge")
        alert.addButton(withTitle: "Cancel Request")
        let approved = alert.runModal() == .alertFirstButtonReturn
        let text = approved
            ? RelayIdentityProtocol.mergeApprovalMessage(requestId: approval.requestId)
            : RelayIdentityProtocol.mergeCancelMessage(requestId: approval.requestId)
        if let text {
            sendRelayIdentityControl(text, label: approved ? "relayMergeApprove" : "relayMergeCancel")
        }
    }

    private static func accountChangeMessage(_ reason: String) -> String {
        switch reason {
        case "merge_completed": return "Astation data accounts were merged."
        case "merge_cancelled": return "The pending merge was cancelled."
        case "delayed_merge_pending": return "A delayed merge is pending for 24 hours."
        default: return "The account changed on another Astation."
        }
    }

    /// Bind a granted pairing session on the relay (any grant path: relay, LAN, loopback).
    /// While unverified this is a no-op; the next verification's resync includes it.
    func sendRelayBind(sessionId: String) {
        guard let text = RelayIdentityProtocol.bindMessage(sessionId: sessionId) else { return }
        sendRelayIdentityControl(text, label: "relayBind")
    }

    /// Revoke relay bindings for deleted or expired pairing sessions.
    func sendRelayUnbind(sessionIds: [String]) {
        for sessionId in sessionIds {
            guard let text = RelayIdentityProtocol.unbindMessage(sessionId: sessionId) else { continue }
            sendRelayIdentityControl(text, label: "relayUnbind")
        }
    }

    /// Send an intercepted control message on the verified identity socket.
    /// Payloads carry session IDs, so they are never written to the debug log.
    private func sendRelayIdentityControl(_ text: String, label: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard identityRelayVerified, let task = identityRelayTask else {
            Log.debug("[RelayIdentity] Relay identity not verified — \(label) deferred to next resync")
            return
        }
        task.send(.string(text)) { error in
            if let error {
                Log.warn("[RelayIdentity] Failed to send \(label): \(error)")
            }
        }
    }

    private func startSessionExpiryTimerIfNeeded() {
        guard sessionExpiryTimer == nil else { return }
        sessionExpiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.deviceSessionStore.cleanupExpired()
        }
    }

    private func handleIdentityRelayConnectionEvent(
        _ event: String,
        clientId: String,
        connectionId: String
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch event {
        case "connected":
            if identityRelayAuthentication.connect(clientId: clientId, connectionId: connectionId) {
                removeClient(withId: clientId)
            }
        case "disconnected":
            if identityRelayAuthentication.disconnect(clientId: clientId, connectionId: connectionId) {
                removeClient(withId: clientId)
            }
        default:
            Log.warn("[AstationHub] Ignored unknown identity relay event: \(event)")
        }
    }

    private func handleIdentityRelayMessage(
        _ msg: AstationMessage,
        clientId: String,
        connectionId: String
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if identityRelayAuthentication.connect(clientId: clientId, connectionId: connectionId) {
            removeClient(withId: clientId)
        }

        if case .statusUpdate(let status, let data) = msg, status == "hello" {
            guard !identityRelayAuthentication.isAuthenticated(
                clientId: clientId,
                connectionId: connectionId
            ) else {
                sendHandler?(.error(message: "Relay client is already authenticated"), clientId)
                Log.warn("[AstationHub] Ignored repeated hello from authenticated relay client \(clientId)")
                return
            }
            let hostname = DeviceAuthentication.deviceLabel(data["hostname"] ?? "unknown")
            let challenge = DeviceAuthentication.makeChallenge()
            guard identityRelayAuthentication.issueChallenge(
                clientId: clientId,
                connectionId: connectionId,
                challenge: challenge
            ) else {
                sendHandler?(.error(message: "Too many pending relay authentication requests"), clientId)
                Log.warn("[AstationHub] Relay authentication challenge limit reached")
                return
            }
            sendHandler?(.statusUpdate(status: "auth_required", data: [
                "astation_id": AstationIdentity.shared.id,
                "challenge": challenge,
                "transport": "relay",
                "protocol": DeviceAuthentication.protocolVersion,
                "hostname": hostname
            ]), clientId)
            Log.info("[AstationHub] Relay authentication required for \(hostname)")
            return
        }

        if !identityRelayAuthentication.isAuthenticated(
            clientId: clientId,
            connectionId: connectionId
        ) {
            handleIdentityRelayAuthentication(
                msg,
                clientId: clientId,
                connectionId: connectionId
            )
            return
        }

        if let response = handleMessage(
            msg,
            from: clientId,
            relayConnectionId: connectionId
        ) {
            sendMessage(response, to: clientId, expectedRelayConnectionId: connectionId)
        }
    }

    func broadcastToAuthenticatedIdentityRelayClients(_ message: AstationMessage) {
        dispatchPrecondition(condition: .onQueue(.main))
        for clientId in identityRelayAuthentication.authenticatedClientIds {
            sendHandler?(message, clientId)
        }
    }

    private func handleIdentityRelayAuthentication(
        _ msg: AstationMessage,
        clientId: String,
        connectionId: String
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .statusUpdate(let status, let data) = msg,
              status == "auth",
              let challenge = identityRelayAuthentication.challenge(
                clientId: clientId,
                connectionId: connectionId
              ) else {
            Log.warn("[AstationHub] Dropped unauthenticated relay message from \(clientId)")
            return
        }

        guard let atemId = data["atem_id"],
              DeviceAuthentication.relayClientMatchesAtemId(clientId: clientId, atemId: atemId) else {
            sendHandler?(.error(message: "Relay identity does not match authentication proof"), clientId)
            Log.warn("[AstationHub] Rejected mismatched relay authentication identity for \(clientId)")
            return
        }

        if let sessionId = data["session_id"],
           let proof = data["proof"],
           DeviceAuthentication.isValidSessionId(sessionId),
           let session = deviceSessionStore.authenticate(
                sessionId: sessionId,
                atemId: atemId,
                challenge: challenge,
                proof: proof,
                astationId: AstationIdentity.shared.id
           ) {
            finishIdentityRelayAuthentication(
                clientId: clientId,
                atemId: atemId,
                connectionId: connectionId,
                hostname: session.hostname,
                response: .statusUpdate(status: "authenticated", data: [
                    "method": "session_proof",
                    "session_id": sessionId,
                    "protocol": DeviceAuthentication.protocolVersion
                ])
            )
            return
        }

        if data["session_id"] != nil {
            sendHandler?(.error(message: "Session proof invalid - pairing required"), clientId)
            return
        }

        guard let pairingCode = data["pairing_code"],
              let rawHostname = data["hostname"],
              DeviceAuthentication.isValidPairingCode(pairingCode) else {
            sendHandler?(.error(message: "Invalid relay authentication credentials"), clientId)
            return
        }

        let hostname = DeviceAuthentication.deviceLabel(rawHostname)
        dispatchPrecondition(condition: .onQueue(.main))
        let alert = NSAlert()
        alert.messageText = "Remote Atem Pairing Request"
        alert.informativeText = "Device: \(hostname)\nCode: \(pairingCode)\n\nAllow this Atem to connect through the relay?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else {
            identityRelayAuthentication.reject(clientId: clientId, connectionId: connectionId)
            sendHandler?(.auth(info: ["status": "denied", "message": "Pairing denied by user"]), clientId)
            return
        }

        guard identityRelayAuthentication.connectionId(for: clientId) == connectionId else {
            Log.warn("[AstationHub] Relay connection changed while pairing approval was pending")
            return
        }
        let session = deviceSessionStore.create(hostname: hostname, atemId: atemId)
        finishIdentityRelayAuthentication(
            clientId: clientId,
            atemId: atemId,
            connectionId: connectionId,
            hostname: hostname,
            response: .auth(info: [
                "status": "granted",
                "session_id": session.id,
                "token": session.token,
                "protocol": DeviceAuthentication.protocolVersion
            ])
        )
    }

    private func finishIdentityRelayAuthentication(
        clientId: String,
        atemId: String,
        connectionId: String,
        hostname: String,
        response: AstationMessage
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard identityRelayAuthentication.authenticate(
            clientId: clientId,
            atemId: atemId,
            connectionId: connectionId
        ) else {
            sendHandler?(.error(message: "Relay identity does not match authentication proof"), clientId)
            Log.warn("[AstationHub] Refused stale or mismatched relay authentication for \(clientId)")
            return
        }
        sendHandler?(response, clientId)
        addClient(
            ConnectedClient(
                id: clientId,
                clientType: "Atem",
                connectedAt: Date(),
                hostname: "relay:\(hostname)",
                atemId: atemId
            ),
            relayConnectionId: connectionId
        )
        Log.info("[AstationHub] Authenticated relay Atem: \(hostname)")
    }

    private func sendMessage(
        _ message: AstationMessage,
        to clientId: String,
        expectedRelayConnectionId: String?
    ) {
        guard clientId.hasPrefix("relay-"), let expectedRelayConnectionId else {
            sendHandler?(message, clientId)
            return
        }

        let sendIfCurrent = { [weak self] in
            guard let self,
                  self.identityRelayAuthentication.connectionId(for: clientId) == expectedRelayConnectionId else {
                Log.warn("[AstationHub] Dropped response for replaced relay connection")
                return
            }
            self.sendHandler?(message, clientId)
        }
        if Thread.isMainThread {
            sendIfCurrent()
        } else {
            DispatchQueue.main.async(execute: sendIfCurrent)
        }
    }

    private static func isRelayAuthenticationControl(_ message: AstationMessage) -> Bool {
        switch message {
        case .statusUpdate(let status, _):
            return status == "auth_required" ||
                status == "authenticated" ||
                status == "auth" ||
                status == "error"
        default:
            return false
        }
    }
}

// MARK: - Data Models

struct ConnectedClient: Identifiable {
    let id: String
    let clientType: String
    let connectedAt: Date
    var hostname: String = "unknown"
    var atemId: String?
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
    static let voiceCodingResponseReceived = Notification.Name("VoiceCodingResponseReceived")
    static let rtcJoinSuccess = Notification.Name("RtcJoinSuccess")
}
