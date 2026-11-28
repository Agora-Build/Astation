import AtemClient
import Foundation

/// An exact recovery review, not evidence that history or signing clocks are complete.
public struct RemoteControlRecoveryContext: Codable, Equatable, Sendable {
    public let accountID: String
    public let genesisHash: String
    public let stationOrigin: String
    public let generation: UInt64
    public let planID: String
    public let sourceHash: String
    public let evidenceHash: String
    public let candidateFeedID: String
    private let membershipSeq: UInt64
    private let membershipHash: String
    public var membershipHead: LogHead { LogHead(seq: membershipSeq, hash: membershipHash) }

    public init(accountID: String, genesisHash: String, stationOrigin: String, generation: UInt64,
        planID: String, sourceHash: String, evidenceHash: String, candidateFeedID: String,
        membershipHead: LogHead) throws {
        self.accountID = accountID; self.genesisHash = genesisHash; self.stationOrigin = stationOrigin
        self.generation = generation; self.planID = planID; self.sourceHash = sourceHash
        self.evidenceHash = evidenceHash; self.candidateFeedID = candidateFeedID
        membershipSeq = membershipHead.seq; membershipHash = membershipHead.hash
        try validate()
    }

    var signerReportRecovery: SignerReportRecovery {
        SignerReportRecovery(generation: String(generation), planId: planID, candidateFeedId: candidateFeedID,
            sourceHash: sourceHash, evidenceHash: evidenceHash)
    }

    func validate() throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin), (1...UInt64(Int64.max)).contains(generation),
              Self.validUUID(planID), Self.validUUID(candidateFeedID),
              RemoteRecoveryKit.validHash(sourceHash), RemoteRecoveryKit.validHash(evidenceHash),
              (1...9_007_199_254_740_991).contains(membershipHead.seq),
              RemoteRecoveryKit.validHash(membershipHead.hash) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
    }

    static func validUUID(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value) else { return false }
        // A canonical UUID places its version nibble at offset 14.
        return id.uuidString.lowercased() == value && value[value.index(value.startIndex, offsetBy: 14)] == "4"
    }
}

public struct RemoteControlRecoveryHold: LocalizedError {
    public let context: RemoteControlRecoveryContext

    public var errorDescription: String? {
        "Stop changes are paused for recovery plan " + context.planID + " (generation " +
            String(context.generation) + ") at " + context.stationOrigin + "."
    }
}

public struct RemoteControlRecoveryReview: Equatable, Sendable {
    public let context: RemoteControlRecoveryContext
    public let originalRecordJSON: String
    public let originalRecordID: String
    public let body: ControlRecordBody
    public let request: SignRequest
    public let signed: Bool
}

/// Checks the closed plan, exact original, current manager and the adapter's timestamp
/// reservation again at signing. Managers sign native copies before their final reports.
/// Service clock reconstruction and complete author history are publication requirements.
@MainActor
public protocol RemoteControlRecoveryAuthorizing {
    func reserve(originalRecordJSON: String, context: RemoteControlRecoveryContext,
        managerID: String, log: MembershipLog) async throws -> UInt64
    func authorize(_ review: RemoteControlRecoveryReview, log: MembershipLog) throws
}

/// Recovery signatures never supersede originals or enter ordinary delivery.
@MainActor
public final class RemoteControlRecoveryPublication {
    private struct Operation: Codable {
        let context: RemoteControlRecoveryContext
        let originalRecordJSON: String
        let originalKey: SavedKey
        let bodyJSON: String
        let signingKey: SavedKey
        var recordJSON: String?
        var attempted: Bool?
    }
    private struct SavedKey: Codable {
        let algorithm: String
        let raw: Data
        init(_ key: PublicKeyData) {
            algorithm = key.alg == .p256 ? "p256" : "ed25519"
            raw = key.raw
        }
        func key() throws -> PublicKeyData {
            guard ["p256", "ed25519"].contains(algorithm) else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            let key = PublicKeyData(alg: algorithm == "p256" ? .p256 : .ed25519, raw: raw)
            try checkPublicKey(key: key)
            return key
        }
    }
    private struct Checkpoint: Codable {
        var version: Int
        let accountID: String
        let genesisHash: String
        let stationOrigin: String
        var operations: [Operation]
    }

