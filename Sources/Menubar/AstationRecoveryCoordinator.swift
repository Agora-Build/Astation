import AtemClient
import AstationRemote
import AppKit
import Foundation

@MainActor
protocol AstationRecoveryCheckpointStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
extension RemoteRecoveryStore: AstationRecoveryCheckpointStorage {}

protocol AstationRecoveryDataKeys {
    func recoveryKeys(dataAccount: String) throws -> [AccountDataKey]
    func generate() throws -> AccountDataKey
    func install(_ value: AccountDataKey, dataAccount: String) throws
    func installRecovered(_ values: [AccountDataKey], dataAccount: String) throws
}
extension DataEncryptionKeyManager: AstationRecoveryDataKeys {}

enum AstationHostEnrollmentError: LocalizedError {
    case generationNotAdvanced

    var errorDescription: String? {
        "A previous verification already registered this Atem generation. Atem must start verification with a newer trust generation. Your pairing and account data were retained."
    }
}

/// One account, one protected checkpoint and one process owner for all v2 operations.
/// A relay reply cannot replace this independently saved genesis or authorize a device.
@MainActor
final class AstationRecoveryCoordinator {
    private struct SavedKey: Codable { let kid: String; let bytes: Data; var initializeOff: Bool? }
    private struct Saved: Codable {
        var version = 2
        let accountID: String
        let managerID: String
        var bootstrap: Data?
        var entries: [String] = []
        var membership: String?
        var publication: Data?
        var hostBody: String?
        var supersededHostPublications: [Data]?
        var serviceApproval: Data?
        var supersededServiceReviews: [Data]?
        var serviceRemoval: Data?
        var supersededServiceRemovals: [Data]?
        var deviceEnrollment: Data?
        var deviceReview: Data?
        var backup: Data?
        var restoreKit: String?
        var restore: Data?
        var pendingDataKey: SavedKey?
        var controlJournalIDs: [String: Data]?
        var controlPublications: [String: Data]?
        var controlRecoveryPublications: [String: Data]?
        var hostSenderReview: Data?
        var supersededHostSenderPublications: [Data]?
        var verifierRosters: [String: AcceptedVerifierRoster]?
        var processRosters: [String: [String: AstationProcessRoster]]?
        var verifierHistoryRoots: [String: String]?
    }

    nonisolated static let bootID = RemoteSystemClock.bootIdentifier
    nonisolated static func clock() -> HostClock {
        RemoteSystemClock.now()
    }

    let accountID: String
    let managerID: String
    private let store: AstationRecoveryCheckpointStorage
    private let identity: AtemE2EIdentity
    private let http: RemoteRecoveryTransport
    let relayURL: String
    private let allowNewDataKey: () -> Bool
    private let confirmOwner: (SignRequest) async -> Bool
    private let confirmServiceOwner: (RemoteServiceApproval, SignRequest) async -> Bool
    private let authorizeDelegatedControl: ((MembershipLog) throws -> Void)?
    private let controlSigningJournal: @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal
    private let controlRecoveryAuthority: RemoteControlRecoveryAuthorizing?
    private let authorizeNewMembership: ((SignRequest, MembershipLog) throws -> Void)?
    private let confirmVerifierRoster: ((VerifierRosterReview) async -> Bool)?
    private let confirmProcessRoster: (() async -> Bool)?
    private let verifierHistory: @MainActor (MembershipLog, String, Bool) throws -> RemoteMemberVerifierJournal
    private var processReview: ProcessReview?
    private var deliveredVerifierChallenges: [String: Set<String>] = [:]
    private var verifierReportGeneration = UUID()
    private let verifierTime: () -> UInt64
    /// The caller authenticates this account's Station roster and scopes each transport's token
    /// to its exact origin. A cached presence list is not a complete roster.
    private let additionalControlStations: ((MembershipLog) throws -> [String: RemoteControlStationTransport])?
    private let retainedControlTransport: ((String) throws -> RemoteControlStationTransport)?
    private let confirmReplacement: (String) async -> Bool
    private let saveKit: (String) async -> Bool
    private let dataKeys: AstationRecoveryDataKeys
    private let now: () -> HostClock
    private var checkpointTimer: Timer?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var saved: Saved
    private var bootstrap: RemoteRecoveryBootstrap?
    private var publication: RemoteMembershipPublication?
    private var backup: RemoteRecoveryBackup?
    private var restoreOperation: RemoteRecoveryRestore?
    private var membershipLog: MembershipLog?
    private var controlPublications: [String: RemoteControlPublication] = [:]
    private var controlRecoveryPublications: [String: RemoteControlRecoveryPublication] = [:]
    private var controlDeliveryContext: (portal: PortalIntegrationHTTP, current: () -> Bool)?
    private var controlDeliveryTask: Task<Void, Never>?
    private var lastControlDeliveryOrigin: String?
    private var lastControlDeliveryRecord: [String: String] = [:]
    private var controlActivityContext: (generation: UUID, current: () -> Bool,
        updated: (String, MembershipLog, [RemoteControlActivity]) -> Void)?
    private var controlActivityTask: Task<Void, Never>?
    private var controlActivityPages: [String: ControlDiscoveryPage] = [:]
    private var lastControlActivityOrigin: String?
    var onControlDelivery: ((RemoteControlDelivery) -> Void)?
    /// Deliver only durable head changes, after the account operation releases its lock.
    var onMembershipCommit: ((LogHead) -> Void)?
    var onControlCommit: (() -> Void)?
    var onLocalVerifierSlotChange: (() -> Void)?
    private var pendingMembershipHead: LogHead?
    private var pendingControlCommit = false
    private var busy = false {
        didSet { notifyMembershipCommit(); notifyControlCommit() }
    }
    private var uncertain = false
    private var verifierRosterReview: VerifierRosterReview?

