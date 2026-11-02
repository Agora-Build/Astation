import XCTest
@testable import AstationRemote

@MainActor
final class RemoteStationRouteTests: XCTestCase {
    func testDirectSelectionIsStagedBeforeRelayOnlyAndFallbackUsesTheSameSelectedStation() throws {
        let f = StationRouteFixture()
        f.controller.receive(try f.request(), context: f.context)
        XCTAssertEqual(f.offers.map(\.station), [f.context.station])
        XCTAssertEqual(f.offers.map(\.relayOnly), [false])
        XCTAssertNil(f.controller.stagedSelection(f.context))
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertEqual(f.controller.stagedSelection(f.context)?.relayOnly, false)
        XCTAssertEqual(f.accepted.count, 1)

        f.controller.requireRelay(f.context)
        XCTAssertEqual(f.sent.last, RemoteStationRoute.changed)
        f.controller.receive(try f.request(), context: f.context)
        XCTAssertEqual(f.offers.map(\.relayOnly), [false, true])
        XCTAssertEqual(f.offers.map(\.station), [f.context.station, f.context.station])
        f.controller.receive(f.ack(blocked: true), context: f.context)
        XCTAssertEqual(f.controller.stagedSelection(f.context)?.directBlocked, true)
    }

    func testRelaySelectionUsesTheCurrentCustomOriginAndNeverTheRequestAsAnEndpoint() throws {
        let f = StationRouteFixture(direct: false)
        f.controller.receive(try f.request(), context: f.context)
        XCTAssertEqual(f.offers.first?.station, "https://custom.example:8443")
        XCTAssertEqual(f.offers.first?.relayOnly, true)
        XCTAssertEqual(f.offers.first?.secret, "synthetic-session-token")
        XCTAssertFalse(f.sent.contains { String(decoding: $0, as: UTF8.self).contains("synthetic-session-token") })
    }

    func testWrongAuthenticatedHostSessionAndAstationNeverReachTheSigner() throws {
        for field in ["astation_id", "atem_id", "session_id"] {
            let f = StationRouteFixture()
            f.controller.receive(try f.request(hostChanges: [field: "other-device"]), context: f.context)
            XCTAssertTrue(f.offers.isEmpty, field)
            XCTAssertTrue(f.sent.isEmpty, field)
        }
        let f = StationRouteFixture()
        f.controller.receive(try f.request(hostChanges: ["account_id": "other-account",
            "host_device_id": "host-test", "genesis_hash": String(repeating: "12", count: 32)]), context: f.context)
        XCTAssertTrue(f.offers.isEmpty)
    }

    func testEstablishedMembershipMustMatchAccountGenesisHostAndTrustGeneration() throws {
        for (field, replacement) in [("account_id", "other-account" as Any),
                                     ("genesis_hash", String(repeating: "34", count: 32)),
                                     ("host_device_id", "other-host"), ("host_trust_gen", 16)] {
            let f = StationRouteFixture(anchored: true)
            f.controller.receive(try f.request(hostChanges: [field: replacement]), context: f.context)
            XCTAssertTrue(f.offers.isEmpty, field)
        }
        let f = StationRouteFixture(anchored: true)
        f.controller.receive(try f.request(), context: f.context)
        XCTAssertEqual(f.offers.count, 1)
    }

