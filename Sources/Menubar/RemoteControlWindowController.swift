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
    private var pasteAndGoButton: NSButton!
    private let promptField = NSTextField()
    private let receiptLabel = NSTextField(labelWithString: "")
    private var sendPromptButton: NSButton!
    private var displayedSessions: [RemoteTerminalSession] = []
    private var lastInputEpoch = ""
    private var lastInputEnabled = false
    private struct PromptDraft {
        let target: AtemSessionTarget
        let requestID: String
        let text: String
    }
    private var promptDraft: PromptDraft?
    private var confirmingTakeover = false

    private var promptTarget: AtemSessionTarget? {
        terminal.session.flatMap { sessions.target(sessionId: $0.terminalId, process: $0.generation) }
    }

    private lazy var offlineSessions = AtemSessionClient(context: { nil }, send: { _, _ in false })
    private var sessions: AtemSessionClient {
        guard let id = targetClientId else { return offlineSessions }
        return hubManager.sessionClient(for: id, atemId: targetAtemId) ?? offlineSessions
    }

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
        NotificationCenter.default.addObserver(self, selector: #selector(releaseForegroundControl),
            name: NSApplication.didResignActiveNotification, object: nil)
        terminal.sessionClient = sessions
        hubManager.sessionStateDidChange = { [weak self] id in
            guard let self, self.sessions.context?.route.clientId == id else { return }
            self.terminal.sessionClient = self.sessions
            self.terminal.sessionStateChanged()
            self.refresh()
        }
        terminal.onChange = { [weak self] in self?.refresh() }
        hubManager.terminalMessageHandler = { [weak self] message, source in self?.terminal.receive(message, from: source) }
        hubManager.terminalConnectionsDidChange = { [weak self] in
            guard let self else { return }
            self.terminal.sessionClient = self.sessions
            self.terminal.connectionChanged()
            self.terminal.sessionStateChanged()
        }
        hubManager.remoteAgentInputHandler = { [weak self] route, agentId, kind, value in
            guard let self, route == self.terminal.connection,
                  route == self.hubManager.terminalConnection(for: route.clientId),
                  agentId == nil || agentId == self.terminal.session?.agentId else { return false }
            return self.terminal.sendScopedInput(kind: kind, value: value)
        }
    }

    func showWindow(clientId: String, agent: AtemAgentInfo?) {
        sessions.releaseAll()
        terminal.close()
        promptDraft = nil
        promptField.stringValue = ""
        targetClientId = clientId
        targetAtemId = hubManager.connectedClients.first(where: { $0.id == clientId })?.atemId
        terminal.sessionClient = sessions
        targetLabel.stringValue = hubManager.connectedClients.first(where: { $0.id == clientId })?.hostname ?? "Atem"
        if window == nil { createWindow() }
        sessions.start()
        terminal.open(preferredTerminalId: nil, preferredAgentId: agent?.id)
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
        pasteAndGoButton = button("Paste & Go", symbol: "arrow.turn.down.left", action: #selector(pasteAndGo))
        pasteAndGoButton.toolTip = "Paste the clipboard into the selected remote terminal and press Enter"
        stopButton = button("Stop Agent", symbol: "stop.circle", action: #selector(stopAgent))
        stopButton.toolTip = "Stop this original agent process on the remote machine"
        let controls = NSStackView(views: [modeLabel, viewButton, controlButton, releaseButton, spacer(), pasteAndGoButton, stopButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        promptField.placeholderString = "Send a prompt to this agent"
        promptField.target = self
        promptField.action = #selector(sendPrompt)
        promptField.font = .systemFont(ofSize: 13)
        sendPromptButton = button("Send", symbol: "arrow.up.circle.fill", action: #selector(sendPrompt))
        let promptRow = NSStackView(views: [promptField, sendPromptButton])
        promptRow.orientation = .horizontal
        promptRow.spacing = 8
        receiptLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        receiptLabel.textColor = .secondaryLabelColor
        receiptLabel.lineBreakMode = .byTruncatingTail
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
        for view in [titleRow, controls, renderer.webView, promptRow, receiptLabel, statusLabel] {
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
            renderer.webView.bottomAnchor.constraint(equalTo: promptRow.topAnchor, constant: -12),
            promptRow.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            promptRow.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            promptRow.bottomAnchor.constraint(equalTo: receiptLabel.topAnchor, constant: -6),
            receiptLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            receiptLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            receiptLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        if timeoutTimer == nil { timeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.terminal.connectionChanged()
            self?.terminal.checkTimeouts()
        } }
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
                let identifier = String(session.terminalId.prefix(12))
                let detail = session.label.flatMap { $0.isEmpty ? nil : $0 + " [" + identifier + "]" } ?? identifier
                sessionPicker.addItem(withTitle: name + " - " + detail + (session.exitStatus == nil ? " - live" : " - exited"))
                sessionPicker.lastItem?.toolTip = session.terminalId + " / " + session.generation
            }
        }
        if let index = displayedSessions.firstIndex(where: { $0.id == terminal.session?.id }) { sessionPicker.selectItem(at: index) }
        else { sessionPicker.select(nil) }
        sessionPicker.isEnabled = !displayedSessions.isEmpty
        let blockReason = targetClientId.flatMap { hubManager.remoteAccessBlockReason(for: $0) }
        statusLabel.stringValue = terminal.phase == .offline ? blockReason?.localizedDescription ?? terminal.status : terminal.status
        statusLabel.textColor = terminal.phase == .failed ? .systemOrange : .secondaryLabelColor
        modeLabel.stringValue = terminal.canInput ? "CONTROLLING" : terminal.phase == .offline ? "OFFLINE" : "VIEWING"
        modeLabel.textColor = terminal.canInput ? .controlAccentColor : .secondaryLabelColor
        viewButton.isEnabled = terminal.session?.isSupported == true && terminal.connection != nil
            && [.ready, .failed, .viewing, .exited].contains(terminal.phase)
            && terminal.session.flatMap { sessions.target(sessionId: $0.terminalId, process: $0.generation) } != nil
        controlButton.isEnabled = terminal.canTakeControl
        releaseButton.isEnabled = terminal.canRelease
        stopButton.isEnabled = terminal.canInput
        pasteAndGoButton.isEnabled = terminal.canInput
        let supportsPrompts = terminal.session.flatMap { sessions.registry[$0.terminalId] }?.capabilities.contains("chat-v1") == true
        if let draft = promptDraft, let record = sessions.journal.snapshot.requests.first(where: { $0.requestId == draft.requestID }),
           record.receipt != nil || (record.refusal != nil && record.refusal?.code != "lease_held") {
            if let receipt = record.receipt, receipt.state != .rejected,
               promptField.stringValue == draft.text { promptField.stringValue = "" }
            promptDraft = nil
        }
        let refusedHolder = promptDraft.flatMap { draft in
            sessions.journal.snapshot.requests.first { $0.requestId == draft.requestID }?.refusal?.controller
        }
        let holdsControl = promptTarget.map { sessions.controls($0) } ?? false
        let canSend = supportsPrompts && sessions.canReviewApprovals && promptTarget != nil
            && (holdsControl || sessions.features.contains("chat.send_acquire"))
            && (promptTarget.flatMap { sessions.controlOwner(for: $0) }.map { $0 == "native" } != false)
        promptField.isEnabled = canSend && promptDraft == nil
        sendPromptButton.isEnabled = canSend && !confirmingTakeover && (promptDraft == nil || refusedHolder != nil)
        sendPromptButton.title = refusedHolder != nil ? "Take over & Send" : "Send"
        promptField.placeholderString = supportsPrompts ? "Send a prompt to this agent" : "Type or paste in this agent's terminal"
        if let receipt = sessions.latestReceipt, receipt.target.session_id == terminal.session?.terminalId,
           receipt.target.process_gen == terminal.session?.generation {
            receiptLabel.stringValue = receipt.kind.capitalized + " - " + receipt.state.rawValue.replacingOccurrences(of: "_", with: " ")
                + (receipt.detail.map { " - " + $0 } ?? "")
                + (receipt.result.map { " - replies " + $0.replies + ($0.more ? " (more available)" : "") } ?? "")
            receiptLabel.toolTip = receipt.request_id
        } else { receiptLabel.stringValue = sessions.status; receiptLabel.toolTip = nil }
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
        case .paste(let epoch): if epoch == inputEpoch { pasteClipboard(submit: false) }
        case .oversizedPaste: terminal.input(Data(repeating: 0, count: 16 * 1024 + 1))
        }
    }

    @objc private func refreshSessions() { sessions.refresh(); terminal.refresh() }
    @objc private func sendPrompt() {
        if let draft = promptDraft {
            guard draft.target == promptTarget, let window,
                  let refusal = sessions.journal.snapshot.requests.first(where: { $0.requestId == draft.requestID })?.refusal,
                  refusal.code == "lease_held", let holder = refusal.controller, !confirmingTakeover else { return }
            let alert = NSAlert()
            alert.messageText = "Take over and send?"
            alert.informativeText = "Controller \(holder.controller_session) currently holds this session (lease \(holder.lease_epoch)). Sending moves control to this Mac."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Take over and Send")
            confirmingTakeover = true
            alert.beginSheetModal(for: window) { [weak self] result in
                guard let self else { return }
                self.confirmingTakeover = false
                guard result == .alertSecondButtonReturn, self.promptTarget == draft.target,
                      self.promptDraft?.requestID == draft.requestID else { self.refresh(); return }
                _ = self.sessions.submit(draft.target, kind: "prompt", text: draft.text,
                    requestID: draft.requestID, takeover: holder)
                self.refresh()
            }
            return
        }
        let text = promptField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let target = promptTarget else { return }
        let draft = PromptDraft(target: target, requestID: UUID().uuidString.lowercased(), text: text)
        promptDraft = draft
        if sessions.submit(target, kind: "prompt", text: text, requestID: draft.requestID) == nil { promptDraft = nil }
        refresh()
    }
    @objc private func selectSession() {
        let index = sessionPicker.indexOfSelectedItem
        if displayedSessions.indices.contains(index) {
            sessions.releaseAll()
            promptDraft = nil
            promptField.stringValue = ""
            terminal.select(displayedSessions[index])
        }
    }
    @objc private func viewSession() { terminal.view() }
    @objc private func takeControl() { terminal.takeControl() }
    @objc private func releaseControl() { terminal.release() }
    @objc private func releaseForegroundControl() {
        sessions.releaseAll()
        terminal.sessionStateChanged()
    }
    func windowDidMiniaturize(_ notification: Notification) { releaseForegroundControl() }
    @objc private func pasteAndGo() { pasteClipboard(submit: true) }
    private func pasteClipboard(submit: Bool) {
        guard terminal.canInput, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if text.utf8.count + 12 + (submit ? 1 : 0) > 16 * 1024 {
            terminal.input(Data(repeating: 0, count: 16 * 1024 + 1))
        } else { renderer?.paste(text, epoch: inputEpoch, submit: submit) }
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
        sessions.releaseAll()
        renderer = nil
        window = nil
        displayedSessions = []
        promptDraft = nil
    }
}
