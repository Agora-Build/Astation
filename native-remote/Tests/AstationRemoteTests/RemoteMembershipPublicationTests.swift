import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private func b64u(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
}

private actor IntegrationApprovalTestHTTP: AccountOIDCHTTP {
    var reply = Data()
    var status = 200
    private var requests: [URLRequest] = []
    func set(_ object: [String: Any], status: Int = 200) throws {
        reply = try JSONSerialization.data(withJSONObject: object)
        self.status = status
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (reply, status)
    }
    func last() -> URLRequest? { requests.last }
    func count() -> Int { requests.count }
}

private final class PublicationKeys: AppKeyProvider, @unchecked Sendable {
    // Test-only software manager. Production supplies its native protected key provider.
    let key = Curve25519.Signing.PrivateKey()
    var requests: [SignRequest] = []
    var beforeSign: (() throws -> Void)?
    var denied = false

    func publicKey(keyId: String) throws -> PublicKeyData {
        PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation)
    }
    func sign(request: SignRequest) throws -> Data {
        try beforeSign?()
        requests.append(request)
        if denied { throw RemotePublicationError.busy }
        return try key.signature(for: request.input)
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemotePublicationError.busy }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw RemotePublicationError.busy
    }
}

@MainActor
private final class PublicationFixture {
    let keys = PublicationKeys()
    let clock = HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "publication-test")
    let log: MembershipLog
    var stored: Data?
    var writes = 0
    var failWrite = false
    var onPersist: (() throws -> Void)?
    private var active: RemoteMembershipPublication?
    var publication: RemoteMembershipPublication {
        if let active { return active }
        let created = RemoteMembershipPublication(log: log, persist: { [unowned self] in try persist($0) })
        active = created
        return created
    }

    init() throws {
        let body: [String: Any] = [
            "type": "atem-membership-entry", "v": 1, "account_id": "account-a",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64),
            "action": "genesis", "signer": "manager-a", "signed_at": clock.wallMs,
            "member": ["device_id": "manager-a", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "ed25519", "pub": b64u(keys.key.publicKey.rawRepresentation)],
                "enc_key": ["alg": "x25519", "pub": b64u(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]],
            "recovery_key": ["alg": "ed25519", "pub": b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]
        ]
        let info = try signedObjectInfo(json: json(["body": body, "sig": b64u(Data(repeating: 0, count: 64))]))
        let entry = try json(["body": body, "sig": b64u(keys.key.signature(for: info.signingInput))])
        log = try MembershipLog.verify(accountId: "account-a", genesisHash: XCTUnwrap(info.entryHash),
            entries: [entry], now: clock)
    }

    func persist(_ bytes: Data) throws {
        writes += 1
        try onPersist?()
        if failWrite { throw RemotePublicationError.storageUncertain }
        stored = bytes
    }

    func action(_ host: String = "host-a", generation: UInt64 = 3) throws -> String {
        try json(["action": "add_host", "host": ["host_id": host, "host_trust_gen": generation,
            "host_key": ["alg": "ed25519", "pub": b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]])
    }

    func prepare() throws {
        try publication.prepare(actionJSON: action(), signer: "manager-a", signedAt: clock.wallMs)
    }

    func restore() throws -> RemoteMembershipPublication {
        active = nil // A restart drops the old core and its process-wide publisher claim.
        return try RemoteMembershipPublication(checkpoint: XCTUnwrap(stored), accountID: log.accountId(),
            genesisHash: log.genesisHash(), now: clock, persist: { [unowned self] in try persist($0) })
    }
}

