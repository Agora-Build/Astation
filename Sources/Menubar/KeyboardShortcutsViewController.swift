import Cocoa

private final class ShortcutDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class KeyboardShortcutsViewController: NSViewController {
    private let manager: HotkeyManager
    private var bindingButtons: [ShortcutAction: NSButton] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private var statusLabels: [ShortcutAction: NSTextField] = [:]
    private var restoreButton: NSButton!
    private var checkButton: NSButton!
    private var messageLabel: NSTextField!
    private var eventMonitor: Any?
    private var pendingShortcut: KeyboardShortcut?
    private(set) var recordingAction: ShortcutAction?

    init(manager: HotkeyManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if recordingAction != nil { manager.resumeAfterRecording() }
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let document = ShortcutDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        view = scrollView
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(title)
        let intro = label("Use these shortcuts from any app. Click a binding, then press your new key combination. Changes are saved immediately.")
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for (index, action) in ShortcutAction.allCases.enumerated() {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 8
            let heading = NSTextField(labelWithString: action.title)
            heading.font = .boldSystemFont(ofSize: 13)
            row.addArrangedSubview(heading)
            let detail = label(action.detail)
            row.addArrangedSubview(detail)
            let binding = NSButton(title: "", target: self, action: #selector(recordShortcut(_:)))
            binding.bezelStyle = .rounded
            binding.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            binding.tag = index
            binding.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            binding.setAccessibilityLabel("\(action.title) shortcut")
            binding.toolTip = "Click to record a shortcut. Press Escape to cancel."
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.bezelStyle = .rounded
            clear.tag = index
            clear.setAccessibilityLabel("Clear \(action.title) shortcut")
            let controls = NSStackView(views: [binding, clear])
            controls.spacing = 8
            row.addArrangedSubview(controls)
            let status = label("")
            row.addArrangedSubview(status)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            status.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            bindingButtons[action] = binding
            clearButtons[action] = clear
            statusLabels[action] = status
        }

        restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restoreButton.bezelStyle = .rounded
        checkButton = NSButton(title: "Check Conflicts", target: self, action: #selector(checkConflicts))
        checkButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [restoreButton, checkButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        messageLabel = label("")
        messageLabel.setAccessibilityIdentifier("shortcutMessage")
        stack.addArrangedSubview(messageLabel)
        messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let help = label("Include Control, Option, or Command, or use F1-F20. Escape cancels recording. Checks cover Astation commands, macOS shortcuts, and registered global shortcuts; other apps' local shortcuts cannot all be detected.")
        help.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        render()
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    override func viewWillDisappear() {
        cancelRecording()
        super.viewWillDisappear()
    }

    func refresh() {
        guard isViewLoaded else { return }
        render()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        if recordingAction == action {
            cancelRecording()
            return
        }
        beginRecording(action)
    }

    func beginRecording(_ action: ShortcutAction) {
        cancelRecording()
        recordingAction = action
        manager.suspendForRecording()
        messageLabel.stringValue = "Press a shortcut for \(action.title). Press Escape or click Cancel to keep the current binding."
        messageLabel.textColor = .secondaryLabelColor
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.recordingAction != nil else { return event }
            guard event.window === self.view.window, self.view.window?.isKeyWindow == true else {
                self.cancelRecording()
                return event
            }
            self.capture(event)
            return nil
        }
        render()
    }

    func capture(_ event: NSEvent) {
        guard let action = recordingAction, !event.isARepeat else { return }
        if event.type == .keyUp {
            guard let shortcut = pendingShortcut, shortcut.keyCode == UInt32(event.keyCode) else { return }
            // Resume only after release, so holding the recorded key cannot activate the new binding.
            finishRecording()
            let error = manager.setShortcut(shortcut, for: action)
            showResult(error: error, success: "\(action.title) is now bound to \(shortcut.displayName).")
            render()
            return
        }
        guard event.type == .keyDown else { return }
        if event.keyCode == 53, KeyboardShortcut.carbonModifiers(event.modifierFlags) == 0 {
            cancelRecording()
            return
        }
        guard pendingShortcut == nil else { return }
        let shortcut = KeyboardShortcut(event: event)
        if let error = shortcut.validationError {
            showResult(error: error, success: "")
            return
        }
        pendingShortcut = shortcut
        showResult(error: nil, success: "Release \(shortcut.displayName) to save the binding.")
    }

    func cancelRecording() {
        guard recordingAction != nil else { return }
        finishRecording()
        messageLabel?.stringValue = "Recording canceled."
        messageLabel?.textColor = .secondaryLabelColor
        render()
    }

    private func finishRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        pendingShortcut = nil
        recordingAction = nil
        manager.resumeAfterRecording()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        guard recordingAction != nil, let window = notification.object as? NSWindow, window === view.window else { return }
        cancelRecording()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        let error = manager.setShortcut(nil, for: action)
        showResult(error: error, success: "\(action.title) shortcut cleared.")
        render()
    }

    @objc private func restoreDefaults() {
        let error = manager.restoreDefaults()
        showResult(error: error, success: "Default shortcuts restored.")
        render()
    }

    @objc private func checkConflicts() {
        manager.unregisterAll()
        manager.registerHotkeys()
        let failures = ShortcutAction.allCases.compactMap { manager.registrationErrors[$0] }
        showResult(error: failures.isEmpty ? nil : failures.joined(separator: "\n"),
                   success: "No conflicts found for the current bindings.")
        render()
    }

    private func showResult(error: String?, success: String) {
        messageLabel.stringValue = error ?? success
        messageLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
    }

    private func render() {
        for action in ShortcutAction.allCases {
            bindingButtons[action]?.title = recordingAction == action ? "Cancel Recording" : manager.shortcutLabel(for: action)
            bindingButtons[action]?.isEnabled = recordingAction == nil || recordingAction == action
            clearButtons[action]?.isEnabled = recordingAction == nil && manager.bindings[action] != nil
            let error = manager.registrationErrors[action]
            statusLabels[action]?.stringValue = recordingAction != nil ? "Shortcuts paused while recording." :
                (error ?? (manager.bindings[action] == nil ? "No shortcut assigned." : "Active globally"))
            statusLabels[action]?.textColor = error == nil || recordingAction != nil ? .secondaryLabelColor : .systemRed
        }
        restoreButton?.isEnabled = recordingAction == nil
        checkButton?.isEnabled = recordingAction == nil
    }
}
