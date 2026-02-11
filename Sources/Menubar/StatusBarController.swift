import Cocoa
import Foundation

class StatusBarController {
    private var statusItem: NSStatusItem!
    private let hubManager: AstationHubManager
    private let webSocketServer: AstationWebSocketServer
    private var statusMenu: NSMenu!
    private lazy var settingsWindowController = SettingsWindowController(credentialManager: hubManager.credentialManager)
    private lazy var devConsoleController = DevConsoleController(hubManager: hubManager)
    private var headerTapCount = 0
    private var lastHeaderTapTime: Date?

    init(hubManager: AstationHubManager, webSocketServer: AstationWebSocketServer) {
        self.hubManager = hubManager
        self.webSocketServer = webSocketServer
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
        
        // Create menu
        statusMenu = NSMenu()
        setupMenu()
        statusItem.menu = statusMenu
        
        print("📊 Status bar controller initialized")
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
        
        let claudeStatusItem = NSMenuItem(
            title: "🤖 Claude: \(systemStatus.claudeRunning ? "Running" : "Idle")",
            action: nil,
            keyEquivalent: ""
        )
        claudeStatusItem.isEnabled = false
        statusMenu.addItem(claudeStatusItem)
        
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
                let focusIndicator = client.isFocused ? "[active]" : "[idle]"
                let displayName = client.hostname == "unknown" ? client.id.prefix(8) + "..." : client.hostname
                let instanceItem = NSMenuItem(
                    title: "  \(focusIndicator) \(displayName)",
                    action: nil,
                    keyEquivalent: ""
                )
                instanceItem.isEnabled = false
                if client.isFocused {
                    instanceItem.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Active")
                } else {
                    instanceItem.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Idle")
                }
                statusMenu.addItem(instanceItem)
            }
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
                    title: "Start Screen Share",
                    action: #selector(startScreenShare),
                    keyEquivalent: ""
                )
                startShareItem.target = self
                statusMenu.addItem(startShareItem)
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

        // Launch Claude Code
        let launchClaudeItem = NSMenuItem(
            title: "Launch Claude Code",
            action: #selector(launchClaudeCode),
            keyEquivalent: "c"
        )
        launchClaudeItem.target = self
        statusMenu.addItem(launchClaudeItem)
        
        // Show Projects
        let showProjectsItem = NSMenuItem(
            title: "📋 Show Projects",
            action: #selector(showProjects),
            keyEquivalent: "p"
        )
        showProjectsItem.target = self
        statusMenu.addItem(showProjectsItem)
        
        // Show Connections
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
        
        let wsServerItem = NSMenuItem(
            title: "🌐 WebSocket: ws://127.0.0.1:8080/ws",
            action: #selector(copyWebSocketURL),
            keyEquivalent: ""
        )
        wsServerItem.target = self
        statusMenu.addItem(wsServerItem)
        
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
    
    @objc private func launchClaudeCode() {
        print("🤖 Launch Claude Code requested from status bar")
        let success = hubManager.launchClaudeCode()
        
        let alert = NSAlert()
        if success {
            alert.messageText = "Claude Code Launched"
            alert.informativeText = "Claude Code has been launched successfully."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Launch Failed"
            alert.informativeText = "Failed to launch Claude Code. Please check if it's installed."
            alert.alertStyle = .warning
        }
        alert.runModal()
        
        // Refresh menu to update status
        setupMenu()
    }
    
    @objc private func showProjects() {
        print("📋 Show projects requested from status bar")
        let projects = hubManager.getProjects()

        let alert = NSAlert()
        alert.messageText = "Agora Projects (\(projects.count))"

        if let error = hubManager.projectLoadError {
            alert.informativeText = "Failed to load projects: \(error)\n\nCheck your credentials in Settings."
            alert.alertStyle = .warning
        } else if projects.isEmpty {
            alert.informativeText = "No projects found. Configure credentials in Settings."
            alert.alertStyle = .informational
        } else {
            let projectList = projects.map { project in
                "• \(project.name) (\(project.status))\n  App ID: \(project.vendorKey)"
            }.joined(separator: "\n\n")
            alert.informativeText = projectList
            alert.alertStyle = .informational
        }

        alert.runModal()
    }
    
    @objc private func showConnections() {
        print("🔌 Show connections requested from status bar")
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
        let url = "ws://127.0.0.1:8080/ws"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
        
        print("📋 WebSocket URL copied to clipboard: \(url)")
        
        let alert = NSAlert()
        alert.messageText = "URL Copied"
        alert.informativeText = "WebSocket URL has been copied to clipboard:\n\(url)"
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    // MARK: - RTC Actions

    @objc private func joinRTCChannel() {
        let projects = hubManager.getProjects()
        guard let project = projects.first else {
            let alert = NSAlert()
            alert.messageText = "No Projects"
            alert.informativeText = "No Agora projects available. Configure credentials in Settings and ensure you have at least one project."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Initialize RTC engine if needed, then join a default channel
        hubManager.initializeRTC(appId: project.vendorKey)
        let uid = UInt32.random(in: 1000...9999)
        hubManager.joinRTCChannel(channel: "astation-default", uid: uid)

        setupMenu()
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
        hubManager.rtcManager.startScreenShare(displayId: 0)
        setupMenu()
    }

    @objc private func stopScreenShare() {
        hubManager.rtcManager.stopScreenShare()
        setupMenu()
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
            print("[StatusBar] Dev Console activated via 5-tap")
            devConsoleController.showWindow()
        }
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow()
    }

    @objc private func quitApplication() {
        print("🛑 Quit requested from status bar")
        NSApp.terminate(nil)
    }
    
    func showStatus() {
        print("📊 Status bar menu opened")
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