import AtemClient
import CryptoKit
import Foundation

public enum RemoteDeviceEnrollmentError: LocalizedError, Equatable {
    case invalidMessage, expired, wrongContext, invalidProof, alreadyUsed, cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "This device setup message could not be verified. Start setup again from your trusted device."
        case .expired: return "Device setup expired. Show a new setup code on your trusted device."
        case .wrongContext: return "This setup belongs to a different account or Station."
        case .invalidProof: return "The device keys or setup code do not match. Nothing was approved."
        case .alreadyUsed: return "This setup code is already being used by another device. Start a new setup."
        case .cancelled: return "Device setup was cancelled."
        }
    }
}

enum RemoteEnrollmentCoding {
    static let maximumMessageBytes = 16_384

    static func json<T: Encodable>(_ value: T) throws -> String {
        try canonicalJson(json: String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    static func parse<T: Codable>(_ type: T.Type, _ text: String) throws -> T {
        guard text.utf8.count <= maximumMessageBytes else { throw RemoteDeviceEnrollmentError.invalidMessage }
        let canonical = try canonicalJson(json: text)
        let value = try JSONDecoder().decode(type, from: Data(canonical.utf8))
        // Reject unknown fields as well as duplicate keys and noncanonical encodings.
        guard try json(value) == canonical else { throw RemoteDeviceEnrollmentError.invalidMessage }
        return value
    }

    static func random() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func text(_ data: Data) -> String { RemoteRecoveryKit.base64URL(data) }
    static func bytes(_ text: String, count: Int) throws -> Data {
        guard let data = RemoteRecoveryKit.decodeBase64URL(text, count: count) else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        return data
    }
    static func digest(_ domain: String, _ fields: [String]) -> String {
        hashFields(fields: ([domain] + fields).map { Data($0.utf8) })
    }
    static func mac(_ input: Data, secret: String) throws -> String {
        text(Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: try bytes(secret, count: 32)))))
    }
    static func verifyMAC(_ mac: String, input: Data, secret: String) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(try bytes(mac, count: 32), authenticating: input,
            using: SymmetricKey(data: try bytes(secret, count: 32))) else { throw RemoteDeviceEnrollmentError.invalidProof }
    }
}

/// Native-only QR contents, scanned directly from an already trusted manager.
/// Its secret must never enter Flutter, a URL, analytics or Station storage.
public struct RemoteDeviceEnrollmentInvitation: Codable, Equatable, Sendable {
    public let version: Int
    public let issuer: String
    public let owner: String
    public let station: String
    public let account: String
    public let genesis: String
    public let manager: String
    public let seq: UInt64
    public let head: String
    public let id: String
    public let created: UInt64
    public let expires: UInt64
    public let roles: [String]
    let secret: String

    @MainActor
    public init(issuer: String, owner: String, station: String, log: MembershipLog,
        manager: String, roles: [String], now: HostClock, lifetime: UInt64 = 300_000) throws {
        guard lifetime > 0, lifetime <= 600_000, now.wallMs <= 9_007_199_254_140_991 else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        version = 1
        self.issuer = issuer; self.owner = owner; self.station = station
        account = log.accountId(); genesis = log.genesisHash(); self.manager = manager
        seq = log.head().seq; head = log.head().hash
        id = RemoteEnrollmentCoding.text(RemoteEnrollmentCoding.random())
        secret = RemoteEnrollmentCoding.text(RemoteEnrollmentCoding.random())
        created = now.wallMs; expires = now.wallMs + lifetime; self.roles = roles
        try validate(issuer: issuer, owner: owner, station: station, now: now)
        try checkManager(log: log, now: now)
    }

    public init(scannedJSON: String, issuer: String, owner: String, station: String, now: HostClock) throws {
        self = try RemoteEnrollmentCoding.parse(Self.self, scannedJSON)
        try validate(issuer: issuer, owner: owner, station: station, now: now)
    }

    public func qrJSON() throws -> String { try RemoteEnrollmentCoding.json(self) }
    public var commitment: String { get throws { RemoteEnrollmentCoding.digest("astation-device-invitation-v1", [try qrJSON()]) } }

    public func validate(issuer: String, owner: String, station: String, now: HostClock) throws {
        guard version == 1, PortalIntegrationRecord.validOrigin(self.issuer),
              PortalIntegrationRecord.validOrigin(self.station), RemoteRecoveryKit.validID(self.owner),
              RemoteRecoveryKit.validID(account), RemoteRecoveryKit.validID(manager), manager != "recovery",
              RemoteRecoveryKit.validHash(genesis), RemoteRecoveryKit.validHash(head), seq > 0, seq <= 8_192,
              [["view"], ["control", "view"]].contains(roles), created < expires,
              expires <= 9_007_199_254_740_991, expires - created <= 600_000 else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        _ = try RemoteEnrollmentCoding.bytes(id, count: 32)
        _ = try RemoteEnrollmentCoding.bytes(secret, count: 32)
        guard self.issuer == issuer, self.owner == owner, self.station == station else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
        guard created <= now.wallMs, now.wallMs < expires else { throw RemoteDeviceEnrollmentError.expired }
    }

