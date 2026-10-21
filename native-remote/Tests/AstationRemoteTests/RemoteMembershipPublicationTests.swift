import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private func b64u(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
}

private final class PublicationKeys: AppKeyProvider, @unchecked Sendable {
    // Test-only software manager. Production supplies its native protected key provider.
    let key = Curve25519.Signing.PrivateKey()
    var requests: [SignRequest] = []
    var beforeSign: (() throws -> Void)?
    var denied = false

    func publicKey(keyId: String) throws -> PublicKeyData {
        PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation)
    }
    func sign(request: SignRequest) throws -> Data {
        try beforeSign?()
        requests.append(request)
        if denied { throw RemotePublicationError.busy }
        return try key.signature(for: request.input)
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemotePublicationError.busy }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw RemotePublicationError.busy
    }
}

@MainActor
private final class PublicationFixture {
    let keys = PublicationKeys()
    let clock = HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "publication-test")
    let log: MembershipLog
    var stored: Data?
    var writes = 0
    var failWrite = false
    var onPersist: (() throws -> Void)?
    private var active: RemoteMembershipPublication?
    var publication: RemoteMembershipPublication {
        if let active { return active }
        let created = RemoteMembershipPublication(log: log, persist: { [unowned self] in try persist($0) })
        active = created
        return created
    }

    init() throws {
        let body: [String: Any] = [
            "type": "atem-membership-entry", "v": 1, "account_id": "account-a",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64),
            "action": "genesis", "signer": "manager-a", "signed_at": clock.wallMs,
            "member": ["device_id": "manager-a", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "ed25519", "pub": b64u(keys.key.publicKey.rawRepresentation)],
                "enc_key": ["alg": "x25519", "pub": b64u(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]],
            "recovery_key": ["alg": "ed25519", "pub": b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]
        ]
        let info = try signedObjectInfo(json: json(["body": body, "sig": b64u(Data(repeating: 0, count: 64))]))
        let entry = try json(["body": body, "sig": b64u(keys.key.signature(for: info.signingInput))])
        log = try MembershipLog.verify(accountId: "account-a", genesisHash: XCTUnwrap(info.entryHash),
            entries: [entry], now: clock)
    }

    func persist(_ bytes: Data) throws {
        writes += 1
        try onPersist?()
        if failWrite { throw RemotePublicationError.storageUncertain }
        stored = bytes
    }

    func action(_ host: String = "host-a", generation: UInt64 = 3) throws -> String {
        try json(["action": "add_host", "host": ["host_id": host, "host_trust_gen": generation,
            "host_key": ["alg": "ed25519", "pub": b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]])
    }

    func prepare() throws {
        try publication.prepare(actionJSON: action(), signer: "manager-a", signedAt: clock.wallMs)
    }

    func restore() throws -> RemoteMembershipPublication {
        active = nil // A restart drops the old core and its process-wide publisher claim.
        return try RemoteMembershipPublication(checkpoint: XCTUnwrap(stored), accountID: log.accountId(),
            genesisHash: log.genesisHash(), now: clock, persist: { [unowned self] in try persist($0) })
    }
}

final class RemoteMembershipPublicationTests: XCTestCase {
    @MainActor
    func testHostEntryUsesTheCapturedAuthenticatedIdentityAndExactGeneration() throws {
        for generation: UInt64 in [3, 9_007_199_254_740_991] {
            let f = try PublicationFixture()
            let context = RemotePairingContext(accountID: "account-a", hostID: "host-a", linkGeneration: UUID())
            let raw = Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"host-a\",\"commitment\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"host_trust_gen\":\(generation)}}".utf8)
            let captured = try RemotePairingCommit(originalJSON: raw, context: context)
            let hostKey = PublicKeyData(alg: .ed25519, raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
            let body = try f.publication.prepareHost(commit: captured, hostChannelKey: hostKey,
                signer: "manager-a", signedAt: f.clock.wallMs)
            XCTAssertTrue(body.contains("\"host_trust_gen\":\(generation)"))
            let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
            XCTAssertTrue(request.entryJson.contains("\"host_id\":\"host-a\""))
            _ = try f.publication.relayStored(now: f.clock)
            let committed = try MembershipLog.verify(accountId: "account-a", genesisHash: f.log.genesisHash(),
                entries: f.publication.entries, now: f.clock)
            XCTAssertEqual(committed.host(hostId: "host-a")?.hostTrustGen, generation)
            XCTAssertEqual(committed.host(hostId: "host-a")?.hostKey, hostKey)
        }
    }

