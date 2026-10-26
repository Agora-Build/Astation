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

    init(verified: Bool = true, relayOnly: Bool? = nil) throws {
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
        let journal = AtemSessionJournal()
        if let relayOnly {
            let issuer = try AccountServiceSettings.load().issuer
            let station = StationRelayURL.normalizedBase(SettingsWindowController.currentAstationRelayUrl)
            let policy = AtemTransportPolicyRecord(account: AstationIdentity.shared.id,
                issuer: issuer, station: station, relayOnly: relayOnly, hosts: [deviceId])
            try journal.update { $0.transportPolicies = [policy] }
        }
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            relayIdentityKeyManager: manager, relayIdentityRepairDefaults: defaults,
            atemE2EIdentity: identity, sessionJournal: journal, makeIdentityRelayTask: { _ in sockets.makeIdentity() },
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
    func testRelayOnlyReportsAreFencedAcrossReconnectAndNeverAuthorizeActivation() async throws {
        let f = try TerminalHubFixture(relayOnly: true)
        func policies() -> [[String: Any]] {
            f.socket.sent.compactMap { $0["payload"] as? [String: Any] }.filter { $0["type"] as? String == "transportPolicy" }
        }
        try await f.start()
        XCTAssertTrue(policies().isEmpty)
        try await f.authenticate()
        XCTAssertEqual(policies().count, 1)
        XCTAssertEqual((policies().first?["data"] as? [String: Bool])?["relay_only"], true)
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        try f.emit(.transportPolicyAck(AtemTransportPolicyAck(relayOnly: false, stored: true)))
        await f.drain(); XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        try f.emit(.transportPolicyAck(AtemTransportPolicyAck(relayOnly: true, stored: true)))
        await f.drain(); XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        XCTAssertTrue(f.hub.relayOnlyPolicyStatus.contains("reported relay-only"))
        let oldGeneration = f.generation
        f.generation = UUID().uuidString
        try f.socket.emit(["relay_event": "connected", "atem_id": f.deviceId, "connection_id": f.generation])
        await f.drain(); XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        let stale = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AstationMessage.transportPolicyAck(AtemTransportPolicyAck(relayOnly: true, stored: true))))
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": oldGeneration, "payload": stale])
        await f.drain(); XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        try await f.authenticate()
        try f.emit(.transportPolicyAck(AtemTransportPolicyAck(relayOnly: true, stored: true)))
        await f.drain(); XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        XCTAssertTrue(f.hub.relayOnlyPolicyStatus.contains("reported relay-only"))
        f.socket.fail()
        await f.drain()
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)
    }

    func testRelayOnlyBlocksExistingAndNewDirectAgentChannelsWithoutRemovingPairing() async throws {
        let f = try TerminalHubFixture(relayOnly: true)
        var sent: [AstationMessage] = [], closed: [String] = []
        f.hub.sendHandler = { message, _ in sent.append(message) }
        f.hub.disconnectDirectClient = { closed.append($0) }
        let id = UUID().uuidString
        f.hub.addClient(ConnectedClient(id: id, clientType: "Atem", connectedAt: Date(), hostname: "LAN",
            atemId: f.deviceId, authenticationSessionId: f.session.id))
        await f.drain()
        XCTAssertNil(f.hub.terminalConnection(for: id))
        XCTAssertEqual(f.hub.remoteAccessBlockReason(for: id), .selectedRelayRequired)
        XCTAssertTrue(sent.contains { if case .transportPolicy(relayOnly: true) = $0 { return true }; return false })
        XCTAssertNotNil(f.hub.deviceSessionStore.get(sessionId: f.session.id))
        _ = f.hub.handleMessage(.transportPolicyAck(AtemTransportPolicyAck(relayOnly: true, stored: true)), from: id)
        await f.drain()
        XCTAssertEqual(closed, [id])
        XCTAssertFalse(f.hub.relayOnlyPolicyReady, "A direct ACK is not selected-relay readiness")
        XCTAssertNotNil(f.hub.deviceSessionStore.get(sessionId: f.session.id))
    }

    func testUnsupportedHostIsHiddenWithoutLosingItsPairingOrFallingBack() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let client = try XCTUnwrap(f.hub.sessionClient(for: f.clientId))
        client.channelFailed("Upgrade Atem", unsupported: true)
        XCTAssertTrue(client.unsupportedVersion)
        XCTAssertTrue(f.hub.supportedAtemClients.isEmpty)
        XCTAssertNil(f.hub.routeToFocusedAtem())
        XCTAssertEqual(f.hub.connectedClients.count, 1)
        XCTAssertTrue(f.sessionFrames.isEmpty)
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

    func testVerificationCannotFallBackWhenR9MembershipIsUnavailable() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let route = AtemVerificationRoute(clientId: f.clientId, connectionId: f.generation,
            deviceId: f.deviceId, deviceName: "Host")
        f.hub.remoteVerificationDidComplete(on: route)
        await f.drain()
        XCTAssertTrue(f.sessionFrames.isEmpty)
        XCTAssertEqual(f.hub.sessionStatusByClientId[f.clientId]?.phase, .failed)
        XCTAssertTrue(f.hub.sessionStatusByClientId[f.clientId]?.message.contains("r9") == true)
        XCTAssertEqual(f.socket.cancelCount, 0)
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
        XCTAssertTrue(f.sessionFrames.isEmpty)
        try f.revokeVerification()
        f.hub.remoteVerificationDidComplete(on: AtemVerificationRoute(clientId: f.clientId, connectionId: f.generation,
            deviceId: f.deviceId, deviceName: "Host"))
        XCTAssertTrue(f.sessionFrames.isEmpty)
        XCTAssertEqual(f.socket.cancelCount, 0)
    }

    func testPlaintextWelcomeAndRefusalNeverOpenAChannelOrReconnectTheSocket() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let client = try XCTUnwrap(f.hub.sessionClient(for: f.clientId))
        var refusal = AtemSessionMessage(op: "error"); refusal.code = "unauthorized"
        try f.emit(.session(refusal))
        await f.drain()
        XCTAssertNil(client.welcome)
        XCTAssertFalse(client.hasRegistrySnapshot)
        XCTAssertEqual(f.socket.cancelCount, 0)
        XCTAssertTrue(f.sessionFrames.isEmpty)
    }

    func testSleepWakeClosesTransportAndNeverRestoresAPlaintextSession() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let oldContext = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        let oldSocket = f.socket
        f.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        XCTAssertEqual(oldSocket.cancelCount, 1)
        f.hub.startIdentityRelay()
        XCTAssertEqual(f.sockets.identity.count, 1)
        f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(f.sockets.identity.count, 2)
        try oldSocket.emit(["type": "relayAuthResult", "status": "verified"])
        await f.drain()
        XCTAssertNil(f.hub.sessionContext(for: f.clientId))
        try await f.start(); try await f.authenticate()
        let current = try XCTUnwrap(f.hub.sessionContext(for: f.clientId))
        XCTAssertEqual(oldContext.route, current.route)
        XCTAssertNotEqual(oldContext.transportGeneration, current.transportGeneration)
        XCTAssertTrue(f.sessionFrames.isEmpty)
        XCTAssertNil(f.hub.sessionClient(for: f.clientId)?.welcome)
    }

    func testForgedChannelOnUnknownRouteCannotReachTerminalOrChat() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        var delivered = 0
        f.hub.terminalMessageHandler = { _, _ in delivered += 1 }
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation,
            "payload": ["type":"channel", "event":"frame", "channel":"unknown", "frame":["ch":"atem-ch1", "op":"record", "ct":"forged"]]])
        await f.drain()
        XCTAssertEqual(delivered, 0)
        XCTAssertNil(f.hub.sessionClient(for: f.clientId)?.welcome)
        XCTAssertTrue(f.sessionFrames.isEmpty)
    }

    func testPairingWithOnlineHostNeverCreatesPairingRoomRowOrAnotherHello() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        _ = try XCTUnwrap(f.hub.sessionClient(for: f.clientId))
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
        XCTAssertTrue(sent.isEmpty)
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

    func testConnectionsAndTerminalShareOneR9ClientAndNeverSendPlaintextHello() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let client = try XCTUnwrap(f.hub.sessionClient(for: f.clientId))
        for _ in 0..<3 {
            XCTAssertTrue(f.hub.sessionClient(for: f.clientId) === client)
            client.start()
        }
        await f.drain()
        XCTAssertTrue(f.sessionFrames.isEmpty)
        XCTAssertTrue(f.terminalFrames.isEmpty)
        XCTAssertNil(client.welcome)
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

    func testVerifiedTransportStillRejectsPlaintextTerminalAndChatTraffic() async throws {
        let f = try TerminalHubFixture()
        var received = 0
        f.hub.terminalMessageHandler = { _, _ in received += 1 }
        try await f.start(); try await f.authenticate()
        let route = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        try f.emit(.terminal(.sessions([])))
        await f.drain()
        XCTAssertEqual(received, 0)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: route))
        f.hub.broadcastToAuthenticatedIdentityRelayClients(.terminal(.list))
        XCTAssertTrue(f.terminalFrames.isEmpty)
    }

    func testDisconnectAndReplacementNeverRestoreAnUnencryptedTerminalRoute() async throws {
        let f = try TerminalHubFixture()
        try await f.start(); try await f.authenticate()
        let old = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "relay_event": "disconnected"])
        await f.drain()
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: old))
        f.generation = UUID().uuidString
        try await f.authenticate()
        let current = try XCTUnwrap(f.hub.terminalConnection(for: f.clientId))
        XCTAssertNotEqual(current, old)
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: old))
        XCTAssertFalse(f.hub.sendTerminalMessage(.list, to: current))
        XCTAssertTrue(f.terminalFrames.isEmpty)
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
