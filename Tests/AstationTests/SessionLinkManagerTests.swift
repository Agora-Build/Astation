import XCTest
@testable import Menubar

final class SessionLinkManagerTests: XCTestCase {

    // MARK: - maxLinks enforcement

    func testCanCreateMoreInitiallyTrue() {
        let hub = AstationHubManager()
        let manager = SessionLinkManager(hubManager: hub)
        XCTAssertTrue(manager.canCreateMore)
        XCTAssertEqual(manager.activeLinks.count, 0)
    }

    func testMaxLinksValue() {
        let hub = AstationHubManager()
        let manager = SessionLinkManager(hubManager: hub)
        XCTAssertEqual(manager.maxLinks, 8)
    }

    // MARK: - Link tracking

    func testActiveLinkStartsEmpty() {
        let hub = AstationHubManager()
        let manager = SessionLinkManager(hubManager: hub)
        XCTAssertTrue(manager.activeLinks.isEmpty)
    }

    // MARK: - SessionLink struct

    func testSessionLinkStoresProperties() {
        let link = SessionLinkManager.SessionLink(
            id: "abc-123",
            url: "https://station.agora.build/session/abc-123",
            channel: "my-room",
            createdAt: Date()
        )
        XCTAssertEqual(link.id, "abc-123")
        XCTAssertEqual(link.url, "https://station.agora.build/session/abc-123")
        XCTAssertEqual(link.channel, "my-room")
    }

    // MARK: - Error descriptions

    func testErrorDescriptions() {
        XCTAssertNotNil(SessionLinkError.maxLinksReached.errorDescription)
        XCTAssertNotNil(SessionLinkError.notInChannel.errorDescription)
        XCTAssertNotNil(SessionLinkError.tokenGenerationFailed.errorDescription)
        XCTAssertNotNil(SessionLinkError.noProject.errorDescription)
        XCTAssertNotNil(SessionLinkError.invalidServerURL.errorDescription)
        XCTAssertNotNil(SessionLinkError.networkError(urlString: "http://127.0.0.1:3000", detail: "timed out").errorDescription)
        XCTAssertNotNil(SessionLinkError.httpError(statusCode: 401, body: "Unauthenticated.").errorDescription)
        XCTAssertNotNil(SessionLinkError.invalidResponse.errorDescription)
    }

    func testNetworkErrorDescriptionContainsURL() {
        let description = SessionLinkError
            .networkError(urlString: "https://station-staging.agora.build/api/rtc-sessions", detail: "timed out")
            .errorDescription ?? ""
        XCTAssertTrue(description.contains("https://station-staging.agora.build/api/rtc-sessions"))
        XCTAssertTrue(description.contains("timed out"))
    }

    func testHttpErrorDescriptionIncludesBody() {
        let description = SessionLinkError
            .httpError(statusCode: 401, body: "Unauthenticated.")
            .errorDescription ?? ""
        XCTAssertTrue(description.contains("HTTP 401"))
        XCTAssertTrue(description.contains("Unauthenticated."))
    }

    // MARK: - createLink requires channel

    func testCreateLinkFailsWhenNotInChannel() async {
        let hub = AstationHubManager()
        let manager = SessionLinkManager(hubManager: hub)

        do {
            _ = try await manager.createLink()
            XCTFail("Expected notInChannel error")
        } catch let error as SessionLinkError {
            if case .notInChannel = error {
                // expected
            } else {
                XCTFail("Expected notInChannel, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
