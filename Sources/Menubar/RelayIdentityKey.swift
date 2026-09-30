import CryptoKit
import Foundation
import Security

// MARK: - Relay identity key

enum RelayIdentityKeyError: Error, Equatable {
    /// The Keychain returned an error other than "not found". The stored key is
    /// left untouched so a transient failure never replaces a registered key.
    case keychain(OSStatus)
    /// A Secure Enclave key blob is stored but the Secure Enclave is unavailable.
    case secureEnclaveUnavailable
    /// A key item exists but cannot be decoded. It is never replaced automatically:
    /// the relay has this Astation's key registered (TOFU), so a new key would be
    /// locked out until an admin reset.
    case undecodableStoredKey
    /// `SecAccessControlCreateWithFlags` returned nil for the Secure Enclave key.
    case accessControlUnavailable
}

/// Result of reading the persisted key material.
enum RelayIdentityKeyReadResult {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

/// Persistence for the relay identity key material.
/// Production uses the Keychain; tests inject an in-memory store.
protocol RelayIdentityKeyStorage {
    func read() -> RelayIdentityKeyReadResult
    func write(_ data: Data) -> OSStatus
}

/// Keychain generic-password storage:
/// service `build.agora.astation.relay-identity`, account `astation-relay-key-v1`.
struct KeychainRelayIdentityKeyStorage: RelayIdentityKeyStorage {
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RelayIdentityKey.keychainService,
            kSecAttrAccount as String: RelayIdentityKey.keychainAccount
        ]
    }

    func read() -> RelayIdentityKeyReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess, let data = item as? Data else {
            return .failed(status)
        }
        return .found(data)
    }

    func write(_ data: Data) -> OSStatus {
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// The P-256 key Astation uses to prove its identity (room code) to the relay.
/// Prefers a Secure Enclave key; falls back to a software key.
final class RelayIdentityKey {
    static let keychainService = "build.agora.astation.relay-identity"
    static let keychainAccount = "astation-relay-key-v1"
    static let signingDomain = "station-relay-auth-v1"
    /// Length of `P256.Signing.PrivateKey.rawRepresentation`.
    static let softwareKeyLength = 32

    private enum Backing {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let backing: Backing

    init(softwareKey: P256.Signing.PrivateKey) {
        backing = .software(softwareKey)
    }

    init(secureEnclaveKey: SecureEnclave.P256.Signing.PrivateKey) {
        backing = .secureEnclave(secureEnclaveKey)
    }

    var isHardwareBacked: Bool {
        if case .secureEnclave = backing { return true }
        return false
    }

    var publicKey: P256.Signing.PublicKey {
        switch backing {
        case .secureEnclave(let key): return key.publicKey
        case .software(let key): return key.publicKey
        }
    }

    /// X9.63 uncompressed public key (65 bytes, `04 || X || Y`) as lowercase hex.
    var publicKeyHex: String {
        Self.hex(publicKey.x963Representation)
    }

    /// DER-encoded ECDSA (SHA-256) signature, lowercase hex, over `signingMessage`.
    func sign(challenge: String, astationId: String) throws -> String {
        let message = Data(Self.signingMessage(challenge: challenge, astationId: astationId).utf8)
        let signature: P256.Signing.ECDSASignature
        switch backing {
        case .secureEnclave(let key): signature = try key.signature(for: message)
        case .software(let key): signature = try key.signature(for: message)
        }
        return Self.hex(signature.derRepresentation)
    }

    /// The exact UTF-8 string the relay verifies: `station-relay-auth-v1\n<challenge>\n<astationId>`.
    static func signingMessage(challenge: String, astationId: String) -> String {
        "\(signingDomain)\n\(challenge)\n\(astationId)"
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Load or create

    /// Load the persisted key, or create and persist a new one.
    /// A new key is generated ONLY when no item exists. A Keychain read error or an
    /// undecodable stored item is thrown and the item is left untouched, so a key
    /// the relay has registered is never silently replaced.
    static func loadOrCreate(
        storage: RelayIdentityKeyStorage = KeychainRelayIdentityKeyStorage(),
        preferSecureEnclave: Bool = SecureEnclave.isAvailable
    ) throws -> RelayIdentityKey {
        switch storage.read() {
        case .found(let data):
            return try decode(data)
        case .notFound:
            break
        case .failed(let status):
            throw RelayIdentityKeyError.keychain(status)
        }

        let (key, material) = generate(preferSecureEnclave: preferSecureEnclave)
        let status = storage.write(material)
        guard status == errSecSuccess else {
            throw RelayIdentityKeyError.keychain(status)
        }
        Log.info("[RelayIdentity] Created relay identity key (secureEnclave=\(key.isHardwareBacked))")
        return key
    }

    /// Decode a stored item. Never returns a fresh key: any failure throws so the
    /// caller leaves the stored item in place.
    private static func decode(_ data: Data) throws -> RelayIdentityKey {
        if data.count == softwareKeyLength {
            do {
                let key = try P256.Signing.PrivateKey(rawRepresentation: data)
                return RelayIdentityKey(softwareKey: key)
            } catch {
                Log.error("[RelayIdentity] Stored software relay key is undecodable (left in place): \(error)")
                throw RelayIdentityKeyError.undecodableStoredKey
            }
        }
        guard SecureEnclave.isAvailable else {
            Log.error("[RelayIdentity] Stored Secure Enclave relay key but the Secure Enclave is unavailable")
            throw RelayIdentityKeyError.secureEnclaveUnavailable
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            return RelayIdentityKey(secureEnclaveKey: key)
        } catch {
            Log.error("[RelayIdentity] Stored Secure Enclave relay key is undecodable (left in place): \(error)")
            throw RelayIdentityKeyError.undecodableStoredKey
        }
    }

    /// Secure Enclave key usable after first unlock, so signing works while the
    /// screen is locked (overnight reconnects).
    private static func makeSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        ) else {
            throw RelayIdentityKeyError.accessControlUnavailable
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
    }

    private static func generate(preferSecureEnclave: Bool) -> (RelayIdentityKey, Data) {
        if preferSecureEnclave {
            do {
                let key = try makeSecureEnclaveKey()
                return (RelayIdentityKey(secureEnclaveKey: key), key.dataRepresentation)
            } catch {
                Log.warn("[RelayIdentity] Secure Enclave key creation failed, using software key: \(error)")
            }
        }
        let key = P256.Signing.PrivateKey()
        return (RelayIdentityKey(softwareKey: key), key.rawRepresentation)
    }
}

// MARK: - Relay identity protocol (relay-auth-1)

/// Control frames the relay sends raw on the `role=astation` socket
/// (never wrapped in an `atem_id`/`connection_id` envelope).
enum RelayControlFrame: Equatable {
    case authChallenge(challenge: String)
    case authResult(status: String, message: String?)
    case ack(forType: String, ok: Bool, message: String?)
}

enum RelayIdentityProtocol {
    static let protocolVersion = "relay-auth-1"
    static let statusRegistered = "registered"
    static let statusVerified = "verified"
    static let statusRejected = "rejected"
    static let rejectedMenuMessage = "Relay rejected this Astation's key"
    static let keyUnavailableMenuMessage = "Relay identity key unreadable — relay works, vault/memory unavailable"

    /// Parse a raw identity-socket frame as a relay control frame.
    /// Returns nil for Atem envelopes and anything unrecognised, so existing
    /// Atem traffic handling is unchanged.
    static func parseControlFrame(_ text: String) -> RelayControlFrame? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["atem_id"] == nil,
              object["connection_id"] == nil,
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "relayAuthChallenge":
            guard object["protocol"] as? String == protocolVersion,
                  let challenge = object["challenge"] as? String,
                  isValidChallenge(challenge) else {
                return nil
            }
            return .authChallenge(challenge: challenge)
        case "relayAuthResult":
            guard let status = object["status"] as? String else { return nil }
            return .authResult(status: status, message: object["message"] as? String)
        case "relayAck":
            guard let forType = object["for"] as? String,
                  let ok = object["ok"] as? Bool else {
                return nil
            }
            return .ack(forType: forType, ok: ok, message: object["message"] as? String)
        default:
            return nil
        }
    }

    /// Challenge is exactly 64 lowercase hex characters.
    static func isValidChallenge(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    static func authMessage(astationId: String, publicKeyHex: String, signatureHex: String) -> String? {
        encode([
            "type": "relayAuth",
            "astation_id": astationId,
            "public_key": publicKeyHex,
            "signature": signatureHex
        ])
    }

    /// Full resync; session IDs are de-duplicated and sorted for a stable payload.
    static func sessionsMessage(sessionIds: [String]) -> String? {
        encode([
            "type": "relaySessions",
            "sessions": Array(Set(sessionIds)).sorted()
        ])
    }

    static func bindMessage(sessionId: String) -> String? {
        encode(["type": "relayBind", "session_id": sessionId])
    }

    static func unbindMessage(sessionId: String) -> String? {
        encode(["type": "relayUnbind", "session_id": sessionId])
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
