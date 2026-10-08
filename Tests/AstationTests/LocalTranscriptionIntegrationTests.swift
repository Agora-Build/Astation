import AVFoundation
import XCTest
@testable import Menubar

private final class LocalCaptionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = TranscriptBuffer()
    private var captions = FloatingCaptionBuffer()
    private var receiptTime: TimeInterval = 100
    func update(_ segment: TranscriptSegment) {
        lock.withLock { buffer.update(segment); captions.update(segment, now: receiptTime) }
    }
    func advanceClock(to time: TimeInterval) { lock.withLock { receiptTime = time; captions.expire(now: time) } }
    var segments: [TranscriptSegment] { lock.withLock { buffer.segments } }
    var visibleSegments: [TranscriptSegment] { lock.withLock { captions.lines.map(\.segment) } }
}

final class LocalTranscriptionIntegrationTests: XCTestCase {
    func testRealParakeetRepeatedSpeechAppearsAgainAfterTwentySecondExpiry() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ASTATION_TEST_MODEL_ROOT"], let speech = environment["ASTATION_TEST_SPEECH_FILE"] else {
            throw XCTSkip("Set model and fixture paths to run real repeated-utterance inference.")
        }
        let store = TranscriptionModelStore(root: URL(fileURLWithPath: root, isDirectory: true))
        let engine = LocalParakeetTranscriber(directory: try await store.verifiedDirectory(), sourceID: "fixture")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: speech), commonFormat: .pcmFormatFloat32, interleaved: true)
        let converter = TranscriptionAudioConverter()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600))
        var chunks: [[Float]] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            let pcm = TranscriptionPCM(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)),
                sampleRate: buffer.format.sampleRate, channels: Int(buffer.format.channelCount))
            chunks.append(try converter.convert(pcm))
        }
        chunks.append(try converter.finish())
        let results = LocalCaptionResults()
        do {
            try await engine.start { results.update($0) }
            for chunk in chunks { try await engine.consume(chunk) }
            // Silence, supplied in real streaming-sized chunks, confirms the first EOU.
            for _ in 0..<20 { try await engine.consume([Float](repeating: 0, count: 1_600)) }
            let firstIDs = Set(results.visibleSegments.map(\.id))
            XCTAssertFalse(firstIDs.isEmpty)
            XCTAssertTrue(results.visibleSegments.allSatisfy(\.isFinal))
            results.advanceClock(to: 121)
            XCTAssertTrue(results.visibleSegments.isEmpty)
            for chunk in chunks { try await engine.consume(chunk) }
            for _ in 0..<20 { try await engine.consume([Float](repeating: 0, count: 1_600)) }
            try await engine.finish(); await engine.cancel()
            XCTAssertFalse(results.visibleSegments.isEmpty)
            XCTAssertTrue(Set(results.visibleSegments.map(\.id)).isDisjoint(with: firstIDs))
            let text = results.visibleSegments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("ask not what your country can do for you"), text)
        } catch { await engine.cancel(); throw error }
    }
    func testRealWhisperProfilesTranscribePublicFixtureOffline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ASTATION_TEST_MODEL_ROOT"], let speech = environment["ASTATION_TEST_SPEECH_FILE"],
              environment["ASTATION_TEST_WHISPER"] == "1" else {
            throw XCTSkip("Set model/fixture paths and ASTATION_TEST_WHISPER=1 to run both large Whisper models.")
        }
        let store = TranscriptionModelStore(root: URL(fileURLWithPath: root, isDirectory: true))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: speech), commonFormat: .pcmFormatFloat32, interleaved: true)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let count = Int(input.frameLength) * Int(input.format.channelCount)
        let pcm = TranscriptionPCM(samples: Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: count)),
            sampleRate: input.format.sampleRate, channels: Int(input.format.channelCount))
        let converter = TranscriptionAudioConverter()
        var audio = try converter.convert(pcm)
        audio += try converter.finish(); audio += [Float](repeating: 0, count: 12_800)
        // Sequential profiles avoid loading two full large-v3 instances at once.
        for profile in [LocalTranscriptionModel.whisperTurbo, .whisperLarge] {
            var settings = TranscriptionSettings(); settings.localModel = profile; settings.sourceID = "fixture"
            let engine = LocalWhisperTranscriber(directory: try await store.verifiedDirectory(for: profile), settings: settings)
            let results = LocalCaptionResults()
            do {
                try await engine.start { results.update($0) }
                try await engine.consume(audio); try await engine.finish(); await engine.cancel()
            } catch { await engine.cancel(); throw error }
            XCTAssertFalse(results.segments.isEmpty)
            XCTAssertTrue(results.segments.allSatisfy { $0.sourceID == "fixture" && $0.isFinal })
            let text = results.segments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("ask not what your country can do for you"), "Unexpected \(profile) transcript: \(text)")
        }
    }
    /// Explicit file-only opt-in: never downloads models, captures devices, or calls Agora.
    func testRealLocalEnginesTranscribeConcurrentlyWithoutSourceCollisions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ASTATION_TEST_MODEL_ROOT"],
              let speech = environment["ASTATION_TEST_SPEECH_FILE"] else {
            throw XCTSkip("Set ASTATION_TEST_MODEL_ROOT and ASTATION_TEST_SPEECH_FILE to run local multi-source inference.")
        }
        let store = TranscriptionModelStore(root: URL(fileURLWithPath: root, isDirectory: true))
        let directory = try await store.verifiedDirectory()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: speech), commonFormat: .pcmFormatFloat32, interleaved: true)
        let converter = TranscriptionAudioConverter()
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600)!
        var chunks: [[Float]] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            let pcm = TranscriptionPCM(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)),
                                       sampleRate: buffer.format.sampleRate, channels: Int(buffer.format.channelCount))
            chunks.append(try converter.convert(pcm))
        }
        chunks.append(try converter.finish())
        chunks.append([Float](repeating: 0, count: 32_000))
        let input = chunks, results = LocalCaptionResults(), sourceIDs = ["microphone", "system"]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in sourceIDs {
                group.addTask {
                    let engine = LocalParakeetTranscriber(directory: directory, sourceID: id)
                    do {
                        try await engine.start { results.update($0) }
                        for chunk in input {
                            try Task.checkCancellation()
                            try await engine.consume(chunk)
                        }
                        try await engine.finish()
                        await engine.cancel()
                    } catch { await engine.cancel(); throw error }
                }
            }
            while let _ = try await group.next() {}
        }
        let segments = results.segments
        XCTAssertEqual(Set(segments.map(\.sourceID)), Set(sourceIDs))
        for id in sourceIDs {
            let sourceSegments = segments.filter { $0.sourceID == id }
            XCTAssertFalse(sourceSegments.isEmpty)
            XCTAssertTrue(sourceSegments.allSatisfy(\.isFinal))
            let text = sourceSegments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("ask not what your country can do for you"), "Unexpected \(id) transcript: \(text)")
        }
    }
}
