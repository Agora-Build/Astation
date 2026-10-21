import XCTest
import NIOHTTP1
import CryptoKit
@testable import Menubar

private let sessionID = "ses-aaaaaaaaaaaa"
private let processID = "22222222-2222-4222-8222-222222222222"
private let attachmentID = "33333333-3333-4333-8333-333333333333"
private let runtimeID = "55555555-5555-4555-8555-555555555555"
private let controllerID = "66666666-6666-4666-8666-666666666666"

private final class SessionDisk {
    var state = AtemSessionJournal.Snapshot()
    var fail = false
    func journal() -> AtemSessionJournal {
        AtemSessionJournal(load: { self.state }, save: { state in
            if self.fail { throw CocoaError(.fileWriteUnknown) }
            self.state = state
        })
    }
}

private final class SessionFixture {
    var time: TimeInterval = 0
    var source: AtemSessionContext? = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "socket-1"),
        account: "account-a", device: "host-a", pairingSession: "pairing-1")
    var sent: [AtemSessionMessage] = []
    var chats: [AgentChatWire] = []
    var reconnects: [AtemSessionContext] = []
    var nextID: String?
    var canSend = true
    let disk: SessionDisk
    lazy var client = makeClient()
    func makeClient() -> AtemSessionClient { AtemSessionClient(context: { self.source }, send: { message, _ in
        self.sent.append(message)
        return self.canSend
    }, journal: disk.journal(), makeID: {
        defer { self.nextID = nil }
        return self.nextID ?? UUID().uuidString.lowercased()
    }, now: { self.time }, reconnect: { context in
        self.reconnects.append(context)
        return true
    }, sendChat: { message, _ in
        self.chats.append(message)
        return self.canSend
    }) }

    init(disk: SessionDisk = SessionDisk()) { self.disk = disk }
    var route: RemoteTerminalConnection { source!.route }
    var target: AtemSessionTarget { AtemSessionTarget(account_id: "account-a", atem_device_id: "host-a", host_trust_gen: 1, session_id: sessionID, process_gen: processID) }

    func handshake(trust: UInt64 = 1, runtime: String = runtimeID, attachment: String = attachmentID,
                   permissions: [String] = ["view", "control"], helloID: String? = nil,
                   controller: String = controllerID, remaining: UInt64 = 60_000,
                   features: [String] = AtemSessionWire.features.sorted(),
                   mutate: (inout AtemSessionMessage) -> Void = { _ in }) throws {
        if sent.isEmpty { client.start() }
        let hello = try XCTUnwrap(sent.last(where: { $0.op == "hello" }))
        var reply = AtemSessionMessage(op: "welcome")
        reply.re = helloID ?? hello.id
        reply.revision = 8
        reply.features = features
        reply.account_id = "account-a"
        reply.atem_device_id = "host-a"
        reply.host_trust_gen = trust
        reply.runtime_gen = runtime
        reply.controller_session = controller
        reply.attachment_gen = attachment
        reply.client_kind = "native"
        reply.permissions = permissions
        reply.authorization_ms_left = remaining
        reply.server_time = 1_760_500_000_000
        mutate(&reply)
        try receive(reply)
    }

    func ready() throws {
        try handshake()
        try snapshot()
    }

    func snapshot(epoch: UInt64 = 7, sequence: UInt64 = 1, runtime: String = runtimeID,
                  descriptors: [AtemSessionDescriptor]? = nil) throws {
        var reply = AtemSessionMessage(op: "sessions")
        reply.runtime_gen = runtime
        reply.runtime_epoch = epoch
        reply.seq = sequence
        reply.sessions = try descriptors ?? [Self.descriptor()]
        try receive(reply)
    }

    static func descriptor(session: String = sessionID, state: String = "running", process: String = processID, provider: String = "claude", controller: AtemSessionController? = nil) throws -> AtemSessionDescriptor {
        let json: [String: Any] = ["session_id": session, "process_gen": process, "provider": provider, "cwd_label": "Atem",
            "state": state, "activity": "ready", "activity_since": 1_760_500_000_000,
            "controller": controller.map { ["controller_session": $0.controller_session, "lease_epoch": $0.lease_epoch] } as Any? ?? NSNull(), "capabilities": ["terminal-v1", "chat-v1"], "created_at": 1_760_490_000_000]
        return try JSONDecoder().decode(AtemSessionDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func takeControl(epoch: UInt64 = 1) throws {
        client.acquire(target)
        try lease(replyTo: XCTUnwrap(sent.last(where: { $0.op == "acquire" })).id, epoch: epoch)
    }

    func lease(replyTo: String, epoch: UInt64 = 1, remaining: UInt64 = 15_000) throws {
        var reply = AtemSessionMessage(op: "lease")
        reply.re = replyTo
        reply.binding = AtemSessionBinding(target: target, attachment_gen: attachmentID, lease_epoch: epoch)
        reply.ms_left = remaining
        try receive(reply)
    }

    func receive(_ message: AtemSessionMessage, route: RemoteTerminalConnection? = nil) throws {
        let bytes = try JSONEncoder().encode(AstationMessage.session(message))
        guard case .session(let decoded) = try AstationMessage.decodePacket(bytes) else { throw AtemSessionJSON.Invalid.json }
        client.receive(decoded, from: route ?? self.route)
    }

    func receipt(_ request: String, state: AtemReceiptState, time: UInt64 = 100) throws {
        var reply = AtemSessionMessage(op: "receipt")
        reply.request_id = request
        reply.target = target
        reply.kind = "prompt"
        reply.state = state
        reply.updated_at = time
        try receive(reply)
    }
}

private extension SessionFixture {
    func approval(id: String = "88888888-8888-4888-8888-888888888888", process: String = processID,
                  rules: [AtemApprovalRule] = []) throws -> AtemApprovalRequest {
        var message = AtemSessionMessage(op: "approval_request")
        message.approval_id = id; message.session_id = sessionID; message.process_gen = process
        message.tool = "Bash"; message.summary = "npm test"; message.created_at = 1_760_500_000_000
        message.always_rules = rules
        try receive(message)
        return try XCTUnwrap(message.approval)
    }

    func closeApproval(_ id: String, reason: String = "answered_terminal") throws {
        var message = AtemSessionMessage(op: "approval_closed")
        message.approval_id = id; message.reason = reason
        try receive(message)
    }

    func rules(_ rules: [AtemApprovalRule], process: String = processID, route: RemoteTerminalConnection? = nil) throws {
        var message = AtemSessionMessage(op: "approval_rules")
        message.session_id = sessionID; message.process_gen = process; message.rules = rules
        try receive(message, route: route)
    }

    func chat(_ op: String, sequence: UInt64, part: AgentChatPart? = nil,
              conversation: String? = nil, process: String = processID, route: RemoteTerminalConnection? = nil) throws {
        let opened = try XCTUnwrap(chats.last(where: { $0.op == "open" }))
        var event = AgentChatWire(op: op, conversationId: conversation ?? opened.conversationId,
            agentId: sessionID, generation: process, sequence: sequence)
        if op == "opened" { event.status = AgentChatStatus(state: "ready", since: .milliseconds(1_760_500_000_000)) }
        if let part {
            event.messageId = "approval-88888888-8888-4888-8888-888888888888"
            event.role = "assistant"; event.turnId = "turn-1"; event.createdAt = .milliseconds(1_760_500_000_000)
            event.parts = [part]
        }
        let bytes = try JSONEncoder().encode(AstationMessage.agentChat(event))
        guard case .agentChat(let decoded) = try AstationMessage.decodePacket(bytes) else { throw AtemSessionJSON.Invalid.json }
        client.receiveChat(decoded, from: route ?? self.route)
    }
}

@MainActor
final class LocalControlAPISessionTests: XCTestCase {
    private func api(_ f: SessionFixture) throws -> LocalControlAPI {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(String(repeating: "ab", count: 32).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let inbox = ApprovalInbox()
        f.client.onChange = { inbox.sync(sourceID: "host", client: f.client, host: "Test host") }
        inbox.sync(sourceID: "host", client: f.client, host: "Test host")
        return LocalControlAPI(key: try LocalAPIKey(file: file.path), clients: { ["host": f.client] },
            inbox: inbox, records: { f.disk.state.requests })
    }

    private func post(_ api: LocalControlAPI, _ path: String, _ object: [String: Any]) throws -> LocalAPIResponse {
        api.handle(method: .POST, path: "/api/v1/" + path, body: try JSONSerialization.data(withJSONObject: object))
    }

    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }

    func testPromptSubmissionsAcquireAtomicallyAndIdenticalRetriesNeverReplay() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        var input: [String: Any] = ["client_id": "host", "target": try object(f.target),
            "request_id": UUID().uuidString.lowercased(), "kind": "prompt", "text": "one test prompt"]
        XCTAssertEqual(try post(api, "sessions/submit", input).status, .accepted)
        XCTAssertEqual(f.sent.last?.acquire, true)
        XCTAssertNil(f.sent.last?.binding?.lease_epoch)
        XCTAssertEqual(try post(api, "sessions/submit", input).status, .accepted)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        input["text"] = "different prompt"
        XCTAssertEqual(try post(api, "sessions/submit", input).status, .conflict)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        f.source = nil
        XCTAssertEqual(try post(api, "sessions/submit", input).status, .conflict)
    }

    func testApprovalAnswersRequireExactSnapshotAndClaudeRuleWithIdempotentRetries() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        let rule = AtemApprovalRule(rule_id: "npm-test", label: "Bash(npm test:*)", scope: "this project")
        let approval = try f.approval(rules: [rule])
        var input: [String: Any] = ["client_id": "host", "target": try object(f.target),
            "request_id": UUID().uuidString.lowercased(), "approval": try object(approval), "decision": "allow_always",
            "rule": try object(rule)]
        input["rule"] = ["rule_id": rule.rule_id, "label": "Bash(*)", "scope": rule.scope]
        XCTAssertEqual(try post(api, "approvals/answer", input).status, .badRequest)
        input["rule"] = try object(rule)
        XCTAssertEqual(try post(api, "approvals/answer", input).status, .accepted)
        try f.closeApproval(approval.approval_id, reason: "answered_remote")
        XCTAssertEqual(try post(api, "approvals/answer", input).status, .accepted)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        let list = api.handle(method: .GET, path: "/api/v1/approvals", body: Data())
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        XCTAssertEqual(entries.first?["can_answer"] as? Bool, false)
        input["request_id"] = UUID().uuidString.lowercased()
        XCTAssertEqual(try post(api, "approvals/answer", input).status, .conflict)
    }

    func testTerminalAnswerExpiryAndUnknownReceiptCannotBeOverriddenThroughAPI() throws {
        for reason in ["answered_terminal", "timed_out", "process_ended"] {
            let f = SessionFixture(); try f.ready()
            let api = try api(f)
            let approval = try f.approval()
            try f.closeApproval(approval.approval_id, reason: reason)
            let input: [String: Any] = ["client_id": "host", "target": try object(f.target),
                "request_id": UUID().uuidString.lowercased(), "approval": try object(approval),
                "decision": "deny", "message": "Test denial"]
            XCTAssertEqual(try post(api, "approvals/answer", input).status, .conflict)
            XCTAssertFalse(f.sent.contains { $0.op == "submit" })
        }
    }

    func testReceiptQueriesRequireFullTargetAndMalformedBodiesNeverAct() throws {
        let f = SessionFixture(); try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "one prompt"))
        let api = try api(f)
        let query: [String: Any] = ["target": try object(f.target), "request_id": request]
        XCTAssertEqual(try post(api, "receipts/query", query).status, .ok)
        XCTAssertEqual(try post(api, "receipts/query", ["request_id": request]).status, .badRequest)
        let duplicate = Data(#"{"client_id":"host","client_id":"other"}"#.utf8)
        XCTAssertEqual(api.handle(method: .POST, path: "/api/v1/sessions/submit", body: duplicate).status, .badRequest)
        XCTAssertEqual(api.handle(method: .GET, path: "/api/v1/trust/enroll", body: Data()).status, .notFound)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
    }

    func testCodexSessionRulesCanBeGrantedThroughAPI() throws {
        let f = SessionFixture(); try f.ready()
        try f.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(provider: "codex")])
        let api = try api(f)
        let rule = AtemApprovalRule(rule_id: "s-0123456789abcdef", label: "npm test in /project", scope: "session")
        let request = try f.approval(rules: [rule])
        let input: [String: Any] = ["client_id": "host", "target": try object(f.target),
            "request_id": UUID().uuidString.lowercased(), "approval": try object(request),
            "decision": "allow_always", "rule": try object(rule)]
        XCTAssertEqual(try post(api, "approvals/answer", input).status, .accepted)
        XCTAssertEqual(f.sent.last?.payload?["rule_id"], .string(rule.rule_id))
        XCTAssertEqual(f.sent.last?.payload?["acquire"], nil)
    }

    func testRulesAPIRevokesWithoutLeaseAndNeverRedispatchesUUIDEvenAfterRemoval() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        let rule = AtemApprovalRule(rule_id: "s-0123456789abcdef", label: "npm test in /project", scope: "session")
        try f.rules([rule])
        let list = api.handle(method: .GET, path: "/api/v1/approval-rules", body: Data())
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["can_revoke"] as? Bool, true)
        XCTAssertEqual(entries.first?["controls"] as? Bool, false)
        var input: [String: Any] = ["client_id": "host", "target": try object(f.target),
            "request_id": UUID().uuidString.lowercased(), "rule_id": rule.rule_id]
        XCTAssertEqual(try post(api, "approval-rules/revoke", input).status, .accepted)
        XCTAssertNil(f.sent.last?.binding?.lease_epoch)
        XCTAssertFalse(f.sent.contains { $0.op == "acquire" || $0.op == "release" })
        try f.rules([])
        XCTAssertEqual(try post(api, "approval-rules/revoke", input).status, .accepted)
        input["rule_id"] = "s-other"
        XCTAssertEqual(try post(api, "approval-rules/revoke", input).status, .conflict)
        XCTAssertEqual(f.sent.filter { $0.kind == "approval_rule_revoke" }.count, 1)
        f.source = nil
        XCTAssertEqual(api.handle(method: .GET, path: "/api/v1/approval-rules", body: Data()).body, Data("[]".utf8))
    }
}

final class AtemSessionRuleTests: XCTestCase {
    private let rule = AtemApprovalRule(rule_id: "s-0123456789abcdef", label: "Always allow npm test in /project", scope: "session")

    func testRuleCardCanRevokeBeforeAndAfterControlIsGrantedAndReleased() throws {
        let f = SessionFixture(); let inbox = ApprovalInbox()
        f.client.onChange = { inbox.sync(sourceID: "host", client: f.client, host: "Genie") }
        try f.ready(); try f.rules([rule])
        let viewing = try XCTUnwrap(inbox.rules.first)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertTrue(viewing.canRevoke)
        f.client.acquire(f.target)
        XCTAssertTrue(try XCTUnwrap(inbox.rules.first).canRevoke)
        try f.lease(replyTo: XCTUnwrap(f.sent.last(where: { $0.op == "acquire" })).id)
        let controlling = try XCTUnwrap(inbox.rules.first)
        XCTAssertEqual(viewing.id, controlling.id)
        XCTAssertTrue(f.client.controls(f.target))
        XCTAssertTrue(controlling.canRevoke)
        f.client.release(f.target)
        let released = try XCTUnwrap(inbox.rules.first)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertTrue(released.canRevoke)
        XCTAssertFalse(f.sent.contains { $0.kind == "approval_rule_revoke" }, "Taking control never revokes a rule implicitly")
        try f.rules([])
        XCTAssertTrue(released.canRevoke, "Presentation snapshots remain immutable")
        XCTAssertNil(released.client.revokeRule(released.rule, target: released.target), "A stale enabled button cannot bypass the live rule check")
    }

