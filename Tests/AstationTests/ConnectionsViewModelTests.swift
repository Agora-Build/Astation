import XCTest
@testable import Menubar

final class ConnectionsViewModelTests: XCTestCase {
    func testProcessIndicatorDoesNotDependOnAgentActivity() throws {
        for state in ["running", "exited", "interrupted", "recovery_required", "closed", "removed"] {
            for (activity, label) in [("ready", "Idle"), ("working", "Working"), ("waiting", "Waiting"), ("unknown", "Unknown")] {
                let descriptor: [String: Any] = [
                    "session_id": "ses-aaaaaaaaaaaa", "process_gen": "22222222-2222-4222-8222-222222222222",
                    "provider": "codex", "cwd_label": "Atem", "state": state,
                    "activity": activity, "activity_since": 1, "controller": NSNull(),
                    "capabilities": ["terminal-v1"], "created_at": 1
                ]
                let session = try JSONDecoder().decode(AtemSessionDescriptor.self, from: JSONSerialization.data(withJSONObject: descriptor))
                let agent = AtemAgentInfo(session: session)
                XCTAssertEqual(agent.processStatus, state == "running" ? .running : .stopped, "\(state)/\(activity)")
                XCTAssertEqual(agent.activityLabel, state == "running" ? label : "Stopped")
                let restored = try JSONDecoder().decode(AtemAgentInfo.self, from: JSONEncoder().encode(agent))
                XCTAssertEqual(restored.processState, state)
                XCTAssertEqual(restored.processStatus, agent.processStatus)
                XCTAssertEqual(restored.activityLabel, agent.activityLabel)
            }
        }
    }

    func testLegacyActivityWithoutProcessStateDoesNotClaimRunning() throws {
        for status in ["Idle", "Thinking", "WaitingForInput", "Unknown", "Disconnected"] {
            let object = ["id": "agent", "name": "Codex", "kind": "Codex", "status": status]
            let agent = try JSONDecoder().decode(AtemAgentInfo.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(agent.processState)
            XCTAssertEqual(agent.processStatus, status == "Disconnected" ? .stopped : .unknown)
            XCTAssertEqual(agent.status, status, "Preserve the existing registry serialization")
        }
    }

    func testOnlineClientsCollapseSameDeviceAndPreferDirectConnection() {
        let connectedAt = Date()
        let relay = ConnectedClient(
            id: "relay-atem-office",
            clientType: "Atem",
            connectedAt: connectedAt.addingTimeInterval(10),
            hostname: "office-mac",
            atemId: "atem-office"
        )
        let direct = ConnectedClient(
            id: "direct-socket",
            clientType: "Atem",
            connectedAt: connectedAt,
            hostname: "office-mac",
            atemId: "atem-office"
        )

        let result = AtemClientListModel.onlineClients([relay, direct])

        XCTAssertEqual(result.map(\.id), ["direct-socket"])
    }

    func testOnlineClientsPreferPinnedConnectionForSameDevice() {
        let direct = ConnectedClient(
            id: "direct-socket",
            clientType: "Atem",
            connectedAt: Date(),
            atemId: "atem-office"
        )
        let relay = ConnectedClient(
            id: "relay-atem-office",
            clientType: "Atem",
            connectedAt: Date(),
            atemId: "atem-office"
        )

        let result = AtemClientListModel.onlineClients(
            [direct, relay],
            preferredClientId: relay.id
        )

        XCTAssertEqual(result.map(\.id), ["relay-atem-office"])
    }

    func testOnlineClientsKeepLegacyConnectionsDistinct() {
        let first = ConnectedClient(
            id: "legacy-1",
            clientType: "Atem",
            connectedAt: Date(),
            hostname: "shared-hostname"
        )
        let second = ConnectedClient(
            id: "legacy-2",
            clientType: "Atem",
            connectedAt: Date(),
            hostname: "shared-hostname"
        )

        let result = AtemClientListModel.onlineClients([second, first])

        XCTAssertEqual(result.map(\.id), ["legacy-1", "legacy-2"])
    }

    func testOfflineSessionsExcludeConnectedDevice() {
        let onlineSession = makeSession(id: "session-online", atemId: "atem-online")
        let offlineSession = makeSession(id: "session-offline", atemId: "atem-offline")
        let clients = [
            ConnectedClient(
                id: "socket-1",
                clientType: "Atem",
                connectedAt: Date(),
                hostname: "online-mac",
                atemId: "atem-online"
            )
        ]

        let result = AtemClientListModel.offlineSessions(
            activeSessions: [onlineSession, offlineSession],
            connectedClients: clients
        )

        XCTAssertEqual(result.map(\.id), ["session-offline"])
    }

    func testOfflineSessionsUseMostRecentlyActiveSessionPerDevice() {
        let older = makeSession(
            id: "older",
            atemId: "atem-office",
            lastActivity: Date().addingTimeInterval(-120)
        )
        let newer = makeSession(
            id: "newer",
            atemId: "atem-office",
            lastActivity: Date().addingTimeInterval(-30)
        )

        let result = AtemClientListModel.offlineSessions(
            activeSessions: [older, newer],
            connectedClients: []
        )

        XCTAssertEqual(result.map(\.id), ["newer"])
    }

    func testOfflineSessionsUseStableTieBreakForEqualActivity() {
        let activity = Date().addingTimeInterval(-60)
        let first = makeSession(
            id: "a-session",
            atemId: "atem-office",
            lastActivity: activity
        )
        let second = makeSession(
            id: "b-session",
            atemId: "atem-office",
            lastActivity: first.lastActivity
        )

        let forward = AtemClientListModel.offlineSessions(
            activeSessions: [first, second],
            connectedClients: []
        )
        let reversed = AtemClientListModel.offlineSessions(
            activeSessions: [second, first],
            connectedClients: []
        )

        XCTAssertEqual(forward.map(\.id), ["a-session"])
        XCTAssertEqual(reversed.map(\.id), ["a-session"])
    }

    func testOfflineSessionsExcludeLegacySessionWithoutStableAtemId() {
        let legacy = makeSession(id: "legacy", atemId: nil)

        let result = AtemClientListModel.offlineSessions(
            activeSessions: [legacy],
            connectedClients: [
                ConnectedClient(
                    id: "legacy-socket",
                    clientType: "Atem",
                    connectedAt: Date(),
                    hostname: legacy.hostname
                )
            ]
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testOfflineSessionsExcludeExpiredPairings() {
        let expired = makeSession(
            id: "expired",
            atemId: "atem-old",
            lastActivity: Date().addingTimeInterval(-(8 * 24 * 60 * 60)),
            createdAt: Date()
        )

        let result = AtemClientListModel.offlineSessions(
            activeSessions: [expired],
            connectedClients: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    private func makeSession(
        id: String,
        atemId: String?,
        lastActivity: Date = Date(),
        createdAt: Date? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: id,
            hostname: "office-mac",
            atemId: atemId,
            lastActivity: lastActivity,
            token: "secret",
            createdAt: createdAt ?? lastActivity
        )
    }
}
