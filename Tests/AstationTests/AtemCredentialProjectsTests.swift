import CryptoKit
import XCTest
@testable import Menubar

final class AtemCredentialProjectsTests: XCTestCase {
    func testRustGeneratedSignedHPKEReportDecryptsInSwift() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/credential-project-report.json")
        let report = try JSONDecoder().decode(AtemProjectReportWire.self, from: Data(contentsOf: path))
        let crypto = TestAtemCryptography(encryption: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)))
        let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: crypto)
        let keys = try identity.verificationKeys(nonce: Data(repeating: 3, count: 32))
        try identity.markRecoverySaved(signingPublicKey: keys.signPub)
        _ = try identity.completeVerification(account: "interop-account", deviceId: "interop-device", reveal: AtemVerifyReveal(
            devicePub: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation,
            deviceSignPub: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32)).publicKey.rawRepresentation,
            unlockAuthPub: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32)).publicKey.rawRepresentation,
            nonce: Data(repeating: 4, count: 32)), transcript: Data(repeating: 5, count: 32), expectedSigningKey: keys.signPub, key: nil)
        let fields = try AtemE2ECrypto.decode(report.signed.statement, maximumFields: 6)
        let time = fields[4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let value = try identity.openCredentialProjects(report, account: "interop-account", deviceId: "interop-device",
            now: Date(timeIntervalSince1970: Double(time)))
        XCTAssertEqual(value.projects, ["github.com/org/current", "github.com/org/reported"])
    }

    private struct Fixture {
        let storage = TestAtemStorage()
        let crypto = TestAtemCryptography()
        let device = Curve25519.Signing.PrivateKey()
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let account = AstationIdentity.shared.id
        let deviceId = "project-device"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity: AtemE2EIdentity

        init() throws {
            identity = AtemE2EIdentity(storage: storage, crypto: crypto)
            let keys = try identity.verificationKeys(nonce: Data(repeating: 3, count: 32))
            try identity.markRecoverySaved(signingPublicKey: keys.signPub)
            _ = try identity.completeVerification(account: account, deviceId: deviceId, reveal: AtemVerifyReveal(
                devicePub: encryption.publicKey.rawRepresentation, deviceSignPub: device.publicKey.rawRepresentation,
                unlockAuthPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, nonce: Data(repeating: 4, count: 32)),
                transcript: Data(repeating: 5, count: 32), expectedSigningKey: keys.signPub, key: nil)
        }

        func report(_ names: [String] = ["github.com/org/repo"], time: Date? = nil,
                    account reportAccount: String? = nil, device reportDevice: String? = nil,
                    recipient: Curve25519.KeyAgreement.PublicKey? = nil) throws -> AtemProjectReportWire {
            let fields = [Data((reportAccount ?? account).utf8), Data((reportDevice ?? deviceId).utf8),
                AtemStatements.number(1), AtemStatements.number(UInt64((time ?? now).timeIntervalSince1970))]
            let info = try AtemE2ECrypto.encode([Data("atem-credential-projects-info-v1".utf8)] + fields)
            var sender = try HPKE.Sender(recipientKey: recipient ?? crypto.encryption.publicKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
            let ciphertext = try sender.seal(JSONEncoder().encode(names), authenticating: Data())
            let hash = Data(SHA256.hash(data: try AtemE2ECrypto.encode([sender.encapsulatedKey, ciphertext])))
            let statement = try AtemE2ECrypto.encode([Data("atem-credential-projects-v1".utf8)] + fields + [hash])
            return AtemProjectReportWire(signed: AtemSignedWire(statement: statement, signature: try device.signature(for: statement)),
                encappedKey: sender.encapsulatedKey, ciphertext: ciphertext)
        }
    }

    func testVerifiedReportDecryptsWithoutChangingEncryptionAndRoundTripsWireFormat() throws {
        let f = try Fixture(), report = try f.report(["github.com/org/b", "github.com/org/a", "github.com/org/a"])
        let before = f.storage.data
        let value = try f.identity.openCredentialProjects(report, account: f.account, deviceId: f.deviceId, now: f.now)
        XCTAssertEqual(value.projects, ["github.com/org/a", "github.com/org/b"])
        XCTAssertEqual(f.storage.data, before)
        let bytes = try JSONEncoder().encode(AstationMessage.credentialProjectListResponse(report: report))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("github.com"))
        guard case .credentialProjectListResponse(let decoded) = try JSONDecoder().decode(AstationMessage.self, from: bytes) else {
            return XCTFail("wrong message")
        }
        XCTAssertEqual(decoded, report)
    }

    func testWrongBindingsRecipientTamperingAndExpiredReportsAreRejected() throws {
        let f = try Fixture()
        let rejected = [try f.report(account: "other"), try f.report(device: "other"),
            try f.report(time: f.now.addingTimeInterval(-301)), try f.report(time: f.now.addingTimeInterval(61)),
            try f.report(recipient: Curve25519.KeyAgreement.PrivateKey().publicKey)]
        for report in rejected {
            XCTAssertThrowsError(try f.identity.openCredentialProjects(report, account: f.account, deviceId: f.deviceId, now: f.now))
        }
        let valid = try f.report()
        var corrupt = valid.ciphertext; corrupt[corrupt.startIndex] ^= 1
        XCTAssertThrowsError(try f.identity.openCredentialProjects(AtemProjectReportWire(signed: valid.signed,
            encappedKey: valid.encappedKey, ciphertext: corrupt), account: f.account, deviceId: f.deviceId, now: f.now))
    }

    func testRevokedPinCannotDecryptOrRemainAProjectSource() throws {
        let f = try Fixture(), report = try f.report()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(f.storage.data)) as? [String: Any])
        record["devices"] = [String: Any]()
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        XCTAssertNil(try f.identity.credentialProjectPin(account: f.account, deviceId: f.deviceId))
        XCTAssertThrowsError(try f.identity.openCredentialProjects(report, account: f.account, deviceId: f.deviceId, now: f.now))
    }

    func testInvalidNamesAndOversizedInventoriesAreRejected() throws {
        let f = try Fixture()
        for names in [["local:scratch"], ["github.com/Org/Repo"], ["https://user:secret@github.com/org/repo"],
                      Array(repeating: "github.com/org/repo", count: 257)] {
            XCTAssertThrowsError(try f.identity.openCredentialProjects(f.report(names), account: f.account, deviceId: f.deviceId, now: f.now))
        }
    }

    func testAcceptedReportCanFinishAfterDisconnectAndDuplicatesAreIdempotent() throws {
        let f = try Fixture()
        let hub = AstationHubManager(skipProjectLoad: true, atemE2EIdentity: f.identity)
        let client = ConnectedClient(id: "project-client", clientType: "atem", connectedAt: Date(), atemId: f.deviceId)
        hub.connectedClients = [client]
        let report = try f.report(time: Date())
        _ = hub.handleMessage(.credentialProjectListResponse(report: report), from: client.id)
        hub.connectedClients = []
        let delivered = expectation(description: "accepted report processed")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(hub.credentialProjectSuggestions, ["github.com/org/repo"])
        hub.connectedClients = [client]
        _ = hub.handleMessage(.credentialProjectListResponse(report: report), from: client.id)
        let duplicate = expectation(description: "duplicate processed")
        DispatchQueue.main.async { duplicate.fulfill() }
        wait(for: [duplicate], timeout: 2)
        XCTAssertEqual(hub.credentialProjectSuggestions, ["github.com/org/repo"])
    }

    func testQueuedRevocationAndOlderReportsCannotReplaceCurrentSuggestions() throws {
        let f = try Fixture(), hub = AstationHubManager(skipProjectLoad: true, atemE2EIdentity: f.identity)
        let client = ConnectedClient(id: "project-client", clientType: "atem", connectedAt: Date(), atemId: f.deviceId)
        hub.connectedClients = [client]
        _ = hub.handleMessage(.credentialProjectListResponse(report: try f.report(["github.com/org/new"], time: Date())), from: client.id)
        _ = hub.handleMessage(.credentialProjectListResponse(report: try f.report(["github.com/org/old"], time: Date().addingTimeInterval(-10))), from: client.id)
        let ordered = expectation(description: "reports processed")
        DispatchQueue.main.async { ordered.fulfill() }
        wait(for: [ordered], timeout: 2)
        XCTAssertEqual(hub.credentialProjectSuggestions, ["github.com/org/new"])
        _ = hub.handleMessage(.credentialProjectListResponse(report: try f.report(["github.com/org/revoked"], time: Date())), from: client.id)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(f.storage.data)) as? [String: Any])
        record["devices"] = [String: Any]()
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        let revoked = expectation(description: "queued revoked report refused")
        DispatchQueue.main.async { revoked.fulfill() }
        wait(for: [revoked], timeout: 2)
        hub.requestCredentialProjects()
        XCTAssertTrue(hub.credentialProjectSuggestions.isEmpty)
    }
}
