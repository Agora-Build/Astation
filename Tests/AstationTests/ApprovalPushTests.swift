import Foundation
import XCTest
import AtemClient
@testable import Menubar

final class ApprovalPushTests: XCTestCase {
    private let id = "11111111-1111-4111-8111-111111111111"

    private func hint(_ kind: String, host: String = "genie") throws -> ApprovalPushHint {
        try XCTUnwrap(ApprovalPushHint(userInfo: ["kind": kind, "approval_id": id,
            "atem_device_id": host, "session_id": "claude-session"]))
    }

    func testVerifiedResolutionUsesTheFullR9IdentityAndUnsignedFieldsCannotSupplyItsScope() throws {
        let target = ApprovalRef(accountId: "account", genesisHash: String(repeating: "a", count: 64),
            hostId: "genie", hostTrustGen: 1, sessionId: "session", processGen: "process", approvalId: id)
        let now = Date()
        var inbox = ApprovalPushReconciliation()
        XCTAssertTrue(inbox.receive(ApprovalPushHint(verified: target, resolved: true), now: now))
        XCTAssertTrue(inbox.receive(ApprovalPushHint(verified: target, resolved: false), now: now))
        for field in 0..<6 {
            var changed = target
            switch field {
            case 0: changed.accountId = "other"
            case 1: changed.genesisHash = String(repeating: "b", count: 64)
            case 2: changed.hostId = "other"
            case 3: changed.hostTrustGen = 2
            case 4: changed.sessionId = "other"
            default: changed.processGen = "other"
            }
            XCTAssertFalse(inbox.receive(ApprovalPushHint(verified: changed, resolved: false), now: now))
        }
        let unsigned = try XCTUnwrap(ApprovalPushHint(userInfo: ["kind":"approval","approval_id":id,
            "atem_device_id":"genie","session_id":"session","scope":ApprovalPushHint(verified: target, resolved: true).cacheKey]))
        XCTAssertNil(unsigned.scope)
        XCTAssertFalse(inbox.receive(unsigned, now: now))
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
        for operation in ["push_approval", "push_resolved"] {
            let wire = "{\"type\":\"relay\",\"data\":{\"v\":1,\"op\":\"\(operation)\",\"summary\":\"private-tool-summary\"}}"
            for input in [wire, String(wire.dropLast()), "{\"payload\":\(wire)}"] {
                let sanitized = NetworkDebugLogger.sanitizedPayload(input)
                XCTAssertFalse(sanitized.contains("private-tool-summary"))
                XCTAssertTrue(sanitized.contains("redacted"))
            }
        }
    }

    func testSealedRelayAndOSPushDoNotLogCiphertextOrApprovalMetadata() throws {
        let privateFields = ["sealed-ciphertext", "approval-identity", "device-identity"]
        for op in ["push_hint", "push_seen", "push_ack"] {
            let text = "{\"type\":\"relay\",\"op\":\"\(op)\",\"hints\":[{\"ct\":\"sealed-ciphertext\",\"approval_id\":\"approval-identity\",\"device_id\":\"device-identity\"}]}"
            for wire in [text, String(text.dropLast()), "{\"atem_id\":\"host\",\"payload\":\(text)}"] {
                let sanitized = NetworkDebugLogger.sanitizedPayload(wire)
                for field in privateFields { XCTAssertFalse(sanitized.contains(field)) }
            }
        }
        for text in ["{\"r9_hint\":\"sealed-ciphertext\"}", "{\"r9_hint\":\"sealed-ciphertext\","] {
            XCTAssertFalse(NetworkDebugLogger.sanitizedPayload(text).contains("sealed-ciphertext"))
        }
    }
}
