import CryptoKit
import Foundation
import Security
import XCTest
@testable import Menubar

private final class KeyWorkQueue {
    var work: [() -> Void] = []
    var timers: [(TimeInterval, () -> Void)] = []
    func runWork() { work.removeFirst()() }
    func runTimer() { timers.removeFirst().1() }
}

final class RelayIdentityKeyManagerTests: XCTestCase {
    private func manager(
        queue: KeyWorkQueue,
        load: @escaping (Bool) throws -> RelayIdentityKey,
        repair: @escaping () throws -> RelayIdentityKey = { throw RelayIdentityKeyError.repairNotNeeded }
    ) -> RelayIdentityKeyManager {
        RelayIdentityKeyManager(loadKey: load, repairKey: repair,
                                perform: { queue.work.append($0) }, deliver: { $0() },
                                schedule: { queue.timers.append(($0, $1)) })
    }

    func testReconnectRequestsDoNotRetryAPermanentlyBrokenKey() {
        let queue = KeyWorkQueue()
        var reads = 0
        let subject = manager(queue: queue) { _ in reads += 1; throw RelayIdentityKeyError.undecodableStoredKey }
        subject.loadIfNeeded()
        queue.runWork()
        for _ in 0..<100 { subject.loadIfNeeded() }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(queue.work.isEmpty)
        XCTAssertTrue(queue.timers.isEmpty)
        XCTAssertTrue(subject.canRepair)
        guard case .failed(.undecodableStoredKey) = subject.state else { return XCTFail("Lost the original error") }
    }

    func testTemporaryFailuresHaveBoundedNoninteractiveBackoff() {
        let queue = KeyWorkQueue()
        var interactive: [Bool] = []
        let subject = manager(queue: queue) { allowed in
            interactive.append(allowed)
            throw RelayIdentityKeyError.keychain(errSecInteractionNotAllowed)
        }
        subject.loadIfNeeded()
        queue.runWork()
        for delay in [30.0, 60, 120, 240, 300, 300] {
            XCTAssertEqual(queue.timers.first?.0, delay)
            subject.loadIfNeeded()
            XCTAssertTrue(queue.work.isEmpty)
            queue.runTimer()
            queue.runWork()
        }
        XCTAssertEqual(interactive, Array(repeating: false, count: 7))
        XCTAssertFalse(subject.canRepair)
    }

    func testDeniedAccessWaitsForExplicitInteractiveRetry() throws {
        let queue = KeyWorkQueue()
        var reads: [Bool] = []
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let subject = manager(queue: queue) { interactive in
            reads.append(interactive)
            if !interactive { throw RelayIdentityKeyError.keychain(errSecAuthFailed) }
            return key
        }
        subject.loadIfNeeded()
        queue.runWork()
        subject.loadIfNeeded()
        XCTAssertTrue(queue.timers.isEmpty)
        XCTAssertTrue(queue.work.isEmpty)
        subject.retry()
        queue.runWork()
        guard case .loaded(let loaded) = subject.state else { return XCTFail("Retry did not load the original key") }
        XCTAssertEqual(loaded.publicKeyHex, key.publicKeyHex)
        XCTAssertEqual(reads, [false, true])
    }

    func testOldRetryTimerCannotReplaceARecoveredKey() {
        let queue = KeyWorkQueue()
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        var reads = 0
        let subject = manager(queue: queue) { _ in
            reads += 1
            if reads == 1 { throw RelayIdentityKeyError.keychain(errSecNotAvailable) }
            return key
        }
        subject.loadIfNeeded()
        queue.runWork()
        subject.retry()
        queue.runWork()
        queue.runTimer()
        XCTAssertTrue(queue.work.isEmpty)
        XCTAssertEqual(reads, 2)
        guard case .loaded(let loaded) = subject.state else { return XCTFail("Stale timer changed the state") }
        XCTAssertEqual(loaded.publicKeyHex, key.publicKeyHex)
    }

    func testSuccessResetsKeyRetryDelay() {
        let queue = KeyWorkQueue()
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        var fail = true
        let subject = manager(queue: queue) { _ in
            if fail { throw RelayIdentityKeyError.keychain(errSecNotAvailable) }
            return key
        }
        subject.loadIfNeeded(); queue.runWork()
        queue.runTimer(); queue.runWork()
        XCTAssertEqual(queue.timers.first?.0, 60)
        fail = false
        subject.retry(); queue.runWork()
        queue.runTimer()
        subject.signingFailed(RelayIdentityKeyError.keychain(errSecNotAvailable))
        XCTAssertEqual(queue.timers.first?.0, 30)
    }

