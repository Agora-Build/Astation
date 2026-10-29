import Foundation
import XCTest
import AstationRemote
@testable import Menubar

private final class TransportPolicyFixture {
    struct Sent {
        let id: String
        let operation: RemoteAgentOperation
        let context: AtemTransportPolicyContext
        let saved: [AtemHostPolicyCheckpoint]
    }
    var time: TimeInterval = 100
    var snapshot = AtemSessionJournal.Snapshot()
    var failSave = false
    var contexts: [String: AtemTransportPolicyContext] = [:]
    var sent: [Sent] = []
    var reconnects: [AtemTransportPolicyContext] = []
    lazy var journal = AtemSessionJournal(load: { [unowned self] in snapshot }, save: { [unowned self] state in
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        snapshot = state
    })
    lazy var controller = makeController()
    func makeController() -> AtemTransportPolicyController {
        AtemTransportPolicyController(journal: journal, now: { [unowned self] in time },
            current: { [unowned self] in contexts[$0.route.clientId] == $0 },
            send: { [unowned self] operation, context in
                let id = UUID().uuidString.lowercased()
                sent.append(Sent(id: id, operation: operation, context: context, saved: snapshot.hostPolicies ?? []))
                return id
            }, reconnect: { [unowned self] in reconnects.append($0) })
    }
    func context(host: String = "host-a", relay: Bool = true, generation: String = "link-1",
                 pairing: String = "pairing-1", account: String = "account-a", verified: Bool = true,
                 attachment: String = "attachment-1", trust: UInt64 = 3, supported: Bool = true) -> AtemTransportPolicyContext {
        let id = relay ? "relay-" + host : "direct-" + host
        return AtemTransportPolicyContext(route: AtemVerificationRoute(clientId: id, connectionId: generation,
            deviceId: host, deviceName: "Test host"), account: account, issuer: "https://auth.example.test",
            station: "https://station.example.test", pairingSession: pairing, transportGeneration: generation,
            verifiedPin: verified ? AtemDevicePin(account: account, devicePub: Data(repeating: 1, count: 32),
                deviceSignPub: Data(repeating: 2, count: 32), unlockAuthPub: Data(repeating: 3, count: 32)) : nil,
            binding: AtemHostPolicyBinding(genesis: String(repeating: "a", count: 64), manager: "native-manager", trust: trust,
                channel: "channel-" + attachment, attachment: attachment, supported: supported))
    }
    func policy(_ value: Bool = true, hosts: [String] = ["host-a"]) -> AtemTransportPolicyRecord {
        AtemTransportPolicyRecord(account: "account-a", issuer: "https://auth.example.test",
            station: "https://station.example.test", relayOnly: value, hosts: hosts)
    }
    func connect(_ context: AtemTransportPolicyContext) {
        contexts[context.route.clientId] = context; controller.authenticated(context)
    }
    var ready: Bool { controller.ready(account: "account-a", issuer: "https://auth.example.test", station: "https://station.example.test") }
    func reply(_ context: AtemTransportPolicyContext, value: Bool = true, revision: UInt64 = 1,
               outcome: String = "current", state: String = "durable", confirmed: Bool = true, sent: Sent? = nil) {
        guard let message = sent ?? self.sent.last else { return XCTFail("No policy request") }
        let request: String?
        if case .hostPolicyRetry(_, let id, _) = message.operation { request = id } else { request = nil }
        controller.receive(AtemHostPolicyReply(re: message.id, requestID: request, outcome: outcome,
            relayOnly: value, revision: revision, state: state, confirmed: confirmed), context: context)
    }
}

final class AtemTransportPolicyTests: XCTestCase {
    func testSharedSessionChannelRequiresTheExactAuthenticatedContext() {
        let f = TransportPolicyFixture(), policy = f.context()
        func session(account: String = "account-a", device: String = "host-a", client: String = "relay-host-a",
                     connection: String = "link-1", pairing: String = "pairing-1", transport: String = "link-1") -> AtemSessionContext {
            AtemSessionContext(route: RemoteTerminalConnection(clientId: client, connectionId: connection),
                account: account, device: device, pairingSession: pairing, transportGeneration: transport)
        }
        XCTAssertTrue(policy.matches(session()))
        for changed in [session(account: "account-b"), session(device: "host-b"), session(client: "direct-host-a"),
                        session(connection: "link-2"), session(pairing: "pairing-2"), session(transport: "transport-2")] {
            XCTAssertFalse(policy.matches(changed), "A policy cannot borrow authority from a different authenticated link")
        }
    }

