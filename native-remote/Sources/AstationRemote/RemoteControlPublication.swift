import AtemClient
import Foundation

public enum RemoteControlPublicationError: Error, Equatable {
    case invalidCheckpoint
    case invalidRecord
    case requiresReview
    case storageUncertain
    case busy
    case full
}

public enum RemoteControlPortalRefusal: String, Codable, Sendable {
    case tooLate = "too_late"
    case stationRemoved = "station_removed"
}

public struct RemoteControlPortalMirror: Codable, Equatable, Sendable {
    public let issuer: String
    public let ownerAccount: String
    public let stationOrigin: String
    public let integrationID: String
    public let interruptRunning: Bool

    public init(issuer: String, ownerAccount: String, stationOrigin: String,
        integrationID: String, interruptRunning: Bool) throws {
        self.issuer = issuer
        self.ownerAccount = ownerAccount
        self.stationOrigin = stationOrigin
        self.integrationID = integrationID
        self.interruptRunning = interruptRunning
        try validate()
    }

    func validate() throws {
        _ = try AccountOIDCConfiguration.endpoint(issuer)
        guard let parts = URLComponents(string: issuer), parts.path.isEmpty,
              parts.url?.absoluteString == issuer, PortalIntegrationRecord.validAccountID(ownerAccount),
              PortalIntegrationRecord.validOrigin(stationOrigin), PortalIntegrationRecord.validID(integrationID) else {
            throw RemoteControlPublicationError.invalidRecord
        }
    }
}

public struct RemoteControlDelivery: Equatable, Sendable {
    public let recordID: String
    public let recordJSON: String
    public let stationOrigin: String
    public let stationStored: Bool
    public let portalMirror: RemoteControlPortalMirror?
    public let portalMirrored: Bool
    public let portalRefusal: RemoteControlPortalRefusal?
    public let additionalStations: [String: Bool]
    public var portalSettled: Bool { portalMirrored || portalRefusal != nil }
    public var allStationsStored: Bool { stationStored && additionalStations.values.allSatisfy { $0 } }

    init(recordID: String, recordJSON: String, stationOrigin: String, stationStored: Bool,
        portalMirror: RemoteControlPortalMirror?, portalMirrored: Bool, portalRefusal: RemoteControlPortalRefusal?,
        additionalStations: [String: Bool] = [:]) {
        self.recordID = recordID; self.recordJSON = recordJSON; self.stationOrigin = stationOrigin
        self.stationStored = stationStored; self.portalMirror = portalMirror
        self.portalMirrored = portalMirrored; self.portalRefusal = portalRefusal
        self.additionalStations = additionalStations
    }
}

public struct RemoteControlReview: Equatable, Sendable {
    public let body: ControlRecordBody
    public let request: SignRequest
    public let signed: Bool
    public let resignsRecordID: String?
    public let additionalStationOrigins: [String]
}

/// The protected checkpoint owns drafts, exact signatures and both delivery legs.
/// A Station receipt means stored, never that a host has applied the stop.
@MainActor
public final class RemoteControlPublication {
    private struct Operation: Codable {
        let bodyJSON: String
        let headSeq: UInt64
        let headHash: String
        let signerAlgorithm: String
        let signerPublicKey: Data
        let resignsRecordID: String?
        let observed: Bool?
        // Older outboxes cannot distinguish an untouched draft from a lost signature.
        var attempted: Bool?
        var recordJSON: String?
        var stationStored = false
        let portalMirror: RemoteControlPortalMirror?
        var portalMirrored = false
        var portalRefusal: RemoteControlPortalRefusal?
        var additionalStations: [String: Bool]?
    }
    private struct Checkpoint: Codable {
        var version: Int
        let accountID: String
        let genesisHash: String
        let stationOrigin: String
        var operations: [Operation]
    }

    private var saved: Checkpoint
    private let persist: (Data) throws -> Void
    private var operating = false
    public private(set) var storageUncertain = false
    public var recordIDs: [String] {
        saved.operations.compactMap { try? Self.body($0.bodyJSON).recordId }
    }

    public func pendingDeliveryIDs() throws -> [String] {
        try available()
        return try saved.operations.filter {
            $0.recordJSON != nil && (needsStation($0) || ($0.portalMirror != nil && !$0.portalMirrored && $0.portalRefusal == nil))
        }.map { try Self.body($0.bodyJSON).recordId }
    }

