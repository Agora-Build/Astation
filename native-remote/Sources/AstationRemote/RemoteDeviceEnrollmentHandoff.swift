import AtemClient
import CryptoKit
import Foundation

/// The carrier sees only this bounded, authenticated ciphertext. Account keys
/// are released only after the signed add and a durable native checkpoint.
public struct RemoteDeviceEnrollmentHandoff: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        let version: Int
        let invitation: String
        let request: String
        let seq: UInt64
        let head: String
        let entry: String
    }
    struct Key: Codable { let kid: String; let k: String }
    struct Payload: Codable { let keys: [Key] }
    let context: Context
    let enc: String
    let ciphertext: String
    let mac: String

    public func json() throws -> String { try RemoteEnrollmentCoding.json(self) }

    public init(json: String, invitation: RemoteDeviceEnrollmentInvitation, request: RemoteDeviceEnrollmentRequest,
        now: HostClock) throws {
        self = try RemoteEnrollmentCoding.parse(Self.self, json)
        try validate(invitation: invitation, request: request, now: now)
    }

    @MainActor
    public static func seal(invitation: RemoteDeviceEnrollmentInvitation, request: RemoteDeviceEnrollmentRequest,
        committedLog: MembershipLog, keys: [AccountKey], now: HostClock) throws -> Self {
        try request.validate(invitation: invitation, now: now)
        let entry = try acceptedEntry(invitation: invitation, request: request, log: committedLog, now: now)
        try checkKeys(keys)
        let context = Context(version: 1, invitation: try invitation.commitment, request: try request.digest,
            seq: committedLog.head().seq, head: committedLog.head().hash, entry: entry)
        let plaintext = Data(try RemoteEnrollmentCoding.json(Payload(keys: keys.map {
            Key(kid: $0.kid, k: RemoteEnrollmentCoding.text($0.k))
        })).utf8)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.encryptionKey.raw),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info(context))
        let enc = RemoteEnrollmentCoding.text(sender.encapsulatedKey)
        let ciphertext = RemoteEnrollmentCoding.text(try sender.seal(plaintext, authenticating: aad(context)))
        let result = Self(context: context, enc: enc, ciphertext: ciphertext,
            mac: try RemoteEnrollmentCoding.mac(macInput(context, enc, ciphertext), secret: invitation.secret))
        _ = try Self(json: result.json(), invitation: invitation, request: request, now: now)
        return result
    }

    private init(context: Context, enc: String, ciphertext: String, mac: String) {
        self.context = context; self.enc = enc; self.ciphertext = ciphertext; self.mac = mac
    }

    @MainActor
    func open(invitation: RemoteDeviceEnrollmentInvitation, request: RemoteDeviceEnrollmentRequest,
        identity: RemoteDevicePublicIdentity, log: MembershipLog, now: HostClock,
        decrypt: (Data, Data, Data, Data) throws -> Data) throws -> [AccountKey] {
        try validate(invitation: invitation, request: request, now: now)
        guard identity.deviceID == request.deviceID, identity.authKey == (try request.authKey),
              identity.encryptionKey == (try request.encryptionKey), context.seq <= UInt64(log.entries().count),
              try signedObjectInfo(json: log.entries()[Int(context.seq) - 1]).entryHash == context.head,
              try Self.acceptedEntry(invitation: invitation, request: request, log: log, now: now) == context.entry else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
        let plaintext = try decrypt(RemoteEnrollmentCoding.bytes(enc, count: 32), ciphertextBytes(),
            Self.info(context), Self.aad(context))
        guard let text = String(data: plaintext, encoding: .utf8) else { throw RemoteDeviceEnrollmentError.invalidMessage }
        let payload = try RemoteEnrollmentCoding.parse(Payload.self, text)
        let keys = try payload.keys.map { AccountKey(kid: $0.kid, k: try RemoteEnrollmentCoding.bytes($0.k, count: 32)) }
        try Self.checkKeys(keys)
        return keys
    }

    private func validate(invitation: RemoteDeviceEnrollmentInvitation, request: RemoteDeviceEnrollmentRequest, now: HostClock) throws {
        try request.validate(invitation: invitation, now: now)
        guard context.version == 1, context.invitation == (try invitation.commitment), context.request == (try request.digest),
              context.seq > invitation.seq, context.seq <= 8_192, RemoteRecoveryKit.validHash(context.head),
              RemoteRecoveryKit.validHash(context.entry) else { throw RemoteDeviceEnrollmentError.invalidMessage }
        _ = try RemoteEnrollmentCoding.bytes(enc, count: 32)
        _ = try ciphertextBytes()
        try RemoteEnrollmentCoding.verifyMAC(mac, input: Self.macInput(context, enc, ciphertext), secret: invitation.secret)
    }

    @MainActor
    static func acceptedEntry(invitation: RemoteDeviceEnrollmentInvitation, request: RemoteDeviceEnrollmentRequest,
        log: MembershipLog, now: HostClock) throws -> String {
        try invitation.checkManager(log: log, now: now)
        let current = log.snapshot()
        _ = try current.advance(now: now)
        guard let member = current.member(deviceId: request.deviceID), member.kind == "native", member.status == .active,
              member.roles == request.roles, member.authKey == (try request.authKey),
              member.encKey == (try request.encryptionKey) else { throw RemoteDeviceEnrollmentError.wrongContext }
        for entry in current.entries().dropFirst(Int(invitation.seq)) {
            let info = try signedObjectInfo(json: entry)
            let body = try JSONSerialization.jsonObject(with: Data(info.bodyJcs.utf8)) as? [String: Any]
            guard body?["action"] as? String == "add", body?["signer"] as? String == invitation.manager,
                  let applicant = body?["member"],
                  let signed = body?["signed_at"] as? NSNumber, CFGetTypeID(signed) != CFBooleanGetTypeID(),
                  signed.uint64Value >= invitation.created, signed.uint64Value < invitation.expires else { continue }
            let json = try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: applicant), as: UTF8.self))
            if json == (try canonicalJson(json: member.memberJson)), let hash = info.entryHash { return hash }
        }
        throw RemoteRecoveryError.notCommitted
    }

    private func ciphertextBytes() throws -> Data {
        guard ciphertext.utf8.count <= 12_000,
              let bytes = Data(base64Encoded: ciphertext.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - ciphertext.utf8.count % 4) % 4)),
              (16...9_000).contains(bytes.count), RemoteEnrollmentCoding.text(bytes) == ciphertext else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
        return bytes
    }
    private static func checkKeys(_ keys: [AccountKey]) throws {
        guard (1...32).contains(keys.count), Set(keys.map(\.kid)).count == keys.count,
              keys.allSatisfy({ RemoteRecoveryKit.validID($0.kid) && $0.k.count == 32 }) else {
            throw RemoteDeviceEnrollmentError.invalidMessage
        }
    }
    private static func info(_ context: Context) -> Data {
        encodeFields(fields: ["astation-device-handoff-hpke-v1", context.invitation, context.request].map { Data($0.utf8) })
    }
    private static func aad(_ context: Context) throws -> Data { Data(try RemoteEnrollmentCoding.json(context).utf8) }
    private static func macInput(_ context: Context, _ enc: String, _ ciphertext: String) throws -> Data {
        encodeFields(fields: [Data("astation-device-handoff-auth-v1".utf8), try aad(context), Data(enc.utf8), Data(ciphertext.utf8)])
    }
}

