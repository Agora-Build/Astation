import CryptoKit
import Foundation

struct AtemUnlockRequestWire: Codable, Equatable {
    let request: Data
    let signature: Data
    var signed: AtemSignedWire { AtemSignedWire(statement: request, signature: signature) }
}

struct AtemUnlockGrantWire: Codable, Equatable {
    let grant: AtemSignedWire
    let encappedKey: Data
    let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case grant, ciphertext
        case encappedKey = "encapped_key"
    }
}

struct AtemStorageRotateWire: Codable, Equatable {
    let rotate: AtemSignedWire
    let encappedKey: Data
    let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case rotate, ciphertext
        case encappedKey = "encapped_key"
    }

    var sealed: AtemHPKESealedKey { AtemHPKESealedKey(encapsulatedKey: encappedKey, ciphertext: ciphertext) }
}

enum AtemStorageKeyError: LocalizedError {
    case invalidStatement, invalidSignature, unverifiedDevice, wrongDevice, unavailableKey, staleRequest
    case replayedKey, wrongCurrentKey, pendingKey(String), identityChanged

    var errorDescription: String? {
        switch self {
        case .invalidStatement: return "The storage-key request is invalid."
        case .invalidSignature: return "The device signature is invalid."
        case .unverifiedDevice: return "This device's verification was revoked or is unknown to Astation. Verify its safety code again."
        case .wrongDevice: return "The request names a different device or account."
        case .unavailableKey: return "This Astation does not hold the requested storage key."
        case .staleRequest: return "The unlock request time is outside the five-minute window."
        case .replayedKey: return "This storage key ID was already acknowledged."
        case .wrongCurrentKey: return "The rotation does not name the current storage key."
        case .pendingKey: return "A storage-key rotation is pending; confirm or abandon it first."
        case .identityChanged: return "The verified device or Astation identity changed; retry."
        }
    }

    var pendingKid: String? {
        if case .pendingKey(let kid) = self { return kid }
        return nil
    }
}

enum AtemStatementReader {
    static func fields(_ bytes: Data, label: String, count: Int) throws -> [Data] {
        guard bytes.count <= 8192 else { throw AtemStorageKeyError.invalidStatement }
        let fields = try AtemE2ECrypto.decode(bytes, maximumFields: count)
        guard fields.count == count, fields.first == Data(label.utf8) else {
            throw AtemStorageKeyError.invalidStatement
        }
        return fields
    }

    static func text(_ field: Data, maximum: Int = 256, allowEmpty: Bool = false) throws -> String {
        guard field.count <= maximum, allowEmpty || !field.isEmpty,
              let value = String(data: field, encoding: .utf8) else { throw AtemStorageKeyError.invalidStatement }
        return value
    }

    static func number(_ field: Data) throws -> UInt64 {
        guard field.count == 8 else { throw AtemStorageKeyError.invalidStatement }
        return field.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func validKid(_ kid: String) -> Bool {
        kid.utf8.count == 8 && kid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func verify(_ signed: AtemSignedWire, publicKey: Data) throws {
        guard publicKey.count == 32, signed.signature.count == 64,
              signed.statement.count <= 8192,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signed.signature, for: signed.statement) else {
            throw AtemStorageKeyError.invalidSignature
        }
    }
}

struct AtemUnlockRequest: Equatable {
    let account: String
    let deviceId: String
    let bootId: String
    let ephemeralPublicKey: Data
    let nonce: Data
    let time: UInt64
    let storageKid: String