    func testRuleCardSnapshotUpdatesRevocationStatusWithoutMutatingEarlierRows() throws {
        let f = SessionFixture(); let inbox = ApprovalInbox()
        f.client.onChange = { inbox.sync(sourceID: "host", client: f.client, host: "Genie") }
        try f.ready(); try f.rules([rule])
        let before = try XCTUnwrap(inbox.rules.first)
        XCTAssertTrue(before.canRevoke)
        XCTAssertFalse(f.client.controls(f.target))
        let requestID = try XCTUnwrap(f.client.revokeRule(rule, target: f.target))
        let pending = try XCTUnwrap(inbox.rules.first)
        XCTAssertFalse(pending.canRevoke)
        XCTAssertTrue(pending.status.contains("Revocation pending"))
        XCTAssertFalse(before.status.contains("Revocation pending"))
        var receipt = AtemSessionMessage(op: "receipt")
        receipt.request_id = requestID; receipt.target = f.target; receipt.kind = "approval_rule_revoke"
        receipt.state = .completed; receipt.updated_at = 1
        try f.receive(receipt)
        XCTAssertTrue(try XCTUnwrap(inbox.rules.first).status.contains("Revoked."))
        XCTAssertTrue(pending.status.contains("Revocation pending"))
    }

    private var automatic: AgentChatPart {
        AgentChatPart(id: "approval", kind: "approval", summary: "npm test",
            approval_id: "88888888-8888-4888-8888-888888888888", tool: "Bash", always_rules: [],
            state: "auto_allowed", rule_id: rule.rule_id)
    }

    func testPublishedR8RevokeFixturePinsAndValidatesEveryClientRequest() throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "atem-session-v1", withExtension: nil, subdirectory: "Fixtures"))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("source.json"))) as? [String: Any])
        XCTAssertEqual(source["commit"] as? String, "4f87bab1289848cb6a0da5707d2e7830eb5c057d")
        XCTAssertEqual(source["revision"] as? String, "r8")
        let hashes = try XCTUnwrap(source["sha256"] as? [String: String])
        let name = "approval-rule-revoke-needs-control-not-the-lease.json"
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[name])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(fixture["steps"] as? [[String: Any]])
        var revokes: [AtemSessionMessage] = []
        var invalidPayloads = 0
        for step in steps where step["send"] != nil {
            let envelope = try XCTUnwrap(step["json"] as? [String: Any])
            let fields = try XCTUnwrap(envelope["data"] as? [String: Any])
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            if fields["kind"] as? String == "approval_rule_revoke",
               (fields["payload"] as? [String: Any])?["acquire"] != nil {
                XCTAssertThrowsError(try AstationMessage.decodePacket(bytes))
                invalidPayloads += 1
                continue
            }
            guard case .session(let message) = try AstationMessage.decodePacket(bytes) else {
                return XCTFail("Expected a session request")
            }
            if message.kind == "approval_rule_revoke" { revokes.append(message) }
        }
        XCTAssertEqual(invalidPayloads, 1)
        XCTAssertEqual(revokes.count, 7)
        XCTAssertTrue(revokes.contains { $0.binding?.lease_epoch == nil })
        XCTAssertTrue(revokes.contains { $0.binding?.lease_epoch == 1 })
        XCTAssertTrue(revokes.contains { $0.payload?["rule_id"] == .string(rule.rule_id) })
    }

    func testRulesRequireCurrentControlPermissionProcessAndRoute() throws {
        let f = SessionFixture(); try f.ready()
        try f.rules([rule], process: "99999999-9999-4999-8999-999999999999")
        try f.rules([rule], route: RemoteTerminalConnection(clientId: "host", connectionId: "old-socket"))
        XCTAssertTrue(f.client.approvalRules.isEmpty)
        try f.rules([rule])
        XCTAssertTrue(f.client.hasRule(rule, target: f.target))
        let viewer = SessionFixture(); try viewer.handshake(permissions: ["view"]); try viewer.snapshot()
        try viewer.rules([rule])
        XCTAssertTrue(viewer.client.approvalRules.isEmpty)
        XCTAssertTrue(viewer.chats.allSatisfy { $0.op == "open" && $0.binding?.lease_epoch == nil })
        XCTAssertNil(viewer.client.revokeRule(rule, target: viewer.target))
        f.source = nil
        XCTAssertFalse(f.client.hasRule(rule, target: f.target))
        f.client.tick()
        XCTAssertTrue(f.client.approvalRules.isEmpty)
    }

    func testFreshSnapshotRefreshProcessEndAndReplacementClearRules() throws {
        let f = SessionFixture(); try f.ready(); try f.rules([rule])
        try f.snapshot(sequence: 2)
        XCTAssertTrue(f.client.approvalRules.isEmpty)
        try f.rules([rule]); f.client.refresh()
        XCTAssertFalse(f.client.hasRule(rule, target: f.target))
        try f.snapshot(sequence: 3); try f.rules([rule])
        try f.snapshot(sequence: 4, descriptors: [SessionFixture.descriptor(state: "exited")])
        XCTAssertTrue(f.client.approvalRules.isEmpty)
        try f.snapshot(sequence: 5, descriptors: [SessionFixture.descriptor(process: "99999999-9999-4999-8999-999999999999")])
        try f.rules([rule])
        XCTAssertTrue(f.client.approvalRules.isEmpty)
    }

    func testRevokeWithoutLeasePersistsBeforeSendingAndQueriesAfterReconnect() throws {
        let disk = SessionDisk()
        let f = SessionFixture(disk: disk); try f.ready(); try f.rules([rule])
        f.canSend = false
        let requestID = try XCTUnwrap(f.client.revokeRule(rule, target: f.target))
        let message = try XCTUnwrap(f.sent.last)
        XCTAssertEqual(message.kind, "approval_rule_revoke")
        XCTAssertNil(message.binding?.lease_epoch)
        XCTAssertEqual(message.payload, .object(["rule_id": .string(rule.rule_id)]))
        XCTAssertEqual(disk.state.requests.last?.requestId, requestID)
        XCTAssertFalse(f.sent.contains { $0.op == "acquire" || $0.op == "release" })
        XCTAssertNil(f.client.revokeRule(rule, target: f.target))
        let recovered = SessionFixture(disk: disk); try recovered.ready(); try recovered.rules([rule])
        XCTAssertFalse(recovered.client.journal.loadFailed)
        XCTAssertTrue(recovered.sent.contains { $0.op == "receipt_query" && $0.request_ids?.contains(requestID) == true })
        XCTAssertFalse(recovered.sent.contains { $0.op == "submit" || $0.op == "acquire" })
        XCTAssertNil(recovered.client.revokeRule(rule, target: recovered.target))
    }

    func testRevokePersistenceFailureSendsNeitherMutationNorAcquire() throws {
        let f = SessionFixture(); try f.ready(); try f.rules([rule])
        f.disk.fail = true
        XCTAssertNil(f.client.revokeRule(rule, target: f.target))
        XCTAssertFalse(f.sent.contains { $0.op == "submit" || $0.op == "acquire" })
    }

    func testRevokePreservesOwnLeaseAndDoesNotAcquireAnotherControllersLease() throws {
        for ownsLease in [false, true] {
            let f = SessionFixture(); try f.ready(); try f.rules([rule])
            if ownsLease { try f.takeControl(epoch: 3) }
            else {
                var other = AtemSessionMessage(op: "lease_changed")
                other.session_id = sessionID; other.process_gen = processID; other.lease_epoch = 3
                other.reason = "granted"
                other.controller = AtemSessionController(controller_session: "99999999-9999-4999-8999-999999999999", lease_epoch: 3)
                try f.receive(other)
            }
            let binding = f.client.binding(for: f.target, mutation: true)
            let deadline = f.client.controlDeadline(for: f.target)
            let before = f.sent.count
            XCTAssertNotNil(f.client.revokeRule(rule, target: f.target))
            XCTAssertEqual(f.client.controls(f.target), ownsLease)
            XCTAssertEqual(f.client.binding(for: f.target, mutation: true), binding)
            XCTAssertEqual(f.client.controlDeadline(for: f.target), deadline)
            XCTAssertEqual(f.sent.count, before + 1)
            XCTAssertEqual(f.sent.last?.kind, "approval_rule_revoke")
            XCTAssertNil(f.sent.last?.binding?.lease_epoch)
        }
    }

    func testRevokeAfterLeaseExpiryStillRequiresFreshDeviceAndProcessAuthority() throws {
        let f = SessionFixture(); try f.ready(); try f.rules([rule]); try f.takeControl()
        f.time = 15; f.client.tick()
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertNotNil(f.client.revokeRule(rule, target: f.target))
        XCTAssertNil(f.sent.last?.binding?.lease_epoch)
        for invalidation in ["offline", "socket", "process", "authorization", "permission"] {
            let g = SessionFixture(); try g.ready(); try g.rules([rule])
            switch invalidation {
            case "offline": g.source = nil
            case "socket":
                g.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "socket-2"),
                    account: "account-a", device: "host-a", pairingSession: "pairing-1")
            case "process":
                try g.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(process: "99999999-9999-4999-8999-999999999999")])
            case "authorization": g.time = 60
            default:
                g.source = nil; g.client.connectionChanged()
                g.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "socket-2"),
                    account: "account-a", device: "host-a", pairingSession: "pairing-1")
                g.client.connectionChanged(); try g.handshake(permissions: ["view"]); try g.snapshot()
            }
            XCTAssertNil(g.client.revokeRule(rule, target: g.target), invalidation)
            XCTAssertFalse(g.sent.contains { $0.kind == "approval_rule_revoke" || $0.op == "acquire" }, invalidation)
        }
    }

    func testRevokeReceiptsAndRegrantOfSameRuleRemainUsable() throws {
        let f = SessionFixture(); try f.ready(); try f.rules([rule]); try f.takeControl()
        let requestID = try XCTUnwrap(f.client.revokeRule(rule, target: f.target))
        for (index, state) in [AtemReceiptState.accepted, .executing, .completed].enumerated() {
            var message = AtemSessionMessage(op: "receipt")
            message.request_id = requestID; message.target = f.target; message.kind = "approval_rule_revoke"
            message.state = state; message.updated_at = UInt64(index + 1)
            try f.receive(message)
        }
        XCTAssertFalse(f.client.canRevoke(rule, target: f.target))
        try f.rules([])
        XCTAssertFalse(f.client.hasRule(rule, target: f.target))
        try f.rules([rule])
        XCTAssertTrue(f.client.canRevoke(rule, target: f.target))
        XCTAssertNotNil(f.client.revokeRule(rule, target: f.target))
        XCTAssertEqual(f.sent.filter { $0.kind == "approval_rule_revoke" }.count, 2)
    }

    func testRuleWireBoundsAndStrictRevokePayload() throws {
        let f = SessionFixture(); try f.ready()
        var list = AtemSessionMessage(op: "approval_rules")
        list.session_id = sessionID; list.process_gen = processID
        list.rules = [rule, rule]
        XCTAssertThrowsError(try list.validate())
        list.rules = (0..<33).map { AtemApprovalRule(rule_id: "s-\($0)", label: "command", scope: "session") }
        XCTAssertThrowsError(try list.validate())
        list.rules = [AtemApprovalRule(rule_id: "r", label: "bad\u{1b}", scope: "session")]
        XCTAssertThrowsError(try list.validate())
        list.rules = [AtemApprovalRule(rule_id: "r", label: "all projects", scope: "account")]
        XCTAssertThrowsError(try list.validate())
        var revoke = AtemSessionMessage(op: "submit")
        revoke.binding = AtemSessionBinding(target: f.target, attachment_gen: attachmentID, lease_epoch: 1)
        revoke.request_id = UUID().uuidString.lowercased(); revoke.kind = "approval_rule_revoke"
        revoke.payload = .object(["rule_id": .string(rule.rule_id)])
        XCTAssertNoThrow(try revoke.validate())
        revoke.payload = .object(["rule_id": .string(rule.rule_id), "acquire": .bool(true)])
        XCTAssertThrowsError(try revoke.validate())
        revoke.payload = .object(["rule_id": .string(rule.rule_id)]); revoke.binding?.lease_epoch = nil
        XCTAssertNoThrow(try revoke.validate())
        revoke.kind = "prompt"; revoke.payload = .object(["text": .string("test")])
        XCTAssertThrowsError(try revoke.validate(), "Only rule revocation gains the lease-free exception")
    }

    func testAutomaticCardsAreClosedInformationalAndNeverAlert() throws {
        let f = SessionFixture(); try f.ready()
        let inbox = ApprovalInbox(); var alerts = 0
        inbox.onNew = { _ in alerts += 1 }
        XCTAssertEqual(f.chats.filter { $0.op == "open" }.count, 1)
        try f.chat("opened", sequence: 0)
        try f.chat("message", sequence: 1, part: automatic)
        try f.chat("message", sequence: 1, part: automatic)
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertEqual(inbox.activities.count, 1)
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertTrue(inbox.entries.isEmpty)
        XCTAssertTrue(f.client.approvals.isEmpty)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertEqual(alerts, 0)
        var replacement = automatic; replacement.state = "closed"; replacement.rule_id = nil
        try f.chat("message", sequence: 2, part: replacement)
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertTrue(inbox.activities.isEmpty)
        XCTAssertEqual(alerts, 0)
    }

    func testChatFencesRouteGenerationConversationSequenceAndRefresh() throws {
        let f = SessionFixture(); try f.ready()
        try f.chat("opened", sequence: 0)
        try f.chat("message", sequence: 1, part: automatic, conversation: "stale-conversation")
        try f.chat("message", sequence: 1, part: automatic, process: "99999999-9999-4999-8999-999999999999")
        try f.chat("message", sequence: 1, part: automatic, route: RemoteTerminalConnection(clientId: "host", connectionId: "old-socket"))
        XCTAssertTrue(f.client.approvalActivities.isEmpty)
        try f.chat("message", sequence: 2, part: automatic)
        try f.chat("message", sequence: 1, part: automatic)
        XCTAssertTrue(f.client.approvalActivities.isEmpty)
        let old = try XCTUnwrap(f.chats.last(where: { $0.op == "open" })?.conversationId)
        f.client.refresh(); try f.snapshot(sequence: 2)
        XCTAssertEqual(f.chats.filter { $0.op == "open" }.count, 2)
        try f.chat("opened", sequence: 0)
        try f.chat("message", sequence: 1, part: automatic, conversation: old)
        XCTAssertTrue(f.client.approvalActivities.isEmpty)
        try f.chat("message", sequence: 1, part: automatic)
        XCTAssertEqual(f.client.approvalActivities.count, 1)
        f.source = nil
        XCTAssertTrue(f.client.approvalActivities.isEmpty)
        f.client.tick()
        XCTAssertTrue(f.client.approvalRules.isEmpty)
    }

    func testMalformedAutoAllowedPartNeverAppears() throws {
        var part = automatic
        XCTAssertTrue(part.isValid)
        part.rule_id = nil
        XCTAssertFalse(part.isValid)
        let f = SessionFixture(); try f.ready(); try f.chat("opened", sequence: 0)
        try f.chat("message", sequence: 1, part: part)
        XCTAssertTrue(f.client.approvalActivities.isEmpty)
    }

    func testMultipleSessionsKeepRulesAndMutationsSeparateAndObservationNeverTakesControl() throws {
        let f = SessionFixture(); try f.ready()
        let secondID = "ses-bbbbbbbbbbbb"
        let secondProcess = "99999999-9999-4999-8999-999999999999"
        try f.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(provider: "codex"),
            SessionFixture.descriptor(session: secondID, process: secondProcess)])
        let opens = f.chats.filter { $0.op == "open" }
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(Set(opens.map(\.agentId)), [sessionID, secondID])
        XCTAssertTrue(opens.allSatisfy { $0.binding?.lease_epoch == nil })
        XCTAssertFalse(f.sent.contains { $0.op == "acquire" || $0.op == "submit" })
        try f.rules([rule])
        let request = try f.approval(rules: [rule])
        XCTAssertNotNil(f.client.answerApproval(request, decision: .allowAlways, ruleID: rule.rule_id))
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.map { $0.binding?.target.session_id }, [sessionID])
        XCTAssertNil(f.client.approvalRules[secondID])
        let otherTarget = AtemSessionTarget(account_id: f.target.account_id, atem_device_id: f.target.atem_device_id,
            host_trust_gen: f.target.host_trust_gen, session_id: secondID, process_gen: secondProcess)
        XCTAssertNil(f.client.revokeRule(rule, target: otherTarget))
        XCTAssertFalse(f.client.controls(otherTarget))
    }
}

