import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

final class RemotePushHintsTests: XCTestCase {
    private func alertFixture() throws -> (MembershipLog, String, UInt64) {
        let manager = Curve25519.Signing.PrivateKey(), host = Curve25519.Signing.PrivateKey()
        let encryption = PublicKeyData(alg: .x25519, raw: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let now: UInt64 = 1_794_000_000_000
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        func signed(_ body: [String: Any], key: Curve25519.Signing.PrivateKey, enc: Data? = nil, ct: Data? = nil) throws -> String {
            var object: [String: Any] = ["body": body, "sig": b64(Data(repeating: 0, count: 64))]
            if let enc, let ct { object["enc"] = b64(enc); object["ct"] = b64(ct) }
            let input = try signedObjectInfo(json: json(object)).signingInput
            object["sig"] = b64(try key.signature(for: input))
            return try json(object)
        }
        var body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "alert-account",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "owner", "signed_at": now,
            "member": ["device_id": "owner", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "ed25519", "pub": b64(manager.publicKey.rawRepresentation)],
                "enc_key": ["alg": "x25519", "pub": b64(encryption.raw)]],
            "recovery_key": ["alg": "ed25519", "pub": b64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]
        let entry = try signed(body, key: manager)
        let genesis = try XCTUnwrap(signedObjectInfo(json: entry).entryHash)
        let clock = HostClock(wallMs: now, monoMs: 100, bootId: "alert-test")
        let log = try MembershipLog.verify(accountId: "alert-account", genesisHash: genesis, entries: [entry], now: clock)
        body = ["type": "atem-membership-entry", "v": 1, "account_id": "alert-account", "genesis_hash": genesis, "seq": 2,
            "prev_hash": log.head().hash, "action": "add_host", "signer": "owner", "signed_at": now,
            "host": ["host_id": "host-a", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": b64(host.publicKey.rawRepresentation)]]]
        let extended = try log.extend(entries: [signed(body, key: manager)], now: clock)
        XCTAssertNil(extended.stop)
        XCTAssertNotNil(log.host(hostId: "host-a"))
        // These bytes exercise signature/seal-integrity routing, not HPKE opening.
        let enc = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let ct = Data(repeating: 42, count: 32)
        body = ["type": "atem-push-hint", "v": 1, "kind": "outcome_unknown", "account_id": log.accountId(),
            "genesis_hash": log.genesisHash(), "host_id": "host-a", "host_trust_gen": 1,
            "alert_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "created_at": now, "expires_at": now + 60_000,
            "recipient": ["device_id": "owner", "enc_kid": try encKid(encKey: encryption)], "sealed_hash": hashFields(fields: [enc, ct])]
        return (log, try signed(body, key: host, enc: enc, ct: ct), now)
    }

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
            return .approval(tool: "Bash", summary: "npm test")
        }))
        XCTAssertEqual(notice.state, .approval(.approval(tool: "Bash", summary: "npm test")))
        let bytes = try XCTUnwrap(saved)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("npm test"))
        hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "dev-phone", checkpoint: bytes, persist: { saved = $0 })
        XCTAssertNil(try hints.receive(hintJSON: phone, log: log, now: now + 1000))
        XCTAssertEqual(try hints.target(hintJSON: phone, log: log, now: now + 1000), notice.target)
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

    @MainActor
    func testUnknownOutcomeIsAnAlertTargetAndApprovalClassificationDoesNotConsumeIt() throws {
        let (log, json, now) = try alertFixture()
        var saved: Data?
        var hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "owner", persist: { saved = $0 })
        guard case .alert(let target) = try hints.target(hintJSON: json, log: log, now: now) else { return XCTFail("not an alert") }
        XCTAssertNil(saved, "Checking the target before routing must not consume dedup state")
        XCTAssertEqual(target.hostId, "host-a")
        let notice = try XCTUnwrap(hints.receive(hintJSON: json, log: log, now: now))
        XCTAssertEqual(notice.state, .outcomeUnknown(nil))
        XCTAssertEqual(notice.target, .alert(target))
        hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "owner", checkpoint: saved,
            persist: { _ in XCTFail("duplicate write") })
        XCTAssertNil(try hints.receive(hintJSON: json, log: log, now: now + 1))
        XCTAssertEqual(try hints.target(hintJSON: json, log: log, now: now + 1), .alert(target), "Taps reverify despite delivery dedup")
        XCTAssertThrowsError(try hints.target(hintJSON: json, log: log, now: now + 400_000))
    }

    @MainActor
    func testUnknownOutcomeTamperingOrWrongRecipientCannotCreateANotice() throws {
        let (log, raw, now) = try alertFixture()
        let hints = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "owner",
            persist: { _ in XCTFail("unverified write") })
        XCTAssertThrowsError(try hints.receive(hintJSON: raw.replacingOccurrences(of: "host-a", with: "host-b"), log: log, now: now))
        XCTAssertThrowsError(try hints.receive(hintJSON: raw.replacingOccurrences(of: "outcome_unknown", with: "open"), log: log, now: now))
        XCTAssertThrowsError(try hints.receive(hintJSON: raw.replacingOccurrences(of: "\"ct\":", with: "\"unexpected\":"), log: log, now: now))
        let other = try RemotePushHints(accountID: log.accountId(), genesisHash: log.genesisHash(), deviceID: "other", persist: { _ in })
        XCTAssertThrowsError(try other.receive(hintJSON: raw, log: log, now: now))
    }
}