    @MainActor
    func testHostEntryRefusesAnotherAccountAndNonSigningHostKeys() throws {
        let f = try PublicationFixture()
        let raw = Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"host-a\",\"commitment\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"host_trust_gen\":3}}".utf8)
        let other = try RemotePairingCommit(originalJSON: raw,
            context: RemotePairingContext(accountID: "other", hostID: "host-a", linkGeneration: UUID()))
        let hostKey = PublicKeyData(alg: .ed25519, raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try f.publication.prepareHost(commit: other, hostChannelKey: hostKey,
            signer: "manager-a", signedAt: f.clock.wallMs))
        let current = try RemotePairingCommit(originalJSON: raw,
            context: RemotePairingContext(accountID: "account-a", hostID: "host-a", linkGeneration: UUID()))
        let encryptionKey = PublicKeyData(alg: .x25519, raw: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try f.publication.prepareHost(commit: current, hostChannelKey: encryptionKey,
            signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertEqual(f.writes, 0)
        XCTAssertTrue(f.keys.requests.isEmpty)
    }

    @MainActor
    func testSecondPublisherCannotReserveTheSameManagerWhileAnAppendIsPending() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let second = RemoteMembershipPublication(log: f.log, persist: { _ in XCTFail("Competing publisher reached storage") })
        XCTAssertThrowsError(try second.prepare(actionJSON: f.action("host-b"), signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertNil(try second.outstanding())
        XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testBodyAndSignatureAreDurableBeforeTheyCanBeUsed() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let bodyCheckpoint = try XCTUnwrap(f.stored)
        XCTAssertEqual(f.keys.requests.count, 0)
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertNil(try f.publication.outstanding())
        f.keys.beforeSign = { [unowned f] in XCTAssertEqual(f.stored, bodyCheckpoint) }
        let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.writes, 2)
        XCTAssertNotEqual(f.stored, bodyCheckpoint)
        XCTAssertEqual(f.keys.requests.first?.purpose, .host)
        XCTAssertEqual(f.keys.requests.first?.freshConfirmation, true)
        XCTAssertNotNil(f.keys.requests.first?.bodyJson)
        XCTAssertEqual(request.expected, f.log.head())
        XCTAssertEqual(try f.publication.outstanding(), request)
        XCTAssertEqual(f.publication.entries.count, 1, "Signing is not a relay commit")
        guard case .committed(let head) = try f.publication.relayStored(now: f.clock) else {
            return XCTFail("Expected committed")
        }
        XCTAssertEqual(head.seq, 2)
        XCTAssertEqual(f.publication.entries.count, 2)
        XCTAssertNil(try f.publication.outstanding())
        let restored = try f.restore()
        XCTAssertEqual(restored.head, head)
        XCTAssertNil(try restored.outstanding())
    }

    @MainActor
    func testCrashAfterPrepareResignsTheSameBodyWithFreshConfirmation() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let restored = try f.restore()
        let request = try restored.sign(provider: f.keys, keyID: "manager-key")
        let body = try XCTUnwrap(f.keys.requests.first?.bodyJson)
        let info = try signedObjectInfo(json: request.entryJson)
        XCTAssertEqual(info.bodyJcs, body)
        XCTAssertEqual(restored.head.seq, 1)
    }

