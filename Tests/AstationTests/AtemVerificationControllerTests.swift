import CryptoKit
import XCTest
@testable import Menubar

private final class VerificationHarness {
    let storage = TestAtemStorage()
    let crypto = TestAtemCryptography()
    let device = Curve25519.KeyAgreement.PrivateKey()
    let route = AtemVerificationRoute(clientId: "client-1", connectionId: "connection-1", deviceId: "dev-1", deviceName: "Test Mac")
    var currentConnection = "connection-1"
    var account = "acct-1"
    var time = Date()
    var messages: [AstationMessage] = []
    var approvals: [(Bool) -> Void] = []
    var recoveryApprovals: [(Bool) -> Void] = []
    var key: AccountDataKey?
    lazy var identity = AtemE2EIdentity(storage: storage, crypto: crypto)
    lazy var reveal = AtemVerifyReveal(
        devicePub: device.publicKey.rawRepresentation,
        deviceSignPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
        unlockAuthPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
        nonce: Data(repeating: 0x44, count: 32)
    )
    lazy var controller = AtemVerificationController(
        identity: identity, account: { [unowned self] in account },
        key: { [unowned self] _, kid in
            guard kid == nil || kid == key?.kid else { throw AtemIdentityError.invalidState }
            return key
        },
        isCurrent: { [unowned self] in $0.clientId == route.clientId && $0.connectionId == currentConnection },
        send: { [unowned self] message, _ in messages.append(message) },
        approve: { [unowned self] request, callback in
            XCTAssertEqual(request.deviceName, "Test Mac")
            XCTAssertEqual(request.safetyCode.count, 14)
            approvals.append(callback)
        },
        saveRecovery: { [unowned self] text, callback in
            XCTAssertTrue(text.contains("Recovery key:"))
            recoveryApprovals.append(callback)
        },
        kit: { [unowned self] in try identity.recoveryKit(astationId: "astation-00000000-0000-0000-0000-000000000001", relayURL: "https://station.agora.build") },
        now: { [unowned self] in time }
    )

    func begin() throws {
        controller.start(AtemVerifyCommit(deviceId: route.deviceId, commitment: try reveal.commitment()), route: route)
        controller.reveal(reveal, route: route)
    }

    func complete() throws {
        try begin()
        try XCTUnwrap(approvals.last)(true)
        try XCTUnwrap(recoveryApprovals.last)(true)
    }

    var certificates: [AtemDeviceVerified] {
        messages.compactMap { if case .deviceVerified(let value) = $0 { return value }; return nil }
    }

    var aborts: [String] {
        messages.compactMap { if case .verifyAbort(let value) = $0 { return value }; return nil }
    }
}

