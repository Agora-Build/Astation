import Foundation
import XCTest
@testable import Menubar

private final class TransportPolicyFixture {
    var time: TimeInterval = 100
    var snapshot = AtemSessionJournal.Snapshot()
    var failSave = false
    var contexts: [String: AtemTransportPolicyContext] = [:]
    var sent: [(Bool, AtemTransportPolicyContext)] = []
    var reconnects: [AtemTransportPolicyContext] = []
    lazy var journal = AtemSessionJournal(load: { [unowned self] in snapshot }, save: { [unowned self] state in
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        snapshot = state
    })
    lazy var controller = makeController()
    func makeController() -> AtemTransportPolicyController {
        AtemTransportPolicyController(journal: journal, now: { [unowned self] in time },
            current: { [unowned self] in contexts[$0.route.clientId] == $0 },
            send: { [unowned self] in sent.append(($0, $1)) },
            reconnect: { [unowned self] in reconnects.append($0) })
    }
    func context(host: String = "host-a", relay: Bool = true, generation: String = "link-1",
                 pairing: String = "pairing-1", account: String = "account-a", verified: Bool = true) -> AtemTransportPolicyContext {
        let id = relay ? "relay-" + host : "direct-" + host
        return AtemTransportPolicyContext(route: AtemVerificationRoute(clientId: id, connectionId: generation,
            deviceId: host, deviceName: "Test host"), account: account, issuer: "https://auth.example.test",
            station: "https://station.example.test", pairingSession: pairing, transportGeneration: generation,
            verifiedPin: verified ? AtemDevicePin(account: account, devicePub: Data(repeating: 1, count: 32),
                deviceSignPub: Data(repeating: 2, count: 32), unlockAuthPub: Data(repeating: 3, count: 32)) : nil)
    }
    func policy(_ value: Bool = true, hosts: [String] = ["host-a"]) -> AtemTransportPolicyRecord {
        AtemTransportPolicyRecord(account: "account-a", issuer: "https://auth.example.test",
            station: "https://station.example.test", relayOnly: value, hosts: hosts)
    }
    func connect(_ context: AtemTransportPolicyContext) {
        contexts[context.route.clientId] = context; controller.authenticated(context)
    }
    var reported: Bool { controller.allHostsReported(account: "account-a", issuer: "https://auth.example.test", station: "https://station.example.test") }
    func ack(_ context: AtemTransportPolicyContext, value: Bool = true, stored: Bool = true, reason: String? = nil) {
        controller.receive(AtemTransportPolicyAck(relayOnly: value, stored: stored, reason: reason), context: context)
    }
}