final class AtemApprovalTests: XCTestCase {
    private let id = "88888888-8888-4888-8888-888888888888"
    private let rule = AtemApprovalRule(rule_id: "r-npm-test", label: "Bash(npm test:*)", scope: "this project")

    func testInAppPreferenceWorksWithoutAPNsAndPreservesExistingPushOptIn() throws {
        let suite = "ApprovalNotificationsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentApprovalNotificationsEnabled")
        var registrations = 0
        let notifications = ApprovalNotifications(defaults: defaults, platform: nil,
            register: { _ in registrations += 1 }, unregister: { _ in }, open: { _ in })
        XCTAssertTrue(notifications.inAppEnabled)
        XCTAssertFalse(notifications.supportsPush)
        XCTAssertFalse(notifications.pushEnabled)
        notifications.setPushEnabled(true)
        notifications.setInAppEnabled(false)
        XCTAssertTrue(defaults.bool(forKey: "agentApprovalNotificationsEnabled"))
        notifications.setInAppEnabled(true)
        XCTAssertTrue(notifications.inAppEnabled)
        XCTAssertEqual(registrations, 0)
        let reloaded = ApprovalNotifications(defaults: defaults, platform: .apnsSandbox,
            register: { _ in }, unregister: { _ in }, open: { _ in })
        XCTAssertTrue(reloaded.pushEnabled)
        XCTAssertTrue(reloaded.inAppEnabled)
    }

    func testApprovalArrivesAndCanBeAnsweredWithoutAnyLease() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval()
        XCTAssertTrue(f.client.canAnswer(request))
        XCTAssertFalse(f.client.controls(f.target))
        let answer = try XCTUnwrap(f.client.answerApproval(request, decision: .allowOnce))
        let wire = try XCTUnwrap(f.sent.last)
        XCTAssertEqual(wire.kind, "approval")
        XCTAssertEqual(wire.binding?.target, f.target)
        XCTAssertNil(wire.binding?.lease_epoch)
        XCTAssertEqual(wire.payload?["acquire"], nil)
        XCTAssertEqual(f.disk.state.requests.last?.requestId, answer)
        XCTAssertEqual(f.disk.state.requests.last?.approvalID, id)
        XCTAssertFalse(f.sent.contains { $0.op == "acquire" })
        XCTAssertNil(f.client.answerApproval(request, decision: .deny))
        let saved = String(decoding: try JSONEncoder().encode(f.disk.state), as: UTF8.self)
        XCTAssertFalse(saved.contains("npm test"))
        XCTAssertFalse(saved.contains("allow_once"))
    }

    func testDuplicateCatchupUpdatesOneCardAndNeverRepeatsAnAlert() throws {
        let f = SessionFixture(); try f.ready()
        let inbox = ApprovalInbox()
        var alerts = 0; inbox.onNew = { _ in alerts += 1 }
        let request = try f.approval()
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        _ = try f.approval()
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertEqual(inbox.entries.count, 1)
        XCTAssertEqual(inbox.pendingCount, 1)
        XCTAssertEqual(alerts, 1)
        try f.closeApproval(request.approval_id)
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        _ = try f.approval()
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.entries.first?.resolution, "answered_terminal")
        XCTAssertFalse(inbox.entries.first?.canAnswer ?? true)
        XCTAssertEqual(alerts, 1)
    }

    func testResolvedBeforeOpenAndViewOnlyAndWrongProcessNeverCreateActionableRequests() throws {
        let closed = SessionFixture(); try closed.ready()
        try closed.closeApproval(id)
        _ = try closed.approval()
        XCTAssertTrue(closed.client.approvals.isEmpty)
        let viewer = SessionFixture(); try viewer.handshake(permissions: ["view"]); try viewer.snapshot()
        _ = try viewer.approval()
        XCTAssertTrue(viewer.client.approvals.isEmpty)
        let stale = SessionFixture(); try stale.ready()
        _ = try stale.approval(process: "99999999-9999-4999-8999-999999999999")
        XCTAssertTrue(stale.client.approvals.isEmpty)
    }

    func testDisconnectImmediatelyFencesAnswersAndReconnectNeedsFreshCatchup() throws {
        let f = SessionFixture(); try f.ready()
        _ = try f.approval()
        let inbox = ApprovalInbox(); var alerts = 0
        inbox.onNew = { _ in alerts += 1 }
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        let entry = try XCTUnwrap(inbox.entries.first)
        f.source = nil
        XCTAssertNil(inbox.answer(entry, decision: .allowOnce))
        f.client.tick()
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertFalse(try XCTUnwrap(inbox.entries.first).available)
        XCTAssertNil(inbox.entries.first?.resolution)
        f.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "socket-2"),
            account: "account-a", device: "host-a", pairingSession: "pairing-1")
        f.client.connectionChanged()
        try f.handshake(); try f.snapshot()
        XCTAssertNil(inbox.answer(entry, decision: .allowOnce))
        _ = try f.approval()
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertTrue(try XCTUnwrap(inbox.entries.first).canAnswer)
        XCTAssertEqual(alerts, 1)
    }

    func testApprovalDeliveryUncertaintyOnlyQueriesReceiptsAfterReconnect() throws {
        let disk = SessionDisk()
        let first = SessionFixture(disk: disk); try first.ready()
        let request = try first.approval()
        first.canSend = false
        XCTAssertNotNil(first.client.answerApproval(request, decision: .deny, message: "Please use a different command"))
        XCTAssertFalse(first.client.canAnswer(request))
        let second = SessionFixture(disk: disk); try second.ready()
        _ = try second.approval()
        XCTAssertTrue(second.sent.contains { $0.op == "receipt_query" })
        XCTAssertFalse(second.sent.contains { $0.op == "submit" || $0.op == "acquire" })
        XCTAssertFalse(second.client.canAnswer(request))
    }

    func testAlwaysAllowMustUseTheExactOfferedRuleForClaudeAndCodex() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval(rules: [rule])
        XCTAssertNil(f.client.answerApproval(request, decision: .allowAlways, ruleID: "other-rule"))
        XCTAssertNotNil(f.client.answerApproval(request, decision: .allowAlways, ruleID: rule.rule_id))
        XCTAssertEqual(f.sent.last?.payload?["rule_id"], .string(rule.rule_id))
        let codex = SessionFixture(); try codex.ready()
        try codex.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(provider: "codex")])
        let sessionRule = AtemApprovalRule(rule_id: "s-0123456789abcdef", label: "Always allow npm test in /project", scope: "session")
        let codexRequest = try codex.approval(rules: [sessionRule])
        XCTAssertNil(codex.client.answerApproval(codexRequest, decision: .allowAlways, ruleID: rule.rule_id))
        XCTAssertNotNil(codex.client.answerApproval(codexRequest, decision: .allowAlways, ruleID: sessionRule.rule_id))
        XCTAssertEqual(codex.sent.last?.payload, AtemApprovalAnswer(approvalID: codexRequest.approval_id,
            decision: .allowAlways, ruleID: sessionRule.rule_id).payload)
        XCTAssertNil(codex.sent.last?.binding?.lease_epoch)
        XCTAssertFalse(codex.sent.contains { $0.op == "acquire" })
    }

    func testApprovalSubmissionFailsClosedWhenJournalCannotCommit() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval()
        let count = f.sent.count
        f.disk.fail = true
        XCTAssertNil(f.client.answerApproval(request, decision: .allowOnce))
        XCTAssertEqual(f.sent.count, count)
    }

    func testLeaseFreeAnswerNeverAdoptsAnUnsolicitedGrant() throws {
        let f = SessionFixture(); try f.ready()
        var grant = AtemSessionMessage(op: "lease_changed")
        grant.session_id = sessionID; grant.process_gen = processID; grant.lease_epoch = 1
        grant.reason = "granted"; grant.controller = AtemSessionController(controller_session: controllerID, lease_epoch: 1)
        try f.receive(grant)
        XCTAssertFalse(f.client.controls(f.target))
        let request = try f.approval()
        XCTAssertNotNil(f.client.answerApproval(request, decision: .allowOnce))
        try f.receive(grant)
        XCTAssertFalse(f.client.controls(f.target))
        f.time = 5; f.client.tick()
        XCTAssertFalse(f.sent.contains { $0.op == "renew" })
        grant.controller = nil; grant.reason = "local_input"
        try f.receive(grant)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertEqual(f.client.approvals[id], request)
    }

    func testWireRejectsUnknownDecisionFieldsUnsafeTextAndInvalidAcquireBinding() throws {
        var message = AtemSessionMessage(op: "submit")
        let f = SessionFixture()
        message.binding = AtemSessionBinding(target: f.target, attachment_gen: attachmentID)
        message.request_id = UUID().uuidString.lowercased(); message.kind = "approval"
        message.payload = AtemApprovalAnswer(approvalID: id, decision: .allowOnce).payload
        XCTAssertNoThrow(try message.validate())
        message.binding?.lease_epoch = 1
        XCTAssertNoThrow(try message.validate(), "r8 ignores an approval answer lease epoch")
        message.binding?.lease_epoch = nil
        message.payload = .object(["approval_id": .string(id), "decision": .string("allow_once"), "acquire": .bool(true), "rule": .string("anything")])
        XCTAssertThrowsError(try message.validate())
        XCTAssertThrowsError(try AtemApprovalAnswer.validate(AtemApprovalAnswer(approvalID: id, decision: .deny, message: "hidden\u{1b}command").payload))
        XCTAssertFalse(AtemApprovalRequest.text("line\nsecond", minimum: 0, maximum: 512))
        XCTAssertFalse(AtemApprovalRequest.text("hidden\u{85}command", minimum: 0, maximum: 512))
        XCTAssertFalse(AtemApprovalRequest.text(String(repeating: "a", count: 513), minimum: 0, maximum: 512))
    }

    func testUnknownOutcomeCannotEnableAnotherAnswerOrReplay() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval()
        let requestID = try XCTUnwrap(f.client.answerApproval(request, decision: .allowOnce))
        for (index, state) in [AtemReceiptState.accepted, .executing, .outcome_unknown].enumerated() {
            var receipt = AtemSessionMessage(op: "receipt")
            receipt.request_id = requestID; receipt.target = f.target; receipt.kind = "approval"
            receipt.state = state; receipt.updated_at = UInt64(index + 1)
            try f.receive(receipt)
        }
        XCTAssertFalse(f.client.canAnswer(request))
        XCTAssertNil(f.client.answerApproval(request, decision: .deny))
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        let loaded = AtemSessionJournal(load: { f.disk.state })
        XCTAssertFalse(loaded.loadFailed)
        XCTAssertEqual(loaded.snapshot.requests.first?.receipt?.state, .outcome_unknown)
    }

    func testLocalInputAndExpiredApprovalGrantCannotRestoreControl() throws {
        for expired in [false, true] {
            let f = SessionFixture(); try f.ready()
            let request = try f.approval()
            XCTAssertNotNil(f.client.answerApproval(request, decision: .allowOnce))
            var grant = AtemSessionMessage(op: "lease_changed")
            grant.session_id = sessionID; grant.process_gen = processID; grant.lease_epoch = 1
            grant.reason = "granted"; grant.controller = AtemSessionController(controller_session: controllerID, lease_epoch: 1)
            if expired { f.time = 15 }
            else {
                var local = grant; local.controller = nil; local.reason = "local_input"
                try f.receive(local)
            }
            try f.receive(grant)
            XCTAssertFalse(f.client.controls(f.target))
            XCTAssertEqual(f.client.approvals[id], request)
        }
    }

    func testPendingProcessEndsAndAuthoritativeResolutionUpdatesTheInbox() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval()
        let inbox = ApprovalInbox(); inbox.onNew = { _ in }
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        try f.closeApproval(id, reason: "process_ended")
        inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        XCTAssertEqual(inbox.entries.first?.status, "The agent session ended.")
        XCTAssertFalse(f.client.canAnswer(request))
        XCTAssertEqual(inbox.pendingCount, 0)
    }

    func testApprovalCreationTimeRejectsNonIntegerAndUnsafeWireRepresentations() throws {
        let f = SessionFixture(); try f.ready()
        let request = try f.approval()
        var message = AtemSessionMessage(op: "approval_request")
        message.approval_id = request.approval_id; message.session_id = request.session_id; message.process_gen = request.process_gen
        message.tool = request.tool; message.summary = request.summary; message.created_at = request.created_at; message.always_rules = []
        let wire = String(decoding: try JSONEncoder().encode(AstationMessage.session(message)), as: UTF8.self)
        for number in ["1.0", "1e0", "-1", "9007199254740992"] {
            let malformed = wire.replacingOccurrences(of: "\"created_at\":1760500000000", with: "\"created_at\":\(number)")
            XCTAssertNotEqual(wire, malformed)
            XCTAssertThrowsError(try AstationMessage.decodePacket(Data(malformed.utf8)))
        }
    }
}

