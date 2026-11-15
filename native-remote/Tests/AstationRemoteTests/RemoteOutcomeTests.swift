import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class OutcomeFixture {
    let host = RemoteWorkHost(account: "account", device: "host", trust: 3)
    var attachment = UUID().uuidString.lowercased()
    var sent: [[String: Any]] = []
    var time: UInt64 = 1_793_620_800_000
    var failSend = false
    let enabled: Bool
    lazy var client = RemoteHostWork(load: { [] }, save: { _ in }, clock: { self.time },
        resolutionEnabled: enabled, send: {
            self.sent.append((try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["data"] as! [String: Any])
            return !self.failSend
        })

    init(enabled: Bool = true) { self.enabled = enabled }
    func connect(control: Bool = true, features: Set<String> = ["host.alerts", "host.delegated", "host.work"]) {
        client.connected(host: host, attachment: attachment, features: features, control: control)
    }
    func alert(_ seq: UInt64 = 1, task: String = UUID().uuidString.lowercased()) -> [String: Any] {
        ["alert_id": UUID().uuidString.lowercased(), "seq": seq, "kind": "outcome_unknown", "host_id": "host",
         "session_id": "ses-aaaaaaaaaaaa", "task_id": task, "sender": "service:revoked-sender",
         "reason": "agent exited", "created_at": time - seq]
    }
    func reply(_ result: [String: Any], request: [String: Any]? = nil, attachment: String? = nil) -> String {
        let request = request ?? sent.last!
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "session", "data": [
            "v": 1, "op": "host_work_result", "id": UUID().uuidString.lowercased(), "re": request["id"]!,
            "host": ["account_id": "account", "atem_device_id": "host", "host_trust_gen": 3],
            "attachment_gen": attachment ?? self.attachment, "channel_id": "channel", "result": result
        ]]), as: UTF8.self)
    }
    func page(_ alerts: [[String: Any]], more: Bool = false, request: [String: Any]? = nil) -> Bool {
        client.receive(reply(["kind": "alerts", "alerts": alerts, "more": more], request: request))
    }
    func refusal(_ code: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "session", "data": [
            "v": 1, "op": "error", "re": sent.last!["id"]!, "code": code
        ]]), as: UTF8.self)
    }
    func work(_ task: String, state: String, resolved: Bool = false, result: [String: Any]? = nil) -> [String: Any] {
        var work: [String: Any] = ["task_id": task, "receipt_id": UUID().uuidString.lowercased(),
            "state": state, "detail": "reviewed", "result": result as Any? ?? NSNull()]
        if resolved { work["resolved"] = ["by": "member:owner", "at": time] }
        return ["kind": "work", "work": work]
    }
}

