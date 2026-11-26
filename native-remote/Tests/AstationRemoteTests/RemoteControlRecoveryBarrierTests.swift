import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
final class RemoteControlRecoveryBarrierTests: XCTestCase {
    private func context(_ f: ControlPublicationFixture, origin: String? = nil, generation: UInt64 = 2) throws -> RemoteControlRecoveryContext {
        try RemoteControlRecoveryContext(accountID: f.log.accountId(), genesisHash: f.log.genesisHash(),
            stationOrigin: origin ?? f.origin, generation: generation, planID: UUID().uuidString.lowercased(),
            sourceHash: String(repeating: "a", count: 64), evidenceHash: String(repeating: "b", count: 64),
            candidateFeedID: UUID().uuidString.lowercased(), membershipHead: f.log.head())
    }

    private func challenge(_ c: RemoteControlRecoveryContext, now: UInt64) throws -> String {
        try signerReportChallenge(signer: "member:manager", slot: "astation-macos", origin: c.stationOrigin,
            connection: 1, issuedAt: now, expiresAt: now + 30_000, recovery: SignerReportRecovery(
                generation: String(c.generation), planId: c.planID, candidateFeedId: c.candidateFeedID,
                sourceHash: c.sourceHash, evidenceHash: c.evidenceHash))
    }

