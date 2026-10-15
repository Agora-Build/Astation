import CryptoKit
import XCTest
@testable import Menubar

private final class BrowserChatFixture {
    let host = RemoteTerminalConnection(clientId: "relay-host", connectionId: UUID().uuidString)
    var current: RemoteTerminalConnection?
    var time = Date(timeIntervalSince1970: 1_000)
    var hostMessages: [(AgentChatWire, RemoteTerminalConnection)] = []
    var browserFrames: [(BrowserChatFrame, RemoteTerminalConnection)] = []
    var sendSucceeds = true
    var sessionId = ""
    var key = SymmetricKey(size: .bits256)
    var nonce = "browser-nonce"
    var sequence: UInt64 = 0
    var link: URL!
    var browser: RemoteTerminalConnection {
        RemoteTerminalConnection(clientId: "relay-browser-\(sessionId)", connectionId: "browser-connection")
    }
    lazy var chat = BrowserAgentChat(currentRoute: { [unowned self] id in
        current?.clientId == id ? current : nil
    }, sendAgent: { [unowned self] event, route in
        hostMessages.append((event, route))
        return sendSucceeds
    }, sendBrowser: { [unowned self] frame, route in browserFrames.append((frame, route)) }, now: { [unowned self] in time })

    init(capable: Bool = true) throws {
        current = host
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: JSONSerialization.data(withJSONObject: [
            "id": "agent", "name": "Claude", "kind": "ClaudeCode", "capabilities": capable ? ["chat-v1"] : []
        ]))
        link = try chat.createLink(relayURL: "https://station.agora.build", stationId: "station", clientId: host.clientId,
                                  agent: agent, hostname: "Genie")
        let parameters = URLComponents(string: "?" + (link.fragment ?? ""))?.queryItems ?? []
        sessionId = try XCTUnwrap(parameters.first { $0.name == "session" }?.value)
        var secret = try XCTUnwrap(parameters.first { $0.name == "key" }?.value)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while secret.count % 4 != 0 { secret += "=" }
        key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: secret)))
    }

    func frame(_ body: [String: Any], nonce: String? = nil, sequence: UInt64? = nil) throws -> BrowserChatFrame {
        self.sequence += 1
        let number = sequence ?? self.sequence
        let nonce = nonce ?? self.nonce
        let body = try JSONSerialization.data(withJSONObject: body).base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: BrowserChatFrame.signingData("request", sessionId: sessionId,
            nonce: nonce, sequence: number, body: body), using: key)
        return BrowserChatFrame(sessionId: sessionId, nonce: nonce, sequence: number, body: body, mac: Data(mac).base64EncodedString())
    }

    func receive(_ body: [String: Any]) throws { chat.receive(try frame(body), from: browser) }
    func open() throws { try receive(["op": "open"]) }
    func opened(state: String = "ready") throws {
        try open()
        let request = try XCTUnwrap(hostMessages.last?.0)
        chat.receiveAgent(AgentChatWire(op: "opened", conversationId: request.conversationId, agentId: "agent",
            generation: "generation", sequence: 0,
            status: AgentChatStatus(state: state, since: .milliseconds(1_000_000))), from: host)
    }
    func event(_ op: String, sequence: UInt64, requestId: String? = nil, text: String? = nil,
               messageId: String? = nil, generation: String = "generation", source: RemoteTerminalConnection? = nil) throws {
        let conversationId = try XCTUnwrap(hostMessages.last { $0.0.op == "open" }?.0.conversationId)
        var event = AgentChatWire(op: op, conversationId: conversationId, agentId: "agent", generation: generation,
            sequence: sequence, requestId: requestId, messageId: messageId, text: op == "error" ? text : nil)
        if op == "complete" { event.turnId = "turn"; event.outcome = "done" }
        if op == "message" {
            event.role = "assistant"; event.turnId = "turn"; event.createdAt = .milliseconds(1_000_000)
            event.parts = text.map { [AgentChatPart(id: "p1", kind: "text", markdown: $0)] }
        }
        if op == "delta" { event.part = text.map { AgentChatPart(id: "p\(sequence)", kind: "text", markdown: $0) } }
        if op == "status" { event.state = text ?? "ready"; event.since = .milliseconds(1_000_000) }
        chat.receiveAgent(event, from: source ?? host)
    }
    func bodies() throws -> [[String: Any]] {
        try browserFrames.map { frame, _ in
            let mac = try XCTUnwrap(Data(base64Encoded: frame.mac))
            XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: BrowserChatFrame.signingData("response",
                sessionId: frame.sessionId, nonce: frame.nonce, sequence: frame.sequence, body: frame.body), using: key))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: frame.body))) as? [String: Any])
        }
    }
    var sentPrompts: Int { hostMessages.filter { $0.0.op == "submit" }.count }
}

