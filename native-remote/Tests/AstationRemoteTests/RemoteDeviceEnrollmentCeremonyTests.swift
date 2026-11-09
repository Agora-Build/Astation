import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class CeremonyFixture {
    let manager: EnrollmentFixture
    let phone = DeviceIdentityFixture()
    let identity: RemoteAppleDeviceIdentity
    let issuer = "https://auth.dev.agora.build"
    let owner = "owner-login"
    let station = "https://station-dev.agora.build"
    var stored: Data?
    var failWrite = false
    var writes = 0
    let keys = [AccountKey(kid: "0123abcd", k: Data(repeating: 0x55, count: 32))]

    init() throws {
        manager = try EnrollmentFixture()
        identity = try phone.load(account: "owner-login")
    }
    var clock: HostClock { manager.clock }
    func invitation(roles: [String] = ["control", "view"]) throws -> RemoteDeviceEnrollmentInvitation {
        try RemoteDeviceEnrollmentInvitation(issuer: issuer, owner: owner, station: station, log: manager.log,
            manager: "manager", roles: roles, now: clock)
    }
    func session(_ invitation: RemoteDeviceEnrollmentInvitation) throws -> RemoteDeviceEnrollmentSession {
        try RemoteDeviceEnrollmentSession(invitation: invitation, now: clock, persist: persist)
    }
    func persist(_ value: Data) throws {
        writes += 1
        if failWrite { throw RemoteRecoveryError.storageUncertain }
        stored = value
    }
    func restore() throws -> RemoteDeviceEnrollmentSession {
        try RemoteDeviceEnrollmentSession(checkpoint: XCTUnwrap(stored), issuer: issuer, owner: owner,
            station: station, now: clock, persist: persist)
    }
    func request(_ invitation: RemoteDeviceEnrollmentInvitation, name: String = "My phone") async throws -> RemoteDeviceEnrollmentRequest {
        try await identity.enrollmentRequest(invitation: invitation, station: station, deviceName: name,
            now: { self.clock }, current: { true }, confirm: { true }, persist: { _ in })
    }
    func commit(_ session: RemoteDeviceEnrollmentSession) throws -> MembershipLog {
        let review = try session.review(log: manager.log, now: clock)
        _ = try review.prepare(publication: manager.publication, managerID: "manager", now: clock)
        _ = try manager.sign(review)
        _ = try manager.publication.relayStored(now: clock)
        return try review.committedLog(publication: manager.publication, now: clock)
    }
    func changed(_ json: String, _ change: (inout [String: Any]) throws -> Void) throws -> String {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        try change(&value)
        return try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}

final class RemoteDeviceEnrollmentCeremonyTests: XCTestCase {
    @MainActor
    func testAppleReadsTheSamePublicCeremonyVectorAsAndroid() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "native-device-enrollment-v1", withExtension: "json", subdirectory: "Fixtures"))
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let clock = HostClock(wallMs: try XCTUnwrap(vector["wall"] as? UInt64), monoMs: 100, bootId: "test-vector")
        let invitation = try RemoteDeviceEnrollmentInvitation(scannedJSON: XCTUnwrap(vector["invitation"] as? String),
            issuer: "https://auth.dev.agora.build", owner: "owner-login", station: "https://station-dev.agora.build", now: clock)
        let request = try RemoteDeviceEnrollmentRequest(json: XCTUnwrap(vector["request"] as? String), invitation: invitation, now: clock)
        let handoff = try RemoteDeviceEnrollmentHandoff(json: XCTUnwrap(vector["handoff"] as? String), invitation: invitation, request: request, now: clock)
        let log = try MembershipLog.verify(accountId: invitation.account, genesisHash: invitation.genesis,
            entries: XCTUnwrap(vector["entries"] as? [String]), now: clock)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            RemoteEnrollmentCoding.bytes(XCTUnwrap(vector["recipient_private"] as? String), count: 32))
        let keys = try handoff.open(invitation: invitation, request: request,
            identity: RemoteDevicePublicIdentity(deviceID: request.deviceID, authKey: request.authKey, encryptionKey: request.encryptionKey),
            log: log, now: clock, decrypt: { enc, ct, info, aad in
                var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: enc)
                return try recipient.open(ct, authenticating: aad)
            })
        XCTAssertEqual(try request.safetyCode, vector["safety_code"] as? String)
        XCTAssertEqual(keys.map(\.k), [try RemoteEnrollmentCoding.bytes(XCTUnwrap(vector["account_key"] as? String), count: 32)])
    }

    @MainActor
    func testTrustedScanPinsAccountIssuerStationRootAndDeadline() throws {
        let f = try CeremonyFixture(), invitation = try f.invitation()
        let json = try invitation.qrJSON()
        XCTAssertEqual(try RemoteDeviceEnrollmentInvitation(scannedJSON: json, issuer: f.issuer,
            owner: f.owner, station: f.station, now: f.clock), invitation)
        for (issuer, owner, station) in [("https://auth.agora.build", f.owner, f.station),
            (f.issuer, "someone-else", f.station), (f.issuer, f.owner, "https://station.agora.build")] {
            XCTAssertThrowsError(try RemoteDeviceEnrollmentInvitation(scannedJSON: json, issuer: issuer,
                owner: owner, station: station, now: f.clock))
        }
        let deadline = HostClock(wallMs: invitation.expires, monoMs: 10, bootId: "test")
        XCTAssertThrowsError(try RemoteDeviceEnrollmentInvitation(scannedJSON: json, issuer: f.issuer,
            owner: f.owner, station: f.station, now: deadline))
        XCTAssertThrowsError(try RemoteDeviceEnrollmentInvitation(scannedJSON: f.changed(json) { $0["extra"] = true },
            issuer: f.issuer, owner: f.owner, station: f.station, now: f.clock))
    }

    @MainActor
    func testRealApplicantKeyProofAndInvitationSecretBindEveryRequestField() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), request = try await f.request(invitation)
        XCTAssertNoThrow(try request.validate(invitation: invitation, now: f.clock))
        XCTAssertEqual(try request.safetyCode.count, 14)
        XCTAssertFalse(try request.json().contains(invitation.secret))
        for field in ["device", "auth", "encryption", "roles", "nonce", "name", "invitation"] {
            let altered = try f.changed(request.json()) { value in
                var body = try XCTUnwrap(value["body"] as? [String: Any])
                body[field] = field == "roles" ? ["view"] : "altered"
                value["body"] = body
            }
            XCTAssertThrowsError(try RemoteDeviceEnrollmentRequest(json: altered, invitation: invitation, now: f.clock), field)
        }
        let alteredProof = try f.changed(request.json()) { $0["signature"] = RemoteEnrollmentCoding.text(Data(repeating: 1, count: 64)) }
        XCTAssertThrowsError(try RemoteDeviceEnrollmentRequest(json: alteredProof, invitation: invitation, now: f.clock))
        XCTAssertThrowsError(try RemoteDeviceEnrollmentRequest(json: request.json(), invitation: f.invitation(), now: f.clock))
    }

    @MainActor
    func testKnowingTheInvitationSecretCannotForgeTheApplicantSigningKey() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation()
        let request = try await f.request(invitation)
        let forged = try f.changed(request.json()) { value in
            let signature = RemoteEnrollmentCoding.text(Data(repeating: 1, count: 64))
            let body = try XCTUnwrap(value["body"] as? [String: Any])
            let bodyJSON = try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
            value["signature"] = signature
            value["mac"] = try RemoteEnrollmentCoding.mac(encodeFields(fields: [Data("astation-device-request-auth-v1".utf8),
                Data(bodyJSON.utf8), Data(repeating: 1, count: 64)]), secret: invitation.secret)
        }
        XCTAssertThrowsError(try RemoteDeviceEnrollmentRequest(json: forged, invitation: invitation, now: f.clock))
    }

    @MainActor
    func testApplicantDenialContextChangesAndFailedPersistenceNeverExposeARequest() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation()
        var persisted = false
        do {
            _ = try await f.identity.enrollmentRequest(invitation: invitation, station: f.station, deviceName: "Phone",
                now: { f.clock }, current: { true }, confirm: { false }, persist: { _ in persisted = true })
            XCTFail("Owner denied")
        } catch { XCTAssertEqual(error as? RemoteOwnerAuthenticationError, .denied) }
        XCTAssertFalse(persisted)
        XCTAssertEqual(f.phone.crypto.signatures, 0)
        var current = true
        do {
            _ = try await f.identity.enrollmentRequest(invitation: invitation, station: f.station, deviceName: "Phone",
                now: { f.clock }, current: { current }, confirm: { current = false; return true }, persist: { _ in persisted = true })
            XCTFail("Account changed during confirmation")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertFalse(persisted)
        XCTAssertEqual(f.phone.crypto.signatures, 0)
        do {
            _ = try await f.identity.enrollmentRequest(invitation: invitation, station: f.station, deviceName: "Phone",
                now: { f.clock }, current: { true }, confirm: { true }, persist: { _ in throw RemoteRecoveryError.storageUncertain })
            XCTFail("Failed protected save")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
    }

    @MainActor
    func testPersistedInvitationCannotRebindToAnotherRequestAcrossRestart() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), session = try f.session(invitation)
        XCTAssertNotNil(f.stored)
        let first = try await f.request(invitation), second = try await f.request(invitation, name: "Other phone")
        XCTAssertEqual(try session.bind(requestJSON: first.json(), now: f.clock), first)
        let restored = try f.restore()
        XCTAssertEqual(try restored.bind(requestJSON: first.json(), now: f.clock), first)
        XCTAssertThrowsError(try restored.bind(requestJSON: second.json(), now: f.clock))
        try restored.cancel()
        let cancelled = try f.restore()
        XCTAssertThrowsError(try cancelled.qrJSON(now: f.clock))
        XCTAssertThrowsError(try cancelled.bind(requestJSON: first.json(), now: f.clock))
    }

    @MainActor
    func testFailedManagerSaveFencesEveryFollowingOperation() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), session = try f.session(invitation)
        let request = try await f.request(invitation)
        f.failWrite = true
        XCTAssertThrowsError(try session.bind(requestJSON: request.json(), now: f.clock))
        f.failWrite = false
        XCTAssertTrue(session.storageUncertain)
        XCTAssertThrowsError(try session.review(log: f.manager.log, now: f.clock))
        XCTAssertThrowsError(try session.qrJSON(now: f.clock))
    }

    @MainActor
    func testDurableSignedAddAndSealedHandoffCompleteOnlyTheExactPhone() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), session = try f.session(invitation)
        let request = try await f.request(invitation)
        _ = try session.bind(requestJSON: request.json(), now: f.clock)
        XCTAssertThrowsError(try session.handoff(committedLog: f.manager.log, keys: f.keys, now: f.clock))
        let log = try f.commit(session)
        let sealed = try session.handoff(committedLog: log, keys: f.keys, now: f.clock)
        XCTAssertFalse(sealed.contains(RemoteEnrollmentCoding.text(f.keys[0].k)))
        XCTAssertEqual(try f.restore().handoff(committedLog: log, keys: f.keys, now: f.clock), sealed)
        let handoff = try RemoteDeviceEnrollmentHandoff(json: sealed, invitation: invitation, request: request, now: f.clock)
        var checkpoint: Data?
        let enrolled = try RemoteEnrolledDevice(handoff: handoff, invitation: invitation, request: request,
            identity: f.identity, log: log, now: f.clock, persist: { checkpoint = $0 })
        XCTAssertEqual(enrolled.accountKeys, f.keys)
        XCTAssertEqual(enrolled.accountID, f.manager.log.accountId())
        let restored = try RemoteEnrolledDevice(checkpoint: XCTUnwrap(checkpoint), issuer: f.issuer, owner: f.owner,
            station: f.station, identity: f.identity.publicIdentity, now: f.clock)
        XCTAssertEqual(restored.accountKeys, f.keys)
        XCTAssertEqual(try restored.membership(now: f.clock).head(), log.head())
        XCTAssertThrowsError(try RemoteEnrolledDevice(checkpoint: XCTUnwrap(checkpoint), issuer: f.issuer, owner: "wrong-owner",
            station: f.station, identity: f.identity.publicIdentity, now: f.clock))
        XCTAssertThrowsError(try RemoteEnrolledDevice(handoff: handoff, invitation: invitation, request: request,
            identity: f.identity, log: log, now: f.clock, persist: { _ in throw RemoteRecoveryError.storageUncertain }))
    }

    @MainActor
    func testTamperedHandoffAndAnotherPhoneCannotReadTheAccountKeys() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), session = try f.session(invitation)
        let request = try await f.request(invitation)
        _ = try session.bind(requestJSON: request.json(), now: f.clock)
        let log = try f.commit(session), sealed = try session.handoff(committedLog: log, keys: f.keys, now: f.clock)
        for field in ["enc", "ciphertext", "mac"] {
            let altered = try f.changed(sealed) { $0[field] = RemoteEnrollmentCoding.text(Data(repeating: 3, count: 32)) }
            XCTAssertThrowsError(try RemoteDeviceEnrollmentHandoff(json: altered, invitation: invitation, request: request, now: f.clock))
        }
        let changedHead = try f.changed(sealed) { value in
            var context = try XCTUnwrap(value["context"] as? [String: Any])
            context["head"] = String(repeating: "0", count: 64); value["context"] = context
        }
        XCTAssertThrowsError(try RemoteDeviceEnrollmentHandoff(json: changedHead, invitation: invitation, request: request, now: f.clock))
        let otherFixture = DeviceIdentityFixture(), other = try otherFixture.load(account: f.owner)
        let handoff = try RemoteDeviceEnrollmentHandoff(json: sealed, invitation: invitation, request: request, now: f.clock)
        XCTAssertThrowsError(try RemoteEnrolledDevice(handoff: handoff, invitation: invitation, request: request,
            identity: other, log: log, now: f.clock, persist: { _ in XCTFail("Must not save another recipient") }))
    }

    @MainActor
    func testRemovedApplicantCannotReceiveOrInstallAnEarlierHandoff() async throws {
        let f = try CeremonyFixture(), invitation = try f.invitation(), session = try f.session(invitation)
        let request = try await f.request(invitation)
        _ = try session.bind(requestJSON: request.json(), now: f.clock)
        let log = try f.commit(session), sealed = try session.handoff(committedLog: log, keys: f.keys, now: f.clock)
        let remove = "{\"action\":\"remove\",\"device_id\":\"\(request.deviceID)\"}"
        _ = try f.manager.publication.prepare(actionJSON: remove, signer: "manager", signedAt: f.clock.wallMs)
        _ = try f.manager.publication.sign(provider: f.manager.keys, keyID: "manager")
        _ = try f.manager.publication.relayStored(now: f.clock)
        let revoked = try f.manager.publication.committedLog()
        XCTAssertThrowsError(try session.handoff(committedLog: revoked, keys: f.keys, now: f.clock))
        let handoff = try RemoteDeviceEnrollmentHandoff(json: sealed, invitation: invitation, request: request, now: f.clock)
        XCTAssertThrowsError(try RemoteEnrolledDevice(handoff: handoff, invitation: invitation, request: request,
            identity: f.identity, log: revoked, now: f.clock, persist: { _ in XCTFail("Removed device") }))
    }
}
