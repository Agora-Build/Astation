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

@MainActor
private final class TerminalHubFixture {
    let socket = TerminalHubSocket()
    let directory: URL
    let defaults: UserDefaults
    let suite = "Astation.terminal-hub.\(UUID().uuidString)"
    let hub: AstationHubManager
    let identity: AtemE2EIdentity
    let identityStorage = TestAtemStorage()
    let deviceSigning = Curve25519.Signing.PrivateKey()
    let unlockSigning = Curve25519.Signing.PrivateKey()
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

    init(verified: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        session = sessions.create(hostname: "Host", atemId: deviceId)
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let manager = RelayIdentityKeyManager(loadKey: { _ in key }, perform: { $0() }, deliver: { $0() }, schedule: { _, _ in })
        let socket = self.socket
        identity = AtemE2EIdentity(storage: identityStorage, crypto: TestAtemCryptography())
        if verified {
            let keys = try identity.verificationKeys(nonce: Data(repeating: 1, count: 32))
            try identity.markRecoverySaved(signingPublicKey: keys.signPub)
            _ = try identity.completeVerification(account: AstationIdentity.shared.id, deviceId: deviceId,
                reveal: AtemVerifyReveal(devicePub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                    deviceSignPub: deviceSigning.publicKey.rawRepresentation,
                    unlockAuthPub: unlockSigning.publicKey.rawRepresentation,
                    nonce: Data(repeating: 2, count: 32)),
                transcript: Data(repeating: 3, count: 32), expectedSigningKey: keys.signPub, key: nil)
        }
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            relayIdentityKeyManager: manager, relayIdentityRepairDefaults: defaults,
            atemE2EIdentity: identity, makeIdentityRelayTask: { _ in socket })
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