final class RemoteMembershipPublicationTests: XCTestCase {
    @MainActor
    func testUnselectedHostIsExplainedBeforeTokenAccessOrProvisioning() async throws {
        let f = try PublicationFixture(), approval = try serviceApproval(f)
        let transport = IntegrationApprovalTestHTTP()
        let client = try StationIntegrationHTTP(origin: approval.stationOrigin, http: transport,
            accessToken: { XCTFail("Selecting a host must precede token access"); throw AccountLoginError.unavailable })
        let record = try JSONDecoder().decode(PortalIntegrationRecord.self, from: JSONSerialization.data(withJSONObject: [
            "id": approval.integrationID, "name": "Test integration", "stationOrigin": approval.stationOrigin,
            "state": "awaiting_approval", "scopes": ["agent.view"], "expiresAt": "2099-01-01T00:00:00Z", "role": "owner"]))
        do {
            _ = try await client.prepare(record: record, ownerAccount: approval.ownerAccount, issuer: approval.issuer,
                log: f.log, managerID: "manager-a", hosts: [], sessions: nil, projects: nil, signedAt: f.clock.wallMs)
            XCTFail("An integration must have an explicitly selected host")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Select at least one verified Atem host before reviewing access.")
        }
        let count = await transport.count()
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testStationDraftTransportBindsOwnerRootOriginAndExactReviewedScope() async throws {
        let f = try PublicationFixture(), approval = try serviceApproval(f)
        let transport = IntegrationApprovalTestHTTP()
        let client = try StationIntegrationHTTP(origin: approval.stationOrigin, http: transport, accessToken: { "native-station-token" })
        let record = try JSONDecoder().decode(PortalIntegrationRecord.self, from: JSONSerialization.data(withJSONObject: [
            "id":approval.integrationID,"name":"Test integration","stationOrigin":approval.stationOrigin,"state":"awaiting_approval",
            "scopes":["agent.view","agent.prompt"],"expiresAt":"2099-01-01T00:00:00Z","role":"owner"]))
        var draft: [String: Any] = ["integrationId":approval.integrationID,"ownerAccount":approval.ownerAccount,"issuer":approval.issuer,
            "stationOrigin":approval.stationOrigin,"genesisHash":approval.genesisHash,"bodyJSON":approval.bodyJSON,"fingerprint":approval.fingerprint]
        try await transport.set(draft)
        let response = try await client.prepare(record: record, ownerAccount: approval.ownerAccount, issuer: approval.issuer,
            log: f.log, managerID: "manager-a", hosts: ["host-a"], sessions: nil, projects: nil, signedAt: f.clock.wallMs)
        XCTAssertEqual(response.fingerprint, approval.fingerprint)
        let sent = await transport.last()
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.url?.absoluteString, approval.stationOrigin + "/agora-build/v1/integrations/" + approval.integrationID + "/provision")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-station-token")
        let review = try RemoteServiceReview(approval: approval)
        let now = Date(timeIntervalSince1970: Double(f.clock.wallMs) / 1000)
        try review.check(record: record, hosts: ["host-a"], sessions: nil, projects: nil, now: now)
        XCTAssertThrowsError(try review.check(record: record, hosts: ["other-host"], sessions: nil, projects: nil, now: now))
        XCTAssertThrowsError(try review.check(record: record, hosts: ["host-a"], sessions: ["ses-aaaaaaaaaaaa"], projects: nil, now: now))
        draft["ownerAccount"] = "ab99999999999999999999999999"; try await transport.set(draft)
        do {
            _ = try await client.prepare(record: record, ownerAccount: approval.ownerAccount, issuer: approval.issuer,
                log: f.log, managerID: "manager-a", hosts: ["host-a"], sessions: nil, projects: nil, signedAt: f.clock.wallMs)
            XCTFail("Station cannot substitute an owner")
        } catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
    }

