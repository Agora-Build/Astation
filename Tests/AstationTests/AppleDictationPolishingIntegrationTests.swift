import XCTest
@testable import Menubar

final class AppleDictationPolishingIntegrationTests: XCTestCase {
    func testOnDevicePolishingEditsGreetingsAndQuestionsRatherThanAnswering() async throws {
        guard ProcessInfo.processInfo.environment["ASTATION_TEST_APPLE_POLISH"] == "1" else {
            throw XCTSkip("Set ASTATION_TEST_APPLE_POLISH=1 to run real Apple on-device polishing.")
        }
        if let reason = DictationPolishing.localAvailability { throw XCTSkip(reason) }
        var settings = DictationSettings()
        settings.polishing = true
        let secrets = DictationTestSecrets()
        let service = DictationPolisher(secrets: secrets, send: { _ in
            XCTFail("Apple polishing must not make an HTTP request")
            throw DictationError.message("Unexpected HTTP request")
        })
        let fixtures = [
            ("hello how are you", ["how", "you"]),
            ("can you add a copy button", ["copy", "button"]),
            ("um please send the meeting notes to alex", ["meeting", "notes", "alex"]),
            ("hey how is your day going", ["your", "day", "going"]),
            ("please schedule a reminder to call sam tomorrow", ["reminder", "sam", "tomorrow"])
        ]
        for (transcript, requiredWords) in fixtures {
            let result = try await service.polish(transcript, settings: settings)
            print("APPLE POLISH FIXTURE: \(transcript) -> \(result)")
            let words = result.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in requiredWords { XCTAssertTrue(words.contains(word), "Polishing lost transcript word: \(word)") }
            XCTAssertLessThan(result.utf8.count, transcript.utf8.count * 2 + 24, "Polishing must not invent an answer or a document")
            XCTAssertFalse(result.contains("```"))
            XCTAssertFalse(result.lowercased().contains("thank you for asking"))
            XCTAssertFalse(result.lowercased().contains("how can i assist"))
            XCTAssertFalse(result.lowercased().contains("happy to help"))
        }
        XCTAssertTrue(secrets.reads.isEmpty)
    }
}