final class AtemSessionWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/atem-session-v1"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testPinnedR8FixturesMatchPublishedCommit() throws {
        let source = try fixture("source")
        XCTAssertEqual(source["revision"] as? String, "r8")
        XCTAssertEqual(source["commit"] as? String, "4f87bab1289848cb6a0da5707d2e7830eb5c057d")
        let hashes = try XCTUnwrap(source["sha256"] as? [String: String])
        XCTAssertNotNil(hashes["second-hello-replaces-the-attachment.json"])
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "atem-session-v1", withExtension: nil, subdirectory: "Fixtures"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "source.json" }
        XCTAssertEqual(Set(hashes.keys), Set(files))
        for (name, expected) in hashes {
            let digest = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected, name)
        }
    }

    func testSecondHelloHostFixtureRequestsDecodeWithUUIDCapture() throws {
        let scenario = try fixture("second-hello-replaces-the-attachment")
        let replacement = "77777777-7777-4777-8777-777777777777"
        let steps = try XCTUnwrap(scenario["steps"] as? [[String: Any]])
        var operations: [String] = []
        for step in steps where step["send"] != nil {
            let object = try XCTUnwrap(step["json"])
            let unresolved = try JSONSerialization.data(withJSONObject: object)
            let raw = try XCTUnwrap(String(data: unresolved, encoding: .utf8))
            // Captures are real protocol values, never literal placeholder strings.
            if raw.contains("${gen2}") { XCTAssertThrowsError(try AstationMessage.decodePacket(unresolved)) }
            let resolved = Data(raw.replacingOccurrences(of: "${gen2}", with: replacement).utf8)
            guard case .session(let message) = try AstationMessage.decodePacket(resolved) else { return XCTFail("Expected session message") }
            operations.append(message.op)
            if message.op == "renew" { XCTAssertEqual(message.binding?.attachment_gen, attachmentID) }
            if ["receipt_query", "acquire"].contains(message.op) {
                XCTAssertEqual(message.binding?.attachment_gen, replacement)
                XCTAssertNil(message.binding?.lease_epoch)
            }
            guard case .session(let roundTrip) = try AstationMessage.decodePacket(JSONEncoder().encode(AstationMessage.session(message))) else {
                return XCTFail("Expected round trip")
            }
            XCTAssertEqual(roundTrip, message)
        }
        XCTAssertEqual(operations, ["submit", "hello", "renew", "receipt_query", "acquire", "hello"])
    }

    func testSharedDigestAndRawRejectionVectorsUseActualParser() throws {
        let file = try fixture("digest-vectors")
        for vector in try XCTUnwrap(file["vectors"] as? [[String: Any]]) {
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["payload"]))
            let payload = try AtemSessionJSON.parse(data)
            XCTAssertEqual(try payload.canonical(), vector["canonical"] as? String, vector["name"] as? String ?? "")
            XCTAssertEqual(try payload.digest(), vector["sha256"] as? String)
        }
        for vector in try XCTUnwrap(file["must_reject"] as? [[String: Any]]) {
            let data: Data
            if let raw = vector["payload_json"] as? String { data = Data(raw.utf8) }
            else {
                let hex = try XCTUnwrap(vector["payload_hex"] as? String)
                data = Data(stride(from: 0, to: hex.count, by: 2).map {
                    let start = hex.index(hex.startIndex, offsetBy: $0)
                    return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
                })
            }
            XCTAssertThrowsError(try AtemSessionJSON.parse(data), vector["name"] as? String ?? "")
        }
    }

    func testCanonicalizationPreservesDistinctUnicodeKeySpellings() throws {
        let payload = try AtemSessionJSON.parse(Data(#"{"\u00e9":1,"e\u0301":2}"#.utf8))
        XCTAssertEqual(try payload.canonical(), "{\"e\u{301}\":2,\"\u{e9}\":1}")
        let packet = Data(#"{"type":"session","data":{"v":1,"op":"hello","revision":8,"id":"11111111-1111-4111-8111-000000000001","payload":{"\u00e9":1,"e\u0301":2}}}"#.utf8)
        guard case .session(let decoded) = try AstationMessage.decodePacket(packet) else { return XCTFail("session") }
        XCTAssertEqual(try decoded.payload?.canonical(), try payload.canonical())
        XCTAssertThrowsError(try AtemSessionJSON.parse(Data(#"{"a":1,"\u0061":2}"#.utf8)))
    }

    func testDuplicateEnvelopeFieldsAndUnsafeKnownCountersAreRejectedBeforeRoundTrip() throws {
        for raw in [
            #"{"type":"session","data":{"v":1,"op":"list","id":"11111111-1111-4111-8111-000000000001","v":1}}"#,
            #"{"atem_id":"host-a","payload":{"type":"session","data":{"v":1e0,"op":"list","id":"11111111-1111-4111-8111-000000000001"}}}"#,
            #"{"type":"session","data":{"v":1,"op":"list","id":"11111111-1111-4111-8111-000000000001","seq":9007199254740992}}"#,
            #"{"payload":{"type":"session","data":{"v":1,"op":"list","id":"11111111-1111-4111-8111-000000000001"}},"payload":{}}"#
        ] { XCTAssertThrowsError(try AtemSessionJSON.validatePacket(Data(raw.utf8))) }
        let unknown = Data(#"{"type":"session","data":{"v":1,"op":"list","id":"11111111-1111-4111-8111-000000000001","future":{"fraction":1.5}}}"#.utf8)
        XCTAssertNoThrow(try AstationMessage.decodePacket(unknown), "Unknown fields remain ignorable")
    }

    func testDescriptorRequiresEveryFieldIncludingExplicitNullController() throws {
        let valid = try SessionFixture.descriptor()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var complete = raw
        complete["controller"] = NSNull()
        for key in complete.keys {
            var missing = complete
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(AtemSessionDescriptor.self, from: JSONSerialization.data(withJSONObject: missing)), key)
        }
    }

    func testSessionAndNestedRelayPromptsAreRedacted() {
        for raw in [
            #"{"type":"session","data":{"op":"submit","payload":{"text":"private-prompt"}}}"#,
            #"{"payload":{"type":"session","data":{"op":"submit","payload":{"text":"private-prompt"}}}}"#,
            #"{"type":"session","data":{"payload":{"text":"private-truncated"#
        ] {
            let text = NetworkDebugLogger.sanitizedPayload(raw)
            XCTAssertFalse(text.contains("private"))
            XCTAssertTrue(text.contains("redacted"))
        }
    }

    func testBoundTerminalMutationsOmitLegacyLeaseAndKeepExactTarget() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let binding = try XCTUnwrap(f.client.binding(for: f.target, mutation: true))
        let stream = RemoteTerminalStream(terminalId: sessionID, generation: processID, streamId: "stream")
        let message = RemoteTerminalMessage.bound(.input(stream, leaseId: "", sequence: 0, bytes: "aGkN"), binding)
        let bytes = try JSONEncoder().encode(AstationMessage.terminal(message))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertNil(data["lease_id"])
        XCTAssertEqual((data["binding"] as? [String: Any])?["lease_epoch"] as? Int, 1)
        guard case .terminal(let decoded) = try AstationMessage.decodePacket(bytes) else { return XCTFail("terminal") }
        XCTAssertEqual(decoded, message)
        let wrong = RemoteTerminalStream(terminalId: "ses-bbbbbbbbbbbb", generation: processID, streamId: "stream")
        XCTAssertThrowsError(try JSONEncoder().encode(AstationMessage.terminal(.bound(.input(wrong, leaseId: "", sequence: 0, bytes: "YQ=="), binding))))
        XCTAssertThrowsError(try JSONEncoder().encode(AstationMessage.terminal(.bound(.input(stream, leaseId: "", sequence: AtemSessionWire.maximumCounter + 1, bytes: "YQ=="), binding))))
    }

    func testR62ErrorsKeepFamilyCodesAndAllowUncorrelatedSessionRefusals() throws {
        let raw = #"{"type":"session","data":{"v":1,"op":"error","id":"11111111-1111-4111-8111-000000000001","code":"unsupported_version"}}"#
        guard case .session(let refusal) = try AstationMessage.decodePacket(Data(raw.utf8)) else { return XCTFail("session") }
        XCTAssertNil(refusal.re)
        XCTAssertEqual(refusal.code, "unsupported_version")
        let f = SessionFixture()
        f.client.start()
        try f.receive(refusal)
        XCTAssertEqual(f.client.phase, .failed)
        XCTAssertTrue(f.client.status.contains("Upgrade Atem"))

        let terminal = #"{"type":"terminal","data":{"v":1,"op":"error","terminal_id":"ses-aaaaaaaaaaaa","stream_id":"old-stream","code":"stale_lease","message":"Control lease is stale"}}"#
        guard case .terminal(.error(let id, let stream, let code, let message)) = try AstationMessage.decodePacket(Data(terminal.utf8)) else { return XCTFail("terminal error") }
        XCTAssertEqual(id, sessionID); XCTAssertEqual(stream, "old-stream")
        XCTAssertEqual(code, "stale_lease"); XCTAssertEqual(message, "Control lease is stale")
        let chat = #"{"type":"agentChat","data":{"v":1,"op":"error","conversationId":"conv-1","agentId":"ses-aaaaaaaaaaaa","requestId":"44444444-4444-4444-8444-000000000001","code":"outcome_unknown","text":"Write interrupted"}}"#
        guard case .agentChat(let event) = try AstationMessage.decodePacket(Data(chat.utf8)) else { return XCTFail("chat error") }
        XCTAssertEqual(event.code, "outcome_unknown")
        XCTAssertEqual(event.requestId, "44444444-4444-4444-8444-000000000001")
        XCTAssertEqual(event.text, "Write interrupted")
        for packet in [terminal] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any])
            var data = try XCTUnwrap(object["data"] as? [String: Any]); data.removeValue(forKey: "code"); object["data"] = data
            XCTAssertThrowsError(try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)))
        }
        let notice = AgentChatWire(op: "error", conversationId: "conv-1", agentId: sessionID, text: "the conversation was switched; reopen the chat")
        XCTAssertNoThrow(try AstationMessage.decodePacket(JSONEncoder().encode(AstationMessage.agentChat(notice))))
    }

    func testEverySharedClientScenarioUsesRealWireMessages() throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "atem-session-v1", withExtension: nil, subdirectory: "Fixtures"))
        var scenarios = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
            let scenario = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            guard scenario["side"] as? String == "client" else { continue }
            scenarios += 1
            let f = SessionFixture()
            let setup = try XCTUnwrap(scenario["setup"] as? [String: Any])
            let clients = try XCTUnwrap(setup["clients"] as? [[String: Any]])
            let steps = try XCTUnwrap(scenario["steps"] as? [[String: Any]])
            let explicitHello = steps.contains { ($0["json"] as? [String: Any])?["data"].flatMap { $0 as? [String: Any] }?["op"] as? String == "hello" && $0["send"] != nil }
            if !explicitHello {
                try f.handshake(permissions: XCTUnwrap(clients.first?["permissions"] as? [String]))
                if let sessions = setup["sessions"] as? [[String: Any]], !sessions.isEmpty { try f.snapshot() }
            }
            var conversations: [String: String] = [:]
            var sentBaseline = f.sent.count
            var chatBaseline = f.chats.count
            for (index, step) in steps.enumerated() {
                let location = "\(url.lastPathComponent) step \(index)"
                if let advance = step["advance_ms"] as? Double { f.time += advance / 1000 }
                else if step["send"] != nil {
                    let object = try XCTUnwrap(step["json"] as? [String: Any])
                    guard case .session(let message) = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)) else { return XCTFail(location) }
                    f.nextID = message.id
                    switch message.op {
                    case "hello":
                        if f.sent.isEmpty { f.client.start() }
                        else {
                            // Production reconnects the authenticated transport
                            // before replacing the attachment; no authority resumes.
                            let old = try XCTUnwrap(f.source)
                            f.source = AtemSessionContext(route: old.route, account: old.account, device: old.device,
                                pairingSession: old.pairingSession, transportGeneration: "fixture-\(index)")
                            f.client.connectionChanged()
                        }
                    case "list":
                        // Welcome sends list automatically. Correlation ids are
                        // opaque; subsequent fixture replies use the actual id.
                        f.nextID = nil
                    case "acquire": f.client.acquire(f.target, takeover: message.takeover ?? false)
                    case "renew": f.client.renew(f.target)
                    case "submit":
                        XCTAssertNotNil(f.client.submit(f.target, kind: try XCTUnwrap(message.kind), text: message.payload?["text"]?.string,
                            requestID: try XCTUnwrap(message.request_id), takeover: message.expected_controller), location)
                    default: return XCTFail("Unexpected client op: " + location)
                    }
                    let actual = try XCTUnwrap(f.sent.last(where: { $0.op == message.op }), location)
                    if message.op != "list" { XCTAssertEqual(actual.id, message.id, location) }
                    XCTAssertEqual(actual.revision, message.revision, location)
                    if message.op == "submit" {
                        XCTAssertEqual(actual.binding, message.binding, location)
                        XCTAssertEqual(actual.acquire, message.acquire, location)
                        XCTAssertEqual(actual.payload, message.payload, location)
                    }
                    sentBaseline = f.sent.count; chatBaseline = f.chats.count
                } else if step["client_open_chat"] != nil {
                    if f.client.registry.isEmpty { try f.snapshot() }
                    let fixtureID = try XCTUnwrap(step["conversation"] as? String)
                    conversations[fixtureID] = try XCTUnwrap(f.client.chatSnapshot(f.target)?.chat_id)
                    XCTAssertEqual(f.chats.last?.op, "open", location)
                    XCTAssertNil(f.chats.last?.generation, location)
                    XCTAssertNil(f.chats.last?.before, location)
                    sentBaseline = f.sent.count; chatBaseline = f.chats.count
                } else if step["client_try"] != nil {
                    let object = try XCTUnwrap(step["json"] as? [String: Any])
                    guard case .agentChat(let message) = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)) else { return XCTFail(location) }
                    sentBaseline = f.sent.count; chatBaseline = f.chats.count
                    XCTAssertNil(f.client.chatHistory(f.target, before: message.before, next: message.next, turn: message.turn_id,
                        request: message.request_id), location)
                } else if step["deliver_to_client"] != nil {
                    let object = try XCTUnwrap(step["json"] as? [String: Any])
                    let packet = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object))
                    switch packet {
                    case .session(var message):
                        if message.op == "welcome" {
                            if f.client.phase == .ready {
                                let old = try XCTUnwrap(f.source)
                                f.source = AtemSessionContext(route: old.route, account: old.account, device: old.device,
                                    pairingSession: old.pairingSession, transportGeneration: "welcome-\(index)")
                                f.client.connectionChanged()
                            }
                            message.re = try XCTUnwrap(f.sent.last(where: { $0.op == "hello" })).id
                        }
                        try f.receive(message)
                    case .agentChat(var message):
                        message.conversationId = conversations[message.conversationId] ?? message.conversationId
                        f.client.receiveChat(message, from: f.route)
                    default: return XCTFail("Unexpected fixture family: " + location)
                    }
                } else if let expected = step["assert_client"] as? [String: Any] {
                    let supported: Set<String> = ["controls", "input_enabled", "deadline_ms", "registry", "registry_state", "runtime_epoch", "seq", "sent_list",
                        "admitted", "revision", "features_enabled", "lookup_enabled", "coverage_enabled", "chat_enabled", "sent",
                        "chat_truncated", "chat_reopens", "chat_loaded", "chat_messages"]
                    XCTAssertTrue(Set(expected.keys).isSubset(of: supported), location)
                    if let controls = expected["controls"] as? Bool { XCTAssertEqual(f.client.controls(f.target), controls, location) }
                    if let input = expected["input_enabled"] as? Bool { XCTAssertEqual(f.client.binding(for: f.target, mutation: true) != nil, input, location) }
                    if let deadline = expected["deadline_ms"] as? Double { XCTAssertEqual(try XCTUnwrap(f.client.controlDeadline(for: f.target)) * 1000, deadline, accuracy: 0.001, location) }
                    if let ids = expected["registry"] as? [String] { XCTAssertEqual(f.client.registry.keys.sorted(), ids.sorted(), location) }
                    if let epoch = expected["runtime_epoch"] as? UInt64 { XCTAssertEqual(f.client.runtimeEpoch, epoch, location) }
                    if let seq = expected["seq"] as? UInt64 { XCTAssertEqual(f.client.sequence, seq, location) }
                    if let listed = expected["sent_list"] as? Bool {
                        if listed { XCTAssertGreaterThan(f.sent.filter { $0.op == "list" }.count, 1, location) }
                        else { XCTAssertFalse(f.sent.contains { $0.op == "list" }, location) }
                    }
                    if let admitted = expected["admitted"] as? Bool { XCTAssertEqual(f.client.phase == .ready, admitted, location) }
                    if let revision = expected["revision"] as? UInt64 { XCTAssertEqual(f.client.welcome?.revision, revision, location) }
                    else if expected["revision"] is NSNull { XCTAssertNil(f.client.welcome?.revision, location) }
                    if let features = expected["features_enabled"] as? [String] { XCTAssertEqual(f.client.features, Set(features), location) }
                    for (key, feature) in [("lookup_enabled", "chat.lookup"), ("coverage_enabled", "chat.coverage"), ("chat_enabled", "chat.history_end")] {
                        if let enabled = expected[key] as? Bool { XCTAssertEqual(f.client.features.contains(feature), enabled, location) }
                    }
                    if let states = expected["registry_state"] as? [String: String] {
                        for (id, state) in states { XCTAssertEqual(f.client.registry[id]?.state, state, location) }
                    }
                    let chat = f.client.chatSnapshot(f.target)
                    if let truncated = expected["chat_truncated"] as? Bool { XCTAssertEqual(chat?.truncated, truncated, location) }
                    if let loaded = expected["chat_loaded"] as? Bool { XCTAssertEqual(chat?.loaded, loaded, location) }
                    if let reopens = expected["chat_reopens"] as? Int { XCTAssertEqual(chat?.reopens, reopens, location) }
                    if let ids = expected["chat_messages"] as? [String] { XCTAssertEqual(chat?.messages.compactMap(\.messageId), ids, location) }
                    if let sent = expected["sent"] as? [Any] {
                        XCTAssertTrue(sent.isEmpty, "Add matcher before accepting non-empty sent assertions")
                        XCTAssertEqual(f.sent.count, sentBaseline, location)
                        XCTAssertEqual(f.chats.count, chatBaseline, location)
                    }
                    sentBaseline = f.sent.count; chatBaseline = f.chats.count
                } else { XCTFail("Unhandled fixture step: " + location) }
            }
        }
        XCTAssertEqual(scenarios, 7, "Every pinned r8 client-side scenario must execute")
    }

}

