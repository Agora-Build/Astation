import CryptoKit
import XCTest
@testable import Menubar

// Concurrent tests access mutable fixture state through the identity's lock after setup.
private final class MigrationFixture: @unchecked Sendable {
    let account = AstationIdentity.shared.id
    let deviceId = "migration-device"
    let storage = TestAtemStorage()
    let crypto = TestAtemCryptography()
    let device = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let unlockAuth = Curve25519.Signing.PrivateKey()
    let key: AccountDataKey
    let identity: AtemE2EIdentity
    let keys: AtemVerifyKeys
    let route: AtemVerificationRoute

    init() throws {
        let bytes = Data(repeating: 0x99, count: 32)
        key = AccountDataKey(kid: SHA256.hash(data: bytes).prefix(4).map { String(format: "%02x", $0) }.joined(), key: bytes)
        identity = AtemE2EIdentity(storage: storage, crypto: crypto)
        keys = try identity.verificationKeys(nonce: Data(repeating: 8, count: 32))
        route = AtemVerificationRoute(clientId: UUID().uuidString, connectionId: "original-connection",
            deviceId: deviceId, deviceName: "Migration fixture")
        try identity.markRecoverySaved(signingPublicKey: keys.signPub)
        try verify()
        _ = try identity.setState(account: account, mode: "enabling", kid: key.kid)
    }

    func verify() throws {
        let state = try identity.state(account: account)
        _ = try identity.completeVerification(account: account, deviceId: deviceId,
            reveal: AtemVerifyReveal(devicePub: device.publicKey.rawRepresentation,
                deviceSignPub: signing.publicKey.rawRepresentation, unlockAuthPub: unlockAuth.publicKey.rawRepresentation,
                nonce: Data(repeating: 4, count: 32)), transcript: Data(repeating: 9, count: 32),
            expectedSigningKey: keys.signPub, key: state?.mode != nil && state?.mode != "off" ? key : nil)
    }

    func report(target: String = "on", epoch: UInt64? = nil, stores: UInt64 = 7, remaining: UInt64 = 0,
                account: String? = nil, deviceId: String? = nil, kid: String? = nil, proofKey: Data? = nil) throws -> AtemSignedWire {
        let fields = [Data("atem-migration-complete-v1".utf8), Data((account ?? self.account).utf8), AtemStatements.number(1),
            Data((deviceId ?? self.deviceId).utf8), Data(target.utf8), Data((kid ?? key.kid).utf8),
            AtemStatements.number(try epoch ?? XCTUnwrap(identity.state(account: self.account)).epoch),
            AtemStatements.number(stores), AtemStatements.number(remaining)]
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: proofKey ?? key.key),
            salt: Data(), info: Data("atem-migration-proof-v1".utf8), outputByteCount: 32)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: try AtemE2ECrypto.encode(fields), using: derived))
        let statement = try AtemE2ECrypto.encode(fields + [proof])
        return AtemSignedWire(statement: statement, signature: try signing.signature(for: statement))
    }

    func accept(_ signed: AtemSignedWire? = nil, target: String = "on", route: AtemVerificationRoute? = nil) throws -> AtemMigrationCommit? {
        try identity.acceptMigrationCompletion(signed ?? report(target: target), mode: target, kid: key.kid,
            account: account, route: route ?? self.route, key: key)
    }

    func revoke() throws {
        let storageKid = "0a1b2c3d"
        if try identity.storageKeyStatus(account: account, deviceId: deviceId) == nil {
            let sealed = try AtemE2ECrypto.sealKey(Data(repeating: 0xee, count: 32), to: keys.encPub,
                info: AtemStatements.storageKeyInfo(account: account, deviceId: deviceId, kid: storageKid))
            let statement = try AtemStatements.storageRotate(account: account, deviceId: deviceId,
                oldKid: "", newKid: storageKid, sealedHash: AtemE2ECrypto.sealedKeyDigest(sealed))
            _ = try identity.rotateStorageKey(AtemStorageRotateWire(
                rotate: AtemSignedWire(statement: statement, signature: try signing.signature(for: statement)),
                encappedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext), account: account, deviceId: deviceId)
        }
        let now = Date()
        let request = try AtemStatements.unlockRequest(account: account, deviceId: deviceId, bootId: "fixture",
            ephemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            nonce: Data(repeating: 2, count: 32), time: UInt64(now.timeIntervalSince1970), storageKid: storageKid)
        let authorization = try identity.prepareUnlock(AtemUnlockRequestWire(request: request,
            signature: unlockAuth.signature(for: request)), account: account, deviceId: deviceId, now: now)
        try identity.revokeDevice(authorization)
    }
}