final class BrowserAgentChatTests: XCTestCase {
    func testPublishedTypedHostFixtureSurvivesNativeBridgeIncludingLateParts() throws {
        struct Fixture: Decodable { let requestId: String; let events: [AgentChatWire] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "agent-chat-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let f = try BrowserChatFixture()
        try f.open()
        let conversation = try XCTUnwrap(f.hostMessages.last?.0.conversationId)
        for var event in fixture.events {
            event.conversationId = conversation
            event.agentId = "agent"
            if event.op == "accepted" {
                try f.receive(["op": "submit", "requestId": fixture.requestId, "text": "Reply with a harmless greeting"])
            }
            f.chat.receiveAgent(event, from: f.host)
        }
        let events = try f.bodies().compactMap { $0["event"] as? [String: Any] }
        XCTAssertEqual(events.count, fixture.events.count)
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertEqual(events[11]["op"] as? String, "delta", "late content after complete remains valid")
        XCTAssertEqual(try f.bodies().last?["enabled"] as? Bool, true)
    }

    func testPreSessionErrorsAndHeaderlessCloseOnlyAffectExactAuthenticatedConversation() throws {
        let f = try BrowserChatFixture()
        try f.open()
        let conversation = try XCTUnwrap(f.hostMessages.last?.0.conversationId)
        let error = AgentChatWire(op: "error", conversationId: conversation, agentId: "agent", text: "chat is unavailable")
        let count = f.browserFrames.count
        f.chat.receiveAgent(error, from: RemoteTerminalConnection(clientId: f.host.clientId, connectionId: "wrong"))
        XCTAssertEqual(f.browserFrames.count, count)
        f.chat.receiveAgent(error, from: f.host)
        XCTAssertEqual(try f.bodies().last?["notice"] as? String, "chat is unavailable")
        XCTAssertEqual(try f.bodies().last?["enabled"] as? Bool, false)
        XCTAssertEqual(try f.bodies().last?["canReopen"] as? Bool, true)

        let open = try BrowserChatFixture()
        try open.opened()
        let id = try XCTUnwrap(open.hostMessages.last?.0.conversationId)
        open.chat.receiveAgent(AgentChatWire(op: "close", conversationId: id, agentId: "agent"), from: open.host)
        try open.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Must not send"])
        XCTAssertEqual(open.sentPrompts, 0)
    }

    func testHistoryPagingUsesFreshConversationAndPinsOriginalProcessGeneration() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        try f.event("message", sequence: 1, text: "Current", messageId: "current")
        let original = try XCTUnwrap(f.hostMessages.first?.0.conversationId)
        try f.receive(["op": "history", "before": "current"])
        let request = try XCTUnwrap(f.hostMessages.last?.0)
        XCTAssertEqual(request.op, "open")
        XCTAssertEqual(request.before, "current")
        XCTAssertNotEqual(request.conversationId, original)
        let before = f.browserFrames.count
        f.chat.receiveAgent(AgentChatWire(op: "close", conversationId: original, agentId: "agent"), from: f.host)
        XCTAssertEqual(f.browserFrames.count, before, "old conversation cannot close the new view")
        f.chat.receiveAgent(AgentChatWire(op: "opened", conversationId: request.conversationId, agentId: "agent",
            generation: "restarted", sequence: 0,
            status: AgentChatStatus(state: "ready", since: .milliseconds(1_000_000))), from: f.host)
        XCTAssertTrue(try f.bodies().contains { $0["blocked"] as? Bool == true })
        XCTAssertEqual(f.sentPrompts, 0)
    }

    func testUnknownRegistryAndCapabilityDefaultsNeverClaimIdle() throws {
        for status in [nil, "Unknown", "FutureStatus", "Idle", "Thinking", "WaitingForInput", "Disconnected"] as [String?] {
            var object = ["id": "agent", "name": "Codex", "kind": "Codex"]
            object["status"] = status
            let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(agent.status, ["Idle", "Thinking", "WaitingForInput", "Disconnected"].contains(status ?? "") ? (status ?? "Unknown") : "Unknown")
            XCTAssertTrue(agent.capabilities.isEmpty)
        }
    }

