import AppKit

/// One addressed terminal window. Closing it releases the view, not the agent.
final class RemoteControlWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager
    private var targetClientId: String?
    private var targetAtemId: String?
    private var renderer: RemoteTerminalRenderer?
    private var timeoutTimer: Timer?
    private let targetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "VIEWING")
    private let sessionPicker = NSPopUpButton()
    private var viewButton: NSButton!
    private var controlButton: NSButton!
    private var releaseButton: NSButton!
    private var stopButton: NSButton!
    private var pasteButton: NSButton!
    private var displayedSessions: [RemoteTerminalSession] = []
    private var lastInputEpoch = ""
    private var lastInputEnabled = false

    private lazy var terminal = RemoteTerminalController(
        currentConnection: { [weak self] in
            guard let self, let id = self.targetClientId else { return nil }
            return self.hubManager.terminalConnection(for: id, atemId: self.targetAtemId)
        },
        send: { [weak self] message, route in self?.hubManager.sendTerminalMessage(message, to: route) ?? false }
    )

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
        terminal.onChange = { [weak self] in self?.refresh() }
        hubManager.terminalMessageHandler = { [weak self] message, source in self?.terminal.receive(message, from: source) }
        hubManager.terminalConnectionsDidChange = { [weak self] in self?.terminal.connectionChanged() }
    }

    func showWindow(clientId: String, agent: AtemAgentInfo?) {
        terminal.close()
        targetClientId = clientId
        targetAtemId = hubManager.connectedClients.first(where: { $0.id == clientId })?.atemId
        targetLabel.stringValue = hubManager.connectedClients.first(where: { $0.id == clientId })?.hostname ?? "Atem"
        if window == nil { createWindow() }
        let preferred: String? = agent?.kind == "Claude Code" ? "claude" : agent?.kind == "Codex" ? "codex" : nil
        terminal.open(preferredTerminalId: preferred)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Remote Terminal"
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        let content = NSView()
        window.contentView = content
        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        sessionPicker.target = self
        sessionPicker.action = #selector(selectSession)
        sessionPicker.toolTip = "Select the original Claude or Codex process on this Atem"
        sessionPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        let refreshButton = button("Refresh", symbol: "arrow.clockwise", action: #selector(refreshSessions))
        let titleRow = NSStackView(views: [targetLabel, spacer(), sessionPicker, refreshButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        modeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        viewButton = button("View", symbol: "eye", action: #selector(viewSession))
        controlButton = button("Take Control", symbol: "keyboard", action: #selector(takeControl))
        releaseButton = button("Release", symbol: "keyboard.badge.ellipsis", action: #selector(releaseControl))
        let copyButton = button("Copy", symbol: "doc.on.doc", action: #selector(copySelection))
        pasteButton = button("Paste", symbol: "doc.on.clipboard", action: #selector(paste))
        stopButton = button("Stop Agent", symbol: "stop.circle", action: #selector(stopAgent))
        stopButton.toolTip = "Stop this original agent process on the remote machine"
        let controls = NSStackView(views: [modeLabel, viewButton, controlButton, releaseButton, spacer(), copyButton, pasteButton, stopButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let renderer = RemoteTerminalRenderer()
        self.renderer = renderer
        renderer.onAction = { [weak self, weak renderer] action in
            guard let self, let renderer, self.renderer === renderer else { return }
            self.handleRenderer(action)
        }
        renderer.onFailure = { [weak self, weak renderer] in
            guard let self, let renderer, self.renderer === renderer else { return }
            self.terminal.rendererFailed()
        }
        for view in [titleRow, controls, renderer.webView, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            renderer.webView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            renderer.webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            renderer.webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            renderer.webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.terminal.connectionChanged()
            self?.terminal.checkTimeouts()
        }
        lastInputEpoch = ""
        lastInputEnabled = false
        renderer.load()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        result.imagePosition = .imageLeading
        result.controlSize = .small
        return result
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private var inputEpoch: String {
        guard let stream = terminal.stream, let lease = terminal.leaseId else { return "" }
        return stream.streamId + ":" + lease
    }

    private func refresh() {
        guard window != nil else { return }
        if displayedSessions != terminal.sessions {
            displayedSessions = terminal.sessions
            sessionPicker.removeAllItems()
            for session in displayedSessions {
                let name = session.provider == "claude" ? "Claude Code" : session.provider == "codex" ? "Codex" : session.provider
                sessionPicker.addItem(withTitle: name + (session.exitStatus == nil ? " - live" : " - exited"))
            }
        }
        if let index = displayedSessions.firstIndex(where: { $0.id == terminal.session?.id }) { sessionPicker.selectItem(at: index) }
        sessionPicker.isEnabled = !displayedSessions.isEmpty
        statusLabel.stringValue = terminal.status
        statusLabel.textColor = terminal.phase == .failed ? .systemOrange : .secondaryLabelColor
        modeLabel.stringValue = terminal.canInput ? "CONTROLLING" : terminal.phase == .offline ? "OFFLINE" : "VIEWING"
        modeLabel.textColor = terminal.canInput ? .controlAccentColor : .secondaryLabelColor
        viewButton.isEnabled = terminal.session?.isSupported == true && terminal.connection != nil
            && [.ready, .failed, .viewing, .exited].contains(terminal.phase)
        controlButton.isEnabled = terminal.canTakeControl
        releaseButton.isEnabled = terminal.canRelease
        stopButton.isEnabled = terminal.canInput
        pasteButton.isEnabled = terminal.canInput
        if renderer?.isReady == true && (lastInputEnabled != terminal.canInput || lastInputEpoch != inputEpoch) {
            lastInputEnabled = terminal.canInput
            lastInputEpoch = inputEpoch
            renderer?.setControl(terminal.canInput, epoch: inputEpoch)
        }
    }

    private func handleRenderer(_ action: RemoteTerminalRendererAction) {
        switch action {
        case .ready:
            terminal.render = { [weak self] frame, token in self?.renderer?.render(frame, token: token) }
            terminal.rendererAvailable()
            renderer?.setControl(terminal.canInput, epoch: inputEpoch)
        case .input(let bytes, let epoch):
            if epoch == inputEpoch { terminal.input(bytes) }
        case .consumed(let token): terminal.consumed(token)
        case .size(let rows, let cols): terminal.resize(rows: rows, cols: cols)
        case .copy(let text):
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .paste(let epoch): if epoch == inputEpoch { paste(nil) }
        case .oversizedPaste: terminal.input(Data(repeating: 0, count: 16 * 1024 + 1))
        }
    }

    @objc private func refreshSessions() { terminal.refresh() }
    @objc private func selectSession() {
        let index = sessionPicker.indexOfSelectedItem
        if displayedSessions.indices.contains(index) { terminal.select(displayedSessions[index]) }
    }
    @objc private func viewSession() { terminal.view() }
    @objc private func takeControl() { terminal.takeControl() }
    @objc private func releaseControl() { terminal.release() }
    @objc private func copySelection() { renderer?.copySelection() }
    @objc private func paste(_ sender: Any?) {
        guard terminal.canInput, let text = NSPasteboard.general.string(forType: .string) else { return }
        if text.utf8.count + 12 > 16 * 1024 {
            terminal.input(Data(repeating: 0, count: 16 * 1024 + 1))
        } else { renderer?.paste(text, epoch: inputEpoch) }
    }

    @objc private func stopAgent() {
        guard terminal.canInput, let window, let session = terminal.session else { return }
        let originalStream = terminal.stream
        let alert = NSAlert()
        alert.messageText = "Stop \(session.provider == "claude" ? "Claude Code" : "Codex") on \(targetLabel.stringValue)?"
        alert.informativeText = "This stops the original agent process. Closing or releasing this window keeps it running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop Agent")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertSecondButtonReturn, let self, self.terminal.stream == originalStream else { return }
            self.terminal.stop()
        }
    }

    func windowWillClose(_ notification: Notification) {
        terminal.close()
        terminal.render = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        renderer = nil
        window = nil
        displayedSessions = []
    }
}
