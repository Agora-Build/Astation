import Cocoa
import Foundation
import NIO
import CStationCore

struct StartupFailureAlertContent: Equatable {
    let title: String
    let message: String

    static func make(error: Error, port: Int) -> StartupFailureAlertContent {
        if isAddressAlreadyInUse(error) {
            return StartupFailureAlertContent(
                title: "Astation Could Not Start",
                message: "Port \(port) is already in use. Another Astation instance or application may already be running.\n\nClose it, then open Astation again."
            )
        }

        return StartupFailureAlertContent(
            title: "Astation Could Not Start",
            message: "The local connection server could not start on port \(port).\n\n\(diagnosticDescription(for: error))"
        )
    }

    private static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        if let ioError = error as? IOError {
            return ioError.errnoCode == EADDRINUSE
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE)
    }

    private static func diagnosticDescription(for error: Error) -> String {
        (error as? IOError)?.localizedDescription ?? error.localizedDescription
    }
}

class AstationApp: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    var webSocketServer: AstationWebSocketServer!
    var hubManager: AstationHubManager!
    private var authGrantController: AuthGrantController?
    private var hotkeyManager: HotkeyManager?
    private var androidDeviceManager: AndroidDeviceManager?
    private var audioRecordingManager: AudioRecordingManager?
    private var transcriptionToast: TranscriptionToastController?
    private var voiceDictationManager: VoiceDictationManager?
    
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

        // Direct and relay transports must authenticate against the same devices.
        let deviceSessionStore = SessionStore()
        hubManager = AstationHubManager(deviceSessionStore: deviceSessionStore)

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
        webSocketServer = AstationWebSocketServer(
            hubManager: hubManager,
            sessionStore: deviceSessionStore
        )
        
        // Initialize status bar
        let androidDevices = AndroidDeviceManager()
        androidDeviceManager = androidDevices
        let shortcuts = HotkeyManager()
        hotkeyManager = shortcuts
        let recorder = AudioRecordingManager()
        audioRecordingManager = recorder
        transcriptionToast = TranscriptionToastController(manager: recorder.transcription)
        recorder.transcription.cloudEngineFactory = { [weak hubManager] settings in
            guard let hubManager, let project = hubManager.effectiveProject, !project.signKey.isEmpty else {
                throw TranscriptionError.message("Sign in and select an Agora project with an App Certificate and Real-Time STT enabled.")
            }
            let channel = "astation-caption-\(UUID().uuidString)"
            let projectID = project.id
            let hubReference = WeakTranscriptionHub(hubManager)
            return AgoraCloudTranscriber(settings: settings, tokenProvider: {
                try await MainActor.run {
                    guard let hubManager = hubReference.value, let project = hubManager.getProjects().first(where: { $0.id == projectID }), !project.signKey.isEmpty else {
                        throw TranscriptionError.message("Agora project access expired. Sign in again.")
                    }
                    func token(uid: UInt32) throws -> String {
                        guard let ptr = astation_rtc_build_token(project.vendorKey, project.signKey, channel, uid, 1, 3600, 3600) else {
                            throw TranscriptionError.message("Could not generate an Agora caption token.")
                        }
                        defer { astation_token_free(ptr) }
                        let value = String(cString: ptr)
                        guard value.hasPrefix("007") else { throw TranscriptionError.message("Agora caption token generation failed.") }
                        return value
                    }
                    return AgoraTranscriptionTokens(appID: project.vendorKey, channel: channel, publisherUID: 101,
                                                     botUID: 201, publisherToken: try token(uid: 101), botToken: try token(uid: 201))
                }
            })
        }
        statusBarController = StatusBarController(hubManager: hubManager, webSocketServer: webSocketServer,
                                                androidDeviceManager: androidDevices, hotkeyManager: shortcuts,
                                                recordingManager: recorder)
        voiceDictationManager = statusBarController.dictationManager
        transcriptionToast?.attachDictation(statusBarController.dictationManager)
        
        // One listener supports offline loopback and authenticated LAN clients concurrently.
        let webSocketPort = 8080
        do {
            try webSocketServer.start(host: "0.0.0.0", port: webSocketPort)
            let localIP = getLocalNetworkIP() ?? "127.0.0.1"
            Log.info("WebSocket server started on all interfaces (port \(webSocketPort))")
            Log.info("  Local (same-user): ws://127.0.0.1:\(webSocketPort)/ws")
            Log.info("  LAN (paired):      ws://\(localIP):\(webSocketPort)/ws")
        } catch {
            Log.error("Failed to start WebSocket server: \(error)")
            showStartupFailure(error, port: webSocketPort)
            return
        }

        // Wire broadcast handler so hubManager can broadcast to all connected Atems
        hubManager.broadcastHandler = { [weak webSocketServer, weak hubManager] message in
            DispatchQueue.main.async {
                webSocketServer?.broadcastMessage(message)
                hubManager?.broadcastToAuthenticatedIdentityRelayClients(message)
            }
        }

        // Wire send handler so hubManager can send to a specific Atem by client ID
        hubManager.sendHandler = { [weak webSocketServer] message, clientId in
            webSocketServer?.sendMessageToClient(message, clientId: clientId)
        }

        // Start network monitoring to detect IP changes
        NetworkMonitor.shared.startMonitoring()

        // Connect the saved global shortcuts to voice and video actions.
        hotkeyManager?.onVoiceKeyDown = { [weak self] in
            let vcm = self?.voiceDictationManager
            if vcm?.mode == .off {
                vcm?.startPTT()
            }
            self?.statusBarController.showStatus()
        }
        hotkeyManager?.onVoiceKeyUp = { [weak self] in
            let vcm = self?.voiceDictationManager
            if vcm?.mode == .ptt {
                vcm?.stopPTT()
            }
            self?.statusBarController.showStatus()
        }
        hotkeyManager?.onVideoToggle = { [weak self] in
            self?.hubManager.toggleVideo()
            self?.statusBarController.showStatus()
        }
        hotkeyManager?.registerHotkeys()
        hotkeyManager?.onRecordingToggle = { [weak recorder] in recorder?.toggleRecording() }
        hotkeyManager?.onRecordingPause = { [weak recorder] in recorder?.togglePause() }
        hotkeyManager?.onFloatingCaptionsToggle = { [weak recorder] in recorder?.transcription.toggleFloatingCaptions() }
        hotkeyManager?.onHandsFreeDictationToggle = { [weak self] in
            guard let manager = self?.voiceDictationManager else { return }
            if manager.mode == .handsFree { manager.stopHandsFree() }
            else if manager.mode == .off { manager.startHandsFree() }
        }

        // Connect to relay using this Astation's identity, so Atem TUI can auto-reconnect
        // after the first `atem pair` without needing to pair again.
        hubManager.startIdentityRelay()

        Log.info("Astation fully operational!")
        Log.info("Global hotkeys: \(shortcuts.shortcutLabel(for: .voice)) (PTT voice dictation), \(shortcuts.shortcutLabel(for: .video)) (video)")
        Log.info("Log file: \(Log.logFile.path)")
    }

    private func showStartupFailure(_ error: Error, port: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showStartupFailure(error, port: port)
            }
            return
        }

        let content = StartupFailureAlertContent.make(error: error, port: port)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.runModal()
        NSApp.terminate(nil)
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
        voiceDictationManager?.cancel()
        hubManager?.rtcManager.stopMicrophoneCapture()
        audioRecordingManager?.shutdown()
        androidDeviceManager?.shutdown()
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
        case "pair":
            handlePairDeepLink(url)
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

    private func handlePairDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { dict, item in
            dict[item.name] = item.value
        } ?? [:]

        guard let code = params["code"], !code.isEmpty else {
            Log.error(" Pair deep link missing required 'code' parameter")
            return
        }

        Log.info(" Pair deep link received with code: \(code)")
        hubManager?.connectToRelay(code: code)
    }
}

/// The reference is only read on MainActor when refreshing cloud credentials.
private final class WeakTranscriptionHub: @unchecked Sendable {
    weak var value: AstationHubManager?
    init(_ value: AstationHubManager) { self.value = value }
}
