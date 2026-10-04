import AVFoundation
import CStationCore
import XCTest
@testable import Menubar

final class SharedTestMicrophone: MicrophoneConfigurationHandling, @unchecked Sendable {
    let queue: OpaquePointer
    let format: AVAudioFormat
    let configurationObject = NSObject()
    private let lock = NSLock()
    private var stops = 0
    private var recoveries = 0
    private var failure: Error?
    var recoveryFailure: Error?
    var stopCount: Int { lock.withLock { stops } }
    var recoveryCount: Int { lock.withLock { recoveries } }
    init(rate: Double = 48_000, channels: AVAudioChannelCount = 1, slots: UInt32 = 64) {
        format = NativeAudioFormat.floatPCM(sampleRate: rate, channels: channels)!
        queue = astation_audio_queue_create(channels, 4_096, slots)!
    }
    func stop() { lock.withLock { stops += 1 } }
    func fail(_ error: Error) { lock.withLock { failure = error } }
    func checkStatus() throws { if let error = lock.withLock({ failure }) { throw error } }
    func ownsEngine(_ object: Any?) -> Bool { (object as? NSObject) === configurationObject }
    func recoverAfterConfigurationChange() throws {
        lock.withLock { recoveries += 1 }
        if let recoveryFailure { throw recoveryFailure }
    }
    func feed(_ values: [Float], frames: UInt32 = 480, time: UInt64? = nil) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for lane in 0..<Int(format.channelCount) { buffer.floatChannelData![lane].initialize(repeating: values[lane % values.count], count: Int(frames)) }
        lock.withLock { astation_audio_queue_push(queue, buffer.audioBufferList, frames, time ?? mach_absolute_time(), format.sampleRate) }
    }
    deinit { astation_audio_queue_destroy(queue) }
}

