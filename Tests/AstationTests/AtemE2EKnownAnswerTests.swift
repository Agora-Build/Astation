import CryptoKit
import XCTest
@testable import Menubar

final class AtemE2EKnownAnswerTests: XCTestCase {
    private func repeated(_ value: UInt8) -> Data { Data(repeating: value, count: 32) }
    private func bytes(_ value: String) -> Data { AtemKnownAnswers.bytes(value) }

    private var reveal: AtemVerifyReveal {
        AtemVerifyReveal(
            devicePub: bytes(AtemKnownAnswers.devicePub), deviceSignPub: bytes(AtemKnownAnswers.deviceSignPub),
            unlockAuthPub: bytes(AtemKnownAnswers.unlockAuthPub), nonce: repeated(0x44)
        )
    }

    private var keys: AtemVerifyKeys {
        AtemVerifyKeys(
            signPub: bytes(AtemKnownAnswers.signPub), encPub: bytes(AtemKnownAnswers.encPub),
            recoverySignPub: bytes(AtemKnownAnswers.recoverySignPub), nonce: repeated(0x88)
        )
    }

    func testEveryDerivedPublicKeyMatchesAtem() throws {
        XCTAssertEqual(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x11)).publicKey.rawRepresentation, reveal.devicePub)
        XCTAssertEqual(try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x22)).publicKey.rawRepresentation, reveal.deviceSignPub)
        XCTAssertEqual(try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x33)).publicKey.rawRepresentation, reveal.unlockAuthPub)
        XCTAssertEqual(try P256.Signing.PrivateKey(rawRepresentation: repeated(0x55)).publicKey.x963Representation, keys.signPub)
        XCTAssertEqual(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x66)).publicKey.rawRepresentation, keys.encPub)
        XCTAssertEqual(try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x77)).publicKey.rawRepresentation, keys.recoverySignPub)
    }

    func testEncodingCommitmentSafetyCodeAndTranscriptMatchAtem() throws {
        XCTAssertEqual(try AtemE2ECrypto.encode([Data("atem".utf8), Data(), Data([1, 2])]), bytes(AtemKnownAnswers.encSample))
        XCTAssertEqual(try reveal.commitment(), bytes(AtemKnownAnswers.commitment))
        XCTAssertEqual(try reveal.safetyCode(keys: keys), AtemKnownAnswers.safetyCode)
        XCTAssertEqual(
            try AtemE2ECrypto.transcript(commitment: reveal.commitment(), nonceA: reveal.nonce, nonceS: keys.nonce),
            bytes(AtemKnownAnswers.transcript)
        )
    }

    func testAllSignedStatementEncodingsMatchAtem() throws {
        XCTAssertEqual(
            try AtemStatements.accountState(account: "acct-1", mode: "on", kid: "0123abcd", epoch: 2),
            bytes(AtemKnownAnswers.accountState)
        )
        XCTAssertEqual(try AtemStatements.deviceVerified(
            account: "acct-1", deviceId: "dev-1", reveal: reveal, transcript: bytes(AtemKnownAnswers.transcript), epoch: 1
        ), bytes(AtemKnownAnswers.deviceVerified))
        XCTAssertEqual(try AtemStatements.grantInfo(
            account: "acct-1", deviceId: "dev-1", devicePub: reveal.devicePub, kid: "0123abcd"
        ), bytes(AtemKnownAnswers.grantInfo))
        XCTAssertEqual(try AtemE2ECrypto.sealedKeyDigest(AtemHPKESealedKey(
            encapsulatedKey: bytes(AtemKnownAnswers.encappedKey), ciphertext: bytes(AtemKnownAnswers.ciphertext)
        )), bytes(AtemKnownAnswers.sealedHash))
        XCTAssertEqual(try AtemStatements.grant(
            account: "acct-1", deviceId: "dev-1", devicePub: reveal.devicePub, kid: "0123abcd", sealedHash: bytes(AtemKnownAnswers.sealedHash)
        ), bytes(AtemKnownAnswers.grantStatement))
    }

    func testAtemCertificateAndGrantSignaturesVerify() {
        for (statement, signature) in [
            (AtemKnownAnswers.deviceVerified, AtemKnownAnswers.deviceVerifiedSignature),
            (AtemKnownAnswers.grantStatement, AtemKnownAnswers.grantSignature),
        ] {
            XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(bytes(signature), message: bytes(statement), publicKey: keys.signPub))
            XCTAssertFalse(AtemE2ECrypto.verifyP256Signature(bytes(signature), message: bytes(statement) + Data([0]), publicKey: keys.signPub))
        }
    }

    func testAtemHPKEGrantOpensToTheSpecifiedAccountKey() throws {
        var receiver = try HPKE.Recipient(
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x11)),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: bytes(AtemKnownAnswers.grantInfo),
            encapsulatedKey: bytes(AtemKnownAnswers.encappedKey)
        )
        XCTAssertEqual(try receiver.open(bytes(AtemKnownAnswers.ciphertext), authenticating: Data()), repeated(0x99))
    }

    func testMessagesUseTheExactAtemWireNamesAndBase64() throws {
        let commit = AstationMessage.verifyCommit(AtemVerifyCommit(deviceId: "dev-1", commitment: bytes(AtemKnownAnswers.commitment)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(commit)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "verifyCommit")
        let data = try XCTUnwrap(object["data"] as? [String: String])
        XCTAssertEqual(data, ["device_id": "dev-1", "commitment": bytes(AtemKnownAnswers.commitment).base64EncodedString()])
        let certificate = AtemSignedWire(statement: bytes(AtemKnownAnswers.deviceVerified), signature: bytes(AtemKnownAnswers.deviceVerifiedSignature))
        let state = AtemSignedWire(statement: bytes(AtemKnownAnswers.accountState), signature: Data(repeating: 1, count: 64))
        let grant = AtemGrantWire(
            signed: AtemSignedWire(statement: bytes(AtemKnownAnswers.grantStatement), signature: bytes(AtemKnownAnswers.grantSignature)),
            encappedKey: bytes(AtemKnownAnswers.encappedKey), ciphertext: bytes(AtemKnownAnswers.ciphertext)
        )
        for message in [
            commit, .verifyKeys(keys), .verifyReveal(reveal),
            .deviceVerified(AtemDeviceVerified(deviceVerified: certificate, accountState: state, grants: [grant])),
            .encryptionMode(accountState: state), .keyGrant(grant: grant), .verifyAbort(reason: "denied"),
        ] {
            let encoded = try JSONEncoder().encode(message)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONDecoder().decode(AstationMessage.self, from: encoded))) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AstationMessage.self, from: Data(#"{"type":"encryptionMode","data":{"mode":"off"}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AstationMessage.self, from: Data(#"{"type":"keyGrant","data":{"wrapped_key":"legacy"}}"#.utf8)))
    }
}
