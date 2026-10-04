import AVFoundation
import CStationCore
import XCTest
@testable import Menubar

final class AudioRecordingTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astation-audio-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func settings(in folder: URL, format: RecordingFileFormat = .caf) -> AudioRecordingSettings {
        var settings = AudioRecordingSettings()
        settings.folderPath = folder.path
        settings.format = format
        return settings
    }

    private let mic = AudioSourceSelection(id: "microphone", title: "Test microphone", kind: .microphone(nil))
    private let app = AudioSourceSelection(id: "test.app", title: "Test app", kind: .application("test.app"))

    private func append(_ samples: [Float], session: AudioRecordingSession, source: String,
                        channels: Int, at time: TimeInterval) throws {
        try samples.withUnsafeBufferPointer {
            try session.append(sourceID: source, samples: $0, frames: samples.count / channels,
                               hostTime: time, droppedFrames: 0)
        }
    }

    private func read(_ session: AudioRecordingSession, trackID: String) throws -> (AVAudioFile, AVAudioPCMBuffer) {
        let track = try XCTUnwrap(session.manifest.tracks.first { $0.sourceID == trackID })
        let segment = try XCTUnwrap(track.segments.first)
        let file = try AVAudioFile(forReading: session.folder.appendingPathComponent(segment.file))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (file, buffer)
    }

    func testLosslessCAFAndWAVPreserveStereoSamplesAndNativeRate() throws {
        for format in RecordingFileFormat.allCases {
            let session = try AudioRecordingSession(settings: settings(in: temporaryFolder(), format: format), startTime: 100)
            try session.addSource(app, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
            let samples: [Float] = (0..<441).flatMap { frame in [Float(frame) / 1000, -Float(frame) / 2000] }
            try append(samples, session: session, source: app.id, channels: 2, at: 100)
            try session.finish(at: 100.01)
            let (file, buffer) = try read(session, trackID: app.id)
            XCTAssertEqual(file.length, 441)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            XCTAssertEqual(file.fileFormat.channelCount, 2)
            for frame in 0..<441 {
                XCTAssertEqual(buffer.floatChannelData![0][frame], samples[frame * 2], accuracy: 1e-7)
                XCTAssertEqual(buffer.floatChannelData![1][frame], samples[frame * 2 + 1], accuracy: 1e-7)
            }
            XCTAssertEqual(session.manifest.status, "completed")
        }
    }

    func testIndependentTracksKeepNativeRatesAndAlignLateStart() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try session.addSource(app, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        try append([Float](repeating: 0.25, count: 4800), session: session, source: mic.id, channels: 1, at: 100)
        try append([Float](repeating: 0.5, count: 4410), session: session, source: app.id, channels: 2, at: 100.05)
        try session.finish(at: 100.1)
        let (micFile, _) = try read(session, trackID: mic.id)
        let (appFile, appData) = try read(session, trackID: app.id)
        XCTAssertEqual(micFile.length, 4800)
        XCTAssertEqual(appFile.length, 4410)
        XCTAssertEqual(appData.floatChannelData![0][2204], 0)
        XCTAssertEqual(appData.floatChannelData![0][2205], 0.5)
        XCTAssertEqual(session.manifest.tracks.first { $0.sourceID == app.id }?.gaps.first?.frameCount, 2205)
    }

    func testThreeChannelAggregateCAFPreservesEveryLane() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        let format = try XCTUnwrap(NativeAudioFormat.floatPCM(sampleRate: 44_100, channels: 3))
        try session.addSource(mic, format: format)
        let samples = (0..<441).flatMap { _ in [Float(0.25), Float(-0.5), Float(0.75)] }
        try append(samples, session: session, source: mic.id, channels: 3, at: 100)
        try session.finish(at: 100.01)
        let (file, buffer) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.fileFormat.channelCount, 3); XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.length, 441)
        for frame in 0..<441 {
            for lane in 0..<3 { XCTAssertEqual(buffer.floatChannelData![lane][frame], samples[frame * 3 + lane], accuracy: 1e-7) }
        }
    }

    func testPauseExcludesItsSamplesAndDuration() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try append([Float](repeating: 0.25, count: 480), session: session, source: mic.id, channels: 1, at: 100)
        try session.pause(at: 100.01)
        try append([Float](repeating: 0.9, count: 480), session: session, source: mic.id, channels: 1, at: 100.5)
        XCTAssertEqual(session.elapsed(at: 100.7), 0.01, accuracy: 1e-8)
        try session.resume(at: 101.01)
        try append([Float](repeating: 0.5, count: 480), session: session, source: mic.id, channels: 1, at: 101.01)
        try session.finish(at: 101.02)
        let (file, data) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.length, 960)
        XCTAssertEqual(data.floatChannelData![0][479], 0.25)
        XCTAssertEqual(data.floatChannelData![0][480], 0.5)
        XCTAssertEqual(session.manifest.duration, 0.02, accuracy: 1e-8)
    }

    func testGapIsPaddedAndReportedWithoutChangingFollowingSamples() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try append([Float](repeating: 0.25, count: 480), session: session, source: mic.id, channels: 1, at: 100)
        try append([Float](repeating: 0.5, count: 480), session: session, source: mic.id, channels: 1, at: 100.05)
        try session.finish(at: 100.06)
        let (file, data) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.length, 2880)
        XCTAssertEqual(data.floatChannelData![0][480], 0)
        XCTAssertEqual(data.floatChannelData![0][2399], 0)
        XCTAssertEqual(data.floatChannelData![0][2400], 0.5)
        XCTAssertEqual(session.manifest.tracks[0].gaps.first?.frameCount, 1920)
    }

    func testDelayedBufferStraddlingPauseIsTrimmedAtSampleBoundaries() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try session.pause(at: 100.005)
        try session.resume(at: 100.007)
        let samples = [Float](repeating: 0.25, count: 240) + [Float](repeating: 0.9, count: 96) + [Float](repeating: 0.5, count: 144)
        try append(samples, session: session, source: mic.id, channels: 1, at: 100)
        try session.finish(at: 100.01)
        let (file, data) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.length, 384)
        XCTAssertEqual(data.floatChannelData![0][239], 0.25)
        XCTAssertEqual(data.floatChannelData![0][240], 0.5)
    }

    func testDelayedBufferBeforeRecordingStartExcludesItsEarlierSamples() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100.005)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        let samples = [Float](repeating: 0.9, count: 240) + [Float](repeating: 0.5, count: 240)
        try append(samples, session: session, source: mic.id, channels: 1, at: 100)
        try session.finish(at: 100.01)
        let (file, data) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.length, 240)
        XCTAssertEqual(data.floatChannelData![0][0], 0.5)
    }

    func testFailedSessionKeepsAudioAndWritesFailureMetadata() throws {
        let session = try AudioRecordingSession(settings: settings(in: temporaryFolder()), startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try append([Float](repeating: 0.25, count: 480), session: session, source: mic.id, channels: 1, at: 100)
        try session.finish(at: 120, error: "Device disconnected")
        let (file, _) = try read(session, trackID: mic.id)
        XCTAssertEqual(file.length, 480)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: session.folder.appendingPathComponent("session.json")))
        XCTAssertEqual(saved.status, "failed")
        XCTAssertEqual(saved.warnings, ["Device disconnected"])
        XCTAssertEqual(saved.tracks.count, 1)
    }

    func testLongTrackSplitsAtConfiguredBoundary() throws {
        var config = settings(in: try temporaryFolder())
        config.splitMinutes = 15
        let session = try AudioRecordingSession(settings: config, startTime: 100)
        try session.addSource(mic, format: AVAudioFormat(standardFormatWithSampleRate: 100, channels: 1)!)
        try append([Float](repeating: 0.25, count: 90_100), session: session, source: mic.id, channels: 1, at: 100)
        try session.finish(at: 1001)
        let track = try XCTUnwrap(session.manifest.tracks.first)
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertEqual(track.segments[0].frameCount, 90_000)
        XCTAssertEqual(track.segments[1].startFrame, 90_000)
        XCTAssertEqual(track.segments[1].frameCount, 100)
        for segment in track.segments {
            let file = try AVAudioFile(forReading: session.folder.appendingPathComponent(segment.file))
            XCTAssertEqual(file.length, segment.frameCount)
        }
    }

    func testRecordingFolderFailureIsReported() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try AudioRecordingSession(settings: settings(in: file), startTime: 100))
    }

    func testDefaultRecordingFolderUsesDocumentsAstationRecordings() throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        XCTAssertEqual(AudioRecordingSettings().folderPath,
                       documents.appendingPathComponent("Astation/Recordings", isDirectory: true).path)
    }

    func testMicrophoneFormatValidationChecksRateChannelsAndSampleLayout() {
        let original = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertTrue(MicrophoneCaptureFormat.matches(original, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!))
        XCTAssertFalse(MicrophoneCaptureFormat.matches(original, AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!))
        XCTAssertFalse(MicrophoneCaptureFormat.matches(original, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!))
        XCTAssertFalse(MicrophoneCaptureFormat.matches(original, AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 48_000, channels: 1, interleaved: false)!))
        XCTAssertFalse(MicrophoneCaptureFormat.matches(original, AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!))
    }
    func testMicrophoneTapUsesHardwareChannelsInsteadOfCachedMonoOutput() throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let aggregate = try XCTUnwrap(NativeAudioFormat.floatPCM(sampleRate: 44_100, channels: 3))
        XCTAssertTrue(MicrophoneCaptureFormat.matches(try MicrophoneCaptureFormat.tapFormat(hardware: stereo), stereo))
        XCTAssertEqual(try MicrophoneCaptureFormat.tapFormat(hardware: aggregate).channelCount, 3)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        XCTAssertNoThrow(try MicrophoneCaptureFormat.validate(stereo, hardware: stereo, nodeOutput: stereo))
        XCTAssertThrowsError(try MicrophoneCaptureFormat.validate(stereo, hardware: stereo, nodeOutput: mono)) { error in
            XCTAssertTrue(error.localizedDescription.contains("44100 Hz / 1 channels"))
        }
    }

    func testSettingsRequireSourceAndValidFileLength() {
        var settings = AudioRecordingSettings()
        XCTAssertNil(settings.validationError)
        settings.microphoneEnabled = false
        XCTAssertNotNil(settings.validationError)
        settings.outputMode = .applications
        XCTAssertNotNil(settings.validationError)
        settings.applicationBundleIDs = ["test.app"]
        XCTAssertNil(settings.validationError)
        settings.splitMinutes = -1
        XCTAssertNotNil(settings.validationError)
    }

    func testWaveformReportsStereoLevelsWithoutNormalizingQuietAudio() {
        var waveform = AudioWaveformAccumulator(channels: 2, sampleRate: 48_000)
        let samples: [Float] = (0..<1600).flatMap { _ in [Float(0.01), Float(-0.02)] }
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: 1600, now: 100) }
        let result = waveform.takeSnapshot(now: 100, droppedFrames: 0)
        XCTAssertEqual(result.lanes.count, 2)
        XCTAssertEqual(result.lanes[0].first?.maximum ?? -1, 0.01, accuracy: 1e-7)
        XCTAssertEqual(result.lanes[1].first?.minimum ?? -1, -0.02, accuracy: 1e-7)
        XCTAssertEqual(result.peakDB, -33.9794, accuracy: 0.001)
        XCTAssertEqual(result.rmsDB, -36.0206, accuracy: 0.001)
    }

    func testSineWaveRMSAndPeakAreCalibrated() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let increment = 2.0 * Double.pi * 1000.0 / 48_000.0
        let samples: [Float] = (0..<4800).map { Float(0.5 * sin(Double($0) * increment)) }
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 100) }
        let result = waveform.takeSnapshot(now: 100, droppedFrames: 0)
        XCTAssertEqual(result.peakDB, -6.0206, accuracy: 0.001)
        XCTAssertEqual(result.rmsDB, -9.0309, accuracy: 0.001)
        XCTAssertEqual(result.lanes[0].count, 3)
    }

    func testSilenceIsFlatAndClippingHasRealTimestamp() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        var samples = [Float](repeating: 0, count: 1600)
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 100) }
        var result = waveform.takeSnapshot(now: 100, droppedFrames: 7)
        XCTAssertEqual(result.peakDB, -120)
        XCTAssertEqual(result.rmsDB, -120)
        XCTAssertEqual(result.lanes[0], [WaveformBin()])
        XCTAssertEqual(result.lastClipTime, 0)
        samples[800] = -1
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 101) }
        result = waveform.takeSnapshot(now: 101, droppedFrames: 7)
        XCTAssertEqual(result.lastClipTime, 101)
        XCTAssertEqual(result.peakDB, 0)
        XCTAssertEqual(result.droppedFrames, 7)
    }

    func testWaveformHistoryIsBoundedToFiveSeconds() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let samples = [Float](repeating: 0.25, count: 48_000 * 6)
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 100) }
        let result = waveform.takeSnapshot(now: 100, droppedFrames: 0)
        XCTAssertEqual(result.lanes[0].count, 150)
    }

    func testEmptyWorkerPollsRetainLevelsAndDoNotInsertFalseSilence() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let samples = [Float](repeating: 0.25, count: 4800)
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 100) }
        let measured = waveform.takeSnapshot(now: 100.12, droppedFrames: 0)
        for poll in 1...5 {
            let betweenBuffers = waveform.takeSnapshot(now: 100.12 + Double(poll) / 30, droppedFrames: 3)
            XCTAssertEqual(betweenBuffers.rmsDB, measured.rmsDB)
            XCTAssertEqual(betweenBuffers.peakDB, measured.peakDB)
            XCTAssertEqual(betweenBuffers.lanes, measured.lanes)
            XCTAssertEqual(betweenBuffers.lastAudioTime, measured.lastAudioTime)
            XCTAssertEqual(betweenBuffers.droppedFrames, 3)
        }
    }

    func testActualSilentBuffersReplaceHeldLevelsImmediately() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let sound = [Float](repeating: 0.25, count: 4800)
        sound.withUnsafeBufferPointer { waveform.consume($0, frames: sound.count, now: 100) }
        _ = waveform.takeSnapshot(now: 100.1, droppedFrames: 0)
        let silence = [Float](repeating: 0, count: 4800)
        silence.withUnsafeBufferPointer { waveform.consume($0, frames: silence.count, now: 100.1) }
        let measured = waveform.takeSnapshot(now: 100.2, droppedFrames: 0)
        XCTAssertEqual(measured.rmsDB, -120)
        XCTAssertEqual(measured.peakDB, -120)
    }

    func testStoppedSourceExpiresLevelsAndWaveformHistory() {
        var waveform = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let samples = [Float](repeating: 0.25, count: 1600)
        samples.withUnsafeBufferPointer { waveform.consume($0, frames: samples.count, now: 100) }
        _ = waveform.takeSnapshot(now: 100.1, droppedFrames: 0)
        let expired = waveform.takeSnapshot(now: 106, droppedFrames: 0)
        XCTAssertEqual(expired.rmsDB, -120)
        XCTAssertEqual(expired.peakDB, -120)
        XCTAssertEqual(expired.lanes[0], [WaveformBin](repeating: WaveformBin(), count: 150))
    }

    func testSoundStatusHoldsAcrossShortSpeechPausesWithoutHoldingMeters() {
        var tracker = AudioSourceActivityTracker()
        var snapshot = AudioMeterSnapshot(peakDB: -30, lastAudioTime: 100)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100), .sound)
        snapshot.peakDB = -120
        snapshot.lastAudioTime = 100.1
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100.1), .sound)
        snapshot.lastAudioTime = 100.5
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100.5), .silence)
    }

    func testSoundStatusDoesNotChatterAtDetectionThreshold() {
        var tracker = AudioSourceActivityTracker()
        var snapshot = AudioMeterSnapshot(peakDB: -63, lastAudioTime: 100)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100), .silence)
        snapshot.peakDB = -59
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100), .sound)
        for step in 1...30 {
            let time = 100 + Double(step) / 30
            snapshot.peakDB = step.isMultiple(of: 2) ? -59.9 : -60.1
            snapshot.lastAudioTime = time
            XCTAssertEqual(tracker.update(snapshot, capturing: true, now: time), .sound)
        }
    }

    func testMissingSamplesBecomeWaitingNotPreviewOff() {
        var tracker = AudioSourceActivityTracker()
        let snapshot = AudioMeterSnapshot(peakDB: -30, lastAudioTime: 100)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100), .sound)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 101.01), .waiting)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 106), .waiting)
    }

    func testSoundStatusRemainsStableBetweenSlowAudioCallbacks() {
        var tracker = AudioSourceActivityTracker()
        let snapshot = AudioMeterSnapshot(peakDB: -30, lastAudioTime: 100)
        for poll in 0..<30 {
            XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100 + Double(poll) / 30), .sound)
        }
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 101.01), .waiting)
    }

    func testStoppingPreviewClearsSoundHoldBeforeRestart() {
        var tracker = AudioSourceActivityTracker()
        let sound = AudioMeterSnapshot(peakDB: -30, lastAudioTime: 100)
        XCTAssertEqual(tracker.update(sound, capturing: true, now: 100), .sound)
        XCTAssertEqual(tracker.update(sound, capturing: false, now: 100.1), .off)
        let silence = AudioMeterSnapshot(lastAudioTime: 100.2)
        XCTAssertEqual(tracker.update(silence, capturing: true, now: 100.2), .silence)
    }

    func testClippingStatusIsImmediateAndExpiresWithFreshSilentAudio() {
        var tracker = AudioSourceActivityTracker()
        var snapshot = AudioMeterSnapshot(peakDB: 0, lastAudioTime: 100, lastClipTime: 100)
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100), .clipping)
        snapshot.peakDB = -120
        snapshot.lastAudioTime = 100.5
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 100.5), .clipping)
        snapshot.lastAudioTime = 101.1
        XCTAssertEqual(tracker.update(snapshot, capturing: true, now: 101.1), .silence)
    }

    func testAudioQueuePreservesPlanarStereoAndSplitsOversizeBuffers() throws {
        let queue = try XCTUnwrap(astation_audio_queue_create(2, 2, 4))
        defer { astation_audio_queue_destroy(queue) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        input.frameLength = 4
        for index in 0..<4 {
            input.floatChannelData![0][index] = Float(index + 1)
            input.floatChannelData![1][index] = -Float(index + 1)
        }
        let start = mach_absolute_time()
        astation_audio_queue_push(queue, input.audioBufferList, 4, start, 48_000)
        var output = [Float](repeating: 0, count: 4)
        var timestamp: UInt64 = 0
        let first = output.withUnsafeMutableBufferPointer { astation_audio_queue_pop(queue, $0.baseAddress!, 2, &timestamp) }
        XCTAssertEqual(first, 2)
        XCTAssertEqual(output, [1, -1, 2, -2])
        XCTAssertEqual(timestamp, start)
        let second = output.withUnsafeMutableBufferPointer { astation_audio_queue_pop(queue, $0.baseAddress!, 2, &timestamp) }
        XCTAssertEqual(second, 2)
        XCTAssertEqual(output, [3, -3, 4, -4])
        XCTAssertGreaterThan(timestamp, start)
        XCTAssertEqual(AVAudioTime.seconds(forHostTime: timestamp) - AVAudioTime.seconds(forHostTime: start), 2.0 / 48_000, accuracy: 1e-6)
    }

    func testAudioQueuePreservesInterleavedPCM() throws {
        let queue = try XCTUnwrap(astation_audio_queue_create(2, 4, 2))
        defer { astation_audio_queue_destroy(queue) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        input.frameLength = 2
        input.floatChannelData![0].update(from: [0.1, 0.2, 0.3, 0.4], count: 4)
        astation_audio_queue_push(queue, input.audioBufferList, 2, 100, 48_000)
        var output = [Float](repeating: 0, count: 4)
        var time: UInt64 = 0
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { astation_audio_queue_pop(queue, $0.baseAddress!, 2, &time) }, 2)
        XCTAssertEqual(output, [0.1, 0.2, 0.3, 0.4])
    }

    func testQueueOverflowIsCountedAndUnreadAudioIsNotOverwritten() throws {
        let queue = try XCTUnwrap(astation_audio_queue_create(1, 2, 2))
        defer { astation_audio_queue_destroy(queue) }
        let input = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 6)!
        input.frameLength = 6
        input.floatChannelData![0].update(from: [1, 2, 3, 4, 5, 6], count: 6)
        astation_audio_queue_push(queue, input.audioBufferList, 6, 100, 48_000)
        XCTAssertEqual(astation_audio_queue_dropped_frames(queue), 2)
        var output = [Float](repeating: 0, count: 2)
        var time: UInt64 = 0
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { astation_audio_queue_pop(queue, $0.baseAddress!, 2, &time) }, 2)
        XCTAssertEqual(output, [1, 2])
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { astation_audio_queue_pop(queue, $0.baseAddress!, 2, &time) }, 2)
        XCTAssertEqual(output, [3, 4])
    }

    func testQueueRejectsWrongChannelsAndInvalidCapacity() throws {
        XCTAssertNil(astation_audio_queue_create(0, 2, 2))
        XCTAssertNil(astation_audio_queue_create(33, 2, 2))
        let queue = try XCTUnwrap(astation_audio_queue_create(2, 4, 2))
        defer { astation_audio_queue_destroy(queue) }
        let input = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 2)!
        input.frameLength = 2
        astation_audio_queue_push(queue, input.audioBufferList, 2, 100, 48_000)
        XCTAssertEqual(astation_audio_queue_dropped_frames(queue), 2)
    }
}

