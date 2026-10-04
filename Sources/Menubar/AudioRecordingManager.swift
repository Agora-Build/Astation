import AppKit
import AVFoundation
import CStationCore

extension Notification.Name {
    static let audioRecordingChanged = Notification.Name("AstationAudioRecordingChanged")
}

private final class CapturedAudioTrack {
    let source: AudioSourceSelection
    let capture: NativeAudioCapturing
    private var samples: [Float]
    private var waveform: AudioWaveformAccumulator
    private let lock = NSLock()
    private var storedSnapshot = AudioMeterSnapshot()
    var recordingDroppedBaseline: UInt64 = 0

    init(source: AudioSourceSelection, capture: NativeAudioCapturing) {
        self.source = source
        self.capture = capture
        samples = [Float](repeating: 0, count: 4096 * Int(capture.format.channelCount))
        waveform = AudioWaveformAccumulator(channels: Int(capture.format.channelCount), sampleRate: capture.format.sampleRate)
    }

    var snapshot: AudioMeterSnapshot {
        lock.lock(); defer { lock.unlock() }
        return storedSnapshot
    }

    func drain(session: AudioRecordingSession?, consumer: ((AudioSourceSelection, TranscriptionPCM) -> Void)?, checkStatus: Bool = true) throws {
        if checkStatus { try capture.checkStatus() }
        let dropped = astation_audio_queue_dropped_frames(capture.queue)
        session?.updateDroppedFrames(sourceID: source.id, count: dropped - recordingDroppedBaseline)
        if session != nil && dropped > recordingDroppedBaseline {
            throw AudioCaptureError.message("Audio capture could not keep up. The recording was stopped; its files and gap metadata are retained.")
        }
        try samples.withUnsafeMutableBufferPointer { buffer in
            var hostTime: UInt64 = 0
            while true {
                let frames = astation_audio_queue_pop(capture.queue, buffer.baseAddress!, 4096, &hostTime)
                if frames == 0 { break }
                let time = AVAudioTime.seconds(forHostTime: hostTime)
                waveform.consume(UnsafeBufferPointer(buffer), frames: Int(frames), now: time)
                try session?.append(sourceID: source.id, samples: UnsafeBufferPointer(buffer), frames: Int(frames),
                                    hostTime: time, droppedFrames: dropped - recordingDroppedBaseline)
                if let consumer {
                    consumer(source, TranscriptionPCM(samples: Array(buffer.prefix(Int(frames) * Int(capture.format.channelCount))),
                        sampleRate: capture.format.sampleRate, channels: Int(capture.format.channelCount), hostTime: hostTime))
                }
            }
        }
        let snapshot = waveform.takeSnapshot(now: AudioRecordingManager.hostSeconds, droppedFrames: dropped)
        lock.lock()
        storedSnapshot = snapshot
        lock.unlock()
    }
}

/// UI/lifecycle access is on the main thread; audio files and meters use one worker.
final class AudioRecordingManager: NSObject {
    static let defaultsKey = "AstationAudioRecording.v1"
    private static let folderMigrationKey = "AstationAudioRecording.documentsFolderMigration.v1"
    static var hostSeconds: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    enum State: Equatable { case idle, starting, previewing, recording, paused, failed }
    private(set) var settings: AudioRecordingSettings
    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var lastSessionFolder: URL?
    private(set) var microphones: [RecordingMicrophone] = []
    private(set) var applications: [RecordingApplication] = []
    private(set) var sourceMessages: [String: String] = [:]
    var isRecording: Bool { state == .recording || state == .paused }
    var isCapturing: Bool { state == .previewing || isRecording }
    var isReconnectingMicrophone: Bool { !recoveringMicrophones.isEmpty }
    var controlsLocked: Bool { state == .starting || isRecording || isReconnectingMicrophone }
    var elapsed: TimeInterval {
        elapsedLock.lock(); defer { elapsedLock.unlock() }
        return lastElapsed
    }
    var onStateChanged: (() -> Void)?
    var onCaptureStopped: (() -> Void)?
    var retainCaptureForTranscription: (() -> Bool)?
    lazy var transcription = AudioTranscriptionManager(recorder: self, defaults: defaults)

