import CryptoKit
import Security
import XCTest
@testable import Menubar

struct AtemStorageFixture {
    let account = "acct-1"
    let deviceId = "dev-1"
    let storage: TestAtemStorage
    let crypto: TestAtemCryptography
    let identity: AtemE2EIdentity
    let device = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let unlockAuth = Curve25519.Signing.PrivateKey()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let key = Data(repeating: 0xee, count: 32)
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let keys: AtemVerifyKeys

    init() throws {
        storage = TestAtemStorage()
        crypto = TestAtemCryptography()
        identity = AtemE2EIdentity(storage: storage, crypto: crypto)
        keys = try identity.verificationKeys(nonce: Data(repeating: 8, count: 32))
        try identity.markRecoverySaved(signingPublicKey: keys.signPub)
        try verify()
    }

    func verify(devicePub: Data? = nil) throws {
        _ = try identity.completeVerification(account: account, deviceId: deviceId, reveal: AtemVerifyReveal(
            devicePub: devicePub ?? device.publicKey.rawRepresentation,
            deviceSignPub: signing.publicKey.rawRepresentation, unlockAuthPub: unlockAuth.publicKey.rawRepresentation,
            nonce: Data(repeating: 4, count: 32)
        ), transcript: Data(repeating: 9, count: 32), expectedSigningKey: keys.signPub, key: nil)
    }

    func rotate(old: String = "", new: String = "0a1b2c3d", plaintext: Data? = nil,
                account: String? = nil, deviceId: String? = nil, publicKey: Data? = nil) throws -> AtemStorageRotateWire {
        let account = account ?? self.account, deviceId = deviceId ?? self.deviceId
        let seal = try AtemE2ECrypto.sealKey(plaintext ?? key, to: publicKey ?? keys.encPub,
                                          info: AtemStatements.storageKeyInfo(account: account, deviceId: deviceId, kid: new))
        let statement = try AtemStatements.storageRotate(account: account, deviceId: deviceId, oldKid: old,
                                                         newKid: new, sealedHash: AtemE2ECrypto.sealedKeyDigest(seal))
        return AtemStorageRotateWire(rotate: AtemSignedWire(statement: statement, signature: try signing.signature(for: statement)),
                                     encappedKey: seal.encapsulatedKey, ciphertext: seal.ciphertext)
    }

    func escrow(_ wire: AtemStorageRotateWire? = nil) throws -> AtemSignedWire {
        try identity.rotateStorageKey(wire ?? rotate(), account: account, deviceId: deviceId)
    }

    func settlement(kid: String = "0a1b2c3d", abandon: Bool = false, account: String? = nil, deviceId: String? = nil) throws -> AtemSignedWire {
        let statement = try AtemStatements.storageSettlement(account: account ?? self.account, deviceId: deviceId ?? self.deviceId,
                                                             kid: kid, abandoning: abandon)
        return AtemSignedWire(statement: statement, signature: try signing.signature(for: statement))
    }

    func settle(kid: String = "0a1b2c3d", abandon: Bool = false) throws {
        try identity.settleStorageKey(settlement(kid: kid, abandon: abandon), account: account, deviceId: deviceId, abandoning: abandon)
    }

    func unlock(kid: String = "0a1b2c3d", time: UInt64 = 1_760_000_000, ticket: String = "",
                account: String? = nil, deviceId: String? = nil, ephemeral: Data? = nil) throws -> AtemUnlockRequestWire {
        let statement = try AtemStatements.unlockRequest(account: account ?? self.account, deviceId: deviceId ?? self.deviceId,
            bootId: "boot-1", ticket: ticket, ephemeralPublicKey: ephemeral ?? self.ephemeral.publicKey.rawRepresentation,
            nonce: Data(repeating: 0xbb, count: 32), time: time, storageKid: kid)
        return AtemUnlockRequestWire(request: statement, signature: try unlockAuth.signature(for: statement))
    }

    func prepare(_ wire: AtemUnlockRequestWire? = nil) throws -> AtemUnlockAuthorization {
        try identity.prepareUnlock(wire ?? unlock(), account: account, deviceId: deviceId, now: now)
    }

