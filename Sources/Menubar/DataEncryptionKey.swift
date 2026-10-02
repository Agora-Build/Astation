import CryptoKit
import Foundation
import Security

struct AccountDataKey: Equatable {
    let kid: String
    let key: Data
}

struct WrappedAccountKey: Equatable {
    let kid: String
    let wrappedKey: String
}

enum DataEncryptionKeyError: LocalizedError {
    case keychain(OSStatus)
    case invalidKey
    case invalidRecoveryKey
    case invalidDevicePublicKey

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The encryption key could not be read from Keychain (\(status))."
        case .invalidKey: return "The stored encryption key is unreadable."
        case .invalidRecoveryKey: return "The encryption recovery key is invalid or damaged."
        case .invalidDevicePublicKey: return "The Atem encryption public key is invalid."
        }
    }
}

/// Owns the account data key. Astation wraps it to Atem device keys but never
/// receives or decrypts stored memory, skill, or vault content.
final class DataEncryptionKeyManager {
    static let shared = DataEncryptionKeyManager()
    static let service = "build.agora.astation.data-encryption"
    private static let recoveryPrefix = "AEK1-"
    private static let wrapDomain = "astation-data-key-wrap-v1"

    private struct Stored: Codable {
        let version: Int
        let kid: String
        let key: String
        let previous: [StoredKey]?
    }

    private struct StoredKey: Codable {
        let kid: String
        let key: String
    }

    func load(dataAccount: String, kid requestedKid: String? = nil) throws -> AccountDataKey? {
        guard let stored = try readStored(dataAccount: dataAccount) else { return nil }
        return try value(from: stored, kid: requestedKid)
    }

    /// Account grouping can change the server-side data-account id while the
    /// same key remains authoritative. Re-home that key before granting it to
    /// Atems connected through the newly grouped account.
    func makeAvailable(
        dataAccount: String,
        kid: String,
        preferredDataAccount: String? = nil
    ) throws {
        if try load(dataAccount: dataAccount, kid: kid) != nil { return }
        if let preferredDataAccount,
           let value = try load(dataAccount: preferredDataAccount, kid: kid) {
            try store(value, dataAccount: dataAccount)
            return
        }
        if let value = try loadAny(kid: kid) {
            try store(value, dataAccount: dataAccount)
            return
        }
        throw DataEncryptionKeyError.invalidKey
    }

    private func value(from stored: Stored, kid requestedKid: String?) throws -> AccountDataKey? {
        let candidates = [StoredKey(kid: stored.kid, key: stored.key)] + (stored.previous ?? [])
        guard let candidate = requestedKid.flatMap({ kid in
            candidates.first(where: { $0.kid == kid })
        }) ?? (requestedKid == nil ? candidates.first : nil),
              Self.validKid(candidate.kid),
              let key = Data(base64Encoded: candidate.key), key.count == 32 else {
            throw DataEncryptionKeyError.invalidKey
        }
        return AccountDataKey(kid: candidate.kid, key: key)
    }

