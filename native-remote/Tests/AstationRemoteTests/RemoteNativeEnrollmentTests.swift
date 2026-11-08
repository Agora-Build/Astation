import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private func enrollmentJSON(_ value: Any) throws -> String {
    try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
}

private final class EnrollmentManagerKeys: AppKeyProvider, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey()
    var signatures = 0
    func publicKey(keyId: String) throws -> PublicKeyData {
        PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation)
    }
    func sign(request: SignRequest) throws -> Data {
        signatures += 1
        return try key.signature(for: request.input)
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.invalidInput }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw RemoteChannelError.invalidInput
    }
}

@MainActor
private final class EnrollmentFixture {
    let keys = EnrollmentManagerKeys()
    let phoneAuth = P256.Signing.PrivateKey()
    let phoneEnc = Curve25519.KeyAgreement.PrivateKey()
    let clock = HostClock(wallMs: 1_793_000_000_000, monoMs: 100, bootId: "enrollment-test")
    let log: MembershipLog
    var stored: Data?
    var failWrite = false
    var writes = 0
    private var active: RemoteMembershipPublication?
    var publication: RemoteMembershipPublication {
        if let active { return active }
        let created = RemoteMembershipPublication(log: log, persist: { [unowned self] in try persist($0) })
        active = created
        return created
    }

