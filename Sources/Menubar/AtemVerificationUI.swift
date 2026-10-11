import AppKit
import LocalAuthentication

enum AtemVerificationUI {
    private static var activePrompt: UUID?

    static func approve(_ request: AtemVerificationApproval, completion: @escaping (Bool) -> Void) -> (() -> Void) {
        guard activePrompt == nil else { completion(false); return {} }
        let id = UUID()
        activePrompt = id
        let alert = NSAlert()
        alert.messageText = "Verify Atem Safety Code"
        alert.informativeText = "Device: \(request.deviceName)\n\n\(request.safetyCode)\n\nCompare this code with the code shown by atem pair. Approve only when both codes match."
        alert.addButton(withTitle: "Codes Match")
        alert.addButton(withTitle: "Deny")
        let prompt = AtemVerificationDialog(alert: alert) { accepted in
            if activePrompt == id { activePrompt = nil }
            completion(accepted)
        }
        prompt.confirm = { $0.authenticate() }
        prompt.show()
        return { prompt.finish(false) }
    }

    static func saveRecovery(_ text: String, completion: @escaping (Bool) -> Void) -> (() -> Void) {
        guard activePrompt == nil else { completion(false); return {} }
        let id = UUID()
        activePrompt = id
        let prompt = AtemRecoveryKitPrompt(text: text) { saved in
            if activePrompt == id { activePrompt = nil }
            completion(saved)
        }
        prompt.show()
        return { prompt.cancel() }
    }

    static func unlock(_ request: AtemUnlockApproval, completion: @escaping (AtemUnlockDecision) -> Void) -> (() -> Void) {
        guard activePrompt == nil else { completion(.deny); return {} }
        let id = UUID()
        activePrompt = id
        let alert = unlockAlert(request)
        var revoke = false
        let prompt = AtemVerificationDialog(alert: alert) { accepted in
            if activePrompt == id { activePrompt = nil }
            completion(accepted ? .approve : (revoke ? .revoke : .deny))
        }
        prompt.confirm = { $0.authenticate(reason: "unlock this Atem's storage key") }
        prompt.alternate = { dialog in revoke = true; dialog.finish(false) }
        prompt.show()
        return { prompt.finish(false) }
    }

    static func unlockAlert(_ request: AtemUnlockApproval) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Unlock Atem Storage Key"
        let requested = DateFormatter.localizedString(from: request.requestTime, dateStyle: .medium, timeStyle: .medium)
        let last = request.lastUnlock.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "Never"
        alert.informativeText = "Device: \(displayText(request.deviceName))\nBoot ID: \(displayText(request.bootId))\nRequested: \(requested)\nLast unlock: \(last)\n\nApprove with Touch ID to unlock this device's sealed keys. Deny and revoke requires the device to verify again."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Deny and Revoke")
        return alert
    }

    private static func displayText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }).prefix(200))
    }
}

// Modeless alerts keep the main queue free to handle a peer's verifyAbort.
final class AtemVerificationDialog: NSObject, NSWindowDelegate {
    let alert: NSAlert
    var confirm: ((AtemVerificationDialog) -> Void)?
    var alternate: ((AtemVerificationDialog) -> Void)?
    private var completion: ((Bool) -> Void)?
    private var authentication: LAContext?
    var isActive: Bool { completion != nil }

    init(alert: NSAlert, completion: @escaping (Bool) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    func show() {
        guard isActive else { return }
        // Accessing the window directly skips NSAlert's usual presentation layout.
        alert.layout()
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(accept)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(deny)
        if alert.buttons.count > 2 {
            alert.buttons[2].target = self
            alert.buttons[2].action = #selector(alternateAction)
        }
        alert.window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func accept() {
        guard isActive else { return }
        if let confirm { confirm(self) } else { finish(true) }
    }

    @objc private func deny() { finish(false) }
    @objc private func alternateAction() { alternate?(self) }

    func authenticate(reason: String = "verify this Atem's safety code") {
        guard isActive, authentication == nil else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            alert.messageText = "Touch ID Is Required"
            alert.informativeText = "Unlock this Mac and enable Touch ID to approve this request."
            alert.buttons[0].title = "OK"
            alert.buttons[1].isHidden = true
            if alert.buttons.count > 2 { alert.buttons[2].isHidden = true }
            confirm = { $0.finish(false) }
            return
        }
        authentication = context
        alert.window.orderOut(nil)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] ok, _ in
            DispatchQueue.main.async { self?.finish(ok) }
        }
    }

    func finish(_ accepted: Bool) {
        guard let callback = completion else { return }
        completion = nil
        authentication?.invalidate()
        authentication = nil
        alert.window.close()
        callback(accepted)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}

final class AtemRecoveryKitPrompt: NSObject {
    private let text: String
    private let dialog: AtemVerificationDialog
    private var savePanel: NSSavePanel?
    private let status = NSTextField(wrappingLabelWithString: "")
    var alert: NSAlert { dialog.alert }

    init(text: String, completion: @escaping (Bool) -> Void) {
        self.text = text
        dialog = AtemVerificationDialog(alert: NSAlert(), completion: completion)
    }

    func show() {
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
        content.preferredMaxLayoutWidth = 450
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
        status.stringValue = "Copy or save the kit, then confirm you've stored it safely."
        stack.addArrangedSubview(status)
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        dialog.show()
    }

    func cancel() {
        savePanel?.cancel(nil)
        savePanel = nil
        dialog.finish(false)
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
        guard dialog.isActive, savePanel == nil else { return }
        let panel = NSSavePanel()
        savePanel = panel
        panel.nameFieldStringValue = "Astation Recovery Kit.txt"
        panel.beginSheetModal(for: alert.window) { [weak self] result in
            guard let self, self.dialog.isActive, self.savePanel === panel else { return }
            self.savePanel = nil
            guard result == .OK, let url = panel.url else { return }
            do {
                try RecoveryKit.save(self.text, to: url)
                self.status.stringValue = "Recovery kit saved. Keep an off-Mac copy."
            } catch { self.status.stringValue = "Couldn't save the recovery kit: \(error.localizedDescription)" }
        }
    }
}
