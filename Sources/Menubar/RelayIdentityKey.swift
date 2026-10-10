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
    case unexpected(domain: String, code: Int)
    case repairNotNeeded
    case repairStateUnavailable
}

extension RelayIdentityKeyError: LocalizedError {
    static func capture(_ error: Error) -> RelayIdentityKeyError {
        if let error = error as? RelayIdentityKeyError { return error }
        if let error = error as? CryptoKitError,
           case .underlyingCoreCryptoError(let status) = error {
            return .keychain(status)
        }
        let error = error as NSError
        if error.domain == NSOSStatusErrorDomain {
            return .keychain(OSStatus(error.code))
        }
        return .unexpected(domain: error.domain, code: error.code)
    }

    var retriesAutomatically: Bool {
        guard case .keychain(let status) = self else { return false }
        return status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }

    var allowsRepair: Bool {
        self == .undecodableStoredKey || self == .secureEnclaveUnavailable
    }

    var menuDescription: String {
        switch self {
        case .undecodableStoredKey: return "Stored relay device key needs repair"
        case .secureEnclaveUnavailable: return "Secure Enclave device key is unavailable"
        case .keychain(errSecInteractionNotAllowed), .keychain(errSecNotAvailable):
            return "Relay device key access is restricted; retry in Security settings"
        case .keychain(errSecAuthFailed), .keychain(errSecUserCanceled):
            return "Relay device key access was denied; retry in Security settings"
        default: return "Relay device key needs attention in Security settings"
        }
    }

    var errorDescription: String? {
        switch self {
        case .keychain(errSecInteractionNotAllowed):
            return "Device key access is restricted. Retrying automatically; use Retry Key Access in Settings > Security to allow a Keychain prompt. Relay access is unavailable."
        case .keychain(errSecNotAvailable):
            return "Keychain is temporarily unavailable. Retrying automatically. Relay access is unavailable."
        case .keychain(errSecAuthFailed), .keychain(errSecUserCanceled):
            return "Device key access was denied or cancelled. Use Retry Key Access in Settings > Security. Relay access is unavailable."
        case .keychain(let status):
            return "Device key access failed (Keychain error \(status)). Use Retry Key Access in Settings > Security. Relay access is unavailable."
        case .undecodableStoredKey:
            return "The stored device key cannot be decoded. Repair it in Settings > Security. Relay access is unavailable."
        case .secureEnclaveUnavailable:
            return "This Mac cannot use the stored Secure Enclave key. Repair it in Settings > Security. Relay access is unavailable."
        case .accessControlUnavailable:
            return "Device key access control is unavailable. Retry key access in Settings > Security."
        case .unexpected(let domain, let code):
            return "Device key access failed (\(domain), \(code)). Retry key access in Settings > Security. Relay access is unavailable."
        case .repairNotNeeded:
            return "The device key changed or is readable again. It was not replaced. Retry key access in Settings > Security."
        case .repairStateUnavailable:
            return "The recovery pause could not be saved. The device key was not changed. Check this Mac's available storage and try again."
        }
    }
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
    func replace(_ data: Data) -> OSStatus
}

