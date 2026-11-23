import AtemClient
import CryptoKit
import Foundation

/// The device keeps every possibly signed stop under the member key, across
/// ordinary delivery, manager re-signs, recovery copies and Station origins.
@MainActor
public final class RemoteControlSigningJournal {
    private struct Entry: Codable {
        let body: String
        var record: String?
    }

    private struct Checkpoint: Codable {
        let version: Int
        let account: String
        let genesis: String
        let member: String
        let algorithm: String
        let key: Data
        let id: Data
        let since: UInt64
        var revision: UInt64
        var entries: [String: Entry]
    }

    private let read: () throws -> Data?
    private let persist: (Data) throws -> Void
    private let key: PublicKeyData
    private var saved: Checkpoint
    private var expected: Data?
    private var operating = false
    private var uncertain = false

    public var storageScope: String {
        let keyScope = Self.keyScope(key)
        return Self.scope(keyScope: keyScope, account: saved.account, genesis: saved.genesis, memberID: saved.member)
    }

    private static func keyScope(_ key: PublicKeyData) -> String {
        let algorithm = key.alg == .p256 ? "p256" : "ed25519"
        return hashFields(fields: [Data("astation-stop-author-v1".utf8), Data(algorithm.utf8), key.raw])
    }

    private static func scope(keyScope: String, account: String, genesis: String, memberID: String) -> String {
        hashFields(fields: [keyScope, account, genesis, memberID].map { Data($0.utf8) })
    }

    public var id: Data { saved.id }
    public var revision: UInt64 { saved.revision }

    public convenience init(log: MembershipLog, memberID: String) throws {
        guard let key = log.member(deviceId: memberID)?.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        let keyScope = Self.keyScope(key)
        let scope = Self.scope(keyScope: keyScope, account: log.accountId(), genesis: log.genesisHash(), memberID: memberID)
        let store = try RemoteRecoveryStore(controlJournalScope: scope, keyScope: keyScope)
        try self.init(log: log, memberID: memberID, read: { try store.read() }, persist: { try store.write($0) })
    }

    /// The backing store must hold the key's interprocess lock until this journal is released.
    public init(log: MembershipLog, memberID: String, read: @escaping () throws -> Data?,
                persist: @escaping (Data) throws -> Void) throws {
        guard log.frozen() == nil, let member = log.member(deviceId: memberID), member.kind == "native" else {
            throw RemoteControlPublicationError.requiresReview
        }
        self.read = read
        self.persist = persist
        key = member.authKey
        let algorithm = key.alg == .p256 ? "p256" : "ed25519"
        expected = try read()
        if let bytes = expected {
            guard bytes.count <= 8_388_608 else { throw RemoteControlPublicationError.invalidCheckpoint }
            saved = try PropertyListDecoder().decode(Checkpoint.self, from: bytes)
            guard saved.version == 1, saved.account == log.accountId(), saved.genesis == log.genesisHash(),
                  saved.member == memberID, saved.algorithm == algorithm, saved.key == key.raw,
                  saved.id.count == 16, saved.since > 0, saved.since <= log.head().seq,
                  saved.revision <= 9_007_199_254_740_991, saved.entries.count <= 4096 else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            var minimumRevision = UInt64(saved.entries.count)
            for (id, entry) in saved.entries {
                let body = try checkedBody(entry.body)
                guard body.recordId == id else { throw RemoteControlPublicationError.invalidCheckpoint }
                if let record = entry.record {
                    try checkRecord(record, bodyJSON: entry.body)
                    minimumRevision += 1
                }
            }
            guard saved.revision >= minimumRevision else { throw RemoteControlPublicationError.invalidCheckpoint }
        } else {
            saved = Checkpoint(version: 1, account: log.accountId(), genesis: log.genesisHash(),
                member: memberID, algorithm: algorithm, key: key.raw,
                id: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, since: log.head().seq,
                revision: 0, entries: [:])
        }
    }