    func open(_ grant: AtemUnlockGrantWire, request: AtemUnlockRequestWire) throws -> Data {
        let parsed = try AtemUnlockRequest(statement: request.request)
        let hash = Data(SHA256.hash(data: request.request))
        let expected = try AtemStatements.unlockGrant(account: account, deviceId: deviceId, kid: parsed.storageKid,
            requestHash: hash, sealedHash: AtemE2ECrypto.sealedKeyDigest(AtemHPKESealedKey(
                encapsulatedKey: grant.encappedKey, ciphertext: grant.ciphertext)))
        XCTAssertEqual(grant.grant.statement, expected)
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(grant.grant.signature, message: expected, publicKey: keys.signPub))
        var recipient = try HPKE.Recipient(privateKey: ephemeral, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: AtemStatements.unlockInfo(account: account, deviceId: deviceId, kid: parsed.storageKid, requestHash: hash),
            encapsulatedKey: grant.encappedKey)
        return try recipient.open(grant.ciphertext, authenticating: Data())
    }

    func status(_ instance: AtemE2EIdentity? = nil) throws -> AtemStorageKeyStatus? {
        try (instance ?? identity).storageKeyStatus(account: account, deviceId: deviceId)
    }
}

final class AtemStorageKeyTests: XCTestCase {
    func testFirstEscrowPersistsAndIdenticalRetryReturnsTheSameAckAfterRestart() throws {
        let f = try AtemStorageFixture(), rotate = try f.rotate()
        let ack = try f.escrow(rotate)
        XCTAssertEqual(ack.statement, try AtemStatements.storageAck(account: f.account, deviceId: f.deviceId, kid: "0a1b2c3d"))
        XCTAssertTrue(AtemE2ECrypto.verifyP256Signature(ack.signature, message: ack.statement, publicKey: f.keys.signPub))
        let writes = f.storage.writes
        let reload = AtemE2EIdentity(storage: f.storage, crypto: f.crypto)
        XCTAssertEqual(try reload.rotateStorageKey(rotate, account: f.account, deviceId: f.deviceId), ack)
        XCTAssertEqual(f.storage.writes, writes)
        XCTAssertEqual(try f.status(reload), AtemStorageKeyStatus(currentKid: nil, pendingKid: "0a1b2c3d", lastUnlock: nil))
        try f.settle()
        XCTAssertEqual(try f.status()?.currentKid, "0a1b2c3d")
        XCTAssertNil(try f.status()?.pendingKid)
    }

