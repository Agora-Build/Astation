import AVFoundation
import CStationCore
import XCTest
@testable import Menubar

private final class CaptionTestCapture: MicrophoneConfigurationHandling {
    let format: AVAudioFormat
    let queue: OpaquePointer
    let configurationObject = NSObject()
    var onRecovery: (() throws -> Void)?
    init(channels: AVAudioChannelCount = 1) {
        format = NativeAudioFormat.floatPCM(sampleRate: 48_000, channels: channels)!
        queue = astation_audio_queue_create(channels, 4_096, 64)!
    }
    private(set) var stopped = false
    func stop() { stopped = true }
    func ownsEngine(_ object: Any?) -> Bool { (object as? NSObject) === configurationObject }
    func recoverAfterConfigurationChange() throws { try onRecovery?() }
    deinit { astation_audio_queue_destroy(queue) }
    func feed(_ value: Float) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for lane in 0..<Int(format.channelCount) { buffer.floatChannelData![lane].initialize(repeating: value, count: 4_800) }
        astation_audio_queue_push(queue, buffer.audioBufferList, 4_800, mach_absolute_time(), 48_000)
    }
}
private final class CaptionTestSecrets: TranscriptionSecretStoring {
    var values: [String: String] = [:]
    var reads: [String] = []
    func read(endpoint: String) -> String? { reads.append(endpoint); return values[endpoint] }
    func write(_ value: String?, endpoint: String) { values[endpoint] = value }
}
private actor CaptionTestEngine: LiveTranscribing {
    let sourceID: String
    var callback: (@Sendable (TranscriptSegment) -> Void)?
    var started = false
    var cancelled = false
    var consumed: [Float] = []
    var throwOnConsume = false
    var throwOnStart = false
    var delayStart = false
    var finishCount = 0
    var cancellationStarted = false
    private var holdCancellation = false
    private var cancellation: CheckedContinuation<Void, Never>?
    init(sourceID: String = "microphone") { self.sourceID = sourceID }
    func configureFailure() { throwOnConsume = true }
    func configureStartFailure() { throwOnStart = true }
    func configureDelay() { delayStart = true }
    func configureCancellationGate() { holdCancellation = true }
    func releaseCancellation() {
        holdCancellation = false
        cancellation?.resume(); cancellation = nil
    }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        started = true; callback = onSegment
        if throwOnStart { throw TranscriptionError.message("Source could not start") }
        if delayStart { try await Task.sleep(nanoseconds: 10_000_000_000) }
    }
    func consume(_ samples: [Float]) throws {
        if throwOnConsume { throw TranscriptionError.message("Inference failed; original is safe") }
        consumed.append(contentsOf: samples)
        callback?(TranscriptSegment(id: "one", sourceID: sourceID, language: "en-US", text: "hello\nworld", isFinal: false, offset: 0))
    }
    func finish() {
        finishCount += 1
        callback?(TranscriptSegment(id: "one", sourceID: sourceID, language: "en-US", text: "hello\nworld", isFinal: true, offset: 0))
    }
    func cancel() async {
        cancellationStarted = true
        if holdCancellation { await withCheckedContinuation { cancellation = $0 } }
        cancelled = true
    }
    func emit(_ text: String, id: String = "one", final: Bool = false) {
        callback?(TranscriptSegment(id: id, sourceID: sourceID, language: "en-US", text: text, isFinal: final, offset: 0))
    }
}

