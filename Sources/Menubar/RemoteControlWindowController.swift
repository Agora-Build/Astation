import Cocoa
import Foundation

/// Remote control panel for the v1 "up lane": send text + control keys to the
/// focused Atem's agent. Voice stays on the existing PTT/hands-free path.
class RemoteControlWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager
    private var targetLabel: NSTextField!
    private var inputField: NSTextField!
    private var sendButton: NSButton!
    private var targetClientId: String?
    private var targetAgentId: String?
    private var targetAgentName: String?

    /// Control keys exposed in the key bar: (button title, wire key name).
    private let keys: [(String, String)] = [
        ("⏎ Enter", "enter"),
        ("Esc", "esc"),
        ("Ctrl-C", "ctrl-c"),
        ("↑", "up"),
        ("↓", "down"),
        ("y", "y"),
        ("n", "n"),
    ]

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    func showWindow(clientId: String, agent: AtemAgentInfo) {
        targetClientId = clientId
        targetAgentId = agent.id
        targetAgentName = agent.name.isEmpty ? agent.kind : agent.name

        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshTarget()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remote Agent Control"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Target Atem label
        targetLabel = NSTextField(labelWithString: "")
        targetLabel.font = NSFont.systemFont(ofSize: 11)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.frame = NSRect(x: 20, y: 165, width: 420, height: 18)
        contentView.addSubview(targetLabel)

        // Text input + Send
        inputField = NSTextField(frame: NSRect(x: 20, y: 120, width: 320, height: 26))
        inputField.placeholderString = "Type an instruction, press Enter or Send"
        inputField.delegate = self
        contentView.addSubview(inputField)

        sendButton = NSButton(title: "Send", target: self, action: #selector(sendText))
        sendButton.bezelStyle = .rounded
        sendButton.frame = NSRect(x: 350, y: 118, width: 90, height: 30)
        sendButton.keyEquivalent = "\r"
        contentView.addSubview(sendButton)

        // Key bar
        let keyBarLabel = NSTextField(labelWithString: "Keys:")
        keyBarLabel.font = NSFont.systemFont(ofSize: 11)
        keyBarLabel.frame = NSRect(x: 20, y: 78, width: 40, height: 18)
        contentView.addSubview(keyBarLabel)

        var x: CGFloat = 20
        let y: CGFloat = 40
        for (title, keyName) in keys {
            let btn = NSButton(title: title, target: self, action: #selector(sendKey(_:)))
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 11)
            let width: CGFloat = title.count > 3 ? 70 : 44
            btn.frame = NSRect(x: x, y: y, width: width, height: 28)
            btn.identifier = NSUserInterfaceItemIdentifier(keyName)
            contentView.addSubview(btn)
            x += width + 6
        }

        window.contentView = contentView
        window.makeFirstResponder(inputField)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        refreshTarget()
    }

    private func refreshTarget() {
        if let clientId = targetClientId,
           let client = hubManager.connectedClients.first(where: { $0.id == clientId }) {
            let clientName = client.hostname
            targetLabel.stringValue = "Target: \(targetAgentName ?? "Agent") on \(clientName)"
            targetLabel.textColor = .secondaryLabelColor
        } else {
            targetLabel.stringValue = "⚠ Target Atem is offline — input will be dropped"
            targetLabel.textColor = .systemOrange
        }
    }

    @objc private func sendText() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hubManager.sendAgentText(text, agentId: targetAgentId, clientId: targetClientId)
        inputField.stringValue = ""
        refreshTarget()
    }

    @objc private func sendKey(_ sender: NSButton) {
        guard let keyName = sender.identifier?.rawValue else { return }
        hubManager.sendAgentKey(keyName, agentId: targetAgentId, clientId: targetClientId)
        refreshTarget()
    }

    // Enter in the text field sends.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            sendText()
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