    func testServiceFingerprintMatchesBothPublicAuthVectors() throws {
        let cases: [(KeyAlg, String, Int, String)] = [
            (.p256, "BNa0CKl9dCuZMEg6WPNIaZatMGhIKeCElX2Pc8FA3H2v8Iezbt5Glq2FKvXNzpwYxjaRpx_aqnXuXSTjG4kQq90", 65,
             "9af59dce1292f9401b3fa89bbd050b1671bddfccc5ace04a2402bacffda5e5d6"),
            (.ed25519, "ggpM_o3M3L3H4slbWlvWcIkSew9H-qMEWi49Py_wbkE", 32,
             "837e9176e9bcaffae6ca630d56ded10fb7d8d2b6cfe2d7d19499a483c3ba2cf4")
        ]
        for (alg, encoded, count, expected) in cases {
            let key = PublicKeyData(alg: alg, raw: try XCTUnwrap(RemoteRecoveryKit.decodeBase64URL(encoded, count: count)))
            XCTAssertEqual(try RemoteServiceKeyFingerprint.compute(key), expected)
        }
        XCTAssertThrowsError(try RemoteServiceKeyFingerprint.compute(PublicKeyData(alg: .p256, raw: Data(repeating: 0, count: 65))))
        XCTAssertThrowsError(try RemoteServiceKeyFingerprint.compute(PublicKeyData(alg: .x25519, raw: Data(repeating: 1, count: 32))))
    }
    @MainActor
    private func serviceApproval(_ f: PublicationFixture) throws -> RemoteServiceApproval {
        let action = try json(["action": "add", "member": [
            "device_id": "service-a", "kind": "service", "roles": ["service"],
            "auth_key": ["alg": "ed25519", "pub": b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)],
            "scope": ["hosts": ["host-a"], "ops": ["prompt", "view"]],
            "expires_at": f.clock.wallMs + 60_000
        ]])
        let body = try f.log.draftEntry(signer: "manager-a", signedAt: f.clock.wallMs, actionJson: action)
        return try RemoteServiceApproval(operationID: "setup-a", integrationID: "i-01234567890123456789012345",
            issuer: "https://auth.example", ownerAccount: "ab01234567890123456789012345",
            stationOrigin: "https://custom.example", bodyJSON: body, log: f.log, managerID: "manager-a", now: f.clock)
    }

    @MainActor
    func testServiceConsentSurvivesRestartAndSignsTheExactReviewedBodyOnce() throws {
        let f = try PublicationFixture()
        let approval = try serviceApproval(f)
        let request = try approval.prepare(publication: f.publication, managerID: "manager-a", now: f.clock)
        XCTAssertEqual(request.purpose, .enroll)
        XCTAssertTrue(request.freshConfirmation)
        XCTAssertEqual(f.keys.requests.count, 0)
        let restored = try f.restore()
        XCTAssertEqual(try JSONDecoder().decode(RemoteServiceApproval.self, from: XCTUnwrap(restored.operationContext)), approval)
        let append = try approval.sign(publication: restored, provider: f.keys, managerID: "manager-a", validationClock: f.clock,
            confirmedAt: 100, now: { 100 }, current: { true })
        let duplicate = try approval.sign(publication: restored, provider: f.keys, managerID: "manager-a", validationClock: f.clock,
            confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertEqual(append, duplicate)
        XCTAssertEqual(f.keys.requests.count, 1)
        XCTAssertEqual(try signedObjectInfo(json: append.entryJson).bodyJcs, approval.bodyJSON)
        guard case .committed = try restored.relayStored(now: f.clock) else { return XCTFail("Expected commit") }
        let member = try XCTUnwrap(restored.committedLog().member(deviceId: "service-a"))
        XCTAssertEqual(member.roles, ["service"])
        XCTAssertEqual(try RemoteServiceKeyFingerprint.compute(member.authKey), approval.fingerprint)
        XCTAssertNil(member.encKey)
    }

    @MainActor
    func testPortalApprovalWaitsForDurableExactMembershipAndRejectsChangedContext() async throws {
        let f = try PublicationFixture()
        let approval = try serviceApproval(f)
        let transport = IntegrationApprovalTestHTTP()
        let config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation",
            resource: "https://portal.example", requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
        let http = try PortalIntegrationHTTP(configuration: config, portalOrigin: config.resource,
            ownerAccount: approval.ownerAccount, http: transport, accessToken: { "native-portal-token" })
        let now = Date(timeIntervalSince1970: Double(f.clock.wallMs) / 1000)
        let record: [String: Any] = ["id": approval.integrationID, "name": "My API", "stationOrigin": approval.stationOrigin,
            "state": "provisioning", "scopes": ["agent.view", "agent.prompt"], "r9Svc": approval.fingerprint,
            "expiresAt": "2099-01-01T00:00:00.000Z", "role": "owner"]
        try await transport.set(record)
        _ = try approval.prepare(publication: f.publication, managerID: "manager-a", now: f.clock)
        _ = try approval.sign(publication: f.publication, provider: f.keys, managerID: "manager-a",
            validationClock: f.clock, confirmedAt: 100, now: { 100 }, current: { true })
        do {
            _ = try await http.approve(approval, publication: f.publication, current: { true }, now: now)
            XCTFail("Signing without durable membership publication must not approve at Auth")
        } catch {}
        let before = await transport.count()
        XCTAssertEqual(before, 0)
        _ = try f.publication.relayStored(now: f.clock)
        let result = try await http.approve(approval, publication: f.publication, current: { true }, now: now)
        XCTAssertEqual(result.r9Svc, approval.fingerprint)
        let last = await transport.last()
        let sent = try XCTUnwrap(last)
        XCTAssertEqual(sent.url?.absoluteString, "https://portal.example/api/v1/integrations/\(approval.integrationID)/approval")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer native-portal-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["r9Svc": approval.fingerprint])
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: approval.checkpoint()) as? [String: Any])
        changed["integrationID"] = "i-11234567890123456789012345"
        let swapped = try JSONDecoder().decode(RemoteServiceApproval.self, from: JSONSerialization.data(withJSONObject: changed))
        do {
            _ = try await http.approve(swapped, publication: f.publication, current: { true }, now: now)
            XCTFail("Another integration must not reuse this consent")
        } catch {}
        let after = await transport.count()
        XCTAssertEqual(after, 1)
        var pending = record; pending["state"] = "awaiting_approval"; pending.removeValue(forKey: "r9Svc")
        try await transport.set(["integrations": [pending], "stale": false])
        let list = try await http.pending(stationOrigin: approval.stationOrigin, now: now)
        XCTAssertEqual(list.map(\.id), [approval.integrationID])
        try await transport.set(["integrations": [pending], "stale": true])
        do { _ = try await http.pending(stationOrigin: approval.stationOrigin, now: now); XCTFail("Stale Portal data cannot authorize") } catch {}
    }

    @MainActor
    func testServiceExpiryIsRecheckedAfterConfirmationBeforeSigning() throws {
        let f = try PublicationFixture()
        let approval = try serviceApproval(f)
        _ = try approval.prepare(publication: f.publication, managerID: "manager-a", now: f.clock)
        let expired = HostClock(wallMs: f.clock.wallMs + 60_000, monoMs: f.clock.monoMs + 60_000, bootId: f.clock.bootId)
        XCTAssertThrowsError(try approval.sign(publication: f.publication, provider: f.keys, managerID: "manager-a",
            validationClock: expired, confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertTrue(f.keys.requests.isEmpty)
    }

    @MainActor
    func testChangedServiceConsentOrAccountContextCannotReuseConfirmation() throws {
        let f = try PublicationFixture()
        let approval = try serviceApproval(f)
        _ = try approval.prepare(publication: f.publication, managerID: "manager-a", now: f.clock)
        for (field, changed) in [("stationOrigin", "https://other.example"), ("operationID", "setup-b"),
            ("issuer", "https://other-auth.example"), ("ownerAccount", "ab11234567890123456789012345"),
            ("genesisHash", String(repeating: "f", count: 64)),
            ("integrationID", "i-11234567890123456789012345"), ("fingerprint", String(repeating: "f", count: 64))] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: approval.checkpoint()) as? [String: Any])
            value[field] = changed
            let altered = try JSONDecoder().decode(RemoteServiceApproval.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try altered.sign(publication: f.publication, provider: f.keys, managerID: "manager-a", validationClock: f.clock,
                confirmedAt: 100, now: { 100 }, current: { true }), field)
        }
        XCTAssertThrowsError(try approval.sign(publication: f.publication, provider: f.keys, managerID: "manager-a", validationClock: f.clock,
            confirmedAt: 100, now: { 100 }, current: { false }))
        XCTAssertThrowsError(try approval.sign(publication: f.publication, provider: f.keys, managerID: "manager-a", validationClock: f.clock,
            confirmedAt: 100, now: { 30_100 }, current: { true }))
        XCTAssertTrue(f.keys.requests.isEmpty)
    }

    @MainActor
    func testServiceApprovalRefusesChangedHeadAndFailedProtectedStorage() throws {
        let f = try PublicationFixture()
        let approval = try serviceApproval(f)
        try f.prepare()
        _ = try f.publication.sign(provider: f.keys, keyID: "manager-a")
        _ = try f.publication.relayStored(now: f.clock)
        XCTAssertThrowsError(try approval.prepare(publication: f.publication, managerID: "manager-a", now: f.clock))
        let g = try PublicationFixture()
        let other = try serviceApproval(g)
        g.failWrite = true
        XCTAssertThrowsError(try other.prepare(publication: g.publication, managerID: "manager-a", now: g.clock))
        XCTAssertTrue(g.publication.storageUncertain)
        XCTAssertThrowsError(try other.sign(publication: g.publication, provider: g.keys, managerID: "manager-a", validationClock: g.clock,
            confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertTrue(g.keys.requests.isEmpty)
    }

    @MainActor
    func testHostEntryUsesTheCapturedAuthenticatedIdentityAndExactGeneration() throws {
        for generation: UInt64 in [3, 9_007_199_254_740_991] {
            let f = try PublicationFixture()
            let context = RemotePairingContext(accountID: "account-a", hostID: "host-a", linkGeneration: UUID())
            let raw = Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"host-a\",\"commitment\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"host_trust_gen\":\(generation)}}".utf8)
            let captured = try RemotePairingCommit(originalJSON: raw, context: context)
            let hostKey = PublicKeyData(alg: .ed25519, raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
            let body = try f.publication.prepareHost(commit: captured, hostChannelKey: hostKey,
                signer: "manager-a", signedAt: f.clock.wallMs)
            XCTAssertTrue(body.contains("\"host_trust_gen\":\(generation)"))
            let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
            XCTAssertTrue(request.entryJson.contains("\"host_id\":\"host-a\""))
            _ = try f.publication.relayStored(now: f.clock)
            let committed = try MembershipLog.verify(accountId: "account-a", genesisHash: f.log.genesisHash(),
                entries: f.publication.entries, now: f.clock)
            XCTAssertEqual(committed.host(hostId: "host-a")?.hostTrustGen, generation)
            XCTAssertEqual(committed.host(hostId: "host-a")?.hostKey, hostKey)
        }
    }

    @MainActor
    func testHostEntryRefusesAnotherAccountAndNonSigningHostKeys() throws {
        let f = try PublicationFixture()
        let raw = Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"host-a\",\"commitment\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"host_trust_gen\":3}}".utf8)
        let other = try RemotePairingCommit(originalJSON: raw,
            context: RemotePairingContext(accountID: "other", hostID: "host-a", linkGeneration: UUID()))
        let hostKey = PublicKeyData(alg: .ed25519, raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try f.publication.prepareHost(commit: other, hostChannelKey: hostKey,
            signer: "manager-a", signedAt: f.clock.wallMs))
        let current = try RemotePairingCommit(originalJSON: raw,
            context: RemotePairingContext(accountID: "account-a", hostID: "host-a", linkGeneration: UUID()))
        let encryptionKey = PublicKeyData(alg: .x25519, raw: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try f.publication.prepareHost(commit: current, hostChannelKey: encryptionKey,
            signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertEqual(f.writes, 0)
        XCTAssertTrue(f.keys.requests.isEmpty)
    }

    @MainActor
    func testSecondPublisherCannotReserveTheSameManagerWhileAnAppendIsPending() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let second = RemoteMembershipPublication(log: f.log, persist: { _ in XCTFail("Competing publisher reached storage") })
        XCTAssertThrowsError(try second.prepare(actionJSON: f.action("host-b"), signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertNil(try second.outstanding())
        XCTAssertEqual(f.writes, 1)
    }

    @MainActor
    func testBodyAndSignatureAreDurableBeforeTheyCanBeUsed() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let bodyCheckpoint = try XCTUnwrap(f.stored)
        XCTAssertEqual(f.keys.requests.count, 0)
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertNil(try f.publication.outstanding())
        f.keys.beforeSign = { [unowned f] in XCTAssertEqual(f.stored, bodyCheckpoint) }
        let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.writes, 2)
        XCTAssertNotEqual(f.stored, bodyCheckpoint)
        XCTAssertEqual(f.keys.requests.first?.purpose, .host)
        XCTAssertEqual(f.keys.requests.first?.freshConfirmation, true)
        XCTAssertNotNil(f.keys.requests.first?.bodyJson)
        XCTAssertEqual(request.expected, f.log.head())
        XCTAssertEqual(try f.publication.outstanding(), request)
        XCTAssertEqual(f.publication.entries.count, 1, "Signing is not a relay commit")
        guard case .committed(let head) = try f.publication.relayStored(now: f.clock) else {
            return XCTFail("Expected committed")
        }
        XCTAssertEqual(head.seq, 2)
        XCTAssertEqual(f.publication.entries.count, 2)
        XCTAssertNil(try f.publication.outstanding())
        let restored = try f.restore()
        XCTAssertEqual(restored.head, head)
        XCTAssertNil(try restored.outstanding())
    }

    @MainActor
    func testCrashAfterPrepareResignsTheSameBodyWithFreshConfirmation() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let restored = try f.restore()
        let request = try restored.sign(provider: f.keys, keyID: "manager-key")
        let body = try XCTUnwrap(f.keys.requests.first?.bodyJson)
        let info = try signedObjectInfo(json: request.entryJson)
        XCTAssertEqual(info.bodyJcs, body)
        XCTAssertEqual(restored.head.seq, 1)
    }

    @MainActor
    func testLostReplyAndRestartResendTheExactStoredSignature() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let first = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        let restored = try f.restore()
        XCTAssertEqual(try restored.outstanding(), first)
        XCTAssertEqual(try restored.sign(provider: f.keys, keyID: "manager-key"), first)
        XCTAssertEqual(f.keys.requests.count, 1, "A delivery retry cannot ask the key to sign again")
        XCTAssertThrowsError(try restored.prepare(actionJSON: f.action("different-host"),
            signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertEqual(try restored.outstanding(), first)
    }

    @MainActor
    func testBodyWriteFailurePreventsSigningAndHaltsUntilReload() throws {
        let f = try PublicationFixture()
        f.failWrite = true
        XCTAssertThrowsError(try f.prepare())
        XCTAssertTrue(f.publication.storageUncertain)
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertThrowsError(try f.publication.outstanding())
        XCTAssertEqual(f.keys.requests.count, 0)
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertNil(f.stored)
    }

    @MainActor
    func testSignatureWriteFailureExposesNoRequestAndKeepsTheDurableBody() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let bodyCheckpoint = f.stored
        f.failWrite = true
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertEqual(f.stored, bodyCheckpoint)
        XCTAssertThrowsError(try f.publication.outstanding())
        XCTAssertEqual(f.publication.head.seq, 1)
        f.failWrite = false
        let restored = try f.restore()
        XCTAssertNil(try restored.outstanding())
        _ = try restored.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.keys.requests.count, 2)
        XCTAssertEqual(f.keys.requests[0].input, f.keys.requests[1].input)
        XCTAssertTrue(f.keys.requests.allSatisfy(\.freshConfirmation))
    }

    @MainActor
    func testCommitWriteFailureDoesNotPublishALocalHeadOrLoseTheRetry() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let request = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        f.failWrite = true
        XCTAssertThrowsError(try f.publication.relayStored(now: f.clock))
        XCTAssertEqual(f.publication.head.seq, 1)
        XCTAssertEqual(f.publication.entries.count, 1)
        f.failWrite = false
        let restored = try f.restore()
        XCTAssertEqual(try restored.outstanding(), request)
        _ = try restored.relayStored(now: f.clock)
        XCTAssertEqual(restored.head.seq, 2)
        XCTAssertEqual(f.keys.requests.count, 1)
    }

    @MainActor
    func testConflictVerifiesTheWinningLogAndRequiresANewConfirmation() throws {
        let f = try PublicationFixture()
        try f.prepare()
        let first = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        // Simulate a separately signed winner arriving from another process, not a second live FFI publisher.
        let body = try f.log.draftEntry(signer: "manager-a", signedAt: f.clock.wallMs, actionJson: f.action("host-b"))
        let bodyObject = try JSONSerialization.jsonObject(with: Data(body.utf8))
        let info = try signedObjectInfo(json: json(["body": bodyObject, "sig": b64u(Data(repeating: 0, count: 64))]))
        let winner = try json(["body": bodyObject, "sig": b64u(f.keys.key.signature(for: info.signingInput))])
        let winningLog = f.log.snapshot()
        _ = try winningLog.extend(entries: [winner], now: f.clock)
        guard case .lostRace = try f.publication.relayConflict(head: winningLog.head(),
            entries: [winner], more: false, now: f.clock) else {
            return XCTFail("Expected lost race")
        }
        XCTAssertEqual(f.publication.head, winningLog.head())
        XCTAssertNil(try f.publication.outstanding())
        let restored = try f.restore()
        XCTAssertNil(try restored.outstanding())
        try restored.prepare(actionJSON: f.action(), signer: "manager-a", signedAt: f.clock.wallMs)
        let next = try restored.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertNotEqual(next.entryHash, first.entryHash)
        XCTAssertEqual(next.expected.seq, 2)
        XCTAssertEqual(f.keys.requests.count, 2)
        XCTAssertNotEqual(f.keys.requests.first?.input, f.keys.requests.last?.input)
    }

    @MainActor
    func testDeniedSigningKeepsTheBodyAndReentrantCallsAreRefused() throws {
        let f = try PublicationFixture()
        f.onPersist = { [unowned f] in XCTAssertThrowsError(try f.publication.outstanding()) }
        try f.prepare()
        f.keys.denied = true
        f.keys.beforeSign = { [unowned f] in XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "nested")) }
        XCTAssertThrowsError(try f.publication.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertFalse(f.publication.storageUncertain)
        XCTAssertNil(try f.publication.outstanding())
        XCTAssertEqual(f.writes, 1)
        f.keys.denied = false
        _ = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        XCTAssertEqual(f.keys.requests[0].input, f.keys.requests[1].input)
    }

    @MainActor
    func testCheckpointCannotMoveToAnotherAccountOrGenesis() throws {
        let f = try PublicationFixture()
        try f.prepare()
        for (account, genesis) in [("other-account", f.log.genesisHash()), (f.log.accountId(), String(repeating: "0", count: 64))] {
            XCTAssertThrowsError(try RemoteMembershipPublication(checkpoint: XCTUnwrap(f.stored),
                accountID: account, genesisHash: genesis, now: f.clock, persist: { _ in }))
        }
        let invalid = Data("{\"version\":1,\"version\":2}".utf8)
        XCTAssertThrowsError(try RemoteMembershipPublication(checkpoint: invalid,
            accountID: f.log.accountId(), genesisHash: f.log.genesisHash(), now: f.clock, persist: { _ in }))
    }

    @MainActor
    func testInconsistentRelayReplyCannotCauseASiblingSignatureEvenAfterRestart() throws {
        let f = try PublicationFixture()
        try f.prepare()
        _ = try f.publication.sign(provider: f.keys, keyID: "manager-key")
        guard case .relayInconsistent = try f.publication.relayConflict(head: f.log.head(), entries: [], more: false, now: f.clock) else {
            return XCTFail("Expected inconsistent reply")
        }
        XCTAssertTrue(f.publication.requiresRefresh)
        XCTAssertThrowsError(try f.prepare())
        let restored = try f.restore()
        XCTAssertTrue(restored.requiresRefresh)
        XCTAssertThrowsError(try restored.prepare(actionJSON: f.action("host-b"), signer: "manager-a", signedAt: f.clock.wallMs))
        XCTAssertThrowsError(try restored.sign(provider: f.keys, keyID: "manager-key"))
        XCTAssertEqual(f.keys.requests.count, 1)
    }

    @MainActor
    func testACompleteLogLargerThanTheSharedJSONMessageLimitCanBeReloaded() throws {
        let f = try PublicationFixture()
        let log = f.log.snapshot()
        let serviceKey = b64u(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let hosts = (0..<16).map { String(format: "host-%02d-", $0) + String(repeating: "x", count: 115) }
        var encodedBytes = log.entries().reduce(0) { $0 + $1.utf8.count }
        while encodedBytes < 1_100_000 {
            let add: [String: Any] = ["action": "add", "member": [
                "device_id": "service-a", "kind": "service", "roles": ["service"],
                "auth_key": ["alg": "ed25519", "pub": serviceKey],
                "scope": ["hosts": hosts, "ops": ["view"]], "expires_at": f.clock.wallMs + 60_000
            ]]
            for action in [try json(add), try json(["action": "remove", "device_id": "service-a"])] {
                let body = try log.draftEntry(signer: "manager-a", signedAt: f.clock.wallMs, actionJson: action)
                let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
                let info = try signedObjectInfo(json: json(["body": object, "sig": b64u(Data(repeating: 0, count: 64))]))
                let entry = try json(["body": object, "sig": b64u(f.keys.key.signature(for: info.signingInput))])
                _ = try log.extend(entries: [entry], now: f.clock)
                encodedBytes += entry.utf8.count
            }
            guard log.head().seq < 1_024 else { return XCTFail("Fixture exceeded the contract's log bound") }
        }
        var saved: Data?
        var publication: RemoteMembershipPublication? = RemoteMembershipPublication(log: log, persist: { saved = $0 })
        try XCTUnwrap(publication).prepare(actionJSON: f.action(), signer: "manager-a", signedAt: f.clock.wallMs)
        XCTAssertGreaterThan(encodedBytes, 1_048_576)
        let checkpoint = try XCTUnwrap(saved)
        publication = nil
        let restored = try RemoteMembershipPublication(checkpoint: checkpoint,
            accountID: log.accountId(), genesisHash: log.genesisHash(), now: f.clock, persist: { _ in })
        XCTAssertEqual(restored.head, log.head())
        XCTAssertEqual(restored.entries, log.entries())
        XCTAssertNil(try restored.outstanding(), "The saved body has not been signed")
        _ = try restored.sign(provider: f.keys, keyID: "manager-key")
    }
}