    init() throws {
        let body: [String: Any] = [
            "type": "atem-membership-entry", "v": 1, "account_id": "account-native",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis",
            "signer": "manager", "signed_at": clock.wallMs,
            "member": ["device_id": "manager", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(keys.key.publicKey.rawRepresentation)],
                "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]],
            "recovery_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]
        ]
        let info = try signedObjectInfo(json: enrollmentJSON(["body": body, "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]))
        let signed = try enrollmentJSON(["body": body, "sig": RemoteRecoveryKit.base64URL(keys.key.signature(for: info.signingInput))])
        log = try MembershipLog.verify(accountId: "account-native", genesisHash: XCTUnwrap(info.entryHash), entries: [signed], now: clock)
    }

    func review(roles: [String] = ["control", "view"], requestID: String = "request-phone", station: String = "https://station-dev.agora.build",
        expiresAt: UInt64? = nil, deviceID: String = "phone-ios", log: MembershipLog? = nil, managerID: String = "manager") throws -> RemoteNativeEnrollment {
        try RemoteNativeEnrollment(requestID: requestID, stationOrigin: station, deviceID: deviceID,
            authKey: PublicKeyData(alg: .p256, raw: phoneAuth.publicKey.x963Representation),
            encryptionKey: PublicKeyData(alg: .x25519, raw: phoneEnc.publicKey.rawRepresentation), roles: roles,
            expiresAt: expiresAt ?? clock.wallMs + 300_000, log: log ?? self.log, managerID: managerID, now: clock)
    }

    func persist(_ bytes: Data) throws {
        writes += 1
        if failWrite { throw RemotePublicationError.storageUncertain }
        stored = bytes
    }

    func restore() throws -> RemoteMembershipPublication {
        active = nil
        let restored = try RemoteMembershipPublication(checkpoint: XCTUnwrap(stored), accountID: log.accountId(),
            genesisHash: log.genesisHash(), now: clock, persist: { [unowned self] in try persist($0) })
        active = restored
        return restored
    }

    func sign(_ review: RemoteNativeEnrollment, publication: RemoteMembershipPublication? = nil,
        fingerprint: String? = nil, current: Bool = true, clock: HostClock? = nil) throws -> AppendRequest {
        try review.sign(publication: publication ?? self.publication, provider: keys, managerID: "manager",
            confirmedFingerprint: fingerprint ?? review.fingerprint, validationClock: clock ?? self.clock,
            confirmedAt: 100, now: { 101 }, current: { current })
    }
}

final class RemoteNativeEnrollmentTests: XCTestCase {
    @MainActor
    func testNativeAddUsesExistingR9AndPersistsBeforeSigningOrCompleting() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        XCTAssertEqual(review.deviceID, "phone-ios")
        XCTAssertEqual(review.roles, ["control", "view"])
        let request = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        XCTAssertEqual(request.purpose, .enroll)
        XCTAssertTrue(request.freshConfirmation)
        XCTAssertEqual(f.writes, 1)
        XCTAssertEqual(f.keys.signatures, 0)
        XCTAssertThrowsError(try review.committedLog(publication: f.publication, now: f.clock))
        let append = try f.sign(review)
        XCTAssertEqual(f.writes, 2)
        XCTAssertEqual(f.keys.signatures, 1)
        XCTAssertEqual(try signedObjectInfo(json: append.entryJson).bodyJcs, review.bodyJSON)
        XCTAssertThrowsError(try review.committedLog(publication: f.publication, now: f.clock))
        _ = try f.publication.relayStored(now: f.clock)
        let accepted = try review.committedLog(publication: f.publication, now: f.clock)
        XCTAssertEqual(accepted.member(deviceId: "phone-ios")?.roles, ["control", "view"])
        XCTAssertEqual(accepted.head().seq, 2)
    }

    @MainActor
    func testViewOnlyIsSupportedAndManageCannotBeSmuggledIntoEnrollment() throws {
        let f = try EnrollmentFixture()
        XCTAssertEqual(try f.review(roles: ["view"]).roles, ["view"])
        for roles in [["control"], ["manage", "view"], ["control", "manage", "view"], ["service"], ["view", "control"], ["view", "view"], []] {
            XCTAssertThrowsError(try f.review(roles: roles), "\(roles)")
        }
    }

    @MainActor
    func testUnsupportedKeysAndInvalidApplicantIDsAreRefused() throws {
        let f = try EnrollmentFixture()
        for id in ["recovery", "phone/one", "", String(repeating: "a", count: 129), "manager"] {
            XCTAssertThrowsError(try f.review(deviceID: id), id)
        }
        for (auth, enc) in [
            (PublicKeyData(alg: .x25519, raw: f.phoneEnc.publicKey.rawRepresentation), PublicKeyData(alg: .x25519, raw: f.phoneEnc.publicKey.rawRepresentation)),
            (PublicKeyData(alg: .p256, raw: Data(repeating: 0, count: 65)), PublicKeyData(alg: .x25519, raw: f.phoneEnc.publicKey.rawRepresentation)),
            (PublicKeyData(alg: .p256, raw: f.phoneAuth.publicKey.x963Representation), PublicKeyData(alg: .ed25519, raw: f.keys.key.publicKey.rawRepresentation)),
            (PublicKeyData(alg: .p256, raw: f.phoneAuth.publicKey.x963Representation), PublicKeyData(alg: .x25519, raw: Data(repeating: 0, count: 32)))
        ] {
            XCTAssertThrowsError(try RemoteNativeEnrollment(requestID: "request", stationOrigin: "https://station-dev.agora.build",
                deviceID: "phone", authKey: auth, encryptionKey: enc, roles: ["view"], expiresAt: f.clock.wallMs + 100,
                log: f.log, managerID: "manager", now: f.clock))
        }
    }

    @MainActor
    func testReviewExpiresAtTheDeadlineAndHasABoundedLifetime() throws {
        let f = try EnrollmentFixture()
        for expiry in [f.clock.wallMs, f.clock.wallMs - 1, f.clock.wallMs + 600_001, UInt64.max] {
            XCTAssertThrowsError(try f.review(expiresAt: expiry))
        }
        let review = try f.review(expiresAt: f.clock.wallMs + 100)
        _ = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        let deadline = HostClock(wallMs: review.expiresAt, monoMs: 200, bootId: f.clock.bootId)
        XCTAssertThrowsError(try f.sign(review, clock: deadline))
        XCTAssertEqual(f.keys.signatures, 0)
    }

    @MainActor
    func testFingerprintBindsStationRequestExpiryPermissionsAndEntireMembershipBody() throws {
        let f = try EnrollmentFixture(), original = try f.review()
        for changed in [try f.review(requestID: "request-2"), try f.review(station: "https://station.agora.build"),
                        try f.review(expiresAt: f.clock.wallMs + 301_000), try f.review(roles: ["view"]),
                        try f.review(deviceID: "phone-android")] {
            XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
        }
        _ = try original.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        XCTAssertThrowsError(try f.sign(original, fingerprint: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try f.sign(original, current: false))
        XCTAssertEqual(f.keys.signatures, 0)
    }

    @MainActor
    func testAccountOrRelaySwitchCannotReuseAnotherSavedReview() throws {
        let f = try EnrollmentFixture(), original = try f.review(), switched = try f.review(station: "https://station.agora.build")
        _ = try original.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        XCTAssertThrowsError(try f.sign(switched))
        XCTAssertThrowsError(try original.prepare(publication: f.publication, managerID: "other-manager", now: f.clock))
        XCTAssertEqual(f.keys.signatures, 0)
    }

    @MainActor
    func testLostReplyAndRestartRetryTheSameStoredSignature() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        _ = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        let first = try f.sign(review)
        let restored = try f.restore()
        let saved = try JSONDecoder().decode(RemoteNativeEnrollment.self, from: XCTUnwrap(restored.operationContext))
        XCTAssertEqual(saved, review)
        let retry = try f.sign(saved, publication: restored)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(f.keys.signatures, 1)
        _ = try restored.relayStored(now: f.clock)
        XCTAssertEqual(try review.committedLog(publication: restored, now: f.clock).head().seq, 2)
    }

    @MainActor
    func testFailedReviewWriteCannotReachTheKeyProvider() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        f.failWrite = true
        XCTAssertThrowsError(try review.prepare(publication: f.publication, managerID: "manager", now: f.clock))
        f.failWrite = false
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertEqual(f.keys.signatures, 0)
        XCTAssertTrue(f.publication.storageUncertain)
    }

    @MainActor
    func testFailedSignatureWriteCannotExposeAnAppendOrMarkThePhoneTrusted() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        _ = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        f.failWrite = true
        XCTAssertThrowsError(try f.sign(review))
        XCTAssertThrowsError(try f.publication.outstanding())
        XCTAssertThrowsError(try review.committedLog(publication: f.publication, now: f.clock))
        XCTAssertEqual(f.keys.signatures, 1)
    }

