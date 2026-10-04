import AVFoundation
import CStationCore
import XCTest
@testable import Menubar

private final class TestAudioCapture: MicrophoneConfigurationHandling {
    let format: AVAudioFormat
    let queue: OpaquePointer
    let configurationObject = NSObject()
    var onRecovery: (() throws -> Void)?
    private let lifecycleLock = NSLock()
    private var storedStopped = false
    private var storedRecoveryCount = 0
    var stopped: Bool { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return storedStopped }
    var recoveryCount: Int { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return storedRecoveryCount }

    init(smallQueue: Bool = false, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        queue = astation_audio_queue_create(channels, smallQueue ? 8 : 4096, smallQueue ? 2 : 64)!
    }
    func stop() { lifecycleLock.lock(); storedStopped = true; lifecycleLock.unlock() }
    func ownsEngine(_ object: Any?) -> Bool { (object as? NSObject) === configurationObject }
    func recoverAfterConfigurationChange() throws {
        lifecycleLock.lock()
        storedRecoveryCount += 1
        let stopped = storedStopped
        lifecycleLock.unlock()
        if !stopped { try onRecovery?() }
    }
    deinit { astation_audio_queue_destroy(queue) }

    func feed(_ value: Float, frames: UInt32 = 480) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            buffer.floatChannelData![channel].initialize(repeating: value, count: Int(frames))
        }
        astation_audio_queue_push(queue, buffer.audioBufferList, frames, mach_absolute_time(), format.sampleRate)
    }
}

