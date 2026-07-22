import XCTest
@testable import Menubar

final class ConnectionsViewModelTests: XCTestCase {
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
