import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class StoredMembershipKeys: AppKeyProvider, @unchecked Sendable {
    let manager = Curve25519.Signing.PrivateKey()
    let recovery = Curve25519.Signing.PrivateKey()
    func publicKey(keyId: String) throws -> PublicKeyData { PublicKeyData(alg: .ed25519, raw: manager.publicKey.rawRepresentation) }
    func sign(request: SignRequest) throws -> Data { try manager.signature(for: request.input) }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.notReady }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw RemoteChannelError.notReady }
}

private struct StoredMembershipFixture {
    static let hour: UInt64 = 3_600_000
    let keys = StoredMembershipKeys()
    let log: MembershipLog
    func clock(hours: UInt64, boot: String = "boot-one", wallHours: UInt64? = nil) -> HostClock {
        HostClock(wallMs: 1_792_400_000_000 + (wallHours ?? hours) * Self.hour,
            monoMs: 1000 + hours * Self.hour, bootId: boot)
    }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    static func base64(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func member(_ id: String) -> [String: Any] {
        ["device_id": id, "kind": "native", "roles": ["control", "manage", "view"],
         "auth_key": ["alg": "ed25519", "pub": Self.base64(keys.manager.publicKey.rawRepresentation)],
         "enc_key": ["alg": "x25519", "pub": Self.base64(Data(repeating: 7, count: 32))]]
    }
    static func signed(_ body: [String: Any], key: Curve25519.Signing.PrivateKey) throws -> String {
        let info = try signedObjectInfo(json: json(["body": body, "sig": base64(Data(repeating: 0, count: 64))]))
        return try json(["body": body, "sig": base64(key.signature(for: info.signingInput))])
    }
    init() throws {
        let manager: [String: Any] = ["device_id": "manager-a", "kind": "native", "roles": ["control", "manage", "view"],
            "auth_key": ["alg": "ed25519", "pub": Self.base64(keys.manager.publicKey.rawRepresentation)],
            "enc_key": ["alg": "x25519", "pub": Self.base64(Data(repeating: 7, count: 32))]]
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account-a", "seq": 1,
            "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "manager-a", "signed_at": 1_792_400_000_000,
            "member": manager, "recovery_key": ["alg": "ed25519", "pub": Self.base64(keys.recovery.publicKey.rawRepresentation)]]
        let genesis = try Self.signed(body, key: keys.manager)
        let hash = try XCTUnwrap(signedObjectInfo(json: genesis).entryHash)
        log = try MembershipLog.verify(accountId: "account-a", genesisHash: hash, entries: [genesis],
            now: HostClock(wallMs: 1_792_400_000_000, monoMs: 1000, bootId: "boot-one"))
        let replacement: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account-a", "seq": 2,
            "prev_hash": hash, "genesis_hash": hash, "action": "recovery_add", "signer": "recovery", "signed_at": 1_792_400_000_000,
            "member": member("replacement-a")]
        let result = try log.extend(entries: [Self.signed(replacement, key: keys.recovery)], now: clock(hours: 0))
        XCTAssertNil(result.stop)
        XCTAssertEqual(result.appended, 1)
    }
}

final class RemoteMembershipCheckpointTests: XCTestCase {
    func testSameBootReloadPreservesElapsedWaitAndRebootPreservesOnlyDurableElapsedTime() throws {
        let f = try StoredMembershipFixture()
        _ = try f.log.advance(now: f.clock(hours: 10))
        let saved = try f.log.storedJson()
        let resumed = try RemoteMembershipCheckpoint.load(accountID: "account-a", genesisHash: f.log.genesisHash(),
            entries: f.log.entries(), storedJSON: saved, now: f.clock(hours: 12))
        XCTAssertEqual(try resumed.pendingRecovery(now: f.clock(hours: 12)).first?.effectiveAt, f.clock(hours: 24).wallMs)
        _ = try resumed.advance(now: f.clock(hours: 24))
        XCTAssertEqual(resumed.member(deviceId: "replacement-a")?.status, .active)
        let reboot = f.clock(hours: 0, boot: "boot-two", wallHours: 30)
        let afterReboot = try RemoteMembershipCheckpoint.load(accountID: "account-a", genesisHash: f.log.genesisHash(),
            entries: f.log.entries(), storedJSON: saved, now: reboot)
        XCTAssertEqual(try afterReboot.pendingRecovery(now: reboot).first?.effectiveAt, reboot.wallMs + 14 * StoredMembershipFixture.hour)
        XCTAssertEqual(afterReboot.member(deviceId: "replacement-a")?.status, .pending)
    }

    @MainActor
    func testPublisherRestartKeepsWaitEndedDecisionEvenAfterWallRollback() throws {
        let f = try StoredMembershipFixture()
        _ = try f.log.advance(now: f.clock(hours: 24))
        var checkpoint: Data?
        var publisher: RemoteMembershipPublication? = RemoteMembershipPublication(log: f.log, persist: { checkpoint = $0 })
        _ = try publisher?.prepare(actionJSON: StoredMembershipFixture.json(["action": "remove", "device_id": "replacement-a"]),
            signer: "manager-a", signedAt: f.clock(hours: 24).wallMs)
        publisher = nil
        let restored = try RemoteMembershipPublication(checkpoint: XCTUnwrap(checkpoint), accountID: "account-a",
            genesisHash: f.log.genesisHash(), now: f.clock(hours: 25, wallHours: 1), persist: { checkpoint = $0 })
        XCTAssertEqual(try restored.committedLog().member(deviceId: "replacement-a")?.status, .active)
        _ = try restored.sign(provider: f.keys, keyID: "manager-a")
        _ = try restored.relayStored(now: f.clock(hours: 25, wallHours: 1))
        XCTAssertNotEqual(try restored.committedLog().member(deviceId: "replacement-a")?.status, .active)
    }