    func testReplacingAppStateDuringSigningCannotSendAnOffer() throws {
        for change in ["station", "account", "socket", "session"] {
            let f = StationRouteFixture()
            let captured = f.context
            f.duringSign = { f.replace(change) }
            f.controller.receive(try f.request(), context: captured)
            XCTAssertEqual(f.offers.count, 1, change)
            XCTAssertTrue(f.sent.isEmpty, change)
        }
        let f = StationRouteFixture()
        f.duringSign = { f.secret = "replacement-session-token" }
        f.controller.receive(try f.request(), context: f.context)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testLateAcknowledgmentCannotCompleteAfterAStationAccountSocketOrSessionChange() throws {
        for change in ["station", "account", "socket", "session"] {
            let f = StationRouteFixture()
            let captured = f.context
            f.controller.receive(try f.request(), context: captured)
            f.replace(change)
            f.controller.receive(f.ack(), context: captured)
            XCTAssertTrue(f.accepted.isEmpty, change)
            XCTAssertNil(f.controller.stagedSelection(f.context), change)
        }
    }

    func testReentrantVerificationCannotApplyAnAcknowledgmentToReplacedState() throws {
        let f = StationRouteFixture()
        let captured = f.context
        f.controller.receive(try f.request(), context: captured)
        f.duringVerify = { f.replace("station") }
        f.controller.receive(f.ack(), context: captured)
        XCTAssertTrue(f.accepted.isEmpty)
    }

    func testAcknowledgmentsNeedTheExactPendingOfferAndMustArriveBeforeTheDeadline() throws {
        let f = StationRouteFixture()
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertTrue(f.accepted.isEmpty)
        f.controller.receive(try f.request(), context: f.context)
        f.verificationFails = true
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertTrue(f.accepted.isEmpty)
        f.verificationFails = false
        f.clock += 30
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertTrue(f.accepted.isEmpty)
    }

    func testRepeatedRequestsAndAcknowledgmentsCannotTriggerDuplicateWork() throws {
        let f = StationRouteFixture()
        let request = try f.request()
        f.controller.receive(request, context: f.context)
        f.controller.receive(request, context: f.context)
        XCTAssertEqual(f.offers.count, 1)
        f.controller.receive(f.ack(), context: f.context)
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertEqual(f.accepted.count, 1)
    }

    func testSelectionChangesFenceTheOldOfferAndDisconnectedStateCannotRestoreReadiness() throws {
        let f = StationRouteFixture()
        f.controller.receive(try f.request(), context: f.context)
        f.controller.selectionChanged(f.context)
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertTrue(f.accepted.isEmpty)
        f.controller.receive(try f.request(), context: f.context)
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertNotNil(f.controller.stagedSelection(f.context))
        f.controller.disconnected(client: f.context.client)
        f.controller.receive(f.ack(), context: f.context)
        XCTAssertNil(f.controller.stagedSelection(f.context))
    }

    func testMalformedVersionDuplicatesAndOversizedEnvelopesNeverReachTheSigner() throws {
        let f = StationRouteFixture()
        let request = String(decoding: try f.request(), as: UTF8.self)
        for json in [request.replacingOccurrences(of: "\"v\":1", with: "\"v\":1.0"),
                     request.replacingOccurrences(of: "\"op\":\"request\"", with: "\"op\":\"request\",\"op\":\"request\""),
                     request + String(repeating: " ", count: 4096)] {
            f.controller.receive(Data(json.utf8), context: f.context)
        }
        XCTAssertTrue(f.offers.isEmpty)
    }
}

@MainActor
private final class StationRouteFixture {
    struct Offer { let json: String; let station: String; let relayOnly: Bool; let secret: String }
    var context: RemoteStationRoute.Context
    var clock: TimeInterval = 100
    var secret = "synthetic-session-token"
    var offers: [Offer] = []
    var sent: [Data] = []
    var accepted: [RemoteStationRoute.Acceptance] = []
    var duringSign: (() -> Void)?
    var duringVerify: (() -> Void)?
    var verificationFails = false
    lazy var controller = RemoteStationRouteController(codec: RemoteStationRoute.Codec(
        offer: { [unowned self] json, station, relayOnly, secret in
            offers.append(Offer(json: json, station: station, relayOnly: relayOnly, secret: secret))
            duringSign?()
            return #"{"type":"stationRoute","data":{"v":1,"op":"offer"}}"#
        }, verify: { [unowned self] offer, _, secret in
            XCTAssertEqual(offer, #"{"type":"stationRoute","data":{"v":1,"op":"offer"}}"#)
            XCTAssertEqual(secret, self.secret)
            if verificationFails { throw RemoteChannelError.invalidInput }
            duringVerify?()
            return 8
        }), current: { [unowned self] in $0 == context }, token: { [unowned self] _ in secret },
        send: { [unowned self] bytes, _ in sent.append(bytes) },
        accepted: { [unowned self] _, value in accepted.append(value) }, now: { [unowned self] in clock })

    init(direct: Bool = true, anchored: Bool = false) {
        context = RemoteStationRoute.Context(client: "client-test", connection: "connection-test", transport: "transport-test",
            accountGeneration: UUID(), account: "account-test", astation: "native-test", atem: "host-test", session: "session-test",
            station: "https://custom.example:8443", relayOnly: true, direct: direct,
            anchor: anchored ? RemoteStationRoute.Anchor(account: "account-test", genesis: String(repeating: "12", count: 32),
                host: "host-test", trust: 15) : nil)
    }

    func replace(_ field: String) {
        context = RemoteStationRoute.Context(client: context.client,
            connection: field == "socket" ? "new-connection" : context.connection, transport: context.transport,
            accountGeneration: field == "account" ? UUID() : context.accountGeneration,
            account: context.account, astation: context.astation, atem: context.atem,
            session: field == "session" ? "new-session" : context.session,
            station: field == "station" ? "https://new.example" : context.station,
            relayOnly: context.relayOnly, direct: context.direct, anchor: context.anchor)
    }

    func request(hostChanges: [String: Any] = [:]) throws -> Data {
        var host: [String: Any] = ["astation_id": context.astation, "atem_id": context.atem,
            "binding_id": "binding-test", "session_id": context.session, "host_trust_gen": 15,
            "account_id": context.anchor?.account as Any? ?? NSNull(),
            "genesis_hash": context.anchor?.genesis as Any? ?? NSNull(),
            "host_device_id": context.anchor?.host as Any? ?? NSNull()]
        host.merge(hostChanges) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["type": "stationRoute", "data": ["v": 1, "op": "request",
            "request": ["id": UUID().uuidString.lowercased(), "context": host, "route_revision": 7, "policy_revision": 3]]],
            options: [.sortedKeys])
    }

    func ack(blocked: Bool = false) -> Data {
        Data("{\"type\":\"stationRoute\",\"data\":{\"v\":1,\"op\":\"accepted\",\"accepted\":{\"direct_blocked\":\(blocked)}}}".utf8)
    }
}
