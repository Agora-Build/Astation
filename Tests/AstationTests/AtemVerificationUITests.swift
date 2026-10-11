import AppKit
import XCTest
@testable import Menubar

final class AtemVerificationUITests: XCTestCase {
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
        XCTAssertEqual(alert.buttons.map(\.title), ["Approve", "Deny", "Deny and Revoke"])
        XCTAssertTrue(alert.informativeText.contains("Device: MacForged"))
        XCTAssertTrue(alert.informativeText.contains("Boot ID: boot-1"))
        XCTAssertTrue(alert.informativeText.contains("Requested:"))
        XCTAssertTrue(alert.informativeText.contains("Last unlock: Never"))
        XCTAssertFalse(alert.informativeText.contains("\u{202e}"))
        XCTAssertFalse(alert.informativeText.contains("\u{200b}"))
    }

    func testUnlockRevokeButtonAndSinglePromptGate() throws {
        _ = NSApplication.shared
        let request = AtemUnlockApproval(deviceName: "Test Device", bootId: "test-boot", requestTime: Date(), lastUnlock: nil)
        var decisions: [AtemUnlockDecision] = []
        let cancel = AtemVerificationUI.unlock(request) { decisions.append($0) }
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
        let cancelNext = AtemVerificationUI.unlock(request) { decisions.append($0) }
        cancelNext()
        XCTAssertEqual(decisions, [.revoke, .deny])
    }
}
