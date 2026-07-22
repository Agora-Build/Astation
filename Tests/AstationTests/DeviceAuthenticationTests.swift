import Foundation
import XCTest
@testable import Menubar

final class DeviceAuthenticationTests: XCTestCase {
    func testDeviceLabelRemovesControlsAndBoundsLength() {
        let label = DeviceAuthentication.deviceLabel(
            "office\n\u{0000}" + String(repeating: "x", count: 300)
        )

        XCTAssertFalse(label.contains("\n"))
        XCTAssertEqual(label.count, 255)
        XCTAssertEqual(DeviceAuthentication.deviceLabel("\n\t"), "unknown")
    }

    func testProofMatchesProtocolVector() {
        let proof = DeviceAuthentication.proof(
            token: "token-abc",
            challenge: "challenge-123",
            astationId: "astation-home",
            atemId: "atem-office",
            sessionId: "session-456"
        )

        XCTAssertEqual(proof, "9fde5ba861c1a159d377b89e6fb3f92d245795998af958f5db3ad343d589d0ba")
        XCTAssertTrue(DeviceAuthentication.verify(
            proof: proof,
            token: "token-abc",
            challenge: "challenge-123",
            astationId: "astation-home",
            atemId: "atem-office",
            sessionId: "session-456"
        ))
        XCTAssertFalse(DeviceAuthentication.verify(
            proof: proof,
            token: "wrong-token",
            challenge: "challenge-123",
            astationId: "astation-home",
            atemId: "atem-office",
            sessionId: "session-456"
        ))
    }

    func testRejectsOversizedOrMalformedAuthenticationFields() {
        XCTAssertFalse(DeviceAuthentication.isValidAtemId(String(repeating: "a", count: 256)))
        XCTAssertFalse(DeviceAuthentication.isValidSessionId("session\nother"))
        XCTAssertFalse(DeviceAuthentication.isValidRequestId(""))
        XCTAssertFalse(DeviceAuthentication.isValidPairingCode(String(repeating: "1", count: 33)))
        XCTAssertFalse(DeviceAuthentication.verify(
            proof: String(repeating: "z", count: 64),
            token: "token-abc",
            challenge: "challenge-123",
            astationId: "astation-home",
            atemId: "atem-office",
            sessionId: "session-456"
        ))
    }

    func testBootstrapSecretIsStableAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationBootstrapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try LocalBootstrapStore(directory: directory)
        let second = try LocalBootstrapStore(directory: directory)
        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(first.token.count, 64)

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testSessionRequiresTokenProofAndMatchingDevice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        let session = store.create(hostname: "office", atemId: "atem-office")
        let proof = DeviceAuthentication.proof(
            token: session.token,
            challenge: "nonce",
            astationId: "astation-home",
            atemId: "atem-office",
            sessionId: session.id
        )

        XCTAssertNotNil(store.authenticate(
            sessionId: session.id,
            atemId: "atem-office",
            challenge: "nonce",
            proof: proof,
            astationId: "astation-home"
        ))
        XCTAssertNil(store.authenticate(
            sessionId: session.id,
            atemId: "atem-other",
            challenge: "nonce",
            proof: proof,
            astationId: "astation-home"
        ))
        XCTAssertNil(store.authenticate(
            sessionId: session.id,
            atemId: "atem-office",
            challenge: "new-nonce",
            proof: proof,
            astationId: "astation-home"
        ))
    }

    func testLegacySessionBindsToFirstDeviceWithValidProof() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationLegacySessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        let session = store.create(hostname: "legacy")
        let proof = DeviceAuthentication.proof(
            token: session.token,
            challenge: "nonce",
            astationId: "astation-home",
            atemId: "atem-first",
            sessionId: session.id
        )

        let authenticated = store.authenticate(
            sessionId: session.id,
            atemId: "atem-first",
            challenge: "nonce",
            proof: proof,
            astationId: "astation-home"
        )
        XCTAssertEqual(authenticated?.atemId, "atem-first")
        XCTAssertEqual(store.get(sessionId: session.id)?.atemId, "atem-first")
    }
}
