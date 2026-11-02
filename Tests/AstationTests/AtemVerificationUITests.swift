import AppKit
import LocalAuthentication
import XCTest
@testable import Menubar

final class AtemVerificationUITests: XCTestCase {
    private final class SavePanel: NSSavePanel {
        var destination: URL?
        var presentations = 0
        var presentedFor: NSWindow?
        var reply: ((NSApplication.ModalResponse) -> Void)?
        override var url: URL? { destination }

        override func beginSheetModal(for window: NSWindow,
                                      completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
            presentations += 1
            presentedFor = window
            reply = handler
        }

        override func cancel(_ sender: Any?) { reply?(.cancel) }
    }

    private final class AuthenticationContext: LAContext, @unchecked Sendable {
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

    private var verificationRequest: AtemVerificationApproval {
        AtemVerificationApproval(deviceName: "Test Device", safetyCode: "ABCD-EFGH-IJKL")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue callbacks delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { button(title, in: $0) }.first
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

    func testPeerCancellationDismissesAlertAndIgnoresLateCompletion() {
        var results: [Bool] = []
        let prompt = dialog { results.append($0) }
        prompt.show()
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

    func testRecoveryPromptStaysInteractiveWhenCallerDiscardsCancellationHandle() throws {
        _ = NSApplication.shared
        var results: [Bool] = []
        _ = AtemVerificationUI.saveRecovery("synthetic recovery kit") { results.append($0) }
        let window = try XCTUnwrap(NSApp.windows.first { window in
            window.isVisible && window.contentView.map {
                textFields(in: $0).contains { $0.stringValue == "synthetic recovery kit" }
            } == true
        })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let checkbox = try XCTUnwrap(button("I've saved this recovery kit somewhere safe", in: content))
        let next = try XCTUnwrap(button("Continue Verification", in: content))
        checkbox.performClick(nil)
        XCTAssertTrue(next.isEnabled)
        next.performClick(nil)
        XCTAssertEqual(results, [true])
        XCTAssertFalse(window.isVisible)
        var nextResults: [Bool] = []
        let cancelNext = AtemVerificationUI.saveRecovery("next synthetic kit") { nextResults.append($0) }
        XCTAssertTrue(nextResults.isEmpty)
        cancelNext()
        XCTAssertEqual(nextResults, [false])
    }

    func testRecoverySaveSheetWritesPrivateFileAndStillRequiresUserConfirmation() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = SavePanel()
        let destination = directory.appendingPathComponent("synthetic-kit.txt")
        panel.destination = destination
        var results: [Bool] = []
        let prompt = AtemRecoveryKitPrompt(text: "synthetic kit", makeSavePanel: { panel }) { results.append($0) }
        prompt.show()
        defer { prompt.cancel() }
        let content = try XCTUnwrap(prompt.alert.accessoryView)
        let save = try XCTUnwrap(button("Save to File...", in: content))
        save.performClick(nil)
        save.performClick(nil)
        XCTAssertEqual(panel.presentations, 1)
        XCTAssertTrue(panel.presentedFor === prompt.alert.window)
        XCTAssertEqual(panel.nameFieldStringValue, "Astation Recovery Kit.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        panel.reply?(.OK)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "synthetic kit")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(textFields(in: content).contains { $0.stringValue == "Recovery kit saved. Keep an off-Mac copy." })
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        let checkbox = try XCTUnwrap(button("I've saved this recovery kit somewhere safe", in: content))
        checkbox.performClick(nil)
        XCTAssertTrue(prompt.alert.buttons[0].isEnabled)
        prompt.alert.buttons[0].performClick(nil)
        XCTAssertEqual(results, [true])
    }

    func testCancelledOrFailedSaveDoesNotConfirmRecoveryAndCanRetry() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let panel = SavePanel()
        panel.destination = directory.appendingPathComponent("missing/synthetic-kit.txt")
        var results: [Bool] = []
        let prompt = AtemRecoveryKitPrompt(text: "synthetic kit", makeSavePanel: { panel }) { results.append($0) }
        prompt.show()
        defer { prompt.cancel() }
        let content = try XCTUnwrap(prompt.alert.accessoryView)
        let save = try XCTUnwrap(button("Save to File...", in: content))
        save.performClick(nil)
        panel.reply?(.cancel)
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertTrue(results.isEmpty)
        save.performClick(nil)
        XCTAssertEqual(panel.presentations, 2)
        panel.reply?(.OK)
        XCTAssertTrue(textFields(in: content).contains { $0.stringValue.hasPrefix("Couldn't save the recovery kit:") })
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        save.performClick(nil)
        XCTAssertEqual(panel.presentations, 3)
    }

    func testRealRecoverySavePanelOpensAsSheetAndCanBeCancelled() throws {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        var results: [Bool] = []
        let prompt = AtemRecoveryKitPrompt(text: "synthetic kit", makeSavePanel: { panel }) { results.append($0) }
        prompt.show()
        defer { prompt.cancel() }
        let save = try XCTUnwrap(button("Save to File...", in: XCTUnwrap(prompt.alert.accessoryView)))
        save.performClick(nil)
        XCTAssertTrue(prompt.alert.window.attachedSheet === panel)
        XCTAssertTrue(panel.sheetParent === prompt.alert.window)
        panel.cancel(nil)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
    }

    func testRecoveryDismissalCancelsSaveSheetAndIgnoresLateSaveReply() throws {
        _ = NSApplication.shared
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let panel = SavePanel()
        panel.destination = destination
        var results: [Bool] = []
        let prompt = AtemRecoveryKitPrompt(text: "synthetic kit", makeSavePanel: { panel }) { results.append($0) }
        prompt.show()
        let save = try XCTUnwrap(button("Save to File...", in: XCTUnwrap(prompt.alert.accessoryView)))
        save.performClick(nil)
        prompt.cancel()
        panel.reply?(.OK)
        XCTAssertEqual(results, [false])
        XCTAssertFalse(prompt.alert.window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        prompt.cancel()
        XCTAssertEqual(results, [false])
    }

    func testSafetyCodeAndTouchIDStayInOneWindowAndWaitForCodeConfirmation() throws {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        context.localizedFallbackTitle = "Use Password"
        context.touchIDAuthenticationAllowableReuseDuration = 60
        let request = AtemVerificationApproval(deviceName: "Mac\nForged\u{202e}\u{200b}", safetyCode: verificationRequest.safetyCode)
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: request, context: context) { results.append($0) }
        defer { prompt.finish(false) }
        prompt.show()
        prompt.show()
        drainMainQueue()
        XCTAssertTrue(context.preflightPolicies.isEmpty)
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(textFields(in: try XCTUnwrap(prompt.alert.accessoryView)).contains { $0.stringValue == "MacForged" })
        XCTAssertEqual(prompt.alert.buttons.map(\.title), ["Codes Match", "Deny"])
        XCTAssertEqual(prompt.safetyCode.stringValue, request.safetyCode)
        XCTAssertTrue(prompt.safetyCode.isSelectable)
        XCTAssertEqual(prompt.safetyCode.font?.pointSize, 26)
        XCTAssertTrue(prompt.authenticationView.context === context)
        XCTAssertTrue(prompt.authenticationView.window === prompt.alert.window)
        XCTAssertEqual(context.localizedFallbackTitle, "")
        XCTAssertEqual(context.touchIDAuthenticationAllowableReuseDuration, 0)
        let content = try XCTUnwrap(prompt.alert.window.contentView)
        for view in [prompt.safetyCode, prompt.authenticationView, prompt.status, prompt.passwordButton] + prompt.alert.buttons {
            let frame = content.convert(view.bounds, from: view)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertTrue(content.bounds.contains(frame), "Verification control is clipped: \(type(of: view))")
        }
        prompt.alert.buttons[0].performClick(nil)
        prompt.alert.buttons[0].performClick(nil)
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertTrue(context.policies.isEmpty)
        drainMainQueue()
        XCTAssertEqual(context.preflightPolicies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertEqual(context.policies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertEqual(context.reasons, ["verify this Atem's safety code"])
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertEqual(prompt.safetyCode.stringValue, request.safetyCode)
        XCTAssertTrue(prompt.alert.buttons[1].isEnabled)
        XCTAssertTrue(results.isEmpty)
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [true])
        XCTAssertEqual(context.invalidations, 1)
        XCTAssertFalse(prompt.alert.window.isVisible)
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [true])
    }

    func testSafetyCodeDenialBeforeConfirmationNeverStartsBiometrics() {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
        prompt.show()
        prompt.alert.buttons[1].performClick(nil)
        drainMainQueue()
        XCTAssertEqual(results, [false])
        XCTAssertTrue(context.preflightPolicies.isEmpty)
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertEqual(context.invalidations, 1)
    }

    func testSafetyCodeApprovalCannotSkipCodeComparison() {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
        prompt.show()
        prompt.finish(true)
        XCTAssertEqual(results, [false])
        XCTAssertTrue(context.policies.isEmpty)
    }

    func testSafetyCodeCancellationAfterConfirmationPreventsQueuedBiometrics() {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
        prompt.show()
        prompt.alert.buttons[0].performClick(nil)
        prompt.finish(false)
        drainMainQueue()
        XCTAssertEqual(results, [false])
        XCTAssertTrue(context.preflightPolicies.isEmpty)
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertEqual(context.invalidations, 1)
    }

    func testSafetyCodeDenialCloseAndCancellationIgnoreBiometricSuccess() {
        _ = NSApplication.shared
        for action in 0..<3 {
            let context = AuthenticationContext()
            var results: [Bool] = []
            let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
            prompt.show()
            prompt.alert.buttons[0].performClick(nil)
            drainMainQueue()
            if action == 0 { prompt.alert.buttons[1].performClick(nil) }
            if action == 1 { prompt.alert.window.close() }
            if action == 2 {
                context.replies[0](true, nil)
                prompt.finish(false)
            }
            context.replies[0](true, nil)
            drainMainQueue()
            XCTAssertEqual(results, [false])
            XCTAssertEqual(context.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testSafetyCodeUnavailableTouchIDKeepsTheCodeVisibleAndCannotApprove() throws {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        context.available = false
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
        defer { prompt.finish(false) }
        prompt.show()
        drainMainQueue()
        XCTAssertTrue(context.preflightPolicies.isEmpty)
        prompt.alert.buttons[0].performClick(nil)
        drainMainQueue()
        XCTAssertEqual(context.preflightPolicies, [.deviceOwnerAuthenticationWithBiometrics])
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertEqual(prompt.safetyCode.stringValue, verificationRequest.safetyCode)
        XCTAssertTrue(prompt.status.stringValue.contains("Touch ID is unavailable"))
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertTrue(results.isEmpty)
        let textSize = try XCTUnwrap(prompt.status.cell).cellSize(forBounds: prompt.status.bounds)
        XCTAssertLessThanOrEqual(textSize.height, prompt.status.bounds.height)
        prompt.alert.buttons[1].performClick(nil)
        XCTAssertEqual(results, [false])
    }

    func testFailedSafetyCodeBiometricsNeverApprove() {
        _ = NSApplication.shared
        for code in [LAError.Code.authenticationFailed, .userCancel, .systemCancel, .userFallback, .biometryLockout] {
            let context = AuthenticationContext()
            var results: [Bool] = []
            let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { results.append($0) }
            prompt.show()
            prompt.alert.buttons[0].performClick(nil)
            drainMainQueue()
            context.replies[0](false, NSError(domain: LAError.errorDomain, code: code.rawValue))
            drainMainQueue()
            XCTAssertTrue(results.isEmpty)
            XCTAssertTrue(prompt.isActive)
            XCTAssertTrue(prompt.passwordButton.isEnabled)
            XCTAssertTrue(prompt.status.stringValue.contains("Use Mac Password"))
            prompt.alert.buttons[1].performClick(nil)
            XCTAssertEqual(results, [false])
            XCTAssertEqual(context.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testSafetyCodeBackgroundBiometricsCompleteOnMain() {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        let completed = expectation(description: "verification approval delivered on main")
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: context) { accepted in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(accepted)
            completed.fulfill()
        }
        prompt.show()
        prompt.alert.buttons[0].performClick(nil)
        drainMainQueue()
        let reply = context.replies[0]
        DispatchQueue.global().async { reply(true, nil) }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(context.invalidations, 1)
    }

    func testSafetyCodePromptGateSurvivesCancellationAndLatePreviousApproval() throws {
        _ = NSApplication.shared
        let context = AuthenticationContext()
        var results: [Bool] = []
        let cancel = AtemVerificationUI.approve(verificationRequest, context: context) { results.append($0) }
        defer { cancel() }
        func matchButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Codes Match" { return button }
            return view.subviews.compactMap { matchButton(in: $0) }.first
        }
        let button = try XCTUnwrap(NSApp.windows.filter(\.isVisible).compactMap { window in
            window.contentView.flatMap { matchButton(in: $0) }
        }.first)
        button.performClick(nil)
        drainMainQueue()
        var recovery: [Bool] = []
        let cancelRecovery = AtemVerificationUI.saveRecovery("synthetic") { recovery.append($0) }
        cancelRecovery()
        XCTAssertEqual(recovery, [false])
        cancel()
        let nextContext = AuthenticationContext()
        var nextResults: [Bool] = []
        let cancelNext = AtemVerificationUI.approve(verificationRequest, context: nextContext) { nextResults.append($0) }
        defer { cancelNext() }
        context.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [false])
        XCTAssertTrue(nextResults.isEmpty)
        var unlock: [AtemUnlockDecision] = []
        let cancelUnlock = AtemVerificationUI.unlock(unlockRequest, context: AuthenticationContext()) { unlock.append($0) }
        cancelUnlock()
        XCTAssertEqual(unlock, [.deny])
        XCTAssertTrue(nextContext.policies.isEmpty)
        cancelNext()
        XCTAssertEqual(nextResults, [false])
    }

    func testUnlockPromptShowsMetadataAndStripsUntrustedFormatting() {
        _ = NSApplication.shared
        let request = AtemUnlockApproval(deviceName: "Mac\nForged", bootId: "boot\u{202e}\u{200b}\n-1",
            requestTime: Date(timeIntervalSince1970: 1_760_000_000), lastUnlock: nil)
        let prompt = AtemUnlockPrompt(request: request, context: AuthenticationContext()) { _ in }
        defer { prompt.finish(.deny) }
        let alert = prompt.alert
        XCTAssertEqual(alert.buttons.map(\.title), ["Deny", "Deny and Revoke"])
        let fields = textFields(in: alert.accessoryView!)
        let values = fields.map(\.stringValue)
        XCTAssertTrue(values.contains("MacForged"))
        XCTAssertTrue(values.contains("boot-1"))
        XCTAssertTrue(values.contains("Requested"))
        XCTAssertTrue(values.contains("Last unlock"))
        XCTAssertTrue(values.contains("Never"))
        XCTAssertFalse(values.contains { $0.contains("\u{202e}") || $0.contains("\u{200b}") })
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
    }

    func testLongDeviceDetailsStayAlignedAndVisibleInLightAndDarkAppearance() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let request = AtemUnlockApproval(deviceName: String(repeating: "Remote Mac ", count: 25),
                bootId: String(repeating: "0123456789abcdef", count: 20), requestTime: Date(), lastUnlock: Date())
            let prompt = AtemUnlockPrompt(request: request, context: AuthenticationContext()) { _ in }
            defer { prompt.finish(.deny) }
            prompt.alert.window.appearance = NSAppearance(named: appearance)
            prompt.show()
            let accessory = try XCTUnwrap(prompt.alert.accessoryView as? NSStackView)
            let content = try XCTUnwrap(prompt.alert.window.contentView)
            let fields = textFields(in: accessory)
            for field in fields {
                let frame = content.convert(field.bounds, from: field)
                XCTAssertTrue(content.bounds.contains(frame), "Device detail is clipped: \(field.stringValue)")
                let textSize = try XCTUnwrap(field.cell).cellSize(forBounds: field.bounds)
                XCTAssertLessThanOrEqual(textSize.height, field.bounds.height + 1)
            }
            let values = fields.filter { ["Remote Mac", "0123456789abcdef"].contains(where: $0.stringValue.hasPrefix) }
            XCTAssertEqual(values.count, 2)
            let origins = values.map { content.convert($0.bounds, from: $0).minX }
            XCTAssertEqual(origins.first, origins.last)
            let cards = accessory.arrangedSubviews.dropLast()
            XCTAssertEqual(Set(cards.map { $0.frame.minX }).count, 1)
            XCTAssertEqual(Set(cards.map { $0.frame.width }).count, 1)
        }
    }

    func testUnlockEmbedsTouchIDAndStartsWithoutAnApproveClick() throws {
        _ = NSApplication.shared
        let context = AuthenticationContext()
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
        for view in [prompt.authenticationView, prompt.status, prompt.passwordButton] + prompt.alert.buttons {
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
            let context = AuthenticationContext()
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
        let context = AuthenticationContext()
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
        let context = AuthenticationContext()
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
        let context = AuthenticationContext()
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
        let context = AuthenticationContext()
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
        let context = AuthenticationContext()
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
            let context = AuthenticationContext()
            var decisions: [AtemUnlockDecision] = []
            let prompt = AtemUnlockPrompt(request: unlockRequest, context: context) { decisions.append($0) }
            prompt.show()
            drainMainQueue()
            context.replies[0](false, NSError(domain: LAError.errorDomain, code: code.rawValue))
            drainMainQueue()
            XCTAssertTrue(decisions.isEmpty)
            XCTAssertTrue(prompt.isActive)
            XCTAssertTrue(prompt.passwordButton.isEnabled)
            XCTAssertTrue(prompt.status.stringValue.contains("Use Mac Password"))
            prompt.alert.buttons[0].performClick(nil)
            XCTAssertEqual(decisions, [.deny])
            XCTAssertEqual(context.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testPasswordVerificationRequiresCodesMatchAndSkipsQueuedBiometrics() throws {
        _ = NSApplication.shared
        let biometric = AuthenticationContext(), password = AuthenticationContext()
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: biometric,
            makePasswordContext: { password }) { results.append($0) }
        prompt.show()
        XCTAssertFalse(prompt.passwordButton.isEnabled)
        prompt.passwordButton.performClick(nil)
        XCTAssertTrue(password.policies.isEmpty)
        prompt.alert.buttons[0].performClick(nil)
        prompt.passwordButton.performClick(nil)
        prompt.passwordButton.performClick(nil)
        drainMainQueue()
        XCTAssertTrue(biometric.policies.isEmpty)
        XCTAssertEqual(biometric.invalidations, 1)
        XCTAssertEqual(password.policies, [.deviceOwnerAuthentication])
        XCTAssertEqual(password.localizedFallbackTitle, "Use Password...")
        XCTAssertEqual(password.touchIDAuthenticationAllowableReuseDuration, 0)
        XCTAssertFalse(prompt.authenticationView.context === password)
        XCTAssertTrue(prompt.alert.window.isVisible)
        XCTAssertEqual(prompt.safetyCode.stringValue, verificationRequest.safetyCode)
        let content = try XCTUnwrap(prompt.alert.window.contentView)
        XCTAssertTrue(content.bounds.contains(content.convert(prompt.passwordButton.bounds, from: prompt.passwordButton)))
        password.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [true])
        XCTAssertEqual(password.invalidations, 1)
    }

    func testSwitchToPasswordIgnoresAlreadyQueuedBiometricSuccess() {
        _ = NSApplication.shared
        let biometric = AuthenticationContext(), password = AuthenticationContext()
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: biometric,
            makePasswordContext: { password }) { results.append($0) }
        prompt.show()
        prompt.alert.buttons[0].performClick(nil)
        drainMainQueue()
        biometric.replies[0](true, nil)
        prompt.passwordButton.performClick(nil)
        drainMainQueue()
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(prompt.isActive)
        XCTAssertEqual(biometric.invalidations, 1)
        password.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [true])
    }

    func testPasswordVerificationRetryIgnoresPreviousAttemptReplies() {
        _ = NSApplication.shared
        let biometric = AuthenticationContext(), first = AuthenticationContext(), second = AuthenticationContext()
        biometric.available = false
        var contexts = [first, second]
        var results: [Bool] = []
        let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: biometric,
            makePasswordContext: { contexts.removeFirst() }) { results.append($0) }
        prompt.show()
        prompt.alert.buttons[0].performClick(nil)
        drainMainQueue()
        prompt.passwordButton.performClick(nil)
        first.replies[0](false, NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue))
        drainMainQueue()
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(prompt.passwordButton.isEnabled)
        prompt.passwordButton.performClick(nil)
        first.replies[0](true, nil)
        drainMainQueue()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(first.invalidations, 1)
        second.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(results, [true])
        XCTAssertEqual(second.invalidations, 1)
    }