    private let defaults: UserDefaults
    private let captureFactory: ((AudioSourceSelection) throws -> NativeAudioCapturing)?
    private let microphonePermission: () async -> Bool
    private let ioQueue = DispatchQueue(label: "build.agora.astation.audio-recording", qos: .userInitiated)
    private let setupQueue = DispatchQueue(label: "build.agora.astation.audio-capture-setup", qos: .userInitiated)
    private var tracks: [String: CapturedAudioTrack] = [:]
    private var workerTracks: [CapturedAudioTrack] = []
    private var session: AudioRecordingSession?
    private var ioTimer: DispatchSourceTimer?
    private var catalogTimer: Timer?
    private var checkpointTicks = 0
    private var lastElapsed: TimeInterval = 0
    private let elapsedLock = NSLock()
    private var operation = UUID()
    private var pendingSources: Set<String> = []
    private var recoveringMicrophones: Set<String> = []
    private var microphoneRecoveryTimes: [String: [TimeInterval]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var audioConsumer: ((AudioSourceSelection, TranscriptionPCM) -> Void)?

    func setAudioConsumer(_ consumer: ((AudioSourceSelection, TranscriptionPCM) -> Void)?) {
        ioQueue.sync { audioConsumer = consumer }
    }

    init(defaults: UserDefaults = .standard,
         captureFactory: ((AudioSourceSelection) throws -> NativeAudioCapturing)? = nil,
         microphonePermission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.defaults = defaults
        self.captureFactory = captureFactory
        self.microphonePermission = microphonePermission
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(AudioRecordingSettings.self, from: data) {
            settings = saved
        } else { settings = AudioRecordingSettings() }
        if !defaults.bool(forKey: Self.folderMigrationKey) {
            let legacyPath = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Astation Recordings", isDirectory: true).path
            if settings.folderPath == legacyPath {
                settings.folderPath = AudioRecordingSettings().folderPath
                if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
            }
            // Migrate once; a later explicit choice of the old path must remain a user choice.
            defaults.set(true, forKey: Self.folderMigrationKey)
        }
        super.init()
        refreshSources()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isCapturing || self.state == .starting else { return }
            self.failAndStop("Capture stopped because the Mac is going to sleep. Start a new recording after waking.")
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            let engine = notification.object
            // AVAudioEngine must not be stopped/deallocated inside its notification callback.
            DispatchQueue.main.async { [weak self] in self?.microphoneConfigurationChanged(engine) }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        catalogTimer?.invalidate()
        ioTimer?.cancel()
        for track in tracks.values { track.capture.stop() }
    }

    var selectedSources: [AudioSourceSelection] {
        var sources: [AudioSourceSelection] = []
        if settings.microphoneEnabled {
            let name = microphones.first { $0.uid == settings.microphoneUID }?.name ?? "System Default Microphone"
            sources.append(AudioSourceSelection(id: "microphone", title: name, kind: .microphone(settings.microphoneUID)))
        }
        switch settings.outputMode {
        case .none: break
        case .system: sources.append(AudioSourceSelection(id: "system", title: "All System Audio", kind: .system))
        case .applications:
            for identity in settings.applicationBundleIDs {
                sources.append(AudioSourceSelection(id: identity,
                    title: applications.first { $0.bundleID == identity }?.name ?? identity,
                    kind: .application(identity)))
            }
        }
        return sources
    }

    func meter(for id: String) -> AudioMeterSnapshot { tracks[id]?.snapshot ?? AudioMeterSnapshot() }

    func updateSettings(_ settings: AudioRecordingSettings) {
        guard !controlsLocked else { return }
        if isCapturing { stopPreview() }
        self.settings = settings
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
        errorMessage = nil
        state = .idle
        notify()
    }

    func refreshSources() {
        microphones = AudioSourceCatalog.microphones()
        if #available(macOS 14.2, *) { applications = AudioSourceCatalog.applications() }
    }

    func startPreview() { startCapture(record: false) }

    func startRecording() {
        guard !isReconnectingMicrophone else { return }
        if state == .previewing {
            do { try beginSession(); state = .recording; notify() }
            catch { failAndStop(error.localizedDescription) }
        } else { startCapture(record: true) }
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else if state != .starting { startRecording() }
    }

    func togglePause() {
        guard isRecording else { return }
        do {
            try ioQueue.sync {
                try drain()
                if state == .recording { try session?.pause(at: Self.hostSeconds) }
                else { try session?.resume(at: Self.hostSeconds) }
            }
            state = state == .recording ? .paused : .recording
            notify()
        } catch { failAndStop(error.localizedDescription) }
    }

    func stopPreview() {
        guard !isRecording else { return }
        operation = UUID()
        stopCapture()
        sourceMessages.removeAll()
        state = .idle
        notify()
    }

    func stopRecording(keepTranscription: Bool = true) {
        guard isRecording else { return }
        let keepCapturing = keepTranscription && retainCaptureForTranscription?() == true
        // Closing original files must not tear down capture that live captions still need.
        if !keepCapturing { stopCapture() }
        do {
            try ioQueue.sync {
                try drain()
                let finished = session
                session = nil
                try finished?.finish(at: Self.hostSeconds)
            }
            state = keepCapturing ? .previewing : .idle
        } catch {
            if keepCapturing { stopCapture() }
            ioQueue.sync {
                let failed = session
                session = nil
                try? failed?.finish(at: Self.hostSeconds, error: error.localizedDescription)
            }
            state = .failed
            errorMessage = error.localizedDescription
        }
        if !keepCapturing || state == .failed {
            tracks.removeAll()
            ioQueue.sync { workerTracks.removeAll() }
        }
        notify()
    }

    func shutdown() {
        if isRecording { stopRecording(keepTranscription: false) } else { stopPreview() }
    }

    private func startCapture(record: Bool) {
        guard !isCapturing, state != .starting else { return }
        if let error = settings.validationError { failAndStop(error); return }
        if settings.outputMode != .none {
            guard #available(macOS 14.2, *) else { failAndStop("System and application audio require macOS 14.2 or later."); return }
        }
        state = .starting
        errorMessage = nil
        let token = UUID()
        operation = token
        notify()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.settings.microphoneEnabled {
                let granted = await self.microphonePermission()
                guard self.operation == token else { return }
                if !granted { self.failAndStop("Microphone permission is required. Enable Astation in System Settings > Privacy & Security > Microphone."); return }
            }
            guard self.operation == token else { return }
            do {
                self.refreshSources()
                self.startWorker()
                // Creating a process-tap aggregate can reconfigure I/O. Bring microphones up last.
                let sources = self.selectedSources
                let captureOrder = sources.filter { if case .microphone = $0.kind { return false }; return true }
                    + sources.filter { if case .microphone = $0.kind { return true }; return false }
                for source in captureOrder {
                    let capture = try await self.prepareCapture(source)
                    guard self.operation == token else { capture?.stop(); return }
                    if let capture { try self.register(source, capture: capture) }
                    else { self.sourceMessages[source.id] = "Waiting for application audio" }
                }
                if record { try self.beginSession() }
                self.state = record ? .recording : .previewing
                self.startCatalogTimer()
                self.notify()
            } catch {
                guard self.operation == token else { return }
                self.failAndStop(error.localizedDescription)
            }
        }
    }

