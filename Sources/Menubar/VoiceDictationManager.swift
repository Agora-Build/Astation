import AVFoundation

extension Notification.Name { static let voiceDictationChanged = Notification.Name("AstationVoiceDictationChanged") }

private final class DictationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = TranscriptBuffer()
    func append(_ segment: TranscriptSegment) { lock.withLock { buffer.update(segment) } }
    var segments: [TranscriptSegment] { lock.withLock { buffer.segments } }
}

/// Local-mic dictation. Neither its capture lifetime nor utterance boundaries control RTC.
final class VoiceDictationManager {
    static let defaultsKey = "AstationVoiceDictation.v1"
    private let transcription: AudioTranscriptionManager
    private let captureFactory: (String?) throws -> NativeAudioCapturing
    private let permission: () async -> Bool
    private let engineFactory: () async throws -> LiveTranscribing
    private let resolveTarget: () -> String?
    private let sendText: (String, String) -> Bool
    private let showStatus: (String) -> Void
    private let defaults: UserDefaults
    private let secrets: TranscriptionSecretStoring
    private let polish: (String, DictationSettings) async throws -> String
    private let captureTextTarget: () throws -> DictationTextTarget
    private(set) var settings: DictationSettings
    private(set) var keyMessage: String?
    private(set) var lastRawDictationText = ""
    private(set) var lastPolishedDictationText: String?
    private(set) var isPolishing = false
    private(set) var mode: VoiceCodingMode = .off
    private(set) var isWaitingForResponse = false
    private(set) var message: String?
    private(set) var lastDictationText = ""
    var isAvailable: Bool { !transcription.isTranscribingMicrophone }
    var unavailableReason: String? { isAvailable ? nil : "Mic transcription is active. Stop it or select system/app audio only to use dictation." }
    private var stream: MicrophonePCMStream?
    private var inbox: TranscriptionInbox?
    private var task: Task<Void, Never>?
    private var worker: Task<Void, Error>?
    private var generation = UUID()
    private var target: String?
    private var textTarget: DictationTextTarget?
    private var textTargetError: String?
    private var sentKeys = Set<String>()
    private struct Delivery {
        let segment: TranscriptSegment
        let replacingKeys: Set<String>
        let settings: DictationSettings
    }
    private var deliveries: [Delivery] = []
    private var deliveryTask: Task<Void, Never>?
    private var captureComplete = false