    convenience init(accountID: String, managerID: String, identity: AtemE2EIdentity, relayURL: String,
        accessToken: @escaping @Sendable () async throws -> String, allowNewDataKey: @escaping () -> Bool,
        retainedControlTransport: ((String) throws -> RemoteControlStationTransport)? = nil) throws {
        try self.init(accountID: accountID, managerID: managerID, identity: identity, relayURL: relayURL,
            store: RemoteRecoveryStore(accountID: accountID),
            transport: RemoteRecoveryHTTP(relayURL: relayURL, accessToken: accessToken),
            dataKeys: DataEncryptionKeyManager.shared, allowNewDataKey: allowNewDataKey,
            confirmOwner: { request in
                await withCheckedContinuation { continuation in
                    let reason = request.purpose == .genesis ? "confirm this account's recovery setup"
                        : request.purpose == .signerReport ? "sign this Mac's recovery report for the reviewed Station plan"
                        : request.purpose == .controlRecord ? "authorize the reviewed stop of delegated agent work"
                        : request.purpose == .hostSender ? "confirm the reviewed host sending change"
                        : request.purpose == .project ? "confirm the reviewed project permissions"
                        : request.purpose == .hostEncKey ? "confirm the reviewed host encryption key"
                        : request.purpose != .keyBackup ? "approve this account's device or integration access"
                        : "confirm this account's encrypted key backup"
                    DeviceOwnerAuth.authenticate(reason: reason) {
                        continuation.resume(returning: $0)
                    }
                }
            }, confirmReplacement: { account in
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: "add this Mac as the replacement device for account \(account)") { continuation.resume(returning: $0) }
                }
            }, saveKit: { text in
                await withCheckedContinuation { continuation in
                    _ = AtemVerificationUI.saveRecovery(text) { continuation.resume(returning: $0) }
                }
            }, confirmServiceOwner: { approval, _ in
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: IntegrationAccessNotice.ownerAuthenticationReason(stationOrigin: approval.stationOrigin)) {
                        continuation.resume(returning: $0)
                    }
                }
            }, retainedControlTransport: retainedControlTransport, confirmVerifierRoster: { _ in
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: "confirm the reviewed Station server list") {
                        continuation.resume(returning: $0)
                    }
                }
            }, confirmProcessRoster: {
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: "confirm the reviewed verifier processes") {
                        continuation.resume(returning: $0)
                    }
                }
            })
    }

    init(accountID: String, managerID: String, identity: AtemE2EIdentity, relayURL: String,
        store: AstationRecoveryCheckpointStorage, transport: RemoteRecoveryTransport, dataKeys: AstationRecoveryDataKeys,
        allowNewDataKey: @escaping () -> Bool, confirmOwner: @escaping (SignRequest) async -> Bool,
        confirmReplacement: @escaping (String) async -> Bool, saveKit: @escaping (String) async -> Bool,
        confirmServiceOwner: ((RemoteServiceApproval, SignRequest) async -> Bool)? = nil,
        authorizeDelegatedControl: ((MembershipLog) throws -> Void)? = nil,
        controlRecoveryAuthority: RemoteControlRecoveryAuthorizing? = nil,
        controlSigningJournal: @escaping @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal = RemoteControlSigningJournal.init(log:memberID:),
        authorizeNewMembership: ((SignRequest, MembershipLog) throws -> Void)? = nil,
        additionalControlStations: ((MembershipLog) throws -> [String: RemoteControlStationTransport])? = nil,
        retainedControlTransport: ((String) throws -> RemoteControlStationTransport)? = nil,
        confirmVerifierRoster: ((VerifierRosterReview) async -> Bool)? = nil,
        confirmProcessRoster: (() async -> Bool)? = nil,
        verifierHistory: @escaping @MainActor (MembershipLog, String, Bool) throws -> RemoteMemberVerifierJournal =
            RemoteMemberVerifierJournal.init(log:origin:creating:),
        verifierTime: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() },
        now: @escaping () -> HostClock = { AstationRecoveryCoordinator.clock() }) throws {
        self.accountID = accountID
        self.managerID = managerID
        self.identity = identity
        self.relayURL = relayURL
        self.allowNewDataKey = allowNewDataKey
        self.store = store
        http = transport
        self.dataKeys = dataKeys
        self.confirmOwner = confirmOwner
        self.confirmServiceOwner = confirmServiceOwner ?? { _, request in await confirmOwner(request) }
        self.authorizeDelegatedControl = authorizeDelegatedControl
        self.controlRecoveryAuthority = controlRecoveryAuthority
        self.controlSigningJournal = controlSigningJournal
        self.authorizeNewMembership = authorizeNewMembership
        self.additionalControlStations = additionalControlStations
        self.retainedControlTransport = retainedControlTransport
        self.confirmVerifierRoster = confirmVerifierRoster
        self.confirmProcessRoster = confirmProcessRoster
        self.verifierHistory = verifierHistory
        self.verifierTime = verifierTime
        self.confirmReplacement = confirmReplacement
        self.saveKit = saveKit
        self.now = now
        if let data = try store.read() {
            saved = try PropertyListDecoder().decode(Saved.self, from: data)
            guard (2...9).contains(saved.version), saved.accountID == accountID, saved.managerID == managerID,
                  saved.version >= 9 || saved.verifierHistoryRoots == nil,
                  (saved.verifierHistoryRoots ?? [:]).count <= 64,
                  (saved.verifierHistoryRoots ?? [:]).allSatisfy({ PortalIntegrationRecord.validOrigin($0.key) && RemoteRecoveryKit.validHash($0.value) }),
                  saved.version >= 8 || !(saved.processRosters ?? [:]).values.contains(where: {
                      $0.values.contains { $0.localReporterSlot != nil }
                  }),
                  saved.version >= 7 || !(saved.processRosters ?? [:]).values.contains(where: {
                      $0.values.contains { $0.earlier != nil }
                  }),
                  (saved.controlJournalIDs ?? [:]).allSatisfy({ RemoteRecoveryKit.validHash($0.key) && $0.value.count == 16 }),
                  saved.version >= 6 || saved.controlJournalIDs == nil,
                  saved.version >= 5 || (saved.processRosters ?? [:]).isEmpty,
                  saved.version >= 4 || (saved.controlRecoveryPublications ?? [:]).isEmpty else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
        } else { saved = Saved(accountID: accountID, managerID: managerID) }
        if !saved.entries.isEmpty {
            guard let genesis = try currentKit()?.genesisHash else { throw RemoteRecoveryError.invalidCheckpoint }
            let log = try RemoteMembershipCheckpoint.load(accountID: accountID, genesisHash: genesis,
                entries: saved.entries, storedJSON: saved.membership, now: now())
            try commitLog(log)
        } else if saved.membership != nil { throw RemoteRecoveryError.invalidCheckpoint }
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkpointFromLifecycle()
                self?.refreshControlActivityInBackground()
            }
        }
        for (center, name) in [(NotificationCenter.default, NSApplication.didResignActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification)] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkpointFromLifecycle() }
            }
            lifecycleObservers.append((center, observer))
        }
    }

    deinit {
        checkpointTimer?.invalidate()
        controlActivityTask?.cancel()
        for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
    }

    private func checkpointFromLifecycle() {
        do { try checkpointPendingWaits() }
        catch { uncertain = true; Log.error("[Recovery] Membership checkpoint failed; account operations are paused") }
        retrySavedControlsIfNeeded()
    }

    func checkpointPendingWaits() throws {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !busy, let current = membershipLog else { return }
        do {
            let log = current.snapshot()
            _ = try log.advance(now: now())
            if try log.storedJson() != saved.membership { try commitLog(log) }
        } catch { uncertain = true; throw error }
    }

    private func commitLog(_ log: MembershipLog, change: (inout Saved) -> Void = { _ in }) throws {
        do {
            let state = try log.storedJson()
            let entries = log.entries()
            let headChanged = membershipLog?.head() != log.head()
            try persist { $0.entries = entries; $0.membership = state; change(&$0) }
            membershipLog = log.snapshot()
            if headChanged { pendingMembershipHead = log.head() }
            notifyMembershipCommit()
        } catch { uncertain = true; throw error }
    }

    private func notifyMembershipCommit() {
        guard !busy, let head = pendingMembershipHead else { return }
        pendingMembershipHead = nil
        onMembershipCommit?(head)
    }

    private func notifyControlCommit() {
        guard !busy, !uncertain, pendingControlCommit else { return }
        pendingControlCommit = false
        onControlCommit?()
    }

    private func persist(_ change: (inout Saved) -> Void) throws {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        var next = saved
        change(&next)
        // Older readers must refuse rather than rewrite away recovery signatures.
        next.version = max(saved.version, next.version)
        if !(next.controlRecoveryPublications ?? [:]).isEmpty { next.version = max(next.version, 4) }
        if !(next.processRosters ?? [:]).isEmpty { next.version = max(next.version, 5) }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try store.write(encoder.encode(next))
            saved = next
        } catch { uncertain = true; throw error }
    }

    private func begin(nativeDevice: Bool = false, hostSender: Bool = false) throws {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !busy, nativeDevice || saved.deviceReview == nil,
              hostSender || saved.hostSenderReview == nil else { throw RemoteRecoveryError.busy }
        busy = true
    }

    private func provider() throws -> AstationMembershipKeyProvider {
        AstationMembershipKeyProvider(identity: identity, keyID: managerID, publicKey: try identity.remotePublicKeys().signing)
    }

    private func confirmed(_ request: SignRequest, at time: UInt64? = nil) async throws -> RemoteConfirmedSigner {
        if time == nil {
            let ok = await confirmOwner(request)
            guard ok else { throw RemoteRecoveryError.confirmationRequired }
        }
        return try RemoteConfirmedSigner(provider: provider(), request: request,
            confirmedAt: time ?? Self.clock().monoMs, now: { Self.clock().monoMs })
    }

    private func loadBootstrap() throws -> RemoteRecoveryBootstrap? {
        if let bootstrap { return bootstrap }
        guard let checkpoint = saved.bootstrap else { return nil }
        let value = try RemoteRecoveryBootstrap(checkpoint: checkpoint, accountID: accountID, now: now(),
            persist: { [unowned self] bytes in try self.persist { $0.bootstrap = bytes } })
        bootstrap = value
        return value
    }

    /// Setup is an explicit owner-confirmed creation, never an automatic restore fallback.
    func setup() async throws -> RemoteRecoveryKit {
        try await setup(backupCurrentKeys: true)
    }

    private func setup(backupCurrentKeys: Bool) async throws -> RemoteRecoveryKit {
        try begin(); defer { busy = false }
        if let text = saved.restoreKit {
            let kit = try RemoteRecoveryKit(text: text)
            let log = try await refreshedLog(genesis: kit.genesisHash)
            guard log.recoveryKey() == kit.recoveryKey else { throw RemoteRecoveryError.kitNotCurrent }
            if log.member(deviceId: managerID)?.status == .active {
                try requireManager(log)
                if backupCurrentKeys { try await finishBackup() }
            }
            return try kit.replacingRelayURL(relayURL)
        }
        var value = try loadBootstrap()
        if value == nil {
            let keys = try identity.remotePublicKeys()
            value = try RemoteRecoveryBootstrap(accountID: accountID, managerID: managerID, keyID: managerID,
                authKey: PublicKeyData(alg: .p256, raw: keys.signing),
                encryptionKey: PublicKeyData(alg: .x25519, raw: keys.encryption),
                recoverySecret: AtemSecureEnclaveCryptography.random32(), relayURL: relayURL, signedAt: now().wallMs,
                persist: { [unowned self] bytes in try self.persist { $0.bootstrap = bytes } })
            bootstrap = value
        }
        let operation = value!
        if (try? operation.committedLog(now: now())) == nil {
            let request: AppendRequest
            if let outstanding = try operation.outstanding() { request = outstanding }
            else {
                let signer = try await confirmed(operation.signingRequest())
                request = try operation.sign(provider: signer, now: now())
            }
            switch try await http.append(genesisHash: operation.genesisHash, request: request) {
            case .stored: break
            case .conflict: throw RemoteRecoveryError.requiresReview
            }
            try operation.relayStored(now: now())
        }
        if saved.entries.isEmpty {
            try commitLog(operation.committedLog(now: now()))
        }
        let originalKit = try operation.kit(now: now())
        let currentLog = try await refreshedLog(genesis: originalKit.genesisHash)
        guard currentLog.recoveryKey() == (try operation.committedLog(now: now())).recoveryKey() else {
            throw RemoteRecoveryError.kitNotCurrent
        }
        let kit = try originalKit.replacingRelayURL(relayURL)
        if !operation.recoveryIsSaved {
            let accepted = await saveKit(kit.text())
            guard accepted else { throw AtemIdentityError.recoveryNotSaved }
            try operation.markKitSaved(originalKit, now: now())
        }
        try identity.markRecoverySaved(signingPublicKey: identity.remotePublicKeys().signing)
        if backupCurrentKeys { try await finishBackup() }
        return kit
    }

    /// Rotation and imported AEK1 keys are backed up with all retained keys before use.
    func installBackedUpKey(_ value: AccountDataKey) async throws {
        _ = try await setup(backupCurrentKeys: false)
        try begin(); defer { busy = false }
        if let pending = saved.pendingDataKey {
            guard pending.kid == value.kid, pending.bytes == value.key else { throw RemoteRecoveryError.requiresReview }
        } else {
            guard saved.backup == nil else { throw RemoteRecoveryError.requiresReview }
            try persist { $0.pendingDataKey = SavedKey(kid: value.kid, bytes: value.key, initializeOff: false) }
        }
        try await finishBackup()
    }

    func exportedKit() async throws -> RemoteRecoveryKit {
        try await setup()
    }

    var securitySetupComplete: Bool {
        get throws {
            guard !saved.entries.isEmpty else { return false }
            if saved.restoreKit != nil { return true }
            return try loadBootstrap()?.recoveryIsSaved == true
        }
    }

    func pairingKeys(nonce: Data) async throws -> AtemVerifyKeys {
        let kit = try await setup()
        let log = try await refreshedLog(genesis: kit.genesisHash)
        let keys = try identity.remotePublicKeys()
        try requireManager(log)
        return AtemVerifyKeys(signPub: keys.signing, encPub: keys.encryption,
            recoverySignPub: log.recoveryKey().raw, nonce: nonce, genesisHash: kit.genesisHash)
    }

    func prepareHost(commit: RemotePairingCommit, reveal: RemotePairingReveal, keys: AtemVerifyKeys) async throws -> SignRequest {
        try begin(); defer { busy = false }
        guard saved.serviceApproval == nil, saved.serviceRemoval == nil else { throw RemoteRecoveryError.busy }
        guard let genesis = keys.genesisHash else { throw AtemIdentityError.invalidState }
        let log = try await refreshedLog(genesis: genesis)
        try requireManager(log)
        guard log.host(hostId: commit.context.hostID).map({ $0.hostTrustGen < commit.hostTrustGeneration }) ?? true else {
            throw AstationHostEnrollmentError.generationNotAdvanced
        }
        if let checkpoint = saved.publication {
            publication = nil
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: log.genesisHash(), now: now(), persist: { [unowned self] bytes in try self.persist { $0.publication = bytes } })
            if let body = saved.hostBody, let outstanding = try publication?.outstanding(),
               try !archiveInvalidHostDraft(body: body, outstanding: outstanding, checkpoint: checkpoint,
                   log: log, hostID: commit.context.hostID) {
                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID)
                let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                let host = object?["host"] as? [String: Any]
                let key = host?["host_key"] as? [String: Any]
                guard host?["host_id"] as? String == commit.context.hostID,
                      (host?["host_trust_gen"] as? NSNumber)?.uint64Value == commit.hostTrustGeneration,
                      key?["pub"] as? String == reveal.hostChannelPublicKey.base64URLEncodedString() else {
                    throw RemoteRecoveryError.requiresReview
                }
                return request
            }
            publication = nil
        }
        let publisher = RemoteMembershipPublication(log: log, persist: { [unowned self] bytes in try self.persist { $0.publication = bytes } })
        publication = publisher
        let body = try publisher.prepareHost(commit: commit,
            hostChannelKey: PublicKeyData(alg: .ed25519, raw: reveal.hostChannelPublicKey), signer: managerID, signedAt: now().wallMs)
        try persist { $0.hostBody = body }
        return try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID)
    }

    private func archiveInvalidHostDraft(body: String, outstanding: AppendRequest, checkpoint: Data,
        log: MembershipLog, hostID: String) throws -> Bool {
        guard try signedObjectInfo(json: outstanding.entryJson).bodyJcs == body else { throw RemoteRecoveryError.requiresReview }
        if try log.entries().contains(where: { try signedObjectInfo(json: $0).entryHash == outstanding.entryHash }) {
            try persist { $0.publication = nil; $0.hostBody = nil }
            publication = nil
            return true
        }
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let host = object?["host"] as? [String: Any]
        guard object?["action"] as? String == "add_host", object?["signer"] as? String == managerID,
              host?["host_id"] as? String == hostID, let generation = host?["host_trust_gen"] as? NSNumber,
              let currentHost = log.host(hostId: hostID), generation.uint64Value <= currentHost.hostTrustGen,
              outstanding.expected == log.head(), try signedObjectInfo(json: outstanding.entryJson).bodyJcs == body else { return false }
        let evaluation = try log.snapshot().extend(entries: [outstanding.entryJson], now: now())
        guard evaluation.appended == 0, case .invalid(_, let code) = evaluation.stop,
              code == "host_trust_gen_not_increasing" else { return false }
        guard (saved.supersededHostPublications?.count ?? 0) < 16 else { throw RemoteRecoveryError.requiresReview }
        // Only the anchored verifier can prove this signed draft invalid.
        // Preserve its evidence before preparing a higher-generation replacement.
        let evidence = try PropertyListEncoder().encode(["publication": checkpoint, "body": Data(body.utf8)])
        try persist {
            $0.supersededHostPublications = ($0.supersededHostPublications ?? []) + [evidence]
            $0.publication = nil; $0.hostBody = nil
        }
        publication = nil
        return true
    }

    func commitHost(request: SignRequest, confirmedAt: UInt64, current: () -> Bool) async throws -> [String] {
        try begin(); defer { busy = false }
        guard current(), let publication, let body = saved.hostBody,
              request == (try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID)),
              let genesis = try currentKit()?.genesisHash else { throw RemoteChannelError.staleLink }
        let signer = try await confirmed(request, at: confirmedAt)
        guard current() else { throw RemoteChannelError.staleLink }
        let entry = try publication.sign(provider: signer, keyID: managerID)
        switch try await http.append(genesisHash: genesis, request: entry) {
        case .stored:
            guard case .committed = try publication.relayStored(now: now()) else { throw RemoteRecoveryError.requiresReview }
        case .conflict(let page):
            _ = try publication.relayConflict(head: page.head, entries: page.entries, more: page.more, now: now())
            try commitLog(publication.committedLog()) { $0.publication = nil; $0.hostBody = nil }
            self.publication = nil
            throw RemoteRecoveryError.confirmationRequired
        }
        let committed = try publication.committedLog()
        let entries = committed.entries()
        try commitLog(committed) { $0.publication = nil; $0.hostBody = nil }
        self.publication = nil
        guard current() else { throw RemoteChannelError.staleLink }
        return entries
    }

    func cancelUnsignedHost(request: SignRequest) throws {
        guard !busy, saved.hostBody == request.bodyJson, try publication?.outstanding() == nil else { return }
        try persist { $0.publication = nil; $0.hostBody = nil }
        publication = nil
    }

    private func deviceTransport() throws -> any RemoteDeviceEnrollmentTransport {
        guard let transport = http as? any RemoteDeviceEnrollmentTransport else {
            throw RemoteRecoveryTransportError.unavailable
        }
        return transport
    }

    private func deviceSession(issuer: String, owner: String) throws -> RemoteDeviceEnrollmentSession {
        guard let checkpoint = saved.deviceEnrollment else { throw RemoteRecoveryError.notCommitted }
        return try RemoteDeviceEnrollmentSession(checkpoint: checkpoint, issuer: issuer, owner: owner,
            station: relayURL, now: now(), persist: { [unowned self] bytes in
                try self.persist { $0.deviceEnrollment = bytes }
            })
    }

    /// The QR remains in the native window and protected checkpoint, never the relay or Flutter.
    func startDeviceEnrollment(issuer: String, owner: String, roles: [String],
        current: () -> Bool) async throws -> RemoteDeviceEnrollmentInvitation {
        try begin(nativeDevice: true); defer { busy = false }
        guard current(), let kit = try currentKit(), saved.hostBody == nil,
              saved.serviceApproval == nil, saved.serviceRemoval == nil,
              saved.publication == nil || saved.deviceReview != nil else { throw RemoteRecoveryError.busy }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireManager(log)
        let session: RemoteDeviceEnrollmentSession
        if saved.deviceEnrollment != nil {
            session = try deviceSession(issuer: issuer, owner: owner)
            guard session.invitation.roles == roles else { throw RemoteRecoveryError.requiresReview }
        } else {
            let invitation = try RemoteDeviceEnrollmentInvitation(issuer: issuer, owner: owner,
                station: relayURL, log: log, manager: managerID, roles: roles, now: now())
            session = try RemoteDeviceEnrollmentSession(invitation: invitation, now: now(), persist: { [unowned self] bytes in
                try self.persist { $0.deviceEnrollment = bytes }
            })
        }
        _ = try session.qrJSON(now: now())
        _ = try await deviceTransport().createEnrollment(session.invitation, now: now().wallMs)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        return session.invitation
    }

    func readDeviceEnrollment(issuer: String, owner: String, current: () -> Bool) async throws
        -> (request: RemoteDeviceEnrollmentRequest?, handedOff: Bool) {
        try begin(nativeDevice: true); defer { busy = false }
        guard current() else { throw RemoteChannelError.staleLink }
        let session = try deviceSession(issuer: issuer, owner: owner)
        let mailbox = try await deviceTransport().readEnrollment(session.invitation, now: now().wallMs)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        if let request = mailbox.request { _ = try session.bind(requestJSON: request.json(), now: now()) }
        if let response = mailbox.response {
            guard try session.matchesHandoff(response, now: now()) else { throw RemoteDeviceEnrollmentError.invalidProof }
        }
        return (mailbox.request, mailbox.response != nil)
    }

    /// Save the exact reviewed add in the same serialized writer used by host and service changes.
    func prepareDeviceEnrollment(issuer: String, owner: String, request: RemoteDeviceEnrollmentRequest,
        current: () -> Bool) async throws -> RemoteNativeEnrollment {
        try begin(nativeDevice: true); defer { busy = false }
        guard current(), saved.hostBody == nil, saved.serviceApproval == nil,
              saved.serviceRemoval == nil else { throw RemoteRecoveryError.busy }
        let session = try deviceSession(issuer: issuer, owner: owner)
        _ = try session.bind(requestJSON: request.json(), now: now())
        if let checkpoint = saved.deviceReview {
            let review = try JSONDecoder().decode(RemoteNativeEnrollment.self, from: checkpoint)
            guard review.deviceID == request.deviceID, review.requestID == session.invitation.id else {
                throw RemoteRecoveryError.requiresReview
            }
            return review
        }
        guard saved.publication == nil else { throw RemoteRecoveryError.busy }
        let log = try await refreshedLog(genesis: session.invitation.genesis)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireManager(log)
        let review = try session.review(log: log, now: now())
        let context = try review.checkpoint()
        let candidate = RemoteMembershipPublication(log: log, persist: { [unowned self] bytes in
            try self.persist { $0.publication = bytes; $0.deviceReview = context }
        })
        _ = try review.prepare(publication: candidate, managerID: managerID, now: now())
        publication = candidate
        return review
    }

    func approveDeviceEnrollment(_ review: RemoteNativeEnrollment, issuer: String, owner: String,
        current: @escaping () -> Bool) async throws {
        try begin(nativeDevice: true); defer { busy = false }
        guard current(), saved.deviceReview == (try review.checkpoint()), let checkpoint = saved.publication else {
            throw RemoteChannelError.staleLink
        }
        let session = try deviceSession(issuer: issuer, owner: owner)
        _ = try session.qrJSON(now: now())
        if publication == nil {
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: review.genesisHash, now: now(), persist: { [unowned self] bytes in
                    try self.persist { $0.publication = bytes }
                })
        }
        guard let publication, publication.operationContext == (try review.checkpoint()) else {
            throw RemoteRecoveryError.requiresReview
        }
        var latest = try await refreshedLog(genesis: review.genesisHash)
        try requireManager(latest)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        if latest.head() != publication.head {
            _ = try publication.relayConflict(head: latest.head(), entries: latest.entriesAfter(seq: publication.head.seq), more: false, now: now())
        }
        let alreadyStored = try latest.entries().contains { try signedObjectInfo(json: $0).bodyJcs == review.bodyJSON }
        if !alreadyStored {
            guard !publication.requiresRefresh else { throw RemoteRecoveryError.requiresReview }
            let append: AppendRequest
            if let retry = try publication.outstanding() { append = retry }
            else {
                let signRequest = try RemoteConfirmedSigner.membershipRequest(bodyJSON: review.bodyJSON, keyID: managerID)
                guard await confirmOwner(signRequest), current(), !Task.isCancelled else {
                    throw RemoteRecoveryError.confirmationRequired
                }
                let stamp = Self.clock().monoMs
                latest = try await refreshedLog(genesis: review.genesisHash)
                try requireManager(latest)
                guard current(), latest.head() == publication.head, !Task.isCancelled else {
                    throw RemoteRecoveryError.requiresReview
                }
                append = try review.sign(publication: publication, provider: provider(), managerID: managerID,
                    confirmedFingerprint: review.fingerprint, validationClock: now(), confirmedAt: stamp,
                    now: { Self.clock().monoMs }, current: current)
            }
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            switch try await http.append(genesisHash: review.genesisHash, request: append) {
            case .stored:
                guard case .committed = try publication.relayStored(now: now()) else { throw RemoteRecoveryError.requiresReview }
            case .conflict(let page):
                _ = try publication.relayConflict(head: page.head, entries: page.entries, more: page.more, now: now())
                try commitLog(publication.committedLog())
                throw RemoteRecoveryError.requiresReview
            }
            try commitLog(publication.committedLog())
        }
        latest = try await refreshedLog(genesis: review.genesisHash)
        try requireManager(latest)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        let keys = try dataKeys.recoveryKeys(dataAccount: accountID).map { AccountKey(kid: $0.kid, k: $0.key) }
        let response = try session.handoff(committedLog: latest, keys: keys, now: now())
        let mailbox = try await deviceTransport().readEnrollment(session.invitation, now: now().wallMs)
        guard current(), !Task.isCancelled, let request = mailbox.request,
              request.deviceID == review.deviceID else { throw RemoteChannelError.staleLink }
        _ = try session.bind(requestJSON: request.json(), now: now())
        let handoff = try RemoteDeviceEnrollmentHandoff(json: response, invitation: session.invitation, request: request, now: now())
        _ = try await deviceTransport().publishEnrollment(handoff, request: request, invitation: session.invitation, now: now().wallMs)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try persist { $0.publication = nil; $0.deviceReview = nil }
        self.publication = nil
    }

    /// Cancels setup carriage, not an already committed member. An uncertain signed append must be reconciled first.
    func cancelDeviceEnrollment(issuer: String, owner: String, current: () -> Bool) async throws {
        try begin(nativeDevice: true); defer { busy = false }
        guard current() else { throw RemoteChannelError.staleLink }
        let ownsPublication = saved.deviceReview != nil
        if ownsPublication {
            guard let checkpoint = saved.publication else { throw RemoteRecoveryError.invalidCheckpoint }
            if publication == nil {
                let session = try deviceSession(issuer: issuer, owner: owner)
                publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                    genesisHash: session.invitation.genesis, now: now(), persist: { [unowned self] bytes in
                        try self.persist { $0.publication = bytes }
                    })
            }
            guard try publication?.outstanding() == nil else { throw RemoteRecoveryError.requiresReview }
        }
        let session = try deviceSession(issuer: issuer, owner: owner)
        try session.cancel()
        try await deviceTransport().cancelEnrollment(session.invitation)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try persist {
            $0.deviceEnrollment = nil; $0.deviceReview = nil
            if ownsPublication { $0.publication = nil }
        }
        if ownsPublication { publication = nil }
    }

    func serviceMembership() async throws -> MembershipLog {
        try begin(); defer { busy = false }
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        return log.snapshot()
    }

    /// A new Station receives the existing signed chain, never a new genesis or K.
    /// Signed replay is idempotent, so a lost reply can resume from its verified prefix.
    func connectAccountSecurity(current: () -> Bool, confirm: () async -> Bool) async throws {
        try begin(); defer { busy = false }
        guard current(), let kit = try currentKit(), let retained = membershipLog,
              saved.publication == nil, saved.restore == nil else { throw RemoteRecoveryError.requiresReview }
        var log = retained.snapshot()
        try requireManager(log)
        guard !(try dataKeys.recoveryKeys(dataAccount: accountID)).isEmpty || saved.pendingDataKey != nil else {
            throw DataEncryptionKeyError.invalidKey
        }
        guard await confirm(), current(), !Task.isCancelled else { throw RemoteRecoveryError.confirmationRequired }
        do {
            let page = try await http.entries(genesisHash: kit.genesisHash, after: 0)
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            if page.head.seq > log.head().seq {
                // A lost backup-append reply can leave this Station one entry ahead.
                // Verify and durably retain the extension before resuming its writer.
                log = try await refreshedLog(genesis: kit.genesisHash)
                try requireManager(log)
            }
        } catch RemoteRecoveryTransportError.recordNotFound {}
        try await RemoteRecoveryLogReplication.publish(log: log.snapshot(), transport: http, current: current)
        guard current() else { throw RemoteChannelError.staleLink }
        let latest = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(latest)
        try await finishBackup(current: current)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
    }

    func pendingServiceApproval() throws -> RemoteServiceApproval? {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        return try saved.serviceApproval.map { try JSONDecoder().decode(RemoteServiceApproval.self, from: $0) }
    }

    func prepareService(_ approval: RemoteServiceApproval) async throws {
        try begin(); defer { busy = false }
        guard saved.hostBody == nil, saved.serviceRemoval == nil,
              let kit = try currentKit(), kit.genesisHash == approval.genesisHash else {
            throw RemoteRecoveryError.busy
        }
        if let pending = try pendingServiceApproval() {
            guard pending == approval else { throw RemoteRecoveryError.requiresReview }
            return
        }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        let consent = try approval.checkpoint()
        let candidate = RemoteMembershipPublication(log: log, persist: { [unowned self] bytes in
            try self.persist { $0.publication = bytes; $0.serviceApproval = consent }
        })
        _ = try approval.prepare(publication: candidate, managerID: managerID, now: now())
        publication = candidate
    }

    /// Retain the exact publication across lost relay/Portal replies. A retry
    /// uses its saved signature; a conflicting head requires another review.
    @discardableResult
    func approveService(_ approval: RemoteServiceApproval, portal: PortalIntegrationHTTP,
        authorizeNewOperations: ((MembershipLog) throws -> Void)? = nil,
        refreshServiceReports: ((MembershipLog) async throws -> ((MembershipLog) throws -> Void))? = nil,
        confirmationClock: @escaping @Sendable () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() },
        current: @escaping () -> Bool) async throws -> (record: PortalIntegrationRecord, membership: MembershipLog) {
        try begin(); defer { busy = false }
        guard current(), try pendingServiceApproval() == approval, let checkpoint = saved.publication else {
            throw RemoteChannelError.staleLink
        }
        if publication == nil {
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: approval.genesisHash, now: now(), persist: { [unowned self] bytes in
                    try self.persist { $0.publication = bytes }
                })
        }
        guard let publication else { throw RemoteRecoveryError.notCommitted }
        let committed = try publication.committedLog()
        let exists = try committed.entries().contains { try signedObjectInfo(json: $0).bodyJcs == approval.bodyJSON }
        if !exists {
            let append: AppendRequest
            if let retry = try publication.outstanding() { append = retry }
            else {
                let review = try RemoteServiceReview(approval: approval)
                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: approval.bodyJSON, keyID: managerID)
                let authorizeInventory: ((SignRequest, MembershipLog) throws -> Void)?
                var checkServiceReports: ((MembershipLog) throws -> Void)?
                if !review.requiredHostFeatures.isEmpty {
                    guard let authorizeNewOperations else { throw StationIntegrationError.hostUpgradeRequired }
                    try authorizeNewOperations(committed)
                    checkServiceReports = try await refreshServiceReports?(committed)
                    try checkServiceReports?(committed)
                    guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                    guard let authorizeNewMembership else { throw RemoteVerifierGateError.unconfirmedVerifiers }
                    try authorizeNewMembership(request, committed)
                    authorizeInventory = { request, log in
                        try authorizeNewOperations(log)
                        try checkServiceReports?(log)
                        try authorizeNewMembership(request, log)
                    }
                } else { authorizeInventory = nil }
                guard await confirmServiceOwner(approval, request), current() else { throw RemoteRecoveryError.confirmationRequired }
                let stamp = confirmationClock()
                let latest = try await refreshedLog(genesis: approval.genesisHash)
                try requireManager(latest)
                guard current(), latest.head() == publication.head else { throw RemoteRecoveryError.requiresReview }
                if authorizeInventory != nil {
                    checkServiceReports = try await refreshServiceReports?(latest)
                    guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                }
                try authorizeInventory?(request, latest)
                let snapshot = latest.snapshot()
                let signer = AstationMembershipKeyProvider(identity: identity, keyID: managerID,
                    publicKey: try identity.remotePublicKeys(create: false).signing,
                    authorizeNewMembership: authorizeInventory.map { authorize in
                        { request in try authorize(request, snapshot) }
                    })
                append = try approval.sign(publication: publication, provider: signer, managerID: managerID,
                    validationClock: now(), confirmedAt: stamp, now: confirmationClock, current: current)
            }
            guard current() else { throw RemoteChannelError.staleLink }
            switch try await http.append(genesisHash: approval.genesisHash, request: append) {
            case .stored:
                guard case .committed = try publication.relayStored(now: now()) else { throw RemoteRecoveryError.requiresReview }
            case .conflict(let page):
                _ = try publication.relayConflict(head: page.head, entries: page.entries, more: page.more, now: now())
                try commitLog(publication.committedLog())
                throw RemoteRecoveryError.requiresReview
            }
            try commitLog(publication.committedLog())
        }
        guard current() else { throw RemoteChannelError.staleLink }
        let latest = try await refreshedLog(genesis: approval.genesisHash)
        try requireManager(latest)
        let review = try RemoteServiceReview(approval: approval)
        let member = latest.member(deviceId: review.serviceID)
        guard current(), latest.frozen() == nil, member?.status == .active,
              member?.memberJson == (try publication.committedLog().member(deviceId: review.serviceID)?.memberJson),
              member?.expiresAt.map({ $0 > now().wallMs }) == true else { throw RemoteRecoveryError.requiresReview }
        // Listing reconciles an uncertain previous POST before any new POST.
        let records = try await portal.owned(stationOrigin: approval.stationOrigin)
        guard current(), let record = records.first(where: { $0.id == approval.integrationID }) else { throw AccountLoginError.changed }
        let approved: PortalIntegrationRecord
        if record.state == "awaiting_approval" {
            approved = try await portal.approve(approval, publication: publication, current: current)
        } else {
            guard ["provisioning", "waiting_for_host", "ready"].contains(record.state), record.r9Svc == approval.fingerprint else {
                throw AccountLoginError.changed
            }
            approved = record
        }
        guard current() else { throw RemoteChannelError.staleLink }
        try persist { $0.publication = nil; $0.serviceApproval = nil }
        self.publication = nil
        return (approved, latest.snapshot())
    }

    func cancelUnsignedService(_ approval: RemoteServiceApproval) throws {
        guard !busy, try pendingServiceApproval() == approval else { return }
        if publication == nil, let checkpoint = saved.publication {
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: approval.genesisHash, now: now(), persist: { [unowned self] bytes in
                    try self.persist { $0.publication = bytes }
                })
        }
        guard try publication?.outstanding() == nil else { throw RemoteRecoveryError.requiresReview }
        if let log = try publication?.committedLog(), try log.entries().contains(where: { try signedObjectInfo(json: $0).bodyJcs == approval.bodyJSON }) {
            throw RemoteRecoveryError.requiresReview
        }
        try persist { $0.publication = nil; $0.serviceApproval = nil }
        publication = nil
    }

    private struct ServiceRemoval: Codable, Equatable {
        let integrationID: String
        let issuer: String
        let ownerAccount: String
        let stationOrigin: String
        let genesisHash: String
        let serviceID: String
        let fingerprint: String
        let bodyJSON: String

        func checkpoint() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    static func removableService(record: PortalIntegrationRecord, log: MembershipLog) throws -> String? {
        guard ["revoking", "revoked"].contains(record.state), let fingerprint = record.r9Svc,
              log.frozen() == nil else { return nil }
        let matches = try log.members().filter {
            guard $0.kind == "service", $0.status == .active else { return false }
            return try RemoteServiceKeyFingerprint.compute($0.authKey) == fingerprint
        }
        guard matches.count == 1 else { return nil }
        return matches[0].deviceId
    }

    static func serviceRemovalComplete(record: PortalIntegrationRecord, log: MembershipLog) throws -> Bool {
        guard ["revoking", "revoked"].contains(record.state), let fingerprint = record.r9Svc,
              log.frozen() == nil else { return false }
        // The core's members() lists active members; removed keys remain in the signed history.
        let ids = try log.entries().compactMap { entry -> String? in
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            guard body?["action"] as? String == "add", let member = body?["member"] as? [String: Any],
                  member["kind"] as? String == "service" else { return nil }
            return member["device_id"] as? String
        }
        let matches = try Set(ids).compactMap { log.member(deviceId: $0) }.filter {
            guard $0.kind == "service" else { return false }
            return try RemoteServiceKeyFingerprint.compute($0.authKey) == fingerprint
        }
        return matches.count == 1 && matches[0].status == .removed
    }

    func pendingServiceRemovalID() throws -> String? {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        return try saved.serviceRemoval.map { try JSONDecoder().decode(ServiceRemoval.self, from: $0).integrationID }
    }

    /// Remove only already-revoked access. Portal never supplies the member ID;
    /// the signed account log binds the reviewed fingerprint to the exact key.
    func removeRevokedService(_ record: PortalIntegrationRecord, ownerAccount: String,
        portal: PortalIntegrationHTTP, current: @escaping () -> Bool) async throws {
        try begin(); defer { busy = false }
        guard current(), portal.ownerAccount == ownerAccount,
              record.stationOrigin == relayURL, ["revoking", "revoked"].contains(record.state),
              let fingerprint = record.r9Svc, saved.hostBody == nil, saved.serviceApproval == nil,
              let kit = try currentKit() else { throw RemoteRecoveryError.requiresReview }
        let records = try await portal.owned(stationOrigin: relayURL)
        guard current(), let fresh = records.first(where: { $0.id == record.id }),
              ["revoking", "revoked"].contains(fresh.state), fresh.r9Svc == fingerprint else {
            throw AccountLoginError.changed
        }
        let removal: ServiceRemoval
        if let data = saved.serviceRemoval {
            removal = try JSONDecoder().decode(ServiceRemoval.self, from: data)
            guard removal.integrationID == record.id, removal.issuer == portal.configuration.issuer,
                  removal.ownerAccount == ownerAccount, removal.stationOrigin == relayURL,
                  removal.genesisHash == kit.genesisHash, removal.fingerprint == fingerprint,
                  let checkpoint = saved.publication else { throw RemoteRecoveryError.requiresReview }
            if publication == nil {
                publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                    genesisHash: kit.genesisHash, now: now(), persist: { [unowned self] bytes in
                        try self.persist { $0.publication = bytes }
                    })
            }
        } else {
            let log = try await refreshedLog(genesis: kit.genesisHash)
            try requireManager(log)
            guard current(), let id = try Self.removableService(record: fresh, log: log) else {
                throw RemoteRecoveryError.requiresReview
            }
            let signedAt = now().wallMs
            let action = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "remove", "device_id": id]), as: UTF8.self)
            let body = try log.draftEntry(signer: managerID, signedAt: signedAt, actionJson: action)
            removal = ServiceRemoval(integrationID: record.id, issuer: portal.configuration.issuer,
                ownerAccount: ownerAccount, stationOrigin: relayURL, genesisHash: kit.genesisHash,
                serviceID: id, fingerprint: fingerprint, bodyJSON: body)
            let context = try removal.checkpoint()
            let candidate = RemoteMembershipPublication(log: log, persist: { [unowned self] bytes in
                try self.persist { $0.version = 3; $0.publication = bytes; $0.serviceRemoval = context }
            })
            guard try candidate.prepare(actionJSON: action, signer: managerID, signedAt: signedAt,
                operationContext: context) == body else { throw RemoteRecoveryError.requiresReview }
            publication = candidate
        }
        guard let publication, publication.operationContext == (try removal.checkpoint()) else {
            throw RemoteRecoveryError.requiresReview
        }
        let reconciled = try await refreshedLog(genesis: removal.genesisHash)
        try requireManager(reconciled)
        guard current(), let member = reconciled.member(deviceId: removal.serviceID), member.kind == "service",
              try RemoteServiceKeyFingerprint.compute(member.authKey) == removal.fingerprint else {
            throw RemoteRecoveryError.requiresReview
        }
        if member.status == .removed {
            if try !reconciled.entries().contains(where: { try signedObjectInfo(json: $0).bodyJcs == removal.bodyJSON }) {
                try archiveSupersededRemoval(removal, latest: reconciled)
            }
            try persist { $0.publication = nil; $0.serviceRemoval = nil }
            self.publication = nil
            return
        }
        guard member.status == .active else { throw RemoteRecoveryError.requiresReview }
        if publication.requiresRefresh || reconciled.head() != publication.head {
            try archiveSupersededRemoval(removal, latest: reconciled)
            throw RemoteRecoveryError.requiresReview
        }
        let committed = try publication.committedLog()
        let stored = try committed.entries().contains { try signedObjectInfo(json: $0).bodyJcs == removal.bodyJSON }
        if !stored {
            let append: AppendRequest
            if let retry = try publication.outstanding() { append = retry }
            else {
                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: removal.bodyJSON, keyID: managerID)
                guard await confirmOwner(request), current() else { throw RemoteRecoveryError.confirmationRequired }
                let confirmedAt = Self.clock().monoMs
                let latest = try await refreshedLog(genesis: removal.genesisHash)
                try requireManager(latest)
                guard current(), latest.head() == publication.head,
                      try Self.removableService(record: fresh, log: latest) == removal.serviceID else {
                    try archiveSupersededRemoval(removal, latest: latest)
                    throw RemoteRecoveryError.requiresReview
                }
                let signer = try await confirmed(request, at: confirmedAt)
                guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
                append = try publication.sign(provider: signer, keyID: managerID)
            }
            guard current(), try signedObjectInfo(json: append.entryJson).bodyJcs == removal.bodyJSON else {
                throw RemoteChannelError.staleLink
            }
            switch try await http.append(genesisHash: removal.genesisHash, request: append) {
            case .stored:
                guard case .committed = try publication.relayStored(now: now()) else { throw RemoteRecoveryError.requiresReview }
            case .conflict(let page):
                _ = try publication.relayConflict(head: page.head, entries: page.entries, more: page.more, now: now())
                let latest = try publication.committedLog()
                try commitLog(latest)
                try archiveSupersededRemoval(removal, latest: latest)
                throw RemoteRecoveryError.requiresReview
            }
            try commitLog(publication.committedLog())
        }
        guard current() else { throw RemoteChannelError.staleLink }
        let latest = try await refreshedLog(genesis: removal.genesisHash)
        try requireManager(latest)
        guard current(), latest.frozen() == nil,
              latest.member(deviceId: removal.serviceID)?.status == .removed else { throw RemoteRecoveryError.requiresReview }
        try persist { $0.publication = nil; $0.serviceRemoval = nil }
        self.publication = nil
    }

    private func archiveSupersededRemoval(_ removal: ServiceRemoval, latest: MembershipLog) throws {
        let body = try JSONSerialization.jsonObject(with: Data(removal.bodyJSON.utf8)) as? [String: Any]
        guard let sequence = body?["seq"] as? NSNumber, let checkpoint = saved.publication,
              (saved.supersededServiceRemovals?.count ?? 0) < 16 else { throw RemoteRecoveryError.requiresReview }
        let replaced = try latest.entries().contains {
            let info = try signedObjectInfo(json: $0)
            let fields = try JSONSerialization.jsonObject(with: Data(info.bodyJcs.utf8)) as? [String: Any]
            return fields?["seq"] as? NSNumber == sequence && info.bodyJcs != removal.bodyJSON
        }
        guard replaced else { throw RemoteRecoveryError.requiresReview }
        let evidence = try PropertyListEncoder().encode(["publication": checkpoint, "removal": removal.checkpoint()])
        try persist {
            $0.supersededServiceRemovals = ($0.supersededServiceRemovals ?? []) + [evidence]
            $0.publication = nil; $0.serviceRemoval = nil
        }
        publication = nil
    }

    /// A signed losing draft is safe to replace only after the anchored chain
    /// proves another body permanently occupies its sequence. Keep its evidence.
    func reviewServiceAgain(_ approval: RemoteServiceApproval) async throws {
        try begin(); defer { busy = false }
        guard try pendingServiceApproval() == approval, let checkpoint = saved.publication else {
            throw RemoteRecoveryError.requiresReview
        }
        let latest = try await refreshedLog(genesis: approval.genesisHash)
        try requireManager(latest)
        let fields = try JSONSerialization.jsonObject(with: Data(approval.bodyJSON.utf8)) as? [String: Any]
        guard let sequence = fields?["seq"] as? NSNumber else { throw RemoteRecoveryError.requiresReview }
        let replacement = try latest.entries().first { entry in
            let info = try signedObjectInfo(json: entry)
            let body = try JSONSerialization.jsonObject(with: Data(info.bodyJcs.utf8)) as? [String: Any]
            return body?["seq"] as? NSNumber == sequence && info.bodyJcs != approval.bodyJSON
        }
        guard replacement != nil, (saved.supersededServiceReviews?.count ?? 0) < 16 else {
            throw RemoteRecoveryError.requiresReview
        }
        let evidence = try PropertyListEncoder().encode(["publication": checkpoint, "consent": approval.checkpoint()])
        try persist {
            $0.supersededServiceReviews = ($0.supersededServiceReviews ?? []) + [evidence]
            $0.publication = nil; $0.serviceApproval = nil
        }
        publication = nil
    }

    /// A proof requires a foreground owner confirmation even for a recently unlocked Mac.
    func approveStationBinding(action: BindingAction, previous: ExpectedBinding, session: AccountLoginSession,
                               current: () -> Bool) async throws -> String {
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let approvals = try RemoteStationBindingApproval(origin: relayURL)
        return try await approvals.prove(action: action, previous: previous, session: session, managerID: managerID,
            membership: {
                try self.requireDurableRecoveryCheckpoint()
                let log = try RemoteMembershipCheckpoint.load(accountID: self.accountID, genesisHash: kit.genesisHash,
                    entries: self.saved.entries, storedJSON: self.saved.membership, now: self.now())
                _ = try log.advance(now: self.now())
                try self.identity.requireVerifierManager(log: log, memberID: self.managerID)
                return log
            }, now: { self.now().wallMs }, current: current, confirm: { review in
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: review.confirmation) { continuation.resume(returning: $0) }
                }
            }, sign: { try self.identity.signStationBinding($0, expectedKey: $1) })
    }

    private func refreshedLog(genesis: String, transport: RemoteRecoveryTransport? = nil) async throws -> MembershipLog {
        guard !saved.entries.isEmpty else { throw RemoteRecoveryError.notCommitted }
        try requireDurableRecoveryCheckpoint()
        let log: MembershipLog
        if let previous = membershipLog, previous.entries() == saved.entries {
            log = previous.snapshot()
        } else {
            log = try RemoteMembershipCheckpoint.load(accountID: accountID, genesisHash: genesis,
                entries: saved.entries, storedJSON: saved.membership, now: now())
        }
        _ = try log.advance(now: now())
        try commitLog(log)
        for _ in 0..<128 {
            let page = try await (transport ?? http).entries(genesisHash: genesis, after: log.head().seq)
            try requireDurableRecoveryCheckpoint()
            let result = try log.extend(entries: page.entries, now: now())
            try commitLog(log)
            guard result.stop == nil, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
            if !page.more {
                guard log.head() == page.head else { throw RemoteRecoveryTransportError.invalidResponse }
                return log
            }
            guard !page.entries.isEmpty else { throw RemoteRecoveryTransportError.invalidResponse }
        }
        throw RemoteRecoveryTransportError.invalidResponse
    }

    private func currentKit() throws -> RemoteRecoveryKit? {
        if let text = saved.restoreKit { return try RemoteRecoveryKit(text: text) }
        return try loadBootstrap()?.kit(now: now())
    }

    /// Use the independently anchored, durable log. A relay/account login never creates membership.
    func refreshChannelMembership(hostID: String, requiredHead: LogHead) async throws {
        try begin(); defer { busy = false }
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        switch try log.relation(head: requiredHead) {
        case .same, .hostBehind: break
        case .hostAhead, .diverged: throw RemoteRecoveryError.requiresReview
        }
        guard log.host(hostId: hostID) != nil else { throw RemoteRecoveryError.requiresReview }
    }

    func channelMembership(hostID: String) throws -> MembershipLog {
        guard !busy, !uncertain, let kit = try currentKit(), let log = membershipLog?.snapshot(),
              log.genesisHash() == kit.genesisHash else { throw RemoteRecoveryError.notCommitted }
        _ = try log.advance(now: now())
        try commitLog(log)
        let keys = try identity.remotePublicKeys()
        guard let member = log.member(deviceId: managerID), member.kind == "native",
              member.status == .active, member.roles.contains("view"),
              member.authKey == PublicKeyData(alg: .p256, raw: keys.signing),
              member.encKey == PublicKeyData(alg: .x25519, raw: keys.encryption) else {
            throw RemoteRecoveryError.requiresReview
        }
        guard log.frozen() == nil, log.host(hostId: hostID) != nil else { throw RemoteRecoveryError.requiresReview }
        return log.snapshot()
    }

    func stationRouteAnchor(hostID: String) throws -> RemoteStationRoute.Anchor? {
        guard let log = membershipLog, let host = log.host(hostId: hostID) else { return nil }
        return RemoteStationRoute.Anchor(account: accountID, genesis: log.genesisHash(),
            host: host.hostId, trust: host.hostTrustGen)
    }

    private func requireManager(_ log: MembershipLog, createKeys: Bool = true) throws {
        let keys = try identity.remotePublicKeys(create: createKeys)
        guard let manager = log.member(deviceId: managerID) else { throw RemoteRecoveryError.requiresReview }
        guard manager.status != .pending else { throw RemoteRecoveryError.enrollmentPending }
        guard manager.status == .active, manager.roles.contains("manage"),
              manager.authKey == PublicKeyData(alg: .p256, raw: keys.signing),
              manager.encKey == PublicKeyData(alg: .x25519, raw: keys.encryption) else { throw RemoteRecoveryError.requiresReview }
    }

    private func finishBackup(current: () -> Bool = { true }) async throws {
        func check() throws {
            try Task.checkCancellation()
            guard current() else { throw RemoteChannelError.staleLink }
        }
        try check()
        var keys = try dataKeys.recoveryKeys(dataAccount: accountID)
        if let pending = saved.pendingDataKey {
            let candidate = AccountDataKey(kid: pending.kid, key: pending.bytes)
            guard !keys.contains(where: { $0.kid == candidate.kid && $0 != candidate }) else {
                throw AtemIdentityError.identityChanged
            }
            keys = [candidate] + keys.filter { $0.kid != candidate.kid }
        } else if keys.isEmpty {
            guard allowNewDataKey() else { throw AtemIdentityError.invalidState }
            let new = try dataKeys.generate()
            try persist { $0.pendingDataKey = SavedKey(kid: new.kid, bytes: new.key, initializeOff: true) }
            keys = [new]
        }
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let genesis = kit.genesisHash
        let log = try await refreshedLog(genesis: genesis)
        try check()
        try requireManager(log)
        if saved.backup == nil, let committed = log.kBackup(), committed.kids == keys.map(\.kid),
           committed.recoveryKey == kit.recoveryKey {
            do {
                let envelope = try await http.backup(log: log)
                try check()
                guard try kit.openBackup(envelope) == keys.map({ AccountKey(kid: $0.kid, k: $0.key) }) else {
                    throw AtemIdentityError.identityChanged
                }
                try installPendingKey()
                return
            } catch RemoteRecoveryTransportError.recordNotFound {
                // A new Station has the signed log but not the old encrypted blob.
                // Use the normal durable backup writer with the same keys and kit.
            }
        }
        try check()
        if backup == nil {
            if let checkpoint = saved.backup {
                backup = try RemoteRecoveryBackup(checkpoint: checkpoint, accountID: accountID, genesisHash: genesis,
                    now: now(), persist: { [unowned self] bytes in try self.persist { $0.backup = bytes } })
            } else {
                backup = try RemoteRecoveryBackup(log: log, kids: keys.map(\.kid), signer: managerID,
                    persist: { [unowned self] bytes in try self.persist { $0.backup = bytes } })
            }
        }
        let operation = backup!
        for _ in 0..<128 {
            try check()
            guard !operation.storageUncertain else { throw RemoteRecoveryError.storageUncertain }
            switch operation.step {
            case .seal:
                _ = try operation.seal(keys: keys.map { AccountKey(kid: $0.kid, k: $0.key) }, signedAt: now().wallMs)
            case .sign(let body):
                // A CAS conflict may have removed this manager while confirmation was open.
                let signingLog = try operation.committedLog()
                try requireManager(signingLog)
                let signer = try await confirmed(RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID))
                try check()
                _ = try operation.sign(provider: signer, keyID: managerID)
            case .put(_, let bytes):
                let occupied = try await http.uploadBackup(genesisHash: genesis, envelopeJSON: bytes, signedEntryJSON: operation.uploadEntryJSON())
                _ = try operation.uploadReply(maxOccupied: occupied)
            case .append(let request):
                switch try await http.append(genesisHash: genesis, request: request) {
                case .stored: _ = try operation.relayStored(now: now(), signedAt: now().wallMs)
                case .conflict(let page): _ = try operation.relayConflict(head: page.head, entries: page.entries,
                    more: page.more, now: now(), signedAt: now().wallMs)
                }
            case .fetch(let after):
                let page = try await http.entries(genesisHash: genesis, after: after)
                _ = try operation.fetched(entries: page.entries, more: page.more, now: now(), signedAt: now().wallMs)
            case .done:
                try commitLog(operation.committedLog()) { $0.backup = nil }
                backup = nil
                try installPendingKey()
                return
            case .failed: throw RemoteRecoveryError.requiresReview
            }
        }
        throw RemoteRecoveryTransportError.unavailable
    }

    private func installPendingKey() throws {
        guard let pending = saved.pendingDataKey else { return }
        if pending.initializeOff != false {
            guard allowNewDataKey() else { throw AtemIdentityError.invalidState }
            try identity.initializeEncryptionOff(account: accountID)
        }
        try dataKeys.install(AccountDataKey(kid: pending.kid, key: pending.bytes), dataAccount: accountID)
        try persist { $0.pendingDataKey = nil }
    }

    /// Import never replaces an existing genesis, device ID or signing key.
    /// A successful recovery request still waits for manager approval / the host's 24-hour timer.
    func restoreAccount(kit: RemoteRecoveryKit) async throws -> String {
        try begin(); defer { busy = false }
        guard kit.accountID == accountID, saved.bootstrap == nil else { throw RemoteRecoveryError.requiresReview }
        if let existing = saved.restoreKit {
            guard try RemoteRecoveryKit(text: existing) == kit else { throw RemoteRecoveryError.invalidCheckpoint }
        } else { try persist { $0.restoreKit = kit.text() } }
        if restoreOperation == nil {
            restoreOperation = try RemoteRecoveryRestore(kit: kit, checkpoint: saved.restore,
                now: now(),
                persist: { [unowned self] bytes in try self.persist { $0.restore = bytes } })
        }
        let operation = restoreOperation!
        var entries: [String] = []
        var head = LogHead(seq: 0, hash: String(repeating: "0", count: 64))
        var finished = false
        for _ in 0..<128 {
            let page = try await http.entries(genesisHash: kit.genesisHash, after: UInt64(entries.count))
            guard !page.more || !page.entries.isEmpty else { throw RemoteRecoveryTransportError.invalidResponse }
            entries += page.entries
            head = page.head
            if !page.more { finished = true; break }
        }
        guard finished else { throw RemoteRecoveryTransportError.invalidResponse }
        let log = try MembershipLog.verify(accountId: kit.accountID, genesisHash: kit.genesisHash, entries: entries, now: now())
        guard log.head() == head, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
        let envelope = try await http.backup(log: log)
        try operation.fetched(entries: entries, envelopeJSON: envelope, now: now())
        guard case .waitingForHost(let hosts) = operation.phase else { throw RemoteRecoveryError.requiresReview }
        for host in hosts {
            do {
                let probe = try operation.beginHostProbe(hostID: host, replacementDeviceID: managerID, now: now())
                let accept = try await http.hostAccept(genesisHash: kit.genesisHash, hostID: host, initFrame: probe.frame)
                try operation.receivedHostAccept(accept, probeID: probe.id, now: now())
                _ = try operation.attempt(now: now())
                break
            } catch {
                if operation.phase == .storageUncertain { throw error }
            }
        }
        guard operation.phase == .readyToEnroll || operation.phase == .enrollmentPending || operation.phase == .published else {
            return operation.statusText
        }
        let recovered = try operation.recoveredKeys()
        try commitRestoredLog(operation.verifiedLog())
        try dataKeys.installRecovered(recovered.map { AccountDataKey(kid: $0.kid, key: $0.k) }, dataAccount: accountID)
        try identity.markRecoverySaved(signingPublicKey: identity.remotePublicKeys().signing)
        if operation.phase == .published {
            if let member = membershipLog?.member(deviceId: managerID), member.status == .active {
                return "Account restored. This device is an active member of your signed device list."
            }
            return operation.statusText
        }
        let request: AppendRequest
        if let pending = try operation.outstanding() { request = pending }
        else {
            let keys = try identity.remotePublicKeys()
            let member: [String: Any] = ["device_id": managerID, "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "p256", "pub": keys.signing.base64URLEncodedString()],
                "enc_key": ["alg": "x25519", "pub": keys.encryption.base64URLEncodedString()]]
            let json = try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: member), as: UTF8.self))
            let accepted = await confirmReplacement(kit.accountID)
            guard accepted, try identity.remotePublicKeys().signing == keys.signing,
                  try identity.remotePublicKeys().encryption == keys.encryption else { throw RemoteRecoveryError.confirmationRequired }
            request = try operation.enroll(confirmedMemberJSON: json, signedAt: now().wallMs)
        }
        switch try await http.append(genesisHash: kit.genesisHash, request: request) {
        case .stored:
            _ = try operation.relayStored(now: now())
            try commitRestoredLog(operation.verifiedLog())
        case .conflict(let page):
            _ = try operation.relayConflict(head: page.head, entries: page.entries, more: page.more, now: now())
        }
        return operation.statusText
    }

    private func commitRestoredLog(_ restored: MembershipLog) throws {
        guard let previous = membershipLog else { try commitLog(restored); return }
        let log = previous.snapshot()
        let result = try log.extend(entries: restored.entries(), now: now())
        try commitLog(log)
        guard result.stop == nil, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
    }
}

