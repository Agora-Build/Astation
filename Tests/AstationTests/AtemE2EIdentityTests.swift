import CryptoKit
import Security
import XCTest
@testable import Menubar

final class TestAtemStorage: AtemIdentityStorage {
    var data: Data?
    var failRead = false
    var failWrite = false
    var writes = 0

    func read() throws -> Data? {
        if failRead { throw AtemIdentityError.keychain(errSecInteractionNotAllowed) }
        return data
    }

    func write(_ data: Data, creating: Bool) throws {
        if failWrite { throw AtemIdentityError.keychain(errSecNotAvailable) }
        if creating && self.data != nil { throw AtemIdentityError.keychain(errSecDuplicateItem) }
        if !creating && self.data == nil { throw AtemIdentityError.keychain(errSecItemNotFound) }
        self.data = data
        writes += 1
    }
}

final class TestAtemCryptography: AtemIdentityCryptography {
    let signing = P256.Signing.PrivateKey()
    let encryption = Curve25519.KeyAgreement.PrivateKey()
    var failSign = false
    var creates = 0

    func create() throws -> AtemIdentityMaterial {
        creates += 1
        return AtemIdentityMaterial(
            signingKey: signing.rawRepresentation, sealingKey: Data([1]), sealingPublicKey: Data([2]),
            sealedEncryptionKey: Data([3]), encryptionPublicKey: encryption.publicKey.rawRepresentation,
            recoverySecret: Data(repeating: 0x12, count: 32)
        )
    }

    func signingPublicKey(_ material: AtemIdentityMaterial) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: material.signingKey).publicKey.x963Representation
    }

    func validate(_ material: AtemIdentityMaterial) throws {
        _ = try signingPublicKey(material)
        guard material.encryptionPublicKey.count == 32 else { throw AtemIdentityError.invalidStoredIdentity }
    }

    func sign(_ message: Data, material: AtemIdentityMaterial) throws -> Data {
        if failSign { throw AtemIdentityError.keychain(errSecAuthFailed) }
        return try AtemE2ECrypto.normalizedP256Signature(P256.Signing.PrivateKey(rawRepresentation: material.signingKey).signature(for: message).rawRepresentation)
    }
}

func atemStatementFields(_ signed: AtemSignedWire) -> [Data] {
    var bytes = Array(signed.statement)
    var fields: [Data] = []
    while bytes.count >= 4 {
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        bytes.removeFirst(4)
        guard length <= bytes.count else { return [] }
        fields.append(Data(bytes.prefix(length)))
        bytes.removeFirst(length)
    }
    return bytes.isEmpty ? fields : []
}

