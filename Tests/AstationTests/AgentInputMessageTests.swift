import XCTest
@testable import Menubar

final class AgentInputMessageTests: XCTestCase {
    func testEncodeTextOmitsKeyAndNilAgentId() throws {
        let msg = AstationMessage.agentInput(agentId: nil, kind: "text",
                                             text: "refactor the auth module", key: nil)
        let data = try JSONEncoder().encode(msg)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""type":"agentInput""#))
        XCTAssertTrue(s.contains(#""kind":"text""#))
        XCTAssertTrue(s.contains(#""text":"refactor the auth module""#))
        XCTAssertFalse(s.contains(#""key""#))
        XCTAssertFalse(s.contains(#""agentId""#))
    }

    func testEncodeKeyOmitsText() throws {
        let msg = AstationMessage.agentInput(agentId: "agent-1", kind: "key", text: nil, key: "ctrl-c")
        let data = try JSONEncoder().encode(msg)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""kind":"key""#))
        XCTAssertTrue(s.contains(#""key":"ctrl-c""#))
        XCTAssertTrue(s.contains(#""agentId":"agent-1""#))
        XCTAssertFalse(s.contains(#""text""#))
    }

    func testDecodeText() throws {
        let json = """
        {"type":"agentInput","data":{"kind":"text","text":"print working directory"}}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .agentInput(agentId, kind, text, key) = msg else {
            return XCTFail("expected agentInput")
        }
        XCTAssertNil(agentId)
        XCTAssertEqual(kind, "text")
        XCTAssertEqual(text, "print working directory")
        XCTAssertNil(key)
    }

    func testDecodeKeyWithAgentId() throws {
        let json = """
        {"type":"agentInput","data":{"agentId":"a2","kind":"key","key":"enter"}}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .agentInput(agentId, kind, text, key) = msg else {
            return XCTFail("expected agentInput")
        }
        XCTAssertEqual(agentId, "a2")
        XCTAssertEqual(kind, "key")
        XCTAssertNil(text)
        XCTAssertEqual(key, "enter")
    }

    func testRoundTrip() throws {
        let original = AstationMessage.agentInput(agentId: nil, kind: "text", text: "hello", key: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AstationMessage.self, from: data)
        guard case let .agentInput(_, kind, text, _) = decoded else {
            return XCTFail("expected agentInput")
        }
        XCTAssertEqual(kind, "text")
        XCTAssertEqual(text, "hello")
    }
}