extension AstationRecoveryCoordinator {
    private struct AcceptedVerifierRoster: Codable, Equatable {
        let genesis: String
        let roster: RemoteStationVerifierRoster
    }

    struct ProcessReview: Equatable {
        let id: UUID
        let member: String
        let origin: String
        let genesis: String
        let head: LogHead
        let previous: AstationProcessRoster?
        let started: UInt64
    }

    var processReviewAvailable: Bool { confirmProcessRoster != nil }

    struct MemberProcessReview: Equatable {
        enum Status: Equatable {
            case needsReview, previousRevision, expiredService
            case reviewed(slots: Int)
        }
        let member: String
        let status: Status
    }

    /// Include every active signed-list member, even when none of its processes are online.
    func memberProcessReviews() throws -> [MemberProcessReview] {
        try memberProcessInventory(at: relayURL).map(\.review)
    }

    private func memberProcessInventory(at origin: String) throws -> [(review: MemberProcessReview, slots: [RemoteMemberVerifierSlot])] {
        guard !busy, !uncertain, let log = membershipLog, log.frozen() == nil,
              log.accountId() == accountID else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        let head = log.head(), genesis = log.genesisHash(), wall = now().wallMs
        let rosters = saved.processRosters?[origin] ?? [:]
        return try log.members().filter {
            $0.status == .active && (origin == relayURL || rosters[$0.deviceId]?.genesis == genesis)
        }.map { member in
            let id = member.deviceId
            let status: MemberProcessReview.Status
            var slots: [RemoteMemberVerifierSlot] = []
            if member.kind == "service" && (member.expiresAt ?? 0) <= wall {
                status = .expiredService
            } else if let roster = rosters[id] {
                guard roster.member == id, roster.origin == origin, roster.genesis == genesis,
                      roster.sequence > 0, roster.sequence <= head.seq else { throw RemoteRecoveryError.invalidCheckpoint }
                if roster.sequence == head.seq {
                    guard roster.headHash == head.hash else { throw RemoteRecoveryError.invalidCheckpoint }
                    slots = try roster.slots()
                    status = .reviewed(slots: slots.count)
                } else { status = .previousRevision }
            } else { status = .needsReview }
            return (review: MemberProcessReview(member: id, status: status), slots: slots)
        }.sorted { $0.review.member < $1.review.member }
    }

