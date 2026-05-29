import Cocoa
import Foundation
import AVFoundation

class JoinChannelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager
    private let encryptionModes = RTCEncryptionMode.manualJoinPickerOptions
    private let geoFenceOptions = RTCGeoFence.manualJoinPickerOptions
    private var projectPicker: NSPopUpButton!
    private var channelField: NSTextField!
    private var uidField: NSTextField!
    private var roleControl: NSSegmentedControl!
    private var encryptionModePopup: NSPopUpButton!
    private var encryptionKeyField: NSSecureTextField!
    private var saltLabel: NSTextField!
    private var saltField: NSTextField!
    private var geoFencePopup: NSPopUpButton!
    private var joinButton: NSButton!
    private var statusLabel: NSTextField!

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshProjectPicker()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Join RTC Channel"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        let fieldWidth: CGFloat = 320
        var y: CGFloat = 390

        // Project picker
        let projectLabel = NSTextField(labelWithString: "Project:")
        projectLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(projectLabel)

        projectPicker = NSPopUpButton(frame: NSRect(x: 110, y: y - 2, width: fieldWidth, height: 26))
        contentView.addSubview(projectPicker)
        y -= 40

        // Channel name
        let channelLabel = NSTextField(labelWithString: "Channel:")
        channelLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(channelLabel)

        channelField = NSTextField(frame: NSRect(x: 110, y: y, width: fieldWidth, height: 22))
        let defaultChannel = "astation-\(Self.randomHex(8))"
        channelField.placeholderString = "e.g. astation-a1b2c3d4"
        channelField.stringValue = defaultChannel
        contentView.addSubview(channelField)
        y -= 40

        // UID
        let uidLabel = NSTextField(labelWithString: "UID:")
        uidLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(uidLabel)

        uidField = NSTextField(frame: NSRect(x: 110, y: y, width: fieldWidth, height: 22))
        uidField.placeholderString = "Numeric user ID"
        uidField.stringValue = String(UInt32.random(in: 1000...9999))
        contentView.addSubview(uidField)
        y -= 40

        // Role selector
        let roleLabel = NSTextField(labelWithString: "Role:")
        roleLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(roleLabel)

        roleControl = NSSegmentedControl(
            labels: ["Publisher", "Subscriber"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        roleControl.frame = NSRect(x: 110, y: y, width: 200, height: 24)
        roleControl.selectedSegment = 0
        contentView.addSubview(roleControl)
        y -= 40

        // Encryption mode
        let encryptionModeLabel = NSTextField(labelWithString: "Encrypt:")
        encryptionModeLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(encryptionModeLabel)

        encryptionModePopup = NSPopUpButton(frame: NSRect(x: 110, y: y - 2, width: fieldWidth, height: 26))
        encryptionModePopup.addItems(withTitles: encryptionModes.map(\.title))
        encryptionModePopup.target = self
        encryptionModePopup.action = #selector(encryptionModeChanged)
        if let defaultModeIndex = encryptionModes.firstIndex(of: .manualJoinDefault) {
            encryptionModePopup.selectItem(at: defaultModeIndex)
        }
        contentView.addSubview(encryptionModePopup)
        y -= 40

        // Encryption key
        let encryptionKeyLabel = NSTextField(labelWithString: "Key:")
        encryptionKeyLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(encryptionKeyLabel)

        encryptionKeyField = NSSecureTextField(frame: NSRect(x: 110, y: y, width: fieldWidth, height: 22))
        encryptionKeyField.placeholderString = "Shared channel encryption key"
        encryptionKeyField.maximumNumberOfLines = 1
        encryptionKeyField.cell?.wraps = false
        encryptionKeyField.cell?.usesSingleLineMode = true
        encryptionKeyField.cell?.isScrollable = true
        contentView.addSubview(encryptionKeyField)
        y -= 40

        // Encryption salt
        saltLabel = NSTextField(labelWithString: "Salt:")
        saltLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(saltLabel)

        saltField = NSTextField(frame: NSRect(x: 110, y: y, width: fieldWidth, height: 22))
        saltField.placeholderString = "32-byte salt in hex or base64"
        saltField.stringValue = RTCEncryptionConfiguration.generateSaltHex()
        saltField.maximumNumberOfLines = 1
        saltField.cell?.wraps = false
        saltField.cell?.usesSingleLineMode = true
        saltField.cell?.isScrollable = true
        contentView.addSubview(saltField)
        y -= 40

        // Geo fence
        let geoFenceLabel = NSTextField(labelWithString: "Geo:")
        geoFenceLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(geoFenceLabel)

        geoFencePopup = NSPopUpButton(frame: NSRect(x: 110, y: y - 2, width: fieldWidth, height: 26))
        geoFencePopup.addItems(withTitles: geoFenceOptions.map(\.title))
        if let defaultGeoFenceIndex = geoFenceOptions.firstIndex(of: .manualJoinDefault) {
            geoFencePopup.selectItem(at: defaultGeoFenceIndex)
        }
        contentView.addSubview(geoFencePopup)
        y -= 50

        // Status label
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: y + 8, width: 330, height: 34)
        contentView.addSubview(statusLabel)

        // Join button
        joinButton = NSButton(title: "Join", target: self, action: #selector(joinChannel))
        joinButton.bezelStyle = .rounded
        joinButton.keyEquivalent = "\r"
        joinButton.frame = NSRect(x: 340, y: y, width: 90, height: 32)
        contentView.addSubview(joinButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        refreshProjectPicker()
        updateEncryptionFields()
    }

    private func ensureMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.showMicrophonePermissionAlert()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            showMicrophonePermissionAlert()
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Needed"
        alert.informativeText = "Astation needs Microphone access to publish voice audio. Enable it in System Settings > Privacy & Security > Microphone."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Continue Without Mic")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshProjectPicker() {
        projectPicker?.removeAllItems()
        let projects = hubManager.getProjects()
        if projects.isEmpty {
            projectPicker?.addItem(withTitle: "(no projects available)")
            projectPicker?.isEnabled = false
            joinButton?.isEnabled = false
        } else {
            projectPicker?.addItems(withTitles: projects.map { $0.name })
            projectPicker?.isEnabled = true
            joinButton?.isEnabled = true
        }
    }

    @objc private func encryptionModeChanged() {
        updateEncryptionFields()
    }

    @objc private func joinChannel() {
        let projects = hubManager.getProjects()
        let idx = projectPicker.indexOfSelectedItem
        guard idx >= 0, idx < projects.count else {
            statusLabel.stringValue = "No project selected"
            statusLabel.textColor = .systemRed
            return
        }
        let project = projects[idx]

        let channel = channelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else {
            statusLabel.stringValue = "Channel name required"
            statusLabel.textColor = .systemRed
            return
        }

        let uidText = uidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = Int(uidText), uid >= 0, uid <= Int(UInt32.max) else {
            statusLabel.stringValue = "UID must be a non-negative number"
            statusLabel.textColor = .systemRed
            return
        }

        let joinOptions: RTCJoinOptions
        do {
            joinOptions = try currentJoinOptions()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
            return
        }

        statusLabel.stringValue = "Checking microphone permission..."
        statusLabel.textColor = .systemBlue
        joinButton.isEnabled = false

        ensureMicrophonePermission { [weak self] micGranted in
            guard let self = self else { return }

            self.hubManager.initializeRTC(appId: project.vendorKey, geoFence: joinOptions.geoFence)
            self.hubManager.joinRTCChannel(
                channel: channel,
                uid: uid,
                projectId: project.id,
                joinOptions: joinOptions
            )

            self.statusLabel.stringValue = micGranted ? "Joining \(channel)..." : "Joining \(channel) (no mic permission)..."
            self.statusLabel.textColor = micGranted ? .systemBlue : .systemOrange

            let encryptionMode = joinOptions.encryption?.mode.title ?? RTCEncryptionMode.none.title
            Log.info(
                "[JoinChannel] Joining channel=\(channel) uid=\(uid) project=\(project.name) " +
                "micPermission=\(micGranted) geoFence=\(joinOptions.geoFence.title) encryption=\(encryptionMode)"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.window?.close()
            }
        }
    }

    private func selectedEncryptionMode() -> RTCEncryptionMode {
        let index = encryptionModePopup.indexOfSelectedItem
        guard index >= 0, index < encryptionModes.count else {
            return .manualJoinDefault
        }
        return encryptionModes[index]
    }

    private func selectedGeoFence() -> RTCGeoFence {
        let index = geoFencePopup.indexOfSelectedItem
        guard index >= 0, index < geoFenceOptions.count else {
            return .manualJoinDefault
        }
        return geoFenceOptions[index]
    }

    private func updateEncryptionFields() {
        let mode = selectedEncryptionMode()
        let encryptionEnabled = mode.isEnabled

        encryptionKeyField.isEnabled = encryptionEnabled
        saltLabel.isHidden = !mode.requiresSalt
        saltField.isHidden = !mode.requiresSalt

        if mode.requiresSalt && saltField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saltField.stringValue = RTCEncryptionConfiguration.generateSaltHex()
        }
    }

    private func currentJoinOptions() throws -> RTCJoinOptions {
        let mode = selectedEncryptionMode()
        if mode.requiresSalt && saltField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saltField.stringValue = RTCEncryptionConfiguration.generateSaltHex()
        }

        let encryption = try RTCEncryptionConfiguration.make(
            mode: mode,
            key: encryptionKeyField.stringValue,
            salt: saltField.stringValue
        )

        return RTCJoinOptions(
            geoFence: selectedGeoFence(),
            encryption: encryption
        )
    }

    private static func randomHex(_ length: Int) -> String {
        (0..<length).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
