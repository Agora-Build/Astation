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

    func testParsesABareIdAndCanonicalizesItsCase() throws {
        let kit = try XCTUnwrap(RecoveryKit.parse("  \(id.lowercased())\n"))
        XCTAssertEqual(kit.astationId, id)
        XCTAssertEqual(kit.relayURL, "")
        XCTAssertTrue(RecoveryKit.identifiesSameAstation(id, id.lowercased()))
        XCTAssertFalse(RecoveryKit.identifiesSameAstation(id, "astation-00000000-0000-0000-0000-000000000000"))
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

    func testRejectsMalformedOrAmbiguousRelayValues() {
        XCTAssertNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: station.agora.build"))
        XCTAssertNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: file:///tmp/relay"))
        XCTAssertNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: https://user@example.test"))
        XCTAssertNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: https://example.test?other=1"))
        XCTAssertNil(RecoveryKit.parse("Astation ID: \(id)\nAstation ID: \(id)"))
    }

    func testAcceptsSupportedRelayURLsAndNormalizesTrailingSlashes() throws {
        let kit = try XCTUnwrap(RecoveryKit.parse("Astation ID: \(id)\nRelay: https://example.test/base///"))
        XCTAssertEqual(kit.relayURL, "https://example.test/base")
        XCTAssertNotNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: http://127.0.0.1:3100"))
        XCTAssertNotNil(RecoveryKit.parse("Astation ID: \(id)\nRelay: wss://example.test"))
    }

    func testSavesRecoveryKitWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.txt")

        try RecoveryKit.save("sensitive", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "sensitive")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRecoverySaveReplacesSymlinkWithoutWritingThroughIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let target = directory.appendingPathComponent("recovery.txt")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        try RecoveryKit.save("recovery secret", to: target)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "recovery secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFailedRecoverySaveRetainsDestinationAndCleansTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RecoveryKit.save("secret", to: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing-directory"])
    }

    func testRestoresCanonicalIdentityWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identity.txt")

        try AstationIdentity.restore(id.lowercased(), at: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), id)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRestoreRejectsInvalidIdentityWithoutWriting() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("identity.txt")
        XCTAssertThrowsError(try AstationIdentity.restore("astation-invalid", at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteAllSessionsPersistsAnEmptyStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        let store = SessionStore(storageURL: url)
        _ = store.create(hostname: "old-device")

        try store.deleteAll()

        XCTAssertEqual(store.count, 0)
        let data = try Data(contentsOf: url)
        let persisted = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(persisted?.count, 0)
    }

    func testMaskShowsTheStartAndEnd() {
        XCTAssertEqual(RecoveryKit.masked(id), "astation-4630…7279625")
        XCTAssertEqual(RecoveryKit.masked("short"), "short")
    }
}