    func testWrongAnchorsCorruptionAndDisagreementWithEntriesAreRefused() throws {
        let f = try StoredMembershipFixture()
        for (account, genesis, snapshot, entries) in [
            ("other", f.log.genesisHash(), try f.log.storedJson(), f.log.entries()),
            ("account-a", String(repeating: "0", count: 64), try f.log.storedJson(), f.log.entries()),
            ("account-a", f.log.genesisHash(), "{}", f.log.entries()),
            ("account-a", f.log.genesisHash(), try f.log.storedJson(), Array(f.log.entries().prefix(1)))
        ] {
            XCTAssertThrowsError(try RemoteMembershipCheckpoint.load(accountID: account, genesisHash: genesis,
                entries: entries, storedJSON: snapshot, now: f.clock(hours: 1)))
        }
    }

    @MainActor
    func testBackupRestartKeepsTheRecoveredManagersDurableAuthority() throws {
        let f = try StoredMembershipFixture()
        _ = try f.log.advance(now: f.clock(hours: 24))
        var checkpoint: Data?
        var backup: RemoteRecoveryBackup? = try RemoteRecoveryBackup(log: f.log, kids: ["0123abcd"],
            signer: "replacement-a", persist: { checkpoint = $0 })
        XCTAssertNotNil(backup)
        backup = nil
        backup = try RemoteRecoveryBackup(checkpoint: XCTUnwrap(checkpoint), accountID: "account-a",
            genesisHash: f.log.genesisHash(), now: f.clock(hours: 25, wallHours: 1), persist: { checkpoint = $0 })
        XCTAssertEqual(try backup?.committedLog().member(deviceId: "replacement-a")?.status, .active)
        _ = try backup?.seal(keys: [AccountKey(kid: "0123abcd", k: Data(repeating: 3, count: 32))], signedAt: f.clock(hours: 25).wallMs)
        _ = try backup?.sign(provider: f.keys, keyID: "manager-a")
        guard case .put = backup?.step else { return XCTFail("Recovered manager could not sign the backup") }
    }

    func testApprovalVetoAndFreezeRemainAuthoritativeAfterReload() throws {
        for action in ["recovery_approve", "recovery_veto"] {
            let f = try StoredMembershipFixture()
            let body = try f.log.draftEntry(signer: "manager-a", signedAt: f.clock(hours: 1).wallMs,
                actionJson: StoredMembershipFixture.json(["action": action, "target": f.log.head().hash]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let result = try f.log.extend(entries: [StoredMembershipFixture.signed(object, key: f.keys.manager)], now: f.clock(hours: 1))
            XCTAssertNil(result.stop)
            let loaded = try RemoteMembershipCheckpoint.load(accountID: "account-a", genesisHash: f.log.genesisHash(),
                entries: f.log.entries(), storedJSON: f.log.storedJson(), now: f.clock(hours: 2))
            XCTAssertEqual(loaded.member(deviceId: "replacement-a")?.status, f.log.member(deviceId: "replacement-a")?.status)
            XCTAssertTrue(try loaded.pendingRecovery(now: f.clock(hours: 2)).isEmpty)
        }
        let f = try StoredMembershipFixture()
        let fork: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account-a", "seq": 2,
            "prev_hash": f.log.genesisHash(), "genesis_hash": f.log.genesisHash(), "action": "add_host",
            "signer": "manager-a", "signed_at": f.clock(hours: 1).wallMs,
            "host": ["host_id": "fork-host", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": StoredMembershipFixture.base64(f.keys.manager.publicKey.rawRepresentation)]]]
        _ = try f.log.extend(entries: [StoredMembershipFixture.signed(fork, key: f.keys.manager)], now: f.clock(hours: 1))
        XCTAssertNotNil(f.log.frozen())
        let loaded = try RemoteMembershipCheckpoint.load(accountID: "account-a", genesisHash: f.log.genesisHash(),
            entries: f.log.entries(), storedJSON: f.log.storedJson(), now: f.clock(hours: 2))
        XCTAssertEqual(loaded.frozen(), f.log.frozen())
    }

    @MainActor
    func testPublisherLoadMustCommitBeforeAnyPreparedRequestCanBeUsed() throws {
        let f = try StoredMembershipFixture()
        var checkpoint: Data?
        var publisher: RemoteMembershipPublication? = RemoteMembershipPublication(log: f.log, persist: { checkpoint = $0 })
        _ = try publisher?.prepare(actionJSON: StoredMembershipFixture.json(["action": "remove", "device_id": "replacement-a"]),
            signer: "manager-a", signedAt: f.clock(hours: 0).wallMs)
        let first = try publisher?.sign(provider: f.keys, keyID: "manager-a")
        XCTAssertNotNil(first)
        publisher = nil
        var commitAttempted = false
        XCTAssertThrowsError(try RemoteMembershipPublication(checkpoint: XCTUnwrap(checkpoint), accountID: "account-a",
            genesisHash: f.log.genesisHash(), now: f.clock(hours: 1), persist: { _ in
                commitAttempted = true
                throw RemoteRecoveryError.storageUncertain
            }))
        XCTAssertTrue(commitAttempted)
    }

    #if os(macOS)
    func testSystemClockUsesTheSameOSBootIdentifierAsAnIndependentProcess() throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "kern.bootsessionuuid"]
        let pipe = Pipe(); task.standardOutput = pipe
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        let system = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(RemoteSystemClock.now().bootId, system)
    }
    #endif
}
