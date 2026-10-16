import Foundation
import XCTest
@testable import Menubar

final class ApprovalPushTests: XCTestCase {
    private let id = "11111111-1111-4111-8111-111111111111"

    private func hint(_ kind: String, host: String = "genie") throws -> ApprovalPushHint {
        try XCTUnwrap(ApprovalPushHint(userInfo: ["kind": kind, "approval_id": id,
            "atem_device_id": host, "session_id": "claude-session"]))
    }

    func testRegistrationUsesTheSignedBuildEnvironmentAndSendsNoAccountOrDeviceClaim() throws {
        XCTAssertNil(ApprovalPushPlatform(entitlement: "unknown"))
        let sandbox = try XCTUnwrap(ApprovalPushPlatform(entitlement: "development"))
        XCTAssertEqual(sandbox, .apnsSandbox)
        XCTAssertEqual(ApprovalPushPlatform(entitlement: "production"), .apnsProduction)
        let registration = try XCTUnwrap(ApprovalPushRegistration(deviceToken: Data(repeating: 0xab, count: 32), platform: sandbox))
        let data = try XCTUnwrap(registration.registerMessage?.data(using: .utf8))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(wire["type"] as? String, "relayPushRegister")
        let address = try XCTUnwrap(wire["registration"] as? [String: Any])
        XCTAssertEqual(address["platform"] as? String, "apns_sandbox")
        XCTAssertEqual(address["token"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(Set(wire.keys), ["type", "registration"])
        XCTAssertEqual(Set(address.keys), ["platform", "token"])
        XCTAssertNil(ApprovalPushRegistration(deviceToken: Data(), platform: sandbox))
        XCTAssertNil(ApprovalPushRegistration(deviceToken: Data(repeating: 0, count: 257), platform: sandbox))
    }

    func testResolvedBeforeOpenAndDuplicateDeliveryRemainSuppressedAfterRestart() throws {
        let now = Date(timeIntervalSince1970: 100)
        var inbox = ApprovalPushReconciliation()
        XCTAssertTrue(inbox.receive(try hint("resolved"), now: now))
        XCTAssertTrue(inbox.receive(try hint("approval"), now: now.addingTimeInterval(1)))
        XCTAssertTrue(inbox.receive(try hint("resolved"), now: now.addingTimeInterval(2)))
        XCTAssertEqual(inbox.resolutions.count, 1)
        var restarted = ApprovalPushReconciliation(saved: inbox.saved)
        XCTAssertTrue(restarted.receive(try hint("approval"), now: now.addingTimeInterval(3)))
        XCTAssertFalse(restarted.receive(try hint("approval", host: "another-host"), now: now.addingTimeInterval(3)))
        XCTAssertFalse(restarted.receive(try hint("approval"), now: now.addingTimeInterval(86_402)))
    }

    func testResolutionCacheIsBoundedAndMalformedHintsAreNotUsable() throws {
        var inbox = ApprovalPushReconciliation()
        for index in 0..<600 {
            let hint = try XCTUnwrap(ApprovalPushHint(userInfo: ["kind": "resolved", "approval_id": UUID().uuidString,
                "atem_device_id": "host-\(index)"]))
            XCTAssertTrue(inbox.receive(hint, now: Date(timeIntervalSince1970: 100)))
        }
        XCTAssertEqual(inbox.resolutions.count, 512)
        XCTAssertNil(ApprovalPushHint(userInfo: ["kind": "approval", "approval_id": id, "atem_device_id": "genie"]))
        XCTAssertNil(ApprovalPushHint(userInfo: ["kind": "resolved", "approval_id": "../another", "atem_device_id": "genie"]))
        XCTAssertNil(ApprovalPushHint(userInfo: ["kind": "resolved", "approval_id": id, "atem_device_id": "genie\nother"]))
        let injected = try XCTUnwrap(ApprovalPushHint(userInfo: ["kind": "approval", "approval_id": id,
            "atem_device_id": "genie", "session_id": "session", "decision": "allow", "acquire": true,
            "rule": "any command", "process_gen": "untrusted"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(injected)) as? [String: Any])
        XCTAssertNil(object["decision"])
        XCTAssertNil(object["acquire"])
        XCTAssertNil(object["rule"])
        XCTAssertNil(object["process_gen"])
    }

    func testPushFramesAndMalformedPushFramesNeverLogSummariesOrAddresses() throws {
        for type in ["push_approval", "push_resolved", "relayPushRegister"] {
            let message: [String: Any] = ["type": type, "summary": "private-tool-summary", "token": "private-device-address",
                                        "data": ["op": "private-tool-summary"]]
            let envelope: [String: Any] = ["atem_id": "host", "payload": message]
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            let malformed = "{\"type\":\"\(type)\",\"summary\":\"private-tool-summary\","
            for input in [wire, malformed] {
                let sanitized = NetworkDebugLogger.sanitizedPayload(input)
                XCTAssertFalse(sanitized.contains("private-tool-summary"))
                XCTAssertFalse(sanitized.contains("private-device-address"))
            }
        }
    }
}
