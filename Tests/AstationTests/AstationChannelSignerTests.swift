import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

final class AstationChannelSignerTests: XCTestCase {
    private func request() -> SignRequest {
        SignRequest(keyId: "manager-a", purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client-sig-v1", input: signingInput(label: .channelClient, payload: Data(repeating: 7, count: 32)), bodyJson: nil)
    }

    func testChannelPrimitiveSignsOnlyThePinnedExistingIdentityAndExactDomain() throws {
        let crypto = TestAtemCryptography(), store = TestAtemStorage()
        let identity = AtemE2EIdentity(storage: store, crypto: crypto)
        let expected = try identity.remotePublicKeys().signing
        let original = request()
        let signature = try identity.signChannel(original, keyID: "manager-a", expectedPublicKey: expected)
        let publicKey = try P256.Signing.PublicKey(x963Representation: expected)
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: original.input))
        var membership = original; membership.purpose = .enroll; membership.bodyJson = "{}"
        XCTAssertThrowsError(try identity.signChannel(membership, keyID: "manager-a", expectedPublicKey: expected))
        XCTAssertThrowsError(try identity.signChannel(original, keyID: "other", expectedPublicKey: expected))
        XCTAssertThrowsError(try identity.signChannel(original, keyID: "manager-a", expectedPublicKey: Data(repeating: 0, count: 65)))
        XCTAssertThrowsError(try identity.signMembership(original, expectedPublicKey: expected))
    }

    func testMissingOrUnreadableIdentityIsNeverReplacedForChannelSigning() throws {
        let crypto = TestAtemCryptography(), store = TestAtemStorage()
        let identity = AtemE2EIdentity(storage: store, crypto: crypto)
        XCTAssertThrowsError(try identity.signChannel(request(), keyID: "manager-a", expectedPublicKey: Data()))
        XCTAssertEqual(crypto.creates, 0)
        XCTAssertNil(store.data)
        let expected = try identity.remotePublicKeys().signing
        let saved = store.data
        store.failRead = true
        XCTAssertThrowsError(try identity.signChannel(request(), keyID: "manager-a", expectedPublicKey: expected))
        XCTAssertEqual(store.data, saved)
        XCTAssertEqual(crypto.creates, 1)
    }
}
