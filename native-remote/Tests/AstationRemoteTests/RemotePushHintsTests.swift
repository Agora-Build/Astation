import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

final class RemotePushHintsTests: XCTestCase {
    private func fixture() throws -> (MembershipLog, String, String, String, UInt64) {
        let prefix = try XCTUnwrap(Bundle.module.url(forResource: "membership-prefix", withExtension: "json", subdirectory: "Fixtures"))
        let pushes = try XCTUnwrap(Bundle.module.url(forResource: "push-public-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let membership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: prefix)) as? [String: Any])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pushes)) as? [String: Any])
        let now = try XCTUnwrap(value["verifier_now"] as? UInt64)
        let entries = try XCTUnwrap(membership["entries"] as? [Any]).map { try json($0) }
        let account = try XCTUnwrap(membership["account_id"] as? String)
        let genesis = try XCTUnwrap(membership["genesis_hash"] as? String)
        let log = try MembershipLog.verify(accountId: account, genesisHash: genesis, entries: entries,
            now: HostClock(wallMs: now, monoMs: 1000, bootId: "push-test"))
        let opens = try XCTUnwrap(value["open"] as? [Any])
        return (log, try json(opens[0]), try json(opens[1]), try json(XCTUnwrap(value["resolved"])), now)
    }
    private func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }

    @MainActor
    func testVerifiedHintCommitsBeforeOpeningAndSealedBytesSurviveReload() throws {
        let (log, phone, _, _, now) = try fixture()
        var saved: Data?
        var hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { saved = $0 })
        let notice = try XCTUnwrap(hints.receive(hintJSON: phone, log: log, now: now, open: { _ in
            XCTAssertNotNil(saved)
            return HintContent(tool: "Bash", summary: "npm test")
        }))
        XCTAssertEqual(notice.state, .approval(HintContent(tool: "Bash", summary: "npm test")))
        let bytes = try XCTUnwrap(saved)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("npm test"))
        hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", checkpoint: bytes, persist: { saved = $0 })
        XCTAssertNil(try hints.receive(hintJSON: phone, log: log, now: now + 1000))
        XCTAssertEqual(try hints.target(hintJSON: phone, log: log, now: now + 1000), notice.approval)
    }

    @MainActor
    func testUnavailableProtectedKeyProducesOnlyGenericVerifiedHint() throws {
        let (log, phone, _, _, now) = try fixture()
        let hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { _ in })
        XCTAssertEqual(try hints.receive(hintJSON: phone, log: log, now: now, open: { _ in throw RemoteChannelError.notReady })?.state, .approval(nil))
    }

    @MainActor
    func testResolutionBeforeOpenSurvivesRestartAndDoesNotCreateAnActionableCard() throws {
        let (log, phone, _, resolved, now) = try fixture()
        var saved: Data?
        var hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { saved = $0 })
        guard case .resolved = try hints.receive(hintJSON: resolved, log: log, now: now)?.state else { return XCTFail("missing resolution") }
        hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", checkpoint: saved, persist: { _ in })
        XCTAssertNil(try hints.receive(hintJSON: phone, log: log, now: now + 1000))
    }

    @MainActor
    func testFailedCommitPresentsNothingAndAnUncertainWriterCannotContinue() throws {
        let (log, phone, _, _, now) = try fixture()
        var saved: Data?
        let hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { saved = $0; throw RemoteRecoveryError.storageUncertain })
        var opened = false
        XCTAssertThrowsError(try hints.receive(hintJSON: phone, log: log, now: now, open: { _ in opened = true; throw RemoteChannelError.notReady }))
        XCTAssertFalse(opened)
        XCTAssertTrue(hints.storageUncertain)
        XCTAssertThrowsError(try hints.receive(hintJSON: phone, log: log, now: now))
        let restarted = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", checkpoint: saved, persist: { _ in })
        XCTAssertNil(try restarted.receive(hintJSON: phone, log: log, now: now))
    }

    @MainActor
    func testForeignRecipientTamperedCiphertextAndUnsignedMetadataCannotOpen() throws {
        let (log, phone, mac, _, now) = try fixture()
        var writes = 0
        let hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { _ in writes += 1 })
        XCTAssertThrowsError(try hints.receive(hintJSON: mac, log: log, now: now))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(phone.utf8)) as? [String: Any])
        changed["ct"] = "AAAA"
        XCTAssertThrowsError(try hints.receive(hintJSON: json(changed), log: log, now: now))
        XCTAssertThrowsError(try hints.receive(hintJSON: "{\"kind\":\"approval\",\"verified\":true}", log: log, now: now))
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testCheckpointCannotMoveAcrossAccountsRootsOrDevicesAndStaleHintCannotSelectATarget() throws {
        let (log, phone, _, _, now) = try fixture()
        var saved: Data?
        let hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", persist: { saved = $0 })
        _ = try hints.receive(hintJSON: phone, log: log, now: now)
        XCTAssertThrowsError(try RemotePushHints(accountID: "foreign", genesisHash: log.genesisHash(), deviceID: "dev-phone", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemotePushHints(accountID: log.accountId(), genesisHash: String(repeating: "a", count: 64), deviceID: "dev-phone", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "other", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try hints.target(hintJSON: phone, log: log, now: now + 2_000_000))
    }
}