    func testSigningFailureInvalidatesAnOlderLoadCompletion() {
        let queue = KeyWorkQueue()
        let subject = manager(queue: queue) { _ in RelayIdentityKey(softwareKey: P256.Signing.PrivateKey()) }
        subject.loadIfNeeded()
        subject.signingFailed(RelayIdentityKeyError.keychain(errSecUserCanceled))
        queue.runWork()
        guard case .failed(.keychain(errSecUserCanceled)) = subject.state else {
            return XCTFail("An old completion cleared the signing failure")
        }
        XCTAssertTrue(queue.timers.isEmpty)
    }

    func testParallelRequestsDoNotStartDuplicateKeyWork() {
        let queue = KeyWorkQueue()
        let subject = manager(queue: queue) { _ in RelayIdentityKey(softwareKey: P256.Signing.PrivateKey()) }
        subject.loadIfNeeded()
        subject.retry()
        subject.loadIfNeeded()
        XCTAssertEqual(queue.work.count, 1)
        XCTAssertTrue(subject.isBusy)
    }

    func testRepairIsAvailableOnlyForUnusablePersistedKeys() {
        let queue = KeyWorkQueue()
        var repairs = 0
        let subject = manager(queue: queue, load: { _ in throw RelayIdentityKeyError.undecodableStoredKey },
                              repair: { repairs += 1; return RelayIdentityKey(softwareKey: P256.Signing.PrivateKey()) })
        var completionCalled = false
        subject.repair { failure in XCTAssertEqual(failure, .repairNotNeeded); completionCalled = true }
        XCTAssertTrue(completionCalled)
        subject.loadIfNeeded(); queue.runWork()
        XCTAssertTrue(subject.canRepair)
        subject.repair { failure in XCTAssertNil(failure) }
        subject.repair { failure in XCTAssertEqual(failure, .repairNotNeeded) }
        queue.runWork()
        XCTAssertEqual(repairs, 1)
        XCTAssertFalse(subject.canRepair)
        guard case .loaded = subject.state else { return XCTFail("Repaired key was not cached") }
    }

    func testProductionWorkerLoadsOffMainAndPublishesOnMain() {
        let loaded = expectation(description: "key loaded")
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let subject = RelayIdentityKeyManager(loadKey: { interactive in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(interactive)
            return key
        })
        subject.onChange = { state in
            XCTAssertTrue(Thread.isMainThread)
            if case .loaded = state { loaded.fulfill() }
        }
        subject.loadIfNeeded()
        wait(for: [loaded], timeout: 3)
    }

    func testErrorClassificationKeepsTemporaryAndPermanentFailuresDistinct() {
        XCTAssertTrue(RelayIdentityKeyError.keychain(errSecInteractionNotAllowed).retriesAutomatically)
        XCTAssertTrue(RelayIdentityKeyError.keychain(errSecNotAvailable).retriesAutomatically)
        for failure in [RelayIdentityKeyError.keychain(errSecAuthFailed), .keychain(errSecUserCanceled),
                        .keychain(errSecMissingEntitlement), .undecodableStoredKey, .secureEnclaveUnavailable] {
            XCTAssertFalse(failure.retriesAutomatically)
            XCTAssertFalse(failure.localizedDescription.contains("relay works"))
        }
        XCTAssertEqual(RelayIdentityKeyError.capture(CryptoKitError.underlyingCoreCryptoError(error: errSecInteractionNotAllowed)),
                       .keychain(errSecInteractionNotAllowed))
        XCTAssertEqual(RelayIdentityKeyError.capture(NSError(domain: "test", code: 17)), .unexpected(domain: "test", code: 17))
    }
}

final class RelayIdentityKeyRepairActionTests: XCTestCase {
    func testDeniedAuthenticationNeverConfirmsOrRepairs() {
        var events: [String] = []
        RelayIdentityKeyRepairAction.request(authenticate: { events.append("authenticate"); $0(false) },
            canRepair: { true }, confirm: { XCTFail("Unexpected confirmation"); return true },
            repair: { XCTFail("Unexpected repair") }, cancelled: { XCTAssertEqual($0, .notAuthenticated) })
        XCTAssertEqual(events, ["authenticate"])
    }

    func testCancelledConfirmationNeverRepairs() {
        RelayIdentityKeyRepairAction.request(authenticate: { $0(true) }, canRepair: { true },
            confirm: { false }, repair: { XCTFail("Unexpected repair") },
            cancelled: { XCTAssertEqual($0, .notConfirmed) })
    }

