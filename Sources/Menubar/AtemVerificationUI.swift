import AppKit
import LocalAuthentication

enum AtemVerificationUI {
    static func approve(_ request: AtemVerificationApproval, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Verify Atem Safety Code"
        alert.informativeText = "Device: \(request.deviceName)\n\n\(request.safetyCode)\n\nCompare this code with the code shown by atem pair. Approve only when both codes match."
        alert.addButton(withTitle: "Codes Match")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { completion(false); return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            let unavailable = NSAlert()
            unavailable.messageText = "Touch ID Is Required"
            unavailable.informativeText = "Unlock this Mac and enable Touch ID to approve device verification."
            unavailable.runModal()
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "verify this Atem's safety code") { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func saveRecovery(_ text: String, completion: @escaping (Bool) -> Void) {
        completion(AtemRecoveryKitPrompt(text: text).run())
    }
}

private final class AtemRecoveryKitPrompt: NSObject {
    private let text: String
    private let alert = NSAlert()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(text: String) { self.text = text }

    func run() -> Bool {
        alert.messageText = "Save Your Astation Recovery Kit"
        alert.informativeText = "Save this kit somewhere off this Mac, such as a password manager. The recovery key is separate from your account encryption key. Save it before verifying your first device."
        alert.addButton(withTitle: "Continue Verification")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let content = NSTextField(wrappingLabelWithString: text)
        content.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.isSelectable = true
        content.widthAnchor.constraint(equalToConstant: 450).isActive = true
        stack.addArrangedSubview(content)
        let actions = NSStackView()
        actions.addArrangedSubview(NSButton(title: "Copy", target: self, action: #selector(copyKit)))
        actions.addArrangedSubview(NSButton(title: "Save to File...", target: self, action: #selector(saveKit)))
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(NSButton(
            checkboxWithTitle: "I've saved this recovery kit somewhere safe", target: self, action: #selector(confirmSaved(_:))
        ))
        status.widthAnchor.constraint(equalToConstant: 450).isActive = true
        stack.addArrangedSubview(status)
        alert.accessoryView = stack
        return alert.runModal() == .alertFirstButtonReturn && alert.buttons[0].isEnabled
    }

    @objc private func confirmSaved(_ sender: NSButton) {
        alert.buttons[0].isEnabled = sender.state == .on
    }

    @objc private func copyKit() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status.stringValue = "Copied. Save it in your password manager before continuing."
    }

    @objc private func saveKit() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Astation Recovery Kit.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RecoveryKit.save(text, to: url)
            status.stringValue = "Recovery kit saved. Keep an off-Mac copy."
        } catch { status.stringValue = "Couldn't save the recovery kit: \(error.localizedDescription)" }
    }
}
