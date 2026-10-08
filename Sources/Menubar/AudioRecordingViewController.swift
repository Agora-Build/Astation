import AppKit

private final class RecordingDocumentView: NSView { override var isFlipped: Bool { true } }
private final class RecordingApplicationButton: NSButton { var bundleID = "" }

final class AudioRecordingViewController: NSViewController {
    private let manager: AudioRecordingManager
    private let hotkeys: HotkeyManager
    private let sourceStack = NSStackView()
    private let applicationStack = NSStackView()
    private let microphoneToggle = NSButton(checkboxWithTitle: "Record microphone", target: nil, action: nil)
    private let microphonePicker = NSPopUpButton()
    private let outputPicker = NSPopUpButton()
    private let formatPicker = NSPopUpButton()
    private let splitPicker = NSPopUpButton()
    private let folderLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let previewButton = NSButton(title: "Start Preview", target: nil, action: nil)
    private let recordButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let chooseFolderButton = NSButton(title: "Choose Folder...", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show Recording", target: nil, action: nil)
    private var cards: [String: AudioSourceCardView] = [:]
    private var renderedSources: [AudioSourceSelection] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var microphoneIDs: [String?] = []
    private var visible = false

    init(manager: AudioRecordingManager, hotkeys: HotkeyManager) {
        self.manager = manager
        self.hotkeys = hotkeys
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        let document = RecordingDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        view = scroll
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let eyebrow = text("LOCAL AUDIO", size: 10, weight: .semibold)
        eyebrow.textColor = .systemTeal
        stack.addArrangedSubview(eyebrow)
        stack.addArrangedSubview(text("Audio & Recording", size: 24, weight: .semibold))
        let intro = text("See your sound before you record. Save separate, lossless original tracks from your microphone and selected apps.")
        stack.addArrangedSubview(intro)
        let controls = NSStackView(views: [previewButton, recordButton, pauseButton, NSView(), elapsedLabel])
        controls.spacing = 8
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        for (button, action) in [(previewButton, #selector(togglePreview)), (recordButton, #selector(toggleRecording)),
                                 (pauseButton, #selector(togglePause)), (chooseFolderButton, #selector(chooseFolder)),
                                 (revealButton, #selector(revealRecording))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        recordButton.contentTintColor = .systemRed
        stack.addArrangedSubview(controls)
        messageLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(messageLabel)
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 12
        sourceStack.setHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(sourceStack)
        let scale = text("Last 5 seconds  /  Fixed waveform scale  /  Original input")
        scale.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        stack.addArrangedSubview(scale)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(text("Sources", size: 14, weight: .semibold))
        microphoneToggle.target = self
        microphoneToggle.action = #selector(changeSettings)
        stack.addArrangedSubview(microphoneToggle)
        stack.addArrangedSubview(row("Input device", control: microphonePicker, width: stack.widthAnchor))
        outputPicker.addItems(withTitles: RecordingOutputMode.allCases.map(\.title))
        stack.addArrangedSubview(row("Output audio", control: outputPicker, width: stack.widthAnchor))
        applicationStack.orientation = .vertical
        applicationStack.alignment = .leading
        applicationStack.spacing = 6
        stack.addArrangedSubview(applicationStack)
        let refresh = NSButton(title: "Refresh Devices & Apps", target: self, action: #selector(refreshCatalog))
        refresh.bezelStyle = .rounded
        stack.addArrangedSubview(refresh)
        stack.addArrangedSubview(text("Files", size: 14, weight: .semibold))
        formatPicker.addItems(withTitles: RecordingFileFormat.allCases.map(\.title))
        splitPicker.addItems(withTitles: ["15 minutes", "30 minutes", "60 minutes"])
        stack.addArrangedSubview(row("Format", control: formatPicker, width: stack.widthAnchor))
        stack.addArrangedSubview(row("Split files every", control: splitPicker, width: stack.widthAnchor))
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(folderLabel)
        stack.addArrangedSubview(NSStackView(views: [chooseFolderButton, revealButton]))
        let note = text("Recording saves original tracks locally. Preview alone creates no files, playback, or uploads. Captions are configured separately in Settings > Live Transcription; you can run both together.")
        stack.addArrangedSubview(note)
        for child in stack.arrangedSubviews where !(child is NSButton) {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for picker in [microphonePicker, outputPicker, formatPicker, splitPicker] {
            picker.target = self
            picker.action = #selector(changeSettings)
        }
        observer = NotificationCenter.default.addObserver(forName: .audioRecordingChanged, object: manager, queue: .main) { [weak self] _ in
            self?.refreshState()
        }
        refreshCatalog()
    }

    func setPageVisible(_ visible: Bool) {
        self.visible = visible
        timer?.invalidate()
        timer = nil
        if visible {
            loadViewIfNeeded()
            refreshState()
            timer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(updateMeters), userInfo: nil, repeats: true)
            RunLoop.main.add(timer!, forMode: .common)
        } else if !manager.isRecording && !manager.transcription.isActive { manager.stopPreview() }
    }

    private func text(_ value: String, size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = size <= 11 ? .secondaryLabelColor : .labelColor
        return label
    }

    private func row(_ title: String, control: NSView, width: NSLayoutDimension) -> NSView {
        let label = text(title, size: 12)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 12
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return row
    }

    @objc private func refreshCatalog() {
        manager.refreshSources()
        microphonePicker.removeAllItems()
        microphonePicker.addItem(withTitle: "System Default")
        microphoneIDs = [nil]
        for device in manager.microphones {
            microphonePicker.addItem(withTitle: device.name)
            microphoneIDs.append(device.uid)
        }
        if let uid = manager.settings.microphoneUID, !microphoneIDs.contains(where: { $0 == uid }) {
            microphonePicker.addItem(withTitle: "Disconnected: \(uid)")
            microphoneIDs.append(uid)
        }
        microphonePicker.selectItem(at: microphoneIDs.firstIndex { $0 == manager.settings.microphoneUID } ?? 0)
        rebuildApplications()
        refreshState()
    }

    private func rebuildApplications() {
        for view in applicationStack.arrangedSubviews { applicationStack.removeArrangedSubview(view); view.removeFromSuperview() }
        var apps = manager.applications.map { ($0.bundleID, $0.name) }
        for selected in manager.settings.applicationBundleIDs where !apps.contains(where: { $0.0 == selected }) {
            apps.append((selected, "\(selected) (not running)"))
        }
        if apps.isEmpty { applicationStack.addArrangedSubview(text("Open an application, then refresh to select it.")) }
        for (identity, name) in apps {
            let button = RecordingApplicationButton(checkboxWithTitle: name, target: self, action: #selector(selectApplication(_:)))
            button.bundleID = identity
            button.state = manager.settings.applicationBundleIDs.contains(identity) ? .on : .off
            button.isEnabled = !manager.controlsLocked
            button.setAccessibilityLabel("Record \(name) audio")
            applicationStack.addArrangedSubview(button)
        }
    }

    private func refreshState() {
        guard isViewLoaded else { return }
        microphoneToggle.state = manager.settings.microphoneEnabled ? .on : .off
        outputPicker.selectItem(at: RecordingOutputMode.allCases.firstIndex(of: manager.settings.outputMode)!)
        formatPicker.selectItem(at: RecordingFileFormat.allCases.firstIndex(of: manager.settings.format)!)
        splitPicker.selectItem(at: [15, 30, 60].firstIndex(of: manager.settings.splitMinutes) ?? 1)
        folderLabel.stringValue = manager.settings.folderPath
        for control in [microphoneToggle, microphonePicker, outputPicker, formatPicker, splitPicker, chooseFolderButton] as [NSControl] {
            control.isEnabled = !manager.controlsLocked
        }
        microphonePicker.isEnabled = !manager.controlsLocked && manager.settings.microphoneEnabled
        applicationStack.isHidden = manager.settings.outputMode != .applications
        for button in applicationStack.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = !manager.controlsLocked }
        previewButton.title = manager.state == .previewing ? "Stop Preview" : "Start Preview"
        previewButton.isEnabled = !manager.isRecording && manager.state != .starting
        recordButton.title = manager.isRecording ? "Stop Recording" : "Start Recording"
        recordButton.isEnabled = manager.state != .starting && (!manager.isReconnectingMicrophone || manager.isRecording)
        recordButton.toolTip = "\(hotkeys.shortcutLabel(for: .recording)) - configure in Keyboard Shortcuts"
        pauseButton.title = manager.state == .paused ? "Resume" : "Pause"
        pauseButton.isEnabled = manager.isRecording
        revealButton.isEnabled = manager.lastSessionFolder != nil
        if let error = manager.errorMessage {
            messageLabel.stringValue = error
            messageLabel.textColor = .systemRed
        } else {
            switch manager.state {
            case .starting: messageLabel.stringValue = "Requesting access and connecting sources..."
            case .recording: messageLabel.stringValue = "Recording original tracks locally."
            case .paused: messageLabel.stringValue = "Recording paused. Preview stays live."
            case .previewing: messageLabel.stringValue = "Preview live. Nothing is being saved."
            default: messageLabel.stringValue = "Select sources, then start preview to check your sound."
            }
            if #unavailable(macOS 14.2) { messageLabel.stringValue += " App and system capture need macOS 14.2+." }
            messageLabel.textColor = .secondaryLabelColor
        }
        let sources = manager.selectedSources
        if sources != renderedSources {
            for view in sourceStack.arrangedSubviews { sourceStack.removeArrangedSubview(view); view.removeFromSuperview() }
            cards.removeAll()
            for source in sources {
                let icon = manager.applications.first { $0.bundleID == source.id }?.icon
                let card = AudioSourceCardView(source: source, icon: icon)
                sourceStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
                cards[source.id] = card
            }
            renderedSources = sources
        }
        updateMeters()
    }

    @objc private func updateMeters() {
        let fallbackMessage: String?
        switch manager.state {
        case .starting: fallbackMessage = "Connecting source..."
        case .failed: fallbackMessage = "Capture unavailable"
        default: fallbackMessage = nil
        }
        for (id, card) in cards {
            card.update(manager.meter(for: id), capturing: manager.isCapturing,
                        message: manager.sourceMessages[id] ?? fallbackMessage)
        }
        let seconds = Int(manager.elapsed)
        elapsedLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func changeSettings() {
        var settings = manager.settings
        settings.microphoneEnabled = microphoneToggle.state == .on
        settings.microphoneUID = microphoneIDs.indices.contains(microphonePicker.indexOfSelectedItem) ? microphoneIDs[microphonePicker.indexOfSelectedItem] : nil
        settings.outputMode = RecordingOutputMode.allCases[outputPicker.indexOfSelectedItem]
        settings.format = RecordingFileFormat.allCases[formatPicker.indexOfSelectedItem]
        settings.splitMinutes = [15, 30, 60][splitPicker.indexOfSelectedItem]
        manager.updateSettings(settings)
    }

    @objc private func selectApplication(_ sender: RecordingApplicationButton) {
        var settings = manager.settings
        settings.applicationBundleIDs.removeAll { $0 == sender.bundleID }
        if sender.state == .on { settings.applicationBundleIDs.append(sender.bundleID) }
        manager.updateSettings(settings)
    }

    @objc private func togglePreview() {
        if manager.state == .previewing { manager.stopPreview() } else { manager.startPreview() }
    }
    @objc private func toggleRecording() { manager.toggleRecording() }
    @objc private func togglePause() { manager.togglePause() }
    @objc private func chooseFolder() {
        guard !manager.controlsLocked else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            var settings = manager.settings
            settings.folderPath = url.path
            manager.updateSettings(settings)
        }
    }
    @objc private func revealRecording() {
        if let folder = manager.lastSessionFolder { NSWorkspace.shared.open(folder) }
    }
}