    private func checkedBody(_ json: String) throws -> ControlRecordBody {
        let request = try RemoteConfirmedSigner.controlRequest(bodyJSON: json, keyID: saved.member)
        let placeholder = RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))
        let body = try parseControlRecord(recordJson: "{\"body\":" + json + ",\"sig\":\"" + placeholder + "\"}")
        guard request.bodyJson == json, body.accountId == saved.account, body.genesisHash == saved.genesis else {
            throw RemoteControlPublicationError.invalidRecord
        }
        return body
    }

    private func checkRecord(_ record: String, bodyJSON: String) throws {
        guard try signedObjectInfo(json: record).bodyJcs == bodyJSON else { throw RemoteControlPublicationError.invalidRecord }
        try verifySignedObject(json: record, key: key)
    }

    private func checkStorage() throws {
        guard !uncertain else { throw RemoteControlPublicationError.storageUncertain }
        do {
            guard try read() == expected else { throw RemoteRecoveryStoreError.changed }
        } catch { uncertain = true; throw error }
    }

    private func append(id: String, entry: Entry) throws {
        var next = saved
        next.entries[id] = entry
        guard next.revision < 9_007_199_254_740_991, next.entries.count <= 4096 else {
            throw RemoteControlPublicationError.full
        }
        next.revision += 1
        try write(next)
    }

    /// Pin a newly created journal in the account checkpoint before signing with it.
    public func establish() throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        if expected == nil { try write(saved) }
    }

    private func write(_ next: Checkpoint) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(next)
        guard bytes.count <= 8_388_608 else { throw RemoteControlPublicationError.full }
        try checkStorage()
        do {
            try persist(bytes)
            guard try read() == bytes else { throw RemoteRecoveryStoreError.changed }
        } catch { uncertain = true; throw error }
        saved = next
        expected = bytes
    }

    public func inventory(stationOrigin: String, outboxes: [RemoteControlPublication],
                          recoveryCopies: [RemoteControlRecoveryPublication]) throws -> RemoteControlAuthorInventory {
        guard !operating else { throw RemoteControlPublicationError.busy }
        guard PortalIntegrationRecord.validOrigin(stationOrigin) else { throw RemoteControlPublicationError.invalidRecord }
        try checkStorage()
        var result = RemoteControlAuthorInventory(origin: stationOrigin, account: saved.account,
            genesis: saved.genesis, member: saved.member, key: key)
        for entry in saved.entries.values {
            try result.retain(body: checkedBody(entry.body), json: entry.body, key: key,
                record: entry.record, possiblySigned: true)
        }
        for box in outboxes { try box.collectAuthorEvidence(into: &result) }
        for copies in recoveryCopies { try copies.collectAuthorEvidence(into: &result) }
        try checkStorage()
        return result
    }

    enum SigningEvidence {
        case untouched
        case attempted
        case signed(String)
    }

    func evidence(bodyJSON: String, publicKey: PublicKeyData) throws -> SigningEvidence {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        let body = try checkedBody(bodyJSON)
        guard key == publicKey else { throw RemoteControlPublicationError.requiresReview }
        guard let entry = saved.entries[body.recordId] else { return .untouched }
        guard entry.body == bodyJSON else { throw RemoteControlPublicationError.requiresReview }
        if let record = entry.record { return .signed(record) }
        return .attempted
    }

    func sign(bodyJSON: String, publicKey: PublicKeyData, makeRecord: () throws -> String) throws -> String {
        guard !operating else { throw RemoteControlPublicationError.busy }
        operating = true
        defer { operating = false }
        try checkStorage()
        let body = try checkedBody(bodyJSON)
        guard publicKey == key else { throw RemoteControlPublicationError.requiresReview }
        if let entry = saved.entries[body.recordId] {
            guard entry.body == bodyJSON else { throw RemoteControlPublicationError.requiresReview }
            if let record = entry.record { return record }
        }
        // Commit each attempt before invoking the key, including an exact retry.
        try append(id: body.recordId, entry: Entry(body: bodyJSON))
        let record = try makeRecord()
        try checkRecord(record, bodyJSON: bodyJSON)
        try append(id: body.recordId, entry: Entry(body: bodyJSON, record: record))
        return record
    }
}
