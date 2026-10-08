import Cocoa
import Foundation

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hubManager: AstationHubManager
    private let webSocketServer: AstationWebSocketServer
    private let androidDeviceManager: AndroidDeviceManager
    private var statusMenu: NSMenu!
    private lazy var settingsWindowController = SettingsWindowController(hubManager: hubManager, hotkeyManager: hotkeyManager,
                                                                         recordingManager: recordingManager, dictationManager: dictationManager)
    private lazy var devConsoleController = DevConsoleController(hubManager: hubManager)
    private lazy var projectsWindowController = ProjectsWindowController(hubManager: hubManager)
    private lazy var joinChannelWindowController = JoinChannelWindowController(hubManager: hubManager)
    private lazy var connectionsWindowController = ConnectionsWindowController(hubManager: hubManager, androidDeviceManager: androidDeviceManager)
    let hotkeyManager: HotkeyManager
    let recordingManager: AudioRecordingManager
    let dictationManager: VoiceDictationManager
    private var headerTapCount = 0
    private var lastHeaderTapTime: Date?

    init(hubManager: AstationHubManager, webSocketServer: AstationWebSocketServer, androidDeviceManager: AndroidDeviceManager,
         hotkeyManager: HotkeyManager, recordingManager: AudioRecordingManager = AudioRecordingManager(),
         dictationManager: VoiceDictationManager? = nil) {
        self.hubManager = hubManager
        self.webSocketServer = webSocketServer
        self.androidDeviceManager = androidDeviceManager
        self.hotkeyManager = hotkeyManager
        self.recordingManager = recordingManager
        self.dictationManager = dictationManager ?? VoiceDictationManager(transcription: recordingManager.transcription,
            resolveTarget: { [weak hubManager] in hubManager?.routeToFocusedAtem() },
            sendText: { [weak hubManager] text, target in
                guard let hubManager, hubManager.connectedClients.contains(where: { $0.id == target && $0.clientType == "Atem" }),
                      let send = hubManager.sendHandler else { return false }
                send(.voiceCommand(text: text, isFinal: true), target)
                return true
            })
        hubManager.rtcManager.microphoneDeviceUID = { [weak recordingManager] in recordingManager?.settings.microphoneUID }
        super.init()
        setupStatusBar()
        recordingManager.onStateChanged = { [weak self] in self?.updateRecordingIndicator() }
        hotkeyManager.additionalMenus = { [weak self] in
            guard let menu = self?.statusMenu else { return [] }
            // Reserve contextual commands even while their menu items are hidden.
            let contextual = NSMenu()
            for (title, key) in [("Join Channel", "j"), ("Leave Channel", "l"),
                                 ("Toggle Mic", "m"), ("Create Share Link", "s")] {
                contextual.addItem(withTitle: title, action: nil, keyEquivalent: key)
            }
            return [menu, contextual]
        }
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
        // Availability depends on capture/RTC state, not just the presence of an action.
        statusMenu.autoenablesItems = false
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

        if let relayIdentityWarning = hubManager.relayIdentityStatusMessage {
            let relayIdentityItem = NSMenuItem(
                title: "⚠️ \(relayIdentityWarning)",
                action: nil,
                keyEquivalent: ""
            )
            relayIdentityItem.isEnabled = false
            statusMenu.addItem(relayIdentityItem)
        }

        let projectTitle: String
        if let selected = hubManager.selectedProject {
            projectTitle = "📋 Project: \(selected.name)"
        } else {
            projectTitle = "📋 Projects: \(systemStatus.projects) loaded"
        }
        let projectsItem = NSMenuItem(
            title: projectTitle,
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

        // Local audio recording
        let recordingItem = NSMenuItem(title: recordingManager.isRecording ? "Stop Audio Recording" : "Start Audio Recording",
                                       action: #selector(toggleAudioRecording), keyEquivalent: "")
        recordingItem.target = self
        recordingItem.isEnabled = recordingManager.state != .starting
        recordingItem.image = NSImage(systemSymbolName: recordingManager.isRecording ? "stop.circle.fill" : "record.circle", accessibilityDescription: "Audio Recording")
        statusMenu.addItem(recordingItem)
        if recordingManager.isRecording {
            let pause = NSMenuItem(title: recordingManager.state == .paused ? "Resume Audio Recording" : "Pause Audio Recording",
                                   action: #selector(pauseAudioRecording), keyEquivalent: "")
            pause.target = self
            statusMenu.addItem(pause)
        }
        let audioSettings = NSMenuItem(title: "Audio & Recording...", action: #selector(openRecordingSettings), keyEquivalent: "")
        audioSettings.target = self
        statusMenu.addItem(audioSettings)
        statusMenu.addItem(.separator())

        // Voice Dictation Section
        let vcm = dictationManager
        let voiceDictationHeader = NSMenuItem(title: "Voice Dictation", action: nil, keyEquivalent: "")
        voiceDictationHeader.isEnabled = false
        statusMenu.addItem(voiceDictationHeader)

        let captionsTitle = recordingManager.transcription.floatingCaptionsVisible ? "Hide Floating Captions" : "Show Floating Captions"
        let showCaptions = NSMenuItem(title: captionsTitle, action: #selector(toggleFloatingCaptions), keyEquivalent: "")
        showCaptions.target = self
        showCaptions.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Floating Captions")
        statusMenu.addItem(showCaptions)
        let dictationSettings = NSMenuItem(title: "Voice Dictation Settings...", action: #selector(openDictationSettings), keyEquivalent: "")
        dictationSettings.target = self
        statusMenu.addItem(dictationSettings)

        switch vcm.mode {
        case .off:
            statusMenu.addItem(StatusBarMediaMenu.dictationHint(shortcut: hotkeyManager.bindings.voice?.displayName,
                                                              unavailableReason: vcm.unavailableReason))

            if hotkeyManager.voiceHotkeyFailed {
                let warn = NSMenuItem(title: "  ⚠ \(hotkeyManager.shortcutLabel(for: .voice)) unavailable - check Settings", action: nil, keyEquivalent: "")
                warn.isEnabled = false
                statusMenu.addItem(warn)
            }

            let handsFreeItem = NSMenuItem(
                title: "Start Hands-Free Mode",
                action: #selector(startHandsFreeMode),
                keyEquivalent: ""
            )
            handsFreeItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hands-Free")
            handsFreeItem.target = self
            handsFreeItem.isEnabled = vcm.isAvailable
            handsFreeItem.toolTip = vcm.unavailableReason ?? "Listen to the local microphone continuously. Outputs: \(vcm.settings.outputSummary)."
            statusMenu.addItem(handsFreeItem)

        case .ptt:
            let pttItem = NSMenuItem(
                title: vcm.isPolishing ? "Dictation (PTT): Polishing..." : vcm.isWaitingForResponse ? "Dictation (PTT): Finishing..." : "Dictation (PTT): Listening",
                action: nil,
                keyEquivalent: ""
            )
            pttItem.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "PTT Active")
            pttItem.isEnabled = false
            statusMenu.addItem(pttItem)

        case .handsFree:
            let hfItem = NSMenuItem(
                title: vcm.isWaitingForResponse ? "Hands-Free Dictation: Finishing..." : "Hands-Free Dictation: Listening",
                action: nil,
                keyEquivalent: ""
            )
            hfItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hands-Free Active")
            hfItem.isEnabled = false
            statusMenu.addItem(hfItem)

            let stopItem = NSMenuItem(
                title: "Stop Hands-Free Mode",
                action: #selector(stopHandsFreeMode),
                keyEquivalent: ""
            )
            stopItem.target = self
            statusMenu.addItem(stopItem)
        }

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

        statusMenu.addItem(NSMenuItem.separator())

        // RTC Status Section
        let rtcHeader = NSMenuItem(title: "RTC Media", action: nil, keyEquivalent: "")
        rtcHeader.isEnabled = false
        statusMenu.addItem(rtcHeader)

        let rtc = hubManager.rtcManager
        let micStatus = rtc.isMicMuted ? "Not publishing" : rtc.microphonePublisher.isCapturing
            ? (rtc.isInChannel ? "Publishing" : "Listening (RTC disconnected)") : "Off"
        let micIndicator = hubManager.rtcManager.isMicMuted ? "mic.slash" : "mic.fill"
        let micItem = NSMenuItem(
            title: "RTC Mic: \(micStatus)",
            action: nil,
            keyEquivalent: ""
        )
        micItem.image = NSImage(systemSymbolName: micIndicator, accessibilityDescription: "Microphone")
        micItem.isEnabled = false
        statusMenu.addItem(micItem)

        let rtcMicToggle = NSMenuItem(title: rtc.isMicMuted || !rtc.microphonePublisher.isCapturing ? "Enable RTC Mic Publishing" : "Mute RTC Mic Publishing",
            action: #selector(toggleMic), keyEquivalent: "m")
        rtcMicToggle.target = self
        rtcMicToggle.toolTip = "Only changes RTC publishing. Local transcription and original recording continue."
        statusMenu.addItem(rtcMicToggle)
        if rtc.microphonePublisher.isCapturing || rtc.microphonePublisher.isPreparing {
            let stopCapture = NSMenuItem(title: "Release RTC Microphone", action: #selector(releaseRTCMicrophone), keyEquivalent: "")
            stopCapture.target = self
            stopCapture.toolTip = "Release RTC's microphone capture. Other audio features retain their own capture."
            statusMenu.addItem(stopCapture)
        }
        let noise = NSMenuItem(title: "RTC Noise Reduction", action: nil, keyEquivalent: "")
        let noiseMenu = NSMenu()
        for mode in RTCNoiseReduction.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(changeRTCNoiseReduction(_:)), keyEquivalent: "")
            option.target = self; option.tag = Int(mode.rawValue)
            option.state = mode == rtc.noiseReduction ? .on : .off
            noiseMenu.addItem(option)
        }
        noise.submenu = noiseMenu; statusMenu.addItem(noise)
        if let message = rtc.audioProcessingMessage {
            let warning = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            warning.isEnabled = false; statusMenu.addItem(warning)
        }

        statusMenu.addItem(StatusBarMediaMenu.screenShareItem(shortcut: hotkeyManager.bindings.video?.displayName,
            isInChannel: rtc.isInChannel, isSharing: rtc.isScreenSharing, isStarting: rtc.isScreenShareStarting,
            target: self, startAction: #selector(startScreenShare), stopAction: #selector(stopScreenShare)))
        if hotkeyManager.videoHotkeyFailed {
            let warn = NSMenuItem(title: "Screen Share shortcut (\(hotkeyManager.shortcutLabel(for: .video))) unavailable - check Settings",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            statusMenu.addItem(warn)
        }

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
            ? "🔌 Connections (\(onlineCount) Atem online)"
            : "🔌 Connections"
        let showClientsItem = NSMenuItem(
            title: clientsTitle,
            action: #selector(showClientsAndAgents),
            keyEquivalent: "k"
        )
        showClientsItem.target = self
        statusMenu.addItem(showClientsItem)

        // Pair Remote Atem
        let pairRemoteItem = NSMenuItem(
            title: "📡 Pair Remote Atem",
            action: #selector(pairRemoteAtem),
            keyEquivalent: "r"
        )
        pairRemoteItem.keyEquivalentModifierMask = [.control]
        pairRemoteItem.target = self
        statusMenu.addItem(pairRemoteItem)

        statusMenu.addItem(NSMenuItem.separator())
        
        // Server Info Section
        let serverHeader = NSMenuItem(title: "Server Info", action: nil, keyEquivalent: "")
        serverHeader.isEnabled = false
        statusMenu.addItem(serverHeader)

        let wsUrl = "ws://127.0.0.1:8080/ws"
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

        // Agora Account (Sign in / Sign out)
        let acctTitle: String
        if hubManager.hasSession {
            let id = hubManager.currentSession()?.loginId ?? "—"
            acctTitle = "Sign out (\(id))"
        } else {
            acctTitle = "Sign in with Agora…"
        }
        let acctItem = NSMenuItem(title: acctTitle, action: #selector(signInOrOut), keyEquivalent: "")
        acctItem.target = self
        statusMenu.addItem(acctItem)
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
    
    @objc private func pairRemoteAtem() {
        Log.info(" Pair Remote Atem requested from status bar")

        let alert = NSAlert()
        alert.messageText = "Pair Remote Atem"
        alert.informativeText = "Enter the relay pairing code shown by 'atem pair':"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "e.g. ABCD-1234"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let code = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else {
            Log.warn(" Pair Remote Atem: empty code entered")
            return
        }

        Log.info(" Pair Remote Atem: connecting with code \(code)")
        hubManager.connectToRelay(code: code)
    }

    @objc private func copyWebSocketURL() {
        let url = "ws://127.0.0.1:8080/ws"
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
        let newState = !hubManager.rtcManager.isMicMuted && hubManager.rtcManager.microphonePublisher.isCapturing
        hubManager.rtcManager.muteMic(newState)
        setupMenu()
    }

    @objc private func releaseRTCMicrophone() { hubManager.rtcManager.stopMicrophoneCapture(); setupMenu() }
    @objc private func changeRTCNoiseReduction(_ sender: NSMenuItem) {
        guard let mode = RTCNoiseReduction(rawValue: Int32(sender.tag)) else { return }
        hubManager.rtcManager.setNoiseReduction(mode); setupMenu()
    }

    @objc private func startScreenShare() {
        promptForScreenShareOptions { [weak self] source, useRegion, options in
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
                    Task { @MainActor in
                        let started = await self.hubManager.rtcManager.startScreenShare(
                            displayId: source.id, regionPixels: regionPixels, options: options
                        )
                        if !started, !self.hubManager.rtcManager.isScreenSharing,
                           !self.hubManager.rtcManager.isScreenShareStarting {
                            ScreenRegionSelector.hideOverlay()
                        }
                        self.setupMenu()
                    }
                }
            } else {
                Task { @MainActor in
                    await self.hubManager.rtcManager.startScreenShare(displayId: source.id, options: options)
                    self.setupMenu()
                }
            }
        }
    }

    @objc private func stopScreenShare() {
        hubManager.rtcManager.stopScreenShare()
        setupMenu()
    }

    private func promptForScreenShareOptions(completion: @escaping (ScreenShareSource, Bool, ScreenShareOptions) -> Void) {
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
        alert.informativeText = "Share at native resolution. 60 fps targets smoother motion; actual frame rate depends on your Mac and connection."

        let accessoryWidth: CGFloat = 320
        let accessoryHeight: CGFloat = 118
        let savedOptions = ScreenShareOptions.load()
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
        checkbox.frame = NSRect(x: 0, y: 66, width: accessoryWidth, height: 18)

        let audioCheckbox = NSButton(checkboxWithTitle: "Include system audio", target: nil, action: nil)
        audioCheckbox.state = savedOptions.captureAudio ? .on : .off
        audioCheckbox.frame = NSRect(x: 0, y: 40, width: accessoryWidth, height: 18)
        audioCheckbox.toolTip = "Shares other apps' audio. Your microphone has a separate mute control."
        let frameRateLabel = NSTextField(labelWithString: "Frame rate:")
        frameRateLabel.frame = NSRect(x: 0, y: 3, width: 90, height: 20)
        let frameRatePopup = NSPopUpButton(frame: NSRect(x: 92, y: 0, width: 220, height: 26))
        frameRatePopup.addItems(withTitles: ["60 fps", "30 fps"])
        frameRatePopup.selectItem(at: savedOptions.frameRate == 30 ? 1 : 0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))
        popup.autoresizingMask = [.width]
        checkbox.autoresizingMask = [.width]
        container.addSubview(popup)
        container.addSubview(checkbox)
        container.addSubview(audioCheckbox)
        container.addSubview(frameRateLabel)
        container.addSubview(frameRatePopup)

        alert.accessoryView = container
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let options = ScreenShareOptions(
                captureAudio: audioCheckbox.state == .on,
                frameRate: frameRatePopup.indexOfSelectedItem == 1 ? 30 : 60
            )
            options.save()
            completion(sources[popup.indexOfSelectedItem], checkbox.state == .on, options)
        }
    }

    private func displayPixelSize(for source: ScreenShareSource) -> CGSize? {
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

    @objc private func startHandsFreeMode() {
        dictationManager.startHandsFree()
        setupMenu()
    }

    @objc private func stopHandsFreeMode() {
        dictationManager.stopHandsFree()
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

    @objc private func signInOrOut() {
        if hubManager.hasSession {
            try? hubManager.sessionStore.delete()
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } else {
            Task { @MainActor in
                do {
                    let mgr = SsoAuthManager(ssoUrl: SsoConfig.currentSsoUrl)
                    let session = try await mgr.runLoginFlow()
                    try hubManager.sessionStore.save(session)
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                } catch {
                    Log.error("[StatusBar] sign-in failed: \(error)")
                }
            }
        }
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow()
    }

    @objc private func openRecordingSettings() { settingsWindowController.showRecording() }
    @objc private func openDictationSettings() { settingsWindowController.showDictation() }
    @objc private func toggleFloatingCaptions() { recordingManager.transcription.toggleFloatingCaptions() }
    @objc private func toggleAudioRecording() {
        if recordingManager.isRecording { recordingManager.stopRecording() }
        else { settingsWindowController.showRecording(); recordingManager.startRecording() }
        setupMenu()
    }
    @objc private func pauseAudioRecording() { recordingManager.togglePause(); setupMenu() }

    private func updateRecordingIndicator() {
        guard let button = statusItem.button else { return }
        let recording = recordingManager.isRecording
        button.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "antenna.radiowaves.left.and.right", accessibilityDescription: recording ? "Astation recording audio" : "Astation")
        button.contentTintColor = recording ? (recordingManager.state == .paused ? .systemOrange : .systemRed) : nil
        button.toolTip = recording ? "Astation - audio recording \(recordingManager.state == .paused ? "paused" : "active")" : "Astation - AI Work Suite Hub"
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