    @MainActor
    func checkManager(log: MembershipLog, now: HostClock) throws {
        let log = log.snapshot()
        _ = try log.advance(now: now)
        guard log.accountId() == account, log.genesisHash() == genesis, log.frozen() == nil,
              let member = log.member(deviceId: manager), member.kind == "native", member.status == .active,
              member.roles.contains("manage"), log.entries().count >= Int(seq),
              try signedObjectInfo(json: log.entries()[Int(seq) - 1]).entryHash == head else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
    }
}

public struct RemoteDeviceEnrollmentRequest: Codable, Equatable, Sendable {
    struct Body: Codable, Equatable, Sendable {
        let version: Int
        let invitation: String
        let device: String
        let name: String
        let auth: String
        let encryption: String
        let roles: [String]
        let nonce: String
    }
    let body: Body
    let signature: String
    let mac: String

    public var deviceID: String { body.device }
    public var deviceName: String { body.name }
    public var roles: [String] { body.roles }
    public var authKey: PublicKeyData { get throws { PublicKeyData(alg: .p256, raw: try RemoteEnrollmentCoding.bytes(body.auth, count: 65)) } }
    public var encryptionKey: PublicKeyData { get throws { PublicKeyData(alg: .x25519, raw: try RemoteEnrollmentCoding.bytes(body.encryption, count: 32)) } }
    public var digest: String { get throws { RemoteEnrollmentCoding.digest("astation-device-request-v1", [try json()]) } }
    public var safetyCode: String {
        get throws {
            let value = try digest.prefix(12).uppercased()
            return stride(from: 0, to: 12, by: 4).map { offset in
                String(value.dropFirst(offset).prefix(4))
            }.joined(separator: "-")
        }
    }
    public func json() throws -> String { try RemoteEnrollmentCoding.json(self) }

    public init(json: String, invitation: RemoteDeviceEnrollmentInvitation, now: HostClock) throws {
        self = try RemoteEnrollmentCoding.parse(Self.self, json)
        try validate(invitation: invitation, now: now)
    }

    static func proofInput(_ body: Body) throws -> Data {
        encodeFields(fields: [Data("astation-device-applicant-proof-v1".utf8), Data(try RemoteEnrollmentCoding.json(body).utf8)])
    }

    @MainActor
    static func make(invitation: RemoteDeviceEnrollmentInvitation, identity: RemoteDevicePublicIdentity,
        name: String, now: HostClock, sign: (Data) throws -> Data) throws -> Self {
        let body = Body(version: 1, invitation: try invitation.commitment, device: identity.deviceID, name: name,
            auth: RemoteEnrollmentCoding.text(identity.authKey.raw), encryption: RemoteEnrollmentCoding.text(identity.encryptionKey.raw),
            roles: invitation.roles, nonce: RemoteEnrollmentCoding.text(RemoteEnrollmentCoding.random()))
        guard identity.authKey.alg == .p256, identity.encryptionKey.alg == .x25519 else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        try validateBody(body, invitation: invitation)
        let signature = try RemoteEnrollmentCoding.text(RemoteP256Signature.normalize(sign(proofInput(body))))
        let mac = try RemoteEnrollmentCoding.mac(macInput(body, signature), secret: invitation.secret)
        let request = Self(body: body, signature: signature, mac: mac)
        try request.validate(invitation: invitation, now: now)
        return request
    }

    private init(body: Body, signature: String, mac: String) { self.body = body; self.signature = signature; self.mac = mac }

    public func validate(invitation: RemoteDeviceEnrollmentInvitation, now: HostClock) throws {
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: invitation.station, now: now)
        try Self.validateBody(body, invitation: invitation)
        try RemoteEnrollmentCoding.verifyMAC(mac, input: Self.macInput(body, signature), secret: invitation.secret)
        let raw = try RemoteEnrollmentCoding.bytes(signature, count: 64)
        guard try RemoteP256Signature.normalize(raw) == raw,
              try P256.Signing.PublicKey(x963Representation: authKey.raw).isValidSignature(
                P256.Signing.ECDSASignature(rawRepresentation: raw), for: Self.proofInput(body)) else {
            throw RemoteDeviceEnrollmentError.invalidProof
        }
    }

    private static func validateBody(_ body: Body, invitation: RemoteDeviceEnrollmentInvitation) throws {
        guard body.version == 1, body.invitation == (try invitation.commitment),
              RemoteRecoveryKit.validID(body.device), body.device != "recovery", body.device != invitation.manager,
              (1...80).contains(body.name.utf8.count), body.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              body.name == body.name.trimmingCharacters(in: .whitespacesAndNewlines), body.roles == invitation.roles else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        _ = try RemoteEnrollmentCoding.bytes(body.nonce, count: 32)
        try checkPublicKey(key: PublicKeyData(alg: .p256, raw: RemoteEnrollmentCoding.bytes(body.auth, count: 65)))
        let encryption = try RemoteEnrollmentCoding.bytes(body.encryption, count: 32)
        _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryption))
    }

    private static func macInput(_ body: Body, _ signature: String) throws -> Data {
        encodeFields(fields: [Data("astation-device-request-auth-v1".utf8), Data(try RemoteEnrollmentCoding.json(body).utf8),
            try RemoteEnrollmentCoding.bytes(signature, count: 64)])
    }
}
