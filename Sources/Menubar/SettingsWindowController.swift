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
    private var relayAccountStack: NSStackView?
    private var relayAccountStatusLabel: NSTextField?
    private var leaveGroupButton: NSButton?
    private var encryptionStatusLabel: NSTextField?
    private var encryptionOnButton: NSButton?
    private var encryptionOffButton: NSButton?
    private var encryptionRotateButton: NSButton?
    private var encryptionShowButton: NSButton?
    private weak var pendingEncryptionAlert: NSAlert?
    private var pendingEncryptionRecoveryKey: String?
    private var pendingEncryptionKid: String?
    private var pendingEncryptionKey: AccountDataKey?

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(relayAccountChanged),
            name: .relayAccountChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(relayEncryptionChanged),
            name: .relayEncryptionChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showWindow() {
        if let existingWindow = window {
            shortcutsController.refresh()
            renderRelayAccountState()
            hubManager.requestRelayAccountState()
            renderEncryptionState()
            hubManager.requestRelayEncryptionState()
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

    // MARK: - Security

    private func makeSecurityView() -> NSView {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedSettingsView()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        document.addSubview(content)
        scroll.documentView = document
        container.addSubview(scroll)
        for view in [scroll, document, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 450)
        ])

        content.addArrangedSubview(sectionTitle("End-to-End Encryption"))
        content.addArrangedSubview(wrappingInfo(
            "Encrypt memory, skill files, and vault content before it reaches the relay. Only this Mac, paired Atems, and your separate encryption recovery key can unlock it."
        ))
        let encryptionStatus = NSTextField(wrappingLabelWithString: "Loading encryption state…")
        encryptionStatus.font = .systemFont(ofSize: 12, weight: .medium)
        encryptionStatus.translatesAutoresizingMaskIntoConstraints = false
        encryptionStatus.widthAnchor.constraint(equalToConstant: 410).isActive = true
        content.addArrangedSubview(encryptionStatus)
        encryptionStatusLabel = encryptionStatus

        let encryptionActions = NSStackView()
        encryptionActions.orientation = .horizontal
        encryptionActions.spacing = 8
        let turnOn = NSButton(title: "Turn On…", target: self, action: #selector(turnOnEncryption))
        let turnOff = NSButton(title: "Turn Off…", target: self, action: #selector(turnOffEncryption))
        let rotate = NSButton(title: "Rotate Key…", target: self, action: #selector(rotateEncryptionKey))
        let show = NSButton(title: "Show Recovery Key…", target: self, action: #selector(showEncryptionRecoveryKey))
        for button in [turnOn, turnOff, rotate, show] {
            button.bezelStyle = .rounded
            encryptionActions.addArrangedSubview(button)
        }
        encryptionOnButton = turnOn
        encryptionOffButton = turnOff
        encryptionRotateButton = rotate
        encryptionShowButton = show
        content.addArrangedSubview(encryptionActions)

        let restoreEncryption = NSButton(
            title: "Restore Encryption Key…",
            target: self,
            action: #selector(restoreEncryptionKey)
        )
        restoreEncryption.bezelStyle = .rounded
        content.addArrangedSubview(restoreEncryption)
        content.addArrangedSubview(separator())

        let accountTitle = sectionTitle("Astations on Your Agora Account")
        content.addArrangedSubview(accountTitle)
        content.addArrangedSubview(wrappingInfo(
            "Each Mac keeps separate data until you choose Merge. An online Mac must approve; a lost or offline Mac requires a fresh Agora sign-in and a notified 24-hour wait."
        ))
        let accountStack = NSStackView()
        accountStack.orientation = .vertical
        accountStack.alignment = .leading
        accountStack.spacing = 8
        accountStack.translatesAutoresizingMaskIntoConstraints = false
        accountStack.widthAnchor.constraint(equalToConstant: 410).isActive = true
        content.addArrangedSubview(accountStack)
        relayAccountStack = accountStack

        let accountActions = NSStackView()
        accountActions.orientation = .horizontal
        accountActions.spacing = 8
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshRelayAccount))
        refresh.bezelStyle = .rounded
        let leave = NSButton(title: "Leave Shared Group…", target: self, action: #selector(leaveRelayGroup))
        leave.bezelStyle = .rounded
        leaveGroupButton = leave
        accountActions.addArrangedSubview(refresh)
        accountActions.addArrangedSubview(leave)
        content.addArrangedSubview(accountActions)

        let accountStatus = NSTextField(wrappingLabelWithString: "")
        accountStatus.font = .systemFont(ofSize: 11)
        accountStatus.textColor = .secondaryLabelColor
        accountStatus.translatesAutoresizingMaskIntoConstraints = false
        accountStatus.widthAnchor.constraint(equalToConstant: 410).isActive = true
        relayAccountStatusLabel = accountStatus
        content.addArrangedSubview(accountStatus)
        content.addArrangedSubview(separator())

        content.addArrangedSubview(sectionTitle("Account Recovery"))
        content.addArrangedSubview(wrappingInfo(
            "Save the recovery kit somewhere off this Mac. It remains the fallback for an Astation that was never registered to an Agora account."
        ))
        let idLabel = NSTextField(labelWithString: "Astation ID: \(RecoveryKit.masked(AstationIdentity.shared.id))")
        idLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        content.addArrangedSubview(idLabel)
        let showButton = NSButton(title: "Show Recovery Kit…", target: self, action: #selector(showRecoveryKit))
        showButton.bezelStyle = .rounded
        content.addArrangedSubview(showButton)
        content.addArrangedSubview(separator())

        content.addArrangedSubview(sectionTitle("Restore on a New Mac"))
        content.addArrangedSubview(wrappingInfo(
            "Replace this Astation's ID with the one in your recovery kit. Astation quits; open it again to finish. Atems paired with the current ID will need to pair again."
        ))
        let restoreButton = NSButton(title: "Restore Account…", target: self, action: #selector(restoreAccount))
        restoreButton.bezelStyle = .rounded
        content.addArrangedSubview(restoreButton)
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 410).isActive = true
        content.addArrangedSubview(status)
        recoveryStatusLabel = status

        renderRelayAccountState()
        hubManager.requestRelayAccountState()
        renderEncryptionState()
        hubManager.requestRelayEncryptionState()
        return container
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 14)
        return label
    }

    private func wrappingInfo(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return label
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 410).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    @objc private func relayEncryptionChanged() {
        DispatchQueue.main.async { [weak self] in self?.renderEncryptionState() }
    }

    private func renderEncryptionState() {
        guard let label = encryptionStatusLabel else { return }
        guard let state = hubManager.relayEncryptionState else {
            label.stringValue = hubManager.relayEncryptionStatusMessage ?? "Encryption state unavailable."
            encryptionOnButton?.isEnabled = false
            encryptionOffButton?.isEnabled = false
            encryptionRotateButton?.isEnabled = false
            encryptionShowButton?.isEnabled = false
            return
        }
        let remaining = "\(state.plaintextFields) plaintext, \(state.ciphertextFields) encrypted, \(state.obsoleteFields) obsolete fields"
        switch state.mode {
        case "off": label.stringValue = "Off — stored data is readable by the relay."
        case "enabling": label.stringValue = "Turning on — \(remaining). Keep an Atem connected to finish migration."
        case "on":
            let date = state.enabledAt.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted() } ?? "unknown date"
            label.stringValue = "On since \(date) — key \(state.kid ?? "unknown")."
        case "disabling": label.stringValue = "Turning off — \(remaining). Keep an Atem connected to finish migration."
        default: label.stringValue = "Unknown encryption state."
        }
        if let message = hubManager.relayEncryptionStatusMessage { label.stringValue += "\n\(message)" }
        encryptionOnButton?.isEnabled = state.mode == "off"
        encryptionOffButton?.isEnabled = state.mode == "on"
        encryptionRotateButton?.isEnabled = state.mode == "on"
        encryptionShowButton?.isEnabled = state.mode != "off"
    }

    @objc private func turnOnEncryption() {
        beginEncryptionKeyChange(
            reason: "turn on end-to-end encryption",
            actionTitle: "Turn On",
            reuseExisting: true
        )
    }

    @objc private func rotateEncryptionKey() {
        beginEncryptionKeyChange(
            reason: "rotate your encryption key",
            actionTitle: "Rotate Key",
            reuseExisting: false
        )
    }

    private func beginEncryptionKeyChange(
        reason: String,
        actionTitle: String,
        reuseExisting: Bool
    ) {
        DeviceOwnerAuth.authenticate(reason: reason) { [weak self] ok in
            guard let self, ok else { return }
            do {
                let (key, recovery) = try self.hubManager.prepareEncryptionKeyForCurrentAccount(
                    reuseExisting: reuseExisting
                )
                self.pendingEncryptionKey = key
                self.pendingEncryptionKid = key.kid
                self.pendingEncryptionRecoveryKey = recovery
                self.showEncryptionRecoveryConfirmation(actionTitle: actionTitle)
            } catch {
                self.hubManager.relayEncryptionStatusMessage = error.localizedDescription
                self.renderEncryptionState()
            }
        }
    }

    private func showEncryptionRecoveryConfirmation(actionTitle: String) {
        guard let recovery = pendingEncryptionRecoveryKey,
              let key = pendingEncryptionKey else { return }
        let alert = NSAlert()
        alert.messageText = "Save Your Encryption Recovery Key"
        alert.informativeText = "If you lose this Mac and every paired Atem, nobody — including the server operator — can recover your encrypted data without this separate key."
        alert.alertStyle = .warning
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let keyLabel = NSTextField(wrappingLabelWithString: recovery)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keyLabel.isSelectable = true
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 430).isActive = true
        stack.addArrangedSubview(keyLabel)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(NSButton(title: "Copy", target: self, action: #selector(copyPendingEncryptionRecoveryKey)))
        actions.addArrangedSubview(NSButton(title: "Save to File…", target: self, action: #selector(savePendingEncryptionRecoveryKey)))
        stack.addArrangedSubview(actions)
        let saved = NSButton(
            checkboxWithTitle: "I've saved my encryption recovery key somewhere safe",
            target: self,
            action: #selector(encryptionRecoveryConfirmationChanged(_:))
        )
        stack.addArrangedSubview(saved)
        alert.accessoryView = stack
        pendingEncryptionAlert = alert

        let response = alert.runModal()
        pendingEncryptionAlert = nil
        if response == .alertFirstButtonReturn {
            do {
                try hubManager.installEncryptionKey(key)
                hubManager.setRelayEncryption(mode: "enabling", kid: key.kid)
            } catch {
                hubManager.relayEncryptionStatusMessage = error.localizedDescription
            }
        }
        pendingEncryptionRecoveryKey = nil
        pendingEncryptionKid = nil
        pendingEncryptionKey = nil
        renderEncryptionState()
    }

    @objc private func encryptionRecoveryConfirmationChanged(_ sender: NSButton) {
        pendingEncryptionAlert?.buttons.first?.isEnabled = sender.state == .on
    }

    @objc private func copyPendingEncryptionRecoveryKey() {
        guard let value = pendingEncryptionRecoveryKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func savePendingEncryptionRecoveryKey() {
        guard let value = pendingEncryptionRecoveryKey else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Astation Encryption Recovery Key.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            hubManager.relayEncryptionStatusMessage = "Couldn't save the encryption key: \(error.localizedDescription)"
        }
    }

    @objc private func turnOffEncryption() {
        guard let state = hubManager.relayEncryptionState, let kid = state.kid else { return }
        let alert = NSAlert()
        alert.messageText = "Turn Off End-to-End Encryption?"
        alert.informativeText = "A paired Atem will decrypt and rewrite all memory, skill, and vault history. The server will be able to read that data again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hubManager.setRelayEncryption(mode: "disabling", kid: kid)
    }

    @objc private func showEncryptionRecoveryKey() {
        DeviceOwnerAuth.authenticate(reason: "show your encryption recovery key") { [weak self] ok in
            guard let self, ok else { return }
            do {
                let recovery = try self.hubManager.encryptionRecoveryKey()
                self.pendingEncryptionRecoveryKey = recovery
                let alert = NSAlert()
                alert.messageText = "Encryption Recovery Key"
                alert.informativeText = recovery
                alert.addButton(withTitle: "Copy")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.copyPendingEncryptionRecoveryKey()
                }
                self.pendingEncryptionRecoveryKey = nil
            } catch {
                self.hubManager.relayEncryptionStatusMessage = error.localizedDescription
                self.renderEncryptionState()
            }
        }
    }

    @objc private func restoreEncryptionKey() {
        DeviceOwnerAuth.authenticate(reason: "restore your encryption key") { [weak self] ok in
            guard let self, ok else { return }
            let alert = NSAlert()
            alert.messageText = "Restore Encryption Key"
            alert.informativeText = "Paste the separate AEK1 encryption recovery key. This is not the Astation Account Recovery Kit."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 48))
            field.placeholderString = "AEK1-…"
            alert.accessoryView = field
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try self.hubManager.restoreEncryptionKey(field.stringValue)
                self.hubManager.relayEncryptionStatusMessage =
                    self.hubManager.relayEncryptionState?.mode == "off"
                    ? "Encryption key restored; turning encryption on."
                    : "Encryption key restored."
            } catch {
                self.hubManager.relayEncryptionStatusMessage = error.localizedDescription
            }
            self.renderEncryptionState()
        }
    }

    @objc private func relayAccountChanged() {
        DispatchQueue.main.async { [weak self] in self?.renderRelayAccountState() }
    }

    @objc private func refreshRelayAccount() {
        hubManager.requestRelayAccountState()
    }

    private func renderRelayAccountState() {
        guard let stack = relayAccountStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let currentId = AstationIdentity.shared.id
        let devices = hubManager.relayAccountDevices
        guard !devices.isEmpty else {
            stack.addArrangedSubview(wrappingInfo(
                hubManager.currentSession() == nil
                    ? "Sign in with Agora in General to register this Mac."
                    : "Waiting for the relay to register this Mac…"
            ))
            leaveGroupButton?.isEnabled = false
            relayAccountStatusLabel?.stringValue = hubManager.relayAccountStatusMessage ?? ""
            return
        }

        let current = devices.first { $0.astationId == currentId }
        leaveGroupButton?.isEnabled = current.map { $0.dataAccount != currentId } ?? false
        for device in devices {
            stack.addArrangedSubview(accountDeviceRow(device, current: device.astationId == currentId))
        }
        for request in hubManager.relayMergeRequests {
            stack.addArrangedSubview(mergeRequestRow(request))
        }
        relayAccountStatusLabel?.stringValue = hubManager.relayAccountStatusMessage ?? ""
    }

    private func accountDeviceRow(_ device: RelayAccountDevice, current: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 410).isActive = true

        let state = current ? "This Mac" : (device.online ? "Online" : "Last seen \(relativeTime(device.lastSeenAt))")
        let text = NSTextField(wrappingLabelWithString:
            "\(device.label)  ·  \(state)\n\(RecoveryKit.masked(device.astationId))  ·  \(device.dataAccount.hasPrefix("group-") ? "shared data" : "own data")")
        text.font = .systemFont(ofSize: 11)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(text)

        if !current {
            let mine = hubManager.relayAccountDevices.first { $0.astationId == AstationIdentity.shared.id }
            if mine?.dataAccount != device.dataAccount {
                let merge = SettingsActionButton(title: "Merge…", target: self, action: #selector(mergeRelayAstation(_:)))
                merge.bezelStyle = .rounded
                merge.payload = device.astationId
                row.addArrangedSubview(merge)
            }
            if !device.online {
                let remove = SettingsActionButton(title: "Remove…", target: self, action: #selector(removeRelayAstation(_:)))
                remove.bezelStyle = .rounded
                remove.payload = device.astationId
                row.addArrangedSubview(remove)
            }
        }
        return row
    }

    private func mergeRequestRow(_ request: RelayMergeRequest) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 410).isActive = true
        let detail: String
        if let readyAt = request.readyAt {
            detail = "Delayed merge pending until \(Date(timeIntervalSince1970: TimeInterval(readyAt)).formatted(date: .abbreviated, time: .shortened))"
        } else {
            detail = "Waiting for approval on the other Mac"
        }
        let label = NSTextField(wrappingLabelWithString: detail)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        let cancel = SettingsActionButton(title: "Cancel", target: self, action: #selector(cancelRelayMerge(_:)))
        cancel.bezelStyle = .rounded
        cancel.payload = request.requestId
        row.addArrangedSubview(cancel)
        return row
    }

    private func relativeTime(_ seconds: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seconds)), relativeTo: Date())
    }

    @objc private func mergeRelayAstation(_ sender: SettingsActionButton) {
        guard let id = sender.payload,
              let device = hubManager.relayAccountDevices.first(where: { $0.astationId == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Merge memories, skills and vaults?"
        alert.informativeText = device.online
            ? "\(device.label) will be asked to approve. After approval, both Macs use one shared data account."
            : "\(device.label) is offline. Continue with a fresh Agora sign-in; all registered Macs are notified, and the merge waits 24 hours so any of them can cancel."
        alert.addButton(withTitle: device.online ? "Request Approval" : "Sign In and Start Wait")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if device.online {
            hubManager.requestRelayMerge(targetAstationId: id)
            return
        }
        Task { @MainActor in
            do {
                let manager = SsoAuthManager(ssoUrl: SsoConfig.currentSsoUrl)
                let session = try await manager.runLoginFlow()
                try hubManager.sessionStore.save(session)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                hubManager.requestRelayMerge(
                    targetAstationId: id,
                    freshAccessToken: session.accessToken
                )
            } catch {
                relayAccountStatusLabel?.stringValue = error.localizedDescription
                relayAccountStatusLabel?.textColor = .systemRed
            }
        }
    }

    @objc private func cancelRelayMerge(_ sender: SettingsActionButton) {
        guard let id = sender.payload else { return }
        hubManager.cancelRelayMerge(requestId: id)
    }

    @objc private func leaveRelayGroup() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Leave the shared data group?"
        alert.informativeText = "This Mac starts with an empty personal data account. The group's existing data stays with the other Macs."
        alert.addButton(withTitle: "Leave Group")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hubManager.leaveRelayAccountGroup()
    }

    @objc private func removeRelayAstation(_ sender: SettingsActionButton) {
        guard let id = sender.payload,
              let device = hubManager.relayAccountDevices.first(where: { $0.astationId == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove \(device.label)?"
        alert.informativeText = "The relay revokes this Astation's device key and disconnects it. Its copy of already-downloaded data is not erased."
        alert.addButton(withTitle: "Remove Device")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hubManager.removeRelayAstation(astationId: id)
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
            let relayURL = StationRelayURL.validatedBase(SettingsWindowController.currentAstationRelayUrl)
                ?? SettingsWindowController.defaultStationURL
            let kit = RecoveryKit(
                astationId: AstationIdentity.shared.id,
                relayURL: relayURL
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
            try RecoveryKit.save(text, to: url)
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
                self.setRecoveryStatus("The recovery kit needs a valid Astation ID and relay URL.", isError: true)
                return
            }
            let current = AstationIdentity.shared.id
            guard !RecoveryKit.identifiesSameAstation(kit.astationId, current) else {
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
                try self.hubManager.deviceSessionStore.deleteAll()
                try AstationIdentity.restore(kit.astationId)
            } catch {
                self.setRecoveryStatus(error.localizedDescription, isError: true)
                return
            }
            if !kit.relayURL.isEmpty {
                UserDefaults.standard.set(kit.relayURL, forKey: SettingsWindowController.astationRelayUrlKey)
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

private final class FlippedSettingsView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsActionButton: NSButton {
    var payload: String?
}

extension Notification.Name {
    static let serverInfoChanged = Notification.Name("AstationServerInfoChanged")
    static let credentialsChanged = Notification.Name("AstationCredentialsChanged")
    static let relayAccountChanged = Notification.Name("AstationRelayAccountChanged")
    static let relayEncryptionChanged = Notification.Name("AstationRelayEncryptionChanged")
}
