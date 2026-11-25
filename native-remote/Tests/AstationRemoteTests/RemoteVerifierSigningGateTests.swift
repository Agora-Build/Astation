import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class VerifierFixtureKeys: AppKeyProvider, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey()
    var signs = 0
    func publicKey(keyId: String) throws -> PublicKeyData { PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation) }
    func sign(request: SignRequest) throws -> Data { signs += 1; return try key.signature(for: request.input) }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.invalidInput }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw RemoteChannelError.invalidInput }
}

@MainActor
private final class VerifierFixture {
    let keys = VerifierFixtureKeys()
    let clock = HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "verifier-test")
    let log: MembershipLog
    let roster: [RemoteVerifierID] = [.host("host"), .member("manager"), .stationReplica("a"), .stationReplica("b"), .other("sdk")]
    var checkpoint: Data?
    var publication: RemoteMembershipPublication!

    init() throws {
        let pub: [String: Any] = ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(keys.key.publicKey.rawRepresentation)]
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "manager",
            "signed_at": clock.wallMs, "member": ["device_id": "manager", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": pub, "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Data(repeating: 7, count: 32))]],
            "recovery_key": pub]
        let genesis = try Self.signed(body, keys: keys)
        log = try MembershipLog.verify(accountId: "account", genesisHash: XCTUnwrap(signedObjectInfo(json: genesis).entryHash),
            entries: [genesis], now: clock)
        try append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1, "host_key": pub]])
        publication = RemoteMembershipPublication(log: log, persist: { [unowned self] in checkpoint = $0 })
    }

    func append(_ action: [String: Any]) throws {
        let body = try log.draftEntry(signer: "manager", signedAt: clock.wallMs,
            actionJson: String(decoding: JSONSerialization.data(withJSONObject: action), as: UTF8.self))
        let result = try log.extend(entries: [Self.signed(JSONSerialization.jsonObject(with: Data(body.utf8)), keys: keys)], now: clock)
        XCTAssertEqual(result.appended, 1)
        XCTAssertNil(result.stop)
    }

    private static func signed(_ body: Any, keys: VerifierFixtureKeys) throws -> String {
        let info = try signedObjectInfo(json: String(decoding: JSONSerialization.data(withJSONObject: ["body": body,
            "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]), as: UTF8.self))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["body": body,
            "sig": RemoteRecoveryKit.base64URL(keys.key.signature(for: info.signingInput))]), as: UTF8.self)
    }

    func review(_ operation: RemoteHostSenderReview.Operation = .revoke(interruptRunning: false)) throws -> RemoteHostSenderReview {
        try RemoteHostSenderReview(stationOrigin: "https://station.example", log: log, managerID: "manager", hostID: "host",
            operation: operation, now: clock)
    }

    func confirmedGate(now: @escaping () -> UInt64 = { 100 }) throws
        -> (RemoteVerifierSigningGate, [RemoteVerifierID: RemoteVerifierSigningGate.Connection]) {
        let gate = try RemoteVerifierSigningGate(log: log, verifiers: roster, now: now)
        var connections: [RemoteVerifierID: RemoteVerifierSigningGate.Connection] = [:]
        for id in roster {
            let connection = try gate.connect(id)
            connections[id] = connection
            if case .host = id { try gate.observeHostWelcome(welcome(), on: connection) }
            else { try gate.observeConsumer(verifierInventory(), on: connection) }
        }
        return (gate, connections)
    }

    func welcome(inventory: VerifierInventory? = verifierInventory()) -> WelcomeInfo {
        WelcomeInfo(principal: "member:manager", clientKind: "native", permissions: ["control", "manage", "view"],
            revision: 9, features: [], accountId: log.accountId(), atemDeviceId: "host", hostTrustGen: 1,
            attachmentGen: "attachment", controllerSession: "controller", runtimeGen: "runtime", authorizationMsLeft: 1000,
            serverTime: clock.wallMs, head: log.head(), pendingRecovery: [], channelId: "channel", scopeJson: nil,
            verifier: inventory, json: "")
    }
}

@MainActor
private final class VerifierChannelCore: RemoteChannelCore {
    var acceptDeadline: UInt64? = 5_000
    var isClosed = false
    var events: [ClientEvent] = []
    var receiveError: Error?
    var startError: Error?
    let welcomeInfo: WelcomeInfo

