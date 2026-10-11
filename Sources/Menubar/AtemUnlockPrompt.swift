import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

final class AtemUnlockPrompt: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let authenticationView: LAAuthenticationView
    let status = NSTextField(wrappingLabelWithString:
        "Place your finger on Touch ID to unlock this device's storage key.")
    private let context: LAContext
    private var completion: ((AtemUnlockDecision) -> Void)?
    private var shown = false
    var isActive: Bool { completion != nil }

    init(request: AtemUnlockApproval, context: LAContext, completion: @escaping (AtemUnlockDecision) -> Void) {
        alert = AtemVerificationUI.unlockAlert()
        self.context = context
        self.completion = completion
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authenticationView = LAAuthenticationView(context: context, controlSize: .regular)
        super.init()

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
            AtemAuthenticationLayout.touchID(authenticationView, status: status),
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
        guard isActive else { return }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            status.stringValue = "Touch ID is unavailable. Unlock this Mac and enable Touch ID, then retry the Atem command. This request cannot be approved."
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "unlock this Atem's storage key") { [weak self] accepted, _ in
            DispatchQueue.main.async { self?.finish(accepted ? .approve : .deny) }
        }
    }

    @objc private func deny() { finish(.deny) }
    @objc private func revoke() { finish(.revoke) }

    func finish(_ decision: AtemUnlockDecision) {
        guard let callback = completion else { return }
        completion = nil
        context.invalidate()
        alert.window.close()
        callback(decision)
    }

    func windowWillClose(_ notification: Notification) { finish(.deny) }
}
