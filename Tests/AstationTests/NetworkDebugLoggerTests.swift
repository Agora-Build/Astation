import XCTest
@testable import Menubar

final class NetworkDebugLoggerTests: XCTestCase {
    func testSanitizedPayloadRedactsNestedCredentials() {
        let payload = #"{"atem_id":"device-1","payload":{"data":{"session_id":"session-secret","proof":"proof-secret","token":"token-secret","hostname":"office"}}}"#
        let sanitized = NetworkDebugLogger.sanitizedPayload(payload)

        XCTAssertFalse(sanitized.contains("session-secret"))
        XCTAssertFalse(sanitized.contains("proof-secret"))
        XCTAssertFalse(sanitized.contains("token-secret"))
        XCTAssertTrue(sanitized.contains("device-1"))
        XCTAssertTrue(sanitized.contains("office"))
    }

    func testSanitizedPayloadLeavesNonJSONTextReadable() {
        XCTAssertEqual(NetworkDebugLogger.sanitizedPayload("connection closed"), "connection closed")
    }
}
