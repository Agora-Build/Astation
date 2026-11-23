import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

final class SoftwareDeviceCryptography: RemoteAppleIdentityCryptography {
    var creations = 0
    var signatures = 0
    var noninteractiveSignatures = 0
    var noninteractiveLoads = 0
    var refuseInteraction = false
    var onNoninteractiveSignature: (() -> Void)?
    func create() throws -> RemoteAppleIdentityMaterial {
        creations += 1
        let signing = P256.Signing.PrivateKey()
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        // Test-only key material. The production backend accepts only Secure Enclave handles.
        return RemoteAppleIdentityMaterial(signingHandle: signing.rawRepresentation, wrappingHandle: Data(),
            wrappingPublicKey: Data(), sealedEncryptionKey: encryption.rawRepresentation,
            encryptionPublicKey: encryption.publicKey.rawRepresentation)
    }
    func validate(_ material: RemoteAppleIdentityMaterial) throws -> (auth: Data, encryption: Data) {
        let auth = try P256.Signing.PrivateKey(rawRepresentation: material.signingHandle).publicKey.x963Representation
        let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.sealedEncryptionKey).publicKey.rawRepresentation
        guard encryption == material.encryptionPublicKey else { throw RemoteDeviceIdentityError.invalidIdentity }
        return (auth, encryption)
    }
    func sign(_ input: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        signatures += 1
        return try P256.Signing.PrivateKey(rawRepresentation: material.signingHandle).signature(for: input).rawRepresentation
    }
    func validateWithoutInteraction(_ material: RemoteAppleIdentityMaterial) throws -> (auth: Data, encryption: Data) {
        noninteractiveLoads += 1
        if refuseInteraction { throw RemoteDeviceIdentityError.secureHardwareUnavailable }
        return try validate(material)
    }
    func signWithoutInteraction(_ input: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        noninteractiveSignatures += 1
        if refuseInteraction { throw RemoteDeviceIdentityError.secureHardwareUnavailable }
        onNoninteractiveSignature?()
        return try P256.Signing.PrivateKey(rawRepresentation: material.signingHandle).signature(for: input).rawRepresentation
    }
    func sharedSecret(_ peer: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.sealedEncryptionKey)
            .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return secret.withUnsafeBytes { Data($0) }
    }
    func open(enc: Data, ct: Data, info: Data, aad: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.sealedEncryptionKey),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: enc)
        return try recipient.open(ct, authenticating: aad)
    }
}

@MainActor
final class DeviceIdentityFixture {
    let crypto = SoftwareDeviceCryptography()
    var stored: Data?
    var locked = false
    var failBeforeWrite = false
    var failAfterWrite = false
    var writes = 0
    var active = true
    var confirmation = true
    var confirmations = 0
    var time: UInt64 = 100

    func load(issuer: String = "https://auth.dev.agora.build", account: String = "account-device", existingOnly: Bool = false) throws -> RemoteAppleDeviceIdentity {
        try RemoteAppleDeviceIdentity(issuer: issuer, accountID: account, crypto: crypto,
            read: { [unowned self] in
                if locked { throw RemoteDeviceIdentityError.storageUncertain }
                return stored
            }, write: { [unowned self] bytes in
                writes += 1
                if failBeforeWrite { throw RemoteDeviceIdentityError.storageUncertain }
                stored = bytes
                if failAfterWrite { throw RemoteDeviceIdentityError.storageUncertain }
            }, existingOnly: existingOnly)
    }

    func signer(_ identity: RemoteAppleDeviceIdentity) -> RemoteRoutineChannelSigner {
        identity.channelSigner(now: { self.time }, active: { self.active }, confirm: {
            self.confirmations += 1
            return self.confirmation
        })
    }

