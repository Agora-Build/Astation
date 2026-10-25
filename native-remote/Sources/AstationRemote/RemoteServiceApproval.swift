import AtemClient
import CryptoKit
import Foundation

public enum RemoteServiceKeyFingerprint {
    public static func compute(_ key: PublicKeyData) throws -> String {
        switch key.alg {
        case .p256:
            guard key.raw.count == 65, key.raw.first == 4 else { throw RemoteChannelError.invalidInput }
            _ = try P256.Signing.PublicKey(x963Representation: key.raw)
        case .ed25519:
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: key.raw)
        default: throw RemoteChannelError.invalidInput
        }
        return SHA256.hash(data: key.raw).map { String(format: "%02x", $0) }.joined()
    }
}

/// Application consent context; only the existing R9 body is signed.
/// Persist it beside the publisher in the caller's protected checkpoint.
public struct RemoteServiceApproval: Codable, Equatable, Sendable {
    public let operationID: String
    public let integrationID: String
    public let issuer: String
    public let ownerAccount: String
    public let stationOrigin: String
    public let genesisHash: String
    public let bodyJSON: String
    public let fingerprint: String

    @MainActor
    public init(operationID: String, integrationID: String, issuer: String, ownerAccount: String, stationOrigin: String,
        bodyJSON: String, log: MembershipLog, managerID: String, now: HostClock) throws {
        guard bodyJSON.utf8.count <= 65_536 else { throw RemoteChannelError.invalidInput }
        self.operationID = operationID
        self.integrationID = integrationID
        self.issuer = issuer
        self.ownerAccount = ownerAccount
        self.stationOrigin = stationOrigin
        self.genesisHash = log.genesisHash()
        self.bodyJSON = try canonicalJson(json: bodyJSON)
        let member = try Self.validate(body: self.bodyJSON, log: log, managerID: managerID, now: now)
        let keyObject = member["auth_key"] as? [String: Any]
        guard let alg = keyObject?["alg"] as? String, let encoded = keyObject?["pub"] as? String,
              let bytes = RemoteRecoveryKit.decodeBase64URL(encoded, count: alg == "p256" ? 65 : 32) else { throw RemoteChannelError.invalidInput }
        let key: PublicKeyData
        switch alg {
        case "p256": key = PublicKeyData(alg: .p256, raw: bytes)
        case "ed25519": key = PublicKeyData(alg: .ed25519, raw: bytes)
        default: throw RemoteChannelError.invalidInput
        }
        fingerprint = try RemoteServiceKeyFingerprint.compute(key)
        try validateContext()
    }

    @MainActor
    public func prepare(publication: RemoteMembershipPublication, managerID: String, now: HostClock) throws -> SignRequest {
        try validateContext()
        let log = try publication.committedLog()
        guard log.genesisHash() == genesisHash else { throw RemoteChannelError.staleLink }
        let member = try Self.validate(body: bodyJSON, log: log, managerID: managerID, now: now)
        let body = try Self.object(bodyJSON)
        let action = try Self.json(["action": "add", "member": member])
        let prepared = try publication.prepare(actionJSON: action, signer: managerID,
            signedAt: try Self.number(body["signed_at"]), operationContext: checkpoint())
        guard prepared == bodyJSON else { throw RemoteChannelError.invalidInput }
        return try RemoteConfirmedSigner.membershipRequest(bodyJSON: prepared, keyID: managerID)
    }

    @MainActor
    public func sign(publication: RemoteMembershipPublication, provider: AppKeyProvider,
        managerID: String, validationClock: HostClock, confirmedAt: UInt64, now: @escaping @Sendable () -> UInt64,
        current: () -> Bool) throws -> AppendRequest {
        try validateContext()
        guard current(), publication.operationContext == (try checkpoint()) else { throw RemoteChannelError.staleLink }
        let log = try publication.committedLog()
        guard log.genesisHash() == genesisHash else { throw RemoteChannelError.staleLink }
        _ = try Self.validate(body: bodyJSON, log: log, managerID: managerID, now: validationClock)
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: bodyJSON, keyID: managerID)
        let signer = try RemoteConfirmedSigner(provider: provider, request: request, confirmedAt: confirmedAt, now: now)
        guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
        let append = try publication.sign(provider: signer, keyID: managerID)
        guard try signedObjectInfo(json: append.entryJson).bodyJcs == bodyJSON else { throw RemoteChannelError.invalidInput }
        return append
    }

    public func checkpoint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private func validateContext() throws {
        _ = try AccountOIDCConfiguration.endpoint(issuer)
        guard (1...128).contains(operationID.utf8.count),
              let auth = URLComponents(string: issuer), auth.path.isEmpty, auth.url?.absoluteString == issuer,
              PortalIntegrationRecord.validAccountID(ownerAccount), RemoteRecoveryKit.validHash(genesisHash),
              operationID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              PortalIntegrationRecord.validID(integrationID), PortalIntegrationRecord.validOrigin(stationOrigin),
              bodyJSON.utf8.count <= 65_536,
              try canonicalJson(json: bodyJSON) == bodyJSON,
              let member = try Self.object(bodyJSON)["member"] as? [String: Any],
              let key = member["auth_key"] as? [String: Any], let alg = key["alg"] as? String,
              let encoded = key["pub"] as? String,
              let raw = RemoteRecoveryKit.decodeBase64URL(encoded, count: alg == "p256" ? 65 : 32),
              ["p256", "ed25519"].contains(alg),
              try RemoteServiceKeyFingerprint.compute(PublicKeyData(alg: alg == "p256" ? .p256 : .ed25519, raw: raw)) == fingerprint
        else { throw RemoteChannelError.invalidInput }
    }

    @MainActor
    private static func validate(body: String, log: MembershipLog, managerID: String, now: HostClock) throws -> [String: Any] {
        let log = log.snapshot()
        _ = try log.advance(now: now)
        let object = try Self.object(body)
        guard log.frozen() == nil, let manager = log.member(deviceId: managerID), manager.kind == "native",
              manager.status == .active, manager.roles.contains("manage"),
              object["account_id"] as? String == log.accountId(), object["action"] as? String == "add",
              let member = object["member"] as? [String: Any], member["kind"] as? String == "service",
              member["roles"] as? [String] == ["service"], member["enc_key"] == nil,
              try number(object["signed_at"]) <= now.wallMs,
              try number(member["expires_at"]) > now.wallMs else { throw RemoteChannelError.invalidInput }
        let action = try Self.json(["action": "add", "member": member])
        let expected = try log.draftEntry(signer: managerID, signedAt: Self.number(object["signed_at"]), actionJson: action)
        guard expected == body else { throw RemoteRecoveryError.confirmationRequired }
        return member
    }

    private static func object(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw RemoteChannelError.invalidInput
        }
        return object
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    private static func number(_ value: Any?) throws -> UInt64 {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { throw RemoteChannelError.invalidInput }
        return value.uint64Value
    }
}
