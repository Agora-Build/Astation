import CryptoKit
import XCTest
@testable import Menubar

final class AtemE2ECryptoTests: XCTestCase {
    private let device = Data(0..<32)
    private let deviceSigning = Data(32..<64)
    private let unlockAuth = Data(64..<96)
    private let nonceA = Data(96..<128)
    private let astationEncryption = Data(128..<160)
    private let recoverySigning = Data(160..<192)
    private let nonceS = Data(192..<224)
    private let signingPublic = Data(hex:
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
    )

    func testEncodingPreservesFieldBoundariesAndBinaryBytes() throws {
        XCTAssertEqual(
            try AtemE2ECrypto.encode([Data("v1".utf8), Data(), Data([0, 0xff])]),
            Data(hex: "000000027631000000000000000200ff")
        )
        XCTAssertNotEqual(
            try AtemE2ECrypto.encode([Data("ab".utf8), Data("c".utf8)]),
            try AtemE2ECrypto.encode([Data("a".utf8), Data("bc".utf8)])
        )
    }

    // Independent Python hashlib fixtures; the authoritative Atem wire vectors are still required.
    func testCommitmentAndTranscriptMatchIndependentHashFixtures() throws {
        let commitment = try makeCommitment()
        XCTAssertEqual(commitment, Data(hex: "9e4d3e3cb60a66fdede547083d99cdfa0fa25967943a138b7c9ade9d2f116c63"))
        XCTAssertEqual(
            try AtemE2ECrypto.transcript(commitment: commitment, nonceA: nonceA, nonceS: nonceS),
            Data(hex: "0d21c9ebd2a2d074ac4a8565b87470459b1c9b2588f00f4ca88974afa9260fa1")
        )
        XCTAssertNotEqual(try makeCommitment(nonce: nonceS), commitment)
        XCTAssertNotEqual(
            try AtemE2ECrypto.commitment(
                devicePublicKey: deviceSigning, deviceSigningPublicKey: device,
                unlockAuthPublicKey: unlockAuth, nonce: nonceA
            ),
            commitment
        )
    }

    func testSafetyDigestUsesEveryKeyAndBothNonces() throws {
        XCTAssertEqual(
            try makeSafetyDigest(),
            Data(hex: "976e6ab689c16f74c04fb2493ba9e507d3e1eeb4c9f5c0508480e3a3e21d8c0c")
        )
        XCTAssertNotEqual(try makeSafetyDigest(nonce: nonceA), try makeSafetyDigest())
        XCTAssertNotEqual(try makeSafetyDigest(recoveryKey: device), try makeSafetyDigest())
    }

