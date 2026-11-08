import AtemClient
import CryptoKit
import Foundation

/// App-local review context. The host receives only the existing R9 `add` entry.
/// This is not an invitation, proof of key possession, or a trusted root from Station.
public struct RemoteNativeEnrollment: Codable, Equatable, Sendable {
    public let requestID: String
    public let stationOrigin: String
    public let accountID: String
    public let genesisHash: String
    public let expiresAt: UInt64
    public let bodyJSON: String
    public let fingerprint: String

    public var deviceID: String { (try? member()["device_id"] as? String) ?? "" }
    public var roles: [String] { (try? member()["roles"] as? [String]) ?? [] }

    /// Applicant keys must come from the verified device ceremony. Login is not that ceremony.
    @MainActor
    public init(requestID: String, stationOrigin: String, deviceID: String,
        authKey: PublicKeyData, encryptionKey: PublicKeyData, roles: [String], expiresAt: UInt64,
        log: MembershipLog, managerID: String, now: HostClock) throws {
        guard authKey.alg == .p256 || authKey.alg == .ed25519, encryptionKey.alg == .x25519 else {
            throw RemoteChannelError.invalidInput
        }
        try checkPublicKey(key: authKey)
        try checkPublicKey(key: encryptionKey)
        let action: [String: Any] = ["action": "add", "member": [
            "device_id": deviceID, "kind": "native", "roles": roles,
            "auth_key": ["alg": authKey.alg == .p256 ? "p256" : "ed25519", "pub": RemoteRecoveryKit.base64URL(authKey.raw)],
            "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(encryptionKey.raw)]
        ]]
        self.requestID = requestID
        self.stationOrigin = stationOrigin
        accountID = log.accountId()
        genesisHash = log.genesisHash()
        self.expiresAt = expiresAt
        bodyJSON = try log.draftEntry(signer: managerID, signedAt: now.wallMs, actionJson: Self.json(action))
        fingerprint = Self.digest(requestID: requestID, stationOrigin: stationOrigin, expiresAt: expiresAt, body: bodyJSON)
        try validate(log: log, managerID: managerID, now: now)
    }

    /// Commit the exact review before presenting its native owner-confirmation prompt.
    @MainActor
    public func prepare(publication: RemoteMembershipPublication, managerID: String, now: HostClock) throws -> SignRequest {
        try validate(log: publication.committedLog(), managerID: managerID, now: now)
        let body = try Self.object(bodyJSON)
        let prepared = try publication.prepare(actionJSON: Self.json(["action": "add", "member": try member()]),
            signer: managerID, signedAt: Self.number(body["signed_at"]), operationContext: checkpoint())
        guard prepared == bodyJSON else { throw RemoteChannelError.invalidInput }
        return try RemoteConfirmedSigner.membershipRequest(bodyJSON: prepared, keyID: managerID)
    }