@MainActor
final class AudioRecordingSettingsTests: XCTestCase {
    func testMultipleSourceCardsHaveNoLargeGapOrOverlappingContents() async throws {
        let name = "astation-audio-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AudioRecordingManager(defaults: defaults, captureFactory: { _ in
            throw AudioCaptureError.microphoneFormatChanged(previous: "48000 Hz / 2 channels", current: "44100 Hz / 2 channels")
        }, microphonePermission: { true })
        var settings = manager.settings
        settings.outputMode = .system
        manager.updateSettings(settings)
        let controller = AudioRecordingViewController(manager: manager, hotkeys: HotkeyManager(defaults: defaults))
        controller.loadViewIfNeeded()
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let message = try XCTUnwrap(descendants(document).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Select sources, then start preview") })
        func checkLayout(width: CGFloat) {
            let cards = descendants(document).compactMap { $0 as? AudioSourceCardView }
            XCTAssertEqual(cards.count, 2)
            window.setContentSize(NSSize(width: width, height: 600))
            scroll.layoutSubtreeIfNeeded()
            document.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let frames = cards.map { document.convert($0.bounds, from: $0) }
            let messageFrame = document.convert(message.bounds, from: message)
            XCTAssertGreaterThanOrEqual(frames[0].minY - messageFrame.maxY, 12)
            XCTAssertLessThanOrEqual(frames[0].minY - messageFrame.maxY, 24)
            XCTAssertGreaterThanOrEqual(frames[1].minY - frames[0].maxY, 10)
            XCTAssertLessThanOrEqual(frames[1].minY - frames[0].maxY, 14)
            for (card, frame) in zip(cards, frames) {
                XCTAssertGreaterThanOrEqual(frame.height, 175)
                XCTAssertLessThanOrEqual(frame.height, 200)
                for content in descendants(card) {
                    let contentFrame = document.convert(content.bounds, from: content)
                    XCTAssertGreaterThanOrEqual(contentFrame.minY, frame.minY - 1)
                    XCTAssertLessThanOrEqual(contentFrame.maxY, frame.maxY + 1)
                    XCTAssertGreaterThanOrEqual(contentFrame.minX, frame.minX - 1)
                    XCTAssertLessThanOrEqual(contentFrame.maxX, frame.maxX + 1)
                }
            }
        }
        for width in [CGFloat(560), 740, 510, 740] {
            settings.outputMode = .none
            manager.updateSettings(settings)
            settings.outputMode = .system
            manager.updateSettings(settings)
            checkLayout(width: width)
        }
        func saveSnapshots(state: String) throws {
            guard let path = ProcessInfo.processInfo.environment["ASTATION_AUDIO_UI_SNAPSHOT"] else { return }
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                scroll.appearance = NSAppearance(named: name)
                let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(path)-\(state)-\(suffix).png"))
            }
        }
        try saveSnapshots(state: "two-sources")
        manager.startPreview()
        for _ in 0..<100 {
            if manager.state == .failed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.state, .failed)
        XCTAssertEqual(message.textColor, .systemRed)
        XCTAssertTrue(message.stringValue.contains("48000 Hz"))
        for width in [CGFloat(510), 740] { checkLayout(width: width) }
        try saveSnapshots(state: "two-sources-error")
    }

    func testSavedLegacyDefaultFolderMigratesAndKeepsOtherSettings() throws {
        let name = "astation-audio-folder-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = AudioRecordingSettings()
        saved.folderPath = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Astation Recordings", isDirectory: true).path
        saved.microphoneUID = "selected-aggregate-device"
        saved.outputMode = .system
        saved.format = .wav
        saved.splitMinutes = 60
        defaults.set(try JSONEncoder().encode(saved), forKey: AudioRecordingManager.defaultsKey)
        let manager = AudioRecordingManager(defaults: defaults)
        saved.folderPath = AudioRecordingSettings().folderPath
        XCTAssertEqual(manager.settings, saved)
        let persisted = try JSONDecoder().decode(AudioRecordingSettings.self,
            from: XCTUnwrap(defaults.data(forKey: AudioRecordingManager.defaultsKey)))
        XCTAssertEqual(persisted, saved)
        XCTAssertEqual(AudioRecordingManager(defaults: defaults).settings, saved)
    }

    func testLoadingSettingsPreservesCustomFolder() throws {
        let name = "astation-audio-custom-folder-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = AudioRecordingSettings()
        saved.folderPath = "/Volumes/Audio/Custom Recordings"
        defaults.set(try JSONEncoder().encode(saved), forKey: AudioRecordingManager.defaultsKey)
        XCTAssertEqual(AudioRecordingManager(defaults: defaults).settings, saved)
    }

    func testExplicitFolderChoiceIsPreservedOnRelaunch() {
        let name = "astation-audio-explicit-folder-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AudioRecordingManager(defaults: defaults)
        var settings = manager.settings
        settings.folderPath = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Astation Recordings", isDirectory: true).path
        manager.updateSettings(settings)
        XCTAssertEqual(AudioRecordingManager(defaults: defaults).settings, settings)
    }

    func testSourceCardLabelsAndLevelPositionStayStableBetweenBuffers() throws {
        let source = AudioSourceSelection(id: "microphone", title: "Test microphone", kind: .microphone(nil))
        let card = AudioSourceCardView(source: source, icon: nil)
        card.frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let status = try XCTUnwrap(fields(in: card).first { $0.stringValue == "Preview off" })
        let levels = try XCTUnwrap(fields(in: card).first { $0.stringValue.hasPrefix("RMS ") })
        var accumulator = AudioWaveformAccumulator(channels: 1, sampleRate: 48_000)
        let samples = [Float](repeating: 0.25, count: 4800)
        samples.withUnsafeBufferPointer { accumulator.consume($0, frames: samples.count, now: 100) }
        card.update(accumulator.takeSnapshot(now: 100.12, droppedFrames: 0), capturing: true, message: nil, now: 100.12)
        card.layoutSubtreeIfNeeded()
        let measuredText = levels.stringValue
        let measuredFrame = levels.frame
        func saveSnapshot(_ state: String) throws {
            guard let path = ProcessInfo.processInfo.environment["ASTATION_AUDIO_UI_SNAPSHOT"] else { return }
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                card.appearance = NSAppearance(named: name)
                let rep = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                card.cacheDisplay(in: card.bounds, to: rep)
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "\(path)-card-\(state)-\(suffix).png"))
            }
        }
        try saveSnapshot("sound")
        for poll in 1...5 {
            let time = 100.12 + Double(poll) / 30
            card.update(accumulator.takeSnapshot(now: time, droppedFrames: 0), capturing: true, message: nil, now: time)
            card.layoutSubtreeIfNeeded()
            XCTAssertEqual(status.stringValue, "Sound detected")
            XCTAssertEqual(levels.stringValue, measuredText)
            XCTAssertEqual(levels.frame, measuredFrame)
        }
        card.update(AudioMeterSnapshot(lastAudioTime: 101), capturing: true, message: nil, now: 101)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(status.stringValue, "Listening: silence")
        XCTAssertEqual(levels.stringValue, "RMS --   PEAK -- dBFS")
        XCTAssertEqual(levels.frame, measuredFrame)
        try saveSnapshot("silence")
        card.update(AudioMeterSnapshot(), capturing: true, message: "Capture unavailable", now: 101.1)
        XCTAssertEqual(status.stringValue, "Capture unavailable")
        card.update(AudioMeterSnapshot(), capturing: false, message: nil, now: 101.2)
        XCTAssertEqual(status.stringValue, "Preview off")
    }

    func testSelectionsAndFileOptionsSurviveRelaunchWithoutStartingCapture() throws {
        let name = "astation-audio-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AudioRecordingManager(defaults: defaults)
        var config = manager.settings
        config.microphoneEnabled = false
        config.outputMode = .applications
        config.applicationBundleIDs = ["test.browser", "test.player"]
        config.format = .wav
        manager.updateSettings(config)
        let restored = AudioRecordingManager(defaults: defaults)
        XCTAssertEqual(restored.settings, config)
        XCTAssertEqual(restored.selectedSources.map(\.id), config.applicationBundleIDs)
        XCTAssertEqual(restored.state, .idle)
        XCTAssertFalse(restored.isCapturing)
    }

    func testMalformedSettingsDoNotCrashStartup() {
        let name = "astation-audio-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: AudioRecordingManager.defaultsKey)
        let manager = AudioRecordingManager(defaults: defaults)
        XCTAssertEqual(manager.settings, AudioRecordingSettings())
    }

    func testSettingsViewLoadsWithoutRequestingAudioPermission() {
        let name = "astation-audio-view-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AudioRecordingManager(defaults: defaults)
        let controller = AudioRecordingViewController(manager: manager, hotkeys: HotkeyManager(defaults: defaults))
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.view is NSScrollView)
        XCTAssertEqual(manager.state, .idle)
        if let path = ProcessInfo.processInfo.environment["ASTATION_AUDIO_UI_SNAPSHOT"] {
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                controller.view.appearance = NSAppearance(named: name)
                controller.view.displayIfNeeded()
                let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)!
                controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(suffix).png"))
            }
        }
        controller.setPageVisible(false)
    }
}
