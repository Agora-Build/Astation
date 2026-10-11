import CryptoKit
import XCTest
@testable import Menubar

final class AtemStorageKeyControllerTests: XCTestCase {
    private let route = AtemVerificationRoute(clientId: "relay-device", connectionId: "socket-1", deviceId: "dev-1", deviceName: "Test Mac")

    private final class Harness {
        let fixture: AtemStorageFixture
        var account = "acct-1"
        var connection = "socket-1"
        var time: Date
        var replies: [(AstationMessage, AtemVerificationRoute)] = []
        var approvals: [AtemUnlockApproval] = []
        var callbacks: [(AtemUnlockDecision) -> Void] = []
        var cancellations = 0
        lazy var controller = AtemStorageKeyController(
            identity: fixture.identity, account: { self.account },
            isCurrent: { $0.connectionId == self.connection },
            send: { self.replies.append(($0, $1)) },
            approve: { approval, completion in
                self.approvals.append(approval)
                self.callbacks.append(completion)
                return { self.cancellations += 1 }
            }, now: { self.time }
        )

        init() throws {
            fixture = try AtemStorageFixture()
            time = fixture.now
            _ = try fixture.escrow()
        }
    }

    func testUnlockWaitsForApprovalAndReturnsBoundGrantOnOriginalConnection() throws {
        let h = try Harness(), request = try h.fixture.unlock()
        h.controller.unlock(request, route: route)
        XCTAssertTrue(h.replies.isEmpty)
        XCTAssertEqual(h.approvals.count, 1)
        XCTAssertEqual(h.approvals.first?.deviceName, "Test Mac")
        XCTAssertEqual(h.approvals.first?.bootId, "boot-1")
        XCTAssertEqual(h.approvals.first?.requestTime, h.time)
        XCTAssertNil(h.approvals.first?.lastUnlock)
        h.callbacks[0](.approve)
        XCTAssertEqual(h.replies.count, 1)
        guard case .unlockGrant(let grant) = h.replies[0].0 else { return XCTFail("Expected a grant") }
        XCTAssertEqual(try h.fixture.open(grant, request: request), h.fixture.key)
        XCTAssertEqual(h.replies[0].1, route)
        h.callbacks[0](.approve)
        XCTAssertEqual(h.replies.count, 1)
    }

    func testInvalidRequestsNeverPrompt() throws {
        let h = try Harness()
        let valid = try h.fixture.unlock()
        for request in [try h.fixture.unlock(ticket: "ticket"), try h.fixture.unlock(time: 0),
                        try h.fixture.unlock(account: "other"), try h.fixture.unlock(deviceId: "other"),
                        AtemUnlockRequestWire(request: valid.request, signature: Data(repeating: 0, count: 64)),
                        try h.fixture.unlock(kid: "deadbeef"),
                        try h.fixture.unlock(ephemeral: Data(repeating: 0, count: 32))] {
            h.controller.unlock(request, route: route)
        }
        XCTAssertTrue(h.approvals.isEmpty)
        XCTAssertEqual(h.replies.count, 7)
        for (message, bound) in h.replies {
            guard case .unlockDenied(let reason, let revoked) = message else { return XCTFail("Expected denial") }
            XCTAssertFalse(revoked)
            // Atem also recognizes these phrases in denials from older Astation builds.
            XCTAssertFalse(reason.lowercased().contains("revoked"))
            XCTAssertFalse(reason.lowercased().contains("does not belong to this verified device"))
            XCTAssertEqual(bound, route)
        }
    }

    func testDenyAndRevokeNeverSendAGrant() throws {
        for decision in [AtemUnlockDecision.deny, .revoke] {
            let h = try Harness()
            h.controller.unlock(try h.fixture.unlock(), route: route)
            h.callbacks[0](decision)
            XCTAssertEqual(h.replies.count, 1)
            guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
            XCTAssertEqual(revoked, decision == .revoke)
            XCTAssertEqual(try h.fixture.identity.isVerified(account: h.fixture.account, deviceId: h.fixture.deviceId), decision == .deny)
        }
    }

    func testUnknownDeviceOrMissingIdentityIsDeniedAsRevokedWithoutPromptOrMutation() throws {
        for missingIdentity in [true, false] {
            let h = try Harness()
            let unknown = AtemVerificationRoute(clientId: route.clientId, connectionId: route.connectionId,
                deviceId: missingIdentity ? route.deviceId : "unknown-device", deviceName: route.deviceName)
            let request = try h.fixture.unlock(deviceId: unknown.deviceId)
            if missingIdentity { h.fixture.storage.data = nil }
            let before = h.fixture.storage.data
            h.controller.unlock(request, route: unknown)
            XCTAssertTrue(h.approvals.isEmpty)
            XCTAssertEqual(h.replies.count, 1)
            guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
            XCTAssertTrue(revoked)
            XCTAssertEqual(h.replies[0].1, unknown)
            XCTAssertEqual(h.fixture.storage.data, before)
        }
    }