final class AtemTransportPolicyTests: XCTestCase {
    func testMatchingOuterAckForAPinnedHostCannotEstablishActivationReadiness() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c)
        // A relay knows the requested value and can inject this exact outer frame.
        let forged = try AstationMessage.decodePacket(Data(
            #"{"type":"transportPolicyAck","data":{"relay_only":true,"stored":true}}"#.utf8))
        guard case .transportPolicyAck(let ack) = forged else { return XCTFail("ACK not decoded") }
        f.controller.receive(ack, context: c)
        XCTAssertTrue(f.reported)
        XCTAssertFalse(f.controller.ready(account: c.account, issuer: c.issuer, station: c.station))
        let status = f.controller.status(account: c.account, issuer: c.issuer, station: c.station)
        XCTAssertTrue(status.contains("reported relay-only"))
        XCTAssertTrue(status.contains("hosted execution remains disabled"))
        XCTAssertFalse(status.contains("confirmed relay-only"))
    }

    func testWireMatchesAtemAndRequiresRealBooleans() throws {
        let data = try JSONEncoder().encode(AstationMessage.transportPolicy(relayOnly: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        XCTAssertEqual(object, ["type": "transportPolicy", "data": ["relay_only": true]] as NSDictionary)
        for wire in [#"{"type":"transportPolicyAck","data":{"relay_only":true,"stored":true}}"#,
                     #"{"type":"transportPolicyAck","data":{"relay_only":false,"stored":false,"reason":"save_failed"}}"#] {
            guard case .transportPolicyAck(let ack) = try AstationMessage.decodePacket(Data(wire.utf8)) else { return XCTFail("ACK not decoded") }
            let roundtrip = try JSONEncoder().encode(AstationMessage.transportPolicyAck(ack))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: roundtrip) as? NSDictionary,
                try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? NSDictionary)
        }
        for invalid in [#"{"type":"transportPolicyAck","data":{"relay_only":true}}"#,
                        #"{"type":"transportPolicyAck","data":{"relay_only":1,"stored":true}}"#,
                        #"{"type":"transportPolicyAck","data":{"relay_only":true,"stored":"true"}}"#] {
            XCTAssertThrowsError(try AstationMessage.decodePacket(Data(invalid.utf8)))
        }
    }

    func testOpeningAnotherControllerDoesNotSilentlyClearTheHostPolicy() {
        let f = TransportPolicyFixture(); f.connect(f.context())
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertFalse(f.reported)
    }

    func testIntentIsDurableBeforeSendAndEveryReviewedHostMustReportOnRelay() throws {
        let f = TransportPolicyFixture()
        try f.controller.set(f.policy(hosts: ["host-a", "host-b"]), connections: [])
        let a = f.context(), b = f.context(host: "host-b")
        f.connect(a)
        XCTAssertEqual(f.snapshot.transportPolicies, [f.policy(hosts: ["host-a", "host-b"])])
        XCTAssertEqual(f.sent.count, 1)
        f.ack(a)
        XCTAssertFalse(f.reported, "Offline hosts cannot count as reported")
        f.connect(b); f.ack(b)
        XCTAssertTrue(f.reported)
        f.ack(b)
        XCTAssertTrue(f.reported, "A duplicate ACK is harmless")
        f.contexts.removeValue(forKey: a.route.clientId)
        XCTAssertFalse(f.reported, "A former connection is not a current routing report")
    }

    func testWrongValueRefusalOrContradictoryAckIsNotASuccessReport() throws {
        for (value, stored, reason) in [(false, true, nil), (true, false, "save_failed"), (true, true, "pairing_changed")] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let c = f.context(); f.connect(c); f.ack(c, value: value, stored: stored, reason: reason)
            XCTAssertFalse(f.reported)
        }
    }

    func testDelayedDispatchCannotAdoptAReconnectedRepairedOrDifferentAccountContext() throws {
        for replacement in ["generation", "pairing", "account"] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let old = f.context(); f.connect(old)
            let new = f.context(generation: replacement == "generation" ? "link-2" : "link-1",
                pairing: replacement == "pairing" ? "pairing-2" : "pairing-1",
                account: replacement == "account" ? "account-b" : "account-a")
            f.connect(new); f.ack(old)
            XCTAssertFalse(f.reported)
            if replacement != "account" { f.ack(new); XCTAssertTrue(f.reported) }
        }
    }

    func testDeadlineIsMonotonicAndLateAcknowledgmentCannotRestoreAReport() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.time = 110; f.ack(c)
        XCTAssertFalse(f.reported, "At the exact deadline the attempt is expired")
        f.controller.tick(); f.ack(c)
        XCTAssertFalse(f.reported)
        XCTAssertTrue(f.controller.status(account: c.account, issuer: c.issuer, station: c.station).contains("did not confirm"))
        let next = f.context(generation: "link-2"); f.connect(next); f.ack(next)
        XCTAssertTrue(f.reported)
    }

    func testDirectAckIsMigrationOnlyAndNewDirectConnectionsStayBlocked() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let direct = f.context(relay: false); f.connect(direct); f.ack(direct)
        XCTAssertEqual(f.reconnects, [direct])
        XCTAssertFalse(f.reported)
        XCTAssertTrue(f.controller.blocksDirect(account: "account-a", issuer: "https://auth.example.test"))
        let relay = f.context(); f.connect(relay); f.ack(relay)
        XCTAssertTrue(f.reported)
    }

    func testDirectTimeoutClosesTheMigrationLinkWithoutClaimingSavedPolicy() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(relay: false); f.connect(c); f.time += 10; f.controller.tick()
        XCTAssertEqual(f.reconnects, [c]); XCTAssertFalse(f.reported)
        f.controller.tick(); XCTAssertEqual(f.reconnects.count, 1)
    }

    func testRapidTrueFalseTrueNeverReusesAnAmbiguousAcknowledgment() throws {
        let f = TransportPolicyFixture(); let c = f.context(); f.contexts[c.route.clientId] = c
        try f.controller.set(f.policy(), connections: [c])
        try f.controller.set(f.policy(false), connections: [c])
        try f.controller.set(f.policy(), connections: [c])
        XCTAssertEqual(f.sent.count, 1, "The opposite value must wait for a new connection")
        XCTAssertEqual(f.reconnects, [c]); f.ack(c); XCTAssertFalse(f.reported)
        let next = f.context(generation: "link-2"); f.connect(next); f.ack(next)
        XCTAssertTrue(f.reported)
    }

    func testWriteFailureAndCorruptStorageNeverSendOrAdmit() throws {
        let f = TransportPolicyFixture(); let c = f.context(); f.contexts[c.route.clientId] = c; f.failSave = true
        XCTAssertThrowsError(try f.controller.set(f.policy(), connections: [c]))
        XCTAssertTrue(f.sent.isEmpty); XCTAssertTrue(f.journal.loadFailed)
        XCTAssertTrue(f.controller.blocksDirect(account: "account-a", issuer: "https://auth.example.test"))
        f.ack(c); XCTAssertFalse(f.reported)
        let corrupt = AtemSessionJournal(load: { throw CocoaError(.fileReadCorruptFile) })
        let controller = AtemTransportPolicyController(journal: corrupt, current: { _ in true },
            send: { _, _ in XCTFail("Corrupt checkpoint sent a policy") }, reconnect: { _ in })
        controller.authenticated(c)
        XCTAssertFalse(controller.allHostsReported(account: "account-a", issuer: "https://auth.example.test", station: c.station))
    }

    func testRestartRetainsIntentButRequiresANewLiveAcknowledgment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.json")
        let f = TransportPolicyFixture(), c = f.context()
        let first = AtemSessionJournal.persistent(at: path)
        let policy = f.policy()
        try first.update { $0.transportPolicies = [policy] }
        let restored = AtemSessionJournal.persistent(at: path)
        var sends = 0
        let controller = AtemTransportPolicyController(journal: restored, current: { $0 == c },
            send: { value, context in XCTAssertTrue(value); XCTAssertEqual(context, c); sends += 1 }, reconnect: { _ in })
        XCTAssertEqual(controller.policy(account: policy.account, issuer: policy.issuer), policy)
        XCTAssertFalse(controller.allHostsReported(account: policy.account, issuer: policy.issuer, station: policy.station))
        controller.authenticated(c); XCTAssertEqual(sends, 1)
        controller.receive(AtemTransportPolicyAck(relayOnly: true, stored: true), context: c)
        XCTAssertTrue(controller.allHostsReported(account: policy.account, issuer: policy.issuer, station: policy.station))
    }

    func testDifferentStationAndNewHostDoNotInheritReports() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.ack(c); XCTAssertTrue(f.reported)
        XCTAssertFalse(f.controller.allHostsReported(account: "account-a", issuer: c.issuer, station: "https://other.example.test"))
        f.connect(f.context(host: "new-host")); XCTAssertFalse(f.reported)
    }

    func testUnverifiedOrRevokedDeviceCannotProvideACurrentReport() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let unverified = f.context(verified: false); f.connect(unverified); f.ack(unverified)
        XCTAssertFalse(f.reported)
        let verified = f.context(); f.connect(verified); f.ack(verified); XCTAssertTrue(f.reported)
        f.contexts[verified.route.clientId] = unverified
        XCTAssertFalse(f.reported)
        f.ack(verified); XCTAssertFalse(f.reported)
    }

    func testOldJournalMigratesWithoutInventingPolicyAndNewPoliciesRequireTheNewFormat() throws {
        let old = try JSONDecoder().decode(AtemSessionJournal.Snapshot.self,
            from: Data(#"{"version":1,"requests":[],"hosts":[]}"#.utf8))
        let migrated = AtemSessionJournal(load: { old })
        XCTAssertFalse(migrated.loadFailed)
        XCTAssertEqual(migrated.snapshot.version, 2)
        XCTAssertNil(migrated.snapshot.transportPolicies)
        var ambiguous = old
        ambiguous.transportPolicies = [TransportPolicyFixture().policy()]
        XCTAssertTrue(AtemSessionJournal(load: { ambiguous }).loadFailed)
    }
}
