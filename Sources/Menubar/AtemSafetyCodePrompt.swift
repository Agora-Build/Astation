import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

final class AtemSafetyCodePrompt: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let safetyCode: NSTextField
    let authenticationView: LAAuthenticationView
    let passwordButton = NSButton(title: "Use Mac Password...", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString:
        "After comparing the codes, click Codes Match, then use Touch ID or your Mac password.")
    private let authentication: AtemOwnerAuthentication
    private var completion: ((Bool) -> Void)?
    private var shown = false
    private var codesMatched = false
    private var usingPassword = false
    var isActive: Bool { completion != nil }

    init(request: AtemVerificationApproval, context: LAContext,
         makePasswordContext: @escaping () -> LAContext = { LAContext() }, completion: @escaping (Bool) -> Void) {
        alert = AtemVerificationUI.verificationAlert()
        safetyCode = NSTextField(labelWithString: request.safetyCode)
        authentication = AtemOwnerAuthentication(context: context, makePasswordContext: makePasswordContext)
        self.completion = completion
        authenticationView = LAAuthenticationView(context: context, controlSize: .regular)
        super.init()
        passwordButton.target = self
        passwordButton.action = #selector(usePassword)
        passwordButton.isEnabled = false

        safetyCode.font = .monospacedSystemFont(ofSize: 26, weight: .semibold)
        safetyCode.alignment = .center
        safetyCode.isSelectable = true
        safetyCode.setAccessibilityLabel("Atem safety code")
        alert.accessoryView = AtemAuthenticationLayout.content([
            AtemAuthenticationLayout.details([("Device", AtemVerificationUI.displayText(request.deviceName))]),
            AtemAuthenticationLayout.code(safetyCode),
            AtemAuthenticationLayout.touchID(authenticationView, status: status, passwordButton: passwordButton),
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
        passwordButton.isEnabled = true
        status.stringValue = "Use Touch ID to verify this device, or choose Use Mac Password."
        // Keep comparison explicit; evaluating on presentation could accept an incidental match.
        DispatchQueue.main.async { [weak self] in self?.authenticate() }
    }

    private func authenticate() {
        guard isActive, codesMatched, !usingPassword else { return }
        if !authentication.biometrics(reason: "verify this Atem's safety code", completion: { [weak self] accepted in
            guard let self, self.isActive else { return }
            if accepted { self.finish(true) }
            else { self.status.stringValue = "Touch ID did not complete. Choose Use Mac Password to continue, or Deny." }
        }) {
            status.stringValue = "Touch ID is unavailable. Choose Use Mac Password to verify with your Mac login password."
        }
    }

    @objc private func usePassword() {
        guard isActive, shown, codesMatched, passwordButton.isEnabled else { return }
        usingPassword = true
        passwordButton.isEnabled = false
        status.stringValue = "Authenticate in the macOS dialog. Choose Use Password if Touch ID is offered."
        if !authentication.password(reason: "verify this Atem's safety code", completion: { [weak self] accepted in
            guard let self, self.isActive else { return }
            if accepted { self.finish(true) }
            else { self.passwordFailed() }
        }) {
            passwordFailed()
        }
    }

    private func passwordFailed() {
        passwordButton.isEnabled = true
        status.stringValue = "Authentication did not complete. Choose Use Mac Password to retry, or Deny."
    }

    @objc private func deny() { finish(false) }

    func finish(_ accepted: Bool) {
        guard let callback = completion else { return }
        completion = nil
        authentication.cancel()
        alert.window.close()
        callback(accepted && codesMatched)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}
