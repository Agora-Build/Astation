import XCTest
@testable import AstationRemote

@MainActor
final class RemoteStationRouteBindingTests: XCTestCase {
    func testProductionCodecCompletesTheIndependentVectorOnlyOnce() throws {
        let f = try BindingRouteFixture()
        f.controller.receive(f.request, context: f.context)
        let offer = try XCTUnwrap(f.sent.last)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: offer) as? NSDictionary, f.vector["offer"] as? NSDictionary)
        XCTAssertNil(f.controller.stagedSelection(f.context))
        f.controller.receive(f.accepted, context: f.context)
        f.controller.receive(f.accepted, context: f.context)
        XCTAssertEqual(f.results, [.init(revision: 8, policyRevision: 3, directBlocked: true, relayOnly: true)])
        XCTAssertEqual(f.controller.stagedSelection(f.context), f.results.first)
    }

    func testWrongSessionAndTamperedAckCannotFinishButTheValidAckCan() throws {
        let f = try BindingRouteFixture()
        f.controller.receive(f.request, context: f.context)
        let altered = String(decoding: f.accepted, as: UTF8.self)
            .replacingOccurrences(of: "\"direct_blocked\":true", with: "\"direct_blocked\":false")
        f.controller.receive(Data(altered.utf8), context: f.context)
        XCTAssertTrue(f.results.isEmpty)
        f.token = "different-test-session"
        f.controller.receive(f.accepted, context: f.context)
        XCTAssertTrue(f.results.isEmpty)
        f.token = f.vector["test_session_token"] as! String
        f.controller.receive(f.accepted, context: f.context)
        XCTAssertEqual(f.results.count, 1)
    }

    func testDifferentCurrentOriginCannotAcceptAnOldOriginAcknowledgment() throws {
        let f = try BindingRouteFixture(station: "https://custom.example:8443")
        f.controller.receive(f.request, context: f.context)
        let raw = try XCTUnwrap(f.sent.last)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual((payload["offer"] as? [String: Any])?["relay_url"] as? String, "https://custom.example:8443")
        f.controller.receive(f.accepted, context: f.context)
        XCTAssertTrue(f.results.isEmpty)
        XCTAssertNil(f.controller.stagedSelection(f.context))
    }

    func testFreshOfferAndDeadlineFenceTheRealSignedAcknowledgment() throws {
        let f = try BindingRouteFixture()
        f.controller.receive(f.request, context: f.context)
        let fresh = String(decoding: f.request, as: UTF8.self)
            .replacingOccurrences(of: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", with: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        f.controller.receive(Data(fresh.utf8), context: f.context)
        f.controller.receive(f.accepted, context: f.context)
        XCTAssertTrue(f.results.isEmpty)

        let expired = try BindingRouteFixture()
        expired.controller.receive(expired.request, context: expired.context)
        expired.clock += 30
        expired.controller.receive(expired.accepted, context: expired.context)
        XCTAssertTrue(expired.results.isEmpty)
    }
}

@MainActor
private final class BindingRouteFixture {
    let vector: [String: Any]
    let request: Data
    let accepted: Data
    let context: RemoteStationRoute.Context
    var token: String
    var clock: TimeInterval = 100
    var sent: [Data] = []
    var results: [RemoteStationRoute.Acceptance] = []
    lazy var controller = RemoteStationRouteController(codec: .shared,
        current: { [unowned self] in $0 == context }, token: { [unowned self] _ in token },
        send: { [unowned self] bytes, _ in sent.append(bytes) },
        accepted: { [unowned self] _, value in results.append(value) }, now: { [unowned self] in clock })

    init(station: String = "https://station-dev.agora.build") throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "station-route-v1", withExtension: "json", subdirectory: "Fixtures"))
        vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        request = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["request"]), options: [.sortedKeys])
        accepted = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["accepted"]), options: [.sortedKeys])
        token = try XCTUnwrap(vector["test_session_token"] as? String)
        context = RemoteStationRoute.Context(client: "test-client", connection: "test-connection", transport: "test-transport",
            accountGeneration: UUID(), account: "account-test", astation: "astation-test", atem: "atem-test", session: "session-test",
            station: station, relayOnly: true, direct: false,
            anchor: .init(account: "account-test", genesis: String(repeating: "12", count: 32), host: "host-test", trust: 15))
    }
}