    func testPasswordUnlockWorksWithUnavailableTouchID() {
        _ = NSApplication.shared
        let biometric = AuthenticationContext(), password = AuthenticationContext()
        biometric.available = false
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: biometric,
            makePasswordContext: { password }) { decisions.append($0) }
        prompt.show()
        drainMainQueue()
        XCTAssertTrue(prompt.status.stringValue.contains("Touch ID is unavailable"))
        prompt.passwordButton.performClick(nil)
        XCTAssertEqual(password.preflightPolicies, [.deviceOwnerAuthentication])
        XCTAssertEqual(password.policies, [.deviceOwnerAuthentication])
        XCTAssertEqual(password.reasons, ["unlock this Atem's storage key"])
        XCTAssertTrue(decisions.isEmpty)
        password.replies[0](true, nil)
        drainMainQueue()
        XCTAssertEqual(decisions, [.approve])
        XCTAssertEqual(biometric.invalidations, 1)
        XCTAssertEqual(password.invalidations, 1)
    }

    func testPasswordUnlockDenyRevokeAndPeerCancellationIgnoreQueuedSuccess() {
        _ = NSApplication.shared
        for action in 0..<3 {
            let biometric = AuthenticationContext(), password = AuthenticationContext()
            var decisions: [AtemUnlockDecision] = []
            let prompt = AtemUnlockPrompt(request: unlockRequest, context: biometric,
                makePasswordContext: { password }) { decisions.append($0) }
            prompt.show()
            drainMainQueue()
            prompt.passwordButton.performClick(nil)
            password.replies[0](true, nil)
            if action < 2 { prompt.alert.buttons[action].performClick(nil) }
            else { prompt.finish(.deny) }
            biometric.replies[0](true, nil)
            drainMainQueue()
            XCTAssertEqual(decisions, [action == 1 ? .revoke : .deny])
            XCTAssertEqual(password.invalidations, 1)
            XCTAssertEqual(biometric.invalidations, 1)
            XCTAssertFalse(prompt.alert.window.isVisible)
        }
    }

    func testUnavailablePasswordAuthenticationNeverApproves() {
        _ = NSApplication.shared
        let biometric = AuthenticationContext(), password = AuthenticationContext()
        biometric.available = false
        password.available = false
        var decisions: [AtemUnlockDecision] = []
        let prompt = AtemUnlockPrompt(request: unlockRequest, context: biometric,
            makePasswordContext: { password }) { decisions.append($0) }
        prompt.show()
        prompt.passwordButton.performClick(nil)
        drainMainQueue()
        XCTAssertTrue(biometric.policies.isEmpty)
        XCTAssertTrue(password.policies.isEmpty)
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(prompt.passwordButton.isEnabled)
        prompt.alert.window.close()
        XCTAssertEqual(decisions, [.deny])
    }

    func testPasswordVerificationCancellationCannotApprove() {
        _ = NSApplication.shared
        for closeWindow in [false, true] {
            let biometric = AuthenticationContext(), password = AuthenticationContext()
            var results: [Bool] = []
            let prompt = AtemSafetyCodePrompt(request: verificationRequest, context: biometric,
                makePasswordContext: { password }) { results.append($0) }
            prompt.show()
            prompt.alert.buttons[0].performClick(nil)
            prompt.passwordButton.performClick(nil)
            password.replies[0](true, nil)
            if closeWindow { prompt.alert.window.close() }
            else { prompt.finish(false) }
            drainMainQueue()
            XCTAssertEqual(results, [false])
            XCTAssertEqual(password.invalidations, 1)
            XCTAssertTrue(biometric.policies.isEmpty)
        }
    }

    func testLocalCredentialAuthenticationOffersSystemPassword() {
        let context = AuthenticationContext()
        var results: [Bool] = []
        let cancel = LocalCredentialActions.deviceOwner(context: context, reason: "save a credential") { results.append($0) }
        XCTAssertEqual(context.preflightPolicies, [.deviceOwnerAuthentication])
        XCTAssertEqual(context.policies, [.deviceOwnerAuthentication])
        XCTAssertEqual(context.localizedFallbackTitle, "Use Password...")
        XCTAssertEqual(context.touchIDAuthenticationAllowableReuseDuration, 0)
        context.replies[0](false, nil)
        drainMainQueue()
        XCTAssertEqual(results, [false])
        cancel()
        XCTAssertEqual(context.invalidations, 1)
    }

    func testUnlockRevokeButtonAndSinglePromptGate() throws {
        _ = NSApplication.shared
        let context = AuthenticationContext()
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
        let nextContext = AuthenticationContext()
        let cancelNext = AtemVerificationUI.unlock(unlockRequest, context: nextContext) { decisions.append($0) }
        cancelNext()
        XCTAssertEqual(decisions, [.revoke, .deny])
        drainMainQueue()
        XCTAssertTrue(context.policies.isEmpty)
        XCTAssertTrue(nextContext.policies.isEmpty)
    }
}
