import XCTest
@testable import Menubar

/// Tests for HubManager.sendAgentText / sendAgentKey routing + the agentInput
/// payload they emit. Uses a stubbed sendHandler to capture messages.
final class AgentInputRoutingTests: XCTestCase {
    private func makeHub(withClient: Bool) -> (AstationHubManager, [(AstationMessage, String)]) {
        let hub = AstationHubManager(skipProjectLoad: true)
        if withClient {
            hub.connectedClients = [
                ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date())
            ]
        }
        return (hub, [])
    }

    func testSendAgentTextRoutesToConnectedAtem() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date())]

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("print working directory")

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].1, "atem-1")
        guard case let .agentInput(agentId, kind, text, key) = captured[0].0 else {
            return XCTFail("expected agentInput")
        }
        XCTAssertNil(agentId)
        XCTAssertEqual(kind, "text")
        XCTAssertEqual(text, "print working directory")
        XCTAssertNil(key)
    }

    func testSendAgentKeyRoutesToConnectedAtem() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date())]

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentKey("ctrl-c")

        XCTAssertEqual(captured.count, 1)
        guard case let .agentInput(_, kind, text, key) = captured[0].0 else {
            return XCTFail("expected agentInput")
        }
        XCTAssertEqual(kind, "key")
        XCTAssertNil(text)
        XCTAssertEqual(key, "ctrl-c")
    }

    func testSendAgentTextWithExplicitAgentId() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date())]

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("hi", agentId: "agent-9")

        guard case let .agentInput(agentId, _, _, _) = captured[0].0 else {
            return XCTFail("expected agentInput")
        }
        XCTAssertEqual(agentId, "agent-9")
    }

    func testSendAgentTextDroppedWhenNoAtem() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = []  // no Atems

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("nobody home")
        hub.sendAgentKey("enter")

        XCTAssertTrue(captured.isEmpty, "messages should be dropped when no Atem is connected")
    }

    func testRoutingPrefersPinnedClient() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [
            ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date()),
            ConnectedClient(id: "atem-2", clientType: "Atem", connectedAt: Date()),
        ]
        hub.pinnedClientId = "atem-2"

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("route me")
        XCTAssertEqual(captured.first?.1, "atem-2", "pinned client should win")
    }

    func testRemoteControlRoutesToExplicitClientAndAgent() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [
            ConnectedClient(id: "atem-1", clientType: "Atem", connectedAt: Date()),
            ConnectedClient(id: "atem-2", clientType: "Atem", connectedAt: Date()),
        ]
        hub.pinnedClientId = "atem-1"

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("inspect logs", agentId: "agent-9", clientId: "atem-2")
        hub.sendAgentKey("ctrl-c", agentId: "agent-9", clientId: "atem-2")

        XCTAssertEqual(captured.map(\.1), ["atem-2", "atem-2"])
        guard case let .agentInput(textAgentId, textKind, text, _) = captured[0].0,
              case let .agentInput(keyAgentId, keyKind, _, key) = captured[1].0 else {
            return XCTFail("expected agentInput messages")
        }
        XCTAssertEqual(textAgentId, "agent-9")
        XCTAssertEqual(textKind, "text")
        XCTAssertEqual(text, "inspect logs")
        XCTAssertEqual(keyAgentId, "agent-9")
        XCTAssertEqual(keyKind, "key")
        XCTAssertEqual(key, "ctrl-c")
    }

    func testRemoteControlDropsInputForOfflineExplicitClient() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.connectedClients = [
            ConnectedClient(id: "atem-online", clientType: "Atem", connectedAt: Date())
        ]

        var captured: [(AstationMessage, String)] = []
        hub.sendHandler = { msg, clientId in captured.append((msg, clientId)) }

        hub.sendAgentText("do not send", agentId: "agent-9", clientId: "atem-offline")
        hub.sendAgentKey("enter", agentId: "agent-9", clientId: "atem-offline")

        XCTAssertTrue(captured.isEmpty)
    }
}
