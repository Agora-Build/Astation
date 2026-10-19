import CryptoKit
import AppKit
import XCTest
@testable import Menubar

private final class TerminalHubSocket: IdentityRelaySocket, @unchecked Sendable {
    var sent: [[String: Any]] = []
    var closeCode = URLSessionWebSocketTask.CloseCode.invalid
    var closeReason: Data?
    var cancelCount = 0
    private var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        closeReason = reason
        cancelCount += 1
    }
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
private final class TerminalHubSockets {
    var identity: [TerminalHubSocket] = []
    let pairing = TerminalHubSocket()
    var current: TerminalHubSocket { identity.last ?? pairing }
    func makeIdentity() -> TerminalHubSocket {
        let socket = TerminalHubSocket()
        identity.append(socket)
        return socket
    }
}

@MainActor
private final class TerminalHubFixture {
    let sockets = TerminalHubSockets()
    var socket: TerminalHubSocket { sockets.current }
    let workspaceNotifications = NotificationCenter()
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
        let sockets = self.sockets
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
            atemE2EIdentity: identity, sessionJournal: AtemSessionJournal(), makeIdentityRelayTask: { _ in sockets.makeIdentity() },
            makePairingRelayTask: { _ in sockets.pairing }, workspaceNotifications: workspaceNotifications)
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

    var sessionFrames: [[String: Any]] {
        socket.sent.compactMap { $0["payload"] as? [String: Any] }.filter { $0["type"] as? String == "session" }
    }

    func readySession() async throws -> (AtemSessionClient, AtemSessionTarget) {
        let client = try XCTUnwrap(hub.sessionClient(for: clientId))
        let context = try XCTUnwrap(hub.sessionContext(for: clientId))
        let hello = try XCTUnwrap(sessionFrames.last { ($0["data"] as? [String: Any])?["op"] as? String == "hello" })
        let data = try XCTUnwrap(hello["data"] as? [String: Any])
        var welcome = AtemSessionMessage(op: "welcome")
        welcome.revision = 8
        welcome.features = AtemSessionWire.features.sorted()
        welcome.re = try XCTUnwrap(data["id"] as? String)
        welcome.account_id = context.account; welcome.atem_device_id = context.device
        welcome.host_trust_gen = 1; welcome.runtime_gen = "55555555-5555-4555-8555-555555555555"
        welcome.controller_session = "66666666-6666-4666-8666-666666666666"
        welcome.attachment_gen = "33333333-3333-4333-8333-333333333333"
        welcome.client_kind = "native"; welcome.permissions = ["view", "control"]
        welcome.authorization_ms_left = 60_000; welcome.server_time = 1_760_500_000_000
        try emit(.session(welcome)); await drain()
        let descriptor = try JSONDecoder().decode(AtemSessionDescriptor.self, from: Data(
            #"{"session_id":"ses-aaaaaaaaaaaa","process_gen":"22222222-2222-4222-8222-222222222222","provider":"claude","cwd_label":"Project","state":"running","activity":"ready","activity_since":1,"controller":null,"capabilities":["terminal-v1","chat-v1"],"created_at":1}"#.utf8))
        var snapshot = AtemSessionMessage(op: "sessions")
        snapshot.runtime_gen = welcome.runtime_gen; snapshot.runtime_epoch = 7; snapshot.seq = 1; snapshot.sessions = [descriptor]
        try emit(.session(snapshot)); await drain()
        return (client, try XCTUnwrap(client.target(sessionId: descriptor.session_id, process: descriptor.process_gen)))
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
    func testUnsupportedHostIsHiddenFromRoutingAndSelectionWithoutLosingItsPairing() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let (client, _) = try await f.readySession()
        XCTAssertEqual(f.hub.supportedAtemClients.count, 1)
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unsupported_version"
        try f.emit(.session(refusal)); await f.drain()
        XCTAssertTrue(client.unsupportedVersion)
        XCTAssertTrue(f.hub.supportedAtemClients.isEmpty)
        XCTAssertNil(f.hub.routeToFocusedAtem())
        XCTAssertTrue(f.hub.agentsByClientId[f.clientId]?.isEmpty == true)
        XCTAssertEqual(f.hub.connectedClients.count, 1, "Version rejection does not unpair the verified device")
        XCTAssertTrue(AtemClientListModel.offlineSessions(activeSessions: f.hub.deviceSessionStore.getAllActive(),
            connectedClients: f.hub.connectedClients).isEmpty, "A hidden incompatible host is not mislabeled offline")
    }

    func testPairingRoomTransfersMessagesWithoutBecomingAnOnlineAtem() async throws {
        let f = try TerminalHubFixture()
        var forwarded: [String] = []
        f.hub.sendHandler = { _, id in forwarded.append(id) }
        f.hub.connectToRelay(code: "TEST-CODE")
        await f.drain()
        XCTAssertTrue(f.hub.connectedClients.isEmpty)
        XCTAssertTrue(f.hub.agentsByClientId.isEmpty)
        XCTAssertTrue(f.hub.sessionStatusByClientId.isEmpty)
        f.hub.sendHandler?(.statusUpdate(status: "test", data: [:]), "relay-TEST-CODE")
        XCTAssertEqual(f.socket.sent.last?["type"] as? String, "statusUpdate")
        XCTAssertTrue(forwarded.isEmpty)
        f.hub.sendHandler?(.statusUpdate(status: "test", data: [:]), "actual-host")
        XCTAssertEqual(forwarded, ["actual-host"])
        XCTAssertTrue(f.sessionFrames.isEmpty)
        f.socket.fail()
        await f.drain()
        XCTAssertTrue(f.hub.connectedClients.isEmpty)
    }

    func testLocalVerificationCompletionRetriesOnlyTheRefusedInitialHello() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let hello = try XCTUnwrap(f.sessionFrames.last?["data"] as? [String: Any])
        var refusal = AtemSessionMessage(op: "error")
        refusal.re = try XCTUnwrap(hello["id"] as? String); refusal.code = "unauthorized"
        try f.emit(.session(refusal)); await f.drain()
        let route = AtemVerificationRoute(clientId: f.clientId, connectionId: f.generation,
            deviceId: f.deviceId, deviceName: "Host")
        f.hub.remoteVerificationDidComplete(on: route)
        f.hub.remoteVerificationDidComplete(on: route)
        XCTAssertEqual(f.socket.cancelCount, 0, "Verification delivery must not be interrupted by reconnect")
        XCTAssertEqual(f.sockets.identity.count, 1)
        let hellos = f.sessionFrames.compactMap { $0["data"] as? [String: Any] }.filter { $0["op"] as? String == "hello" }
        XCTAssertEqual(hellos.count, 2)
        XCTAssertNotEqual(hellos.last?["id"] as? String, hello["id"] as? String)
        _ = try await f.readySession()
        XCTAssertEqual(f.hub.sessionStatusByClientId[f.clientId]?.phase, .ready)
    }

    func testVerificationCompletionCannotRetryAStaleOrRevokedLink() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.emit(.session(refusal)); await f.drain()
        for route in [
            AtemVerificationRoute(clientId: f.clientId, connectionId: "stale", deviceId: f.deviceId, deviceName: "Host"),
            AtemVerificationRoute(clientId: f.clientId, connectionId: f.generation, deviceId: "other", deviceName: "Host")
        ] { f.hub.remoteVerificationDidComplete(on: route) }
        XCTAssertEqual(f.sessionFrames.count, 1)
        try f.revokeVerification()
        f.hub.remoteVerificationDidComplete(on: AtemVerificationRoute(clientId: f.clientId, connectionId: f.generation,
            deviceId: f.deviceId, deviceName: "Host"))
        XCTAssertEqual(f.sessionFrames.count, 1)
        XCTAssertEqual(f.socket.cancelCount, 0)
    }

    func testPairingTimeHelloRefusalRetryClosesSocketAndRequiresFreshAuthentication() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let hello = try XCTUnwrap(f.sessionFrames.last?["data"] as? [String: Any])
        var refusal = AtemSessionMessage(op: "error")
        refusal.re = try XCTUnwrap(hello["id"] as? String)
        refusal.code = "unauthorized"
        try f.emit(.session(refusal)); await f.drain()
        XCTAssertEqual(f.hub.sessionStatusByClientId[f.clientId]?.phase, .failed)
        XCTAssertTrue(f.hub.sessionStatusByClientId[f.clientId]?.message.contains("unauthorized") == true)
        XCTAssertEqual(f.hub.sessionStatusByClientId[f.clientId]?.canReconnect, true)
        XCTAssertFalse(f.hub.sessionStatusByClientId[f.clientId]?.message.contains("Complete verification") == true)
        let oldSocket = f.socket
        let oldContext = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        let oldChallenge = try XCTUnwrap(f.challenges.last)
        f.hub.requestAgentList(from: f.clientId)
        await f.drain()
        XCTAssertEqual(oldSocket.cancelCount, 1)
        XCTAssertEqual(oldSocket.closeCode, .goingAway)
        XCTAssertFalse(f.socket === oldSocket)
        XCTAssertEqual(f.sockets.identity.count, 2)
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        XCTAssertTrue(f.sessionFrames.isEmpty)
        try await f.start()
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "connected"])
        await f.drain()
        XCTAssertTrue(f.sessionFrames.isEmpty)
        try await f.prove(challenge: oldChallenge)
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        try await f.prove(challenge: XCTUnwrap(f.challenges.last))
        XCTAssertEqual(f.sessionFrames.count, 1)
        let current = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        XCTAssertEqual(current.route, oldContext.route, "The Atem host socket survived the Mac reconnect")
        XCTAssertNotEqual(current.transportGeneration, oldContext.transportGeneration)
        let retry = try XCTUnwrap(f.sessionFrames.last?["data"] as? [String: Any])
        XCTAssertNotEqual(hello["id"] as? String, retry["id"] as? String)
        _ = try await f.readySession()
        XCTAssertEqual(f.hub.sessionStatusByClientId[f.clientId]?.phase, .ready)
    }

    func testSleepWakeClosesTransportFencesControlAndIgnoresStaleSocket() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let (client, target) = try await f.readySession()
        let oldContext = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        client.acquire(target)
        var lease = AtemSessionMessage(op: "lease")
        lease.re = try XCTUnwrap((f.sessionFrames.last?["data"] as? [String: Any])?["id"] as? String)
        lease.binding = AtemSessionBinding(target: target, attachment_gen: try XCTUnwrap(client.welcome?.attachment_gen), lease_epoch: 1)
        lease.ms_left = 15_000
        try f.emit(.session(lease)); await f.drain()
        XCTAssertTrue(client.controls(target))
        let oldSocket = f.socket
        f.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        XCTAssertFalse(client.controls(target))
        XCTAssertTrue(client.registry.isEmpty)
        XCTAssertEqual(oldSocket.cancelCount, 1)
        f.hub.startIdentityRelay()
        XCTAssertEqual(f.sockets.identity.count, 1, "No reconnect while sleeping")
        await f.drain()
        f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(f.sockets.identity.count, 2, "Duplicate wake does not reconnect twice")
        try oldSocket.emit(["type": "relayAuthResult", "status": "verified"])
        await f.drain()
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        XCTAssertTrue(f.sessionFrames.isEmpty)
        try await f.start(); try await f.authenticate()
        let current = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        XCTAssertEqual(oldContext.route, current.route)
        XCTAssertNotEqual(oldContext.transportGeneration, current.transportGeneration)
        let (newClient, _) = try await f.readySession()
        try f.emit(.session(lease)); await f.drain()
        XCTAssertFalse(newClient.controls(target), "Old lease replies never restore control")
        XCTAssertEqual(f.sessionFrames.filter { ($0["data"] as? [String: Any])?["op"] as? String == "hello" }.count, 1)
    }

    func testPostWelcomeUnauthorizedReconnectsOnceWithoutVerificationPrompt() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let (client, _) = try await f.readySession()
        let oldSocket = f.socket
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.emit(.session(refusal)); await f.drain()
        XCTAssertEqual(oldSocket.cancelCount, 1)
        XCTAssertEqual(f.sockets.identity.count, 2)
        XCTAssertNil(client.welcome)
        XCTAssertFalse(client.status.contains("Complete verification"))
        XCTAssertTrue(f.sessionFrames.isEmpty)
        oldSocket.fail(); await f.drain()
        XCTAssertEqual(f.sockets.identity.count, 2)
    }

    func testPairingWithOnlineHostNeverCreatesPairingRoomRowOrAnotherHello() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        _ = try await f.readySession()
        let before = f.sessionFrames.count
        f.hub.connectToRelay(code: "TEST-CODE"); await f.drain()
        XCTAssertEqual(f.hub.connectedClients.map(\.id), [f.clientId])
        XCTAssertEqual(f.sessionFrames.count, before)
        XCTAssertNil(f.hub.sessionStatusByClientId["relay-TEST-CODE"])
        f.sockets.pairing.fail(); await f.drain()
        XCTAssertEqual(f.hub.connectedClients.map(\.id), [f.clientId])
        XCTAssertEqual(f.sessionFrames.count, before)
    }

    func testDirectRetryClosesOnlySelectedSocketAndDiscardsAttachment() async throws {
        let f = try TerminalHubFixture()
        f.hub.connectedClients = ["direct-one", "direct-two"].map {
            ConnectedClient(id: $0, clientType: "Atem", connectedAt: Date(), hostname: "Host",
                atemId: f.deviceId, authenticationSessionId: f.session.id)
        }
        var sent: [AtemSessionMessage] = []
        var closed: [String] = []
        f.hub.sendHandler = { message, _ in if case .session(let frame) = message { sent.append(frame) } }
        f.hub.disconnectDirectClient = { closed.append($0) }
        let client = try XCTUnwrap(f.hub.sessionClient(for: "direct-one"))
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        client.receive(refusal, from: try XCTUnwrap(f.hub.sessionContext(for: "direct-one")).route)
        client.refresh(); await f.drain()
        XCTAssertEqual(closed, ["direct-one"])
        XCTAssertEqual(sent.filter { $0.op == "hello" }.count, 1)
        XCTAssertNil(f.hub.sessionContext(for: "direct-one"))
        XCTAssertNotNil(f.hub.sessionContext(for: "direct-two"))
    }

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

    func testBrowserAccessIsBlockedBeforeHelloAndAfterReconnect() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: Data(
            #"{"id":"agent","name":"Claude","kind":"ClaudeCode","capabilities":["chat-v1"]}"#.utf8))
        for _ in 0..<2 {
            XCTAssertThrowsError(try f.hub.openAgentInBrowser(clientId: f.clientId, agent: agent)) {
                XCTAssertTrue($0.localizedDescription.contains("secure companion"))
            }
            f.generation = UUID().uuidString
            try await f.authenticate()
        }
        XCTAssertFalse(f.socket.sent.contains { ($0["payload"] as? [String: Any])?["type"] as? String == "agentChat" })
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
        XCTAssertTrue(f.hub.agentsByClientId[f.clientId]?.isEmpty != false)
    }

    func testOneSessionClientServesConnectionsAndTerminalWithoutSecondHello() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let (client, target) = try await f.readySession()
        let initialHellos = f.sessionFrames.filter { ($0["data"] as? [String: Any])?["op"] as? String == "hello" }.count
        XCTAssertEqual(initialHellos, 1)
        for _ in 0..<3 {
            XCTAssertTrue(f.hub.sessionClient(for: f.clientId) === client)
            client.start()
            f.hub.requestAgentList(from: f.clientId)
        }
        XCTAssertEqual(f.sessionFrames.filter { ($0["data"] as? [String: Any])?["op"] as? String == "hello" }.count, 1)
        XCTAssertEqual(f.hub.agentsByClientId[f.clientId]?.map(\.id), [target.session_id])
        XCTAssertEqual(f.hub.agentsByClientId[f.clientId]?.first?.status, "Idle")
        XCTAssertTrue(f.terminalFrames.isEmpty)
        XCTAssertFalse(f.socket.sent.contains { ($0["payload"] as? [String: Any])?["type"] as? String == "agentListRequest" })
    }

    func testRemovedCommandsReturnUnsupportedVersionAndConsoleNeverSends() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let before = f.socket.sent.count
        XCTAssertFalse(f.hub.sendCommandToClient("private command", action: "shell", clientId: f.clientId))
        XCTAssertEqual(f.socket.sent.count, before)
        for removed in [AstationMessage.agentListRequest, .voiceCommand(text: "never dispatch", isFinal: true),
                        .userCommand(command: "never execute", context: ["action": "shell"])] {
            guard case .session(let response) = f.hub.handleMessage(removed, from: f.clientId, relayConnectionId: f.generation) else {
                return XCTFail("Removed op needs unsupported_version")
            }
            XCTAssertEqual(response.code, "unsupported_version")
            XCTAssertNil(response.re)
        }
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
        let (client, target) = try await f.readySession()
        let subscribe = RemoteTerminalMessage.bound(.subscribe(terminalId: target.session_id, generation: target.process_gen),
            try XCTUnwrap(client.binding(for: target, mutation: false)))
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: route))
        XCTAssertTrue(f.hub.sendTerminalMessage(subscribe, to: route))
        XCTAssertEqual(f.terminalFrames.count, 1)
        let sent = try XCTUnwrap(f.terminalFrames.first)
        XCTAssertEqual(sent["atem_id"] as? String, f.deviceId)
        XCTAssertEqual(sent["connection_id"] as? String, f.generation)
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
        let (client, target) = try await f.readySession()
        let subscribe = RemoteTerminalMessage.bound(.subscribe(terminalId: target.session_id, generation: target.process_gen),
            try XCTUnwrap(client.binding(for: target, mutation: false)))
        XCTAssertTrue(f.hub.sendTerminalMessage(subscribe, to: current))
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