    func testHostPromptRulesMatchNativeBoundary() {
        for text in ["", " ", " /resume", "\n !echo test", "bad\r", "\u{1b}[201~bad", "\u{85}", String(repeating: "a", count: 32_769)] {
            XCTAssertFalse(BrowserAgentChat.validPrompt(text))
        }
        for text in ["# hello", "line\nnext\tcolumn", "emoji \u{200d} ok", String(repeating: "a", count: 32_768)] {
            XCTAssertTrue(BrowserAgentChat.validPrompt(text))
        }
    }

    func testStatusGatesPromptsAndUnknownDeliveryCanRecoverOnlyFromHostHistory() throws {
        let f = try BrowserChatFixture()
        try f.opened(state: "unknown")
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Not ready"])
        XCTAssertEqual(f.sentPrompts, 0)
        try f.event("status", sequence: 1)
        let id = UUID().uuidString
        try f.receive(["op": "submit", "requestId": id, "text": "Maybe delivered"])
        try f.event("error", sequence: 2, requestId: id, text: "delivery unknown; check the terminal")
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Must not retry"])
        XCTAssertEqual(f.sentPrompts, 1)
        try f.receive(["op": "reopen"])
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertEqual(try f.bodies().last?["enabled"] as? Bool, false)
        let conversation = try XCTUnwrap(f.hostMessages.last?.0.conversationId)
        f.chat.receiveAgent(AgentChatWire(op: "opened", conversationId: conversation, agentId: "agent",
            generation: "generation", sequence: 0,
            status: AgentChatStatus(state: "ready", since: .milliseconds(1_000_000))), from: f.host)
        f.chat.receiveAgent(AgentChatWire(op: "message", conversationId: conversation, agentId: "agent",
            generation: "generation", sequence: 1, requestId: id, messageId: "confirmed-user",
            role: "user", origin: "remote", turnId: "turn", createdAt: .milliseconds(1_000_000),
            parts: [AgentChatPart(id: "text", kind: "text", markdown: "Maybe delivered")], history: true), from: f.host)
        XCTAssertEqual(try f.bodies().last?["deliveryUnknown"] as? Bool, false)
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "A separate new task"])
        XCTAssertEqual(f.sentPrompts, 2, "only an explicitly submitted new request is sent")
    }

    func testMACMatchesIndependentJavaScriptAndPythonVectors() throws {
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let frame = BrowserChatFrame(sessionId: "test-session", nonce: "test-nonce", sequence: 1,
            body: "eyJvcCI6Im9wZW4ifQ==", mac: "TNBvyVK7GHmiZIA5L3gZe9NzZyELeIyGC3hlntDA56Y=")
        XCTAssertEqual(frame.open(key: key)?["op"] as? String, "open")
        let signed = try XCTUnwrap(BrowserChatFrame.response(key: key, sessionId: frame.sessionId, nonce: frame.nonce,
            sequence: 1, object: ["op": "open"]))
        XCTAssertEqual(signed.mac, "xrk7NVzgDUxvcJ45X+FWsW2Rjg7xDY4xFq3v37xTNWY=")
        XCTAssertNil(signed.open(key: key), "response cannot authenticate as a request")
        let changed = BrowserChatFrame(sessionId: frame.sessionId, nonce: frame.nonce, sequence: 2, body: frame.body, mac: frame.mac)
        XCTAssertNil(changed.open(key: key))
    }

    func testLinkKeepsSecretInFragmentAndUnsupportedHostCannotReceivePrompts() throws {
        let f = try BrowserChatFixture(capable: false)
        XCTAssertEqual(f.link.path, "/agent")
        XCTAssertNil(f.link.query)
        XCTAssertTrue(f.link.fragment?.contains("key=") == true)
        try f.open()
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Hello"])
        XCTAssertTrue(f.hostMessages.isEmpty)
        let context = try XCTUnwrap(f.bodies().first)
        XCTAssertEqual(context["supported"] as? Bool, false)
        XCTAssertEqual(context["enabled"] as? Bool, false)
    }

    func testAuthenticatedBrowserIsBoundToExactSourceAndFramesCannotBeReplayed() throws {
        let f = try BrowserChatFixture()
        let open = try f.frame(["op": "open"])
        f.chat.receive(open, from: RemoteTerminalConnection(clientId: "relay-another", connectionId: "browser-connection"))
        XCTAssertTrue(f.hostMessages.isEmpty)
        f.chat.receive(open, from: f.browser)
        let count = f.browserFrames.count
        f.chat.receive(open, from: f.browser)
        XCTAssertEqual(f.browserFrames.count, count)
        XCTAssertEqual(f.hostMessages.count, 1)
        let refresh = try f.frame(["op": "refresh"])
        f.chat.receive(refresh, from: RemoteTerminalConnection(clientId: f.browser.clientId, connectionId: "replaced"))
        XCTAssertEqual(f.browserFrames.count, count)
    }

    func testReloadBindsFreshNonceReopensHistoryAndNeverReplaysPrompt() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let id = UUID().uuidString
        try f.receive(["op": "submit", "requestId": id, "text": "One prompt"])
        let newBrowser = RemoteTerminalConnection(clientId: f.browser.clientId, connectionId: "reconnected")
        let reload = try f.frame(["op": "open"], nonce: "new-nonce", sequence: 1)
        f.chat.receive(reload, from: newBrowser)
        XCTAssertEqual(f.hostMessages.filter { $0.0.op == "open" }.count, 2)
        XCTAssertEqual(f.hostMessages.filter { $0.0.op == "close" }.count, 1)
        XCTAssertNotEqual(f.hostMessages.first?.0.conversationId, f.hostMessages.last?.0.conversationId)
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertEqual(f.browserFrames.last?.0.sequence, 1)
        XCTAssertEqual(f.browserFrames.last?.1, newBrowser)
        XCTAssertEqual(try f.bodies().last?["pending"] as? Bool, true)
        let count = f.browserFrames.count
        f.chat.receive(try f.frame(["op": "open"], sequence: 1), from: f.browser)
        XCTAssertEqual(f.browserFrames.count, count, "old nonce cannot take back the route")
    }

    func testPromptDeduplicationAndMatchingCompletion() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let id = UUID().uuidString
        let prompt: [String: Any] = ["op": "submit", "requestId": id, "text": "Only once"]
        try f.receive(prompt)
        try f.receive(prompt)
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertEqual(f.hostMessages.last?.1, f.host)
        try f.event("accepted", sequence: 1, requestId: id)
        f.time.addTimeInterval(60)
        f.chat.tick()
        try f.event("complete", sequence: 2, requestId: id)
        try f.receive(prompt)
        XCTAssertEqual(f.sentPrompts, 1)
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Stale ready"])
        XCTAssertEqual(f.sentPrompts, 1)
        try f.event("status", sequence: 3)
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Next"])
        XCTAssertEqual(f.sentPrompts, 2)
    }

    func testImmediateDisconnectAndDelayedHostEventDoNotReachReplacedConnection() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let id = UUID().uuidString
        try f.receive(["op": "submit", "requestId": id, "text": "Prompt"])
        f.current = RemoteTerminalConnection(clientId: f.host.clientId, connectionId: "new-generation")
        let count = f.browserFrames.count
        try f.event("accepted", sequence: 1, requestId: id)
        XCTAssertEqual(f.browserFrames.count, count)
        f.chat.tick()
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "No fallback"])
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertTrue(try f.bodies().contains { $0["blocked"] as? Bool == true })
    }

    func testRevocationBetweenOpenAndSubmitPreventsDelivery() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        f.current = nil
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Revoked"])
        XCTAssertEqual(f.sentPrompts, 0)
    }

    func testUnacknowledgedPromptBecomesUnknownWithoutRetryAndSessionExpires() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Maybe delivered"])
        f.time.addTimeInterval(13)
        f.chat.tick()
        try f.receive(["op": "open"])
        XCTAssertEqual(f.sentPrompts, 1)
        XCTAssertTrue(try f.bodies().contains { $0["delivery"] as? String == "unknown" })
        f.time.addTimeInterval(3600)
        f.chat.tick()
        let count = f.browserFrames.count
        try f.receive(["op": "open"])
        XCTAssertEqual(f.browserFrames.count, count)
    }

    func testWrongHostAndDuplicatesIgnoredButSequenceGapStopsSending() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let count = f.browserFrames.count
        try f.event("message", sequence: 1, text: "Bad", messageId: "m", source: RemoteTerminalConnection(clientId: "other", connectionId: f.host.connectionId))
        XCTAssertEqual(f.browserFrames.count, count)
        try f.event("message", sequence: 1, text: "Good", messageId: "m")
        try f.event("message", sequence: 1, text: "Duplicate", messageId: "m")
        XCTAssertEqual(f.browserFrames.count, count + 2)
        try f.event("message", sequence: 3, text: "Gap", messageId: "m")
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Blocked"])
        XCTAssertEqual(f.sentPrompts, 0)
        XCTAssertTrue(try f.bodies().contains { $0["canReopen"] as? Bool == true && $0["enabled"] as? Bool == false })
    }

    func testChangedProcessGenerationImmediatelyBlocksExistingView() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        try f.event("status", sequence: 1, generation: "changed-process")
        try f.receive(["op": "submit", "requestId": UUID().uuidString, "text": "Must not cross processes"])
        XCTAssertEqual(f.sentPrompts, 0)
        XCTAssertTrue(try f.bodies().contains { $0["blocked"] as? Bool == true })
    }

    func testLiveTranscriptEchoDoesNotReplaceExplicitAcceptanceAcknowledgment() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let id = UUID().uuidString
        try f.receive(["op": "submit", "requestId": id, "text": "Needs both hook and transcript"])
        let conversation = try XCTUnwrap(f.hostMessages.first?.0.conversationId)
        f.chat.receiveAgent(AgentChatWire(op: "message", conversationId: conversation, agentId: "agent",
            generation: "generation", sequence: 1, requestId: id, messageId: "user",
            role: "user", origin: "remote", turnId: "turn", createdAt: .milliseconds(1_000_000),
            parts: [AgentChatPart(id: "text", kind: "text", markdown: "Needs both hook and transcript")]), from: f.host)
        f.time.addTimeInterval(13)
        f.chat.tick()
        XCTAssertEqual(try f.bodies().last?["deliveryUnknown"] as? Bool, true)
        XCTAssertEqual(f.sentPrompts, 1)
    }

    func testInvalidHostEventsAndAccumulatedRepliesFailClosed() throws {
        let malformed = try BrowserChatFixture()
        try malformed.opened()
        try malformed.event("accepted", sequence: 1)
        XCTAssertTrue(try malformed.bodies().contains { $0["blocked"] as? Bool == true })
        let f = try BrowserChatFixture()
        try f.opened()
        try f.event("message", sequence: 1, text: String(repeating: "a", count: 131_072), messageId: "m")
        try f.event("delta", sequence: 2, text: "overflow", messageId: "m")
        XCTAssertTrue(try f.bodies().contains { $0["blocked"] as? Bool == true })
    }

    func testEmptyPartMetadataIsBoundedEvenWithoutAnyContentBytes() throws {
        let f = try BrowserChatFixture()
        try f.opened()
        let conversation = try XCTUnwrap(f.hostMessages.first?.0.conversationId)
        let parts = (0..<2048).map {
            AgentChatPart(id: String(repeating: "p", count: 120) + String($0), kind: "text", markdown: "")
        }
        for index in 0..<60 {
            f.chat.receiveAgent(AgentChatWire(op: "message", conversationId: conversation, agentId: "agent",
                generation: "generation", sequence: UInt64(index + 1), messageId: "m\(index)",
                role: "assistant", turnId: "turn", createdAt: .milliseconds(1_000_000), parts: parts), from: f.host)
        }
        XCTAssertTrue(try f.bodies().contains { $0["blocked"] as? Bool == true })
        XCTAssertLessThan(try f.bodies().filter { ($0["event"] as? [String: Any])?["op"] as? String == "message" }.count, 60)
    }

    func testChatEnvelopesAndURLCapabilitiesAreRedactedFromLogs() throws {
        for text in [
            #"{"type":"agentChat","data":{"op":"message","text":"private reply"}}"#,
            #"{"atem_id":"peer","payload":{"type":"browserChat","data":{"body":"private reply","mac":"signature"}}}"#,
            #"{"type":"agentChat","data":{"text":"private reply""#
        ] {
            XCTAssertFalse(NetworkDebugLogger.sanitizedPayload(text).contains("private reply"))
        }
        let url = URL(string: "https://station.agora.build/agent/#station=id&key=private-key")!
        XCTAssertFalse(NetworkDebugLogger.sanitizeURL(url).contains("private-key"))
        XCTAssertFalse(NetworkDebugLogger.sanitizedPayload(url.absoluteString).contains("private-key"))
        XCTAssertTrue(AstationMessage.agentChat(AgentChatWire(op: "open", conversationId: "c", agentId: "a")).isPrivateAgentTraffic)
    }
}
