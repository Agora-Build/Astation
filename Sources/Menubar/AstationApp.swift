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
        
        // Start WebSocket server on all interfaces (0.0.0.0) so LAN clients can connect
        do {
            try webSocketServer.start(host: "0.0.0.0", port: 8080)
            let localIP = getLocalNetworkIP() ?? "127.0.0.1"
            Log.info("WebSocket server started on all interfaces (port 8080)")
            Log.info("  Local:   ws://127.0.0.1:8080")
            Log.info("  Network: ws://\(localIP):8080")
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

        // Start network monitoring to detect IP changes
        NetworkMonitor.shared.startMonitoring()

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
        Log.info("Global hotkeys: Ctrl+V (voice), Ctrl+Shift+V (video)")
        Log.info("Log file: \(Log.logFile.path)")
    }

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
}