@MainActor
final class AudioRecordingManagerTests: XCTestCase {
    private func storage() -> UserDefaults {
        let name = "astation-audio-manager-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astation-audio-manager-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Audio state did not settle within one second")
    }

    func testPreviewUsesRealMeterDataButCreatesNoRecordingFiles() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        let root = try folder()
        settings.folderPath = root.path
        manager.updateSettings(settings)
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        capture.feed(0.25)
        try await waitUntil { manager.meter(for: "microphone").lastAudioTime > 0 }
        XCTAssertEqual(manager.meter(for: "microphone").peakDB, -12.0412, accuracy: 0.001)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertNil(manager.lastSessionFolder)
        manager.stopPreview()
        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(manager.state, .idle)
    }

    func testSparsePreviewBuffersKeepLevelsBetweenWorkerTicks() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        defer { manager.shutdown() }
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        capture.feed(0.25, frames: 4800)
        try await waitUntil { manager.meter(for: "microphone").lastAudioTime > 0 }
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 40_000_000)
            let meter = manager.meter(for: "microphone")
            XCTAssertEqual(meter.rmsDB, -12.0412, accuracy: 0.001)
            XCTAssertEqual(meter.peakDB, -12.0412, accuracy: 0.001)
            XCTAssertEqual(manager.state, .previewing)
        }
    }

    func testOutputTapStartsBeforeMicrophone() async throws {
        let microphone = TestAudioCapture()
        let system = TestAudioCapture()
        var started: [String] = []
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { source in
            started.append(source.id)
            return source.id == "microphone" ? microphone : system
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        var settings = manager.settings
        settings.outputMode = .system
        manager.updateSettings(settings)
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        XCTAssertEqual(started, ["system", "microphone"])
        XCTAssertEqual(manager.selectedSources.map(\.id), ["microphone", "system"])
    }

    func testUnchangedMicrophoneConfigurationKeepsPreviewAndSystemCapture() async throws {
        let microphone = TestAudioCapture()
        let system = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { source in
            source.id == "microphone" ? microphone : system
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        var settings = manager.settings
        settings.outputMode = .system
        manager.updateSettings(settings)
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationObject)
        try await waitUntil { microphone.recoveryCount == 1 && manager.sourceMessages["microphone"] == nil }
        XCTAssertEqual(manager.state, .previewing)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(microphone.stopped)
        XCTAssertFalse(system.stopped)
        microphone.feed(0.25)
        system.feed(0.5)
        try await waitUntil { manager.meter(for: "microphone").peakDB > -120 && manager.meter(for: "system").peakDB > -120 }
    }

    func testConfigurationFromUnrelatedEngineIsIgnored() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        defer { manager.shutdown() }
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(capture.recoveryCount, 0)
        XCTAssertEqual(manager.state, .previewing)
    }

    func testMonoToStereoChangeReconnectsOnlyMicrophoneAndKeepsSystemPreview() async throws {
        let capture = TestAudioCapture(sampleRate: 44_100), replacement = TestAudioCapture(sampleRate: 44_100, channels: 2)
        let system = TestAudioCapture()
        capture.onRecovery = { throw AudioCaptureError.microphoneFormatChanged(previous: "44100 Hz / 1 channel", current: "44100 Hz / 2 channels") }
        var microphoneStarts = 0
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { source in
            guard source.id == "microphone" else { return system }
            microphoneStarts += 1
            return microphoneStarts == 1 ? capture : replacement
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        var settings = manager.settings; settings.outputMode = .system; settings.folderPath = try folder().path
        manager.updateSettings(settings)
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.configurationObject)
        try await waitUntil { microphoneStarts == 2 && !manager.isReconnectingMicrophone }
        XCTAssertTrue(capture.stopped)
        XCTAssertFalse(replacement.stopped); XCTAssertFalse(system.stopped)
        XCTAssertEqual(manager.state, .previewing)
        XCTAssertNil(manager.errorMessage)
        replacement.feed(0.25); system.feed(0.5)
        try await waitUntil { manager.meter(for: "microphone").peakDB > -120 && manager.meter(for: "system").peakDB > -120 }
        XCTAssertEqual(manager.meter(for: "microphone").lanes.count, 2)
        XCTAssertEqual(manager.meter(for: "microphone").peakDB, -12.0412, accuracy: 0.001)
        XCTAssertNil(manager.lastSessionFolder)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: settings.folderPath).isEmpty)
    }

    func testFailedPreviewFormatReconnectShowsErrorWithoutCreatingRecording() async throws {
        let capture = TestAudioCapture()
        capture.onRecovery = { throw AudioCaptureError.microphoneFormatChanged(previous: "mono", current: "stereo") }
        var starts = 0
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            starts += 1
            if starts > 1 { throw AudioCaptureError.message("Device disconnected") }
            return capture
        }, microphonePermission: { true })
        manager.startPreview(); try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.configurationObject)
        try await waitUntil { manager.state == .failed }
        XCTAssertTrue(capture.stopped)
        XCTAssertTrue(manager.errorMessage?.contains("could not be reconnected") == true)
        XCTAssertTrue(manager.errorMessage?.contains("Device disconnected") == true)
        XCTAssertNil(manager.lastSessionFolder)
    }
    func testRepeatedTrueFormatReplacementsStayBoundedAcrossNewCaptures() async throws {
        var captures: [TestAudioCapture] = []
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            let capture = TestAudioCapture(channels: captures.count.isMultiple(of: 2) ? 1 : 2)
            capture.onRecovery = { throw AudioCaptureError.microphoneFormatChanged(previous: "old", current: "changed") }
            captures.append(capture)
            return capture
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        manager.startPreview(); try await waitUntil { manager.state == .previewing }
        for count in 1...3 {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: captures.last!.configurationObject)
            try await waitUntil { captures.count == count + 1 && !manager.isReconnectingMicrophone }
            XCTAssertEqual(manager.state, .previewing)
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: captures.last!.configurationObject)
        try await waitUntil { manager.state == .failed }
        XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(captures.count, 4)
        XCTAssertTrue(manager.errorMessage?.contains("keeps reconfiguring") == true)
    }

    func testCancelledFormatReplacementCannotAttachToNewPreview() async throws {
        let first = TestAudioCapture(), stale = TestAudioCapture(channels: 2), fresh = TestAudioCapture()
        first.onRecovery = { throw AudioCaptureError.microphoneFormatChanged(previous: "mono", current: "stereo") }
        let waiting = expectation(description: "Replacement is preparing"), release = DispatchSemaphore(value: 0)
        var starts = 0
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            starts += 1
            if starts == 2 {
                waiting.fulfill()
                guard release.wait(timeout: .now() + 2) == .success else { throw AudioCaptureError.message("Timed out") }
                return stale
            }
            return starts == 1 ? first : fresh
        }, microphonePermission: { true })
        defer { manager.shutdown(); release.signal() }
        manager.startPreview(); try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: first.configurationObject)
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(manager.isReconnectingMicrophone)
        XCTAssertTrue(manager.controlsLocked)
        manager.startRecording()
        XCTAssertFalse(manager.isRecording)
        XCTAssertNil(manager.lastSessionFolder)
        manager.stopPreview(); manager.startPreview(); release.signal()
        try await waitUntil { manager.state == .previewing && starts == 3 }
        XCTAssertTrue(stale.stopped)
        XCTAssertFalse(fresh.stopped)
        XCTAssertNil(manager.errorMessage)
    }

    func testUnchangedMicrophoneConfigurationKeepsOriginalRecording() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        settings.folderPath = try folder().path
        manager.updateSettings(settings)
        manager.startRecording()
        try await waitUntil { manager.isRecording }
        capture.feed(0.25)
        try await waitUntil { manager.meter(for: "microphone").peakDB > -120 }
        let sessionFolder = manager.lastSessionFolder
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.configurationObject)
        try await waitUntil { capture.recoveryCount == 1 && manager.sourceMessages["microphone"] == nil }
        XCTAssertEqual(manager.state, .recording)
        XCTAssertEqual(manager.lastSessionFolder, sessionFolder)
        XCTAssertNil(manager.errorMessage)
        manager.stopRecording()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingSessionManifest.self,
            from: Data(contentsOf: XCTUnwrap(sessionFolder).appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "completed")
        XCTAssertEqual(manifest.tracks[0].sampleRate, 48_000)
        XCTAssertGreaterThan(manifest.tracks[0].segments[0].frameCount, 0)
    }

    func testTrueMicrophoneFormatChangeRetainsBothOriginalTracks() async throws {
        let microphone = TestAudioCapture()
        let system = TestAudioCapture()
        microphone.onRecovery = {
            throw AudioCaptureError.microphoneFormatChanged(previous: "48000 Hz / 1 channel", current: "44100 Hz / 2 channels")
        }
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { source in
            source.id == "microphone" ? microphone : system
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        var settings = manager.settings
        settings.folderPath = try folder().path
        settings.outputMode = .system
        manager.updateSettings(settings)
        manager.startRecording()
        try await waitUntil { manager.isRecording }
        microphone.feed(0.25)
        system.feed(0.5)
        try await waitUntil { manager.meter(for: "microphone").peakDB > -120 && manager.meter(for: "system").peakDB > -120 }
        let sessionFolder = try XCTUnwrap(manager.lastSessionFolder)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationObject)
        try await waitUntil { manager.state == .failed }
        XCTAssertTrue(microphone.stopped)
        XCTAssertTrue(system.stopped)
        XCTAssertEqual(manager.lastSessionFolder, sessionFolder)
        XCTAssertTrue(manager.errorMessage?.contains("recording was stopped") == true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingSessionManifest.self,
            from: Data(contentsOf: sessionFolder.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "failed")
        XCTAssertEqual(manifest.tracks.count, 2)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("48000 Hz") && $0.contains("44100 Hz") })
        for track in manifest.tracks {
            XCTAssertEqual(track.sampleRate, 48_000)
            let segment = try XCTUnwrap(track.segments.first)
            XCTAssertGreaterThan(segment.frameCount, 0)
            let file = try AVAudioFile(forReading: sessionFolder.appendingPathComponent(segment.file))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
            try file.read(into: buffer)
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            XCTAssertTrue(samples.contains(track.sourceID == "microphone" ? 0.25 : 0.5))
        }
    }

    func testRepeatedMicrophoneReconfigurationIsBounded() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        for attempt in 1...3 {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.configurationObject)
            try await waitUntil { capture.recoveryCount == attempt && manager.sourceMessages["microphone"] == nil }
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.configurationObject)
        try await waitUntil { manager.state == .failed }
        XCTAssertEqual(capture.recoveryCount, 3)
        XCTAssertTrue(manager.errorMessage?.contains("keeps reconfiguring") == true)
        XCTAssertTrue(capture.stopped)
    }

    func testCancelledMicrophoneRecoveryCannotFailNewPreview() async throws {
        let first = TestAudioCapture()
        let second = TestAudioCapture()
        let started = expectation(description: "Recovery started")
        let releaseRecovery = DispatchSemaphore(value: 0)
        first.onRecovery = {
            started.fulfill()
            guard releaseRecovery.wait(timeout: .now() + 2) == .success else {
                throw AudioCaptureError.message("Test recovery timed out")
            }
            throw AudioCaptureError.message("Cancelled recovery failed late")
        }
        var setups = 0
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            setups += 1
            return setups == 1 ? first : second
        }, microphonePermission: { true })
        defer { manager.shutdown() }
        manager.startPreview()
        try await waitUntil { manager.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: first.configurationObject)
        await fulfillment(of: [started], timeout: 1)
        manager.stopPreview()
        manager.startPreview()
        releaseRecovery.signal()
        try await waitUntil { manager.state == .previewing }
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(second.stopped)
    }

    func testRecordingPauseAndResumeSaveOriginalAudioAndExcludePausedSamples() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        settings.folderPath = try folder().path
        manager.updateSettings(settings)
        manager.startRecording()
        try await waitUntil { manager.state == .recording }
        capture.feed(0.25)
        try await Task.sleep(nanoseconds: 80_000_000)
        manager.togglePause()
        XCTAssertEqual(manager.state, .paused)
        let pausedElapsed = manager.elapsed
        capture.feed(0.9)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(manager.elapsed, pausedElapsed, accuracy: 0.04)
        manager.togglePause()
        capture.feed(0.5)
        try await Task.sleep(nanoseconds: 80_000_000)
        manager.stopRecording()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(capture.stopped)
        let sessionFolder = try XCTUnwrap(manager.lastSessionFolder)
        let files = try FileManager.default.contentsOfDirectory(at: sessionFolder, includingPropertiesForKeys: nil)
        let file = try AVAudioFile(forReading: XCTUnwrap(files.first { $0.pathExtension == "caf" }))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        XCTAssertTrue(samples.contains(0.25))
        XCTAssertTrue(samples.contains(0.5))
        XCTAssertFalse(samples.contains(0.9))
    }

    func testRecordingLocksSourceSettings() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        settings.folderPath = try folder().path
        manager.updateSettings(settings)
        manager.startRecording()
        try await waitUntil { manager.isRecording }
        var changed = settings
        changed.microphoneEnabled = false
        manager.updateSettings(changed)
        XCTAssertEqual(manager.settings, settings)
        manager.stopRecording()
    }

    func testDeniedMicrophoneNeverOpensCapture() async throws {
        var opened = false
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            opened = true
            return TestAudioCapture()
        }, microphonePermission: { false })
        manager.startPreview()
        try await waitUntil { manager.state == .failed }
        XCTAssertFalse(opened)
        XCTAssertTrue(manager.errorMessage?.contains("Microphone permission") == true)
    }

    func testCancellingPendingPermissionCannotRestartHiddenPreview() async throws {
        var opened = false
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            opened = true
            return TestAudioCapture()
        }, microphonePermission: {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        })
        manager.startPreview()
        manager.stopPreview()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.state, .idle)
    }

    func testLateSetupFailureCannotStopNewPreview() async throws {
        let firstStarted = expectation(description: "First setup started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let capture = TestAudioCapture()
        var setups = 0
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            setups += 1
            if setups == 1 {
                firstStarted.fulfill()
                guard releaseFirst.wait(timeout: .now() + 2) == .success else {
                    throw AudioCaptureError.message("Test setup timed out")
                }
                throw AudioCaptureError.message("Cancelled setup failed late")
            }
            return capture
        }, microphonePermission: { true })
        manager.startPreview()
        await fulfillment(of: [firstStarted], timeout: 1)
        manager.stopPreview()
        manager.startPreview()
        releaseFirst.signal()
        try await waitUntil { manager.state == .previewing }
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(capture.stopped)
        manager.shutdown()
    }

    func testCancellingSetupStopsLateCaptureWithoutRestartingPreview() async throws {
        let started = expectation(description: "Setup started")
        let releaseSetup = DispatchSemaphore(value: 0)
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            started.fulfill()
            guard releaseSetup.wait(timeout: .now() + 2) == .success else {
                throw AudioCaptureError.message("Test setup timed out")
            }
            return capture
        }, microphonePermission: { true })
        manager.startPreview()
        await fulfillment(of: [started], timeout: 1)
        manager.stopPreview()
        releaseSetup.signal()
        try await waitUntil { capture.stopped }
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.errorMessage)
    }

    func testSleepCancelsPendingCaptureSetup() async throws {
        let started = expectation(description: "Setup started")
        let releaseSetup = DispatchSemaphore(value: 0)
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in
            started.fulfill()
            guard releaseSetup.wait(timeout: .now() + 2) == .success else {
                throw AudioCaptureError.message("Test setup timed out")
            }
            return capture
        }, microphonePermission: { true })
        manager.startPreview()
        await fulfillment(of: [started], timeout: 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(manager.state, .failed)
        releaseSetup.signal()
        try await waitUntil { capture.stopped }
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.errorMessage?.contains("going to sleep") == true)
    }

    func testOverflowStopsRecordingAndRecordsDroppedFrames() async throws {
        let capture = TestAudioCapture(smallQueue: true)
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        settings.folderPath = try folder().path
        manager.updateSettings(settings)
        manager.startRecording()
        try await waitUntil { manager.isRecording }
        capture.feed(0.25, frames: 64)
        try await waitUntil { manager.state == .failed }
        XCTAssertTrue(capture.stopped)
        XCTAssertTrue(manager.errorMessage?.contains("could not keep up") == true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: XCTUnwrap(manager.lastSessionFolder).appendingPathComponent("session.json")))
        XCTAssertEqual(manifest.status, "failed")
        XCTAssertEqual(manifest.tracks[0].droppedFrames, 48)
    }

    func testHidingRecordingPageStopsPreviewButKeepsRecording() async throws {
        let capture = TestAudioCapture()
        let manager = AudioRecordingManager(defaults: storage(), captureFactory: { _ in capture }, microphonePermission: { true })
        var settings = manager.settings
        settings.folderPath = try folder().path
        manager.updateSettings(settings)
        let controller = AudioRecordingViewController(manager: manager, hotkeys: HotkeyManager(defaults: storage()))
        manager.startRecording()
        try await waitUntil { manager.isRecording }
        controller.setPageVisible(false)
        XCTAssertTrue(manager.isRecording)
        manager.shutdown()
        XCTAssertTrue(capture.stopped)
    }
}
