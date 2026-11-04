import AstationRemote
import Foundation
import XCTest
@testable import Menubar

final class AtemHostWorkJournalTests: XCTestCase {
    private func record(id: String = UUID().uuidString.lowercased(), host: String = "host-a",
                        state: String? = nil, process: String = "11111111-1111-4111-8111-111111111111") throws -> RemoteLaunchRecord {
        var value: [String: Any] = ["requestID": id, "host": ["account_id": "account", "atem_device_id": host, "host_trust_gen": 3],
            "profile": ["id": "oss", "revision": 1, "label": "OSS", "provider": "codex"], "expiresAt": 1_793_621_100_000 as UInt64]
        if let state {
            value["status"] = ["request_id": id, "session_id": "ses-aaaaaaaaaaaa", "process_gen": process, "state": state]
        }
        return try JSONDecoder().decode(RemoteLaunchRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("launches.json")
    }

    func testRealFileReloadFiltersHostsAndRestrictsPermissions() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AtemHostWorkJournal(url: url)
        XCTAssertTrue(try journal.load(account: "account", device: "host-a").isEmpty)
        let a = try record(), b = try record(host: "host-b")
        try journal.save([a])
        try journal.save([b])
        let restart = AtemHostWorkJournal(url: url)
        XCTAssertEqual(try restart.load(account: "account", device: "host-a"), [a])
        XCTAssertEqual(try restart.load(account: "account", device: "host-b"), [b])
        XCTAssertTrue(try restart.load(account: "another-account", device: "host-a").isEmpty)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testStaleViewsCannotEraseKnownOutcomesOrChangeLaunchIdentity() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AtemHostWorkJournal(url: url)
        _ = try journal.load(account: "account", device: "host-a")
        let pending = try record(), starting = try record(id: pending.id, state: "starting")
        let started = try record(id: pending.id, state: "started")
        try journal.save([starting]); try journal.save([started])
        try journal.save([pending]); try journal.save([starting])
        XCTAssertEqual(try journal.load(account: "account", device: "host-a"), [started])
        XCTAssertThrowsError(try journal.save([record(id: pending.id, host: "host-b")]))
        XCTAssertThrowsError(try journal.save([record(id: pending.id, state: "failed")]))
        XCTAssertThrowsError(try journal.save([record(id: pending.id, state: "started", process: UUID().uuidString.lowercased())]))
        XCTAssertEqual(try AtemHostWorkJournal(url: url).load(account: "account", device: "host-a"), [started])
    }

    func testStaleViewsCannotEraseDefinitiveRefusals() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AtemHostWorkJournal(url: url)
        _ = try journal.load(account: "account", device: "host-a")
        let pending = try record()
        var refused = pending; refused.refusal = "forbidden"
        try journal.save([refused]); try journal.save([pending])
        XCTAssertEqual(try journal.load(account: "account", device: "host-a"), [refused])
        XCTAssertThrowsError(try journal.save([record(id: pending.id, state: "started")]))
    }

    func testCorruptAndDuplicateRecordsCannotBeOverwritten() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = try record()
        for bytes in [Data("[{\"requestID\":1,\"requestID\":2}]".utf8), try JSONEncoder().encode([a, a])] {
            try bytes.write(to: url)
            let journal = AtemHostWorkJournal(url: url)
            XCTAssertThrowsError(try journal.load(account: "account", device: "host-a"))
            XCTAssertThrowsError(try journal.save([]))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testFailedFileWriteDisablesSubsequentWrites() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AtemHostWorkJournal(url: url)
        _ = try journal.load(account: "account", device: "host-a")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try journal.save([record()]))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try journal.save([record()]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