    @MainActor
    func testHeadMovementRequiresAnotherReviewAndOwnerConfirmation() throws {
        let f = try EnrollmentFixture(), old = try f.review(), winner = try f.review(deviceID: "another-phone")
        _ = try winner.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        _ = try f.sign(winner)
        _ = try f.publication.relayStored(now: f.clock)
        XCTAssertThrowsError(try old.prepare(publication: f.publication, managerID: "manager", now: f.clock))
        XCTAssertEqual(f.keys.signatures, 1)
        let fresh = try f.review(log: f.publication.committedLog())
        XCTAssertNotEqual(old.fingerprint, fresh.fingerprint)
    }

    @MainActor
    func testDecodedContextCannotSubstituteAKeyOrEscalateRoles() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: review.checkpoint()) as? [String: Any])
        fields["stationOrigin"] = "https://station.agora.build"
        let tampered = try JSONDecoder().decode(RemoteNativeEnrollment.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try tampered.prepare(publication: f.publication, managerID: "manager", now: f.clock))
        fields["stationOrigin"] = review.stationOrigin
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(review.bodyJSON.utf8)) as? [String: Any])
        var member = try XCTUnwrap(body["member"] as? [String: Any])
        member["roles"] = ["control", "manage", "view"]
        body["member"] = member
        let newBody = try enrollmentJSON(body)
        fields["bodyJSON"] = newBody
        fields["fingerprint"] = hashFields(fields: ["astation-native-enrollment-review-v1", review.requestID,
            review.stationOrigin, String(review.expiresAt), newBody].map { Data($0.utf8) })
        let escalated = try JSONDecoder().decode(RemoteNativeEnrollment.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try escalated.prepare(publication: f.publication, managerID: "manager", now: f.clock))
        XCTAssertEqual(f.keys.signatures, 0)
    }

    @MainActor
    func testSignedEnrollmentNeverExpiresTheNativeMemberAndRemovalCannotReuseItsID() throws {
        let f = try EnrollmentFixture(), review = try f.review()
        _ = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        _ = try f.sign(review)
        _ = try f.publication.relayStored(now: f.clock)
        let afterReviewExpired = HostClock(wallMs: review.expiresAt + 1, monoMs: 301_001, bootId: f.clock.bootId)
        XCTAssertEqual(try review.committedLog(publication: f.publication, now: afterReviewExpired).member(deviceId: review.deviceID)?.status, .active)
        _ = try f.publication.prepare(actionJSON: enrollmentJSON(["action": "remove", "device_id": review.deviceID]),
            signer: "manager", signedAt: f.clock.wallMs)
        _ = try f.publication.sign(provider: f.keys, keyID: "manager")
        _ = try f.publication.relayStored(now: f.clock)
        XCTAssertThrowsError(try review.committedLog(publication: f.publication, now: f.clock))
        XCTAssertThrowsError(try f.review(log: f.publication.committedLog()))
    }
}