    init(_ welcome: WelcomeInfo) { welcomeInfo = welcome }
    func start(now: UInt64) throws -> Data {
        if let startError { throw startError }
        return Data()
    }
    func accept(_ frame: Data, now: UInt64) throws -> SignRequest {
        SignRequest(keyId: "manager", purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client", input: Data(), bodyJson: nil)
    }
    func finish(_ signature: Data, now: UInt64) throws -> Data { Data() }
    func welcome(_ frame: Data, now: UInt64) throws -> WelcomeInfo { welcomeInfo }
    func receive(_ frame: Data, now: UInt64) throws -> [ClientEvent] {
        if let receiveError { throw receiveError }
        return events
    }
    func perform(_ operation: RemoteAgentOperation, now: UInt64) throws -> Outgoing {
        Outgoing(id: "unused", frame: Data())
    }
    func disconnect() { isClosed = true }
}

@MainActor
private final class VerifierChannelHarness {
    let route = try! RemoteChannelRoute(linkGeneration: UUID(), handle: "verified_host")
    let core: VerifierChannelCore
    let channel: RemoteAgentChannel

    init(gate: RemoteVerifierSigningGate, welcome: WelcomeInfo, now: @escaping () -> UInt64 = { 100 },
        ready: @escaping () -> Void = {}, update: @escaping (ClientEvent) -> Void = { _ in }) {
        core = VerifierChannelCore(welcome)
        channel = RemoteAgentChannel(route: route, core: core, clock: now, automaticTimer: false,
            verifierEvidence: RemoteHostVerifierEvidence(gate: gate, hostID: "host"),
            sign: { _ in Data() }, send: { _, _ in }, close: { _ in }, observe: { event in
                if case .ready = event { ready() }
                if case .update(let event) = event { update(event) }
            })
    }

    func welcome() async throws {
        if channel.phase == .new { try channel.start() }
        channel.receive(Data(), from: route)
        for _ in 0..<20 where channel.phase == .signing { await Task.yield() }
        XCTAssertEqual(channel.phase, .awaitingWelcome)
        channel.receive(Data(), from: route)
        XCTAssertEqual(channel.phase, .ready)
    }
}

final class RemoteVerifierSigningGateTests: XCTestCase {
    @MainActor
    func testLegacyNativeRolesWaiveOnlyTheVerifierUpgradeRequirement() throws {
        let f = try VerifierFixture()
        let body = try f.log.draftEntry(signer: "manager", signedAt: f.clock.wallMs,
            actionJson: "{\"action\":\"set_roles\",\"device_id\":\"manager\",\"roles\":[\"control\",\"manage\",\"view\"]}")
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager")
        XCTAssertNil(try membershipRequiredVersion(bodyJson: body))
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: f.roster)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        XCTAssertTrue(request.freshConfirmation)
        XCTAssertThrowsError(try gate.authorize(f.review().signingRequest(managerID: "manager"), log: f.log))
    }

