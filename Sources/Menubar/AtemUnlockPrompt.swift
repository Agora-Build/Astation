import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

final class AtemUnlockPrompt: NSObject, NSWindowDelegate {
    let alert: NSAlert
    let authenticationView: LAAuthenticationView
    let status = NSTextField(wrappingLabelWithString:
        "Use Touch ID to approve this device's unlock request. Deny and Revoke requires the device to verify again.")
    private let context: LAContext
    private var completion: ((AtemUnlockDecision) -> Void)?
    private var shown = false
    var isActive: Bool { completion != nil }

    init(request: AtemUnlockApproval, context: LAContext, completion: @escaping (AtemUnlockDecision) -> Void) {
        alert = AtemVerificationUI.unlockAlert(request)
        self.context = context
        self.completion = completion
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authenticationView = LAAuthenticationView(context: context, controlSize: .regular)
        super.init()

        let size = authenticationView.fittingSize
        authenticationView.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        authenticationView.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        status.font = .systemFont(ofSize: 13)
        status.preferredMaxLayoutWidth = 350
        status.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let row = NSStackView(views: [authenticationView, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.setFrameSize(row.fittingSize)
        alert.accessoryView = row
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
