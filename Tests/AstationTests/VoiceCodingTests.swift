import XCTest
@testable import Menubar
import Foundation

/// Tests for voice coding message serialization and VoiceCodingManager state machine.
final class VoiceCodingTests: XCTestCase {

    // MARK: - AstationMessage voiceRequest encode/decode

    func testVoiceRequestEncode() throws {
        let msg = AstationMessage.voiceRequest(
            sessionId: "sess-abc",
            accumulatedText: "fix the login bug",
            relayUrl: "https://relay.example.com"
        )

        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "voiceRequest")

        let dataObj = json?["data"] as? [String: Any]
        XCTAssertEqual(dataObj?["session_id"] as? String, "sess-abc")
        XCTAssertEqual(dataObj?["accumulated_text"] as? String, "fix the login bug")
        XCTAssertEqual(dataObj?["relay_url"] as? String, "https://relay.example.com")
    }

    func testVoiceRequestRoundtrip() throws {
        let original = AstationMessage.voiceRequest(
            sessionId: "sess-123",
            accumulatedText: "create a function",
            relayUrl: "https://relay.test/api"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AstationMessage.self, from: data)

        if case .voiceRequest(let sessionId, let text, let url) = decoded {
            XCTAssertEqual(sessionId, "sess-123")
            XCTAssertEqual(text, "create a function")
            XCTAssertEqual(url, "https://relay.test/api")
        } else {
            XCTFail("Expected voiceRequest, got \(decoded)")
        }
    }

    func testVoiceRequestDecodeFromRustFormat() throws {
        // Verify the JSON format matches what Atem's Rust serde produces
        let json = """
        {"type":"voiceRequest","data":{"session_id":"s1","accumulated_text":"hello world","relay_url":"https://r.test"}}
        """
        let data = json.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: data)

        if case .voiceRequest(let sessionId, let text, let url) = msg {
            XCTAssertEqual(sessionId, "s1")
            XCTAssertEqual(text, "hello world")
            XCTAssertEqual(url, "https://r.test")
        } else {
            XCTFail("Expected voiceRequest")
        }
    }

    func testVoiceRequestEmptyText() throws {
        let msg = AstationMessage.voiceRequest(
            sessionId: "sess-empty",
            accumulatedText: "",
            relayUrl: "https://relay.test"
        )

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AstationMessage.self, from: data)

        if case .voiceRequest(_, let text, _) = decoded {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected voiceRequest")
        }
    }

    // MARK: - AstationMessage voiceResponse encode/decode

    func testVoiceResponseEncode() throws {
        let msg = AstationMessage.voiceResponse(
            sessionId: "sess-abc",
            success: true,
            message: "Response delivered to relay"
        )

        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "voiceResponse")

        let dataObj = json?["data"] as? [String: Any]
        XCTAssertEqual(dataObj?["session_id"] as? String, "sess-abc")
        XCTAssertEqual(dataObj?["success"] as? Bool, true)
        XCTAssertEqual(dataObj?["message"] as? String, "Response delivered to relay")
    }

    func testVoiceResponseRoundtrip() throws {
        let original = AstationMessage.voiceResponse(
            sessionId: "sess-456",
            success: false,
            message: "Claude timeout"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AstationMessage.self, from: data)

        if case .voiceResponse(let sessionId, let success, let message) = decoded {
            XCTAssertEqual(sessionId, "sess-456")
            XCTAssertFalse(success)
            XCTAssertEqual(message, "Claude timeout")
        } else {
            XCTFail("Expected voiceResponse, got \(decoded)")
        }
    }

    func testVoiceResponseDecodeFromRustFormat() throws {
        let json = """
        {"type":"voiceResponse","data":{"session_id":"s1","success":true,"message":"ok"}}
        """
        let data = json.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: data)

        if case .voiceResponse(let sessionId, let success, let message) = msg {
            XCTAssertEqual(sessionId, "s1")
            XCTAssertTrue(success)
            XCTAssertEqual(message, "ok")
        } else {
            XCTFail("Expected voiceResponse")
        }
    }

    // MARK: - VoiceCodingManager state machine

    func testInitialModeIsOff() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        XCTAssertEqual(vcm.mode, .off, "Initial mode should be .off")
        XCTAssertNil(vcm.activeSessionId)
        XCTAssertFalse(vcm.isWaitingForResponse)
    }

    func testStartPTTIgnoredWhenNotOff() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // Start PTT — mode transitions to .ptt
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .ptt)

        // Starting PTT again should be ignored (already in .ptt)
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .ptt)
    }

    func testStopPTTIgnoredWhenNotPTT() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // stopPTT when mode is .off should be a no-op
        vcm.stopPTT()
        XCTAssertEqual(vcm.mode, .off)
    }

    func testStartHandsFreeIgnoredWhenNotOff() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        vcm.startHandsFree()
        XCTAssertEqual(vcm.mode, .handsFree)

        // Starting again should be ignored
        vcm.startHandsFree()
        XCTAssertEqual(vcm.mode, .handsFree)
    }

    func testStopHandsFreeIgnoredWhenNotHandsFree() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // Stopping hands-free when not in hands-free mode should be a no-op
        vcm.stopHandsFree()
        XCTAssertEqual(vcm.mode, .off)
    }

    func testHandleVoiceResponseCleansUpPTT() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // Simulate PTT mode
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .ptt)

        // Handle a response — should clean up
        vcm.handleVoiceResponse(sessionId: "test-sess", success: true, message: "Done")
        XCTAssertEqual(vcm.mode, .off)
        XCTAssertFalse(vcm.isWaitingForResponse)
    }

    func testNotifySpeechActivityUpdatesTimestamp() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // Should not crash when called while mode is .off
        vcm.notifySpeechActivity()
    }

    // MARK: - VoiceCodingManager relay HTTP (with mock server)

    func testPTTCreatesRelaySession() throws {
        let exp = expectation(description: "create session POST received")

        let server = MockHTTPServer(onRequest: { method, path, _ in
            if path == "/api/voice-sessions" && method == "POST" {
                exp.fulfill()
                return (201, """
                {"session_id":"mock-sess-1","atem_id":"","channel":"","created_at":"2024-01-01T00:00:00Z"}
                """)
            }
            return (404, "{}")
        })
        let port = try server.start()

        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:\(port)")
        let vcm = hub.voiceCodingManager

        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .ptt)

        waitForExpectations(timeout: 3)
        server.stop()
    }

    func testPTTStopTriggersRelay() throws {
        let createExp = expectation(description: "create session")
        let triggerExp = expectation(description: "trigger session")

        let server = MockHTTPServer(onRequest: { method, path, _ in
            if path == "/api/voice-sessions" && method == "POST" {
                createExp.fulfill()
                return (201, """
                {"session_id":"mock-sess-2","atem_id":"","channel":"","created_at":"2024-01-01T00:00:00Z"}
                """)
            }
            if path.contains("/trigger") && method == "POST" {
                triggerExp.fulfill()
                return (200, """
                {"session_id":"mock-sess-2","accumulated_text":"hello world","atem_id":""}
                """)
            }
            // Handle DELETE for cleanup
            if method == "DELETE" {
                return (200, "{}")
            }
            return (404, "{}")
        })
        let port = try server.start()

        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:\(port)")
        let vcm = hub.voiceCodingManager

        vcm.startPTT()

        // Wait for session creation, then stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            vcm.stopPTT()
        }

        waitForExpectations(timeout: 5)
        server.stop()
    }

    // MARK: - Wire format cross-platform compatibility

    func testVoiceRequestWireFormatSnakeCaseKeys() throws {
        let msg = AstationMessage.voiceRequest(
            sessionId: "test",
            accumulatedText: "hello",
            relayUrl: "https://relay.test"
        )

        let data = try JSONEncoder().encode(msg)
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify snake_case keys (must match Rust serde)
        XCTAssertTrue(jsonString.contains("\"session_id\""))
        XCTAssertTrue(jsonString.contains("\"accumulated_text\""))
        XCTAssertTrue(jsonString.contains("\"relay_url\""))

        // Must NOT contain camelCase variants
        XCTAssertFalse(jsonString.contains("\"sessionId\""))
        XCTAssertFalse(jsonString.contains("\"accumulatedText\""))
        XCTAssertFalse(jsonString.contains("\"relayUrl\""))
    }

    func testVoiceResponseWireFormatSnakeCaseKeys() throws {
        let msg = AstationMessage.voiceResponse(
            sessionId: "test",
            success: true,
            message: "ok"
        )

        let data = try JSONEncoder().encode(msg)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"session_id\""))
        XCTAssertFalse(jsonString.contains("\"sessionId\""))
    }
}