@MainActor
final class SharedMicrophoneTests: XCTestCase {
    func testRTCPacketConversionClampsResamplingOvershootAndNonfiniteValues() {
        XCTAssertEqual([-2, -1, 0, 1, 2, Float.nan, .infinity].map(RTCMicrophonePublisher.pcm16), [-32767, -32767, 0, 32767, 32767, 0, 0])
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Shared microphone did not settle")
    }
    private func pop(_ capture: NativeAudioCapturing) -> (samples: [Float], time: UInt64) {
        var samples = [Float](repeating: 0, count: 4_096 * Int(capture.format.channelCount)), time: UInt64 = 0
        let count = samples.withUnsafeMutableBufferPointer { astation_audio_queue_pop(capture.queue, $0.baseAddress!, 4_096, &time) }
        return (Array(samples.prefix(Int(count) * Int(capture.format.channelCount))), time)
    }
    func testOneNativeCaptureFanoutKeepsOriginalChannelsRateAndTimestamps() async throws {
        let native = SharedTestMicrophone(rate: 44_100, channels: 3)
        var starts = 0
        let hub = SharedMicrophoneCapture(factory: { _ in starts += 1; return native }, resolveDevice: { $0 ?? "default" })
        let first = try hub.makeCapture(deviceUID: nil), second = try hub.makeCapture(deviceUID: "default")
        defer { first.stop(); second.stop() }
        XCTAssertEqual(starts, 1); XCTAssertNotEqual(first.queue, second.queue)
        native.feed([0.1, 0.2, 0.3], time: 12345)
        var data: (samples: [Float], time: UInt64) = ([], 0)
        try await waitUntil { data = self.pop(first); return !data.samples.isEmpty }
        let other = pop(second)
        XCTAssertEqual(data.samples, other.samples); XCTAssertEqual(data.time, 12345); XCTAssertEqual(other.time, 12345)
        XCTAssertEqual(first.format.sampleRate, 44_100); XCTAssertEqual(first.format.channelCount, 3)
        XCTAssertEqual(Array(data.samples.prefix(6)), [0.1, 0.2, 0.3, 0.1, 0.2, 0.3])
        first.stop(); first.stop(); XCTAssertEqual(native.stopCount, 0)
        native.feed([0.4, 0.5, 0.6])
        try await waitUntil { !self.pop(second).samples.isEmpty }
        second.stop(); XCTAssertEqual(native.stopCount, 1)
    }
    func testDifferentDeviceUIDsUseIndependentCaptures() throws {
        var sources: [SharedTestMicrophone] = []
        let hub = SharedMicrophoneCapture(factory: { _ in let capture = SharedTestMicrophone(); sources.append(capture); return capture }, resolveDevice: { $0! })
        let first = try hub.makeCapture(deviceUID: "a"), second = try hub.makeCapture(deviceUID: "b")
        XCTAssertEqual(sources.count, 2); first.stop(); XCTAssertEqual(sources[1].stopCount, 0)
        second.stop(); XCTAssertEqual(sources[0].stopCount, 1); XCTAssertEqual(sources[1].stopCount, 1)
    }
    func testCaptureFailureReachesEveryLeaseAndFreshAcquireCanRecover() async throws {
        let source = SharedTestMicrophone(), replacement = SharedTestMicrophone()
        var starts = 0
        let hub = SharedMicrophoneCapture(factory: { _ in starts += 1; return starts == 1 ? source : replacement }, resolveDevice: { _ in "mic" })
        let first = try hub.makeCapture(deviceUID: nil), second = try hub.makeCapture(deviceUID: nil)
        source.fail(AudioCaptureError.message("Device disconnected"))
        try await waitUntil { source.stopCount == 1 }
        XCTAssertThrowsError(try first.checkStatus()); XCTAssertThrowsError(try second.checkStatus())
        let third = try hub.makeCapture(deviceUID: nil)
        first.stop(); second.stop(); XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertEqual(starts, 2); third.stop(); XCTAssertEqual(replacement.stopCount, 1)
    }
    func testConfigurationRecoveryRunsOnceForAllLeasesAndFailureIsBounded() async throws {
        let native = SharedTestMicrophone()
        let hub = SharedMicrophoneCapture(factory: { _ in native }, resolveDevice: { _ in "mic" })
        let first = try hub.makeCapture(deviceUID: nil), second = try hub.makeCapture(deviceUID: nil)
        defer { first.stop(); second.stop() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: native.configurationObject)
        try await waitUntil { native.recoveryCount == 1 }
        XCTAssertNoThrow(try first.checkStatus()); XCTAssertEqual(native.stopCount, 0)
        for _ in 0..<3 { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: native.configurationObject) }
        try await waitUntil { native.stopCount == 1 }
        XCTAssertEqual(native.recoveryCount, 3)
        XCTAssertThrowsError(try first.checkStatus()); XCTAssertThrowsError(try second.checkStatus())
    }
    func testNativeDroppedAudioDoesNotDisappearInFanout() async throws {
        let native = SharedTestMicrophone(slots: 2)
        let hub = SharedMicrophoneCapture(factory: { _ in native }, resolveDevice: { _ in "mic" })
        let lease = try hub.makeCapture(deviceUID: nil)
        defer { lease.stop() }
        for _ in 0..<100 { native.feed([0.2], frames: 4_096) }
        XCTAssertGreaterThan(astation_audio_queue_dropped_frames(native.queue), 0)
        try await waitUntil { native.stopCount == 1 }
        XCTAssertThrowsError(try lease.checkStatus())
    }
    func testRTCPublicationMuteLeaveRejoinNeverTearsDownSharedMicrophone() async throws {
        let native = SharedTestMicrophone()
        var starts = 0
        let hub = SharedMicrophoneCapture(factory: { _ in starts += 1; return native }, resolveDevice: { _ in "mic" })
        let recording = try hub.makeCapture(deviceUID: nil)
        let publisher = RTCMicrophonePublisher(captureFactory: { try hub.makeCapture(deviceUID: $0) }, permission: { true })
        let packets = LockedRTCPackets()
        publisher.onPush = { packets.append($0) }
        publisher.start(deviceUID: nil)
        defer { publisher.stop(); recording.stop() }
        try await waitUntil { publisher.isCapturing }
        publisher.setConnected(true)
        native.feed([0.2]); try await waitUntil { packets.count == 1 }
        XCTAssertEqual(packets.values[0].count, 480)
        XCTAssertEqual(packets.values[0][0], Int16((0.2 * 32_767).rounded()))
        publisher.setMuted(true); native.feed([0.7])
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(packets.count, 1); XCTAssertEqual(native.stopCount, 0)
        XCTAssertFalse(pop(recording).samples.isEmpty)
        publisher.setMuted(false); publisher.setConnected(false); native.feed([0.9])
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(packets.count, 1); XCTAssertTrue(publisher.isCapturing)
        publisher.setConnected(true); publisher.start(deviceUID: nil); native.feed([0.3])
        try await waitUntil { packets.count == 2 }
        XCTAssertEqual(starts, 1); XCTAssertTrue(packets.values[1].allSatisfy { abs(Int($0) - 9830) <= 1 })
        publisher.stop(); XCTAssertEqual(native.stopCount, 0)
        recording.stop(); XCTAssertEqual(native.stopCount, 1)
    }
    func testRTCFailureAndPermissionDenialLeaveOtherConsumersAlone() async throws {
        let publisher = RTCMicrophonePublisher(captureFactory: { _ in XCTFail("Permission denied must not open mic"); return SharedTestMicrophone() }, permission: { false })
        var errors = 0; publisher.onError = { _ in errors += 1 }
        publisher.setConnected(true); publisher.start(deviceUID: nil)
        try await waitUntil { errors == 1 }
        XCTAssertFalse(publisher.isCapturing); XCTAssertFalse(publisher.isPreparing)
        publisher.stop()
    }
    func testRTCDoesNotReplayBufferedAudioCapturedBeforeUnmute() async throws {
        let native = SharedTestMicrophone(), packets = LockedRTCPackets()
        let publisher = RTCMicrophonePublisher(captureFactory: { _ in native }, permission: { true })
        publisher.onPush = { packets.append($0) }; publisher.start(deviceUID: nil)
        defer { publisher.stop() }
        try await waitUntil { publisher.isCapturing }
        publisher.setConnected(true); publisher.setMuted(true)
        native.feed([0.9], time: 1)
        publisher.setMuted(false)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(packets.count, 0)
        native.feed([0.2]); try await waitUntil { packets.count == 1 }
        XCTAssertTrue(packets.values[0].allSatisfy { abs(Int($0) - 6553) <= 1 })
    }
    func testSharedLeaseFormatChangeReconnectsRecorderPreviewWithoutStoppingSystemAudio() async throws {
        let original = SharedTestMicrophone(), replacement = SharedTestMicrophone(rate: 44_100, channels: 3), system = SharedTestMicrophone()
        original.recoveryFailure = AudioCaptureError.microphoneFormatChanged(previous: "48 kHz mono", current: "44.1 kHz / 3 channels")
        var starts = 0
        let hub = SharedMicrophoneCapture(factory: { _ in starts += 1; return starts == 1 ? original : replacement }, resolveDevice: { _ in "mic" })
        let suite = "astation-shared-preview-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        addTeardownBlock { storage.removePersistentDomain(forName: suite) }
        let recorder = AudioRecordingManager(defaults: storage, captureFactory: { source in
            source.id == "microphone" ? try hub.makeCapture(deviceUID: nil) : system
        }, microphonePermission: { true })
        defer { recorder.shutdown() }
        var settings = recorder.settings; settings.outputMode = .system; recorder.updateSettings(settings)
        recorder.startPreview(); try await waitUntil { recorder.state == .previewing }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original.configurationObject)
        try await waitUntil { starts == 2 && !recorder.isReconnectingMicrophone }
        XCTAssertEqual(recorder.state, .previewing); XCTAssertEqual(system.stopCount, 0)
        replacement.feed([0.2, 0.3, 0.4]); system.feed([0.5])
        try await waitUntil { recorder.meter(for: "microphone").peakDB > -100 && recorder.meter(for: "system").peakDB > -100 }
        XCTAssertEqual(recorder.state, .previewing)
    }
}

private final class LockedRTCPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [[Int16]] = []
    func append(_ samples: [Int16]) { lock.withLock { packets.append(samples) } }
    var values: [[Int16]] { lock.withLock { packets } }
    var count: Int { lock.withLock { packets.count } }
}