    @MainActor
    func testLostReplyAndRestartResendTheExactStoredSignature() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let first = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        let restored = try f.restore()
        XCTAssertEqual(try restored.outstanding(), first)
        XCTAssertEqual(try restored.sign(provider: f.keys, keyID: "manager-key"), first)
        XCTAssertEqual(f.keys.requests.count, 1, "A delivery retry cannot ask the key to sign again")
        XCTAssertThrowsError(try restored.prepare(actionJSON: f.action("different-host"),
            signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertEqual(try restored.outstanding(), first)
    }

    @MainActor
    func testBodyWriteFailurePreventsSigningAndHaltsUntilReload() throws {
        let f = try PublicationFixture()
        f.failWrite = true
        XCTAssertThrowsError(try f.prepare())
        XCTAssertTrue(f.publication.storageUncertain)
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertThrowsError(try f.publication.outstanding())
        XCTAssertEqual(f.keys.requests.count, 0)
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertNil(f.stored)
    }

    @MainActor
    func testSignatureWriteFailureExposesNoRequestAndKeepsTheDurableBody() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let bodyCheckpoint = f.stored
        f.failWrite = true
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertEqual(f.stored, bodyCheckpoint)
        XCTAssertThrowsError(try f.publication.outstanding())
        XCTAssertEqual(f.publication.head.seq, 1)
        f.failWrite = false
        let restored = try f.restore()
        XCTAssertNil(try restored.outstanding())
        _ = try restored.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.keys.requests.count, 2)
        XCTAssertEqual(f.keys.requests[0].input, f.keys.requests[1].input)
        XCTAssertTrue(f.keys.requests.allSatisfy(\.freshConfirmation))
    }

    @MainActor
    func testCommitWriteFailureDoesNotPublishALocalHeadOrLoseTheRetry() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        f.failWrite = true
        XCTAssertThrowsError(try f.publication.relayStored(now: f.clock))
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertEqual(f.publication.entries.count, 1)
        f.failWrite = false
        let restored = try f.restore()
        XCTAssertEqual(try restored.outstanding(), request)
        _ = try restored.relayStored(now: f.clock)
        XCTAssertEqual(restored.head.seq, 2)
        XCTAssertEqual(f.keys.requests.count, 1)
    }

    @MainActor
    func testConflictVerifiesTheWinningLogAndRequiresANewConfirmation() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let first = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        // Simulate a separately signed winner arriving from another process, not a second live FFI publisher.
        let body = try f.log.draftEntry(signer: "manager-a", signedAt: f.clock.wallMs, actionJson: f.action("host-b"))
        let bodyObject = try JSONSerialization.jsonObject(with: Data(body.utf8))
        let info = try signedObjectInfo(json: json(["body": bodyObject, "sig": b64u(Data(repeating: 0, count: 64))]))
        let winner = try json(["body": bodyObject, "sig": b64u(f.keys.key.signature(for: info.signingInput))])
        let winningLog = f.log.snapshot()
        _ = try winningLog.extend(entries: [winner], now: f.clock)
        guard case .lostRace = try f.publication.relayConflict(head: winningLog.head(),
            entries: [winner], more: false, now: f.clock) else {
            return XCTFail("Expected lost race")
        }
        XCTAssertEqual(f.publication.head, winningLog.head())
        XCTAssertNil(try f.publication.outstanding())
        let restored = try f.restore()
        XCTAssertNil(try restored.outstanding())
        try restored.prepare(actionJSON: f.action(), signer: "manager-a", signedAt: f.clock.wallMs)
        let next = try restored.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertNotEqual(next.entryHash, first.entryHash)
        XCTAssertEqual(next.expected.seq, 2)
        XCTAssertEqual(f.keys.requests.count, 2)
        XCTAssertNotEqual(f.keys.requests.first?.input, f.keys.requests.last?.input)
    }

    @MainActor
    func testDeniedSigningKeepsTheBodyAndReentrantCallsAreRefused() throws {
        let f = try PublicationFixture()
        f.onPersist = { [unowned f] in XCTAssertThrowsError(try f.publication.outstanding()) }
        try f.prepare()
        f.keys.denied = true
        f.keys.beforeSign = { [unowned f] in XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "nested")) }
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertFalse(f.publication.storageUncertain)
        XCTAssertNil(try f.publication.outstanding())
        XCTAssertEqual(f.writes, 1)
        f.keys.denied = false
        _ = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.keys.requests[0].input, f.keys.requests[1].input)
    }

    @MainActor
    func testCheckpointCannotMoveToAnotherAccountOrGenesis() throws {
        let f = try PublicationFixture()
        try f.prepare()
        for (account, genesis) in [("other-account", f.log.genesisHash()), (f.log.accountId(), String(repeating: "0", count: 64))] {
            XCTAssertThrowsError(try RemoteMembershipPublication(checkpoint: XCTUnwrap(f.stored),
                accountID: account, genesisHash: genesis, now: f.clock, persist: { _ in }))
        }
        let invalid = Data("{\"version\":1,\"version\":2}".utf8)
        XCTAssertThrowsError(try RemoteMembershipPublication(checkpoint: invalid,
            accountID: f.log.accountId(), genesisHash: f.log.genesisHash(), now: f.clock, persist: { _ in }))
    }

    @MainActor
    func testInconsistentRelayReplyCannotCauseASiblingSignatureEvenAfterRestart() throws {
        let f = try PublicationFixture()
        try f.prepare()
        _ = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        guard case .relayInconsistent = try f.publication.relayConflict(head: f.log.head(), entries: [], more: false, now: f.clock) else {
            return XCTFail("Expected inconsistent reply")
        }
        XCTAssertTrue(f.publication.requiresRefresh)
        XCTAssertThrowsError(try f.prepare())
        let restored = try f.restore()
        XCTAssertTrue(restored.requiresRefresh)
        XCTAssertThrowsError(try restored.prepare(actionJSON: f.action("host-b"), signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertThrowsError(try restored.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertEqual(f.keys.requests.count, 1)
    }

    @MainActor
    func testACompleteLogLargerThanTheSharedJSONMessageLimitCanBeReloaded() throws {
        let f = try PublicationFixture()
        let log = f.log.snapshot()
        let serviceKey = b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let hosts = (0..<16).map { String(format: "host-%02d-", $0) + String(repeating: "x", count: 115) }
        var encodedBytes = log.entries().reduce(0) { $0 + $1.utf8.count }
        while encodedBytes < 1_100_000 {
            let add: [String: Any] = ["action": "add", "member": [
                "device_id": "service-a", "kind": "service", "roles": ["service"],
                "auth_key": ["alg": "ed25519", "pub": serviceKey],
                "scope": ["hosts": hosts, "ops": ["view"]], "expires_at": f.clock.wallMs + 60_000
            ]]
            for action in [try json(add), try json(["action": "remove", "device_id": "service-a"])] {
                let body = try log.draftEntry(signer: "manager-a", signedAt: f.clock.wallMs, actionJson: action)
                let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
                let info = try signedObjectInfo(json: json(["body": object, "sig": b64u(Data(repeating: 0, count: 64))]))
                let entry = try json(["body": object, "sig": b64u(f.keys.key.signature(for: info.signingInput))])
                _ = try log.extend(entries: [entry], now: f.clock)
                encodedBytes += entry.utf8.count
            }
            guard log.head().seq < 1_024 else { return XCTFail("Fixture exceeded the contract's log bound") }
        }
        var saved: Data?
        var publication: RemoteMembershipPublication? = RemoteMembershipPublication(log: log, persist: { saved = $0 })
        try XCTUnwrap(publication).prepare(actionJSON: f.action(), signer: "manager-a", signedAt: f.clock.wallMs)
        XCTAssertGreaterThan(encodedBytes, 1_048_576)
        let checkpoint = try XCTUnwrap(saved)
        publication = nil
        let restored = try RemoteMembershipPublication(checkpoint: checkpoint,
            accountID: log.accountId(), genesisHash: log.genesisHash(), now: f.clock, persist: { _ in })
        XCTAssertEqual(restored.head, log.head())
        XCTAssertEqual(restored.entries, log.entries())
        XCTAssertNil(try restored.outstanding(), "The saved body has not been signed")
        _ = try restored.sign(provider: f.keys, keyID: "manager-key")
    }
}
