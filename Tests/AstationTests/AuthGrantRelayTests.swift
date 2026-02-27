import XCTest
@testable import Menubar
import Foundation

/// Tests that Astation builds correct relay grant/deny requests.
final class AuthGrantRelayTests: XCTestCase {

    func testGrantRequestContainsOtpAndEndpoint() throws {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:3000")

        guard let request = hub.makeGrantRequest(sessionId: "test-session-id", otp: "12345678") else {
            XCTFail("Expected grant request")
            return
        }

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3000/api/sessions/test-session-id/grant")

        let json = try XCTUnwrap(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: json) as? [String: String]
        XCTAssertEqual(body?["otp"], "12345678")
    }

    func testDenyRequestContainsEndpoint() {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:3000")

        guard let request = hub.makeDenyRequest(sessionId: "test-session-id") else {
            XCTFail("Expected deny request")
            return
        }

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3000/api/sessions/test-session-id/deny")
        XCTAssertNil(request.httpBody)
    }
}

// MARK: - AstationHubManager test extension

extension AstationHubManager {
    /// Override the relay URL for testing without touching UserDefaults.
    func overrideRelayUrl(_ url: String) {
        _testRelayUrlOverride = url
    }
}
