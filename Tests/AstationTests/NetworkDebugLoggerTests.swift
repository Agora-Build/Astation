import XCTest
@testable import Menubar

final class NetworkDebugLoggerTests: XCTestCase {
    func testSessionErrorKeepsOnlyKnownCodeAndRedactsDetailAndIdentifiers() {
        let payload = #"{"payload":{"type":"session","data":{"v":1,"op":"error","code":"unauthorized","detail":"secret detail","re":"secret id"}}}"#
        let sanitized = NetworkDebugLogger.sanitizedPayload(payload)
        XCTAssertTrue(sanitized.contains("unauthorized"))
        XCTAssertFalse(sanitized.contains("secret detail"))
        XCTAssertFalse(sanitized.contains("secret id"))
        let unknown = NetworkDebugLogger.sanitizedPayload(
            #"{"type":"session","data":{"op":"error","code":"secret error"}}"#)
        XCTAssertTrue(unknown.contains("unknown_error"))
        XCTAssertFalse(unknown.contains("secret error"))
    }

    func testSanitizedPayloadRedactsNestedCredentials() {
        let payload = #"{"atem_id":"device-1","payload":{"data":{"session_id":"session-secret","sessionToken":"camel-secret","proof":"proof-secret","token":"token-secret","hostname":"office"}}}"#
        let sanitized = NetworkDebugLogger.sanitizedPayload(payload)

        XCTAssertFalse(sanitized.contains("session-secret"))
        XCTAssertFalse(sanitized.contains("camel-secret"))
        XCTAssertFalse(sanitized.contains("proof-secret"))
        XCTAssertFalse(sanitized.contains("token-secret"))
        XCTAssertTrue(sanitized.contains("device-1"))
        XCTAssertTrue(sanitized.contains("office"))
    }

    func testSanitizedPayloadLeavesNonJSONTextReadable() {
        XCTAssertEqual(NetworkDebugLogger.sanitizedPayload("connection closed"), "connection closed")
    }

    func testSanitizedPayloadRedactsUnstructuredSecrets() {
        let sanitized = NetworkDebugLogger.sanitizedPayload(
            "request failed token=secret-value Authorization: Bearer header.payload.signature"
        )

        XCTAssertFalse(sanitized.contains("secret-value"))
        XCTAssertFalse(sanitized.contains("header.payload.signature"))
        XCTAssertTrue(sanitized.contains("token=<redacted>"))
        XCTAssertTrue(sanitized.contains("Bearer <redacted>"))
    }

    func testSanitizedPayloadRedactsSecretInTruncatedJSON() {
        let sanitized = NetworkDebugLogger.sanitizedPayload(
            #"{"data":{"sessionToken":"truncated-secret""#
        )

        XCTAssertFalse(sanitized.contains("truncated-secret"))
        XCTAssertTrue(sanitized.contains("sessionToken=<redacted>"))
    }
}
