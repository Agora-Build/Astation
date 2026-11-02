import CryptoKit
import XCTest
@testable import Menubar

@MainActor
final class AgentInputRoutingTests: XCTestCase {
    func testVerifiedInputUsesScopedControllerInsteadOfLegacyWireMessage() throws {
        let f = try ScopedInputFixture()
        var captured: [(RemoteTerminalConnection, String?, String, String)] = []
        f.hub.remoteAgentInputHandler = { route, agentId, kind, value in
            captured.append((route, agentId, kind, value))
            return true
        }
        f.hub.sendAgentText("inspect logs", agentId: "agent-9", clientId: "direct-two")
        f.hub.sendAgentKey("ctrl-c", agentId: "agent-9", clientId: "direct-two")
        XCTAssertEqual(captured.map { $0.0.clientId }, ["direct-two", "direct-two"])
        XCTAssertEqual(captured.map { $0.1 }, ["agent-9", "agent-9"])
        XCTAssertEqual(captured.map { $0.2 }, ["text", "key"])
        XCTAssertEqual(captured.map { $0.3 }, ["inspect logs", "ctrl-c"])
        XCTAssertTrue(f.sent.isEmpty, "legacy lease-less mutations must never be sent")
        XCTAssertNil(f.hub.remoteInputStatusMessage)
    }

    func testPinnedTargetUsesTheSameVerifiedScopedRoute() throws {
        let f = try ScopedInputFixture()
        f.hub.pinnedClientId = "direct-two"
        var target: RemoteTerminalConnection?
        f.hub.remoteAgentInputHandler = { route, _, _, _ in target = route; return true }
        f.hub.sendAgentText("route me")
        XCTAssertEqual(target?.clientId, "direct-two")
    }

    func testVerifiedHostWithoutHeldControllerFailsWithActionableHint() throws {
        let f = try ScopedInputFixture()
        f.hub.remoteAgentInputHandler = { _, _, _, _ in false }
        f.hub.sendAgentText("do not send", clientId: "direct-one")
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.hub.remoteInputStatusMessage?.contains("Take Control") == true)
    }

    func testUnverifiedHostNeverInvokesControllerAndDoesNotSend() throws {
        let f = try ScopedInputFixture(verified: false)
        var invoked = false
        f.hub.remoteAgentInputHandler = { _, _, _, _ in invoked = true; return true }
        f.hub.sendAgentText("do not send", clientId: "direct-one")
        f.hub.sendAgentKey("ctrl-c", clientId: "direct-one")
        XCTAssertFalse(invoked)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.hub.remoteInputStatusMessage?.contains("atem pair verify") == true)
    }

    func testRevokedPairingCannotReuseScopedController() throws {
        let f = try ScopedInputFixture()
        var invoked = false
        f.hub.remoteAgentInputHandler = { _, _, _, _ in invoked = true; return true }
        let sessionId = try XCTUnwrap(f.hub.connectedClients.first?.authenticationSessionId)
        f.hub.deviceSessionStore.delete(sessionId: sessionId)
        f.hub.sendAgentText("do not send", clientId: "direct-one")
        XCTAssertFalse(invoked)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testFinalVoiceInputRequiresScopedControllerAndPartialInputDoesNothing() throws {
        let f = try ScopedInputFixture()
        f.hub.pinnedClientId = "direct-two"
        var captured: [String] = []
        f.hub.remoteAgentInputHandler = { _, _, kind, value in captured.append(kind + ":" + value); return true }
        f.hub.sendVoiceCommand(text: "partial", isFinal: false)
        XCTAssertTrue(captured.isEmpty)
        f.hub.sendVoiceCommand(text: "finished", isFinal: true)
        XCTAssertEqual(captured, ["text:finished"])
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testOfflineExplicitTargetDoesNotFallbackToAnotherHost() throws {
        let f = try ScopedInputFixture()
        var invoked = false
        f.hub.remoteAgentInputHandler = { _, _, _, _ in invoked = true; return true }
        f.hub.sendAgentText("do not send", agentId: "agent", clientId: "offline")
        f.hub.sendAgentKey("enter", agentId: "agent", clientId: "offline")
        XCTAssertFalse(invoked)
        XCTAssertTrue(f.sent.isEmpty)
    }
}

@MainActor
private final class ScopedInputFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let hub: AstationHubManager
    var sent: [AstationMessage] = []

    init(verified: Bool = true) throws {
        let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        if verified {
            let keys = try identity.verificationKeys(nonce: Data(repeating: 1, count: 32))
            try identity.markRecoverySaved(signingPublicKey: keys.signPub)
            _ = try identity.completeVerification(account: AstationIdentity.shared.id, deviceId: "host",
                reveal: AtemVerifyReveal(devicePub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                    deviceSignPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    unlockAuthPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    nonce: Data(repeating: 2, count: 32)), transcript: Data(repeating: 3, count: 32),
                expectedSigningKey: keys.signPub, key: nil)
        }
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            atemE2EIdentity: identity, sessionJournal: AtemSessionJournal())
        hub.connectedClients = ["direct-one", "direct-two"].map { clientId in
            let session = sessions.create(hostname: "Host", atemId: "host")
            return ConnectedClient(id: clientId, clientType: "Atem", connectedAt: Date(),
                atemId: "host", authenticationSessionId: session.id)
        }
        hub.sendHandler = { [weak self] message, _ in self?.sent.append(message) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