final class AtemSessionClientTests: XCTestCase {
    func testR71ClientReplacementOnSameTransportFencesAuthorityAndQueriesDurableReceipt() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "run the tests",
            requestID: "44444444-4444-4444-8444-444444444444"))
        try f.receipt(request, state: .accepted)
        try f.receipt(request, state: .executing, time: 101)
        f.client.renew(f.target)
        let oldRenewal = try XCTUnwrap(f.sent.last)
        let source = try XCTUnwrap(f.source)
        let oldClient = f.client
        f.source = nil; oldClient.connectionChanged()
        XCTAssertFalse(oldClient.controls(f.target))
        f.source = source
        f.time = 2
        // A recreated client has lost attachment state but retains the protected
        // journal. r7.1 welcomes its second hello on this same authenticated link.
        f.client = f.makeClient()
        f.client.start()
        let hello = try XCTUnwrap(f.sent.last)
        XCTAssertEqual(hello.op, "hello")
        let replacement = "77777777-7777-4777-8777-777777777777"
        try f.handshake(attachment: replacement, controller: "99999999-9999-4999-8999-999999999999", remaining: 58_000)
        let query = try XCTUnwrap(f.sent.last(where: { $0.op == "receipt_query" }))
        XCTAssertEqual(query.request_ids, [request])
        XCTAssertEqual(query.binding?.attachment_gen, replacement)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertNil(f.client.submit(f.target, kind: "interrupt"))
        XCTAssertNil(f.client.sequence)
        XCTAssertTrue(f.client.registry.isEmpty)
        try f.snapshot()
        var stale = AtemSessionMessage(op: "error")
        stale.re = oldRenewal.id; stale.code = "stale_target"
        try f.receive(stale)
        try f.lease(replyTo: oldRenewal.id, epoch: 1)
        XCTAssertFalse(f.client.controls(f.target), "Neither an old refusal nor a delayed old grant restores authority")
        var result = AtemSessionMessage(op: "receipts")
        result.re = query.id
        result.receipts = [AtemSessionReceipt(request_id: request, target: f.target, kind: "prompt", state: .completed, detail: nil, updated_at: 102)]
        try f.receive(result)
        XCTAssertEqual(f.disk.state.requests.first?.receipt?.state, .completed)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        f.client.acquire(f.target, takeover: false)
        let acquire = try XCTUnwrap(f.sent.last)
        XCTAssertEqual(acquire.binding?.attachment_gen, replacement)
        XCTAssertNil(acquire.binding?.lease_epoch)
        var lease = AtemSessionMessage(op: "lease")
        lease.re = acquire.id; lease.binding = AtemSessionBinding(target: f.target, attachment_gen: replacement, lease_epoch: 3)
        lease.ms_left = 15_000
        try f.receive(lease)
        XCTAssertTrue(f.client.controls(f.target))
        XCTAssertEqual(f.client.binding(for: f.target, mutation: true)?.lease_epoch, 3)
        XCTAssertTrue(f.reconnects.isEmpty)
        XCTAssertEqual(f.source, source, "The replacement hello uses the same authenticated transport")
        f.time = 60; f.client.tick()
        XCTAssertEqual(f.client.phase, .failed, "Replacement preserves the host's original authorization deadline")
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testVerificationRetriesAnUnauthorizedInitialHelloOnceAndFencesItsOldReply() throws {
        for correlated in [false, true] {
            let f = SessionFixture(); f.client.start()
            let original = try XCTUnwrap(f.sent.last?.id)
            var refusal = AtemSessionMessage(op: "error")
            refusal.re = correlated ? original : nil
            refusal.code = "unauthorized"
            try f.receive(refusal)
            f.time = 9; f.client.tick()
            XCTAssertEqual(f.sent.count, 1)
            f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
            let retry = try XCTUnwrap(f.sent.last?.id)
            XCTAssertNotEqual(retry, original)
            XCTAssertEqual(f.sent.count, 2)
            XCTAssertEqual(f.sent.last?.revision, 8)
            XCTAssertTrue(f.reconnects.isEmpty)
            f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
            try f.handshake(helloID: original)
            XCTAssertNil(f.client.welcome)
            refusal.re = correlated ? retry : nil
            try f.receive(refusal)
            f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
            f.time = 30; f.client.tick()
            XCTAssertEqual(f.client.phase, .failed)
            XCTAssertEqual(f.sent.count, 2, "Duplicates and a refused retry never loop")
        }
        let f = SessionFixture(); f.client.start()
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.receive(refusal)
        f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
        try f.handshake(); try f.snapshot()
        XCTAssertTrue(f.client.hasRegistrySnapshot)
        f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
        XCTAssertEqual(f.sent.filter { $0.op == "hello" }.count, 2)
    }

    func testVerificationCompletionRacingTheInitialRefusalStillRetriesOnce() throws {
        for correlated in [false, true] {
            let f = SessionFixture(); f.client.start()
            let original = try XCTUnwrap(f.sent.last?.id)
            f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
            XCTAssertEqual(f.sent.count, 1, "Wait for the outstanding hello instead of replacing it")
            var refusal = AtemSessionMessage(op: "error")
            refusal.code = "unauthorized"; refusal.re = correlated ? original : nil
            try f.receive(refusal)
            XCTAssertEqual(f.sent.count, 2)
            try f.handshake(); try f.snapshot()
            XCTAssertTrue(f.client.hasRegistrySnapshot)
        }
    }

    func testVerificationCannotRetryAnotherContextOrAnUnrelatedFailure() throws {
        for code in ["unsupported_version", "busy", "forbidden", "paused"] {
            let f = SessionFixture(); f.client.start()
            var refusal = AtemSessionMessage(op: "error")
            refusal.code = code; refusal.re = f.sent.last?.id
            try f.receive(refusal)
            f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
            XCTAssertEqual(f.sent.count, 1, code)
        }
        let f = SessionFixture(); f.client.start()
        let original = try XCTUnwrap(f.source)
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.receive(refusal)
        for stale in [
            AtemSessionContext(route: original.route, account: "other", device: original.device, pairingSession: original.pairingSession),
            AtemSessionContext(route: original.route, account: original.account, device: "other", pairingSession: original.pairingSession),
            AtemSessionContext(route: original.route, account: original.account, device: original.device, pairingSession: "other"),
            AtemSessionContext(route: original.route, account: original.account, device: original.device,
                pairingSession: original.pairingSession, transportGeneration: "old-socket")
        ] { f.client.verificationDidComplete(context: stale) }
        XCTAssertEqual(f.sent.count, 1)
        f.source = nil
        f.client.verificationDidComplete(context: original)
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertTrue(f.reconnects.isEmpty)
    }

    func testVerificationAfterAWelcomeNeverReplacesTheAttachmentOrAcquiresControl() throws {
        let f = SessionFixture(); try f.ready(); try f.takeControl()
        let originalCount = f.sent.count
        f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
        XCTAssertEqual(f.sent.count, originalCount)
        XCTAssertTrue(f.client.controls(f.target))
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.receive(refusal)
        f.client.verificationDidComplete(context: try XCTUnwrap(f.source))
        XCTAssertEqual(f.sent.count, originalCount)
        XCTAssertEqual(f.client.phase, .reconnecting)
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testUnauthorizedHelloRetryReconnectsTransportAndFencesOldReply() throws {
        for correlated in [false, true] {
            let f = SessionFixture(); f.client.start()
            let first = try XCTUnwrap(f.sent.last?.id)
            var refusal = AtemSessionMessage(op: "error")
            refusal.re = correlated ? first : nil
            refusal.code = "unauthorized"
            try f.receive(refusal)
            XCTAssertTrue(f.client.connectionStatus.canReconnect)
            XCTAssertFalse(f.client.status.contains("Complete verification"))
            f.time = 9; f.client.tick()
            XCTAssertEqual(f.sent.count, 1, "Discovery never retries on a timer")
            XCTAssertTrue(f.reconnects.isEmpty)
            f.client.refresh()
            f.client.refresh()
            XCTAssertEqual(f.reconnects, [f.source!], "Repeated clicks coalesce while reconnecting")
            XCTAssertEqual(f.sent.count, 1, "Never send a second hello on the old socket")
            try f.handshake(helloID: first)
            XCTAssertEqual(f.client.phase, .reconnecting)
            f.source = AtemSessionContext(route: f.route, account: "account-a", device: "host-a",
                pairingSession: "pairing-1", transportGeneration: "fresh-mac-socket")
            f.client.connectionChanged()
            XCTAssertEqual(f.sent.count, 2)
            XCTAssertNotEqual(f.sent.last?.id, first)
            try f.handshake(); try f.snapshot(); try f.takeControl()
            refusal.re = nil
            try f.receive(refusal)
            XCTAssertEqual(f.client.phase, .reconnecting)
            XCTAssertEqual(f.reconnects.count, 2)
            XCTAssertFalse(f.client.status.contains("verification"))
            XCTAssertFalse(f.client.connectionStatus.canReconnect)
            let sent = f.sent.count
            f.client.refresh()
            XCTAssertEqual(f.sent.count, sent)
            XCTAssertFalse(f.client.controls(f.target))
        }
    }

    func testUnauthorizedHelloCannotRetryAfterAuthenticatedContextIsRevoked() throws {
        let f = SessionFixture(); f.client.start()
        var refusal = AtemSessionMessage(op: "error")
        refusal.code = "unauthorized"
        try f.receive(refusal)
        f.source = nil
        f.client.refresh()
        XCTAssertEqual(f.sent.count, 1)
        f.client.tick()
        XCTAssertEqual(f.client.phase, .offline)
        XCTAssertFalse(f.client.connectionStatus.canReconnect)
        XCTAssertTrue(f.reconnects.isEmpty)
    }

    func testContextRestorationOnSameSocketReconnectsWithoutReplayingRequestsOrControl() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "run once"))
        let original = try XCTUnwrap(f.source)
        f.source = nil; f.client.connectionChanged()
        XCTAssertFalse(f.client.controls(f.target))
        f.source = original; f.client.connectionChanged()
        XCTAssertEqual(f.client.phase, .reconnecting)
        XCTAssertEqual(f.reconnects, [original])
        XCTAssertEqual(f.sent.filter { $0.op == "hello" }.count, 1)
        try f.handshake()
        XCTAssertNil(f.client.welcome)
        f.source = AtemSessionContext(route: original.route, account: original.account, device: original.device,
            pairingSession: original.pairingSession, transportGeneration: "socket-2")
        f.client.connectionChanged()
        try f.handshake(attachment: "99999999-9999-4999-8999-999999999999"); try f.snapshot()
        XCTAssertEqual(f.sent.filter { $0.op == "hello" }.count, 2)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        XCTAssertEqual(f.sent.filter { $0.op == "acquire" }.count, 1)
        XCTAssertEqual(f.sent.last(where: { $0.op == "receipt_query" })?.request_ids, [request])
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testPostWelcomeUnauthorizedReplyReconnectsAndDropsControl() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        f.client.refresh()
        var refusal = AtemSessionMessage(op: "error")
        refusal.re = try XCTUnwrap(f.sent.last?.id); refusal.code = "unauthorized"
        try f.receive(refusal)
        XCTAssertEqual(f.client.phase, .reconnecting)
        XCTAssertEqual(f.reconnects.count, 1)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertTrue(f.client.registry.isEmpty)
        XCTAssertEqual(f.sent.filter { $0.op == "hello" }.count, 1)
        try f.receive(refusal)
        XCTAssertEqual(f.reconnects.count, 1)
    }

    func testViewOnlyAndTerminalOnlyCapabilitiesDoNotOfferUnsupportedSubmissions() throws {
        let viewer = SessionFixture()
        try viewer.handshake(permissions: ["view"]); try viewer.snapshot()
        viewer.client.acquire(viewer.target)
        XCTAssertFalse(viewer.sent.contains { $0.op == "acquire" })
        XCTAssertNil(viewer.client.submit(viewer.target, kind: "prompt", text: "never send"))
        let terminal = SessionFixture()
        try terminal.ready(); try terminal.takeControl()
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionFixture.descriptor())) as? [String: Any])
        descriptor["capabilities"] = ["terminal-v1"]
        descriptor["controller"] = ["controller_session": controllerID, "lease_epoch": 1]
        let codex = try JSONDecoder().decode(AtemSessionDescriptor.self, from: JSONSerialization.data(withJSONObject: descriptor))
        try terminal.snapshot(sequence: 2, descriptors: [codex])
        XCTAssertNil(terminal.client.submit(terminal.target, kind: "prompt", text: "use terminal"))
        XCTAssertTrue(terminal.client.controls(terminal.target))
        XCTAssertFalse(terminal.sent.contains { $0.op == "submit" })
        XCTAssertTrue(terminal.client.status.contains("terminal input only"))
    }

    func testAdmissionRefusalsFenceControlWithoutReplay() throws {
        for code in ["forbidden", "session_closed", "stale_lease", "stale_target", "unknown_session"] {
            let f = SessionFixture()
            try f.ready(); try f.takeControl(epoch: 1025)
            let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "one prompt"))
            var error = AtemSessionMessage(op: "error")
            error.re = try XCTUnwrap(f.sent.last(where: { $0.op == "submit" })).id
            error.code = code
            try f.receive(error)
            XCTAssertFalse(f.client.controls(f.target), code)
            XCTAssertNil(f.client.submit(f.target, kind: "stop"), code)
            XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1, code)
            XCTAssertEqual(f.disk.state.requests.first?.requestId, request)
        }
    }

    func testBusySubmitQueriesOriginalReceiptWithoutAssumingNoEffectOrResending() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "one prompt"))
        var error = AtemSessionMessage(op: "error")
        error.re = try XCTUnwrap(f.sent.last(where: { $0.op == "submit" })).id; error.code = "busy"
        try f.receive(error)
        f.time = 5; f.client.tick()
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        XCTAssertEqual(f.sent.last(where: { $0.op == "receipt_query" })?.request_ids, [request])
        XCTAssertNil(f.disk.state.requests.first?.receipt)
        try f.receipt(request, state: .accepted)
        XCTAssertEqual(f.disk.state.requests.first?.receipt?.state, .accepted)
    }

    func testFreshWelcomeClearsSequenceAndTombstonesButKeepsRuntimeFloor() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        try f.snapshot(sequence: 100, descriptors: [SessionFixture.descriptor(state: "removed")])
        XCTAssertTrue(f.client.registry.isEmpty)
        f.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "new-socket"),
            account: "account-a", device: "host-a", pairingSession: "pairing-1")
        f.client.connectionChanged()
        try f.handshake(attachment: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertTrue(f.client.registry.isEmpty)
        XCTAssertEqual(f.client.runtimeEpoch, 7)
        XCTAssertNil(f.client.sequence)
        try f.snapshot(sequence: 1)
        XCTAssertNotNil(f.client.registry[sessionID])
        XCTAssertEqual(f.client.sequence, 1)
        XCTAssertFalse(f.client.controls(f.target))
        try f.snapshot(epoch: 6, sequence: 999)
        XCTAssertEqual(f.client.sequence, 1)
    }

    func testRevocationBeforeGrantCannotRestoreControlAndExplicitAcquireCanRecover() throws {
        let f = SessionFixture()
        try f.ready()
        f.client.acquire(f.target)
        let acquire = try XCTUnwrap(f.sent.last)
        var revoked = AtemSessionMessage(op: "lease_changed")
        revoked.session_id = sessionID; revoked.process_gen = processID
        revoked.lease_epoch = 2; revoked.reason = "local_input"
        try f.receive(revoked)
        try f.lease(replyTo: acquire.id, epoch: 2)
        XCTAssertFalse(f.client.controls(f.target))
        f.client.acquire(f.target)
        try f.lease(replyTo: XCTUnwrap(f.sent.last).id, epoch: 3)
        XCTAssertTrue(f.client.controls(f.target))
    }

    func testRenewalCannotChangeEpochOrRestoreControlAtExactDeadline() throws {
        for (time, epoch) in [(6.0, UInt64(2)), (15.0, UInt64(1))] {
            let f = SessionFixture()
            try f.ready(); try f.takeControl()
            f.time = 5; f.client.tick()
            let renewal = try XCTUnwrap(f.sent.last(where: { $0.op == "renew" }))
            f.time = time
            try f.lease(replyTo: renewal.id, epoch: epoch)
            XCTAssertEqual(f.client.controlDeadline(for: f.target), time == 15 ? nil : 15)
            if time == 15 { XCTAssertFalse(f.client.controls(f.target)) }
        }
    }

    func testMismatchedReceiptReplyDoesNotConsumeControlRequest() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "inspect logs"))
        f.time = 5; f.client.tick()
        let renewal = try XCTUnwrap(f.sent.last(where: { $0.op == "renew" }))
        var unrelated = AtemSessionMessage(op: "receipt")
        unrelated.re = renewal.id; unrelated.request_id = request; unrelated.target = f.target
        unrelated.kind = "prompt"; unrelated.state = .accepted; unrelated.updated_at = 100
        try f.receive(unrelated)
        XCTAssertNil(f.client.latestReceipt)
        try f.lease(replyTo: renewal.id)
        XCTAssertEqual(f.client.controlDeadline(for: f.target), 20)
    }

    func testFreshAttachmentNeverRestoresControlOrReplaysPrompt() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "inspect logs"))
        try f.receipt(request, state: .accepted)
        let oldRoute = f.route
        f.source = nil; f.client.connectionChanged()
        XCTAssertFalse(f.client.controls(f.target))
        f.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "socket-2"), account: "account-a", device: "host-a", pairingSession: "pairing-1")
        f.client.connectionChanged()
        try f.handshake(attachment: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        try f.snapshot()
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        XCTAssertEqual(f.sent.last(where: { $0.op == "receipt_query" })?.request_ids, [request])
        var late = AtemSessionMessage(op: "lease")
        late.re = f.sent.first(where: { $0.op == "acquire" })!.id
        late.binding = AtemSessionBinding(target: f.target, attachment_gen: attachmentID, lease_epoch: 1)
        late.ms_left = 15_000
        try f.receive(late, route: oldRoute)
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testRevocationOrPairingChangeImmediatelyFencesInputBeforeTimer() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        f.source = AtemSessionContext(route: f.route, account: "account-a", device: "host-a", pairingSession: "pairing-2")
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertNil(f.client.submit(f.target, kind: "prompt", text: "must not send"))
        f.source = nil
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testPersistenceFailurePreventsAnySubmit() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        f.disk.fail = true
        XCTAssertNil(f.client.submit(f.target, kind: "prompt", text: "never written"))
        XCTAssertFalse(f.sent.contains { $0.op == "submit" })
    }

    func testRecoveryMetadataContainsNoPromptAndSurvivesClientRestart() throws {
        let disk = SessionDisk()
        let f = SessionFixture(disk: disk)
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "secret prompt contents"))
        let raw = String(decoding: try JSONEncoder().encode(disk.state), as: UTF8.self)
        XCTAssertFalse(raw.contains("secret prompt contents"))
        XCTAssertFalse(raw.contains("payload"))
        let recovered = SessionFixture(disk: disk)
        try recovered.ready()
        XCTAssertEqual(recovered.sent.last(where: { $0.op == "receipt_query" })?.request_ids, [request])
        XCTAssertFalse(recovered.sent.contains { $0.op == "submit" })
    }

    func testTerminalReceiptIsImmutableAcrossDuplicatesAndLateCompletion() throws {
        for final in [AtemReceiptState.rejected, .outcome_unknown] {
            let f = SessionFixture()
            try f.ready(); try f.takeControl()
            let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "run tests"))
            try f.receipt(request, state: .accepted, time: 1)
            try f.receipt(request, state: .executing, time: 2)
            try f.receipt(request, state: final, time: 3)
            try f.receipt(request, state: final, time: 3)
            XCTAssertEqual(f.client.latestReceipt?.state, final)
            try f.receipt(request, state: .completed, time: 4)
            XCTAssertEqual(f.client.phase, .failed)
            XCTAssertEqual(f.disk.state.requests.first?.receipt?.state, final)
        }
    }

    func testTrustGenerationCannotRollbackAndNewTrustDoesNotQueryOldReceipts() throws {
        let disk = SessionDisk()
        let f = SessionFixture(disk: disk)
        try f.ready(); try f.takeControl()
        _ = f.client.submit(f.target, kind: "prompt", text: "old trust")
        let next = SessionFixture(disk: disk)
        try next.handshake(trust: 2)
        XCTAssertFalse(next.sent.contains { $0.op == "receipt_query" })
        let stale = SessionFixture(disk: disk)
        try stale.handshake(trust: 1)
        XCTAssertEqual(stale.client.phase, .failed)
    }

    func testWelcomeReportsTrustRollbackWithoutReplacingTheSavedRuntimeFloor() throws {
        let disk = SessionDisk()
        let original = SessionFixture(disk: disk)
        try original.handshake(trust: 5)
        try original.snapshot(epoch: 10)
        let saved = disk.state

        let stale = SessionFixture(disk: disk)
        try stale.handshake(trust: 3)
        XCTAssertEqual(stale.client.phase, .failed)
        XCTAssertTrue(stale.client.status.contains("older trust generation (3; previously accepted 5)"))
        XCTAssertEqual(disk.state, saved)
        XCTAssertFalse(stale.client.journal.loadFailed, "A rejected rollback is not a storage fault")
        XCTAssertFalse(stale.sent.contains { ["list", "receipt_query", "acquire", "submit"].contains($0.op) })

        let newer = SessionFixture(disk: disk)
        try newer.handshake(trust: 6)
        try newer.snapshot(epoch: 1)
        XCTAssertTrue(newer.client.hasRegistrySnapshot)
        XCTAssertEqual(disk.state.hosts.first?.trust, 6)
        XCTAssertEqual(disk.state.hosts.first?.runtimeEpoch, 1)
    }

    func testWelcomeDiagnosticsNameTheFailedCheckWithoutExposingPayloads() throws {
        let cases: [(String, (inout AtemSessionMessage) -> Void)] = [
            ("account_id", { $0.account_id = "private-other-account" }),
            ("atem_device_id", { $0.atem_device_id = "private-other-device" }),
            ("client_kind", { $0.client_kind = "browser" }),
            ("permissions", { $0.permissions = ["control"] }),
            ("authorization_ms_left", { $0.authorization_ms_left = 0 }),
            ("authorization_ms_left", { $0.authorization_ms_left = 86_400_001 }),
            ("host_error", { $0.host_error = "private-host-error" }),
        ]
        for (field, mutate) in cases {
            let f = SessionFixture()
            try f.handshake(mutate: mutate)
            XCTAssertEqual(f.client.phase, .failed, field)
            XCTAssertTrue(f.client.status.contains("(\(field))"), f.client.status)
            XCTAssertFalse(f.client.status.contains("private-"))
            XCTAssertTrue(f.disk.state.hosts.isEmpty)
            XCTAssertFalse(f.sent.contains { $0.op == "list" })
        }
    }

    func testWelcomeJournalFailureIsDistinctFromTrustRollbackAndKeepsTheFence() throws {
        let disk = SessionDisk()
        disk.state.hosts = [AtemSessionHostFence(account: "account-a", device: "host-a", trust: 5,
            runtimeEpoch: 10, runtimeGeneration: runtimeID)]
        let f = SessionFixture(disk: disk)
        let saved = disk.state
        disk.fail = true
        try f.handshake(trust: 6)
        XCTAssertEqual(f.client.phase, .failed)
        XCTAssertEqual(f.client.status, "Could not save the session's verification state. Check this Mac's local storage before reconnecting.")
        XCTAssertTrue(f.client.journal.loadFailed)
        XCTAssertFalse(f.client.connectionStatus.canReconnect)
        XCTAssertEqual(disk.state, saved)
        XCTAssertFalse(f.sent.contains { $0.op == "list" })
    }

    func testLocalTakeoverFencesOutstandingRenewalAndQueuedControlReply() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        f.time = 5; f.client.tick()
        let renew = try XCTUnwrap(f.sent.last(where: { $0.op == "renew" }))
        var changed = AtemSessionMessage(op: "lease_changed")
        changed.session_id = sessionID; changed.process_gen = processID
        changed.lease_epoch = 2; changed.reason = "local_input"
        try f.receive(changed)
        try f.lease(replyTo: renew.id)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertNil(f.client.submit(f.target, kind: "stop"))
    }

    func testRuntimeRestartRequiresFreshWelcomeAndNeverRestoresLease() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        try f.snapshot(sequence: 100)
        let newRuntime = "99999999-9999-4999-8999-999999999999"
        try f.snapshot(epoch: 8, runtime: newRuntime)
        XCTAssertEqual(f.client.phase, .failed)
        XCTAssertFalse(f.client.controls(f.target))
        let helloCount = f.sent.filter { $0.op == "hello" }.count
        f.client.refresh()
        XCTAssertEqual(f.sent.filter { $0.op == "hello" }.count, helloCount, "No second hello on a welcomed attachment")
        XCTAssertEqual(f.disk.state.hosts.first?.runtimeEpoch, 8)
        f.source = AtemSessionContext(route: RemoteTerminalConnection(clientId: "host", connectionId: "restarted"),
            account: "account-a", device: "host-a", pairingSession: "pairing-1")
        f.client.connectionChanged()
        try f.handshake(runtime: newRuntime, attachment: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        try f.snapshot(epoch: 8, runtime: newRuntime)
        XCTAssertEqual(f.client.phase, .ready)
        XCTAssertNotNil(f.client.target(sessionId: sessionID, process: processID), "The new runtime starts a fresh sequence domain")
        XCTAssertFalse(f.client.controls(f.target))
    }

    func testMultipleRemovedGenerationsCannotResurrectAnEarlierProcess() throws {
        let f = SessionFixture()
        try f.ready()
        let second = "77777777-7777-4777-8777-777777777777"
        for (sequence, state, process) in [(UInt64(2), "removed", processID), (3, "running", second), (4, "removed", second), (5, "running", processID)] {
            var change = AtemSessionMessage(op: "session_changed")
            change.runtime_gen = runtimeID; change.runtime_epoch = 7; change.seq = sequence
            change.descriptor = try SessionFixture.descriptor(state: state, process: process)
            try f.receive(change)
        }
        XCTAssertTrue(f.client.registry.isEmpty)
        XCTAssertNil(f.client.target(sessionId: sessionID, process: processID))
    }

    func testMissingReceiptsAreQueriedAgainWithoutResubmission() throws {
        let f = SessionFixture()
        try f.ready(); try f.takeControl()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "run tests"))
        f.time = 5; f.client.tick()
        let query = try XCTUnwrap(f.sent.last(where: { $0.op == "receipt_query" }))
        var reply = AtemSessionMessage(op: "receipts")
        reply.re = query.id; reply.receipts = []
        try f.receive(reply)
        f.time = 10; f.client.tick()
        XCTAssertEqual(f.sent.filter { $0.op == "receipt_query" }.count, 2)
        XCTAssertEqual(f.sent.last(where: { $0.op == "receipt_query" })?.request_ids, [request])
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
    }
}