    func testRepairRequiresAuthenticationBeforeConfirmation() {
        var events: [String] = []
        RelayIdentityKeyRepairAction.request(authenticate: { events.append("authenticate"); $0(true) },
            canRepair: { true }, confirm: { events.append("confirm"); return true },
            repair: { events.append("repair") }, cancelled: { _ in XCTFail("Unexpected cancellation") })
        XCTAssertEqual(events, ["authenticate", "confirm", "repair"])
    }

    func testEligibilityChangesDuringAuthenticationOrConfirmationPreventRepair() {
        for changeDuringAuthentication in [true, false] {
            var eligible = true
            RelayIdentityKeyRepairAction.request(authenticate: {
                if changeDuringAuthentication { eligible = false }
                $0(true)
            }, canRepair: { eligible }, confirm: { eligible = false; return true },
                repair: { XCTFail("Unexpected repair") }, cancelled: { XCTAssertEqual($0, .unavailable) })
        }
    }

    func testRepeatedAuthenticationCallbackCannotRepairTwice() {
        var repairs = 0
        RelayIdentityKeyRepairAction.request(authenticate: { $0(true); $0(true) }, canRepair: { true },
            confirm: { true }, repair: { repairs += 1 }, cancelled: { _ in XCTFail("Unexpected cancellation") })
        XCTAssertEqual(repairs, 1)
    }
}

final class RelayIdentityKeyRepairRecordTests: XCTestCase {
    private let astationId = "astation-1F2E3D4C-0000-4000-8000-000000000001"

    func testRecoveryPauseSurvivesAStoreReloadAndMatchesOnlyItsIdentityAndRelay() throws {
        let suite = "Astation.relay-key-repair-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = RelayIdentityKeyRepairRecord(astationId: astationId, relayURL: "https://station.agora.build/")
        XCTAssertTrue(record.save(to: defaults))
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(RelayIdentityKeyRepairRecord.load(astationId: astationId, relayURL: "https://station.agora.build", defaults: reloaded), record)
        XCTAssertNil(RelayIdentityKeyRepairRecord.load(astationId: "another-id", relayURL: record.relayURL, defaults: reloaded))
        XCTAssertNil(RelayIdentityKeyRepairRecord.load(astationId: astationId, relayURL: "http://127.0.0.1:3000", defaults: reloaded))
        XCTAssertTrue(record.clear(from: reloaded))
        XCTAssertNil(RelayIdentityKeyRepairRecord.load(astationId: astationId, relayURL: record.relayURL, defaults: defaults))
    }

    func testAnOlderOperationCannotClearANewerRecoveryPause() throws {
        let suite = "Astation.relay-key-repair-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = RelayIdentityKeyRepairRecord(astationId: astationId, relayURL: "https://station.agora.build")
        let new = RelayIdentityKeyRepairRecord(astationId: astationId, relayURL: old.relayURL)
        XCTAssertTrue(old.save(to: defaults))
        XCTAssertTrue(new.save(to: defaults))
        XCTAssertFalse(old.clear(from: defaults))
        XCTAssertEqual(RelayIdentityKeyRepairRecord.load(astationId: astationId, relayURL: old.relayURL, defaults: defaults), new)
    }

    func testDisplayedResetCommandQuotesTheIdentity() {
        let record = RelayIdentityKeyRepairRecord(astationId: "id'; printf unsafe", relayURL: "https://station.agora.build")
        XCTAssertEqual(record.resetCommand, "station-relay-server admin forget-key 'id'\\''; printf unsafe'")
    }

    func testKeychainRepairUsesAnIsolatedItemAndKeepsTheSameKeyOnReload() throws {
        let service = "build.agora.astation.test-relay-key.\(UUID().uuidString)"
        let storage = KeychainRelayIdentityKeyStorage(service: service, account: "test")
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: "test"] as CFDictionary)
        }
        let status = storage.write(Data([0x00]))
        guard status == errSecSuccess else { throw XCTSkip("Test Keychain is unavailable (\(status))") }
        let repaired = try RelayIdentityKey.repair(storage: storage, preferSecureEnclave: false)
        let reloaded = try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false)
        XCTAssertEqual(repaired.publicKeyHex, reloaded.publicKeyHex)
        XCTAssertEqual(storage.write(Data([0x01])), errSecDuplicateItem)
        XCTAssertEqual(try RelayIdentityKey.loadOrCreate(storage: storage, preferSecureEnclave: false).publicKeyHex, repaired.publicKeyHex)
    }
}
