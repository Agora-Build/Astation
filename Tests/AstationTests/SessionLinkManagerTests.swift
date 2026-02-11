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
        XCTAssertNotNil(SessionLinkError.serverError.errorDescription)
        XCTAssertNotNil(SessionLinkError.invalidResponse.errorDescription)
    }

    // MARK: - createLink requires channel

    func testCreateLinkFailsWhenNotInChannel() async {
        let hub = AstationHubManager()
        let manager = SessionLinkManager(hubManager: hub)

        do {
            _ = try await manager.createLink()
            XCTFail("Expected notInChannel error")
        } catch let error as SessionLinkError {
            XCTAssertEqual(error, .notInChannel)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// Allow equatable comparison for test assertions
extension SessionLinkError: Equatable {}