    func testPendingCommitmentRejectsDifferentSealAndOtherRotation() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let before = f.storage.data
        for rotate in [try f.rotate(), try f.rotate(new: "4e5f6a7b")] {
            XCTAssertThrowsError(try f.escrow(rotate)) { XCTAssertEqual(($0 as? AtemStorageKeyError)?.pendingKid, "0a1b2c3d") }
        }
        XCTAssertEqual(f.storage.data, before)
    }

    func testExplicitAndImplicitConfirmationPreserveOnlyTwoKeys() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        _ = try f.escrow(f.rotate(old: "0a1b2c3d", new: "4e5f6a7b"))
        XCTAssertEqual(try f.status()?.currentKid, "0a1b2c3d")
        XCTAssertEqual(try f.status()?.pendingKid, "4e5f6a7b")
        try f.settle(kid: "12345678")
        try f.settle(kid: "0a1b2c3d")
        XCTAssertEqual(try f.status()?.pendingKid, "4e5f6a7b")
        try f.settle(kid: "4e5f6a7b")
        let saved = f.storage.data
        try f.settle(kid: "4e5f6a7b")
        XCTAssertEqual(f.storage.data, saved)
        XCTAssertEqual(try f.status()?.currentKid, "4e5f6a7b")
        XCTAssertNil(try f.status()?.pendingKid)
    }

    func testCurrentUnlockKeepsPendingAndPendingUnlockPromotesWithBoundGrant() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        try f.settle()
        let nextKey = Data(repeating: 0xaa, count: 32)
        _ = try f.escrow(f.rotate(old: "0a1b2c3d", new: "4e5f6a7b", plaintext: nextKey))
        let current = try f.unlock()
        XCTAssertEqual(try f.open(f.identity.unlockGrant(f.prepare(current), now: f.now), request: current), f.key)
        XCTAssertEqual(try f.status()?.pendingKid, "4e5f6a7b")
        let pending = try f.unlock(kid: "4e5f6a7b")
        XCTAssertEqual(try f.open(f.identity.unlockGrant(f.prepare(pending), now: f.now), request: pending), nextKey)
        XCTAssertEqual(try f.status()?.currentKid, "4e5f6a7b")
        XCTAssertNil(try f.status()?.pendingKid)
        XCTAssertEqual(try f.status()?.lastUnlock, 1_760_000_000)
        XCTAssertThrowsError(try f.prepare(current))
    }

    func testFirstEscrowCanBeImplicitlyConfirmedByUnlock() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let request = try f.unlock()
        XCTAssertEqual(try f.open(f.identity.unlockGrant(f.prepare(request), now: f.now), request: request), f.key)
        XCTAssertEqual(try f.status()?.currentKid, "0a1b2c3d")
        XCTAssertNil(try f.status()?.pendingKid)
    }

    func testAbandonOnlyDropsExactPendingKidAndReplayHistorySurvivesRestart() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        try f.settle()
        let next = try f.rotate(old: "0a1b2c3d", new: "4e5f6a7b")
        _ = try f.escrow(next)
        try f.settle(kid: "0a1b2c3d", abandon: true)
        try f.settle(kid: "deadbeef", abandon: true)
        XCTAssertEqual(try f.status()?.pendingKid, "4e5f6a7b")
        try f.settle(kid: "4e5f6a7b", abandon: true)
        XCTAssertEqual(try f.status()?.currentKid, "0a1b2c3d")
        XCTAssertNil(try f.status()?.pendingKid)
        let reload = AtemE2EIdentity(storage: f.storage, crypto: f.crypto)
        XCTAssertThrowsError(try reload.rotateStorageKey(next, account: f.account, deviceId: f.deviceId)) {
            guard case .replayedKey? = $0 as? AtemStorageKeyError else { return XCTFail("Expected a replay rejection") }
        }
        _ = try f.escrow(f.rotate(old: "0a1b2c3d", new: "12345678"))
    }

    func testImplicitConfirmPersistsEvenIfNextRotationCannotBeOpened() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let wrongRecipient = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try f.escrow(f.rotate(old: "0a1b2c3d", new: "4e5f6a7b", publicKey: wrongRecipient)))
        XCTAssertEqual(try f.status()?.currentKid, "0a1b2c3d")
        XCTAssertNil(try f.status()?.pendingKid)
        _ = try f.escrow(f.rotate(old: "0a1b2c3d", new: "4e5f6a7b"))
    }

    func testFreshDeviceKeyStartsNewEscrowAndCannotReadOldKeys() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        try f.settle()
        let old = try f.prepare()
        try f.verify(devicePub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        XCTAssertNil(try f.status())
        XCTAssertThrowsError(try f.prepare())
        XCTAssertThrowsError(try f.identity.unlockGrant(old, now: f.now))
        _ = try f.escrow()
        XCTAssertEqual(try f.status()?.pendingKid, "0a1b2c3d")
    }

    func testUnlockRejectsSignatureIdentityTicketTimeAndUnusablePointBeforeApproval() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let valid = try f.unlock()
        let signedByDevice = AtemUnlockRequestWire(request: valid.request, signature: try f.signing.signature(for: valid.request))
        let requests = [signedByDevice,
            AtemUnlockRequestWire(request: valid.request + Data([0]), signature: valid.signature),
            try f.unlock(account: "other"), try f.unlock(deviceId: "other"),
            try f.unlock(ticket: "not-yet"), try f.unlock(time: 1_759_999_699), try f.unlock(time: 1_760_000_301),
            try f.unlock(time: UInt64.max), try f.unlock(kid: "4e5f6a7b"), try f.unlock(kid: "0A1B2C3D"),
            try f.unlock(ephemeral: Data(repeating: 0, count: 32)), try f.unlock(ephemeral: Data([1])),
        ]
        let before = f.storage.data
        for request in requests { XCTAssertThrowsError(try f.prepare(request)) }
        _ = try f.prepare(f.unlock(time: 1_759_999_700))
        _ = try f.prepare(f.unlock(time: 1_760_000_300))
        XCTAssertEqual(f.storage.data, before)
    }

    func testRotationsAndSettlementsFailClosedOnInvalidAuthorization() throws {
        let f = try AtemStorageFixture()
        let valid = try f.rotate()
        var ciphertext = valid.ciphertext
        ciphertext[ciphertext.startIndex] ^= 1
        let wrongSignature = AtemSignedWire(statement: valid.rotate.statement, signature: try f.unlockAuth.signature(for: valid.rotate.statement))
        for rotate in [
            AtemStorageRotateWire(rotate: wrongSignature, encappedKey: valid.encappedKey, ciphertext: valid.ciphertext),
            AtemStorageRotateWire(rotate: valid.rotate, encappedKey: valid.encappedKey, ciphertext: ciphertext),
            try f.rotate(account: "other"), try f.rotate(deviceId: "other"), try f.rotate(old: "12345678"),
            try f.rotate(new: "UPPERHEX"), try f.rotate(old: "0a1b2c3d", new: "0a1b2c3d"),
        ] { XCTAssertThrowsError(try f.escrow(rotate)) }
        XCTAssertNil(try f.status())
        _ = try f.escrow(valid)
        let before = f.storage.data
        for signed in [try f.settlement(account: "other"), try f.settlement(deviceId: "other"),
                       AtemSignedWire(statement: try f.settlement().statement, signature: Data(repeating: 0, count: 64))] {
            XCTAssertThrowsError(try f.identity.settleStorageKey(signed, account: f.account, deviceId: f.deviceId, abandoning: false))
        }
        XCTAssertEqual(f.storage.data, before)
    }

    func testFailedSigningAndPersistenceNeverAcknowledgeOrReleaseKeys() throws {
        let f = try AtemStorageFixture()
        let rotate = try f.rotate()
        let before = f.storage.data
        f.crypto.failSign = true
        XCTAssertThrowsError(try f.escrow(rotate))
        XCTAssertEqual(f.storage.data, before)
        f.crypto.failSign = false
        f.storage.failWrite = true
        XCTAssertThrowsError(try f.escrow(rotate))
        XCTAssertEqual(f.storage.data, before)
        f.storage.failWrite = false
        _ = try f.escrow(rotate)
        let authorization = try f.prepare(), pending = f.storage.data
        f.storage.failWrite = true
        XCTAssertThrowsError(try f.identity.unlockGrant(authorization, now: f.now))
        XCTAssertEqual(f.storage.data, pending)
        f.storage.failWrite = false
        f.crypto.failSign = true
        XCTAssertThrowsError(try f.identity.unlockGrant(authorization, now: f.now))
        XCTAssertEqual(f.storage.data, pending)
    }

    func testRevocationInvalidatesApprovalAndRetainsReplayHistory() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let authorization = try f.prepare()
        try f.identity.revokeDevice(authorization)
        XCTAssertFalse(try f.identity.isVerified(account: f.account, deviceId: f.deviceId))
        XCTAssertThrowsError(try f.identity.unlockGrant(authorization, now: f.now))
        XCTAssertThrowsError(try f.escrow())
        try f.verify()
        XCTAssertEqual(try f.status()?.pendingKid, "0a1b2c3d")
    }

    func testStepOneIdentityLoadsWithoutStorageKeysAndCorruptRecordsAreRetained() throws {
        let f = try AtemStorageFixture()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        old["version"] = 1
        old.removeValue(forKey: "storageKeys")
        f.storage.data = try JSONSerialization.data(withJSONObject: old)
        XCTAssertTrue(try f.identity.isVerified(account: f.account, deviceId: f.deviceId))
        _ = try f.escrow()
        var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        XCTAssertEqual(corrupt["version"] as? Int, AtemE2EIdentity.storedVersion)
        XCTAssertEqual(try f.identity.verificationKeys(nonce: f.keys.nonce), f.keys)
        var records = try XCTUnwrap(corrupt["storageKeys"] as? [String: [String: Any]])
        let binding = try XCTUnwrap(records.keys.first)
        records[binding]?["acked"] = []
        corrupt["storageKeys"] = records
        f.storage.data = try JSONSerialization.data(withJSONObject: corrupt)
        let retained = f.storage.data
        XCTAssertThrowsError(try f.prepare())
        XCTAssertEqual(f.storage.data, retained)
        XCTAssertEqual(f.crypto.creates, 1)
    }

    func testVersionTwoRequiresEscrowStateAndUnknownVersionsRetainStoredKeys() throws {
        let f = try AtemStorageFixture()
        _ = try f.escrow()
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        var missing = good
        missing.removeValue(forKey: "storageKeys")
        var future = good
        future["version"] = AtemE2EIdentity.storedVersion + 1
        for record in [missing, future] {
            f.storage.data = try JSONSerialization.data(withJSONObject: record)
            let retained = f.storage.data
            XCTAssertThrowsError(try f.identity.verificationKeys(nonce: f.keys.nonce))
            XCTAssertEqual(f.storage.data, retained)
            XCTAssertEqual(f.crypto.creates, 1)
        }
    }

    func testNewerIdentityFormatReportsAnUpgradeBeforeReadingItsUnknownSchema() throws {
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        // Future versions need not have the material or escrow layout this build expects.
        storage.data = Data("{\"version\":\(AtemE2EIdentity.storedVersion + 1),\"future_schema\":{}}".utf8)
        let retained = storage.data
        let identity = AtemE2EIdentity(storage: storage, crypto: crypto)
        XCTAssertThrowsError(try identity.verificationKeys(nonce: Data(repeating: 1, count: 32))) { error in
            guard case .newerStoredIdentity(let version)? = error as? AtemIdentityError else {
                return XCTFail("Expected a format upgrade error, received \(error)")
            }
            XCTAssertEqual(version, AtemE2EIdentity.storedVersion + 1)
            XCTAssertTrue(error.localizedDescription.contains("Update Astation"))
        }
        XCTAssertEqual(storage.data, retained)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(crypto.creates, 0)
    }
}