    private func attachWhenAvailable(_ source: AudioSourceSelection) {
        guard pendingSources.insert(source.id).inserted else { return }
        let token = operation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.prepareCapture(source)
                guard self.operation == token else { capture?.stop(); return }
                self.pendingSources.remove(source.id)
                if let capture { try self.register(source, capture: capture) }
                else { self.sourceMessages[source.id] = "Waiting for application audio" }
                self.notify()
            } catch {
                guard self.operation == token else { return }
                self.pendingSources.remove(source.id)
                self.failAndStop(error.localizedDescription)
            }
        }
    }

    private func microphoneConfigurationChanged(_ engine: Any?) {
        guard isCapturing || state == .starting else { return }
        for track in tracks.values {
            guard case .microphone = track.source.kind,
                  let capture = track.capture as? MicrophoneConfigurationHandling,
                  capture.ownsEngine(engine), recoveringMicrophones.insert(track.source.id).inserted else { continue }
            let id = track.source.id
            let now = Self.hostSeconds
            var attempts = (microphoneRecoveryTimes[id] ?? []).filter { now - $0 < 5 }
            guard attempts.count < 3 else {
                failAndStop("The microphone's audio engine keeps reconfiguring. Capture stopped; check the selected device and restart preview.")
                return
            }
            attempts.append(now)
            microphoneRecoveryTimes[id] = attempts
            let token = operation
            sourceMessages[id] = "Reconnecting microphone..."
            notify()
            setupQueue.async { [weak self] in
                let result = Result { try capture.recoverAfterConfigurationChange() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operation == token else { return }
                    switch result {
                    case .success:
                        self.recoveringMicrophones.remove(id)
                        self.sourceMessages[id] = nil
                        self.notify()
                    case .failure(let error):
                        if self.state == .previewing, let changed = error as? AudioCaptureError,
                           case .microphoneFormatChanged = changed {
                            self.reconnectPreviewMicrophone(track, token: token)
                            return
                        }
                        let detail = self.isRecording
                            ? "The recording was stopped to preserve its original format; saved audio is retained."
                            : "Preview stopped. Restart preview to reconnect the selected microphone."
                        self.failAndStop("\(error.localizedDescription) \(detail)")
                    }
                }
            }
        }
    }

    private func reconnectPreviewMicrophone(_ oldTrack: CapturedAudioTrack, token: UUID, failedCapture: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replacement = try await self.prepareCapture(oldTrack.source, replacing: oldTrack.capture)
                guard self.operation == token, self.tracks[oldTrack.source.id] === oldTrack,
                      self.state == .previewing else { replacement?.stop(); return }
                guard let replacement else { throw AudioCaptureError.message("The selected microphone could not be reconnected.") }
                // Retire the old queue before publishing a new format to meters and captions.
                try self.ioQueue.sync {
                    try oldTrack.drain(session: nil, consumer: self.audioConsumer, checkStatus: !failedCapture)
                    self.workerTracks.removeAll { $0 === oldTrack }
                }
                try self.register(oldTrack.source, capture: replacement)
                self.recoveringMicrophones.remove(oldTrack.source.id)
                self.notify()
            } catch {
                guard self.operation == token else { return }
                self.failAndStop("The microphone could not be reconnected. \(error.localizedDescription) Restart preview after checking the selected device.")
            }
        }
    }

    private func prepareCapture(_ source: AudioSourceSelection, replacing oldCapture: NativeAudioCapturing? = nil) async throws -> NativeAudioCapturing? {
        let processes: [UInt32]
        switch source.kind {
        case .application(let identity):
            processes = applications.first { $0.bundleID == identity }?.processIDs ?? []
            if processes.isEmpty && captureFactory == nil { return nil }
        case .system:
            if #available(macOS 14.2, *) { processes = AudioSourceCatalog.ownProcessIDs() }
            else { processes = [] }
        case .microphone: processes = []
        }
        let factory = captureFactory
        // Core Audio can wait on the OS permission dialog. Keep that wait off the UI thread.
        return try await withCheckedThrowingContinuation { continuation in
            setupQueue.async {
                do {
                    oldCapture?.stop()
                    let capture: NativeAudioCapturing
                    if let factory { capture = try factory(source) }
                    else {
                        switch source.kind {
                        case .microphone(let uid): capture = try SharedMicrophoneCapture.shared.makeCapture(deviceUID: uid)
                        case .application, .system:
                            guard #available(macOS 14.2, *) else { throw AudioCaptureError.message("App audio requires macOS 14.2 or later.") }
                            capture = try ProcessAudioCapture(processes: processes, system: source.kind == .system)
                        }
                    }
                    continuation.resume(returning: capture)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func register(_ source: AudioSourceSelection, capture: NativeAudioCapturing) throws {
        let track = CapturedAudioTrack(source: source, capture: capture)
        tracks[source.id] = track
        sourceMessages[source.id] = nil
        try ioQueue.sync {
            workerTracks.append(track)
            track.recordingDroppedBaseline = astation_audio_queue_dropped_frames(capture.queue)
            try session?.addSource(source, format: capture.format)
        }
    }

    private func startCatalogTimer() {
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(refreshActiveSources), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        catalogTimer = timer
    }

    @objc private func refreshActiveSources() {
        guard isCapturing else { return }
        refreshSources()
        do {
            for source in selectedSources {
                switch source.kind {
                case .microphone(let uid):
                    if let uid, !microphones.contains(where: { $0.uid == uid }) {
                        throw AudioCaptureError.message("The selected microphone was disconnected. Its recording has been retained.")
                    }
                case .application(let identity):
                    guard #available(macOS 14.2, *) else { continue }
                    let app = applications.first { $0.bundleID == identity }
                    if let capture = tracks[source.id]?.capture as? ProcessAudioCapture {
                        try capture.updateProcesses(app?.processIDs ?? [])
                        try capture.validateFormat()
                        sourceMessages[source.id] = app == nil ? "Application closed - waiting for restart" : nil
                    } else { attachWhenAvailable(source) }
                case .system:
                    if #available(macOS 14.2, *), let capture = tracks[source.id]?.capture as? ProcessAudioCapture {
                        try capture.updateProcesses(AudioSourceCatalog.ownProcessIDs())
                        try capture.validateFormat()
                    }
                }
            }
        } catch { failAndStop(error.localizedDescription) }
        notify()
    }

    private func beginSession() throws {
        try ioQueue.sync {
            try drain()
            let newSession = try AudioRecordingSession(settings: settings, startTime: Self.hostSeconds)
            session = newSession
            elapsedLock.lock()
            lastElapsed = 0
            elapsedLock.unlock()
            for track in workerTracks {
                track.recordingDroppedBaseline = astation_audio_queue_dropped_frames(track.capture.queue)
                try newSession.addSource(track.source, format: track.capture.format)
            }
            lastSessionFolder = newSession.folder
        }
    }

    private func startWorker() {
        let token = operation
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.drain()
                self.checkpointTicks += 1
                if self.checkpointTicks >= 150 {
                    self.checkpointTicks = 0
                    try self.session?.checkpoint(at: Self.hostSeconds)
                }
            } catch {
                let message = error.localizedDescription
                let failed = self.session
                self.session = nil
                try? failed?.finish(at: Self.hostSeconds, error: message)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operation == token else { return }
                    self.failAndStop(message)
                }
            }
        }
        ioTimer = timer
        timer.resume()
    }

    private func drain() throws {
        for track in workerTracks {
            do { try track.drain(session: session, consumer: audioConsumer) }
            catch {
                guard session == nil, case .microphone = track.source.kind,
                      let changed = error as? AudioCaptureError, case .microphoneFormatChanged = changed else { throw error }
                // Shared capture owns recovery. Replace its failed mic lease during
                // preview without stopping healthy system/app sources or their ASR.
                workerTracks.removeAll { $0 === track }
                let token = operation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operation == token, self.tracks[track.source.id] === track else { return }
                    guard self.state == .previewing else { self.failAndStop(changed.localizedDescription); return }
                    let now = Self.hostSeconds, id = track.source.id
                    var attempts = (self.microphoneRecoveryTimes[id] ?? []).filter { now - $0 < 5 }
                    guard attempts.count < 3 else {
                        self.failAndStop("The microphone keeps changing format. Restart preview after checking the selected device."); return
                    }
                    attempts.append(now); self.microphoneRecoveryTimes[id] = attempts
                    self.recoveringMicrophones.insert(id); self.sourceMessages[id] = "Reconnecting microphone..."; self.notify()
                    self.reconnectPreviewMicrophone(track, token: token, failedCapture: true)
                }
            }
        }
        if let session {
            elapsedLock.lock()
            lastElapsed = session.elapsed(at: Self.hostSeconds)
            elapsedLock.unlock()
        }
    }

    private func stopCapture() {
        operation = UUID()
        onCaptureStopped?()
        pendingSources.removeAll()
        recoveringMicrophones.removeAll()
        microphoneRecoveryTimes.removeAll()
        catalogTimer?.invalidate()
        catalogTimer = nil
        ioTimer?.cancel()
        ioTimer = nil
        for track in tracks.values { track.capture.stop() }
        // Wait for in-flight callbacks/worker work before releasing their queues.
        ioQueue.sync {}
        if !isRecording {
            tracks.removeAll()
            ioQueue.sync { workerTracks.removeAll() }
        }
    }

    private func failAndStop(_ message: String) {
        stopCapture()
        ioQueue.sync {
            let failed = session
            session = nil
            try? failed?.finish(at: Self.hostSeconds, error: message)
            workerTracks.removeAll()
        }
        tracks.removeAll()
        sourceMessages.removeAll()
        errorMessage = message
        state = .failed
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .audioRecordingChanged, object: self)
        onStateChanged?()
    }
}