    public func stationDeliveryNeeded(recordID: String, stationOrigin: String? = nil) throws -> Bool {
        try available()
        let operation = saved.operations[try index(recordID)]
        guard !superseded(operation) else { return false }
        let origin = stationOrigin ?? saved.stationOrigin
        if origin == saved.stationOrigin { return !operation.stationStored }
        guard let stored = operation.additionalStations?[origin] else {
            throw RemoteControlPublicationError.invalidRecord
        }
        return !stored
    }

    private func needsStation(_ operation: Operation) -> Bool {
        !superseded(operation) && (!operation.stationStored || (operation.additionalStations ?? [:]).values.contains(false))
    }

    private func superseded(_ operation: Operation) -> Bool {
        guard let body = try? Self.body(operation.bodyJSON) else { return false }
        return saved.operations.contains { $0.resignsRecordID == body.recordId && $0.recordJSON != nil }
    }

    public func stationOrigins(recordID: String) throws -> [String] {
        try available()
        return [saved.stationOrigin] + (saved.operations[try index(recordID)].additionalStations ?? [:]).keys.sorted()
    }

    public func signingRequest(recordID: String, log: MembershipLog? = nil) throws -> SignRequest? {
        try available()
        let operation = saved.operations[try index(recordID)]
        guard operation.recordJSON == nil else { return nil }
        if let log {
            try check(log)
            guard log.head() == LogHead(seq: operation.headSeq, hash: operation.headHash) else {
                throw RemoteControlPublicationError.requiresReview
            }
            try checkResignSource(operation, log: log)
        }
        let body = try validate(operation)
        return try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: String(body.signer.dropFirst(7)))
    }

    /// Includes unsigned reviews so closing a window or restarting never loses a prepared stop.
    public func pendingReviews() throws -> [RemoteControlReview] {
        try available()
        return try saved.operations.filter {
            needsStation($0) || ($0.portalMirror != nil && !$0.portalMirrored && $0.portalRefusal == nil)
        }.map {
            let body = try validate($0)
            return RemoteControlReview(body: body,
                request: try RemoteConfirmedSigner.controlRequest(bodyJSON: $0.bodyJSON, keyID: String(body.signer.dropFirst(7))),
                signed: $0.recordJSON != nil, resignsRecordID: $0.resignsRecordID,
                additionalStationOrigins: ($0.additionalStations ?? [:]).keys.sorted())
        }
    }

    /// Includes completed deliveries: a storage receipt does not settle host application.
    public func activity(log: MembershipLog,
        status: [String: RemoteControlApplicationState] = [:]) throws -> [RemoteControlActivity] {
        try available()
        try check(log)
        return try saved.operations.map { operation in
            let body = try validate(operation)
            let needsManager: Bool
            if let record = operation.recordJSON {
                switch try verifyControlRecord(log: log, recordJson: record) {
                case .valid: needsManager = false
                case .refused(let reason) where reason == "removed_manager": needsManager = true
                default: throw RemoteControlPublicationError.requiresReview
                }
            } else { needsManager = false }
            return RemoteControlActivity(body: body, signed: operation.recordJSON != nil,
                stationStored: operation.stationStored,
                portalPending: operation.portalMirror != nil && !operation.portalMirrored && operation.portalRefusal == nil,
                managerReviewRequired: needsManager,
                replacementRecordID: try saved.operations.first(where: { $0.resignsRecordID == body.recordId })
                    .map { try Self.body($0.bodyJSON).recordId },
                application: operation.recordJSON == nil ? nil : status[body.recordId],
                additionalStations: operation.additionalStations ?? [:])
        }.sorted {
            if $0.body.issuedAt != $1.body.issuedAt { return $0.body.issuedAt > $1.body.issuedAt }
            return $0.body.recordId < $1.body.recordId
        }
    }

    public init(accountID: String, genesisHash: String, stationOrigin: String,
        persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        saved = Checkpoint(version: 2, accountID: accountID, genesisHash: genesisHash,
            stationOrigin: stationOrigin, operations: [])
        self.persist = persist
    }

    public init(checkpoint: Data, accountID: String, genesisHash: String, stationOrigin: String,
        persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 2_097_152 else { throw RemoteControlPublicationError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        self.persist = persist
        guard [1, 2].contains(saved.version), saved.accountID == accountID, saved.genesisHash == genesisHash,
              saved.stationOrigin == stationOrigin, saved.operations.count <= 256,
              RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        var ids = Set<String>()
        for operation in saved.operations {
            guard saved.version >= 2 || operation.attempted == nil else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            let body = try validate(operation)
            guard ids.insert(body.recordId).inserted else { throw RemoteControlPublicationError.invalidCheckpoint }
        }
        for (offset, operation) in saved.operations.enumerated() {
            if let source = operation.resignsRecordID {
                guard let original = saved.operations[..<offset].first(where: { (try? Self.body($0.bodyJSON).recordId) == source }) else {
                    throw RemoteControlPublicationError.invalidCheckpoint
                }
                try validateReplacement(operation, original: original)
                guard saved.operations.filter({ $0.resignsRecordID == source }).count == 1 else {
                    throw RemoteControlPublicationError.invalidCheckpoint
                }
            }
        }
    }

    /// Reserve the Station timestamp first, then durably prepare before showing confirmation.
    /// The actual SDK builds the SignRequest; this layer has no control-record serializer.
    public func prepare(body: ControlRecordBody, log: MembershipLog,
        portalMirror: RemoteControlPortalMirror? = nil, additionalStationOrigins: [String] = []) throws -> SignRequest {
        try prepare(body: body, log: log, portalMirror: portalMirror, resignsRecordID: nil,
            additionalStationOrigins: additionalStationOrigins)
    }

    public func savedResignReview(recordID: String) throws -> RemoteControlReview? {
        try available()
        guard let operation = saved.operations.first(where: { $0.resignsRecordID == recordID }) else { return nil }
        let body = try validate(operation)
        return RemoteControlReview(body: body,
            request: try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: String(body.signer.dropFirst(7))),
            signed: operation.recordJSON != nil, resignsRecordID: recordID,
            additionalStationOrigins: (operation.additionalStations ?? [:]).keys.sorted())
    }

    /// Called only for a correlated selected-Station feed page, never an ACK reason.
    /// Importing evidence neither signs it nor creates an owner's Portal intent.
    public func retainRemovedManagerStop(recordJSON: String, log: MembershipLog) throws {
        try available()
        try check(log)
        let body = try parseControlRecord(recordJson: recordJSON)
        guard body.signer.hasPrefix("member:"),
              case .refused(let reason) = try verifyControlRecord(log: log, recordJson: recordJSON),
              reason == "removed_manager",
              let key = log.member(deviceId: String(body.signer.dropFirst(7)))?.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        let info = try signedObjectInfo(json: recordJSON)
        let operation = Operation(bodyJSON: info.bodyJcs, headSeq: log.head().seq, headHash: log.head().hash,
            signerAlgorithm: key.alg == .p256 ? "p256" : "ed25519", signerPublicKey: key.raw,
            resignsRecordID: nil, observed: true, recordJSON: recordJSON, stationStored: true, portalMirror: nil)
        do { _ = try validate(operation) }
        catch { throw RemoteControlPublicationError.invalidRecord }
        if let prior = saved.operations.first(where: { (try? Self.body($0.bodyJSON).recordId) == body.recordId }) {
            guard prior.bodyJSON == info.bodyJcs else { throw RemoteControlPublicationError.requiresReview }
            return
        }
        guard saved.operations.count < 256 else { throw RemoteControlPublicationError.full }
        try transaction { $0.operations.append(operation) }
    }

    /// A current manager reviews the same stop under a fresh ID. The original
    /// signature and its independent Portal intent remain in the journal.
    public func prepareResign(recordID: String, managerID: String, issuedAt: UInt64,
        feedID: String?, log: MembershipLog) throws -> RemoteControlReview {
        try available()
        try check(log)
        let original = saved.operations[try index(recordID)]
        guard let record = original.recordJSON,
              case .refused(let reason) = try verifyControlRecord(log: log, recordJson: record),
              reason == "removed_manager" else { throw RemoteControlPublicationError.requiresReview }
        if let review = try savedResignReview(recordID: recordID) { return review }
        let old = try validate(original)
        let body = ControlRecordBody(accountId: old.accountId, genesisHash: old.genesisHash, origin: old.origin,
            feedId: old.principal.hasPrefix("service:") ? feedID : nil, principal: old.principal,
            principalKey: old.principalKey, signer: "member:" + managerID, action: old.action,
            interruptRunning: old.interruptRunning, revokeSeq: old.revokeSeq,
            recordId: UUID().uuidString.lowercased(), issuedAt: issuedAt, integrationId: old.integrationId, by: old.by)
        let request = try prepare(body: body, log: log, portalMirror: nil, resignsRecordID: recordID,
            additionalStationOrigins: (original.additionalStations ?? [:]).keys.sorted())
        return RemoteControlReview(body: body, request: request, signed: false, resignsRecordID: recordID,
            additionalStationOrigins: (original.additionalStations ?? [:]).keys.sorted())
    }

    private func prepare(body: ControlRecordBody, log: MembershipLog,
        portalMirror: RemoteControlPortalMirror?, resignsRecordID: String?, additionalStationOrigins: [String]) throws -> SignRequest {
        try available()
        try check(log)
        guard additionalStationOrigins.count <= 63, Set(additionalStationOrigins).count == additionalStationOrigins.count,
              !additionalStationOrigins.contains(saved.stationOrigin),
              additionalStationOrigins.allSatisfy(PortalIntegrationRecord.validOrigin) else {
            throw RemoteControlPublicationError.invalidRecord
        }
        guard body.signer.hasPrefix("member:") else { throw RemoteControlPublicationError.invalidRecord }
        let manager = String(body.signer.dropFirst(7))
        guard let key = log.member(deviceId: manager)?.authKey else { throw RemoteControlPublicationError.invalidRecord }
        let capture = ControlRequestCapture(keyID: manager, key: key)
        do { _ = try buildControlRecord(provider: capture, keyId: manager, body: body) }
        catch { if capture.request == nil { throw error } }
        guard let request = capture.request, let bodyJSON = request.bodyJson,
              request == (try RemoteConfirmedSigner.controlRequest(bodyJSON: bodyJSON, keyID: manager)) else {
            throw RemoteControlPublicationError.invalidRecord
        }
        let head = log.head()
        let operation = Operation(bodyJSON: bodyJSON, headSeq: head.seq, headHash: head.hash,
            signerAlgorithm: key.alg == .p256 ? "p256" : "ed25519", signerPublicKey: key.raw,
            resignsRecordID: resignsRecordID, observed: nil, attempted: false, portalMirror: portalMirror,
            additionalStations: additionalStationOrigins.isEmpty ? nil : Dictionary(uniqueKeysWithValues: additionalStationOrigins.map { ($0, false) }))
        _ = try validate(operation)
        if let source = resignsRecordID {
            try validateReplacement(operation, original: saved.operations[try index(source)])
        }
        // All authority checks precede signature verification in the shared verifier.
        guard case .refused(let reason) = try verifyControlRecord(log: log, recordJson: Self.unsigned(bodyJSON)),
              reason == "bad_signature" else { throw RemoteControlPublicationError.invalidRecord }
        if let prior = saved.operations.first(where: { (try? Self.body($0.bodyJSON).recordId) == body.recordId }) {
            guard prior.bodyJSON == bodyJSON, prior.headSeq == head.seq, prior.headHash == head.hash,
                  prior.portalMirror == portalMirror, prior.resignsRecordID == resignsRecordID,
                  Set((prior.additionalStations ?? [:]).keys) == Set(additionalStationOrigins) else {
                throw RemoteControlPublicationError.requiresReview
            }
            return request
        }
        guard saved.operations.count < 256 else { throw RemoteControlPublicationError.full }
        try transaction { $0.operations.append(operation) }
        return request
    }

    /// A retry returns the stored signature, including for nondeterministic P-256 keys.
    public func sign(recordID: String, log: MembershipLog, provider: AppKeyProvider,
        authorJournal: @MainActor (MembershipLog, String) throws -> RemoteControlSigningJournal = RemoteControlSigningJournal.init(log:memberID:),
        confirmedAt: UInt64, now: @escaping @Sendable () -> UInt64, current: () -> Bool) throws -> String {
        try available()
        try check(log)
        guard current() else { throw RemoteChannelError.staleLink }
        let index = try index(recordID)
        let operation = saved.operations[index]
        if let record = operation.recordJSON {
            try verify(record, log: log)
            return record
        }
        guard log.head() == LogHead(seq: operation.headSeq, hash: operation.headHash) else {
            throw RemoteControlPublicationError.requiresReview
        }
        try checkResignSource(operation, log: log)
        operating = true
        defer { operating = false }
        let body = try validate(operation)
        let manager = String(body.signer.dropFirst(7))
        let request = try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: manager)
        guard let member = log.member(deviceId: manager), member.authKey == (try Self.signerKey(operation)),
              try provider.publicKey(keyId: manager) == member.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        let signer = try RemoteConfirmedSigner(provider: provider, request: request, confirmedAt: confirmedAt, now: now)
        guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
        let journal = try authorJournal(log, manager)
        if operation.attempted != true {
            try commit { $0.operations[index].attempted = true }
        }
        let record = try journal.sign(bodyJSON: operation.bodyJSON, publicKey: member.authKey) {
            guard current(), log.head() == LogHead(seq: operation.headSeq, hash: operation.headHash),
                  log.frozen() == nil else { throw RemoteChannelError.staleLink }
            return try buildControlRecord(provider: signer, keyId: manager, body: body)
        }
        try verify(record, log: log)
        guard current(), log.head() == LogHead(seq: operation.headSeq, hash: operation.headHash),
              log.frozen() == nil else { throw RemoteChannelError.staleLink }
        try commit { $0.operations[index].recordJSON = record }
        return record
    }

    /// Revalidate on every delivery against the independently refreshed device list.
    /// Removed-manager evidence remains in the journal for a fresh re-sign ceremony.
    public func delivery(recordID: String, log: MembershipLog) throws -> RemoteControlDelivery? {
        try available()
        try check(log)
        guard let delivery = try retainedDelivery(recordID: recordID) else { return nil }
        try verify(delivery.recordJSON, log: log)
        return delivery
    }

    /// Retained intent is not current signing authority. Portal mirroring must finish
    /// even when the native signer has since lost manage and the stop needs re-signing.
    public func retainedDelivery(recordID: String) throws -> RemoteControlDelivery? {
        try available()
        let operation = saved.operations[try index(recordID)]
        guard let record = operation.recordJSON else { return nil }
        return RemoteControlDelivery(recordID: recordID, recordJSON: record, stationOrigin: saved.stationOrigin,
            stationStored: operation.stationStored, portalMirror: operation.portalMirror, portalMirrored: operation.portalMirrored,
            portalRefusal: operation.portalRefusal, additionalStations: operation.additionalStations ?? [:])
    }

    func collectAuthorEvidence(into inventory: inout RemoteControlAuthorInventory) throws {
        try available()
        guard saved.accountID == inventory.account, saved.genesisHash == inventory.genesis else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        for op in saved.operations {
            try inventory.retain(body: Self.body(op.bodyJSON), json: op.bodyJSON, key: Self.signerKey(op),
                record: op.recordJSON, possiblySigned: op.attempted != false)
        }
    }

    /// Export original public evidence, including superseded and completed stops.
    /// This is not a complete history, signing-clock anchor or recovery approval.
    public func recoveryEvidenceJSON(authorJournal: (String) throws -> RemoteControlSigningJournal) throws -> String {
        try available()
        var records: [String] = [], unsigned: [String] = []
        var destinations: [String: [String]] = [:]
        var journals: [String: RemoteControlSigningJournal] = [:]
        for operation in saved.operations {
            let body = try validate(operation)
            destinations[body.recordId] = [saved.stationOrigin] + (operation.additionalStations ?? [:]).keys.sorted()
            if let record = operation.recordJSON {
                records.append(record)
                continue
            }
            let member = String(body.signer.dropFirst(7))
            let journal = try journals[member] ?? authorJournal(member)
            journals[member] = journal
            if let record = try retainedSignature(operation, journal: journal) { records.append(record) }
            else { unsigned.append(operation.bodyJSON) }
        }
        let metadata: [String: Any] = [
            "type": "astation-native-control-recovery-evidence", "version": 1,
            "account_id": saved.accountID, "genesis_hash": saved.genesisHash,
            "station_origin": saved.stationOrigin, "destinations": destinations,
            "retained_history_only": true, "complete_history": false,
            "signing_clock_complete": false, "snapshot_complete": false,
        ]
        let header = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
        // Keep the saved signed bytes; do not rebuild bodies or signatures.
        let output = String(header.dropLast()) + ",\"records\":[" + records.joined(separator: ",") +
            "],\"unsigned_reviews\":[" + unsigned.joined(separator: ",") + "]}"
        guard output.utf8.count <= 8_388_608 else { throw RemoteControlPublicationError.full }
        return output
    }

    private func retainedSignature(_ operation: Operation, journal: RemoteControlSigningJournal) throws -> String? {
        switch try journal.evidence(bodyJSON: operation.bodyJSON, publicKey: Self.signerKey(operation)) {
        case .signed(let record): return record
        case .untouched where operation.attempted == false: return nil
        default: throw RemoteControlPublicationError.requiresReview
        }
    }

    public func cancelUnsigned(recordID: String, authorJournal: (String) throws -> RemoteControlSigningJournal) throws {
        try available()
        let index = try index(recordID)
        let operation = saved.operations[index]
        let body = try validate(operation)
        guard operation.recordJSON == nil, operation.attempted == false,
              try retainedSignature(operation, journal: authorJournal(String(body.signer.dropFirst(7)))) == nil else {
            throw RemoteControlPublicationError.requiresReview
        }
        _ = try transaction { $0.operations.remove(at: index) }
    }

    public func stationStored(_ delivery: RemoteControlDelivery, stationOrigin: String? = nil) throws {
        let index = try matching(delivery)
        let origin = stationOrigin ?? saved.stationOrigin
        if origin == saved.stationOrigin {
            try transaction { $0.operations[index].stationStored = true }
        } else {
            guard saved.operations[index].additionalStations?[origin] != nil else {
                throw RemoteControlPublicationError.invalidRecord
            }
            try transaction { $0.operations[index].additionalStations?[origin] = true }
        }
    }

    public func portalMirrored(_ delivery: RemoteControlDelivery) throws {
        let index = try matching(delivery)
        guard delivery.portalMirror != nil, saved.operations[index].portalRefusal == nil else {
            throw RemoteControlPublicationError.invalidRecord
        }
        try transaction { $0.operations[index].portalMirrored = true }
    }

    /// A final Portal refusal settles only the mirror, retaining the signed stop and Station delivery.
    public func portalRefused(_ delivery: RemoteControlDelivery, reason: RemoteControlPortalRefusal) throws {
        let index = try matching(delivery)
        let operation = saved.operations[index]
        guard delivery.portalMirror?.interruptRunning == true, !operation.portalMirrored else {
            throw RemoteControlPublicationError.invalidRecord
        }
        if let prior = operation.portalRefusal {
            guard prior == reason else { throw RemoteControlPublicationError.invalidRecord }
            return
        }
        try transaction { $0.operations[index].portalRefusal = reason }
    }

    private func matching(_ delivery: RemoteControlDelivery) throws -> Int {
        try available()
        let index = try index(delivery.recordID)
        let operation = saved.operations[index]
        guard delivery.stationOrigin == saved.stationOrigin, operation.recordJSON == delivery.recordJSON,
              operation.portalMirror == delivery.portalMirror else { throw RemoteControlPublicationError.invalidRecord }
        return index
    }

    private func check(_ log: MembershipLog) throws {
        guard log.accountId() == saved.accountID, log.genesisHash() == saved.genesisHash, log.frozen() == nil else {
            throw RemoteControlPublicationError.requiresReview
        }
    }

    private func verify(_ record: String, log: MembershipLog) throws {
        guard case .valid = try verifyControlRecord(log: log, recordJson: record) else {
            throw RemoteControlPublicationError.requiresReview
        }
    }

    private func validate(_ operation: Operation) throws -> ControlRecordBody {
        let body = try Self.body(operation.bodyJSON)
        guard body.accountId == saved.accountID, body.genesisHash == saved.genesisHash,
              body.origin == nil || body.origin == saved.stationOrigin,
              body.signer.hasPrefix("member:"), operation.headSeq > 0,
              operation.headSeq <= 9_007_199_254_740_991, RemoteRecoveryKit.validHash(operation.headHash),
              try canonicalJson(json: operation.bodyJSON) == operation.bodyJSON else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        _ = try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: String(body.signer.dropFirst(7)))
        if let stations = operation.additionalStations {
            guard stations.count <= 63, !stations.keys.contains(saved.stationOrigin),
                  stations.keys.allSatisfy(PortalIntegrationRecord.validOrigin),
                  body.principal.hasPrefix("host:"), body.action == "interrupt_running", body.origin == nil,
                  operation.recordJSON != nil || !stations.values.contains(true) else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
        }
        let signerKey = try Self.signerKey(operation)
        if let mirror = operation.portalMirror {
            try mirror.validate()
            guard body.principal.hasPrefix("service:"), body.action == "revoke",
                  mirror.stationOrigin == saved.stationOrigin, mirror.integrationID == body.integrationId,
                  mirror.interruptRunning == body.interruptRunning else { throw RemoteControlPublicationError.invalidCheckpoint }
        } else if body.principal.hasPrefix("service:"), body.action == "revoke",
                  operation.resignsRecordID == nil, operation.observed != true {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        if let record = operation.recordJSON {
            guard try signedObjectInfo(json: record).bodyJcs == operation.bodyJSON,
                  try parseControlRecord(recordJson: record) == body else { throw RemoteControlPublicationError.invalidCheckpoint }
            try verifySignedObject(json: record, key: signerKey)
        } else if operation.stationStored || operation.portalMirrored || operation.portalRefusal != nil {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        guard !operation.portalMirrored || operation.portalMirror != nil else { throw RemoteControlPublicationError.invalidCheckpoint }
        if operation.portalRefusal != nil {
            guard !operation.portalMirrored, operation.portalMirror?.interruptRunning == true else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
        }
        if operation.observed == true {
            guard operation.recordJSON != nil, operation.stationStored, operation.portalMirror == nil,
                  operation.resignsRecordID == nil else { throw RemoteControlPublicationError.invalidCheckpoint }
        }
        return body
    }

    private func validateReplacement(_ operation: Operation, original: Operation) throws {
        let old = try validate(original), body = try validate(operation)
        guard original.recordJSON != nil, operation.resignsRecordID == old.recordId,
              operation.portalMirror == nil, body.recordId != old.recordId, body.signer != old.signer,
              body.issuedAt > old.issuedAt, body.principal == old.principal, body.principalKey == old.principalKey,
              body.origin == old.origin, body.action == old.action, body.interruptRunning == old.interruptRunning,
              body.revokeSeq == old.revokeSeq, body.integrationId == old.integrationId, body.by == old.by,
              Set((operation.additionalStations ?? [:]).keys) == Set((original.additionalStations ?? [:]).keys) else {
            throw RemoteControlPublicationError.invalidRecord
        }
    }

    private func checkResignSource(_ operation: Operation, log: MembershipLog) throws {
        guard let source = operation.resignsRecordID else { return }
        let original = saved.operations[try index(source)]
        guard let record = original.recordJSON,
              case .refused(let reason) = try verifyControlRecord(log: log, recordJson: record),
              reason == "removed_manager" else { throw RemoteControlPublicationError.requiresReview }
    }

    private static func signerKey(_ operation: Operation) throws -> PublicKeyData {
        guard ["p256", "ed25519"].contains(operation.signerAlgorithm) else { throw RemoteControlPublicationError.invalidCheckpoint }
        let key = PublicKeyData(alg: operation.signerAlgorithm == "p256" ? .p256 : .ed25519, raw: operation.signerPublicKey)
        try checkPublicKey(key: key)
        return key
    }

    private static func unsigned(_ bodyJSON: String) -> String {
        "{\"body\":" + bodyJSON + ",\"sig\":\"" + RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64)) + "\"}"
    }
    private static func body(_ bodyJSON: String) throws -> ControlRecordBody {
        try parseControlRecord(recordJson: unsigned(bodyJSON))
    }
    private func index(_ id: String) throws -> Int {
        guard let index = saved.operations.firstIndex(where: { (try? Self.body($0.bodyJSON).recordId) == id }) else {
            throw RemoteControlPublicationError.invalidRecord
        }
        return index
    }
    private func available() throws {
        guard !storageUncertain else { throw RemoteControlPublicationError.storageUncertain }
        guard !operating else { throw RemoteControlPublicationError.busy }
    }
    private func transaction<T>(_ update: (inout Checkpoint) throws -> T) throws -> T {
        try available()
        operating = true
        defer { operating = false }
        return try commit(update)
    }

    private func commit<T>(_ update: (inout Checkpoint) throws -> T) throws -> T {
        var next = saved
        next.version = 2
        let result = try update(&next)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(next)
        guard data.count <= 2_097_152 else { throw RemoteControlPublicationError.full }
        do { try persist(data) }
        catch { storageUncertain = true; throw error }
        saved = next
        return result
    }
}

private final class ControlRequestCapture: AppKeyProvider, @unchecked Sendable {
    let keyID: String
    let key: PublicKeyData
    private(set) var request: SignRequest?
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
