import AppKit

extension Notification.Name {
    static let transcriptionChanged = Notification.Name("AstationTranscriptionChanged")
}

private struct TranscriptionSourceWorker: @unchecked Sendable {
    let sourceID: String
    let engine: LiveTranscribing
    let inbox: TranscriptionInbox
}

private final class TranscriptionRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func close() { lock.withLock { open = false } }
    func accept(_ action: () -> Void) { lock.withLock { if open { action() } } }
    var isOpen: Bool { lock.withLock { open } }
}

private struct TranscriptionUploadContext: Equatable {
    let provider: TranscriptionProvider
    let endpoint: String
    let model: String
    let language: String
    let translation: String?
    let sources: [String]
    init(_ settings: TranscriptionSettings) {
        provider = settings.provider; endpoint = settings.customEndpoint; model = settings.customModel
        language = settings.language; translation = settings.translationLanguage; sources = settings.selectedSourceIDs.sorted()
    }
}

/// State and controls live on the main thread; inference consumes a bounded worker inbox.
final class AudioTranscriptionManager {
    enum State: Equatable { case idle, preparing, running, stopping, failed }
    static let defaultsKey = "AstationTranscription.v1"
    private(set) var settings: TranscriptionSettings
    private(set) var state: State = .idle
    private(set) var transcript = TranscriptBuffer()
    private(set) var floatingCaptionBuffer = FloatingCaptionBuffer()
    private(set) var floatingCaptionsVisible = false
    private(set) var sourceTitles: [String: String] = [:]
    private(set) var message: String?
    private(set) var downloadProgress: Double?
    private(set) var downloadMessage: String?
    private(set) var customKeyMessage: String?
    private(set) var autoSaveMessage: String?
    private(set) var lastTranscriptFolder: URL?
    let modelStore: TranscriptionModelStore
    var cloudEngineFactory: ((TranscriptionSettings) throws -> LiveTranscribing)?
    var isActive: Bool { [.preparing, .running, .stopping].contains(state) }
    var isTranscribingMicrophone: Bool { isActive && settings.selectedSourceIDs.contains("microphone") }
    private(set) var desiredMode: TranscriptionMode = .off
    var wantsTranscription: Bool { desiredMode != .off }
    var sourceButtonTitle: String {
        let ids = (pendingSettings ?? settings).selectedSourceIDs
        return desiredMode == .apps && ids.contains("microphone") ? "Apps + Mic" : desiredMode.title
    }
    var availableSources: [AudioSourceSelection] {
        let sources = recorder?.transcriptionSources ?? []
        let known = Set(sources.map(\.id))
        return sources + selectedApplications.filter { !known.contains($0.bundleID) }.map {
            AudioSourceSelection(id: $0.bundleID, title: $0.name, kind: .application($0.bundleID))
        }
    }
    var selectedApplicationIDs: [String] { applicationSelection ?? recorder?.selectedApplicationIDs ?? [] }
    var applicationChoices: [RecordingApplication] {
        var apps = recorder?.applications ?? []
        for id in selectedApplicationIDs where !apps.contains(where: { $0.bundleID == id }) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            apps.append(RecordingApplication(bundleID: id, name: url?.deletingPathExtension().lastPathComponent ?? id,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, processIDs: []))
        }
        return apps
    }
    var selectedApplications: [RecordingApplication] {
        let choices = applicationChoices
        let ids = desiredMode == .apps ? (pendingSettings ?? settings).selectedSourceIDs.filter { !["microphone", "system"].contains($0) }
            : selectedApplicationIDs
        return ids.map { id in
            choices.first { $0.bundleID == id } ?? RecordingApplication(bundleID: id, name: id, icon: nil, processIDs: [])
        }
    }
    private(set) var isDictating = false
    var microphoneDeviceUID: String? { recorder?.settings.microphoneUID }
    private weak var recorder: AudioRecordingManager?
    private weak var captureRecorder: AudioRecordingManager?
    private var auxiliaryRecorder: AudioRecordingManager?
    private let defaults: UserDefaults
    private let engineFactory: ((TranscriptionSettings) async throws -> LiveTranscribing)?
    private let secretStore: TranscriptionSecretStoring
    private var autoSaver: TranscriptAutoSaver?
    private var inboxes: [TranscriptionInbox] = []
    private var task: Task<Void, Never>?
    private var worker: Task<Void, Error>?
    private var downloadTask: Task<Void, Never>?
    private var token = UUID()
    private var downloadToken = UUID()
    private var ownsPreview = false
    private var startedAt: Date?
    private var runSettings: TranscriptionSettings?
    private var observer: NSObjectProtocol?
    private var transitionTask: Task<Void, Never>?
    private var transition = UUID()
    private var pendingSettings: TranscriptionSettings?
    private var applicationSelection: [String]?
    private static let applicationSelectionKey = "AstationTranscriptionApplications.v1"
    private var approvedUpload: TranscriptionUploadContext?
    private var preserveSessionOnStop = false
    private var runGate: TranscriptionRunGate?
    private var saverID = UUID()

    init(recorder: AudioRecordingManager, defaults: UserDefaults = .standard,
         modelStore: TranscriptionModelStore = TranscriptionModelStore(),
         engineFactory: ((TranscriptionSettings) async throws -> LiveTranscribing)? = nil,
         secretStore: TranscriptionSecretStoring = KeychainTranscriptionSecrets()) {
        self.recorder = recorder; self.defaults = defaults; self.modelStore = modelStore; self.engineFactory = engineFactory
        self.secretStore = secretStore
        applicationSelection = defaults.stringArray(forKey: Self.applicationSelectionKey)
        settings = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(TranscriptionSettings.self, from: $0) }
            ?? TranscriptionSettings()
        recorder.onCaptureStopped = { [weak self] in
            guard let self, self.captureRecorder === self.recorder, self.state == .running else { return }
            self.stop(stopOwnedPreview: false)
        }
        recorder.onShutdown = { [weak self] in self?.stop() }
        recorder.retainCaptureForTranscription = { [weak self] in
            guard let self, self.captureRecorder === self.recorder,
                  self.state == .preparing || self.state == .running else { return false }
            // Once recording ends, captions own the retained capture and release it on Stop.
            self.ownsPreview = true
            return true
        }
        observer = NotificationCenter.default.addObserver(forName: .credentialsChanged, object: nil, queue: .main) { [weak self] _ in
            guard self?.settings.provider == .agora else { return }
            self?.stop()
        }
    }
    deinit {
        transitionTask?.cancel(); runGate?.close()
        task?.cancel(); worker?.cancel(); downloadTask?.cancel(); inboxes.forEach { $0.finish() }
        auxiliaryRecorder?.shutdown()
        autoSaver?.finish()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    func updateSettings(_ settings: TranscriptionSettings) {
        guard !isActive, downloadProgress == nil else { return }
        if !settings.modelManifestURL.isEmpty {
            guard let url = URL(string: settings.modelManifestURL), TranscriptionModelManifest.safeURL(url) else {
                fail("Use an HTTPS model manifest URL without embedded credentials or query parameters."); return
            }
        }
        if self.settings.autoSaveTranscript != settings.autoSaveTranscript || self.settings.transcriptFolderPath != settings.transcriptFolderPath {
            autoSaver?.finish(); autoSaver = nil; saverID = UUID()
        }
        if approvedUpload != TranscriptionUploadContext(settings) { approvedUpload = nil }
        self.settings = settings
        if isDictating { pendingSettings = settings }
        downloadMessage = nil; customKeyMessage = nil
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
        message = nil; state = .idle; notify()
    }
    func saveCustomKey(_ value: String?) {
        guard !isActive else { return }
        guard CustomTranscriptionHTTP.endpoint(settings.customEndpoint) != nil else {
            customKeyMessage = "Enter and apply a valid endpoint before saving its key."; notify(); return
        }
        do {
            try secretStore.write(value, endpoint: settings.customEndpoint)
            customKeyMessage = value?.isEmpty == false ? "API key saved in Keychain for this exact endpoint." : "API key cleared for this endpoint."
        } catch { customKeyMessage = error.localizedDescription }
        notify()
    }
    func setFloatingCaptions(_ enabled: Bool) {
        settings.floatingCaptions = enabled
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
        notify(showFloatingCaptions: enabled)
    }
    func toggleFloatingCaptions() { setFloatingCaptions(!floatingCaptionsVisible) }
    func updateFloatingCaptionVisibility(_ visible: Bool) { floatingCaptionsVisible = visible }
    func expireFloatingCaptions(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        floatingCaptionBuffer.expire(now: now)
    }
    func downloadModel() {
        guard !isActive, downloadProgress == nil else { return }
        let identifier = UUID()
        downloadToken = identifier
        downloadProgress = 0; downloadMessage = "Downloading and verifying \(settings.localModel.name)..."; notify()
        let manifestURL = settings.modelManifestURL
        let selectedModel = settings.localModel
        let store = modelStore
        downloadTask = Task { @MainActor [weak self] in
            do {
                let manifest: TranscriptionModelManifest
                if manifestURL.isEmpty { manifest = try TranscriptionModelManifest.bundled(for: selectedModel) }
                else {
                    guard let url = URL(string: manifestURL), TranscriptionModelManifest.safeURL(url) else {
                        throw TranscriptionError.message("Use an HTTPS model manifest URL without embedded credentials.")
                    }
                    let (file, response) = try await URLSession.shared.download(from: url)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard (response as? HTTPURLResponse)?.statusCode == 200, size <= 1_000_000 else {
                        throw TranscriptionError.message("The model manifest could not be downloaded.")
                    }
                    manifest = try JSONDecoder().decode(TranscriptionModelManifest.self, from: Data(contentsOf: file))
                }
                guard manifest.id == selectedModel.id else { throw TranscriptionError.message("The manifest does not match the selected local model.") }
                try await store.download(manifest: manifest) { [weak self] fraction in
                    DispatchQueue.main.async {
                        guard let self, self.downloadToken == identifier, self.downloadTask != nil else { return }
                        self.downloadProgress = fraction; self.notify()
                    }
                }
                guard let self, self.downloadToken == identifier else { return }
                self.downloadToken = UUID()
                self.downloadProgress = nil; self.downloadMessage = "\(selectedModel.name) installed. Transcription now works offline."
                self.downloadTask = nil; self.notify()
            } catch {
                guard let self, self.downloadToken == identifier else { return }
                self.downloadToken = UUID()
                self.downloadProgress = nil
                self.downloadMessage = Task.isCancelled ? "Download cancelled. The previously installed model is unchanged." : error.localizedDescription
                self.downloadTask = nil; self.notify()
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }

    func refreshApplicationChoices() { recorder?.refreshSources() }

    @discardableResult
    func saveApplicationSelection(_ ids: [String]) -> Bool {
        let choices = Set(applicationChoices.map(\.bundleID))
        var seen = Set<String>()
        let selection = ids.filter { !["", "microphone", "system"].contains($0) && seen.insert($0).inserted }
        guard !selection.isEmpty, selection.allSatisfy({ choices.contains($0) }) else { return false }
        // Keep the running recording's source settings and tracks independent of this picker.
        applicationSelection = selection
        defaults.set(selection, forKey: Self.applicationSelectionKey)
        notify()
        return true
    }

    func settings(for mode: TranscriptionMode) throws -> TranscriptionSettings {
        var value = pendingSettings ?? settings
        let ids: [String]
        switch mode {
        case .off: ids = []
        case .mic: ids = ["microphone"]
        case .system: ids = ["system"]
        case .all: ids = ["microphone", "system"]
        case .apps:
            ids = selectedApplicationIDs
            guard !ids.isEmpty else {
                throw TranscriptionError.message("Choose applications in Audio & Recording, then select Apps again.")
            }
        }
        value.sourceID = ids.first ?? ""; value.additionalSourceIDs = Array(ids.dropFirst())
        return value
    }
    func requiresConsent(for value: TranscriptionSettings) -> Bool {
        value.provider != .local && approvedUpload != TranscriptionUploadContext(value)
    }
    func selectMode(_ mode: TranscriptionMode, cloudConsent: Bool = false) {
        do {
            let value = try settings(for: mode)
            if mode != .off && requiresConsent(for: value) && !cloudConsent {
                message = "Allow uploading the selected sources before starting remote transcription."; notify(); return
            }
            if cloudConsent { approvedUpload = TranscriptionUploadContext(value) }
            desiredMode = mode; pendingSettings = value
            setFloatingCaptions(true)
            if mode == .off { stop(); return }
            if isActive { stopRun(preserveSession: true, interrupt: true) }
            if !isDictating { scheduleTransition() }
            else { message = "\(mode.title) transcription is paused for dictation."; notify() }
        } catch { message = error.localizedDescription; notify() }
    }
    private func scheduleTransition() {
        transitionTask?.cancel()
        let id = UUID(); transition = id
        let previous = task
        transitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.transition == id, !Task.isCancelled, !self.isDictating else { return }
            self.transitionTask = nil
            guard self.wantsTranscription else { self.autoSaver?.finish(); return }
            if let pending = self.pendingSettings {
                self.updateSettings(pending); self.pendingSettings = nil
            }
            self.start(cloudConsent: !self.requiresConsent(for: self.settings), preservingTranscript: true)
        }
    }
    @MainActor func waitForDictationPriority() async {
        // Capture the task before suspension; completion clears it on the main actor.
        guard let stoppingTask = task else { return }
        await stoppingTask.value
    }

    func start(cloudConsent: Bool = false, preservingTranscript: Bool = false) {
        guard !isActive, downloadProgress == nil, let recorder else { return }
        let selectedIDs = settings.selectedSourceIDs
        let available = availableSources
        guard !selectedIDs.isEmpty, selectedIDs.allSatisfy({ id in available.contains { $0.id == id } }) else {
            fail("Choose a valid source in the floating controls to start transcription."); return
        }
        if settings.provider != .local && !cloudConsent {
            fail("Remote transcription requires explicit permission to upload the selected sources."); return
        }
        if settings.provider == .custom {
            do { try CustomTranscriptionHTTP.validate(settings) }
            catch { fail(error.localizedDescription); return }
        }
        if settings.provider != .agora && settings.translationLanguage != nil {
            fail("Choose Agora cloud for a translation target. Local and custom modes transcribe the input language."); return
        }
        if settings.provider == .local && settings.localModel.isEnglishOnly && settings.language != "en-US" {
            fail("The local Parakeet model supports English. Choose English or use Agora cloud for other languages."); return
        }
        if settings.translationLanguage == settings.language {
            fail("The translation language must differ from the input language."); return
        }
        if cloudConsent && settings.provider != .local { approvedUpload = TranscriptionUploadContext(settings) }
        desiredMode = .selected(by: selectedIDs)
        if isDictating {
            pendingSettings = settings; message = "Transcription is paused for dictation."; notify(); return
        }
        let identifier = UUID()
        token = identifier
        preserveSessionOnStop = false
        let gate = TranscriptionRunGate(); runGate = gate
        state = .preparing; message = "Preparing transcription..."
        if !preservingTranscript {
            transcript = TranscriptBuffer(); floatingCaptionBuffer = FloatingCaptionBuffer()
            startedAt = Date(); runSettings = settings
            autoSaver?.finish(); autoSaver = nil; autoSaveMessage = nil
        }
        if startedAt == nil { startedAt = Date(); runSettings = settings }
        let offset = preservingTranscript ? Date().timeIntervalSince(startedAt!) : 0
        let selected = settings
        let titles: [String: String] = Dictionary(uniqueKeysWithValues: selectedIDs.compactMap { id in
            guard let source = available.first(where: { $0.id == id }) else { return nil }
            return (source.id, source.id == "microphone" ? "Microphone" : source.title)
        })
        if preservingTranscript { sourceTitles.merge(titles, uniquingKeysWith: { _, new in new }) }
        else { sourceTitles = titles }
        let customFactory = engineFactory
        let cloudFactory = cloudEngineFactory
        let store = modelStore
        let secrets = secretStore
        if selected.autoSaveTranscript && autoSaver == nil {
            do {
                let saveID = UUID(); saverID = saveID
                guard selected.transcriptFolderPath.hasPrefix("/") else { throw TranscriptionError.message("Choose an absolute transcript folder.") }
                let saver = try TranscriptAutoSaver(root: URL(fileURLWithPath: selected.transcriptFolderPath, isDirectory: true),
                    settings: selected, startedAt: startedAt ?? Date()) { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self, self.saverID == saveID else { return }
                        self.autoSaveMessage = text; self.notify()
                    }
                }
                autoSaver = saver; lastTranscriptFolder = saver.folder
                autoSaveMessage = "Auto-saving TXT and live JSONL history."
            } catch {
                // A file error must not prevent otherwise healthy captions or original recording.
                autoSaveMessage = "Transcript auto-save could not start. Choose another folder or use Save Transcript."
            }
        }
        let sessionSaver = autoSaver
        let requested = selectedIDs.compactMap { id in available.first { $0.id == id } }
        let activeIDs = Set(recorder.activeSources.map(\.id))
        let canShare = (recorder.isCapturing || recorder.state == .starting) && Set(selectedIDs).isSubset(of: activeIDs)
        let canOwn = !recorder.isCapturing && recorder.state != .starting && Set(selectedIDs) == Set(recorder.selectedSources.map(\.id))
        let capture: AudioRecordingManager
        if canShare || canOwn { capture = recorder }
        else {
            capture = recorder.makeTranscriptionCapture(); auxiliaryRecorder = capture
            capture.onCaptureStopped = { [weak self] in
                guard let self, self.state == .running else { return }
                self.stop(stopOwnedPreview: false)
            }
        }
        captureRecorder = capture
        notify()
        task = Task { @MainActor [weak self, weak capture] in
            var sources: [TranscriptionSourceWorker] = []
            do {
                let directory = customFactory == nil && selected.provider == .local ? try await store.verifiedDirectory(for: selected.localModel) : nil
                let customKey = customFactory == nil && selected.provider == .custom ? try secrets.read(endpoint: selected.customEndpoint) : nil
                for id in selectedIDs {
                    try Task.checkCancellation()
                    var sourceSettings = selected
                    sourceSettings.sourceID = id; sourceSettings.additionalSourceIDs = []
                    let engine: LiveTranscribing
                    if let customFactory { engine = try await customFactory(sourceSettings) }
                    else if let directory {
                        engine = selected.localModel == .parakeet
                            ? LocalParakeetTranscriber(directory: directory, sourceID: id)
                            : LocalWhisperTranscriber(directory: directory, settings: sourceSettings)
                    }
                    else if selected.provider == .custom { engine = CustomHTTPTranscriber(settings: sourceSettings, key: customKey) }
                    else {
                        guard let cloudFactory else { throw TranscriptionError.message("Sign in and select an Agora project with Real-Time STT enabled.") }
                        engine = try cloudFactory(sourceSettings)
                    }
                    sources.append(TranscriptionSourceWorker(sourceID: id, engine: engine, inbox: TranscriptionInbox()))
                }
                try Task.checkCancellation()
                guard let self, let recorder = capture, self.token == identifier else {
                    for source in sources { await source.engine.cancel() }; return
                }
                self.inboxes = sources.map(\.inbox)
                // Resolve capture permissions before starting a billable cloud session.
                if !recorder.isCapturing && recorder.state != .starting {
                    self.ownsPreview = true
                    recorder.startPreview(sources: recorder === self.recorder ? nil : requested)
                }
                while recorder.state == .starting { try await Task.sleep(nanoseconds: 50_000_000) }
                try Task.checkCancellation()
                guard recorder.isCapturing else { throw TranscriptionError.message(recorder.errorMessage ?? "The audio source could not be started.") }
                for source in sources {
                    try await source.engine.start { [weak self] segment in
                        let segment = TranscriptSegment(id: preservingTranscript ? "\(identifier)-\(segment.id)" : segment.id, sourceID: segment.sourceID,
                            language: segment.language, text: segment.text, isFinal: segment.isFinal,
                            offset: segment.offset + offset, isTranslation: segment.isTranslation)
                        gate.accept {
                            // Normal Stop accepts final callbacks; suspension rejects all late results.
                            sessionSaver?.append(segment)
                            DispatchQueue.main.async {
                                guard let self, self.token == identifier, gate.isOpen, self.state != .failed else { return }
                                self.transcript.update(segment)
                                self.floatingCaptionBuffer.update(segment, now: ProcessInfo.processInfo.systemUptime)
                                self.notify()
                            }
                        }
                    }
                    try Task.checkCancellation()
                }
                guard self.token == identifier else { for source in sources { await source.engine.cancel() }; return }
                guard recorder.isCapturing, selectedIDs.allSatisfy({ id in recorder.activeSources.contains { $0.id == id } }) else {
                    throw TranscriptionError.message("The selected capture changed or stopped while preparing transcription.")
                }
                self.state = .running
                let incoming = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0.inbox) })
                let acceptAfter = mach_absolute_time()
                recorder.setAudioConsumer { [weak self] source, pcm in
                    // Shared recordings keep draining during suspension. Never replay an older queued packet.
                    guard pcm.hostTime >= acceptAfter, let inbox = incoming[source.id] else { return }
                    if !inbox.offer(pcm) {
                        DispatchQueue.main.async {
                            guard let self, self.token == identifier, self.state == .running else { return }
                            self.fail("Transcription could not keep up. Original recording is unaffected.")
                        }
                    }
                }
                switch selected.provider {
                case .local: self.message = "\(selected.localModel.name) live - \(sources.count) source(s), no audio uploads."
                case .agora: self.message = "Agora cloud captions live - \(sources.count) source(s) are being uploaded in separate sessions."
                case .custom: self.message = "Custom HTTP captions live - \(sources.count) source(s) upload in short windows."
                }
                self.notify()
                let activeSources = sources
                let work = Task.detached(priority: .userInitiated) {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for source in activeSources {
                            group.addTask {
                                let converter = TranscriptionAudioConverter()
                                for await pcm in source.inbox.stream {
                                    try Task.checkCancellation()
                                    source.inbox.consumed(pcm)
                                    try await source.engine.consume(converter.convert(pcm))
                                }
                                try Task.checkCancellation()
                                let tail = try converter.finish()
                                if !tail.isEmpty { try await source.engine.consume(tail) }
                                try await source.engine.finish()
                            }
                        }
                        // Throw on the first failing source so other infinite streams are cancelled.
                        while let _ = try await group.next() {}
                    }
                }
                self.worker = work
                try await work.value
                for source in sources { await source.engine.cancel() }
                guard self.token == identifier else { return }
                self.complete()
            } catch {
                if let self, self.token == identifier, self.state != .failed, !Task.isCancelled {
                    // Invalidate capture callbacks before closing inboxes so late audio
                    // cannot replace the original error with an overload failure.
                    self.fail(error.localizedDescription)
                }
                for source in sources { source.inbox.finish(); await source.engine.cancel() }
                guard let self, self.token == identifier else { return }
                if self.state == .failed { self.clearWork() }
                else if Task.isCancelled { self.complete() }
                else { self.fail(error.localizedDescription) }
            }
        }
    }
    func stop(stopOwnedPreview: Bool = true) {
        desiredMode = .off; pendingSettings = nil
        transition = UUID(); transitionTask?.cancel(); transitionTask = nil
        if !isActive { autoSaver?.finish(); autoSaver = nil; notify(); return }
        stopRun(preserveSession: false, interrupt: false, stopOwnedPreview: stopOwnedPreview)
    }
    private func stopRun(preserveSession: Bool, interrupt: Bool, stopOwnedPreview: Bool = true) {
        if !preserveSession { preserveSessionOnStop = false }
        guard isActive else { return }
        if interrupt {
            runGate?.close(); captureRecorder?.setAudioConsumer(nil)
            task?.cancel(); worker?.cancel()
        }
        guard state != .stopping else { return }
        preserveSessionOnStop = preserveSession
        let preparing = state == .preparing
        state = .stopping
        captureRecorder?.setAudioConsumer(nil)
        inboxes.forEach { $0.finish() }
        if interrupt || preparing || settings.provider == .custom { task?.cancel(); worker?.cancel() }
        let stopPreview = ownsPreview && stopOwnedPreview && captureRecorder?.isRecording == false
        ownsPreview = false
        if stopPreview { captureRecorder?.stopPreview() }
        message = "Finishing transcription..."; notify()
    }

    /// Dictation uses the installed local profile, independent of RTC and cloud caption sessions.
    func makeDictationEngine() async throws -> LiveTranscribing {
        var selected = settings
        selected.provider = .local; selected.sourceID = "microphone"; selected.additionalSourceIDs = []
        selected.translationLanguage = nil
        if selected.localModel.isEnglishOnly && selected.language != "en-US" {
            throw TranscriptionError.message("Select English or a multilingual local model in Live Transcription settings for dictation.")
        }
        if let engineFactory { return try await engineFactory(selected) }
        let directory = try await modelStore.verifiedDirectory(for: selected.localModel)
        return selected.localModel == .parakeet ? LocalParakeetTranscriber(directory: directory, sourceID: "microphone")
            : LocalWhisperTranscriber(directory: directory, settings: selected)
    }

    func setDictationActive(_ active: Bool) {
        guard isDictating != active else { return }
        isDictating = active
        if active {
            runGate?.close()
            transitionTask?.cancel(); transition = UUID()
            stopRun(preserveSession: true, interrupt: true)
            message = wantsTranscription ? "\(desiredMode.title) transcription is paused for dictation." : message
        } else if wantsTranscription { scheduleTransition() }
        notify()
    }
    func displayDictationCaption(_ segment: TranscriptSegment, replacingKeys: Set<String> = [], refreshReceipt: Bool = false) {
        guard segment.sourceID == "microphone", !segment.isTranslation else { return }
        sourceTitles["microphone"] = "Microphone Dictation"
        floatingCaptionBuffer.remove(keys: replacingKeys)
        floatingCaptionBuffer.update(segment, now: ProcessInfo.processInfo.systemUptime, refreshReceipt: refreshReceipt)
        notify()
    }
    private func complete() {
        if !preserveSessionOnStop { autoSaver?.finish(); autoSaver = nil }
        else { autoSaver?.flush() }
        clearWork()
        let stopPreview = ownsPreview && captureRecorder?.isRecording == false
        ownsPreview = false
        state = .idle; message = isDictating && wantsTranscription ? "Transcription is paused for dictation." : "Transcription stopped."
        if stopPreview { captureRecorder?.stopPreview() }
        captureRecorder = nil; auxiliaryRecorder = nil
        notify()
    }
    private func fail(_ text: String) {
        autoSaver?.finish(); autoSaver = nil; desiredMode = .off
        runGate?.close()
        token = UUID()
        captureRecorder?.setAudioConsumer(nil)
        inboxes.forEach { $0.finish() }; task?.cancel(); worker?.cancel()
        inboxes = []; task = nil; worker = nil
        let stopPreview = ownsPreview && captureRecorder?.isRecording == false
        ownsPreview = false
        state = .failed; message = text
        if stopPreview { captureRecorder?.stopPreview() }
        captureRecorder = nil; auxiliaryRecorder = nil
        notify()
    }
    private func clearWork() {
        captureRecorder?.setAudioConsumer(nil)
        inboxes = []; task = nil; worker = nil
    }
    func export(to url: URL) throws {
        if url.pathExtension.lowercased() == "txt" {
            try transcript.text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            struct Export: Encodable {
                let schemaVersion = 1
                let startedAt: Date?
                let settings: TranscriptionSettings
                let truncated: Bool
                let segments: [TranscriptSegment]
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Export(startedAt: startedAt, settings: runSettings ?? settings,
                                      truncated: transcript.wasTruncated, segments: transcript.segments)).write(to: url, options: .atomic)
        }
    }
    private func notify(showFloatingCaptions: Bool = false) {
        NotificationCenter.default.post(name: .transcriptionChanged, object: self,
            userInfo: showFloatingCaptions ? ["showFloatingCaptions": true] : nil)
    }
}
