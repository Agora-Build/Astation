import XCTest
@testable import Menubar

final class StationRelayURLTests: XCTestCase {
    func testTrailingSlashesDoNotCreateDoubleSlashWebSocketPaths() throws {
        for suffix in ["", "/", "///", "/ \n"] {
            let url = try XCTUnwrap(StationRelayURL.webSocketURL(
                base: " https://station-staging.agora.build" + suffix,
                code: "astation-test"
            ))
            XCTAssertEqual(url.absoluteString, "wss://station-staging.agora.build/ws?role=astation&code=astation-test")
        }
    }

    func testLocalPortAndBasePathArePreserved() throws {
        let url = try XCTUnwrap(StationRelayURL.webSocketURL(
            base: "http://127.0.0.1:3000/relay/", code: "pair-code"
        ))
        XCTAssertEqual(url.absoluteString, "ws://127.0.0.1:3000/relay/ws?role=astation&code=pair-code")
    }

    func testPairingCodeCannotAddQueryParametersOrFragments() throws {
        let code = "pair&role=atem#fragment"
        let url = try XCTUnwrap(StationRelayURL.webSocketURL(base: "https://station.agora.build/", code: code))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "role", value: "astation"),
            URLQueryItem(name: "code", value: code)
        ])
        XCTAssertNil(components.fragment)
    }

    func testInvalidRelayOriginsAreRejected() {
        for base in ["", "   ", "/relay/", "https://", "ftp://station.agora.build/"] {
            XCTAssertNil(StationRelayURL.webSocketURL(base: base, code: "test"), base)
        }
    }

    func testHTTPRequestsAlsoNormalizeTheRelayBase() throws {
        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl(" https://station-staging.agora.build/// \n")
        XCTAssertEqual(hub.stationRelayUrl, "https://station-staging.agora.build")
        let request = try XCTUnwrap(hub.makeGrantRequest(sessionId: "test-session", otp: "12345678"))
        XCTAssertEqual(request.url?.absoluteString, "https://station-staging.agora.build/api/sessions/test-session/grant")
    }
}
