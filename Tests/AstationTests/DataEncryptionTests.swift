import CryptoKit
import XCTest
@testable import Menubar

final class DataEncryptionTests: XCTestCase {
    func testRecoveryKeyRoundTripAndChecksumFailure() throws {
        let value = try DataEncryptionKeyManager.shared.generate()
        let recovery = try DataEncryptionKeyManager.shared.recoveryKey(for: value)
        XCTAssertTrue(recovery.hasPrefix("AEK1-"))
        XCTAssertEqual(try DataEncryptionKeyManager.decodeRecoveryKey(recovery), value)

        var damaged = recovery
        let index = damaged.index(before: damaged.endIndex)
        damaged.replaceSubrange(index...index, with: damaged[index] == "A" ? "B" : "A")
        XCTAssertThrowsError(try DataEncryptionKeyManager.decodeRecoveryKey(damaged))
    }

    func testWrappedKeyCanBeOpenedWithTheAtemWireAlgorithm() throws {
        let device = Curve25519.KeyAgreement.PrivateKey()
        let account = AccountDataKey(kid: "0123abcd", key: Data(repeating: 7, count: 32))
        let grant = try DataEncryptionKeyManager.shared.wrap(
            account,
            to: device.publicKey.rawRepresentation.base64EncodedString(),
            dataAccount: "account-1"
        )
        let wire = try XCTUnwrap(Data(base64Encoded: grant.wrappedKey))
        XCTAssertGreaterThanOrEqual(wire.count, 32 + 12 + 16)

        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: wire.prefix(32))
        let secret = try device.sharedSecretFromKeyAgreement(with: ephemeral)
        let aad = Data("astation-data-key-wrap-v1\naccount-1\n0123abcd".utf8)
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: aad,
            outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(combined: wire.dropFirst(32))
        XCTAssertEqual(try ChaChaPoly.open(box, using: wrappingKey, authenticating: aad), account.key)
    }

    func testDeviceFingerprintUses64Bits() throws {
        let publicKey = Data(repeating: 5, count: 32)
        let expected = SHA256.hash(data: publicKey).prefix(8)
            .map { String(format: "%02X", $0) }
            .joined()
        let grouped = stride(from: 0, to: expected.count, by: 4).map { offset in
            let start = expected.index(expected.startIndex, offsetBy: offset)
            let end = expected.index(start, offsetBy: 4)
            return String(expected[start..<end])
        }.joined(separator: "-")

        XCTAssertEqual(
            DataEncryptionKeyManager.fingerprint(publicKeyBase64: publicKey.base64EncodedString()),
            grouped
        )
        XCTAssertEqual(grouped.count, 19)
    }

    func testEncryptionMessagesRoundTrip() throws {
        let messages: [AstationMessage] = [
            .encryptionMode(
                mode: "enabling",
                kid: "0123abcd",
                dataAccount: "group-1",
                astationId: "astation-1"
            ),
            .keyRequest(publicKey: Data(repeating: 1, count: 32).base64EncodedString()),
            .keyGrant(kid: "0123abcd", wrappedKey: "wrapped", dataAccount: "group-1"),
            .encryptionMigrationComplete(mode: "on", kid: "0123abcd"),
        ]

        for message in messages {
            let encoded = try JSONEncoder().encode(message)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            let decoded = try JSONDecoder().decode(AstationMessage.self, from: encoded)
            XCTAssertEqual(object["type"] as? String, messageType(decoded))
        }
    }

    func testRelayEncryptionControlsEncodeAndParse() throws {
        let set = try XCTUnwrap(
            RelayIdentityProtocol.encryptionSetMessage(mode: "enabling", kid: "0123abcd")
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(set.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "relayEncryptionSet")
        XCTAssertEqual(object["mode"] as? String, "enabling")
        XCTAssertEqual(object["kid"] as? String, "0123abcd")

        let state = """
        {"type":"relayEncryptionState","data_account":"group-1","mode":"on",\
        "kid":"0123abcd","enabled_at":10,"updated_at":11,"plaintext_fields":0,\
        "ciphertext_fields":4,"obsolete_fields":0}
        """
        guard case .encryptionState(let parsed) = RelayIdentityProtocol.parseControlFrame(state) else {
            return XCTFail("expected encryption state")
        }
        XCTAssertEqual(parsed.dataAccount, "group-1")
        XCTAssertEqual(parsed.mode, "on")
        XCTAssertEqual(parsed.ciphertextFields, 4)
    }

    private func messageType(_ message: AstationMessage) -> String {
        switch message {
        case .encryptionMode: return "encryptionMode"
        case .keyRequest: return "keyRequest"
        case .keyGrant: return "keyGrant"
        case .encryptionMigrationComplete: return "encryptionMigrationComplete"
        default: return "unexpected"
        }
    }
}
