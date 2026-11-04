import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class HostWorkFixture {
    let host = RemoteWorkHost(account: "account", device: "host", trust: 3)
    var saved: [RemoteLaunchRecord] = []
    var sent: [[String: Any]] = []
    var time: UInt64 = 1_793_620_800_000
    var failSave = false
    var failSend = false
    var starts = 0
    var attachment = UUID().uuidString.lowercased()
    lazy var client = makeClient()

    func makeClient() -> RemoteHostWork {
        let client = RemoteHostWork(load: { self.saved }, save: {
            if self.failSave { throw CocoaError(.fileWriteUnknown) }
            self.saved = $0
        }, clock: { self.time }, send: {
            let root = try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            let data = root["data"] as! [String: Any]
            if data["op"] as? String == "host_launch" {
                XCTAssertEqual(self.saved.last?.requestID, data["request_id"] as? String)
            }
            self.sent.append(data)
            return !self.failSend
        })
        client.onStarted = { _ in self.starts += 1 }
        return client
    }

    func connect(_ client: RemoteHostWork? = nil, features: Set<String> = ["host.launch", "host.work"], control: Bool = true) {
        (client ?? self.client).connected(host: host, attachment: attachment, features: features, control: control)
    }

    func reply(_ result: [String: Any], request: [String: Any]? = nil, attachment: String? = nil) -> String {
        let request = request ?? sent.last!
        let root: [String: Any] = ["type": "session", "data": ["v": 1, "op": "host_work_result",
            "id": UUID().uuidString.lowercased(), "re": request["id"]!,
            "host": ["account_id": host.account_id, "atem_device_id": host.atem_device_id, "host_trust_gen": host.host_trust_gen],
            "attachment_gen": attachment ?? self.attachment, "channel_id": "channel", "result": result]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    func profiles() {
        connect()
        XCTAssertTrue(client.receive(reply(["kind": "profiles", "profiles": [
            ["id": "backend", "revision": 2, "label": "Backend OSS", "provider": "codex"]
        ]])))
    }

    func launch() -> String {
        profiles()
        return client.launch(client.profiles[0])!
    }

    func launchResult(_ id: String, state: String = "started", process: String = "11111111-1111-4111-8111-111111111111") -> [String: Any] {
        ["kind": "launch", "launch": ["request_id": id, "session_id": "ses-aaaaaaaaaaaa", "process_gen": process, "state": state]]
    }
}

final class RemoteHostWorkTests: XCTestCase {
    @MainActor
    func testReceiptRefusalAndTimeoutAreVisibleAndReconnectOnlyRepeatsQueries() throws {
        let f = HostWorkFixture()
        f.connect(features: ["host.work"], control: false)
        let id = UUID().uuidString.lowercased()
        f.client.track(taskID: id)
        let requestID = try XCTUnwrap(f.sent.last?["id"] as? String)
        let refusal: [String: Any] = ["type": "session", "data": ["v": 1, "op": "error", "re": requestID, "code": "forbidden"]]
        XCTAssertTrue(f.client.receive(String(decoding: try JSONSerialization.data(withJSONObject: refusal), as: UTF8.self)))
        XCTAssertTrue(f.client.trackingStatus?.contains("forbidden") == true)
        f.client.track(taskID: id)
        f.time += 16_000; f.client.tick()
        XCTAssertTrue(f.client.needsReconnect)
        XCTAssertFalse(f.client.canTrackTasks)
        XCTAssertTrue(f.client.trackingStatus?.contains("delayed") == true)
        f.attachment = UUID().uuidString.lowercased()
        f.connect(features: ["host.work"], control: false)
        XCTAssertTrue(f.client.canTrackTasks)
        XCTAssertNil(f.client.trackingStatus)
        XCTAssertEqual(f.sent.last?["task_id"] as? String, id)
        XCTAssertTrue(f.sent.allSatisfy { $0["op"] as? String == "work_query" })
    }

    @MainActor
    func testReceiptLookupWorksWithoutLaunchOrControlAndKeepsErrorsSeparateFromLaunchStatus() {
        let f = HostWorkFixture()
        f.connect(features: ["host.messages", "host.work"], control: false)
        XCTAssertFalse(f.client.available)
        XCTAssertTrue(f.client.canTrackMessages)
        XCTAssertTrue(f.client.canTrackTasks)
        let launchStatus = f.client.status
        f.client.track(messageID: "not-an-id")
        XCTAssertTrue(f.client.trackingStatus?.contains("valid message") == true)
        XCTAssertEqual(f.client.status, launchStatus)
        XCTAssertTrue(f.sent.isEmpty)
        let id = UUID().uuidString.lowercased()
        f.client.track(messageID: id)
        XCTAssertEqual(f.sent.last?["op"] as? String, "message_query")
        XCTAssertTrue(f.client.receive(f.reply(["kind": "message", "message": ["message_id": id,
            "digest": String(repeating: "a", count: 64), "sender": "service:test", "recipients": []]])))
        XCTAssertNil(f.client.trackingStatus)
        XCTAssertEqual(f.client.messages.first?.id, id)
        f.client.connected(host: nil, attachment: nil, features: [], control: false)
        XCTAssertFalse(f.client.canTrackMessages)
        XCTAssertFalse(f.client.canTrackTasks)
        XCTAssertTrue(f.client.messages.isEmpty)
        let count = f.sent.count
        f.client.track(taskID: UUID().uuidString.lowercased())
        XCTAssertEqual(f.sent.count, count)
        XCTAssertFalse(f.sent.contains { ["host_launch", "acquire", "submit"].contains($0["op"] as? String ?? "") })
    }

    @MainActor
    func testPersistsBeforeLaunchAndNeverReplaysAfterLostReplyOrAppRestart() {
        let f = HostWorkFixture(), id = f.launch()
        XCTAssertEqual(f.sent.filter { $0["op"] as? String == "host_launch" }.count, 1)
        f.time += 16_000; f.client.tick()
        XCTAssertTrue(f.client.needsReconnect)
        XCTAssertEqual(f.sent.last?["op"] as? String, "host_launch")
        let restarted = f.makeClient()
        f.attachment = UUID().uuidString.lowercased(); f.connect(restarted)
        XCTAssertEqual(f.sent.last?["op"] as? String, "host_launch_query")
        XCTAssertEqual(f.sent.filter { $0["op"] as? String == "host_launch" }.count, 1)
        XCTAssertTrue(restarted.receive(f.reply(f.launchResult(id))))
        XCTAssertEqual(restarted.currentLaunches.first?.status?.state, .started)
        XCTAssertEqual(f.starts, 1)
    }

    @MainActor
    func testFailedPersistenceOrMissingControlNeverLaunches() {
        let f = HostWorkFixture(); f.profiles(); f.failSave = true
        XCTAssertNil(f.client.launch(f.client.profiles[0]))
        XCTAssertTrue(f.client.storageFailed)
        XCTAssertFalse(f.sent.contains { $0["op"] as? String == "host_launch" })
        f.connect(control: false)
        XCTAssertFalse(f.client.available)
        XCTAssertTrue(f.client.profiles.isEmpty)
    }

    @MainActor
    func testProfileRefreshCannotHideAPersistenceFailure() {
        let f = HostWorkFixture(); f.profiles()
        f.client.refreshProfiles()
        let profileRequest = f.sent.last!
        f.failSave = true
        XCTAssertNil(f.client.launch(f.client.profiles[0]))
        let failure = f.client.status, sent = f.sent.count
        XCTAssertFalse(f.client.receive(f.reply(["kind": "profiles", "profiles": []], request: profileRequest)))
        f.client.refreshProfiles(); f.time += 16_000; f.client.tick()
        XCTAssertEqual(f.client.status, failure)
        XCTAssertEqual(f.sent.count, sent)
    }

    @MainActor
    func testStaleAttachmentAndWrongRequestCannotPublishLaunchOrRestoreState() {
        let f = HostWorkFixture(), id = f.launch(), original = f.sent.last!
        XCTAssertFalse(f.client.receive(f.reply(f.launchResult(id), attachment: UUID().uuidString.lowercased())))
        XCTAssertFalse(f.client.receive(f.reply(f.launchResult(UUID().uuidString.lowercased()))))
        XCTAssertNil(f.saved.last?.status)
        f.client.connected(host: nil, attachment: nil, features: [], control: false)
        XCTAssertFalse(f.client.receive(f.reply(f.launchResult(id), request: original)))
        XCTAssertEqual(f.starts, 0)
    }

    @MainActor
    func testAStartedLaunchDoesNotRegressOrChangeProcessIdentity() {
        let f = HostWorkFixture(), id = f.launch()
        XCTAssertTrue(f.client.receive(f.reply(f.launchResult(id))))
        XCTAssertFalse(f.client.receive(f.reply(f.launchResult(id, state: "starting"))))
        XCTAssertEqual(f.saved.last?.status?.state, .started)
        XCTAssertEqual(f.starts, 1)
    }

    @MainActor
    func testSendFailureRetainsUnconfirmedIdentityForQuery() {
        let f = HostWorkFixture(); f.profiles(); f.failSend = true
        let id = f.client.launch(f.client.profiles[0])!
        XCTAssertEqual(f.saved.last?.requestID, id)
        f.failSend = false; f.client.refresh()
        XCTAssertEqual(f.sent.last?["op"] as? String, "host_launch_query")
        XCTAssertEqual(f.sent.last?["request_id"] as? String, id)
    }

    @MainActor
    func testTaskTurnEndRemainsAwaitingResultAndNeverLooksCompleted() {
        let f = HostWorkFixture(); f.connect()
        let id = UUID().uuidString.lowercased()
        f.client.track(taskID: id)
        XCTAssertTrue(f.client.receive(f.reply(["kind": "work", "work": ["task_id": id,
            "receipt_id": UUID().uuidString.lowercased(), "state": "awaiting_result", "detail": "turn finished", "result": NSNull()]])))
        XCTAssertEqual(f.client.work.first?.state, "awaiting_result")
        f.time += 5_000; f.client.tick()
        XCTAssertEqual(f.sent.last?["op"] as? String, "work_query")
    }

    @MainActor
    func testOldHostsWithoutLaunchFeatureCannotSendLaunchRequests() {
        let f = HostWorkFixture(); f.connect(features: [])
        f.client.refreshProfiles(); f.client.refresh()
        XCTAssertFalse(f.client.available)
        XCTAssertTrue(f.sent.isEmpty)
    }

    @MainActor
    func testTimeoutStopsFillingTheSdkExchangeLimitAndRecoversOnlyOnAFreshAttachment() {
        let f = HostWorkFixture(), id = f.launch()
        f.time += 16_000; f.client.tick()
        let sent = f.sent.count
        for _ in 0..<100 { f.time += 5_000; f.client.tick() }
        XCTAssertEqual(f.sent.count, sent)
        XCTAssertTrue(f.client.needsReconnect)
        f.attachment = UUID().uuidString.lowercased(); f.connect()
        XCTAssertFalse(f.client.needsReconnect)
        XCTAssertEqual(f.sent.last?["op"] as? String, "host_launch_query")
        XCTAssertEqual(f.sent.last?["request_id"] as? String, id)
        XCTAssertEqual(f.sent.filter { $0["op"] as? String == "host_launch" }.count, 1)
    }

    @MainActor
    func testStoredMessageIsNeitherAgentInputNorTaskCompletionAndDoesNotPollForever() {
        let f = HostWorkFixture(); f.connect(features: ["host.launch", "host.messages"])
        let id = UUID().uuidString.lowercased()
        f.client.track(messageID: id)
        XCTAssertTrue(f.client.receive(f.reply(["kind": "message", "message": ["message_id": id,
            "digest": String(repeating: "a", count: 64), "sender": "service:test",
            "recipients": [["recipient_id": UUID().uuidString.lowercased(), "delivery": ["state": "stored"]]]]])))
        XCTAssertEqual(f.client.messages.first?.recipients.first?.delivery.state, "stored")
        XCTAssertTrue(f.client.work.isEmpty)
        let sent = f.sent.count
        f.time += 5_000; f.client.tick()
        XCTAssertEqual(f.sent.count, sent)
    }
}
