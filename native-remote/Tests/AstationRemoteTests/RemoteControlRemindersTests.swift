import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
final class RemoteControlRemindersTests: XCTestCase {
    private let genesis = String(repeating: "a", count: 64)
    private let station = "https://station.example"
    private func row(id: String = UUID().uuidString.lowercased(), account: String = "account",
        replacement: String? = nil, signed: Bool = true, removed: Bool = true,
        applied: RemoteControlApplicationState? = nil, additional: [String: Bool] = [:],
        peerReports: [String: RemoteControlApplicationState] = [:]) -> RemoteControlActivity {
        RemoteControlActivity(body: ControlRecordBody(accountId: account, genesisHash: genesis, origin: nil,
            feedId: nil, principal: "host:private-host", principalKey: nil, signer: "member:private-manager",
            action: "interrupt_running", interruptRunning: nil, revokeSeq: 3, recordId: id,
            issuedAt: 100, integrationId: nil, by: "owner"), signed: signed, stationStored: true,
            portalPending: false, managerReviewRequired: removed, replacementRecordID: replacement,
            application: applied, additionalStations: additional, additionalApplications: peerReports)
    }

    func testRestartDeduplicatesAndDailyReminderDoesNotPersistStopContent() throws {
        var saved: Data?
        var book = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager",
            persist: { saved = $0 })
        let activity = [row()]
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: activity, now: 1_000))
        let bytes = try XCTUnwrap(saved)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("private-host")); XCTAssertFalse(text.contains("private-manager"))
        XCTAssertFalse(text.contains("interrupt_running"))
        book = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager",
            checkpoint: bytes, persist: { saved = $0 })
        XCTAssertFalse(try book.offer(stationOrigin: station, activity: activity, now: 1_001))
        XCTAssertFalse(try book.offer(stationOrigin: station, activity: activity, now: 999))
        XCTAssertFalse(try book.offer(stationOrigin: station, activity: activity, now: 86_400_999))
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: activity, now: 86_401_000))
    }

    func testNewStopAlertsButPartialRemovalDoesNotResetDailyReminder() throws {
        let book = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager", persist: { _ in })
        let first = row(), second = row()
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: [first], now: 100))
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: [first, second], now: 200))
        XCTAssertFalse(try book.offer(stationOrigin: station, activity: [second], now: 300))
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: [second], now: 86_400_200))
        XCTAssertFalse(try book.offer(stationOrigin: station, activity: [], now: 86_400_300))
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: [second], now: 86_400_400))
    }

    func testSignedReplacementKeepsReminderUntilEveryCoveredHostReportsApplication() throws {
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(RemoteControlReminders.reviewIDs([row(applied: .effectsReported)]).isEmpty)
        XCTAssertEqual(RemoteControlReminders.reviewIDs([row(id: id, applied: .effectsReported,
            additional: ["https://other.example": true])]), [id])
        let copy = row(signed: false, removed: false)
        let original = row(replacement: copy.body.recordId)
        XCTAssertEqual(RemoteControlReminders.reviewIDs([original, copy]), [original.body.recordId])
        for state: RemoteControlApplicationState? in [nil, .unknown, .awaitingApplication] {
            let pendingCopy = row(id: copy.body.recordId, removed: false, applied: state)
            XCTAssertEqual(RemoteControlReminders.reviewIDs([original, pendingCopy]), [original.body.recordId])
        }
        let appliedCopy = row(id: copy.body.recordId, removed: false, applied: .effectsReported)
        XCTAssertTrue(RemoteControlReminders.reviewIDs([original, appliedCopy]).isEmpty)
        let removedCopy = row(id: copy.body.recordId)
        XCTAssertEqual(RemoteControlReminders.reviewIDs([original, removedCopy]), [original.body.recordId, copy.body.recordId])
    }

    func testReplacementChainNeedsApplicationAtEveryApprovedDestination() {
        let peer = "https://peer.example", id = UUID().uuidString.lowercased()
        let second = row(replacement: id, additional: [peer: true])
        let original = row(replacement: second.body.recordId, additional: [peer: true])
        for state: RemoteControlApplicationState? in [nil, .unknown, .awaitingApplication, .effectsReported] {
            let final = row(id: id, removed: false, applied: .effectsReported, additional: [peer: true],
                peerReports: state.map { [peer: $0] } ?? [:])
            let pending = RemoteControlReminders.reviewIDs([final, original, second])
            XCTAssertEqual(pending, state == .effectsReported ? [] : [original.body.recordId, second.body.recordId])
        }
    }

    func testStationsAndAccountAnchorsCannotShareReminderEvidence() throws {
        var saved: Data?
        let book = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager", persist: { saved = $0 })
        let activity = [row()]
        XCTAssertTrue(try book.offer(stationOrigin: station, activity: activity, now: 1))
        XCTAssertTrue(try book.offer(stationOrigin: "https://other.example", activity: activity, now: 2))
        XCTAssertThrowsError(try book.offer(stationOrigin: station, activity: [row(account: "foreign")], now: 3))
        XCTAssertThrowsError(try book.offer(stationOrigin: station, activity: [activity[0], activity[0]], now: 3))
        XCTAssertThrowsError(try book.offer(stationOrigin: station, activity: [row(id: "not-a-uuid")], now: 3))
        XCTAssertThrowsError(try RemoteControlReminders(accountID: "foreign", genesisHash: genesis, deviceID: "manager", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemoteControlReminders(accountID: "account", genesisHash: String(repeating: "b", count: 64), deviceID: "manager", checkpoint: saved, persist: { _ in }))
        XCTAssertThrowsError(try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "other", checkpoint: saved, persist: { _ in }))
    }

    func testUncertainNotificationWriteFencesPresentationUntilProtectedReload() throws {
        var saved: Data?
        let book = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager", persist: {
            saved = $0; throw RemoteRecoveryError.storageUncertain
        })
        let activity = [row()]
        XCTAssertThrowsError(try book.offer(stationOrigin: station, activity: activity, now: 100))
        XCTAssertTrue(book.storageUncertain)
        XCTAssertThrowsError(try book.offer(stationOrigin: station, activity: activity, now: 101))
        let restored = try RemoteControlReminders(accountID: "account", genesisHash: genesis, deviceID: "manager", checkpoint: saved, persist: { _ in })
        XCTAssertFalse(try restored.offer(stationOrigin: station, activity: activity, now: 102))
    }
}
