import AppKit
import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class AuthenticationPresentationWindow: NSWindow {
    var visibleForAuthentication = false
    override var isVisible: Bool { visibleForAuthentication }
}

final class AstationChannelSignerTests: XCTestCase {
    @MainActor
    func testDismissedModalDoesNotReplaceTheVisibleSettingsAuthenticationWindow() {
        let settings = AuthenticationPresentationWindow()
        let alert = AuthenticationPresentationWindow()
        settings.visibleForAuthentication = true
        alert.visibleForAuthentication = true
        let captured = AstationChannelSigner.presentationWindow(keyWindow: alert, mainWindow: settings)
        alert.visibleForAuthentication = false
        XCTAssertTrue(captured === settings)
        XCTAssertTrue(captured?.isVisible == true, "Dismissing Apply must not prevent foreground restoration after Touch ID")
        settings.visibleForAuthentication = false
        XCTAssertFalse(captured?.isVisible == true, "Actually closing Settings still prevents its restoration")
    }

    @MainActor
    func testAuthenticationWindowSelectionIgnoresHiddenWindowsAndRetainsAVisibleKeyWindow() {
        let hidden = AuthenticationPresentationWindow()
        let visible = AuthenticationPresentationWindow()
        visible.visibleForAuthentication = true
        XCTAssertTrue(AstationChannelSigner.presentationWindow(keyWindow: visible, mainWindow: hidden) === visible)
        XCTAssertTrue(AstationChannelSigner.presentationWindow(keyWindow: hidden, mainWindow: visible) === visible)
        visible.visibleForAuthentication = false
        XCTAssertNil(AstationChannelSigner.presentationWindow(keyWindow: visible, mainWindow: hidden))
        XCTAssertNil(AstationChannelSigner.presentationWindow(keyWindow: nil, mainWindow: nil))
    }

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