    func reviewedProcessSlots(member: String, log: MembershipLog, stationOrigin: String? = nil) throws -> [RemoteMemberVerifierSlot] {
        let origin = stationOrigin ?? relayURL
        guard !uncertain, let roster = saved.processRosters?[origin]?[member], roster.member == member,
              roster.origin == origin, log.accountId() == accountID, log.frozen() == nil,
              roster.genesis == log.genesisHash(), roster.sequence == log.head().seq, roster.headHash == log.head().hash,
              log.head() == membershipLog?.head(), let target = log.member(deviceId: member), target.status == .active,
              target.kind == "native" || (target.kind == "service" && (target.expiresAt ?? 0) > now().wallMs)
        else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        return try roster.slots()
    }

    func prepareProcessReview(member: String, current: () -> Bool) async throws -> ProcessReview {
        try begin(); defer { busy = false }
        processReview = nil
        guard processReviewAvailable, current(), !Task.isCancelled, PortalIntegrationRecord.validOrigin(relayURL),
              let kit = try currentKit() else { throw RemoteRecoveryError.requiresReview }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log, createKeys: false)
        guard current(), !Task.isCancelled, log.frozen() == nil,
              let target = log.member(deviceId: member), target.status == .active,
              ["native", "service"].contains(target.kind) else { throw RemoteRecoveryError.requiresReview }
        let previous = saved.processRosters?[relayURL]?[member]
        if let previous {
            guard previous.member == member, previous.genesis == kit.genesisHash, previous.origin == relayURL,
                  previous.sequence <= UInt64(log.entries().count), previous.sequence > 0,
                  try signedObjectInfo(json: log.entries()[Int(previous.sequence - 1)]).entryHash == previous.headHash,
                  !previous.lines.isEmpty else { throw RemoteRecoveryError.invalidCheckpoint }
            _ = try previous.slots()
        }
        let review = ProcessReview(id: UUID(), member: member, origin: relayURL, genesis: kit.genesisHash,
            head: log.head(), previous: previous, started: verifierTime())
        processReview = review
        return review
    }

    func acceptProcessReview(_ review: ProcessReview, lines: [String], current: () -> Bool) async throws {
        try begin(); defer { busy = false }
        guard let confirmProcessRoster, processReview == review else { throw RemoteRecoveryError.requiresReview }
        processReview = nil
        let slots = try AstationProcessRoster.rows(member: review.member, text: lines.joined(separator: "\n"))
        guard lines == slots.map({ $0.slot + " " + $0.process }) else { throw RemoteVerifierGateError.invalidRoster }
        func check(_ log: MembershipLog) throws {
            let tick = verifierTime()
            guard current(), !Task.isCancelled, review.origin == relayURL, log.frozen() == nil,
                  log.genesisHash() == review.genesis, log.head() == review.head, review.started <= tick,
                  tick - review.started < 300_000, saved.processRosters?[relayURL]?[review.member] == review.previous
            else { throw RemoteRecoveryError.requiresReview }
            try requireManager(log, createKeys: false)
        }
        guard current(), !Task.isCancelled else { throw RemoteRecoveryError.requiresReview }
        try check(try await refreshedLog(genesis: review.genesis))
        var rosters = saved.processRosters ?? [:]
        var candidate = AstationProcessRoster(origin: relayURL, member: review.member,
            genesis: review.genesis, sequence: review.head.seq, headHash: review.head.hash, lines: lines)
        if review.member == managerID {
            let local = slots.filter { $0.process == verifierReportProcess() }
            if local.count == 1 { candidate.localReporterSlot = local[0].slot }
        }
        if let previous = review.previous { candidate.retainDisplacedSlots(from: previous) }
        rosters[relayURL, default: [:]][review.member] = candidate
        let lists = rosters.values.flatMap(\.values)
        guard rosters.count <= 64, lists.reduce(0, { $0 + $1.lines.count }) <= 4096,
              lists.reduce(0, { $0 + ($1.earlier?.count ?? 0) }) <= 4096 else { throw RemoteVerifierGateError.invalidRoster }
        guard await confirmProcessRoster() else { throw RemoteRecoveryError.confirmationRequired }
        let confirmedAt = verifierTime()
        let log = try await refreshedLog(genesis: review.genesis)
        try check(log)
        try requireDurableRecoveryCheckpoint()
        var roots = saved.verifierHistoryRoots ?? [:]
        if let genesis = roots[relayURL] {
            guard genesis == review.genesis else { throw RemoteRecoveryError.invalidCheckpoint }
        } else {
            // An interrupted first review may have already created this journal.
            // The shared opener preserves any existing conflict and downgrade history.
            _ = try verifierHistory(log, relayURL, true)
            roots[relayURL] = review.genesis
        }
        let finished = verifierTime()
        guard finished >= confirmedAt, finished - confirmedAt < 30_000 else { throw RemoteRecoveryError.requiresReview }
        try persist { $0.version = 9; $0.processRosters = rosters; $0.verifierHistoryRoots = roots }
        verifierReportGeneration = UUID()
        deliveredVerifierChallenges.removeAll()
        do { try requireDurableRecoveryCheckpoint() }
        catch { uncertain = true; throw error }
        onLocalVerifierSlotChange?()
    }

    var localVerifierOrigins: [String] {
        guard !uncertain, let log = membershipLog, log.frozen() == nil else { return [] }
        let genesis = log.genesisHash(), head = log.head()
        return (saved.processRosters ?? [:]).compactMap { origin, members in
            guard let roster = members[managerID], roster.member == managerID, roster.origin == origin,
                  roster.localReporterSlot != nil, roster.genesis == genesis, roster.sequence == head.seq,
                  roster.headHash == head.hash, PortalIntegrationRecord.validOrigin(origin) else { return nil }
            return origin
        }.sorted()
    }

    /// These counts describe this inspection. No live connection or signing
    /// capability escapes the check, including on cancellation or an error.
    struct StationProcessCheck {
        let origin: String
        let serverCount: Int?
        let unconfirmedServers: [String]
        let pendingMembers: [String]
        let slots: Int
        var unanswered: [RemoteMemberVerifierSlot] = []
    }

    struct ProcessCheck {
        var stations: [StationProcessCheck] = []
        var hostCount: Int?
        var unconfirmedHosts: [String] = []
    }

    /// One unsigned approval owns these channel generations until its key is used.
    /// An exact retry of a previously signed append never invokes this check.
    func serviceHostVerifier(for approval: RemoteServiceApproval, current: @escaping () -> Bool,
        channels: @escaping (RemoteVerifierSigningGate, VerifierRequirement) -> [String: Set<UUID>]
    ) throws -> (MembershipLog) throws -> Void {
        let requirement = try membershipRequiredVersion(bodyJson: approval.bodyJSON)
        var checked: (roster: RemoteStationVerifierRoster, gate: RemoteVerifierSigningGate, links: [String: Set<UUID>])?
        return { [weak self] log in
            guard let requirement else { return }
            guard let self, current(), !Task.isCancelled, !self.uncertain,
                  log.accountId() == self.accountID, log.genesisHash() == approval.genesisHash,
                  log.head() == self.membershipLog?.head(), self.membershipLog?.frozen() == nil
            else { throw RemoteVerifierGateError.staleMembership }
            try self.requireDurableRecoveryCheckpoint()
            guard let roster = try self.acceptedStationVerifierRoster() else { throw RemoteVerifierGateError.invalidRoster }
            if let checked, roster != checked.roster { throw RemoteVerifierGateError.staleMembership }
            let gate = try checked?.gate ?? RemoteVerifierSigningGate(log: log, station: roster, now: self.verifierTime)
            try gate.requireMembership(log)
            let live = channels(gate, requirement)
            guard gate.enrolledHostIDs.allSatisfy({ live[$0]?.isEmpty == false }) else {
                throw RemoteVerifierGateError.unconfirmedVerifiers
            }
            if let checked, checked.links != live { throw RemoteVerifierGateError.staleConnection }
            checked = (roster, gate, live)
        }
    }

    func serviceStationVerifier(for approval: RemoteServiceApproval, current: @escaping @MainActor @Sendable () -> Bool,
        transport: @escaping (@escaping @MainActor @Sendable () -> Bool) throws -> any RemoteManagedServiceVerifierTransport
    ) -> (MembershipLog) async throws -> ((MembershipLog) throws -> Void) {
        var sources: [RemoteManagedServiceVerifierEvidence] = []
        var reviewedRoster: RemoteStationVerifierRoster?
        func checkContext(_ log: MembershipLog) throws {
            guard current(), !Task.isCancelled, !uncertain, approval.stationOrigin == relayURL,
                  log.accountId() == accountID, log.genesisHash() == approval.genesisHash,
                  let latest = membershipLog, latest.head() == log.head(), latest.frozen() == nil,
                  let reviewedRoster, try acceptedStationVerifierRoster() == reviewedRoster else {
                throw RemoteVerifierGateError.staleMembership
            }
            try requireDurableRecoveryCheckpoint()
        }
        return { log in
            if sources.isEmpty {
                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: approval.bodyJSON, keyID: self.managerID)
                let service = try RemoteServiceReview(approval: approval).serviceID
                guard let roster = try self.acceptedStationVerifierRoster() else { throw RemoteVerifierGateError.invalidRoster }
                reviewedRoster = roster
                try checkContext(log)
                let existing = log.members().filter { $0.kind == "service" && $0.status == .active }.map(\.deviceId).sorted()
                // The proposed key binds every page to the same enrollment. Separate gates
                // preserve each page's original deadline, even when later pages are fresh.
                sources = try stride(from: 0, to: max(1, existing.count), by: 63).map { start in
                    let ids = (existing[start..<min(start + 63, existing.count)] + [service]).sorted()
                    let gate = try RemoteVerifierSigningGate(log: log, station: roster, prospectiveServiceID: service,
                        wall: { self.now().wallMs }, now: self.verifierTime)
                    return try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: log,
                        memberIDs: ids, prospectiveRequest: request)
                }
            }
            try checkContext(log)
            let carrier = try transport(current)
            var generations: [UInt64]?
            for source in sources {
                let reported = try await source.refreshEnrollment(using: carrier) { try checkContext(log) }
                guard generations == nil || generations == reported else { throw RemoteVerifierGateError.staleConnection }
                generations = reported
            }
            return { latest in
                try checkContext(latest)
                for source in sources { try source.requireEnrollment(log: latest) }
            }
        }
    }

    func serviceAdditionalStationVerifier(for approval: RemoteServiceApproval, current: @escaping @MainActor @Sendable () -> Bool,
        transport: @escaping (String, @escaping @MainActor @Sendable () -> Bool) throws -> any RemoteStationVerifierTransport
    ) -> (MembershipLog) async throws -> ((MembershipLog) throws -> Void) {
        var sources: [String: RemoteStationVerifierEvidence] = [:]
        var reviewed: [String: RemoteStationVerifierRoster]?
        func rosters(_ log: MembershipLog) throws -> [String: RemoteStationVerifierRoster] {
            guard current(), !Task.isCancelled, !uncertain, relayURL == approval.stationOrigin,
                  log.accountId() == accountID, log.genesisHash() == approval.genesisHash, log.frozen() == nil,
                  membershipLog?.head() == log.head(), membershipLog?.frozen() == nil else {
                throw RemoteVerifierGateError.staleMembership
            }
            try requireDurableRecoveryCheckpoint()
            var result: [String: RemoteStationVerifierRoster] = [:]
            let origins = try verifierStationOrigins(log).subtracting([relayURL])
            for origin in origins {
                guard let entry = saved.verifierRosters?[origin], entry.genesis == approval.genesisHash,
                      entry.roster.origin == origin else { throw RemoteVerifierGateError.invalidRoster }
                result[origin] = entry.roster
            }
            return result
        }
        return { log in
            let required = try rosters(log)
            guard reviewed == nil || reviewed == required,
                  let requirement = try membershipRequiredVersion(bodyJson: approval.bodyJSON)
            else { throw RemoteVerifierGateError.staleMembership }
            reviewed = required
            for (origin, roster) in required.sorted(by: { $0.key < $1.key }) {
                let source: RemoteStationVerifierEvidence
                if let existing = sources[origin] { source = existing }
                else {
                    let gate = try RemoteVerifierSigningGate(log: log, station: roster, now: self.verifierTime)
                    source = try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: log)
                    sources[origin] = source
                }
                try await source.refreshApproval(using: try transport(origin, current), requirement: requirement) {
                    guard try rosters(log) == required else { throw RemoteVerifierGateError.staleMembership }
                }
            }
            let check: (MembershipLog) throws -> Void = { latest in
                guard try rosters(latest) == required else { throw RemoteVerifierGateError.staleMembership }
                for source in sources.values { try source.requireApproval(log: latest) }
            }
            try check(log)
            return check
        }
    }

    private func reviewedProcessOrigins(genesis: String) -> Set<String> {
        Set((saved.processRosters ?? [:]).compactMap { origin, reviews in
            reviews.values.contains(where: { $0.genesis == genesis }) ? origin : nil
        })
    }

    private func verifierStationOrigins(_ log: MembershipLog) throws -> Set<String> {
        let origins = try retainedControlOrigins(log).union(reviewedProcessOrigins(genesis: log.genesisHash()))
            .union(controlStationTransports(log).keys).union([relayURL])
        guard origins.count <= 64, origins.allSatisfy(PortalIntegrationRecord.validOrigin) else {
            throw RemoteVerifierGateError.invalidRoster
        }
        return origins
    }

    func serviceMemberProcessVerifier(for approval: RemoteServiceApproval,
        current: @escaping @MainActor @Sendable () -> Bool,
        transport: @escaping (String, @escaping @MainActor @Sendable () -> Bool) throws -> any RemoteVerifierReportTransport,
        waitForReport: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }
    ) -> (MembershipLog) async throws -> ((MembershipLog) throws -> Void) {
        let generation = verifierReportGeneration
        let rosters = saved.verifierRosters
        var retired = false
        var sources: [(origin: String, poller: RemoteMemberVerifierPoller, evidence: RemoteMemberVerifierEvidence,
                       slots: [RemoteMemberVerifierSlot])] = []
        return { log in
            let head = log.head()
            guard let requirement = try membershipRequiredVersion(bodyJson: approval.bodyJSON) else {
                throw RemoteVerifierGateError.invalidRoster
            }
            let active: @MainActor @Sendable () -> Bool = {
                current() && !Task.isCancelled && !retired && !self.uncertain && self.verifierReportGeneration == generation &&
                    self.membershipLog?.head() == head && self.membershipLog?.frozen() == nil &&
                    self.saved.verifierRosters == rosters
            }
            @MainActor func membership() throws -> MembershipLog {
                guard active(), self.relayURL == approval.stationOrigin, let latest = self.membershipLog,
                      latest.genesisHash() == approval.genesisHash else { throw RemoteVerifierGateError.staleMembership }
                try self.requireDurableRecoveryCheckpoint()
                try self.identity.requireVerifierManager(log: latest, memberID: self.managerID)
                return latest
            }
            _ = try membership()
            let first = sources.isEmpty
            do {
                if first {
                    let reviews = self.saved.processRosters ?? [:]
                    let origins = self.reviewedProcessOrigins(genesis: approval.genesisHash).union([self.relayURL])
                    let members = log.members().filter { $0.status == .active }
                    for origin in origins.sorted() {
                        let required = members.filter { member in
                            (origin == self.relayURL && member.kind == "native") ||
                                reviews[origin]?[member.deviceId] != nil
                        }
                        if required.isEmpty && origin != self.relayURL { continue }
                        let slots = try required.flatMap { try self.reviewedProcessSlots(member: $0.deviceId, log: log, stationOrigin: origin) }
                        guard !slots.isEmpty, let accepted = self.saved.verifierRosters?[origin],
                              accepted.genesis == approval.genesisHash, accepted.roster.origin == origin,
                              self.saved.verifierHistoryRoots?[origin] == approval.genesisHash else {
                            throw RemoteVerifierGateError.invalidRoster
                        }
                        let gate = try RemoteVerifierSigningGate(log: log, station: accepted.roster, now: self.verifierTime)
                        let journal = try self.verifierHistory(log, origin, false)
                        let evidence = try RemoteMemberVerifierEvidence(gate: gate, log: log, origin: origin,
                            slots: slots, journal: journal, current: active, now: self.verifierTime)
                        let poller = RemoteMemberVerifierPoller(evidence: evidence, transport: try transport(origin, active),
                            membership: membership, wall: { self.now().wallMs }, now: self.verifierTime)
                        sources.append((origin, poller, evidence, slots))
                    }
                    for source in sources {
                        try await source.poller.pollSlots(source.slots, issue: true)
                        try await self.answerLocalVerifierChallenges(at: source.origin, current: active) { try transport(source.origin, $0) }
                    }
                    try await waitForReport()
                }
                for source in sources { try await source.poller.pollSlots(source.slots, issue: false) }
                let check: (MembershipLog) throws -> Void = { latest in
                    let currentLog = try membership()
                    guard !sources.isEmpty, latest.head() == currentLog.head() else { throw RemoteVerifierGateError.staleMembership }
                    for source in sources {
                        try source.evidence.requireSupport(requirement, log: latest, wallMs: self.now().wallMs)
                    }
                }
                try check(log)
                return check
            } catch {
                retired = true
                for source in sources { source.poller.retire() }
                throw error
            }
        }
    }

    func checkMemberProcesses(current: @escaping @MainActor @Sendable () -> Bool,
        transport: (String, @escaping @MainActor @Sendable () -> Bool) throws -> any RemoteVerifierReportTransport & RemoteStationVerifierTransport,
        reportingHosts: (RemoteVerifierSigningGate) -> Set<String> = { _ in [] },
        waitForReport: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) },
        progress: (String, Int, Int) -> Void) async throws -> ProcessCheck {
        guard current(), !Task.isCancelled, !busy, !uncertain, let log = membershipLog?.snapshot(),
              log.accountId() == accountID else { throw RemoteVerifierGateError.invalidRoster }
        let origins = try verifierStationOrigins(log), rosters = saved.verifierRosters
        let head = log.head(), generation = verifierReportGeneration
        let active: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return current() && !Task.isCancelled && !self.busy && !self.uncertain &&
                self.verifierReportGeneration == generation && self.membershipLog?.head() == head &&
                self.membershipLog?.frozen() == nil && self.saved.verifierRosters == rosters &&
                (try? self.verifierStationOrigins(log)) == origins
        }
        let membership: () throws -> MembershipLog = {
            guard active(), let latest = self.membershipLog else { throw RemoteVerifierGateError.staleConnection }
            try self.requireDurableRecoveryCheckpoint()
            try self.identity.requireVerifierManager(log: latest, memberID: self.managerID)
            return latest
        }
        var result = ProcessCheck()
        for origin in origins.sorted() {
            _ = try membership()
            let inventory = try memberProcessInventory(at: origin)
            let slots = inventory.flatMap(\.slots)
            let pending = inventory.filter { $0.slots.isEmpty }.map(\.review.member)
            guard let entry = rosters?[origin], entry.genesis == log.genesisHash() else {
                result.stations.append(StationProcessCheck(origin: origin, serverCount: nil, unconfirmedServers: [],
                    pendingMembers: pending, slots: slots.count, unanswered: slots))
                continue
            }
            guard entry.roster.origin == origin else { throw RemoteRecoveryError.invalidCheckpoint }
            progress(origin, 0, slots.count)
            let gate = try RemoteVerifierSigningGate(log: log, station: entry.roster, now: verifierTime)
            let carrier = try transport(origin, active)
            let servers = try RemoteStationVerifierEvidence(gate: gate, roster: entry.roster, log: log)
            defer { servers.disconnect() }
            let missing = try await servers.inspect(using: carrier) { _ = try membership() }
            var station = StationProcessCheck(origin: origin, serverCount: entry.roster.replicas.count,
                unconfirmedServers: missing, pendingMembers: pending, slots: slots.count)
            if !slots.isEmpty {
                guard saved.verifierHistoryRoots?[origin] == log.genesisHash() else { throw RemoteRecoveryError.requiresReview }
                let evidence = try RemoteMemberVerifierEvidence(gate: gate, log: log, origin: origin, slots: slots,
                    journal: verifierHistory(log, origin, false), current: active, now: verifierTime)
                let poller = RemoteMemberVerifierPoller(evidence: evidence, transport: carrier,
                    membership: membership, wall: { self.now().wallMs }, now: verifierTime)
                defer { poller.retire() }
                station.unanswered = try await inspectSlots(slots, poller: poller, waitForReport: waitForReport) { end in
                    _ = try membership()
                    progress(origin, end, slots.count)
                }
            }
            result.stations.append(station)
            if result.hostCount == nil {
                let hosts = gate.enrolledHostIDs, reported = reportingHosts(gate)
                result.hostCount = hosts.count
                result.unconfirmedHosts = hosts.filter { !reported.contains($0) }
            }
        }
        _ = try membership()
        return result
    }

    private func inspectSlots(_ slots: [RemoteMemberVerifierSlot], poller: RemoteMemberVerifierPoller,
        waitForReport: @escaping @Sendable () async throws -> Void, progress: (Int) throws -> Void
    ) async throws -> [RemoteMemberVerifierSlot] {
        var missing: [RemoteMemberVerifierSlot] = []
        // Bound issuance and give the four-second Mac responder time to answer.
        for start in stride(from: 0, to: slots.count, by: 8) {
            let end = min(start + 8, slots.count)
            try await withThrowingTaskGroup(of: (RemoteMemberVerifierSlot, Bool).self) { group in
                for slot in slots[start..<end] {
                    group.addTask {
                        _ = try await poller.poll(slot)
                        try await waitForReport()
                        return (slot, try await poller.readIssuedChallenge(slot))
                    }
                }
                for try await (slot, answered) in group {
                    if !answered { missing.append(slot) }
                }
            }
            try progress(end)
        }
        return missing
    }

    func answerVerifierChallenges(at origin: String, current: @escaping @MainActor @Sendable () -> Bool,
        transport: (@escaping @MainActor @Sendable () -> Bool) throws -> any RemoteVerifierReportTransport) async throws {
        try await answerLocalVerifierChallenges(at: origin, current: { [weak self] in self?.busy == false && current() }, transport: transport)
    }

    private func answerLocalVerifierChallenges(at origin: String, current: @escaping @MainActor @Sendable () -> Bool,
        transport: (@escaping @MainActor @Sendable () -> Bool) throws -> any RemoteVerifierReportTransport) async throws {
        guard current(), !Task.isCancelled, !uncertain,
              let roster = saved.processRosters?[origin]?[managerID], let slot = roster.localReporterSlot,
              let log = membershipLog?.snapshot(), log.frozen() == nil,
              roster.genesis == log.genesisHash(), roster.sequence == log.head().seq, roster.headHash == log.head().hash,
              try reviewedProcessSlots(member: managerID, log: log, stationOrigin: origin).contains(where: { $0.slot == slot })
        else { return }
        let anchor = try RemoteVerifierReportAnchor(log: log)
        let head = log.head(), generation = verifierReportGeneration
        let active: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return current() && !Task.isCancelled && !self.uncertain &&
                self.verifierReportGeneration == generation && self.membershipLog?.head() == head &&
                self.membershipLog?.frozen() == nil
        }
        let station = try transport(active)
        let challenges = try await station.verifierChallenges(genesisHash: anchor.genesisHash,
            signer: "member:" + managerID, slot: slot, expected: head)
        guard active(), challenges.count <= 16 else { throw RemoteChannelError.staleLink }
        deliveredVerifierChallenges[origin, default: []].formIntersection(challenges)
        for challenge in challenges where deliveredVerifierChallenges[origin]?.contains(challenge) != true {
            guard active() else { throw RemoteChannelError.staleLink }
            try requireDurableRecoveryCheckpoint()
            // An inbox entry can expire while an earlier entry is being answered.
            let wall = now().wallMs
            let parsed = try parseVerifierReportChallenge(challengeJson: challenge)
            guard wall < parsed.expiresAt else { continue }
            let report = try identity.verifierReport(log: log, anchor: anchor, memberID: managerID,
                challengeJSON: challenge, slot: slot, origin: origin, wallMs: wall, current: active)
            let receipt = try await station.publishVerifierReport(genesisHash: anchor.genesisHash,
                challengeJSON: challenge, expected: head, reportJSON: report)
            guard active() else { throw RemoteChannelError.staleLink }
            // Station may have kept an earlier valid signature for this same body.
            let body = try signedObjectInfo(json: report).bodyJcs
            let receivedAt = now().wallMs
            guard receipt.reports.contains(where: { returned in
                guard let proof = try? verifyVerifierReport(log: log, reportJson: returned,
                    expectedChallengeJson: challenge, nowMs: receivedAt), proof.atHead else { return false }
                return (try? signedObjectInfo(json: returned).bodyJcs) == body
            })
            else { throw RemoteRecoveryTransportError.invalidResponse }
            deliveredVerifierChallenges[origin, default: []].insert(challenge)
        }
    }

    struct VerifierRosterReview: Equatable {
        let id: UUID
        let account: String
        let genesis: String
        let head: LogHead
        let previous: RemoteStationVerifierRoster?
        let candidate: RemoteStationVerifierRoster
        let validBefore: UInt64

        var removed: [String] { (previous?.replicas ?? []).filter { !candidate.replicas.contains($0) } }
    }

    var verifierRosterReviewAvailable: Bool { confirmVerifierRoster != nil && http is RemoteStationVerifierTransport }

    func acceptedStationVerifierRoster() throws -> RemoteStationVerifierRoster? {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        guard let genesis = try currentKit()?.genesisHash,
              let accepted = saved.verifierRosters?[relayURL], accepted.genesis == genesis else { return nil }
        guard accepted.roster.origin == relayURL else { throw RemoteRecoveryError.invalidCheckpoint }
        return accepted.roster
    }

    func prepareStationVerifierRoster(current: () -> Bool) async throws -> VerifierRosterReview {
        try begin(); defer { busy = false }
        guard verifierRosterReviewAvailable, let transport = http as? RemoteStationVerifierTransport,
              current(), !Task.isCancelled, let kit = try currentKit() else { throw RemoteChannelError.staleLink }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        let snapshot = try await transport.stationVerifiers(genesisHash: kit.genesisHash)
        guard current(), !Task.isCancelled, log.frozen() == nil,
              snapshot.accountID == accountID, snapshot.genesisHash == kit.genesisHash,
              snapshot.head == log.head(), snapshot.roster.origin == relayURL else { throw RemoteRecoveryError.requiresReview }
        let previous = try acceptedStationVerifierRoster()
        guard previous != nil || (saved.verifierRosters?.count ?? 0) < 64 else { throw RemoteRecoveryError.requiresReview }
        if let previous {
            guard snapshot.roster.generation >= previous.generation,
                  snapshot.roster.generation != previous.generation || snapshot.roster == previous else {
                throw RemoteRecoveryError.requiresReview
            }
        }
        let deadline = verifierTime().addingReportingOverflow(300_000)
        guard !deadline.overflow else { throw RemoteRecoveryError.requiresReview }
        let review = VerifierRosterReview(id: UUID(), account: accountID, genesis: kit.genesisHash, head: log.head(),
            previous: previous, candidate: snapshot.roster,
            validBefore: deadline.partialValue)
        verifierRosterReview = review
        return review
    }

    func acceptStationVerifierRoster(_ review: VerifierRosterReview, current: () -> Bool) async throws {
        try begin(); defer { busy = false }
        guard let confirmVerifierRoster, let transport = http as? RemoteStationVerifierTransport else {
            throw RemoteRecoveryError.requiresReview
        }
        func check(_ log: MembershipLog) throws {
            guard current(), !Task.isCancelled, verifierRosterReview == review,
                  review.account == accountID, review.candidate.origin == relayURL,
                  review.genesis == log.genesisHash(), review.head == log.head(), log.frozen() == nil,
                  review.previous == (try acceptedStationVerifierRoster()),
                  verifierTime() < review.validBefore else {
                throw RemoteRecoveryError.requiresReview
            }
            try requireManager(log)
        }
        let before = try await refreshedLog(genesis: review.genesis)
        try check(before)
        guard await confirmVerifierRoster(review) else { throw RemoteRecoveryError.confirmationRequired }
        let confirmedAt = verifierTime()
        let log = try await refreshedLog(genesis: review.genesis)
        try check(log)
        let snapshot = try await transport.stationVerifiers(genesisHash: review.genesis)
        try check(log)
        let finishedAt = verifierTime()
        guard snapshot.roster == review.candidate, snapshot.accountID == accountID,
              snapshot.genesisHash == review.genesis, snapshot.head == review.head,
              finishedAt >= confirmedAt, finishedAt - confirmedAt < 30_000 else {
            throw RemoteRecoveryError.requiresReview
        }
        try persist { value in
            var rosters = value.verifierRosters ?? [:]
            rosters[relayURL] = AcceptedVerifierRoster(genesis: review.genesis, roster: review.candidate)
            value.verifierRosters = rosters
        }
        verifierRosterReview = nil
    }

    var hostSenderControlsAvailable: Bool { authorizeNewMembership != nil && delegatedControlsAvailable }

    func pendingHostSenderReview() throws -> RemoteHostSenderReview? {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        return try saved.hostSenderReview.map { try JSONDecoder().decode(RemoteHostSenderReview.self, from: $0) }
    }

    func hostSenderMembership() async throws -> MembershipLog {
        try begin(hostSender: true); defer { busy = false }
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        return log.snapshot()
    }

    func prepareHostSender(hostID: String, operation: RemoteHostSenderReview.Operation,
        current: () -> Bool) async throws -> RemoteHostSenderReview {
        try begin(hostSender: true); defer { busy = false }
        guard hostSenderControlsAvailable, let authorizeNewMembership else { throw AstationDelegatedControlError.notVerified }
        guard current(), !Task.isCancelled, let kit = try currentKit() else { throw RemoteChannelError.staleLink }
        if let pending = try pendingHostSenderReview() {
            guard pending.hostID == hostID, pending.operation == operation else { throw RemoteRecoveryError.requiresReview }
            return pending
        }
        guard saved.publication == nil, saved.restore == nil else { throw RemoteRecoveryError.busy }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        try requireDelegatedControl(log)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        let review = try RemoteHostSenderReview(stationOrigin: relayURL, log: log, managerID: managerID,
            hostID: hostID, operation: operation, now: now())
        try authorizeNewMembership(review.signingRequest(managerID: managerID), log)
        let context = try review.checkpoint()
        let publisher = RemoteMembershipPublication(log: log, persist: { [unowned self] bytes in
            try self.persist { $0.publication = bytes; $0.hostSenderReview = context }
        })
        try review.prepare(publication: publisher, managerID: managerID, now: now())
        publication = publisher
        return review
    }

    /// The saved entry owns retries. A fresh confirmation is required only before its first signature.
    func commitHostSender(_ review: RemoteHostSenderReview, current: () -> Bool) async throws {
        try begin(hostSender: true); defer { busy = false }
        guard hostSenderControlsAvailable, let authorizeNewMembership else { throw AstationDelegatedControlError.notVerified }
        guard current(), !Task.isCancelled, review.stationOrigin == relayURL,
              saved.hostSenderReview == (try review.checkpoint()), let checkpoint = saved.publication,
              let kit = try currentKit(), kit.genesisHash == review.genesisHash else { throw RemoteChannelError.staleLink }
        if publication == nil {
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: kit.genesisHash, now: now(), persist: { [unowned self] bytes in
                    try self.persist { $0.publication = bytes }
                })
        }
        guard let publisher = publication, publisher.operationContext == (try review.checkpoint()) else {
            throw RemoteRecoveryError.requiresReview
        }
        var log = try await refreshedLog(genesis: kit.genesisHash)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        if try reconcileHostSender(review, publisher: publisher, log: log) { return }
        try requireManager(log)
        try requireDelegatedControl(log)
        let append: AppendRequest
        if let retry = try publisher.outstanding() { append = retry }
        else {
            let request = try review.signingRequest(managerID: managerID)
            try authorizeNewMembership(request, log)
            try review.validate(log: log, managerID: managerID, now: now())
            guard await confirmOwner(request), current(), !Task.isCancelled else { throw RemoteRecoveryError.confirmationRequired }
            let stamp = Self.clock().monoMs
            log = try await refreshedLog(genesis: kit.genesisHash)
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            try requireManager(log)
            try requireDelegatedControl(log)
            guard log.head() == publisher.head else { throw RemoteRecoveryError.requiresReview }
            try authorizeNewMembership(request, log)
            let snapshot = log.snapshot()
            let provider = AstationMembershipKeyProvider(identity: identity, keyID: managerID,
                publicKey: try identity.remotePublicKeys().signing,
                authorizeNewMembership: { request in try authorizeNewMembership(request, snapshot) })
            append = try review.sign(publication: publisher, provider: provider, managerID: managerID,
                validationClock: now(), confirmedAt: stamp, now: { Self.clock().monoMs }, current: current)
        }
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        switch try await http.append(genesisHash: kit.genesisHash, request: append) {
        case .stored:
            guard case .committed = try publisher.relayStored(now: now()) else { throw RemoteRecoveryError.requiresReview }
            try commitLog(publisher.committedLog()) { $0.publication = nil; $0.hostSenderReview = nil }
            publication = nil
        case .conflict:
            log = try await refreshedLog(genesis: kit.genesisHash)
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            if try reconcileHostSender(review, publisher: publisher, log: log) { return }
            throw RemoteRecoveryError.requiresReview
        }
    }

    /// A verified chain either proves our exact entry stored or proves its old CAS can no longer win.
    /// Keep a losing signed publication as evidence, and never silently re-sign it at the new head.
    private func reconcileHostSender(_ review: RemoteHostSenderReview, publisher: RemoteMembershipPublication,
        log: MembershipLog) throws -> Bool {
        if try log.entries().contains(where: { try signedObjectInfo(json: $0).bodyJcs == review.bodyJSON }) {
            try commitLog(log) { $0.publication = nil; $0.hostSenderReview = nil }
            publication = nil
            return true
        }
        guard log.head() != publisher.head else { return false }
        guard log.head().seq > publisher.head.seq,
              (saved.supersededHostSenderPublications?.count ?? 0) < 16,
              let checkpoint = saved.publication else { throw RemoteRecoveryError.requiresReview }
        let entries = log.entriesAfter(seq: publisher.head.seq)
        _ = try publisher.relayConflict(head: log.head(), entries: entries, more: false, now: now())
        try commitLog(log) {
            $0.supersededHostSenderPublications = ($0.supersededHostSenderPublications ?? []) + [checkpoint]
            $0.publication = nil; $0.hostSenderReview = nil
        }
        publication = nil
        // Concurrent Revoke/Readmit is already done only when it has the reviewed effect. A revoke
        // with interruption cannot be satisfied by another manager's noninterrupting revoke.
        switch (review.operation, log.hostSenderState(hostId: review.hostID)) {
        case (.revoke(interruptRunning: false), .revoked), (.readmit, .authorized): return true
        default: throw RemoteRecoveryError.requiresReview
        }
    }

    func cancelUnsignedHostSender(_ review: RemoteHostSenderReview) throws {
        try begin(hostSender: true); defer { busy = false }
        guard saved.hostSenderReview == (try review.checkpoint()), let checkpoint = saved.publication else {
            throw RemoteRecoveryError.requiresReview
        }
        if publication == nil {
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: review.genesisHash, now: now(), persist: { [unowned self] bytes in
                    try self.persist { $0.publication = bytes }
                })
        }
        guard try publication?.outstanding() == nil else { throw RemoteRecoveryError.requiresReview }
        try persist { $0.publication = nil; $0.hostSenderReview = nil }
        publication = nil
    }
}

