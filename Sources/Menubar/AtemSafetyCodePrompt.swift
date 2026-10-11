import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

final class AtemSafetyCodePrompt: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let safetyCode: NSTextField
    let authenticationView: LAAuthenticationView
    let status = NSTextField(wrappingLabelWithString:
        "After comparing the codes, click Codes Match to enable Touch ID.")
    private let context: LAContext
    private var completion: ((Bool) -> Void)?
    private var shown = false
    private var codesMatched = false
    var isActive: Bool { completion != nil }

    init(request: AtemVerificationApproval, context: LAContext, completion: @escaping (Bool) -> Void) {
        alert = AtemVerificationUI.verificationAlert()
        safetyCode = NSTextField(labelWithString: request.safetyCode)
        self.context = context
        self.completion = completion
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authenticationView = LAAuthenticationView(context: context, controlSize: .regular)
        super.init()

        safetyCode.font = .monospacedSystemFont(ofSize: 26, weight: .semibold)
        safetyCode.alignment = .center
        safetyCode.isSelectable = true
        safetyCode.setAccessibilityLabel("Atem safety code")
        alert.accessoryView = AtemAuthenticationLayout.content([
            AtemAuthenticationLayout.details([("Device", AtemVerificationUI.displayText(request.deviceName))]),
            AtemAuthenticationLayout.code(safetyCode),
            AtemAuthenticationLayout.touchID(authenticationView, status: status),
            AtemAuthenticationLayout.note("If the codes differ, choose Deny and pair again.")
        ])
    }

    func show() {
        guard isActive, !shown else { return }
        shown = true
        alert.layout()
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(confirmCodes)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(deny)
        alert.window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func confirmCodes() {
        guard isActive, shown, !codesMatched else { return }
        codesMatched = true
        alert.buttons[0].isEnabled = false
        status.stringValue = "Place your finger on Touch ID to verify this device."
        // Keep comparison explicit; evaluating on presentation could accept an incidental match.
        DispatchQueue.main.async { [weak self] in self?.authenticate() }
    }

    private func authenticate() {
        guard isActive, codesMatched else { return }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            status.stringValue = "Touch ID is unavailable. Unlock this Mac and enable Touch ID, then retry pairing. Verification cannot be approved."
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "verify this Atem's safety code") { [weak self] accepted, _ in
            DispatchQueue.main.async { self?.finish(accepted) }
        }
    }

    @objc private func deny() { finish(false) }

    func finish(_ accepted: Bool) {
        guard let callback = completion else { return }
        completion = nil
        context.invalidate()
        alert.window.close()
        callback(accepted && codesMatched)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}
