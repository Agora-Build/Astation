import CStationCore
import XCTest
@testable import Menubar

final class TokenLibraryInteropTests: XCTestCase {
    func testLegacyTokensRebuildIdenticallyWithSharedLibrary() throws {
        let app = "0123456789abcdef0123456789abcdef"
        let certificate = "abcdef0123456789abcdef0123456789"
        // Captured from the original C++ builder before removing it.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "token-compatibility", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 8)
        for fixture in fixtures {
            let original = try XCTUnwrap(fixture["token"])
            let decoded = try AgoraTokenService.decode(original)
            let service = try XCTUnwrap(decoded.services.first)
            let rebuilt: String
            if service.service_type == 1 {
                let channel = try XCTUnwrap(service.details.channel)
                let account = try XCTUnwrap(service.details.account)
                let uid = account.isEmpty ? 0 : try XCTUnwrap(UInt32(account))
                var request = AgoraRTCRequest(channel: channel, identity: .uid(uid),
                                              role: service.privileges.count == 1 ? .subscriber : .publisher)
                request.tokenExpiry = decoded.expire
                request.privilegeExpiry = try XCTUnwrap(service.privileges["1"])
                request.issuedAt = decoded.issued_at; request.salt = decoded.salt
                rebuilt = try AgoraTokenService.rtc(appID: app, certificate: certificate, request: request)
            } else {
                rebuilt = try AgoraTokenService.rtm(appID: app, certificate: certificate,
                    user: XCTUnwrap(service.details.user_id), expiry: decoded.expire, issuedAt: decoded.issued_at, salt: decoded.salt)
            }
            XCTAssertEqual(rebuilt, original, fixture["name"] ?? "")
            XCTAssertTrue(try AgoraTokenService.verify(original, certificate: certificate))
        }
    }
}