extension AstationRecoveryCoordinator {
    struct HostInterruptReview: Equatable {
        let stationOrigin: String
        let body: ControlRecordBody
        let request: SignRequest
        var additionalStationOrigins: [String] = []
        var hostID: String { String(body.principal.dropFirst(5)) }
        var recordID: String { body.recordId }
    }

    struct ServiceControlReview {
        let integrationID: String
        let integrationName: String
        let issuer: String
        let ownerAccount: String
        let stationOrigin: String
        let recordID: String
        let body: ControlRecordBody
        let request: SignRequest
    }

    // Production supplies no authorization until the real delegated joint checks pass.
    var delegatedControlsAvailable: Bool { authorizeDelegatedControl != nil }

    func localControlActivity(stationOrigin: String? = nil) throws -> [RemoteControlActivity] {
        guard !busy, !uncertain, let log = membershipLog else { throw RemoteRecoveryError.busy }
        return try controls(stationOrigin: stationOrigin).activity(log: log)
    }

    func exportControlRecoveryEvidence(stationOrigin: String? = nil, current: () -> Bool) throws -> String {
        guard !busy, !uncertain, current() else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        // Reading retained public evidence needs neither network access nor new
        // signing authority. Removed managers' originals must remain exportable.
        return try controls(stationOrigin: stationOrigin).recoveryEvidenceJSON(authorJournal: readControlJournal)
    }