    func testReportCommitsSignedAndDraftSetsIndependentlyAndFreezesBothAfterReopen() throws {
        let f = try ControlPublicationFixture(), host = try f.hostBody(), stop = try f.body()
        _ = try f.prepare(host)
        _ = try f.prepare(stop)
        let before = try XCTUnwrap(f.stored)
        let record = try f.sign(stop)
        try f.restore(before)
        // The exact signature survived independently of the rolled-back outbox.
        let c = try context(f), now = f.clock.wallMs, ch = try challenge(c, now: now)
        let writer = try f.readAuthorJournal("manager")
        let request = try writer.holdForReport(context: c, challengeJSON: ch, log: f.log,
            slot: "astation-macos", nowMs: now, outboxes: [f.journal], recoveryCopies: [])
        let result = try writer.finishReport(context: c, reviewed: request, log: f.log, nowMs: { now },
            current: { true }, sign: f.keys.sign)
        let signed = result.report
        XCTAssertEqual(result.records, [record])
        let retried = try f.readAuthorJournal("manager").finishReport(context: c, reviewed: request, log: f.log,
            nowMs: { now }, current: { true }, sign: { _ in XCTFail("a retry must use the retained signature"); return Data() })
        XCTAssertEqual(retried.report, signed)
        let verified = try verifySignerReport(log: f.log, reportJson: signed, expectedChallengeJson: ch,
            exportedRecordsJson: [record], nowMs: now)
        XCTAssertEqual(verified.journal.records, 1)
        XCTAssertEqual(verified.journal.drafts, 2)
        XCTAssertEqual(verified.journal.revision + 1, writer.revision)
        let keys = f.keys.signs, bytes = f.stored
        let assertHeld: (Error) -> Void = { error in
            XCTAssertEqual((error as? RemoteControlRecoveryHold)?.context, c)
        }
        XCTAssertThrowsError(try f.prepare(f.body()), "", assertHeld)
        XCTAssertThrowsError(try f.sign(stop), "", assertHeld)
        XCTAssertThrowsError(try f.sign(host), "", assertHeld)
        XCTAssertThrowsError(try f.journal.cancelUnsigned(recordID: host.recordId, authorJournal: f.readAuthorJournal),
            "", assertHeld)
        XCTAssertEqual(f.keys.signs, keys)
        XCTAssertEqual(f.stored, bytes)
        let other = "https://second.example"
        let box = try RemoteControlPublication(accountID: f.log.accountId(), genesisHash: f.log.genesisHash(),
            stationOrigin: other, draftJournal: f.authorJournal, persist: { _ in })
        var foreign = try f.body(action: "interrupt_running", interrupt: nil)
        foreign.origin = other
        _ = try box.prepare(body: foreign, log: f.log)
        _ = try box.sign(recordID: foreign.recordId, log: f.log, provider: f.keys, authorJournal: f.authorJournal,
            confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertThrowsError(try box.prepare(body: host, log: f.log), "", assertHeld)
    }

    func testFreshConfirmationOfTheSameHeldInventorySurvivesRestart() throws {
        let f = try ControlPublicationFixture(), first = try context(f), now = f.clock.wallMs
        let next = try RemoteControlRecoveryContext(accountID: first.accountID, genesisHash: first.genesisHash,
            stationOrigin: first.stationOrigin, generation: first.generation, planID: first.planID,
            sourceHash: first.sourceHash, evidenceHash: String(repeating: "c", count: 64),
            candidateFeedID: first.candidateFeedID, membershipHead: first.membershipHead)
        let stop = try f.body()
        _ = try f.prepare(stop)
        let record = try f.sign(stop)

        func confirm(_ context: RemoteControlRecoveryContext) throws -> VerifiedSignerReport {
            let journal = try f.readAuthorJournal("manager"), ch = try challenge(context, now: now)
            let request = try journal.holdForReport(context: context, challengeJSON: ch, log: f.log,
                slot: "astation-macos", nowMs: now, outboxes: [f.journal], recoveryCopies: [])
            let result = try journal.finishReport(context: context, reviewed: request, log: f.log,
                nowMs: { now }, current: { true }, sign: f.keys.sign)
            XCTAssertEqual(result.records, [record])
            return try verifySignerReport(log: f.log, reportJson: result.report, expectedChallengeJson: ch,
                exportedRecordsJson: result.records, nowMs: now)
        }

        let firstReport = try confirm(first)
        let storedRevision = try f.readAuthorJournal("manager").revision
        let secondReport = try confirm(next)
        XCTAssertEqual(secondReport.journal, firstReport.journal)
        XCTAssertNotEqual(secondReport.recovery.evidenceHash, firstReport.recovery.evidenceHash)
        let reopened = try f.readAuthorJournal("manager")
        XCTAssertGreaterThan(reopened.revision, storedRevision)
        XCTAssertThrowsError(try reopened.requireStopChange(origin: next.stationOrigin))
        let retry = try XCTUnwrap(reopened.exposedSubmission(for: next, log: f.log))
        XCTAssertEqual(retry.context, next)
    }

    func testUncertainBarrierCommitNeverReturnsARequestAndReopenSeesWhatBecameDurable() throws {
        for stored in [false, true] {
            let f = try ControlPublicationFixture(), c = try context(f), ch = try challenge(c, now: f.clock.wallMs)
            let journal = try RemoteControlSigningJournal(log: f.log, memberID: "manager",
                read: { f.authorBytes["manager"] }, persist: { bytes in
                    if stored { f.authorBytes["manager"] = bytes }
                    throw RemoteControlPublicationError.storageUncertain
                })
            XCTAssertThrowsError(try journal.holdForReport(context: c, challengeJSON: ch, log: f.log,
                slot: "astation-macos", nowMs: f.clock.wallMs, outboxes: [f.journal], recoveryCopies: []))
            XCTAssertThrowsError(try journal.requireStopChange(origin: f.origin))
            let reopened = try f.readAuthorJournal("manager")
            if stored {
                XCTAssertThrowsError(try reopened.requireStopChange(origin: f.origin)) {
                    XCTAssertEqual(($0 as? RemoteControlRecoveryHold)?.context, c)
                }
            } else {
                XCTAssertNoThrow(try reopened.requireStopChange(origin: f.origin))
            }
            XCTAssertEqual(f.keys.signs, 0)
        }
    }

    func testFrozenEvidenceSurvivesLossOfTheOutboxesAcrossOrigins() throws {
        let f = try ControlPublicationFixture(), host = try f.hostBody(), service = try f.body()
        let hostDraft = try XCTUnwrap(f.prepare(host).bodyJson)
        _ = try f.prepare(service)
        let signed = try f.sign(service)
        // Model a legacy signed outbox retained from before independent journaling.
        f.authorBytes.removeAll()
        let c = try context(f), ch = try challenge(c, now: f.clock.wallMs)
        _ = try f.readAuthorJournal("manager").holdForReport(context: c, challengeJSON: ch, log: f.log,
            slot: "astation-macos", nowMs: f.clock.wallMs, outboxes: [f.journal], recoveryCopies: [])
        let reopened = try f.readAuthorJournal("manager")
        let here = try reopened.inventory(stationOrigin: f.origin, outboxes: [], recoveryCopies: [])
        XCTAssertEqual(here.signedRecords, [signed])
        XCTAssertEqual(here.unsignedDraftBodies, [hostDraft])
        let elsewhere = try reopened.inventory(stationOrigin: "https://second.example", outboxes: [], recoveryCopies: [])
        XCTAssertTrue(elsewhere.signedRecords.isEmpty)
        XCTAssertEqual(elsewhere.unsignedDraftBodies, [hostDraft])
        _ = try reopened.holdForReport(context: c, challengeJSON: challenge(c, now: f.clock.wallMs + 1),
            log: f.log, slot: "astation-macos", nowMs: f.clock.wallMs + 1, outboxes: [], recoveryCopies: [])
    }

    func testExposureFailureCannotReturnSignedBytesAndDurableRetryUsesTheExactSignature() throws {
        let f = try ControlPublicationFixture(), c = try context(f), now = f.clock.wallMs
        let j = try f.readAuthorJournal("manager"), ch = try challenge(c, now: now)
        let review = try j.holdForReport(context: c, challengeJSON: ch, log: f.log, slot: "astation-macos",
            nowMs: now, outboxes: [f.journal], recoveryCopies: [])
        let exposed = try RemoteControlSigningJournal(log: f.log, memberID: "manager", read: { f.authorBytes["manager"] },
            persist: { bytes in f.authorBytes["manager"] = bytes; throw RemoteControlPublicationError.storageUncertain })
        XCTAssertThrowsError(try exposed.finishReport(context: c, reviewed: review, log: f.log,
            nowMs: { now }, current: { true }, sign: f.keys.sign))
        XCTAssertThrowsError(try exposed.requireStopChange(origin: c.stationOrigin))
        let reopened = try f.readAuthorJournal("manager")
        let retry = try reopened.holdForReport(context: c, challengeJSON: ch, log: f.log, slot: "astation-macos",
            nowMs: now, outboxes: [f.journal], recoveryCopies: [])
        XCTAssertEqual(retry, review)
        let result = try reopened.finishReport(context: c, reviewed: retry, log: f.log, nowMs: { now },
            current: { true }, sign: { _ in XCTFail("exposure was already committed"); return Data() })
        _ = try verifySignerReport(log: f.log, reportJson: result.report, expectedChallengeJson: ch,
            exportedRecordsJson: [], nowMs: now)
        XCTAssertEqual(f.keys.signs, 1)
    }

    func testOnlyAuthenticatedHigherGenerationWithDifferentPlanReleasesItsOwnOrigin() async throws {
        let f = try ControlPublicationFixture(), first = try context(f), other = try context(f, origin: "https://second.example")
        let now = f.clock.wallMs
        func hold(_ c: RemoteControlRecoveryContext) throws {
            _ = try f.readAuthorJournal("manager").holdForReport(context: c, challengeJSON: challenge(c, now: now),
                log: f.log, slot: "astation-macos", nowMs: now, outboxes: [f.journal], recoveryCopies: [])
        }
        try hold(first)
        try hold(other)
        let successor = try context(f, generation: 3)
        let payload: [String: Any] = ["version": 1, "account_id": successor.accountID, "genesis_hash": successor.genesisHash,
            "origin": successor.stationOrigin, "generation": String(successor.generation), "plan_id": successor.planID,
            "candidate_feed_id": successor.candidateFeedID, "source_hash": successor.sourceHash,
            "evidence_hash": successor.evidenceHash, "reconstruction_hash": successor.sourceHash,
            "membership_head": ["seq": successor.membershipHead.seq, "hash": successor.membershipHead.hash],
            "retained_history_only": true, "complete_history": false, "signing_clock_complete": false,
            "snapshot_complete": false, "recovery_ready": false]
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        let journal = try f.readAuthorJournal("manager")
        let fromFile = try RemoteControlRecoveryPreparation.decode(bytes, accountID: first.accountID,
            genesisHash: first.genesisHash, stationOrigin: first.stationOrigin, expected: first.membershipHead)
        let initialBytes = f.authorBytes
        try journal.reconcileSupersedingPlan(fromFile)
        XCTAssertEqual(initialBytes, f.authorBytes)
        let host = try XCTUnwrap(URL(string: first.stationOrigin)?.host)
        defer { RecoveryHTTPStub.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: first.stationOrigin, configuration: config, accessToken: { "test-token" })
        for (planID, generation, endsFirst) in [(successor.planID, "2", false), (first.planID, "3", false), (successor.planID, "3", true)] {
            var object = payload
            object["plan_id"] = planID
            object["generation"] = generation
            let response = try JSONSerialization.data(withJSONObject: object)
            RecoveryHTTPStub.install(host: host) { _ in (200, response) }
            let live = try await http.controlRecoveryReview(accountID: first.accountID, genesisHash: first.genesisHash,
                expected: first.membershipHead)
            try journal.reconcileSupersedingPlan(live)
            if !endsFirst { XCTAssertEqual(initialBytes, f.authorBytes) }
        }
        let reopened = try f.readAuthorJournal("manager")
        XCTAssertNoThrow(try reopened.requireStopChange(origin: first.stationOrigin))
        XCTAssertThrowsError(try reopened.requireStopChange(origin: other.stationOrigin))
        XCTAssertThrowsError(try reopened.requireStopChange(origin: nil))
        XCTAssertThrowsError(try hold(first), "a delayed old challenge cannot reinstall the released plan")
        try hold(successor)
    }

    func testOnlyExactAbandonmentReleasesTheHoldAndPreventsItsReinstallation() async throws {
        try await checkTerminalReceipt(.abandoned)
    }

    func testOnlyExactPublicationReleasesTheHoldAndPreventsItsReinstallation() async throws {
        try await checkTerminalReceipt(.published)
    }

    private func checkTerminalReceipt(_ outcome: RemoteStationPlanEnd.Outcome) async throws {
        let f = try ControlPublicationFixture(), c = try context(f), other = try context(f, origin: "https://another.example")
        let host = try XCTUnwrap(URL(string: c.stationOrigin)?.host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let station = try RemoteRecoveryHTTP(relayURL: c.stationOrigin, configuration: config, accessToken: { "native-test" })
        defer { RecoveryHTTPStub.remove(host: host) }
        func hold(_ ctx: RemoteControlRecoveryContext) throws {
            _ = try f.readAuthorJournal("manager").holdForReport(context: ctx, challengeJSON: challenge(ctx, now: f.clock.wallMs),
                log: f.log, slot: "astation-macos", nowMs: f.clock.wallMs, outboxes: [f.journal], recoveryCopies: [])
        }
        try hold(c); try hold(other)
        let current = try f.readAuthorJournal("manager")
        let payload: [String: String] = ["account_id": c.accountID, "genesis_hash": c.genesisHash, "origin": c.stationOrigin,
            "generation": String(c.generation), "plan_id": c.planID, "candidate_feed_id": c.candidateFeedID,
            "source_hash": c.sourceHash, "outcome": outcome.rawValue]
        for field in payload.keys.sorted() + ["extra", "pending", "valid"] {
            var body = payload
            if field == "pending" { body["outcome"] = "pending" }
            else if field != "valid" { body[field] = "wrong" }
            let data = try JSONSerialization.data(withJSONObject: body)
            RecoveryHTTPStub.install(host: host) { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/" + c.genesisHash + "/control/recovery/" + c.planID + "/outcome")
                return (200, data)
            }
            if field == "valid" {
                let end = try await station.planEnd(for: c)
                let proof = try XCTUnwrap(end)
                XCTAssertEqual(proof.outcome, outcome)
                let fail = try RemoteControlSigningJournal(log: f.log, memberID: "manager",
                    read: { f.authorBytes["manager"] }, persist: { _ in throw RemoteControlPublicationError.storageUncertain })
                XCTAssertThrowsError(try fail.reconcilePlanEnd(proof))
                XCTAssertThrowsError(try current.requireStopChange(origin: c.stationOrigin))
                try current.reconcilePlanEnd(proof)
            } else if field == "pending" {
                let end = try await station.planEnd(for: c)
                XCTAssertNil(end)
            } else {
                do { _ = try await station.planEnd(for: c); XCTFail(field) }
                catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse, field) }
            }
        }
        let reopened = try f.readAuthorJournal("manager")
        XCTAssertNoThrow(try reopened.requireStopChange(origin: c.stationOrigin))
        XCTAssertThrowsError(try reopened.requireStopChange(origin: other.stationOrigin))
        XCTAssertThrowsError(try reopened.requireStopChange(origin: nil))
        XCTAssertThrowsError(try hold(c))
        XCTAssertThrowsError(try hold(context(f)))
        try hold(context(f, generation: c.generation + 1))
    }

