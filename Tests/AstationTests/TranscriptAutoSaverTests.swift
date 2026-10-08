import XCTest
import Foundation
@testable import Menubar

final class TranscriptAutoSaverTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astation-transcript-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func segment(_ id: String = "one", text: String = "hello\nworld", final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(id: id, sourceID: "microphone", language: "en-US", text: text, isFinal: final, offset: 1.5)
    }
    func testPartialHistoryFinalTextPermissionsAndNoKeysInMetadata() throws {
        var settings = TranscriptionSettings(); settings.provider = .custom
        settings.customEndpoint = "https://speech.example.test/v1/audio/transcriptions"
        let saver = try TranscriptAutoSaver(root: folder(), settings: settings, startedAt: Date()) { _ in XCTFail("Unexpected save error") }
        saver.append(segment(text: "hello", final: false))
        saver.append(segment()); saver.append(segment())
        saver.append(segment(text: "late partial", final: false))
        saver.append(segment("two", text: " "))
        saver.finish()
        let text = try String(contentsOf: saver.folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertEqual(text, "[00:01 microphone en-US final] hello\nworld\n")
        let events = try String(contentsOf: saver.folder.appendingPathComponent("transcript.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(events.count, 2)
        let decoded = try events.map { try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8)) }
        XCTAssertFalse(decoded[0].isFinal); XCTAssertTrue(decoded[1].isFinal)
        let metadata = try String(contentsOf: saver.folder.appendingPathComponent("session.json"), encoding: .utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        XCTAssertEqual((object["settings"] as? [String: Any])?["customEndpoint"] as? String, settings.customEndpoint)
        XCTAssertFalse(metadata.lowercased().contains("apikey"))
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: saver.folder.path)[.posixPermissions] as? Int, 0o700)
        for name in ["transcript.txt", "transcript.jsonl", "session.json"] {
            XCTAssertEqual(try fm.attributesOfItem(atPath: saver.folder.appendingPathComponent(name).path)[.posixPermissions] as? Int, 0o600)
        }
        saver.append(segment("late", text: "after close")); saver.flush()
        XCTAssertEqual(try String(contentsOf: saver.folder.appendingPathComponent("transcript.txt"), encoding: .utf8), text)
    }
    func testFullHistorySurvivesUIBufferLimitAndSessionsAreDistinct() throws {
        let root = try folder()
        let saver = try TranscriptAutoSaver(root: root, settings: TranscriptionSettings(), startedAt: Date()) { _ in XCTFail("Unexpected save error") }
        var buffer = TranscriptBuffer()
        for index in 0..<2_010 {
            let value = segment(String(index), text: "line \(index)")
            buffer.update(value); saver.append(value)
        }
        saver.finish()
        XCTAssertTrue(buffer.wasTruncated); XCTAssertEqual(buffer.segments.count, 2_000)
        let text = try String(contentsOf: saver.folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2_010)
        XCTAssertTrue(text.contains("line 0\n")); XCTAssertTrue(text.contains("line 2009\n"))
        let next = try TranscriptAutoSaver(root: root, settings: TranscriptionSettings(), startedAt: Date()) { _ in }
        XCTAssertNotEqual(saver.folder, next.folder); next.finish()
    }
    func testUnwritableDestinationReportsCreationFailure() throws {
        let root = try folder().appendingPathComponent("not-a-folder")
        try Data().write(to: root)
        XCTAssertThrowsError(try TranscriptAutoSaver(root: root, settings: TranscriptionSettings(), startedAt: Date()) { _ in })
    }
}
