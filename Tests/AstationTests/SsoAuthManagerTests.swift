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

final class SsoAuthorizeURLTests: XCTestCase {
    func testAuthorizeURLContainsAllRequiredFields() {
        let url = SsoAuthManager.buildAuthorizeURL(
            ssoUrl: "https://sso2.agora.io",
            redirectUri: "http://127.0.0.1:54321/oauth/callback",
            state: "STATE",
            challenge: "CHAL"
        )
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertTrue(url.contains("client_id=atem"))
        XCTAssertTrue(url.contains("scope=basic_info%2Cconsole"))
        XCTAssertTrue(url.contains("state=STATE"))
        XCTAssertTrue(url.contains("code_challenge=CHAL"))
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Foauth%2Fcallback"))
        XCTAssertTrue(url.hasPrefix("https://sso2.agora.io/api/v0/oauth/authorize?"))
    }
}

final class SsoTokenResponseDecodeTests: XCTestCase {
    func testDecodeFullResponse() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#.data(using: .utf8)!
        let session = try SsoNetworkRefresher.decodeTokenResponse(json)
        XCTAssertEqual(session.accessToken, "AT")
        XCTAssertEqual(session.refreshToken, "RT")
        // expiresAt is "now + 3600" — should be within 5s of that.
        let target = SsoSession.nowSecs() + 3600
        XCTAssertLessThan(abs(Int64(session.expiresAt) - Int64(target)), 5)
    }

    func testRejectsMissingFields() {
        let json = #"{"access_token":"AT"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try SsoNetworkRefresher.decodeTokenResponse(json))
    }
}

import NIO

/// Spins up the real SsoLoopbackListener, fires an HTTP GET at it from the
/// test, and asserts the parsed callback is returned. No external network.
final class SsoLoopbackIntegrationTests: XCTestCase {
    func testRoundTripsValidCallback() async throws {
        let listener = try await SsoLoopbackListener.bind(timeout: .seconds(5), expectedState: "ST")

        // Fire the GET request from the test in parallel with awaitCallback.
        async let awaited = listener.awaitCallback()

        let url = URL(string: "http://127.0.0.1:\(listener.port)/oauth/callback?code=CODE&state=ST&loginId=u%40a.io")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Login successful") == true)

        let result = try await awaited
        XCTAssertEqual(result.code, "CODE")
        XCTAssertEqual(result.state, "ST")
        XCTAssertEqual(result.loginId, "u@a.io")
    }

    func testStateMismatchFails() async throws {
        let listener = try await SsoLoopbackListener.bind(timeout: .seconds(5), expectedState: "EXPECTED")
        async let awaited = listener.awaitCallback()

        let url = URL(string: "http://127.0.0.1:\(listener.port)/oauth/callback?code=C&state=WRONG")!
        _ = try? await URLSession.shared.data(from: url)

        do {
            _ = try await awaited
            XCTFail("expected stateMismatch")
        } catch SsoError.stateMismatch {
            // ok
        } catch {
            XCTFail("expected stateMismatch, got \(error)")
        }
    }
}
