import AtemClient
import Foundation

/// Durable platform adapter for the shared backup writer. K stays in the caller's key store.
@MainActor
public final class RemoteRecoveryBackup {
    private struct Checkpoint: Codable {
        var version = 1
        let accountID: String
        let genesisHash: String
        let entries: [String]
        let prepared: String?
        let committedVersion: UInt64?
        let failure: String?
        let membership: String?
    }

    private var log: MembershipLog
    private var writer: KBackupWriter?
    private let persist: (Data) throws -> Void
    private var operating = false
    public private(set) var storageUncertain = false
    public private(set) var step: BackupStep
    public var committedEntries: [String] { log.entries() }

    public func committedLog() throws -> MembershipLog {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !operating else { throw RemoteRecoveryError.busy }
        return log.snapshot()
    }

    /// The shared writer's documented durable form contains the signature
    /// already committed before upload. Reading it does not advance the writer.
    public func uploadEntryJSON() throws -> String {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !operating, case .put = step, let saved = writer?.preparedJson(),
              let value = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any],
              let writerState = value["writer"] as? [String: Any],
              let prepared = writerState["prepared"] as? [String: Any], let signed = prepared["signed"] else {
            throw RemoteChannelError.notReady
        }
        let json = try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: signed), as: UTF8.self))
        guard try signedObjectInfo(json: json).bodyType == "atem-membership-entry" else { throw RemoteRecoveryError.invalidCheckpoint }
        return json
    }

    public init(log: MembershipLog, kids: [String], signer: String, persist: @escaping (Data) throws -> Void) throws {
        self.log = log.snapshot()
        let writer = try KBackupWriter.start(log: self.log, kids: kids, kitRecoveryKey: log.recoveryKey(), signer: signer)
        self.writer = writer
        self.persist = persist
        step = writer.step()
        try checkpoint()
    }

    public init(checkpoint: Data, accountID: String, genesisHash: String, now: HostClock,
        persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
        let saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        guard saved.version == 1, saved.accountID == accountID, saved.genesisHash == genesisHash else {
            throw RemoteRecoveryError.invalidCheckpoint
        }
        log = try RemoteMembershipCheckpoint.load(accountID: accountID, genesisHash: genesisHash,
            entries: saved.entries, storedJSON: saved.membership, now: now)
        self.persist = persist
        if let prepared = saved.prepared {
            guard saved.committedVersion == nil, saved.failure == nil else { throw RemoteRecoveryError.invalidCheckpoint }
            let writer = try KBackupWriter.resume(savedJson: prepared)
            self.writer = writer
            step = try writer.restart()
        } else if let version = saved.committedVersion {
            guard saved.failure == nil, log.kBackup()?.blobVersion == version else { throw RemoteRecoveryError.invalidCheckpoint }
            step = .done(committed: version)
        } else if let failure = saved.failure {
            step = .failed(code: failure, detail: "The saved backup operation stopped; its state was retained.")
        } else { throw RemoteRecoveryError.invalidCheckpoint }
        try self.checkpoint()
    }

    @discardableResult
    public func seal(keys: [AccountKey], signedAt: UInt64) throws -> BackupStep {
        guard case .seal(let version) = step else { throw RemoteChannelError.notReady }
        return try transaction { log, writer in
            let envelope = try sealKBackup(accountId: log.accountId(), genesisHash: log.genesisHash(),
                blobVersion: version, recoveryKey: log.recoveryKey(), keys: keys)
            return try writer.sealed(log: log, envelopeJson: envelope, signedAt: signedAt)
        }
    }

    @discardableResult
    public func sign(provider: AppKeyProvider, keyID: String) throws -> BackupStep {
        guard case .sign = step else { throw RemoteChannelError.notReady }
        return try transaction { _, writer in try writer.sign(provider: provider, keyId: keyID) }
    }

    @discardableResult
    public func uploadReply(maxOccupied: UInt64?) throws -> BackupStep {
        guard case .put = step else { throw RemoteChannelError.notReady }
        return try transaction { log, writer in try writer.putReply(log: log, maxOccupied: maxOccupied) }
    }

    @discardableResult
    public func relayStored(now: HostClock, signedAt: UInt64) throws -> BackupStep {
        guard case .append = step else { throw RemoteChannelError.notReady }
        return try transaction { log, writer in try writer.appendStored(log: log, now: now, signedAt: signedAt) }
    }

    @discardableResult
    public func relayConflict(head: LogHead, entries: [String], more: Bool, now: HostClock, signedAt: UInt64) throws -> BackupStep {
        guard case .append = step else { throw RemoteChannelError.notReady }
        return try transaction { log, writer in
            try writer.appendConflict(log: log, head: head, entries: entries, more: more, now: now, signedAt: signedAt)
        }
    }

    @discardableResult
    public func fetched(entries: [String], more: Bool, now: HostClock, signedAt: UInt64) throws -> BackupStep {
        guard case .fetch = step else { throw RemoteChannelError.notReady }
        return try transaction { log, writer in try writer.fetched(log: log, entries: entries, more: more, now: now, signedAt: signedAt) }
    }

    private func transaction(_ operation: (MembershipLog, KBackupWriter) throws -> BackupStep) throws -> BackupStep {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !operating, let writer else { throw RemoteRecoveryError.busy }
        operating = true
        defer { operating = false }
        let candidate = log.snapshot()
        let result = try operation(candidate, writer)
        try checkpoint(log: candidate, step: result)
        log = candidate
        step = result
        return result
    }

    private func checkpoint(log: MembershipLog? = nil, step: BackupStep? = nil) throws {
        let log = log ?? self.log
        let step = step ?? self.step
        let committed: UInt64?
        let failure: String?
        switch step {
        case .done(let version): committed = version; failure = nil
        case .failed(let code, _): committed = nil; failure = code
        default: committed = nil; failure = nil
        }
        do {
            let saved = Checkpoint(accountID: log.accountId(), genesisHash: log.genesisHash(), entries: log.entries(),
                prepared: writer?.preparedJson(), committedVersion: committed, failure: failure,
                membership: try log.storedJson())
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let bytes = try encoder.encode(saved)
            guard bytes.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
            try persist(bytes)
        } catch { storageUncertain = true; throw error }
    }
}