    private func loadAny(kid: String) throws -> AccountDataKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DataEncryptionKeyError.keychain(status) }
        let values: [Data]
        if let all = item as? [Data] {
            values = all
        } else if let one = item as? Data {
            values = [one]
        } else {
            throw DataEncryptionKeyError.invalidKey
        }
        for data in values {
            guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.version == 1 || stored.version == 2 else { continue }
            if let value = try value(from: stored, kid: kid) { return value }
        }
        return nil
    }

    private func readStored(dataAccount: String) throws -> Stored? {
        var query = baseQuery(dataAccount: dataAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DataEncryptionKeyError.keychain(status)
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1 || stored.version == 2 else {
            throw DataEncryptionKeyError.invalidKey
        }
        return stored
    }

    func generate(dataAccount: String) throws -> AccountDataKey {
        let value = try generate()
        try store(value, dataAccount: dataAccount)
        return value
    }

    func generate() throws -> AccountDataKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DataEncryptionKeyError.invalidKey
        }
        let key = Data(bytes)
        let kid = SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
        return AccountDataKey(kid: kid, key: key)
    }

    func install(_ value: AccountDataKey, dataAccount: String) throws {
        try store(value, dataAccount: dataAccount)
    }

    func retainOnly(kid: String, dataAccount: String) throws {
        guard let value = try load(dataAccount: dataAccount, kid: kid) else {
            throw DataEncryptionKeyError.invalidKey
        }
        try write(value, previous: [], dataAccount: dataAccount)
    }

    func restore(_ recoveryKey: String, dataAccount: String) throws -> AccountDataKey {
        let value = try Self.decodeRecoveryKey(recoveryKey)
        try store(value, dataAccount: dataAccount)
        return value
    }

    func delete(dataAccount: String) throws {
        let status = SecItemDelete(baseQuery(dataAccount: dataAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DataEncryptionKeyError.keychain(status)
        }
    }

    func recoveryKey(for value: AccountDataKey) throws -> String {
        guard value.key.count == 32, let kid = Self.hexData(value.kid), kid.count == 4 else {
            throw DataEncryptionKeyError.invalidKey
        }
        var payload = Data([1])
        payload.append(kid)
        payload.append(value.key)
        payload.append(contentsOf: SHA256.hash(data: payload).prefix(4))
        let encoded = Self.base32Encode(payload)
        return Self.recoveryPrefix + stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(4, encoded.count - offset))
            return String(encoded[start..<end])
        }.joined(separator: "-")
    }

    static func decodeRecoveryKey(_ text: String) throws -> AccountDataKey {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard compact.hasPrefix(recoveryPrefix) else {
            throw DataEncryptionKeyError.invalidRecoveryKey
        }
        let encoded = compact.dropFirst(recoveryPrefix.count).filter { $0 != "-" && !$0.isWhitespace }
        guard let payload = base32Decode(String(encoded)), payload.count == 41, payload[0] == 1 else {
            throw DataEncryptionKeyError.invalidRecoveryKey
        }
        let body = payload.prefix(37)
        guard Data(SHA256.hash(data: body).prefix(4)) == payload.suffix(4) else {
            throw DataEncryptionKeyError.invalidRecoveryKey
        }
        let kid = payload[1..<5].map { String(format: "%02x", $0) }.joined()
        let key = Data(payload[5..<37])
        let expectedKid = SHA256.hash(data: key).prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        guard kid == expectedKid else { throw DataEncryptionKeyError.invalidRecoveryKey }
        return AccountDataKey(kid: kid, key: key)
    }

    func wrap(_ value: AccountDataKey, to publicKeyBase64: String, dataAccount: String) throws -> WrappedAccountKey {
        guard let publicData = Data(base64Encoded: publicKeyBase64), publicData.count == 32,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicData) else {
            throw DataEncryptionKeyError.invalidDevicePublicKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let aad = Data("\(Self.wrapDomain)\n\(dataAccount)\n\(value.kid)".utf8)
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: aad,
            outputByteCount: 32
        )
        let sealed = try ChaChaPoly.seal(value.key, using: wrappingKey, authenticating: aad)
        let combined = sealed.combined
        var wrapped = ephemeral.publicKey.rawRepresentation
        wrapped.append(combined)
        return WrappedAccountKey(kid: value.kid, wrappedKey: wrapped.base64EncodedString())
    }

    static func fingerprint(publicKeyBase64: String) -> String? {
        guard let key = Data(base64Encoded: publicKeyBase64), key.count == 32 else { return nil }
        let hex = SHA256.hash(data: key).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }

    private func store(_ value: AccountDataKey, dataAccount: String) throws {
        guard value.key.count == 32, Self.validKid(value.kid) else {
            throw DataEncryptionKeyError.invalidKey
        }
        var previous = try readStored(dataAccount: dataAccount).map { stored in
            [StoredKey(kid: stored.kid, key: stored.key)] + (stored.previous ?? [])
        } ?? []
        previous.removeAll { $0.kid == value.kid }
        try write(value, previous: previous, dataAccount: dataAccount)
    }

    private func write(
        _ value: AccountDataKey,
        previous: [StoredKey],
        dataAccount: String
    ) throws {
        let data = try JSONEncoder().encode(Stored(
            version: 2,
            kid: value.kid,
            key: value.key.base64EncodedString(),
            previous: previous.isEmpty ? nil : previous
        ))
        let query = baseQuery(dataAccount: dataAccount)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DataEncryptionKeyError.keychain(update) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw DataEncryptionKeyError.keychain(status) }
    }

    private func baseQuery(dataAccount: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: dataAccount
        ]
    }

    private static func validKid(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        return result
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Encode(_ data: Data) -> String {
        var buffer = 0
        var bits = 0
        var output = ""
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(base32Alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    private static func base32Decode(_ text: String) -> Data? {
        var buffer = 0
        var bits = 0
        var output = Data()
        for character in text {
            guard let value = base32Alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 && buffer != 0 { return nil }
        return output
    }
}
