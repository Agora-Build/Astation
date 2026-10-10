import CryptoKit
import Foundation
import Security
import LocalAuthentication

enum AtemIdentityError: LocalizedError {
    case keychain(OSStatus)
    case secureEnclaveUnavailable
    case invalidStoredIdentity
    case recoveryNotSaved
    case identityChanged
    case unverifiedDevice
    case invalidState
    case epochExhausted

    var errorDescription: String? {
        switch self {
        case .keychain(errSecMissingEntitlement): return "This Astation build needs provisioned signing with Keychain access to verify devices."
        case .keychain(let status): return "Astation's verification keys are unavailable (\(status)). Unlock this Mac and retry."
        case .secureEnclaveUnavailable: return "Device verification requires this Mac's Secure Enclave."
        case .invalidStoredIdentity: return "Astation's stored verification identity is unreadable. Its keys were retained."
        case .recoveryNotSaved: return "Save the Astation recovery kit before verifying a device."
        case .identityChanged: return "The verification identity changed. Start verification again."
        case .unverifiedDevice: return "Verify this device's safety code before requesting an encryption key."
        case .invalidState: return "The account's encryption state or key is unavailable."
        case .epochExhausted: return "The verification epoch counter is exhausted."
        }
    }
}

protocol AtemIdentityStorage {
    func read() throws -> Data?
    func write(_ data: Data, creating: Bool) throws
}

struct AtemIdentityKeychainStorage: AtemIdentityStorage {
    let astationId: String

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "build.agora.astation.atem-e2e-v1",
         kSecAttrAccount as String: astationId,
         kSecUseDataProtectionKeychain as String: true,
         kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AtemIdentityError.keychain(status) }
        guard let data = value as? Data else { throw AtemIdentityError.invalidStoredIdentity }
        return data
    }

    func write(_ data: Data, creating: Bool) throws {
        let status: OSStatus
        if creating {
            var item = query
            item.removeValue(forKey: kSecUseAuthenticationContext as String)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw AtemIdentityError.keychain(status) }
    }
}

struct AtemIdentityMaterial: Codable {
    let signingKey: Data
    let sealingKey: Data
    let sealingPublicKey: Data
    let sealedEncryptionKey: Data
    let encryptionPublicKey: Data
    let recoverySecret: Data
}

protocol AtemIdentityCryptography {
    func create() throws -> AtemIdentityMaterial
    func signingPublicKey(_ material: AtemIdentityMaterial) throws -> Data
    func validate(_ material: AtemIdentityMaterial) throws
    func sign(_ message: Data, material: AtemIdentityMaterial) throws -> Data
}

struct AtemSecureEnclaveCryptography: AtemIdentityCryptography {
    func create() throws -> AtemIdentityMaterial {
        guard SecureEnclave.isAvailable else { throw AtemIdentityError.secureEnclaveUnavailable }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil
        ) else { throw AtemIdentityError.invalidStoredIdentity }
        let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let sealing = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: sealing.publicKey)
        let box = try AES.GCM.seal(encryption.rawRepresentation, using: wrappingKey(shared))
        guard let combined = box.combined else { throw AtemIdentityError.invalidStoredIdentity }
        return AtemIdentityMaterial(
            signingKey: signing.dataRepresentation, sealingKey: sealing.dataRepresentation,
            sealingPublicKey: ephemeral.publicKey.x963Representation, sealedEncryptionKey: combined,
            encryptionPublicKey: encryption.publicKey.rawRepresentation,
            recoverySecret: try Self.random32()
        )
    }

    func signingPublicKey(_ material: AtemIdentityMaterial) throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material.signingKey).publicKey.x963Representation
    }

    func validate(_ material: AtemIdentityMaterial) throws {
        guard material.recoverySecret.count == 32 else { throw AtemIdentityError.invalidStoredIdentity }
        let sealing = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: material.sealingKey)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: material.sealingPublicKey)
        let shared = try sealing.sharedSecretFromKeyAgreement(with: ephemeral)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: material.sealedEncryptionKey), using: wrappingKey(shared))
        let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        guard encryption.publicKey.rawRepresentation == material.encryptionPublicKey else {
            throw AtemIdentityError.invalidStoredIdentity
        }
        _ = try signingPublicKey(material)
    }

    func sign(_ message: Data, material: AtemIdentityMaterial) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material.signingKey)
        return try AtemE2ECrypto.normalizedP256Signature(key.signature(for: message).rawRepresentation)
    }

    private func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: Data("astation-e2e-enclave-seal-v1".utf8), outputByteCount: 32
        )
    }

    static func random32() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AtemIdentityError.keychain(status) }
        return Data(bytes)
    }
}

