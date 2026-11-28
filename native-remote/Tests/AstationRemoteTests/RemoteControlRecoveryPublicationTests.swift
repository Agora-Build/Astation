import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class ControlRecoveryAuthority: RemoteControlRecoveryAuthorizing {
    let context: RemoteControlRecoveryContext
    let original: String
    let reservedTime: UInt64
    var complete = true
    var beforeAuthorize: (() throws -> Void)?
    var calls = 0
    private var reservedRequest: SignRequest?

    init(context: RemoteControlRecoveryContext, original: String, reservedTime: UInt64) {
        self.context = context; self.original = original; self.reservedTime = reservedTime
    }
    func reserve(originalRecordJSON: String, context: RemoteControlRecoveryContext,
        managerID: String, log: MembershipLog) async throws -> UInt64 {
        guard complete, originalRecordJSON == original, context == self.context else {
            throw RemoteControlPublicationError.requiresReview
        }
        return reservedTime
    }
    func authorize(_ review: RemoteControlRecoveryReview, log: MembershipLog) throws {
        calls += 1
        try beforeAuthorize?()
        guard complete, review.context == context, review.originalRecordJSON == original,
              review.body.issuedAt == reservedTime,
              reservedRequest == nil || reservedRequest == review.request else {
            throw RemoteControlPublicationError.requiresReview
        }
        reservedRequest = review.request
    }
}

@MainActor
private final class ControlRecoveryFixture {
    let source: ControlPublicationFixture
    let original: String
    let context: RemoteControlRecoveryContext
    let authority: ControlRecoveryAuthority
    var journal: RemoteControlRecoveryPublication!
    var bytes: Data?
    var writes = 0
    var failBeforeWrite = false
    var failAfterWrite = false

    init(host: Bool = false, removed: Bool = false) throws {
        source = try ControlPublicationFixture()
        let body = try host ? source.hostBody() : source.body(interrupt: true)
        _ = try source.prepare(body)
        original = try source.sign(body)
        if removed { _ = try source.replaceManager() }
        context = try Self.context(source)
        authority = ControlRecoveryAuthority(context: context, original: original, reservedTime: body.issuedAt + 1)
        journal = try RemoteControlRecoveryPublication(accountID: source.log.accountId(), genesisHash: source.log.genesisHash(),
            stationOrigin: source.origin, draftJournal: source.authorJournal, persist: { [unowned self] in try self.save($0) })
    }

    static func context(_ source: ControlPublicationFixture, evidence: String = String(repeating: "b", count: 64)) throws -> RemoteControlRecoveryContext {
        try RemoteControlRecoveryContext(accountID: source.log.accountId(), genesisHash: source.log.genesisHash(),
            stationOrigin: source.origin, generation: 2, planID: UUID().uuidString.lowercased(),
            sourceHash: String(repeating: "a", count: 64), evidenceHash: evidence,
            candidateFeedID: UUID().uuidString.lowercased(), membershipHead: source.log.head())
    }
    func save(_ data: Data) throws {
        writes += 1
        if failBeforeWrite { throw RemoteControlPublicationError.storageUncertain }
        bytes = data
        if failAfterWrite { throw RemoteControlPublicationError.storageUncertain }
    }
    func restore(_ data: Data? = nil) throws {
        journal = try RemoteControlRecoveryPublication(checkpoint: XCTUnwrap(data ?? bytes),
            accountID: source.log.accountId(), genesisHash: source.log.genesisHash(), stationOrigin: source.origin, draftJournal: source.authorJournal,
            persist: { [unowned self] in try self.save($0) })
    }
    func prepare(manager: String = "manager") throws -> RemoteControlRecoveryReview {
        try journal.prepare(originalRecordJSON: original, context: context, managerID: manager,
            issuedAt: authority.reservedTime, log: source.log, authority: authority)
    }
    func sign(_ review: RemoteControlRecoveryReview, provider: AppKeyProvider? = nil,
        current: () -> Bool = { true }, confirmedAt: UInt64 = 100, now: @escaping @Sendable () -> UInt64 = { 100 }) throws -> String {
        try journal.sign(recordID: review.body.recordId, log: source.log, provider: provider ?? source.keys, authorJournal: source.authorJournal,
            authority: authority, confirmedAt: confirmedAt, now: now, current: current)
    }
}