    func testPreviouslyRevokedDeviceIsDeniedAsRevokedWithoutPrompt() throws {
        let h = try Harness(), request = try h.fixture.unlock()
        try h.fixture.identity.revokeDevice(h.fixture.prepare(request))
        let before = h.fixture.storage.data
        h.controller.unlock(request, route: route)
        XCTAssertTrue(h.approvals.isEmpty)
        XCTAssertEqual(h.replies.count, 1)
        guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
        XCTAssertTrue(revoked)
        XCTAssertEqual(h.fixture.storage.data, before)
    }

    func testRevocationWhileApprovalIsPendingReturnsRevokedInsteadOfGrant() throws {
        for decision in [AtemUnlockDecision.approve, .revoke] {
            let h = try Harness(), request = try h.fixture.unlock()
            h.controller.unlock(request, route: route)
            try h.fixture.identity.revokeDevice(h.fixture.prepare(request))
            let before = h.fixture.storage.data
            h.callbacks[0](decision)
            XCTAssertEqual(h.replies.count, 1)
            guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
            XCTAssertTrue(revoked)
            XCTAssertEqual(h.fixture.storage.data, before)
        }
    }

    func testFailedRevocationDoesNotTellAtemToDiscardVerification() throws {
        let h = try Harness()
        h.controller.unlock(try h.fixture.unlock(), route: route)
        let before = h.fixture.storage.data
        h.fixture.storage.failWrite = true
        h.callbacks[0](.revoke)
        XCTAssertEqual(h.replies.count, 1)
        guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
        XCTAssertFalse(revoked)
        XCTAssertEqual(h.fixture.storage.data, before)
        XCTAssertTrue(try h.fixture.identity.isVerified(account: h.fixture.account, deviceId: h.fixture.deviceId))
    }