struct AtemAccountState: Codable, Equatable {
    var mode: String
    var kid: String?
    var epoch: UInt64
}

struct AtemDevicePin: Codable, Equatable {
    let account: String
    let devicePub: Data
    let deviceSignPub: Data
    let unlockAuthPub: Data
}

final class AtemE2EIdentity {
    private struct Stored: Codable {
        var version = 1
        let material: AtemIdentityMaterial
        var recoverySaved = false
        var epoch: UInt64 = 0
        var accounts: [String: AtemAccountState] = [:]
        var devices: [String: AtemDevicePin] = [:]

        mutating func advance() throws -> UInt64 {
            guard epoch < UInt64.max else { throw AtemIdentityError.epochExhausted }
            epoch += 1
            return epoch
        }
    }

    private let storage: AtemIdentityStorage
    private let crypto: AtemIdentityCryptography
    private let lock = NSRecursiveLock()

    init(storage: AtemIdentityStorage, crypto: AtemIdentityCryptography = AtemSecureEnclaveCryptography()) {
        self.storage = storage
        self.crypto = crypto
    }

    private func read(create: Bool = true) throws -> Stored? {
        if let data = try storage.read() {
            guard let record = try? JSONDecoder().decode(Stored.self, from: data), record.version == 1,
                  record.material.recoverySecret.count == 32,
                  record.accounts.values.allSatisfy({ Self.validState($0.mode, $0.kid) && $0.epoch <= record.epoch }),
                  record.devices.values.allSatisfy({ $0.devicePub.count == 32 && $0.deviceSignPub.count == 32 && $0.unlockAuthPub.count == 32 }) else {
                throw AtemIdentityError.invalidStoredIdentity
            }
            return record
        }
        guard create else { return nil }
        let record = Stored(material: try crypto.create())
        try storage.write(JSONEncoder().encode(record), creating: true)
        return record
    }

    private func save(_ record: Stored) throws {
        try storage.write(JSONEncoder().encode(record), creating: false)
    }

    func verificationKeys(nonce: Data) throws -> AtemVerifyKeys {
        lock.lock(); defer { lock.unlock() }
        guard nonce.count == 32, let record = try read() else { throw AtemIdentityError.invalidStoredIdentity }
        try crypto.validate(record.material)
        return AtemVerifyKeys(
            signPub: try crypto.signingPublicKey(record.material), encPub: record.material.encryptionPublicKey,
            recoverySignPub: try AtemE2ECrypto.recoverySigningKey(secret: record.material.recoverySecret).publicKey.rawRepresentation,
            nonce: nonce
        )
    }

    func recoveryKit(astationId: String, relayURL: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let record = try read() else { throw AtemIdentityError.invalidStoredIdentity }
        let code = Array(AtemE2ECrypto.base32(record.material.recoverySecret))
        let recovery = stride(from: 0, to: code.count, by: 4).map {
            String(code[$0..<min($0 + 4, code.count)])
        }.joined(separator: "-")
        return RecoveryKit(astationId: astationId, relayURL: relayURL, recoveryKey: recovery).text()
    }