    func testInvalidKeyAndNonceLengthsAreRejected() throws {
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try makeCommitment(nonce: Data(repeating: 1, count: length)))
            XCTAssertThrowsError(try makeSafetyDigest(recoveryKey: Data(repeating: 1, count: length)))
        }
        XCTAssertThrowsError(try AtemE2ECrypto.safetyDigest(
            devicePublicKey: device, deviceSigningPublicKey: deviceSigning,
            unlockAuthPublicKey: unlockAuth, astationSigningPublicKey: signingPublic.dropFirst(),
            astationEncryptionPublicKey: astationEncryption, recoverySigningPublicKey: recoverySigning,
            nonceA: nonceA, nonceS: nonceS
        ))
        XCTAssertThrowsError(try AtemE2ECrypto.transcript(
            commitment: Data(), nonceA: nonceA, nonceS: nonceS
        ))
    }

    func testP256NormalizationHandlesScalarBoundsAndHighS() throws {
        let one = Data(repeating: 0, count: 31) + Data([1])
        let order = Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
        let orderMinusOne = Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
        let half = Data(hex: "7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8")
        XCTAssertEqual(try AtemE2ECrypto.normalizedP256Signature(one + orderMinusOne), one + one)
        XCTAssertEqual(try AtemE2ECrypto.normalizedP256Signature(one + half), one + half)
        XCTAssertThrowsError(try AtemE2ECrypto.normalizedP256Signature(one + order))
        XCTAssertThrowsError(try AtemE2ECrypto.normalizedP256Signature(order + one))
        XCTAssertThrowsError(try AtemE2ECrypto.normalizedP256Signature(one + Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try AtemE2ECrypto.normalizedP256Signature(Data(repeating: 0, count: 32) + one))
        XCTAssertThrowsError(try AtemE2ECrypto.normalizedP256Signature(Data(repeating: 1, count: 63)))
    }

    func testP256SignatureRejectsMessageAndSigningKeyChanges() throws {
        let key = P256.Signing.PrivateKey()
        let message = try AtemE2ECrypto.encode([Data("statement-v1".utf8), Data([0, 0xff])])
        let raw = try AtemE2ECrypto.normalizedP256Signature(key.signature(for: message).rawRepresentation)
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(raw, message: message, publicKey: key.publicKey.x963Representation))
        XCTAssertFalse(AtemE2ECrypto.verifyP256Signature(raw, message: message + Data([1]), publicKey: key.publicKey.x963Representation))
        XCTAssertFalse(AtemE2ECrypto.verifyP256Signature(raw, message: message, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertFalse(AtemE2ECrypto.verifyP256Signature(raw, message: message, publicKey: key.publicKey.rawRepresentation))
    }

    func testRFC6979SignatureIsAcceptedOnlyAfterLowSNormalization() throws {
        // RFC 6979 A.2.5: a valid P-256/SHA-256 signature with high S.
        let publicKey = Data(hex:
            "0460FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6" +
            "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299"
        )
        let high = Data(hex:
            "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716" +
            "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8"
        )
        let message = Data("sample".utf8)
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: high), for: message))
        XCTAssertFalse(AtemE2ECrypto.verifyP256Signature(high, message: message, publicKey: publicKey))
        let low = try AtemE2ECrypto.normalizedP256Signature(high)
        XCTAssertEqual(low, Data(high.prefix(32)) + Data(hex: "0834e36ad29a83bf2bc9385e491d6099c8fdf9d1ed67aa7ea5f51f93782857a9"))
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(low, message: message, publicKey: publicKey))
    }

    func testSealedKeyDigestMatchesIndependentHashFixture() throws {
        let sealed = AtemHPKESealedKey(encapsulatedKey: Data(0..<32), ciphertext: Data(32..<80))
        XCTAssertEqual(
            try AtemE2ECrypto.sealedKeyDigest(sealed),
            Data(hex: "7e25f06ef40ae4c61add6be7fe3f62f4dcd572b486bb9b1ea4f4910e28bfe40d")
        )
        var ciphertext = sealed.ciphertext
        ciphertext[ciphertext.startIndex] ^= 1
        XCTAssertNotEqual(
            try AtemE2ECrypto.sealedKeyDigest(sealed),
            try AtemE2ECrypto.sealedKeyDigest(AtemHPKESealedKey(
                encapsulatedKey: sealed.encapsulatedKey, ciphertext: ciphertext
            ))
        )
        XCTAssertThrowsError(try AtemE2ECrypto.sealedKeyDigest(AtemHPKESealedKey(
            encapsulatedKey: Data(), ciphertext: sealed.ciphertext
        )))
    }

    func testRecoverySigningKeyMatchesIndependentHKDFAndEd25519Fixtures() throws {
        // Python HMAC-SHA256 for HKDF; OpenSSL 3 for the Ed25519 public key.
        let key = try AtemE2ECrypto.recoverySigningKey(secret: device)
        XCTAssertEqual(
            key.rawRepresentation,
            Data(hex: "307202c127b6f79d67a2351bab99799150c120314e8947ac6eef3cda0533b834")
        )
        XCTAssertEqual(
            key.publicKey.rawRepresentation,
            Data(hex: "811b543a06225ac7b08d783bbaddb77e11ba0741492ca27aef49959984e92d61")
        )
        let differentKey = try AtemE2ECrypto.recoverySigningKey(secret: nonceA)
        XCTAssertNotEqual(key.publicKey.rawRepresentation, differentKey.publicKey.rawRepresentation)
        XCTAssertNotEqual(key.rawRepresentation, device)
    }

    func testRecoverySigningKeyRejectsInvalidSecretLengths() throws {
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try AtemE2ECrypto.recoverySigningKey(secret: Data(repeating: 1, count: length)))
        }
    }

    func testHPKESuiteOpensRFC9180BaseModeVector() throws {
        // CFRG HPKE test-vectors.json: mode=0, kem_id=32, kdf_id=1, aead_id=3.
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex:
            "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"
        ))
        XCTAssertEqual(privateKey.publicKey.rawRepresentation, Data(hex:
            "4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a"
        ))
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: Data(hex: "4f6465206f6e2061204772656369616e2055726e"),
            encapsulatedKey: Data(hex: "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a")
        )
        let plaintext = try recipient.open(
            Data(hex: "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28"),
            authenticating: Data(hex: "436f756e742d30")
        )
        XCTAssertEqual(plaintext, Data("Beauty is truth, truth beauty".utf8))
    }

    func testHPKEKeyGrantUsesBaseModeAndEmptyAAD() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let key = Data(repeating: 7, count: 32)
        let info = try AtemE2ECrypto.encode([
            Data("atem-grant-info-v1".utf8), Data("test-account".utf8), Data("K".utf8),
            Data("test-device".utf8), recipient.publicKey.rawRepresentation,
            Data("0123abcd".utf8), Data(),
        ])
        let sealed = try AtemE2ECrypto.sealKey(key, to: recipient.publicKey.rawRepresentation, info: info)
        XCTAssertEqual(sealed.encapsulatedKey.count, 32)
        XCTAssertEqual(sealed.ciphertext.count, 48)
        var receiver = try HPKE.Recipient(
            privateKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: sealed.encapsulatedKey
        )
        XCTAssertEqual(try receiver.open(sealed.ciphertext, authenticating: Data()), key)

        var wrongContext = try HPKE.Recipient(
            privateKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info + Data([0]), encapsulatedKey: sealed.encapsulatedKey
        )
        XCTAssertThrowsError(try wrongContext.open(sealed.ciphertext, authenticating: Data()))
        var wrongAAD = try HPKE.Recipient(
            privateKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: sealed.encapsulatedKey
        )
        XCTAssertThrowsError(try wrongAAD.open(sealed.ciphertext, authenticating: Data([0])))
        var tampered = sealed.ciphertext
        tampered[tampered.startIndex] ^= 1
        var freshReceiver = try HPKE.Recipient(
            privateKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: sealed.encapsulatedKey
        )
        XCTAssertThrowsError(try freshReceiver.open(tampered, authenticating: Data()))
    }

    func testHPKERejectsInvalidKeySizesAndEmptyInfo() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try AtemE2ECrypto.sealKey(Data(), to: recipient, info: Data([1])))
        XCTAssertThrowsError(try AtemE2ECrypto.sealKey(device, to: Data(), info: Data([1])))
        XCTAssertThrowsError(try AtemE2ECrypto.sealKey(device, to: recipient, info: Data()))
        XCTAssertThrowsError(try AtemE2ECrypto.sealKey(device, to: Data(repeating: 0, count: 32), info: Data([1])))
    }

    private func makeCommitment(nonce: Data? = nil) throws -> Data {
        try AtemE2ECrypto.commitment(
            devicePublicKey: device, deviceSigningPublicKey: deviceSigning,
            unlockAuthPublicKey: unlockAuth, nonce: nonce ?? nonceA
        )
    }

    private func makeSafetyDigest(nonce: Data? = nil, recoveryKey: Data? = nil) throws -> Data {
        try AtemE2ECrypto.safetyDigest(
            devicePublicKey: device, deviceSigningPublicKey: deviceSigning,
            unlockAuthPublicKey: unlockAuth, astationSigningPublicKey: signingPublic,
            astationEncryptionPublicKey: astationEncryption,
            recoverySigningPublicKey: recoveryKey ?? recoverySigning,
            nonceA: nonceA, nonceS: nonce ?? nonceS
        )
    }
}

private extension Data {
    init(hex: String) {
        let bytes = Array(hex.utf8)
        self.init(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }
}