final class AtemVerificationControllerTests: XCTestCase {
    func testSuccessfulCeremonyRequiresApprovalAndSavedRecoveryBeforePinning() throws {
        let h = VerificationHarness()
        h.key = AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))
        try h.begin()
        XCTAssertTrue(h.certificates.isEmpty)
        XCTAssertFalse(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
        try XCTUnwrap(h.approvals.last)(true)
        XCTAssertTrue(h.certificates.isEmpty)
        try XCTUnwrap(h.recoveryApprovals.last)(true)
        XCTAssertTrue(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
        let result = try XCTUnwrap(h.certificates.first)
        guard case .verifyKeys(let keys) = h.messages.first else { return XCTFail("missing keys") }
        XCTAssertEqual(atemStatementFields(result.deviceVerified)[7], try AtemE2ECrypto.transcript(commitment: h.reveal.commitment(), nonceA: h.reveal.nonce, nonceS: keys.nonce))
        XCTAssertEqual(result.grants.count, 1)
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(result.accountState.signature, message: result.accountState.statement, publicKey: keys.signPub))
        var receiver = try HPKE.Recipient(
            privateKey: h.device, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: AtemStatements.grantInfo(account: h.account, deviceId: h.route.deviceId, devicePub: h.reveal.devicePub, kid: "0123abcd"),
            encapsulatedKey: result.grants[0].encappedKey
        )
        XCTAssertEqual(try receiver.open(result.grants[0].ciphertext, authenticating: Data()), h.key?.key)
    }

    func testDeniedOwnerAuthenticationAndRecoveryCancellationNeverPin() throws {
        for denyRecovery in [false, true] {
            let h = VerificationHarness()
            try h.begin()
            try XCTUnwrap(h.approvals.last)(denyRecovery)
            if denyRecovery { try XCTUnwrap(h.recoveryApprovals.last)(false) }
            XCTAssertEqual(h.aborts.count, 1)
            XCTAssertTrue(h.certificates.isEmpty)
            XCTAssertFalse(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
        }
    }

    func testCommitmentMismatchAndUnexpectedRevealAbortWithoutApproval() throws {
        let h = VerificationHarness()
        h.controller.reveal(h.reveal, route: h.route)
        XCTAssertEqual(h.aborts.count, 1)
        h.controller.start(AtemVerifyCommit(deviceId: h.route.deviceId, commitment: Data(repeating: 1, count: 32)), route: h.route)
        h.controller.reveal(h.reveal, route: h.route)
        XCTAssertEqual(h.aborts.count, 2)
        XCTAssertTrue(h.approvals.isEmpty)
        XCTAssertTrue(h.certificates.isEmpty)
    }

    func testCommitCannotClaimAnotherAuthenticatedDevice() {
        let h = VerificationHarness()
        h.controller.start(AtemVerifyCommit(deviceId: "other", commitment: Data(repeating: 1, count: 32)), route: h.route)
        XCTAssertEqual(h.aborts.count, 1)
        XCTAssertEqual(h.crypto.creates, 0)
    }

    func testAbortDisconnectReplacementAccountChangeAndExpiryInvalidateApproval() throws {
        for change in 0..<5 {
            let h = VerificationHarness()
            try h.begin()
            switch change {
            case 0: h.controller.cancel(route: h.route)
            case 1: h.controller.disconnect(clientId: h.route.clientId)
            case 2: h.currentConnection = "replacement"
            case 3: h.account = "another-account"
            default: h.time = h.time.addingTimeInterval(181)
            }
            try XCTUnwrap(h.approvals.last)(true)
            XCTAssertTrue(h.certificates.isEmpty)
            XCTAssertTrue(h.recoveryApprovals.isEmpty)
            XCTAssertFalse(try h.identity.isVerified(account: "acct-1", deviceId: h.route.deviceId))
        }
    }

    func testCancellationWhileRecoveryKitIsShownPreventsCompletion() throws {
        let h = VerificationHarness()
        try h.begin()
        try XCTUnwrap(h.approvals.last)(true)
        h.controller.cancel(route: h.route)
        try XCTUnwrap(h.recoveryApprovals.last)(true)
        XCTAssertFalse(try h.identity.recoveryIsSaved())
        XCTAssertTrue(h.certificates.isEmpty)
    }

    func testReplayDuringApprovalCannotReuseTheApproval() throws {
        let h = VerificationHarness()
        try h.begin()
        let callback = try XCTUnwrap(h.approvals.last)
        h.controller.reveal(h.reveal, route: h.route)
        callback(true)
        XCTAssertEqual(h.aborts.count, 1)
        XCTAssertTrue(h.certificates.isEmpty)
    }

    func testNewCeremonyUsesNewNonceAndCannotUseOldApproval() throws {
        let h = VerificationHarness()
        try h.begin()
        let callback = try XCTUnwrap(h.approvals.last)
        h.controller.cancel(route: h.route)
        try h.begin()
        callback(true)
        XCTAssertTrue(h.certificates.isEmpty)
        let nonces = h.messages.compactMap { if case .verifyKeys(let keys) = $0 { return keys.nonce }; return nil }
        XCTAssertEqual(nonces.count, 2)
        XCTAssertNotEqual(nonces[0], nonces[1])
    }

    func testKeyRequestRejectsUnverifiedAndChangedKeyThenReturnsSignedGrant() throws {
        let h = VerificationHarness()
        h.key = AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))
        h.controller.requestKey(publicKey: h.reveal.devicePub.base64EncodedString(), route: h.route)
        XCTAssertTrue(h.messages.contains { if case .statusUpdate(let status, _) = $0 { return status == "error" }; return false })
        try h.complete()
        h.controller.requestKey(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), route: h.route)
        h.controller.requestKey(publicKey: h.reveal.devicePub.base64EncodedString(), route: h.route)
        let grants = h.messages.compactMap { if case .keyGrant(let value) = $0 { return value }; return nil }
        XCTAssertEqual(grants.count, 1)
        XCTAssertTrue(h.approvals.count == 1)
    }
}
