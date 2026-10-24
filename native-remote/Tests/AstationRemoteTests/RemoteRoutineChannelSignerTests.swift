import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class RoutineSignerHarness {
    var now: UInt64 = 100
    var active = true
    var current = true
    var accepted = true
    var confirmations = 0
    var signed: [SignRequest] = []
    var confirmation: (() async -> Bool)?
    var signError: Error?
    lazy var signer = RemoteRoutineChannelSigner(keyID: "device-key", now: { [unowned self] in now },
        active: { [unowned self] in active }, confirm: { [unowned self] in
            confirmations += 1
            return await confirmation?() ?? accepted
        }, sign: { [unowned self] request in
            if let signError { throw signError }
            signed.append(request)
            return Data("signature".utf8)
        })
    func request(_ hash: UInt8 = 1) -> SignRequest {
        SignRequest(keyId: "device-key", purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client-sig-v1", input: signingInput(label: .channelClient, payload: Data(repeating: hash, count: 32)), bodyJson: nil)
    }
    func sign(_ request: SignRequest? = nil) async throws -> Data {
        try await signer.sign(request ?? self.request(), isCurrent: { current })
    }
}

final class RemoteRoutineChannelSignerTests: XCTestCase {
    @MainActor
    func testOneConfirmationCoversRoutineTranscriptsForLessThanFiveMinutesOnly() async throws {
        let h = RoutineSignerHarness()
        _ = try await h.sign()
        h.now += 299_999
        _ = try await h.sign(h.request(2))
        XCTAssertEqual(h.confirmations, 1)
        h.now += 1
        _ = try await h.sign(h.request(3))
        XCTAssertEqual(h.confirmations, 2)
        XCTAssertEqual(h.signed.count, 3)
    }

    @MainActor
    func testConcurrentCallsShareTheConfirmationWithoutExtendingItsWindow() async throws {
        let h = RoutineSignerHarness()
        var answer: CheckedContinuation<Bool, Never>?
        h.confirmation = { await withCheckedContinuation { answer = $0 } }
        let a = Task { try await h.sign() }
        let b = Task { try await h.sign(h.request(2)) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.confirmations, 1)
        try XCTUnwrap(answer).resume(returning: true)
        _ = try await a.value; _ = try await b.value
        XCTAssertEqual(h.signed.count, 2)
        h.confirmation = nil
        h.now += 300_000
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 2)
    }

    @MainActor
    func testInvalidationFencesAnOutstandingConfirmationAndDoesNotRestoreReuse() async throws {
        let h = RoutineSignerHarness()
        var answer: CheckedContinuation<Bool, Never>?
        h.confirmation = { await withCheckedContinuation { answer = $0 } }
        let task = Task { try await h.sign() }
        for _ in 0..<10 { await Task.yield() }
        h.signer.invalidate()
        try XCTUnwrap(answer).resume(returning: true)
        do { _ = try await task.value; XCTFail("Late confirmation signed") } catch { }
        XCTAssertTrue(h.signed.isEmpty)
        h.confirmation = nil
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 2)
    }

    @MainActor
    func testBackgroundStaleRouteAndCancellationFenceSigningAfterOwnerPrompt() async throws {
        for outcome in ["background", "stale", "cancel"] {
            let h = RoutineSignerHarness()
            var answer: CheckedContinuation<Bool, Never>?
            h.confirmation = { await withCheckedContinuation { answer = $0 } }
            let task = Task { try await h.sign() }
            for _ in 0..<10 { await Task.yield() }
            if outcome == "background" { h.active = false }
            if outcome == "stale" { h.current = false }
            if outcome == "cancel" { task.cancel() }
            try XCTUnwrap(answer).resume(returning: true)
            do { _ = try await task.value; XCTFail("Fenced signing: \(outcome)") } catch { }
            XCTAssertTrue(h.signed.isEmpty)
        }
    }

    @MainActor
    func testMalformedOrOtherPurposeRequestsNeverPromptOrUseThePrimitive() async throws {
        let h = RoutineSignerHarness()
        let original = h.request()
        var invalid: [SignRequest] = []
        var wrong = original; wrong.keyId = "other"; invalid.append(wrong)
        wrong = original; wrong.purpose = .enroll; invalid.append(wrong)
        wrong = original; wrong.freshConfirmation = true; invalid.append(wrong)
        wrong = original; wrong.label = "atem-membership-entry-v1"; invalid.append(wrong)
        wrong = original; wrong.bodyJson = "{}"; invalid.append(wrong)
        wrong = original; wrong.input = signingInput(label: .channelHost, payload: Data(repeating: 1, count: 32)); invalid.append(wrong)
        wrong = original; wrong.input.append(0); invalid.append(wrong)
        for request in invalid {
            do { _ = try await h.sign(request); XCTFail("Invalid signing request accepted") } catch { }
        }
        XCTAssertEqual(h.confirmations, 0)
        XCTAssertTrue(h.signed.isEmpty)
    }

    @MainActor
    func testDenialSigningFailureAndClockRegressionRequireConfirmationAgain() async throws {
        let h = RoutineSignerHarness()
        h.accepted = false
        do { _ = try await h.sign(); XCTFail("Denied signature") } catch { }
        h.accepted = true
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 2)
        h.signError = RemoteChannelError.invalidInput
        do { _ = try await h.sign(); XCTFail("Broken key signed") } catch { }
        h.signError = nil
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 3)
        h.now = 50
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 4)
        XCTAssertEqual(h.signed.count, 3)
    }

    @MainActor
    func testAStaleCompletionCannotLeaveAnExpiredPromptCachedAndBackgroundClearsReuse() async throws {
        let h = RoutineSignerHarness()
        h.confirmation = { h.current = false; return true }
        do { _ = try await h.sign(); XCTFail("Stale route signed") } catch { }
        h.current = true
        h.now += 300_000
        h.confirmation = nil
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 2)
        h.active = false
        do { _ = try await h.sign(); XCTFail("Background signed") } catch { }
        h.active = true
        _ = try await h.sign()
        XCTAssertEqual(h.confirmations, 3)
    }
}
