import XCTest
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
    var nextID: String?
    var canSend = true
    let disk: SessionDisk
    lazy var client = AtemSessionClient(context: { self.source }, send: { message, _ in
        self.sent.append(message)
        return self.canSend
    }, journal: disk.journal(), makeID: {
        defer { self.nextID = nil }
        return self.nextID ?? UUID().uuidString.lowercased()
    }, now: { self.time })

    init(disk: SessionDisk = SessionDisk()) { self.disk = disk }
    var route: RemoteTerminalConnection { source!.route }
    var target: AtemSessionTarget { AtemSessionTarget(account_id: "account-a", atem_device_id: "host-a", host_trust_gen: 1, session_id: sessionID, process_gen: processID) }

    func handshake(trust: UInt64 = 1, runtime: String = runtimeID, attachment: String = attachmentID) throws {
        if sent.isEmpty { client.start() }
        let hello = try XCTUnwrap(sent.last(where: { $0.op == "hello" }))
        var reply = AtemSessionMessage(op: "welcome")
        reply.re = hello.id
        reply.account_id = "account-a"
        reply.atem_device_id = "host-a"
        reply.host_trust_gen = trust
        reply.runtime_gen = runtime
        reply.controller_session = controllerID
        reply.attachment_gen = attachment
        reply.client_kind = "native"
        reply.permissions = ["view", "control"]
        reply.authorization_ms_left = 60_000
        reply.server_time = 1_760_500_000_000
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

    static func descriptor(state: String = "running", process: String = processID) throws -> AtemSessionDescriptor {
        let json: [String: Any] = ["session_id": sessionID, "process_gen": process, "provider": "claude", "cwd_label": "Atem",
            "state": state, "activity": "ready", "activity_since": 1_760_500_000_000,
            "controller": NSNull(), "capabilities": ["terminal-v1", "chat-v1"], "created_at": 1_760_490_000_000]
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

final class AtemSessionWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/atem-session-v1"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
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
        let packet = Data(#"{"type":"session","data":{"v":1,"op":"hello","id":"11111111-1111-4111-8111-000000000001","payload":{"\u00e9":1,"e\u0301":2}}}"#.utf8)
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

    func testSharedClientLeaseFixture() throws {
        let fixture = try fixture("late-renew-reply-does-not-resurrect-control")
        let f = SessionFixture()
        try f.ready()
        for step in try XCTUnwrap(fixture["steps"] as? [[String: Any]]) {
            if let advance = step["advance_ms"] as? Double { f.time += advance / 1000 }
            if step["send"] != nil {
                let object = try XCTUnwrap(step["json"] as? [String: Any])
                guard case .session(let message) = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)) else { return XCTFail("session") }
                f.nextID = message.id
                if message.op == "acquire" { f.client.acquire(f.target, takeover: message.takeover ?? false) }
                else if message.op == "renew" { f.client.tick() }
                else { return XCTFail("Unexpected client op") }
                XCTAssertEqual(f.sent.last?.id, message.id)
            }
            if step["deliver_to_client"] != nil {
                let object = try XCTUnwrap(step["json"] as? [String: Any])
                guard case .session(let message) = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)) else { return XCTFail("session") }
                f.client.receive(message, from: f.route)
            }
            if let expected = step["assert_client"] as? [String: Any] {
                if let controls = expected["controls"] as? Bool { XCTAssertEqual(f.client.controls(f.target), controls) }
                if let input = expected["input_enabled"] as? Bool { XCTAssertEqual(f.client.binding(for: f.target, mutation: true) != nil, input) }
                if let deadline = expected["deadline_ms"] as? Double { XCTAssertEqual(try XCTUnwrap(f.client.controlDeadline(for: f.target)) * 1000, deadline, accuracy: 0.001) }
            }
        }
    }

    func testSharedClientRegistryFixtureUsesRealWireDescriptors() throws {
        let fixture = try fixture("runtime-epoch-and-sequence-ordering")
        let f = SessionFixture()
        try f.handshake()
        for step in try XCTUnwrap(fixture["steps"] as? [[String: Any]]) {
            if step["deliver_to_client"] != nil {
                let object = try XCTUnwrap(step["json"] as? [String: Any])
                guard case .session(let message) = try AstationMessage.decodePacket(JSONSerialization.data(withJSONObject: object)) else { return XCTFail("session") }
                f.client.receive(message, from: f.route)
            }
            if let expected = step["assert_client"] as? [String: Any] {
                if let ids = expected["registry"] as? [String] { XCTAssertEqual(f.client.registry.keys.sorted(), ids.sorted()) }
                if expected["sent_list"] as? Bool == true { XCTAssertGreaterThan(f.sent.filter { $0.op == "list" }.count, 1) }
                if let states = expected["registry_state"] as? [String: String] {
                    for (id, state) in states { XCTAssertEqual(f.client.registry[id]?.state, state) }
                }
            }
        }
    }
}

final class AtemSessionClientTests: XCTestCase {
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
        XCTAssertEqual(f.client.phase, .connecting)
        XCTAssertFalse(f.client.controls(f.target))
        XCTAssertEqual(f.sent.last?.op, "hello")
        XCTAssertEqual(f.disk.state.hosts.first?.runtimeEpoch, 8, "The newer runtime is durable before the asynchronous re-handshake")
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
    func receive(_ message: RemoteTerminalMessage, bound: Bool = true) throws {
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
        try receive(.sessions([session]), bound: false)
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

    func testUnboundRepliesCannotAttachAndRegistryArrivalUnblocksViewing() throws {
        let f = SessionTerminalFixture()
        try f.protocolFixture.handshake()
        f.terminal.open(preferredTerminalId: sessionID)
        try f.receive(.sessions([f.session]), bound: false)
        XCTAssertEqual(f.terminal.phase, .ready)
        XCTAssertEqual(f.sent.count, 1)
        try f.protocolFixture.snapshot()
        XCTAssertEqual(f.terminal.phase, .attaching)
        try f.receive(.attached(f.session, streamId: "stream"), bound: false)
        XCTAssertNil(f.terminal.stream)
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
