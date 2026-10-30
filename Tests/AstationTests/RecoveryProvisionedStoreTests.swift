import AstationRemote
import AtemClient
import CryptoKit
import Security
import XCTest
@testable import Menubar

@MainActor
final class RecoveryProvisionedStoreTests: XCTestCase {
    func testSecureEnclaveSignsTheRoutineChannelTranscriptWithoutAcceptingMembershipInputs() throws {
        guard ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Run with the provisioned local XCTest host to verify the Secure Enclave.")
        }
        let identity = AtemE2EIdentity(storage: TestAtemStorage())
        let keys = try identity.remotePublicKeys()
        let request = SignRequest(keyId: "test-manager", purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client-sig-v1", input: signingInput(label: .channelClient, payload: Data(repeating: 0x71, count: 32)), bodyJson: nil)
        let signature = try identity.signChannel(request, keyID: "test-manager", expectedPublicKey: keys.signing)
        XCTAssertTrue(try P256.Signing.PublicKey(x963Representation: keys.signing)
            .isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: request.input))
        XCTAssertThrowsError(try identity.signMembership(request, expectedPublicKey: keys.signing))
    }

    func testSecureEnclaveSignsOnlyTheConfirmedV2Genesis() throws {
        guard ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Run with the provisioned local XCTest host to verify the Secure Enclave.")
        }
        let id = "v2-enclave-test-" + UUID().uuidString
        let identity = AtemE2EIdentity(storage: TestAtemStorage())
        let keys = try identity.remotePublicKeys()
        let bootstrap = try RemoteRecoveryBootstrap(accountID: id, managerID: id, keyID: id,
            authKey: PublicKeyData(alg: .p256, raw: keys.signing),
            encryptionKey: PublicKeyData(alg: .x25519, raw: keys.encryption),
            recoverySecret: Data(repeating: 0x37, count: 32), relayURL: "https://example.test",
            signedAt: AstationRecoveryCoordinator.clock().wallMs, persist: { _ in })
        let request = try bootstrap.signingRequest()
        let signer = try RemoteConfirmedSigner(provider: AstationMembershipKeyProvider(identity: identity, keyID: id, publicKey: keys.signing),
            request: request, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, now: { AstationRecoveryCoordinator.clock().monoMs })
        _ = try bootstrap.sign(provider: signer, now: AstationRecoveryCoordinator.clock())
        XCTAssertThrowsError(try signer.sign(request: request))
        try bootstrap.relayStored(now: AstationRecoveryCoordinator.clock())
        let log = try bootstrap.committedLog(now: AstationRecoveryCoordinator.clock())
        XCTAssertEqual(log.member(deviceId: id)?.authKey, PublicKeyData(alg: .p256, raw: keys.signing))
    }

    func testProtectedV2CheckpointReloadsAndSerializesAllAccountOperations() throws {
        guard ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Run with the provisioned local XCTest host to verify the Data Protection Keychain.")
        }
        let account = "v2-test-" + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "build.agora.astation.recovery-v2", kSecAttrAccount as String: "account:" + account,
            kSecUseDataProtectionKeychain as String: true]
        defer { SecItemDelete(query as CFDictionary) }
        var store: RemoteRecoveryStore? = try RemoteRecoveryStore(accountID: account)
        XCTAssertNil(try store?.read())
        try store?.write(Data([1, 2, 3]))
        XCTAssertThrowsError(try RemoteRecoveryStore(accountID: account, operation: "another"))
        var attributes = query
        attributes[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributes as CFDictionary, &item), errSecSuccess)
        XCTAssertEqual((item as? [String: Any])?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        store = nil
        store = try RemoteRecoveryStore(accountID: account)
        XCTAssertEqual(try store?.read(), Data([1, 2, 3]))
        try store?.write(Data([4, 5, 6]))
        XCTAssertEqual(try store?.read(), Data([4, 5, 6]))
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data([7])] as CFDictionary), errSecSuccess)
        XCTAssertThrowsError(try store?.read())
        XCTAssertThrowsError(try store?.write(Data([8])))
    }
}
