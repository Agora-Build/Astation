import AppKit
import LocalAuthentication
import XCTest
@testable import Menubar

final class AtemVerificationUITests: XCTestCase {
    private final class UnlockContext: LAContext, @unchecked Sendable {
        var available = true
        var preflightPolicies: [LAPolicy] = []
        var policies: [LAPolicy] = []
        var reasons: [String] = []
        var replies: [@Sendable (Bool, Error?) -> Void] = []
        var invalidations = 0

        override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
            preflightPolicies.append(policy)
            return available
        }

        override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String,
                                     reply: @escaping @Sendable (Bool, Error?) -> Void) {
            policies.append(policy)
            reasons.append(localizedReason)
            replies.append(reply)
        }

        override func invalidate() { invalidations += 1 }
    }

    private var unlockRequest: AtemUnlockApproval {
        AtemUnlockApproval(deviceName: "Test Device", bootId: "test-boot", requestTime: Date(), lastUnlock: nil)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue callbacks delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func dialog(completion: @escaping (Bool) -> Void) -> AtemVerificationDialog {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Verification UI Test"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return AtemVerificationDialog(alert: alert, completion: completion)
    }

    func testAlertButtonsCompleteWithoutBlockingTheMainQueue() {
        for accepted in [true, false] {
            var results: [Bool] = []
            let prompt = dialog { results.append($0) }
            prompt.show()
            XCTAssertTrue(prompt.alert.window.isVisible)
            prompt.alert.buttons[accepted ? 0 : 1].performClick(nil)
            XCTAssertEqual(results, [accepted])
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testPeerCancellationDismissesAlertAndIgnoresLateAuthenticationResult() {
        var results: [Bool] = []
        let prompt = dialog { results.append($0) }
        prompt.confirm = { _ in }
        prompt.show()
        prompt.alert.buttons[0].performClick(nil)
        XCTAssertTrue(prompt.isActive)
        prompt.finish(false)
        prompt.finish(true)
        XCTAssertEqual(results, [false])
        XCTAssertFalse(prompt.alert.window.isVisible)
    }

    func testClosingWindowCancelsOnce() {
        var results: [Bool] = []
        let prompt = dialog { results.append($0) }
        prompt.show()
        prompt.alert.window.close()
        prompt.finish(true)
        XCTAssertEqual(results, [false])
    }

    func testRecoveryKitAndSaveControlsAreVisibleBeforeConfirming() throws {
        _ = NSApplication.shared
        let kit = RecoveryKit(
            astationId: "astation-00000000-0000-0000-0000-000000000001",
            relayURL: "https://station.agora.build",
            recoveryKey: Array(repeating: "AAAA", count: 13).joined(separator: "-")
        ).text(createdAt: Date(timeIntervalSince1970: 0))
        var results: [Bool] = []
        let prompt = AtemRecoveryKitPrompt(text: kit) { results.append($0) }
        prompt.show()
        defer { prompt.cancel() }
        let stack = try XCTUnwrap(prompt.alert.accessoryView as? NSStackView)
        XCTAssertGreaterThanOrEqual(stack.frame.width, 450)
        XCTAssertGreaterThan(stack.frame.height, 150)
        let content = try XCTUnwrap(stack.arrangedSubviews.first as? NSTextField)
        XCTAssertEqual(content.stringValue, kit)
        XCTAssertTrue(content.isSelectable)
        let textSize = try XCTUnwrap(content.cell).cellSize(forBounds: content.bounds)
        XCTAssertLessThanOrEqual(textSize.height, content.bounds.height)
        let windowContent = try XCTUnwrap(prompt.alert.window.contentView)
        for view in stack.arrangedSubviews {
            let frame = windowContent.convert(view.bounds, from: view)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(windowContent.bounds.contains(frame), "Recovery control is clipped: \(type(of: view))")
        }
        let actions = try XCTUnwrap(stack.arrangedSubviews[1] as? NSStackView)
        XCTAssertEqual(actions.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }, ["Copy", "Save to File..."])
        let checkbox = try XCTUnwrap(stack.arrangedSubviews[2] as? NSButton)
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        checkbox.performClick(nil)
        XCTAssertTrue(prompt.alert.buttons[0].isEnabled)
        prompt.alert.buttons[0].performClick(nil)
        XCTAssertEqual(results, [true])
    }

    func testUnlockPromptShowsMetadataAndStripsUntrustedFormatting() {
        _ = NSApplication.shared
        let request = AtemUnlockApproval(deviceName: "Mac\nForged", bootId: "boot\u{202e}\u{200b}\n-1",
            requestTime: Date(timeIntervalSince1970: 1_760_000_000), lastUnlock: nil)
        let alert = AtemVerificationUI.unlockAlert(request)
        XCTAssertEqual(alert.buttons.map(\.title), ["Deny", "Deny and Revoke"])
        XCTAssertTrue(alert.informativeText.contains("Device: MacForged"))
        XCTAssertTrue(alert.informativeText.contains("Boot ID: boot-1"))
        XCTAssertTrue(alert.informativeText.contains("Requested:"))
        XCTAssertTrue(alert.informativeText.contains("Last unlock: Never"))
        XCTAssertFalse(alert.informativeText.contains("\u{202e}"))
        XCTAssertFalse(alert.informativeText.contains("\u{200b}"))
    }

    func testUnlockEmbedsTouchIDAndStartsWithoutAnApproveClick() throws {
        _ = NSApplication.shared
        let context = UnlockContext()
        context.localizedFallbackTitle = "Use Password"
        context.touchIDAuthenticationAllowableReuseDuration = 60
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
        defer { prompt.finish(.deny) }
        prompt.show()
        prompt.show()
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertTrue(prompt.authenticationView.context === context)
        XCTAssertTrue(prompt.authenticationView.window === prompt.alert.window)
        XCTAssertEqual(context.localizedFallbackTitle, "")
        XCTAssertEqual(context.touchIDAuthenticationAllowableReuseDuration, 0)
        XCTAssertTrue(context.policies.isEmpty)
        drainMainQueue()
        XCTAssertEqual(context.preflightPolicies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertEqual(context.policies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertEqual(context.reasons, ["unlock this Atem's storage key"])
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(prompt.alert.window.isVisible)
        let content = try XCTUnwrap(prompt.alert.window.contentView)
        for view in [prompt.authenticationView, prompt.status] + prompt.alert.buttons {
            let frame = content.convert(view.bounds, from: view)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertTrue(content.bounds.contains(frame), "Unlock control is clipped: \(type(of: view))")
        }
        let textSize = try XCTUnwrap(prompt.status.cell).cellSize(forBounds: prompt.status.bounds)
        XCTAssertLessThanOrEqual(textSize.height, prompt.status.bounds.height)
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(decisions, [.approve])
        XCTAssertEqual(context.invalidations, 1)
        XCTAssertFalse(prompt.alert.window.isVisible)
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(decisions, [.approve])
    }

    func testUnlockDenyAndRevokeRemainExplicitAndIgnoreLateBiometrics() {
        _ = NSApplication.shared
        for (index, decision) in [AtemUnlockDecision.deny, .revoke].enumerated() {
            let context = UnlockContext()
            var decisions: [AtemUnlockDecision] = []
            let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
            prompt.show()
            drainMainQueue()
            prompt.alert.buttons[index].performClick(nil)
            XCTAssertEqual(decisions, [decision])
            XCTAssertEqual(context.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
            context.replies[0](true, nil)
            drainMainQueue()
            XCTAssertEqual(decisions, [decision])
        }
    }

    func testUnlockCancellationBeforeDisplayCallbackNeverStartsBiometrics() {
        _ = NSApplication.shared
        let context = UnlockContext()
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
        prompt.show()
        prompt.finish(.deny)
        drainMainQueue()
        XCTAssertEqual(decisions, [.deny])
        XCTAssertTrue(context.preflightPolicies.isEmpty)
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertEqual(context.invalidations, 1)
        XCTAssertFalse(prompt.alert.window.isVisible)
    }

    func testUnlockWindowCloseDeniesOnceAndIgnoresLateBiometrics() {
        _ = NSApplication.shared
        let context = UnlockContext()
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
        prompt.show()
        drainMainQueue()
        prompt.alert.window.close()
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(decisions, [.deny])
        XCTAssertEqual(context.invalidations, 1)
        XCTAssertFalse(prompt.alert.window.isVisible)
    }

    func testQueuedBiometricSuccessCannotOverrideCancellation() {
        _ = NSApplication.shared
        let context = UnlockContext()
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
        prompt.show()
        drainMainQueue()
        context.replies[0](true, nil)
        prompt.finish(.deny)
        drainMainQueue()
        XCTAssertEqual(decisions, [.deny])
        XCTAssertEqual(context.invalidations, 1)
    }

    func testBackgroundBiometricReplyCompletesOnTheMainThread() {
        _ = NSApplication.shared
        let context = UnlockContext()
        let completed = expectation(description: "biometric approval delivered on main")
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decision in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(decision, .approve)
            completed.fulfill()
        }
        prompt.show()
        drainMainQueue()
        let reply = context.replies[0]
        DispatchQueue.global().async { reply(true, nil) }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(context.invalidations, 1)
        XCTAssertFalse(prompt.alert.window.isVisible)
    }

    func testUnavailableTouchIDShowsGuidanceWithoutEvaluatingAnotherPolicy() throws {
        _ = NSApplication.shared
        let context = UnlockContext()
        context.available = false
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
        prompt.show()
        drainMainQueue()
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertTrue(prompt.status.stringValue.contains("Touch ID is unavailable"))
        XCTAssertEqual(context.preflightPolicies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertTrue(context.policies.isEmpty)
        let textSize = try XCTUnwrap(prompt.status.cell).cellSize(forBounds: prompt.status.bounds)
        XCTAssertLessThanOrEqual(textSize.height, prompt.status.bounds.height)
        prompt.alert.buttons[0].performClick(nil)
        XCTAssertEqual(decisions, [.deny])
    }

    func testFailedOrCancelledBiometricsNeverApproveOrRevoke() {
        _ = NSApplication.shared
        for code in [LAError.Code.authenticationFailed, .userCancel, .systemCancel, .userFallback, .biometryLockout] {
            let context = UnlockContext()
            var decisions: [AtemUnlockDecision] = []
            let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
            prompt.show()
            drainMainQueue()
            context.replies[0](false, NSError(domain: LAError.errorDomain, code: code.rawValue))
            drainMainQueue()
            XCTAssertEqual(decisions, [.deny])
            XCTAssertEqual(context.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testUnlockRevokeButtonAndSinglePromptGate() throws {
        _ = NSApplication.shared
        let context = UnlockContext()
        var decisions: [AtemUnlockDecision] = []
        let cancel = AtemVerificationUI.unlock(unlockRequest, context: context) { decisions.append($0) }
        defer { cancel() }
        var verified: [Bool] = []
        let cancelOther = AtemVerificationUI.approve(AtemVerificationApproval(deviceName: "Other", safetyCode: "000 000")) { verified.append($0) }
        cancelOther()
        XCTAssertEqual(verified, [false])
        func revokeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Deny and Revoke" { return button }
            return view.subviews.compactMap { revokeButton(in: $0) }.first
        }
        let button = try XCTUnwrap(NSApp.windows.filter(\.isVisible).compactMap { window in
            window.contentView.flatMap { revokeButton(in: $0) }
        }.first)
        button.performClick(nil)
        XCTAssertEqual(decisions, [.revoke])
        cancel()
        XCTAssertEqual(decisions, [.revoke])
        let nextContext = UnlockContext()
        let cancelNext = AtemVerificationUI.unlock(unlockRequest, context: nextContext) { decisions.append($0) }
        cancelNext()
        XCTAssertEqual(decisions, [.revoke, .deny])
        drainMainQueue()
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertTrue(nextContext.policies.isEmpty)
    }
}