    func testDisconnectCancelsAndLateApprovalCannotGrantOnReplacementConnection() throws {
        let h = try Harness()
        h.controller.unlock(try h.fixture.unlock(), route: route)
        h.controller.disconnect(clientId: route.clientId)
        XCTAssertEqual(h.cancellations, 1)
        h.connection = "socket-2"
        h.callbacks[0](.approve)
        XCTAssertTrue(h.replies.isEmpty)
        let replacement = AtemVerificationRoute(clientId: route.clientId, connectionId: "socket-2", deviceId: route.deviceId, deviceName: route.deviceName)
        h.controller.unlock(try h.fixture.unlock(), route: replacement)
        h.callbacks[0](.approve)
        XCTAssertTrue(h.replies.isEmpty)
        h.callbacks[1](.approve)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.replies[0].1, replacement)
    }

    func testConnectionReplacementWithoutDisconnectAndAccountChangeInvalidateApproval() throws {
        for changeAccount in [true, false] {
            let h = try Harness()
            h.controller.unlock(try h.fixture.unlock(), route: route)
            if changeAccount { h.account = "another-account" } else { h.connection = "socket-2" }
            h.callbacks[0](.approve)
            XCTAssertEqual(h.cancellations, 1)
            for (message, _) in h.replies {
                guard case .unlockDenied = message else { return XCTFail("Stale approval sent a grant") }
            }
            XCTAssertNil(try h.fixture.status()?.currentKid)
        }
    }

    func testPinChangeAndPersistenceFailureInvalidateApprovedUnlock() throws {
        for changePin in [true, false] {
            let h = try Harness()
            h.controller.unlock(try h.fixture.unlock(), route: route)
            if changePin {
                try h.fixture.verify(devicePub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            } else { h.fixture.storage.failWrite = true }
            h.callbacks[0](.approve)
            XCTAssertEqual(h.replies.count, 1)
            guard case .unlockDenied(_, let revoked) = h.replies[0].0 else { return XCTFail("Expected denial") }
            XCTAssertFalse(revoked)
        }
    }

    func testTimeoutAndConcurrentRequestKeepCallbacksSeparate() throws {
        let h = try Harness()
        let request = try h.fixture.unlock()
        h.controller.unlock(request, route: route)
        h.controller.unlock(request, route: route)
        XCTAssertEqual(h.approvals.count, 1)
        XCTAssertEqual(h.replies.count, 1)
        h.time = h.time.addingTimeInterval(181)
        h.callbacks[0](.approve)
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertNil(try h.fixture.status()?.currentKid)
        h.controller.unlock(request, route: route)
        XCTAssertEqual(h.approvals.count, 2)
        h.callbacks[0](.approve)
        XCTAssertEqual(h.replies.count, 2)
        h.callbacks[1](.approve)
        XCTAssertEqual(h.replies.count, 3)
    }

    func testAbandonThenRotateIsHandledInOrderAndRepliesUseCapturedRoute() throws {
        let h = try Harness()
        h.controller.rotate(try h.fixture.rotate(new: "4e5f6a7b"), route: route)
        guard case .storageKeyRejected(_, let pending) = h.replies[0].0 else { return XCTFail("Expected pending rejection") }
        XCTAssertEqual(pending, "0a1b2c3d")
        h.controller.settle(try h.fixture.settlement(abandon: true), abandoning: true, route: route)
        XCTAssertEqual(h.replies.count, 1)
        h.controller.rotate(try h.fixture.rotate(new: "4e5f6a7b"), route: route)
        XCTAssertEqual(h.replies.count, 2)
        guard case .storageKeyAck = h.replies[1].0 else { return XCTFail("Expected ack") }
        XCTAssertEqual(h.replies[1].1, route)
        XCTAssertEqual(try h.fixture.status()?.pendingKid, "4e5f6a7b")
        h.controller.settle(try h.fixture.settlement(kid: "4e5f6a7b"), abandoning: false, route: route)
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertEqual(try h.fixture.status()?.currentKid, "4e5f6a7b")
    }

    func testStaleRouteCannotMutateStateOrOpenPrompt() throws {
        let h = try Harness(), before = h.fixture.storage.data
        h.connection = "socket-2"
        h.controller.unlock(try h.fixture.unlock(), route: route)
        h.controller.rotate(try h.fixture.rotate(old: "0a1b2c3d", new: "4e5f6a7b"), route: route)
        h.controller.settle(try h.fixture.settlement(abandon: true), abandoning: true, route: route)
        XCTAssertEqual(h.fixture.storage.data, before)
        XCTAssertTrue(h.replies.isEmpty)
        XCTAssertTrue(h.approvals.isEmpty)
    }

    func testSynchronousPresenterFinishesExactlyOnce() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        var replies = 0, cancellations = 0
        let controller = AtemStorageKeyController(identity: f.identity, account: { f.account }, isCurrent: { _ in true },
            send: { _, _ in replies += 1 }, approve: { _, done in done(.deny); return { cancellations += 1 } }, now: { f.now })
        controller.unlock(try f.unlock(), route: route)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(cancellations, 1)
    }

    func testMalformedWireRequestsReturnDenialWithoutPromptOrMutation() throws {
        let h = try Harness(), before = h.fixture.storage.data
        for payload in [
            #"{"type":"unlockRequest","data":{"request":"not base64","signature":"AA=="}}"#,
            #"{"type":"unlockRequest","data":{}}"#,
            #"{"type":"unlockRequest"}"#,
            #"{"type":"storageKeyRotate","data":{"rotate":{"statement":"AA=="},"ciphertext":5}}"#,
            #"{"type":"storageKeyRotate"}"#,
        ] {
            switch try JSONDecoder().decode(AstationMessage.self, from: Data(payload.utf8)) {
            case .unlockRequest(let wire): h.controller.unlock(wire, route: route)
            case .storageKeyRotate(let wire): h.controller.rotate(wire, route: route)
            default: XCTFail("Expected a storage-key request")
            }
        }
        XCTAssertEqual(h.replies.count, 5)
        XCTAssertTrue(h.approvals.isEmpty)
        XCTAssertEqual(h.fixture.storage.data, before)
    }

    func testScheduledExpiryDismissesPromptAndInvalidatesLateApproval() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let expired = expectation(description: "Timed-out request is denied")
        var callback: ((AtemUnlockDecision) -> Void)?
        var replies = 0, cancellations = 0
        let controller = AtemStorageKeyController(identity: f.identity, account: { f.account }, isCurrent: { _ in true },
            send: { message, _ in
                guard case .unlockDenied = message else { return XCTFail("Expected timeout denial") }
                replies += 1
                expired.fulfill()
            }, approve: { _, done in callback = done; return { cancellations += 1 } }, now: { f.now }, timeout: 0.02)
        controller.unlock(try f.unlock(), route: route)
        wait(for: [expired], timeout: 1)
        XCTAssertEqual(cancellations, 1)
        callback?(.approve)
        XCTAssertEqual(replies, 1)
        XCTAssertNil(try f.status()?.currentKid)
    }
}
