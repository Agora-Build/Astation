import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class RecoveryTestKeys: AppKeyProvider, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var requests: [SignRequest] = []
    var beforeSign: (() throws -> Void)?
    func publicKey(keyId: String) throws -> PublicKeyData { PublicKeyData(alg: .p256, raw: key.publicKey.x963Representation) }
    func sign(request: SignRequest) throws -> Data {
        try beforeSign?()
        requests.append(request)
        // The shared verifier enforces low-S signatures; use the public P-256 order.
        let raw = try key.signature(for: request.input).rawRepresentation
        let order = Array(Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"))
        let s = Array(raw.suffix(32))
        var borrow = 0
        var other = [UInt8](repeating: 0, count: 32)
        for i in (0..<32).reversed() {
            let d = Int(order[i]) - Int(s[i]) - borrow
            other[i] = UInt8(truncatingIfNeeded: d)
            borrow = d < 0 ? 1 : 0
        }
        return Data(raw.prefix(32)) + Data(other.lexicographicallyPrecedes(s) ? other : s)
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteRecoveryError.busy }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw RemoteRecoveryError.busy }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

@MainActor
private final class RecoveryFixture {
    let keys = RecoveryTestKeys()
    let secret = Data(repeating: 7, count: 32)
    let now = HostClock(wallMs: 1_792_400_000_000, monoMs: 10, bootId: "recovery-test")
    var checkpoint: Data?
    var fail = false
    var beforeWrite: (() throws -> Void)?
    var writes = 0
    var bootstrap: RemoteRecoveryBootstrap!

    init() throws {
        bootstrap = try RemoteRecoveryBootstrap(accountID: "account-a", managerID: "manager-a", keyID: "key-a",
            authKey: keys.publicKey(keyId: "key-a"),
            encryptionKey: PublicKeyData(alg: .x25519, raw: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            recoverySecret: secret, relayURL: "https://station.agora.build", signedAt: now.wallMs,
            persist: { [unowned self] in try self.write($0) })
    }
    func write(_ bytes: Data) throws {
        writes += 1
        try beforeWrite?()
        if fail { throw RemoteRecoveryError.storageUncertain }
        checkpoint = bytes
    }
    func reload() throws {
        bootstrap = try RemoteRecoveryBootstrap(checkpoint: XCTUnwrap(checkpoint), accountID: "account-a",
            now: now, persist: { [unowned self] in try self.write($0) })
    }
    func commit() throws -> RemoteRecoveryKit {
        _ = try bootstrap.sign(provider: keys, now: now)
        try bootstrap.relayStored(now: now)
        return try bootstrap.kit(now: now)
    }
}

final class RemoteConfirmedSignerTests: XCTestCase {
    @MainActor
    func testFreshApprovalSignsOnlyTheExactStoredGenesisOnce() throws {
        let f = try RecoveryFixture()
        let request = try f.bootstrap.signingRequest()
        let provider = try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 101 })
        var changed = request
        changed.input.append(0)
        XCTAssertThrowsError(try provider.sign(request: changed))
        _ = try f.bootstrap.sign(provider: provider, now: f.now)
        XCTAssertThrowsError(try provider.sign(request: request))
        let stored = try XCTUnwrap(f.bootstrap.outstanding())
        XCTAssertEqual(try f.bootstrap.sign(provider: provider, now: f.now), stored)
    }

    @MainActor
    func testExpiredRevokedAndMismatchedApprovalsNeverSign() throws {
        let f = try RecoveryFixture()
        let request = try f.bootstrap.signingRequest()
        XCTAssertThrowsError(try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 30_100 }))
        XCTAssertThrowsError(try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 99 }))
        let revoked = try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 101 })
        revoked.invalidate()
        XCTAssertThrowsError(try revoked.sign(request: request))
        for change in 0..<3 {
            var bad = request
            if change == 0 { bad.purpose = .host }
            if change == 1 { bad.label = "atem-channel-host-v1" }
            if change == 2 { bad.freshConfirmation = false }
            XCTAssertThrowsError(try RemoteConfirmedSigner(provider: f.keys, request: bad, confirmedAt: 100, now: { 101 }))
        }
        XCTAssertNil(try f.bootstrap.outstanding())
    }
}

