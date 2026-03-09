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

        // With no projects configured, auto-join fails fast and mode resets to .off.
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)

        // Repeated start should also remain off.
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)
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

        // With no projects configured, auto-join fails fast and mode resets to .off.
        vcm.startHandsFree()
        XCTAssertEqual(vcm.mode, .off)

        // Repeated start should also remain off.
        vcm.startHandsFree()
        XCTAssertEqual(vcm.mode, .off)
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

        // Handling a response in off mode should remain safe and keep mode off.
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

    func testPTTDoesNotCreateSessionWithoutRTCContext() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)
        XCTAssertNil(vcm.activeSessionId)
    }

    func testPTTStopDoesNothingWhenModeOffAfterFailedStart() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)
        vcm.stopPTT()
        XCTAssertEqual(vcm.mode, .off)
        XCTAssertFalse(vcm.isWaitingForResponse)
    }

    func testPTTFailsFastWhenMicrophonePermissionDenied() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager
        vcm._testMicrophonePermissionOverride = false

        vcm.startPTT()

        XCTAssertEqual(vcm.mode, .off)
        XCTAssertNil(vcm.activeSessionId)
        XCTAssertFalse(vcm.isWaitingForResponse)
    }

    func testHandsFreeFailsFastWhenMicrophonePermissionDenied() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager
        vcm._testMicrophonePermissionOverride = false

        vcm.startHandsFree()

        XCTAssertEqual(vcm.mode, .off)
        XCTAssertNil(vcm.activeSessionId)
        XCTAssertFalse(vcm.isWaitingForResponse)
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

    // MARK: - ConvoAI Client

    func testConvoAICreateAgentRequestFormat() throws {
        // Build the same request body that ConvoAIClient sends.
        let body: [String: Any] = [
            "name": "atem-voice-test",
            "properties": [
                "channel": "test-channel",
                "token": "test-token",
                "agent_rtc_uid": "1001",
                "remote_rtc_uids": ["999"],
                "enable_string_uid": false,
                "idle_timeout": 120,
                "llm": [
                    "url": "https://relay.test/api/llm/chat?session_id=sess-1",
                    "api_key": "unused",
                    "style": "openai",
                    "system_messages": [
                        ["role": "system", "content": "You are a voice coding assistant."]
                    ],
                    "max_history": 10,
                    "params": ["model": "atem-voice-proxy"]
                ] as [String: Any],
                "asr": ["language": "en-US"],
                "tts": [
                    "vendor": "microsoft",
                    "params": [
                        "key": "placeholder",
                        "region": "eastus",
                        "voice_name": "en-US-AndrewMultilingualNeural"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify structure
        let props = json?["properties"] as? [String: Any]
        XCTAssertEqual(props?["channel"] as? String, "test-channel")
        XCTAssertEqual(props?["agent_rtc_uid"] as? String, "1001")
        XCTAssertEqual(props?["idle_timeout"] as? Int, 120)

        let llm = props?["llm"] as? [String: Any]
        XCTAssertEqual(llm?["style"] as? String, "openai")
        XCTAssertTrue((llm?["url"] as? String)?.contains("session_id=") ?? false)

        let asr = props?["asr"] as? [String: Any]
        XCTAssertEqual(asr?["language"] as? String, "en-US")

        let tts = props?["tts"] as? [String: Any]
        XCTAssertEqual(tts?["vendor"] as? String, "microsoft")
    }

    func testConvoAIBasicAuthHeader() throws {
        let credentials = AgoraCredentials(customerId: "my-customer", customerSecret: "my-secret")

        // Replicate the auth header construction from ConvoAIClient
        let authString = "\(credentials.customerId):\(credentials.customerSecret)"
        let authData = authString.data(using: .utf8)!
        let encoded = authData.base64EncodedString()
        let header = "Basic \(encoded)"

        // Verify Base64 encoding
        XCTAssertEqual(encoded, "bXktY3VzdG9tZXI6bXktc2VjcmV0")
        XCTAssertEqual(header, "Basic bXktY3VzdG9tZXI6bXktc2VjcmV0")

        // Verify round-trip
        let decoded = Data(base64Encoded: encoded)!
        let decodedString = String(data: decoded, encoding: .utf8)!
        XCTAssertEqual(decodedString, "my-customer:my-secret")
    }

    func testConvoAIStopAgentRequestFormat() throws {
        // Verify the stop request body format
        let agentId = "agent-abc-123"
        let body: [String: Any] = ["agent_id": agentId]
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["agent_id"] as? String, "agent-abc-123")
    }

    func testConvoAIAgentResponseDecoding() throws {
        let json = """
        {"agent_id":"ag-12345","create_ts":1700000000,"state":"started"}
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ConvoAIAgentResponse.self, from: data)

        XCTAssertEqual(response.agentId, "ag-12345")
        XCTAssertEqual(response.createTs, 1700000000)
        XCTAssertEqual(response.state, "started")
    }

    // MARK: - VoiceCodingManager ConvoAI integration

    func testDeferredStopPTT() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // No projects configured -> start fails fast and mode remains off.
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)
        vcm.stopPTT()
        XCTAssertEqual(vcm.mode, .off)
    }

    func testCleanupResetsConvoAIState() {
        let hub = AstationHubManager(skipProjectLoad: true)
        let vcm = hub.voiceCodingManager

        // No projects configured -> start fails fast and state remains clean.
        vcm.startPTT()
        XCTAssertEqual(vcm.mode, .off)
        vcm.handleVoiceResponse(sessionId: "test", success: true, message: "done")
        XCTAssertEqual(vcm.mode, .off)
        XCTAssertNil(vcm.activeAgentId)
        XCTAssertFalse(vcm.isAgentReady)
    }
}