/// Keychain generic-password storage:
/// service `build.agora.astation.relay-identity`, account `astation-relay-key-v1`.
struct KeychainRelayIdentityKeyStorage: RelayIdentityKeyStorage {
    var allowAuthenticationUI = false
    var service = RelayIdentityKey.keychainService
    var account = RelayIdentityKey.keychainAccount

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read() -> RelayIdentityKeyReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = allowAuthenticationUI
            ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess else {
            return .failed(status)
        }
        guard let data = item as? Data else { return .failed(errSecDecode) }
        return .found(data)
    }

    func write(_ data: Data) -> OSStatus {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func replace(_ data: Data) -> OSStatus {
        // An explicit repair updates atomically; a failed update keeps the old item.
        SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
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
        if status == errSecDuplicateItem {
            // Another instance created a key after our read. Keep its registered key.
            switch storage.read() {
            case .found(let stored): return try decode(stored)
            case .failed(let status): throw RelayIdentityKeyError.keychain(status)
            case .notFound: throw RelayIdentityKeyError.keychain(errSecItemNotFound)
            }
        }
        guard status == errSecSuccess else {
            throw RelayIdentityKeyError.keychain(status)
        }
        Log.info("[RelayIdentity] Created relay identity key (secureEnclave=\(key.isHardwareBacked))")
        return key
    }

    /// Called only after device-owner authentication and explicit repair confirmation.
    static func repair(
        storage: RelayIdentityKeyStorage = KeychainRelayIdentityKeyStorage(allowAuthenticationUI: true),
        preferSecureEnclave: Bool = SecureEnclave.isAvailable
    ) throws -> RelayIdentityKey {
        switch storage.read() {
        case .found(let data):
            do {
                _ = try decode(data)
                throw RelayIdentityKeyError.repairNotNeeded
            } catch {
                let failure = RelayIdentityKeyError.capture(error)
                guard failure.allowsRepair else { throw failure }
            }
        case .notFound:
            throw RelayIdentityKeyError.repairNotNeeded
        case .failed(let status):
            throw RelayIdentityKeyError.keychain(status)
        }
        let (key, material) = generate(preferSecureEnclave: preferSecureEnclave)
        let status = storage.replace(material)
        guard status == errSecSuccess else { throw RelayIdentityKeyError.keychain(status) }
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
            let failure = RelayIdentityKeyError.capture(error)
            if case .keychain(let status) = failure,
               [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecUserCanceled].contains(status) {
                throw failure
            }
            Log.error("[RelayIdentity] Stored Secure Enclave relay key is undecodable (left in place)")
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
    case accountState(devices: [RelayAccountDevice], requests: [RelayMergeRequest])
    case mergeApproval(RelayMergeApproval)
    case accountChanged(reason: String, requestId: String?)
    case encryptionState(RelayEncryptionState)
    case encryptionChanged(mode: String, kid: String?)
}

struct RelayEncryptionState: Codable, Equatable {
    let dataAccount: String
    let mode: String
    let kid: String?
    let enabledAt: Int64?
    let updatedAt: Int64
    let plaintextFields: Int64
    let ciphertextFields: Int64
    let obsoleteFields: Int64

    func withEncryptionState(_ local: AtemAccountState) -> RelayEncryptionState {
        RelayEncryptionState(
            dataAccount: dataAccount, mode: local.mode, kid: local.kid,
            enabledAt: enabledAt, updatedAt: updatedAt, plaintextFields: plaintextFields,
            ciphertextFields: ciphertextFields, obsoleteFields: obsoleteFields
        )
    }

    enum CodingKeys: String, CodingKey {
        case dataAccount = "data_account"
        case mode, kid
        case enabledAt = "enabled_at"
        case updatedAt = "updated_at"
        case plaintextFields = "plaintext_fields"
        case ciphertextFields = "ciphertext_fields"
        case obsoleteFields = "obsolete_fields"
    }
}

struct RelayAccountDevice: Codable, Equatable {
    let astationId: String
    let label: String
    let dataAccount: String
    let registeredAt: Int64
    let lastSeenAt: Int64
    let online: Bool

    enum CodingKeys: String, CodingKey {
        case astationId = "astation_id"
        case label
        case dataAccount = "data_account"
        case registeredAt = "registered_at"
        case lastSeenAt = "last_seen_at"
        case online
    }
}

struct RelayMergeRequest: Codable, Equatable {
    let requestId: String
    let requesterAstationId: String
    let targetAstationId: String
    let mode: String
    let createdAt: Int64
    let readyAt: Int64?
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case requesterAstationId = "requester_astation_id"
        case targetAstationId = "target_astation_id"
        case mode
        case createdAt = "created_at"
        case readyAt = "ready_at"
        case expiresAt = "expires_at"
    }
}

struct RelayMergeApproval: Codable, Equatable {
    let requestId: String
    let requesterAstationId: String
    let requesterLabel: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case requesterAstationId = "requester_astation_id"
        case requesterLabel = "requester_label"
        case expiresAt = "expires_at"
    }
}

enum RelayIdentityProtocol {
    static let protocolVersion = "relay-auth-1"
    static let statusRegistered = "registered"
    static let statusVerified = "verified"
    static let statusRejected = "rejected"
    static let rejectedMenuMessage = "The relay rejected this Mac's device key. Relay access is unavailable; see Settings > Security."

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
        case "relayAccountState":
            guard let devices = decode([RelayAccountDevice].self, from: object["devices"]),
                  let requests = decode([RelayMergeRequest].self, from: object["requests"]) else {
                return nil
            }
            return .accountState(devices: devices, requests: requests)
        case "relayMergeApproval":
            guard let approval = decode(RelayMergeApproval.self, from: object) else { return nil }
            return .mergeApproval(approval)
        case "relayAccountChanged":
            guard let reason = object["reason"] as? String else { return nil }
            return .accountChanged(reason: reason, requestId: object["request_id"] as? String)
        case "relayEncryptionState":
            guard let state = decode(RelayEncryptionState.self, from: object) else { return nil }
            return .encryptionState(state)
        case "relayEncryptionChanged":
            guard let mode = object["mode"] as? String else { return nil }
            return .encryptionChanged(mode: mode, kid: object["kid"] as? String)
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

    static func registerAccountMessage(accessToken: String, label: String) -> String? {
        encode([
            "type": "relayRegisterAccount",
            "sso_access_token": accessToken,
            "label": label
        ])
    }

    static func accountListMessage() -> String? {
        encode(["type": "relayAccountList"])
    }

    static func mergeRequestMessage(targetAstationId: String, freshAccessToken: String?) -> String? {
        var object = [
            "type": "relayMergeRequest",
            "target_astation_id": targetAstationId
        ]
        if let freshAccessToken {
            object["fresh_sso_access_token"] = freshAccessToken
        }
        return encode(object)
    }

    static func mergeApprovalMessage(requestId: String) -> String? {
        encode(["type": "relayMergeApprove", "request_id": requestId])
    }

    static func mergeCancelMessage(requestId: String) -> String? {
        encode(["type": "relayMergeCancel", "request_id": requestId])
    }

    static func leaveGroupMessage() -> String? {
        encode(["type": "relayLeaveGroup"])
    }

    static func removeAstationMessage(astationId: String) -> String? {
        encode(["type": "relayRemoveAstation", "target_astation_id": astationId])
    }

    static func encryptionStateMessage() -> String? {
        encode(["type": "relayEncryptionGet"])
    }

    static func encryptionSetMessage(mode: String, kid: String?) -> String? {
        var object = ["type": "relayEncryptionSet", "mode": mode]
        if let kid { object["kid"] = kid }
        return encode(object)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any?) -> T? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
