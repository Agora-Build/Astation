import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

final class RemotePairingSafetyTests: XCTestCase {
    private func repeated(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private func fields() throws -> [String: String] {
        ["device_pub": try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x11)).publicKey.rawRepresentation.base64EncodedString(),
         "device_sign_pub": try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x22)).publicKey.rawRepresentation.base64EncodedString(),
         "unlock_auth_pub": try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x33)).publicKey.rawRepresentation.base64EncodedString(),
         "host_channel_pub": RemoteRecoveryKit.base64URL(try Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0xaa)).publicKey.rawRepresentation),
         "nonce": repeated(0x44).base64EncodedString()]
    }

    private func message(_ fields: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "verifyReveal", "data": fields])
    }

    private func keys(genesis: String? = nil) throws -> RemotePairingKeys {
        try RemotePairingKeys(
            signingPublicKey: P256.Signing.PrivateKey(rawRepresentation: repeated(0x55)).publicKey.x963Representation,
            encryptionPublicKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: repeated(0x66)).publicKey.rawRepresentation,
            recoverySigningPublicKey: Curve25519.Signing.PrivateKey(rawRepresentation: repeated(0x77)).publicKey.rawRepresentation,
            genesisHash: genesis ?? String(repeating: "bb", count: 32), nonce: repeated(0x88))
    }

    func testV2MatchesTheReviewedAtemCeremonyKnownAnswers() throws {
        // Atem PR #89 at 7f2ad11, src/memory/kat_tests.rs; independently checked with CryptoKit.
        let reveal = try RemotePairingReveal(originalJSON: message(fields()))
        XCTAssertEqual(try hex(reveal.commitment()), "44c67e878ff3ab25acc7f0b84ad08b3e0ca107aba9fe3ce98d351c48f31661c4")
        XCTAssertEqual(try reveal.safetyCode(keys: keys()), "UVCK-F5EV-JFQ7")
        XCTAssertEqual(try hex(reveal.transcript(keys: keys())), "8e38877976a0c0ca63cfbb24ffa209178b2eb2f290de41544279d38305fe8007")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: keys().wireJSON()) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["genesis_hash"] as? String, String(repeating: "bb", count: 32))
        XCTAssertEqual(data["sign_pub"] as? String, try keys().signingPublicKey.base64EncodedString())
    }

    func testHostKeyAndGenesisChangesAlterTheCodeAndHostKeyAltersTheCommitment() throws {
        let original = try RemotePairingReveal(originalJSON: message(fields()))
        var changed = try fields()
        changed["host_channel_pub"] = RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let other = try RemotePairingReveal(originalJSON: message(changed))
        XCTAssertNotEqual(try original.commitment(), try other.commitment())
        XCTAssertNotEqual(try original.safetyCode(keys: keys()), try other.safetyCode(keys: keys()))
        XCTAssertNotEqual(try original.safetyCode(keys: keys()), try original.safetyCode(keys: keys(genesis: String(repeating: "bc", count: 32))))
    }

    func testMissingChannelKeyDuplicatesBadEncodingAndUnusableKeysAreRefused() throws {
        let original = try fields()
        for name in original.keys {
            var bad = original
            bad.removeValue(forKey: name)
            XCTAssertThrowsError(try RemotePairingReveal(originalJSON: message(bad)))
            bad = original
            bad[name] = "bad"
            XCTAssertThrowsError(try RemotePairingReveal(originalJSON: message(bad)))
        }
        var bad = original
        bad["host_channel_pub"] = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try RemotePairingReveal(originalJSON: message(bad)))
        bad = original
        bad["device_pub"] = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try RemotePairingReveal(originalJSON: message(bad)))
        let json = String(decoding: try message(original), as: UTF8.self)
        let duplicate = json.replacingOccurrences(of: "\"nonce\":", with: "\"nonce\":\"duplicate\",\"nonce\":")
        XCTAssertThrowsError(try RemotePairingReveal(originalJSON: Data(duplicate.utf8)))
        XCTAssertThrowsError(try keys(genesis: String(repeating: "BB", count: 32)))
    }
}
