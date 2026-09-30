import CryptoKit
import Foundation
import Security
import XCTest
@testable import Menubar

/// In-memory stand-in for the Keychain so tests never touch the real one.
private final class MemoryRelayIdentityKeyStorage: RelayIdentityKeyStorage {
    var stored: Data?
    var readFailure: OSStatus?
    var writeCount = 0

    func read() -> RelayIdentityKeyReadResult {
        if let failure = readFailure {
            return .failed(failure)
        }
        if let data = stored {
            return .found(data)
        }
        return .notFound
    }

    func write(_ data: Data) -> OSStatus {
        stored = data
        writeCount += 1
        return errSecSuccess
    }
}

final class RelayIdentityTests: XCTestCase {
    private let challenge = String(repeating: "ab", count: 32)
    private let astationId = "astation-1F2E3D4C-0000-4000-8000-000000000001"

    private func object(_ text: String?) throws -> [String: Any] {
        let text = try XCTUnwrap(text)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Signing message + hex

    func testSigningMessageFormat() {
        XCTAssertEqual(
            RelayIdentityKey.signingMessage(challenge: "c0ffee", astationId: "astation-x"),
            "station-relay-auth-v1\nc0ffee\nastation-x"
        )
    }

    func testKeychainNamesMatchProtocol() {
        XCTAssertEqual(RelayIdentityKey.keychainService, "build.agora.astation.relay-identity")
        XCTAssertEqual(RelayIdentityKey.keychainAccount, "astation-relay-key-v1")
    }

    func testHexEncodingIsLowercaseAndZeroPadded() {
        XCTAssertEqual(RelayIdentityKey.hex(Data([0x00, 0x0a, 0xab, 0xff])), "000aabff")
        XCTAssertEqual(RelayIdentityKey.hex(Data()), "")
    }

    // MARK: Key + signature

    func testPublicKeyHexIsUncompressedX963() {
        let privateKey = P256.Signing.PrivateKey()
        let key = RelayIdentityKey(softwareKey: privateKey)

        XCTAssertEqual(key.publicKeyHex.count, 130)
        XCTAssertTrue(key.publicKeyHex.hasPrefix("04"))
        XCTAssertEqual(key.publicKeyHex, key.publicKeyHex.lowercased())
        XCTAssertEqual(key.publicKeyHex, RelayIdentityKey.hex(privateKey.publicKey.x963Representation))
        XCTAssertFalse(key.isHardwareBacked)
    }

    func testSignVerifyRoundTripWithSoftwareKey() throws {
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let signatureHex = try key.sign(challenge: challenge, astationId: astationId)
        XCTAssertEqual(signatureHex, signatureHex.lowercased())

        let der = try XCTUnwrap(dataFromHex(signatureHex))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: try XCTUnwrap(dataFromHex(key.publicKeyHex))
        )
        let message = Data(RelayIdentityKey.signingMessage(challenge: challenge, astationId: astationId).utf8)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))

        let otherMessage = Data(RelayIdentityKey.signingMessage(challenge: challenge, astationId: "astation-other").utf8)
        XCTAssertFalse(publicKey.isValidSignature(signature, for: otherMessage))
    }

    // MARK: Load or create

    func testLoadOrCreatePersistsSoftwareKeyAndReloadsIt() throws {
        let storage = MemoryRelayIdentityKeyStorage()
        let first = try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false)
        XCTAssertEqual(storage.stored?.count, RelayIdentityKey.softwareKeyLength)
        XCTAssertEqual(storage.writeCount, 1)

        let second = try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false)
        XCTAssertEqual(second.publicKeyHex, first.publicKeyHex)
        XCTAssertEqual(storage.writeCount, 1)
    }

    func testLoadOrCreateDoesNotReplaceKeyOnKeychainError() {
        let storage = MemoryRelayIdentityKeyStorage()
        storage.readFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false)) { error in
            XCTAssertEqual(error as? RelayIdentityKeyError, RelayIdentityKeyError.keychain(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(storage.writeCount, 0)
    }

    func testLoadOrCreateRegeneratesCorruptSoftwareKey() throws {
        // 32 zero bytes is not a valid P-256 scalar.
        let corrupt = Data(repeating: 0, count: RelayIdentityKey.softwareKeyLength)
        if (try? P256.Signing.PrivateKey(rawRepresentation: corrupt)) != nil {
            throw XCTSkip("CryptoKit accepted a zero scalar; corrupt-key path not exercisable")
        }
        let storage = MemoryRelayIdentityKeyStorage()
        storage.stored = corrupt
        let key = try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertNotEqual(storage.stored, corrupt)
        XCTAssertEqual(key.publicKeyHex.count, 130)
    }

    // MARK: Outbound JSON

    func testRelayAuthMessage() throws {
        let json = try object(RelayIdentityProtocol.authMessage(
            astationId: astationId,
            publicKeyHex: "04aa",
            signatureHex: "3045"
        ))
        XCTAssertEqual(Set(json.keys), ["type", "astation_id", "public_key", "signature"])
        XCTAssertEqual(json["type"] as? String, "relayAuth")
        XCTAssertEqual(json["astation_id"] as? String, astationId)
        XCTAssertEqual(json["public_key"] as? String, "04aa")
        XCTAssertEqual(json["signature"] as? String, "3045")
    }

    func testRelaySessionsMessage() throws {
        let json = try object(RelayIdentityProtocol.sessionsMessage(sessionIds: ["s-2", "s-1", "s-2"]))
        XCTAssertEqual(Set(json.keys), ["type", "sessions"])
        XCTAssertEqual(json["type"] as? String, "relaySessions")
        XCTAssertEqual(json["sessions"] as? [String], ["s-1", "s-2"])

        let empty = try object(RelayIdentityProtocol.sessionsMessage(sessionIds: []))
        XCTAssertEqual(empty["sessions"] as? [String], [])
    }

    func testRelayBindAndUnbindMessages() throws {
        let bind = try object(RelayIdentityProtocol.bindMessage(sessionId: "session-1"))
        XCTAssertEqual(Set(bind.keys), ["type", "session_id"])
        XCTAssertEqual(bind["type"] as? String, "relayBind")
        XCTAssertEqual(bind["session_id"] as? String, "session-1")

        let unbind = try object(RelayIdentityProtocol.unbindMessage(sessionId: "session-1"))
        XCTAssertEqual(Set(unbind.keys), ["type", "session_id"])
        XCTAssertEqual(unbind["type"] as? String, "relayUnbind")
        XCTAssertEqual(unbind["session_id"] as? String, "session-1")
    }

    // MARK: Inbound control frames

    func testParsesChallenge() {
        let text = "{\"type\":\"relayAuthChallenge\",\"protocol\":\"relay-auth-1\",\"challenge\":\"\(challenge)\"}"
        XCTAssertEqual(RelayIdentityProtocol.parseControlFrame(text), RelayControlFrame.authChallenge(challenge: challenge))
    }

    func testRejectsMalformedChallenges() {
        let upper = challenge.uppercased()
        let short = String(challenge.dropLast())
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame(
            "{\"type\":\"relayAuthChallenge\",\"protocol\":\"relay-auth-1\",\"challenge\":\"\(upper)\"}"
        ))
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame(
            "{\"type\":\"relayAuthChallenge\",\"protocol\":\"relay-auth-1\",\"challenge\":\"\(short)\"}"
        ))
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame(
            "{\"type\":\"relayAuthChallenge\",\"protocol\":\"relay-auth-2\",\"challenge\":\"\(challenge)\"}"
        ))
    }

    func testParsesAuthResultAndAck() {
        XCTAssertEqual(
            RelayIdentityProtocol.parseControlFrame("{\"type\":\"relayAuthResult\",\"status\":\"verified\",\"message\":\"ok\"}"),
            RelayControlFrame.authResult(status: "verified", message: "ok")
        )
        XCTAssertEqual(
            RelayIdentityProtocol.parseControlFrame("{\"type\":\"relayAuthResult\",\"status\":\"rejected\"}"),
            RelayControlFrame.authResult(status: "rejected", message: nil)
        )
        XCTAssertEqual(
            RelayIdentityProtocol.parseControlFrame("{\"type\":\"relayAck\",\"for\":\"relayBind\",\"ok\":false,\"message\":\"owned\"}"),
            RelayControlFrame.ack(forType: "relayBind", ok: false, message: "owned")
        )
    }

    func testAtemEnvelopesAreNotControlFrames() {
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame(
            "{\"atem_id\":\"atem-1\",\"connection_id\":\"43c8a181-6567-49ae-9191-8e103a66cc55\",\"payload\":{\"type\":\"relayAuthResult\"}}"
        ))
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame(
            "{\"type\":\"relayAuthResult\",\"status\":\"verified\",\"atem_id\":\"atem-1\"}"
        ))
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame("{\"type\":\"somethingElse\"}"))
        XCTAssertNil(RelayIdentityProtocol.parseControlFrame("not json"))
    }

    // MARK: SessionStore change notifications

    func testSessionStoreNotifiesGrantAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))

        var granted: [String] = []
        var removed: [String] = []
        let grantExpectation = expectation(description: "granted")
        let removeExpectation = expectation(description: "removed")
        store.onSessionGranted = { id in
            granted.append(id)
            grantExpectation.fulfill()
        }
        store.onSessionsRemoved = { ids in
            removed.append(contentsOf: ids)
            removeExpectation.fulfill()
        }

        let session = store.create(hostname: "office", atemId: "atem-office")
        wait(for: [grantExpectation], timeout: 2)
        XCTAssertEqual(granted, [session.id])

        store.delete(sessionId: session.id)
        wait(for: [removeExpectation], timeout: 2)
        XCTAssertEqual(removed, [session.id])
    }

    func testSessionStoreNotifiesExpiredSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))

        let expired = store.createTest(
            id: "expired-session",
            hostname: "old",
            lastActivity: Date().addingTimeInterval(-8 * 24 * 60 * 60)
        )
        _ = store.createTest(id: "fresh-session", hostname: "new", lastActivity: Date())

        var removed: [String] = []
        let removeExpectation = expectation(description: "expired removed")
        store.onSessionsRemoved = { ids in
            removed.append(contentsOf: ids)
            removeExpectation.fulfill()
        }
        store.cleanupExpired()
        wait(for: [removeExpectation], timeout: 2)
        XCTAssertEqual(removed, [expired.id])
    }

    // MARK: Helpers

    private func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
