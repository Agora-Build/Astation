import Cocoa
import Foundation

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hubManager: AstationHubManager
    private let webSocketServer: AstationWebSocketServer
    private var statusMenu: NSMenu!
    private lazy var settingsWindowController = SettingsWindowController(credentialManager: hubManager.credentialManager)
    private lazy var devConsoleController = DevConsoleController(hubManager: hubManager)
    private lazy var projectsWindowController = ProjectsWindowController(hubManager: hubManager)
    private lazy var joinChannelWindowController = JoinChannelWindowController(hubManager: hubManager)
    private lazy var connectionsWindowController = ConnectionsWindowController(hubManager: hubManager)
    private var headerTapCount = 0
    private var lastHeaderTapTime: Date?

    init(hubManager: AstationHubManager, webSocketServer: AstationWebSocketServer) {
        self.hubManager = hubManager
        self.webSocketServer = webSocketServer
        super.init()
        setupStatusBar()
    }
    
    private func setupStatusBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Set the status bar button image
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Astation")
            button.toolTip = "Astation - AI Work Suite Hub"
        }
        
        // Create menu (rebuilt on every open via NSMenuDelegate)
        statusMenu = NSMenu()
        statusMenu.delegate = self
        setupMenu()
        statusItem.menu = statusMenu
        
        Log.info(" Status bar controller initialized")
    }
    
    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Log.info("Menu opening — isInChannel=\(hubManager.rtcManager.isInChannel), channel=\(hubManager.rtcManager.currentChannel ?? "nil"), uid=\(hubManager.rtcManager.currentUid)")
        setupMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        setupMenu()
    }

    private func setupMenu() {
        statusMenu.removeAllItems()
        
        // Header (clickable — 5 taps opens Dev Console)
        let headerItem = NSMenuItem(title: "🚀 Astation Hub", action: #selector(handleHeaderTap), keyEquivalent: "")
        headerItem.target = self
        statusMenu.addItem(headerItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // System Status Section
        let systemStatus = hubManager.getSystemStatus()
        let statusItem = NSMenuItem(
            title: "📊 Status: \(webSocketServer.getConnectedClientsCount()) clients connected",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        statusMenu.addItem(statusItem)
        
        let projectsItem = NSMenuItem(
            title: "📋 Projects: \(systemStatus.projects) loaded",
            action: nil,
            keyEquivalent: ""
        )
        projectsItem.isEnabled = false
        statusMenu.addItem(projectsItem)
        
        let uptimeHours = systemStatus.uptimeSeconds / 3600
        let uptimeMinutes = (systemStatus.uptimeSeconds % 3600) / 60
        let uptimeItem = NSMenuItem(
            title: "⏱️ Uptime: \(uptimeHours)h \(uptimeMinutes)m",
            action: nil,
            keyEquivalent: ""
        )
        uptimeItem.isEnabled = false
        statusMenu.addItem(uptimeItem)
        
        statusMenu.addItem(NSMenuItem.separator())

        // Hotkey State Section
        let hotkeyHeader = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
        hotkeyHeader.isEnabled = false
        statusMenu.addItem(hotkeyHeader)

        let voiceState = hubManager.voiceActive ? "Active" : "Muted"
        let voiceIcon = hubManager.voiceActive ? "mic.fill" : "mic.slash"
        let voiceItem = NSMenuItem(
            title: "Voice (Ctrl+V): \(voiceState)",
            action: #selector(toggleVoiceHotkey),
            keyEquivalent: ""
        )
        voiceItem.image = NSImage(systemSymbolName: voiceIcon, accessibilityDescription: "Voice")
        voiceItem.target = self
        statusMenu.addItem(voiceItem)

        let videoState = hubManager.videoActive ? "Sharing" : "Off"
        let videoIcon = hubManager.videoActive ? "video.fill" : "video.slash"
        let videoItem = NSMenuItem(
            title: "Video (Ctrl+Shift+V): \(videoState)",
            action: #selector(toggleVideoHotkey),
            keyEquivalent: ""
        )
        videoItem.image = NSImage(systemSymbolName: videoIcon, accessibilityDescription: "Video")
        videoItem.target = self
        statusMenu.addItem(videoItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Connected Atems Section
        let atemHeader = NSMenuItem(title: "Connected Atems", action: nil, keyEquivalent: "")
        atemHeader.isEnabled = false
        statusMenu.addItem(atemHeader)

        let atemClients = hubManager.connectedClients.filter { $0.clientType == "Atem" }
        if atemClients.isEmpty {
            let noneItem = NSMenuItem(title: "  (no Atem instances)", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            statusMenu.addItem(noneItem)
        } else {
            for client in atemClients {
                let isPinned = hubManager.pinnedClientId == client.id
                let isActive = isPinned || (hubManager.pinnedClientId == nil && client.isFocused)
                let indicator = isPinned ? "★" : (isActive ? "●" : "○")
                let displayName = client.hostname == "unknown"
                    ? String(client.id.prefix(8)) + "..."
                    : client.hostname
                let instanceItem = NSMenuItem(
                    title: "  \(indicator) \(displayName)",
                    action: #selector(showClientsAndAgents),
                    keyEquivalent: ""
                )
                instanceItem.target = self
                if isActive {
                    instanceItem.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Active")
                } else {
                    instanceItem.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Idle")
                }
                statusMenu.addItem(instanceItem)
            }
        }
        // Show offline count if any
        if !hubManager.offlineClients.isEmpty {
            let offlineItem = NSMenuItem(
                title: "  ⊘ \(hubManager.offlineClients.count) offline",
                action: #selector(showClientsAndAgents),
                keyEquivalent: ""
            )
            offlineItem.target = self
            statusMenu.addItem(offlineItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        // RTC Status Section
        let rtcHeader = NSMenuItem(title: "RTC Media", action: nil, keyEquivalent: "")
        rtcHeader.isEnabled = false
        statusMenu.addItem(rtcHeader)

        let micStatus = hubManager.rtcManager.isMicMuted ? "Muted" : "Active"
        let micIndicator = hubManager.rtcManager.isMicMuted ? "mic.slash" : "mic.fill"
        let micItem = NSMenuItem(
            title: "Mic: \(micStatus)",
            action: nil,
            keyEquivalent: ""
        )
        micItem.image = NSImage(systemSymbolName: micIndicator, accessibilityDescription: "Microphone")
        micItem.isEnabled = false
        statusMenu.addItem(micItem)

        let screenStatus = hubManager.rtcManager.isScreenSharing ? "Sharing" : "Off"
        let screenIndicator = hubManager.rtcManager.isScreenSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle"
        let screenItem = NSMenuItem(
            title: "Screen Share: \(screenStatus)",
            action: nil,
            keyEquivalent: ""
        )
        screenItem.image = NSImage(systemSymbolName: screenIndicator, accessibilityDescription: "Screen Share")
        screenItem.isEnabled = false
        statusMenu.addItem(screenItem)

        let channelStatus = hubManager.rtcManager.isInChannel ? "Connected" : "Not Connected"
        let channelIndicator = hubManager.rtcManager.isInChannel ? "phone.fill" : "phone"
        let channelItem = NSMenuItem(
            title: "Channel: \(channelStatus)",
            action: nil,
            keyEquivalent: ""
        )
        channelItem.image = NSImage(systemSymbolName: channelIndicator, accessibilityDescription: "Channel")
        channelItem.isEnabled = false
        statusMenu.addItem(channelItem)

        // RTC Action Items
        if hubManager.rtcManager.isInChannel {
            let leaveItem = NSMenuItem(
                title: "Leave Channel",
                action: #selector(leaveRTCChannel),
                keyEquivalent: "l"
            )
            leaveItem.target = self
            statusMenu.addItem(leaveItem)

            let toggleMicTitle = hubManager.rtcManager.isMicMuted ? "Unmute Mic" : "Mute Mic"
            let toggleMicItem = NSMenuItem(
                title: toggleMicTitle,
                action: #selector(toggleMic),
                keyEquivalent: "m"
            )
            toggleMicItem.target = self
            statusMenu.addItem(toggleMicItem)

            if hubManager.rtcManager.isScreenSharing {
                let stopShareItem = NSMenuItem(
                    title: "Stop Screen Share",
                    action: #selector(stopScreenShare),
                    keyEquivalent: ""
                )
                stopShareItem.target = self
                statusMenu.addItem(stopShareItem)
            } else {
                let startShareItem = NSMenuItem(
                    title: "Start Screen Share…",
                    action: #selector(startScreenShare),
                    keyEquivalent: ""
                )
                startShareItem.target = self
                statusMenu.addItem(startShareItem)
            }

            // Share Session Section
            let linkManager = hubManager.sessionLinkManager
            let linkCount = linkManager.activeLinks.count
            let shareHeader = NSMenuItem(
                title: "Share Links (\(linkCount)/\(linkManager.maxLinks))",
                action: nil,
                keyEquivalent: ""
            )
            shareHeader.isEnabled = false
            statusMenu.addItem(shareHeader)

            if linkManager.canCreateMore {
                let createLinkItem = NSMenuItem(
                    title: "Create Share Link",
                    action: #selector(createShareLink),
                    keyEquivalent: "s"
                )
                createLinkItem.target = self
                statusMenu.addItem(createLinkItem)
            }

            for link in linkManager.activeLinks {
                let linkSubmenu = NSMenu()

                let copyItem = NSMenuItem(
                    title: "Copy URL",
                    action: #selector(copyShareLinkURL(_:)),
                    keyEquivalent: ""
                )
                copyItem.target = self
                copyItem.representedObject = link.url
                linkSubmenu.addItem(copyItem)

                let revokeItem = NSMenuItem(
                    title: "Revoke",
                    action: #selector(revokeShareLink(_:)),
                    keyEquivalent: ""
                )
                revokeItem.target = self
                revokeItem.representedObject = link.id
                linkSubmenu.addItem(revokeItem)

                let linkItem = NSMenuItem(
                    title: "  \(link.id.prefix(8))...",
                    action: nil,
                    keyEquivalent: ""
                )
                linkItem.submenu = linkSubmenu
                statusMenu.addItem(linkItem)
            }

            if !linkManager.activeLinks.isEmpty {
                let revokeAllItem = NSMenuItem(
                    title: "Revoke All Links",
                    action: #selector(revokeAllShareLinks),
                    keyEquivalent: ""
                )
                revokeAllItem.target = self
                statusMenu.addItem(revokeAllItem)
            }
        } else {
            let joinItem = NSMenuItem(
                title: "Join Channel...",
                action: #selector(joinRTCChannel),
                keyEquivalent: "j"
            )
            joinItem.target = self
            statusMenu.addItem(joinItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        // Actions Section
        let actionsHeader = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        actionsHeader.isEnabled = false
        statusMenu.addItem(actionsHeader)

        // Show Projects
        let showProjectsItem = NSMenuItem(
            title: "📋 Show Projects",
            action: #selector(showProjects),
            keyEquivalent: "p"
        )
        showProjectsItem.target = self
        statusMenu.addItem(showProjectsItem)

        // Show Clients & Agents
        let onlineCount = hubManager.connectedClients.filter { $0.clientType == "Atem" }.count
        let clientsTitle = onlineCount > 0
            ? "🔌 Clients & Agents (\(onlineCount) online)"
            : "🔌 Clients & Agents"
        let showClientsItem = NSMenuItem(
            title: clientsTitle,
            action: #selector(showClientsAndAgents),
            keyEquivalent: "k"
        )
        showClientsItem.target = self
        statusMenu.addItem(showClientsItem)

        // Show Connections (legacy developer panel)
        let showConnectionsItem = NSMenuItem(
            title: "🔌 Show Connections",
            action: #selector(showConnections),
            keyEquivalent: "n"
        )
        showConnectionsItem.target = self
        statusMenu.addItem(showConnectionsItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Server Info Section
        let serverHeader = NSMenuItem(title: "Server Info", action: nil, keyEquivalent: "")
        serverHeader.isEnabled = false
        statusMenu.addItem(serverHeader)

        let wsUrl = SettingsWindowController.currentAstationWs
        let wsServerItem = NSMenuItem(
            title: "🌐 WebSocket: \(wsUrl)",
            action: #selector(copyWebSocketURL),
            keyEquivalent: ""
        )
        wsServerItem.target = self
        statusMenu.addItem(wsServerItem)

        let stationUrl = SettingsWindowController.currentAstationRelayUrl
        let stationItem = NSMenuItem(
            title: "📡 Station: \(stationUrl)",
            action: #selector(copyStationURL),
            keyEquivalent: ""
        )
        stationItem.target = self
        statusMenu.addItem(stationItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        statusMenu.addItem(settingsItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Astation",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }
    
    @objc private func showProjects() {
        Log.info(" Show projects requested from status bar")
        projectsWindowController.showWindow()
    }

    @objc private func showClientsAndAgents() {
        Log.info(" Show clients & agents requested from status bar")
        connectionsWindowController.showAndFocus()
    }
    
    @objc private func showConnections() {
        Log.info(" Show connections requested from status bar")
        let clientCount = webSocketServer.getConnectedClientsCount()
        let clients = hubManager.connectedClients
        
        let alert = NSAlert()
        alert.messageText = "Connected Clients (\(clientCount))"
        
        let clientList = clients.map { client in
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "• \(client.clientType) (\(client.id.prefix(8))...)\n  Connected: \(formatter.string(from: client.connectedAt))"
        }.joined(separator: "\n\n")
        
        alert.informativeText = clientList.isEmpty ? "No clients connected" : clientList
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc private func copyWebSocketURL() {
        let url = SettingsWindowController.currentAstationWs
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)

        Log.info(" WebSocket URL copied to clipboard: \(url)")

        let alert = NSAlert()
        alert.messageText = "URL Copied"
        alert.informativeText = "WebSocket URL has been copied to clipboard:\n\(url)"
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func copyStationURL() {
        let url = SettingsWindowController.currentAstationRelayUrl
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)

        Log.info(" Station URL copied to clipboard: \(url)")

        let alert = NSAlert()
        alert.messageText = "URL Copied"
        alert.informativeText = "Station relay URL has been copied to clipboard:\n\(url)"
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    // MARK: - RTC Actions

    @objc private func joinRTCChannel() {
        let projects = hubManager.getProjects()
        guard !projects.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Projects"
            alert.informativeText = "No Agora projects available. Configure credentials in Settings and ensure you have at least one project."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        joinChannelWindowController.showWindow()
    }

    @objc private func leaveRTCChannel() {
        hubManager.leaveRTCChannel()
        setupMenu()
    }

    @objc private func toggleMic() {
        let newState = !hubManager.rtcManager.isMicMuted
        hubManager.rtcManager.muteMic(newState)
        setupMenu()
    }

    @objc private func startScreenShare() {
        promptForScreenShareOptions { [weak self] source, useRegion in
            guard let self = self else { return }
            if useRegion {
                guard let screen = self.matchNSScreen(for: source) else {
                    let alert = NSAlert()
                    alert.messageText = "Display Not Found"
                    alert.informativeText = "Unable to match the selected display. Try again."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                let scale = self.screenPixelScale(for: screen, source: source)
                ScreenRegionSelector.selectRegion(
                    on: screen,
                    displayId: source.id,
                    pixelsPerPoint: scale
                ) { regionPixels, regionPoints in
                    guard let regionPixels, let regionPoints else { return }
                    _ = ScreenRegionSelector.showOverlay(
                        on: screen,
                        displayId: source.id,
                        rectPoints: regionPoints
                    )
                    let started = self.hubManager.rtcManager.startScreenShare(
                        displayId: source.id,
                        regionPixels: regionPixels
                    )
                    if !started {
                        ScreenRegionSelector.hideOverlay()
                    }
                    self.setupMenu()
                }
            } else {
                self.hubManager.rtcManager.startScreenShare(displayId: source.id)
                self.setupMenu()
            }
        }
    }

    @objc private func stopScreenShare() {
        hubManager.rtcManager.stopScreenShare()
        setupMenu()
    }

    private func promptForScreenShareOptions(completion: @escaping (ScreenShareSource, Bool) -> Void) {
        let sources = hubManager.rtcManager.screenSources()
        guard !sources.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Displays Available"
            alert.informativeText = "Unable to fetch screen capture sources. Ensure the app has Screen Recording permission."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Start Screen Share"
        alert.informativeText = "Choose a display and optionally share a region."

        let accessoryWidth: CGFloat = 320
        let accessoryHeight: CGFloat = 54
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: accessoryHeight - 24, width: accessoryWidth, height: 24))
        popup.controlSize = .regular
        let primaryIndex = sources.firstIndex { $0.isPrimary } ?? 0
        for (index, source) in sources.enumerated() {
            var label = "Display \(index + 1)"
            if source.isPrimary {
                label += " (Primary)"
            }
            if let size = displayPixelSize(for: source) {
                label += " — \(Int(size.width))x\(Int(size.height))"
            }
            popup.addItem(withTitle: label)
        }
        popup.selectItem(at: primaryIndex)

        let checkbox = NSButton(checkboxWithTitle: "Share region only", target: nil, action: nil)
        checkbox.state = .off
        checkbox.frame = NSRect(x: 0, y: 0, width: accessoryWidth, height: 18)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))
        popup.autoresizingMask = [.width]
        checkbox.autoresizingMask = [.width]
        container.addSubview(popup)
        container.addSubview(checkbox)

        alert.accessoryView = container
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            completion(sources[popup.indexOfSelectedItem], checkbox.state == .on)
        }
    }

    private func displayPixelSize(for source: ScreenShareSource) -> CGSize? {
        if let screen = screenForDisplayId(source.id) {
            let scale = screen.backingScaleFactor
            return CGSize(
                width: screen.frame.size.width * scale,
                height: screen.frame.size.height * scale
            )
        }
        if source.rectPixels.width > 0 && source.rectPixels.height > 0 {
            return source.rectPixels.size
        }
        return nil
    }

    private func screenPixelScale(for screen: NSScreen, source: ScreenShareSource) -> CGSize {
        let pointsSize = screen.frame.size
        if pointsSize.width > 0,
           pointsSize.height > 0,
           source.rectPixels.width > 0,
           source.rectPixels.height > 0 {
            let scaleX = source.rectPixels.width / pointsSize.width
            let scaleY = source.rectPixels.height / pointsSize.height
            if scaleX > 0.5, scaleY > 0.5 {
                return CGSize(width: scaleX, height: scaleY)
            }
        }
        let scale = screen.backingScaleFactor
        return CGSize(width: scale, height: scale)
    }

    private func screenForDisplayId(_ displayId: Int64) -> NSScreen? {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                if number.int64Value == displayId {
                    return screen
                }
            }
        }
        return nil
    }

    private func matchNSScreen(for source: ScreenShareSource) -> NSScreen? {
        if let screen = screenForDisplayId(source.id) {
            return screen
        }
        let target = source.rectPixels
        if target.width <= 0 || target.height <= 0 {
            return NSScreen.main
        }
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            let frame = screen.frame
            let pixelRect = CGRect(
                x: frame.origin.x * scale,
                y: frame.origin.y * scale,
                width: frame.size.width * scale,
                height: frame.size.height * scale
            )
            let deltaX = abs(pixelRect.origin.x - target.origin.x)
            let deltaY = abs(pixelRect.origin.y - target.origin.y)
            let deltaW = abs(pixelRect.size.width - target.size.width)
            let deltaH = abs(pixelRect.size.height - target.size.height)
            if deltaX < 2 && deltaY < 2 && deltaW < 2 && deltaH < 2 {
                return screen
            }
        }
        return NSScreen.main
    }

    @objc private func createShareLink() {
        Task {
            do {
                let link = try await hubManager.sessionLinkManager.createLink()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(link.url, forType: .string)

                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Share Link Created"
                    alert.informativeText = "Link copied to clipboard:\n\(link.url)"
                    alert.alertStyle = .informational
                    alert.runModal()
                    setupMenu()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Create Link"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    @objc private func copyShareLinkURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    @objc private func revokeShareLink(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? String else { return }
        guard let link = hubManager.sessionLinkManager.activeLinks.first(where: { $0.id == linkId }) else { return }
        Task {
            await hubManager.sessionLinkManager.revokeLink(link)
            await MainActor.run { setupMenu() }
        }
    }

    @objc private func revokeAllShareLinks() {
        Task {
            await hubManager.sessionLinkManager.revokeAll()
            await MainActor.run { setupMenu() }
        }
    }

    @objc private func toggleVoiceHotkey() {
        hubManager.toggleVoice()
        setupMenu()
    }

    @objc private func toggleVideoHotkey() {
        hubManager.toggleVideo()
        setupMenu()
    }

    @objc private func handleHeaderTap() {
        let now = Date()
        if let lastTap = lastHeaderTapTime, now.timeIntervalSince(lastTap) > 2.0 {
            headerTapCount = 0
        }
        headerTapCount += 1
        lastHeaderTapTime = now

        if headerTapCount >= 5 {
            headerTapCount = 0
            Log.info("[StatusBar] Dev Console activated via 5-tap")
            devConsoleController.showWindow()
        }
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow()
    }

    @objc private func quitApplication() {
        Log.info(" Quit requested from status bar")
        NSApp.terminate(nil)
    }
    
    func showStatus() {
        Log.info(" Status bar menu opened")
        setupMenu() // Refresh menu with current data
    }
    
    // Update status bar periodically
    func updateStatusBar() {
        DispatchQueue.main.async {
            let clientCount = self.webSocketServer.getConnectedClientsCount()
            let rtcStatus = self.hubManager.rtcManager.isInChannel ? " | RTC: Connected" : ""
            let voiceStatus = self.hubManager.voiceActive ? " | Voice: Active" : ""
            let videoStatus = self.hubManager.videoActive ? " | Video: Sharing" : ""
            if let button = self.statusItem.button {
                button.toolTip = "Astation - \(clientCount) client\(clientCount == 1 ? "" : "s") connected\(rtcStatus)\(voiceStatus)\(videoStatus)"
            }
        }
    }
}
