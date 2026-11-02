import AstationRemote
import XCTest
@testable import Menubar

@MainActor
final class StationRouteHubTests: XCTestCase {
    func testUnavailableAnchorCannotBypassEndpointStagingToOpenADirectPolicyChannel() async throws {
        let codec = HubRouteCodec()
        var preparations = 0
        let f = try TerminalHubFixture(relayOnly: true, prepareR9Channel: { _ in
            preparations += 1
            throw RemoteChannelError.invalidInput
        }, stationRouteCodec: codec.value, loadStationRouteAnchor: { _ in throw RemoteChannelError.invalidInput })
        let direct = UUID().uuidString
        var sent: [Data] = []
        f.hub.sendDirectChannel = { bytes, _, completion in sent.append(bytes); completion(nil) }
        f.hub.addClient(ConnectedClient(id: direct, clientType: "Atem", connectedAt: Date(),
            atemId: f.deviceId, authenticationSessionId: f.session.id))
        await f.drain()
        f.hub.receiveStationRoute(try request(f), clientID: direct, connectionID: direct)
        await f.drain()
        XCTAssertEqual(preparations, 0)
        XCTAssertTrue(codec.origins.isEmpty)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)
    }

    func testMissingMembershipStagesSelectedEndpointThenRequestsRelayOnlyWithoutDisconnecting() async throws {
        let codec = HubRouteCodec()
        let f = try TerminalHubFixture(relayOnly: true, stationRouteCodec: codec.value)
        let direct = UUID().uuidString
        var sent: [Data] = [], disconnected: [String] = []
        f.hub.sendDirectChannel = { bytes, _, completion in sent.append(bytes); completion(nil) }
        f.hub.disconnectDirectClient = { disconnected.append($0) }
        f.hub.addClient(ConnectedClient(id: direct, clientType: "Atem", connectedAt: Date(),
            atemId: f.deviceId, authenticationSessionId: f.session.id))
        await f.drain()
        f.hub.receiveStationRoute(try request(f), clientID: direct, connectionID: direct)
        let staged = try XCTUnwrap(sent.last)
        XCTAssertEqual(try offer(staged)["relay_url"] as? String, f.hub.stationRelayUrl)
        XCTAssertEqual(try offer(staged)["relay_only"] as? Bool, false)
        f.hub.receiveStationRoute(try accepted(staged, blocked: false), clientID: direct, connectionID: direct)
        await f.drain()
        XCTAssertEqual(sent.last, RemoteStationRoute.changed)
        f.hub.receiveStationRoute(try request(f), clientID: direct, connectionID: direct)
        XCTAssertEqual(try offer(try XCTUnwrap(sent.last))["relay_only"] as? Bool, true)
        XCTAssertEqual(try offer(try XCTUnwrap(sent.last))["relay_url"] as? String, f.hub.stationRelayUrl)
        XCTAssertTrue(disconnected.isEmpty)
        XCTAssertNotNil(f.hub.deviceSessionStore.get(sessionId: f.session.id))
        XCTAssertNil(f.hub.sessionClient(for: direct))
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)
    }

    func testPrimaryRelayOnlySignsRoutingRequestsFromItsAuthenticatedHostGeneration() async throws {
        let codec = HubRouteCodec()
        let f = try TerminalHubFixture(stationRouteCodec: codec.value)
        try await f.start()
        let packet = try JSONSerialization.jsonObject(with: request(f)) as! [String: Any]
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "payload": packet])
        await f.drain()
        XCTAssertTrue(codec.origins.isEmpty)
        try await f.authenticate()
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": UUID().uuidString, "payload": packet])
        await f.drain()
        XCTAssertTrue(codec.origins.isEmpty)
        try f.socket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "payload": packet])
        await f.drain()
        XCTAssertEqual(codec.origins, [f.hub.stationRelayUrl])
    }

    func testChangingStationsRetainsOldAuthenticatedSocketForRoutingToTheNewCurrentOrigin() async throws {
        let codec = HubRouteCodec()
        let f = try TerminalHubFixture(relayOnly: true, stationRouteCodec: codec.value)
        try await f.start(); try await f.authenticate()
        let oldSocket = f.socket
        f.hub._testRelayUrlOverride = "https://custom-station.example:8443"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        await f.drain()
        XCTAssertEqual(oldSocket.cancelCount, 0)
        XCTAssertEqual(f.sockets.identity.count, 2)
        let packet = try JSONSerialization.jsonObject(with: request(f))
        try oldSocket.emit(["atem_id": f.deviceId, "connection_id": f.generation, "payload": packet])
        await f.drain()
        XCTAssertEqual(codec.origins.last, "https://custom-station.example:8443")
        let routed = oldSocket.sent.compactMap { $0["payload"] as? [String: Any] }.last { $0["type"] as? String == "stationRoute" }
        let fields = routed?["data"] as? [String: Any]
        XCTAssertEqual((fields?["offer"] as? [String: Any])?["relay_url"] as? String, "https://custom-station.example:8443")
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)

        f.hub._testRelayUrlOverride = "https://newest-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        await f.drain()
        try oldSocket.emit(["atem_id": f.deviceId, "connection_id": f.generation,
            "payload": JSONSerialization.jsonObject(with: request(f))])
        await f.drain()
        XCTAssertEqual(codec.origins.last, "https://newest-station.example")
        f.hub.accountSessionChanged()
        XCTAssertEqual(oldSocket.cancelCount, 1)
    }

    func testHandoffKeepsItsAccountWhileTheNewStationHasNotReportedAnAccountYet() async throws {
        let codec = HubRouteCodec()
        let f = try TerminalHubFixture(stationRouteCodec: codec.value)
        try await f.start()
        try f.socket.emit(["type": "relayEncryptionState", "data_account": "paired-account", "mode": "off",
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
        await f.drain()
        try await f.authenticate()
        let old = f.socket
        f.hub._testRelayUrlOverride = "https://new-account-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        await f.drain()
        try old.emit(["atem_id": f.deviceId, "connection_id": f.generation,
            "payload": JSONSerialization.jsonObject(with: request(f, account: "paired-account"))])
        await f.drain()
        XCTAssertEqual(codec.origins, ["https://new-account-station.example"])

        try f.socket.emit(["type": "relayAuthResult", "status": "verified"])
        await f.drain()
        try f.socket.emit(["type": "relayEncryptionState", "data_account": "different-account", "mode": "off",
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
        await f.drain()
        try old.emit(["atem_id": f.deviceId, "connection_id": f.generation,
            "payload": JSONSerialization.jsonObject(with: request(f, account: "paired-account"))])
        await f.drain()
        XCTAssertEqual(codec.origins.count, 1, "A different current account cannot continue an old account's handoff")
    }

    private func request(_ f: TerminalHubFixture, account: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "stationRoute", "data": ["v": 1, "op": "request",
            "request": ["id": UUID().uuidString.lowercased(), "route_revision": 0, "policy_revision": 0,
                "context": ["astation_id": AstationIdentity.shared.id, "atem_id": f.deviceId, "binding_id": "binding-test",
                    "host_trust_gen": 1, "session_id": f.session.id,
                    "host_device_id": account == nil ? NSNull() : f.deviceId as Any,
                    "account_id": account as Any? ?? NSNull(),
                    "genesis_hash": account == nil ? NSNull() : String(repeating: "12", count: 32) as Any]]]])
    }

    private func offer(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((root["data"] as? [String: Any])?["offer"] as? [String: Any])
    }

    private func accepted(_ data: Data, blocked: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "stationRoute", "data": ["v": 1, "op": "accepted",
            "accepted": ["offer": offer(data), "route_revision": 1, "direct_blocked": blocked, "proof": "test-only"]]])
    }
}

/// Orchestration double; shared-vector tests separately exercise the real binding.
@MainActor
private final class HubRouteCodec {
    var origins: [String] = []
    var value: RemoteStationRoute.Codec {
        RemoteStationRoute.Codec(offer: { [unowned self] json, station, relayOnly, _ in
            origins.append(station)
            let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let data = root["data"] as! [String: Any]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["type": "stationRoute", "data": ["v": 1,
                "op": "offer", "offer": ["request": data["request"]!, "relay_url": station,
                    "relay_only": relayOnly, "proof": "test-only"]]]), as: UTF8.self)
        }, verify: { offer, accepted, _ in
            let sent = try JSONSerialization.jsonObject(with: Data(offer.utf8)) as! [String: Any]
            let reply = try JSONSerialization.jsonObject(with: Data(accepted.utf8)) as! [String: Any]
            let expected = (sent["data"] as! [String: Any])["offer"] as! NSDictionary
            let data = (reply["data"] as! [String: Any])["accepted"] as! [String: Any]
            guard let actual = data["offer"] as? NSDictionary, expected == actual else { throw RemoteChannelError.invalidInput }
            return 1
        })
    }
}
