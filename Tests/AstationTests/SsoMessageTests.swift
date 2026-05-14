import XCTest
@testable import Menubar

final class CredentialSyncMessageTests: XCTestCase {
    func testEncodeIncludesAllFields() throws {
        let msg = AstationMessage.credentialSync(
            accessToken: "AT",
            refreshToken: "RT",
            expiresAt: 1_700_000_000,
            loginId: "u@a.io",
            astationId: "ast-1",
            saveCredentials: true
        )
        let data = try JSONEncoder().encode(msg)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""type":"credentialSync""#))
        XCTAssertTrue(s.contains(#""access_token":"AT""#))
        XCTAssertTrue(s.contains(#""refresh_token":"RT""#))
        XCTAssertTrue(s.contains(#""expires_at":1700000000"#))
        XCTAssertTrue(s.contains(#""login_id":"u@a.io""#))
        XCTAssertTrue(s.contains(#""astation_id":"ast-1""#))
        XCTAssertTrue(s.contains(#""save_credentials":true"#))
    }

    func testDecodeRequiredFields() throws {
        let json = """
        {"type":"credentialSync","timestamp":"2026-05-13T00:00:00Z","data":{
          "access_token":"AT","refresh_token":"RT","expires_at":1700000000,
          "login_id":"u","astation_id":"ast-1","save_credentials":false
        }}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .credentialSync(at, rt, ex, lid, aid, save) = msg else {
            return XCTFail("expected credentialSync")
        }
        XCTAssertEqual(at, "AT")
        XCTAssertEqual(rt, "RT")
        XCTAssertEqual(ex, 1_700_000_000)
        XCTAssertEqual(lid, "u")
        XCTAssertEqual(aid, "ast-1")
        XCTAssertFalse(save)
    }

    func testDecodeAllowsMissingLoginId() throws {
        let json = """
        {"type":"credentialSync","timestamp":"2026-05-13T00:00:00Z","data":{
          "access_token":"AT","refresh_token":"RT","expires_at":1700000000,
          "astation_id":"ast-1","save_credentials":true
        }}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .credentialSync(_, _, _, lid, _, _) = msg else {
            return XCTFail("expected credentialSync")
        }
        XCTAssertNil(lid)
    }
}
