import XCTest
@testable import Menubar

final class RecoveryKitTests: XCTestCase {
    private let id = "astation-46307CB4-1707-433C-855D-8B6B27279625"

    func testValidatesTheGeneratedIdForm() {
        XCTAssertTrue(RecoveryKit.isValidAstationId(id))
        XCTAssertTrue(RecoveryKit.isValidAstationId("astation-\(UUID().uuidString)"))
        XCTAssertFalse(RecoveryKit.isValidAstationId("46307CB4-1707-433C-855D-8B6B27279625"))
        XCTAssertFalse(RecoveryKit.isValidAstationId("astation-not-a-uuid"))
        XCTAssertFalse(RecoveryKit.isValidAstationId("astation-"))
        XCTAssertFalse(RecoveryKit.isValidAstationId(""))
    }

    func testTextRoundTrips() throws {
        let kit = RecoveryKit(astationId: id, relayURL: "https://station.agora.build")
        let text = kit.text(createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(text.contains("Astation ID: \(id)"))
        XCTAssertTrue(text.contains("Relay: https://station.agora.build"))
        XCTAssertTrue(text.contains("Created: 2026-09-21"))
        XCTAssertEqual(RecoveryKit.parse(text), kit)
    }

    func testParsesABareIdAndKeepsItsCase() throws {
        let kit = try XCTUnwrap(RecoveryKit.parse("  \(id)\n"))
        XCTAssertEqual(kit.astationId, id)
        XCTAssertEqual(kit.relayURL, "")
    }

    func testParsesTextWithExtraIndentation() throws {
        let pasted = "    Astation ID:   \(id)  \n    Relay: https://example.test\n"
        let kit = try XCTUnwrap(RecoveryKit.parse(pasted))
        XCTAssertEqual(kit.astationId, id)
        XCTAssertEqual(kit.relayURL, "https://example.test")
    }

    func testRejectsTextWithoutAValidId() {
        XCTAssertNil(RecoveryKit.parse(""))
        XCTAssertNil(RecoveryKit.parse("hello"))
        XCTAssertNil(RecoveryKit.parse("Astation ID: astation-garbage\nRelay: x"))
    }

    func testMaskShowsTheStartAndEnd() {
        XCTAssertEqual(RecoveryKit.masked(id), "astation-4630…7279625")
        XCTAssertEqual(RecoveryKit.masked("short"), "short")
    }
}
