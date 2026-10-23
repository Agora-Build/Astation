import CStationCore
import AppKit
import Foundation
import Network
import AtemClient
import AstationRemote
import CryptoKit

// Hub Manager - Contains all business logic for Agora projects, tokens, etc.
class AstationHubManager: ObservableObject {
    @Published var connectedClients: [ConnectedClient] = [] {
        didSet {
            refreshDirectMigrationContexts()
            refreshSessionConnections()
            terminalConnectionsDidChange?()
        }
    }
    @Published var projects: [AgoraProject] = []
    @Published var selectedProject: AgoraProject?
    @Published var isClaudeRunning = false
    @Published var startTime = Date()
    @Published var voiceActive = false
    @Published var videoActive = false
    @Published var markTasks: [MarkTask] = []

    /// Agents reported by each Atem, keyed by clientId.
    @Published var agentsByClientId: [String: [AtemAgentInfo]] = [:]
    @Published private(set) var sessionStatusByClientId: [String: AtemSessionClient.ConnectionStatus] = [:]
    @Published private(set) var credentialProjectSuggestions: [String] = []
    private var credentialProjectReports: [String: AtemReportedProjects] = [:]
    /// User-pinned active client ID. Overrides focus-based routing when set.
    @Published var pinnedClientId: String?
    @Published private(set) var remoteInputStatusMessage: String?

    private var hubStartTime = Date()
    let sessionStore: SsoSessionStore
    let tokenProvider: SsoTokenProvider
    private(set) var accountAuth: AstationAccountAuth
    private let accountDefaults: UserDefaults
    private(set) var portalSettings: AccountServiceSettings?
    private(set) var portalAuth: AstationAccountAuth?
    let portalAPI: PortalAPIClient
    @Published private(set) var signedInAccount: String?
    @Published private(set) var accountSignInRequired = true
    @Published private(set) var accountSignInInProgress = false
    @Published private(set) var agoraConnection: PortalAgoraConnection?
    private var projectLoadTask: Task<Void, Never>?
    private var accountGeneration = UUID()
    private var portalProjects: [String: PortalAPIClient.Project] = [:]
    private var projectCache: PortalProjectCache?
    @Published private(set) var projectCacheUpdatedAt: Date?
    @Published private(set) var usingSavedProjects = false

    private static func makePortalAuth(settings: AccountServiceSettings?) -> AstationAccountAuth? {
        guard let settings, let config = try? settings.oidcConfiguration else { return nil }
        // Include the destination as well as the issuer/audience in credential storage isolation.
        return AstationAccountAuth(configuration: config,
            storage: AccountKeychainStorage(service: "build.agora.astation.portal-account-v1." + settings.storageContext))
    }
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
    private var identityRelaySocketGeneration = UUID().uuidString
    private let makeIdentityRelayTask: (URL) -> IdentityRelaySocket
    private let makePairingRelayTask: (URL) -> IdentityRelaySocket
    private let workspaceNotifications: NotificationCenter
    private var systemIsSleeping = false
    private var resumeRelayAfterSleep = false
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
    @Published private(set) var relayAccountDevices: [RelayAccountDevice] = [] {
        didSet { refreshDirectMigrationContexts() }
    }
    @Published private(set) var relayMergeRequests: [RelayMergeRequest] = []
    @Published private(set) var relayAccountStatusMessage: String?
    @Published private(set) var relayEncryptionState: RelayEncryptionState? {
        didSet { refreshDirectMigrationContexts() }
    }
    @Published var relayEncryptionStatusMessage: String?
    private var encryptionMigrationRetryDelay: TimeInterval = 1
    private var encryptionMigrationRetryScheduled = false
    private let loadMigrationKey: (String, String?) throws -> AccountDataKey?
    private let dispatchMigration: (@escaping () -> Void) -> Void
    private struct MigrationContext {
        let account: String
        let route: AtemVerificationRoute
    }
    private let migrationContextLock = NSLock()
    private var directMigrationContexts: [String: MigrationContext] = [:]
    private var directSessionContexts: [String: AtemSessionContext] = [:]
    let atemE2EIdentity: AtemE2EIdentity
    @MainActor private var accountRecovery: AstationRecoveryCoordinator?
    @MainActor private var approvalPushHints: RemotePushHints?
    @MainActor private var approvalPushScope: String?