final class RemoteControlRecoveryPublicationTests: XCTestCase {
    @MainActor
    func testStationAuthorityRechecksTheProtectedDraftAfterRestartAndRetainsSupersededEvidence() async throws {
        let f = try ControlRecoveryFixture(), keys = try f.source.replaceManager(), log = f.source.log
        let context = try ControlRecoveryFixture.context(f.source), manager = "other-manager"
        let host = try XCTUnwrap(URL(string: context.stationOrigin)?.host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: context.stationOrigin, configuration: config, accessToken: { "native-test" })
        let firstTime = f.authority.reservedTime
        let hash = SHA256.hash(data: Data(try canonicalJson(json: f.original).utf8)).map { String(format: "%02x", $0) }.joined()
        func serve(time: UInt64, wrongReceipt: Bool = false, after: UInt64? = nil) {
            RecoveryHTTPStub.install(host: host) { request in
                XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/" + context.genesisHash + "/control/recovery/copy-reservations")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-test")
                var reply = try RemoteRecoveryHTTPTests.requestBody(request)
                XCTAssertEqual(reply.removeValue(forKey: "after_issued_at") as? UInt64, after)
                XCTAssertEqual(reply["manager"] as? String, manager)
                XCTAssertEqual(reply["original_hash"] as? String, hash)
                if let exact = reply["issued_at"] as? UInt64, exact != time {
                    return (409, Data(#"{"error":{"code":"recovery_plan_changed"}}"#.utf8))
                }
                reply["issued_at"] = time
                reply["account_id"] = context.accountID
                reply["genesis_hash"] = context.genesisHash
                reply["origin"] = wrongReceipt ? "https://other.example" : context.stationOrigin
                return (200, try JSONSerialization.data(withJSONObject: reply))
            }
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let authority = RemoteStationRecoveryCopyAuthority(station: http)
        serve(time: firstTime)
        let stamp = try await authority.reserve(originalRecordJSON: f.original, context: context, managerID: manager, log: log)
        let first = try f.journal.prepare(originalRecordJSON: f.original, context: context, managerID: manager,
            issuedAt: stamp, log: log, authority: authority)
        try f.restore()
        let restarted = RemoteStationRecoveryCopyAuthority(station: http)
        XCTAssertThrowsError(try restarted.authorize(first, log: log))
        try await restarted.revalidate(first, log: log)
        let signed = try f.journal.sign(recordID: first.body.recordId, log: log, provider: keys,
            authorJournal: f.source.authorJournal, authority: restarted, confirmedAt: 100, now: { 100 }, current: { true })
        serve(time: firstTime + 1)
        do { try await restarted.revalidate(first, log: log); XCTFail("stale reservation") }
        catch RemoteRecoveryCopyReservationError.changed {}
        XCTAssertThrowsError(try restarted.authorize(first, log: log))
        serve(time: firstTime + 1, wrongReceipt: true)
        do { _ = try await restarted.reserve(originalRecordJSON: f.original, context: context, managerID: manager, log: log); XCTFail("wrong origin") }
        catch RemoteRecoveryTransportError.invalidResponse {}
        serve(time: firstTime, after: firstTime)
        do {
            _ = try await restarted.reserve(originalRecordJSON: f.original, context: context, managerID: manager, log: log, after: firstTime)
            XCTFail("accepted the Mac's previous timestamp")
        } catch RemoteRecoveryTransportError.invalidResponse {}
        serve(time: firstTime + 1, after: firstTime)
        let next = try await restarted.reserve(originalRecordJSON: f.original, context: context, managerID: manager, log: log, after: firstTime)
        let replacement = try f.journal.prepare(originalRecordJSON: f.original, context: context, managerID: manager,
            issuedAt: next, log: log, authority: restarted, replacingRecordID: first.body.recordId)
        try f.restore()
        XCTAssertEqual(try f.journal.reviews().map(\.body.recordId), [first.body.recordId, replacement.body.recordId])
        XCTAssertTrue(try f.journal.export(context: context, recordIDs: [first.body.recordId]).contains(signed))
        XCTAssertFalse(replacement.signed)
    }
    @MainActor
    func testInventoryRetainsRecoveryOriginalAndDistinguishesUntouchedAndInterruptedCopies() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare()
        let request = try XCTUnwrap(review.request.bodyJson)
        func inventory() throws -> RemoteControlAuthorInventory {
            try f.source.authorJournal(f.source.log, "manager").inventory(stationOrigin: f.source.origin,
                outboxes: [], recoveryCopies: [f.journal])
        }
        XCTAssertEqual(try inventory().signedRecords, [f.original])
        XCTAssertEqual(try inventory().unsignedDraftBodies, [request])
        let draft = try XCTUnwrap(f.bytes)
        var stored = try XCTUnwrap(PropertyListSerialization.propertyList(from: draft, format: nil) as? [String: Any])
        var operations = try XCTUnwrap(stored["operations"] as? [[String: Any]])
        operations[0].removeValue(forKey: "attempted")
        stored["version"] = 1
        stored["operations"] = operations
        try f.restore(PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0))
        XCTAssertTrue(try inventory().unsignedDraftBodies.isEmpty)
        XCTAssertEqual(try inventory().missingSignatureBodies, [request])

        try f.restore(draft)
        f.source.keys.beforeSign = { throw RemoteChannelError.staleLink }
        XCTAssertThrowsError(try f.sign(review))
        let attempted = try XCTUnwrap(f.bytes)
        XCTAssertNotEqual(attempted, draft)
        try f.restore(draft)
        XCTAssertEqual(try inventory().missingSignatureBodies, [request], "The independent journal survives an older outbox")
        XCTAssertTrue(try inventory().unsignedDraftBodies.isEmpty)
        f.source.keys.beforeSign = nil
        let signed = try f.sign(review)
        try f.restore(draft)
        let recovered = try inventory()
        XCTAssertEqual(Set(recovered.signedRecords), Set([f.original, signed]))
        XCTAssertTrue(recovered.unsignedDraftBodies.isEmpty)
        XCTAssertTrue(recovered.missingSignatureBodies.isEmpty)
        XCTAssertFalse(try XCTUnwrap(f.journal.reviews().first).signed, "The inventory cannot authorize delivery")
    }

