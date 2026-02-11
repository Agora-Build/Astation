import Cocoa
import Foundation

class AstationApp: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    var webSocketServer: AstationWebSocketServer!
    var hubManager: AstationHubManager!
    private var authGrantController: AuthGrantController?
    private var hotkeyManager: HotkeyManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🔧 Initializing Astation components...")

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
            print("🌐 WebSocket server started on ws://127.0.0.1:8080")
        } catch {
            print("❌ Failed to start WebSocket server: \(error)")
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

        print("🎉 Astation fully operational!")
        print("📡 Ready for Atem connections on ws://127.0.0.1:8080")
        print("⌨️  Global hotkeys: Ctrl+V (voice), Ctrl+Shift+V (video)")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("🛑 Shutting down Astation...")
        hotkeyManager?.unregisterAll()
        webSocketServer?.stop()
        print("👋 Astation terminated")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showStatus()
        return false
    }

    // MARK: - Deep Link Handling (astation:// URL scheme)

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            print("❌ Invalid URL event received")
            return
        }

        print("🔗 Received URL: \(urlString)")
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "astation" else { return }

        switch url.host {
        case "auth":
            handleAuthDeepLink(url)
        default:
            print("⚠️ Unknown deep link path: \(url.host ?? "nil")")
        }
    }

    private func handleAuthDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { dict, item in
            dict[item.name] = item.value
        } ?? [:]

        guard let sessionId = params["id"],
              let hostname = params["tag"] else {
            print("❌ Auth deep link missing required parameters (id, tag)")
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