    func request(_ identity: RemoteAppleDeviceIdentity) -> SignRequest {
        SignRequest(keyId: identity.publicIdentity.deviceID, purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client-sig-v1", input: signingInput(label: .channelClient, payload: Data(repeating: 4, count: 32)), bodyJson: nil)
    }
}

final class RemoteAppleDeviceIdentityTests: XCTestCase {
    @MainActor
    func testReportingLoadNeverCreatesKeysOrFallsBackToInteractiveValidation() throws {
        let f = DeviceIdentityFixture()
        XCTAssertThrowsError(try f.load(existingOnly: true))
        XCTAssertEqual(f.crypto.creations, 0); XCTAssertEqual(f.writes, 0)
        let first = try f.load()
        let saved = f.stored
        XCTAssertEqual(try f.load(existingOnly: true).publicIdentity, first.publicIdentity)
        XCTAssertEqual(f.crypto.noninteractiveLoads, 1)
        f.crypto.refuseInteraction = true
        XCTAssertThrowsError(try f.load(existingOnly: true))
        XCTAssertEqual(f.stored, saved)
        XCTAssertEqual(f.crypto.creations, 1); XCTAssertEqual(f.writes, 1)
        f.stored = Data("corrupt".utf8)
        XCTAssertThrowsError(try f.load(existingOnly: true))
        XCTAssertEqual(f.crypto.creations, 1); XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testReadOnlyVerifierReportUsesTheActualSDKAndOnlyTheNoninteractiveKeyPath() throws {
        let f = DeviceIdentityFixture(), identity = try f.load()
        let publicID = identity.publicIdentity
        let material = try XCTUnwrap(f.stored)
        let log = try VerifierReportTestSupport.log(account: "protocol-account", member: publicID.deviceID,
            auth: publicID.authKey, encryption: publicID.encryptionKey, sign: { input in
                // The genesis is a separate owner operation; reporting must not use this path.
                let record = try PropertyListSerialization.propertyList(from: material, format: nil) as! [String: Any]
                let crypto = record["material"] as! [String: Any]
                return try RemoteP256Signature.normalize(P256.Signing.PrivateKey(rawRepresentation: crypto["signingHandle"] as! Data).signature(for: input).rawRepresentation)
            })
        let anchor = try RemoteVerifierReportAnchor(log: log)
        let challenge = try verifierReportChallenge(signer: "member:" + publicID.deviceID, slot: "astation-ios",
            origin: "https://station.example", connection: 1, issuedAt: VerifierReportTestSupport.wall,
            expiresAt: VerifierReportTestSupport.wall + 30_000)
        let report = try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "astation-ios",
            origin: "https://station.example", wallMs: VerifierReportTestSupport.wall, current: { true })
        let verified = try verifyVerifierReport(log: log, reportJson: report, expectedChallengeJson: challenge,
            nowMs: VerifierReportTestSupport.wall)
        XCTAssertEqual(verified.process, verifierReportProcess())
        XCTAssertEqual(verified.inventory, verifierInventory())
        XCTAssertTrue(verified.atHead)
        XCTAssertEqual(f.crypto.noninteractiveSignatures, 1)
        XCTAssertEqual(f.crypto.signatures, 0); XCTAssertEqual(f.confirmations, 0)
        XCTAssertEqual(f.stored, material); XCTAssertEqual(f.writes, 1); XCTAssertEqual(f.crypto.creations, 1)

        XCTAssertThrowsError(try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "other",
            origin: "https://station.example", wallMs: VerifierReportTestSupport.wall, current: { true }))
        XCTAssertThrowsError(try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "astation-ios",
            origin: "https://other.example", wallMs: VerifierReportTestSupport.wall, current: { true }))
        XCTAssertThrowsError(try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "astation-ios",
            origin: "https://station.example", wallMs: VerifierReportTestSupport.wall, current: { false }))
        XCTAssertEqual(f.crypto.noninteractiveSignatures, 1)
        f.crypto.refuseInteraction = true
        XCTAssertThrowsError(try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "astation-ios",
            origin: "https://station.example", wallMs: VerifierReportTestSupport.wall, current: { true }))
        XCTAssertEqual(f.crypto.noninteractiveSignatures, 2)
        XCTAssertEqual(f.crypto.signatures, 0); XCTAssertEqual(f.confirmations, 0)
        f.crypto.refuseInteraction = false
        f.crypto.onNoninteractiveSignature = { f.stored = nil }
        XCTAssertThrowsError(try identity.verifierReport(log: log, anchor: anchor, challengeJSON: challenge, slot: "astation-ios",
            origin: "https://station.example", wallMs: VerifierReportTestSupport.wall, current: { true }))
        XCTAssertTrue(identity.storageUncertain)
        XCTAssertEqual(f.crypto.creations, 1)
    }

    func testHPKEMatchesTheSamePublishedBaseVectorUsedOnAndroid() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hpke-base-x25519", withExtension: "json", subdirectory: "Fixtures"))
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func bytes(_ name: String, in fields: [String: Any]) throws -> Data {
            let text = try XCTUnwrap(fields[name] as? String)
            var output = Data()
            for index in stride(from: 0, to: text.count, by: 2) {
                let start = text.index(text.startIndex, offsetBy: index)
                let end = text.index(start, offsetBy: 2)
                output.append(try XCTUnwrap(UInt8(text[start..<end], radix: 16)))
            }
            return output
        }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes("skRm", in: vector))
        XCTAssertEqual(key.publicKey.rawRepresentation, try bytes("pkRm", in: vector))
        let info = try bytes("info", in: vector), enc = try bytes("enc", in: vector)
        let encryption = try XCTUnwrap(vector["encryption"] as? [String: Any])
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: enc)
        XCTAssertEqual(try recipient.open(bytes("ct", in: encryption), authenticating: bytes("aad", in: encryption)),
            try bytes("pt", in: encryption))
    }

    @MainActor
    func testIdentityIsDurableBeforeExposureAndStableAcrossRestarts() throws {
        let f = DeviceIdentityFixture(), first = try f.load()
        XCTAssertEqual(f.writes, 1)
        XCTAssertEqual(f.crypto.creations, 1)
        XCTAssertEqual(first.publicIdentity, try f.load().publicIdentity)
        XCTAssertEqual(f.writes, 1)
        XCTAssertEqual(f.crypto.creations, 1)
        XCTAssertEqual(first.publicIdentity.authKey.alg, .p256)
        XCTAssertEqual(first.publicIdentity.encryptionKey.alg, .x25519)
        XCTAssertEqual(first.publicIdentity.authKey.raw.count, 65)
        XCTAssertEqual(first.publicIdentity.encryptionKey.raw.count, 32)
    }

    @MainActor
    func testUnreadableOrCorruptSavedIdentityIsNeverReplaced() throws {
        let f = DeviceIdentityFixture()
        _ = try f.load()
        let original = f.stored
        f.locked = true
        XCTAssertThrowsError(try f.load())
        f.locked = false
        f.stored = Data("corrupt".utf8)
        XCTAssertThrowsError(try f.load())
        XCTAssertEqual(f.crypto.creations, 1)
        XCTAssertEqual(f.writes, 1)
        f.stored = original
        XCTAssertNoThrow(try f.load())
    }

    @MainActor
    func testAccountOrIssuerSubstitutionCannotReadAnotherIdentity() throws {
        let f = DeviceIdentityFixture()
        _ = try f.load()
        XCTAssertThrowsError(try f.load(issuer: "https://auth.agora.build"))
        XCTAssertThrowsError(try f.load(account: "other-account"))
        XCTAssertThrowsError(try f.load(issuer: "http://auth.dev.agora.build"))
        XCTAssertEqual(f.crypto.creations, 1)
        XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testFailedCreationIsNotUsedAndUncertainCommittedCreationCanBeReloaded() throws {
        let f = DeviceIdentityFixture()
        f.failBeforeWrite = true
        XCTAssertThrowsError(try f.load())
        XCTAssertNil(f.stored)
        f.failBeforeWrite = false
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.load())
        let committed = f.stored
        XCTAssertNotNil(committed)
        f.failAfterWrite = false
        let restored = try f.load()
        XCTAssertEqual(f.crypto.creations, 2)
        XCTAssertEqual(f.stored, committed)
        XCTAssertEqual(restored.publicIdentity, try f.load().publicIdentity)
    }

    @MainActor
    func testChannelSigningNeedsOwnerPresenceAndCannotSignMembershipBodies() async throws {
        let f = DeviceIdentityFixture(), identity = try f.load(), signer = f.signer(identity)
        f.confirmation = false
        do { _ = try await signer.sign(f.request(identity), isCurrent: { true }); XCTFail("Owner denied") }
        catch { XCTAssertEqual(error as? RemoteOwnerAuthenticationError, .denied) }
        XCTAssertEqual(f.crypto.signatures, 0)
        f.confirmation = true
        let request = f.request(identity)
        let signature = try await signer.sign(request, isCurrent: { true })
        try verifySignature(key: identity.publicIdentity.authKey, label: .channelClient,
            payload: Data(repeating: 4, count: 32), signature: signature)
        let membership = SignRequest(keyId: identity.publicIdentity.deviceID, purpose: .enroll, freshConfirmation: true,
            label: "atem-membership-entry-v1", input: request.input, bodyJson: "{}")
        do { _ = try await signer.sign(membership, isCurrent: { true }); XCTFail("Wrong purpose") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .invalidInput) }
        XCTAssertEqual(f.crypto.signatures, 1)
    }

    @MainActor
    func testBackgroundAndLockCannotReuseOwnerPresenceOrSavedMaterial() async throws {
        let f = DeviceIdentityFixture(), identity = try f.load(), signer = f.signer(identity)
        _ = try await signer.sign(f.request(identity), isCurrent: { true })
        XCTAssertEqual(f.confirmations, 1)
        signer.invalidate()
        f.active = false
        do { _ = try await signer.sign(f.request(identity), isCurrent: { true }); XCTFail("Background") }
        catch { XCTAssertEqual(error as? RemoteOwnerAuthenticationError, .notForeground) }
        f.active = true
        f.locked = true
        do { _ = try await signer.sign(f.request(identity), isCurrent: { true }); XCTFail("Locked store") }
        catch { XCTAssertEqual(error as? RemoteDeviceIdentityError, .storageUncertain) }
        f.locked = false
        XCTAssertTrue(identity.storageUncertain)
        do { _ = try await signer.sign(f.request(identity), isCurrent: { true }); XCTFail("Reload required") }
        catch { XCTAssertEqual(error as? RemoteDeviceIdentityError, .storageUncertain) }
        XCTAssertEqual(f.crypto.signatures, 1)
    }

    @MainActor
    func testChangedSavedRecordFencesAnAlreadyOpenIdentity() throws {
        let f = DeviceIdentityFixture(), identity = try f.load()
        f.stored = nil
        XCTAssertThrowsError(try identity.sharedSecret(peer: Data(repeating: 3, count: 32)))
        XCTAssertTrue(identity.storageUncertain)
        XCTAssertEqual(f.crypto.creations, 1)
    }

    @MainActor
    func testX25519AndHPKEAreNativeAndBindInfoAndAAD() throws {
        let f = DeviceIdentityFixture(), identity = try f.load()
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let expected = try peer.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: identity.publicIdentity.encryptionKey.raw))
        XCTAssertEqual(try identity.sharedSecret(peer: peer.publicKey.rawRepresentation), expected.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try identity.sharedSecret(peer: Data(repeating: 0, count: 32)))
        let info = Data("device-enrollment-test".utf8), aad = Data("account and root".utf8), plaintext = Data(repeating: 42, count: 32)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: identity.publicIdentity.encryptionKey.raw),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        XCTAssertEqual(try identity.open(enc: sender.encapsulatedKey, ciphertext: ciphertext, info: info, aad: aad), plaintext)
        XCTAssertThrowsError(try identity.open(enc: sender.encapsulatedKey, ciphertext: ciphertext, info: Data(), aad: aad))
        XCTAssertThrowsError(try identity.open(enc: sender.encapsulatedKey, ciphertext: ciphertext, info: info, aad: Data()))
    }
}
