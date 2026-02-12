import XCTest

@testable import Menubar

final class RTCTokenGenerationTests: XCTestCase {
    private func makeHubManager() -> AstationHubManager {
        let hub = AstationHubManager(skipProjectLoad: true)
        let project = AgoraProject(
            id: "test",
            name: "Test Project",
            vendorKey: "0123456789abcdef0123456789abcdef",
            signKey: "abcdef0123456789abcdef0123456789",
            status: "active",
            created: 0
        )
        hub.projects = [project]
        return hub
    }

    func testInvalidUidStringReturnsEmptyToken() async {
        let hub = makeHubManager()
        let response = await hub.generateRTCToken(channel: "chan", uid: "abc")
        XCTAssertTrue(response.token.isEmpty)
        XCTAssertEqual(response.expiresIn, "0")
    }

    func testNegativeUidReturnsEmptyToken() async {
        let hub = makeHubManager()
        let response = await hub.generateRTCToken(channel: "chan", uid: "-1")
        XCTAssertTrue(response.token.isEmpty)
        XCTAssertEqual(response.expiresIn, "0")
    }

    func testOutOfRangeUidReturnsEmptyToken() async {
        let hub = makeHubManager()
        let response = await hub.generateRTCToken(
            channel: "chan",
            uid: String(Int(UInt32.max) + 1)
        )
        XCTAssertTrue(response.token.isEmpty)
        XCTAssertEqual(response.expiresIn, "0")
    }

    func testValidUidGeneratesToken() async {
        let hub = makeHubManager()
        let response = await hub.generateRTCToken(channel: "chan", uid: "1234")
        XCTAssertTrue(response.token.hasPrefix("007"))
        XCTAssertEqual(response.channel, "chan")
        XCTAssertEqual(response.uid, "1234")
        XCTAssertEqual(response.expiresIn, "3600s")
    }
}
