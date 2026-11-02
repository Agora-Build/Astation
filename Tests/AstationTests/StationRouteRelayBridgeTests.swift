import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
final class StationRouteRelayBridgeTests: XCTestCase {
    func testRetiredRelayPreservesAuthenticatedRoutingButDropsAgentAndCredentialTraffic() throws {
        let f = try RouteBridgeFixture(authenticated: true)
        defer { f.close() }
        try f.emit(["type": "stationRoute", "data": ["v": 1, "op": "request"]])
        XCTAssertEqual(f.received.count, 1)
        XCTAssertEqual(f.received.first?.host, f.host)
        for type in ["channel", "session", "terminal", "agentChat", "unlockRequest", "keyRequest"] {
            try f.emit(["type": type, "data": [:]])
        }
        XCTAssertEqual(f.received.count, 1)
        f.bridge.sendPayload(Data(#"{"type":"terminal","data":{}}"#.utf8), host: f.host, connection: f.connection)
        XCTAssertTrue(f.socket.sent.isEmpty)
        f.bridge.sendPayload(RemoteStationRoute.changed, host: f.host, connection: f.connection)
        XCTAssertEqual(f.socket.sent.count, 1)
    }

    func testRetiredRelayRequiresAFreshSessionProofBeforeAcceptingRoutingMessages() throws {
        let f = try RouteBridgeFixture()
        defer { f.close() }
        try f.emit(["type": "stationRoute", "data": ["v": 1, "op": "request"]])
        XCTAssertTrue(f.received.isEmpty)
        try f.emit(try f.object(.statusUpdate(status: "hello", data: ["hostname": "host"])))
        let payload = try XCTUnwrap(f.socket.sent.last?["payload"] as? [String: Any])
        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        let challenge = try XCTUnwrap((data["data"] as? [String: String])?["challenge"])
        let proof = DeviceAuthentication.proof(token: f.session.token, challenge: challenge,
            astationId: f.astation, atemId: f.host, sessionId: f.session.id)
        try f.emit(try f.object(.statusUpdate(status: "auth", data: ["atem_id": f.host,
            "session_id": f.session.id, "proof": proof])))
        XCTAssertEqual(f.bridge.session(host: f.host, connection: f.connection), f.session.id)
        try f.emit(["type": "stationRoute", "data": ["v": 1, "op": "request"]])
        XCTAssertEqual(f.received.count, 1)
        let outgoing = String(decoding: try JSONSerialization.data(withJSONObject: f.socket.sent), as: UTF8.self)
        XCTAssertFalse(outgoing.contains(f.session.token))
    }

    func testReplacedRelayConnectionCannotUseItsOldAuthentication() throws {
        let f = try RouteBridgeFixture(authenticated: true)
        defer { f.close() }
        f.bridge.handle(try f.json(["atem_id": f.host, "connection_id": UUID().uuidString, "relay_event": "connected"]))
        XCTAssertNil(f.bridge.session(host: f.host, connection: f.connection))
        try f.emit(["type": "stationRoute", "data": ["v": 1, "op": "accepted"]])
        XCTAssertTrue(f.received.isEmpty)
    }

    func testUnknownPairingAndInvalidProofCannotEnrollOnTheRetiredRelay() throws {
        let f = try RouteBridgeFixture()
        defer { f.close() }
        let count = f.store.count
        try f.emit(try f.object(.statusUpdate(status: "hello", data: ["hostname": "host"])))
        for fields in [["atem_id": f.host, "session_id": f.session.id, "proof": "invalid-proof"],
                       ["atem_id": f.host, "pairing_code": "ABCD-1234", "pairing_attempt_id": "attempt-test"]] {
            try f.emit(try f.object(.statusUpdate(status: "auth", data: fields)))
        }
        XCTAssertNil(f.bridge.session(host: f.host, connection: f.connection))
        XCTAssertEqual(f.store.count, count)
    }

    func testChangedAccountRemovedPairingAndCloseInvalidateTheRetiredRoute() throws {
        let f = try RouteBridgeFixture(authenticated: true)
        defer { f.close() }
        f.current = false
        XCTAssertNil(f.bridge.session(host: f.host, connection: f.connection))
        f.bridge.wakeHosts()
        XCTAssertTrue(f.socket.sent.isEmpty)
        f.current = true
        try f.store.deleteAll()
        XCTAssertNil(f.bridge.session(host: f.host, connection: f.connection))
        f.bridge.close(); f.bridge.close()
        XCTAssertEqual(f.socket.cancelCount, 1)
    }

    func testUnverifiedRetiredSocketAnswersOnlyRelayIdentityUntilVerified() throws {
        let f = try RouteBridgeFixture(verified: false)
        defer { f.close() }
        f.bridge.handle(try f.json(["type": "relayAuthChallenge", "protocol": RelayIdentityProtocol.protocolVersion,
            "challenge": String(repeating: "a", count: 64)]))
        XCTAssertEqual(f.socket.sent.first?["type"] as? String, "relayAuth")
        f.bridge.handle(try f.json(["type": "relayAuthResult", "status": "verified"]))
        XCTAssertTrue(f.socket.sent.contains { $0["type"] as? String == "relaySessions" })
        XCTAssertFalse(f.socket.sent.contains { $0["type"] as? String == "relayRegisterAccount" })
    }
}

@MainActor
private final class RouteBridgeFixture {
    struct Received { let bytes: Data; let host: String; let session: String; let connection: String }
    let directory: URL
    let store: SessionStore
    let session: SessionInfo
    let socket = TerminalHubSocket()
    let host = "route-host"
    let astation = "route-native"
    let connection = UUID().uuidString
    var current = true
    var received: [Received] = []
    var bridge: StationRouteRelayBridge!

    init(authenticated: Bool = false, verified: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RouteBridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        session = store.create(hostname: "Test host", atemId: host)
        var authentication = IdentityRelayAuthenticationState()
        _ = authentication.connect(clientId: "relay-" + host, connectionId: connection)
        if authenticated {
            XCTAssertTrue(authentication.issueChallenge(clientId: "relay-" + host, connectionId: connection, challenge: "proof-test"))
            XCTAssertTrue(authentication.authenticate(clientId: "relay-" + host, atemId: host, connectionId: connection))
        }
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        bridge = StationRouteRelayBridge(generation: "old-socket", account: "account-test", issuer: "https://auth.example",
            socket: socket, verified: verified, authentication: authentication,
            clients: authenticated ? [ConnectedClient(id: "relay-" + host, clientType: "Atem", connectedAt: Date(),
                atemId: host, authenticationSessionId: session.id)] : [], store: store, astation: astation,
            key: { key }, current: { [unowned self] in current },
            receive: { [unowned self] in received.append(Received(bytes: $0, host: $1, session: $2, connection: $3)) })
    }

    func object(_ message: AstationMessage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    }

    func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func emit(_ payload: [String: Any]) throws {
        bridge.handle(try json(["atem_id": host, "connection_id": connection, "payload": payload]))
    }

    func close() {
        bridge.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
