import XCTest
@testable import Menubar

final class RemoteTerminalWireTests: XCTestCase {
    private let stream = RemoteTerminalStream(terminalId: "claude", generation: "process", streamId: "stream")

    func testSerdeWireMessagesRoundTripWithoutRenamingFields() throws {
        let session = terminalSession()
        let messages: [RemoteTerminalMessage] = [
            .list, .sessions([session]), .subscribe(terminalId: "claude", generation: "process"),
            .unsubscribe(stream), .ack(stream, offset: 4096), .control(stream, take: true),
            .input(stream, leaseId: "lease", sequence: 0, bytes: "aGVsbG8N"),
            .resize(stream, leaseId: "lease", rows: 40, cols: 120), .stop(stream, leaseId: "lease"),
            .attached(session, streamId: "stream"),
            .frame(RemoteTerminalFrame(stream: stream, offset: 0, bytes: "aGVsbG8N", reset: true,
                                      complete: true, rows: 40, cols: 120)),
            .controller(stream, leaseId: "lease"), .controller(stream, leaseId: nil),
            .written(stream, sequence: 0, error: nil), .written(stream, sequence: 1, error: "revoked"),
            .exited(terminalId: "claude", generation: "process", status: "0"), .error(terminalId: nil, message: "failure")
        ]
        for message in messages {
            let encoded = try JSONEncoder().encode(AstationMessage.terminal(message))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "terminal")
            let data = try XCTUnwrap(object["data"] as? [String: Any])
            XCTAssertEqual(data["v"] as? Int, 1)
            XCTAssertNil(data["terminalId"])
            XCTAssertNil(data["streamId"])
            guard case .terminal(let decoded) = try JSONDecoder().decode(AstationMessage.self, from: encoded) else {
                return XCTFail("Not a terminal envelope")
            }
            XCTAssertEqual(decoded, message)
        }
    }

    func testHostFixturesDecodeAndUnsupportedVersionsFailClosed() throws {
        let attached = Data(#"{"type":"terminal","data":{"v":1,"op":"attached","session":{"terminal_id":"claude","generation":"process","provider":"claude","rows":40,"cols":120,"exit_status":null,"rendering":"vt100-screen-diff","width_profile":"atem-unicode-width-0.1.14"},"stream_id":"stream"}}"#.utf8)
        guard case .terminal(.attached(let session, let id)) = try JSONDecoder().decode(AstationMessage.self, from: attached) else {
            return XCTFail("Host fixture did not decode")
        }
        XCTAssertEqual(session, terminalSession())
        XCTAssertEqual(id, "stream")
        let unsupported = try JSONDecoder().decode(RemoteTerminalMessage.self, from: Data(#"{"v":2,"op":"frame"}"#.utf8))
        XCTAssertEqual(unsupported, .unsupported(version: 2, operation: "frame"))
        XCTAssertThrowsError(try JSONEncoder().encode(unsupported))
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteTerminalMessage.self, from: Data(#"{"v":1,"op":"input","bytes":"eA=="}"#.utf8)))
    }

    func testTerminalContentIsRedactedIncludingRelayEnvelope() {
        for payload in [
            #"{"type":"terminal","data":{"v":1,"op":"frame","bytes":"private-base64-output","message":"private-text","lease_id":"private-lease"}}"#,
            #"{"atem_id":"host","connection_id":"connection","payload":{"type":"terminal","data":{"v":1,"op":"input","bytes":"private-input"}}}"#,
            #"{"type":"terminal","data":{"op":"frame","bytes":"private-truncated"#,
            #"{"payload":{"type": "terminal","data":{"bytes":"private-truncated"#
        ] {
            let result = NetworkDebugLogger.sanitizedPayload(payload)
            XCTAssertFalse(result.contains("private"))
            XCTAssertTrue(result.contains("terminal"))
            XCTAssertTrue(result.contains("redacted"))
        }
    }
}

final class RemoteTerminalControllerTests: XCTestCase {
    func testOpenTargetsOnlySelectedConnectionAndStartsViewOnly() {
        let f = TerminalFixture()
        f.open()
        XCTAssertEqual(f.sent.map(\.1), [f.route])
        XCTAssertEqual(f.sent.first?.0, .list)
        f.list()
        XCTAssertEqual(f.sent.last?.0, .subscribe(terminalId: "claude", generation: "process"))
        f.attach()
        f.controller.input(Data("should not send".utf8))
        f.controller.takeControl()
        XCTAssertFalse(f.sent.contains { if case .input = $0.0 { return true }; return false })
        XCTAssertFalse(f.sent.contains { if case .control = $0.0 { return true }; return false })
        f.frame()
        XCTAssertEqual(f.controller.phase, .restoring)
        XCTAssertEqual(f.acks.count, 0)
        f.consume()
        XCTAssertEqual(f.controller.phase, .viewing)
        XCTAssertTrue(f.controller.canTakeControl)
        XCTAssertFalse(f.controller.canInput)
        XCTAssertEqual(f.acks, [1])
    }

    func testFrameCreditWaitsForRendererAndPreservesSplitUTF8() {
        let f = TerminalFixture()
        f.start()
        let first = Data([0xf0, 0x9f])
        let second = Data([0x8c, 0x9f])
        f.frame(bytes: first, offset: 0, complete: false)
        f.frame(bytes: second, offset: 2, reset: false)
        XCTAssertEqual(f.rendered.count, 1)
        XCTAssertEqual(f.controller.queuedBytes, 4)
        f.consume()
        XCTAssertEqual(f.acks, [2])
        XCTAssertEqual(f.rendered.count, 2)
        XCTAssertEqual(Data(base64Encoded: f.rendered[0].0.bytes), first)
        XCTAssertEqual(Data(base64Encoded: f.rendered[1].0.bytes), second)
        XCTAssertEqual(f.controller.phase, .restoring)
        f.consume()
        XCTAssertEqual(f.acks, [2, 4])
        XCTAssertEqual(f.controller.phase, .viewing)
        XCTAssertEqual(f.controller.queuedBytes, 0)
    }

    func testGapsMalformedFramesAndMissingSnapshotRequireFreshView() {
        for invalid in [
            RemoteTerminalFrame(stream: terminalStream(), offset: 1, bytes: "eA==", reset: true, complete: true, rows: 40, cols: 120),
            RemoteTerminalFrame(stream: terminalStream(), offset: 0, bytes: "eA==", reset: false, complete: true, rows: 40, cols: 120),
            RemoteTerminalFrame(stream: terminalStream(), offset: 0, bytes: "not-base64", reset: true, complete: true, rows: 40, cols: 120),
            RemoteTerminalFrame(stream: terminalStream(), offset: 0, bytes: "", reset: true, complete: true, rows: 40, cols: 120),
            RemoteTerminalFrame(stream: terminalStream(), offset: 0, bytes: "eA==", reset: true, complete: true, rows: 1, cols: 120)
        ] {
            let f = TerminalFixture()
            f.start()
            f.receive(.frame(invalid))
            XCTAssertEqual(f.controller.phase, .failed)
            XCTAssertTrue(f.rendered.isEmpty)
            XCTAssertEqual(f.sent.last?.0, .unsubscribe(terminalStream()))
        }
    }

    func testSlowRendererCannotExceedHostCreditWindow() {
        let f = TerminalFixture()
        f.start()
        let bytes = Data(repeating: 65, count: 16 * 1024)
        for index in 0..<8 { f.frame(bytes: bytes, offset: UInt64(index * bytes.count), reset: index == 0, complete: false) }
        XCTAssertEqual(f.controller.queuedBytes, 128 * 1024)
        XCTAssertEqual(f.rendered.count, 1)
        f.frame(bytes: bytes, offset: 128 * 1024, reset: false)
        XCTAssertEqual(f.controller.phase, .failed)
        XCTAssertEqual(f.controller.queuedBytes, 0)
        XCTAssertTrue(f.acks.isEmpty)
    }

    func testControlLeaseAndWrittenAcknowledgmentHaveSeparateMeaning() {
        let f = TerminalFixture()
        f.viewing()
        f.controller.takeControl()
        XCTAssertFalse(f.controller.canInput)
        f.receive(.controller(terminalStream(), leaseId: "lease"))
        let bytes = Data(" hello\r\n\u{1b}[A\u{3}".utf8)
        f.controller.input(bytes)
        XCTAssertEqual(f.sent.last?.0, .input(terminalStream(), leaseId: "lease", sequence: 0, bytes: bytes.base64EncodedString()))
        XCTAssertEqual(f.controller.pendingWrites.count, 1)
        f.receive(.written(terminalStream(), sequence: 0, error: nil))
        XCTAssertTrue(f.controller.pendingWrites.isEmpty)
        XCTAssertTrue(f.controller.status.contains("Written to terminal"))
        XCTAssertFalse(f.controller.status.contains("completed"))
        f.receive(.written(terminalStream(), sequence: 0, error: nil))
        XCTAssertTrue(f.controller.canInput)
    }

    func testReleaseAndLocalReclaimDisableInputAndDoNotResetSequence() {
        let f = TerminalFixture()
        f.controlling()
        f.controller.input(Data("first".utf8))
        f.receive(.written(terminalStream(), sequence: 0, error: nil))
        f.controller.release()
        XCTAssertFalse(f.controller.canInput)
        let before = f.sent.count
        f.controller.input(Data("discard".utf8))
        XCTAssertEqual(f.sent.count, before)
        f.receive(.controller(terminalStream(), leaseId: "late-lease"))
        XCTAssertFalse(f.controller.canInput)
        XCTAssertEqual(f.sent.last?.0, .control(terminalStream(), take: false))
        f.controller.takeControl()
        f.receive(.controller(terminalStream(), leaseId: "new-lease"))
        f.controller.input(Data("second".utf8))
        XCTAssertEqual(f.controller.nextSequence, 2)
        f.receive(.controller(terminalStream(), leaseId: nil))
        XCTAssertFalse(f.controller.canInput)
        XCTAssertEqual(f.controller.phase, .viewing)
    }

    func testDisconnectAndReconnectNeverRestoreControlOrReplayInput() {
        let f = TerminalFixture()
        f.controlling()
        f.controller.input(Data("uncertain".utf8))
        let oldRenderToken = f.rendered.last!.1
        f.current = nil
        f.controller.connectionChanged()
        XCTAssertEqual(f.controller.phase, .offline)
        XCTAssertTrue(f.controller.status.contains("unknown"))
        f.current = RemoteTerminalConnection(clientId: "relay-selected", connectionId: "connection-2")
        f.controller.connectionChanged()
        let newRoute = f.current!
        f.controller.receive(.controller(terminalStream(), leaseId: "old-lease"), from: f.route)
        f.controller.consumed(oldRenderToken)
        f.controller.receive(.sessions([terminalSession()]), from: newRoute)
        f.controller.receive(.attached(terminalSession(), streamId: "stream-2"), from: newRoute)
        let newStream = terminalStream(id: "stream-2")
        f.controller.receive(.frame(RemoteTerminalFrame(stream: newStream, offset: 0, bytes: "eA==", reset: true,
            complete: true, rows: 40, cols: 120)), from: newRoute)
        f.consume()
        XCTAssertEqual(f.controller.phase, .viewing)
        XCTAssertFalse(f.controller.canInput)
        XCTAssertEqual(f.sent.filter { if case .input = $0.0 { return true }; return false }.count, 1)
        XCTAssertEqual(f.sent.filter { if case .control(_, true) = $0.0 { return true }; return false }.count, 1)
    }

    func testStaleHostProcessStreamAndRendererCallbacksAreIgnored() {
        let f = TerminalFixture()
        f.start()
        let wrong = RemoteTerminalConnection(clientId: "another-host", connectionId: "connection")
        f.controller.receive(.error(terminalId: nil, message: "wrong host"), from: wrong)
        f.receive(.frame(RemoteTerminalFrame(stream: terminalStream(id: "old-stream"), offset: 0, bytes: "eA==",
            reset: true, complete: true, rows: 40, cols: 120)))
        f.receive(.controller(terminalStream(id: "old-stream"), leaseId: "old"))
        f.receive(.exited(terminalId: "claude", generation: "old-process", status: "0"))
        f.frame()
        let token = f.rendered.last!.1
        f.controller.view()
        f.controller.consumed(token)
        XCTAssertTrue(f.acks.isEmpty)
        XCTAssertEqual(f.controller.phase, .attaching)
    }

    func testProcessReplacementAfterReconnectRequiresDeliberateView() {
        let f = TerminalFixture()
        f.viewing()
        f.current = nil
        f.controller.connectionChanged()
        f.current = f.route
        f.controller.connectionChanged()
        f.receive(.sessions([terminalSession(generation: "replacement")]))
        XCTAssertEqual(f.controller.phase, .ready)
        XCTAssertTrue(f.controller.status.contains("restarted"))
        XCTAssertEqual(f.sent.filter { if case .subscribe = $0.0 { return true }; return false }.count, 1)
    }

    func testLateAttachAfterWindowCloseIsUnsubscribed() {
        let f = TerminalFixture()
        f.open()
        f.list()
        f.controller.close()
        f.attach()
        XCTAssertEqual(f.controller.phase, .closed)
        XCTAssertEqual(f.sent.last?.0, .unsubscribe(terminalStream()))
    }

    func testCloseAndReopenBeforeAttachDoesNotUnsubscribeSuccessor() {
        let f = TerminalFixture()
        f.open()
        f.list()
        f.controller.close()
        f.open()
        f.list()
        f.attach()
        XCTAssertEqual(f.controller.phase, .attaching)
        f.receive(.attached(terminalSession(), streamId: "stream-2"))
        XCTAssertEqual(f.controller.stream, terminalStream(id: "stream-2"))
        XCTAssertFalse(f.sent.contains { if case .unsubscribe = $0.0 { return true }; return false })
    }

    func testPasteLimitAndTimeoutNeverRetryAnUnknownWrite() {
        let f = TerminalFixture()
        f.controlling()
        let before = f.sent.count
        f.controller.input(Data(repeating: 65, count: 16 * 1024 + 1))
        XCTAssertEqual(f.sent.count, before)
        XCTAssertTrue(f.controller.status.contains("nothing was sent"))
        f.controller.input(Data("single send".utf8))
        f.time += 11
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.phase, .failed)
        XCTAssertTrue(f.controller.status.contains("unknown"))
        f.controller.checkTimeouts()
        XCTAssertEqual(f.sent.filter { if case .input = $0.0 { return true }; return false }.count, 1)
    }

    func testUnsupportedHostAndRestoreTimeoutAreVisible() {
        let f = TerminalFixture()
        f.open()
        f.time += 9
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.phase, .failed)
        XCTAssertTrue(f.controller.status.contains("update Atem"))
        f.controller.refresh(autoView: true)
        f.list()
        f.attach()
        f.time += 16
        f.controller.checkTimeouts()
        XCTAssertEqual(f.controller.phase, .failed)
        XCTAssertEqual(f.sent.last?.0, .unsubscribe(terminalStream()))
    }

    func testResizeAndStopRequireControlAndExitKeepsFinalScreen() {
        let f = TerminalFixture()
        f.viewing()
        f.controller.resize(rows: 30, cols: 100)
        f.controller.stop()
        XCTAssertFalse(f.sent.contains { if case .resize = $0.0 { return true }; return false })
        f.controller.takeControl()
        f.receive(.controller(terminalStream(), leaseId: "lease"))
        XCTAssertEqual(f.sent.last?.0, .resize(terminalStream(), leaseId: "lease", rows: 30, cols: 100))
        f.controller.stop()
        XCTAssertEqual(f.controller.phase, .stopping)
        XCTAssertFalse(f.controller.canInput)
        f.frame(offset: 1, reset: false)
        f.consume()
        f.receive(.exited(terminalId: "claude", generation: "process", status: "exit 0"))
        XCTAssertEqual(f.controller.phase, .exited)
        XCTAssertNotNil(f.controller.stream)
        XCTAssertFalse(f.controller.canTakeControl)
        XCTAssertEqual(f.acks, [1, 2])
    }
}

private func terminalSession(generation: String = "process") -> RemoteTerminalSession {
    RemoteTerminalSession(terminalId: "claude", generation: generation, provider: "claude", rows: 40, cols: 120,
                          exitStatus: nil, rendering: "vt100-screen-diff", widthProfile: "atem-unicode-width-0.1.14")
}

private func terminalStream(id: String = "stream") -> RemoteTerminalStream {
    RemoteTerminalStream(terminalId: "claude", generation: "process", streamId: id)
}

private final class TerminalFixture {
    let route = RemoteTerminalConnection(clientId: "relay-selected", connectionId: "connection")
    var current: RemoteTerminalConnection?
    var sent: [(RemoteTerminalMessage, RemoteTerminalConnection)] = []
    var rendered: [(RemoteTerminalFrame, String)] = []
    var time: TimeInterval = 0
    lazy var controller = RemoteTerminalController(currentConnection: { self.current }, send: { message, connection in
        self.sent.append((message, connection)); return true
    }, now: { self.time })

    init() { current = route }
    var acks: [UInt64] { sent.compactMap { if case .ack(_, let offset) = $0.0 { return offset }; return nil } }
    func open() {
        controller.render = { self.rendered.append(($0, $1)) }
        controller.open(preferredTerminalId: "claude")
    }
    func list() { receive(.sessions([terminalSession()])) }
    func attach() { receive(.attached(terminalSession(), streamId: "stream")) }
    func start() { open(); list(); attach() }
    func viewing() { start(); frame(); consume() }
    func controlling() { viewing(); controller.takeControl(); receive(.controller(terminalStream(), leaseId: "lease")) }
    func receive(_ message: RemoteTerminalMessage) { controller.receive(message, from: route) }
    func frame(bytes: Data = Data("x".utf8), offset: UInt64 = 0, reset: Bool = true, complete: Bool = true) {
        receive(.frame(RemoteTerminalFrame(stream: terminalStream(), offset: offset, bytes: bytes.base64EncodedString(),
            reset: reset, complete: complete, rows: 40, cols: 120)))
    }
    func consume() { if let token = rendered.last?.1 { controller.consumed(token) } }
}
