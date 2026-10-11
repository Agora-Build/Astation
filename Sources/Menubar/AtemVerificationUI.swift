import AppKit
import LocalAuthentication

enum AtemVerificationUI {
    private static var activePrompt: UUID?

    static func approve(_ request: AtemVerificationApproval, completion: @escaping (Bool) -> Void) -> (() -> Void) {
        approve(request, context: LAContext(), completion: completion)
    }

    static func approve(_ request: AtemVerificationApproval, context: LAContext,
                        completion: @escaping (Bool) -> Void) -> (() -> Void) {
        guard activePrompt == nil else { completion(false); return {} }
        let id = UUID()
        activePrompt = id
        let prompt = AtemSafetyCodePrompt(request: request, context: context) { accepted in
            if activePrompt == id { activePrompt = nil }
            completion(accepted)
        }
        prompt.show()
        return { prompt.finish(false) }
    }

    static func verificationAlert(_ request: AtemVerificationApproval) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Verify Atem Safety Code"
        alert.informativeText = "Device: \(displayText(request.deviceName))"
        alert.addButton(withTitle: "Codes Match")
        alert.addButton(withTitle: "Deny")
        return alert
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
        unlock(request, context: LAContext(), completion: completion)
    }

    static func unlock(_ request: AtemUnlockApproval, context: LAContext,
                       completion: @escaping (AtemUnlockDecision) -> Void) -> (() -> Void) {
        guard activePrompt == nil else { completion(.deny); return {} }
        let id = UUID()
        activePrompt = id
        let prompt = AtemUnlockPrompt(request: request, context: context) { decision in
            if activePrompt == id { activePrompt = nil }
            completion(decision)
        }
        prompt.show()
        return { prompt.finish(.deny) }
    }

    static func unlockAlert(_ request: AtemUnlockApproval) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Unlock Atem Storage Key"
        let requested = DateFormatter.localizedString(from: request.requestTime, dateStyle: .medium, timeStyle: .medium)
        let last = request.lastUnlock.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "Never"
        alert.informativeText = "Device: \(displayText(request.deviceName))\nBoot ID: \(displayText(request.bootId))\nRequested: \(requested)\nLast unlock: \(last)"
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
    private var completion: ((Bool) -> Void)?
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
        alert.window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func accept() { finish(true) }
    @objc private func deny() { finish(false) }

    func finish(_ accepted: Bool) {
        guard let callback = completion else { return }
        completion = nil
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
