import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

enum VerifierReportTestSupport {
    static let wall: UInt64 = 1_792_400_000_000

    static func signed(_ body: Any, sign: (Data) throws -> Data) throws -> String {
        let info = try signedObjectInfo(json: String(decoding: JSONSerialization.data(withJSONObject: [
            "body": body, "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]), as: UTF8.self))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["body": body,
            "sig": RemoteRecoveryKit.base64URL(sign(info.signingInput))]), as: UTF8.self)
    }

    static func log(account: String, member: String, auth: PublicKeyData, encryption: PublicKeyData,
                    sign: (Data) throws -> Data) throws -> MembershipLog {
        let publicKey: [String: Any] = ["alg": auth.alg == .p256 ? "p256" : "ed25519",
            "pub": RemoteRecoveryKit.base64URL(auth.raw)]
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": account,
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": member,
            "signed_at": wall, "member": ["device_id": member, "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": publicKey, "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(encryption.raw)]],
            "recovery_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]
        let genesis = try signed(body, sign: sign)
        return try MembershipLog.verify(accountId: account, genesisHash: signedObjectInfo(json: genesis).entryHash!,
            entries: [genesis], now: HostClock(wallMs: wall, monoMs: 100, bootId: "member-report-tests"))
    }
}

@MainActor
private final class MemberReportFixture {
    let key = Curve25519.Signing.PrivateKey()
    let origin = "https://station.example"
    let log: MembershipLog
    var time: UInt64 = 100
    var wall = VerifierReportTestSupport.wall
    var current = true
    var gate: RemoteVerifierSigningGate!
    var evidence: RemoteMemberVerifierEvidence!
    var slots: [RemoteMemberVerifierSlot] = []
    var checkpoint: Data?
    var failWrite = false
    var failAfterWrite = false
    var duringWrite: (() -> Void)?
    var journal: RemoteMemberVerifierJournal!

    init(slotNames: [String] = ["phone", "worker"], service: Bool = false) throws {
        let key = self.key
        log = try VerifierReportTestSupport.log(account: "account", member: "manager",
            auth: PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation),
            encryption: PublicKeyData(alg: .x25519, raw: Data(repeating: 7, count: 32)), sign: { try key.signature(for: $0) })
        try append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(key.publicKey.rawRepresentation)]]])
        if service {
            try append(["action": "add", "member": ["device_id": "service", "kind": "service", "roles": ["service"],
                "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(key.publicKey.rawRepresentation)],
                "scope": ["hosts": ["host"], "ops": ["launch", "view"]], "expires_at": wall + 1_000]])
        }
        slots = try slotNames.map { try RemoteMemberVerifierSlot(memberID: service ? "service" : "manager",
            slot: $0, process: verifierReportProcess()) }
        let ids: [RemoteVerifierID] = [.member("manager"), .host("host"), .stationReplica("station")]
            + (service ? [.member("service")] : [])
        gate = try RemoteVerifierSigningGate(log: log, verifiers: ids, now: { [unowned self] in time })
        let station = try gate.connect(.stationReplica("station"))
        try gate.observeConsumer(verifierInventory(), on: station)
        let host = try gate.connect(.host("host"))
        let welcome = WelcomeInfo(principal: "member:manager", clientKind: "native", permissions: ["control", "manage", "view"],
            revision: 9, features: [], accountId: log.accountId(), atemDeviceId: "host", hostTrustGen: 1,
            attachmentGen: "attachment", controllerSession: "controller", runtimeGen: "runtime", authorizationMsLeft: 100_000,
            serverTime: wall, head: log.head(), pendingRecovery: [], channelId: "channel", scopeJson: nil,
            verifier: verifierInventory(), json: "")
        try gate.observeHostWelcome(welcome, on: host)
        if service {
            let manager = try gate.connect(.member("manager"))
            try gate.observeConsumer(verifierInventory(), on: manager)
        }
        evidence = try RemoteMemberVerifierEvidence(gate: gate, log: log, origin: origin, slots: slots,
            journal: makeJournal(creating: true),
            current: { [unowned self] in current }, now: { [unowned self] in time })
    }

    func makeJournal(creating: Bool = false) throws -> RemoteMemberVerifierJournal {
        let result = try RemoteMemberVerifierJournal(log: log, origin: origin, creating: creating, read: { [unowned self] in checkpoint },
            persist: { [unowned self] bytes in
                if failWrite { throw RemoteRecoveryStoreError.changed }
                checkpoint = bytes
                duringWrite?()
                if failAfterWrite { throw RemoteRecoveryStoreError.changed }
            })
        journal = result
        return result
    }

    func append(_ action: [String: Any]) throws {
        let body = try log.draftEntry(signer: "manager", signedAt: wall,
            actionJson: String(decoding: JSONSerialization.data(withJSONObject: action), as: UTF8.self))
        let entry = try VerifierReportTestSupport.signed(JSONSerialization.jsonObject(with: Data(body.utf8)), sign: { try key.signature(for: $0) })
        let result = try log.extend(entries: [entry], now: HostClock(wallMs: wall, monoMs: time, bootId: "member-report-tests"))
        XCTAssertNil(result.stop); XCTAssertEqual(result.appended, 1)
    }

    func begin(_ index: Int = 0) throws -> RemoteMemberVerifierEvidence.Challenge {
        try evidence.begin(slots[index], log: log, wallMs: wall)
    }

    func report(_ challenge: RemoteMemberVerifierEvidence.Challenge, log: MembershipLog? = nil,
                mutate: ((inout [String: Any]) -> Void)? = nil) throws -> String {
        let request = try VerifierReportRequest(log: log ?? self.log, challengeJson: challenge.json,
            signer: (challenge.slot.memberID == "service" ? "service:" : "member:") + challenge.slot.memberID,
            slot: challenge.slot.slot, origin: origin, keyId: challenge.slot.memberID, nowMs: wall)
        let original = try request.finish(signature: key.signature(for: request.signRequest().input))
        guard let mutate else { return original }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var body = try XCTUnwrap(object["body"] as? [String: Any])
        mutate(&body)
        return try VerifierReportTestSupport.signed(body, sign: { try key.signature(for: $0) })
    }

    func receive(_ report: String, _ challenge: RemoteMemberVerifierEvidence.Challenge) throws {
        try evidence.receive(report, for: challenge, log: log, wallMs: wall)
    }

    func authorize() throws {
        let review = try RemoteHostSenderReview(stationOrigin: origin, log: log, managerID: "manager", hostID: "host",
            operation: .revoke(interruptRunning: false), now: HostClock(wallMs: wall, monoMs: time, bootId: "member-report-tests"))
        try gate.authorize(review.signingRequest(managerID: "manager"), log: log)
    }

    func confirmAll() throws {
        for index in slots.indices { let next = try begin(index); try receive(report(next), next) }
    }
}

