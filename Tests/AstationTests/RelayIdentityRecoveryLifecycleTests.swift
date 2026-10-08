import CryptoKit
import Foundation
import Security
import XCTest
@testable import Menubar

private final class RecoverySocket: IdentityRelaySocket, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode
    var sent: [String] = []
    var wasCancelled = false
    var closeCode: CloseCode = .invalid
    var closeReason: Data?
    private var receiver: ((Result<Message, Error>) -> Void)?

    func resume() {}
    func cancel(with closeCode: CloseCode, reason: Data?) { wasCancelled = true }
    func send(_ message: Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message { sent.append(text) }
        completionHandler(nil)
    }
    func receive(completionHandler: @escaping @Sendable (Result<Message, Error>) -> Void) {
        receiver = completionHandler
    }
    func emit(_ text: String) {
        let callback = receiver
        receiver = nil
        callback?(.success(.string(text)))
    }
}

private final class UnsavableRecoveryDefaults: UserDefaults {
    override func synchronize() -> Bool { false }
}

@MainActor
private final class RecoveryFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
    var hub: AstationHubManager!
    var sockets: [RecoverySocket] = []
    var loadFailure: RelayIdentityKeyError?
    var repairFailure: RelayIdentityKeyError?
    var reads: [Bool] = []
    var repairs = 0
    var recordWasSavedBeforeRepair = false

    init(pending: Bool = false, loadFailure: RelayIdentityKeyError? = nil, unsavable: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "Astation.relay-recovery-test.\(UUID().uuidString)"
        defaults = try XCTUnwrap(unsavable ? UnsavableRecoveryDefaults(suiteName: suite) : UserDefaults(suiteName: suite))
        self.loadFailure = loadFailure
        if pending {
            let record = RelayIdentityKeyRepairRecord(astationId: AstationIdentity.shared.id,
                relayURL: SettingsWindowController.currentAstationRelayUrl)
            XCTAssertTrue(record.save(to: defaults))
        }
        let keyManager = RelayIdentityKeyManager(loadKey: { [weak self] interactive in
            guard let self else { throw RelayIdentityKeyError.repairNotNeeded }
            self.reads.append(interactive)
            if let failure = self.loadFailure { throw failure }
            return self.key
        }, repairKey: { [weak self] in
            guard let self else { throw RelayIdentityKeyError.repairNotNeeded }
            self.repairs += 1
            self.recordWasSavedBeforeRepair = self.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey) != nil
            if let failure = self.repairFailure { throw failure }
            return self.key
        }, perform: { $0() }, deliver: { $0() }, schedule: { _, _ in })
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        _ = sessions.createTest(id: "existing-pairing", hostname: "test", lastActivity: Date())
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso.enc")),
            relayIdentityKeyManager: keyManager, relayIdentityRepairDefaults: defaults,
            makeIdentityRelayTask: { [weak self] _ in
                let socket = RecoverySocket()
                self?.sockets.append(socket)
                return socket
            })
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class RelayIdentityRecoveryLifecycleTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testARecoveredAppStaysPausedUntilTheUserRequestsReconnect() throws {
        let fixture = try RecoveryFixture(pending: true)
        fixture.hub.startIdentityRelay()
        for _ in 0..<10 { fixture.hub.startIdentityRelay() }
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertTrue(fixture.hub.relayIdentityKeyCanReconnectAfterRepair)
        XCTAssertTrue(fixture.sockets.isEmpty)
        XCTAssertEqual(fixture.reads, [false])
    }

    func testVerificationClearsTheRecoveryPauseAndResynchronizesExistingPairings() async throws {
        let fixture = try RecoveryFixture(pending: true)
        fixture.hub.startIdentityRelay()
        fixture.hub.reconnectAfterRelayIdentityKeyRepair()
        let socket = try XCTUnwrap(fixture.sockets.first)
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertFalse(fixture.hub.identityRelayVerified)
        socket.emit("{\"type\":\"relayAuthResult\",\"status\":\"registered\"}")
        await drainMainQueue()
        XCTAssertTrue(fixture.hub.identityRelayVerified)
        XCTAssertFalse(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertNil(fixture.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey))
        let frames = try socket.sent.map { text in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let sessions = try XCTUnwrap(frames.first { $0["type"] as? String == "relaySessions" })
        XCTAssertEqual(sessions["sessions"] as? [String], ["existing-pairing"])
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().map(\.id), ["existing-pairing"])
    }

    func testRejectionKeepsRecoveryPausedWithoutReconnectionLoops() async throws {
        let fixture = try RecoveryFixture(pending: true)
        fixture.hub.startIdentityRelay()
        fixture.hub.reconnectAfterRelayIdentityKeyRepair()
        let socket = try XCTUnwrap(fixture.sockets.first)
        socket.emit("{\"type\":\"relayAuthResult\",\"status\":\"rejected\"}")
        await drainMainQueue()
        fixture.hub.startIdentityRelay()
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertFalse(fixture.hub.identityRelayVerified)
        XCTAssertEqual(fixture.sockets.count, 1)
        XCTAssertNotNil(fixture.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey))
    }

    func testOldSocketCallbacksCannotVerifyAReplacementConnection() async throws {
        let fixture = try RecoveryFixture()
        fixture.hub.startIdentityRelay()
        let oldSocket = try XCTUnwrap(fixture.sockets.first)
        fixture.hub.retryRelayIdentityKey()
        XCTAssertEqual(fixture.sockets.count, 2)
        XCTAssertTrue(oldSocket.wasCancelled)
        oldSocket.emit("{\"type\":\"relayAuthResult\",\"status\":\"verified\"}")
        await drainMainQueue()
        XCTAssertFalse(fixture.hub.identityRelayVerified)
        XCTAssertTrue(fixture.sockets[1].sent.isEmpty)
    }

    func testPermanentFailureNeverOpensSocketsOrRetriesOnNetworkEvents() throws {
        let fixture = try RecoveryFixture(loadFailure: .undecodableStoredKey)
        fixture.hub.startIdentityRelay()
        for _ in 0..<10 { fixture.hub.startIdentityRelay() }
        XCTAssertTrue(fixture.sockets.isEmpty)
        XCTAssertEqual(fixture.reads, [false])
        XCTAssertTrue(fixture.hub.relayIdentityKeyCanRepair)
        fixture.loadFailure = nil
        fixture.hub.retryRelayIdentityKey()
        XCTAssertEqual(fixture.reads, [false, true])
        XCTAssertEqual(fixture.sockets.count, 1)
    }

    func testRejectedReadableKeyCanRecoverRelayTrustWithoutReplacingTheKey() async throws {
        let fixture = try RecoveryFixture()
        fixture.hub.startIdentityRelay()
        let socket = try XCTUnwrap(fixture.sockets.first)
        socket.emit("{\"type\":\"relayAuthResult\",\"status\":\"rejected\"}")
        await drainMainQueue()
        XCTAssertFalse(fixture.hub.relayIdentityKeyCanRepair)
        XCTAssertTrue(fixture.hub.relayIdentityKeyCanResetRelayTrust)
        XCTAssertNil(fixture.hub.prepareRelayIdentityTrustReset())
        XCTAssertEqual(fixture.repairs, 0)
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        fixture.hub.startIdentityRelay()
        XCTAssertEqual(fixture.sockets.count, 1)
        fixture.hub.reconnectAfterRelayIdentityKeyRepair()
        XCTAssertEqual(fixture.sockets.count, 2)
    }

    func testHealthyKeyCannotStartARepairOrRelayTrustReset() throws {
        let fixture = try RecoveryFixture()
        fixture.hub.startIdentityRelay()
        XCTAssertFalse(fixture.hub.relayIdentityKeyCanResetRelayTrust)
        XCTAssertEqual(fixture.hub.prepareRelayIdentityTrustReset(), .repairNotNeeded)
        fixture.hub.repairRelayIdentityKey { XCTAssertEqual($0, .repairNotNeeded) }
        XCTAssertEqual(fixture.repairs, 0)
        XCTAssertNil(fixture.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey))
    }

    func testRepairSavesItsPauseBeforeKeyMutationAndRetainsPairings() throws {
        let fixture = try RecoveryFixture(loadFailure: .undecodableStoredKey)
        fixture.hub.startIdentityRelay()
        var completed = false
        fixture.hub.repairRelayIdentityKey { failure in XCTAssertNil(failure); completed = true }
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.repairs, 1)
        XCTAssertTrue(fixture.recordWasSavedBeforeRepair)
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertTrue(fixture.sockets.isEmpty)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().map(\.id), ["existing-pairing"])
    }

    func testFailureToPersistThePausePreventsKeyMutation() throws {
        let fixture = try RecoveryFixture(loadFailure: .undecodableStoredKey, unsavable: true)
        fixture.hub.startIdentityRelay()
        var completed = false
        fixture.hub.repairRelayIdentityKey { failure in XCTAssertEqual(failure, .repairStateUnavailable); completed = true }
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.repairs, 0)
        XCTAssertTrue(fixture.sockets.isEmpty)
    }

    func testFailedAtomicRepairClearsOnlyItsPauseAndLeavesConnectionsStopped() throws {
        let fixture = try RecoveryFixture(loadFailure: .undecodableStoredKey)
        fixture.repairFailure = .keychain(errSecAuthFailed)
        fixture.hub.startIdentityRelay()
        fixture.hub.repairRelayIdentityKey { XCTAssertEqual($0, .keychain(errSecAuthFailed)) }
        XCTAssertFalse(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertNil(fixture.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey))
        XCTAssertTrue(fixture.sockets.isEmpty)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().map(\.id), ["existing-pairing"])
    }

    func testFailedSecondRepairPreservesAnExistingRecoveryPause() throws {
        let fixture = try RecoveryFixture(pending: true, loadFailure: .undecodableStoredKey)
        fixture.repairFailure = .keychain(errSecAuthFailed)
        fixture.hub.startIdentityRelay()
        fixture.hub.repairRelayIdentityKey { XCTAssertEqual($0, .keychain(errSecAuthFailed)) }
        XCTAssertTrue(fixture.hub.relayIdentityKeyRepairPending)
        XCTAssertNotNil(fixture.defaults.dictionary(forKey: RelayIdentityKeyRepairRecord.defaultsKey))
        fixture.loadFailure = nil
        fixture.hub.retryRelayIdentityKey()
        fixture.hub.startIdentityRelay()
        XCTAssertTrue(fixture.sockets.isEmpty)
        XCTAssertTrue(fixture.hub.relayIdentityKeyCanReconnectAfterRepair)
    }
}