    func testRemovedPlaintextMessagesCannotBeDecodedOrEstablishAuthority() throws {
        for wire in [#"{"type":"transportPolicy","data":{"relay_only":true}}"#,
                     #"{"type":"transportPolicyAck","data":{"relay_only":true,"stored":true}}"#] {
            XCTAssertThrowsError(try AstationMessage.decodePacket(Data(wire.utf8)))
        }
        let f = TransportPolicyFixture(); f.connect(f.context())
        XCTAssertTrue(f.sent.isEmpty); XCTAssertFalse(f.ready)
    }

    func testIntentAndMutationAreDurableBeforeSendAndOnlyCoreConfirmationIsReady() throws {
        let f = TransportPolicyFixture(); let c = f.context()
        try f.controller.set(f.policy(), connections: [])
        f.connect(c)
        XCTAssertEqual(f.snapshot.transportPolicies, [f.policy()])
        XCTAssertEqual(f.sent.last?.operation, .hostPolicyGet(desired: true))
        f.reply(c, value: false, revision: 7, confirmed: false)
        let mutation = try XCTUnwrap(f.snapshot.hostPolicies?.first)
        XCTAssertFalse(mutation.completed)
        XCTAssertEqual(mutation.expectedRevision, 7)
        XCTAssertEqual(f.sent.last?.saved, [mutation], "Persist the exact retry body before transmission")
        XCTAssertEqual(f.sent.last?.operation, .hostPolicyRetry(relayOnly: true, request: mutation.requestID!, expectedRevision: 7))
        f.reply(c, revision: 8, outcome: "committed")
        XCTAssertTrue(f.ready)
        XCTAssertTrue(f.snapshot.hostPolicies!.first!.completed)
    }

