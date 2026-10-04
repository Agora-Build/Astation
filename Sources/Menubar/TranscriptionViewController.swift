import AppKit
import UniformTypeIdentifiers

private final class TranscriptionDocumentView: NSView { override var isFlipped: Bool { true } }
private final class TranscriptionSourceButton: NSButton { var sourceID = "" }

final class TranscriptionViewController: NSViewController {
    var onConfigureSources: (() -> Void)?
    static let languages: [(code: String, title: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("zh-CN", "Chinese (Mandarin)"),
        ("zh-TW", "Chinese (Taiwan)"), ("zh-HK", "Chinese (Cantonese)"), ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"), ("es-ES", "Spanish"), ("fr-FR", "French"), ("de-DE", "German"),
        ("it-IT", "Italian"), ("pt-BR", "Portuguese (Brazil)"), ("hi-IN", "Hindi"),
        ("ar-SA", "Arabic"), ("ru-RU", "Russian"), ("vi-VN", "Vietnamese")
    ]
    private let recorder: AudioRecordingManager
    private let manager: AudioTranscriptionManager
    private let providerPicker = NSPopUpButton()
    private let modelPicker = NSPopUpButton()
    private let modelDetails = NSTextField(wrappingLabelWithString: "")
    private let sourceStack = NSStackView()
    private let languagePicker = NSPopUpButton()
    private let translationPicker = NSPopUpButton()
    private let manifestField = NSTextField()
    private let toastToggle = NSButton(checkboxWithTitle: "Floating captions - multiline, last 20 seconds", target: nil, action: nil)
    private let showCaptionsButton = NSButton(title: "Show Floating Captions", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download Selected Model", target: nil, action: nil)
    private let startButton = NSButton(title: "Start Transcription", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Transcript", target: nil, action: nil)
    private let exportButton = NSButton(title: "Save Transcript...", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let modelLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let localControls = NSStackView()
    private let customControls = NSStackView()
    private let endpointField = NSTextField()
    private let remoteModelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyStatus = NSTextField(wrappingLabelWithString: "")
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)
    private let clearKeyButton = NSButton(title: "Clear Key", target: nil, action: nil)
    private let chunkPicker = NSPopUpButton()
    private let autoSaveToggle = NSButton(checkboxWithTitle: "Auto-save transcript - TXT + live JSONL history", target: nil, action: nil)
    private let autoSaveControls = NSStackView()
    private let transcriptFolder = NSTextField(wrappingLabelWithString: "")
    private let chooseTranscriptFolder = NSButton(title: "Choose Transcript Folder...", target: nil, action: nil)
    private let showSavedButton = NSButton(title: "Show Saved", target: nil, action: nil)
    private let autoSaveStatus = NSTextField(wrappingLabelWithString: "")
    private var observers: [NSObjectProtocol] = []
    private var renderedSources: [AudioSourceSelection]?
    private var sourceButtons: [TranscriptionSourceButton] = []

    init(recorder: AudioRecordingManager, manager: AudioTranscriptionManager? = nil) {
        self.recorder = recorder; self.manager = manager ?? recorder.transcription
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        let document = TranscriptionDocumentView()
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
        stack.spacing = 12
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let eyebrow = label("LIVE AUDIO", size: 10, weight: .semibold)
        eyebrow.textColor = .systemTeal
        stack.addArrangedSubview(eyebrow)
        let title = label("Live Transcription", size: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(label("Read your selected sources in real time. Drag floating captions anywhere, including another monitor."))
        stack.addArrangedSubview(label("Transcribe without saving audio, record without captions, or run both together. Each feature has its own Start and Stop controls."))
        stack.addArrangedSubview(label("Enable sources in Audio & Recording, then check the ones to transcribe here. You do not need to start recording."))
        let configure = NSButton(title: "Configure Audio Sources...", target: self, action: #selector(configureSources))
        configure.bezelStyle = .rounded
        stack.addArrangedSubview(configure)
        providerPicker.addItems(withTitles: TranscriptionProvider.allCases.map(\.title))
        languagePicker.addItems(withTitles: Self.languages.map(\.title))
        translationPicker.addItems(withTitles: ["Off"] + Self.languages.map(\.title))
        stack.addArrangedSubview(row("Engine", control: providerPicker))
        providerPicker.target = self; providerPicker.action = #selector(changeSettings)
        stack.addArrangedSubview(label("Listen to", size: 12, weight: .semibold))
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 6
        sourceStack.setHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(sourceStack)
        stack.addArrangedSubview(label("Select one or more sources. Each gets its own captions; originals are never mixed or modified. All system audio and selected-app capture are alternative modes."))
        for (name, control) in [("Input language", languagePicker), ("Translate to", translationPicker)] {
            stack.addArrangedSubview(row(name, control: control))
            control.target = self; control.action = #selector(changeSettings)
        }
        localControls.orientation = .vertical
        localControls.alignment = .leading
        localControls.spacing = 8
        localControls.setHuggingPriority(.required, for: .vertical)
        modelPicker.addItems(withTitles: LocalTranscriptionModel.allCases.map(\.title))
        modelPicker.target = self; modelPicker.action = #selector(changeSettings)
        localControls.addArrangedSubview(row("Local model", control: modelPicker))
        modelDetails.font = .systemFont(ofSize: 11); modelDetails.textColor = .secondaryLabelColor
        localControls.addArrangedSubview(modelDetails)
        modelLabel.font = .systemFont(ofSize: 11)
        localControls.addArrangedSubview(modelLabel)
        manifestField.placeholderString = "Optional HTTPS manifest from GitHub or dl.agora.build"
        manifestField.font = .systemFont(ofSize: 11)
        manifestField.target = self; manifestField.action = #selector(changeSettings)
        localControls.addArrangedSubview(row("Model mirror", control: manifestField))
        localControls.addArrangedSubview(downloadButton)
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar
        localControls.addArrangedSubview(progress)
        stack.addArrangedSubview(localControls)
        for child in localControls.arrangedSubviews where !(child is NSButton) {
            child.widthAnchor.constraint(equalTo: localControls.widthAnchor).isActive = true
        }
        customControls.orientation = .vertical; customControls.alignment = .leading; customControls.spacing = 8
        endpointField.placeholderString = "https://your-server/v1/audio/transcriptions"
        remoteModelField.placeholderString = "Server model name, e.g. whisper-1"
        keyField.placeholderString = "Optional API key - stored only in Keychain"
        chunkPicker.addItems(withTitles: ["5 seconds", "10 seconds", "15 seconds"])
        for (title, control) in [("Endpoint", endpointField as NSControl), ("Server model", remoteModelField), ("Audio window", chunkPicker)] {
            customControls.addArrangedSubview(row(title, control: control))
            control.target = self; control.action = #selector(changeSettings)
        }
        customControls.addArrangedSubview(row("API key", control: keyField))
        let keyActions = NSStackView(views: [saveKeyButton, clearKeyButton]); keyActions.spacing = 8
        customControls.addArrangedSubview(keyActions)
        keyStatus.font = .systemFont(ofSize: 11); keyStatus.textColor = .secondaryLabelColor
        customControls.addArrangedSubview(keyStatus)
        customControls.addArrangedSubview(label("OpenAI-compatible multipart uploads; the service must return JSON with a text field. This is short-window HTTP transcription, not a continuous WebSocket stream. HTTPS is required except on localhost. Keys are bound to the exact endpoint and never saved in transcript files."))
        stack.addArrangedSubview(customControls)
        for child in customControls.arrangedSubviews { child.widthAnchor.constraint(equalTo: customControls.widthAnchor).isActive = true }
        toastToggle.target = self; toastToggle.action = #selector(toggleToast)
        stack.addArrangedSubview(toastToggle)
        stack.addArrangedSubview(showCaptionsButton)
        stack.addArrangedSubview(privacyLabel)
        autoSaveToggle.target = self; autoSaveToggle.action = #selector(changeSettings)
        stack.addArrangedSubview(autoSaveToggle)
        autoSaveControls.orientation = .vertical; autoSaveControls.alignment = .leading; autoSaveControls.spacing = 6
        transcriptFolder.font = .systemFont(ofSize: 11); transcriptFolder.textColor = .secondaryLabelColor
        autoSaveControls.addArrangedSubview(transcriptFolder)
        autoSaveControls.addArrangedSubview(chooseTranscriptFolder)
        stack.addArrangedSubview(autoSaveControls)
        autoSaveStatus.font = .systemFont(ofSize: 11); autoSaveStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(autoSaveStatus)
        let actions = NSStackView(views: [startButton, copyButton, exportButton])
        actions.spacing = 8
        actions.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(showSavedButton)
        statusLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(statusLabel)
        for (button, action) in [(downloadButton, #selector(downloadModel)), (startButton, #selector(toggleTranscription)),
                                 (copyButton, #selector(copyTranscript)), (exportButton, #selector(exportTranscript)),
                                 (saveKeyButton, #selector(saveCustomKey)), (clearKeyButton, #selector(clearCustomKey)),
                                 (showCaptionsButton, #selector(showCaptions)),
                                 (chooseTranscriptFolder, #selector(chooseFolder)), (showSavedButton, #selector(showSaved))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        for child in stack.arrangedSubviews where !(child is NSButton) {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            child.setContentHuggingPriority(.required, for: .vertical)
        }
        for (name, object) in [(Notification.Name.transcriptionChanged, manager as AnyObject), (.audioRecordingChanged, recorder as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }
    private func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = size <= 11 ? .secondaryLabelColor : .labelColor
        return label
    }
    private func row(_ title: String, control: NSView) -> NSStackView {
        let title = label(title, size: 12)
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [title, control])
        row.spacing = 12
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.setHuggingPriority(.required, for: .vertical)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return row
    }
    private func refresh() {
        guard isViewLoaded else { return }
        let settings = manager.settings
        let locked = manager.isActive || manager.downloadProgress != nil
        let local = settings.provider == .local
        let custom = settings.provider == .custom
        let englishOnly = local && settings.localModel.isEnglishOnly
        providerPicker.selectItem(at: TranscriptionProvider.allCases.firstIndex(of: settings.provider) ?? 0)
        let sources = recorder.selectedSources
        let identities = sources.map(\.id)
        if sources != renderedSources {
            for child in sourceStack.arrangedSubviews { sourceStack.removeArrangedSubview(child); child.removeFromSuperview() }
            sourceButtons = []
            for source in sources {
                let title = source.id == "microphone" ? "Microphone - \(source.title)" : source.title
                let button = TranscriptionSourceButton(checkboxWithTitle: title, target: self, action: #selector(selectSources))
                button.sourceID = source.id
                button.identifier = NSUserInterfaceItemIdentifier("transcription-source-\(source.id)")
                button.setAccessibilityLabel("Transcribe \(title)")
                button.cell?.lineBreakMode = .byTruncatingTail
                button.toolTip = title
                sourceButtons.append(button); sourceStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
            }
            if sources.isEmpty { sourceStack.addArrangedSubview(label("No sources enabled. Configure Audio & Recording to add a microphone, system audio, or apps.")) }
            renderedSources = sources
        }
        for button in sourceButtons {
            button.state = settings.selectedSourceIDs.contains(button.sourceID) ? .on : .off
            button.isEnabled = !locked
        }
        languagePicker.selectItem(at: Self.languages.firstIndex { $0.code == settings.language } ?? 0)
        modelPicker.selectItem(at: LocalTranscriptionModel.allCases.firstIndex(of: settings.localModel) ?? 0)
        translationPicker.selectItem(at: settings.translationLanguage.flatMap { code in Self.languages.firstIndex { $0.code == code }.map { $0 + 1 } } ?? 0)
        if manifestField.currentEditor() == nil { manifestField.stringValue = settings.modelManifestURL }
        for control in [providerPicker, modelPicker, languagePicker, translationPicker, manifestField, endpointField,
                        remoteModelField, keyField, chunkPicker, saveKeyButton, clearKeyButton, autoSaveToggle, chooseTranscriptFolder] as [NSControl] {
            control.isEnabled = !locked
        }
        languagePicker.isEnabled = !locked && !englishOnly
        translationPicker.isEnabled = !locked && settings.provider == .agora
        localControls.isHidden = !local
        customControls.isHidden = !custom
        if endpointField.currentEditor() == nil { endpointField.stringValue = settings.customEndpoint }
        if remoteModelField.currentEditor() == nil { remoteModelField.stringValue = settings.customModel }
        chunkPicker.selectItem(at: [5, 10, 15].firstIndex(of: settings.customChunkSeconds) ?? 0)
        keyStatus.stringValue = manager.customKeyMessage ?? "Leave the key blank for servers without authentication; use Save Key to store a new key."
        toastToggle.state = settings.floatingCaptions ? .on : .off
        switch settings.provider {
        case .local: privacyLabel.stringValue = "On-device captions. No audio uploads. Each checked source loads its own model instance, using more memory and processing. Download the chosen model once for all sources. Labels describe tradeoffs, not guaranteed benchmark rankings."
        case .agora: privacyLabel.stringValue = "Agora Real-Time STT & Translation uploads only the checked sources. Each source uses a separate cloud session and may be billed."
        case .custom: privacyLabel.stringValue = "Only checked sources are uploaded to your endpoint in separate audio windows. Service charges and retention depend on your provider."
        }
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = local ? .secondaryLabelColor : .systemOrange
        let installed = manager.modelStore.hasInstalledModel(settings.localModel)
        let bytes = (try? TranscriptionModelManifest.bundled(for: settings.localModel).totalBytes) ?? 0
        let size = bytes >= 1_000_000_000 ? String(format: "%.2f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
        modelDetails.stringValue = settings.localModel.detail
        modelLabel.stringValue = manager.downloadMessage ?? "\(settings.localModel.name) / \(installed ? "Installed for offline use" : "\(size) download") / \(settings.localModel == .parakeet ? "NVIDIA Open Model License" : "MIT license")"
        downloadButton.title = manager.downloadProgress != nil ? "Cancel Download" : (installed ? "Download Again" : "Download Selected Model")
        downloadButton.isEnabled = !manager.isActive
        progress.isHidden = manager.downloadProgress == nil
        progress.doubleValue = manager.downloadProgress ?? 0
        startButton.title = manager.isActive ? "Stop Transcription" : "Start Transcription"
        let validSources = !settings.selectedSourceIDs.isEmpty && settings.selectedSourceIDs.allSatisfy { identities.contains($0) }
        startButton.isEnabled = manager.state != .stopping && manager.downloadProgress == nil
            && (manager.isActive || (validSources && (!local || installed) && (!custom || CustomTranscriptionHTTP.endpoint(settings.customEndpoint) != nil)))
        copyButton.isEnabled = !manager.transcript.segments.isEmpty
        exportButton.isEnabled = copyButton.isEnabled
        autoSaveToggle.state = settings.autoSaveTranscript ? .on : .off
        autoSaveControls.isHidden = !settings.autoSaveTranscript
        transcriptFolder.stringValue = settings.transcriptFolderPath
        autoSaveStatus.stringValue = manager.autoSaveMessage ?? ""
        autoSaveStatus.isHidden = autoSaveStatus.stringValue.isEmpty
        showSavedButton.isHidden = manager.lastTranscriptFolder == nil
        showSavedButton.isEnabled = manager.lastTranscriptFolder != nil
        let missingSources = settings.selectedSourceIDs.contains { !identities.contains($0) }
        statusLabel.stringValue = manager.message ?? (missingSources
            ? "A previously selected source is no longer enabled. Check the sources to use, or configure Audio & Recording."
            : "Captions are off. Check one or more enabled sources to start.")
        statusLabel.textColor = manager.state == .failed ? .systemRed : .secondaryLabelColor
    }
    @objc private func configureSources() { onConfigureSources?() }
    @objc private func changeSettings() {
        guard !manager.isActive, manager.downloadProgress == nil else { return }
        var settings = manager.settings
        settings.provider = TranscriptionProvider.allCases[providerPicker.indexOfSelectedItem]
        settings.localModel = LocalTranscriptionModel.allCases[modelPicker.indexOfSelectedItem]
        settings.language = settings.provider == .local && settings.localModel.isEnglishOnly ? "en-US" : Self.languages[languagePicker.indexOfSelectedItem].code
        let target = translationPicker.indexOfSelectedItem
        settings.translationLanguage = settings.provider != .agora || target <= 0 ? nil : Self.languages[target - 1].code
        settings.modelManifestURL = manifestField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customEndpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customModel = remoteModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customChunkSeconds = [5, 10, 15][chunkPicker.indexOfSelectedItem]
        settings.autoSaveTranscript = autoSaveToggle.state == .on
        manager.updateSettings(settings)
    }
    @objc private func selectSources() {
        guard !manager.isActive, manager.downloadProgress == nil else { return }
        let selected = sourceButtons.filter { $0.state == .on }.map(\.sourceID)
        var settings = manager.settings
        settings.sourceID = selected.first ?? ""
        settings.additionalSourceIDs = Array(selected.dropFirst())
        manager.updateSettings(settings)
    }
    @objc private func toggleToast() { manager.setFloatingCaptions(toastToggle.state == .on) }
    @objc private func showCaptions() { manager.setFloatingCaptions(true) }
    @objc private func downloadModel() {
        if manager.downloadProgress != nil { manager.cancelDownload() }
        else { changeSettings(); manager.downloadModel() }
    }
    @objc private func toggleTranscription() {
        if manager.isActive { manager.stop(); return }
        changeSettings()
        if manager.settings.provider != .local {
            let alert = NSAlert()
            let agora = manager.settings.provider == .agora
            alert.messageText = "Upload \(manager.settings.selectedSourceIDs.count) source(s) to \(agora ? "Agora" : "your endpoint")?"
            alert.informativeText = agora
                ? "Audio from the checked sources will be uploaded for real-time transcription and optional translation. Each source starts a separate Agora session, so selecting more sources can increase charges. Original recordings stay on this Mac."
                : "Audio from the checked sources will be sent in short WAV windows to \(manager.settings.customEndpoint). Provider charges and retention depend on this service. Original recordings stay on this Mac."
            alert.addButton(withTitle: "Start Cloud Transcription")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            manager.start(cloudConsent: true)
        } else { manager.start() }
    }
    @objc private func saveCustomKey() { changeSettings(); manager.saveCustomKey(keyField.stringValue); keyField.stringValue = "" }
    @objc private func clearCustomKey() { changeSettings(); manager.saveCustomKey(nil); keyField.stringValue = "" }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: manager.settings.transcriptFolderPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = manager.settings; settings.transcriptFolderPath = url.path; manager.updateSettings(settings)
    }
    @objc private func showSaved() { if let folder = manager.lastTranscriptFolder { NSWorkspace.shared.open(folder) } }
    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.transcript.text, forType: .string)
    }
    @objc private func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.nameFieldStringValue = "Astation Transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.export(to: url) }
        catch {
            let alert = NSAlert(); alert.messageText = "Transcript export failed"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}
