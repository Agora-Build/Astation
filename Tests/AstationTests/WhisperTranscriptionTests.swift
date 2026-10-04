import XCTest
import Foundation
@testable import Menubar

private actor WhisperTestDecoder: WhisperWindowDecoding {
    var directory: URL?
    var languages: [String] = []
    var sampleCounts: [Int] = []
    var cancelled = false
    func start(directory: URL) { self.directory = directory }
    func decode(_ samples: [Float], language: String) -> String {
        languages.append(language); sampleCounts.append(samples.count)
        return "recognized speech"
    }
    func cancel() { cancelled = true }
}

private final class WhisperTestCaptions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranscriptSegment] = []
    func append(_ value: TranscriptSegment) { lock.withLock { values.append(value) } }
    var segments: [TranscriptSegment] { lock.withLock { values } }
}

final class WhisperTranscriptionTests: XCTestCase {
    func testModelProfilesHaveSeparatePinnedCompleteManifests() throws {
        XCTAssertEqual(LocalTranscriptionModel.allCases.count, 3)
        var ids = Set<String>()
        for profile in LocalTranscriptionModel.allCases {
            let manifest = try TranscriptionModelManifest.bundled(for: profile)
            try manifest.validate()
            XCTAssertEqual(manifest.id, profile.id); XCTAssertTrue(ids.insert(profile.id).inserted)
            XCTAssertFalse(manifest.revision.isEmpty)
            if profile != .parakeet {
                XCTAssertTrue(manifest.files.contains { $0.path == "tokenizer/tokenizer.json" })
                XCTAssertTrue(manifest.files.contains { $0.path.hasPrefix("TextDecoder.mlmodelc/") })
            }
        }
        let turbo = try TranscriptionModelManifest.bundled(for: .whisperTurbo)
        let large = try TranscriptionModelManifest.bundled(for: .whisperLarge)
        XCTAssertLessThan(turbo.totalBytes, large.totalBytes)
        XCTAssertTrue(turbo.files.filter { $0.path.hasPrefix("TextDecoder") }.allSatisfy { $0.url.absoluteString.contains("v20240930_turbo") })
        XCTAssertTrue(large.files.filter { $0.path.hasPrefix("TextDecoder") }.allSatisfy { !$0.url.absoluteString.contains("v20240930") })
    }
    func testSpeechWindowsIgnoreSilenceKeepPrerollAndFinalOffsets() {
        var planner = SpeechWindowBuffer()
        XCTAssertTrue(planner.append([Float](repeating: 0, count: 32_000)).isEmpty)
        XCTAssertNil(planner.finish())
        XCTAssertTrue(planner.append([Float](repeating: 0.2, count: 8_000)).isEmpty)
        let windows = planner.append([Float](repeating: 0, count: 12_800))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].offset, 1.8, accuracy: 0.001)
        XCTAssertEqual(windows[0].samples.count, 24_000); XCTAssertTrue(windows[0].isFinal)
        XCTAssertNil(planner.finish())
    }
    func testRollingPartialsReuseIDAndMaximumWindowsRemainBounded() {
        var planner = SpeechWindowBuffer(maximumSeconds: 5, partialSeconds: 2)
        let windows = planner.append([Float](repeating: 0.2, count: 10 * 16_000))
        XCTAssertEqual(windows.count, 6)
        XCTAssertEqual(windows.map(\.isFinal), [false, false, true, false, false, true])
        XCTAssertEqual(Set(windows.prefix(3).map(\.id)).count, 1)
        XCTAssertNotEqual(windows[0].id, windows[3].id)
        XCTAssertEqual(windows[3].offset, 5, accuracy: 0.001)
        XCTAssertTrue(windows.allSatisfy { $0.samples.count <= 5 * 16_000 })
        XCTAssertNil(planner.finish())
    }
    func testWhisperAdapterEmitsPartialThenFinalAndForwardsLanguageAndSource() async throws {
        let decoder = WhisperTestDecoder(), captions = WhisperTestCaptions()
        var settings = TranscriptionSettings(); settings.localModel = .whisperTurbo
        settings.sourceID = "selected.app"; settings.language = "fr-FR"
        let directory = URL(fileURLWithPath: "/tmp/whisper-test-only")
        let engine = LocalWhisperTranscriber(directory: directory, settings: settings, decoder: decoder)
        try await engine.start { captions.append($0) }
        try await engine.consume([Float](repeating: 0.1, count: 32_000))
        try await engine.finish(); await engine.cancel()
        XCTAssertEqual(captions.segments.count, 2)
        XCTAssertEqual(captions.segments.map(\.isFinal), [false, true])
        XCTAssertEqual(Set(captions.segments.map(\.id)).count, 1)
        XCTAssertTrue(captions.segments.allSatisfy { $0.sourceID == "selected.app" && $0.language == "fr-FR" })
        let languages = await decoder.languages, installed = await decoder.directory, cancelled = await decoder.cancelled
        XCTAssertEqual(languages, ["fr-FR", "fr-FR"]); XCTAssertEqual(installed, directory); XCTAssertTrue(cancelled)
    }
    func testIrregularPacketsDoNotExceedMaximumWindowAndNonfiniteAudioIsNotSpeech() {
        var planner = SpeechWindowBuffer(maximumSeconds: 1, partialSeconds: nil)
        XCTAssertTrue(planner.append([Float](repeating: .nan, count: 3_200)).isEmpty)
        var windows: [SpeechWindowBuffer.Window] = []
        for _ in 0..<110 { windows += planner.append([Float](repeating: 0.2, count: 319)) }
        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.samples.count == 16_000 })
        XCTAssertNotNil(planner.finish())
    }
}
