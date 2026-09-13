import Cocoa
import Foundation

class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
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
    private var tabView: NSTabView?
    private var sidebarTable: NSTableView?
    private let hubManager: AstationHubManager
    private let shortcutsController: KeyboardShortcutsViewController
    private var statusLabel: NSTextField!
    private var signInButton: NSButton!
    private var signOutButton: NSButton!
    private var identityLabel: NSTextField!
    private var stationUrlField: NSTextField!
    private var serverStatusLabel: NSTextField!
    private var serverInfoLabel: NSTextField!

    init(hubManager: AstationHubManager, hotkeyManager: HotkeyManager) {
        self.hubManager = hubManager
        self.shortcutsController = KeyboardShortcutsViewController(manager: hotkeyManager)
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
            shortcutsController.refresh()
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Astation Settings"
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 440))

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

        let tabs = NSTabView()
        tabs.tabViewType = .noTabsNoBorder
        tabs.delegate = self
        tabView = tabs
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        let generalContainer = NSView()
        generalContainer.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 450),
            contentView.heightAnchor.constraint(equalToConstant: 440),
            contentView.centerXAnchor.constraint(equalTo: generalContainer.centerXAnchor),
            contentView.topAnchor.constraint(equalTo: generalContainer.topAnchor, constant: 16)
        ])
        general.view = generalContainer
        tabs.addTabViewItem(general)
        let shortcuts = NSTabViewItem(identifier: "shortcuts")
        shortcuts.label = "Keyboard Shortcuts"
        shortcuts.viewController = shortcutsController
        tabs.addTabViewItem(shortcuts)
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        let table = NSTableView()
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 36
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Settings categories")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settingsCategory"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        sidebarTable = table
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = table
        sidebar.addSubview(sidebarScroll)
        let divider = NSBox()
        divider.boxType = .separator
        let root = window.contentView!
        for child in [sidebar, divider, tabs] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            sidebarScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            tabs.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func renderAccountState() {
        guard identityLabel != nil else { return }
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
        guard serverInfoLabel != nil else { return }
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
        shortcutsController.cancelRecording()
        tabView = nil
        sidebarTable = nil
        window = nil
    }

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        shortcutsController.cancelRecording()
        shortcutsController.refresh()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        let index = tabView.indexOfTabViewItem(tabViewItem)
        if sidebarTable?.selectedRow != index {
            sidebarTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tabView?.numberOfTabViewItems ?? 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === sidebarTable,
              let tabs = tabView, table.selectedRow >= 0, table.selectedRow < tabs.numberOfTabViewItems else { return }
        let selected = tabs.tabViewItem(at: table.selectedRow)
        if tabs.selectedTabViewItem !== selected { tabs.selectTabViewItem(selected) }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tabs = tabView, row >= 0, row < tabs.numberOfTabViewItems else { return nil }
        let item = tabs.tabViewItem(at: row)
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: item.label)
        label.font = .systemFont(ofSize: 13)
        let symbol = (item.identifier as? String) == "general" ? "gearshape" : "keyboard"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        for child in [icon, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        cell.textField = label
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
        return cell
    }
}

extension Notification.Name {
    static let serverInfoChanged = Notification.Name("AstationServerInfoChanged")
    static let credentialsChanged = Notification.Name("AstationCredentialsChanged")
}