final class RemoteMemberVerifierEvidenceTests: XCTestCase {
    @MainActor
    func testAnotherConsumersDurableHigherInventoryInvalidatesOlderLiveEvidenceAtSigningRefresh() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        try f.confirmAll()
        XCTAssertNoThrow(try f.authorize())
        let gate = try RemoteVerifierSigningGate(log: f.log,
            verifiers: [.member("manager"), .host("host"), .stationReplica("station")], now: { f.time })
        let other = try RemoteMemberVerifierEvidence(gate: gate, log: f.log, origin: f.origin,
            slots: f.slots, journal: f.journal, current: { true }, now: { f.time })
        let challenge = try other.begin(f.slots[0], log: f.log, wallMs: f.wall)
        let report = try f.report(challenge) { body in
            var inventory = body["verifier"] as! [String: Any]; inventory["version"] = 3; body["verifier"] = inventory
        }
        try other.receive(report, for: challenge, log: f.log, wallMs: f.wall)
        try f.evidence.refresh(log: f.log, wallMs: f.wall)
        XCTAssertThrowsError(try f.authorize())
    }

    @MainActor
    func testReporterAnchorRejectsAnotherProtocolRootButAllowsVerifiedHeadAdvancement() throws {
        let f = try MemberReportFixture(), other = try MemberReportFixture()
        let anchor = try RemoteVerifierReportAnchor(log: f.log)
        XCTAssertNoThrow(try anchor.require(f.log))
        XCTAssertThrowsError(try anchor.require(other.log))
        try f.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "manage", "view"]])
        XCTAssertNoThrow(try anchor.require(f.log))
    }

    @MainActor
    func testPersistenceDelayAndAssociationLossCannotExposeAnOtherwiseValidReport() throws {
        let delayed = try MemberReportFixture(slotNames: ["phone"])
        let challenge = try delayed.begin(), report = try delayed.report(challenge)
        delayed.duringWrite = { delayed.time += 30_000 }
        try delayed.receive(report, challenge)
        XCTAssertThrowsError(try delayed.authorize(), "Persistence consumes the same original deadline")
        let changed = try MemberReportFixture(slotNames: ["phone"])
        let next = try changed.begin(), proof = try changed.report(next)
        changed.duringWrite = { changed.current = false }
        XCTAssertThrowsError(try changed.receive(proof, next))
        XCTAssertThrowsError(try changed.authorize())
    }

    @MainActor
    func testDurableHighWaterAndConflictsSurviveConsumerRestartWithoutRestoringLiveEvidence() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        let original = try f.begin()
        try f.receive(f.report(original) { body in
            var inventory = body["verifier"] as! [String: Any]; inventory["version"] = 3; body["verifier"] = inventory
        }, original)
        let stored = try XCTUnwrap(f.checkpoint)
        f.evidence.retire()
        let gate = try RemoteVerifierSigningGate(log: f.log,
            verifiers: [.member("manager"), .host("host"), .stationReplica("station")], now: { f.time })
        let journal = try f.makeJournal()
        let evidence = try RemoteMemberVerifierEvidence(gate: gate, log: f.log, origin: f.origin,
            slots: f.slots, journal: journal, current: { true }, now: { f.time })
        let next = try evidence.begin(f.slots[0], log: f.log, wallMs: f.wall)
        XCTAssertThrowsError(try evidence.receive(f.report(next), for: next, log: f.log, wallMs: f.wall)) {
            XCTAssertEqual($0 as? RemoteVerifierGateError, .downgradedInventory)
        }
        XCTAssertEqual(f.checkpoint, stored)
        let conflict = try evidence.begin(f.slots[0], log: f.log, wallMs: f.wall)
        let other = try f.report(conflict) { $0["process"] = RemoteRecoveryKit.base64URL(Data(repeating: 2, count: 16)) }
        XCTAssertThrowsError(try evidence.receive(other, for: conflict, log: f.log, wallMs: f.wall))
        evidence.retire()
        let restarted = try RemoteMemberVerifierEvidence(gate: gate, log: f.log, origin: f.origin,
            slots: f.slots, journal: f.makeJournal(), current: { true }, now: { f.time })
        XCTAssertThrowsError(try restarted.begin(f.slots[0], log: f.log, wallMs: f.wall))
    }

    @MainActor
    func testJournalWriteFailureNeverExposesEvidenceAndFencesAnUncertainConsumer() throws {
        for committed in [false, true] {
            let f = try MemberReportFixture(slotNames: ["phone"])
            let before = f.checkpoint
            let next = try f.begin(), report = try f.report(next)
            f.failWrite = !committed; f.failAfterWrite = committed
            XCTAssertThrowsError(try f.receive(report, next))
            XCTAssertTrue(f.journal.storageUncertain)
            XCTAssertThrowsError(try f.authorize())
            XCTAssertEqual(f.checkpoint != before, committed)
            f.failWrite = false; f.failAfterWrite = false
            XCTAssertThrowsError(try f.begin(), "Failed persistence retires this consumer")
            let restored = try f.makeJournal()
            XCTAssertEqual(restored.retained(f.slots[0]).highest != nil, committed)
            XCTAssertThrowsError(try f.authorize(), "A durably committed watermark is not live evidence")
        }
    }

    @MainActor
    func testChangedJournalStorageRetiresCurrentProofAndMalformedHistoryCannotResetIt() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        try f.confirmAll()
        let saved = try XCTUnwrap(f.checkpoint)
        f.checkpoint = nil
        XCTAssertThrowsError(try f.evidence.refresh(log: f.log, wallMs: f.wall))
        XCTAssertTrue(f.journal.storageUncertain)
        XCTAssertThrowsError(try f.authorize())
        XCTAssertThrowsError(try f.makeJournal(), "Missing retained history cannot be treated as first use")
        f.checkpoint = saved
        XCTAssertThrowsError(try f.begin())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var otherAccount = raw; otherAccount["account"] = "another-account"
        var unknown = raw; unknown["extra"] = true
        var nullVersion = raw
        var rows = raw["rows"] as! [[String: Any]]
        rows[0]["version"] = NSNull(); rows[0]["actions"] = NSNull(); rows[0]["conflicted"] = true
        nullVersion["rows"] = rows
        for object in [otherAccount, unknown, nullVersion] {
            f.checkpoint = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try f.makeJournal())
        }
        let text = String(decoding: saved, as: UTF8.self)
        f.checkpoint = Data((String(text.dropLast()) + ",\"v\":1}").utf8)
        XCTAssertThrowsError(try f.makeJournal())
        XCTAssertThrowsError(try RemoteMemberVerifierJournal(log: f.log, origin: "https://other.example",
            read: { saved }, persist: { _ in XCTFail("Loading must never replace foreign history") }))
    }

    @MainActor
    func testEveryReviewedProcessIsRequiredAtActualSigningBoundary() throws {
        let f = try MemberReportFixture()
        XCTAssertThrowsError(try f.authorize())
        let phone = try f.begin(), worker = try f.begin(1)
        try f.receive(f.report(phone), phone)
        XCTAssertThrowsError(try f.authorize(), "A live process cannot remove an unavailable slot")
        try f.receive(f.report(worker), worker)
        XCTAssertNoThrow(try f.authorize())
        f.time += 30_000
        XCTAssertThrowsError(try f.authorize(), "Expiry is enforced even if a lifecycle callback was delayed")
        try f.evidence.refresh(log: f.log, wallMs: f.wall)
        XCTAssertThrowsError(try f.authorize())
        let fresh = try f.begin()
        try f.receive(f.report(fresh), fresh)
        XCTAssertThrowsError(try f.authorize(), "Expired worker remains required")
        let workerAgain = try f.begin(1)
        try f.receive(f.report(workerAgain), workerAgain)
        XCTAssertNoThrow(try f.authorize())
    }

    @MainActor
    func testWrongSlotDoesNotConsumeExpectationAndReplayCannotRenewEvidence() throws {
        let f = try MemberReportFixture()
        let phone = try f.begin(), worker = try f.begin(1)
        let phoneReport = try f.report(phone), workerReport = try f.report(worker)
        XCTAssertThrowsError(try f.receive(workerReport, phone))
        try f.receive(phoneReport, phone)
        try f.receive(workerReport, worker)
        XCTAssertNoThrow(try f.authorize())
        f.time += 29_999
        XCTAssertThrowsError(try f.receive(phoneReport, phone))
        XCTAssertNoThrow(try f.authorize())
        f.time += 1
        XCTAssertThrowsError(try f.authorize())
        let next = try f.begin()
        XCTAssertThrowsError(try f.receive(phoneReport, next))
        try f.receive(f.report(next), next)
    }

    @MainActor
    func testTwoAuthenticatedProcessesInOneSlotConflictInsteadOfLastWriterWinning() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        let challenge = try f.begin()
        let original = try f.report(challenge)
        let other = try f.report(challenge) { $0["process"] = RemoteRecoveryKit.base64URL(Data(repeating: 2, count: 16)) }
        try f.receive(original, challenge)
        XCTAssertNoThrow(try f.authorize())
        XCTAssertThrowsError(try f.receive(other, challenge), "Conflicting valid response to an already consumed challenge")
        XCTAssertThrowsError(try f.authorize())
        XCTAssertThrowsError(try f.begin(), "A process conflict requires protected roster review")
        try f.evidence.refresh(log: f.log, wallMs: f.wall)
        XCTAssertThrowsError(try f.authorize())

        let fresh = try MemberReportFixture(slotNames: ["phone"])
        let pending = try fresh.begin()
        let wrong = try fresh.report(pending) { $0["process"] = RemoteRecoveryKit.base64URL(Data(repeating: 3, count: 16)) }
        XCTAssertThrowsError(try fresh.receive(wrong, pending))
        XCTAssertThrowsError(try fresh.receive(fresh.report(pending), pending))
        XCTAssertThrowsError(try fresh.authorize())
    }

    @MainActor
    func testInventoryHighWaterSurvivesFailedPollExpiryAndReconnect() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        let initial = try f.begin()
        let high: (inout [String: Any]) -> Void = { body in
            var inventory = body["verifier"] as! [String: Any]; inventory["version"] = 3; body["verifier"] = inventory
        }
        try f.receive(f.report(initial, mutate: high), initial)
        XCTAssertNoThrow(try f.authorize())
        f.time += 30_000
        try f.evidence.refresh(log: f.log, wallMs: f.wall)
        let low = try f.begin()
        XCTAssertThrowsError(try f.receive(f.report(low), low)) { XCTAssertEqual($0 as? RemoteVerifierGateError, .downgradedInventory) }
        XCTAssertThrowsError(try f.authorize())
        let retry = try f.begin()
        f.evidence.failed(retry)
        let good = try f.begin()
        try f.receive(f.report(good, mutate: high), good)
        XCTAssertNoThrow(try f.authorize())
        let narrow = try f.begin()
        let narrowed = try f.report(narrow) { body in
            var inventory = body["verifier"] as! [String: Any]
            inventory["version"] = 3
            inventory["actions"] = (inventory["actions"] as! [String]).filter { $0 != "project_set" }
            body["verifier"] = inventory
        }
        XCTAssertThrowsError(try f.receive(narrowed, narrow))
        XCTAssertThrowsError(try f.authorize())
    }

    @MainActor
    func testDelayedSupersededFailureCannotWithdrawNewEvidence() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        let old = try f.begin(), next = try f.begin()
        XCTAssertThrowsError(try f.receive(f.report(old), old))
        try f.receive(f.report(next), next)
        f.evidence.failed(old)
        XCTAssertNoThrow(try f.authorize())
        f.evidence.retire()
        XCTAssertThrowsError(try f.receive(f.report(next), next))
        XCTAssertThrowsError(try f.begin())
        XCTAssertThrowsError(try f.authorize())
    }

    @MainActor
    func testDeadlineIncludesTokenDelaySleepAndClockRollback() throws {
        for delay: UInt64 in [30_000, 90_000] {
            let f = try MemberReportFixture(slotNames: ["phone"])
            let request = try f.begin(), report = try f.report(request)
            f.time += delay // Wall time intentionally remains unchanged.
            XCTAssertThrowsError(try f.receive(report, request))
            XCTAssertThrowsError(try f.authorize())
        }
        let f = try MemberReportFixture(slotNames: ["phone"])
        try f.confirmAll()
        f.time -= 1
        XCTAssertThrowsError(try f.evidence.refresh(log: f.log, wallMs: f.wall))
        XCTAssertThrowsError(try f.authorize())
        f.time += 1
        XCTAssertThrowsError(try f.begin(), "A clock rollback retires the collection owner")
    }

    @MainActor
    func testAssociationAndMembershipChangesRetireAllProofs() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        try f.confirmAll()
        f.current = false
        XCTAssertThrowsError(try f.evidence.refresh(log: f.log, wallMs: f.wall))
        f.current = true
        XCTAssertThrowsError(try f.begin())
        XCTAssertThrowsError(try f.authorize())

        let changed = try MemberReportFixture(slotNames: ["phone"])
        let challenge = try changed.begin(), report = try changed.report(challenge)
        try changed.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "manage", "view"]])
        XCTAssertThrowsError(try changed.receive(report, challenge))
        XCTAssertThrowsError(try changed.authorize())
    }

    @MainActor
    func testAncestorReportIsInsufficientForCurrentSigningHead() throws {
        let f = try MemberReportFixture(slotNames: ["phone"]), ancestor = f.log.snapshot()
        try f.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "manage", "view"]])
        let gate = try RemoteVerifierSigningGate(log: f.log,
            verifiers: [.member("manager"), .host("host"), .stationReplica("station")], now: { f.time })
        let evidence = try RemoteMemberVerifierEvidence(gate: gate, log: f.log, origin: f.origin, slots: f.slots,
            journal: f.makeJournal(),
            current: { true }, now: { f.time })
        let challenge = try evidence.begin(f.slots[0], log: f.log, wallMs: f.wall)
        let report = try f.report(challenge, log: ancestor)
        XCTAssertFalse(try verifyVerifierReport(log: f.log, reportJson: report, expectedChallengeJson: challenge.json, nowMs: f.wall).atHead)
        XCTAssertThrowsError(try evidence.receive(report, for: challenge, log: f.log, wallMs: f.wall)) {
            XCTAssertEqual($0 as? RemoteVerifierGateError, .staleMembership)
        }
    }

    @MainActor
    func testExternalServiceProofCannotOutliveItsSignedMembershipExpiry() throws {
        let f = try MemberReportFixture(slotNames: ["bot"], service: true)
        let challenge = try f.begin()
        let fields = try parseVerifierReportChallenge(challengeJson: challenge.json)
        XCTAssertEqual(fields.expiresAt - fields.issuedAt, 1_000)
        try f.receive(f.report(challenge), challenge)
        XCTAssertNoThrow(try f.authorize())
        f.time += 1_000
        XCTAssertThrowsError(try f.authorize())
        f.wall += 1_000
        XCTAssertThrowsError(try f.evidence.refresh(log: f.log, wallMs: f.wall))
        XCTAssertThrowsError(try f.begin())
    }

    @MainActor
    func testRosterRejectsUnreviewedOrAmbiguousProcessSlotsAndForeignAnchor() throws {
        let f = try MemberReportFixture(slotNames: ["phone"])
        let duplicate = try RemoteMemberVerifierSlot(memberID: "manager", slot: "phone",
            process: RemoteRecoveryKit.base64URL(Data(repeating: 2, count: 16)))
        for slots in [[], [f.slots[0], f.slots[0]], [f.slots[0], duplicate]] {
            XCTAssertThrowsError(try RemoteMemberVerifierEvidence(gate: f.gate, log: f.log, origin: f.origin,
                slots: slots, journal: f.journal, current: { true }))
        }
        XCTAssertThrowsError(try RemoteMemberVerifierEvidence(gate: f.gate, log: f.log, origin: "https://STATION.example",
            slots: f.slots, journal: f.journal, current: { true }))
        let other = try MemberReportFixture(slotNames: ["phone"])
        XCTAssertThrowsError(try RemoteMemberVerifierEvidence(gate: f.gate, log: other.log, origin: f.origin,
            slots: f.slots, journal: f.journal, current: { true }))
        XCTAssertThrowsError(try RemoteMemberVerifierSlot(memberID: "manager", slot: "phone", process: "bad"))
    }
}