    func testMismatchedExpiredAndCompetingPlansCannotInstallOrReplaceAHold() throws {
        let f = try ControlPublicationFixture(), c = try context(f), other = try context(f, generation: 3)
        let journal = try f.readAuthorJournal("manager"), ch = try challenge(c, now: f.clock.wallMs)
        func hold(_ plan: RemoteControlRecoveryContext, _ challenge: String, now: UInt64) throws {
            _ = try journal.holdForReport(context: plan, challengeJSON: challenge, log: f.log, slot: "astation-macos",
                nowMs: now, outboxes: [f.journal], recoveryCopies: [])
        }
        XCTAssertThrowsError(try hold(other, ch, now: f.clock.wallMs))
        XCTAssertThrowsError(try hold(c, ch, now: f.clock.wallMs + 30_001))
        XCTAssertNil(f.authorBytes["manager"])
        try hold(c, ch, now: f.clock.wallMs)
        let stored = f.authorBytes
        XCTAssertThrowsError(try hold(other, challenge(other, now: f.clock.wallMs), now: f.clock.wallMs))
        XCTAssertEqual(f.authorBytes, stored)
        try hold(c, challenge(c, now: f.clock.wallMs + 1), now: f.clock.wallMs + 1)
        XCTAssertEqual(journal.revision, 2)
    }
}
