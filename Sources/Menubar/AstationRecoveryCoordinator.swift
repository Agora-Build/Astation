import AtemClient
import AstationRemote
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
        var publication: Data?
        var hostBody: String?
        var backup: Data?
        var restoreKit: String?
        var restore: Data?
        var pendingDataKey: SavedKey?
    }

    nonisolated static let bootID = UUID().uuidString
    nonisolated static func clock() -> HostClock {
        HostClock(wallMs: UInt64(max(0, Date().timeIntervalSince1970 * 1000)),
            monoMs: DispatchTime.now().uptimeNanoseconds / 1_000_000, bootId: bootID)
    }

    let accountID: String
    let managerID: String
    private let store: AstationRecoveryCheckpointStorage
    private let identity: AtemE2EIdentity
    private let http: RemoteRecoveryTransport
    private let relayURL: String
    private let allowNewDataKey: () -> Bool
    private let confirmOwner: (SignRequest) async -> Bool
    private let confirmReplacement: (String) async -> Bool
    private let saveKit: (String) async -> Bool
    private let dataKeys: AstationRecoveryDataKeys
    private var saved: Saved
    private var bootstrap: RemoteRecoveryBootstrap?
    private var publication: RemoteMembershipPublication?
    private var backup: RemoteRecoveryBackup?
    private var restoreOperation: RemoteRecoveryRestore?
    private var membershipLog: MembershipLog?
    private var busy = false
    private var uncertain = false

    convenience init(accountID: String, managerID: String, identity: AtemE2EIdentity, relayURL: String,
        tokenProvider: SsoTokenProvider, allowNewDataKey: @escaping () -> Bool) throws {
        try self.init(accountID: accountID, managerID: managerID, identity: identity, relayURL: relayURL,
            store: RemoteRecoveryStore(accountID: accountID),
            transport: RemoteRecoveryHTTP(relayURL: relayURL, accessToken: { try await tokenProvider.validToken() }),
            dataKeys: DataEncryptionKeyManager.shared, allowNewDataKey: allowNewDataKey,
            confirmOwner: { request in
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: "confirm this account's \(request.purpose == .genesis ? "recovery setup" : "encrypted key backup")") {
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
            })
    }

    init(accountID: String, managerID: String, identity: AtemE2EIdentity, relayURL: String,
        store: AstationRecoveryCheckpointStorage, transport: RemoteRecoveryTransport, dataKeys: AstationRecoveryDataKeys,
        allowNewDataKey: @escaping () -> Bool, confirmOwner: @escaping (SignRequest) async -> Bool,
        confirmReplacement: @escaping (String) async -> Bool, saveKit: @escaping (String) async -> Bool) throws {
        self.accountID = accountID
        self.managerID = managerID
        self.identity = identity
        self.relayURL = relayURL
        self.allowNewDataKey = allowNewDataKey
        self.store = store
        http = transport
        self.dataKeys = dataKeys
        self.confirmOwner = confirmOwner
        self.confirmReplacement = confirmReplacement
        self.saveKit = saveKit
        if let data = try store.read() {
            saved = try PropertyListDecoder().decode(Saved.self, from: data)
            guard saved.version == 2, saved.accountID == accountID, saved.managerID == managerID else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
        } else { saved = Saved(accountID: accountID, managerID: managerID) }
    }

    private func persist(_ change: (inout Saved) -> Void) throws {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        var next = saved
        change(&next)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try store.write(encoder.encode(next))
            saved = next
        } catch { uncertain = true; throw error }
    }

    private func begin() throws {
        guard !uncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !busy else { throw RemoteRecoveryError.busy }
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
        let value = try RemoteRecoveryBootstrap(checkpoint: checkpoint, accountID: accountID, now: Self.clock(),
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
            return kit
        }
        var value = try loadBootstrap()
        if value == nil {
            let keys = try identity.remotePublicKeys()
            value = try RemoteRecoveryBootstrap(accountID: accountID, managerID: managerID, keyID: managerID,
                authKey: PublicKeyData(alg: .p256, raw: keys.signing),
                encryptionKey: PublicKeyData(alg: .x25519, raw: keys.encryption),
                recoverySecret: AtemSecureEnclaveCryptography.random32(), relayURL: relayURL, signedAt: Self.clock().wallMs,
                persist: { [unowned self] bytes in try self.persist { $0.bootstrap = bytes } })
            bootstrap = value
        }
        let operation = value!
        if (try? operation.committedLog(now: Self.clock())) == nil {
            let request: AppendRequest
            if let outstanding = try operation.outstanding() { request = outstanding }
            else {
                let signer = try await confirmed(operation.signingRequest())
                request = try operation.sign(provider: signer, now: Self.clock())
            }
            switch try await http.append(genesisHash: operation.genesisHash, request: request) {
            case .stored: break
            case .conflict: throw RemoteRecoveryError.requiresReview
            }
            try operation.relayStored(now: Self.clock())
        }
        if saved.entries.isEmpty {
            let entries = try operation.committedLog(now: Self.clock()).entries()
            try persist { $0.entries = entries }
        }
        let kit = try operation.kit(now: Self.clock())
        let currentLog = try await refreshedLog(genesis: kit.genesisHash)
        guard currentLog.recoveryKey() == (try operation.committedLog(now: Self.clock())).recoveryKey() else {
            throw RemoteRecoveryError.kitNotCurrent
        }
        if !operation.recoveryIsSaved {
            let accepted = await saveKit(kit.text())
            guard accepted else { throw AtemIdentityError.recoveryNotSaved }
            try operation.markKitSaved(kit, now: Self.clock())
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
        guard let genesis = keys.genesisHash else { throw AtemIdentityError.invalidState }
        let log = try await refreshedLog(genesis: genesis)
        if let checkpoint = saved.publication {
            publication = nil
            publication = try RemoteMembershipPublication(checkpoint: checkpoint, accountID: accountID,
                genesisHash: log.genesisHash(), now: Self.clock(), persist: { [unowned self] bytes in try self.persist { $0.publication = bytes } })
            if let body = saved.hostBody, try publication?.outstanding() != nil {
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
            hostChannelKey: PublicKeyData(alg: .ed25519, raw: reveal.hostChannelPublicKey), signer: managerID, signedAt: Self.clock().wallMs)
        try persist { $0.hostBody = body }
        return try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID)
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
            guard case .committed = try publication.relayStored(now: Self.clock()) else { throw RemoteRecoveryError.requiresReview }
        case .conflict(let page):
            _ = try publication.relayConflict(head: page.head, entries: page.entries, more: page.more, now: Self.clock())
            let entries = publication.entries
            try persist { $0.entries = entries; $0.publication = nil; $0.hostBody = nil }
            self.publication = nil
            throw RemoteRecoveryError.confirmationRequired
        }
        let entries = publication.entries
        try persist { $0.entries = entries; $0.publication = nil; $0.hostBody = nil }
        self.publication = nil
        guard current() else { throw RemoteChannelError.staleLink }
        return entries
    }

    func cancelUnsignedHost(request: SignRequest) throws {
        guard !busy, saved.hostBody == request.bodyJson, try publication?.outstanding() == nil else { return }
        try persist { $0.publication = nil; $0.hostBody = nil }
        publication = nil
    }

    private func refreshedLog(genesis: String) async throws -> MembershipLog {
        guard !saved.entries.isEmpty else { throw RemoteRecoveryError.notCommitted }
        let log: MembershipLog
        if let previous = membershipLog, previous.entries() == saved.entries {
            log = previous.snapshot()
        } else {
            log = try MembershipLog.verify(accountId: accountID, genesisHash: genesis, entries: saved.entries, now: Self.clock())
        }
        _ = log.advance(now: Self.clock())
        for _ in 0..<128 {
            let page = try await http.entries(genesisHash: genesis, after: log.head().seq)
            let result = try log.extend(entries: page.entries, now: Self.clock())
            guard result.stop == nil, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
            if !page.more {
                guard log.head() == page.head else { throw RemoteRecoveryTransportError.invalidResponse }
                let entries = log.entries()
                try persist { $0.entries = entries }
                membershipLog = log
                return log
            }
            guard !page.entries.isEmpty else { throw RemoteRecoveryTransportError.invalidResponse }
        }
        throw RemoteRecoveryTransportError.invalidResponse
    }

    private func currentKit() throws -> RemoteRecoveryKit? {
        if let text = saved.restoreKit { return try RemoteRecoveryKit(text: text) }
        return try loadBootstrap()?.kit(now: Self.clock())
    }

    private func requireManager(_ log: MembershipLog) throws {
        let keys = try identity.remotePublicKeys()
        guard let manager = log.member(deviceId: managerID) else { throw RemoteRecoveryError.requiresReview }
        guard manager.status != .pending else { throw RemoteRecoveryError.enrollmentPending }
        guard manager.status == .active, manager.roles.contains("manage"),
              manager.authKey == PublicKeyData(alg: .p256, raw: keys.signing),
              manager.encKey == PublicKeyData(alg: .x25519, raw: keys.encryption) else { throw RemoteRecoveryError.requiresReview }
    }

    private func finishBackup() async throws {
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
        try requireManager(log)
        if saved.backup == nil, let committed = log.kBackup(), committed.kids == keys.map(\.kid),
           committed.recoveryKey == kit.recoveryKey {
            let envelope = try await http.backup(log: log)
            guard try kit.openBackup(envelope) == keys.map({ AccountKey(kid: $0.kid, k: $0.key) }) else {
                throw AtemIdentityError.identityChanged
            }
            try installPendingKey()
            return
        }
        if backup == nil {
            if let checkpoint = saved.backup {
                backup = try RemoteRecoveryBackup(checkpoint: checkpoint, accountID: accountID, genesisHash: genesis,
                    now: Self.clock(), persist: { [unowned self] bytes in try self.persist { $0.backup = bytes } })
            } else {
                backup = try RemoteRecoveryBackup(log: log, kids: keys.map(\.kid), signer: managerID,
                    persist: { [unowned self] bytes in try self.persist { $0.backup = bytes } })
            }
        }
        let operation = backup!
        for _ in 0..<128 {
            guard !operation.storageUncertain else { throw RemoteRecoveryError.storageUncertain }
            switch operation.step {
            case .seal:
                _ = try operation.seal(keys: keys.map { AccountKey(kid: $0.kid, k: $0.key) }, signedAt: Self.clock().wallMs)
            case .sign(let body):
                let signer = try await confirmed(RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: managerID))
                _ = try operation.sign(provider: signer, keyID: managerID)
            case .put(_, let bytes):
                let occupied = try await http.uploadBackup(genesisHash: genesis, envelopeJSON: bytes, signedEntryJSON: operation.uploadEntryJSON())
                _ = try operation.uploadReply(maxOccupied: occupied)
            case .append(let request):
                switch try await http.append(genesisHash: genesis, request: request) {
                case .stored: _ = try operation.relayStored(now: Self.clock(), signedAt: Self.clock().wallMs)
                case .conflict(let page): _ = try operation.relayConflict(head: page.head, entries: page.entries,
                    more: page.more, now: Self.clock(), signedAt: Self.clock().wallMs)
                }
            case .fetch(let after):
                let page = try await http.entries(genesisHash: genesis, after: after)
                _ = try operation.fetched(entries: page.entries, more: page.more, now: Self.clock(), signedAt: Self.clock().wallMs)
            case .done:
                let entries = operation.committedEntries
                try persist { $0.entries = entries; $0.backup = nil }
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
        let log = try MembershipLog.verify(accountId: kit.accountID, genesisHash: kit.genesisHash, entries: entries, now: Self.clock())
        guard log.head() == head, log.frozen() == nil else { throw RemoteRecoveryError.requiresReview }
        let envelope = try await http.backup(log: log)
        try operation.fetched(entries: entries, envelopeJSON: envelope, now: Self.clock())
        guard case .waitingForHost(let hosts) = operation.phase else { throw RemoteRecoveryError.requiresReview }
        for host in hosts {
            do {
                let probe = try operation.beginHostProbe(hostID: host, replacementDeviceID: managerID, now: Self.clock())
                let accept = try await http.hostAccept(genesisHash: kit.genesisHash, hostID: host, initFrame: probe.frame)
                try operation.receivedHostAccept(accept, probeID: probe.id, now: Self.clock())
                _ = try operation.attempt(now: Self.clock())
                break
            } catch {
                if operation.phase == .storageUncertain { throw error }
            }
        }
        guard operation.phase == .readyToEnroll || operation.phase == .enrollmentPending || operation.phase == .published else {
            return operation.statusText
        }
        let recovered = try operation.recoveredKeys()
        try dataKeys.installRecovered(recovered.map { AccountDataKey(kid: $0.kid, key: $0.k) }, dataAccount: accountID)
        let verified = try operation.verifiedEntries()
        try persist { $0.entries = verified }
        try identity.markRecoverySaved(signingPublicKey: identity.remotePublicKeys().signing)
        if operation.phase == .published {
            if let member = log.member(deviceId: managerID), member.status == .active {
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
            request = try operation.enroll(confirmedMemberJSON: json, signedAt: Self.clock().wallMs)
        }
        switch try await http.append(genesisHash: kit.genesisHash, request: request) {
        case .stored:
            _ = try operation.relayStored(now: Self.clock())
            let entries = try operation.verifiedEntries()
            try persist { $0.entries = entries }
        case .conflict(let page):
            _ = try operation.relayConflict(head: page.head, entries: page.entries, more: page.more, now: Self.clock())
        }
        return operation.statusText
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