final class RemoteRecoveryBackupTests: XCTestCase {
    @MainActor
    func testBackupCommitsBeforeKUseAndRestartsWithExactEnvelopeAndEntry() throws {
        let f = try RecoveryFixture()
        let kit = try f.commit()
        let log = try f.bootstrap.committedLog(now: f.now)
        let key = AccountKey(kid: "0123abcd", k: Data(repeating: 0x55, count: 32))
        var saved: Data?
        var backup: RemoteRecoveryBackup? = try RemoteRecoveryBackup(log: log, kids: [key.kid], signer: "manager-a", persist: { saved = $0 })
        XCTAssertEqual(backup?.step, .seal(blobVersion: 1))
        guard case .sign(let body) = try backup?.seal(keys: [key], signedAt: f.now.wallMs) else { return XCTFail("missing signature step") }
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "key-a")
        let approved = try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 101 })
        guard case .put(let version, let bytes) = try backup?.sign(provider: approved, keyID: "key-a") else { return XCTFail("missing upload") }
        XCTAssertEqual(try signedObjectInfo(json: XCTUnwrap(backup).uploadEntryJSON()).bodyType, "atem-membership-entry")
        XCTAssertEqual(try openKBackup(envelopeJson: bytes, kit: kit.handle), [key])
        XCTAssertEqual(backup?.committedEntries, log.entries())
        guard case .append(let entry) = try backup?.uploadReply(maxOccupied: nil) else { return XCTFail("missing append") }
        backup = nil
        backup = try RemoteRecoveryBackup(checkpoint: XCTUnwrap(saved), accountID: kit.accountID, genesisHash: kit.genesisHash,
            now: f.now, persist: { saved = $0 })
        XCTAssertEqual(backup?.step, .put(blobVersion: version, bytes: bytes))
        XCTAssertEqual(try backup?.uploadReply(maxOccupied: nil), .append(request: entry))
        XCTAssertEqual(try backup?.relayStored(now: f.now, signedAt: f.now.wallMs), .done(committed: version))
        XCTAssertEqual(backup?.committedEntries.count, 2)
        backup = nil
        backup = try RemoteRecoveryBackup(checkpoint: XCTUnwrap(saved), accountID: kit.accountID, genesisHash: kit.genesisHash,
            now: f.now, persist: { saved = $0 })
        XCTAssertEqual(backup?.step, .done(committed: 1))
    }

    @MainActor
    func testOccupiedVersionsAdvanceAndAnUnrelatedCASLossRetainsTheEnvelope() throws {
        let f = try RecoveryFixture()
        _ = try f.commit()
        let log = try f.bootstrap.committedLog(now: f.now)
        let other = RecoveryTestKeys()
        try RestoreFixture.append(["action": "add", "member": ["device_id": "manager-b", "kind": "native",
            "roles": ["control", "manage", "view"], "auth_key": ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(other.key.publicKey.x963Representation)],
            "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]]], log: log, fixture: f)
        let initialHead = log.head()
        let key = AccountKey(kid: "0123abcd", k: Data(repeating: 0x55, count: 32))
        let backup = try RemoteRecoveryBackup(log: log, kids: [key.kid], signer: "manager-a", persist: { _ in })
        _ = try backup.seal(keys: [key], signedAt: f.now.wallMs)
        _ = try backup.sign(provider: f.keys, keyID: "key-a")
        XCTAssertEqual(try backup.uploadReply(maxOccupied: 8), .seal(blobVersion: 9))
        _ = try backup.seal(keys: [key], signedAt: f.now.wallMs)
        guard case .put(_, let envelope) = try backup.sign(provider: f.keys, keyID: "key-a") else { return XCTFail("missing upload") }
        _ = try backup.uploadReply(maxOccupied: nil)
        // Another manager may advance the log while this backup's upload is in flight.
        let publisher = EntryPublisher()
        let body = try log.draftEntry(signer: "manager-b", signedAt: f.now.wallMs, actionJson: RestoreFixture.json([
            "action": "add_host", "host": ["host_id": "other-host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]]))
        try publisher.prepare(log: log, bodyJson: body)
        _ = try publisher.sign(provider: other, keyId: "key-a", cosignKit: nil)
        _ = try publisher.replyStored(log: log, now: f.now)
        guard case .sign = try backup.relayConflict(head: log.head(), entries: log.entriesAfter(seq: initialHead.seq), more: false,
            now: f.now, signedAt: f.now.wallMs) else { return XCTFail("expected a fresh body") }
        guard case .append(let retried) = try backup.sign(provider: f.keys, keyID: "key-a") else { return XCTFail("uploaded envelope should be retained") }
        let bodyInfo = try signedObjectInfo(json: retried.entryJson)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bodyInfo.bodyJcs.utf8)) as? [String: Any])
        let record = try XCTUnwrap(fields["k_backup"] as? [String: Any])
        XCTAssertEqual(record["backup_hash"] as? String, try parseKBackup(envelopeJson: envelope).backupHash)
        XCTAssertEqual(retried.expected, log.head())
    }

    @MainActor
    func testEveryUncertainBackupWriteBlocksTheNextExternalEffect() throws {
        for failAt in 2...6 {
            let f = try RecoveryFixture()
            _ = try f.commit()
            let log = try f.bootstrap.committedLog(now: f.now)
            var writes = 0
            let backup = try RemoteRecoveryBackup(log: log, kids: ["0123abcd"], signer: "manager-a", persist: { _ in
                writes += 1
                if writes == failAt { throw RemoteRecoveryError.storageUncertain }
            })
            do {
                _ = try backup.seal(keys: [AccountKey(kid: "0123abcd", k: Data(repeating: 0x55, count: 32))], signedAt: f.now.wallMs)
                _ = try backup.sign(provider: f.keys, keyID: "key-a")
                _ = try backup.uploadReply(maxOccupied: nil)
                _ = try backup.relayStored(now: f.now, signedAt: f.now.wallMs)
                if failAt <= 5 { XCTFail("write should have failed") }
            } catch {
                XCTAssertTrue(backup.storageUncertain)
                XCTAssertThrowsError(try backup.seal(keys: [], signedAt: f.now.wallMs))
                XCTAssertThrowsError(try backup.sign(provider: f.keys, keyID: "key-a"))
                XCTAssertEqual(backup.committedEntries, log.entries())
            }
        }
    }
}

@MainActor
private final class RestoreFixture {
    let setup: RecoveryFixture
    let kit: RemoteRecoveryKit
    let log: MembershipLog
    let hostKey = Curve25519.Signing.PrivateKey()
    let accountKey = AccountKey(kid: "0123abcd", k: Data(repeating: 0x55, count: 32))
    let member: String
    let envelope: String
    var checkpoint: Data?
    var writes = 0
    var fail = false
    var beforeWrite: (() -> Void)?
    var flow: RemoteRecoveryRestore!

    init() throws {
        setup = try RecoveryFixture()
        kit = try setup.commit()
        log = try setup.bootstrap.committedLog(now: setup.now)
        let host: [String: Any] = ["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(hostKey.publicKey.rawRepresentation)]]]
        try Self.append(host, log: log, fixture: setup)
        envelope = try sealKBackup(accountId: kit.accountID, genesisHash: kit.genesisHash,
            blobVersion: 1, recoveryKey: kit.handle.recoveryKey(), keys: [accountKey])
        let backup = try parseKBackup(envelopeJson: envelope)
        try Self.append(["action": "k_backup", "k_backup": ["blob_version": backup.blobVersion,
            "kids": [accountKey.kid], "recovery_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(kit.handle.recoveryKey().raw)],
            "backup_hash": backup.backupHash]], log: log, fixture: setup)
        member = try Self.json(["device_id": "replacement-manager", "kind": "native", "roles": ["control", "manage", "view"],
            "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)],
            "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]])
        flow = try RemoteRecoveryRestore(kit: kit, persist: { [unowned self] in try self.write($0) })
    }

    static func append(_ action: [String: Any], log: MembershipLog, fixture: RecoveryFixture) throws {
        let publisher = EntryPublisher()
        try publisher.prepare(log: log, bodyJson: log.draftEntry(signer: "manager-a", signedAt: fixture.now.wallMs, actionJson: json(action)))
        _ = try publisher.sign(provider: fixture.keys, keyId: "key-a", cosignKit: nil)
        _ = try publisher.replyStored(log: log, now: fixture.now)
    }

    func write(_ bytes: Data) throws {
        writes += 1
        beforeWrite?()
        if fail { throw RemoteRecoveryError.storageUncertain }
        checkpoint = bytes
    }

    func signedAccept(for probe: RemoteRecoveryRestore.Probe, head: LogHead? = nil) throws -> Data {
        let head = head ?? log.head()
        var accept: [String: Any] = ["ch": "atem-ch1", "op": "accept",
            "e": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            "n": RemoteRecoveryKit.base64URL(Data(repeating: 2, count: 32)),
            "head": ["seq": head.seq, "hash": head.hash], "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]
        let th2 = try hostAcceptTh2(initJson: String(decoding: probe.frame, as: UTF8.self), acceptJson: Self.json(accept))
        let input = signingInput(label: .channelHost, payload: Data(hex: th2))
        accept["sig"] = RemoteRecoveryKit.base64URL(try hostKey.signature(for: input))
        return Data(try Self.json(accept).utf8)
    }

    func fetch(envelope: String? = nil, entries: [String]? = nil) throws {
        try flow.fetched(entries: entries ?? log.entries(), envelopeJSON: envelope ?? self.envelope, now: setup.now)
    }

    func confirm() throws {
        try fetch()
        let probe = try flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: setup.now)
        try flow.receivedHostAccept(signedAccept(for: probe), probeID: probe.id, now: setup.now)
        _ = try flow.attempt(now: setup.now)
    }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
}

final class RemoteRecoveryKitTests: XCTestCase {
    func testPrintedKitMatchesTheIndependentlyReviewedRecoveryVector() throws {
        let secret = Data(hex: "de7b07c173601dbcd9053ef7679fcd3a6864af071005397179134682a438dcc6")
        let tag = Data(hex: "38d5aeaebad0af036ba7bafdc86ab259")
        let kit = try RemoteRecoveryKit(text: """
        Astation Recovery Kit v2
        Account ID: acct-test-1
        Relay: https://station.agora.build
        Recovery Secret: \(RemoteRecoveryKit.base64URL(secret))
        Genesis Fingerprint: 93501542f5f9f4a7ce3d08f79e267d4d80df3f8e35ae852f47216e3cc559cd89
        Recovery Kit Integrity Check: \(RemoteRecoveryKit.base64URL(tag))
        """)
        XCTAssertEqual(kit.handle.secretR(), secret)
        XCTAssertEqual(kit.handle.kitTag(), tag)
        XCTAssertEqual(RemoteRecoveryKit.base64URL(kit.handle.recoveryKey().raw), "mHZ8mI_wz3J66ZF4EenE7WO3-0hgjUwyaI23ny7ZQ2A")
    }

    @MainActor
    func testKitHasClearIntegrityNameAndRoundTripsThroughSharedCore() throws {
        let f = try RecoveryFixture()
        let kit = try f.commit()
        let text = kit.text()
        XCTAssertEqual(try RemoteRecoveryKit(text: text), kit)
        XCTAssertTrue(text.contains("Recovery Kit Integrity Check: "))
        XCTAssertFalse(text.contains("kit_tag"))
        XCTAssertEqual(kit.accountID, "account-a")
        XCTAssertEqual(kit.genesisHash, try f.bootstrap.genesisHash)
        XCTAssertEqual(kit.handle.secretR(), f.secret)
        XCTAssertFalse(f.bootstrap.recoveryIsSaved)
        try f.bootstrap.markKitSaved(kit, now: f.now)
        try f.reload()
        XCTAssertTrue(f.bootstrap.recoveryIsSaved)
        XCTAssertEqual(try f.bootstrap.kit(now: f.now), kit)
    }

    @MainActor
    func testTamperingEachBoundFieldFailsBeforeAnyRestoreOperation() throws {
        let f = try RecoveryFixture()
        let kit = try f.commit()
        for text in [
            kit.text().replacingOccurrences(of: "account-a", with: "account-b"),
            kit.text().replacingOccurrences(of: kit.genesisHash, with: String(repeating: "0", count: 64)),
            kit.text().replacingOccurrences(of: RemoteRecoveryKit.base64URL(f.secret), with: RemoteRecoveryKit.base64URL(Data(repeating: 8, count: 32))),
            kit.text().replacingOccurrences(of: RemoteRecoveryKit.base64URL(kit.handle.kitTag()), with: RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 16)))
        ] { XCTAssertThrowsError(try RemoteRecoveryKit(text: text)) }
        XCTAssertEqual(f.writes, 3)
    }

    @MainActor
    func testMissingDuplicateUnknownAndNoncanonicalFieldsAreRefused() throws {
        let f = try RecoveryFixture()
        let kit = try f.commit()
        let text = kit.text()
        for bad in [text + "\nAccount ID: account-a", text + "\nOther: value",
            text.replacingOccurrences(of: "Account ID: account-a\n", with: ""),
            text.replacingOccurrences(of: kit.genesisHash, with: kit.genesisHash.uppercased()),
            text.replacingOccurrences(of: RemoteRecoveryKit.base64URL(f.secret), with: f.secret.base64EncodedString()),
            text.replacingOccurrences(of: "https://station.agora.build", with: "https://name:password@example.test"),
            text.replacingOccurrences(of: "https://station.agora.build", with: "https://example.test?token=abc"),
            text + String(repeating: "a", count: 16_384)] {
            XCTAssertThrowsError(try RemoteRecoveryKit(text: bad))
        }
        XCTAssertThrowsError(try RemoteRecoveryKit(text: text.replacingOccurrences(of: "Kit v2", with: "Kit v3"))) {
            XCTAssertEqual($0 as? RemoteRecoveryError, .unsupportedVersion)
        }
    }

    @MainActor
    func testRelayAddressIsRoutingMetadataAndCannotChangeTheGenesis() throws {
        let f = try RecoveryFixture()
        let kit = try f.commit()
        let moved = try RemoteRecoveryKit(text: kit.text().replacingOccurrences(of: kit.relayURL, with: "https://other.test/base///"))
        XCTAssertEqual(moved.genesisHash, kit.genesisHash)
        XCTAssertEqual(moved.handle.kitTag(), kit.handle.kitTag())
        XCTAssertEqual(moved.relayURL, "https://other.test/base")
        XCTAssertEqual(try kit.replacingRelayURL("https://other.test/base///"), moved)
        XCTAssertEqual(moved.handle.secretR(), kit.handle.secretR())
        XCTAssertEqual(moved.recoveryKey, kit.recoveryKey)
        XCTAssertEqual(kit.relayURL, "https://station.agora.build")
        XCTAssertThrowsError(try kit.replacingRelayURL("https://user:password@other.test"))
        XCTAssertThrowsError(try kit.replacingRelayURL("https://other.test?token=abc"))
    }

    @MainActor
    func testGenesisIsPreparedBeforeSigningAndExactRetriesSurviveRestart() throws {
        let f = try RecoveryFixture()
        let bodyCheckpoint = f.checkpoint
        XCTAssertThrowsError(try f.bootstrap.kit(now: f.now))
        f.keys.beforeSign = { XCTAssertEqual(f.checkpoint, bodyCheckpoint) }
        let request = try f.bootstrap.sign(provider: f.keys, now: f.now)
        XCTAssertEqual(f.keys.requests.count, 1)
        XCTAssertEqual(f.keys.requests[0].purpose, .genesis)
        XCTAssertTrue(f.keys.requests[0].freshConfirmation)
        XCTAssertNotNil(f.keys.requests[0].bodyJson)
        XCTAssertThrowsError(try f.bootstrap.kit(now: f.now))
        try f.reload()
        XCTAssertEqual(try f.bootstrap.sign(provider: f.keys, now: f.now), request)
        XCTAssertEqual(f.keys.requests.count, 1, "A P-256 retry must not sign again")
        try f.bootstrap.relayStored(now: f.now)
        XCTAssertNil(try f.bootstrap.outstanding())
        XCTAssertThrowsError(try f.bootstrap.sign(provider: f.keys, now: f.now))
        XCTAssertEqual(f.keys.requests.count, 1)
    }

    @MainActor
    func testSignatureAndCommitWriteFailuresHaltWithoutExposingAKit() throws {
        for failStage in ["signature", "commit", "saved"] {
            let f = try RecoveryFixture()
            if failStage != "signature" { _ = try f.bootstrap.sign(provider: f.keys, now: f.now) }
            if failStage == "saved" { try f.bootstrap.relayStored(now: f.now) }
            let kit = failStage == "saved" ? try f.bootstrap.kit(now: f.now) : nil
            let before = f.checkpoint
            f.fail = true
            switch failStage {
            case "signature": XCTAssertThrowsError(try f.bootstrap.sign(provider: f.keys, now: f.now))
            case "commit": XCTAssertThrowsError(try f.bootstrap.relayStored(now: f.now))
            default: XCTAssertThrowsError(try f.bootstrap.markKitSaved(XCTUnwrap(kit), now: f.now))
            }
            XCTAssertEqual(f.checkpoint, before)
            XCTAssertTrue(f.bootstrap.storageUncertain)
            XCTAssertFalse(f.bootstrap.recoveryIsSaved)
            XCTAssertThrowsError(try f.bootstrap.kit(now: f.now))
            XCTAssertThrowsError(try f.bootstrap.outstanding())
            f.fail = false
            try f.reload()
            XCTAssertFalse(f.bootstrap.recoveryIsSaved)
        }
    }

    @MainActor
    func testReloadRejectsAnotherAccountAndCorruptCheckpoints() throws {
        let f = try RecoveryFixture()
        _ = try f.commit()
        XCTAssertThrowsError(try RemoteRecoveryBootstrap(checkpoint: XCTUnwrap(f.checkpoint), accountID: "other", now: f.now, persist: { _ in }))
        XCTAssertThrowsError(try RemoteRecoveryBootstrap(checkpoint: Data("bad".utf8), accountID: "account-a", now: f.now, persist: { _ in }))
        XCTAssertThrowsError(try RemoteRecoveryBootstrap(checkpoint: Data(repeating: 0, count: 65_537), accountID: "account-a", now: f.now, persist: { _ in }))
    }

    @MainActor
    func testReentrantSigningAndCommitAreBlocked() throws {
        let f = try RecoveryFixture()
        f.keys.beforeSign = { XCTAssertThrowsError(try f.bootstrap.sign(provider: f.keys, now: f.now)) }
        _ = try f.bootstrap.sign(provider: f.keys, now: f.now)
        f.beforeWrite = { XCTAssertThrowsError(try f.bootstrap.relayStored(now: f.now)) }
        try f.bootstrap.relayStored(now: f.now)
    }
}

final class RemoteRecoveryRestoreTests: XCTestCase {
    @MainActor
    func testNoReachableHostWaitsWithoutWritingOrEnrolling() throws {
        let f = try RestoreFixture()
        try f.fetch()
        XCTAssertEqual(f.flow.phase, .waitingForHost(["host-a"]))
        XCTAssertEqual(f.writes, 0)
        XCTAssertThrowsError(try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs))
        XCTAssertThrowsError(try f.flow.recoveredKeys())
        XCTAssertThrowsError(try f.flow.outstanding())
    }

    @MainActor
    func testConfirmedRestoreCommitsKeysBeforeEnrollmentAndPublishedStateBeforeSuccess() throws {
        let f = try RestoreFixture()
        try f.confirm()
        XCTAssertEqual(f.flow.phase, .readyToEnroll)
        XCTAssertEqual(try f.flow.recoveredKeys(), [f.accountKey])
        XCTAssertEqual(f.writes, 1)
        let request = try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs)
        XCTAssertEqual(f.writes, 2)
        XCTAssertEqual(f.flow.phase, .enrollmentPending)
        XCTAssertEqual(try f.flow.outstanding(), request)
        guard case .published(let head) = try f.flow.relayStored(now: f.setup.now) else { return XCTFail("Expected published") }
        XCTAssertEqual(head.seq, f.log.head().seq + 1)
        XCTAssertEqual(f.flow.phase, .published)
        XCTAssertEqual(f.writes, 3)
        XCTAssertNil(try f.flow.outstanding())
    }

    @MainActor
    func testTamperedBackupCannotReuseAnEarlierSuccessfulConfirmation() throws {
        let f = try RestoreFixture()
        try f.confirm()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.envelope.utf8)) as? [String: Any])
        object["ct"] = "broken"
        try f.fetch(envelope: RestoreFixture.json(object))
        let probe = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        try f.flow.receivedHostAccept(f.signedAccept(for: probe), probeID: probe.id, now: f.setup.now)
        XCTAssertThrowsError(try f.flow.attempt(now: f.setup.now))
        XCTAssertThrowsError(try f.flow.recoveredKeys())
        XCTAssertThrowsError(try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs))
        XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testOldProbeReplayWrongHostSignatureAndExactDeadlineAreRefused() throws {
        let f = try RestoreFixture()
        try f.fetch()
        let first = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        let accept = try f.signedAccept(for: first)
        f.flow.invalidateFreshness()
        let second = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        XCTAssertThrowsError(try f.flow.receivedHostAccept(accept, probeID: first.id, now: f.setup.now))
        XCTAssertThrowsError(try f.flow.receivedHostAccept(accept, probeID: second.id, now: f.setup.now))
        let third = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        let late = HostClock(wallMs: f.setup.now.wallMs + 10_000, monoMs: f.setup.now.monoMs + 10_000, bootId: f.setup.now.bootId)
        XCTAssertThrowsError(try f.flow.receivedHostAccept(f.signedAccept(for: third), probeID: third.id, now: late))
        XCTAssertEqual(f.writes, 0)
    }

    @MainActor
    func testHostHeadAheadOfTheRelayCannotRestoreOrWriteKeys() throws {
        let f = try RestoreFixture()
        try f.fetch()
        let probe = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        let ahead = LogHead(seq: f.log.head().seq + 1, hash: String(repeating: "a", count: 64))
        try f.flow.receivedHostAccept(f.signedAccept(for: probe, head: ahead), probeID: probe.id, now: f.setup.now)
        XCTAssertThrowsError(try f.flow.attempt(now: f.setup.now))
        XCTAssertEqual(f.flow.phase, .refused("log_behind_host"))
        XCTAssertEqual(f.writes, 0)
    }

    @MainActor
    func testAValidSubstituteGenesisWithTheSameRecoverySecretIsRefused() throws {
        let original = try RestoreFixture()
        let substitute = try RestoreFixture()
        XCTAssertEqual(original.kit.handle.recoveryKey(), substitute.kit.handle.recoveryKey())
        XCTAssertNotEqual(original.kit.genesisHash, substitute.kit.genesisHash)
        XCTAssertThrowsError(try original.flow.fetched(entries: substitute.log.entries(), envelopeJSON: substitute.envelope, now: original.setup.now))
        XCTAssertEqual(original.writes, 0)
        XCTAssertThrowsError(try original.flow.recoveredKeys())
        XCTAssertThrowsError(try original.flow.enroll(confirmedMemberJSON: original.member, signedAt: original.setup.now.wallMs))
    }

    @MainActor
    func testEnrollmentConflictNeedsNewProofAndCannotSendASiblingOnTheOldHead() throws {
        let f = try RestoreFixture()
        try f.confirm()
        _ = try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs)
        try RestoreFixture.append(["action": "add_host", "host": ["host_id": "host-b", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]], log: f.log, fixture: f.setup)
        let result = try f.flow.relayConflict(head: f.log.head(), entries: f.log.entriesAfter(seq: 3), more: false, now: f.setup.now)
        XCTAssertEqual(result, .rebuild)
        XCTAssertThrowsError(try f.flow.outstanding())
        XCTAssertThrowsError(try f.flow.recoveredKeys())
        XCTAssertThrowsError(try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs))
        try f.confirm()
        let retried = try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs)
        XCTAssertEqual(retried.expected, f.log.head())
    }

    @MainActor
    func testPairingMembershipEndsAtTheCapturedHostAndMatchesItsKeysAndGeneration() throws {
        let f = try RestoreFixture()
        let fields: [String: String] = [
            "device_pub": Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            "device_sign_pub": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            "unlock_auth_pub": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            "host_channel_pub": RemoteRecoveryKit.base64URL(f.hostKey.publicKey.rawRepresentation),
            "nonce": Data(repeating: 3, count: 32).base64EncodedString()]
        let raw = try JSONSerialization.data(withJSONObject: ["type": "verifyReveal", "data": fields])
        let reveal = try RemotePairingReveal(originalJSON: raw)
        let keys = try RemotePairingKeys(signingPublicKey: f.setup.keys.key.publicKey.x963Representation,
            encryptionPublicKey: XCTUnwrap(f.log.member(deviceId: "manager-a")?.encKey).raw,
            recoverySigningPublicKey: f.kit.handle.recoveryKey().raw, genesisHash: f.kit.genesisHash, nonce: Data(repeating: 4, count: 32))
        let commitRaw = try JSONSerialization.data(withJSONObject: ["type": "verifyCommit", "data": [
            "device_id": "host-a", "commitment": reveal.commitment().base64EncodedString(), "host_trust_gen": 4]])
        let commit = try RemotePairingCommit(originalJSON: commitRaw,
            context: RemotePairingContext(accountID: f.kit.accountID, hostID: "host-a", linkGeneration: UUID()))
        XCTAssertThrowsError(try keys.membershipEntries(log: f.log, managerID: "manager-a", commit: commit, reveal: reveal))
        try RestoreFixture.append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 4,
            "host_key": ["alg": "ed25519", "pub": fields["host_channel_pub"]!]]], log: f.log, fixture: f.setup)
        XCTAssertEqual(try keys.membershipEntries(log: f.log, managerID: "manager-a", commit: commit, reveal: reveal), f.log.entries())
        XCTAssertThrowsError(try keys.membershipEntries(log: f.log, managerID: "other", commit: commit, reveal: reveal))
    }

    @MainActor
    func testRestartRequiresNewHostProofBeforeRetryingTheExactEnrollment() throws {
        let f = try RestoreFixture()
        try f.confirm()
        let request = try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs)
        f.flow = nil
        f.flow = try RemoteRecoveryRestore(kit: f.kit, checkpoint: XCTUnwrap(f.checkpoint), persist: { [unowned f] in try f.write($0) })
        XCTAssertThrowsError(try f.flow.outstanding())
        XCTAssertThrowsError(try f.flow.recoveredKeys())
        try f.confirm()
        XCTAssertEqual(try f.flow.outstanding(), request)
        XCTAssertEqual(f.flow.phase, .enrollmentPending)
    }

    @MainActor
    func testKeysEnrollmentAndCommitWriteFailuresHaltUntilProtectedReload() throws {
        for stage in ["keys", "enrollment", "commit"] {
            let f = try RestoreFixture()
            if stage == "keys" {
                try f.fetch()
                let probe = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
                try f.flow.receivedHostAccept(f.signedAccept(for: probe), probeID: probe.id, now: f.setup.now)
            } else { try f.confirm() }
            if stage == "commit" { _ = try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs) }
            let saved = f.checkpoint
            f.fail = true
            switch stage {
            case "keys": XCTAssertThrowsError(try f.flow.attempt(now: f.setup.now))
            case "enrollment": XCTAssertThrowsError(try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs))
            default: XCTAssertThrowsError(try f.flow.relayStored(now: f.setup.now))
            }
            XCTAssertEqual(f.flow.phase, .storageUncertain)
            XCTAssertEqual(f.checkpoint, saved)
            XCTAssertThrowsError(try f.flow.recoveredKeys())
            XCTAssertThrowsError(try f.flow.outstanding())
        }
    }

    @MainActor
    func testReentrantDisconnectDuringKeyCommitDoesNotRestoreFreshness() throws {
        let f = try RestoreFixture()
        try f.fetch()
        let probe = try f.flow.beginHostProbe(hostID: "host-a", replacementDeviceID: "replacement-manager", now: f.setup.now)
        try f.flow.receivedHostAccept(f.signedAccept(for: probe), probeID: probe.id, now: f.setup.now)
        f.beforeWrite = { f.flow.invalidateFreshness() }
        XCTAssertThrowsError(try f.flow.attempt(now: f.setup.now))
        XCTAssertThrowsError(try f.flow.recoveredKeys())
        XCTAssertThrowsError(try f.flow.enroll(confirmedMemberJSON: f.member, signedAt: f.setup.now.wallMs))
    }
}