@MainActor
final class AudioTranscriptionManagerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "astation-caption-manager-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astation-caption-recording-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Transcription state did not settle")
    }
    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Transcription engine did not settle")
    }
    func testCustomConsentAndValidationPrecedeKeyReadAndCapture() async throws {
        let secrets = CaptionTestSecrets(), capture = CaptionTestCapture()
        var starts = 0
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { _ in starts += 1; return capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), secretStore: secrets)
        var settings = manager.settings; settings.provider = .custom
        settings.customEndpoint = "https://speech.example.test/v1/audio/transcriptions"
        manager.updateSettings(settings)
        manager.start(); XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(starts, 0); XCTAssertTrue(secrets.reads.isEmpty)
        settings.customEndpoint = "http://insecure.example.test/transcribe"; manager.updateSettings(settings)
        manager.start(cloudConsent: true); XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(starts, 0); XCTAssertTrue(secrets.reads.isEmpty)
        settings.customEndpoint = "https://speech.example.test/v1/audio/transcriptions"; manager.updateSettings(settings)
        manager.start(cloudConsent: true); try await waitUntil { manager.state == .running }
        XCTAssertEqual(secrets.reads, [settings.customEndpoint]); XCTAssertEqual(starts, 1)
        // No samples fed: starting a custom session alone must not make an HTTP request.
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(capture.stopped)
    }
    func testCustomKeysStayOutOfDefaultsAndAreIsolatedByEndpoint() throws {
        let secrets = CaptionTestSecrets(), storage = defaults()
        let recorder = AudioRecordingManager(defaults: storage)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, secretStore: secrets)
        var settings = manager.settings; settings.provider = .custom
        settings.customEndpoint = "https://one.example.test/v1/audio/transcriptions"; manager.updateSettings(settings)
        manager.saveCustomKey("test-only-secret")
        XCTAssertEqual(secrets.values[settings.customEndpoint], "test-only-secret")
        let encoded = try XCTUnwrap(storage.data(forKey: AudioTranscriptionManager.defaultsKey))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("test-only-secret"))
        settings.customEndpoint = "https://two.example.test/v1/audio/transcriptions"; manager.updateSettings(settings)
        XCTAssertNil(secrets.values[settings.customEndpoint])
        manager.saveCustomKey("second-test-only-secret"); manager.saveCustomKey(nil)
        XCTAssertNil(secrets.values[settings.customEndpoint]); XCTAssertEqual(secrets.values.count, 1)
    }
    func testAutoSaveIncludesFinalOnStopAndManualTXTJSONExports() async throws {
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        var settings = manager.settings; settings.autoSaveTranscript = true; settings.transcriptFolderPath = try folder().path
        manager.updateSettings(settings); manager.start(); try await waitUntil { manager.state == .running }
        capture.feed(0.2); try await waitUntil { !manager.transcript.segments.isEmpty }
        manager.stop(); try await waitUntil { manager.state == .idle }
        let saved = try XCTUnwrap(manager.lastTranscriptFolder)
        let text = try String(contentsOf: saved.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("microphone en-US final] hello\nworld"))
        try await waitUntil { manager.transcript.segments.contains { $0.isFinal } }
        let txt = saved.appendingPathComponent("manual.txt"), json = saved.appendingPathComponent("manual.json")
        try manager.export(to: txt); try manager.export(to: json)
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), manager.transcript.text)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["segments"] as? [[String: Any]])?.first?["isFinal"] as? Bool, true)
        XCTAssertNil(recorder.lastSessionFolder)
    }
    func testAutoSaveFailureDoesNotStopCaptionsOrOriginalRecording() async throws {
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        var recording = recorder.settings; recording.folderPath = try folder().path; recorder.updateSettings(recording)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        var settings = manager.settings; settings.autoSaveTranscript = true
        let blocked = try folder().appendingPathComponent("file-not-directory"); try Data().write(to: blocked)
        settings.transcriptFolderPath = blocked.path; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .running }
        XCTAssertTrue(manager.autoSaveMessage?.contains("could not start") == true)
        capture.feed(0.3); try await waitUntil { !manager.transcript.segments.isEmpty }
        XCTAssertTrue(recorder.isRecording)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(recorder.isRecording); recorder.stopRecording()
    }
    func testMicrophoneReplacementKeepsTranscriptionRunningWithNewThreeChannelFormat() async throws {
        let old = CaptionTestCapture(), replacement = CaptionTestCapture(channels: 3), engine = CaptionTestEngine()
        old.onRecovery = { throw AudioCaptureError.microphoneFormatChanged(previous: "mono", current: "3 channels") }
        var starts = 0
        let storage = defaults()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in starts += 1; return starts == 1 ? old : replacement }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        old.feed(0.2); try await waitUntil { !manager.transcript.segments.isEmpty }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: old.configurationObject)
        try await waitUntil { starts == 2 && !recorder.isReconnectingMicrophone }
        XCTAssertEqual(manager.state, .running); XCTAssertTrue(old.stopped)
        replacement.feed(0.5)
        try await waitUntilAsync { await engine.consumed.contains { abs($0 - 0.5) < 0.02 } }
        XCTAssertEqual(manager.state, .running)
        manager.stop(); try await waitUntil { manager.state == .idle }
    }
    func testMicrophoneAndSystemUseSeparateEnginesAndKeepCaptionsDistinct() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        var created: [TranscriptionSettings] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { settings in
            created.append(settings)
            return settings.sourceID == "microphone" ? micEngine : systemEngine
        })
        var settings = manager.settings; settings.additionalSourceIDs = ["system", "microphone", "system"]
        manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .running }
        XCTAssertEqual(created.map(\.sourceID), ["microphone", "system"])
        XCTAssertTrue(created.allSatisfy { $0.additionalSourceIDs.isEmpty })
        mic.feed(0.25); system.feed(0.75)
        try await waitUntil { manager.transcript.segments.count == 2 }
        let micSamples = await micEngine.consumed, systemSamples = await systemEngine.consumed
        XCTAssertFalse(micSamples.isEmpty); XCTAssertFalse(systemSamples.isEmpty)
        XCTAssertTrue(micSamples.suffix(500).allSatisfy { abs($0 - 0.25) < 0.02 })
        XCTAssertTrue(systemSamples.suffix(500).allSatisfy { abs($0 - 0.75) < 0.02 })
        XCTAssertEqual(Set(manager.transcript.segments.map(\.sourceID)), ["microphone", "system"])
        XCTAssertEqual(manager.floatingCaptionBuffer.lines.count, 2)
        let text = TranscriptionToastController.captionText(manager.transcript.segments, sourceTitles: manager.sourceTitles).string
        XCTAssertTrue(text.contains("Microphone  hello\nworld"))
        XCTAssertTrue(text.contains("All System Audio  hello\nworld"))
        XCTAssertTrue(manager.transcript.text.contains("microphone en-US"))
        XCTAssertTrue(manager.transcript.text.contains("system en-US"))
        manager.stop(); try await waitUntil { manager.state == .idle }
        try await waitUntil { manager.transcript.segments.allSatisfy(\.isFinal) }
        let micCancelled = await micEngine.cancelled, systemCancelled = await systemEngine.cancelled
        XCTAssertTrue(micCancelled); XCTAssertTrue(systemCancelled)
        let micFinishes = await micEngine.finishCount, systemFinishes = await systemEngine.finishCount
        XCTAssertEqual(micFinishes, 1); XCTAssertEqual(systemFinishes, 1)
        XCTAssertTrue(mic.stopped); XCTAssertTrue(system.stopped)
        XCTAssertNil(recorder.lastSessionFolder)
    }
    func testMicrophoneAndSelectedAppsRouteOnlyCheckedSourcesWhileRecording() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), app = CaptionTestCapture(), other = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), appEngine = CaptionTestEngine(sourceID: "test.selected-app")
        let captures = ["microphone": mic, "test.selected-app": app, "test.other-app": other]
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { try XCTUnwrap(captures[$0.id]) }, microphonePermission: { true })
        defer { recorder.shutdown() }
        var recording = recorder.settings
        recording.outputMode = .applications; recording.applicationBundleIDs = ["test.selected-app", "test.other-app"]
        recording.folderPath = try folder().path; recorder.updateSettings(recording)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        var createdIDs: [String] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { settings in
            createdIDs.append(settings.sourceID)
            return settings.sourceID == "microphone" ? micEngine : appEngine
        })
        var settings = manager.settings; settings.additionalSourceIDs = ["test.selected-app"]; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .running }
        mic.feed(0.25); app.feed(0.5); other.feed(0.9)
        try await waitUntil { manager.transcript.segments.count == 2 }
        XCTAssertEqual(createdIDs, ["microphone", "test.selected-app"])
        let micSamples = await micEngine.consumed, appSamples = await appEngine.consumed
        XCTAssertTrue(micSamples.suffix(500).allSatisfy { abs($0 - 0.25) < 0.02 })
        XCTAssertTrue(appSamples.suffix(500).allSatisfy { abs($0 - 0.5) < 0.02 })
        XCTAssertFalse(manager.transcript.segments.contains { $0.sourceID == "test.other-app" })
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(captures.values.allSatisfy { !$0.stopped })
        // Finish after the 100 ms fake packets to exercise trailing silence metadata.
        let paddingDeadline = recorder.elapsed + 0.2
        try await waitUntil { recorder.elapsed >= paddingDeadline }
        recorder.stopRecording()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = try XCTUnwrap(recorder.lastSessionFolder)
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: session.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "completed")
        XCTAssertEqual(Set(manifest.tracks.map(\.sourceID)), Set(captures.keys))
        let levels: [String: Float] = ["microphone": 0.25, "test.selected-app": 0.5, "test.other-app": 0.9]
        for track in manifest.tracks {
            XCTAssertTrue(track.gaps.contains { $0.reason == "source silent or unavailable at session end" && $0.frameCount > 0 })
            let file = try AVAudioFile(forReading: session.appendingPathComponent(track.segments[0].file))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            XCTAssertEqual(track.sampleRate, 48_000)
            XCTAssertGreaterThan(buffer.frameLength, 0)
            // Slow runners can finish after the fake packet's end, adding declared silence.
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let gaps = track.gaps.map { $0.startFrame..<($0.startFrame + $0.frameCount) }
            let original = samples.enumerated().filter { sample in
                !gaps.contains { $0.contains(Int64(sample.offset)) }
            }
            let level = try XCTUnwrap(levels[track.sourceID])
            XCTAssertEqual(original.count, 4_800)
            XCTAssertTrue(original.allSatisfy { $0.element == level })
            XCTAssertTrue(samples.enumerated().allSatisfy { sample in
                !gaps.contains { $0.contains(Int64(sample.offset)) } || sample.element == 0
            })
        }
    }
    func testSystemAndAppOnlyTranscriptionNeedNoMicrophonePermission() async throws {
        for (mode, id) in [(RecordingOutputMode.system, "system"), (.applications, "test.selected-app")] {
            let defaults = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine(sourceID: id)
            var micPermissions = 0
            let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { micPermissions += 1; return false })
            var recording = recorder.settings
            recording.microphoneEnabled = false; recording.outputMode = mode; recording.applicationBundleIDs = [id]
            recorder.updateSettings(recording)
            let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { settings in
                XCTAssertEqual(settings.sourceID, id); return engine
            })
            var settings = manager.settings; settings.sourceID = id; manager.updateSettings(settings)
            manager.start(); try await waitUntil { manager.state == .running }
            capture.feed(0.5); try await waitUntil { manager.transcript.segments.count == 1 }
            XCTAssertEqual(micPermissions, 0)
            XCTAssertEqual(manager.transcript.segments.first?.sourceID, id)
            manager.stop(); try await waitUntil { manager.state == .idle }
            XCTAssertTrue(capture.stopped)
        }
    }
    func testOneSourceFailureCancelsAllEnginesWithoutStoppingOriginals() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        await systemEngine.configureFailure()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        defer { recorder.shutdown() }
        var recording = recorder.settings; recording.outputMode = .system; recording.folderPath = try folder().path
        recorder.updateSettings(recording); recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { $0.sourceID == "microphone" ? micEngine : systemEngine })
        var settings = manager.settings; settings.additionalSourceIDs = ["system"]; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .running }
        system.feed(0.75)
        try await waitUntil { manager.state == .failed }
        try await waitUntilAsync {
            let micCancelled = await micEngine.cancelled, systemCancelled = await systemEngine.cancelled
            return micCancelled && systemCancelled
        }
        XCTAssertTrue(manager.message?.contains("Inference failed") == true)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(mic.stopped); XCTAssertFalse(system.stopped)
        mic.feed(0.25); try await waitUntil { recorder.meter(for: "microphone").peakDB > -13 }
        XCTAssertEqual(manager.state, .failed)
    }
    func testPartialEngineStartupFailureCleansUpEverySourceAndOwnedCapture() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        await systemEngine.configureStartFailure()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { $0.sourceID == "microphone" ? micEngine : systemEngine })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        var settings = manager.settings; settings.additionalSourceIDs = ["system"]; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .failed }
        let micStarted = await micEngine.started, systemStarted = await systemEngine.started
        let micCancelled = await micEngine.cancelled, systemCancelled = await systemEngine.cancelled
        XCTAssertTrue(micStarted); XCTAssertTrue(systemStarted)
        XCTAssertTrue(micCancelled); XCTAssertTrue(systemCancelled)
        XCTAssertTrue(mic.stopped); XCTAssertTrue(system.stopped)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(manager.message, "Source could not start")
    }
    func testStopDuringSecondEnginePreparationCancelsEverySource() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        await systemEngine.configureDelay()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { $0.sourceID == "microphone" ? micEngine : systemEngine })
        var settings = manager.settings; settings.additionalSourceIDs = ["system"]; manager.updateSettings(settings)
        manager.start(); try await waitUntilAsync { await systemEngine.started }
        XCTAssertEqual(manager.state, .preparing)
        manager.stop(); try await waitUntil { manager.state == .idle }
        let micCancelled = await micEngine.cancelled, systemCancelled = await systemEngine.cancelled
        XCTAssertTrue(micCancelled); XCTAssertTrue(systemCancelled)
        XCTAssertTrue(mic.stopped); XCTAssertTrue(system.stopped)
        XCTAssertEqual(recorder.state, .idle)
    }
    func testMissingSelectedSourceIsRejectedBeforeCreatingAnyEngine() {
        let defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults)
        var factories = 0
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in
            factories += 1; return CaptionTestEngine()
        })
        for ids in [[], ["system"], ["microphone", "not-enabled"]] as [[String]] {
            var settings = manager.settings; settings.sourceID = ids.first ?? ""; settings.additionalSourceIDs = Array(ids.dropFirst())
            manager.updateSettings(settings); manager.start()
            XCTAssertEqual(manager.state, .failed)
            XCTAssertTrue(manager.message?.contains("Enable sources") == true)
            XCTAssertEqual(factories, 0)
            XCTAssertEqual(recorder.state, .idle)
        }
    }
    func testCloudFactoryGetsIndependentSourceSettingsOnlyAfterConsent() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults)
        var configured: [TranscriptionSettings] = []
        manager.cloudEngineFactory = { settings in
            configured.append(settings)
            return settings.sourceID == "microphone" ? micEngine : systemEngine
        }
        var settings = manager.settings; settings.provider = .agora; settings.additionalSourceIDs = ["system"]
        settings.language = "fr-FR"; settings.translationLanguage = "en-US"; manager.updateSettings(settings)
        manager.start()
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(configured.isEmpty)
        XCTAssertEqual(recorder.state, .idle)
        manager.start(cloudConsent: true); try await waitUntil { manager.state == .running }
        XCTAssertEqual(configured.map(\.sourceID), ["microphone", "system"])
        XCTAssertTrue(configured.allSatisfy { $0.additionalSourceIDs.isEmpty && $0.provider == .agora
            && $0.language == "fr-FR" && $0.translationLanguage == "en-US" })
        mic.feed(0.25); system.feed(0.75)
        try await waitUntil { manager.transcript.segments.count == 2 }
        manager.stop(); try await waitUntil { manager.state == .idle }
        let micCancelled = await micEngine.cancelled, systemCancelled = await systemEngine.cancelled
        XCTAssertTrue(micCancelled); XCTAssertTrue(systemCancelled)
    }
    func testFactoryFailureCleansUpPreviouslyCreatedEngineBeforeCapture() async throws {
        let defaults = defaults(), engine = CaptionTestEngine()
        var captureRequests = 0
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in
            captureRequests += 1; return CaptionTestCapture()
        }, microphonePermission: { captureRequests += 1; return true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { settings in
            if settings.sourceID == "system" { throw TranscriptionError.message("Engine configuration failed") }
            return engine
        })
        var settings = manager.settings; settings.additionalSourceIDs = ["system"]; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .failed }
        let cancelled = await engine.cancelled, started = await engine.started
        XCTAssertTrue(cancelled); XCTAssertFalse(started)
        XCTAssertEqual(captureRequests, 0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(manager.message, "Engine configuration failed")
    }
    func testStoppingRecordingRetainsBothLiveCaptionSources() async throws {
        let defaults = defaults(), mic = CaptionTestCapture(), system = CaptionTestCapture()
        let micEngine = CaptionTestEngine(), systemEngine = CaptionTestEngine(sourceID: "system")
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recording.folderPath = try folder().path
        recorder.updateSettings(recording); recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { $0.sourceID == "microphone" ? micEngine : systemEngine })
        var settings = manager.settings; settings.additionalSourceIDs = ["system"]; manager.updateSettings(settings)
        manager.start(); try await waitUntil { manager.state == .running }
        mic.feed(0.25); system.feed(0.75); try await waitUntil { manager.transcript.segments.count == 2 }
        recorder.stopRecording()
        XCTAssertEqual(recorder.state, .previewing)
        XCTAssertEqual(manager.state, .running)
        XCTAssertFalse(mic.stopped); XCTAssertFalse(system.stopped)
        let micCount = await micEngine.consumed.count, systemCount = await systemEngine.consumed.count
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = try XCTUnwrap(recorder.lastSessionFolder)
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: session.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "completed")
        let files = manifest.tracks.map { session.appendingPathComponent($0.segments[0].file) }
        let completedFrames = try files.map { try AVAudioFile(forReading: $0).length }
        mic.feed(0.5); system.feed(0.9)
        try await waitUntilAsync {
            let micAfter = await micEngine.consumed.count, systemAfter = await systemEngine.consumed.count
            return micAfter > micCount && systemAfter > systemCount
        }
        XCTAssertEqual(try files.map { try AVAudioFile(forReading: $0).length }, completedFrames)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(mic.stopped); XCTAssertTrue(system.stopped)
    }
    func testCaptionsOwnPreviewButNeverCreateRecordingFilesAndFinalToastSurvivesStop() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        var config = recorder.settings; config.folderPath = try folder().path; recorder.updateSettings(config)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start()
        try await waitUntil { manager.state == .running }
        XCTAssertEqual(recorder.state, .previewing)
        capture.feed(0.25)
        try await waitUntil { !manager.transcript.segments.isEmpty }
        manager.stop()
        try await waitUntil { manager.state == .idle }
        try await waitUntil { manager.transcript.segments.first?.isFinal == true }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(manager.floatingCaptionBuffer.lines.first?.segment.text, "hello\nworld")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: config.folderPath).isEmpty)
        XCTAssertNil(recorder.lastSessionFolder)
        let cancelled = await engine.cancelled; XCTAssertTrue(cancelled)
    }
    func testStoppingTranscriptionDoesNotStopExistingPreview() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        defer { recorder.shutdown() }
        recorder.startPreview()
        try await waitUntil { recorder.state == .previewing }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .previewing)
        XCTAssertFalse(capture.stopped)
    }
    func testInferenceFailureKeepsOriginalRecordingAndFailureMessage() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        await engine.configureFailure()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording()
        try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        capture.feed(0.25)
        try await waitUntil { manager.state == .failed }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.message?.contains("Inference failed") == true)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(capture.stopped)
        recorder.stopRecording()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folder = try XCTUnwrap(recorder.lastSessionFolder)
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        let track = try XCTUnwrap(manifest.tracks.first)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(manifest.status, "completed")
        XCTAssertTrue(track.gaps.contains { $0.reason == "source silent or unavailable at session end" && $0.frameCount > 0 })
        let file = try AVAudioFile(forReading: folder.appendingPathComponent(track.segments[0].file))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        // Slow runners can legitimately pad the session after the fake source's
        // 100 ms packet. Check every original sample, excluding documented gaps.
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let gaps = track.gaps.map { $0.startFrame..<($0.startFrame + $0.frameCount) }
        let original = samples.enumerated().filter { sample in
            !gaps.contains { $0.contains(Int64(sample.offset)) }
        }
        XCTAssertEqual(original.count, 4_800)
        XCTAssertTrue(original.allSatisfy { $0.element == 0.25 })
        XCTAssertTrue(samples.enumerated().allSatisfy { sample in
            !gaps.contains { $0.contains(Int64(sample.offset)) } || sample.element == 0
        })
    }
    func testInferenceFailureSurvivesAudioArrivingDuringEngineCancellation() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), storage = defaults()
        await engine.configureFailure(); await engine.configureCancellationGate()
        addTeardownBlock { await engine.releaseCancellation() }
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        defer { recorder.shutdown() }
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        capture.feed(0.25)
        try await waitUntilAsync { await engine.cancellationStarted }
        XCTAssertTrue(recorder.isRecording); XCTAssertFalse(capture.stopped)
        // Flush another packet while cancellation is suspended to expose late inbox writes.
        capture.feed(0.5); recorder.stopRecording()
        try await waitUntil { manager.state == .failed }
        XCTAssertEqual(manager.message, "Inference failed; original is safe")
        await engine.releaseCancellation()
        try await waitUntilAsync { await engine.cancelled }
        XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(manager.message, "Inference failed; original is safe")
    }
    func testOnlySelectedSourceReachesTranscriber() async throws {
        let mic = CaptionTestCapture(), system = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { $0.id == "microphone" ? mic : system }, microphonePermission: { true })
        var settings = recorder.settings; settings.outputMode = .system; recorder.updateSettings(settings)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        system.feed(0.75); mic.feed(0.25)
        try await waitUntil { !manager.transcript.segments.isEmpty }
        manager.stop(); try await waitUntil { manager.state == .idle }
        let samples = await engine.consumed
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThan(samples.max() ?? 1, 0.3)
    }
    func testCloudConsentIsRequiredAndDeniedPermissionNeverStartsEngine() async throws {
        let defaults = defaults(), engine = CaptionTestEngine()
        var madeEngine = 0
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in CaptionTestCapture() }, microphonePermission: { false })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in madeEngine += 1; return engine })
        var settings = manager.settings; settings.provider = .agora; manager.updateSettings(settings)
        manager.start()
        XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(madeEngine, 0)
        manager.start(cloudConsent: true)
        try await waitUntil { manager.state == .failed }
        let started = await engine.started
        XCTAssertFalse(started)
        XCTAssertTrue(manager.message?.contains("Microphone permission") == true)
    }
    func testStopDuringEnginePreparationCancelsAndRetainsPreviewOwnership() async throws {
        let defaults = defaults(), engine = CaptionTestEngine(), capture = CaptionTestCapture()
        await engine.configureDelay()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start()
        try await waitUntil { recorder.state == .previewing }
        manager.stop()
        try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
        let cancelled = await engine.cancelled; XCTAssertTrue(cancelled)
    }
    func testToastTogglePersistsWhileRunningAndDoesNotStopTranscription() async throws {
        let defaults = defaults(), engine = CaptionTestEngine(), capture = CaptionTestCapture()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        manager.setFloatingCaptions(false)
        XCTAssertEqual(manager.state, .running)
        let stored = try JSONDecoder().decode(TranscriptionSettings.self, from: XCTUnwrap(defaults.data(forKey: AudioTranscriptionManager.defaultsKey)))
        XCTAssertFalse(stored.floatingCaptions)
        manager.stop(); try await waitUntil { manager.state == .idle }
    }
    func testSwitchingAwayFromRecordingPageKeepsCaptionsRunning() async throws {
        let defaults = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        recorder.transcription.cloudEngineFactory = { _ in engine }
        var settings = recorder.transcription.settings; settings.provider = .agora; recorder.transcription.updateSettings(settings)
        recorder.transcription.start(cloudConsent: true)
        try await waitUntil { recorder.transcription.state == .running }
        let view = AudioRecordingViewController(manager: recorder, hotkeys: HotkeyManager(defaults: defaults))
        view.setPageVisible(false)
        XCTAssertEqual(recorder.state, .previewing)
        XCTAssertEqual(recorder.transcription.state, .running)
        recorder.transcription.stop(); try await waitUntil { recorder.transcription.state == .idle }
    }
    func testStoppingRecordingKeepsCaptionsLiveAndNeverAppendsToCompletedFile() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        capture.feed(0.25); try await waitUntil { !manager.transcript.segments.isEmpty }
        recorder.stopRecording()
        XCTAssertEqual(recorder.state, .previewing)
        XCTAssertEqual(manager.state, .running)
        XCTAssertFalse(capture.stopped)
        let cancelled = await engine.cancelled; XCTAssertFalse(cancelled)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sessionFolder = try XCTUnwrap(recorder.lastSessionFolder)
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: sessionFolder.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "completed")
        let fileURL = sessionFolder.appendingPathComponent(manifest.tracks[0].segments[0].file)
        let completedFrames = try AVAudioFile(forReading: fileURL).length
        let before = await engine.consumed.count
        capture.feed(0.5)
        try await waitUntil { recorder.meter(for: "microphone").peakDB > -7 }
        for _ in 0..<100 {
            if await engine.consumed.count > before { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let after = await engine.consumed.count
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(try AVAudioFile(forReading: fileURL).length, completedFrames)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
    }
    func testStartingRecordingDuringTranscriptionThenStoppingCaptionsLeavesRecordingLive() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        var captureStarts = 0
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in captureStarts += 1; return capture }, microphonePermission: { true })
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        recorder.startRecording()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(captureStarts, 1)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(capture.stopped)
        capture.feed(0.25)
        try await waitUntil { recorder.meter(for: "microphone").peakDB > -13 }
        recorder.stopRecording()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
    }
    func testStopRecordingDuringTranscriptionPreparationRetainsCapture() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        await engine.configureDelay()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start()
        for _ in 0..<100 {
            if await engine.started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        recorder.stopRecording()
        XCTAssertEqual(recorder.state, .previewing)
        XCTAssertEqual(manager.state, .preparing)
        XCTAssertFalse(capture.stopped)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
    }
    func testShutdownStopsBothFeaturesEvenWhenCaptionsNeedCapture() async throws {
        let capture = CaptionTestCapture(), engine = CaptionTestEngine(), defaults = defaults()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        manager.start(); try await waitUntil { manager.state == .running }
        recorder.shutdown(); try await waitUntil { manager.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(capture.stopped)
    }
    func testFloatingToastUpdatesWithoutMovingItsExternalMonitorPosition() async throws {
        _ = NSApplication.shared
        let defaults = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in engine })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("First line\nSecond line")
        try await waitUntil { toast.panel != nil }
        let panel = try XCTUnwrap(toast.panel)
        let moved = NSPoint(x: -1_000, y: 900)
        panel.setFrameOrigin(moved)
        await engine.emit("First line\nSecond line\nAnother caption that wraps across the available width of the floating window.")
        try await waitUntil { manager.transcript.segments.first?.text.contains("Another caption") == true }
        toast.refresh()
        XCTAssertEqual(panel.frame.origin, moved)
        XCTAssertGreaterThan(panel.frame.height, 100)
        XCTAssertLessThanOrEqual(panel.frame.height, 360)
        if let path = ProcessInfo.processInfo.environment["ASTATION_TRANSCRIPTION_TOAST_SNAPSHOT"], let view = panel.contentView {
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        manager.stop(); try await waitUntil { manager.state == .idle }
        manager.expireFloatingCaptions(now: ProcessInfo.processInfo.systemUptime + 21)
        toast.refresh()
        XCTAssertTrue(manager.floatingCaptionBuffer.lines.isEmpty)
        XCTAssertFalse(panel.isVisible)
    }
    private func toastViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { toastViews($0) } }

    func testFloatingCaptionCopyButtonUsesSelectionOrAllVisibleTextWithoutStoppingCapture() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        var recording = recorder.settings; recording.folderPath = try folder().path; recorder.updateSettings(recording)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let toast = TranscriptionToastController(manager: manager, showWindow: false, pasteboard: pasteboard)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("Hello caf\u{00E9} \u{1F44B}\nSecond line", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        let panel = try XCTUnwrap(toast.panel), content = try XCTUnwrap(panel.contentView)
        let text = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSTextView }.first)
        let copy = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Copy" })
        XCTAssertTrue(copy.isEnabled); XCTAssertTrue(text.isSelectable); XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.mouseDownCanMoveWindow); XCTAssertTrue(text.needsPanelToBecomeKey)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded); XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.makeFirstResponder(text))
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello caf\u{00E9} \u{1F44B}\nSecond line")
        let selected = (text.string as NSString).range(of: "caf\u{00E9} \u{1F44B}")
        text.setSelectedRange(selected)
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "caf\u{00E9} \u{1F44B}")
        XCTAssertEqual(text.selectedRange(), selected)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), text.string)
        XCTAssertEqual(manager.state, .running); XCTAssertTrue(recorder.isRecording); XCTAssertFalse(capture.stopped)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(recorder.isRecording); recorder.stopRecording()
    }

    func testFloatingCaptionWordSelectionSupportsKeyboardAndContextMenuCopy() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let toast = TranscriptionToastController(manager: manager, showWindow: false, pasteboard: pasteboard)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("Choose specific words\nAnother line", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        let panel = try XCTUnwrap(toast.panel)
        let text = try XCTUnwrap(toastViews(panel.contentView!).compactMap { $0 as? NSTextView }.first)
        let insideWord = NSRange(location: (text.string as NSString).range(of: "specific").location + 2, length: 0)
        let word = text.selectionRange(forProposedRange: insideWord, granularity: .selectByWord)
        text.setSelectedRange(word)
        XCTAssertEqual((text.string as NSString).substring(with: word), "specific")
        let commandC = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(text.performKeyEquivalent(with: commandC))
        XCTAssertEqual(pasteboard.string(forType: .string), "specific")
        text.setSelectedRange((text.string as NSString).range(of: "words\nAnother"))
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(text.menu(for: rightClick))
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(pasteboard.string(forType: .string), "words\nAnother")
        let commandA = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(text.performKeyEquivalent(with: commandA))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: (text.string as NSString).length))
        XCTAssertTrue(text.performKeyEquivalent(with: commandC))
        XCTAssertEqual(pasteboard.string(forType: .string), text.string)
        manager.stop(); try await waitUntil { manager.state == .idle }
    }

    func testFloatingCaptionSelectionSurvivesLiveUpdatesAndWaitingCannotBeCopied() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let toast = TranscriptionToastController(manager: manager, showWindow: false, pasteboard: pasteboard)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("Keep these selected words")
        try await waitUntil { manager.floatingCaptionsVisible }
        let panel = try XCTUnwrap(toast.panel), content = try XCTUnwrap(panel.contentView)
        let text = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSTextView }.first)
        let copy = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Copy" })
        let moved = NSPoint(x: -1_000, y: 900); panel.setFrameOrigin(moved)
        text.setSelectedRange((text.string as NSString).range(of: "selected words"))
        await engine.emit("Keep these selected words and more", final: true)
        try await waitUntil { text.string.hasSuffix("and more") }
        await engine.emit("New caption arrives", id: "new", final: true)
        try await waitUntil { text.string.hasSuffix("New caption arrives") }
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "selected words")
        XCTAssertEqual(panel.frame.origin, moved)
        manager.expireFloatingCaptions(now: ProcessInfo.processInfo.systemUptime + 21); toast.refresh()
        XCTAssertFalse(copy.isEnabled); XCTAssertFalse(text.isSelectable); XCTAssertEqual(text.selectedRange().length, 0)
        manager.setFloatingCaptions(true)
        XCTAssertTrue(text.string.contains("Waiting for speech")); XCTAssertFalse(copy.isEnabled); XCTAssertFalse(text.isSelectable)
        copy.performClick(nil); text.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "selected words")
        await engine.emit("Fresh caption", id: "fresh", final: true)
        try await waitUntil { text.string == "Fresh caption" }
        XCTAssertTrue(copy.isEnabled); XCTAssertTrue(text.isSelectable)
        copy.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Fresh caption")
        manager.stop(); try await waitUntil { manager.state == .idle }
    }

    func testNewSpeechReopensToastAfterAutomaticExpiryWithoutTogglingPreference() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("Repeated sentence", id: "first", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        let panel = try XCTUnwrap(toast.panel)
        let moved = NSPoint(x: -1_000, y: 900); panel.setFrameOrigin(moved)
        manager.expireFloatingCaptions(now: ProcessInfo.processInfo.systemUptime + 21)
        toast.refresh()
        XCTAssertFalse(manager.floatingCaptionsVisible)
        XCTAssertTrue(manager.settings.floatingCaptions)
        XCTAssertEqual(manager.state, .running)
        XCTAssertTrue(toast.isMonitoringCaptions)
        // The same words in a NEW utterance must wake the panel after its expiry timer stopped.
        await engine.emit("Repeated sentence", id: "second", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        XCTAssertTrue(toast.panel === panel); XCTAssertEqual(panel.frame.origin, moved)
        XCTAssertEqual(manager.floatingCaptionBuffer.lines.map { $0.segment.id }, ["second"])
        let text = try XCTUnwrap(toastViews(panel.contentView!).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(text.string, "Repeated sentence")
        manager.stop(); try await waitUntil { manager.state == .idle }
    }

    func testHideThenRestoreThroughSettingsWithExpiredHistoryKeepsRecordingAndPosition() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        var recording = recorder.settings; recording.folderPath = try folder().path; recorder.updateSettings(recording)
        recorder.startRecording(); try await waitUntil { recorder.isRecording }
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        let settings = TranscriptionViewController(recorder: recorder, manager: manager)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("Caption before Hide", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        let panel = try XCTUnwrap(toast.panel), content = try XCTUnwrap(toast.panel?.contentView)
        let moved = NSPoint(x: 2_800, y: -200); panel.setFrameOrigin(moved)
        let fields = toastViews(content).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == "LIVE CAPTIONS" })
        XCTAssertFalse(fields.contains { $0.stringValue.contains("LAST 20 SECONDS") })
        let hide = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSButton }.first { $0.title == "Hide" })
        hide.performClick(nil)
        XCTAssertFalse(manager.settings.floatingCaptions); XCTAssertFalse(manager.floatingCaptionsVisible)
        XCTAssertFalse(toast.isMonitoringCaptions)
        manager.expireFloatingCaptions(now: ProcessInfo.processInfo.systemUptime + 21)
        let show = try XCTUnwrap(toastViews(settings.view).compactMap { $0 as? NSButton }.first { $0.title == "Show Floating Captions" })
        show.performClick(nil)
        XCTAssertTrue(manager.settings.floatingCaptions); XCTAssertTrue(manager.floatingCaptionsVisible)
        let text = try XCTUnwrap(toastViews(content).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.string.contains("Waiting for speech"))
        XCTAssertFalse(text.string.contains("Caption before Hide"))
        XCTAssertEqual(panel.frame.origin, moved); XCTAssertTrue(recorder.isRecording)
        await engine.emit("New speech after Hide", id: "new", final: true)
        try await waitUntil { text.string == "New speech after Hide" }
        manager.toggleFloatingCaptions()
        XCTAssertFalse(manager.floatingCaptionsVisible)
        manager.toggleFloatingCaptions()
        XCTAssertTrue(manager.floatingCaptionsVisible)
        XCTAssertEqual(panel.frame.origin, moved)
        manager.stop(); try await waitUntil { manager.state == .idle }
        XCTAssertTrue(recorder.isRecording); recorder.stopRecording()
    }

    func testToggleAfterAutoHideShowsWaitingWindowInsteadOfDisablingCaptions() async throws {
        _ = NSApplication.shared
        let storage = defaults(), capture = CaptionTestCapture(), engine = CaptionTestEngine()
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { _ in capture }, microphonePermission: { true })
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { _ in engine })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        manager.start(); try await waitUntil { manager.state == .running }
        await engine.emit("First caption", final: true)
        try await waitUntil { manager.floatingCaptionsVisible }
        manager.expireFloatingCaptions(now: ProcessInfo.processInfo.systemUptime + 21); toast.refresh()
        XCTAssertFalse(manager.floatingCaptionsVisible); XCTAssertTrue(manager.settings.floatingCaptions)
        manager.toggleFloatingCaptions()
        XCTAssertTrue(manager.floatingCaptionsVisible); XCTAssertTrue(manager.settings.floatingCaptions)
        let text = try XCTUnwrap(toastViews(toast.panel!.contentView!).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.string.contains("Waiting for speech"))
        let checkbox = try XCTUnwrap(toastViews(TranscriptionViewController(recorder: recorder, manager: manager).view)
            .compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Floating captions -") })
        XCTAssertEqual(checkbox.state, .on)
        manager.stop(); try await waitUntil { manager.state == .idle }
    }
}