    private func requireDurableRecoveryCheckpoint() throws {
        guard let checkpoint = try store.read(), checkpoint.count <= 8_388_608 else {
            throw RemoteRecoveryError.notCommitted
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(PropertyListDecoder().decode(Saved.self, from: checkpoint)) == encoder.encode(saved) else {
            uncertain = true
            throw RemoteRecoveryError.storageUncertain
        }
    }

    var controlRecoveryAvailable: Bool { delegatedControlsAvailable && controlRecoveryAuthority != nil }

    /// The account store owns all outboxes under its process lock. A host
    /// interrupt saved at another Station is still part of this origin's review.
    func localControlAuthorInventory(stationOrigin: String, current: () -> Bool) throws -> RemoteControlAuthorInventory {
        guard !busy, !uncertain else { throw RemoteRecoveryError.busy }
        busy = true
        defer { busy = false }
        guard current(), !Task.isCancelled, PortalIntegrationRecord.validOrigin(stationOrigin),
              let log = membershipLog, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
        let journal = try readControlJournal(member: managerID)
        let origins = (saved.controlPublications ?? [:]).keys.sorted()
        let recoveryOrigins = (saved.controlRecoveryPublications ?? [:]).keys.sorted()
        guard origins.count <= 64, recoveryOrigins.count <= 64 else { throw RemoteControlPublicationError.full }
        let inventory = try journal.inventory(stationOrigin: stationOrigin,
            outboxes: origins.map { try controls(stationOrigin: $0) },
            recoveryCopies: recoveryOrigins.map { try recoveryControls(origin: $0) })
        try requireDurableRecoveryCheckpoint()
        guard current(), !Task.isCancelled, membershipLog?.head() == log.head(),
              membershipLog?.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
        return inventory
    }

    func localControlRecoveryOriginals(stationOrigin: String, current: () -> Bool) throws -> [RemoteControlActivity] {
        guard !busy, !uncertain, current(), let log = membershipLog else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        guard saved.controlPublications?[stationOrigin] != nil else { return [] }
        return try controls(stationOrigin: stationOrigin).activity(log: log).filter(\.signed)
    }

    func loadControlRecoveryPreparation(stationOrigin: String, current: () -> Bool) async throws -> RemoteControlRecoveryPreparation {
        try begin(); defer { busy = false }
        guard current(), !Task.isCancelled, let kit = try currentKit(), let log = membershipLog,
              log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        let head = log.head()
        let source = try controlActivitySource(origin: stationOrigin, log: log)
        guard let transport = source as? RemoteControlRecoveryReviewTransport else {
            throw RemoteRecoveryTransportError.unavailable
        }
        let result = try await transport.controlRecoveryReview(accountID: accountID, genesisHash: kit.genesisHash, expected: head)
        guard current(), !Task.isCancelled, membershipLog?.frozen() == nil, membershipLog?.head() == head,
              result.context.accountID == accountID, result.context.genesisHash == kit.genesisHash,
              result.context.stationOrigin == stationOrigin, result.context.membershipHead == head else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        if !(saved.controlJournalIDs ?? [:]).isEmpty {
            try readControlJournal(member: managerID).reconcileSupersedingPlan(result)
        }
        // Reading a plan never installs recovery signing or publication authority.
        return result
    }

    func checkSigningHold(_ context: RemoteControlRecoveryContext, current: () -> Bool) async throws -> RemoteStationPlanEnd.Outcome? {
        try begin(); defer { busy = false }
        guard current(), !Task.isCancelled, context.stationOrigin == relayURL, context.accountID == accountID,
              try currentKit()?.genesisHash == context.genesisHash,
              let station = http as? RemoteRecoveryHTTP else { throw RemoteRecoveryError.requiresReview }
        guard let end = try await station.planEnd(for: context) else { return nil }
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try readControlJournal(member: managerID).reconcilePlanEnd(end)
        return end.outcome
    }

    /// A transport retry sends the existing signed evidence without a second owner prompt.
    func retrySignerReport(_ context: RemoteControlRecoveryContext, current: () -> Bool) async throws -> Bool {
        try begin(); defer { busy = false }
        guard current(), !Task.isCancelled, context.stationOrigin == relayURL, context.accountID == accountID,
              let station = http as? RemoteRecoveryHTTP, let log = membershipLog, log.frozen() == nil,
              log.genesisHash() == context.genesisHash, log.head() == context.membershipHead else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        guard let submission = try readControlJournal(member: managerID).exposedSubmission(for: context, log: log) else {
            return false
        }
        let retained = try await station.retainSignerReport(submission)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        return retained
    }

    /// A report can retain stop evidence before the operator has a complete process roster.
    func localSignerReportSlot(_ context: RemoteControlRecoveryContext) throws -> String {
        try requireDurableRecoveryCheckpoint()
        guard !uncertain, let log = membershipLog, log.frozen() == nil, context.accountID == accountID,
              context.stationOrigin == relayURL, context.genesisHash == log.genesisHash(),
              context.membershipHead == log.head() else { throw RemoteRecoveryError.requiresReview }
        guard let roster = saved.processRosters?[relayURL]?[managerID],
              roster.sequence == log.head().seq, roster.headHash == log.head().hash else { return "astation-macos" }
        let process = verifierReportProcess()
        let matches = try reviewedProcessSlots(member: managerID, log: log).filter { $0.process == process }
        return matches.count == 1 ? matches[0].slot : "astation-macos"
    }

    /// Operator comparison input. Each review head must belong to this Mac's anchored list.
    func exportAuthorRoster(_ plan: RemoteControlRecoveryPreparation, current: () -> Bool) throws -> String {
        let context = plan.context
        guard current(), !busy, !uncertain, !Task.isCancelled, let log = membershipLog,
              log.frozen() == nil, log.accountId() == context.accountID, context.accountID == accountID,
              context.stationOrigin == relayURL, context.genesisHash == log.genesisHash(),
              context.membershipHead == log.head() else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        let entries = log.entries()
        var checkedHeads = [UInt64: String]()
        var rows = [[String: Any]]()
        func append(_ slot: RemoteMemberVerifierSlot, seq: UInt64, hash: String, selected: Bool) throws {
            guard seq > 0, seq <= UInt64(entries.count), rows.count < 8192 else { throw RemoteRecoveryError.invalidCheckpoint }
            if checkedHeads[seq] == nil { checkedHeads[seq] = try signedObjectInfo(json: entries[Int(seq - 1)]).entryHash }
            guard checkedHeads[seq] == hash else { throw RemoteRecoveryError.invalidCheckpoint }
            rows.append(["member": slot.memberID, "slot": slot.slot, "process": slot.process,
                         "review_head": ["seq": seq, "hash": hash], "selected": selected])
        }
        let rosters = saved.processRosters?[relayURL] ?? [:]
        for member in rosters.keys.sorted() {
            guard let roster = rosters[member], member == roster.member, roster.origin == relayURL,
                  roster.genesis == context.genesisHash, let target = log.member(deviceId: member) else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
            guard target.kind == "native" else { continue }
            for slot in try roster.slots() {
                try append(slot, seq: roster.sequence, hash: roster.headHash, selected: true)
            }
            for old in roster.earlier ?? [] {
                let slots = try AstationProcessRoster.rows(member: member, text: old.line)
                guard slots.count == 1, let slot = slots.first, old.line == slot.slot + " " + slot.process else {
                    throw RemoteRecoveryError.invalidCheckpoint
                }
                try append(slot, seq: old.sequence, hash: old.headHash, selected: false)
            }
        }
        let value: [String: Any] = ["version": 1, "account_id": accountID, "genesis_hash": context.genesisHash,
            "origin": relayURL, "generation": String(context.generation), "plan_id": context.planID,
            "candidate_feed_id": context.candidateFeedID, "source_hash": context.sourceHash,
            "evidence_hash": context.evidenceHash, "reconstruction_hash": plan.reconstructionHash,
            "membership_head": ["seq": context.membershipHead.seq, "hash": context.membershipHead.hash],
            "slots": rows]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 4 * 1024 * 1024 else { throw RemoteVerifierGateError.invalidRoster }
        return String(decoding: data, as: UTF8.self)
    }

    func submitSignerReport(_ context: RemoteControlRecoveryContext, slot: String, preview: RemoteControlAuthorInventory,
        current: () -> Bool) async throws {
        try begin(); defer { busy = false }
        guard current(), !Task.isCancelled, context.stationOrigin == relayURL, context.accountID == accountID,
              try currentKit()?.genesisHash == context.genesisHash,
              let station = http as? RemoteRecoveryHTTP else { throw RemoteRecoveryError.requiresReview }
        let log = try await refreshedLog(genesis: context.genesisHash)
        try requireDelegatedControl(log)
        guard current(), !Task.isCancelled, log.head() == context.membershipHead else { throw RemoteChannelError.staleLink }
        guard slot == (try localSignerReportSlot(context)) else { throw RemoteRecoveryError.requiresReview }
        let issued = try await station.signerChallenge(for: context, memberID: managerID, slot: slot,
            nowMs: { Self.clock().wallMs })
        guard current(), !Task.isCancelled, membershipLog?.head() == context.membershipHead else { throw RemoteChannelError.staleLink }
        try requireDelegatedControl(log)
        // The protected hold spans authentication; release the process lock while the owner responds.
        let review = try pinnedControlJournal(log: log, member: managerID).reviewReport(issued,
            log: log, preview: preview, nowMs: now().wallMs,
            outboxes: (saved.controlPublications ?? [:]).keys.map { try controls(stationOrigin: $0) },
            recoveryCopies: (saved.controlRecoveryPublications ?? [:]).keys.map { try recoveryControls(origin: $0) })
        guard await confirmOwner(review.request), current(), !Task.isCancelled else { throw RemoteRecoveryError.confirmationRequired }
        let confirmedAt = Self.clock().monoMs
        let latest = try await refreshedLog(genesis: context.genesisHash)
        guard current(), !Task.isCancelled, latest.head() == context.membershipHead,
              let key = latest.member(deviceId: managerID)?.authKey, key.alg == .p256 else { throw RemoteChannelError.staleLink }
        try requireDelegatedControl(latest)
        try requireDurableRecoveryCheckpoint()
        let submission = try pinnedControlJournal(log: latest, member: managerID).finishReport(review,
            log: latest, nowMs: { now().wallMs },
            current: { current() && !Task.isCancelled },
            sign: { keyRequest in
                let time = Self.clock()
                guard time.monoMs >= confirmedAt, time.monoMs - confirmedAt < 30_000,
                      time.wallMs >= issued.challenge.issuedAt, time.wallMs < issued.challenge.expiresAt else {
                    throw RemoteRecoveryError.confirmationRequired
                }
                return try identity.signRecoveryReport(keyRequest, expectedPublicKey: key.raw)
            })
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        guard try await station.retainSignerReport(submission) else { throw RemoteRecoveryError.requiresReview }
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
    }

    func localControlRecoveryReviews(stationOrigin: String? = nil, current: () -> Bool) throws -> [RemoteControlRecoveryReview] {
        guard !busy, !uncertain, current() else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        return try retainedRecoveryControls(origin: stationOrigin ?? relayURL)?.reviews() ?? []
    }

    func prepareControlRecoveryCopy(recordID: String, context: RemoteControlRecoveryContext,
        current: () -> Bool) async throws -> RemoteControlRecoveryReview {
        try begin(); defer { busy = false }
        guard controlRecoveryAvailable, let authority = controlRecoveryAuthority else {
            throw AstationDelegatedControlError.notVerified
        }
        guard current(), !Task.isCancelled, context.stationOrigin == relayURL, context.accountID == accountID,
              let kit = try currentKit(), kit.genesisHash == context.genesisHash else {
            throw RemoteChannelError.staleLink
        }
        try requireDurableRecoveryCheckpoint()
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        try requireDelegatedControl(log)
        guard current(), !Task.isCancelled, log.head() == context.membershipHead,
              let original = try controls().retainedDelivery(recordID: recordID) else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        let recovery = try recoveryControls(origin: context.stationOrigin)
        if let prior = try recovery.reviews().first(where: { $0.context == context && $0.originalRecordID == recordID }) {
            guard prior.body.signer == "member:" + managerID, prior.originalRecordJSON == original.recordJSON else {
                throw RemoteRecoveryError.requiresReview
            }
            try authority.authorize(prior, log: log)
            guard current(), !Task.isCancelled, log.head() == context.membershipHead else { throw RemoteChannelError.staleLink }
            return prior
        }
        let time = try await authority.reserve(originalRecordJSON: original.recordJSON, context: context,
            managerID: managerID, log: log)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireDurableRecoveryCheckpoint()
        let latest = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(latest)
        try requireDelegatedControl(latest)
        guard current(), !Task.isCancelled, latest.head() == context.membershipHead else { throw RemoteChannelError.staleLink }
        try requireDurableRecoveryCheckpoint()
        return try recovery.prepare(originalRecordJSON: original.recordJSON, context: context, managerID: managerID,
            issuedAt: time, log: latest, authority: authority)
    }

    /// Owner confirmation signs only the protected recovery draft. No live feed,
    /// ordinary delivery, Portal mirror or recovery fence is changed here.
    func signControlRecoveryCopy(_ review: RemoteControlRecoveryReview, current: () -> Bool) async throws -> String {
        try begin(); defer { busy = false }
        guard controlRecoveryAvailable, let authority = controlRecoveryAuthority else {
            throw AstationDelegatedControlError.notVerified
        }
        guard current(), !Task.isCancelled, review.context.stationOrigin == relayURL,
              review.body.signer == "member:" + managerID, let kit = try currentKit(),
              kit.genesisHash == review.context.genesisHash else { throw RemoteChannelError.staleLink }
        try requireDurableRecoveryCheckpoint()
        let recovery = try recoveryControls(origin: relayURL)
        guard let retained = try recovery.reviews().first(where: { $0.body.recordId == review.body.recordId }),
              retained.context == review.context, retained.body == review.body, retained.request == review.request,
              retained.originalRecordJSON == review.originalRecordJSON else { throw RemoteRecoveryError.requiresReview }
        let before = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(before)
        try requireDelegatedControl(before)
        guard current(), !Task.isCancelled, before.head() == retained.context.membershipHead else {
            throw RemoteChannelError.staleLink
        }
        try requireDurableRecoveryCheckpoint()
        try authority.authorize(retained, log: before)
        var confirmedAt: UInt64 = 0
        if !retained.signed {
            try requireControlChange(retained.request)
            guard current(), !Task.isCancelled, await confirmOwner(retained.request), current(), !Task.isCancelled else {
                throw RemoteRecoveryError.confirmationRequired
            }
            confirmedAt = Self.clock().monoMs
        }
        try requireDurableRecoveryCheckpoint()
        let latest = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(latest)
        try requireDelegatedControl(latest)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try authority.authorize(retained, log: latest)
        try requireDurableRecoveryCheckpoint()
        let provider = AstationMembershipKeyProvider(identity: identity, keyID: managerID,
            publicKey: try identity.remotePublicKeys().signing, controlRecordsAllowed: true)
        _ = try recovery.sign(recordID: retained.body.recordId, log: latest, provider: provider, authorJournal: pinnedControlJournal, authority: authority,
            confirmedAt: confirmedAt, now: { Self.clock().monoMs }, current: current)
        return try recovery.export(context: retained.context, recordIDs: [retained.body.recordId])
    }

    func exportControlRecoveryCopies(context: RemoteControlRecoveryContext, recordIDs: [String], current: () -> Bool) throws -> String {
        guard !busy, !uncertain, current(), context.accountID == accountID else { throw RemoteRecoveryError.requiresReview }
        try requireDurableRecoveryCheckpoint()
        guard let recovery = try retainedRecoveryControls(origin: context.stationOrigin) else {
            throw RemoteRecoveryError.requiresReview
        }
        return try recovery.export(context: context, recordIDs: recordIDs)
    }

    /// Send only an already durable signature. A lost reply retries the same
    /// bytes, without reserving another clock or asking the owner to sign again.
    func retainControlRecoveryCopy(_ review: RemoteControlRecoveryReview, current: () -> Bool) async throws -> RemoteControlRecoveryRetention {
        try begin(); defer { busy = false }
        guard current(), !Task.isCancelled, review.signed, review.context.stationOrigin == relayURL,
              review.context.accountID == accountID, let log = membershipLog, log.frozen() == nil,
              log.head() == review.context.membershipHead, log.genesisHash() == review.context.genesisHash else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        guard let recovery = try retainedRecoveryControls(origin: review.context.stationOrigin),
              try recovery.reviews().contains(review) else { throw RemoteRecoveryError.requiresReview }
        let json = try recovery.export(context: review.context, recordIDs: [review.body.recordId])
        let source = try controlActivitySource(origin: review.context.stationOrigin, log: log)
        guard let reviews = source as? RemoteControlRecoveryReviewTransport,
              let retention = source as? RemoteControlRecoveryRetentionTransport else {
            throw RemoteRecoveryTransportError.unavailable
        }
        let preparation = try await reviews.controlRecoveryReview(accountID: accountID,
            genesisHash: review.context.genesisHash, expected: review.context.membershipHead)
        guard current(), !Task.isCancelled, preparation.context == review.context,
              membershipLog?.head() == review.context.membershipHead, membershipLog?.frozen() == nil else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        guard try recovery.export(context: review.context, recordIDs: [review.body.recordId]) == json else {
            throw RemoteRecoveryError.requiresReview
        }
        let receipt = try await retention.retainControlRecoveryCopies(context: review.context, copiesJSON: json)
        guard current(), !Task.isCancelled, membershipLog?.head() == review.context.membershipHead,
              membershipLog?.frozen() == nil, receipt.recordIDs == [review.body.recordId] else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireDurableRecoveryCheckpoint()
        // Keep the protected original and copy. This receipt is neither a live
        // feed ACK nor evidence that the replacement snapshot may be opened.
        return receipt
    }

    private func retainedRecoveryControls(origin: String) throws -> RemoteControlRecoveryPublication? {
        guard PortalIntegrationRecord.validOrigin(origin) else { throw RemoteRecoveryError.requiresReview }
        // Evidence reads must not consume origin slots by creating empty journals.
        guard saved.controlRecoveryPublications?[origin] != nil else { return nil }
        return try recoveryControls(origin: origin)
    }

    private func recoveryControls(origin: String) throws -> RemoteControlRecoveryPublication {
        guard PortalIntegrationRecord.validOrigin(origin), let kit = try currentKit() else { throw RemoteRecoveryError.requiresReview }
        if let value = controlRecoveryPublications[origin] { return value }
        let retained = Set((saved.controlRecoveryPublications ?? [:]).keys).union(controlRecoveryPublications.keys)
        guard retained.contains(origin) || retained.count < 64 else { throw RemoteControlPublicationError.full }
        let save: (Data) throws -> Void = { [unowned self] bytes in
            try self.persist {
                $0.version = 6
                $0.controlRecoveryPublications = ($0.controlRecoveryPublications ?? [:]).merging([origin: bytes]) { _, new in new }
            }
        }
        let value: RemoteControlRecoveryPublication
        if let data = saved.controlRecoveryPublications?[origin] {
            value = try RemoteControlRecoveryPublication(checkpoint: data, accountID: accountID,
                genesisHash: kit.genesisHash, stationOrigin: origin,
                draftJournal: { [unowned self] _, member in try self.readControlJournal(member: member) }, persist: save)
        } else {
            value = try RemoteControlRecoveryPublication(accountID: accountID, genesisHash: kit.genesisHash,
                stationOrigin: origin,
                draftJournal: { [unowned self] _, member in try self.readControlJournal(member: member) }, persist: save)
        }
        controlRecoveryPublications[origin] = value
        return value
    }

    struct ControlDiscoveryPage {
        let stationOrigin: String
        let feedID: String
        let after: UInt64
        let more: Bool
        let membershipHead: LogHead
    }

    func resumeControlActivity(generation: UUID, current: @escaping () -> Bool,
        updated: @escaping (String, MembershipLog, [RemoteControlActivity]) -> Void) {
        guard delegatedControlsAvailable, controlActivityContext?.generation != generation else { return }
        controlActivityTask?.cancel()
        controlActivityPages = [:]
        lastControlActivityOrigin = nil
        controlActivityContext = (generation, current, updated)
        refreshControlActivityInBackground()
    }

    func stopControlActivity() {
        controlActivityContext = nil
        controlActivityPages = [:]
        lastControlActivityOrigin = nil
        controlActivityTask?.cancel()
    }

    /// One bounded feed page per tick, rotating origins even after a failure.
    /// An unavailable Station never blocks another one or resolves its alerts.
    func refreshControlActivityInBackground() {
        guard delegatedControlsAvailable, !busy, !uncertain, controlActivityTask == nil,
              let context = controlActivityContext, context.current() else { return }
        let current: () -> Bool = { [weak self] in
            self?.controlActivityContext?.generation == context.generation && context.current()
        }
        controlActivityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.controlActivityTask = nil }
            do {
                guard let log = self.membershipLog else { return }
                let origins = try self.controlActivityOrigins(log)
                let origin = origins.first(where: { $0 > (self.lastControlActivityOrigin ?? "") }) ?? origins[0]
                self.lastControlActivityOrigin = origin
                let page = try await self.discoverControlActivity(previous: self.controlActivityPages[origin],
                    stationOrigin: origin, current: current)
                guard current(), !Task.isCancelled else { return }
                let activity = try await self.refreshControlActivity(stationOrigin: origin, current: current)
                guard current(), !Task.isCancelled, !self.uncertain, let log = self.membershipLog else { return }
                try self.requireManager(log)
                try self.requireDelegatedControl(log)
                self.controlActivityPages[origin] = page
                context.updated(origin, log, activity)
            } catch {
                // Keep the previous cursor and durable journal for the next tick.
                // An unavailable source is never an empty, resolved alert set.
            }
        }
    }

    /// One bounded page per refresh. A list change restarts discovery at zero.
    func discoverControlActivity(previous: ControlDiscoveryPage?, stationOrigin: String? = nil,
        current: () -> Bool) async throws -> ControlDiscoveryPage {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), !Task.isCancelled, let kit = try currentKit(), let anchor = membershipLog else {
            throw RemoteChannelError.staleLink
        }
        let origin = stationOrigin ?? relayURL
        let source = try controlActivitySource(origin: origin, log: anchor)
        guard let transport = source as? RemoteControlFeedTransport else { throw RemoteChannelError.staleLink }
        let log = try await refreshedLog(genesis: kit.genesisHash, transport: source)
        try requireControlActivitySource(origin: origin, log: log)
        try requireManager(log)
        try requireDelegatedControl(log)
        let heads = try relayDecodeToHost(message: await transport.controlHeads(genesisHash: kit.genesisHash))
        guard current(), !Task.isCancelled, case .heads(let feeds, let head) = heads,
              head == log.head(), feeds.count == 1, feeds[0].origin == origin else {
            throw RemoteRecoveryError.requiresReview
        }
        try requireControlActivitySource(origin: origin, log: log)
        let feed = feeds[0]
        let after = previous.flatMap {
            $0.more && $0.stationOrigin == origin && $0.feedID == feed.feedId && $0.membershipHead == log.head() ? $0.after : nil
        } ?? 0
        let call = try relayControlSync(requestId: UUID().uuidString.lowercased(), origin: origin, feedId: feed.feedId, after: after)
        let result = try await transport.controlSync(genesisHash: kit.genesisHash, callJSON: call)
        guard current(), !Task.isCancelled, try relayControlSyncAnswers(call: call, result: result) == .answers,
              case .controlSyncResult(_, _, let feedID, _, let feedHead, _, let records) = try relayDecodeToHost(message: result),
              records.count <= 64, feedHead >= max(after, feed.head), !records.isEmpty || feedHead == after else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        try requireControlActivitySource(origin: origin, log: log)
        let latest = try await refreshedLog(genesis: kit.genesisHash, transport: source)
        guard current(), !Task.isCancelled, latest.head() == log.head() else { throw RemoteChannelError.staleLink }
        try requireManager(latest)
        try requireDelegatedControl(latest)
        try requireControlActivitySource(origin: origin, log: latest)
        let journal = try controls(stationOrigin: origin)
        for row in records {
            // Feed entries can be future or malformed record types; they grant no authority.
            guard let body = try? parseControlRecord(recordJson: row.recordJson), body.signer.hasPrefix("member:"),
                  case .refused(let reason) = try? verifyControlRecord(log: latest, recordJson: row.recordJson),
                  reason == "removed_manager" else { continue }
            do { try journal.retainRemovedManagerStop(recordJSON: row.recordJson, log: latest) }
            catch RemoteControlPublicationError.invalidRecord { continue }
        }
        let cursor = records.last?.feedSeq ?? after
        return ControlDiscoveryPage(stationOrigin: origin, feedID: feedID, after: cursor,
            more: cursor < feedHead, membershipHead: latest.head())
    }

    func prepareControlResign(recordID: String, current: () -> Bool) async throws -> RemoteControlReview {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), !Task.isCancelled, let kit = try currentKit(), let transport = http as? RemoteControlTransport else {
            throw RemoteChannelError.staleLink
        }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        try requireDelegatedControl(log)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        let journal = try controls()
        guard try journal.activity(log: log).contains(where: { $0.body.recordId == recordID && $0.managerReviewRequired }) else {
            throw RemoteRecoveryError.requiresReview
        }
        if let saved = try journal.savedResignReview(recordID: recordID) {
            guard saved.body.signer == "member:" + managerID else { throw RemoteRecoveryError.requiresReview }
            if !saved.signed { _ = try journal.signingRequest(recordID: saved.body.recordId, log: log) }
            return saved
        }
        let heads = try relayDecodeToHost(message: await transport.controlHeads(genesisHash: kit.genesisHash))
        guard current(), !Task.isCancelled, case .heads(let feeds, let head) = heads,
              head == log.head(), feeds.count == 1, feeds[0].origin == relayURL,
              let source = try journal.activity(log: log).first(where: { $0.body.recordId == recordID }) else {
            throw RemoteRecoveryError.requiresReview
        }
        let time = try await transport.reserveControlTime(genesisHash: kit.genesisHash, principal: source.body.principal,
            managerID: managerID, expected: log.head())
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        return try journal.prepareResign(recordID: recordID, managerID: managerID, issuedAt: time,
            feedID: feeds[0].feedId, log: log)
    }

    func commitControlResign(_ review: RemoteControlReview, current: () -> Bool) async throws -> RemoteControlDelivery {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), !Task.isCancelled, let source = review.resignsRecordID, let kit = try currentKit(),
              let saved = try controls().savedResignReview(recordID: source), saved.body == review.body,
              saved.request == review.request, saved.additionalStationOrigins == review.additionalStationOrigins,
              review.body.signer == "member:" + managerID else {
            throw RemoteRecoveryError.requiresReview
        }
        if !saved.signed {
            try await signControl(recordID: review.body.recordId, request: review.request, genesis: kit.genesisHash, current: current)
        }
        // The original record retains its independently approved Portal mirror.
        return try await deliverControl(review.body.recordId, portal: nil, current: current)
    }

    func cancelUnsignedControlResign(recordID: String) throws {
        guard !busy, !uncertain, let review = try controls().savedResignReview(recordID: recordID), !review.signed else {
            throw RemoteRecoveryError.requiresReview
        }
        try controls().cancelUnsigned(recordID: review.body.recordId, authorJournal: readControlJournal)
    }

    func refreshControlActivity(stationOrigin: String? = nil, current: @escaping () -> Bool) async throws -> [RemoteControlActivity] {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable, current(), let kit = try currentKit(), let anchor = membershipLog else {
            throw AstationDelegatedControlError.notVerified
        }
        let origin = stationOrigin ?? relayURL
        let source = try controlActivitySource(origin: origin, log: anchor)
        guard let transport = source as? RemoteControlStatusTransport else { throw RemoteChannelError.staleLink }
        let log = try await refreshedLog(genesis: kit.genesisHash, transport: source)
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireManager(log)
        try requireDelegatedControl(log)
        try requireControlActivitySource(origin: origin, log: log)
        let activity = try controls(stationOrigin: origin).activity(log: log)
        let ids = activity.filter(\.signed).map { $0.body.recordId }
        func readStatus(_ station: String, _ transport: RemoteControlStatusTransport,
            _ recordIDs: [String]) async throws -> [String: RemoteControlApplicationState] {
            var result: [String: RemoteControlApplicationState] = [:]
            for offset in stride(from: 0, to: recordIDs.count, by: 64) {
                let batch = Array(recordIDs[offset..<min(offset + 64, recordIDs.count)])
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                try requireControlActivitySource(origin: station, log: log)
                let page = try await transport.controlStatus(genesisHash: kit.genesisHash, recordIDs: batch, expected: log.head())
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                try requireControlActivitySource(origin: station, log: log)
                guard Set(page.keys) == Set(batch) else { throw RemoteRecoveryTransportError.invalidResponse }
                result.merge(page) { _, new in new }
            }
            return result
        }
        let reports = try await readStatus(origin, transport, ids)
        // Query only destinations named by this signed record, once its source
        // reports application. A storage receipt cannot settle a peer's effects.
        var peerIDs: [String: [String]] = [:]
        for row in activity where row.signed && reports[row.body.recordId] == .effectsReported {
            for peer in row.additionalStations.keys { peerIDs[peer, default: []].append(row.body.recordId) }
        }
        guard peerIDs.count <= 63 else { throw RemoteRecoveryError.requiresReview }
        // Each reviewed Station has at most one status call in flight. A slow peer
        // cannot serialize the timeouts of every other peer behind it.
        let peerReports = await withTaskGroup(of: (String, [String: RemoteControlApplicationState]?).self) { group in
            for (peer, recordIDs) in peerIDs {
                group.addTask { @MainActor in
                    guard current(), !Task.isCancelled,
                          (try? self.requireControlActivitySource(origin: origin, log: log)) != nil,
                          let peerTransport = try? self.controlActivitySource(origin: peer, log: log) as? RemoteControlStatusTransport
                    else { return (peer, nil) }
                    return (peer, try? await readStatus(peer, peerTransport, recordIDs))
                }
            }
            var observations: [String: [String: RemoteControlApplicationState]] = [:]
            for await (peer, states) in group { observations[peer] = states }
            return observations
        }
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireControlActivitySource(origin: origin, log: log)
        // Reject a changed list even if a delayed status response looked complete.
        let latest = try await refreshedLog(genesis: kit.genesisHash, transport: source)
        guard current(), !Task.isCancelled, latest.head() == log.head() else { throw RemoteChannelError.staleLink }
        try requireManager(latest)
        try requireDelegatedControl(latest)
        try requireControlActivitySource(origin: origin, log: latest)
        let availablePeers = try peerReports.isEmpty ? [] : controlActivityOrigins(latest)
        return try controls(stationOrigin: origin).activity(log: latest, status: reports,
            additionalStatus: peerReports.filter { availablePeers.contains($0.key) })
    }

    func resumeControlDelivery(portal: PortalIntegrationHTTP, current: @escaping () -> Bool) {
        guard delegatedControlsAvailable else { return }
        controlDeliveryContext = (portal, current)
        retrySavedControlsIfNeeded()
    }

    private func retrySavedControlsIfNeeded() {
        guard delegatedControlsAvailable, !busy, !uncertain, controlDeliveryTask == nil,
              let context = controlDeliveryContext, context.current() else { return }
        controlDeliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.controlDeliveryTask = nil }
            do {
                let origins = try self.pendingControlDeliveryOrigins()
                guard let origin = origins.first(where: { $0 > (self.lastControlDeliveryOrigin ?? "") }) ?? origins.first else { return }
                self.lastControlDeliveryOrigin = origin
                let deliveries = try await self.retryPendingControls(portal: context.portal,
                    stationOrigin: origin, current: context.current)
                for delivery in deliveries { self.onControlDelivery?(delivery) }
            } catch {
                Log.warn("[Delegated] Saved control delivery will resume after account access is available")
            }
        }
    }

    private func pendingControlDeliveryOrigins() throws -> [String] {
        let origins = Set((saved.controlPublications ?? [:]).keys).union(controlPublications.keys)
        return try origins.sorted().filter { try !controls(stationOrigin: $0).pendingDeliveryIDs().isEmpty }
    }

    private func requireDelegatedControl(_ log: MembershipLog) throws {
        guard let authorizeDelegatedControl else { throw AstationDelegatedControlError.notVerified }
        try authorizeDelegatedControl(log)
    }

    private func controls(stationOrigin: String? = nil) throws -> RemoteControlPublication {
        let origin = stationOrigin ?? relayURL
        guard PortalIntegrationRecord.validOrigin(origin) else { throw RemoteRecoveryError.requiresReview }
        if let value = controlPublications[origin] { return value }
        let retained = Set((saved.controlPublications ?? [:]).keys).union(controlPublications.keys)
        guard retained.contains(origin) || retained.count < 64 else { throw RemoteControlPublicationError.full }
        guard let kit = try currentKit() else { throw RemoteRecoveryError.notCommitted }
        let persistControl: (Data) throws -> Void = { [unowned self] bytes in
            try self.persist {
                $0.version = 6
                $0.controlPublications = ($0.controlPublications ?? [:]).merging([origin: bytes]) { _, new in new }
            }
            self.pendingControlCommit = true
        }
        let value: RemoteControlPublication
        if let data = saved.controlPublications?[origin] {
            value = try RemoteControlPublication(checkpoint: data, accountID: accountID, genesisHash: kit.genesisHash,
                stationOrigin: origin,
                draftJournal: { [unowned self] _, member in try self.readControlJournal(member: member) }, persist: persistControl)
        } else {
            value = try RemoteControlPublication(accountID: accountID, genesisHash: kit.genesisHash,
                stationOrigin: origin,
                draftJournal: { [unowned self] _, member in try self.readControlJournal(member: member) }, persist: persistControl)
        }
        controlPublications[origin] = value
        return value
    }

    private func controlActivitySource(origin: String, log: MembershipLog) throws -> RemoteRecoveryTransport {
        guard PortalIntegrationRecord.validOrigin(origin) else { throw RemoteRecoveryError.requiresReview }
        if origin == relayURL { return http }
        let value: RemoteControlStationTransport
        if let supplied = try controlStationTransports(log)[origin] { value = supplied }
        else {
            guard let retainedControlTransport, try retainedControlOrigins(log).contains(origin) else {
                throw RemoteChannelError.staleLink
            }
            value = try retainedControlTransport(origin)
        }
        guard PortalIntegrationRecord.validOrigin(origin), value.controlStationOrigin == origin else {
            throw RemoteRecoveryError.requiresReview
        }
        return value
    }

    private func retainedControlOrigins(_ log: MembershipLog) throws -> Set<String> {
        let journals = (saved.controlPublications ?? [:]).keys
        var origins = Set(journals).union((saved.verifierRosters ?? [:]).compactMap {
            $0.value.genesis == log.genesisHash() ? $0.key : nil
        })
        // A signed host interrupt can name a Station that has no journal of its own.
        for origin in journals {
            origins.formUnion(try controls(stationOrigin: origin).previouslyReviewedStations())
        }
        guard origins.union([relayURL]).count <= 64 else { throw RemoteRecoveryError.requiresReview }
        return origins
    }

    private func controlActivityOrigins(_ log: MembershipLog) throws -> [String] {
        var origins = Set(try controlStationTransports(log).keys)
        origins.insert(relayURL)
        if retainedControlTransport != nil { origins.formUnion(try retainedControlOrigins(log)) }
        guard origins.count <= 64, origins.allSatisfy(PortalIntegrationRecord.validOrigin) else {
            throw RemoteRecoveryError.requiresReview
        }
        return origins.sorted()
    }

    private func requireControlActivitySource(origin: String, log: MembershipLog) throws {
        if origin == relayURL { return }
        guard try controlStationTransports(log)[origin] != nil ||
                (retainedControlTransport != nil && retainedControlOrigins(log).contains(origin)) else {
            throw RemoteChannelError.staleLink
        }
    }

    /// Native delivery uses the same durable signatures, independently of Station storage receipts.
    func signedHostControls(for log: MembershipLog) throws -> [String] {
        guard delegatedControlsAvailable else { return [] }
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        guard let kit = try currentKit(), log.frozen() == nil, log.accountId() == accountID,
              log.genesisHash() == kit.genesisHash, log.head() == membershipLog?.head() else {
            throw RemoteRecoveryError.requiresReview
        }
        let journal = try controls()
        return try journal.recordIDs.compactMap { id in
            guard let delivery = try journal.retainedDelivery(recordID: id),
                  try parseControlRecord(recordJson: delivery.recordJSON).principal.hasPrefix("host:"),
                  case .valid = try verifyControlRecord(log: log, recordJson: delivery.recordJSON) else { return nil }
            return delivery.recordJSON
        }
    }

    static func latestHostSenderRevocation(log: MembershipLog, hostID: String) throws -> UInt64? {
        for entry in log.entries().reversed() {
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            if body?["action"] as? String == "host_sender_revoke", body?["host_id"] as? String == hostID,
               let seq = body?["seq"] as? NSNumber { return seq.uint64Value }
        }
        return nil
    }

    func pendingHostInterrupts() throws -> [HostInterruptReview] {
        try controls().pendingReviews().filter { $0.body.principal.hasPrefix("host:") }.map {
            HostInterruptReview(stationOrigin: relayURL, body: $0.body, request: $0.request,
                additionalStationOrigins: try controls().stationOrigins(recordID: $0.body.recordId).filter { $0 != relayURL })
        }
    }

    struct InterruptStations {
        let primary: String
        let previous: Set<String>
        let candidates: Set<String>
        let unavailable: Set<String>
        let directoryComplete: Bool
    }

    private func interruptStationChoices(hostID: String, configured: Set<String>,
        directory: (() async throws -> PortalStationDirectorySnapshot)?) async throws -> InterruptStations {
        var previous = Set<String>()
        for origin in (saved.controlPublications ?? [:]).keys {
            previous.formUnion(try controls(stationOrigin: origin).previouslyReviewedStations(hostID: hostID))
        }
        previous.remove(relayURL)
        let snapshot = try? await directory?()
        var candidates = configured.union(previous)
        var unavailable = Set<String>()
        let complete = snapshot?.complete == true && snapshot?.stale == false
        if complete, let snapshot {
            for (origin, rows) in Dictionary(grouping: snapshot.stations, by: \.origin) where origin != relayURL {
                if rows.allSatisfy(\.availableForIntegrations) { candidates.insert(origin) }
                else { unavailable.insert(origin) }
            }
        }
        return InterruptStations(primary: relayURL, previous: previous, candidates: candidates,
            unavailable: unavailable, directoryComplete: complete)
    }

    func prepareHostInterrupt(hostID: String, directory: (() async throws -> PortalStationDirectorySnapshot)? = nil,
        chooseStations: ((InterruptStations) throws -> Set<String>)? = nil,
        current: () -> Bool) async throws -> HostInterruptReview {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), let kit = try currentKit(), let transport = http as? RemoteControlTransport else {
            throw RemoteChannelError.staleLink
        }
        guard try pendingHostInterrupts().isEmpty else { throw RemoteRecoveryError.busy }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        try requireDelegatedControl(log)
        guard let revokeSeq = try Self.latestHostSenderRevocation(log: log, hostID: hostID) else {
            throw RemoteRecoveryError.requiresReview
        }
        let configured = Set(try controlStationTransports(log).keys)
        let origins: Set<String>
        if let chooseStations {
            let choices = try await interruptStationChoices(hostID: hostID, configured: configured, directory: directory)
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            origins = try chooseStations(choices)
            guard current(), !Task.isCancelled, origins.count <= 63, origins.isSubset(of: choices.candidates) else {
                throw RemoteRecoveryError.requiresReview
            }
        } else { origins = configured }
        let heads = try relayDecodeToHost(message: await transport.controlHeads(genesisHash: kit.genesisHash))
        guard current(), case .heads(let feeds, let head) = heads, head == log.head(), feeds.count == 1,
              feeds[0].origin == relayURL else { throw RemoteRecoveryError.requiresReview }
        let time = try await transport.reserveControlTime(genesisHash: kit.genesisHash, principal: "host:" + hostID,
            managerID: managerID, expected: log.head())
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        // Host interrupts bind to the historical revoke, even after a readmit or key removal.
        // They have no service feed/key/Portal fields in the shared wire format.
        let body = ControlRecordBody(accountId: accountID, genesisHash: kit.genesisHash, origin: nil,
            feedId: nil, principal: "host:" + hostID, principalKey: nil, signer: "member:" + managerID,
            action: "interrupt_running", interruptRunning: nil, revokeSeq: revokeSeq,
            recordId: UUID().uuidString.lowercased(), issuedAt: time, integrationId: nil, by: "owner")
        let destinations = origins.sorted()
        let request = try controls().prepare(body: body, log: log, additionalStationOrigins: destinations)
        return HostInterruptReview(stationOrigin: relayURL, body: body, request: request, additionalStationOrigins: destinations)
    }

    func commitHostInterrupt(_ review: HostInterruptReview, current: () -> Bool) async throws -> RemoteControlDelivery {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), review.stationOrigin == relayURL, review.body.principal.hasPrefix("host:"),
              review.body.action == "interrupt_running", let kit = try currentKit() else { throw AccountLoginError.changed }
        let journal = try controls()
        guard try journal.stationOrigins(recordID: review.recordID) == [relayURL] + review.additionalStationOrigins else {
            throw RemoteRecoveryError.requiresReview
        }
        let savedRequest = try journal.signingRequest(recordID: review.recordID)
        if let retained = try journal.retainedDelivery(recordID: review.recordID) {
            guard try parseControlRecord(recordJson: retained.recordJSON) == review.body else {
                throw RemoteRecoveryError.requiresReview
            }
        } else {
            guard savedRequest == review.request,
                  try journal.pendingReviews().contains(where: { $0.body == review.body && $0.request == review.request }) else {
                throw RemoteRecoveryError.requiresReview
            }
            try await signControl(recordID: review.recordID, request: review.request, genesis: kit.genesisHash, current: current)
        }
        return try await deliverControl(review.recordID, portal: nil, current: current)
    }

    func cancelUnsignedHostInterrupt(_ review: HostInterruptReview) throws {
        guard !busy, !uncertain, review.stationOrigin == relayURL,
              try controls().signingRequest(recordID: review.recordID) == review.request else { throw RemoteRecoveryError.requiresReview }
        try controls().cancelUnsigned(recordID: review.recordID, authorJournal: readControlJournal)
    }

    /// Looking up a draft never creates a protected journal or a pin. A rolled-back
    /// outbox can predate its pin while the independent journal still retains the signature.
    private func readControlJournal(member: String) throws -> RemoteControlSigningJournal {
        try requireDurableRecoveryCheckpoint()
        guard member == managerID, let log = membershipLog else { throw RemoteRecoveryError.requiresReview }
        let journal = try controlSigningJournal(log, member)
        if let pinned = saved.controlJournalIDs?[journal.storageScope], pinned != journal.id {
            throw RemoteRecoveryError.storageUncertain
        }
        return journal
    }

    private func pinnedControlJournal(log: MembershipLog, member: String) throws -> RemoteControlSigningJournal {
        try requireDurableRecoveryCheckpoint()
        guard member == managerID, log.accountId() == accountID else {
            throw RemoteRecoveryError.requiresReview
        }
        let journal = try controlSigningJournal(log, member)
        let scope = journal.storageScope
        if let id = saved.controlJournalIDs?[scope] {
            guard journal.id == id else { throw RemoteRecoveryError.storageUncertain }
        } else {
            guard journal.revision == 0 else { throw RemoteRecoveryError.requiresReview }
            try journal.establish()
            try persist {
                $0.version = 6
                $0.controlJournalIDs = ($0.controlJournalIDs ?? [:]).merging([scope: journal.id]) { _, new in new }
            }
        }
        return journal
    }

    func requireServiceStopChange(origin: String) throws {
        guard origin == relayURL, !busy, !uncertain else { throw RemoteRecoveryError.requiresReview }
        try readControlJournal(member: managerID).requireStopChange(origin: origin)
    }

    func requireControlChange(_ request: SignRequest) throws {
        guard request.keyId == managerID, let json = request.bodyJson,
              request == (try RemoteConfirmedSigner.controlRequest(bodyJSON: json, keyID: managerID)) else {
            throw RemoteRecoveryError.requiresReview
        }
        try readControlJournal(member: managerID).requireStopChange(bodyJSON: json)
    }

    private func signControl(recordID: String, request: SignRequest, genesis: String, current: () -> Bool) async throws {
        let before = try await refreshedLog(genesis: genesis)
        try requireManager(before)
        try requireDelegatedControl(before)
        guard try controls().signingRequest(recordID: recordID, log: before) == request else {
            throw RemoteRecoveryError.requiresReview
        }
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        try requireControlChange(request)
        guard await confirmOwner(request), current(), !Task.isCancelled else { throw RemoteRecoveryError.confirmationRequired }
        let confirmedAt = Self.clock().monoMs
        let log = try await refreshedLog(genesis: genesis)
        try requireManager(log)
        try requireDelegatedControl(log)
        let provider = AstationMembershipKeyProvider(identity: identity, keyID: managerID,
            publicKey: try identity.remotePublicKeys().signing, controlRecordsAllowed: true)
        _ = try controls().sign(recordID: recordID, log: log, provider: provider, authorJournal: pinnedControlJournal,
            confirmedAt: confirmedAt, now: { Self.clock().monoMs }, current: current)
    }

    static func controlService(record: PortalIntegrationRecord, log: MembershipLog) throws -> String? {
        guard let fingerprint = record.r9Svc, log.frozen() == nil else { return nil }
        let ids = try log.entries().compactMap { entry -> String? in
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            guard body?["action"] as? String == "add", let member = body?["member"] as? [String: Any],
                  member["kind"] as? String == "service" else { return nil }
            return member["device_id"] as? String
        }
        let matches = try Set(ids).compactMap { log.member(deviceId: $0) }.filter {
            try $0.kind == "service" && RemoteServiceKeyFingerprint.compute($0.authKey) == fingerprint
        }
        return matches.count == 1 ? matches[0].deviceId : nil
    }

    func prepareServiceControl(_ record: PortalIntegrationRecord, portal: PortalIntegrationHTTP,
        interruptOnly: Bool, interruptRunning: Bool, current: () -> Bool) async throws -> ServiceControlReview {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), record.stationOrigin == relayURL, let kit = try currentKit(),
              let transport = http as? RemoteControlTransport else { throw RemoteChannelError.staleLink }
        let log = try await refreshedLog(genesis: kit.genesisHash)
        try requireManager(log)
        try requireDelegatedControl(log)
        let records = try await portal.owned(stationOrigin: relayURL)
        guard current(), let fresh = records.first(where: { $0.id == record.id }), fresh.role == "owner",
              fresh.r9Svc == record.r9Svc, let service = try Self.controlService(record: fresh, log: log),
              !interruptOnly || ["revoking", "revoked"].contains(fresh.state) else { throw AccountLoginError.changed }
        let heads = try relayDecodeToHost(message: await transport.controlHeads(genesisHash: kit.genesisHash))
        guard current(), case .heads(let feeds, let head) = heads, head == log.head(), feeds.count == 1,
              feeds[0].origin == relayURL else { throw RemoteRecoveryError.requiresReview }
        let principal = "service:" + service
        let time = try await transport.reserveControlTime(genesisHash: kit.genesisHash, principal: principal,
            managerID: managerID, expected: log.head())
        guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
        let body = ControlRecordBody(accountId: accountID, genesisHash: kit.genesisHash, origin: relayURL,
            feedId: feeds[0].feedId, principal: principal, principalKey: fresh.r9Svc, signer: "member:" + managerID,
            action: interruptOnly ? "interrupt_running" : "revoke", interruptRunning: interruptOnly ? nil : interruptRunning,
            revokeSeq: nil, recordId: UUID().uuidString.lowercased(), issuedAt: time, integrationId: fresh.id, by: "owner")
        let mirror = interruptOnly ? nil : try RemoteControlPortalMirror(issuer: portal.configuration.issuer,
            ownerAccount: portal.ownerAccount, stationOrigin: relayURL, integrationID: fresh.id, interruptRunning: interruptRunning)
        let request = try controls().prepare(body: body, log: log, portalMirror: mirror)
        return ServiceControlReview(integrationID: fresh.id, integrationName: fresh.name, issuer: portal.configuration.issuer,
            ownerAccount: portal.ownerAccount, stationOrigin: relayURL, recordID: body.recordId, body: body, request: request)
    }

    /// Fresh confirmation happens only after the exact draft has been durably saved.
    func commitServiceControl(_ review: ServiceControlReview, portal: PortalIntegrationHTTP,
        current: () -> Bool) async throws -> RemoteControlDelivery {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        guard current(), review.issuer == portal.configuration.issuer, review.ownerAccount == portal.ownerAccount,
              review.stationOrigin == relayURL, let kit = try currentKit() else { throw AccountLoginError.changed }
        let journal = try controls()
        if try journal.retainedDelivery(recordID: review.recordID) == nil {
            guard try journal.signingRequest(recordID: review.recordID) == review.request else {
                throw RemoteRecoveryError.requiresReview
            }
            try await signControl(recordID: review.recordID, request: review.request, genesis: kit.genesisHash, current: current)
        }
        return try await deliverControl(review.recordID, portal: portal, current: current)
    }

    func cancelUnsignedControl(_ review: ServiceControlReview) throws {
        guard !busy, !uncertain else { throw RemoteRecoveryError.busy }
        try controls().cancelUnsigned(recordID: review.recordID, authorJournal: readControlJournal)
    }

    /// Existing signatures and Portal intents are retried; no owner approval is reused.
    func retryPendingControls(portal: PortalIntegrationHTTP, stationOrigin: String? = nil,
        current: () -> Bool) async throws -> [RemoteControlDelivery] {
        try begin(); defer { busy = false }
        guard delegatedControlsAvailable else { throw AstationDelegatedControlError.notVerified }
        let origin = stationOrigin ?? relayURL
        guard origin == relayURL || saved.controlPublications?[origin] != nil else {
            throw RemoteChannelError.staleLink
        }
        var results: [RemoteControlDelivery] = []
        let pending = try controls(stationOrigin: origin).pendingDeliveryIDs()
        let start = lastControlDeliveryRecord[origin].flatMap { pending.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        // Unavailable records must not keep later signed stops outside every batch.
        let batch = (Array(pending.dropFirst(start)) + Array(pending.prefix(start))).prefix(8)
        for id in batch {
            guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
            lastControlDeliveryRecord[origin] = id
            results.append(try await deliverControl(id, portal: portal, stationOrigin: origin, current: current))
        }
        return results
    }

    private func deliverControl(_ id: String, portal: PortalIntegrationHTTP?, stationOrigin: String? = nil,
        current: () -> Bool) async throws -> RemoteControlDelivery {
        guard current(), !Task.isCancelled, let kit = try currentKit() else {
            throw RemoteChannelError.staleLink
        }
        let journal = try controls(stationOrigin: stationOrigin)
        guard let delivery = try journal.retainedDelivery(recordID: id) else { throw RemoteRecoveryError.notCommitted }
        let origins = try journal.stationOrigins(recordID: id)
        for origin in origins where try journal.stationDeliveryNeeded(recordID: id, stationOrigin: origin) {
            do {
                guard let anchor = membershipLog?.snapshot() else { throw RemoteChannelError.staleLink }
                let membershipTransport = try controlDeliverySource(origin: origin, approvedOrigins: origins, log: anchor)
                guard let target = membershipTransport as? RemoteControlTransport else { throw RemoteChannelError.staleLink }
                let log = try await refreshedLog(genesis: kit.genesisHash, transport: membershipTransport)
                try requireDelegatedControl(log)
                guard current(), !Task.isCancelled, let verified = try journal.delivery(recordID: id, log: log) else {
                    throw RemoteChannelError.staleLink
                }
                _ = try controlDeliverySource(origin: origin, approvedOrigins: origins, log: log)
                _ = try await target.publishControl(log: log, recordJSON: verified.recordJSON)
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                _ = try controlDeliverySource(origin: origin, approvedOrigins: origins, log: log)
                try journal.stationStored(verified, stationOrigin: origin)
            } catch {
                guard !uncertain, !journal.storageUncertain else { throw RemoteRecoveryError.storageUncertain }
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                Log.warn("[Delegated] Signed stop retained for Station retry or a fresh manager review")
            }
        }
        // This independent leg remains necessary even if Station is down or the signer lost manage.
        if let mirror = delivery.portalMirror, !delivery.portalSettled, let portal {
            do {
                let result = try await portal.mirrorRevoke(mirror)
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                switch result {
                case .confirmed: try journal.portalMirrored(delivery)
                case .finalRefusal(let reason): try journal.portalRefused(delivery, reason: reason)
                }
            } catch {
                guard !uncertain, !journal.storageUncertain else { throw RemoteRecoveryError.storageUncertain }
                guard current(), !Task.isCancelled else { throw RemoteChannelError.staleLink }
                Log.warn("[Delegated] Native revoke retained for Portal retry")
            }
        }
        guard let result = try journal.retainedDelivery(recordID: id) else { throw RemoteRecoveryError.notCommitted }
        return result
    }

    /// A retained signature authorizes only its protected, previously reviewed
    /// destinations. Selection changes never add a destination or sign again.
    private func controlDeliverySource(origin: String, approvedOrigins: [String], log: MembershipLog) throws -> RemoteRecoveryTransport {
        guard approvedOrigins.contains(origin), PortalIntegrationRecord.validOrigin(origin) else {
            throw RemoteRecoveryError.requiresReview
        }
        if origin == relayURL { return http }
        let source: RemoteControlStationTransport
        if let current = try controlStationTransports(log)[origin] { source = current }
        else if let retainedControlTransport { source = try retainedControlTransport(origin) }
        else { throw RemoteChannelError.staleLink }
        guard source.controlStationOrigin == origin else { throw RemoteRecoveryError.requiresReview }
        return source
    }

    private func controlStationTransports(_ log: MembershipLog) throws -> [String: RemoteControlStationTransport] {
        let targets = try additionalControlStations?(log) ?? [:]
        guard targets.count <= 63, targets[relayURL] == nil,
              targets.allSatisfy({ origin, transport in
                  PortalIntegrationRecord.validOrigin(origin) && transport.controlStationOrigin == origin
              }) else {
            throw RemoteRecoveryError.requiresReview
        }
        return targets
    }
}

enum AstationDelegatedControlError: LocalizedError {
    case notVerified
    var errorDescription: String? { "Delegated controls are waiting for the Station and native verification checks. Your existing access is unchanged." }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
