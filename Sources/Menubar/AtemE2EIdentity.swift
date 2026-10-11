import CryptoKit
import Foundation
import Security
import LocalAuthentication

enum AtemIdentityError: LocalizedError {
    case keychain(OSStatus)
    case secureEnclaveUnavailable
    case invalidStoredIdentity
    case newerStoredIdentity(Int)
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
        case .newerStoredIdentity(let version): return "This identity needs a newer Astation build (format \(version)). Update Astation; its keys were retained."
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
    func openStorageKey(_ sealed: AtemHPKESealedKey, info: Data, material: AtemIdentityMaterial) throws -> Data
    func openProjectReport(_ report: AtemProjectReportWire, info: Data, material: AtemIdentityMaterial) throws -> Data
}

extension AtemIdentityCryptography {
    func openProjectReport(_ report: AtemProjectReportWire, info: Data, material: AtemIdentityMaterial) throws -> Data {
        throw AtemIdentityError.invalidState
    }
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
        _ = try encryptionKey(material)
        _ = try signingPublicKey(material)
    }

    private func encryptionKey(_ material: AtemIdentityMaterial) throws -> Curve25519.KeyAgreement.PrivateKey {
        let sealing = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: material.sealingKey)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: material.sealingPublicKey)
        let shared = try sealing.sharedSecretFromKeyAgreement(with: ephemeral)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: material.sealedEncryptionKey), using: wrappingKey(shared))
        let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        guard encryption.publicKey.rawRepresentation == material.encryptionPublicKey else {
            throw AtemIdentityError.invalidStoredIdentity
        }
        return encryption
    }

    func openStorageKey(_ sealed: AtemHPKESealedKey, info: Data, material: AtemIdentityMaterial) throws -> Data {
        _ = try AtemE2ECrypto.sealedKeyDigest(sealed)
        var recipient = try HPKE.Recipient(
            privateKey: encryptionKey(material), ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: sealed.encapsulatedKey
        )
        let key = try recipient.open(sealed.ciphertext, authenticating: Data())
        guard key.count == 32 else { throw AtemStorageKeyError.invalidStatement }
        return key
    }

    func sign(_ message: Data, material: AtemIdentityMaterial) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material.signingKey)
        return try AtemE2ECrypto.normalizedP256Signature(key.signature(for: message).rawRepresentation)
    }

    func openProjectReport(_ report: AtemProjectReportWire, info: Data, material: AtemIdentityMaterial) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: encryptionKey(material),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: report.encappedKey)
        return try recipient.open(report.ciphertext, authenticating: Data())
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
    static let storedVersion = 3

    private struct Stored: Codable {
        var version = AtemE2EIdentity.storedVersion
        let material: AtemIdentityMaterial
        var recoverySaved = false
        var epoch: UInt64 = 0
        var accounts: [String: AtemAccountState] = [:]
        var devices: [String: AtemDevicePin] = [:]
        var storageKeys: [String: AtemDeviceStorageKeys] = [:]
        var deviceVerificationEpochs: [String: UInt64] = [:]
        var migrations: [String: AtemEncryptionMigration] = [:]

        init(material: AtemIdentityMaterial) { self.material = material }

        enum CodingKeys: String, CodingKey {
            case version, material, recoverySaved, epoch, accounts, devices, storageKeys, deviceVerificationEpochs, migrations
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            // Inspect the format before decoding fields an older build cannot understand.
            if version > AtemE2EIdentity.storedVersion { throw AtemIdentityError.newerStoredIdentity(version) }
            guard version >= 1 else { throw AtemIdentityError.invalidStoredIdentity }
            material = try values.decode(AtemIdentityMaterial.self, forKey: .material)
            recoverySaved = try values.decode(Bool.self, forKey: .recoverySaved)
            epoch = try values.decode(UInt64.self, forKey: .epoch)
            accounts = try values.decode([String: AtemAccountState].self, forKey: .accounts)
            devices = try values.decode([String: AtemDevicePin].self, forKey: .devices)
            // Step-1 identities remain readable without replacing any key material.
            if version == 1 {
                storageKeys = try values.decodeIfPresent([String: AtemDeviceStorageKeys].self, forKey: .storageKeys) ?? [:]
            } else {
                storageKeys = try values.decode([String: AtemDeviceStorageKeys].self, forKey: .storageKeys)
            }
            if version < 3 {
                deviceVerificationEpochs = [:]
                migrations = [:]
            } else {
                deviceVerificationEpochs = try values.decode([String: UInt64].self, forKey: .deviceVerificationEpochs)
                migrations = try values.decode([String: AtemEncryptionMigration].self, forKey: .migrations)
            }
        }

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
            let record: Stored
            do {
                record = try JSONDecoder().decode(Stored.self, from: data)
            } catch let error as AtemIdentityError {
                throw error
            } catch {
                throw AtemIdentityError.invalidStoredIdentity
            }
            guard record.material.recoverySecret.count == 32,
                  record.accounts.values.allSatisfy({ Self.validState($0.mode, $0.kid) && $0.epoch <= record.epoch }),
                  record.devices.values.allSatisfy({ $0.devicePub.count == 32 && $0.deviceSignPub.count == 32 && $0.unlockAuthPub.count == 32 }) else {
                throw AtemIdentityError.invalidStoredIdentity
            }
            if !record.storageKeys.isEmpty {
                let signingPublicKey = try crypto.signingPublicKey(record.material)
                for (binding, keys) in record.storageKeys {
                    guard try binding == AtemDeviceStorageKeys.binding(deviceId: keys.deviceId, devicePub: keys.devicePub) else {
                        throw AtemIdentityError.invalidStoredIdentity
                    }
                    try keys.validate(signingPublicKey: signingPublicKey)
                }
            }
            guard record.deviceVerificationEpochs.values.allSatisfy({ $0 <= record.epoch }) else {
                throw AtemIdentityError.invalidStoredIdentity
            }
            if !record.migrations.isEmpty {
                let publicKey = try crypto.signingPublicKey(record.material)
                for (account, migration) in record.migrations {
                    guard let state = record.accounts[account] else { throw AtemIdentityError.invalidStoredIdentity }
                    try migration.validate(account: account, state: state, signingPublicKey: publicKey)
                }
            }
            return record
        }
        guard create else { return nil }
        let record = Stored(material: try crypto.create())
        try storage.write(JSONEncoder().encode(record), creating: true)
        return record
    }

    private func save(_ record: Stored) throws {
        var upgraded = record
        // Older builds refuse this format instead of erasing escrow or migration journals.
        upgraded.version = Self.storedVersion
        try storage.write(JSONEncoder().encode(upgraded), creating: false)
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
        guard !account.isEmpty, ["enabling", "disabling"].contains(mode),
              Self.validState(mode, kid), var record = try read() else {
            throw AtemIdentityError.invalidState
        }
        let state = AtemAccountState(mode: mode, kid: kid, epoch: try record.advance())
        let signed = try sign(AtemStatements.accountState(account: account, mode: mode, kid: kid, epoch: state.epoch), record: record)
        record.accounts[account] = state
        record.migrations[account] = AtemEncryptionMigration(state: state)
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
        let verificationEpoch = try record.advance()
        let certificate = try sign(AtemStatements.deviceVerified(
            account: account, deviceId: deviceId, reveal: reveal, transcript: transcript, epoch: verificationEpoch
        ), record: record)
        let accountState = try signState(account: account, key: key, record: &record)
        var grants: [AtemGrantWire] = []
        if let key {
            grants.append(try grant(account: account, deviceId: deviceId, publicKey: reveal.devicePub, key: key, record: &record))
        }
        record.devices[deviceId] = AtemDevicePin(
            account: account, devicePub: reveal.devicePub, deviceSignPub: reveal.deviceSignPub, unlockAuthPub: reveal.unlockAuthPub
        )
        record.deviceVerificationEpochs[deviceId] = verificationEpoch
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

    func credentialProjectPin(account: String, deviceId: String) throws -> AtemDevicePin? {
        lock.lock(); defer { lock.unlock() }
        guard let pin = try read(create: false)?.devices[deviceId], pin.account == account else { return nil }
        return pin
    }

    func openCredentialProjects(_ report: AtemProjectReportWire, account: String, deviceId: String, now: Date = Date()) throws -> AtemReportedProjects {
        lock.lock(); defer { lock.unlock() }
        guard let record = try read(create: false), let pin = record.devices[deviceId], pin.account == account else {
            throw AtemIdentityError.unverifiedDevice
        }
        let fields = try AtemCredentialProjects.checkedFields(report, account: account, deviceId: deviceId, pin: pin, now: now)
        let plain = try crypto.openProjectReport(report, info: fields.info, material: record.material)
        return AtemReportedProjects(account: account, deviceId: deviceId, pin: pin, time: fields.time,
            projects: try AtemCredentialProjects.projects(plain))
    }

    /// Authenticates and journals the message while its transport identity is still available.
    func acceptMigrationCompletion(
        _ completion: AtemSignedWire?, mode: String, kid: String,
        account: String, route: AtemVerificationRoute, key: AccountDataKey?
    ) throws -> AtemMigrationCommit? {
        lock.lock(); defer { lock.unlock() }
        guard let completion, var record = try read(create: false), record.recoverySaved,
              let pin = record.devices[route.deviceId], pin.account == account else {
            throw AtemMigrationError.invalidCompletion
        }
        try AtemStatementReader.verify(completion, publicKey: pin.deviceSignPub)
        let report = try AtemMigrationCompletion(completion)
        guard report.account == account, report.deviceId == route.deviceId,
              report.target == mode, report.kid == kid else { throw AtemMigrationError.invalidCompletion }
        let verificationEpoch = record.deviceVerificationEpochs[route.deviceId] ?? 0
        // Reusing keys in a new verification must not renew an old report's authorization.
        guard report.stateEpoch >= verificationEpoch else { throw AtemMigrationError.staleMigration }
        try report.verifyKey(key)
        try crypto.validate(record.material)
        guard let state = record.accounts[account] else { throw AtemMigrationError.staleMigration }
        var migration = record.migrations[account] ?? AtemEncryptionMigration(state: state)
        guard migration.kid == kid, migration.target == mode,
              report.stateEpoch >= migration.startEpoch, report.stateEpoch <= state.epoch else {
            throw AtemMigrationError.staleMigration
        }
        if let final = migration.finalState {
            guard state.mode == mode, state.kid == (mode == "off" ? nil : kid) else {
                throw AtemMigrationError.staleMigration
            }
            return AtemMigrationCommit(account: account, target: mode, kid: kid, signedState: final)
        }
        guard state.mode == (mode == "on" ? "enabling" : "disabling"), state.kid == kid else {
            throw AtemMigrationError.staleMigration
        }
        let accepted = AtemAcceptedMigration(completion: completion, pin: pin,
            verificationEpoch: verificationEpoch,
            signingPublicKey: try crypto.signingPublicKey(record.material), route: route)
        if migration.accepted == accepted { return nil }
        migration.accepted = accepted
        record.migrations[account] = migration
        try save(record)
        return nil
    }

    func pendingMigrationAccounts() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try read(create: false)?.migrations.filter {
            $0.value.accepted != nil && $0.value.finalState == nil
        }.map(\.key) ?? []
    }

    func currentMigrationCommit(account: String) throws -> AtemMigrationCommit? {
        lock.lock(); defer { lock.unlock() }
        guard let migration = try read(create: false)?.migrations[account], let signed = migration.finalState else { return nil }
        return AtemMigrationCommit(account: account, target: migration.target, kid: migration.kid, signedState: signed)
    }

    /// Revocation, final state and the journal serialize under the same identity lock.
    func finishAcceptedMigration(account: String, key: AccountDataKey?) throws -> AtemMigrationCommit? {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), var migration = record.migrations[account],
              migration.finalState == nil, let accepted = migration.accepted else { return nil }
        let deviceId = accepted.route.deviceId
        guard record.devices[deviceId] == accepted.pin,
              (record.deviceVerificationEpochs[deviceId] ?? 0) == accepted.verificationEpoch else {
            migration.accepted = nil
            record.migrations[account] = migration
            try save(record)
            throw AtemMigrationError.revokedDevice
        }
        guard record.recoverySaved,
              try crypto.signingPublicKey(record.material) == accepted.signingPublicKey,
              let state = record.accounts[account], state.kid == migration.kid,
              state.mode == (migration.target == "on" ? "enabling" : "disabling") else {
            throw AtemMigrationError.staleMigration
        }
        try crypto.validate(record.material)
        try AtemStatementReader.verify(accepted.completion, publicKey: accepted.pin.deviceSignPub)
        let report = try AtemMigrationCompletion(accepted.completion)
        guard report.account == account, report.deviceId == deviceId,
              report.target == migration.target, report.kid == migration.kid,
              report.stateEpoch >= migration.startEpoch, report.stateEpoch >= accepted.verificationEpoch,
              report.stateEpoch <= state.epoch else {
            throw AtemMigrationError.staleMigration
        }
        try report.verifyKey(key)
        let final = AtemAccountState(mode: migration.target, kid: migration.target == "off" ? nil : migration.kid,
            epoch: try record.advance())
        let signed = try sign(AtemStatements.accountState(account: account, mode: final.mode, kid: final.kid,
            epoch: final.epoch), record: record)
        migration.finalState = signed
        record.accounts[account] = final
        record.migrations[account] = migration
        try save(record)
        return AtemMigrationCommit(account: account, target: migration.target, kid: migration.kid, signedState: signed)
    }

    func prepareUnlock(_ wire: AtemUnlockRequestWire, account: String, deviceId: String, now: Date) throws -> AtemUnlockAuthorization {
        lock.lock(); defer { lock.unlock() }
        guard let record = try read(create: false), let pin = record.devices[deviceId], pin.account == account else {
            throw AtemStorageKeyError.unverifiedDevice
        }
        try AtemStatementReader.verify(wire.signed, publicKey: pin.unlockAuthPub)
        let request = try AtemUnlockRequest(statement: wire.request)
        guard request.account == account, request.deviceId == deviceId else { throw AtemStorageKeyError.wrongDevice }
        guard abs(TimeInterval(request.time) - now.timeIntervalSince1970) <= 300 else { throw AtemStorageKeyError.staleRequest }
        let binding = try AtemDeviceStorageKeys.binding(deviceId: deviceId, devicePub: pin.devicePub)
        guard let keys = record.storageKeys[binding], keys.account == account, keys.held(kid: request.storageKid) != nil else {
            throw AtemStorageKeyError.unavailableKey
        }
        // Reject unusable X25519 points before asking the user to approve.
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.ephemeralPublicKey)
        _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: ephemeral)
        return AtemUnlockAuthorization(
            wire: wire, request: request, pin: pin,
            signingPublicKey: try crypto.signingPublicKey(record.material), lastUnlock: keys.lastUnlock
        )
    }

    func unlockGrant(_ authorization: AtemUnlockAuthorization, now: Date) throws -> AtemUnlockGrantWire {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), let pin = record.devices[authorization.request.deviceId],
              pin.account == authorization.request.account else { throw AtemStorageKeyError.unverifiedDevice }
        guard pin == authorization.pin, try crypto.signingPublicKey(record.material) == authorization.signingPublicKey else {
            throw AtemStorageKeyError.identityChanged
        }
        let request = authorization.request
        let binding = try AtemDeviceStorageKeys.binding(deviceId: request.deviceId, devicePub: authorization.pin.devicePub)
        guard var keys = record.storageKeys[binding], keys.account == request.account,
              let held = keys.held(kid: request.storageKid) else { throw AtemStorageKeyError.unavailableKey }
        let requestHash = Data(SHA256.hash(data: authorization.wire.request))
        let sealed = try AtemE2ECrypto.sealKey(held.key, to: request.ephemeralPublicKey, info: AtemStatements.unlockInfo(
            account: request.account, deviceId: request.deviceId, kid: request.storageKid, requestHash: requestHash
        ))
        let grant = try sign(AtemStatements.unlockGrant(
            account: request.account, deviceId: request.deviceId, kid: request.storageKid,
            requestHash: requestHash, sealedHash: AtemE2ECrypto.sealedKeyDigest(sealed)
        ), record: record)
        if keys.pending?.held.kid == request.storageKid { keys.promotePending() }
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              let timestamp = UInt64(exactly: now.timeIntervalSince1970.rounded(.down)) else { throw AtemStorageKeyError.invalidStatement }
        keys.lastUnlock = timestamp
        record.storageKeys[binding] = keys
        // Promotion and last-unlock metadata must persist before a grant leaves this Mac.
        try save(record)
        return AtemUnlockGrantWire(grant: grant, encappedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext)
    }

    func rotateStorageKey(_ wire: AtemStorageRotateWire, account: String, deviceId: String) throws -> AtemSignedWire {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), let pin = record.devices[deviceId], pin.account == account else {
            throw AtemStorageKeyError.wrongDevice
        }
        try AtemStatementReader.verify(wire.rotate, publicKey: pin.deviceSignPub)
        let rotate = try AtemStorageRotate(statement: wire.rotate.statement)
        guard rotate.account == account, rotate.deviceId == deviceId else { throw AtemStorageKeyError.wrongDevice }
        guard try AtemE2ECrypto.sealedKeyDigest(wire.sealed) == rotate.sealedHash else { throw AtemStorageKeyError.invalidStatement }
        let binding = try AtemDeviceStorageKeys.binding(deviceId: deviceId, devicePub: pin.devicePub)
        var keys = record.storageKeys[binding] ?? AtemDeviceStorageKeys(account: account, deviceId: deviceId, devicePub: pin.devicePub)
        guard keys.account == account else { throw AtemStorageKeyError.wrongDevice }
        if let pending = keys.pending, pending.held.kid == rotate.newKid {
            guard pending.rotateStatement == wire.rotate.statement else { throw AtemStorageKeyError.pendingKey(pending.held.kid) }
            return pending.ack
        }
        if keys.pending?.held.kid == rotate.oldKid {
            keys.promotePending()
            record.storageKeys[binding] = keys
            // Naming the pending key confirms it even if the next rotation is refused.
            try save(record)
        }
        if let pending = keys.pending { throw AtemStorageKeyError.pendingKey(pending.held.kid) }
        guard !keys.acked.contains(rotate.newKid), keys.current?.kid != rotate.newKid else { throw AtemStorageKeyError.replayedKey }
        guard rotate.oldKid == (keys.current?.kid ?? "") else { throw AtemStorageKeyError.wrongCurrentKey }
        let key = try crypto.openStorageKey(wire.sealed, info: AtemStatements.storageKeyInfo(
            account: account, deviceId: deviceId, kid: rotate.newKid
        ), material: record.material)
        guard key.count == 32 else { throw AtemStorageKeyError.invalidStatement }
        let ack = try sign(AtemStatements.storageAck(account: account, deviceId: deviceId, kid: rotate.newKid), record: record)
        keys.pending = AtemPendingStorageKey(held: AtemHeldStorageKey(kid: rotate.newKid, key: key), rotateStatement: wire.rotate.statement, ack: ack)
        keys.acked.insert(rotate.newKid)
        record.storageKeys[binding] = keys
        try save(record)
        return ack
    }

    func settleStorageKey(_ signed: AtemSignedWire, account: String, deviceId: String, abandoning: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), let pin = record.devices[deviceId], pin.account == account else {
            throw AtemStorageKeyError.wrongDevice
        }
        try AtemStatementReader.verify(signed, publicKey: pin.deviceSignPub)
        let settlement = try AtemStorageSettlement(statement: signed.statement, abandoning: abandoning)
        guard settlement.account == account, settlement.deviceId == deviceId else { throw AtemStorageKeyError.wrongDevice }
        let binding = try AtemDeviceStorageKeys.binding(deviceId: deviceId, devicePub: pin.devicePub)
        guard var keys = record.storageKeys[binding], keys.account == account, keys.pending?.held.kid == settlement.kid else { return }
        if abandoning { keys.pending = nil } else { keys.promotePending() }
        record.storageKeys[binding] = keys
        try save(record)
    }

    func revokeDevice(_ authorization: AtemUnlockAuthorization) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read(create: false), let pin = record.devices[authorization.request.deviceId],
              pin.account == authorization.request.account else { throw AtemStorageKeyError.unverifiedDevice }
        guard pin == authorization.pin, try crypto.signingPublicKey(record.material) == authorization.signingPublicKey else {
            throw AtemStorageKeyError.identityChanged
        }
        record.devices.removeValue(forKey: authorization.request.deviceId)
        record.deviceVerificationEpochs.removeValue(forKey: authorization.request.deviceId)
        _ = try record.advance()
        try save(record)
    }

    func storageKeyStatus(account: String, deviceId: String) throws -> AtemStorageKeyStatus? {
        lock.lock(); defer { lock.unlock() }
        guard let record = try read(create: false), let pin = record.devices[deviceId], pin.account == account,
              let keys = try record.storageKeys[AtemDeviceStorageKeys.binding(deviceId: deviceId, devicePub: pin.devicePub)],
              keys.account == account else { return nil }
        return AtemStorageKeyStatus(currentKid: keys.current?.kid, pendingKid: keys.pending?.held.kid, lastUnlock: keys.lastUnlock)
    }

    private func sign(_ statement: Data, record: Stored) throws -> AtemSignedWire {
        AtemSignedWire(statement: statement, signature: try crypto.sign(statement, material: record.material))
    }

    private func signState(account: String, key: AccountDataKey?, record: inout Stored) throws -> AtemSignedWire {
        // A legacy local key alone cannot attest that the remote data was migrated.
        var state = record.accounts[account] ?? AtemAccountState(mode: key == nil ? "off" : "enabling", kid: key?.kid, epoch: 0)
        guard Self.validState(state.mode, state.kid),
              state.mode == "off" || key?.kid == state.kid else { throw AtemIdentityError.invalidState }
        state.epoch = try record.advance()
        if (state.mode == "enabling" || state.mode == "disabling"), record.migrations[account] == nil {
            record.migrations[account] = AtemEncryptionMigration(state: state)
        }
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
