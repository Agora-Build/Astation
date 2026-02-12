import Cocoa
import Foundation

class DevConsoleController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager

    // UI elements
    private var atemListView: NSScrollView!
    private var atemTableView: NSTableView!
    private var pairCodeField: NSTextField!
    private var pairConnectButton: NSButton!
    private var targetPicker: NSPopUpButton!
    private var messageInput: NSTextView!
    private var sendButton: NSButton!
    private var logView: NSTextView!
    private var selectedClientId: String?

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Astation Dev Console"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 500)

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        var yOffset: CGFloat = 560

        // --- Connected Atems Section ---
        let atemHeader = NSTextField(labelWithString: "Connected Atems")
        atemHeader.font = NSFont.boldSystemFont(ofSize: 13)
        atemHeader.frame = NSRect(x: 16, y: yOffset, width: 468, height: 20)
        contentView.addSubview(atemHeader)
        yOffset -= 120

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: yOffset, width: 468, height: 110))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width]

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.target = self
        tableView.action = #selector(atemTableClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("atem"))
        column.title = "Instance"
        column.width = 460
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
        self.atemTableView = tableView
        self.atemListView = scrollView
        yOffset -= 8

        // --- Pair Remote Atem Section ---
        yOffset -= 28
        let pairHeader = NSTextField(labelWithString: "Pair Remote Atem")
        pairHeader.font = NSFont.boldSystemFont(ofSize: 13)
        pairHeader.frame = NSRect(x: 16, y: yOffset, width: 468, height: 20)
        contentView.addSubview(pairHeader)
        yOffset -= 30

        pairCodeField = NSTextField(frame: NSRect(x: 16, y: yOffset, width: 360, height: 24))
        pairCodeField.placeholderString = "Enter pairing code (e.g. ABCD-EFGH)"
        contentView.addSubview(pairCodeField)

        pairConnectButton = NSButton(title: "Connect", target: self, action: #selector(connectRelay))
        pairConnectButton.bezelStyle = .rounded
        pairConnectButton.frame = NSRect(x: 384, y: yOffset - 2, width: 100, height: 28)
        contentView.addSubview(pairConnectButton)
        yOffset -= 8

        // --- Target Picker ---
        yOffset -= 28
        let targetLabel = NSTextField(labelWithString: "Target:")
        targetLabel.frame = NSRect(x: 16, y: yOffset, width: 60, height: 24)
        contentView.addSubview(targetLabel)

        targetPicker = NSPopUpButton(frame: NSRect(x: 80, y: yOffset, width: 200, height: 24))
        targetPicker.addItems(withTitles: ["Active CLI", "Claude Code", "Codex", "Shell"])
        contentView.addSubview(targetPicker)
        yOffset -= 8

        // --- Message Input ---
        yOffset -= 20
        let msgLabel = NSTextField(labelWithString: "Message:")
        msgLabel.font = NSFont.boldSystemFont(ofSize: 13)
        msgLabel.frame = NSRect(x: 16, y: yOffset, width: 468, height: 20)
        contentView.addSubview(msgLabel)
        yOffset -= 104

        let inputScroll = NSScrollView(frame: NSRect(x: 16, y: yOffset, width: 468, height: 100))
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.autoresizingMask = [.width]

        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 100))
        input.isEditable = true
        input.isSelectable = true
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.isRichText = false
        input.autoresizingMask = [.width, .height]
        input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true
        inputScroll.documentView = input
        contentView.addSubview(inputScroll)
        self.messageInput = input
        yOffset -= 8

        // --- Send Button ---
        yOffset -= 32
        sendButton = NSButton(title: "Send", target: self, action: #selector(sendCommand))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.frame = NSRect(x: 384, y: yOffset, width: 100, height: 28)
        contentView.addSubview(sendButton)
        yOffset -= 8

        // --- Log Area ---
        yOffset -= 20
        let logLabel = NSTextField(labelWithString: "Log")
        logLabel.font = NSFont.boldSystemFont(ofSize: 13)
        logLabel.frame = NSRect(x: 16, y: yOffset, width: 468, height: 20)
        contentView.addSubview(logLabel)
        yOffset -= 124

        let logScroll = NSScrollView(frame: NSRect(x: 16, y: yOffset, width: 468, height: 120))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.autoresizingMask = [.width]

        let log = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        log.isEditable = false
        log.isSelectable = true
        log.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        log.isRichText = false
        log.autoresizingMask = [.width, .height]
        log.isVerticallyResizable = true
        log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log
        contentView.addSubview(logScroll)
        self.logView = log

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window

        // Refresh the Atem list
        refreshAtemList()
        appendLog("Tip: use /rtc help for local RTC commands")
    }

    // MARK: - Actions

    @objc private func atemTableClicked() {
        let row = atemTableView.selectedRow
        let clients = hubManager.connectedClients
        guard row >= 0, row < clients.count else {
            selectedClientId = nil
            return
        }
        selectedClientId = clients[row].id
        appendLog("Selected Atem: \(clients[row].hostname) (\(clients[row].id.prefix(8))...)")
    }

    @objc private func connectRelay() {
        let code = pairCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            appendLog("Error: Enter a pairing code")
            return
        }

        appendLog("Connecting to relay with code: \(code)...")
        hubManager.connectToRelay(code: code)
        pairCodeField.stringValue = ""
        appendLog("Relay connection initiated for code: \(code)")

        // Refresh list after a short delay to allow connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshAtemList()
        }
    }

    @objc private func sendCommand() {
        let command = messageInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            appendLog("Error: Enter a command")
            return
        }

        if command.hasPrefix("/rtc") {
            let response = hubManager.handleLocalRtcCommand(command)
            appendLog(response)
            messageInput.string = ""
            return
        }

        let targetIndex = targetPicker.indexOfSelectedItem
        let action: String
        switch targetIndex {
        case 0: action = "cli_input"
        case 1: action = "claude_input"
        case 2: action = "codex_input"
        case 3: action = "shell"
        default: action = "cli_input"
        }

        let clientId = selectedClientId ?? hubManager.routeToFocusedAtem()

        guard let targetId = clientId else {
            appendLog("Error: No Atem selected or connected")
            return
        }

        hubManager.sendCommandToClient(command, action: action, clientId: targetId)
        appendLog("Sent [\(action)] to \(targetId.prefix(8))...: \(command.prefix(80))")

        // Clear input
        messageInput.string = ""
    }

    // MARK: - Helpers

    func refreshAtemList() {
        atemTableView?.reloadData()
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(text)\n"

        logView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension DevConsoleController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return hubManager.connectedClients.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clients = hubManager.connectedClients
        guard row < clients.count else { return nil }
        let client = clients[row]

        let cellId = NSUserInterfaceItemIdentifier("atemCell")
        let cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId

        let focusBadge = client.isFocused ? " [active]" : ""
        let display = client.hostname == "unknown"
            ? "\(client.id.prefix(8))...\(focusBadge)"
            : "\(client.hostname)\(focusBadge) — \(client.id.prefix(8))..."
        cell.stringValue = display
        cell.font = NSFont.monospacedSystemFont(ofSize: 12, weight: client.isFocused ? .bold : .regular)
        return cell
    }
}