    func recoveryIsSaved() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try read()?.recoverySaved ?? false
    }

    func markRecoverySaved(signingPublicKey: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(), try crypto.signingPublicKey(record.material) == signingPublicKey else {
            throw AtemIdentityError.identityChanged
        }
        record.recoverySaved = true
        try save(record)
    }

    func state(account: String) throws -> AtemAccountState? {
        lock.lock(); defer { lock.unlock() }
        return try read(create: false)?.accounts[account]
    }

    @discardableResult
    func setState(account: String, mode: String, kid: String?) throws -> AtemSignedWire {
        lock.lock(); defer { lock.unlock() }
        guard !account.isEmpty, Self.validState(mode, kid), var record = try read() else {
            throw AtemIdentityError.invalidState
        }
        let state = AtemAccountState(mode: mode, kid: kid, epoch: try record.advance())
        let signed = try sign(AtemStatements.accountState(account: account, mode: mode, kid: kid, epoch: state.epoch), record: record)
        record.accounts[account] = state
        try save(record)
        return signed
    }

    func signedState(account: String, key: AccountDataKey?) throws -> AtemSignedWire {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read() else { throw AtemIdentityError.invalidStoredIdentity }
        let signed = try signState(account: account, key: key, record: &record)
        try save(record)
        return signed
    }

    func completeVerification(
        account: String, deviceId: String, reveal: AtemVerifyReveal, transcript: Data,
        expectedSigningKey: Data, key: AccountDataKey?
    ) throws -> AtemDeviceVerified {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(), record.recoverySaved else { throw AtemIdentityError.recoveryNotSaved }
        guard try crypto.signingPublicKey(record.material) == expectedSigningKey else { throw AtemIdentityError.identityChanged }
        _ = try reveal.commitment()
        guard transcript.count == 32, !account.isEmpty, !deviceId.isEmpty else { throw AtemIdentityError.invalidState }
        let certificate = try sign(AtemStatements.deviceVerified(
            account: account, deviceId: deviceId, reveal: reveal, transcript: transcript, epoch: record.advance()
        ), record: record)
        let accountState = try signState(account: account, key: key, record: &record)
        var grants: [AtemGrantWire] = []
        if let key {
            grants.append(try grant(account: account, deviceId: deviceId, publicKey: reveal.devicePub, key: key, record: &record))
        }
        record.devices[deviceId] = AtemDevicePin(
            account: account, devicePub: reveal.devicePub, deviceSignPub: reveal.deviceSignPub, unlockAuthPub: reveal.unlockAuthPub
        )
        // Pins, account state and epochs commit together, only after every signature succeeds.
        try save(record)
        return AtemDeviceVerified(deviceVerified: certificate, accountState: accountState, grants: grants)
    }

    func keyGrant(account: String, deviceId: String, publicKey: Data, key: AccountDataKey) throws -> AtemGrantWire {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), let pin = record.devices[deviceId],
              pin.account == account, pin.devicePub == publicKey else { throw AtemIdentityError.unverifiedDevice }
        guard let state = record.accounts[account], state.mode != "off", state.kid == key.kid else {
            throw AtemIdentityError.invalidState
        }
        let result = try grant(account: account, deviceId: deviceId, publicKey: publicKey, key: key, record: &record)
        try save(record)
        return result
    }

    func isVerified(account: String, deviceId: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try read(create: false)?.devices[deviceId]?.account == account
    }

    private func sign(_ statement: Data, record: Stored) throws -> AtemSignedWire {
        AtemSignedWire(statement: statement, signature: try crypto.sign(statement, material: record.material))
    }

    private func signState(account: String, key: AccountDataKey?, record: inout Stored) throws -> AtemSignedWire {
        var state = record.accounts[account] ?? AtemAccountState(mode: key == nil ? "off" : "on", kid: key?.kid, epoch: 0)
        guard Self.validState(state.mode, state.kid),
              state.mode == "off" || key?.kid == state.kid else { throw AtemIdentityError.invalidState }
        state.epoch = try record.advance()
        let result = try sign(AtemStatements.accountState(account: account, mode: state.mode, kid: state.kid, epoch: state.epoch), record: record)
        record.accounts[account] = state
        return result
    }

    private func grant(account: String, deviceId: String, publicKey: Data, key: AccountDataKey, record: inout Stored) throws -> AtemGrantWire {
        guard Self.validState("on", key.kid) else { throw AtemIdentityError.invalidState }
        let sealed = try AtemE2ECrypto.sealKey(key.key, to: publicKey, info: AtemStatements.grantInfo(
            account: account, deviceId: deviceId, devicePub: publicKey, kid: key.kid
        ))
        let signed = try sign(AtemStatements.grant(
            account: account, deviceId: deviceId, devicePub: publicKey, kid: key.kid, sealedHash: AtemE2ECrypto.sealedKeyDigest(sealed)
        ), record: record)
        _ = try record.advance()
        return AtemGrantWire(signed: signed, encappedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext)
    }

    private static func validState(_ mode: String, _ kid: String?) -> Bool {
        guard ["off", "enabling", "on", "disabling"].contains(mode) else { return false }
        if let kid {
            guard kid.utf8.count == 8, kid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        }
        return mode == "off" || kid != nil
    }
}