    func testEveryReviewedHostMustConfirmOnSelectedRelayAndOfflineHostsStayPending() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(hosts: ["host-a", "host-b"]), connections: [])
        let a = f.context(), b = f.context(host: "host-b")
        f.connect(a); f.reply(a); XCTAssertFalse(f.ready)
        f.connect(b); f.reply(b); XCTAssertTrue(f.ready)
        f.reply(b); XCTAssertTrue(f.ready, "A duplicate cannot change readiness")
        f.contexts.removeValue(forKey: a.route.clientId); XCTAssertFalse(f.ready)
    }

    func testMatchingValueWithoutSharedConfirmationAndNonconfirmingOutcomesAreNotReady() throws {
        for (outcome, state, confirmed) in [("current", "durable", false), ("committed", "uncertain", false),
                                           ("conflict", "durable", false), ("superseded", "durable", false)] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let c = f.context(); f.connect(c)
            f.reply(c, outcome: outcome, state: state, confirmed: confirmed)
            XCTAssertFalse(f.ready)
        }
    }

    func testDelayedRepliesAreFencedByConnectionAttachmentPairingAndAccount() throws {
        for replacement in ["generation", "attachment", "pairing", "account"] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let old = f.context(); f.connect(old); let request = f.sent.last!
            let next = f.context(generation: replacement == "generation" ? "link-2" : "link-1",
                pairing: replacement == "pairing" ? "pairing-2" : "pairing-1",
                account: replacement == "account" ? "account-b" : "account-a",
                attachment: replacement == "attachment" ? "attachment-2" : "attachment-1")
            f.connect(next); f.reply(old, sent: request); XCTAssertFalse(f.ready)
            if replacement != "account" { f.reply(next); XCTAssertTrue(f.ready) }
        }
    }

    func testTimeoutUsesMonotonicEqualityAndLateResultCannotRestoreReadiness() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.time = 115
        f.reply(c); XCTAssertFalse(f.ready)
        f.controller.tick(); f.reply(c); XCTAssertFalse(f.ready)
        let next = f.context(attachment: "attachment-2"); f.connect(next); f.reply(next); XCTAssertTrue(f.ready)
    }

    func testDirectPolicyChannelMigratesButNeverCountsAsRelayReadiness() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let direct = f.context(relay: false); f.connect(direct); f.reply(direct)
        XCTAssertEqual(f.reconnects, [direct]); XCTAssertFalse(f.ready)
        XCTAssertTrue(f.controller.blocksDirect(account: direct.account, issuer: direct.issuer))
        let relay = f.context(); f.connect(relay); f.reply(relay); XCTAssertTrue(f.ready)
    }

    func testDirectTimeoutAndUnsupportedHostCloseMigrationWithoutConfirmation() throws {
        for supported in [true, false] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let direct = f.context(relay: false, supported: supported); f.connect(direct)
            f.time += 15; f.controller.tick(); f.controller.tick()
            XCTAssertEqual(f.reconnects, [direct]); XCTAssertFalse(f.ready)
        }
    }

    func testDirectMigrationFailureClosesImmediatelyAndKeepsDurableIntent() throws {
        for failure in ["refused", "save_failed", "superseded", "local_storage"] {
            let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
            let direct = f.context(relay: false); f.connect(direct)
            if failure == "refused" {
                f.controller.refused(re: f.sent.last!.id, context: direct)
            } else if failure == "local_storage" {
                f.failSave = true; f.reply(direct)
            } else {
                f.reply(direct, value: false, confirmed: false)
                f.reply(direct, value: false, outcome: failure, confirmed: false)
            }
            XCTAssertEqual(f.reconnects, [direct], failure)
            XCTAssertFalse(f.ready)
            XCTAssertTrue(f.controller.blocksDirect(account: direct.account, issuer: direct.issuer))
            XCTAssertEqual(f.snapshot.transportPolicies, [f.policy()])
            f.time += 15; f.controller.tick()
            XCTAssertEqual(f.reconnects, [direct], "A failed attempt closes once")
        }
    }

    func testUncertainMutationIsPolledAndRequiresDurableCurrentConfirmation() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.reply(c, value: false, revision: 0, confirmed: false)
        f.reply(c, outcome: "uncertain", state: "uncertain", confirmed: false)
        XCTAssertFalse(f.ready)
        f.time += 1; f.controller.tick()
        XCTAssertEqual(f.sent.last?.operation, .hostPolicyGet(desired: true))
        f.reply(c); XCTAssertTrue(f.ready)
    }

    func testRestartRetriesOriginalMutationWithFreshTransmissionAndNeverReappliesSupersededWork() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.reply(c, value: false, revision: 4, confirmed: false)
        let original = f.sent.last!
        f.controller = f.makeController()
        let next = f.context(attachment: "attachment-2"); f.connect(next)
        XCTAssertFalse(f.ready)
        f.reply(next, value: false, revision: 6, confirmed: false)
        XCTAssertEqual(f.sent.last?.operation, original.operation)
        XCTAssertNotEqual(f.sent.last?.id, original.id)
        f.reply(next, value: false, revision: 6, outcome: "superseded", confirmed: false)
        XCTAssertFalse(f.ready)
        XCTAssertTrue(f.controller.status(account: next.account, issuer: next.issuer, station: next.station).contains("conflicts"))
    }

    func testAnotherManagersChangeNeedsReadAndNeverSilentlyReversesThatDecision() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.reply(c); XCTAssertTrue(f.ready)
        f.time += 30; f.controller.receivedChange(context: c)
        XCTAssertFalse(f.ready)
        XCTAssertEqual(f.sent.last?.operation, .hostPolicyGet(desired: true))
        f.reply(c, value: false, revision: 2, confirmed: false)
        XCTAssertFalse(f.ready)
        XCTAssertEqual(f.sent.count, 2, "No automatic write may override the other manager")
        try f.controller.set(f.policy(), connections: [c])
        f.reply(c, value: false, revision: 2, confirmed: false)
        guard case .hostPolicyRetry = f.sent.last?.operation else { return XCTFail("An explicit reviewed apply should write") }
    }

    func testRapidTrueFalseTrueIgnoresRepliesForEarlierIntentOnSameAttachment() throws {
        let f = TransportPolicyFixture(); let c = f.context(); f.contexts[c.route.clientId] = c
        try f.controller.set(f.policy(), connections: [c]); let old = f.sent.last!
        try f.controller.set(f.policy(false), connections: [c])
        try f.controller.set(f.policy(), connections: [c])
        f.reply(c, sent: old); XCTAssertFalse(f.ready)
        f.reply(c); XCTAssertTrue(f.ready)
    }

    func testStorageFailuresBeforeIntentMutationAndConfirmationStayClosed() throws {
        for stage in ["intent", "mutation", "confirmation"] {
            let f = TransportPolicyFixture(); let c = f.context()
            if stage == "intent" {
                f.failSave = true
                XCTAssertThrowsError(try f.controller.set(f.policy(), connections: [c]))
                XCTAssertTrue(f.sent.isEmpty)
            } else {
                try f.controller.set(f.policy(), connections: []); f.connect(c); f.failSave = true
                f.reply(c, value: stage == "confirmation", confirmed: stage == "confirmation")
                XCTAssertEqual(f.sent.count, 1)
            }
            XCTAssertTrue(f.journal.loadFailed); XCTAssertFalse(f.ready)
            XCTAssertTrue(f.controller.blocksDirect(account: c.account, issuer: c.issuer))
        }
    }

    func testUnverifiedRevokedUnsupportedAndNewHostsNeverInheritConfirmation() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        f.connect(f.context(verified: false)); XCTAssertTrue(f.sent.isEmpty)
        let c = f.context(); f.connect(c); f.reply(c); XCTAssertTrue(f.ready)
        f.contexts[c.route.clientId] = f.context(verified: false); XCTAssertFalse(f.ready)
        f.connect(c); f.reply(c); XCTAssertTrue(f.ready)
        f.connect(f.context(host: "new-host")); XCTAssertFalse(f.ready)
        let other = TransportPolicyFixture(); try other.controller.set(other.policy(), connections: [])
        other.connect(other.context(supported: false)); XCTAssertTrue(other.sent.isEmpty); XCTAssertFalse(other.ready)
    }

    func testChangedTrustDoesNotReplayThePreviousPairingsMutation() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.reply(c, value: false, confirmed: false)
        let original = f.sent.last!.operation
        let next = f.context(attachment: "new", trust: 4); f.connect(next)
        f.reply(next, value: false, confirmed: false)
        XCTAssertNotEqual(f.sent.last?.operation, original)
    }

    func testJournalReloadRetainsPendingIdentityAndRejectsCorruptPolicyRecords() throws {
        let f = TransportPolicyFixture(); try f.controller.set(f.policy(), connections: [])
        let c = f.context(); f.connect(c); f.reply(c, value: false, confirmed: false)
        let encoded = try JSONEncoder().encode(f.snapshot)
        let loaded = try JSONDecoder().decode(AtemSessionJournal.Snapshot.self, from: encoded)
        let journal = AtemSessionJournal(load: { loaded })
        XCTAssertFalse(journal.loadFailed); XCTAssertEqual(journal.snapshot.hostPolicies, f.snapshot.hostPolicies)
        let old = try JSONDecoder().decode(AtemSessionJournal.Snapshot.self, from: Data(#"{"version":1,"requests":[],"hosts":[]}"#.utf8))
        XCTAssertFalse(AtemSessionJournal(load: { old }).loadFailed)
        XCTAssertEqual(journal.snapshot.version, 3, "Fence readers that would discard pending mutation identities")
        let previous = try JSONDecoder().decode(AtemSessionJournal.Snapshot.self, from:
            Data(#"{"version":2,"requests":[],"hosts":[]}"#.utf8))
        XCTAssertFalse(AtemSessionJournal(load: { previous }).loadFailed)
        XCTAssertEqual(AtemSessionJournal(load: { previous }).snapshot.version, 3)
        for version in [1, 2, 4] {
            var invalid = loaded; invalid.version = version
            XCTAssertTrue(AtemSessionJournal(load: { invalid }).loadFailed)
        }
    }
}