    @MainActor func verifyApprovalPush(_ userInfo: [AnyHashable: Any], tapped: Bool) -> ApprovalPushHint? {
        do {
            guard let json = userInfo["r9_hint"] as? String, json.utf8.count <= 16_384 else { return nil }
            let parsed = try signedObjectInfo(json: json)
            guard parsed.bodyType == "atem-push-hint",
                  let body = try JSONSerialization.jsonObject(with: Data(parsed.bodyJcs.utf8)) as? [String: Any],
                  body["account_id"] as? String == e2eDataAccount, let host = body["host_id"] as? String else { return nil }
            let log = try recoveryCoordinator().channelMembership(hostID: host)
            let scope = log.accountId() + ":" + log.genesisHash()
            if approvalPushScope != scope {
                approvalPushHints = nil; approvalPushScope = nil
                let store = try RemoteRecoveryStore(pushAccountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: AstationIdentity.shared.id)
                approvalPushHints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(),
                    deviceID: AstationIdentity.shared.id, checkpoint: store.read(), persist: { try store.write($0) })
                approvalPushScope = scope
            }
            guard let hints = approvalPushHints else { return nil }
            let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
            if tapped {
                let target = try hints.target(hintJSON: json, log: log, now: now)
                let hint = try verifyPushHint(hintJson: json, log: log, nowMs: now, verifier: .client)
                if case .resolved = hint.state() { return ApprovalPushHint(verified: target, resolved: true) }
                return ApprovalPushHint(verified: target, resolved: false)
            }
            guard let notice = try hints.receive(hintJSON: json, log: log, now: now) else { return nil }
            if case .resolved = notice.state { return ApprovalPushHint(verified: notice.approval, resolved: true) }
            return ApprovalPushHint(verified: notice.approval, resolved: false)
        } catch {
            Log.warn("[Approvals] Sealed notification could not be verified; reconnect for current host state")
            return nil
        }
    }

    @MainActor func recoveryCoordinator(account: String? = nil, relayURL: String? = nil) throws -> AstationRecoveryCoordinator {
        let account = account ?? e2eDataAccount
        let targetRelay = relayURL ?? stationRelayUrl
        if let coordinator = accountRecovery, coordinator.accountID == account, coordinator.relayURL == targetRelay { return coordinator }
        accountRecovery = nil
        let coordinator = try AstationRecoveryCoordinator(accountID: account, managerID: AstationIdentity.shared.id,
            identity: atemE2EIdentity, relayURL: targetRelay,
            accessToken: { [accountAuth] in try await accountAuth.accessToken(relayURL: targetRelay) },
            allowNewDataKey: { [weak self] in self?.e2eDataAccount == account && self?.relayEncryptionState?.mode == "off" })
        accountRecovery = coordinator
        return coordinator
    }
    private lazy var atemVerification = AtemVerificationController(
        identity: atemE2EIdentity,
        account: { [weak self] in self?.e2eDataAccount ?? "" },
        key: { account, kid in try DataEncryptionKeyManager.shared.load(dataAccount: account, kid: kid) },
        isCurrent: { [weak self] route in self?.verificationRoute(clientId: route.clientId, relayConnectionId: self?.identityRelayAuthentication.connectionId(for: route.clientId)) == route },
        send: { [weak self] message, route in
            self?.sendMessage(message, to: route.clientId, expectedRelayConnectionId: route.clientId.hasPrefix("relay-") ? route.connectionId : nil)
            if case .deviceVerified = message {
                self?.remoteVerificationDidComplete(on: route)
            }
        },
        approve: AtemVerificationUI.approve,
        prepareKeys: { [weak self] account, nonce, completion in
            Task { @MainActor in
                do {
                    guard let self, self.e2eDataAccount == account else { throw AtemIdentityError.identityChanged }
                    completion(.success(try await self.recoveryCoordinator(account: account).pairingKeys(nonce: nonce)))
                } catch { completion(.failure(error)) }
            }
        },
        prepareHost: { [weak self] commit, reveal, keys, completion in
            Task { @MainActor in
                do {
                    guard let self, self.e2eDataAccount == commit.context.accountID else { throw AtemIdentityError.identityChanged }
                    let coordinator = try self.recoveryCoordinator(account: commit.context.accountID)
                    let request = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
                    var publishing: Task<Void, Never>?
                    completion(.success(AtemPreparedHostMembership(publish: { confirmedAt, current, reply in
                        publishing = Task { @MainActor in
                            do { reply(.success(try await coordinator.commitHost(request: request, confirmedAt: confirmedAt, current: current))) }
                            catch { reply(.failure(error)) }
                        }
                    }, cancel: {
                        publishing?.cancel()
                        Task { @MainActor in
                            do { try coordinator.cancelUnsignedHost(request: request) }
                            catch { Log.warn("[Recovery] Membership preparation could not be reconciled: \(error.localizedDescription)") }
                        }
                    })))
                } catch { completion(.failure(error)) }
            }
        }
    )
    private lazy var atemStorageKeys = AtemStorageKeyController(
        identity: atemE2EIdentity,
        account: { [weak self] in self?.e2eDataAccount ?? "" },
        isCurrent: { [weak self] route in
            self?.verificationRoute(clientId: route.clientId, relayConnectionId: self?.identityRelayAuthentication.connectionId(for: route.clientId)) == route
        },
        send: { [weak self] message, route in
            self?.sendMessage(message, to: route.clientId, expectedRelayConnectionId: route.clientId.hasPrefix("relay-") ? route.connectionId : nil)
            if case .unlockDenied(_, let revoked) = message, revoked { self?.remoteTrustDidChange() }
        },
        approve: AtemVerificationUI.unlock
    )

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
    var sendDirectChannel: ((Data, String, @escaping (Error?) -> Void) -> Void)?
    var disconnectDirectClient: ((String) -> Void)?
    var terminalMessageHandler: ((RemoteTerminalMessage, RemoteTerminalConnection) -> Void)?
    var sessionMessageHandler: ((AtemSessionMessage, RemoteTerminalConnection) -> Void)?
    var sessionStateDidChange: ((String) -> Void)?
    var approvalSessionDidChange: ((String, AtemSessionClient, String) -> Void)?
    @Published private(set) var approvalPushRegistrationStatus: String?
    private var approvalPushRegistration: ApprovalPushRegistration?
    private var approvalPushUnregistration: ApprovalPushPlatform?
    var terminalConnectionsDidChange: (() -> Void)?
    var remoteAgentInputHandler: ((RemoteTerminalConnection, String?, String, String) -> Bool)?
    var sessionsRemovedHandler: (([String]) -> Void)?
    private var nativeSessionClients: [String: AtemSessionClient] = [:]
    @MainActor private var r9Connections: [String: AstationR9Connection] = [:]
    @MainActor private var r9Signer: AstationChannelSigner?
    private var sessionTimer: Timer?
    private let sessionJournal: AtemSessionJournal
    lazy var browserAgentChat = BrowserAgentChat(
        currentRoute: { [weak self] in self?.browserChatConnection(for: $0) },
        sendAgent: { [weak self] message, route in
            guard let self, self.browserChatConnection(for: route.clientId) == route, self.sendHandler != nil else { return false }
            self.sendMessage(.agentChat(message), to: route.clientId,
                             expectedRelayConnectionId: route.clientId.hasPrefix("relay-") ? route.connectionId : nil)
            return true
        },
        sendBrowser: { [weak self] frame, route in self?.sendBrowserChatFrame(frame, to: route) }
    )

    init(
        skipProjectLoad: Bool = false,
        deviceSessionStore: SessionStore = SessionStore(),
        sessionStore: SsoSessionStore = SsoSessionStore(),
        relayIdentityKeyManager: RelayIdentityKeyManager = RelayIdentityKeyManager(),
        relayIdentityRepairDefaults: UserDefaults = .standard,
        atemE2EIdentity: AtemE2EIdentity? = nil,
        sessionJournal: AtemSessionJournal = .persistent(),
        loadMigrationKey: @escaping (String, String?) throws -> AccountDataKey? = {
            try DataEncryptionKeyManager.shared.load(dataAccount: $0, kid: $1)
        },
        dispatchMigration: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        makeIdentityRelayTask: @escaping (URL) -> IdentityRelaySocket = { URLSession.shared.webSocketTask(with: $0) },
        makePairingRelayTask: @escaping (URL) -> IdentityRelaySocket = { URLSession.shared.webSocketTask(with: $0) },
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        portalSettings: AccountServiceSettings? = try? AccountServiceSettings.load(),
        portalAuth: AstationAccountAuth? = nil,
        portalAPI: PortalAPIClient = PortalAPIClient(),
        projectCache: PortalProjectCache? = nil,
        accountDefaults: UserDefaults = .standard
    ) {
        self.accountDefaults = accountDefaults
        self.accountAuth = AstationAccountAuth(defaults: accountDefaults)
        self.portalSettings = portalSettings
        self.portalAuth = portalAuth ?? Self.makePortalAuth(settings: portalSettings)
        self.portalAPI = portalAPI
        self.projectCache = projectCache ?? portalSettings.map(PortalProjectCache.init(settings:))
        self.deviceSessionStore = deviceSessionStore
        self.sessionStore = sessionStore
        self.makeIdentityRelayTask = makeIdentityRelayTask
        self.makePairingRelayTask = makePairingRelayTask
        self.workspaceNotifications = workspaceNotifications
        self.relayIdentityKeyManager = relayIdentityKeyManager
        self.relayIdentityRepairDefaults = relayIdentityRepairDefaults
        self.atemE2EIdentity = atemE2EIdentity ?? AtemE2EIdentity(storage: AtemIdentityKeychainStorage(astationId: AstationIdentity.shared.id))
        self.sessionJournal = sessionJournal
        self.loadMigrationKey = loadMigrationKey
        self.dispatchMigration = dispatchMigration
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
            self?.sessionsRemovedHandler?(sessionIds)
            self?.terminalConnectionsDidChange?()
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
        workspaceNotifications.addObserver(self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
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
        dispatchMigration { [weak self] in self?.resumeAcceptedEncryptionMigrations() }
    }

    @objc private func handleCredentialsChanged() {
        reloadSession()
    }

    deinit {
        workspaceNotifications.removeObserver(self)
        sessionTimer?.invalidate()
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
    
    // MARK: - Account Session

    func checkSessionStatus() {
        Log.info("[AstationHub] Account login and linked projects use Agora.Build (Settings > Account)")
    }

    func reloadSession() {
        checkSessionStatus()
        refreshProjects()
        broadcastCredentials()
    }

    func accountSessionChanged() {
        accountGeneration = UUID()
        refreshProjects()
        registerRelayAccountIfPossible()
        NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
    }

    @MainActor func signInAccount() async throws {
        guard !accountSignInInProgress else { throw AccountLoginError.busy }
        accountSignInInProgress = true
        defer { accountSignInInProgress = false }
        guard let portalAuth else { throw AccountLoginError.configuration }
        accountGeneration = UUID()
        projectLoadTask?.cancel()
        projects = []; selectedProject = nil; portalProjects = [:]; agoraConnection = nil; signedInAccount = nil
        accountSignInRequired = true
        projectCacheUpdatedAt = nil; usingSavedProjects = false
        try projectCache?.clear()
        let epoch = accountGeneration
        try await portalAuth.signIn()
        let primary = try await portalAuth.current()
        guard epoch == accountGeneration else { throw AccountLoginError.changed }
        signedInAccount = primary?.session.subject
        accountSignInRequired = primary == nil || primary?.refreshPending == true
        defer { if epoch == accountGeneration { accountSessionChanged() } }
        // Relay credentials have a separate resource audience. Never substitute Portal tokens.
        if accountAuth.configuration != nil {
            let relayAuth = accountAuth
            try await relayAuth.signIn()
            let relay = try await relayAuth.current()
            guard epoch == accountGeneration else { throw AccountLoginError.changed }
            guard relay?.session.subject == signedInAccount else {
                try await relayAuth.clearSession()
                throw AccountLoginError.changed
            }
        }
    }

    @MainActor func signOutAccount() async throws {
        accountGeneration = UUID()
        let epoch = accountGeneration
        let oldPortal = portalAuth, oldRelay = accountAuth
        projectLoadTask?.cancel()
        signedInAccount = nil; agoraConnection = nil
        accountSignInRequired = true
        projects = []; selectedProject = nil; portalProjects = [:]
        projectCacheUpdatedAt = nil; usingSavedProjects = false
        try projectCache?.clear()
        try await oldPortal?.clearSession()
        guard epoch == accountGeneration else { throw AccountLoginError.changed }
        try await oldRelay.clearSession()
        guard epoch == accountGeneration else { throw AccountLoginError.changed }
        accountSessionChanged()
    }

    @MainActor func updateAccountServices(_ settings: AccountServiceSettings) async throws {
        guard settings != portalSettings else { return }
        try await signOutAccount()
        accountRecovery = nil
        settings.save(defaults: accountDefaults)
        // Environment overrides remain authoritative; show the effective values in the form.
        portalSettings = try AccountServiceSettings.load(defaults: accountDefaults)
        portalAuth = Self.makePortalAuth(settings: portalSettings)
        projectCache = portalSettings.map(PortalProjectCache.init(settings:))
        accountAuth = AstationAccountAuth(defaults: accountDefaults)
        accountSessionChanged()
    }

    /// Retain already-consented legacy service credentials for existing Atems.
    /// Portal/relay account tokens must never enter this upstream-token message.
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

    /// Only Portal-scoped credentials can reach the linked Agora account APIs.
    private func loadProjects() {
        projectLoadTask?.cancel()
        let epoch = accountGeneration
        let settings = portalSettings
        let auth = portalAuth
        projectLoadTask = Task { @MainActor in
            do {
                guard let settings, let auth else { throw AccountLoginError.configuration }
                let record = try await auth.current()
                guard epoch == accountGeneration, !Task.isCancelled else { return }
                signedInAccount = record?.session.subject
                accountSignInRequired = record == nil || record?.refreshPending == true
                guard record != nil else { throw AccountLoginError.signInRequired }
                if projects.isEmpty, let cached = try projectCache?.load(subject: record!.session.subject) {
                    portalProjects = Dictionary(uniqueKeysWithValues: cached.metadata.map { ($0.appId, $0) })
                    projects = cached.projects
                    selectedProject = projects.first
                    projectCacheUpdatedAt = cached.updatedAt
                    usingSavedProjects = true
                    NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
                }
                let connection = try await portalAPI.connection(settings: settings, auth: auth)
                guard epoch == accountGeneration, !Task.isCancelled else { return }
                agoraConnection = connection
                guard connection.ready else { throw PortalAPIError.unavailable }
                guard connection.connected, connection.reconnect != true else { throw PortalAPIError.connectAgora }
                let fetched = try await portalAPI.projects(settings: settings, auth: auth)
                guard epoch == accountGeneration, !Task.isCancelled else { return }
                let previousMetadata = portalProjects
                let previousProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
                portalProjects = Dictionary(uniqueKeysWithValues: fetched.map { ($0.appId, $0) })
                projects = fetched.map { remote in
                    let old = previousMetadata[remote.appId]?.projectId == remote.projectId ? previousProjects[remote.appId] : nil
                    return AgoraProject(id: remote.appId, name: remote.name, vendorKey: remote.appId,
                        signKey: old?.signKey ?? "", status: remote.status, created: 0)
                }
                selectedProject = projects.first(where: { $0.id == selectedProject?.id }) ?? projects.first
                projectCacheUpdatedAt = Date(); usingSavedProjects = false
                try saveProjectCache()
                projectLoadError = nil
                if let id = selectedProject?.id {
                    do { _ = try await projectWithCertificate(id: id, refresh: true) }
                    catch { if epoch == accountGeneration { projectLoadError = error.localizedDescription } }
                }
                guard epoch == accountGeneration, !Task.isCancelled else { return }
                NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
            } catch {
                guard epoch == accountGeneration, !Task.isCancelled else { return }
                if error as? AccountLoginError == .signInRequired || error as? PortalAPIError == .signInRequired {
                    accountSignInRequired = true
                }
                if error as? PortalAPIError == .connectAgora {
                    agoraConnection = PortalAgoraConnection(ready: true, connect: true, connected: false, name: agoraConnection?.name)
                }
                if !projects.isEmpty, signedInAccount != nil,
                   Self.isProjectNetworkFailure(error) || error as? AccountLoginError == .signInRequired {
                    usingSavedProjects = true
                    projectLoadError = error as? AccountLoginError == .signInRequired
                        ? "Using saved projects. Sign in again to refresh online access."
                        : "Offline. Using saved projects and local token generation."
                } else {
                    projects = []; selectedProject = nil; portalProjects = [:]
                    projectCacheUpdatedAt = nil; usingSavedProjects = false
                    do { try projectCache?.clear() }
                    catch { Log.warn("[AstationHub] Could not clear the linked-project Keychain cache") }
                    projectLoadError = error.localizedDescription
                }
                NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
            }
        }
    }

    private static func isProjectNetworkFailure(_ error: Error) -> Bool {
        if error as? PortalAPIError == .unavailable || error as? AccountLoginError == .unavailable { return true }
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }

    private func saveProjectCache() throws {
        guard let subject = signedInAccount, let updatedAt = projectCacheUpdatedAt else { return }
        try projectCache?.save(subject: subject, metadata: Array(portalProjects.values), projects: projects, updatedAt: updatedAt)
    }

    /// Cached credentials sign tokens locally, including offline. Project refresh fetches again.
    @MainActor func projectWithCertificate(id: String, refresh: Bool = false) async throws -> AgoraProject {
        guard let project = projects.first(where: { $0.id == id }) else { throw PortalAPIError.invalidResponse }
        if !refresh, !project.signKey.isEmpty { return project }
        guard let remote = portalProjects[id], let settings = portalSettings, let auth = portalAuth else {
            throw AccountLoginError.signInRequired
        }
        let epoch = accountGeneration
        let result: AgoraProject
        do {
            result = try await portalAPI.certificate(project: remote, settings: settings, auth: auth)
        } catch {
            if epoch == accountGeneration, !Task.isCancelled,
               error as? AccountLoginError == .signInRequired || error as? PortalAPIError == .signInRequired {
                accountSignInRequired = true
                NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
            }
            if epoch == accountGeneration, !Task.isCancelled, !project.signKey.isEmpty, Self.isProjectNetworkFailure(error) {
                usingSavedProjects = true
                projectLoadError = "Offline. Using saved projects and local token generation."
                return project
            }
            throw error
        }
        guard epoch == accountGeneration, !Task.isCancelled,
              portalProjects[id]?.projectId == remote.projectId,
              let index = projects.firstIndex(where: { $0.id == id }) else { throw AccountLoginError.changed }
        projects[index] = result
        if selectedProject?.id == id { selectedProject = result }
        try saveProjectCache()
        return result
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
        let epoch = accountGeneration
        Task { @MainActor in
            do { _ = try await projectWithCertificate(id: id) }
            catch { if epoch == accountGeneration { projectLoadError = error.localizedDescription } }
        }
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

        let authorizedProject: AgoraProject?
        if let project {
            authorizedProject = try? await projectWithCertificate(id: project.id)
        } else { authorizedProject = nil }
        guard let project = authorizedProject, !project.signKey.isEmpty else {
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
            self.requestAgentList(from: client.id)
        }
    }

    func removeClient(withId clientId: String) {
        DispatchQueue.main.async {
            self.atemVerification.disconnect(clientId: clientId)
            self.atemStorageKeys.disconnect(clientId: clientId)
            self.connectedClients.removeAll { $0.id == clientId }
            self.agentsByClientId.removeValue(forKey: clientId)
            self.sessionStatusByClientId.removeValue(forKey: clientId)
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
            
        case .userCommand, .agentInput, .voiceCommand, .voiceToggle, .voiceRequest, .agentListRequest:
            var error = AtemSessionMessage(op: "error")
            error.code = "unsupported_version"
            return .session(error)
            
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

        case .agentListResponse:
            // r6.2's authenticated session registry is the only agent list.
            return nil

        case .session, .terminal, .agentChat:
            // Agent traffic is accepted exclusively through the authenticated r9 channel.
            return nil

        case .browserChat:
            // Browser capabilities are accepted only on the explicit relay bridge.
            return nil

        case .credentialProjectListResponse(let report):
            guard let context = captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            DispatchQueue.main.async {
                do {
                    let value = try self.atemE2EIdentity.openCredentialProjects(report, account: context.account, deviceId: context.route.deviceId)
                    guard self.e2eDataAccount == value.account else { return }
                    let key = value.account + "\0" + value.deviceId
                    if let old = self.credentialProjectReports[key], old.pin == value.pin,
                       old.time > value.time || (old.time == value.time && old.hasLabels && !value.hasLabels) { return }
                    self.credentialProjectReports[key] = value
                    self.refreshCredentialProjectSuggestions()
                } catch {
                    Log.warn("[AstationHub] Rejected credential project report")
                }
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
            DispatchQueue.main.async { [weak self] in
                guard let self, let route = self.verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return }
                self.atemVerification.requestKey(publicKey: publicKey, route: route)
            }
            return nil

        case .verifyCommit(let commit):
            guard let context = captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            DispatchQueue.main.async { [weak self] in
                self?.atemVerification.start(commit, route: context.route, account: context.account)
            }
            return nil

        case .invalidVerifyCommit:
            guard captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) != nil else { return nil }
            return .verifyAbort(reason: "Invalid verification generation; upgrade Atem and retry")

        case .verifyReveal(let reveal):
            guard let context = captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.e2eDataAccount == context.account else { return }
                self.atemVerification.reveal(reveal, route: context.route)
            }
            return nil

        case .verifyAbort:
            guard let context = captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.e2eDataAccount == context.account else { return }
                self.atemVerification.cancel(route: context.route)
            }
            return nil

        case .unlockRequest(let wire):
            DispatchQueue.main.async { [weak self] in
                guard let self, let route = self.verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return }
                self.atemStorageKeys.unlock(wire, route: route)
            }
            return nil

        case .storageKeyRotate(let wire):
            DispatchQueue.main.async { [weak self] in
                guard let self, let route = self.verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return }
                self.atemStorageKeys.rotate(wire, route: route)
            }
            return nil

        case .storageKeyConfirm(let signed):
            DispatchQueue.main.async { [weak self] in
                guard let self, let route = self.verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return }
                self.atemStorageKeys.settle(signed, abandoning: false, route: route)
            }
            return nil

        case .storageKeyAbandon(let signed):
            DispatchQueue.main.async { [weak self] in
                guard let self, let route = self.verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return }
                self.atemStorageKeys.settle(signed, abandoning: true, route: route)
            }
            return nil

        case .encryptionMigrationComplete(let mode, let kid, let completion):
            // Freeze and persist authorization before a disconnect/reconnect can remove the route.
            guard let context = captureMigrationContext(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            do {
                let committed = try atemE2EIdentity.acceptMigrationCompletion(completion,
                    mode: mode, kid: kid, account: context.account, route: context.route,
                    key: loadMigrationKey(context.account, kid))
                dispatchMigration { [weak self] in
                    if let committed { self?.publishMigrationCommit(committed) }
                    self?.resumeAcceptedEncryptionMigrations()
                }
            } catch {
                let showError = { [weak self] in
                    self?.relayEncryptionStatusMessage = error.localizedDescription
                    Log.warn("[AstationHub] Rejected encryption migration completion: \(error.localizedDescription)")
                    NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
                }
                if Thread.isMainThread { showError() } else { DispatchQueue.main.async(execute: showError) }
            }
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
            self.requestAgentList(from: clientId)
        }

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
        let available = supportedAtemClients
        if let pinned = pinnedClientId,
           available.contains(where: { $0.id == pinned }) {
            return pinned
        }
        return (available.first(where: \.isFocused) ?? available.first)?.id
    }

    // MARK: - Client & Agent Management

    var supportedAtemClients: [ConnectedClient] {
        connectedClients.filter { $0.clientType == "Atem" && sessionStatusByClientId[$0.id]?.unsupportedVersion != true }
    }

    private func refreshCredentialProjectSuggestions() {
        let account = e2eDataAccount
        credentialProjectReports = credentialProjectReports.filter { _, report in
            report.account == account && (try? atemE2EIdentity.credentialProjectPin(account: account, deviceId: report.deviceId)) == report.pin
        }
        let reports = credentialProjectReports.values.sorted {
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.deviceId < $1.deviceId
        }
        let projects = LocalCredentialStore.projectLabels(reports.flatMap(\.projects))
        if projects != credentialProjectSuggestions { credentialProjectSuggestions = projects }
    }

    func requestCredentialProjects() {
        dispatchPrecondition(condition: .onQueue(.main))
        refreshCredentialProjectSuggestions()
        for client in connectedClients {
            let connection = identityRelayAuthentication.connectionId(for: client.id)
            guard let route = verificationRoute(clientId: client.id, relayConnectionId: connection),
                  (try? atemE2EIdentity.isVerified(account: e2eDataAccount, deviceId: route.deviceId)) == true else { continue }
            sendMessage(.credentialProjectListRequest, to: route.clientId,
                expectedRelayConnectionId: client.id.hasPrefix("relay-") ? route.connectionId : nil)
        }
    }

    /// Explicitly pin a client as the active routing target.
    func pinClient(id: String) {
        DispatchQueue.main.async { self.pinnedClientId = id }
    }

    /// Clear the pin, reverting to focus-based routing.
    func unpinClient() {
        DispatchQueue.main.async { self.pinnedClientId = nil }
    }


    /// Refresh the one registry shared by Connections and terminal windows.
    func requestAgentList(from clientId: String) {
        sessionClient(for: clientId)?.refresh()
    }

    func localControlAPI(key: LocalAPIKey, inbox: ApprovalInbox) -> LocalControlAPI {
        LocalControlAPI(key: key, clients: { [weak self] in
            guard let self else { return [:] }
            return Dictionary(uniqueKeysWithValues: self.connectedClients.compactMap { connected in
                self.sessionClient(for: connected.id).map { (connected.id, $0) }
            })
        }, inbox: inbox, records: { [weak self] in self?.sessionJournal.snapshot.requests ?? [] })
    }

    func sessionClient(for clientId: String, atemId: String? = nil) -> AtemSessionClient? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let context = sessionContext(for: clientId, atemId: atemId) else { return nil }
        let id = context.route.clientId
        if let client = nativeSessionClients[id] { client.connectionChanged(); return client }
        let client = AtemSessionClient(context: { [weak self] in self?.sessionContext(for: id) },
            send: { [weak self] message, route in self?.sendSessionMessage(message, to: route) ?? false },
            journal: sessionJournal,
            reconnect: { [weak self] context in self?.reconnectSessionTransport(context) ?? false },
            sendChat: { [weak self] message, route in self?.sendSessionChatMessage(message, to: route) ?? false },
            openChannel: { [weak self] context in
                Task { @MainActor in self?.openR9Channel(context) }
            }, closeChannel: { [weak self] context in
                MainActor.assumeIsolated { self?.closeR9Channel(context) }
            })
        nativeSessionClients[id] = client
        client.onChange = { [weak self, weak client] in
            guard let self, let client else { return }
            self.sessionStatusByClientId[id] = client.connectionStatus
            self.agentsByClientId[id] = client.hasRegistrySnapshot
                ? client.registry.values.sorted { $0.session_id < $1.session_id }.map(AtemAgentInfo.init(session:)) : []
            self.sessionStateDidChange?(id)
            let host = DeviceAuthentication.deviceLabel(self.connectedClients.first(where: { $0.id == id })?.hostname ?? "Atem")
            self.approvalSessionDidChange?(id, client, host)
        }
        client.start()
        if sessionTimer == nil {
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                for client in Array(self.nativeSessionClients.values) { client.tick() }
            }
        }
        return client
    }

    private func refreshSessionConnections() {
        for (id, client) in Array(nativeSessionClients) {
            client.connectionChanged()
            if !connectedClients.contains(where: { $0.id == id }) {
                nativeSessionClients.removeValue(forKey: id)
                agentsByClientId.removeValue(forKey: id)
                sessionStatusByClientId.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Voice Command Routing

    /// Send a voice command to the focused Atem instance.
    /// Called by the transcription pipeline when speech-to-text produces text.
    func sendVoiceCommand(text: String, isFinal: Bool) {
        guard isFinal else { return }
        sendScopedAgentInput(clientId: routeToFocusedAtem(), agentId: nil, kind: "text", value: text)
    }

    // MARK: - Remote Agent Control

    func openAgentInBrowser(clientId: String, agent: AtemAgentInfo) throws -> URL {
        dispatchPrecondition(condition: .onQueue(.main))
        if let reason = remoteAccessBlockReason(for: clientId) { throw reason }
        throw BrowserAgentChat.OpenError.sessionProtocolRequired
    }

    private func sendBrowserChatFrame(_ frame: BrowserChatFrame, to route: RemoteTerminalConnection) {
        guard identityRelayVerified, let task = identityRelayTask,
              route.clientId.hasPrefix("relay-browser-"),
              let data = try? JSONEncoder().encode(AstationMessage.browserChat(frame)),
              let payload = try? JSONSerialization.jsonObject(with: data),
              let envelope = try? JSONSerialization.data(withJSONObject: [
                "atem_id": String(route.clientId.dropFirst(6)), "connection_id": route.connectionId, "payload": payload
              ]), let text = String(data: envelope, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func terminalConnection(for clientId: String, atemId: String? = nil) -> RemoteTerminalConnection? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !systemIsSleeping else { return nil }
        let sameTransport: (ConnectedClient) -> Bool = {
            $0.id.hasPrefix("relay-") == clientId.hasPrefix("relay-")
        }
        guard let client = connectedClients.first(where: { $0.id == clientId })
                ?? connectedClients.first(where: { atemId != nil && $0.atemId == atemId && sameTransport($0) }),
              client.clientType == "Atem", atemId == nil || client.atemId == atemId,
              let sessionId = client.authenticationSessionId,
              let authenticatedSession = deviceSessionStore.get(sessionId: sessionId),
              authenticatedSession.isValid, authenticatedSession.atemId == client.atemId,
              let deviceId = client.atemId,
              (try? atemE2EIdentity.isVerified(account: e2eDataAccount, deviceId: deviceId)) == true else { return nil }
        if client.id.hasPrefix("relay-") {
            guard identityRelayVerified,
                  let generation = identityRelayAuthentication.connectionId(for: client.id),
                  identityRelayAuthentication.isAuthenticated(clientId: client.id, connectionId: generation) else { return nil }
            return RemoteTerminalConnection(clientId: client.id, connectionId: generation)
        }
        return RemoteTerminalConnection(clientId: client.id, connectionId: client.id)
    }

    func remoteAccessBlockReason(for clientId: String) -> RemoteAccessBlockReason? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let client = connectedClients.first(where: { $0.id == clientId }), client.clientType == "Atem" else { return .offline }
        guard let sessionId = client.authenticationSessionId,
              let session = deviceSessionStore.get(sessionId: sessionId), session.isValid,
              let deviceId = client.atemId, session.atemId == deviceId else { return .authenticationRequired }
        do {
            guard try atemE2EIdentity.isVerified(account: e2eDataAccount, deviceId: deviceId) else { return .verificationRequired }
        } catch { return .identityUnavailable }
        return terminalConnection(for: clientId) == nil ? .authenticationRequired : nil
    }

    private func remoteTrustDidChange() {
        refreshDirectMigrationContexts()
        refreshSessionConnections()
        for client in connectedClients where client.clientType == "Atem" {
            _ = sessionClient(for: client.id)
        }
        agentsByClientId = agentsByClientId.filter { terminalConnection(for: $0.key) != nil }
        objectWillChange.send()
        terminalConnectionsDidChange?()
    }

    func remoteVerificationDidComplete(on route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard verificationRoute(clientId: route.clientId,
                  relayConnectionId: route.clientId.hasPrefix("relay-") ? route.connectionId : nil) == route,
              let context = sessionContext(for: route.clientId), context.device == route.deviceId else { return }
        remoteTrustDidChange()
        requestRelayEncryptionState()
        nativeSessionClients[route.clientId]?.verificationDidComplete(context: context)
    }

    @discardableResult
    func sendTerminalMessage(_ message: RemoteTerminalMessage, to route: RemoteTerminalConnection) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard terminalConnection(for: route.clientId) == route, sendHandler != nil else { return false }
        guard case .bound(_, let binding) = message,
              let client = nativeSessionClients[route.clientId], client.phase == .ready,
              binding.attachment_gen == client.welcome?.attachment_gen,
              binding == client.binding(for: binding.target, mutation: binding.lease_epoch != nil) else { return false }
        return MainActor.assumeIsolated { r9Connections[route.clientId]?.send(.terminal(message)) ?? false }
    }

    func sessionContext(for clientId: String, atemId: String? = nil) -> AtemSessionContext? {
        guard let route = terminalConnection(for: clientId, atemId: atemId),
              let client = connectedClients.first(where: { $0.id == route.clientId }),
              let device = client.atemId, let session = client.authenticationSessionId else { return nil }
        return AtemSessionContext(route: route, account: e2eDataAccount, device: device, pairingSession: session,
            transportGeneration: clientId.hasPrefix("relay-") ? identityRelaySocketGeneration : route.connectionId)
    }

    @discardableResult
    func sendSessionMessage(_ message: AtemSessionMessage, to route: RemoteTerminalConnection) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sessionContext(for: route.clientId)?.route == route, sendHandler != nil,
              (try? message.validate()) != nil else { return false }
        return MainActor.assumeIsolated { r9Connections[route.clientId]?.send(.session(message)) ?? false }
    }

    private func sendSessionChatMessage(_ message: AgentChatWire, to route: RemoteTerminalConnection) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sessionContext(for: route.clientId)?.route == route, sendHandler != nil else { return false }
        return MainActor.assumeIsolated { r9Connections[route.clientId]?.send(.agentChat(message)) ?? false }
    }

    @MainActor private func openR9Channel(_ context: AtemSessionContext) {
        guard sessionContext(for: context.route.clientId) == context else { return }
        closeR9Channel(context)
        do {
            let coordinator = try recoveryCoordinator(account: context.account)
            let log = try coordinator.channelMembership(hostID: context.device)
            if r9Signer == nil { r9Signer = try AstationChannelSigner(identity: atemE2EIdentity, keyID: AstationIdentity.shared.id) }
            let link = AstationR9Connection(context: context,
                current: { [weak self] in self?.sessionContext(for: context.route.clientId) == context },
                write: { [weak self] bytes, completion in
                    guard let self, self.sessionContext(for: context.route.clientId) == context else {
                        completion(RemoteChannelError.staleLink); return
                    }
                    if context.route.clientId.hasPrefix("relay-") {
                        guard let socket = self.identityRelayTask, self.identityRelayVerified,
                              let wrapped = try? RemoteRelayEnvelope.wrap(bytes, host: context.device, connection: context.route.connectionId),
                              let text = String(data: wrapped, encoding: .utf8) else { completion(RemoteChannelError.staleLink); return }
                        socket.send(.string(text), completionHandler: { completion($0) })
                    } else if let send = self.sendDirectChannel { send(bytes, context.route.clientId, completion) }
                    else { completion(RemoteChannelError.staleLink) }
                }, welcomed: { [weak self] welcome in
                    self?.nativeSessionClients[context.route.clientId]?.channelWelcomed(welcome, from: context.route)
                }, receive: { [weak self] message in
                    self?.receiveR9Application(message, context: context)
                }, failed: { [weak self] message, unsupported in
                    self?.nativeSessionClients[context.route.clientId]?.channelFailed(message, unsupported: unsupported)
                }, refreshMembership: { [weak self] head in
                    self?.refreshR9Membership(context, requiredHead: head)
                })
            r9Connections[context.route.clientId] = link
            try link.start(identity: ClientIdentity(kind: .native, deviceId: AstationIdentity.shared.id,
                keyId: AstationIdentity.shared.id, grantJson: nil), log: log, signer: r9Signer!)
        } catch {
            nativeSessionClients[context.route.clientId]?.channelFailed(
                "r9 account membership is unavailable. Complete recovery setup and verify this Atem with an r9 build.")
        }
    }

    @MainActor private func refreshR9Membership(_ context: AtemSessionContext, requiredHead: LogHead) {
        guard let previous = r9Connections[context.route.clientId] else { return }
        Task { @MainActor [weak self] in
            guard let self, self.sessionContext(for: context.route.clientId) == context else { return }
            do {
                try await self.recoveryCoordinator(account: context.account)
                    .refreshChannelMembership(hostID: context.device, requiredHead: requiredHead)
                guard self.sessionContext(for: context.route.clientId) == context,
                      self.r9Connections[context.route.clientId] === previous else { return }
                self.nativeSessionClients[context.route.clientId]?.channelMembershipRefreshed(context: context)
            } catch {
                guard self.sessionContext(for: context.route.clientId) == context,
                      self.r9Connections[context.route.clientId] === previous else { return }
                self.nativeSessionClients[context.route.clientId]?.channelFailed(
                    "The signed membership update could not be verified or saved. Review account verification before reconnecting.")
            }
        }
    }

    @MainActor private func closeR9Channel(_ context: AtemSessionContext) {
        guard let link = r9Connections[context.route.clientId], link.context == context else { return }
        r9Connections.removeValue(forKey: context.route.clientId)?.disconnect()
    }

    /// Socket adapters capture their authenticated generation before entering the main actor.
    @MainActor func receiveR9Envelope(_ bytes: Data, clientID: String, connectionID: String) {
        guard let context = sessionContext(for: clientID), context.route.connectionId == connectionID else { return }
        r9Connections[clientID]?.receive(bytes)
    }

    @MainActor private func receiveR9Application(_ message: AstationMessage, context: AtemSessionContext) {
        guard sessionContext(for: context.route.clientId) == context else { return }
        switch message {
        case .session(let payload):
            nativeSessionClients[context.route.clientId]?.receive(payload, from: context.route)
            sessionMessageHandler?(payload, context.route)
        case .terminal(let payload): terminalMessageHandler?(payload, context.route)
        case .agentChat(let payload): nativeSessionClients[context.route.clientId]?.receiveChat(payload, from: context.route)
        default: break
        }
    }

    private func browserChatConnection(for clientId: String) -> RemoteTerminalConnection? {
        // No unbound chat fallback, including before the first native hello.
        nil
    }

    private func captureSessionContext(clientId: String, relayConnectionId: String?) -> AtemSessionContext? {
        if Thread.isMainThread {
            guard let context = sessionContext(for: clientId),
                  relayConnectionId == nil || relayConnectionId == context.route.connectionId else { return nil }
            return context
        }
        guard !clientId.hasPrefix("relay-"), relayConnectionId == nil else { return nil }
        migrationContextLock.lock(); defer { migrationContextLock.unlock() }
        return directSessionContexts[clientId]
    }

    /// Legacy requests lack the exact process target and current control lease.
    /// Keep callers informed rather than falling back to an unscoped mutation.
    @discardableResult
    func sendAgentText(_ text: String, agentId: String? = nil, clientId: String? = nil) -> Bool {
        sendScopedAgentInput(clientId: clientId ?? routeToFocusedAtem(), agentId: agentId, kind: "text", value: text)
    }

    @discardableResult
    func sendAgentKey(_ key: String, agentId: String? = nil, clientId: String? = nil) -> Bool {
        sendScopedAgentInput(clientId: clientId ?? routeToFocusedAtem(), agentId: agentId, kind: "key", value: key)
    }

    @discardableResult
    private func sendScopedAgentInput(clientId: String?, agentId: String?, kind: String, value: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let clientId, let route = terminalConnection(for: clientId),
           remoteAgentInputHandler?(route, agentId, kind, value) == true {
            remoteInputStatusMessage = nil
            return true
        }
        remoteInputStatusMessage = clientId.flatMap { remoteAccessBlockReason(for: $0)?.localizedDescription }
            ?? "Open Terminal and choose Take Control for this agent before sending voice or shortcut input."
        if clientId == nil { remoteInputStatusMessage = RemoteAccessBlockReason.offline.localizedDescription }
        Log.info("[AgentInput] Rejected input without a session control lease")
        return false
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

    func sendCommandToClient(_ command: String, action: String, clientId: String) -> Bool {
        remoteInputStatusMessage = "Remote console commands were removed. Open Terminal, select a session and take control."
        return false
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

        let task = makePairingRelayTask(url)
        task.resume()

        // Generate a synthetic client ID for this relay connection
        let relayClientId = "relay-\(code)"

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
        // This socket only hands off pairing credentials. The identity-room
        // authentication will add the real Atem; a room code is not a device.
        sendEncryptionMode(to: relayClientId, relayConnectionId: nil)
        sendCredentials(toClientId: relayClientId)
    }

    private func readRelayMessages(task: IdentityRelaySocket, clientId: String) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    NetworkDebugLogger.logWebSocket(direction: "recv", context: "relay \(clientId)", message: text)
                    if let data = text.data(using: .utf8),
                       let msg = try? AstationMessage.decodePacket(data) {
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
            }
        }
    }

    // MARK: - Identity Relay (persistent background relay for TUI auto-reconnect)

    private func reconnectSessionTransport(_ expected: AtemSessionContext) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !systemIsSleeping, sessionContext(for: expected.route.clientId) == expected else { return false }
        if expected.route.clientId.hasPrefix("relay-") {
            Log.info("[Sessions] Resetting the relay transport for fresh session authentication")
            pauseIdentityRelay()
            startIdentityRelay()
        } else {
            guard let disconnectDirectClient else { return false }
            Log.info("[Sessions] Closing the direct transport for fresh session authentication")
            disconnectDirectClient(expected.route.clientId)
            removeClient(withId: expected.route.clientId)
        }
        return true
    }

    @objc private func systemWillSleep() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !systemIsSleeping else { return }
        systemIsSleeping = true
        resumeRelayAfterSleep = identityRelayReconnectGeneration > 0
        Log.info("[Sessions] Mac sleeping; closing session transports and releasing local authority")
        refreshSessionConnections()
        pauseIdentityRelay()
        for client in connectedClients where !client.id.hasPrefix("relay-") {
            disconnectDirectClient?(client.id)
            removeClient(withId: client.id)
        }
    }

    @objc private func systemDidWake() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard systemIsSleeping else { return }
        systemIsSleeping = false
        if resumeRelayAfterSleep {
            resumeRelayAfterSleep = false
            Log.info("[Sessions] Mac woke; reconnecting the relay before session discovery")
            startIdentityRelay()
        }
    }

    /// Connect to the relay using this Astation's own identity as the room code.
    /// Atem stores the identity after first pairing and uses it for TUI auto-connect.
    func startIdentityRelay() {
        guard !systemIsSleeping, !identityRelayActive else { return }

        // Start NWPathMonitor once — fires when network comes back, enabling
        // immediate reconnect without polling. No battery overhead while offline.
        startIdentityRelayMonitorIfNeeded()
        relayIdentityKeyManager.loadIfNeeded()
        guard !identityRelayActive,
              !relayIdentityKeyRepairPending || relayIdentityRepairReconnectRequested else { return }
        guard case .loaded = relayIdentityKeyManager.state else { return }
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
        identityRelaySocketGeneration = UUID().uuidString
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
                    } else if let envelope = try? RemoteRelayEnvelope(Data(text.utf8)),
                              RemoteRelayEnvelope.isChannel(envelope.payload) {
                        Task { @MainActor in
                            guard let self, self.identityRelayTask === task, self.identityRelayVerified,
                                  DeviceAuthentication.isValidAtemId(envelope.host),
                                  self.identityRelayAuthentication.isAuthenticated(clientId: "relay-\(envelope.host)",
                                      connectionId: envelope.connection) else { return }
                            self.receiveR9Envelope(envelope.payload, clientID: "relay-\(envelope.host)", connectionID: envelope.connection)
                        }
                    } else if let data = text.data(using: .utf8),
                       let rawPacket = try? AtemSessionJSON.validatePacket(data),
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
                        } else if let rawPayload = try? rawPacket["payload"]?.canonical(allowOtherNumbers: true),
                                  let payloadData = rawPayload.data(using: .utf8),
                                  let msg = try? AstationMessage.decodePacket(payloadData) {
                            DispatchQueue.main.async {
                                guard let self, self.identityRelayTask === task else {
                                    Log.debug("[AstationHub] Ignored message from a replaced identity relay socket")
                                    return
                                }
                                if case .browserChat(let frame) = msg {
                                    guard self.identityRelayVerified else { return }
                                    self.browserAgentChat.receive(frame, from: RemoteTerminalConnection(
                                        clientId: relayClientId, connectionId: connectionId))
                                    return
                                }
                                guard !relayClientId.hasPrefix("relay-browser-") else { return }
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
        browserAgentChat.invalidateAll()
        terminalConnectionsDidChange?()
        let wasVerified = identityRelayVerified
        identityRelayTask = nil
        identityRelaySocketGeneration = UUID().uuidString
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
            if forType == "relayPushRegister" || forType == "relayPushUnregister" {
                approvalPushRegistrationStatus = ok
                    ? (forType == "relayPushRegister" ? "Notification address registered." : "Approval notifications disabled.")
                    : "Notification registration failed. It will retry after reconnecting."
                return
            }
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
            let previous = relayEncryptionState
            relayEncryptionState = state
            relayEncryptionStatusMessage = nil
            do {
                if let local = try atemE2EIdentity.state(account: state.dataAccount) {
                    relayEncryptionState = state.withEncryptionState(local)
                    if local.mode != state.mode || local.kid != state.kid {
                        relayEncryptionStatusMessage = "The relay's encryption mode differs from this Mac's approved state. The local state is retained."
                        replicateLocalEncryptionState(account: state.dataAccount, state: local, reported: state)
                        scheduleEncryptionMigrationRetry()
                    }
                } else {
                    relayEncryptionState = state.withUnavailableEncryptionState()
                }
            } catch {
                relayEncryptionState = previous?.dataAccount == state.dataAccount ? previous : state.withUnavailableEncryptionState()
                relayEncryptionStatusMessage = error.localizedDescription
            }
            broadcastEncryptionMode(state)
            resumeAcceptedEncryptionMigrations()
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
        let recoveryWasAlreadyPending = relayIdentityKeyRepairPending
        let record: RelayIdentityKeyRepairRecord
        switch beginRelayIdentityKeyRecoveryPause() {
        case .success(let saved): record = saved
        case .failure(let failure): completion(failure); return
        }
        relayIdentityKeyManager.repair { [weak self] failure in
            if let self, failure != nil, !recoveryWasAlreadyPending,
               self.relayIdentityKeyRepairRecord == record,
               record.clear(from: self.relayIdentityRepairDefaults) {
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
        identityRelaySocketGeneration = UUID().uuidString
        identityRelayVerified = false
        identityRelayActive = false
        pendingRelayChallenge = nil
        identityRelayReconnectGeneration &+= 1
        connectedClients.filter { $0.id.hasPrefix("relay-") }.forEach { removeClient(withId: $0.id) }
        identityRelayAuthentication.removeAll()
        browserAgentChat.invalidateAll()
        refreshSessionConnections()
        terminalConnectionsDidChange?()
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
            if relayIdentityKeyRepairPending {
                // Verification completes only the recovery operation this socket started.
                guard let record = relayIdentityKeyRepairRecord,
                      RelayIdentityKeyRepairRecord.load(
                        astationId: AstationIdentity.shared.id, relayURL: stationRelayUrl,
                        defaults: relayIdentityRepairDefaults
                      ) == record,
                      record.clear(from: relayIdentityRepairDefaults) else {
                    relayIdentityRepairReconnectRequested = false
                    pauseIdentityRelay()
                    relayIdentityStatusMessage = "Device key recovery changed or could not be completed. Reopen Astation before reconnecting."
                    NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
                    return
                }
                relayIdentityKeyRepairRecord = nil
                relayIdentityKeyRepairPending = false
                relayIdentityRepairReconnectRequested = false
            }
            relayIdentityKeyRejected = false
            identityRelayVerified = true
            identityRelayReconnectPolicy.reset()
            relayIdentityStatusMessage = nil
            NotificationCenter.default.post(name: .relayIdentityKeyChanged, object: nil)
            Log.info("[RelayIdentity] Relay \(status) this Astation's key")
            sendRelaySessionsResync()
            resumeAcceptedEncryptionMigrations()
            requestRelayAccountState()
            requestRelayEncryptionState()
            registerRelayAccountIfPossible()
            syncApprovalPushRegistration()
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
        // Final modes are committed only by a validated, journaled device report.
        guard mode == "enabling" || mode == "disabling" else {
            relayEncryptionStatusMessage = AtemMigrationError.invalidCompletion.localizedDescription
            return
        }
        guard let text = RelayIdentityProtocol.encryptionSetMessage(mode: mode, kid: kid) else { return }
        do {
            let account = e2eDataAccount
            if try DataEncryptionKeyManager.shared.load(dataAccount: account, kid: kid) == nil {
                throw AtemIdentityError.invalidState
            }
            let signed = try atemE2EIdentity.setState(account: account, mode: mode, kid: kid)
            if let reported = relayEncryptionState, let saved = try atemE2EIdentity.state(account: account) {
                relayEncryptionState = reported.withEncryptionState(saved)
            }
            let message = AstationMessage.encryptionMode(accountState: signed)
            broadcastHandler?(message)
            broadcastToAuthenticatedIdentityRelayClients(message)
        } catch {
            relayEncryptionStatusMessage = error.localizedDescription
            NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
            return
        }
        relayEncryptionStatusMessage = "Updating encryption…"
        NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
        sendRelayIdentityControl(text, label: "relayEncryptionSet")
    }

    private func scheduleEncryptionMigrationRetry() {
        guard !encryptionMigrationRetryScheduled else { return }
        encryptionMigrationRetryScheduled = true
        let delay = encryptionMigrationRetryDelay
        encryptionMigrationRetryDelay = min(delay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.encryptionMigrationRetryScheduled = false
            self.resumeAcceptedEncryptionMigrations()
            if self.identityRelayVerified { self.requestRelayEncryptionState() }
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

    @MainActor func installEncryptionKey(_ value: AccountDataKey) async throws {
        let account = e2eDataAccount
        try await recoveryCoordinator(account: account).installBackedUpKey(value)
        guard e2eDataAccount == account else { throw AtemIdentityError.identityChanged }
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

    @MainActor func restoreEncryptionKey(_ text: String) async throws {
        let account = relayEncryptionState?.dataAccount ?? currentDataAccount
        let value = try DataEncryptionKeyManager.decodeRecoveryKey(text)
        if let state = relayEncryptionState, state.kid != nil, state.kid != value.kid {
            throw DataEncryptionKeyError.invalidRecoveryKey
        }
        try await recoveryCoordinator(account: account).installBackedUpKey(value)
        guard e2eDataAccount == account else { throw AtemIdentityError.identityChanged }
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

    private var e2eDataAccount: String { relayEncryptionState?.dataAccount ?? currentDataAccount }

    private static func directVerificationRoute(_ client: ConnectedClient) -> AtemVerificationRoute? {
        guard let deviceId = client.atemId else { return nil }
        return AtemVerificationRoute(clientId: client.id, connectionId: client.id,
            deviceId: deviceId, deviceName: DeviceAuthentication.deviceLabel(client.hostname))
    }

    private func refreshDirectMigrationContexts() {
        let account = e2eDataAccount
        var contexts: [String: MigrationContext] = [:]
        var sessions: [String: AtemSessionContext] = [:]
        for client in connectedClients where !client.id.hasPrefix("relay-") {
            if let route = Self.directVerificationRoute(client) {
                contexts[client.id] = MigrationContext(account: account, route: route)
            }
            if let context = sessionContext(for: client.id) { sessions[client.id] = context }
        }
        migrationContextLock.lock()
        directMigrationContexts = contexts
        directSessionContexts = sessions
        migrationContextLock.unlock()
    }

    private func captureMigrationContext(clientId: String, relayConnectionId: String?) -> MigrationContext? {
        if Thread.isMainThread {
            guard let route = verificationRoute(clientId: clientId, relayConnectionId: relayConnectionId) else { return nil }
            return MigrationContext(account: e2eDataAccount, route: route)
        }
        // Main may be waiting for this socket's event loop; never synchronously hop back.
        guard !clientId.hasPrefix("relay-"), relayConnectionId == nil else { return nil }
        migrationContextLock.lock(); defer { migrationContextLock.unlock() }
        return directMigrationContexts[clientId]
    }

    private func verificationRoute(clientId: String, relayConnectionId: String?) -> AtemVerificationRoute? {
        guard let client = connectedClients.first(where: { $0.id == clientId }), let deviceId = client.atemId else { return nil }
        guard clientId.hasPrefix("relay-") else { return Self.directVerificationRoute(client) }
        guard identityRelayVerified, let relayConnectionId,
              identityRelayAuthentication.isAuthenticated(clientId: clientId, connectionId: relayConnectionId) else { return nil }
        return AtemVerificationRoute(
            clientId: clientId, connectionId: relayConnectionId,
            deviceId: deviceId, deviceName: DeviceAuthentication.deviceLabel(client.hostname)
        )
    }

    private func broadcastEncryptionMode(_ state: RelayEncryptionState) {
        do {
            guard let local = try atemE2EIdentity.state(account: state.dataAccount) else { return }
            let signed = try atemE2EIdentity.signedState(
                account: state.dataAccount,
                key: DataEncryptionKeyManager.shared.load(dataAccount: state.dataAccount, kid: local.kid)
            )
            let message = AstationMessage.encryptionMode(accountState: signed)
            broadcastHandler?(message)
            broadcastToAuthenticatedIdentityRelayClients(message)
        } catch {
            relayEncryptionStatusMessage = error.localizedDescription
        }
    }

    private func sendEncryptionMode(to clientId: String, relayConnectionId: String?) {
        do {
            guard let local = try atemE2EIdentity.state(account: e2eDataAccount) else { return }
            let signed = try atemE2EIdentity.signedState(
                account: e2eDataAccount,
                key: DataEncryptionKeyManager.shared.load(dataAccount: e2eDataAccount, kid: local.kid)
            )
            sendMessage(.encryptionMode(accountState: signed), to: clientId, expectedRelayConnectionId: relayConnectionId)
        } catch {
            relayEncryptionStatusMessage = error.localizedDescription
        }
    }

    private func resumeAcceptedEncryptionMigrations() {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            var needsRetry = false
            for account in try atemE2EIdentity.pendingMigrationAccounts() {
                do {
                    let state = try atemE2EIdentity.state(account: account)
                    if let committed = try atemE2EIdentity.finishAcceptedMigration(account: account,
                        key: loadMigrationKey(account, state?.kid)) {
                        publishMigrationCommit(committed)
                    }
                } catch {
                    needsRetry = true
                    relayEncryptionStatusMessage = error.localizedDescription
                    NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
                }
            }
            if needsRetry { scheduleEncryptionMigrationRetry() }
        } catch {
            relayEncryptionStatusMessage = error.localizedDescription
            scheduleEncryptionMigrationRetry()
        }
    }

    private func publishMigrationCommit(_ committed: AtemMigrationCommit) {
        guard let current = try? atemE2EIdentity.currentMigrationCommit(account: committed.account),
              current.signedState == committed.signedState,
              committed.account == e2eDataAccount else { return }
        let message = AstationMessage.encryptionMode(accountState: committed.signedState)
        broadcastHandler?(message)
        broadcastToAuthenticatedIdentityRelayClients(message)
        if let reported = relayEncryptionState, reported.dataAccount == committed.account,
           let local = try? atemE2EIdentity.state(account: committed.account) {
            relayEncryptionState = reported.withEncryptionState(local)
        }
        relayEncryptionStatusMessage = nil
        NotificationCenter.default.post(name: .relayEncryptionChanged, object: nil)
        if let text = RelayIdentityProtocol.encryptionSetMessage(mode: committed.target, kid: committed.kid) {
            sendRelayIdentityControl(text, label: "relayEncryptionSet")
        }
    }

    private func replicateLocalEncryptionState(account: String, state: AtemAccountState, reported: RelayEncryptionState) {
        guard account == e2eDataAccount else { return }
        var mode = state.mode
        var kid = state.kid
        // Recover a missed replica transition without regressing the authoritative local state.
        if state.mode == "on", reported.mode == "off" || (reported.mode == "on" && reported.kid != state.kid) {
            mode = "enabling"
        } else if state.mode == "off", reported.mode == "on" {
            mode = "disabling"
            kid = (try? atemE2EIdentity.currentMigrationCommit(account: account))?.kid
        }
        guard let text = RelayIdentityProtocol.encryptionSetMessage(mode: mode, kid: kid) else { return }
        sendRelayIdentityControl(text, label: "relayEncryptionSet")
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

    func setApprovalPushRegistration(_ registration: ApprovalPushRegistration) {
        dispatchPrecondition(condition: .onQueue(.main))
        approvalPushRegistration = registration
        approvalPushUnregistration = nil
        approvalPushRegistrationStatus = "Waiting for a verified relay connection."
        syncApprovalPushRegistration()
    }

    func unregisterApprovalPush(platform: ApprovalPushPlatform) {
        dispatchPrecondition(condition: .onQueue(.main))
        approvalPushRegistration = nil
        approvalPushUnregistration = platform
        syncApprovalPushRegistration()
    }

    private func syncApprovalPushRegistration() {
        guard identityRelayVerified else { return }
        if let platform = approvalPushUnregistration,
           let text = ApprovalPushRegistration.unregisterMessage(platform: platform) {
            sendRelayIdentityControl(text, label: "relayPushUnregister")
        } else if let text = approvalPushRegistration?.registerMessage {
            sendRelayIdentityControl(text, label: "relayPushRegister")
        }
    }

    private func registerRelayAccountIfPossible() {
        guard identityRelayVerified else { return }
        let generation = identityRelaySocketGeneration
        let accountEpoch = accountGeneration
        let relayURL = stationRelayUrl
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await accountAuth.accessToken(relayURL: relayURL)
                let rawLabel = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                let label = DeviceAuthentication.deviceLabel(rawLabel)
                guard let text = RelayIdentityProtocol.registerAccountMessage(
                    accessToken: token,
                    label: label
                ) else { return }
                await MainActor.run {
                    guard self.identityRelaySocketGeneration == generation, self.accountGeneration == accountEpoch,
                          self.stationRelayUrl == relayURL, self.identityRelayVerified else { return }
                    self.sendRelayIdentityControl(text, label: "relayRegisterAccount")
                }
            } catch {
                Log.debug("[RelayAccount] Registration deferred: \(error.localizedDescription)")
                await MainActor.run {
                    guard self.identityRelaySocketGeneration == generation, self.accountGeneration == accountEpoch,
                          self.stationRelayUrl == relayURL else { return }
                    self.relayAccountStatusMessage = error.localizedDescription
                    NotificationCenter.default.post(name: .relayAccountChanged, object: nil)
                }
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
        // A browser proves a local capability; it is never paired as an Atem device.
        if clientId.hasPrefix("relay-browser-") { return }
        switch event {
        case "connected":
            if identityRelayAuthentication.connect(clientId: clientId, connectionId: connectionId) {
                terminalConnectionsDidChange?()
                removeClient(withId: clientId)
            }
            requestIdentityRelayAuthentication(clientId: clientId, connectionId: connectionId)
        case "disconnected":
            if identityRelayAuthentication.disconnect(clientId: clientId, connectionId: connectionId) {
                terminalConnectionsDidChange?()
                removeClient(withId: clientId)
            }
        default:
            Log.warn("[AstationHub] Ignored unknown identity relay event: \(event)")
        }
    }

    private func requestIdentityRelayAuthentication(
        clientId: String,
        connectionId: String,
        hostname: String = "unknown"
    ) {
        guard identityRelayVerified,
              !identityRelayAuthentication.isAuthenticated(clientId: clientId, connectionId: connectionId) else { return }
        // A restored relay socket and a racing hello must use the same proof.
        let challenge: String
        if let pending = identityRelayAuthentication.challenge(clientId: clientId, connectionId: connectionId) {
            challenge = pending
        } else {
            challenge = DeviceAuthentication.makeChallenge()
            guard identityRelayAuthentication.issueChallenge(
                clientId: clientId, connectionId: connectionId, challenge: challenge
            ) else {
                Log.warn("[AstationHub] Relay authentication challenge limit reached")
                return
            }
        }
        sendHandler?(.statusUpdate(status: "auth_required", data: [
            "astation_id": AstationIdentity.shared.id,
            "challenge": challenge,
            "transport": "relay",
            "protocol": DeviceAuthentication.protocolVersion,
            "hostname": hostname
        ]), clientId)
        Log.info("[AstationHub] Relay authentication required for \(hostname)")
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
            requestIdentityRelayAuthentication(clientId: clientId, connectionId: connectionId, hostname: hostname)
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
        if message.isPrivateAgentTraffic { return }
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
                sessionId: session.id,
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
            sessionId: session.id,
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
        sessionId: String,
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
                atemId: atemId,
                authenticationSessionId: sessionId
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
    var authenticationSessionId: String?
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

struct AgoraProject: Codable, Identifiable, Sendable {
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