    init(transcription: AudioTranscriptionManager,
         captureFactory: @escaping (String?) throws -> NativeAudioCapturing = { try SharedMicrophoneCapture.shared.makeCapture(deviceUID: $0) },
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         engineFactory: (() async throws -> LiveTranscribing)? = nil,
         resolveTarget: @escaping () -> String? = { nil },
         sendText: @escaping (String, String) -> Bool = { _, _ in false },
         showStatus: @escaping (String) -> Void = { VoiceCodingHUD.shared.show($0, autoHideAfter: 4) },
         defaults: UserDefaults = .standard,
         secrets: TranscriptionSecretStoring = KeychainTranscriptionSecrets(service: "build.agora.astation.dictation-llm"),
         polish: ((String, DictationSettings) async throws -> String)? = nil,
         captureTextTarget: @escaping () throws -> DictationTextTarget = { try AccessibilityDictationTarget.capture() }) {
        self.transcription = transcription; self.captureFactory = captureFactory; self.permission = permission
        self.engineFactory = engineFactory ?? { try await transcription.makeDictationEngine() }
        self.resolveTarget = resolveTarget; self.sendText = sendText; self.showStatus = showStatus
        self.defaults = defaults; self.secrets = secrets; self.captureTextTarget = captureTextTarget
        settings = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(DictationSettings.self, from: $0) } ?? DictationSettings()
        let polisher = DictationPolisher(secrets: secrets)
        self.polish = polish ?? { try await polisher.polish($0, settings: $1) }
        transcription.onBeforeMicrophoneTranscription = { [weak self] in
            self?.cancel(message: "Dictation stopped: switching to microphone transcription.")
        }
    }
    deinit { task?.cancel(); worker?.cancel(); deliveryTask?.cancel(); inbox?.finish(); stream?.stop() }

    func updateSettings(_ value: DictationSettings) {
        if mode != .off && (value.typeInActiveTextField != settings.typeInActiveTextField || value.sendToAtem != settings.sendToAtem || value.provider != settings.provider
            || value.endpoint != settings.endpoint || value.model != settings.model) {
            cancel(message: "Dictation stopped because its model or outputs changed. Start again with the new settings.")
        }
        settings = value; keyMessage = nil
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.defaultsKey) }
        notify()
    }
    func setPolishing(_ enabled: Bool) { var value = settings; value.polishing = enabled; updateSettings(value) }
    func saveKey(_ key: String?) {
        guard settings.provider != .local, CustomTranscriptionHTTP.endpoint(settings.endpoint) != nil else {
            keyMessage = "Choose a valid cloud or custom endpoint before saving its key."; notify(); return
        }
        do {
            try secrets.write(key, endpoint: settings.endpoint)
            keyMessage = key?.isEmpty == false ? "LLM key saved in Keychain for this endpoint." : "LLM key cleared for this endpoint."
        } catch { keyMessage = "The LLM key could not be saved in Keychain." }
        notify()
    }

    func startPTT() { start(.ptt) }
    func startHandsFree() { start(.handsFree) }
    func stopPTT() { if mode == .ptt { finish() } }
    func stopHandsFree() { if mode == .handsFree { finish() } }

    private func start(_ requested: VoiceCodingMode) {
        guard isAvailable else { setMessage(unavailableReason!); return }
        guard mode == .off else { return }
        if settings.polishing {
            do { try DictationPolishing.validate(settings) }
            catch { setMessage(error.localizedDescription); return }
        }
        textTarget = nil; textTargetError = nil
        if settings.typeInActiveTextField {
            do { textTarget = try captureTextTarget() }
            catch { textTargetError = error.localizedDescription }
        }
        let id = UUID(); generation = id
        mode = requested; isWaitingForResponse = false; target = settings.sendToAtem ? resolveTarget() : nil; sentKeys.removeAll()
        lastDictationText = ""
        lastRawDictationText = ""; lastPolishedDictationText = nil; captureComplete = false
        let listeningMessage = requested == .ptt ? "Dictation: hold to speak." : "Hands-Free Dictation: microphone listening."
        setMessage(listeningMessage + (textTargetError.map { " Typing unavailable: \($0)" } ?? ""))
        let inbox = TranscriptionInbox(); self.inbox = inbox
        let results = DictationResults(), uid = transcription.microphoneDeviceUID
        let factory = captureFactory, permission = permission, makeEngine = engineFactory
        task = Task { @MainActor [weak self] in
            var engine: LiveTranscribing?
            do {
                guard await permission() else { throw AudioCaptureError.message("Microphone permission is required for dictation.") }
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                // Releasing while permission/setup is pending must never open the mic later.
                if self.isWaitingForResponse { self.complete(results, id: id); return }
                let capture = try await Task.detached(priority: .userInitiated) { try factory(uid) }.value
                guard self.generation == id, !Task.isCancelled else { capture.stop(); return }
                if self.isWaitingForResponse { capture.stop(); self.complete(results, id: id); return }
                let stream = MicrophonePCMStream(capture: capture); self.stream = stream
                stream.start(onPCM: { pcm in
                    if !inbox.offer(pcm) { throw TranscriptionError.message("Dictation could not keep up. Try a faster local model.") }
                }, onError: { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.cancel(message: error.localizedDescription)
                    }
                })
                let activeEngine = try await makeEngine(); engine = activeEngine
                try Task.checkCancellation()
                try await activeEngine.start { [weak self] segment in
                    guard segment.sourceID == "microphone", !segment.isTranslation, segment.isValid else { return }
                    results.append(segment)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        // Namespace each ASR run: local engines reuse utterance IDs.
                        let caption = self.caption(segment, id: id)
                        guard !self.captureComplete, !self.sentKeys.contains(caption.key) else { return }
                        self.transcription.displayDictationCaption(caption)
                        if self.mode == .handsFree && segment.isFinal { self.sendFinal(caption) }
                    }
                }
                try Task.checkCancellation()
                let work = Task.detached(priority: .userInitiated) {
                    let converter = TranscriptionAudioConverter()
                    for await pcm in inbox.stream {
                        try Task.checkCancellation(); inbox.consumed(pcm)
                        try await activeEngine.consume(converter.convert(pcm))
                    }
                    try Task.checkCancellation()
                    let tail = try converter.finish()
                    if !tail.isEmpty { try await activeEngine.consume(tail) }
                    try await activeEngine.finish()
                }
                self.worker = work
                try await work.value; await activeEngine.cancel()
                self.complete(results, id: id)
            } catch {
                await engine?.cancel()
                guard let self, self.generation == id else { return }
                self.cancel(message: Task.isCancelled ? "Dictation cancelled." : error.localizedDescription)
            }
        }
    }

    private func finish() {
        guard !isWaitingForResponse else { return }
        isWaitingForResponse = true
        stream?.stop(); stream = nil
        inbox?.finish()
        setMessage("Finishing dictation...")
    }

    private func sendFinal(_ segment: TranscriptSegment) {
        guard sentKeys.insert(segment.key).inserted else { return }
        enqueue(segment, replacing: [])
    }

    private func complete(_ results: DictationResults, id: UUID) {
        guard generation == id else { return }
        if mode == .ptt {
            let text = results.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let segment = TranscriptSegment(id: "\(id)-dictation", sourceID: "microphone", language: results.segments.first?.language ?? transcription.settings.language,
                    text: text, isFinal: true, offset: results.segments.first?.offset ?? 0)
                enqueue(segment, replacing: Set(results.segments.map { caption($0, id: id).key }))
            } else { setMessage("No speech detected.") }
        } else if mode == .handsFree {
            for segment in results.segments where segment.isFinal { sendFinal(caption(segment, id: id)) }
        }
        stream?.stop(); stream = nil; inbox = nil; task = nil; worker = nil
        captureComplete = true
        if deliveryTask == nil { finishDelivery() }
    }

    private func caption(_ segment: TranscriptSegment, id: UUID) -> TranscriptSegment {
        TranscriptSegment(id: "\(id)-\(segment.id)", sourceID: "microphone", language: segment.language,
            text: segment.text, isFinal: segment.isFinal, offset: segment.offset)
    }
    private func enqueue(_ segment: TranscriptSegment, replacing keys: Set<String>) {
        guard deliveries.count < 16 else {
            cancel(message: "Polishing cannot keep up with dictation. Speech was not forwarded. Try a faster model or disable polishing.")
            return
        }
        lastRawDictationText = segment.text
        deliveries.append(Delivery(segment: segment, replacingKeys: keys, settings: settings))
        guard deliveryTask == nil else { return }
        let id = generation
        deliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.generation == id && !self.deliveries.isEmpty {
                let delivery = self.deliveries.removeFirst()
                let raw = delivery.segment.text
                self.lastRawDictationText = raw; self.lastPolishedDictationText = nil
                do {
                    let result: String
                    if delivery.settings.polishing {
                        self.isPolishing = true; self.setMessage("Polishing dictation...")
                        result = try DictationPolishing.output(try await self.polish(raw, delivery.settings))
                        try Task.checkCancellation()
                        guard self.generation == id else { return }
                        self.lastPolishedDictationText = result
                    } else { result = raw }
                    guard self.generation == id, !Task.isCancelled else { return }
                    self.lastDictationText = result
                    let final = TranscriptSegment(id: delivery.segment.id, sourceID: "microphone", language: delivery.segment.language,
                        text: result, isFinal: true, offset: delivery.segment.offset)
                    self.transcription.displayDictationCaption(final, replacingKeys: delivery.replacingKeys, refreshReceipt: true)
                    self.deliverResult(result, settings: delivery.settings)
                } catch {
                    guard self.generation == id, !Task.isCancelled else { return }
                    self.lastDictationText = self.lastPolishedDictationText ?? raw
                    // Retain raw locally, but never bypass checked polishing on failure.
                    if self.lastPolishedDictationText == nil {
                        self.transcription.displayDictationCaption(delivery.segment, replacingKeys: delivery.replacingKeys, refreshReceipt: true)
                    }
                    self.setMessage(error.localizedDescription)
                }
                self.isPolishing = false; self.notify()
            }
            guard self.generation == id else { return }
            self.deliveryTask = nil
            if self.captureComplete { self.finishDelivery() }
        }
    }
    private func deliverResult(_ result: String, settings: DictationSettings) {
        var outcomes = [String]()
        // Each selected output is attempted independently after polishing succeeds.
        if settings.typeInActiveTextField {
            do {
                guard let textTarget else {
                    throw DictationError.message(textTargetError ?? "No original text field is available. Result kept in captions.")
                }
                try textTarget.insert(result)
                outcomes.append("Dictation inserted in the original text field.")
            } catch { outcomes.append(error.localizedDescription) }
        }
        if settings.sendToAtem {
            if let target, resolveTarget() == target, sendText(result, target) {
                outcomes.append("Dictation sent to the active Atem.")
            } else { outcomes.append("The original Atem is no longer active or connected. Result kept in captions.") }
        }
        setMessage(outcomes.isEmpty ? "Dictation ready in floating captions." : outcomes.joined(separator: " "))
    }
    private func finishDelivery() {
        mode = .off; isWaitingForResponse = false; isPolishing = false; textTarget = nil; textTargetError = nil; target = nil; notify()
    }

    /// Mode switches discard unfinished speech; they never silently submit it to Atem.
    func cancel(message: String? = nil) {
        generation = UUID()
        task?.cancel(); worker?.cancel(); inbox?.finish(); stream?.stop()
        deliveryTask?.cancel(); deliveryTask = nil; deliveries.removeAll(); isPolishing = false
        stream = nil; inbox = nil; task = nil; worker = nil
        mode = .off; isWaitingForResponse = false; target = nil; textTarget = nil; textTargetError = nil
        if let message { setMessage(message) } else { notify() }
    }
    private func setMessage(_ text: String) { message = text; showStatus(text); notify() }
    private func notify() {
        transcription.setDictationActive(mode != .off)
        NotificationCenter.default.post(name: .voiceDictationChanged, object: self)
    }
}