final class AtemSessionJournalTests: XCTestCase {
    func testRealFileReloadRestrictsPermissionsAndPreservesOnlyRecoveryMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json")
        let journal = AtemSessionJournal.persistent(at: file)
        let f = SessionFixture()
        let record = AtemSessionRequestRecord(requestId: UUID().uuidString.lowercased(), target: f.target,
            kind: "prompt", digest: try AtemSessionJSON.object(["text": .string("private prompt")]).digest())
        try journal.update {
            $0.requests.append(record)
            $0.hosts.append(AtemSessionHostFence(account: "account-a", device: "host-a", trust: 2,
                runtimeEpoch: 7, runtimeGeneration: runtimeID))
        }
        let reloaded = AtemSessionJournal.persistent(at: file)
        XCTAssertFalse(reloaded.loadFailed)
        XCTAssertEqual(reloaded.snapshot, journal.snapshot)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("private prompt"))
        XCTAssertFalse(bytes.contains("payload"))
        XCTAssertFalse(bytes.contains("token"))
    }

    func testCorruptAndCrossTargetJournalsFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json")
        try Data(#"{"version":1,"version":1,"requests":[],"hosts":[]}"#.utf8).write(to: file)
        let corrupted = AtemSessionJournal.persistent(at: file)
        XCTAssertTrue(corrupted.loadFailed)
        XCTAssertThrowsError(try corrupted.update { $0.hosts = [] })
        let target = SessionFixture().target
        var invalid = AtemSessionJournal.Snapshot()
        let request = UUID().uuidString.lowercased()
        invalid.requests = [AtemSessionRequestRecord(requestId: request, target: target, kind: "prompt", digest: String(repeating: "a", count: 64),
            receipt: AtemSessionReceipt(request_id: UUID().uuidString.lowercased(), target: target, kind: "prompt", state: .accepted, detail: nil, updated_at: 1))]
        XCTAssertTrue(AtemSessionJournal(load: { invalid }).loadFailed)
    }

    func testUncertainPersistenceFailurePreventsLaterFenceOverwrite() throws {
        let disk = SessionDisk()
        let journal = disk.journal()
        disk.fail = true
        XCTAssertThrowsError(try journal.update { $0.hosts.append(AtemSessionHostFence(account: "a", device: "d", trust: 2)) })
        disk.fail = false
        XCTAssertThrowsError(try journal.update { $0.hosts.append(AtemSessionHostFence(account: "a", device: "d", trust: 1)) })
        XCTAssertTrue(disk.state.hosts.isEmpty)
    }
}

