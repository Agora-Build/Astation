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

    func confirmedGate() throws -> (RemoteVerifierSigningGate, [RemoteVerifierID: RemoteVerifierSigningGate.Connection]) {
        let gate = try RemoteVerifierSigningGate(log: log, verifiers: roster)
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

final class RemoteVerifierSigningGateTests: XCTestCase {
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
        let gate = try RemoteVerifierSigningGate(log: f.log, verifiers: roster)
        let newActions: Set<String> = ["host_enc_key", "host_sender_readmit", "host_sender_revoke", "project_remove", "project_set"]
        let v1 = VerifierInventory(version: 1, actions: verifierInventory().actions.filter { !newActions.contains($0) })
        var service: RemoteVerifierSigningGate.Connection?
        for id in roster {
            let connection = try gate.connect(id)
            if case .host = id { try gate.observeHostWelcome(f.welcome(inventory: v1), on: connection) }
            else { try gate.observeConsumer(v1, on: connection) }
            if id == .member("service") { service = connection }
        }
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))
        XCTAssertThrowsError(try gate.authorize(f.review().signingRequest(managerID: "manager"), log: f.log), "The new actions need v2")
        try gate.observeConsumer(nil, on: XCTUnwrap(service))
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }
}