@MainActor
private final class MigrationQueue {
    var work: [() -> Void] = []
    func drain() { while !work.isEmpty { work.removeFirst()() } }
}

private final class MigrationRelaySocket: IdentityRelaySocket, @unchecked Sendable {
    var sent: [String] = []
    var closeCode = URLSessionWebSocketTask.CloseCode.invalid
    var closeReason: Data?
    private var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message { sent.append(text) }
        completionHandler(nil)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiver = completionHandler
    }
    func emit(_ object: [String: Any]) throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let callback = receiver
        receiver = nil
        callback?(.success(.string(text)))
    }
}

@MainActor
private final class MigrationRelayFixture {
    let f: MigrationFixture
    let queue = MigrationQueue()
    let socket = MigrationRelaySocket()
    let hub: AstationHubManager
    let session: SessionInfo
    let directory: URL
    let defaults: UserDefaults
    let suite = "Astation.migration-relay-test.\(UUID().uuidString)"
    var connectionId = UUID().uuidString
    var clientId: String { "relay-\(f.deviceId)" }

    init(_ f: MigrationFixture) throws {
        self.f = f
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        session = sessions.create(hostname: "Migration", atemId: f.deviceId)
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let manager = RelayIdentityKeyManager(loadKey: { _ in key }, perform: { $0() }, deliver: { $0() }, schedule: { _, _ in })
        let socket = self.socket, queue = self.queue
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            relayIdentityKeyManager: manager, relayIdentityRepairDefaults: defaults, atemE2EIdentity: f.identity,
            loadMigrationKey: { _, _ in f.key }, dispatchMigration: { queue.work.append($0) },
            makeIdentityRelayTask: { _ in socket })
    }

    func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    func start(authenticate: Bool = true) async throws {
        hub.startIdentityRelay()
        try socket.emit(["type": "relayAuthResult", "status": "verified"])
        await drain()
        queue.drain()
        if authenticate {
            try emit(.statusUpdate(status: "hello", data: ["hostname": "Migration"]))
            await drain()
            let frames = try socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let payload = try XCTUnwrap(frames.last(where: { ($0["payload"] as? [String: Any])?["type"] as? String == "statusUpdate" })?["payload"] as? [String: Any])
            let data = try XCTUnwrap(payload["data"] as? [String: Any])
            let status = try XCTUnwrap(data["data"] as? [String: String])
            let proof = DeviceAuthentication.proof(token: session.token, challenge: try XCTUnwrap(status["challenge"]),
                astationId: AstationIdentity.shared.id, atemId: f.deviceId, sessionId: session.id)
            try emit(.statusUpdate(status: "auth", data: ["atem_id": f.deviceId, "session_id": session.id, "proof": proof]))
            await drain()
            XCTAssertEqual(hub.connectedClients.map(\.id), [clientId])
        }
    }

    func emit(_ message: AstationMessage) throws {
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        try socket.emit(["atem_id": f.deviceId, "connection_id": connectionId, "payload": payload])
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class AtemEncryptionMigrationTests: XCTestCase {
    private func hub(_ f: MigrationFixture, queue: MigrationQueue, identity: AtemE2EIdentity? = nil,
                     load: ((String, String?) throws -> AccountDataKey?)? = nil) -> AstationHubManager {
        let hub = AstationHubManager(skipProjectLoad: true, atemE2EIdentity: identity ?? f.identity,
            loadMigrationKey: load ?? { _, _ in f.key }, dispatchMigration: { queue.work.append($0) })
        hub.connectedClients = [ConnectedClient(id: f.route.clientId, clientType: "Atem", connectedAt: Date(), atemId: f.deviceId)]
        return hub
    }

    func testImmediateDisconnectAndDelayedHandlerUseDurablyAcceptedIdentity() throws {
        let f = try MigrationFixture(), queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        let report = try f.report()
        _ = hub.handleMessage(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: report), from: f.route.clientId)
        XCTAssertEqual(try f.identity.pendingMigrationAccounts(), [f.account])
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        hub.connectedClients = []
        queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
        XCTAssertTrue(try f.identity.pendingMigrationAccounts().isEmpty)
    }

    func testDuplicateDeliveryBeforeAndAfterCommitDoesNotAdvanceEpochOrRewriteJournal() throws {
        let f = try MigrationFixture(), report = try f.report()
        _ = try f.accept(report)
        let acceptedWrites = f.storage.writes
        _ = try f.accept(report)
        XCTAssertEqual(f.storage.writes, acceptedWrites)
        let commit = try XCTUnwrap(f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        let state = try f.identity.state(account: f.account), writes = f.storage.writes
        let duplicate = try XCTUnwrap(f.accept(report))
        XCTAssertEqual(duplicate.signedState, commit.signedState)
        XCTAssertNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account), state)
        XCTAssertEqual(f.storage.writes, writes)
    }

    func testRestartAfterAcceptanceFinishesWithoutAnyAtemConnection() throws {
        let f = try MigrationFixture()
        _ = try f.accept()
        let reloaded = AtemE2EIdentity(storage: f.storage, crypto: f.crypto), queue = MigrationQueue()
        let hub = hub(f, queue: queue, identity: reloaded)
        hub.connectedClients = []
        queue.drain()
        XCTAssertEqual(try reloaded.state(account: f.account)?.mode, "on")
        let restarted = AtemE2EIdentity(storage: f.storage, crypto: f.crypto)
        XCTAssertEqual(try restarted.acceptMigrationCompletion(f.report(epoch: 3), mode: "on", kid: f.key.kid,
            account: f.account, route: f.route, key: f.key)?.target, "on")
    }

    func testFinalSaveFailurePublishesNothingAndRecoversFromJournal() throws {
        let f = try MigrationFixture(), queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        var published: [AstationMessage] = []
        hub.broadcastHandler = { published.append($0) }
        _ = hub.handleMessage(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: try f.report()), from: f.route.clientId)
        let before = f.storage.data
        f.storage.failWrite = true
        hub.connectedClients = []
        queue.drain()
        XCTAssertEqual(f.storage.data, before)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        f.storage.failWrite = false
        let reload = AtemE2EIdentity(storage: f.storage, crypto: f.crypto)
        XCTAssertNotNil(try reload.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try reload.state(account: f.account)?.mode, "on")
    }

    func testAcceptanceSaveFailureDoesNotQueueWorkOrAuthorizeCompletion() throws {
        let f = try MigrationFixture(), queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        let report = try f.report(), before = f.storage.data
        f.storage.failWrite = true
        _ = hub.handleMessage(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: report), from: f.route.clientId)
        XCTAssertEqual(f.storage.data, before)
        XCTAssertTrue(queue.work.isEmpty)
        XCTAssertTrue(try f.identity.pendingMigrationAccounts().isEmpty)
    }

    func testMissingKeyAndSigningFailureRetainAcceptedReportForRetry() throws {
        let f = try MigrationFixture()
        _ = try f.accept()
        let before = f.storage.data
        XCTAssertThrowsError(try f.identity.finishAcceptedMigration(account: f.account, key: nil))
        f.crypto.failSign = true
        XCTAssertThrowsError(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(f.storage.data, before)
        f.crypto.failSign = false
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
    }

    func testReconnectWithSameDeviceIdCannotReplaceAnAcceptedConnectionContext() throws {
        let f = try MigrationFixture(), queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        _ = hub.handleMessage(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: try f.report()), from: f.route.clientId)
        hub.connectedClients = [ConnectedClient(id: UUID().uuidString, clientType: "Atem", connectedAt: Date(), atemId: f.deviceId)]
        queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
    }

    func testRevocationBetweenAcceptanceAndCommitInvalidatesOnlyTheReport() throws {
        let f = try MigrationFixture()
        _ = try f.accept()
        try f.revoke()
        XCTAssertThrowsError(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        XCTAssertTrue(try f.identity.pendingMigrationAccounts().isEmpty)
        try f.verify()
        _ = try f.accept()
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
    }

    func testReverificationWithIdenticalKeysStillInvalidatesAnAcceptedReport() throws {
        let f = try MigrationFixture()
        _ = try f.accept()
        try f.verify()
        XCTAssertThrowsError(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
    }

    func testOldReportCannotAcquireNewAuthorizationAfterRevocationAndIdenticalKeyReverification() throws {
        let f = try MigrationFixture(), oldReport = try f.report()
        try f.revoke()
        try f.verify()
        let before = f.storage.data
        XCTAssertThrowsError(try f.accept(oldReport))
        XCTAssertEqual(f.storage.data, before)
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        XCTAssertTrue(try f.identity.pendingMigrationAccounts().isEmpty)
        _ = try f.accept()
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
    }

    func testRevocationBeforeAcceptanceRejectsAndAfterCommitDoesNotRollBackOn() throws {
        let f = try MigrationFixture(), report = try f.report()
        try f.revoke()
        XCTAssertThrowsError(try f.accept(report))
        try f.verify()
        _ = try f.accept()
        _ = try f.identity.finishAcceptedMigration(account: f.account, key: f.key)
        let final = try f.identity.state(account: f.account)
        try f.revoke()
        XCTAssertEqual(try f.identity.state(account: f.account), final)
        XCTAssertThrowsError(try f.accept(report))
    }

    func testConcurrentRevocationAndCommitHaveOneDurableOrdering() throws {
        for _ in 0..<8 {
            let f = try MigrationFixture()
            _ = try f.accept()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do {
                    if index == 0 { try f.revoke() }
                    else { _ = try f.identity.finishAcceptedMigration(account: f.account, key: f.key) }
                } catch {
                    if index != 1 || (error as? AtemMigrationError) != .revokedDevice {
                        XCTFail("Unexpected race failure: \(error)")
                    }
                }
            }
            let reloaded = AtemE2EIdentity(storage: f.storage, crypto: f.crypto)
            XCTAssertFalse(try reloaded.isVerified(account: f.account, deviceId: f.deviceId))
            XCTAssertTrue(try reloaded.pendingMigrationAccounts().isEmpty)
            let state = try XCTUnwrap(reloaded.state(account: f.account))
            if state.mode == "on" {
                XCTAssertNotNil(try reloaded.currentMigrationCommit(account: f.account))
            } else {
                XCTAssertEqual(state.mode, "enabling")
                XCTAssertNil(try reloaded.currentMigrationCommit(account: f.account))
            }
        }
    }

    func testPreviousMigrationCannotCompleteANewOperationEvenWithTheSameKid() throws {
        let f = try MigrationFixture(), report = try f.report()
        _ = try f.accept(report)
        _ = try f.identity.setState(account: f.account, mode: "enabling", kid: f.key.kid)
        XCTAssertThrowsError(try f.accept(report))
        XCTAssertNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        _ = try f.accept()
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
    }

    func testUnsignedForgedIncompleteAndWrongContextReportsCannotAuthorizeOn() throws {
        let f = try MigrationFixture(), valid = try f.report(), before = f.storage.data
        let forged = AtemSignedWire(statement: valid.statement,
            signature: try Curve25519.Signing.PrivateKey().signature(for: valid.statement))
        let reports = [forged, try f.report(stores: 3), try f.report(remaining: 1), try f.report(account: "other-account"),
            try f.report(deviceId: "other-device"), try f.report(kid: "0123abcd"), try f.report(epoch: UInt64.max),
            try f.report(proofKey: Data(repeating: 0, count: 32))]
        for report in reports { XCTAssertThrowsError(try f.accept(report)) }
        XCTAssertThrowsError(try f.identity.acceptMigrationCompletion(nil, mode: "on", kid: f.key.kid,
            account: f.account, route: f.route, key: f.key))
        XCTAssertThrowsError(try f.identity.setState(account: f.account, mode: "on", kid: f.key.kid))
        XCTAssertThrowsError(try f.identity.setState(account: f.account, mode: "off", kid: nil))
        let queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        _ = hub.handleMessage(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: valid), from: "not-connected")
        hub.setRelayEncryption(mode: "on", kid: f.key.kid)
        queue.drain()
        XCTAssertEqual(f.storage.data, before)
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
    }

    func testLegacyKeyWithoutApprovedStateRequiresMigrationBeforeOn() throws {
        let f = try MigrationFixture()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        record["accounts"] = [String: Any]()
        record["migrations"] = [String: Any]()
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        _ = try f.identity.signedState(account: f.account, key: f.key)
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        _ = try f.accept()
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
    }

    func testDisablingCommitsOffDurablyAndDuplicatesReuseItsSignature() throws {
        let f = try MigrationFixture()
        _ = try f.identity.setState(account: f.account, mode: "disabling", kid: f.key.kid)
        let report = try f.report(target: "off")
        _ = try f.accept(report, target: "off")
        let final = try XCTUnwrap(f.identity.finishAcceptedMigration(account: f.account, key: f.key))
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "off")
        XCTAssertNil(try f.identity.state(account: f.account)?.kid)
        XCTAssertEqual(try f.accept(report, target: "off")?.signedState, final.signedState)
    }

    func testMessageRoundTripPreservesSignatureAndLegacyPacketFailsClosed() throws {
        let f = try MigrationFixture(), completion = try f.report()
        let message = AstationMessage.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: completion)
        let decoded = try JSONDecoder().decode(AstationMessage.self, from: JSONEncoder().encode(message))
        guard case .encryptionMigrationComplete(let mode, let kid, let signed) = decoded else { return XCTFail("Wrong message") }
        XCTAssertEqual(mode, "on")
        XCTAssertEqual(kid, f.key.kid)
        XCTAssertEqual(signed, completion)
        let legacy = try JSONDecoder().decode(AstationMessage.self,
            from: Data("{\"type\":\"encryptionMigrationComplete\",\"data\":{\"mode\":\"on\",\"kid\":\"\(f.key.kid)\"}}".utf8))
        let queue = MigrationQueue(), hub = hub(f, queue: queue)
        queue.drain()
        _ = hub.handleMessage(legacy, from: f.route.clientId)
        queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
    }

    func testRelayImmediateDisconnectStillFinalizesAnAcceptedCompletion() async throws {
        let f = try MigrationFixture(), relay = try MigrationRelayFixture(f)
        try await relay.start()
        try relay.emit(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: try f.report()))
        try relay.socket.emit(["atem_id": f.deviceId, "connection_id": relay.connectionId, "relay_event": "disconnected"])
        await relay.drain()
        XCTAssertTrue(relay.hub.connectedClients.isEmpty)
        XCTAssertEqual(try f.identity.pendingMigrationAccounts(), [f.account])
        relay.queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
    }

    func testAccountRoutingChangeAfterAcceptanceCannotRetargetTheCommitOrPublication() async throws {
        let f = try MigrationFixture(), relay = try MigrationRelayFixture(f)
        try await relay.start()
        try relay.emit(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: try f.report()))
        await relay.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        var published: [AstationMessage] = []
        relay.hub.broadcastHandler = { published.append($0) }
        relay.socket.sent.removeAll()
        let otherAccount = "other-account"
        try relay.socket.emit(["type": "relayEncryptionState", "data_account": otherAccount, "mode": "off",
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
        await relay.drain()
        relay.queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
        XCTAssertNil(try f.identity.state(account: otherAccount))
        XCTAssertEqual(relay.hub.relayEncryptionState?.dataAccount, otherAccount)
        XCTAssertEqual(relay.hub.relayEncryptionState?.mode, "off")
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(relay.socket.sent.isEmpty)
        try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account, "mode": "enabling", "kid": f.key.kid,
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
        await relay.drain()
        let frames = try relay.socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(frames.contains { $0["type"] as? String == "relayEncryptionSet" && $0["mode"] as? String == "on" })
    }

    func testRelayCannotAuthorizeCompletionByClaimingOnOrByForgingDeviceIdentity() async throws {
        let f = try MigrationFixture(), relay = try MigrationRelayFixture(f)
        try await relay.start(authenticate: false)
        try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account, "mode": "on", "kid": f.key.kid,
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 10, "obsolete_fields": 0])
        try relay.emit(.encryptionMigrationComplete(mode: "on", kid: f.key.kid, completion: try f.report()))
        await relay.drain()
        relay.queue.drain()
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "enabling")
        XCTAssertTrue(try f.identity.pendingMigrationAccounts().isEmpty)
        XCTAssertEqual(relay.hub.relayEncryptionState?.mode, "enabling")
    }

    func testRelayCannotDisplayApprovedOnWhenNoLocalStateExists() async throws {
        let f = try MigrationFixture()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        record["accounts"] = [String: Any]()
        record["migrations"] = [String: Any]()
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        let before = f.storage.data, relay = try MigrationRelayFixture(f)
        try await relay.start(authenticate: false)
        try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account, "mode": "on", "kid": f.key.kid,
            "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 10, "obsolete_fields": 0])
        await relay.drain()
        XCTAssertEqual(relay.hub.relayEncryptionState?.mode, "off")
        XCTAssertNil(try f.identity.state(account: f.account))
        XCTAssertEqual(f.storage.data, before)
    }

    func testRelayMissedPendingTransitionRecoversWithoutChangingLocalFinalState() async throws {
        for target in ["on", "off"] {
            let f = try MigrationFixture()
            if target == "off" { _ = try f.identity.setState(account: f.account, mode: "disabling", kid: f.key.kid) }
            _ = try f.accept(target: target)
            let committed = try XCTUnwrap(f.identity.finishAcceptedMigration(account: f.account, key: f.key))
            let relay = try MigrationRelayFixture(f)
            try await relay.start(authenticate: false)
            let pending = target == "on" ? "enabling" : "disabling"
            try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account,
                "mode": target == "on" ? "off" : "on", "kid": f.key.kid,
                "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
            await relay.drain()
            var frames = try relay.socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertEqual(frames.last(where: { $0["type"] as? String == "relayEncryptionSet" })?["mode"] as? String, pending)
            XCTAssertEqual(try f.identity.state(account: f.account)?.mode, target)
            XCTAssertEqual(relay.hub.relayEncryptionState?.mode, target)
            try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account,
                "mode": pending, "kid": f.key.kid,
                "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
            await relay.drain()
            frames = try relay.socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertEqual(frames.last(where: { $0["type"] as? String == "relayEncryptionSet" })?["mode"] as? String, target)
            XCTAssertEqual(try f.identity.currentMigrationCommit(account: f.account)?.signedState, committed.signedState)
            XCTAssertTrue(relay.hub.connectedClients.isEmpty)
        }
    }

    func testRelayReconnectReplicatesDurableFinalStateWithoutAnAtem() async throws {
        for target in ["on", "off"] {
            let f = try MigrationFixture()
            if target == "off" { _ = try f.identity.setState(account: f.account, mode: "disabling", kid: f.key.kid) }
            _ = try f.accept(target: target)
            _ = try f.identity.finishAcceptedMigration(account: f.account, key: f.key)
            let relay = try MigrationRelayFixture(f)
            try await relay.start(authenticate: false)
            try relay.socket.emit(["type": "relayEncryptionState", "data_account": f.account,
                "mode": target == "on" ? "enabling" : "disabling", "kid": f.key.kid,
                "updated_at": 0, "plaintext_fields": 0, "ciphertext_fields": 0, "obsolete_fields": 0])
            await relay.drain()
            XCTAssertTrue(relay.hub.connectedClients.isEmpty)
            let frames = try relay.socket.sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertTrue(frames.contains { $0["type"] as? String == "relayEncryptionSet" && $0["mode"] as? String == target })
            XCTAssertEqual(try f.identity.state(account: f.account)?.mode, target)
        }
    }

    func testVersionTwoApprovedOnStateRemainsApprovedWithoutReplacingKeys() throws {
        let f = try MigrationFixture()
        _ = try f.accept()
        _ = try f.identity.finishAcceptedMigration(account: f.account, key: f.key)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        let material = try XCTUnwrap(record["material"] as? NSDictionary)
        record["version"] = 2
        record.removeValue(forKey: "migrations")
        record.removeValue(forKey: "deviceVerificationEpochs")
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        _ = try f.identity.signedState(account: f.account, key: f.key)
        XCTAssertEqual(try f.identity.state(account: f.account)?.mode, "on")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 3)
        XCTAssertEqual(saved["material"] as? NSDictionary, material)
        XCTAssertEqual(f.crypto.creates, 1)
    }

    func testVersionTwoPendingMigrationUpgradesWithoutReplacingIdentityOrDeviceKeys() throws {
        let f = try MigrationFixture(), report = try f.report()
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        let material = try XCTUnwrap(record["material"] as? NSDictionary), devices = try XCTUnwrap(record["devices"] as? NSDictionary)
        record["version"] = 2
        record.removeValue(forKey: "migrations")
        record.removeValue(forKey: "deviceVerificationEpochs")
        f.storage.data = try JSONSerialization.data(withJSONObject: record)
        _ = try f.accept(report)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(f.storage.data)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 3)
        XCTAssertEqual(saved["material"] as? NSDictionary, material)
        XCTAssertEqual(saved["devices"] as? NSDictionary, devices)
        XCTAssertEqual(f.crypto.creates, 1)
        XCTAssertNotNil(try f.identity.finishAcceptedMigration(account: f.account, key: f.key))
    }

    func testMigrationKeyProofMatchesTheSharedRustVector() throws {
        let fields = [Data("atem-migration-complete-v1".utf8), Data("acct-1".utf8), AtemStatements.number(1),
            Data("dev-1".utf8), Data("on".utf8), Data("0123abcd".utf8), AtemStatements.number(3),
            AtemStatements.number(7), AtemStatements.number(0)]
        let proof = try XCTUnwrap(Data(base64Encoded: "dF8njJcWm2vy8+Jgv211qWCnvPDq2BQW04E62Ka892k="))
        let statement = try AtemE2ECrypto.encode(fields + [proof])
        let key = Curve25519.Signing.PrivateKey()
        let wire = AtemSignedWire(statement: statement, signature: try key.signature(for: statement))
        XCTAssertNoThrow(try AtemMigrationCompletion(wire).verifyKey(AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))))
    }
}