    init(statement: Data) throws {
        let fields = try AtemStatementReader.fields(statement, label: "atem-unlock-request-v1", count: 9)
        account = try AtemStatementReader.text(fields[1])
        deviceId = try AtemStatementReader.text(fields[2])
        bootId = try AtemStatementReader.text(fields[3], maximum: 256, allowEmpty: true)
        guard fields[4].isEmpty, fields[5].count == 32, fields[6].count == 32 else {
            throw AtemStorageKeyError.invalidStatement
        }
        ephemeralPublicKey = fields[5]
        nonce = fields[6]
        time = try AtemStatementReader.number(fields[7])
        storageKid = try AtemStatementReader.text(fields[8])
        guard AtemStatementReader.validKid(storageKid) else { throw AtemStorageKeyError.invalidStatement }
    }
}

struct AtemStorageRotate: Equatable {
    let account: String
    let deviceId: String
    let oldKid: String
    let newKid: String
    let sealedHash: Data

    init(statement: Data) throws {
        let fields = try AtemStatementReader.fields(statement, label: "atem-storage-rotate-v1", count: 6)
        account = try AtemStatementReader.text(fields[1])
        deviceId = try AtemStatementReader.text(fields[2])
        oldKid = try AtemStatementReader.text(fields[3], allowEmpty: true)
        newKid = try AtemStatementReader.text(fields[4])
        sealedHash = fields[5]
        guard (oldKid.isEmpty || AtemStatementReader.validKid(oldKid)), AtemStatementReader.validKid(newKid),
              oldKid != newKid, sealedHash.count == 32 else { throw AtemStorageKeyError.invalidStatement }
    }
}

struct AtemStorageSettlement {
    let account: String
    let deviceId: String
    let kid: String

    init(statement: Data, abandoning: Bool) throws {
        let label = abandoning ? "atem-storage-abandon-v1" : "atem-storage-confirm-v1"
        let fields = try AtemStatementReader.fields(statement, label: label, count: 4)
        account = try AtemStatementReader.text(fields[1])
        deviceId = try AtemStatementReader.text(fields[2])
        kid = try AtemStatementReader.text(fields[3])
        guard AtemStatementReader.validKid(kid) else { throw AtemStorageKeyError.invalidStatement }
    }
}

extension AtemStatements {
    static func unlockRequest(
        account: String, deviceId: String, bootId: String, ticket: String = "",
        ephemeralPublicKey: Data, nonce: Data, time: UInt64, storageKid: String
    ) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-unlock-request-v1".utf8), Data(account.utf8), Data(deviceId.utf8),
            Data(bootId.utf8), Data(ticket.utf8), ephemeralPublicKey, nonce, number(time), Data(storageKid.utf8),
        ])
    }

    static func unlockInfo(account: String, deviceId: String, kid: String, requestHash: Data) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-unlock-info-v1".utf8), Data(account.utf8), Data(deviceId.utf8), Data(kid.utf8), requestHash,
        ])
    }

    static func unlockGrant(account: String, deviceId: String, kid: String, requestHash: Data, sealedHash: Data) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-unlock-grant-v1".utf8), Data(account.utf8), number(1),
            Data(deviceId.utf8), Data(kid.utf8), requestHash, sealedHash,
        ])
    }

    static func storageKeyInfo(account: String, deviceId: String, kid: String) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-storage-key-info-v1".utf8), Data(account.utf8), Data(deviceId.utf8), Data(kid.utf8),
        ])
    }

    static func storageRotate(account: String, deviceId: String, oldKid: String, newKid: String, sealedHash: Data) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-storage-rotate-v1".utf8), Data(account.utf8), Data(deviceId.utf8),
            Data(oldKid.utf8), Data(newKid.utf8), sealedHash,
        ])
    }

    static func storageAck(account: String, deviceId: String, kid: String) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-storage-ack-v1".utf8), Data(account.utf8), number(1), Data(deviceId.utf8), Data(kid.utf8),
        ])
    }

    static func storageSettlement(account: String, deviceId: String, kid: String, abandoning: Bool) throws -> Data {
        try AtemE2ECrypto.encode([
            Data((abandoning ? "atem-storage-abandon-v1" : "atem-storage-confirm-v1").utf8),
            Data(account.utf8), Data(deviceId.utf8), Data(kid.utf8),
        ])
    }
}