    @MainActor
    func testActualSigningGateRejectsDuplicateAndUnknownActionsBeforeWaivingUpgrade() throws {
        let f = try VerifierFixture()
        let (gate, _) = try f.confirmedGate()
        let body = try f.log.draftEntry(signer: "manager", signedAt: f.clock.wallMs,
            actionJson: "{\"action\":\"set_roles\",\"device_id\":\"manager\",\"roles\":[\"control\",\"manage\",\"view\"]}")
        let valid = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager")
        XCTAssertNoThrow(try gate.authorize(valid, log: f.log))
        let canonical = try XCTUnwrap(valid.bodyJson)
        let malformed = [
            String(canonical.dropLast()) + ",\"action\":\"set_roles\"}",
            String(canonical.dropLast()) + ",\"\\u0061ction\":\"set_roles\"}",
            canonical.replacingOccurrences(of: "\"action\":\"set_roles\"", with: "\"action\":\"future_action\"")
        ]
        for body in malformed {
            XCTAssertNotEqual(body, canonical)
            XCTAssertThrowsError(try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager"))
            let request = SignRequest(keyId: valid.keyId, purpose: valid.purpose,
                freshConfirmation: valid.freshConfirmation, label: valid.label, input: valid.input, bodyJson: body)
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        }
    }

    @MainActor
    func testStationEvidenceMustUseTheGatesExactAccountGenesisAndHead() throws {
        let fixture = try VerifierFixture(), other = try VerifierFixture()
        let gate = try RemoteVerifierSigningGate(log: fixture.log, verifiers: fixture.roster)
        let anchor = fixture.log.snapshot()
        let roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        XCTAssertNoThrow(try gate.requireMembership(anchor))
        XCTAssertThrowsError(try gate.requireMembership(other.log))
        XCTAssertThrowsError(try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: other.log))
        try fixture.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "manage", "view"]])
        XCTAssertThrowsError(try gate.requireMembership(fixture.log))
        XCTAssertThrowsError(try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: fixture.log))
        XCTAssertNoThrow(try gate.requireMembership(anchor))
    }

    @MainActor
    func testStationEvidenceExpiresWithoutTimersAndFreshPollsConsumeRequestDelay() throws {
        let f = try VerifierFixture(), roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        var time: UInt64 = 100
        let gate = try stationGate(f, roster: roster, now: { time })
        let evidence = try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: f.log)
        let request = try f.review().signingRequest(managerID: "manager")
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try evidence.receive(stationSnapshot(f, started: 100), for: evidence.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 399
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 400
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try evidence.receive(stationSnapshot(f, started: 350), for: evidence.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 650
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try evidence.receive(stationSnapshot(f, started: 100), for: evidence.begin()))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testStationPollRetirementAndFailureCannotRestoreOrInvalidateANewerReply() throws {
        let f = try VerifierFixture(), roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        let gate = try stationGate(f, roster: roster), evidence = try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: f.log)
        let request = try f.review().signingRequest(managerID: "manager"), old = evidence.begin(), current = evidence.begin()
        try evidence.receive(stationSnapshot(f), for: current)
        XCTAssertThrowsError(try evidence.receive(stationSnapshot(f), for: old))
        evidence.failed(old)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        let pending = evidence.begin()
        evidence.failed(pending)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try evidence.receive(stationSnapshot(f), for: pending))
        try evidence.receive(stationSnapshot(f), for: evidence.begin())
        evidence.disconnect()
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testStationRosterChangesDowngradeAndStaleProcessGenerationInvalidateEveryReplica() throws {
        for fault in ["missing", "removed", "roster", "head", "account", "downgrade", "generation"] {
            let f = try VerifierFixture(), roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
            let gate = try stationGate(f, roster: roster), evidence = try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: f.log)
            let request = try f.review().signingRequest(managerID: "manager")
            try evidence.receive(stationSnapshot(f), for: evidence.begin())
            XCTAssertNoThrow(try gate.authorize(request, log: f.log))
            let changed = try stationSnapshot(f, fault: fault)
            if fault == "missing" { try evidence.receive(changed, for: evidence.begin()) }
            else { XCTAssertThrowsError(try evidence.receive(changed, for: evidence.begin()), fault) }
            XCTAssertThrowsError(try gate.authorize(request, log: f.log), fault)
        }
    }

    @MainActor
    private func stationGate(_ f: VerifierFixture, roster: RemoteStationVerifierRoster,
                             now: @escaping () -> UInt64 = { 100 }) throws -> RemoteVerifierSigningGate {
        let others: [RemoteVerifierID] = [.host("host"), .member("manager"), .other("sdk")]
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: others + roster.replicas.map(roster.verifierID), now: now)
        for id in others {
            let connection = try gate.connect(id)
            if case .host = id { try gate.observeHostWelcome(f.welcome(), on: connection) }
            else { try gate.observeConsumer(verifierInventory(), on: connection) }
        }
        return gate
    }

    @MainActor
    private func stationSnapshot(_ f: VerifierFixture, started: UInt64 = 100, fault: String = "") throws -> RemoteStationVerifierSnapshot {
        let inventory = verifierInventory()
        var rows: [[String: Any]] = ["a", "b"].map { ["id": $0, "connection_generation": 2,
            "verifier": ["version": inventory.version, "actions": inventory.actions], "authorization_ms_left": 300] }
        switch fault {
        case "missing": rows[1] = ["id": "b", "connection_generation": 2]
        case "removed": rows.removeLast()
        case "downgrade": rows[1]["verifier"] = ["version": 1, "actions": ["add"]]
        case "generation": rows[1]["connection_generation"] = 1
        default: break
        }
        let origin = "https://station.example"
        let object: [String: Any] = ["origin": origin, "roster_generation": fault == "roster" ? 2 : 1,
            "account_id": fault == "account" ? "other" : f.log.accountId(), "genesis_hash": f.log.genesisHash(),
            "head": ["seq": fault == "head" ? f.log.head().seq + 1 : f.log.head().seq, "hash": f.log.head().hash], "replicas": rows]
        return try RemoteStationVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: object), origin: origin,
            genesis: f.log.genesisHash(), startedAt: started)
    }

    @MainActor
    func testChannelRecordsEvidenceBeforeReadyAndRetiresItOnEveryClosePath() async throws {
        for reason in ["disconnect", "link", "fence", "read failure", "expiry"] {
            let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
            var time: UInt64 = 100
            let (gate, _) = try f.confirmedGate(now: { time })
            var ready = false
            let h = VerifierChannelHarness(gate: gate, welcome: f.welcome(), now: { time }, ready: {
                ready = true
                do { try gate.authorize(request, log: f.log) }
                catch { XCTFail("Evidence was not recorded before ready: \(error)") }
            }, update: { event in
                if case .fenced = event {
                    do { try gate.authorize(request, log: f.log); XCTFail("Fence callback retained signing evidence") }
                    catch { }
                }
            })
            try h.channel.start()
            XCTAssertThrowsError(try gate.authorize(request, log: f.log), reason)
            try await h.welcome()
            XCTAssertTrue(ready, reason)
            switch reason {
            case "disconnect": h.channel.disconnect()
            case "link": h.channel.linkLost(generation: h.route.linkGeneration)
            case "fence":
                h.core.events = [.fenced(code: "unauthorized", detail: nil, json: "{}")]
                h.channel.receive(Data(), from: h.route)
            case "read failure":
                h.core.receiveError = RemoteChannelError.invalidInput
                h.channel.receive(Data(), from: h.route)
            default:
                time = 1_100
                h.channel.checkDeadline()
            }
            XCTAssertEqual(h.channel.phase, .closed, reason)
            XCTAssertThrowsError(try gate.authorize(request, log: f.log), reason)
        }
    }

    @MainActor
    func testChangedHostHeadInvalidatesEvidenceBeforeItsCallback() async throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, _) = try f.confirmedGate()
        var changed = false
        let h = VerifierChannelHarness(gate: gate, welcome: f.welcome(), update: { event in
            if case .membershipHead(_, let head, _) = event, head != f.log.head() {
                changed = true
                do { try gate.authorize(request, log: f.log); XCTFail("Changed-head callback retained signing evidence") }
                catch { }
            }
        })
        try await h.welcome()
        h.core.events = [.membershipHead(re: nil, head: f.log.head(), pendingRecovery: [])]
        h.channel.receive(Data(), from: h.route)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        h.core.events = [.membershipHead(re: nil,
            head: LogHead(seq: f.log.head().seq + 1, hash: String(repeating: "a", count: 64)), pendingRecovery: [])]
        h.channel.receive(Data(), from: h.route)
        XCTAssertTrue(changed)
        XCTAssertEqual(h.channel.phase, .ready)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testRetiredChannelCannotConfirmOrInvalidateTheReplacement() async throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, _) = try f.confirmedGate()
        let old = VerifierChannelHarness(gate: gate, welcome: f.welcome())
        try old.channel.start()
        let fresh = VerifierChannelHarness(gate: gate, welcome: f.welcome())
        try await fresh.welcome()
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        try await old.welcome()
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        old.channel.linkLost(generation: old.route.linkGeneration)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        fresh.channel.disconnect()
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testUnconfirmedHostKeepsOrdinaryChannelUsableButCannotAuthorizeSigning() async throws {
        for inventory in [nil, VerifierInventory(version: 2, actions: ["host_sender_revoke", "host_sender_revoke"])] {
            let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
            let (gate, _) = try f.confirmedGate()
            let h = VerifierChannelHarness(gate: gate, welcome: f.welcome(inventory: inventory))
            try await h.welcome()
            XCTAssertNoThrow(try h.channel.perform(.list))
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
            h.channel.disconnect()
        }
    }

    @MainActor
    func testChannelDisposalAndFailedHandshakeNeverLeaveEvidenceUsable() async throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, _) = try f.confirmedGate()
        var h: VerifierChannelHarness? = VerifierChannelHarness(gate: gate, welcome: f.welcome())
        try await h!.welcome()
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        h = nil
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        let failed = VerifierChannelHarness(gate: gate, welcome: f.welcome())
        failed.core.startError = RemoteChannelError.invalidInput
        XCTAssertThrowsError(try failed.channel.start())
        XCTAssertEqual(failed.channel.phase, .closed)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testEnumeratedAccountRequiresEveryHostMemberReplicaAndOtherSDK() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        for missing in [RemoteVerifierID.host("host"), .member("manager")] {
            XCTAssertThrowsError(try RemoteVerifierSigningGate(log: f.log, verifiers: f.roster.filter { $0 != missing }))
        }
        XCTAssertThrowsError(try RemoteVerifierSigningGate(log: f.log, verifiers: [.host("host"), .member("manager")]))
        XCTAssertThrowsError(try RemoteVerifierSigningGate(log: f.log, verifiers: f.roster + [.member("manager")]))
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: f.roster)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        for (index, id) in f.roster.enumerated() {
            let connection = try gate.connect(id)
            if case .host = id { try gate.observeHostWelcome(f.welcome(), on: connection) }
            else { try gate.observeConsumer(verifierInventory(), on: connection) }
            if index < f.roster.count - 1 { XCTAssertThrowsError(try gate.authorize(request, log: f.log)) }
        }
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testReconnectMissingWelcomeAndDelayedOldReportsNeverRestoreConfirmation() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, links) = try f.confirmedGate(), old = try XCTUnwrap(links[.host("host")])
        let new = try gate.connect(.host("host"))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: old))
        try gate.observeHostWelcome(f.welcome(inventory: nil), on: new)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeHostWelcome(f.welcome(), on: new)
        gate.disconnect(old)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        gate.disconnect(new)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        // A process restart has no live evidence, even if the same roster is loaded.
        let restarted = try RemoteVerifierSigningGate(log: f.log, verifiers: f.roster)
        XCTAssertThrowsError(try restarted.authorize(request, log: f.log))
    }

    @MainActor
    func testHostAuthorizationExpiresAtSigningEvenBeforeTheCloseCallback() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, _) = try f.confirmedGate(now: { time })
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 1_099
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        // No timer, disconnect callback or fresh report is needed to stop signing.
        time = 1_100
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testReobservedWelcomeCannotRenewButFreshConnectionCan() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, links) = try f.confirmedGate(now: { time })
        let old = try XCTUnwrap(links[.host("host")])
        time = 900
        try gate.observeHostWelcome(f.welcome(), on: old)
        time = 1_100
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeHostWelcome(f.welcome(), on: old)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeHostWelcome(f.welcome(inventory: nil), on: old)
        try gate.observeHostWelcome(f.welcome(), on: old)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))

        let fresh = try gate.connect(.host("host"))
        try gate.observeHostWelcome(f.welcome(), on: fresh)
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: old, receivedAt: 100))
        gate.disconnect(old)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 2_100
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testDelayedWelcomeKeepsItsOriginalAuthorizationDeadline() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, links) = try f.confirmedGate(now: { time })
        let connection = try gate.connect(.host("host"))
        time = 900
        try gate.observeHostWelcome(f.welcome(), on: connection, receivedAt: 100)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        time = 1_100
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))

        let delayed = try gate.connect(.host("host"))
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: delayed, receivedAt: 100))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        gate.disconnect(try XCTUnwrap(links[.host("host")]))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testInitiallyMissingOrInvalidInventoryCannotShiftTheFirstDeadline() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, _) = try f.confirmedGate(now: { time })
        for inventory in [nil, VerifierInventory(version: 0, actions: [])] {
            time = 100
            let connection = try gate.connect(.host("host"))
            if inventory == nil { try gate.observeHostWelcome(f.welcome(inventory: nil), on: connection) }
            else { XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(inventory: inventory), on: connection)) }
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
            time = 1_100
            try gate.observeHostWelcome(f.welcome(), on: connection)
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        }
    }

    @MainActor
    func testInitiallyExpiredWelcomeCannotBeRevivedOnTheSameConnection() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, _) = try f.confirmedGate(now: { time })
        let expired = try gate.connect(.host("host"))
        time = 1_100
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: expired, receivedAt: 100))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        time = 1_101
        try gate.observeHostWelcome(f.welcome(), on: expired)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeHostWelcome(f.welcome(inventory: nil), on: expired)
        try gate.observeHostWelcome(f.welcome(), on: expired)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))

        let fresh = try gate.connect(.host("host"))
        try gate.observeHostWelcome(f.welcome(), on: fresh)
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: expired, receivedAt: 100))
        gate.disconnect(expired)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testFutureTimestampAndDeadlineOverflowCannotConfirmAHost() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        var time: UInt64 = 100
        let (gate, links) = try f.confirmedGate(now: { time })
        let connection = try XCTUnwrap(links[.host("host")])
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: connection, receivedAt: 101))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        let fresh = try gate.connect(.host("host"))
        time = UInt64.max - 500
        XCTAssertThrowsError(try gate.observeHostWelcome(f.welcome(), on: fresh, receivedAt: time))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testInvalidLowerVersionAndNarrowedReportsInvalidatePreviousEvidence() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, links) = try f.confirmedGate(), link = try XCTUnwrap(links[.stationReplica("b")])
        let current = verifierInventory()
        var cases = [VerifierInventory(version: 0, actions: current.actions),
            VerifierInventory(version: 2, actions: current.actions.reversed()),
            VerifierInventory(version: 2, actions: current.actions + [current.actions[0]]),
            VerifierInventory(version: 2, actions: ["Bad"]), VerifierInventory(version: 2, actions: ["1bad"]),
            VerifierInventory(version: 2, actions: [String(repeating: "a", count: 33)]),
            VerifierInventory(version: 2, actions: []), VerifierInventory(version: 1, actions: current.actions)]
        cases.append(VerifierInventory(version: 3, actions: current.actions.filter { $0 != "host_sender_revoke" }))
        for invalid in cases {
            XCTAssertThrowsError(try gate.observeConsumer(invalid, on: link))
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
            try gate.observeConsumer(current, on: link)
        }
        let future = VerifierInventory(version: 3, actions: (current.actions + ["future_action"]).sorted())
        try gate.observeConsumer(future, on: link)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try gate.observeConsumer(current, on: link))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testHostReportCannotComeFromPresenceOrAnotherAccountHeadOrTrustGeneration() throws {
        let f = try VerifierFixture(), request = try f.review().signingRequest(managerID: "manager")
        let (gate, links) = try f.confirmedGate(), host = try XCTUnwrap(links[.host("host")])
        XCTAssertThrowsError(try gate.observeConsumer(verifierInventory(), on: host))
        for field in ["account", "host", "head", "trust", "revision", "expired"] {
            var bad = f.welcome()
            switch field {
            case "account": bad.accountId = "other"
            case "host": bad.atemDeviceId = "other"
            case "head": bad.head.hash = String(repeating: "f", count: 64)
            case "trust": bad.hostTrustGen += 1
            case "revision": bad.revision = 8
            default: bad.authorizationMsLeft = 0
            }
            XCTAssertThrowsError(try gate.observeHostWelcome(bad, on: host))
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
            try gate.observeHostWelcome(f.welcome(), on: host)
        }
        try f.append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 2,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(f.keys.key.publicKey.rawRepresentation)]]])
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testHostSenderReviewUsesExactSharedRequestAndCannotChangeInterruptionAfterReview() throws {
        let f = try VerifierFixture(), review = try f.review(.revoke(interruptRunning: true))
        try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        XCTAssertEqual(try review.signingRequest(managerID: "manager").purpose, .hostSender)
        XCTAssertEqual(f.keys.signs, 0)
        XCTAssertNotNil(f.checkpoint)
        let other = try f.review(.revoke(interruptRunning: false))
        XCTAssertThrowsError(try other.sign(publication: f.publication, provider: f.keys, managerID: "manager",
            validationClock: f.clock, confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertThrowsError(try review.sign(publication: f.publication, provider: f.keys, managerID: "manager",
            validationClock: f.clock, confirmedAt: 100, now: { 30_100 }, current: { true }))
        XCTAssertEqual(f.keys.signs, 0)
        let append = try review.sign(publication: f.publication, provider: f.keys, managerID: "manager",
            validationClock: f.clock, confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertEqual(try signedObjectInfo(json: append.entryJson).bodyJcs, review.bodyJSON)
        XCTAssertEqual(f.keys.signs, 1)
        XCTAssertThrowsError(try f.review(.readmit), "readmit is only valid after revoke")
    }

    @MainActor
    func testVersionOneScopeOpsRequireReportsFromEveryVerifierIncludingTheNewService() throws {
        let f = try VerifierFixture()
        let action: [String: Any] = ["action": "add", "member": ["device_id": "service", "kind": "service", "roles": ["service"],
            "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(f.keys.key.publicKey.rawRepresentation)],
            "scope": ["hosts": ["host"], "ops": ["launch", "view"]], "expires_at": f.clock.wallMs + 3_600_000]]
        let body = try f.log.draftEntry(signer: "manager", signedAt: f.clock.wallMs,
            actionJson: String(decoding: JSONSerialization.data(withJSONObject: action), as: UTF8.self))
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager")
        let (missing, _) = try f.confirmedGate()
        XCTAssertThrowsError(try missing.authorize(request, log: f.log), "The prospective service verifier must also be enumerated")
        let roster = f.roster + [.member("service")]
        var time: UInt64 = 100
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: roster, wall: { f.clock.wallMs }, now: { time })
        let newActions: Set<String> = ["host_enc_key", "host_sender_readmit", "host_sender_revoke", "project_remove", "project_set"]
        let v1 = VerifierInventory(version: 1, actions: verifierInventory().actions.filter { !newActions.contains($0) })
        var service: RemoteVerifierSigningGate.Connection?
        for id in roster {
            let connection = try gate.connect(id)
            if case .host = id { try gate.observeHostWelcome(f.welcome(inventory: v1), on: connection) }
            else { try gate.observeConsumer(v1, on: connection) }
            if id == .member("service") { service = connection }
        }
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "Generic member evidence cannot confirm a prospective enrollment")
        let serviceLink = try XCTUnwrap(service)
        try gate.observeProspectiveMember(v1, request: request, on: serviceLink, receivedAt: 100, authorizationMilliseconds: 1000)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try gate.authorize(f.review().signingRequest(managerID: "manager"), log: f.log), "The new actions need v2")
        try gate.observeConsumer(nil, on: serviceLink)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeConsumer(v1, on: serviceLink)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "A generic report cannot revive the exact-request binding")
        try gate.observeProspectiveMember(v1, request: request, on: serviceLink, receivedAt: 100, authorizationMilliseconds: 1000)
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        var invalid = request; invalid.keyId = "another-manager"
        XCTAssertThrowsError(try gate.observeProspectiveMember(v1, request: invalid, on: serviceLink,
            receivedAt: 100, authorizationMilliseconds: 1000))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "Invalid observations retire the old exact-request evidence")
        try gate.observeProspectiveMember(v1, request: request, on: serviceLink, receivedAt: 100, authorizationMilliseconds: 1000)
        gate.disconnect(serviceLink)
        let replacement = try gate.connect(.member("service"))
        try gate.observeConsumer(v1, on: replacement)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try gate.observeProspectiveMember(v1, request: request, on: replacement, receivedAt: 100, authorizationMilliseconds: 1000)
        XCTAssertThrowsError(try gate.observeProspectiveMember(v1, request: request, on: serviceLink,
            receivedAt: 100, authorizationMilliseconds: 1000))
        XCTAssertNoThrow(try gate.authorize(request, log: f.log), "Retired connections cannot invalidate newer exact-request evidence")
        time = 1100
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testManagedServiceEvidenceRequiresEveryReplicaTheExistingKeyAndFiniteLifetime() throws {
        let f = try VerifierFixture(), key = P256.Signing.PrivateKey().publicKey.x963Representation
        let service = "svc-i-01234567890123456789012345"
        try f.append(["action": "add", "member": ["device_id": service, "kind": "service", "roles": ["service"],
            "auth_key": ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(key)],
            "scope": ["hosts": ["host"], "ops": ["view"]], "expires_at": f.clock.wallMs + 3_600_000]])
        let roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        var time: UInt64 = 100
        let required = f.roster.filter { if case .stationReplica = $0 { return false }; return true }
            + roster.replicas.map(roster.verifierID) + [.member(service)]
        var wall = f.clock.wallMs
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: required, wall: { wall }, now: { time })
        for id in f.roster {
            if case .stationReplica = id { continue }
            let connection = try gate.connect(id)
            if case .host = id { try gate.observeHostWelcome(f.welcome(), on: connection) }
            else { try gate.observeConsumer(verifierInventory(), on: connection) }
        }
        let source = try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: [service])
        let request = try f.review().signingRequest(managerID: "manager")
        func snapshot(key supplied: Data? = key, missingReplica: Bool = false, lifetime: UInt64 = 500) throws -> RemoteManagedServiceVerifierSnapshot {
            let inventory = verifierInventory()
            let replicas: [[String: Any]] = [
                ["id": "a", "connection_generation": 1, "verifier": ["version": inventory.version, "actions": inventory.actions], "authorization_ms_left": lifetime],
                missingReplica ? ["id": "b"] : ["id": "b", "connection_generation": 1,
                    "verifier": ["version": inventory.version, "actions": inventory.actions], "authorization_ms_left": lifetime]]
            var row: [String: Any] = ["id": service]
            if let supplied { row["auth_key"] = ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(supplied)] }
            return try RemoteManagedServiceVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: ["origin": roster.origin,
                "roster_generation": roster.generation, "account_id": f.log.accountId(), "genesis_hash": f.log.genesisHash(),
                "head": ["seq": f.log.head().seq, "hash": f.log.head().hash], "replicas": replicas, "services": [row]]),
                origin: roster.origin, genesis: f.log.genesisHash(), memberIDs: [service], startedAt: 100)
        }
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try source.receive(snapshot(), for: source.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        for missing in [try snapshot(key: nil), try snapshot(key: P256.Signing.PrivateKey().publicKey.x963Representation),
                        try snapshot(missingReplica: true)] {
            try source.receive(missing, for: source.begin())
            XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        }
        try source.receive(snapshot(), for: source.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        let old = try source.begin(), newer = try source.begin()
        try source.receive(snapshot(), for: newer)
        source.failed(old)
        XCTAssertThrowsError(try source.receive(snapshot(key: nil), for: old))
        XCTAssertNoThrow(try gate.authorize(request, log: f.log), "Retired polls cannot invalidate a newer report")
        let failed = try source.begin()
        source.failed(failed)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        try source.receive(snapshot(), for: source.begin())
        time = 600
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "The shortest finite service/replica lifetime expired")
        XCTAssertThrowsError(try source.receive(snapshot(), for: source.begin()), "Replaying old bytes cannot extend their lifetime")
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        // A fresh lease on every replica still expires at the signed service deadline.
        wall = f.clock.wallMs + 3_600_000 - 1
        try source.receive(snapshot(lifetime: 1_000), for: source.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        wall += 1
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
        wall = f.clock.wallMs
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "A wall clock correction cannot restore expired evidence")
        source.retire()
        XCTAssertThrowsError(try source.begin())
    }

    @MainActor
    func testManagedServiceSourcesCannotRepresentNativeMembersOrAnotherGateAnchor() throws {
        let f = try VerifierFixture()
        let roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        let (gate, _) = try f.confirmedGate()
        XCTAssertThrowsError(try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: ["manager"]))
        try f.append(["action": "host_sender_revoke", "host_id": "host", "interrupt_running": false])
        XCTAssertThrowsError(try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: ["unknown"]))
    }

    @MainActor
    func testProspectiveManagedServiceEvidenceBindsTheExactUnsignedEnrollmentBeforeAnySignature() throws {
        let f = try VerifierFixture(), raw = P256.Signing.PrivateKey().publicKey.x963Representation
        let id = "svc-i-01234567890123456789012345"
        let member: [String: Any] = ["device_id": id, "kind": "service", "roles": ["service"],
            "auth_key": ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(raw)],
            "scope": ["hosts": ["host"], "ops": ["launch", "view"]], "expires_at": f.clock.wallMs + 3_600_000]
        let body = try f.log.draftEntry(signer: "manager", signedAt: f.clock.wallMs,
            actionJson: String(decoding: JSONSerialization.data(withJSONObject: ["action": "add", "member": member]), as: UTF8.self))
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager")
        let roster = try RemoteStationVerifierRoster(origin: "https://station.example", generation: 1, replicas: ["a", "b"])
        let required = f.roster.filter { if case .stationReplica = $0 { return false }; return true }
            + roster.replicas.map(roster.verifierID) + [.member(id)]
        var wall = f.clock.wallMs
        var tick: UInt64 = 100
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: required, wall: { wall }, now: { tick })
        for verifier in f.roster {
            if case .stationReplica = verifier { continue }
            let connection = try gate.connect(verifier)
            if case .host = verifier { try gate.observeHostWelcome(f.welcome(), on: connection) }
            else { try gate.observeConsumer(verifierInventory(), on: connection) }
        }
        XCTAssertThrowsError(try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: [id]))
        let source = try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: [id], prospectiveRequest: request)
        let inventory = verifierInventory()
        let snapshot = try RemoteManagedServiceVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: [
            "origin": roster.origin, "roster_generation": 1, "account_id": f.log.accountId(), "genesis_hash": f.log.genesisHash(),
            "head": ["seq": f.log.head().seq, "hash": f.log.head().hash], "services": [["id": id, "auth_key": member["auth_key"]!]],
            "replicas": roster.replicas.map { ["id": $0, "connection_generation": 1,
                "verifier": ["version": inventory.version, "actions": inventory.actions], "authorization_ms_left": 1000] }]),
            origin: roster.origin, genesis: f.log.genesisHash(), memberIDs: [id], startedAt: 100)
        let signs = f.keys.signs
        try source.receive(snapshot, for: source.begin())
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        for change in ["key", "scope", "expiry", "signed_at"] {
            var changedMember = member
            var signedAt = f.clock.wallMs
            switch change {
            case "key": changedMember["auth_key"] = ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(P256.Signing.PrivateKey().publicKey.x963Representation)]
            case "scope": changedMember["scope"] = ["hosts": ["host"], "ops": ["launch", "message", "view"]]
            case "expiry": changedMember["expires_at"] = f.clock.wallMs + 7_200_000
            default: signedAt += 1
            }
            let changedBody = try f.log.draftEntry(signer: "manager", signedAt: signedAt,
                actionJson: String(decoding: JSONSerialization.data(withJSONObject: ["action": "add", "member": changedMember]), as: UTF8.self))
            let changed = try RemoteConfirmedSigner.membershipRequest(bodyJSON: changedBody, keyID: "manager")
            XCTAssertNotEqual(changed, request)
            XCTAssertThrowsError(try gate.authorize(changed, log: f.log), "Evidence for request A cannot authorize B with a different \(change)")
            XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        }
        XCTAssertEqual(f.keys.signs, signs, "Inventory never signs the enrollment")
        XCTAssertNil(f.log.member(deviceId: id))
        var wrong = request; wrong.bodyJson = body.replacingOccurrences(of: "\"account\"", with: "\"another-account\"")
        XCTAssertThrowsError(try RemoteManagedServiceVerifierEvidence(gate: gate, roster: roster, log: f.log, memberIDs: [id], prospectiveRequest: wrong))
        wall = f.clock.wallMs + 3_600_000 - 1
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        wall = f.clock.wallMs
        tick += 1
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "Elapsed time exhausted the proposed membership before the replica leases")
        source.retire()
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }
}
