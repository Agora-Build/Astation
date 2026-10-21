import AtemClient
import Foundation

public enum RemotePublicationError: Error, Equatable {
    case busy
    case invalidCheckpoint
    case storageUncertain
    case requiresRefresh
}

/// The caller's protected store must commit the entire checkpoint durably or throw.
/// This adapter never sends an entry; only a successful relay reply can extend its log.
@MainActor
public final class RemoteMembershipPublication {
    private struct Checkpoint: Codable {
        let version: Int
        let accountID: String
        let genesisHash: String
        let entries: [String]
        let prepared: String?
        let requiresRefresh: Bool
        let membership: String?
    }

    private var log: MembershipLog
    private var publisher: EntryPublisher
    private let persist: (Data) throws -> Void
    private var operating = false
    public private(set) var storageUncertain = false
    public private(set) var requiresRefresh = false

    public var head: LogHead { log.head() }
    public var entries: [String] { log.entries() }

    public init(log: MembershipLog, persist: @escaping (Data) throws -> Void) {
        self.log = log.snapshot()
        publisher = EntryPublisher()
        self.persist = persist
    }

    public init(
        checkpoint: Data, accountID: String, genesisHash: String, now: HostClock,
        persist: @escaping (Data) throws -> Void
    ) throws {
        guard checkpoint.count <= 8_388_608 else {
            throw RemotePublicationError.invalidCheckpoint
        }
        let saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        guard saved.version == 1, saved.accountID == accountID, saved.genesisHash == genesisHash else {
            throw RemotePublicationError.invalidCheckpoint
        }
        log = try RemoteMembershipCheckpoint.load(accountID: accountID, genesisHash: genesisHash,
            entries: saved.entries, storedJSON: saved.membership, now: now)
        publisher = try saved.prepared.map { try EntryPublisher.resume(preparedJson: $0) } ?? EntryPublisher()
        requiresRefresh = saved.requiresRefresh
        self.persist = persist
        try transaction { _, _ in }
    }

    public func committedLog() throws -> MembershipLog {
        try checkAvailable()
        return log.snapshot()
    }

    /// Persist the exact body before a key provider can see it.
    @discardableResult
    public func prepare(actionJSON: String, signer: String, signedAt: UInt64) throws -> String {
        guard !requiresRefresh else { throw RemotePublicationError.requiresRefresh }
        return try transaction { log, publisher in
            let body = try log.draftEntry(signer: signer, signedAt: signedAt, actionJson: actionJSON)
            try publisher.prepare(log: log, bodyJson: body)
            return body
        }
    }

    /// The ceremony supplies the channel key from its verified reveal, never relay presence.
    @discardableResult
    public func prepareHost(
        commit: RemotePairingCommit, hostChannelKey: PublicKeyData, signer: String, signedAt: UInt64
    ) throws -> String {
        try checkAvailable()
        guard commit.context.accountID == log.accountId(), hostChannelKey.alg == .ed25519 else {
            throw RemoteChannelError.invalidInput
        }
        try checkPublicKey(key: hostChannelKey)
        let encodedKey = hostChannelKey.raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let action: [String: Any] = ["action": "add_host", "host": [
            "host_id": commit.context.hostID, "host_trust_gen": commit.hostTrustGeneration,
            "host_key": ["alg": "ed25519", "pub": encodedKey]
        ]]
        let actionJSON = String(decoding: try JSONSerialization.data(withJSONObject: action), as: UTF8.self)
        return try prepare(actionJSON: actionJSON, signer: signer, signedAt: signedAt)
    }

    /// Retries return the already stored signature, including for nondeterministic P-256 keys.
    public func sign(provider: AppKeyProvider, keyID: String, cosignKit: RecoveryKitHandle? = nil) throws -> AppendRequest {
        try checkAvailable()
        guard !requiresRefresh else { throw RemotePublicationError.requiresRefresh }
        if let request = publisher.outstanding() { return request }
        return try transaction { _, publisher in
            try publisher.sign(provider: provider, keyId: keyID, cosignKit: cosignKit)
        }
    }

    public func outstanding() throws -> AppendRequest? {
        try checkAvailable()
        guard !requiresRefresh else { throw RemotePublicationError.requiresRefresh }
        return publisher.outstanding()
    }

    @discardableResult
    public func relayStored(now: HostClock) throws -> PublishOutcome {
        try transaction(refreshAfter: Self.needsRefresh) { log, publisher in try publisher.replyStored(log: log, now: now) }
    }

    @discardableResult
    public func relayConflict(head: LogHead, entries: [String], more: Bool, now: HostClock) throws -> PublishOutcome {
        try transaction(refreshAfter: Self.needsRefresh) { log, publisher in
            try publisher.replyConflict(log: log, head: head, entries: entries, more: more, now: now)
        }
    }

    private func checkAvailable() throws {
        guard !storageUncertain else { throw RemotePublicationError.storageUncertain }
        guard !operating else { throw RemotePublicationError.busy }
    }

    private static func needsRefresh(_ outcome: PublishOutcome) -> Bool {
        switch outcome {
        case .committed, .lostRace: return false
        default: return true
        }
    }

    private func transaction<T>(
        refreshAfter: ((T) -> Bool)? = nil, _ operation: (MembershipLog, EntryPublisher) throws -> T
    ) throws -> T {
        try checkAvailable()
        operating = true
        defer { operating = false }
        let candidateLog = log.snapshot()
        // EntryPublisher owns the process-wide claim for this manager; never clone/resume it live.
        let result = try operation(candidateLog, publisher)
        let nextRequiresRefresh = refreshAfter?(result) ?? requiresRefresh
        do {
            let checkpoint = Checkpoint(version: 1, accountID: candidateLog.accountId(),
                genesisHash: candidateLog.genesisHash(), entries: candidateLog.entries(),
                prepared: publisher.preparedJson(), requiresRefresh: nextRequiresRefresh,
                membership: try candidateLog.storedJson())
            // A complete log may exceed the shared JSON helper's 1 MiB per-message bound.
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let bytes = try encoder.encode(checkpoint)
            guard bytes.count <= 8_388_608 else { throw RemotePublicationError.invalidCheckpoint }
            try persist(bytes)
        } catch {
            // A throwing store may have committed. Only a protected-store reload can reconcile it.
            storageUncertain = true
            throw error
        }
        log = candidateLog
        requiresRefresh = nextRequiresRefresh
        return result
    }
}
