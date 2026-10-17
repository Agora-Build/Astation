import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

final class AtemUnlockPrompt: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let authenticationView: LAAuthenticationView
    let passwordButton = NSButton(title: "Use Mac Password...", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString:
        "Use Touch ID to unlock this device's storage key, or choose Use Mac Password.")
    private let authentication: AtemOwnerAuthentication
    private var completion: ((AtemUnlockDecision) -> Void)?
    private var shown = false
    private var usingPassword = false
    var isActive: Bool { completion != nil }

    init(request: AtemUnlockApproval, context: LAContext,
         makePasswordContext: @escaping () -> LAContext = { LAContext() }, completion: @escaping (AtemUnlockDecision) -> Void) {
        alert = AtemVerificationUI.unlockAlert()
        authentication = AtemOwnerAuthentication(context: context, makePasswordContext: makePasswordContext)
        self.completion = completion
        authenticationView = LAAuthenticationView(context: context, controlSize: .regular)
        super.init()
        passwordButton.target = self
        passwordButton.action = #selector(usePassword)

        let requested = DateFormatter.localizedString(from: request.requestTime, dateStyle: .medium, timeStyle: .medium)
        let last = request.lastUnlock.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium)
        } ?? "Never"
        alert.accessoryView = AtemAuthenticationLayout.content([
            AtemAuthenticationLayout.details([
                ("Device", AtemVerificationUI.displayText(request.deviceName)),
                ("Requested", requested),
                ("Last unlock", last),
                ("Boot ID", AtemVerificationUI.displayText(request.bootId))
            ]),
            AtemAuthenticationLayout.touchID(authenticationView, status: status, passwordButton: passwordButton),
            AtemAuthenticationLayout.note("Deny and Revoke removes this device's verification.")
        ])
    }

    func show() {
        guard isActive, !shown else { return }
        shown = true
        alert.layout()
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(deny)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(revoke)
        alert.window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        // The context renders into its embedded view only after the window is visible.
        DispatchQueue.main.async { [weak self] in self?.authenticate() }
    }

    private func authenticate() {
        guard isActive, !usingPassword else { return }
        if !authentication.biometrics(reason: "unlock this Atem's storage key", completion: { [weak self] accepted in
            guard let self, self.isActive else { return }
            if accepted { self.finish(.approve) }
            else { self.status.stringValue = "Touch ID did not complete. Choose Use Mac Password to continue, or Deny." }
        }) {
            status.stringValue = "Touch ID is unavailable. Choose Use Mac Password to unlock with your Mac login password."
        }
    }

    @objc private func usePassword() {
        guard isActive, shown, passwordButton.isEnabled else { return }
        usingPassword = true
        passwordButton.isEnabled = false
        status.stringValue = "Authenticate in the macOS dialog. Choose Use Password if Touch ID is offered."
        if !authentication.password(reason: "unlock this Atem's storage key", completion: { [weak self] accepted in
            guard let self, self.isActive else { return }
            if accepted { self.finish(.approve) }
            else { self.passwordFailed() }
        }) {
            passwordFailed()
        }
    }

    private func passwordFailed() {
        passwordButton.isEnabled = true
        status.stringValue = "Authentication did not complete. Choose Use Mac Password to retry, or Deny."
    }

    @objc private func deny() { finish(.deny) }
    @objc private func revoke() { finish(.revoke) }

    func finish(_ decision: AtemUnlockDecision) {
        guard let callback = completion else { return }
        completion = nil
        authentication.cancel()
        alert.window.close()
        callback(decision)
    }

    func windowWillClose(_ notification: Notification) { finish(.deny) }
}