/// Keep this complete record in native, device-only protected storage. The
/// caller must commit it atomically before publishing trusted-device status.
@MainActor
public struct RemoteEnrolledDevice {
    private struct Saved: Codable {
        let version: Int
        let issuer: String
        let owner: String
        let station: String
        let account: String
        let genesis: String
        let device: String
        let auth: String
        let encryption: String
        let membership: String
        let keys: [RemoteDeviceEnrollmentHandoff.Key]
    }
    private let saved: Saved
    public let accountKeys: [AccountKey]
    public var accountID: String { saved.account }
    public var genesisHash: String { saved.genesis }
    public var deviceID: String { saved.device }

    public init(handoff: RemoteDeviceEnrollmentHandoff, invitation: RemoteDeviceEnrollmentInvitation,
        request: RemoteDeviceEnrollmentRequest, identity: RemoteAppleDeviceIdentity, log: MembershipLog,
        now: HostClock, persist: (Data) throws -> Void) throws {
        try identity.validateEnrollmentContext(invitation, now: now)
        accountKeys = try handoff.open(invitation: invitation, request: request, identity: identity.publicIdentity,
            log: log, now: now, decrypt: { try identity.open(enc: $0, ciphertext: $1, info: $2, aad: $3) })
        saved = Saved(version: 1, issuer: invitation.issuer, owner: invitation.owner, station: invitation.station,
            account: invitation.account, genesis: invitation.genesis, device: request.deviceID,
            auth: RemoteEnrollmentCoding.text(identity.publicIdentity.authKey.raw),
            encryption: RemoteEnrollmentCoding.text(identity.publicIdentity.encryptionKey.raw),
            membership: try log.storedJson(), keys: accountKeys.map { .init(kid: $0.kid, k: RemoteEnrollmentCoding.text($0.k)) })
        try persist(PropertyListEncoder().encode(saved))
    }

    public init(checkpoint: Data, issuer: String, owner: String, station: String,
        identity: RemoteDevicePublicIdentity, now: HostClock) throws {
        guard checkpoint.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Saved.self, from: checkpoint)
        guard saved.version == 1, saved.issuer == issuer, saved.owner == owner, saved.station == station,
              saved.device == identity.deviceID, saved.auth == RemoteEnrollmentCoding.text(identity.authKey.raw),
              saved.encryption == RemoteEnrollmentCoding.text(identity.encryptionKey.raw) else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
        accountKeys = try saved.keys.map { AccountKey(kid: $0.kid, k: try RemoteEnrollmentCoding.bytes($0.k, count: 32)) }
        guard (1...32).contains(accountKeys.count), Set(accountKeys.map(\.kid)).count == accountKeys.count,
              accountKeys.allSatisfy({ RemoteRecoveryKit.validID($0.kid) }) else { throw RemoteRecoveryError.invalidCheckpoint }
        _ = try membership(now: now)
    }

    public func membership(now: HostClock) throws -> MembershipLog {
        let log = try MembershipLog.fromStored(accountId: saved.account, genesisHash: saved.genesis, storedJson: saved.membership, now: now)
        guard log.frozen() == nil, let member = log.member(deviceId: saved.device), member.kind == "native", member.status == .active,
              member.authKey == (try PublicKeyData(alg: .p256, raw: RemoteEnrollmentCoding.bytes(saved.auth, count: 65))),
              member.encKey == (try PublicKeyData(alg: .x25519, raw: RemoteEnrollmentCoding.bytes(saved.encryption, count: 32))) else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
        return log
    }
}
