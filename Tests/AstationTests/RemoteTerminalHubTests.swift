import CryptoKit
import XCTest
@testable import Menubar

private final class TerminalHubSocket: IdentityRelaySocket, @unchecked Sendable {
    var sent: [[String: Any]] = []
    var closeCode = URLSessionWebSocketTask.CloseCode.invalid
    var closeReason: Data?
    private var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message,
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { sent.append(object) }
        completionHandler(nil)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) { receiver = completionHandler }
    func emit(_ object: [String: Any]) throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let callback = receiver
        receiver = nil
        callback?(.success(.string(text)))
    }
    func fail() {
        let callback = receiver
        receiver = nil
        callback?(.failure(NSError(domain: NSPOSIXErrorDomain, code: 54)))
    }
}

private final class TerminalIdentityStorage: AtemIdentityStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data, creating: Bool) throws { self.data = data }
}

@MainActor
private final class TerminalHubFixture {
    let socket = TerminalHubSocket()
    let directory: URL
    let defaults: UserDefaults
    let suite = "Astation.terminal-hub.\(UUID().uuidString)"
    let hub: AstationHubManager
    var session: SessionInfo
    let deviceId = "selected-host"
    var generation = UUID().uuidString
    var clientId: String { "relay-" + deviceId }
    var terminalFrames: [[String: Any]] {
        socket.sent.filter { ($0["payload"] as? [String: Any])?["type"] as? String == "terminal" }
    }
    var challenges: [String] {
        socket.sent.compactMap { object in
            guard let payload = object["payload"] as? [String: Any],
                  let data = payload["data"] as? [String: Any], data["status"] as? String == "auth_required"
            else { return nil }
            return (data["data"] as? [String: String])?["challenge"]
        }
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        session = sessions.create(hostname: "Host", atemId: deviceId)
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let manager = RelayIdentityKeyManager(loadKey: { _ in key }, perform: { $0() }, deliver: { $0() }, schedule: { _, _ in })
        let socket = self.socket
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            relayIdentityKeyManager: manager, relayIdentityRepairDefaults: defaults,
            atemE2EIdentity: AtemE2EIdentity(storage: TerminalIdentityStorage()), makeIdentityRelayTask: { _ in socket })
    }

    func drain() async {
        for _ in 0..<4 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    }

    func start() async throws {
        hub.startIdentityRelay()
        try socket.emit(["type": "relayAuthResult", "status": "verified"])
        await drain()
    }

    func authenticate() async throws {
        try emit(.statusUpdate(status: "hello", data: ["hostname": "Host"]))
        await drain()
        try await prove(challenge: XCTUnwrap(challenges.last))
    }

    func prove(challenge: String) async throws {
        let proof = DeviceAuthentication.proof(token: session.token, challenge: challenge,
            astationId: AstationIdentity.shared.id, atemId: deviceId, sessionId: session.id)
        try emit(.statusUpdate(status: "auth", data: ["atem_id": deviceId, "session_id": session.id, "proof": proof]))
        await drain()
    }

    func emit(_ message: AstationMessage) throws {
        try socket.emit(["atem_id": deviceId, "connection_id": generation,
            "payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(message))])
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class RemoteTerminalHubTests: XCTestCase {
    func testDelayedAgentListCannotRestoreCapabilitiesAfterPairingRevocation() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: Data(
            #"{"id":"agent","name":"Claude","kind":"ClaudeCode","status":"Unknown","capabilities":["chat-v1"]}"#.utf8))
        _ = f.hub.handleMessage(.agentListResponse(agents: [agent]), from: f.clientId, relayConnectionId: f.generation)
        f.hub.deviceSessionStore.delete(sessionId: f.session.id)
        await f.drain()
        XCTAssertNil(f.hub.agentsByClientId[f.clientId])
    }

    func testBrowserChatUsesScopedUnpairedBridgeAndAuthenticatedHostGeneration() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: Data(
            #"{"id":"agent","name":"Claude","kind":"ClaudeCode","capabilities":["chat-v1"]}"#.utf8))
        let link = try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent)
        let parameters = URLComponents(string: "?" + (link.fragment ?? ""))?.queryItems ?? []
        let id = try XCTUnwrap(parameters.first { $0.name == "session" }?.value)
        var raw = try XCTUnwrap(parameters.first { $0.name == "key" }?.value)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: raw)))
        let browserId = "browser-" + id
        let connection = UUID().uuidString
        let challenges = f.challenges
        try f.socket.emit(["atem_id": browserId, "connection_id": connection, "relay_event": "connected"])
        try f.socket.emit(["atem_id": browserId, "connection_id": connection,
            "payload": ["type": "statusUpdate", "data": ["status": "hello", "data": ["hostname": "Untrusted"]]]])
        await f.drain()
        XCTAssertEqual(f.challenges, challenges)
        XCTAssertFalse(f.hub.connectedClients.contains { $0.id == "relay-" + browserId })

        let body = Data(#"{"op":"open"}"#.utf8).base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: BrowserChatFrame.signingData("request", sessionId: id,
            nonce: "nonce", sequence: 1, body: body), using: key)
        let frame = BrowserChatFrame(sessionId: id, nonce: "nonce", sequence: 1, body: body, mac: Data(mac).base64EncodedString())
        try f.socket.emit(["atem_id": browserId, "connection_id": connection,
            "payload": JSONSerialization.jsonObject(with: JSONEncoder().encode(AstationMessage.browserChat(frame)))])
        await f.drain()
        let forwarded = try XCTUnwrap(f.socket.sent.last {
            ($0["payload"] as? [String: Any])?["type"] as? String == "agentChat"
        })
        XCTAssertEqual(forwarded["atem_id"] as? String, f.deviceId)
        XCTAssertEqual(forwarded["connection_id"] as? String, f.generation)
        let payload = try XCTUnwrap(forwarded["payload"] as? [String: Any])
        let request = try JSONDecoder().decode(AstationMessage.self, from: JSONSerialization.data(withJSONObject: payload))
        let before = f.socket.sent.count
        f.hub.broadcastToAuthenticatedIdentityRelayClients(request)
        XCTAssertEqual(f.socket.sent.count, before, "chat must never broadcast to other devices")
        guard case .agentChat(let open) = request else { return XCTFail("expected chat open") }
        let browserFramesBeforeRevocation = f.socket.sent.filter {
            ($0["payload"] as? [String: Any])?["type"] as? String == "browserChat"
        }.count
        let event = AgentChatWire(op: "opened", conversationId: open.conversationId, agentId: "agent",
                                  generation: "process", sequence: 0)
        try f.emit(.agentChat(event))
        f.hub.deviceSessionStore.delete(sessionId: f.session.id)
        await f.drain()
        XCTAssertEqual(f.socket.sent.filter {
            ($0["payload"] as? [String: Any])?["type"] as? String == "browserChat"
        }.count, browserFramesBeforeRevocation, "revocation before delayed dispatch drops the host event")
    }

    func testRestoredRelayConnectionRequestsProofWithoutHelloAndRacingHelloKeepsProofValid() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "connected"])
        await f.drain()
        let challenge = try XCTUnwrap(f.challenges.last)
        XCTAssertTrue(f.hub.connectedClients.isEmpty)
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        try f.emit(.statusUpdate(status: "hello", data: ["hostname": "Host"]))
        await f.drain()
        XCTAssertEqual(f.challenges, [challenge, challenge])
        try await f.prove(challenge: challenge)
        XCTAssertNotNil(f.hub.terminalConnection(for: f.clientId))
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "connected"])
        await f.drain()
        XCTAssertEqual(f.challenges.count, 2)
        XCTAssertNotNil(f.hub.terminalConnection(for: f.clientId))
    }

    func testAstationOnlyReconnectRequiresFreshProofForUnchangedAtemSocket() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let oldRoute = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        let oldChallenge = try XCTUnwrap(f.challenges.last)
        f.socket.fail()
        await f.drain()
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        try await f.start()
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "connected"])
        await f.drain()
        let newChallenge = try XCTUnwrap(f.challenges.last)
        XCTAssertNotEqual(newChallenge, oldChallenge)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: oldRoute))
        try await f.prove(challenge: oldChallenge)
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        try await f.prove(challenge: newChallenge)
        XCTAssertNotNil(f.hub.terminalConnection(for: f.clientId))
    }

    func testRelayTerminalRequiresEndpointAuthenticationAndTargetsCurrentGeneration() async throws {
        let f = try TerminalHubFixture()
        var received: [RemoteTerminalConnection] = []
        f.hub.terminalMessageHandler = { _, route in received.append(route) }
        try await f.start()
        try f.emit(.terminal(.sessions([])))
        await f.drain()
        XCTAssertTrue(received.isEmpty)
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        try await f.authenticate()
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        XCTAssertEqual(route.connectionId, f.generation)
        XCTAssertTrue(f.hub.sendTerminalMessage(.list, to: route))
        XCTAssertEqual(f.terminalFrames.count, 1)
        XCTAssertEqual(f.terminalFrames[0]["atem_id"] as? String, f.deviceId)
        XCTAssertEqual(f.terminalFrames[0]["connection_id"] as? String, f.generation)
        try f.emit(.terminal(.sessions([])))
        await f.drain()
        XCTAssertEqual(received, [route])
        f.hub.broadcastToAuthenticatedIdentityRelayClients(.terminal(.list))
        XCTAssertEqual(f.terminalFrames.count, 1)
    }

    func testDisconnectBeforeDelayedDispatchDropsAcceptedTerminalFrame() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        var delivered = 0
        f.hub.terminalMessageHandler = { _, _ in delivered += 1 }
        let old = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        try f.emit(.terminal(.sessions([])))
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "disconnected"])
        await f.drain()
        XCTAssertEqual(delivered, 0)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: old))
        f.generation = UUID().uuidString
        try await f.authenticate()
        let current = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        XCTAssertNotEqual(current, old)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: old))
        XCTAssertTrue(f.hub.sendTerminalMessage(.list, to: current))
        XCTAssertEqual(f.terminalFrames.last?["connection_id"] as? String, f.generation)
    }

    func testRevokedPairingCannotKeepSendingOrReceivingThroughLiveRelay() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        var delivered = 0
        f.hub.terminalMessageHandler = { _, _ in delivered += 1 }
        try f.emit(.terminal(.sessions([])))
        f.hub.deviceSessionStore.delete(sessionId: f.session.id)
        await f.drain()
        XCTAssertEqual(delivered, 0)
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: route))
        XCTAssertTrue(f.terminalFrames.isEmpty)
    }

    func testLANReconnectStaysBoundToSameDeviceAndTransport() throws {
        let f = try TerminalHubFixture()
        f.hub.connectedClients = [ConnectedClient(id: "direct-old", clientType: "Atem", connectedAt: Date(),
            hostname: "Host", atemId: f.deviceId, authenticationSessionId: f.session.id)]
        let old = try XCTUnwrap(f.hub.terminalConnection(for: "direct-old", atemId: f.deviceId))
        f.hub.connectedClients = [ConnectedClient(id: "direct-new", clientType: "Atem", connectedAt: Date(),
            hostname: "Host", atemId: f.deviceId, authenticationSessionId: f.session.id)]
        let new = try XCTUnwrap(f.hub.terminalConnection(for: "direct-old", atemId: f.deviceId))
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(new.clientId, "direct-new")
        XCTAssertNil(f.hub.terminalConnection(for: "direct-old", atemId: "different-device"))
        XCTAssertNil(f.hub.terminalConnection(for: "relay-old", atemId: f.deviceId))
    }
}