    private var saved: Checkpoint
    private let draftJournal: @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal
    private let persist: (Data) throws -> Void
    private var operating = false
    public private(set) var storageUncertain = false

    public init(accountID: String, genesisHash: String, stationOrigin: String,
        draftJournal: @escaping @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal = RemoteControlSigningJournal.init(log:memberID:),
        persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        saved = Checkpoint(version: 2, accountID: accountID, genesisHash: genesisHash,
            stationOrigin: stationOrigin, operations: [])
        self.draftJournal = draftJournal
        self.persist = persist
    }

    public init(checkpoint: Data, accountID: String, genesisHash: String, stationOrigin: String,
        draftJournal: @escaping @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal = RemoteControlSigningJournal.init(log:memberID:),
        persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 2_097_152 else { throw RemoteControlPublicationError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        self.draftJournal = draftJournal
        self.persist = persist
        guard [1, 2].contains(saved.version), saved.accountID == accountID, saved.genesisHash == genesisHash,
              saved.stationOrigin == stationOrigin, saved.operations.count <= 256,
              RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        var ids = Set<String>(), sources = Set<String>(), reviews = Set<String>()
        var observedTimes: [String: UInt64] = [:]
        var originals: [String: String] = [:]
        for operation in saved.operations {
            guard saved.version == 2 || operation.attempted == nil else { throw RemoteControlPublicationError.invalidCheckpoint }
            let review = try validate(operation)
            let original = try canonicalJson(json: review.originalRecordJSON)
            guard ids.insert(review.body.recordId).inserted,
                  reviews.insert(review.context.planID + ":" + review.context.evidenceHash + ":" + review.originalRecordID).inserted,
                  review.body.issuedAt > (observedTimes[review.body.principal] ?? 0),
                  originals[review.originalRecordID] == nil || originals[review.originalRecordID] == original else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            sources.insert(review.originalRecordID)
            observedTimes[review.body.principal] = review.body.issuedAt
            originals[review.originalRecordID] = original
        }
        guard ids.isDisjoint(with: sources) else { throw RemoteControlPublicationError.invalidCheckpoint }
    }

    /// The authority must validate the reservation for this review before the draft is saved.
    public func prepare(originalRecordJSON: String, context: RemoteControlRecoveryContext,
        managerID: String, issuedAt: UInt64, log: MembershipLog,
        authority: RemoteControlRecoveryAuthorizing?) throws -> RemoteControlRecoveryReview {
        try available()
        guard let authority else { throw RemoteControlPublicationError.requiresReview }
        operating = true
        defer { operating = false }
        try check(context, log: log)
        let old = try original(originalRecordJSON, log: log)
        if let operation = saved.operations.first(where: {
            $0.context.planID == context.planID && $0.context.evidenceHash == context.evidenceHash &&
                (try? parseControlRecord(recordJson: $0.originalRecordJSON).recordId) == old.recordId
        }) {
            let review = try validate(operation)
            guard operation.context == context, review.body.signer == "member:" + managerID,
                  try canonicalJson(json: originalRecordJSON) == canonicalJson(json: operation.originalRecordJSON) else {
                throw RemoteControlPublicationError.requiresReview
            }
            try authorize(review, log: log, authority: authority)
            return review
        }
        guard let oldKey = log.member(deviceId: String(old.signer.dropFirst(7)))?.authKey,
              let key = log.member(deviceId: managerID)?.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        for prior in saved.operations {
            let retained = try validate(prior), body = retained.body
            if retained.originalRecordID == old.recordId,
               try canonicalJson(json: retained.originalRecordJSON) != canonicalJson(json: originalRecordJSON) {
                throw RemoteControlPublicationError.requiresReview
            }
            if body.principal == old.principal, issuedAt <= body.issuedAt {
                throw RemoteControlPublicationError.requiresReview
            }
        }
        let body = ControlRecordBody(accountId: old.accountId, genesisHash: old.genesisHash,
            origin: old.origin, feedId: old.feedId,
            principal: old.principal, principalKey: old.principalKey, signer: "member:" + managerID,
            action: old.action, interruptRunning: old.interruptRunning, revokeSeq: old.revokeSeq,
            recordId: UUID().uuidString.lowercased(), issuedAt: issuedAt, integrationId: old.integrationId, by: old.by)
        let capture = RecoveryRequestCapture(keyID: managerID, key: key)
        do { _ = try buildControlRecord(provider: capture, keyId: managerID, body: body) }
        catch { if capture.request == nil { throw error } }
        guard let bodyJSON = capture.request?.bodyJson else { throw RemoteControlPublicationError.invalidRecord }
        let operation = Operation(context: context, originalRecordJSON: originalRecordJSON,
            originalKey: SavedKey(oldKey), bodyJSON: bodyJSON, signingKey: SavedKey(key), attempted: false)
        let review = try validate(operation)
        try authorize(review, log: log, authority: authority)
        guard !saved.operations.contains(where: {
            (try? parseControlRecord(recordJson: $0.originalRecordJSON).recordId) == body.recordId ||
            (try? Self.body($0.bodyJSON).recordId) == old.recordId
        }), saved.operations.count < 256 else { throw RemoteControlPublicationError.full }
        try draftJournal(log, managerID).withPermittedStopChange(bodyJSON: operation.bodyJSON) {
            try commit { $0.operations.append(operation) }
        }
        return review
    }

    public func reviews() throws -> [RemoteControlRecoveryReview] {
        try available()
        return try saved.operations.map(validate)
    }

    /// Exact signed retries need no new signature. Changed membership/context must
    /// be reviewed again; a failed save fences this process even if it wrote first.
    public func sign(recordID: String, log: MembershipLog, provider: AppKeyProvider,
        authorJournal: @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal = RemoteControlSigningJournal.init(log:memberID:),
        authority: RemoteControlRecoveryAuthorizing?, confirmedAt: UInt64,
        now: @escaping @Sendable () -> UInt64, current: () -> Bool) throws -> String {
        try available()
        operating = true
        defer { operating = false }
        guard current() else { throw RemoteChannelError.staleLink }
        guard let index = saved.operations.firstIndex(where: { (try? Self.body($0.bodyJSON).recordId) == recordID }) else {
            throw RemoteControlPublicationError.invalidRecord
        }
        let operation = saved.operations[index], review = try validate(operation)
        try check(review.context, log: log)
        if let record = operation.recordJSON {
            guard case .valid = try verifyControlRecord(log: log, recordJson: record) else {
                throw RemoteControlPublicationError.requiresReview
            }
            return record
        }
        guard let authority else { throw RemoteControlPublicationError.requiresReview }
        try authorize(review, log: log, authority: authority)
        let manager = review.request.keyId
        guard try provider.publicKey(keyId: manager) == operation.signingKey.key() else {
            throw RemoteControlPublicationError.requiresReview
        }
        let signer = try RemoteConfirmedSigner(provider: provider, request: review.request,
            confirmedAt: confirmedAt, now: now)
        guard current() else { throw RemoteChannelError.staleLink }
        let journal = try authorJournal(log, manager)
        try journal.requireStopChange(bodyJSON: operation.bodyJSON)
        if operation.attempted != true {
            try commit { $0.operations[index].attempted = true }
        }
        let record = try journal.sign(bodyJSON: operation.bodyJSON, publicKey: operation.signingKey.key()) {
            guard current() else { throw RemoteChannelError.staleLink }
            try authorize(review, log: log, authority: authority)
            return try buildControlRecord(provider: signer, keyId: manager, body: review.body)
        }
        guard current() else { throw RemoteChannelError.staleLink }
        try authorize(review, log: log, authority: authority)
        guard case .valid = try verifyControlRecord(log: log, recordJson: record) else {
            throw RemoteControlPublicationError.requiresReview
        }
        try commit { $0.operations[index].recordJSON = record }
        return record
    }

    func collectAuthorEvidence(into inventory: inout RemoteControlAuthorInventory) throws {
        try available()
        guard saved.accountID == inventory.account, saved.genesisHash == inventory.genesis else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        for op in saved.operations {
            let original = try parseControlRecord(recordJson: op.originalRecordJSON)
            try inventory.retain(body: original, json: signedObjectInfo(json: op.originalRecordJSON).bodyJcs,
                key: op.originalKey.key(), record: op.originalRecordJSON, possiblySigned: true)
            try inventory.retain(body: Self.body(op.bodyJSON), json: op.bodyJSON, key: op.signingKey.key(),
                record: op.recordJSON, possiblySigned: op.attempted != false, unsignedDraft: op.recordJSON == nil)
        }
    }

    /// Produces the existing retain-resigned input, never the original-evidence
    /// archive. A batch is atomic and bounded; unsigned copies are not exported.
    public func export(context: RemoteControlRecoveryContext, recordIDs: [String]) throws -> String {
        try available()
        try context.validate()
        guard !recordIDs.isEmpty, recordIDs.count <= 64, Set(recordIDs).count == recordIDs.count else {
            throw RemoteControlPublicationError.invalidRecord
        }
        let selected = Set(recordIDs)
        let operations = try saved.operations.filter { selected.contains(try Self.body($0.bodyJSON).recordId) }
        guard operations.count == selected.count else { throw RemoteControlPublicationError.requiresReview }
        var rows: [String] = []
        for operation in operations {
            guard operation.context == context, let record = operation.recordJSON else {
                throw RemoteControlPublicationError.requiresReview
            }
            let review = try validate(operation)
            let encodedID = String(decoding: try JSONSerialization.data(withJSONObject: review.originalRecordID,
                options: [.fragmentsAllowed]), as: UTF8.self)
            rows.append("{\"original_record_id\":" + encodedID + ",\"record\":" + record + "}")
        }
        let result = "{\"evidence_hash\":\"" + context.evidenceHash + "\",\"replacements\":[" + rows.joined(separator: ",") + "]}"
        guard result.utf8.count <= 262_144 else { throw RemoteControlPublicationError.full }
        return result
    }

    private func original(_ record: String, log: MembershipLog) throws -> ControlRecordBody {
        let body = try parseControlRecord(recordJson: record)
        guard body.accountId == saved.accountID, body.genesisHash == saved.genesisHash,
              body.signer.hasPrefix("member:"), body.origin == nil || body.origin == saved.stationOrigin,
              let key = log.member(deviceId: String(body.signer.dropFirst(7)))?.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        try verifySignedObject(json: record, key: key)
        switch try verifyControlRecord(log: log, recordJson: record) {
        case .valid: break
        case .refused(let reason) where reason == "removed_manager": break
        default: throw RemoteControlPublicationError.requiresReview
        }
        return body
    }

    private func check(_ context: RemoteControlRecoveryContext, log: MembershipLog) throws {
        try context.validate()
        guard context.accountID == saved.accountID, context.genesisHash == saved.genesisHash,
              context.stationOrigin == saved.stationOrigin, log.accountId() == saved.accountID,
              log.genesisHash() == saved.genesisHash, log.head() == context.membershipHead,
              log.frozen() == nil else { throw RemoteControlPublicationError.requiresReview }
    }

    private func authorize(_ review: RemoteControlRecoveryReview, log: MembershipLog,
        authority: RemoteControlRecoveryAuthorizing) throws {
        try check(review.context, log: log)
        _ = try original(review.originalRecordJSON, log: log)
        guard let body = review.request.bodyJson,
              case .refused(let reason) = try verifyControlRecord(log: log, recordJson: Self.unsigned(body)),
              reason == "bad_signature" else { throw RemoteControlPublicationError.requiresReview }
        try authority.authorize(review, log: log)
        // The adapter may refresh membership while validating its reservation.
        try check(review.context, log: log)
    }

    private func validate(_ operation: Operation) throws -> RemoteControlRecoveryReview {
        try operation.context.validate()
        let old = try parseControlRecord(recordJson: operation.originalRecordJSON), body = try Self.body(operation.bodyJSON)
        let context = operation.context
        guard context.accountID == saved.accountID, context.genesisHash == saved.genesisHash,
              context.stationOrigin == saved.stationOrigin, old.accountId == saved.accountID,
              old.genesisHash == saved.genesisHash, old.origin == nil || old.origin == saved.stationOrigin,
              old.signer.hasPrefix("member:"), body.signer.hasPrefix("member:"),
              body.accountId == old.accountId, body.genesisHash == old.genesisHash, body.origin == old.origin,
              body.principal == old.principal, body.principalKey == old.principalKey,
              body.action == old.action, body.interruptRunning == old.interruptRunning, body.revokeSeq == old.revokeSeq,
              body.integrationId == old.integrationId, body.by == old.by, body.recordId != old.recordId,
              body.issuedAt > old.issuedAt,
              body.feedId == old.feedId || (old.feedId != nil && body.feedId == context.candidateFeedID),
              try canonicalJson(json: operation.bodyJSON) == operation.bodyJSON else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        try verifySignedObject(json: operation.originalRecordJSON, key: operation.originalKey.key())
        let request = try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON,
            keyID: String(body.signer.dropFirst(7)))
        _ = try operation.signingKey.key()
        if let record = operation.recordJSON {
            guard try signedObjectInfo(json: record).bodyJcs == operation.bodyJSON,
                  try parseControlRecord(recordJson: record) == body else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            try verifySignedObject(json: record, key: operation.signingKey.key())
        }
        return RemoteControlRecoveryReview(context: context, originalRecordJSON: operation.originalRecordJSON,
            originalRecordID: old.recordId, body: body, request: request, signed: operation.recordJSON != nil)
    }