private final class SessionTerminalFixture {
    let protocolFixture = SessionFixture()
    var sent: [RemoteTerminalMessage] = []
    var rendered: [(RemoteTerminalFrame, String)] = []
    lazy var terminal = RemoteTerminalController(currentConnection: { self.protocolFixture.source?.route },
        send: { message, _ in self.sent.append(message); return true }, now: { self.protocolFixture.time })
    var session: RemoteTerminalSession {
        RemoteTerminalSession(terminalId: sessionID, generation: processID, provider: "claude", rows: 40, cols: 120,
            exitStatus: nil, rendering: "vt100-screen-diff", widthProfile: "atem-unicode-width-0.1.14", capabilities: ["terminal-v1"], agentId: sessionID)
    }
    var stream: RemoteTerminalStream { RemoteTerminalStream(terminalId: sessionID, generation: processID, streamId: "stream") }
    init() {
        terminal.sessionClient = protocolFixture.client
        protocolFixture.client.onChange = { [weak self] in self?.terminal.sessionStateChanged() }
        terminal.render = { self.rendered.append(($0, $1)) }
    }
    func receive(_ message: RemoteTerminalMessage, bound: Bool = false) throws {
        let envelope: RemoteTerminalMessage
        if bound {
            envelope = .bound(message, try XCTUnwrap(protocolFixture.client.binding(for: protocolFixture.target, mutation: false)))
        } else { envelope = message }
        let bytes = try JSONEncoder().encode(AstationMessage.terminal(envelope))
        guard case .terminal(let decoded) = try AstationMessage.decodePacket(bytes) else { return XCTFail("terminal") }
        terminal.receive(decoded, from: protocolFixture.route)
    }
    func viewing() throws {
        try protocolFixture.ready()
        terminal.open(preferredTerminalId: sessionID)
        try receive(.attached(session, streamId: "stream"))
        try receive(.frame(RemoteTerminalFrame(stream: stream, offset: 0, bytes: Data("screen".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 40, cols: 120)))
        terminal.consumed(try XCTUnwrap(rendered.last).1)
        XCTAssertEqual(terminal.phase, .viewing)
    }
    func control() throws {
        terminal.takeControl()
        try protocolFixture.lease(replyTo: XCTUnwrap(protocolFixture.sent.last(where: { $0.op == "acquire" })).id)
        XCTAssertTrue(terminal.canInput)
    }
}

final class AtemSessionTerminalTests: XCTestCase {
    func testSelectingAnotherSessionAutomaticallyViewsItAndReleasesPreviousControl() throws {
        let f = SessionTerminalFixture()
        try f.viewing(); try f.control()
        let descriptor = try SessionFixture.descriptor(session: "ses-bbbbbbbbbbbb",
            process: "77777777-7777-4777-8777-777777777777", provider: "codex")
        try f.protocolFixture.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(controller: AtemSessionController(controller_session: controllerID, lease_epoch: 1)), descriptor])
        let selected = try XCTUnwrap(f.terminal.sessions.first { $0.terminalId == descriptor.session_id })
        let target = try XCTUnwrap(f.protocolFixture.client.target(sessionId: selected.terminalId, process: selected.generation))
        let binding = try XCTUnwrap(f.protocolFixture.client.binding(for: target, mutation: false))

        f.terminal.select(selected)

        XCTAssertEqual(f.terminal.phase, .attaching)
        XCTAssertEqual(f.terminal.session?.id, selected.id)
        XCTAssertFalse(f.terminal.canInput)
        XCTAssertFalse(f.protocolFixture.client.controls(f.protocolFixture.target))
        XCTAssertEqual(f.protocolFixture.sent.last(where: { $0.op == "release" })?.binding?.target, f.protocolFixture.target)
        XCTAssertEqual(f.sent.last, .bound(.subscribe(terminalId: selected.terminalId, generation: selected.generation), binding))
        let writes = f.sent.count
        f.terminal.input(Data("must not reach either session".utf8))
        XCTAssertEqual(f.sent.count, writes)

        try f.receive(.attached(selected, streamId: "second-stream"))
        let stream = RemoteTerminalStream(terminalId: selected.terminalId, generation: selected.generation, streamId: "second-stream")
        try f.receive(.frame(RemoteTerminalFrame(stream: stream, offset: 0, bytes: Data("Codex screen".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 24, cols: 80)))
        f.terminal.consumed(try XCTUnwrap(f.rendered.last).1)
        XCTAssertEqual(f.terminal.phase, .viewing)
        XCTAssertEqual(f.rendered.last?.0.stream, stream)
        XCTAssertTrue(f.terminal.canTakeControl)
        XCTAssertFalse(f.terminal.canInput)
        XCTAssertEqual(f.protocolFixture.sent.filter { $0.op == "acquire" }.count, 1, "Switching must not take control")
        let messages = f.sent.count
        f.terminal.select(selected)
        XCTAssertEqual(f.sent.count, messages, "Selecting the current session must not reattach")
    }

    func testSwitchingBeforeFirstAttachmentIgnoresItsLateScreenAndKeepsSelectedSession() throws {
        let f = SessionTerminalFixture()
        try f.protocolFixture.ready()
        f.terminal.open(preferredTerminalId: sessionID)
        let descriptor = try SessionFixture.descriptor(session: "ses-bbbbbbbbbbbb",
            process: "77777777-7777-4777-8777-777777777777")
        try f.protocolFixture.snapshot(sequence: 2, descriptors: [SessionFixture.descriptor(controller: AtemSessionController(controller_session: controllerID, lease_epoch: 1)), descriptor])
        let selected = try XCTUnwrap(f.terminal.sessions.first { $0.terminalId == descriptor.session_id })
        f.terminal.select(selected)
        try f.receive(.attached(f.session, streamId: "stream"))
        try f.receive(.frame(RemoteTerminalFrame(stream: f.stream, offset: 0, bytes: Data("old screen".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 40, cols: 120)))
        XCTAssertEqual(f.terminal.phase, .attaching)
        XCTAssertEqual(f.terminal.session?.id, selected.id)
        XCTAssertNil(f.terminal.stream)
        XCTAssertTrue(f.rendered.isEmpty)
        XCTAssertTrue(f.sent.contains { if case .bound(.unsubscribe(f.stream), _) = $0 { return true }; return false })

        try f.receive(.attached(selected, streamId: "selected-stream"))
        XCTAssertEqual(f.terminal.stream?.terminalId, selected.terminalId)
        XCTAssertEqual(f.terminal.stream?.streamId, "selected-stream")
        XCTAssertFalse(f.terminal.canInput)
        XCTAssertFalse(f.protocolFixture.sent.contains { $0.op == "acquire" })
    }

    func testOldStreamErrorCannotCloseNewViewAndCurrentRefusalDropsControl() throws {
        let f = SessionTerminalFixture()
        try f.viewing(); try f.control()
        try f.receive(.error(terminalId: sessionID, streamId: "old-stream", code: "stale_target", message: "Old stream"))
        XCTAssertTrue(f.terminal.canInput)
        XCTAssertEqual(f.terminal.stream, f.stream)
        f.protocolFixture.client.refresh()
        try f.receive(.error(terminalId: sessionID, streamId: "stream", code: "session_closed", message: "Session closed"))
        XCTAssertFalse(f.terminal.canInput)
        XCTAssertFalse(f.protocolFixture.client.controls(f.protocolFixture.target))
        XCTAssertNil(f.terminal.stream)
        try f.protocolFixture.snapshot(sequence: 2)
        XCTAssertFalse(f.protocolFixture.client.controls(f.protocolFixture.target), "A snapshot cannot restore a lease refused during resync")
    }

    func testActualTerminalUsesBindingForInputResizeAndReceiptSubmissions() throws {
        let f = SessionTerminalFixture()
        try f.viewing(); try f.control()
        f.terminal.input(Data("hi".utf8))
        f.terminal.resize(rows: 50, cols: 100)
        for message in f.sent.dropFirst() {
            guard case .bound(_, let binding) = message else { return XCTFail("Unbound terminal request") }
            XCTAssertEqual(binding.target, f.protocolFixture.target)
        }
        XCTAssertTrue(f.terminal.sendScopedInput(kind: "text", value: "run tests"))
        XCTAssertTrue(f.terminal.sendScopedInput(kind: "key", value: "ctrl-c"))
        f.terminal.stop()
        XCTAssertEqual(f.protocolFixture.sent.filter { $0.op == "submit" }.map(\.kind), ["prompt", "interrupt", "stop"])
        XCTAssertEqual(f.protocolFixture.disk.state.requests.count, 3)
        XCTAssertFalse(f.sent.contains { if case .control = $0 { return true }; if case .stop = $0 { return true }; return false })
    }

    func testRegistryDrivesDiscoveryAndOnlyAnOutstandingSubscriptionCanAttach() throws {
        let f = SessionTerminalFixture()
        try f.protocolFixture.handshake()
        f.terminal.open(preferredTerminalId: sessionID)
        try f.receive(.sessions([f.session]))
        try f.receive(.attached(f.session, streamId: "unsolicited"))
        XCTAssertEqual(f.terminal.phase, .listing)
        XCTAssertTrue(f.sent.isEmpty, "No removed terminal list op")
        XCTAssertNil(f.terminal.stream)
        try f.protocolFixture.snapshot()
        XCTAssertEqual(f.terminal.phase, .attaching)
        XCTAssertEqual(f.sent.count, 1)
        try f.receive(.attached(f.session, streamId: "stream"))
        XCTAssertEqual(f.terminal.stream, f.stream)
    }

    func testReleaseRevocationAndExactExpiryFenceTerminalAndRendererCallbacks() throws {
        for action in ["release", "revoke", "expiry"] {
            let f = SessionTerminalFixture()
            try f.viewing(); try f.control()
            if action == "release" { f.terminal.release() }
            else if action == "revoke" {
                var revoked = AtemSessionMessage(op: "lease_changed")
                revoked.session_id = sessionID; revoked.process_gen = processID
                revoked.lease_epoch = 2; revoked.reason = "local_input"
                try f.protocolFixture.receive(revoked)
            } else { f.protocolFixture.time = 15 }
            let count = f.sent.count
            f.terminal.input(Data("late queued key".utf8))
            XCTAssertFalse(f.terminal.canInput)
            XCTAssertFalse(f.terminal.sendScopedInput(kind: "text", value: "late voice"))
            XCTAssertEqual(f.sent.count, count)
        }
    }
}

final class AtemR8IntegrationTests: XCTestCase {
    private func admit(_ f: SessionFixture, _ request: String, epoch: UInt64 = 1) throws {
        let submit = try XCTUnwrap(f.sent.last { $0.op == "submit" && $0.request_id == request })
        var reply = AtemSessionMessage(op: "receipt")
        reply.re = submit.id; reply.target = f.target; reply.request_id = request
        reply.kind = "prompt"; reply.state = .accepted; reply.updated_at = 100
        reply.lease = AtemSessionSendLease(lease_epoch: epoch, ms_left: 15_000)
        try f.receive(reply)
    }

    private func event(_ f: SessionFixture, _ op: String, _ sequence: UInt64, fields: [String: Any] = [:]) throws {
        var data: [String: Any] = ["v": 1, "op": op, "conversationId": try XCTUnwrap(f.client.chatSnapshot(f.target)?.chat_id),
            "agentId": sessionID, "generation": processID, "sequence": sequence]
        fields.forEach { data[$0.key] = $0.value }
        let raw = try JSONSerialization.data(withJSONObject: ["type": "agentChat", "data": data])
        guard case .agentChat(let chat) = try AstationMessage.decodePacket(raw) else { return XCTFail("chat") }
        f.client.receiveChat(chat, from: f.route)
    }

    private func message(_ id: String, text: String, history: Bool = false) -> [String: Any] {
        ["messageId": id, "role": "assistant", "turnId": "turn-1", "createdAt": 1_760_500_000_000,
         "parts": [["id": "p1", "kind": "text", "markdown": text]], "history": history]
    }

    private func page(_ count: Int, selector: String = "newest", partial: Bool = false) -> [String: Any] {
        ["selector": selector, "count": count, "content_bytes": 100, "wire_bytes": 1000,
         "end": true, "coverage": partial ? "partial" : "complete", "truncated": partial,
         "holes": [], "oldest_retained": "m0"]
    }

