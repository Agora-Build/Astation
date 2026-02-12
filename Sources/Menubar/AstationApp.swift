import Cocoa
import Foundation

class AstationApp: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    var webSocketServer: AstationWebSocketServer!
    var hubManager: AstationHubManager!
    private var authGrantController: AuthGrantController?
    private var hotkeyManager: HotkeyManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Initializing Astation components...")

        // Set up a main menu with Edit submenu so Cmd+C/V/X work in text fields.
        // Accessory apps don't get a default menu bar, so we create one manually.
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        // Initialize hub manager (business logic)
        hubManager = AstationHubManager()

        // Initialize auth grant controller for deep-link auth flow
        authGrantController = AuthGrantController()

        // Register for Apple Events (URL scheme handling for astation:// deep links)
        // NOTE: When packaging as a .app bundle, also register the URL scheme in Info.plist:
        //   CFBundleURLTypes -> CFBundleURLSchemes -> ["astation"]
        // The Apple Event handler approach works for development without Info.plist.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Initialize WebSocket server
        webSocketServer = AstationWebSocketServer(hubManager: hubManager)
        
        // Initialize status bar
        statusBarController = StatusBarController(hubManager: hubManager, webSocketServer: webSocketServer)
        
        // Start WebSocket server
        do {
            try webSocketServer.start(host: "127.0.0.1", port: 8080)
            Log.info("WebSocket server started on ws://127.0.0.1:8080")
        } catch {
            Log.error("Failed to start WebSocket server: \(error)")
            NSApp.terminate(nil)
            return
        }

        // Wire broadcast handler so hubManager can broadcast to all connected Atems
        hubManager.broadcastHandler = { [weak webSocketServer] message in
            webSocketServer?.broadcastMessage(message)
        }

        // Wire send handler so hubManager can send to a specific Atem by client ID
        hubManager.sendHandler = { [weak webSocketServer] message, clientId in
            webSocketServer?.sendMessageToClient(message, clientId: clientId)
        }

        // Initialize global hotkeys (Ctrl+V voice, Ctrl+Shift+V video)
        hotkeyManager = HotkeyManager()
        hotkeyManager?.onVoiceToggle = { [weak self] in
            self?.hubManager.toggleVoice()
            self?.statusBarController.showStatus()
        }
        hotkeyManager?.onVideoToggle = { [weak self] in
            self?.hubManager.toggleVideo()
            self?.statusBarController.showStatus()
        }
        hotkeyManager?.registerHotkeys()

        Log.info("Astation fully operational!")
        Log.info("Ready for Atem connections on ws://127.0.0.1:8080")
        Log.info("Global hotkeys: Ctrl+V (voice), Ctrl+Shift+V (video)")
        Log.info("Log file: \(Log.logFile.path)")

        handleAutoRTC()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Shutting down Astation...")
        hotkeyManager?.unregisterAll()
        webSocketServer?.stop()
        Log.info("Astation terminated")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showStatus()
        return false
    }

    // MARK: - Deep Link Handling (astation:// URL scheme)

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            Log.error(" Invalid URL event received")
            return
        }

        Log.info(" Received URL: \(urlString)")
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "astation" else { return }

        switch url.host {
        case "auth":
            handleAuthDeepLink(url)
        default:
            Log.warn(" Unknown deep link path: \(url.host ?? "nil")")
        }
    }

    private func handleAuthDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { dict, item in
            dict[item.name] = item.value
        } ?? [:]

        guard let sessionId = params["id"],
              let hostname = params["tag"] else {
            Log.error(" Auth deep link missing required parameters (id, tag)")
            return
        }

        let otp = params["otp"] ?? "N/A"

        let request = AuthRequest(
            sessionId: sessionId,
            hostname: hostname,
            otp: otp,
            timestamp: Date()
        )

        // Show the grant dialog on the main thread (modal NSAlert)
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let authController = self.authGrantController else { return }

            let session = authController.handleAuthRequest(request)

            // Notify hub manager of the auth result
            self.hubManager?.handleAuthResult(session)
        }
    }

    // MARK: - Auto RTC (diagnostics)

    private func handleAutoRTC() {
        let env = ProcessInfo.processInfo.environment
        guard env["ASTATION_AUTORUN"] == "1" else { return }

        let channel = (env["ASTATION_RTC_CHANNEL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let uidString = (env["ASTATION_RTC_UID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appId = (env["ASTATION_APP_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (env["ASTATION_RTC_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = (env["ASTATION_PROJECT_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (env["ASTATION_PROJECT_NAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !channel.isEmpty else {
            Log.warn("[AutoRTC] Missing ASTATION_RTC_CHANNEL")
            return
        }
        guard let uid = UInt32(uidString) else {
            Log.warn("[AutoRTC] Invalid ASTATION_RTC_UID: '\(uidString)'")
            return
        }

        if !appId.isEmpty && !token.isEmpty {
            Log.info("[AutoRTC] Initializing RTC and joining channel=\(channel) uid=\(uid)")
            hubManager.initializeRTC(appId: appId)
            hubManager.rtcManager.joinChannel(token: token, channel: channel, uid: uid)
            startAutoScreenShareIfNeeded(env: env)
            return
        }

        Task { @MainActor in
            Log.info("[AutoRTC] Resolving project from stored credentials...")
            let timeoutMs = Int(env["ASTATION_PROJECT_WAIT_MS"] ?? "6000") ?? 6000
            let projects = await waitForProjects(timeoutMs: timeoutMs)
            guard !projects.isEmpty else {
                let err = hubManager.projectLoadError ?? "no projects loaded"
                Log.warn("[AutoRTC] Cannot resolve project: \(err)")
                return
            }

            let selected: AgoraProject
            if !projectId.isEmpty,
               let match = projects.first(where: { $0.id == projectId || $0.vendorKey == projectId }) {
                selected = match
            } else if !projectName.isEmpty,
                      let match = projects.first(where: { $0.name.caseInsensitiveCompare(projectName) == .orderedSame }) {
                selected = match
            } else if !appId.isEmpty,
                      let match = projects.first(where: { $0.vendorKey == appId }) {
                selected = match
            } else {
                selected = projects[0]
            }

            guard !selected.vendorKey.isEmpty else {
                Log.warn("[AutoRTC] Selected project missing App ID")
                return
            }
            guard !selected.signKey.isEmpty else {
                Log.warn("[AutoRTC] Selected project missing App Certificate")
                return
            }

            Log.info("[AutoRTC] Using project '\(selected.name)' (appId=\(selected.vendorKey))")
            hubManager.initializeRTC(appId: selected.vendorKey)
            let tokenResponse = await hubManager.generateRTCToken(channel: channel, uid: Int(uid), projectId: selected.id)
            guard !tokenResponse.token.isEmpty else {
                Log.warn("[AutoRTC] Failed to generate RTC token")
                return
            }
            hubManager.rtcManager.joinChannel(token: tokenResponse.token, channel: channel, uid: uid)
            startAutoScreenShareIfNeeded(env: env)
        }
    }

    private func startAutoScreenShareIfNeeded(env: [String: String]) {
        if env["ASTATION_SCREEN_SHARE"] == "1" {
            let displayId = UInt32(env["ASTATION_SCREEN_SHARE_DISPLAY_ID"] ?? "0") ?? 0
            let delayMs = Int(env["ASTATION_SCREEN_SHARE_DELAY_MS"] ?? "1500") ?? 1500
            Log.info("[AutoRTC] Will start screen share displayId=\(displayId) in \(delayMs)ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                self?.hubManager.rtcManager.startScreenShare(displayId: displayId)
            }
        }
    }

    @MainActor
    private func waitForProjects(timeoutMs: Int) async -> [AgoraProject] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if !hubManager.projects.isEmpty {
                return hubManager.projects
            }
            if hubManager.projectLoadError != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return hubManager.projects
    }
}