    @MainActor
    func testOriginalAndRecoveryCopyShareAnAuthorJournalAcrossOutboxFailure() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare()
        let before = try f.source.authorJournal(f.source.log, "manager")
        let signs = f.source.keys.signs
        XCTAssertEqual(before.revision, 2)
        f.source.keys.beforeSign = { f.failBeforeWrite = true }
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertEqual(f.source.keys.signs, signs + 1)
        let after = try f.source.authorJournal(f.source.log, "manager")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.revision, 4)
        f.failBeforeWrite = false
        try f.restore()
        XCTAssertThrowsError(try f.journal.export(context: review.context, recordIDs: [review.body.recordId]))
        _ = try f.sign(review)
        XCTAssertEqual(f.source.keys.signs, signs + 1)
        XCTAssertNoThrow(try f.journal.export(context: review.context, recordIDs: [review.body.recordId]))
    }

    @MainActor
    func testRemovedManagerOriginalNeedsFreshCurrentManagerAndKeepsItsExactIntent() throws {
        let f = try ControlRecoveryFixture(), keys = try f.source.replaceManager()
        let context = try ControlRecoveryFixture.context(f.source)
        let authority = ControlRecoveryAuthority(context: context, original: f.original, reservedTime: f.authority.reservedTime)
        let review = try f.journal.prepare(originalRecordJSON: f.original, context: context,
            managerID: "other-manager", issuedAt: authority.reservedTime, log: f.source.log, authority: authority)
        let record = try f.journal.sign(recordID: review.body.recordId, log: f.source.log, provider: keys, authorJournal: f.source.authorJournal,
            authority: authority, confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertEqual(review.body.signer, "member:other-manager")
        XCTAssertEqual(review.body.interruptRunning, true)
        guard case .valid = try verifyControlRecord(log: f.source.log, recordJson: record) else { return XCTFail() }
        XCTAssertEqual(try f.source.journal.retainedDelivery(recordID: review.originalRecordID)?.recordJSON, f.original)
    }

    @MainActor
    func testLaterReviewPreservesEarlierCopiesAndRejectsReusedObservedClock() throws {
        let f = try ControlRecoveryFixture(), first = try f.prepare()
        let originalCopy = try f.sign(first)
        let later = try ControlRecoveryFixture.context(f.source, evidence: String(repeating: "c", count: 64))
        let reused = ControlRecoveryAuthority(context: later, original: f.original, reservedTime: first.body.issuedAt)
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: later,
            managerID: "manager", issuedAt: reused.reservedTime, log: f.source.log, authority: reused))
        let authority = ControlRecoveryAuthority(context: later, original: f.original, reservedTime: first.body.issuedAt + 1)
        let second = try f.journal.prepare(originalRecordJSON: f.original, context: later,
            managerID: "manager", issuedAt: authority.reservedTime, log: f.source.log, authority: authority)
        _ = try f.journal.sign(recordID: second.body.recordId, log: f.source.log, provider: f.source.keys, authorJournal: f.source.authorJournal,
            authority: authority, confirmedAt: 100, now: { 100 }, current: { true })
        try f.restore()
        XCTAssertEqual(try f.journal.reviews().count, 2)
        XCTAssertTrue(try f.journal.export(context: f.context, recordIDs: [first.body.recordId]).contains(originalCopy))
        XCTAssertThrowsError(try f.journal.export(context: later, recordIDs: [first.body.recordId, second.body.recordId]))
    }

    @MainActor
    func testChangedMembershipCannotPersistDuplicateReviewThatWouldPreventRestart() throws {
        let f = try ControlRecoveryFixture(), first = try f.prepare()
        let signature = try f.sign(first), checkpoint = f.bytes, writes = f.writes
        let keys = try f.source.replaceManager()
        let changed = try RemoteControlRecoveryContext(accountID: f.context.accountID, genesisHash: f.context.genesisHash,
            stationOrigin: f.context.stationOrigin, generation: f.context.generation, planID: f.context.planID,
            sourceHash: f.context.sourceHash, evidenceHash: f.context.evidenceHash,
            candidateFeedID: f.context.candidateFeedID, membershipHead: f.source.log.head())
        let authority = ControlRecoveryAuthority(context: changed, original: f.original,
            reservedTime: first.body.issuedAt + 1)
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: changed,
            managerID: "other-manager", issuedAt: authority.reservedTime, log: f.source.log, authority: authority))
        XCTAssertEqual(f.bytes, checkpoint)
        XCTAssertEqual(f.writes, writes)
        XCTAssertEqual(keys.signs, 0)
        try f.restore()
        XCTAssertEqual(try f.journal.reviews().count, 1)
        XCTAssertTrue(try f.journal.export(context: f.context, recordIDs: [first.body.recordId]).contains(signature))
    }

    @MainActor
    func testExportKeepsIncreasingPreparationOrderAndRefusesMoreThanOneWirePage() throws {
        let f = try ControlRecoveryFixture()
        var ids: [String] = []
        for index in 0..<65 {
            let body = try f.source.body(interrupt: true)
            _ = try f.source.prepare(body)
            let original = try f.source.sign(body)
            let authority = ControlRecoveryAuthority(context: f.context, original: original,
                reservedTime: f.authority.reservedTime + UInt64(index))
            let review = try f.journal.prepare(originalRecordJSON: original, context: f.context,
                managerID: "manager", issuedAt: authority.reservedTime, log: f.source.log, authority: authority)
            _ = try f.journal.sign(recordID: review.body.recordId, log: f.source.log, provider: f.source.keys, authorJournal: f.source.authorJournal,
                authority: authority, confirmedAt: 100, now: { 100 }, current: { true })
            ids.append(review.body.recordId)
        }
        let exported = try f.journal.export(context: f.context, recordIDs: Array(ids.prefix(64).reversed()))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(value["replacements"] as? [[String: Any]])
        let times = try rows.map { row -> UInt64 in
            let record = try XCTUnwrap(row["record"] as? [String: Any])
            let body = try XCTUnwrap(record["body"] as? [String: Any])
            return try XCTUnwrap(body["issued_at"] as? NSNumber).uint64Value
        }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(rows.count, 64)
        XCTAssertThrowsError(try f.journal.export(context: f.context, recordIDs: ids))
        try f.restore()
        XCTAssertEqual(try f.journal.reviews().count, 65)
    }

    @MainActor
    func testSameManagerRecoveryKeepsOriginalDeliveriesAndExportsExactSignedCopyAfterRestart() throws {
        let f = try ControlRecoveryFixture()
        let originalJournal = f.source.stored
        let originalExport = try f.source.journal.recoveryEvidenceJSON(authorJournal: f.source.readAuthorJournal)
        let deliveryIDs = try f.source.journal.pendingDeliveryIDs()
        let review = try f.prepare()
        XCTAssertFalse(review.signed)
        XCTAssertEqual(review.body.feedId, try parseControlRecord(recordJson: f.original).feedId)
        XCTAssertNotEqual(review.body.feedId, f.context.candidateFeedID)
        XCTAssertEqual(review.body.signer, "member:manager")
        XCTAssertTrue(review.body.interruptRunning == true)
        XCTAssertThrowsError(try f.journal.export(context: f.context, recordIDs: [review.body.recordId]))
        let record = try f.sign(review), signs = f.source.keys.signs, writes = f.writes
        guard case .valid = try verifyControlRecord(log: f.source.log, recordJson: record) else {
            return XCTFail("Recovery copy must pass the real shared verifier")
        }
        let exported = try f.journal.export(context: f.context, recordIDs: [review.body.recordId])
        XCTAssertTrue(exported.contains(record))
        XCTAssertEqual(try RemoteControlRecoveryRetention.requestIDs(context: f.context, json: exported),
                       [review.body.recordId])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["evidence_hash", "replacements"])
        XCTAssertEqual(value["evidence_hash"] as? String, f.context.evidenceHash)
        try f.restore()
        XCTAssertEqual(try f.sign(review), record)
        XCTAssertEqual(try f.journal.export(context: f.context, recordIDs: [review.body.recordId]), exported)
        XCTAssertEqual(f.source.keys.signs, signs)
        XCTAssertEqual(f.writes, writes)
        XCTAssertEqual(f.source.stored, originalJournal)
        XCTAssertEqual(try f.source.journal.recoveryEvidenceJSON(authorJournal: f.source.readAuthorJournal), originalExport)
        XCTAssertEqual(try f.source.journal.pendingDeliveryIDs(), deliveryIDs)
    }

    @MainActor
    func testAbsentAuthorityAndUnknownClocksCannotPrepareOrSign() throws {
        let f = try ControlRecoveryFixture(), signs = f.source.keys.signs
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: f.context,
            managerID: "manager", issuedAt: f.authority.reservedTime, log: f.source.log, authority: nil))
        f.authority.complete = false
        XCTAssertThrowsError(try f.prepare())
        XCTAssertNil(f.bytes)
        f.authority.complete = true
        let review = try f.prepare(), bytes = f.bytes
        f.authority.complete = false
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertThrowsError(try f.journal.sign(recordID: review.body.recordId, log: f.source.log, provider: f.source.keys, authorJournal: f.source.authorJournal,
            authority: nil, confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertEqual(f.bytes, bytes)
        XCTAssertEqual(f.source.keys.signs, signs)
    }

    @MainActor
    func testChangedContextReservationAndWrongManagerRefuseWithoutWriting() throws {
        let f = try ControlRecoveryFixture()
        let changed = try ControlRecoveryFixture.context(f.source)
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: changed,
            managerID: "manager", issuedAt: f.authority.reservedTime, log: f.source.log, authority: f.authority))
        for time in [f.authority.reservedTime - 1, f.authority.reservedTime + 1] {
            XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: f.context,
                managerID: "manager", issuedAt: time, log: f.source.log, authority: f.authority))
        }
        XCTAssertThrowsError(try f.prepare(manager: "service"))
        XCTAssertNil(f.bytes)
        let review = try f.prepare(), writes = f.writes
        XCTAssertEqual(try f.prepare(), review)
        XCTAssertEqual(f.writes, writes)
        XCTAssertThrowsError(try f.sign(review, provider: ControlPublicationKeys()))
        XCTAssertThrowsError(try f.journal.export(context: changed, recordIDs: [review.body.recordId]))
    }

    @MainActor
    func testConfirmationExpiryCancellationAndAuthorityLossDoNotCommitSignature() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare(), bytes = f.bytes
        let signs = f.source.keys.signs
        XCTAssertThrowsError(try f.sign(review, current: { false }))
        XCTAssertThrowsError(try f.sign(review, now: { 30_100 }))
        XCTAssertEqual(f.source.keys.signs, signs)
        XCTAssertEqual(f.bytes, bytes)
        f.source.keys.beforeSign = { f.authority.complete = false }
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertNotEqual(f.bytes, bytes, "A key attempt is retained even when signing authority changes")
        XCTAssertThrowsError(try f.journal.export(context: review.context, recordIDs: [review.body.recordId]))
        XCTAssertEqual(f.source.keys.signs, signs + 1)
        XCTAssertFalse(try XCTUnwrap(f.journal.reviews().first).signed)
    }

    @MainActor
    func testMembershipChangeAndRemovedManagerRequireNewReview() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare(), signs = f.source.keys.signs
        _ = try f.source.replaceManager()
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertEqual(f.source.keys.signs, signs)
        XCTAssertFalse(try XCTUnwrap(f.journal.reviews().first).signed)
    }

    @MainActor
    func testMembershipChangeInsideSigningOrAuthorityCallbackCannotCommit() throws {
        for duringSignature in [false, true] {
            let f = try ControlRecoveryFixture(), review = try f.prepare(), bytes = f.bytes
            if duringSignature { f.source.keys.beforeSign = { _ = try f.source.replaceManager() } }
            else { f.authority.beforeAuthorize = { _ = try f.source.replaceManager() } }
            XCTAssertThrowsError(try f.sign(review))
            if duringSignature { XCTAssertNotEqual(f.bytes, bytes) }
            else { XCTAssertEqual(f.bytes, bytes) }
            XCTAssertThrowsError(try f.journal.export(context: review.context, recordIDs: [review.body.recordId]))
        }
    }

    @MainActor
    func testHostInterruptionKeepsExactRevokeSequenceAndNoFeedBinding() throws {
        let f = try ControlRecoveryFixture(host: true), old = try parseControlRecord(recordJson: f.original)
        let review = try f.prepare(), record = try f.sign(review)
        XCTAssertEqual(review.body.principal, old.principal)
        XCTAssertEqual(review.body.revokeSeq, old.revokeSeq)
        XCTAssertEqual(review.body.by, old.by)
        XCTAssertNil(review.body.feedId)
        XCTAssertNil(review.body.origin)
        XCTAssertEqual(try parseControlRecord(recordJson: record), review.body)
        XCTAssertEqual(try f.source.journal.pendingDeliveryIDs(), [old.recordId])
    }

    @MainActor
    func testUnsignedOrChangedSourceCannotBecomeRecoveryAuthority() throws {
        let f = try ControlRecoveryFixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.original.utf8)) as? [String: Any])
        var body = try XCTUnwrap(object["body"] as? [String: Any])
        body["interrupt_running"] = false
        object["body"] = body
        let altered = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: altered, context: f.context,
            managerID: "manager", issuedAt: f.authority.reservedTime, log: f.source.log, authority: f.authority))
        XCTAssertNil(f.bytes)
        XCTAssertEqual(try f.journal.reviews(), [])
    }

    @MainActor
    func testFailedProtectedSaveFencesAndRestartRecoversCommittedExactSignature() throws {
        for afterWrite in [false, true] {
            let f = try ControlRecoveryFixture(), review = try f.prepare(), draft = f.bytes
            if afterWrite { f.source.keys.beforeSign = { f.failAfterWrite = true } }
            else { f.failBeforeWrite = true }
            XCTAssertThrowsError(try f.sign(review))
            XCTAssertTrue(f.journal.storageUncertain)
            XCTAssertThrowsError(try f.journal.reviews())
            XCTAssertThrowsError(try f.journal.export(context: f.context, recordIDs: [review.body.recordId]))
            let signs = f.source.keys.signs
            f.failBeforeWrite = false; f.failAfterWrite = false
            try f.restore()
            XCTAssertEqual(try XCTUnwrap(f.journal.reviews().first).signed, afterWrite)
            if afterWrite {
                let record = try f.sign(review)
                XCTAssertEqual(f.source.keys.signs, signs)
                XCTAssertTrue(try f.journal.export(context: f.context, recordIDs: [review.body.recordId]).contains(record))
            } else { XCTAssertEqual(f.bytes, draft) }
        }
    }

    @MainActor
    func testReentryFromAuthorityAndSignerCannotOverwriteJournal() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare()
        let nested = {
            XCTAssertThrowsError(try f.prepare()) { XCTAssertEqual($0 as? RemoteControlPublicationError, .busy) }
            XCTAssertThrowsError(try f.journal.reviews()) { XCTAssertEqual($0 as? RemoteControlPublicationError, .busy) }
        }
        f.authority.beforeAuthorize = nested
        f.source.keys.beforeSign = nested
        _ = try f.sign(review)
        XCTAssertEqual(try f.journal.reviews().count, 1)
        XCTAssertTrue(try XCTUnwrap(f.journal.reviews().first).signed)
    }

    @MainActor
    func testCheckpointCorruptionAndPartialOrMixedExportAreRefused() throws {
        let f = try ControlRecoveryFixture(), review = try f.prepare()
        let record = try f.sign(review)
        for ids in [[], [review.body.recordId, review.body.recordId], [review.body.recordId, UUID().uuidString.lowercased()]] {
            XCTAssertThrowsError(try f.journal.export(context: f.context, recordIDs: ids))
        }
        let bytes = try XCTUnwrap(f.bytes)
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var ops = try XCTUnwrap(root["operations"] as? [[String: Any]])
        ops[0]["recordJSON"] = record.replacingOccurrences(of: "\"sig\":\"", with: "\"sig\":\"A")
        root["operations"] = ops
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)))
        try f.restore(bytes)
        XCTAssertEqual(try f.sign(review), record)
        root["accountID"] = "another-account"
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)))
    }

    @MainActor
    func testCheckpointLimitsRefuseValidExcessReviewsWithoutLosingRetainedSignature() throws {
        let f = try ControlRecoveryFixture(), first = try f.prepare()
        let signature = try f.sign(first)
        for index in 1..<256 {
            let context = try ControlRecoveryFixture.context(f.source)
            let authority = ControlRecoveryAuthority(context: context, original: f.original,
                reservedTime: first.body.issuedAt + UInt64(index))
            _ = try f.journal.prepare(originalRecordJSON: f.original, context: context, managerID: "manager",
                issuedAt: authority.reservedTime, log: f.source.log, authority: authority)
        }
        let checkpoint = try XCTUnwrap(f.bytes), writes = f.writes, signs = f.source.keys.signs
        try f.restore(checkpoint)
        XCTAssertEqual(try f.journal.reviews().count, 256)
        let context = try ControlRecoveryFixture.context(f.source)
        let authority = ControlRecoveryAuthority(context: context, original: f.original,
            reservedTime: first.body.issuedAt + 256)
        XCTAssertThrowsError(try f.journal.prepare(originalRecordJSON: f.original, context: context, managerID: "manager",
            issuedAt: authority.reservedTime, log: f.source.log, authority: authority)) {
            XCTAssertEqual($0 as? RemoteControlPublicationError, .full)
        }
        XCTAssertEqual(f.bytes, checkpoint)
        XCTAssertEqual(f.writes, writes)
        XCTAssertEqual(f.source.keys.signs, signs)

        // The 257th entry is valid and unique; only the whole-journal limit should refuse its reload.
        var extra: Data?
        let standalone = try RemoteControlRecoveryPublication(accountID: f.source.log.accountId(),
            genesisHash: f.source.log.genesisHash(), stationOrigin: f.source.origin, draftJournal: f.source.authorJournal, persist: { extra = $0 })
        let extraAuthority = ControlRecoveryAuthority(context: context, original: f.original,
            reservedTime: authority.reservedTime + 1)
        _ = try standalone.prepare(originalRecordJSON: f.original, context: context, managerID: "manager",
            issuedAt: extraAuthority.reservedTime, log: f.source.log, authority: extraAuthority)
        let extraRoot = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(extra), format: nil) as? [String: Any])
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: checkpoint, format: nil) as? [String: Any])
        let operations = try XCTUnwrap(root["operations"] as? [[String: Any]])
        let extraOperations = try XCTUnwrap(extraRoot["operations"] as? [[String: Any]])
        XCTAssertEqual(extraOperations.count, 1)
        var withinCount = root
        withinCount["operations"] = [operations[0]] + operations.dropFirst(2) + extraOperations
        let withinCountBytes = try PropertyListSerialization.data(fromPropertyList: withinCount, format: .binary, options: 0)
        try f.restore(withinCountBytes)
        XCTAssertEqual(try f.journal.reviews().count, 256)
        XCTAssertTrue(try f.journal.export(context: f.context, recordIDs: [first.body.recordId]).contains(signature))
        var excessive = root
        excessive["operations"] = operations + extraOperations
        let excessiveBytes = try PropertyListSerialization.data(fromPropertyList: excessive, format: .binary, options: 0)
        XCTAssertLessThanOrEqual(excessiveBytes.count, 2_097_152)

        var smallPadding = root
        smallPadding["padding"] = Data(repeating: 0, count: 16)
        let smallPaddingBytes = try PropertyListSerialization.data(fromPropertyList: smallPadding, format: .binary, options: 0)
        XCTAssertLessThanOrEqual(smallPaddingBytes.count, 2_097_152)
        try f.restore(smallPaddingBytes)
        XCTAssertEqual(try f.journal.reviews().count, 256)
        var oversized = root
        oversized["padding"] = Data(repeating: 0, count: 2_097_152)
        let oversizedBytes = try PropertyListSerialization.data(fromPropertyList: oversized, format: .binary, options: 0)
        XCTAssertGreaterThan(oversizedBytes.count, 2_097_152)
        var oldVersion = root, futureVersion = root
        oldVersion["version"] = 0
        futureVersion["version"] = 4
        let versionBytes = try [oldVersion, futureVersion].map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
        for bytes in [excessiveBytes, oversizedBytes] + versionBytes {
            XCTAssertThrowsError(try f.restore(bytes)) {
                XCTAssertEqual($0 as? RemoteControlPublicationError, .invalidCheckpoint)
            }
        }
        try f.restore(checkpoint)
        XCTAssertTrue(try f.journal.export(context: f.context, recordIDs: [first.body.recordId]).contains(signature))
        XCTAssertEqual(f.writes, writes)
        XCTAssertEqual(f.source.keys.signs, signs)
    }
}