    @MainActor
    public func sign(publication: RemoteMembershipPublication, provider: AppKeyProvider, managerID: String,
        confirmedFingerprint: String, validationClock: HostClock, confirmedAt: UInt64,
        now: @escaping @Sendable () -> UInt64, current: () -> Bool) throws -> AppendRequest {
        guard current(), confirmedFingerprint == fingerprint,
              publication.operationContext == (try checkpoint()) else { throw RemoteChannelError.staleLink }
        try validate(log: publication.committedLog(), managerID: managerID, now: validationClock)
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: bodyJSON, keyID: managerID)
        let signer = try RemoteConfirmedSigner(provider: provider, request: request, confirmedAt: confirmedAt, now: now)
        guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
        let append = try publication.sign(provider: signer, keyID: managerID)
        guard try signedObjectInfo(json: append.entryJson).bodyJcs == bodyJSON else {
            throw RemoteChannelError.invalidInput
        }
        return append
    }

    /// Only a verified, locally committed entry completes the manager's part of enrollment.
    /// The phone must separately pin the root, verify the log and save its sealed account keys.
    @MainActor
    public func committedLog(publication: RemoteMembershipPublication, now: HostClock) throws -> MembershipLog {
        try validateContext()
        let log = try publication.committedLog()
        _ = try log.advance(now: now)
        guard log.accountId() == accountID, log.genesisHash() == genesisHash, log.frozen() == nil,
              log.entries().contains(where: { (try? signedObjectInfo(json: $0).bodyJcs) == bodyJSON }),
              let accepted = log.member(deviceId: deviceID), accepted.kind == "native", accepted.status == .active,
              try canonicalJson(json: accepted.memberJson) == Self.json(member()) else {
            throw RemoteRecoveryError.notCommitted
        }
        return log
    }

    public func checkpoint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    private func validate(log: MembershipLog, managerID: String, now: HostClock) throws {
        try validateContext()
        let log = log.snapshot()
        _ = try log.advance(now: now)
        let body = try Self.object(bodyJSON)
        let signedAt = try Self.number(body["signed_at"])
        guard log.accountId() == accountID, log.genesisHash() == genesisHash, log.frozen() == nil,
              let manager = log.member(deviceId: managerID), manager.kind == "native", manager.status == .active,
              manager.roles.contains("manage"), log.member(deviceId: deviceID) == nil,
              signedAt <= now.wallMs, now.wallMs < expiresAt else {
            throw RemoteRecoveryError.requiresReview
        }
        let action = try Self.json(["action": "add", "member": try member()])
        guard try log.checkChange(actionJson: action, nowMs: now.wallMs) == nil else {
            throw RemoteRecoveryError.requiresReview
        }
        let expected = try log.draftEntry(signer: managerID, signedAt: signedAt, actionJson: action)
        guard expected == bodyJSON else { throw RemoteRecoveryError.confirmationRequired }
    }

    private func validateContext() throws {
        guard RemoteRecoveryKit.validID(requestID), PortalIntegrationRecord.validOrigin(stationOrigin),
              RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              bodyJSON.utf8.count <= 16_384, try canonicalJson(json: bodyJSON) == bodyJSON,
              fingerprint == Self.digest(requestID: requestID, stationOrigin: stationOrigin, expiresAt: expiresAt, body: bodyJSON)
        else { throw RemoteChannelError.invalidInput }
        let body = try Self.object(bodyJSON)
        let applicant = try member()
        let signedAt = try Self.number(body["signed_at"])
        guard body["action"] as? String == "add", body["account_id"] as? String == accountID,
              body["genesis_hash"] as? String == genesisHash, applicant["kind"] as? String == "native",
              let deviceID = applicant["device_id"] as? String, RemoteRecoveryKit.validID(deviceID),
              // Managing the account is a separate, explicit role change, never an enrollment default.
              [ ["view"], ["control", "view"] ].contains(applicant["roles"] as? [String] ?? []),
              signedAt < expiresAt, expiresAt <= 9_007_199_254_740_991, expiresAt - signedAt <= 600_000 else {
            throw RemoteChannelError.invalidInput
        }
        try Self.checkKeys(applicant)
    }

    private static func checkKeys(_ member: [String: Any]) throws {
        guard let auth = member["auth_key"] as? [String: Any], let algorithm = auth["alg"] as? String,
              ["p256", "ed25519"].contains(algorithm), let encodedAuth = auth["pub"] as? String,
              let authBytes = RemoteRecoveryKit.decodeBase64URL(encodedAuth, count: algorithm == "p256" ? 65 : 32),
              let enc = member["enc_key"] as? [String: Any], enc["alg"] as? String == "x25519",
              let encodedEnc = enc["pub"] as? String,
              let encBytes = RemoteRecoveryKit.decodeBase64URL(encodedEnc, count: 32) else {
            throw RemoteChannelError.invalidInput
        }
        try checkPublicKey(key: PublicKeyData(alg: algorithm == "p256" ? .p256 : .ed25519, raw: authBytes))
        try checkPublicKey(key: PublicKeyData(alg: .x25519, raw: encBytes))
        // Encoding validation alone does not reject X25519 low-order points.
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encBytes)
        _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: recipient)
    }

    private func member() throws -> [String: Any] {
        guard let member = try Self.object(bodyJSON)["member"] as? [String: Any] else {
            throw RemoteChannelError.invalidInput
        }
        return member
    }

    private static func digest(requestID: String, stationOrigin: String, expiresAt: UInt64, body: String) -> String {
        hashFields(fields: ["astation-native-enrollment-review-v1", requestID, stationOrigin, String(expiresAt), body].map { Data($0.utf8) })
    }

    private static func object(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RemoteChannelError.invalidInput
        }
        return value
    }

    private static func json(_ value: Any) throws -> String {
        try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    private static func number(_ value: Any?) throws -> UInt64 {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue >= 0,
              value.doubleValue <= 9_007_199_254_740_991, value.doubleValue.rounded(.towardZero) == value.doubleValue else {
            throw RemoteChannelError.invalidInput
        }
        return value.uint64Value
    }
}
