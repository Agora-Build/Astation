import XCTest
@testable import Menubar

final class SsoSessionTests: XCTestCase {
    func testNeedsRefreshWhenWithin60s() {
        let now = UInt64(Date().timeIntervalSince1970)
        let s = SsoSession(accessToken: "a", refreshToken: "r", expiresAt: now + 30, loginId: nil)
        XCTAssertTrue(s.needsRefresh())
    }

    func testDoesNotNeedRefreshWhenPlenty() {
        let now = UInt64(Date().timeIntervalSince1970)
        let s = SsoSession(accessToken: "a", refreshToken: "r", expiresAt: now + 3600, loginId: nil)
        XCTAssertFalse(s.needsRefresh())
    }

    func testCodableRoundTrip() throws {
        let s = SsoSession(accessToken: "acc", refreshToken: "ref", expiresAt: 1_700_000_000, loginId: "u@a.io")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SsoSession.self, from: data)
        XCTAssertEqual(back.accessToken, "acc")
        XCTAssertEqual(back.refreshToken, "ref")
        XCTAssertEqual(back.expiresAt, 1_700_000_000)
        XCTAssertEqual(back.loginId, "u@a.io")
    }
}
