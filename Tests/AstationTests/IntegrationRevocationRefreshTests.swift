import AstationRemote
import XCTest
@testable import Menubar

@MainActor
final class IntegrationRevocationRefreshTests: XCTestCase {
    private func record(_ state: String = "revoking", id: String = "i-01234567890123456789012345",
                        station: String = "https://configured.example", key: String = "a") throws -> PortalIntegrationRecord {
        let value: [String: Any] = ["id": id, "name": "Test integration", "state": state,
            "stationOrigin": station, "r9Svc": String(repeating: key, count: 64),
            "scopes": ["agent.view"], "expiresAt": "2026-11-04T22:57:08Z", "role": "owner"]
        return try JSONDecoder().decode(PortalIntegrationRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testRefreshesUntilStationConfirmsRevoked() async throws {
        let pending = try record(), revoked = try record("revoked")
        var requests = 0, updates: [String] = [], delays: [UInt64] = []
        let complete = try await IntegrationRevocationRefresh.run(record: pending, current: { true }, fetch: {
            requests += 1
            return [requests == 1 ? pending : revoked]
        }, update: { updates.append($0.state) }, wait: { delays.append($0) })
        XCTAssertTrue(complete)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(updates, ["revoking", "revoked"])
        XCTAssertEqual(delays.count, 1)
    }

    func testChangedSelectionDiscardsInFlightReply() async throws {
        var current = true, updates = 0
        let pending = try record(), revoked = try record("revoked")
        do {
            _ = try await IntegrationRevocationRefresh.run(record: pending, current: { current }, fetch: {
                current = false
                return [revoked]
            }, update: { _ in updates += 1 }, wait: { _ in })
            XCTFail("A stale account or selection must discard the reply")
        } catch is CancellationError {}
        XCTAssertEqual(updates, 0)
    }

    func testContextChangeDuringBackoffStopsRequests() async throws {
        var current = true, requests = 0
        let pending = try record()
        do {
            _ = try await IntegrationRevocationRefresh.run(record: pending, current: { current }, fetch: {
                requests += 1
                return [pending]
            }, update: { _ in }, wait: { _ in current = false })
            XCTFail("Leaving the view or account must stop the refresh")
        } catch is CancellationError {}
        XCTAssertEqual(requests, 1)
    }

    func testCancellationDiscardsInFlightReply() async throws {
        let pending = try record(), revoked = try record("revoked")
        var updates = 0
        let refresh = Task {
            try await IntegrationRevocationRefresh.run(record: pending, current: { true }, fetch: {
                withUnsafeCurrentTask { $0?.cancel() }
                return [revoked]
            }, update: { _ in updates += 1 }, wait: { _ in })
        }
        do {
            _ = try await refresh.value
            XCTFail("A cancelled settings task must discard the reply")
        } catch is CancellationError {}
        XCTAssertEqual(updates, 0)
    }

    func testTransientPortalFailureRetriesWithoutConsent() async throws {
        var requests = 0, updates = 0
        let pending = try record(), revoked = try record("revoked")
        let complete = try await IntegrationRevocationRefresh.run(record: pending, current: { true }, fetch: {
            requests += 1
            if requests == 1 { throw AccountLoginError.unavailable }
            return [revoked]
        }, update: { _ in updates += 1 }, wait: { _ in })
        XCTAssertTrue(complete)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(updates, 1)
    }

    func testSignInFailureStopsWithoutRetrying() async throws {
        var requests = 0, updates = 0
        do {
            _ = try await IntegrationRevocationRefresh.run(record: try record(), current: { true }, fetch: {
                requests += 1
                throw AccountLoginError.signInRequired
            }, update: { _ in updates += 1 }, wait: { _ in XCTFail("Do not retry authorization failures") })
            XCTFail("Authentication failure must stop the refresh")
        } catch AccountLoginError.signInRequired {}
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(updates, 0)
    }

    func testChangedRecordCannotReplaceRemovedService() async throws {
        let pending = try record()
        let responses = [try record("revoked", id: "i-11234567890123456789012345"),
            try record("revoked", station: "https://other.example"),
            try record("revoked", key: "b"), try record("ready")]
        for response in responses {
            var updates = 0
            do {
                _ = try await IntegrationRevocationRefresh.run(record: pending, current: { true },
                    fetch: { [response] }, update: { _ in updates += 1 }, wait: { _ in })
                XCTFail("Only the same revoked service may update the selected row")
            } catch AccountLoginError.changed {}
            XCTAssertEqual(updates, 0)
        }
    }

    func testPendingCleanupAndUnavailablePortalHaveBoundedPolling() async throws {
        let pending = try record()
        for unavailable in [false, true] {
            var requests = 0, updates = 0
            var delay: UInt64 = 0
            let complete = try await IntegrationRevocationRefresh.run(record: pending, current: { true }, fetch: {
                requests += 1
                if unavailable { throw AccountLoginError.unavailable }
                return [pending]
            }, update: { _ in updates += 1 }, wait: { delay += $0 })
            XCTAssertFalse(complete)
            XCTAssertLessThanOrEqual(requests, 10)
            XCTAssertLessThanOrEqual(delay, 120_000_000_000)
            XCTAssertEqual(updates, unavailable ? 0 : requests)
        }
    }
}