    func revokeVerification() throws {
        let account = AstationIdentity.shared.id
        let keys = try identity.verificationKeys(nonce: Data(repeating: 4, count: 32))
        let sealed = try AtemE2ECrypto.sealKey(Data(repeating: 5, count: 32), to: keys.encPub,
            info: AtemStatements.storageKeyInfo(account: account, deviceId: deviceId, kid: "01020304"))
        let rotate = try AtemStatements.storageRotate(account: account, deviceId: deviceId, oldKid: "", newKid: "01020304",
            sealedHash: AtemE2ECrypto.sealedKeyDigest(sealed))
        _ = try identity.rotateStorageKey(AtemStorageRotateWire(
            rotate: AtemSignedWire(statement: rotate, signature: try deviceSigning.signature(for: rotate)),
            encappedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext), account: account, deviceId: deviceId)
        let request = try AtemStatements.unlockRequest(account: account, deviceId: deviceId, bootId: "test-boot", ticket: "",
            ephemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            nonce: Data(repeating: 6, count: 32), time: UInt64(Date().timeIntervalSince1970), storageKid: "01020304")
        let authorization = try identity.prepareUnlock(AtemUnlockRequestWire(request: request,
            signature: try unlockSigning.signature(for: request)), account: account, deviceId: deviceId, now: Date())
        try identity.revokeDevice(authorization)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class RemoteTerminalHubTests: XCTestCase {
    func testDelayedSessionMessagesRecheckPairingAndVerificationBeforeDispatch() async throws {
        for revokeIdentity in [false, true] {
            let f = try TerminalHubFixture()
            try await f.start(); try await f.authenticate()
            var delivered = 0
            f.hub.sessionMessageHandler = { _, _ in delivered += 1 }
            _ = f.hub.handleMessage(.session(AtemSessionMessage(op: "list")), from: f.clientId, relayConnectionId: f.generation)
            if revokeIdentity { try f.revokeVerification() }
            else { f.hub.deviceSessionStore.delete(sessionId: f.session.id) }
            await f.drain()
            XCTAssertEqual(delivered, 0)
        }
    }

    func testSessionDispatchPinsAuthenticatedGenerationAndRejectsReconnectRace() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        var routes: [RemoteTerminalConnection] = []
        f.hub.sessionMessageHandler = { _, route in routes.append(route) }
        let old = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        _ = f.hub.handleMessage(.session(AtemSessionMessage(op: "list")), from: f.clientId, relayConnectionId: "spoofed")
        await f.drain()
        XCTAssertTrue(routes.isEmpty)
        _ = f.hub.handleMessage(.session(AtemSessionMessage(op: "list")), from: f.clientId, relayConnectionId: f.generation)
        f.socket.fail()
        await f.drain()
        // A message delivered before disconnect is harmless; no later work can
        // inherit the replacement connection's identity or authorization.
        XCTAssertTrue(routes.allSatisfy { $0 == old.route })
        f.generation = UUID().uuidString
        try await f.start(); try await f.authenticate()
        let current = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        XCTAssertNotEqual(old.route, current.route)
        XCTAssertFalse(f.hub.sendSessionMessage(AtemSessionMessage(op: "hello"), to: old.route))
        _ = f.hub.handleMessage(.session(AtemSessionMessage(op: "list")), from: f.clientId, relayConnectionId: old.route.connectionId)
        await f.drain()
        XCTAssertFalse(routes.contains(current.route))
    }

    func testStartingSessionHandshakeBlocksLegacyBrowserWithoutWaitingForWelcome() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: Data(
            #"{"id":"agent","name":"Claude","kind":"ClaudeCode","capabilities":["chat-v1"]}"#.utf8))
        XCTAssertNoThrow(try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent))
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        XCTAssertTrue(f.hub.sendSessionMessage(AtemSessionMessage(op: "hello"), to: route))
        XCTAssertThrowsError(try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent)) {
            XCTAssertTrue($0.localizedDescription.contains("secure companion"))
        }
        XCTAssertTrue(f.hub.sendSessionMessage(AtemSessionMessage(op: "list"), to: route))
        f.generation = UUID().uuidString
        try await f.authenticate()
        XCTAssertNoThrow(try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent), "The gate is scoped to the exact socket, not a relay presence label")
    }

    func testVerificationRevocationFencesDelayedFramesAndReconnectedSessionTokens() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        var delivered = false
        f.hub.terminalMessageHandler = { _, _ in delivered = true }
        try f.emit(.terminal(.sessions([])))
        try f.revokeVerification()
        await f.drain()
        XCTAssertFalse(delivered)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: route))
        XCTAssertEqual(f.hub.remoteAccessBlockReason(for: f.clientId), .verificationRequired)
        f.generation = UUID().uuidString
        try await f.authenticate()
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId), "a valid session token does not restore revoked safety-code verification")
    }

    func testAuthenticatedButUnverifiedHostCannotReadOrControlRemotely() async throws {
        let f = try TerminalHubFixture(verified: false)
        try await f.start()
        try await f.authenticate()
        XCTAssertNil(f.hub.terminalConnection(for: f.clientId))
        XCTAssertEqual(f.hub.remoteAccessBlockReason(for: f.clientId), .verificationRequired)
        var delivered = false
        f.hub.terminalMessageHandler = { _, _ in delivered = true }
        try f.emit(.terminal(.sessions([])))
        let before = f.socket.sent.count
        f.hub.sendAgentText("private prompt", clientId: f.clientId)
        f.hub.sendAgentKey("ctrl-c", clientId: f.clientId)
        f.hub.requestAgentList(from: f.clientId)
        await f.drain()
        XCTAssertFalse(delivered)
        XCTAssertEqual(f.socket.sent.count, before)
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: Data(
            #"{"id":"agent","name":"Claude","kind":"ClaudeCode","capabilities":["chat-v1"]}"#.utf8))
        XCTAssertThrowsError(try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent)) {
            XCTAssertEqual($0 as? RemoteAccessBlockReason, .verificationRequired)
        }
    }

    func testUnreadableVerifiedIdentityImmediatelyBlocksExistingRemoteRoute() async throws {
        let f = try TerminalHubFixture()
        try await f.start()
        try await f.authenticate()
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        var delivered = false
        f.hub.terminalMessageHandler = { _, _ in delivered = true }
        try f.emit(.terminal(.sessions([])))
        f.identityStorage.failRead = true
        await f.drain()
        XCTAssertFalse(delivered)
        XCTAssertEqual(f.hub.remoteAccessBlockReason(for: f.clientId), .identityUnavailable)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: route))
    }

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
