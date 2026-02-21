import Cocoa
import Foundation

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let astationWsKey = "AstationWs"
    static let astationRelayUrlKey = "AstationRelayUrl"

    static let defaultWebSocketURL = "ws://127.0.0.1:8080/ws"
    static let defaultStationURL = "https://station.agora.build"

    /// Returns the persisted local WebSocket URL, or the default.
    static var currentAstationWs: String {
        let saved = UserDefaults.standard.string(forKey: astationWsKey) ?? ""
        return saved.isEmpty ? defaultWebSocketURL : saved
    }

    /// Returns the persisted Station relay URL.
    /// Env var ASTATION_RELAY_URL takes priority over UserDefaults.
    static var currentAstationRelayUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["ASTATION_RELAY_URL"], !envUrl.isEmpty {
            return envUrl
        }
        let saved = UserDefaults.standard.string(forKey: astationRelayUrlKey) ?? ""
        return saved.isEmpty ? defaultStationURL : saved
    }

    private var window: NSWindow?
    private let credentialManager: CredentialManager
    private var customerIdField: NSTextField!
    private var customerSecretField: NSSecureTextField!
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var deleteButton: NSButton!
    private var stationUrlField: NSTextField!
    private var serverStatusLabel: NSTextField!

    init(credentialManager: CredentialManager) {
        self.credentialManager = credentialManager
        super.init()

        // Listen for network changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(networkChanged),
            name: .networkChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 440),
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

        // === Server Info Section ===
        let serverTitle = NSTextField(labelWithString: "Server Info")
        serverTitle.font = NSFont.boldSystemFont(ofSize: 14)
        serverTitle.frame = NSRect(x: 20, y: 395, width: 410, height: 24)
        contentView.addSubview(serverTitle)

        let localIP = getLocalNetworkIP() ?? "127.0.0.1"
        let serverInfo = NSTextField(wrappingLabelWithString: "Astation automatically listens on ALL network interfaces (0.0.0.0:8080). No configuration needed on Astation side.\n\nAvailable at:\n• ws://127.0.0.1:8080/ws (localhost)\n• ws://\(localIP):8080/ws (LAN)\n\nConfigure these URLs in Atem's config (~/.config/atem/config.toml).")
        serverInfo.font = NSFont.systemFont(ofSize: 11)
        serverInfo.textColor = .secondaryLabelColor
        serverInfo.frame = NSRect(x: 20, y: 305, width: 410, height: 85)
        contentView.addSubview(serverInfo)

        // Station Relay URL (for remote connections)
        let stationLabel = NSTextField(labelWithString: "Relay URL:")
        stationLabel.frame = NSRect(x: 20, y: 270, width: 80, height: 22)
        contentView.addSubview(stationLabel)

        stationUrlField = NSTextField(frame: NSRect(x: 105, y: 270, width: 320, height: 22))
        stationUrlField.placeholderString = SettingsWindowController.defaultStationURL
        let savedStation = UserDefaults.standard.string(forKey: SettingsWindowController.astationRelayUrlKey) ?? ""
        stationUrlField.stringValue = savedStation
        if ProcessInfo.processInfo.environment["ASTATION_RELAY_URL"] != nil {
            stationUrlField.placeholderString = "Overridden by ASTATION_RELAY_URL env var"
        }
        contentView.addSubview(stationUrlField)

        // Relay URL help text
        let relayHelp = NSTextField(wrappingLabelWithString: "Optional: For Astation relay client to connect to remote relay server (future feature).")
        relayHelp.font = NSFont.systemFont(ofSize: 10)
        relayHelp.textColor = .tertiaryLabelColor
        relayHelp.frame = NSRect(x: 105, y: 245, width: 320, height: 20)
        contentView.addSubview(relayHelp)

        // Server status label (shows current network IP)
        serverStatusLabel = NSTextField(labelWithString: "")
        serverStatusLabel.font = NSFont.systemFont(ofSize: 11)
        serverStatusLabel.textColor = .secondaryLabelColor
        serverStatusLabel.frame = NSRect(x: 20, y: 240, width: 405, height: 18)
        contentView.addSubview(serverStatusLabel)

        // Update status immediately
        updateServerStatus()

        // Save server button
        let saveServerButton = NSButton(title: "Save", target: self, action: #selector(saveServerInfo))
        saveServerButton.bezelStyle = .rounded
        saveServerButton.frame = NSRect(x: 350, y: 255, width: 75, height: 28)
        contentView.addSubview(saveServerButton)

        // Separator
        let separator = NSBox(frame: NSRect(x: 20, y: 245, width: 410, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // === Credentials Section ===
        let titleLabel = NSTextField(labelWithString: "Agora Console Credentials")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 215, width: 410, height: 24)
        contentView.addSubview(titleLabel)

        // Info label
        let infoLabel = NSTextField(wrappingLabelWithString: "Enter your Customer ID and Customer Secret from console.agora.io > RESTful API. Credentials are encrypted and stored locally.")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 175, width: 410, height: 36)
        contentView.addSubview(infoLabel)

        // Customer ID label + field
        let idLabel = NSTextField(labelWithString: "Customer ID:")
        idLabel.frame = NSRect(x: 20, y: 140, width: 120, height: 22)
        contentView.addSubview(idLabel)

        customerIdField = NSTextField(frame: NSRect(x: 145, y: 140, width: 280, height: 22))
        customerIdField.placeholderString = "Enter Customer ID"
        contentView.addSubview(customerIdField)

        // Customer Secret label + field
        let secretLabel = NSTextField(labelWithString: "Customer Secret:")
        secretLabel.frame = NSRect(x: 20, y: 105, width: 120, height: 22)
        contentView.addSubview(secretLabel)

        customerSecretField = NSSecureTextField(frame: NSRect(x: 145, y: 105, width: 280, height: 22))
        customerSecretField.placeholderString = "Enter Customer Secret"
        contentView.addSubview(customerSecretField)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: 70, width: 410, height: 22)
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
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } catch {
            statusLabel.stringValue = "Failed to save: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            print("[Settings] Failed to save credentials: \(error)")
        }
    }

    private func updateServerStatus() {
        let localIP = getLocalNetworkIP() ?? "127.0.0.1"
        serverStatusLabel.stringValue = "Listening on: ws://127.0.0.1:8080/ws, ws://\(localIP):8080/ws"
        serverStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func networkChanged() {
        // Update displayed IP when network changes
        updateServerStatus()
        Log.info("Network changed - IP updated in settings UI")
    }

    @objc private func saveServerInfo() {
        let stationUrl = stationUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(stationUrl, forKey: SettingsWindowController.astationRelayUrlKey)

        serverStatusLabel.stringValue = "Relay URL saved"
        serverStatusLabel.textColor = .systemGreen
        print("[Settings] Station relay URL saved: \(stationUrl.isEmpty ? "(default)" : stationUrl)")

        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)

        // Restore status after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateServerStatus()
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

    // MARK: - Helper Methods

    /// Get the local network IP address (e.g., 192.168.1.5) for LAN connections.
    private func getLocalNetworkIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                // Look for en0 (WiFi) or en1 (Ethernet) - skip loopback
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
        }

        return address
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

extension Notification.Name {
    static let serverInfoChanged = Notification.Name("AstationServerInfoChanged")
    static let credentialsChanged = Notification.Name("AstationCredentialsChanged")
}
