import XCTest
import CryptoKit
@testable import Menubar

final class SsoPkceTests: XCTestCase {
    func testPkceVerifierIsBase64UrlOf32Bytes() {
        let (v, _) = SsoPkce.generate()
        // 32 bytes → base64url with no padding → 43 chars
        XCTAssertEqual(v.count, 43)
        XCTAssertFalse(v.contains("="))
        XCTAssertFalse(v.contains("+"))
        XCTAssertFalse(v.contains("/"))
    }

    func testChallengeIsSha256OfVerifier() {
        let (v, c) = SsoPkce.generate()
        let hash = SHA256.hash(data: Data(v.utf8))
        let computed = Data(hash).base64URLEncoded()
        XCTAssertEqual(c, computed)
    }

    func testStateIsUnique() {
        let a = SsoPkce.generateState()
        let b = SsoPkce.generateState()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }
}

final class SsoCallbackParserTests: XCTestCase {
    func testExtractsCodeAndState() {
        let r = SsoCallbackQuery.parse("code=mycode123&state=mystate456")
        XCTAssertEqual(r.code, "mycode123")
        XCTAssertEqual(r.state, "mystate456")
        XCTAssertEqual(r.loginId, "")
    }

    func testExtractsLoginId() {
        let r = SsoCallbackQuery.parse("code=abc&loginId=52a4f560&state=xyz")
        XCTAssertEqual(r.loginId, "52a4f560")
    }

    func testUrlDecodesValues() {
        let r = SsoCallbackQuery.parse("code=hello%20world&state=foo%2Bbar")
        XCTAssertEqual(r.code, "hello world")
        XCTAssertEqual(r.state, "foo+bar")
    }

    func testHandlesMissing() {
        let r = SsoCallbackQuery.parse("")
        XCTAssertEqual(r.code, "")
        XCTAssertEqual(r.state, "")
        XCTAssertEqual(r.loginId, "")
    }

    func testIgnoresExtras() {
        let r = SsoCallbackQuery.parse("session_state=ignored&code=abc&state=xyz&loginId=u&extra=x")
        XCTAssertEqual(r.code, "abc")
        XCTAssertEqual(r.state, "xyz")
        XCTAssertEqual(r.loginId, "u")
    }
}