    func testSendAcquiresOnceAndReleasedViewNeverAdoptsItsLateReceipt() throws {
        let f = SessionFixture(); try f.ready()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "inspect safely"))
        XCTAssertEqual(f.sent.last?.acquire, true)
        XCTAssertNil(f.sent.last?.binding?.lease_epoch)
        f.client.releaseAll()
        f.time = 1
        try admit(f, request)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertEqual(f.disk.state.requests.last?.receipt?.state, .accepted)
        XCTAssertEqual(f.client.submit(f.target, kind: "prompt", text: "inspect safely", requestID: request), request)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        f.time = 6; f.client.tick()
        XCTAssertFalse(f.sent.contains { $0.op == "renew" })
    }

    func testTimelySendLeaseRenewsButApprovalAnswerKeepsItsHolderAndDeadline() throws {
        let f = SessionFixture(); try f.ready()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "inspect safely"))
        f.time = 1; try admit(f, request)
        XCTAssertTrue(f.client.controls(f.target))
        XCTAssertEqual(f.client.controlDeadline(for: f.target), 15)
        let approval = try f.approval()
        f.time = 3
        XCTAssertNotNil(f.client.answerApproval(approval, decision: .deny, message: "Please explain first"))
        let answer = try XCTUnwrap(f.sent.last)
        XCTAssertNil(answer.acquire); XCTAssertNil(answer.payload?["acquire"])
        XCTAssertNil(answer.binding?.lease_epoch)
        var closed = AtemSessionMessage(op: "error")
        closed.re = answer.id; closed.code = "stale_target"
        try f.receive(closed)
        XCTAssertTrue(f.client.controls(f.target), "Another answer winning cannot revoke unrelated terminal control")
        XCTAssertEqual(f.client.controlDeadline(for: f.target), 15)
        XCTAssertFalse(f.client.canAnswer(approval))
        f.time = 5; f.client.tick()
        XCTAssertEqual(f.sent.last(where: { $0.op == "renew" })?.binding?.lease_epoch, 1)
    }

    func testAPIAndNativeDoNotShareControlAndAbandonedAPICallerExpires() throws {
        let f = SessionFixture(); try f.ready()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "API prompt", owner: "api:test"))
        XCTAssertNil(f.client.submit(f.target, kind: "prompt", text: "native race"))
        XCTAssertFalse(f.client.acquire(f.target))
        try admit(f, request)
        XCTAssertEqual(f.client.controlOwner(for: f.target), "api:test")
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertNil(f.client.submit(f.target, kind: "interrupt"))
        f.time = 5; f.client.tick()
        XCTAssertFalse(f.sent.contains { $0.op == "renew" })
        XCTAssertTrue(f.client.renew(f.target, owner: "api:test"))
        let renewal = try XCTUnwrap(f.sent.last)
        try f.lease(replyTo: renewal.id)
        XCTAssertEqual(f.client.controlDeadline(for: f.target), 20)
        f.client.releaseAll()
        XCTAssertEqual(f.client.controlOwner(for: f.target), "api:test", "Closing native UI cannot steal API control")
        f.time = 20; f.client.tick()
        XCTAssertNil(f.client.controlOwner(for: f.target))
        XCTAssertFalse(f.client.renew(f.target, owner: "api:test"))
    }

    func testTakeoverRequiresTheRefusedHolderAndKeepsSameRequestIdentity() throws {
        let f = SessionFixture(); try f.ready()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "review"))
        let holder = AtemSessionController(controller_session: "99999999-9999-4999-8999-999999999999", lease_epoch: 7)
        var refusal = AtemSessionMessage(op: "error")
        refusal.re = f.sent.last?.id; refusal.code = "lease_held"; refusal.controller = holder
        try f.receive(refusal)
        XCTAssertEqual(f.client.submit(f.target, kind: "prompt", text: "review", requestID: request), request)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        XCTAssertEqual(f.client.submit(f.target, kind: "prompt", text: "review", requestID: request, takeover: holder), request)
        XCTAssertEqual(f.sent.last?.expected_controller, holder)
        XCTAssertEqual(f.sent.last?.takeover, true)
        XCTAssertEqual(f.sent.last?.request_id, request)
        try admit(f, request, epoch: 8)
        XCTAssertTrue(f.client.controls(f.target))
        XCTAssertEqual(f.client.submit(f.target, kind: "prompt", text: "review", requestID: request), request)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 2, "Accepted work never runs again")
    }

    func testWholeMessagesHistoryCoverageAndRecoveredNullPredecessorUseOneOrderedView() throws {
        let f = SessionFixture(); try f.ready()
        try event(f, "opened", 0, fields: ["status": ["state": "working", "since": 1_760_500_000_000]])
        try event(f, "message", 1, fields: message("m1", text: "first", history: true))
        XCTAssertFalse(try XCTUnwrap(f.client.chatSnapshot(f.target)).loaded)
        try event(f, "history_end", 2, fields: ["page": page(1)])
        let pageID = try XCTUnwrap(f.client.chatHistory(f.target, before: "m1"))
        var older = message("m0", text: "older", history: true); older["page_id"] = pageID
        try event(f, "message", 3, fields: older)
        try event(f, "message", 4, fields: message("m2", text: "live"))
        try event(f, "history_end", 5, fields: ["page_id": pageID, "page": page(1, selector: "before", partial: true)])
        XCTAssertEqual(f.client.chatPage(f.target, pageID: pageID)?.pending, false)
        XCTAssertEqual(f.client.chatSnapshot(f.target)?.messages.compactMap(\.messageId), ["m0", "m1", "m2"])
        try event(f, "message", 6, fields: message("m1", text: "whole replacement"))
        try event(f, "complete", 7, fields: ["outcome": "done", "turnId": "turn-1"])
        try event(f, "message", 8, fields: message("m2", text: "late after complete"))
        var recovered = message("recovered", text: "backfilled", history: true)
        recovered["after_message_id"] = NSNull()
        try event(f, "message", 9, fields: recovered)
        try event(f, "coverage", 10, fields: ["truncated": true, "oldest_retained": "m0",
            "holes": [["after_message_id": "m0", "before_message_id": "m1"]]])
        let view = try XCTUnwrap(f.client.chatSnapshot(f.target))
        XCTAssertEqual(view.messages.compactMap(\.messageId), ["recovered", "m0", "m1", "m2"])
        XCTAssertEqual(view.messages.first { $0.messageId == "m1" }?.parts?.first?.markdown, "whole replacement")
        XCTAssertEqual(view.messages.last?.parts?.first?.markdown, "late after complete")
        XCTAssertTrue(view.truncated); XCTAssertEqual(view.holes.count, 1)
        XCTAssertEqual(view.reopens, 0); XCTAssertEqual(f.chats.filter { $0.op == "open" }.count, 1)
        let lookup = try XCTUnwrap(f.client.chatHistory(f.target, request: UUID().uuidString.lowercased()))
        try event(f, "error", 11, fields: ["page_id": lookup, "code": "stale_target"])
        XCTAssertEqual(f.client.chatPage(f.target, pageID: lookup)?.error, "stale_target")
        XCTAssertEqual(f.client.chatSnapshot(f.target)?.closed, false)
    }

    func testMissingHistoryBoundaryIsUnconfirmedAndNeverAnEmptyCompletedHistory() throws {
        let f = SessionFixture(); try f.ready()
        try event(f, "opened", 0, fields: ["status": ["state": "ready", "since": 1_760_500_000_000]])
        f.time = 10; f.client.tick()
        let snapshot = try XCTUnwrap(f.client.chatSnapshot(f.target))
        XCTAssertFalse(snapshot.loaded)
        XCTAssertTrue(snapshot.closed)
        XCTAssertEqual(snapshot.error, "history_unconfirmed")
        _ = f.client.readChat(f.target)
        XCTAssertEqual(f.chats.filter { $0.op == "open" }.count, 1, "Polling cannot create an endless reconnect loop")
    }

    func testUnadvertisedFeaturesDoNotSendMutationsOrLookups() throws {
        let f = SessionFixture()
        try f.handshake(features: ["chat.history_end", "chat.history", "chat.future"]); try f.snapshot()
        XCTAssertEqual(f.client.features, ["chat.history_end", "chat.history"])
        let approval = try f.approval()
        XCTAssertFalse(f.client.canAnswer(approval))
        XCTAssertNil(f.client.answerApproval(approval, decision: .allowOnce))
        XCTAssertNil(f.client.submit(f.target, kind: "prompt", text: "requires atomic send"))
        XCTAssertNil(f.client.chatHistory(f.target, turn: "turn-1"))
        XCTAssertFalse(f.sent.contains { $0.op == "submit" })
    }

    func testCompletedReceiptProjectsUpdatedReplyCoverageWithoutReexecuting() throws {
        let f = SessionFixture(); try f.ready()
        let request = try XCTUnwrap(f.client.submit(f.target, kind: "prompt", text: "inspect"))
        var receipt = AtemSessionMessage(op: "receipt")
        receipt.target = f.target; receipt.request_id = request; receipt.kind = "prompt"
        receipt.state = .completed; receipt.detail = "done"; receipt.updated_at = 101
        receipt.result = AtemSessionResult(turn_id: "turn-1", user_message_id: "user-1", outcome: "done",
            reply_message_ids: [], more: false, replies: "unavailable")
        try f.receive(receipt)
        receipt.result = AtemSessionResult(turn_id: "turn-1", user_message_id: "user-1", outcome: "done",
            reply_message_ids: ["reply-1"], more: true, replies: "partial")
        try f.receive(receipt)
        XCTAssertEqual(f.client.latestReceipt?.result?.reply_message_ids, ["reply-1"])
        XCTAssertEqual(f.client.phase, .ready)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        let saved = String(decoding: try JSONEncoder().encode(f.disk.state), as: UTF8.self)
        XCTAssertFalse(saved.contains("inspect"))
        receipt.result = AtemSessionResult(turn_id: "different-turn", user_message_id: "user-1", outcome: "done",
            reply_message_ids: [], more: false, replies: "unavailable")
        try f.receive(receipt)
        XCTAssertEqual(f.client.phase, .failed, "A final outcome cannot change identity")
    }

    func testFreshRegistrySnapshotCannotRestoreAFormerControllersLease() throws {
        let f = SessionFixture(); try f.ready(); try f.takeControl()
        f.client.refresh()
        try f.snapshot(sequence: 3)
        XCTAssertFalse(f.client.controls(f.target), "A fresh snapshot says there is no holder")
    }

    func testR8CountersRefuseFractionalSpellingsBeforeFoundationCoercion() throws {
        for (field, value) in [("revision", "8.0"), ("revision", "8e0")] {
            let raw = "{\"type\":\"session\",\"data\":{\"v\":1,\"op\":\"hello\",\"id\":\"11111111-1111-4111-8111-000000000001\",\"\(field)\":\(value)}}"
            XCTAssertThrowsError(try AstationMessage.decodePacket(Data(raw.utf8)))
        }
    }
}

extension AtemR8IntegrationTests {
    private func api(_ f: SessionFixture) throws -> LocalControlAPI {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(String(repeating: "ab", count: 32).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let inbox = ApprovalInbox(); inbox.sync(sourceID: "host", client: f.client, host: "Genie")
        return LocalControlAPI(key: try LocalAPIKey(file: file.path), clients: { ["host": f.client] },
            inbox: inbox, records: { f.disk.state.requests })
    }

    private func post(_ api: LocalControlAPI, _ f: SessionFixture, _ path: String,
                      _ fields: [String: Any] = [:]) throws -> LocalAPIResponse {
        var input = fields
        input["client_id"] = "host"
        input["target"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.target))
        return api.handle(method: .POST, path: "/api/v1/" + path, body: try JSONSerialization.data(withJSONObject: input))
    }

    func testAPISendRenewReleaseAndOwnershipUseTheR8SessionService() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        let status = api.handle(method: .GET, path: "/api/v1/status", body: Data())
        XCTAssertEqual((try JSONSerialization.jsonObject(with: status.body) as? [String: String])?["session_contract"], "r8")
        let request = UUID().uuidString.lowercased()
        XCTAssertEqual(try post(api, f, "sessions/submit", ["request_id": request, "kind": "prompt", "text": "inspect"]).status, .accepted)
        XCTAssertEqual(f.sent.last?.acquire, true)
        try admit(f, request)
        XCTAssertEqual(f.client.controlOwner(for: f.target), "api:local-api")
        XCTAssertEqual(try post(api, f, "sessions/renew", ["operator_id": "another-script"]).status, .conflict)
        f.time = 5
        XCTAssertEqual(try post(api, f, "sessions/renew").status, .accepted)
        try f.lease(replyTo: XCTUnwrap(f.sent.last).id)
        XCTAssertEqual(f.client.controlDeadline(for: f.target), 20)
        XCTAssertEqual(try post(api, f, "sessions/release").status, .ok)
        XCTAssertNil(f.client.controlOwner(for: f.target))
        XCTAssertEqual(f.sent.last?.op, "release")
    }

    func testAPITakeoverRejectsStaleConfirmationBeforeResending() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        let request = UUID().uuidString.lowercased()
        let fields: [String: Any] = ["request_id": request, "kind": "prompt", "text": "review"]
        XCTAssertEqual(try post(api, f, "sessions/submit", fields).status, .accepted)
        let holder = AtemSessionController(controller_session: "99999999-9999-4999-8999-999999999999", lease_epoch: 7)
        var refusal = AtemSessionMessage(op: "error")
        refusal.re = f.sent.last?.id; refusal.code = "lease_held"; refusal.controller = holder
        try f.receive(refusal)
        var retry = fields; retry["takeover"] = true
        retry["expected_controller"] = ["controller_session": holder.controller_session, "lease_epoch": 6]
        XCTAssertEqual(try post(api, f, "sessions/submit", retry).status, .conflict)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 1)
        retry["expected_controller"] = ["controller_session": holder.controller_session, "lease_epoch": 7]
        XCTAssertEqual(try post(api, f, "sessions/submit", retry).status, .accepted)
        XCTAssertEqual(f.sent.last?.expected_controller, holder)
        try admit(f, request, epoch: 8)
        XCTAssertEqual(try post(api, f, "sessions/submit", retry).status, .accepted)
        XCTAssertEqual(f.sent.filter { $0.op == "submit" }.count, 2)
    }

    func testAPIReadsOrderedHistoryWithExplicitPendingAndCompletedPages() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        let opening = try post(api, f, "chat/read")
        XCTAssertEqual(opening.status, .ok)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: opening.body) as? [String: Any])?["loaded"] as? Bool, false)
        try event(f, "opened", 0, fields: ["status": ["state": "ready", "since": 1_760_500_000_000]])
        try event(f, "history_end", 1, fields: ["page": page(0)])
        let response = try post(api, f, "chat/history", ["before": "m1"])
        XCTAssertEqual(response.status, .accepted)
        let pageID = try XCTUnwrap((JSONSerialization.jsonObject(with: response.body) as? [String: String])?["page_id"])
        let pending = try post(api, f, "chat/page", ["page_id": pageID])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: pending.body) as? [String: Any])?["pending"] as? Bool, true)
        var earlier = message("m0", text: "earlier", history: true); earlier["page_id"] = pageID
        try event(f, "message", 2, fields: earlier)
        try event(f, "history_end", 3, fields: ["page_id": pageID, "page": page(1, selector: "before")])
        let complete = try post(api, f, "chat/page", ["page_id": pageID])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: complete.body) as? [String: Any])
        XCTAssertEqual(decoded["pending"] as? Bool, false)
        XCTAssertEqual((decoded["messages"] as? [[String: Any]])?.first?["messageId"] as? String, "m0")
        XCTAssertFalse(f.sent.contains { $0.op == "acquire" || $0.op == "submit" })
        XCTAssertEqual(try post(api, f, "chat/history", ["before": "m0", "turn_id": "turn-1"]).status, .conflict)
    }

    func testUnsupportedAtemIsHiddenAndNeverFallsBackOrRetriesOnATimer() throws {
        let f = SessionFixture(); try f.ready()
        let api = try api(f)
        var error = AtemSessionMessage(op: "error"); error.code = "unsupported_version"
        try f.receive(error)
        XCTAssertTrue(f.client.unsupportedVersion)
        XCTAssertTrue(f.client.status.contains("Upgrade Atem"))
        let list = api.handle(method: .GET, path: "/api/v1/sessions", body: Data())
        XCTAssertEqual((try JSONSerialization.jsonObject(with: list.body) as? [Any])?.count, 0)
        let count = f.sent.count
        f.time = 30; f.client.tick()
        XCTAssertEqual(f.sent.count, count)
        XCTAssertNil(f.client.submit(f.target, kind: "prompt", text: "never send"))
    }
}

extension AtemR8IntegrationTests {
    func testHistoryContentLimitIsMeasuredWithoutTrustingThePageDeclaration() throws {
        let f = SessionFixture(); try f.ready()
        try event(f, "opened", 0, fields: ["status": ["state": "ready", "since": 1_760_500_000_000]])
        for sequence in UInt64(1)...3 {
            try event(f, "message", sequence, fields: message("m\(sequence)", text: String(repeating: "a", count: 100_000), history: true))
        }
        XCTAssertEqual(f.client.chatSnapshot(f.target)?.error, "invalid_chat_message")
        XCTAssertEqual(f.client.chatSnapshot(f.target)?.closed, true)
        XCTAssertEqual(f.chats.last?.op, "close")
        XCTAssertFalse(try XCTUnwrap(f.client.chatSnapshot(f.target)).loaded)
    }

    func testLargeFinalResultMetadataCannotBlockOrEvictUnconfirmedRequests() throws {
        let f = SessionFixture()
        let replies = (0..<32).map { "reply-\($0)-" + String(repeating: "a", count: 116) }
        let result = AtemSessionResult(turn_id: "turn-1", user_message_id: "user-1", outcome: "done",
            reply_message_ids: replies, more: false, replies: "complete")
        var records = (0..<1100).map { _ -> AtemSessionRequestRecord in
            let id = UUID().uuidString.lowercased()
            return AtemSessionRequestRecord(requestId: id, target: f.target, kind: "prompt", digest: String(repeating: "a", count: 64),
                receipt: AtemSessionReceipt(request_id: id, target: f.target, kind: "prompt", state: .completed,
                    detail: "done", updated_at: 1, result: result))
        }
        let uncertain = UUID().uuidString.lowercased()
        records.append(AtemSessionRequestRecord(requestId: uncertain, target: f.target, kind: "prompt", digest: String(repeating: "b", count: 64)))
        let journal = AtemSessionJournal(save: { state in
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(state).count, 4_194_304)
        })
        try journal.update { $0.requests = records }
        XCTAssertLessThan(journal.snapshot.requests.count, records.count)
        XCTAssertTrue(journal.snapshot.requests.contains { $0.requestId == uncertain })
        XCTAssertFalse(AtemSessionJournal(load: { journal.snapshot }).loadFailed)
    }
}
