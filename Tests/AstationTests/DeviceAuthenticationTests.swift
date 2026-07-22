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

        let multibyteLabel = DeviceAuthentication.deviceLabel(String(repeating: "界", count: 100))
        XCTAssertEqual(multibyteLabel.utf8.count, 255)
        XCTAssertEqual(multibyteLabel.count, 85)
    }

    func testRelayClientIdentityMustMatchAuthenticatedAtemId() {
        XCTAssertTrue(DeviceAuthentication.relayClientMatchesAtemId(
            clientId: "relay-atem-office",
            atemId: "atem-office"
        ))
        XCTAssertFalse(DeviceAuthentication.relayClientMatchesAtemId(
            clientId: "relay-atem-cloud",
            atemId: "atem-office"
        ))
        XCTAssertFalse(DeviceAuthentication.relayClientMatchesAtemId(
            clientId: "relay-atem-office",
            atemId: "atem-office\nspoof"
        ))
        XCTAssertTrue(DeviceAuthentication.isValidRelayConnectionId(
            "43c8a181-6567-49ae-9191-8e103a66cc55"
        ))
        XCTAssertFalse(DeviceAuthentication.isValidRelayConnectionId("connection-one"))
    }

    func testRelayAuthenticationIsBoundToConnectionGeneration() {
        let clientId = "relay-atem-office"
        let firstConnection = "43c8a181-6567-49ae-9191-8e103a66cc55"
        let replacementConnection = "328e433e-82c0-4d54-9241-503de8ff55dd"
        var state = IdentityRelayAuthenticationState()

        XCTAssertFalse(state.connect(clientId: clientId, connectionId: firstConnection))
        XCTAssertTrue(state.issueChallenge(
            clientId: clientId,
            connectionId: firstConnection,
            challenge: "first-challenge"
        ))
        XCTAssertTrue(state.authenticate(
            clientId: clientId,
            atemId: "atem-office",
            connectionId: firstConnection
        ))
        XCTAssertTrue(state.isAuthenticated(clientId: clientId, connectionId: firstConnection))

        XCTAssertTrue(state.connect(clientId: clientId, connectionId: replacementConnection))
        XCTAssertFalse(state.isAuthenticated(clientId: clientId, connectionId: replacementConnection))
        XCTAssertNil(state.challenge(clientId: clientId, connectionId: firstConnection))
        XCTAssertFalse(state.disconnect(clientId: clientId, connectionId: firstConnection))
        XCTAssertEqual(state.connectionId(for: clientId), replacementConnection)

        XCTAssertTrue(state.issueChallenge(
            clientId: clientId,
            connectionId: replacementConnection,
            challenge: "replacement-challenge"
        ))
        XCTAssertTrue(state.authenticate(
            clientId: clientId,
            atemId: "atem-office",
            connectionId: replacementConnection
        ))
        XCTAssertTrue(state.isAuthenticated(clientId: clientId, connectionId: replacementConnection))
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

    func testBootstrapSecretRotatesWhenPermissionsAreInsecure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationBootstrapPermissionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exposedToken = String(repeating: "a", count: 64)
        let tokenURL = directory.appendingPathComponent(LocalBootstrapStore.filename)
        try Data((exposedToken + "\n").utf8).write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenURL.path)

        let store = try LocalBootstrapStore(directory: directory)
        let mode = try FileManager.default.attributesOfItem(atPath: tokenURL.path)[.posixPermissions] as? NSNumber
        XCTAssertNotEqual(store.token, exposedToken)
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testBootstrapSecretReplacesSymbolicLinkWithoutTouchingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationBootstrapSymlinkTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("store")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exposedToken = String(repeating: "b", count: 64)
        try Data((exposedToken + "\n").utf8).write(to: target)
        let tokenURL = directory.appendingPathComponent(LocalBootstrapStore.filename)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)

        let store = try LocalBootstrapStore(directory: directory)
        let targetContents = try String(contentsOf: target, encoding: .utf8)
        let tokenValues = try tokenURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertNotEqual(store.token, exposedToken)
        XCTAssertEqual(targetContents, exposedToken + "\n")
        XCTAssertEqual(tokenValues.isRegularFile, true)
        XCTAssertNotEqual(tokenValues.isSymbolicLink, true)
    }

    func testRelayAuthenticationChallengesAreBoundedAndExpire() {
        let now = Date(timeIntervalSince1970: 1_000)
        var store = RelayAuthenticationChallengeStore(maxPending: 2, lifetime: 10)

        XCTAssertTrue(store.issue(clientId: "atem-a", challenge: "challenge-a", now: now))
        XCTAssertTrue(store.issue(clientId: "atem-b", challenge: "challenge-b", now: now))
        XCTAssertFalse(store.issue(clientId: "atem-c", challenge: "challenge-c", now: now))
        XCTAssertEqual(store.challenge(for: "atem-a", now: now), "challenge-a")
        XCTAssertNil(store.challenge(for: "atem-a", now: now.addingTimeInterval(11)))
        XCTAssertTrue(store.issue(
            clientId: "atem-c",
            challenge: "challenge-c",
            now: now.addingTimeInterval(11)
        ))
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
