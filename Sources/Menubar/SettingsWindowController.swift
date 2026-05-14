import Cocoa
import Foundation

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let astationRelayUrlKey = "AstationRelayUrl"

    static let defaultStationURL = "https://station.agora.build"

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
    private let hubManager: AstationHubManager
    private var statusLabel: NSTextField!
    private var signInButton: NSButton!
    private var signOutButton: NSButton!
    private var identityLabel: NSTextField!
    private var stationUrlField: NSTextField!
    private var serverStatusLabel: NSTextField!
    private var serverInfoLabel: NSTextField!

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(networkChanged),
            name: .networkChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionChanged),
            name: .credentialsChanged, object: nil)
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

        serverInfoLabel = NSTextField(wrappingLabelWithString: "")
        serverInfoLabel.font = NSFont.systemFont(ofSize: 11)
        serverInfoLabel.textColor = .secondaryLabelColor
        serverInfoLabel.frame = NSRect(x: 20, y: 315, width: 410, height: 70)
        contentView.addSubview(serverInfoLabel)

        // Station Relay URL (for remote connections)
        let stationLabel = NSTextField(labelWithString: "Relay URL:")
        stationLabel.frame = NSRect(x: 20, y: 270, width: 80, height: 22)
        contentView.addSubview(stationLabel)

        stationUrlField = NSTextField(frame: NSRect(x: 105, y: 270, width: 235, height: 22))
        stationUrlField.placeholderString = SettingsWindowController.defaultStationURL
        let savedStation = UserDefaults.standard.string(forKey: SettingsWindowController.astationRelayUrlKey) ?? ""
        stationUrlField.stringValue = savedStation
        if ProcessInfo.processInfo.environment["ASTATION_RELAY_URL"] != nil {
            stationUrlField.placeholderString = "Overridden by ASTATION_RELAY_URL env var"
        }
        contentView.addSubview(stationUrlField)

        // Server status label (shows current network IP)
        serverStatusLabel = NSTextField(labelWithString: "")
        serverStatusLabel.font = NSFont.systemFont(ofSize: 11)
        serverStatusLabel.textColor = .secondaryLabelColor
        serverStatusLabel.frame = NSRect(x: 20, y: 245, width: 405, height: 18)
        contentView.addSubview(serverStatusLabel)

        // Update status immediately
        updateServerStatus()

        // Save server button
        let saveServerButton = NSButton(title: "Save", target: self, action: #selector(saveServerInfo))
        saveServerButton.bezelStyle = .rounded
        saveServerButton.frame = NSRect(x: 350, y: 268, width: 75, height: 24)
        contentView.addSubview(saveServerButton)

        // Separator
        let separator = NSBox(frame: NSRect(x: 20, y: 235, width: 410, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // === Agora Account Section ===
        let acctTitle = NSTextField(labelWithString: "Agora Account")
        acctTitle.font = NSFont.boldSystemFont(ofSize: 14)
        acctTitle.frame = NSRect(x: 20, y: 200, width: 410, height: 24)
        contentView.addSubview(acctTitle)

        let info = NSTextField(wrappingLabelWithString:
            "Sign in once with your Agora account. Astation uses this session to fetch projects and ship credentials to paired Atems. The session is encrypted on disk.")
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 20, y: 150, width: 410, height: 46)
        contentView.addSubview(info)

        identityLabel = NSTextField(labelWithString: "")
        identityLabel.font = NSFont.systemFont(ofSize: 12)
        identityLabel.frame = NSRect(x: 20, y: 110, width: 410, height: 22)
        contentView.addSubview(identityLabel)

        signInButton = NSButton(title: "Sign in with Agora", target: self, action: #selector(signIn))
        signInButton.bezelStyle = .rounded
        signInButton.frame = NSRect(x: 20, y: 70, width: 180, height: 32)
        contentView.addSubview(signInButton)

        signOutButton = NSButton(title: "Sign out", target: self, action: #selector(signOut))
        signOutButton.bezelStyle = .rounded
        signOutButton.frame = NSRect(x: 210, y: 70, width: 100, height: 32)
        contentView.addSubview(signOutButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: 40, width: 410, height: 22)
        contentView.addSubview(statusLabel)

        renderAccountState()

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func renderAccountState() {
        if let session = hubManager.currentSession() {
            let id = session.loginId ?? "—"
            identityLabel.stringValue = "Signed in as: \(id)"
            let mins = max(0, Int64(session.expiresAt) - Int64(Date().timeIntervalSince1970)) / 60
            statusLabel.stringValue = "Access token expires in \(mins) min"
            statusLabel.textColor = .secondaryLabelColor
            signInButton.isEnabled = false
            signOutButton.isEnabled = true
        } else {
            identityLabel.stringValue = "Not signed in"
            statusLabel.stringValue = ""
            signInButton.isEnabled = true
            signOutButton.isEnabled = false
        }
    }

    @objc private func signIn() {
        signInButton.isEnabled = false
        statusLabel.stringValue = "Waiting for browser…"
        statusLabel.textColor = .secondaryLabelColor

        Task { @MainActor in
            do {
                let mgr = SsoAuthManager(ssoUrl: SsoConfig.currentSsoUrl)
                let session = try await mgr.runLoginFlow()
                try hubManager.sessionStore.save(session)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                Log.info("[Settings] Signed in as \(session.loginId ?? "—")")
            } catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                signInButton.isEnabled = true
            }
        }
    }

    @objc private func signOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out?"
        alert.informativeText = "Astation will lose access to your projects until you sign in again. Paired Atems will not receive credential updates."
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? hubManager.sessionStore.delete()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    @objc private func sessionChanged() {
        DispatchQueue.main.async { [weak self] in self?.renderAccountState() }
    }

    private func updateServerStatus() {
        let localIP = getLocalNetworkIP() ?? "127.0.0.1"
        serverInfoLabel.stringValue = "WebSocket:\n• Local: ws://127.0.0.1:8080/ws\n• LAN: ws://\(localIP):8080/ws\n• VPN: ws://<vpn-ip>:8080/ws"
        serverStatusLabel.stringValue = ""
        serverStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func networkChanged() {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateServerStatus()
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
