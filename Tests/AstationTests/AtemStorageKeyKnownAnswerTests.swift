import CryptoKit
import XCTest
@testable import Menubar

final class AtemStorageKeyKnownAnswerTests: XCTestCase {
    private typealias V = AtemStorageKnownAnswers
    private func bytes(_ hex: String) -> Data { AtemKnownAnswers.bytes(hex) }
    private func repeated(_ value: UInt8) -> Data { Data(repeating: value, count: 32) }

    func testAllStepTwoStatementEncodingsMatchAtem() throws {
        let e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0xaa))
        XCTAssertEqual(e.publicKey.rawRepresentation, bytes(V.ephemeralPub))
        let request = try AtemStatements.unlockRequest(account: "acct-1", deviceId: "dev-1", bootId: "boot-1",
            ephemeralPublicKey: e.publicKey.rawRepresentation, nonce: repeated(0xbb), time: 1_760_000_000, storageKid: "0a1b2c3d")
        XCTAssertEqual(request, bytes(V.unlockRequest))
        XCTAssertEqual(Data(SHA256.hash(data: request)), bytes(V.requestHash))
        XCTAssertEqual(try AtemStatements.unlockInfo(account: "acct-1", deviceId: "dev-1", kid: "0a1b2c3d", requestHash: bytes(V.requestHash)), bytes(V.unlockInfo))
        XCTAssertEqual(try AtemStatements.unlockGrant(account: "acct-1", deviceId: "dev-1", kid: "0a1b2c3d", requestHash: bytes(V.requestHash), sealedHash: repeated(0xcc)), bytes(V.unlockGrantSample))
        XCTAssertEqual(try AtemStatements.storageKeyInfo(account: "acct-1", deviceId: "dev-1", kid: "4e5f6a7b"), bytes(V.storageInfo))
        XCTAssertEqual(try AtemStatements.storageRotate(account: "acct-1", deviceId: "dev-1", oldKid: "0a1b2c3d", newKid: "4e5f6a7b", sealedHash: repeated(0xdd)), bytes(V.rotateSample))
        XCTAssertEqual(try AtemStatements.storageRotate(account: "acct-1", deviceId: "dev-1", oldKid: "", newKid: "0a1b2c3d", sealedHash: repeated(0xdd)), bytes(V.firstRotate))
        XCTAssertEqual(try AtemStatements.storageAck(account: "acct-1", deviceId: "dev-1", kid: "4e5f6a7b"), bytes(V.ack))
        XCTAssertEqual(try AtemStatements.storageSettlement(account: "acct-1", deviceId: "dev-1", kid: "4e5f6a7b", abandoning: false), bytes(V.confirm))
        XCTAssertEqual(try AtemStatements.storageSettlement(account: "acct-1", deviceId: "dev-1", kid: "4e5f6a7b", abandoning: true), bytes(V.abandon))
        XCTAssertEqual(try AtemE2ECrypto.encode([Data("atem-device-keys-v1".utf8), Data("dev-1".utf8), Data("0a1b2c3d".utf8)]), bytes(V.fileAAD))
        let parsed = try AtemUnlockRequest(statement: request)
        XCTAssertEqual(parsed.time, 1_760_000_000)
        XCTAssertEqual(parsed.storageKid, "0a1b2c3d")
    }

    func testEveryFixedDeviceSignatureVerifiesUsingItsPinnedKey() throws {
        for (statement, signature, key) in [
            (V.unlockRequest, V.requestSignature, AtemKnownAnswers.unlockAuthPub),
            (V.rotateSample, V.rotateSampleSignature, AtemKnownAnswers.deviceSignPub),
            (V.rotate, V.rotateSignature, AtemKnownAnswers.deviceSignPub),
            (V.confirm, V.confirmSignature, AtemKnownAnswers.deviceSignPub),
            (V.abandon, V.abandonSignature, AtemKnownAnswers.deviceSignPub),
        ] {
            try AtemStatementReader.verify(AtemSignedWire(statement: bytes(statement), signature: bytes(signature)), publicKey: bytes(key))
            XCTAssertThrowsError(try AtemStatementReader.verify(AtemSignedWire(statement: bytes(statement) + Data([0]), signature: bytes(signature)), publicKey: bytes(key)))
        }
    }

    func testFixedUnlockSealOpensAndGrantSignatureVerifies() throws {
        let sealed = AtemHPKESealedKey(encapsulatedKey: bytes(V.unlockEncapped), ciphertext: bytes(V.unlockCiphertext))
        XCTAssertEqual(try AtemE2ECrypto.sealedKeyDigest(sealed), bytes(V.unlockSealedHash))
        XCTAssertEqual(try AtemStatements.unlockGrant(account: "acct-1", deviceId: "dev-1", kid: "0a1b2c3d", requestHash: bytes(V.requestHash), sealedHash: bytes(V.unlockSealedHash)), bytes(V.unlockGrant))
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(bytes(V.unlockGrantSignature), message: bytes(V.unlockGrant), publicKey: bytes(AtemKnownAnswers.signPub)))
        var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0xaa)),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: bytes(V.unlockInfo), encapsulatedKey: sealed.encapsulatedKey)
        XCTAssertEqual(try recipient.open(sealed.ciphertext, authenticating: Data()), repeated(0xee))
    }

    func testFixedRotateSealOpensWithAstationEncryptionKey() throws {
        let sealed = AtemHPKESealedKey(encapsulatedKey: bytes(V.rotateEncapped), ciphertext: bytes(V.rotateCiphertext))
        XCTAssertEqual(try AtemE2ECrypto.sealedKeyDigest(sealed), bytes(V.rotateSealedHash))
        XCTAssertEqual(try AtemStatements.storageRotate(account: "acct-1", deviceId: "dev-1", oldKid: "0a1b2c3d", newKid: "4e5f6a7b", sealedHash: bytes(V.rotateSealedHash)), bytes(V.rotate))
        var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x66)),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: bytes(V.storageInfo), encapsulatedKey: sealed.encapsulatedKey)
        XCTAssertEqual(try recipient.open(sealed.ciphertext, authenticating: Data()), repeated(0xee))
    }

    func testAllEightMessagesRoundTripWithExactSnakeCaseAndBase64() throws {
        let signed = AtemSignedWire(statement: bytes(V.rotate), signature: bytes(V.rotateSignature))
        let samples: [(AstationMessage, String, Set<String>)] = [
            (.unlockRequest(AtemUnlockRequestWire(request: bytes(V.unlockRequest), signature: bytes(V.requestSignature))), "unlockRequest", ["request", "signature"]),
            (.unlockGrant(AtemUnlockGrantWire(grant: signed, encappedKey: bytes(V.unlockEncapped), ciphertext: bytes(V.unlockCiphertext))), "unlockGrant", ["grant", "encapped_key", "ciphertext"]),
            (.unlockDenied(reason: "denied"), "unlockDenied", ["reason"]),
            (.unlockDenied(reason: "denied", revoked: true), "unlockDenied", ["reason", "revoked"]),
            (.storageKeyRotate(AtemStorageRotateWire(rotate: signed, encappedKey: bytes(V.rotateEncapped), ciphertext: bytes(V.rotateCiphertext))), "storageKeyRotate", ["rotate", "encapped_key", "ciphertext"]),
            (.storageKeyAck(ack: signed), "storageKeyAck", ["ack"]),
            (.storageKeyRejected(reason: "pending", pendingKid: "0a1b2c3d"), "storageKeyRejected", ["reason", "pending_kid"]),
            (.storageKeyConfirm(confirm: signed), "storageKeyConfirm", ["confirm"]),
            (.storageKeyAbandon(abandon: signed), "storageKeyAbandon", ["abandon"]),
            (.storageKeyRejected(reason: "invalid", pendingKid: nil), "storageKeyRejected", ["reason"]),
        ]
        for (message, type, fields) in samples {
            let encoded = try JSONEncoder().encode(message)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, type)
            let data = try XCTUnwrap(object["data"] as? [String: Any])
            XCTAssertEqual(Set(data.keys), fields)
            for key in ["ack", "confirm", "abandon", "rotate", "grant"] where fields.contains(key) {
                let wire = try XCTUnwrap(data[key] as? [String: String])
                XCTAssertEqual(wire, ["statement": signed.statement.base64EncodedString(), "signature": signed.signature.base64EncodedString()])
            }
            if type == "unlockRequest" { XCTAssertEqual(data["request"] as? String, bytes(V.unlockRequest).base64EncodedString()) }
            let decoded = try JSONDecoder().decode(AstationMessage.self, from: encoded)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary, object as NSDictionary)
        }
    }

    func testUnlockDenialRevocationFlagIsOptionalAndIndependentOfReasonText() throws {
        for (payload, expected) in [
            (#"{"type":"unlockDenied","data":{"reason":"denied"}}"#, false),
            (#"{"type":"unlockDenied","data":{"reason":"denied","revoked":false}}"#, false),
            (#"{"type":"unlockDenied","data":{"reason":"denied","revoked":true}}"#, true),
        ] {
            let message = try JSONDecoder().decode(AstationMessage.self, from: Data(payload.utf8))
            guard case .unlockDenied(let reason, let revoked) = message else { return XCTFail("Expected denial") }
            XCTAssertEqual(reason, "denied")
            XCTAssertEqual(revoked, expected)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
            let data = try XCTUnwrap(encoded["data"] as? [String: Any])
            XCTAssertEqual(data["revoked"] as? Bool, expected ? true : nil)
        }
    }

    func testStrictParserRejectsTruncationTrailingFieldsInvalidUTF8AndWrongNumbers() throws {
        let request = bytes(V.unlockRequest)
        let fields = try AtemE2ECrypto.decode(request, maximumFields: 9)
        for size in 0..<request.count { XCTAssertThrowsError(try AtemUnlockRequest(statement: request.prefix(size))) }
        XCTAssertThrowsError(try AtemUnlockRequest(statement: request + Data([0])))
        XCTAssertThrowsError(try AtemUnlockRequest(statement: AtemE2ECrypto.encode(fields + [Data()])))
        for (index, replacement) in [(0, Data("wrong".utf8)), (1, Data([0xff])), (2, Data()),
                                     (3, Data(repeating: 0x61, count: 257)), (4, Data([1])),
                                     (5, Data()), (6, Data()), (7, Data([1])), (8, Data("BAD-KID!".utf8))] {
            var invalid = fields
            invalid[index] = replacement
            XCTAssertThrowsError(try AtemUnlockRequest(statement: AtemE2ECrypto.encode(invalid)))
        }
        XCTAssertThrowsError(try AtemE2ECrypto.decode(Data([0xff, 0xff, 0xff, 0xff]), maximumFields: 9))
    }
}
