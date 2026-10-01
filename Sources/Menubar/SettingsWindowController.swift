import Cocoa
import Foundation

class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let astationRelayUrlKey = "AstationRelayUrl"

    static let defaultStationURL = "https://station.agora.build"

    /// Returns the persisted Station relay URL.
    /// Env var ASTATION_RELAY_URL takes priority over UserDefaults.
    static var currentAstationRelayUrl: String {
        if let envUrl = ProcessInfo.processInfo.environment["ASTATION_RELAY_URL"] {
            let normalized = StationRelayURL.normalizedBase(envUrl)
            if !normalized.isEmpty { return normalized }
        }
        let saved = StationRelayURL.normalizedBase(UserDefaults.standard.string(forKey: astationRelayUrlKey) ?? "")
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
    private var recoveryStatusLabel: NSTextField?

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
        let security = NSTabViewItem(identifier: "security")
        security.label = "Security"
        security.view = makeSecurityView()
        tabs.addTabViewItem(security)
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
        let stationUrl = StationRelayURL.normalizedBase(stationUrlField.stringValue)
        stationUrlField.stringValue = stationUrl

        UserDefaults.standard.set(stationUrl, forKey: SettingsWindowController.astationRelayUrlKey)

        serverStatusLabel.stringValue = "Relay URL saved"
        serverStatusLabel.textColor = .systemGreen
        print("[Settings] Station relay URL saved: \(stationUrl.isEmpty ? "(default)" : stationUrl)")

        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateServerStatus()
        }
    }

    // MARK: - Security (account recovery)

    private func makeSecurityView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 440))

        let title = NSTextField(labelWithString: "Account Recovery")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 20, y: 395, width: 410, height: 24)
        content.addSubview(title)

        let info = NSTextField(wrappingLabelWithString:
            "The relay stores your memories, skills and vaults under this Astation's ID. Save the recovery kit somewhere off this Mac, such as a password manager, so you can get them back if this Mac is lost.")
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 20, y: 335, width: 410, height: 56)
        content.addSubview(info)

        let idLabel = NSTextField(labelWithString: "Astation ID: \(RecoveryKit.masked(AstationIdentity.shared.id))")
        idLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        idLabel.frame = NSRect(x: 20, y: 305, width: 410, height: 22)
        content.addSubview(idLabel)

        let showButton = NSButton(title: "Show Recovery Kit…", target: self, action: #selector(showRecoveryKit))
        showButton.bezelStyle = .rounded
        showButton.frame = NSRect(x: 20, y: 265, width: 180, height: 32)
        content.addSubview(showButton)

        let separator = NSBox(frame: NSRect(x: 20, y: 250, width: 410, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        let restoreTitle = NSTextField(labelWithString: "Restore on a New Mac")
        restoreTitle.font = NSFont.boldSystemFont(ofSize: 14)
        restoreTitle.frame = NSRect(x: 20, y: 215, width: 410, height: 24)
        content.addSubview(restoreTitle)

        let restoreInfo = NSTextField(wrappingLabelWithString:
            "Replace this Astation's ID with the one in your recovery kit. Astation quits; open it again to finish. Atems paired with the current ID will need to pair again.")
        restoreInfo.font = NSFont.systemFont(ofSize: 11)
        restoreInfo.textColor = .secondaryLabelColor
        restoreInfo.frame = NSRect(x: 20, y: 160, width: 410, height: 50)
        content.addSubview(restoreInfo)

        let restoreButton = NSButton(title: "Restore Account…", target: self, action: #selector(restoreAccount))
        restoreButton.bezelStyle = .rounded
        restoreButton.frame = NSRect(x: 20, y: 120, width: 180, height: 32)
        content.addSubview(restoreButton)

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.frame = NSRect(x: 20, y: 70, width: 410, height: 40)
        content.addSubview(status)
        recoveryStatusLabel = status

        let container = NSView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 450),
            content.heightAnchor.constraint(equalToConstant: 440),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16)
        ])
        return container
    }

    private func setRecoveryStatus(_ message: String, isError: Bool) {
        recoveryStatusLabel?.stringValue = message
        recoveryStatusLabel?.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// A monospaced text box for an alert's accessory view.
    private static func textBox(_ text: String, editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return (scroll, textView)
    }

    @objc private func showRecoveryKit() {
        DeviceOwnerAuth.authenticate(reason: "show your Astation recovery kit") { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.setRecoveryStatus("Not authenticated, so the recovery kit wasn't shown.", isError: true)
                return
            }
            let kit = RecoveryKit(
                astationId: AstationIdentity.shared.id,
                relayURL: SettingsWindowController.currentAstationRelayUrl
            )
            let text = kit.text()
            let alert = NSAlert()
            alert.messageText = "Astation Recovery Kit"
            alert.informativeText = "Save this somewhere off this Mac, such as a password manager. You need it to get your memories, skills and vaults back if this Mac is lost."
            alert.accessoryView = Self.textBox(text, editable: false).0
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Save to File…")
            alert.addButton(withTitle: "Done")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.setRecoveryStatus("Recovery kit copied to the clipboard.", isError: false)
            case .alertSecondButtonReturn:
                self.saveRecoveryKit(text)
            default:
                break
            }
        }
    }

    private func saveRecoveryKit(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Astation Recovery Kit.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            setRecoveryStatus("Saved to \(url.path).", isError: false)
        } catch {
            setRecoveryStatus("Couldn't save the recovery kit: \(error.localizedDescription)", isError: true)
        }
    }

    @objc private func restoreAccount() {
        DeviceOwnerAuth.authenticate(reason: "restore an Astation account") { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.setRecoveryStatus("Not authenticated, so nothing was restored.", isError: true)
                return
            }
            let input = NSAlert()
            input.messageText = "Restore Account"
            input.informativeText = "Paste your recovery kit, or just the Astation ID."
            let (box, textView) = Self.textBox("", editable: true)
            input.accessoryView = box
            input.addButton(withTitle: "Continue")
            input.addButton(withTitle: "Cancel")
            input.window.initialFirstResponder = textView
            guard input.runModal() == .alertFirstButtonReturn else { return }

            guard let kit = RecoveryKit.parse(textView.string) else {
                self.setRecoveryStatus("No Astation ID found in what you pasted.", isError: true)
                return
            }
            let current = AstationIdentity.shared.id
            guard kit.astationId != current else {
                self.setRecoveryStatus("This Mac already uses that Astation ID.", isError: false)
                return
            }

            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "Replace this Astation's ID?"
            confirm.informativeText = """
            Current: \(current)
            New: \(kit.astationId)

            Astation will quit; open it again to finish. Atems paired with the current ID will need to pair again.

            The relay still trusts the old Mac's device key for this ID. Once, on the relay server, run:
            station-relay-server admin forget-key \(kit.astationId)
            """
            confirm.addButton(withTitle: "Replace and Quit")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            do {
                try AstationIdentity.restore(kit.astationId)
            } catch {
                self.setRecoveryStatus(error.localizedDescription, isError: true)
                return
            }
            if !kit.relayURL.isEmpty {
                UserDefaults.standard.set(StationRelayURL.normalizedBase(kit.relayURL), forKey: SettingsWindowController.astationRelayUrlKey)
            }
            NSApp.terminate(nil)
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
        let symbol: String
        switch item.identifier as? String {
        case "general": symbol = "gearshape"
        case "security": symbol = "lock.shield"
        default: symbol = "keyboard"
        }
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
