import XCTest
@testable import Menubar

final class DictationSettingsTests: XCTestCase {
    func testOutputCombinationsRoundTripIndependently() throws {
        for typing in [false, true] {
            for atem in [false, true] {
                var settings = DictationSettings()
                settings.typeInActiveTextField = typing; settings.sendToAtem = atem
                let data = try JSONEncoder().encode(settings)
                XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: data), settings)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertNil(object["destination"])
                XCTAssertEqual(object["typeInActiveTextField"] as? Bool, typing)
                XCTAssertEqual(object["sendToAtem"] as? Bool, atem)
            }
        }
    }

    func testLegacyDestinationMigratesWithoutEnablingAnotherOutput() throws {
        for (destination, typing, atem) in [("captions", false, false), ("activeText", true, false), ("atem", false, true)] {
            var original = DictationSettings()
            original.polishing = true; original.provider = .custom
            original.customEndpoint = "https://polish.example.test/v1/chat/completions"
            original.customModel = "test-editor"; original.consentEndpoint = original.endpoint
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            legacy.removeValue(forKey: "typeInActiveTextField"); legacy.removeValue(forKey: "sendToAtem")
            legacy["destination"] = destination
            let migrated = try JSONDecoder().decode(DictationSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
            original.typeInActiveTextField = typing; original.sendToAtem = atem
            XCTAssertEqual(migrated, original)
            XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(migrated)), original)
        }
    }

    func testNewOutputFlagsTakePrecedenceOverLegacyDestination() throws {
        let data = Data(#"{"destination":"atem","typeInActiveTextField":false,"sendToAtem":false}"#.utf8)
        let settings = try JSONDecoder().decode(DictationSettings.self, from: data)
        XCTAssertFalse(settings.typeInActiveTextField); XCTAssertFalse(settings.sendToAtem)
    }

    func testMissingSettingsUseActiveTextDefaultWithoutEnablingAtem() throws {
        XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8)), DictationSettings())
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"typeInActiveTextField":false}"#.utf8))
        XCTAssertFalse(settings.typeInActiveTextField); XCTAssertFalse(settings.sendToAtem)
    }

    func testOutputSummaryIncludesAllEnabledOutputsAndAlwaysCaptions() {
        var settings = DictationSettings()
        XCTAssertEqual(settings.outputSummary, "Active text field + Floating captions")
        settings.sendToAtem = true
        XCTAssertEqual(settings.outputSummary, "Active text field + Active Atem + Floating captions")
        settings.typeInActiveTextField = false
        XCTAssertEqual(settings.outputSummary, "Active Atem + Floating captions")
        settings.sendToAtem = false
        XCTAssertEqual(settings.outputSummary, "Floating captions")
    }
}