final class RemoteOutcomeTests: XCTestCase {
    @MainActor
    func testRequiresAdvertisedAlertsAndCurrentControlAndResolutionGate() throws {
        let f = OutcomeFixture(enabled: false)
        f.connect(control: false)
        XCTAssertTrue(f.sent.isEmpty)
        f.connect(features: ["host.work"])
        XCTAssertTrue(f.sent.isEmpty)
        f.connect()
        XCTAssertEqual(f.sent.last?["op"] as? String, "alert_list")
        XCTAssertTrue(f.page([f.alert()]))
        XCTAssertTrue(f.client.canReviewOutcomes)
        XCTAssertFalse(f.client.canResolveOutcomes)
        XCTAssertNil(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        f.connect(control: false)
        XCTAssertTrue(f.client.alerts.isEmpty)
        XCTAssertFalse(f.client.canReviewOutcomes)
    }

    @MainActor
    func testFullFourPageScanUsesSequenceNotWallTimeAndStopsAt256() {
        let f = OutcomeFixture(); f.connect()
        for page in 0..<4 {
            let rows = (1...64).map { f.alert(UInt64(page * 64 + $0)) }
            XCTAssertTrue(f.page(rows, more: page < 3))
            if page < 3 {
                XCTAssertTrue(f.client.alerts.isEmpty)
                XCTAssertEqual(f.sent.last?["after"] as? String, rows.last?["alert_id"] as? String)
            }
        }
        XCTAssertFalse(f.client.loadingAlerts)
        XCTAssertEqual(f.client.alerts.count, 256)
        XCTAssertEqual(f.client.alerts.map(\.seq), Array(1...256).map(UInt64.init))
        XCTAssertEqual(f.sent.count, 4)
    }

    @MainActor
    func testLaterPageRefusalRetainsCardsAndRetryStartsAtTheBeginning() {
        let f = OutcomeFixture(); f.connect()
        let original = f.alert(); XCTAssertTrue(f.page([original]))
        f.client.refreshAlerts()
        XCTAssertTrue(f.page([f.alert(2)], more: true))
        XCTAssertTrue(f.client.receive(f.refusal("stale_target")))
        XCTAssertEqual(f.client.alerts.first?.id, original["alert_id"] as? String)
        XCTAssertFalse(f.client.loadingAlerts)
        f.client.refreshAlerts()
        XCTAssertNil(f.sent.last?["after"])
        XCTAssertTrue(f.page([]))
        XCTAssertTrue(f.client.alerts.isEmpty)
    }

    @MainActor
    func testDuplicateOrOutOfOrderAcrossPagesCannotReplaceTheLastCompleteScan() {
        let f = OutcomeFixture(); f.connect()
        XCTAssertTrue(f.page([f.alert()]))
        let original = f.client.alerts
        f.client.refreshAlerts()
        XCTAssertFalse(f.client.alertsLoaded, "An incomplete scan must not generate reminders")
        let page = f.alert(2)
        XCTAssertTrue(f.page([page], more: true))
        XCTAssertFalse(f.page([page]))
        XCTAssertFalse(f.page([f.alert(1)]))
        XCTAssertEqual(f.client.alerts, original)
        f.time += 16_000; f.client.tick()
        XCTAssertTrue(f.client.needsReconnect)
        XCTAssertEqual(f.client.alerts, original)
    }

    @MainActor
    func testEmptyMoreAndOverCapacityCannotPretendTheScanCompleted() {
        let f = OutcomeFixture(); f.connect()
        XCTAssertFalse(f.page([], more: true))
        XCTAssertTrue(f.client.loadingAlerts)
        for page in 0..<3 {
            XCTAssertTrue(f.page((1...64).map { f.alert(UInt64(page * 64 + $0)) }, more: true))
        }
        XCTAssertFalse(f.page((193...256).map { f.alert(UInt64($0)) }, more: true))
        XCTAssertEqual(f.sent.count, 4, "No fifth page may be sent after reaching the host's capacity")
        XCTAssertTrue(f.client.alerts.isEmpty)
    }

    @MainActor
    func testLostResolutionReplyNeverReplaysAndReconnectInvalidatesOldReview() throws {
        let f = OutcomeFixture(); f.connect()
        let row = f.alert(); XCTAssertTrue(f.page([row]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        XCTAssertTrue(f.client.resolve(review, failed: "Host operator confirmed failure"))
        let mutation = f.sent.last!
        XCTAssertFalse(f.client.resolve(review, failed: "Different decision"))
        f.time += 16_000; f.client.tick()
        XCTAssertTrue(f.client.needsReconnect)
        XCTAssertTrue(f.client.alertStatus?.contains("never replayed") == true)
        f.attachment = UUID().uuidString.lowercased(); f.connect()
        XCTAssertTrue(f.page([row]))
        XCTAssertFalse(f.client.resolve(review, failed: "Old confirmation"))
        XCTAssertFalse(f.client.receive(f.reply(f.work(review.alert.task_id, state: "failed", resolved: true), request: mutation)))
        XCTAssertEqual(f.sent.filter { $0["op"] as? String == "work_resolve" }.count, 1)
        XCTAssertEqual(f.client.alerts.count, 1)
    }

    @MainActor
    func testLossAndRegainOfControlCannotReuseAConfirmationWithoutLaunchFeature() throws {
        let f = OutcomeFixture(); f.connect()
        let row = f.alert(); XCTAssertTrue(f.page([row]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        f.connect(control: false)
        XCTAssertFalse(f.client.resolve(review, failed: "stale"))
        f.connect(); XCTAssertTrue(f.page([row]))
        XCTAssertFalse(f.client.resolve(review, failed: "stale"))
    }

    @MainActor
    func testResolutionReceiptRemovesCardAndPreservesResolverWithoutReexecuting() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        XCTAssertTrue(f.client.resolve(review, failed: "No file was created"))
        XCTAssertEqual((f.sent.last?["resolution"] as? [String: Any])?["kind"] as? String, "failed")
        XCTAssertEqual(f.client.alerts.count, 1, "Sending is not confirmation")
        XCTAssertTrue(f.client.receive(f.reply(f.work(review.alert.task_id, state: "failed", resolved: true))))
        XCTAssertTrue(f.client.alerts.isEmpty)
        XCTAssertEqual(f.client.work.first?.resolved?.by, "member:owner")
        XCTAssertFalse(f.sent.contains { ["host_launch", "work_enqueue", "submit", "acquire"].contains($0["op"] as? String ?? "") })
    }

    @MainActor
    func testLateScanPageCannotResurrectAnOutcomeResolvedDuringTheScan() throws {
        let f = OutcomeFixture(); f.connect()
        let row = f.alert(); XCTAssertTrue(f.page([row]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        XCTAssertTrue(f.client.resolve(review, failed: "confirmed"))
        let resolution = f.sent.last!
        f.client.refreshAlerts(); let scan = f.sent.last!
        XCTAssertTrue(f.client.receive(f.reply(f.work(review.alert.task_id, state: "failed", resolved: true), request: resolution)))
        XCTAssertTrue(f.page([row], request: scan))
        XCTAssertTrue(f.client.alerts.isEmpty)
    }

    @MainActor
    func testPreviouslyRunningTaskCanRaiseAnUnknownOutcomeOnTheSameAttachment() {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([]))
        let task = UUID().uuidString.lowercased()
        f.client.track(taskID: task)
        XCTAssertTrue(f.client.receive(f.reply(f.work(task, state: "executing"))))
        f.client.refreshAlerts(); XCTAssertTrue(f.page([f.alert(task: task)]))
        XCTAssertEqual(f.client.alerts.first?.task_id, task)
    }

    @MainActor
    func testRefusedResolutionRequiresAFreshScanAndNewReview() throws {
        let f = OutcomeFixture(); f.connect(); let row = f.alert(); XCTAssertTrue(f.page([row]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        XCTAssertTrue(f.client.resolve(review, failed: "confirmed"))
        XCTAssertTrue(f.client.receive(f.refusal("forbidden")))
        XCTAssertFalse(f.client.alertsLoaded)
        XCTAssertFalse(f.client.resolve(review, failed: "old decision"))
        f.client.refreshAlerts(); XCTAssertTrue(f.page([row]))
        XCTAssertFalse(f.client.resolve(review, failed: "old decision"))
        let fresh = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        XCTAssertTrue(f.client.resolve(fresh, failed: "new review"))
    }

    @MainActor
    func testUnknownTaskContinuesPollingAndLateReplyEndsTheAlertWithoutClaimingSuccess() throws {
        let f = OutcomeFixture(); f.connect(); let row = f.alert(); XCTAssertTrue(f.page([row]))
        let task = try XCTUnwrap(f.client.alerts.first?.task_id)
        f.client.track(taskID: task)
        XCTAssertTrue(f.client.receive(f.reply(f.work(task, state: "outcome_unknown"))))
        f.time += 5_000; f.client.tick()
        XCTAssertEqual(f.sent.last?["op"] as? String, "work_query")
        XCTAssertTrue(f.client.receive(f.reply(f.work(task, state: "awaiting_result"))))
        XCTAssertTrue(f.client.alerts.isEmpty)
        XCTAssertEqual(f.client.work.first?.state, "awaiting_result")
        XCTAssertNil(f.client.work.first?.resolved)
    }

    @MainActor
    func testDoneForwardsThePublishedSnapshotAndShowsOnlyTheConfirmedResult() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        let review = try XCTUnwrap(f.client.reviewOutcome(try XCTUnwrap(f.client.alerts.first)))
        let snapshot: [String: Any] = ["kind": "memory", "id": "published-result", "version": 3,
            "digest": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "text": ""]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
        XCTAssertFalse(f.client.resolve(review, done: "not json"))
        XCTAssertTrue(f.client.resolve(review, done: json))
        let resolution = try XCTUnwrap(f.sent.last?["resolution"] as? [String: Any])
        XCTAssertEqual(resolution["kind"] as? String, "done")
        XCTAssertEqual((resolution["result"] as? [String: Any])?["version"] as? Int, 3)
        XCTAssertTrue(f.client.alerts.count == 1)
        XCTAssertTrue(f.client.receive(f.reply(f.work(review.alert.task_id, state: "completed", resolved: true, result: snapshot))))
        XCTAssertEqual(f.client.work.first?.result?.id, "published-result")
        XCTAssertTrue(f.client.alerts.isEmpty)
    }

    @MainActor
    func testWrongAttachmentAndDuplicateResponseDoNotMutateAlerts() {
        let f = OutcomeFixture(); f.connect()
        let response = f.reply(["kind": "alerts", "alerts": [f.alert()], "more": false])
        XCTAssertFalse(f.client.receive(f.reply(["kind": "alerts", "alerts": [], "more": false], attachment: "old")))
        XCTAssertTrue(f.client.receive(response))
        XCTAssertFalse(f.client.receive(response))
        XCTAssertEqual(f.client.alerts.count, 1)
    }
}

final class RemoteOutcomeReminderTests: XCTestCase {
    private let genesis = String(repeating: "a", count: 64)

    @MainActor
    func testDailyReminderSurvivesReloadAndStoresNoTaskOrResultContent() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        var saved: Data?
        var book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", persist: { saved = $0 })
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time))
        let bytes = try XCTUnwrap(saved)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("agent exited"))
        XCTAssertFalse(text.contains("revoked-sender"))
        XCTAssertFalse(text.contains(f.client.alerts[0].task_id))
        book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", checkpoint: bytes,
            persist: { saved = $0 })
        XCTAssertFalse(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 86_399_999))
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 86_400_000))
        XCTAssertFalse(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 86_400_001))
    }

    @MainActor
    func testCommitThenThrowFencesTheWriterAndReloadDoesNotDuplicateNotification() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        var saved: Data?
        let book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", persist: {
            saved = $0; throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertThrowsError(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time))
        XCTAssertTrue(book.storageUncertain)
        XCTAssertThrowsError(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 86_400_000))
        let reloaded = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", checkpoint: saved,
            persist: { _ in })
        XCTAssertFalse(try reloaded.offer(host: f.host, alerts: f.client.alerts, now: f.time + 1))
    }

    @MainActor
    func testNewAlertsNotifyImmediatelyButRemovedAlertsEndTheDailyReminder() throws {
        let f = OutcomeFixture(); f.connect(); let row = f.alert(); XCTAssertTrue(f.page([row]))
        let book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", persist: { _ in })
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time))
        f.client.refreshAlerts(); XCTAssertTrue(f.page([row, f.alert(2)]))
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 100))
        XCTAssertFalse(try book.offer(host: f.host, alerts: [], now: f.time + 200))
        XCTAssertFalse(try book.offer(host: f.host, alerts: [], now: f.time + 86_400_000))
    }

    @MainActor
    func testAccountGenesisDeviceAndHostTrustScopesCannotShareNotificationHistory() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        var saved: Data?
        let book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", persist: { saved = $0 })
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time))
        XCTAssertThrowsError(try RemoteOutcomeReminders(accountID: "foreign", genesisHash: genesis, deviceID: "owner", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemoteOutcomeReminders(accountID: "account", genesisHash: String(repeating: "b", count: 64), deviceID: "owner", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "other", checkpoint: saved, persist: { _ in }))
        XCTAssertTrue(try book.offer(host: RemoteWorkHost(account: "account", device: "host", trust: 4), alerts: f.client.alerts, now: f.time + 1))
        XCTAssertThrowsError(try book.offer(host: RemoteWorkHost(account: "other", device: "host", trust: 4), alerts: f.client.alerts, now: f.time + 2))
    }

    @MainActor
    func testWallClockRollbackDoesNotCreateRepeatedReminders() throws {
        let f = OutcomeFixture(); f.connect(); XCTAssertTrue(f.page([f.alert()]))
        let book = try RemoteOutcomeReminders(accountID: "account", genesisHash: genesis, deviceID: "owner", persist: { _ in })
        XCTAssertTrue(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time))
        XCTAssertFalse(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time - 86_400_000))
        XCTAssertFalse(try book.offer(host: f.host, alerts: f.client.alerts, now: f.time + 1))
    }
}
