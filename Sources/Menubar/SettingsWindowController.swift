import Cocoa
import Foundation

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let credentialManager: CredentialManager
    private var customerIdField: NSTextField!
    private var customerSecretField: NSSecureTextField!
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var deleteButton: NSButton!

    init(credentialManager: CredentialManager) {
        self.credentialManager = credentialManager
        super.init()
    }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Astation Settings"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Title label
        let titleLabel = NSTextField(labelWithString: "Agora Console Credentials")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 230, width: 410, height: 24)
        contentView.addSubview(titleLabel)

        // Info label
        let infoLabel = NSTextField(wrappingLabelWithString: "Enter your Customer ID and Customer Secret from console.agora.io > RESTful API. Credentials are encrypted and stored locally.")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 190, width: 410, height: 36)
        contentView.addSubview(infoLabel)

        // Customer ID label + field
        let idLabel = NSTextField(labelWithString: "Customer ID:")
        idLabel.frame = NSRect(x: 20, y: 155, width: 120, height: 22)
        contentView.addSubview(idLabel)

        customerIdField = NSTextField(frame: NSRect(x: 145, y: 155, width: 280, height: 22))
        customerIdField.placeholderString = "Enter Customer ID"
        contentView.addSubview(customerIdField)

        // Customer Secret label + field
        let secretLabel = NSTextField(labelWithString: "Customer Secret:")
        secretLabel.frame = NSRect(x: 20, y: 120, width: 120, height: 22)
        contentView.addSubview(secretLabel)

        customerSecretField = NSSecureTextField(frame: NSRect(x: 145, y: 120, width: 280, height: 22))
        customerSecretField.placeholderString = "Enter Customer Secret"
        contentView.addSubview(customerSecretField)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: 85, width: 410, height: 22)
        contentView.addSubview(statusLabel)

        // Update status based on current credential state
        updateStatus()

        // Save button
        saveButton = NSButton(title: "Save", target: self, action: #selector(saveCredentials))
        saveButton.bezelStyle = .rounded
        saveButton.frame = NSRect(x: 310, y: 20, width: 115, height: 32)
        saveButton.keyEquivalent = "\r" // Enter key
        contentView.addSubview(saveButton)

        // Delete button
        deleteButton = NSButton(title: "Delete Credentials", target: self, action: #selector(deleteCredentials))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 20, y: 20, width: 150, height: 32)
        deleteButton.isEnabled = credentialManager.hasCredentials
        contentView.addSubview(deleteButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func updateStatus() {
        if credentialManager.hasCredentials {
            statusLabel.stringValue = "Credentials saved (encrypted)"
            statusLabel.textColor = .systemGreen
            customerIdField.placeholderString = "••••••••  (saved)"
            customerSecretField.placeholderString = "••••••••  (saved)"
            deleteButton?.isEnabled = true
        } else {
            statusLabel.stringValue = "No credentials configured"
            statusLabel.textColor = .secondaryLabelColor
            customerIdField.placeholderString = "Enter Customer ID"
            customerSecretField.placeholderString = "Enter Customer Secret"
            deleteButton?.isEnabled = false
        }
        // Never pre-fill with real values
        customerIdField?.stringValue = ""
        customerSecretField?.stringValue = ""
    }

    @objc private func saveCredentials() {
        let customerId = customerIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerSecret = customerSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !customerId.isEmpty, !customerSecret.isEmpty else {
            statusLabel.stringValue = "Both fields are required"
            statusLabel.textColor = .systemRed
            return
        }

        let credentials = AgoraCredentials(customerId: customerId, customerSecret: customerSecret)

        do {
            try credentialManager.save(credentials)
            statusLabel.stringValue = "Credentials saved (encrypted)"
            statusLabel.textColor = .systemGreen
            updateStatus()
            print("[Settings] Credentials saved successfully")
        } catch {
            statusLabel.stringValue = "Failed to save: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            print("[Settings] Failed to save credentials: \(error)")
        }
    }

    @objc private func deleteCredentials() {
        let alert = NSAlert()
        alert.messageText = "Delete Credentials?"
        alert.informativeText = "This will remove your stored Agora credentials. You will need to re-enter them to use API features."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try credentialManager.delete()
                updateStatus()
                print("[Settings] Credentials deleted")
            } catch {
                statusLabel.stringValue = "Failed to delete: \(error.localizedDescription)"
                statusLabel.textColor = .systemRed
                print("[Settings] Failed to delete credentials: \(error)")
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