final class AtemE2EIdentityTests: XCTestCase {
    private func rethrowStorageError(_ error: Error) throws -> Never {
        if let identityError = error as? AtemIdentityError,
           case .keychain(errSecMissingEntitlement) = identityError,
           ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] != "1" {
            throw XCTSkip("Requires a provisioned host: bash scripts/verify-local-signing.sh PERSONAL_TEAM_ID")
        }
        throw error
    }

    private let account = "acct-1"
    private let deviceId = "dev-1"
    private let device = Curve25519.KeyAgreement.PrivateKey()
    private let key = AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))
    private var reveal: AtemVerifyReveal {
        AtemVerifyReveal(
            devicePub: device.publicKey.rawRepresentation,
            deviceSignPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            unlockAuthPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            nonce: Data(repeating: 4, count: 32)
        )
    }

    private func identity(_ storage: TestAtemStorage, _ crypto: TestAtemCryptography) -> AtemE2EIdentity {
        AtemE2EIdentity(storage: storage, crypto: crypto)
    }

    private func prepare(_ identity: AtemE2EIdentity) throws -> AtemVerifyKeys {
        let keys = try identity.verificationKeys(nonce: Data(repeating: 8, count: 32))
        try identity.markRecoverySaved(signingPublicKey: keys.signPub)
        return keys
    }

    func testIdentityReloadKeepsKeysRecoveryAndPins() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let first = identity(storage, crypto)
        let keys = try prepare(first)
        let ceremony = reveal
        let response = try first.completeVerification(
            account: account, deviceId: deviceId, reveal: ceremony,
            transcript: Data(repeating: 9, count: 32), expectedSigningKey: keys.signPub, key: key
        )
        let second = identity(storage, crypto)
        XCTAssertEqual(try second.verificationKeys(nonce: keys.nonce), keys)
        XCTAssertTrue(try second.recoveryIsSaved())
        XCTAssertTrue(try second.isVerified(account: account, deviceId: deviceId))
        XCTAssertEqual(crypto.creates, 1)
        for signed in [response.deviceVerified, response.accountState, response.grants[0].signed] {
            XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(signed.signature, message: signed.statement, publicKey: keys.signPub))
        }
        XCTAssertEqual(atemStatementFields(response.deviceVerified)[7], Data(repeating: 9, count: 32))
        let certificateEpoch = atemStatementFields(response.deviceVerified)[8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let stateEpoch = atemStatementFields(response.accountState)[5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        XCTAssertEqual(stateEpoch, certificateEpoch + 1)
        let next = try second.signedState(account: account, key: key)
        XCTAssertGreaterThan(atemStatementFields(next)[5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }, stateEpoch)
    }

    func testGrantedKeyOpensAndBindsAllGrantMetadata() throws {
        let id = identity(TestAtemStorage(), TestAtemCryptography())
        let keys = try prepare(id)
        let result = try id.completeVerification(
            account: account, deviceId: deviceId, reveal: reveal,
            transcript: Data(repeating: 9, count: 32), expectedSigningKey: keys.signPub, key: key
        )
        let grant = try XCTUnwrap(result.grants.first)
        var recipient = try HPKE.Recipient(
            privateKey: device, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: AtemStatements.grantInfo(account: account, deviceId: deviceId, devicePub: device.publicKey.rawRepresentation, kid: key.kid),
            encapsulatedKey: grant.encappedKey
        )
        XCTAssertEqual(try recipient.open(grant.ciphertext, authenticating: Data()), key.key)
        XCTAssertEqual(atemStatementFields(grant.signed).last, try AtemE2ECrypto.sealedKeyDigest(AtemHPKESealedKey(encapsulatedKey: grant.encappedKey, ciphertext: grant.ciphertext)))
        XCTAssertNoThrow(try id.keyGrant(account: account, deviceId: deviceId, publicKey: device.publicKey.rawRepresentation, key: key))
        XCTAssertThrowsError(try id.keyGrant(account: account, deviceId: "other", publicKey: device.publicKey.rawRepresentation, key: key))
        XCTAssertThrowsError(try id.keyGrant(account: "other", deviceId: deviceId, publicKey: device.publicKey.rawRepresentation, key: key))
        XCTAssertThrowsError(try id.keyGrant(account: account, deviceId: deviceId, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, key: key))
        XCTAssertThrowsError(try id.keyGrant(account: account, deviceId: deviceId, publicKey: device.publicKey.rawRepresentation, key: AccountDataKey(kid: "aaaaaaaa", key: key.key)))
    }

    func testPlainAccountVerificationHasNoGrantAndRequiresSavedRecovery() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let id = identity(storage, crypto)
        let keys = try id.verificationKeys(nonce: Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try id.completeVerification(account: account, deviceId: deviceId, reveal: reveal, transcript: key.key, expectedSigningKey: keys.signPub, key: nil))
        XCTAssertFalse(try id.isVerified(account: account, deviceId: deviceId))
        try id.markRecoverySaved(signingPublicKey: keys.signPub)
        let result = try id.completeVerification(account: account, deviceId: deviceId, reveal: reveal, transcript: key.key, expectedSigningKey: keys.signPub, key: nil)
        XCTAssertTrue(result.grants.isEmpty)
        XCTAssertEqual(atemStatementFields(result.accountState)[3], Data("off".utf8))
    }

    func testFailedSignatureAndPersistenceDoNotPinOrAdvanceTheAccount() throws {
        for failSigning in [true, false] {
            let storage = TestAtemStorage(), crypto = TestAtemCryptography()
            let id = identity(storage, crypto)
            let keys = try prepare(id)
            let before = storage.data
            crypto.failSign = failSigning
            storage.failWrite = !failSigning
            XCTAssertThrowsError(try id.completeVerification(account: account, deviceId: deviceId, reveal: reveal, transcript: key.key, expectedSigningKey: keys.signPub, key: key))
            XCTAssertEqual(storage.data, before)
            XCTAssertFalse(try id.isVerified(account: account, deviceId: deviceId))
            XCTAssertNil(try id.state(account: account))
        }
    }

    func testUnavailableAndCorruptStoredKeysNeverGenerateReplacements() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let id = identity(storage, crypto)
        _ = try prepare(id)
        let before = storage.data
        storage.failRead = true
        XCTAssertThrowsError(try id.verificationKeys(nonce: key.key))
        XCTAssertEqual(storage.data, before)
        storage.failRead = false
        storage.data = Data("corrupt".utf8)
        XCTAssertThrowsError(try id.verificationKeys(nonce: key.key))
        XCTAssertEqual(storage.data, Data("corrupt".utf8))
        XCTAssertEqual(crypto.creates, 1)
    }

    func testModeChangeRequiresSuccessfulSigningAndKeepsTheOldStateOnFailure() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let id = identity(storage, crypto)
        try id.setState(account: account, mode: "on", kid: key.kid)
        let before = storage.data
        crypto.failSign = true
        XCTAssertThrowsError(try id.setState(account: account, mode: "off", kid: nil))
        XCTAssertEqual(storage.data, before)
        XCTAssertEqual(try id.state(account: account)?.mode, "on")
        let untrusted = RelayEncryptionState(dataAccount: account, mode: "off", kid: nil,
            enabledAt: nil, updatedAt: 0, plaintextFields: 0, ciphertextFields: 0, obsoleteFields: 0)
        let local = try XCTUnwrap(id.state(account: account))
        XCTAssertEqual(untrusted.withEncryptionState(local).mode, "on")
        XCTAssertEqual(untrusted.withEncryptionState(local).kid, key.kid)
    }

    func testRecoverySecretIsDistinctFromKAndKitRetainsIt() throws {
        let id = identity(TestAtemStorage(), TestAtemCryptography())
        let text = try id.recoveryKit(astationId: "astation-00000000-0000-0000-0000-000000000001", relayURL: "https://station.agora.build")
        let parsed = try XCTUnwrap(RecoveryKit.parse(text))
        let expected = AtemE2ECrypto.base32(Data(repeating: 0x12, count: 32))
        XCTAssertEqual(parsed.recoveryKey?.replacingOccurrences(of: "-", with: ""), expected)
        XCTAssertNotEqual(expected, AtemE2ECrypto.base32(key.key))
        XCTAssertNil(RecoveryKit.parse(text + "\nRecovery key: " + (parsed.recoveryKey ?? "")))
        XCTAssertNil(RecoveryKit.parse(text.replacingOccurrences(of: parsed.recoveryKey ?? "", with: "AEK1-invalid")))
    }

    func testEpochOverflowAndIdentityChangeFailClosed() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let id = identity(storage, crypto)
        let keys = try prepare(id)
        XCTAssertThrowsError(try id.completeVerification(account: account, deviceId: deviceId, reveal: reveal, transcript: key.key, expectedSigningKey: Data(), key: key))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        json["epoch"] = UInt64.max
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let before = storage.data
        XCTAssertThrowsError(try id.completeVerification(account: account, deviceId: deviceId, reveal: reveal, transcript: key.key, expectedSigningKey: keys.signPub, key: key))
        XCTAssertEqual(storage.data, before)
    }

    func testKeychainAccessibilityAndAddOnlyCreation() throws {
        let account = "atem-e2e-test-" + UUID().uuidString
        let storage = AtemIdentityKeychainStorage(astationId: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "build.agora.astation.atem-e2e-v1", kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true]
        defer { SecItemDelete(query as CFDictionary) }
        do { try storage.write(Data([1]), creating: true) }
        catch { try rethrowStorageError(error) }
        XCTAssertThrowsError(try storage.write(Data([2]), creating: true))
        XCTAssertEqual(try storage.read(), Data([1]))
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes), errSecSuccess)
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try storage.write(Data([3]), creating: false)
        XCTAssertEqual(try storage.read(), Data([3]))
    }

    func testRealProtectedIdentityReloadsRecoveryPinsAndEpochs() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Secure Enclave unavailable") }
        let astationId = "atem-e2e-test-" + UUID().uuidString
        let storage = AtemIdentityKeychainStorage(astationId: astationId)
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "build.agora.astation.atem-e2e-v1",
                kSecAttrAccount as String: astationId, kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        }
        let first = AtemE2EIdentity(storage: storage)
        let keys: AtemVerifyKeys
        do { keys = try first.verificationKeys(nonce: Data(repeating: 8, count: 32)) }
        catch { try rethrowStorageError(error) }
        let kit = try first.recoveryKit(astationId: astationId, relayURL: "http://127.0.0.1:1")
        try first.markRecoverySaved(signingPublicKey: keys.signPub)
        let response = try first.completeVerification(account: account, deviceId: deviceId,
            reveal: reveal, transcript: Data(repeating: 9, count: 32), expectedSigningKey: keys.signPub, key: key)
        let second = AtemE2EIdentity(storage: storage)
        XCTAssertEqual(try second.verificationKeys(nonce: keys.nonce), keys)
        XCTAssertEqual(try second.recoveryKit(astationId: astationId, relayURL: "http://127.0.0.1:1"), kit)
        XCTAssertTrue(try second.recoveryIsSaved())
        XCTAssertTrue(try second.isVerified(account: account, deviceId: deviceId))
        XCTAssertEqual(try second.state(account: account)?.mode, "on")
        func storedEpoch() throws -> UInt64 {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.read())) as? [String: Any])
            return try XCTUnwrap(record["epoch"] as? NSNumber).uint64Value
        }
        let previousEpoch = try storedEpoch()
        let grant = try second.keyGrant(account: account, deviceId: deviceId,
            publicKey: device.publicKey.rawRepresentation, key: key)
        XCTAssertEqual(try storedEpoch(), previousEpoch + 1)
        for signed in [response.deviceVerified, response.accountState, grant.signed] {
            XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(signed.signature,
                message: signed.statement, publicKey: keys.signPub))
        }
    }

    func testRealSecureEnclaveMaterialSealsEncryptionKeyAndSigns() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Secure Enclave unavailable") }
        let crypto = AtemSecureEnclaveCryptography()
        let material: AtemIdentityMaterial
        do {
            material = try crypto.create()
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecInteractionNotAllowed) {
            throw XCTSkip("Unlock this Mac to test WhenUnlocked Secure Enclave keys")
        }
        try crypto.validate(material)
        XCTAssertNotEqual(material.signingKey.count, 32)
        XCTAssertGreaterThan(material.sealedEncryptionKey.count, 32)
        XCTAssertEqual(material.recoverySecret.count, 32)
        let signature = try crypto.sign(key.key, material: material)
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(signature, message: key.key, publicKey: try crypto.signingPublicKey(material)))
    }
}
