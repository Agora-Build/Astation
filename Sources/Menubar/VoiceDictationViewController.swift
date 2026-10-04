import AppKit

private final class DictationSettingsDocument: NSView { override var isFlipped: Bool { true } }

final class VoiceDictationViewController: NSViewController, NSTextFieldDelegate {
    private let manager: VoiceDictationManager
    let polishKnob = PolishKnob(frame: .zero)
    private let destination = NSPopUpButton()
    private let provider = NSPopUpButton()
    private let remoteControls = NSStackView()
    private let endpoint = NSTextField()
    private let model = NSTextField()
    private let consent = NSButton(checkboxWithTitle: "Allow dictation text uploads to this exact endpoint", target: nil, action: nil)
    private let key = NSSecureTextField()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let keyStatus = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?
    private var transcriptionObserver: NSObjectProtocol?
    private var renderedSettings: DictationSettings?
    var onConfigureTranscription: (() -> Void)?

    init(manager: VoiceDictationManager) { self.manager = manager; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let transcriptionObserver { NotificationCenter.default.removeObserver(transcriptionObserver) }
    }
    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .windowBackgroundColor
        let document = DictationSettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; view = scroll
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let eyebrow = label("SPEAK. REFINE. USE.", size: 10, weight: .semibold); eyebrow.textColor = .systemTeal
        stack.addArrangedSubview(eyebrow)
        stack.addArrangedSubview(label("Voice Dictation", size: 24, weight: .semibold))
        stack.addArrangedSubview(label("Push-to-talk captures while you hold the shortcut; release to finish. Hands-Free listens continuously until you stop it. Both use only your local microphone."))
        stack.addArrangedSubview(label("Dictation uses the installed local ASR model selected in Live Transcription. System/app captions and RTC remain independent. Mic transcription disables dictation."))
        let asr = NSButton(title: "Choose / Download Speech Model...", target: self, action: #selector(configureASR)); asr.bezelStyle = .rounded
        stack.addArrangedSubview(asr)
        destination.addItems(withTitles: DictationDestination.allCases.map(\.title))
        destination.target = self; destination.action = #selector(changeSettings)
        stack.addArrangedSubview(row("Use result", destination))
        stack.addArrangedSubview(label("Typing is opt-in, requires Accessibility permission, and never presses Return. Atem delivery requires the original Atem to remain active and connected. Results also appear in floating captions."))
        let accessibility = NSButton(title: "Allow Accessibility for Typing...", target: self, action: #selector(allowAccessibility)); accessibility.bezelStyle = .rounded
        stack.addArrangedSubview(accessibility)
        let divider = NSBox(); divider.boxType = .separator; stack.addArrangedSubview(divider)
        let polishDescription = label("Refine the words, keep the meaning.\nPunctuation, grammar, and filler cleanup after ASR.", size: 12)
        let polishRow = NSStackView(views: [polishKnob, polishDescription]); polishRow.spacing = 12
        stack.addArrangedSubview(polishRow)
        polishKnob.target = self; polishKnob.action = #selector(togglePolish)
        provider.addItems(withTitles: DictationLLMProvider.allCases.map(\.title))
        provider.target = self; provider.action = #selector(changeSettings)
        stack.addArrangedSubview(row("Polishing LLM", provider))
        stack.addArrangedSubview(details)
        remoteControls.orientation = .vertical; remoteControls.alignment = .leading; remoteControls.spacing = 10
        endpoint.placeholderString = "Full /v1/chat/completions endpoint"
        endpoint.delegate = self
        model.placeholderString = "Model name installed / available at this endpoint"
        key.placeholderString = "LLM API key (stored in Keychain, never in preferences)"
        remoteControls.addArrangedSubview(row("Endpoint", endpoint)); remoteControls.addArrangedSubview(row("Model", model))
        remoteControls.addArrangedSubview(consent)
        consent.target = self; consent.action = #selector(confirmConsent)
        remoteControls.addArrangedSubview(row("API key", key))
        let save = NSButton(title: "Save LLM Key", target: self, action: #selector(saveKey))
        let clear = NSButton(title: "Clear LLM Key", target: self, action: #selector(clearKey))
        save.bezelStyle = .rounded; clear.bezelStyle = .rounded
        let apply = NSButton(title: "Apply Model Settings", target: self, action: #selector(changeSettings)); apply.bezelStyle = .rounded
        remoteControls.addArrangedSubview(NSStackView(views: [apply, save, clear]))
        remoteControls.addArrangedSubview(keyStatus); stack.addArrangedSubview(remoteControls)
        stack.addArrangedSubview(label("Polishing is optional and defaults off. If the selected model fails, raw ASR stays in captions; nothing is typed or sent as a fallback. The knob on floating captions controls this same setting."))
        stack.addArrangedSubview(status)
        for field in [details, status, keyStatus] { field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor }
        for child in [details, remoteControls, status, keyStatus, polishRow, divider] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        observer = NotificationCenter.default.addObserver(forName: .voiceDictationChanged, object: manager, queue: .main) { [weak self] _ in self?.refresh() }
        transcriptionObserver = NotificationCenter.default.addObserver(forName: .transcriptionChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshStatus() }
        refresh()
    }
    func refresh() {
        guard isViewLoaded else { return }
        let settings = manager.settings
        polishKnob.state = settings.polishing ? .on : .off
        destination.selectItem(at: DictationDestination.allCases.firstIndex(of: settings.destination)!)
        provider.selectItem(at: DictationLLMProvider.allCases.firstIndex(of: settings.provider)!)
        // Preserve edits while ASR/status events arrive.
        if renderedSettings?.provider != settings.provider || renderedSettings?.endpoint != settings.endpoint || renderedSettings?.model != settings.model {
            if renderedSettings?.endpoint != settings.endpoint { key.stringValue = "" }
            endpoint.stringValue = settings.endpoint; model.stringValue = settings.model
        }
        if renderedSettings?.consentEndpoint != settings.consentEndpoint || renderedSettings?.provider != settings.provider || renderedSettings?.endpoint != settings.endpoint {
            consent.state = settings.hasUploadConsent ? .on : .off
        }
        renderedSettings = settings
        remoteControls.isHidden = settings.provider == .local
        endpoint.isEnabled = settings.provider == .custom || settings.provider == .localServer
        consent.isHidden = !settings.requiresUploadConsent
        if settings.provider == .local {
            details.stringValue = DictationPolishing.localAvailability ?? "Apple's compact on-device model is ready. Runs locally; no transcript upload. macOS manages its model download."
        } else if settings.provider == .localServer {
            details.stringValue = "Run a small Qwen model locally with Ollama or llama.cpp. Default: qwen3:4b at localhost:11434. Install the runtime/model separately (for Ollama: ollama pull qwen3:4b). This option accepts localhost only and never falls back to cloud. Model size/speed depend on your chosen model and Mac."
        } else if settings.provider == .cloud {
            details.stringValue = "Cloud polishing sends recognized text (not audio) directly to OpenAI. Uses your API key and may incur provider charges. Model name is configurable."
        } else {
            details.stringValue = "Use any OpenAI-compatible Chat Completions server. For local small models, run Ollama / llama.cpp and enter its installed model name. HTTP is allowed only on localhost; no automatic model downloads or server startup."
        }
        keyStatus.stringValue = manager.keyMessage ?? "LLM keys are separate from transcription-service keys."
        refreshStatus()
    }
    private func refreshStatus() {
        guard isViewLoaded else { return }
        status.stringValue = manager.unavailableReason ?? manager.message ?? "Ready. Configure shortcuts in Keyboard Shortcuts."
    }
    @objc private func togglePolish() { manager.setPolishing(polishKnob.state == .on) }
    @objc private func changeSettings() {
        var settings = manager.settings
        let selectedProvider = DictationLLMProvider.allCases[max(0, provider.indexOfSelectedItem)]
        if selectedProvider == settings.provider {
            if settings.provider == .cloud { settings.cloudModel = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            if settings.provider == .localServer {
                settings.localEndpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.localModel = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if settings.provider == .custom {
                settings.customEndpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.customModel = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Editing the URL never carries an old endpoint's consent to a new host.
            if settings.consentEndpoint != settings.endpoint { settings.consentEndpoint = nil }
        }
        settings.provider = selectedProvider
        settings.destination = DictationDestination.allCases[max(0, destination.indexOfSelectedItem)]
        manager.updateSettings(settings)
    }
    @objc private func confirmConsent() {
        let allowed = consent.state == .on
        changeSettings()
        var settings = manager.settings; settings.consentEndpoint = allowed ? settings.endpoint : nil
        manager.updateSettings(settings)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === endpoint else { return }
        if endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != manager.settings.endpoint { consent.state = .off }
    }
    @objc private func saveKey() { changeSettings(); manager.saveKey(key.stringValue); key.stringValue = "" }
    @objc private func clearKey() { manager.saveKey(nil); key.stringValue = "" }
    @objc private func configureASR() { onConfigureTranscription?() }
    @objc private func allowAccessibility() { AccessibilityDictationTarget.requestPermission() }
    private func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        control.setAccessibilityLabel(title)
        let heading = label(title, size: 12, weight: .medium)
        heading.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NSStackView(views: [heading, control]); row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return row
    }
}
