import AtemClient
import Foundation

public struct RemotePushNotice: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// A nil content uses generic OS text when the protected key is unavailable.
        case approval(HintContent?)
        case resolved(reason: String)
    }
    public let approval: ApprovalRef
    public let state: State
}

/// Verifies hints and commits sealed dedup state before presentation. A notice
/// only selects authenticated catch-up; it never creates an actionable approval.
@MainActor
public final class RemotePushHints {
    private struct Record: Codable { let hint: String; let receivedAt: UInt64 }
    private struct Saved: Codable {
        let version: Int
        let account: String
        let genesis: String
        let device: String
        var records: [Record]
    }
    private var saved: Saved
    private let persist: (Data) throws -> Void
    public private(set) var storageUncertain = false

    public init(accountID: String, genesisHash: String, deviceID: String,
                checkpoint: Data? = nil, persist: @escaping (Data) throws -> Void) throws {
        guard !accountID.isEmpty, !deviceID.isEmpty, genesisHash.utf8.count == 64 else { throw RemoteChannelError.invalidInput }
        if let checkpoint {
            guard checkpoint.count <= 4 * 1024 * 1024,
                  let value = try? JSONDecoder().decode(Saved.self, from: checkpoint), value.version == 1,
                  value.account == accountID, value.genesis == genesisHash, value.device == deviceID,
                  value.records.count <= 512 else { throw RemoteRecoveryError.invalidCheckpoint }
            saved = value
        } else { saved = Saved(version: 1, account: accountID, genesis: genesisHash, device: deviceID, records: []) }
        self.persist = persist
    }

    /// The host signature, current member role and recipient key are checked
    /// before decryption. Extension code must not request interactive signing.
    public func receive(hintJSON: String, log: MembershipLog, now: UInt64,
                        open: ((PushHint) throws -> HintContent)? = nil) throws -> RemotePushNotice? {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        let hint = try verified(hintJSON, log: log, now: now)
        let book = PushHintBook()
        var records: [Record] = []
        for record in saved.records {
            // A legitimate host/key/membership replacement invalidates old hints.
            guard let previous = try? verified(record.hint, log: log, now: now) else { continue }
            _ = try book.offer(hint: previous)
            records.append(record)
        }
        let offer = try book.offer(hint: hint)
        guard offer == .accepted else { return nil }
        records.append(Record(hint: hint.json(), receivedAt: now))
        guard records.count <= 512 else { throw RemoteChannelWriteError.busy }
        var next = saved
        next.records = records
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 4 * 1024 * 1024 else { throw RemoteChannelWriteError.tooLarge }
        do { try persist(bytes) }
        catch { storageUncertain = true; throw RemoteRecoveryError.storageUncertain }
        saved = next
        switch hint.state() {
        case .open:
            return RemotePushNotice(approval: hint.approval(), state: .approval(try? open?(hint)))
        case .resolved(let reason, _):
            return RemotePushNotice(approval: hint.approval(), state: .resolved(reason: reason))
        }
    }

    /// A tap always verifies again against current membership, then reconnects
    /// for host state even when the original delivery was already displayed.
    public func target(hintJSON: String, log: MembershipLog, now: UInt64) throws -> ApprovalRef {
        try verified(hintJSON, log: log, now: now).approval()
    }

    private func verified(_ json: String, log: MembershipLog, now: UInt64) throws -> PushHint {
        guard log.accountId() == saved.account, log.genesisHash() == saved.genesis,
              let member = log.member(deviceId: saved.device), member.kind == "native",
              member.status == .active, member.roles.contains("control") else { throw RemoteChannelError.notReady }
        let hint = try verifyPushHint(hintJson: json, log: log, nowMs: now, verifier: .client)
        try hint.checkSealed()
        if case .open(let device, let kid, _) = hint.state() {
            guard device == saved.device, let key = member.encKey, try encKid(encKey: key) == kid else {
                throw RemoteChannelError.invalidInput
            }
        }
        return hint
    }
}
