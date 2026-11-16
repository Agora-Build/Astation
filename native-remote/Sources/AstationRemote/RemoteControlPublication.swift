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
    public var portalSettled: Bool { portalMirrored || portalRefusal != nil }
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
        var recordJSON: String?
        var stationStored = false
        let portalMirror: RemoteControlPortalMirror?
        var portalMirrored = false
        var portalRefusal: RemoteControlPortalRefusal?
    }
    private struct Checkpoint: Codable {
        let version: Int
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
            $0.recordJSON != nil && (!$0.stationStored || ($0.portalMirror != nil && !$0.portalMirrored && $0.portalRefusal == nil))
        }.map { try Self.body($0.bodyJSON).recordId }
    }

    public func signingRequest(recordID: String) throws -> SignRequest? {
        try available()
        let operation = saved.operations[try index(recordID)]
        guard operation.recordJSON == nil else { return nil }
        let body = try validate(operation)
        return try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: String(body.signer.dropFirst(7)))
    }

    public init(accountID: String, genesisHash: String, stationOrigin: String,
        persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        saved = Checkpoint(version: 1, accountID: accountID, genesisHash: genesisHash,
            stationOrigin: stationOrigin, operations: [])
        self.persist = persist
    }

    public init(checkpoint: Data, accountID: String, genesisHash: String, stationOrigin: String,
        persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 2_097_152 else { throw RemoteControlPublicationError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        self.persist = persist
        guard saved.version == 1, saved.accountID == accountID, saved.genesisHash == genesisHash,
              saved.stationOrigin == stationOrigin, saved.operations.count <= 256,
              RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              PortalIntegrationRecord.validOrigin(stationOrigin) else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        var ids = Set<String>()
        for operation in saved.operations {
            let body = try validate(operation)
            guard ids.insert(body.recordId).inserted else { throw RemoteControlPublicationError.invalidCheckpoint }
        }
    }

    /// Reserve the Station timestamp first, then durably prepare before showing confirmation.
    /// The actual SDK builds the SignRequest; this layer has no control-record serializer.
    public func prepare(body: ControlRecordBody, log: MembershipLog,
        portalMirror: RemoteControlPortalMirror? = nil) throws -> SignRequest {
        try available()
        try check(log)
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
            signerAlgorithm: key.alg == .p256 ? "p256" : "ed25519", signerPublicKey: key.raw, portalMirror: portalMirror)
        _ = try validate(operation)
        // All authority checks precede signature verification in the shared verifier.
        guard case .refused(let reason) = try verifyControlRecord(log: log, recordJson: Self.unsigned(bodyJSON)),
              reason == "bad_signature" else { throw RemoteControlPublicationError.invalidRecord }
        if let prior = saved.operations.first(where: { (try? Self.body($0.bodyJSON).recordId) == body.recordId }) {
            guard prior.bodyJSON == bodyJSON, prior.headSeq == head.seq, prior.headHash == head.hash,
                  prior.portalMirror == portalMirror else { throw RemoteControlPublicationError.requiresReview }
            return request
        }
        guard saved.operations.count < 256 else { throw RemoteControlPublicationError.full }
        try transaction { $0.operations.append(operation) }
        return request
    }

    /// A retry returns the stored signature, including for nondeterministic P-256 keys.
    public func sign(recordID: String, log: MembershipLog, provider: AppKeyProvider,
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
        return try transaction { next in
            let body = try validate(operation)
            let manager = String(body.signer.dropFirst(7))
            let request = try RemoteConfirmedSigner.controlRequest(bodyJSON: operation.bodyJSON, keyID: manager)
            guard let member = log.member(deviceId: manager), member.authKey == (try Self.signerKey(operation)),
                  try provider.publicKey(keyId: manager) == member.authKey else {
                throw RemoteControlPublicationError.requiresReview
            }
            let signer = try RemoteConfirmedSigner(provider: provider, request: request, confirmedAt: confirmedAt, now: now)
            guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
            let record = try buildControlRecord(provider: signer, keyId: manager, body: body)
            try verify(record, log: log)
            guard current(), log.head() == LogHead(seq: operation.headSeq, hash: operation.headHash),
                  log.frozen() == nil else { throw RemoteChannelError.staleLink }
            next.operations[index].recordJSON = record
            return record
        }
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
            portalRefusal: operation.portalRefusal)
    }

    public func cancelUnsigned(recordID: String) throws {
        try available()
        let index = try index(recordID)
        guard saved.operations[index].recordJSON == nil else { throw RemoteControlPublicationError.requiresReview }
        try transaction { $0.operations.remove(at: index) }
    }

    public func stationStored(_ delivery: RemoteControlDelivery) throws {
        let index = try matching(delivery)
        try transaction { $0.operations[index].stationStored = true }
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
        let signerKey = try Self.signerKey(operation)
        if let mirror = operation.portalMirror {
            try mirror.validate()
            guard body.principal.hasPrefix("service:"), body.action == "revoke",
                  mirror.stationOrigin == saved.stationOrigin, mirror.integrationID == body.integrationId,
                  mirror.interruptRunning == body.interruptRunning else { throw RemoteControlPublicationError.invalidCheckpoint }
        } else if body.principal.hasPrefix("service:"), body.action == "revoke" {
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
        return body
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
        var next = saved
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