    private static func unsigned(_ body: String) -> String {
        "{\"body\":" + body + ",\"sig\":\"" + RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64)) + "\"}"
    }
    private static func body(_ json: String) throws -> ControlRecordBody { try parseControlRecord(recordJson: unsigned(json)) }
    private func available() throws {
        guard !storageUncertain else { throw RemoteControlPublicationError.storageUncertain }
        guard !operating else { throw RemoteControlPublicationError.busy }
    }
    private func commit<T>(_ change: (inout Checkpoint) throws -> T) throws -> T {
        var next = saved
        next.version = 2
        let result = try change(&next)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bytes = try encoder.encode(next)
        guard bytes.count <= 2_097_152 else { throw RemoteControlPublicationError.full }
        do { try persist(bytes) }
        catch { storageUncertain = true; throw error }
        saved = next
        return result
    }
}

private final class RecoveryRequestCapture: AppKeyProvider, @unchecked Sendable {
    let keyID: String
    let key: PublicKeyData
    var request: SignRequest?
    init(keyID: String, key: PublicKeyData) { self.keyID = keyID; self.key = key }
    func publicKey(keyId: String) throws -> PublicKeyData {
        guard keyId == keyID else { throw ProviderError.UnknownKey }
        return key
    }
    func sign(request: SignRequest) throws -> Data {
        self.request = request
        throw ProviderError.Cancelled(reason: "prepare only")
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw ProviderError.UnknownKey }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw ProviderError.UnknownKey }
}
