import Cocoa
import Foundation

class JoinChannelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager
    private var projectPicker: NSPopUpButton!
    private var channelField: NSTextField!
    private var uidField: NSTextField!
    private var roleControl: NSSegmentedControl!
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
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

        var y: CGFloat = 240

        // Project picker
        let projectLabel = NSTextField(labelWithString: "Project:")
        projectLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(projectLabel)

        projectPicker = NSPopUpButton(frame: NSRect(x: 110, y: y - 2, width: 270, height: 26))
        contentView.addSubview(projectPicker)
        y -= 40

        // Channel name
        let channelLabel = NSTextField(labelWithString: "Channel:")
        channelLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(channelLabel)

        channelField = NSTextField(frame: NSRect(x: 110, y: y, width: 270, height: 22))
        channelField.placeholderString = "e.g. astation-default"
        channelField.stringValue = "astation-default"
        contentView.addSubview(channelField)
        y -= 40

        // UID
        let uidLabel = NSTextField(labelWithString: "UID:")
        uidLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        contentView.addSubview(uidLabel)

        uidField = NSTextField(frame: NSRect(x: 110, y: y, width: 270, height: 22))
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
        y -= 50

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 20, y: y + 16, width: 250, height: 18)
        contentView.addSubview(statusLabel)

        // Join button
        joinButton = NSButton(title: "Join", target: self, action: #selector(joinChannel))
        joinButton.bezelStyle = .rounded
        joinButton.keyEquivalent = "\r"
        joinButton.frame = NSRect(x: 290, y: y, width: 90, height: 32)
        contentView.addSubview(joinButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        refreshProjectPicker()
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

        hubManager.initializeRTC(appId: project.vendorKey)
        hubManager.joinRTCChannel(channel: channel, uid: uid, projectId: project.id)

        statusLabel.stringValue = "Joining \(channel)..."
        statusLabel.textColor = .systemBlue
        joinButton.isEnabled = false

        Log.info("[JoinChannel] Joining channel=\(channel) uid=\(uid) project=\(project.name)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window?.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
