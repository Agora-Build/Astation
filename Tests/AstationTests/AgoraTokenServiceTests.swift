import XCTest
@testable import Menubar

final class AgoraTokenServiceTests: XCTestCase {
    private let app = "0123456789abcdef0123456789abcdef"
    private let certificate = "abcdef0123456789abcdef0123456789"

    private func token(_ request: AgoraRTCRequest) throws -> AgoraDecodedToken {
        try AgoraTokenService.decode(AgoraTokenService.rtc(appID: app, certificate: certificate, request: request))
    }

    func testUserAccountAndCombinedRTMUseExactIdentity() throws {
        var request = AgoraRTCRequest(channel: "CaseSensitive", identity: .account("User42"))
        request.includeRTM = true
        let decoded = try token(request)
        XCTAssertEqual(decoded.services.count, 2)
        XCTAssertEqual(decoded.services[0].details.channel, "CaseSensitive")
        XCTAssertEqual(decoded.services[0].details.account, "User42")
        XCTAssertEqual(decoded.services[1].details.user_id, "User42")
    }

    func testExplicitPrivilegesAndIndependentExpiries() throws {
        var request = AgoraRTCRequest(channel: "custom", identity: .uid(1), role: .custom)
        request.tokenExpiry = 900; request.joinExpiry = 600; request.audioExpiry = 300
        request.videoExpiry = 200; request.dataExpiry = 100
        request.includeRTM = true; request.rtmUser = "different-user"; request.rtmExpiry = 400
        let decoded = try token(request)
        XCTAssertEqual(decoded.expire, 900)
        XCTAssertEqual(decoded.services[0].privileges, ["1": 600, "2": 300, "3": 200, "4": 100])
        XCTAssertEqual(decoded.services[1].privileges, ["1": 400])
        XCTAssertEqual(decoded.services[1].details.user_id, "different-user")
    }

    func testSignatureVerificationAndDecodeAreSeparate() throws {
        let value = try AgoraTokenService.rtm(appID: app, certificate: certificate, user: "user")
        XCTAssertEqual(try AgoraTokenService.decode(value).app_id, app)
        XCTAssertTrue(try AgoraTokenService.verify(value, certificate: certificate))
        XCTAssertFalse(try AgoraTokenService.verify(value, certificate: app))
    }

    func testInvalidInputsAreRejectedWithoutSecretInErrors() {
        for (appID, cert, channel) in [("invalid", certificate, "demo"), (app, "private-invalid-certificate", "demo"),
                                      (app, certificate, ""), (app, certificate, String(repeating: "a", count: 65))] {
            XCTAssertThrowsError(try AgoraTokenService.rtc(appID: appID, certificate: cert,
                request: AgoraRTCRequest(channel: channel, identity: .uid(1)))) { error in
                XCTAssertFalse(error.localizedDescription.contains(cert))
            }
        }
    }

    func testUTF8LimitsAndEmbeddedNULAreEnforced() {
        XCTAssertThrowsError(try token(AgoraRTCRequest(channel: String(repeating: "\u{00e9}", count: 33), identity: .uid(1))))
        XCTAssertThrowsError(try token(AgoraRTCRequest(channel: "demo\0suffix", identity: .uid(1))))
        XCTAssertThrowsError(try token(AgoraRTCRequest(channel: "demo", identity: .account(String(repeating: "a", count: 256)))))
    }

    func testMalformedAndOversizedTokensFailCleanly() {
        for input in ["", "006invalid", "007invalid", "007\0suffix", String(repeating: "a", count: 65_537)] {
            XCTAssertThrowsError(try AgoraTokenService.decode(input))
        }
    }

    func testZeroExpiriesAndEmptyRTMUserAreRejected() {
        var request = AgoraRTCRequest(channel: "demo", identity: .uid(1))
        request.privilegeExpiry = 0
        XCTAssertThrowsError(try token(request))
        XCTAssertThrowsError(try AgoraTokenService.rtm(appID: app, certificate: certificate, user: "", expiry: 3600))
        XCTAssertThrowsError(try AgoraTokenService.rtm(appID: app, certificate: certificate, user: "user", expiry: 0))
    }

    func testFormRejectsInvalidNumericUIDInsteadOfUsingWildcard() {
        for uid in ["", "user", "-1", "4294967296"] {
            var form = TokenToolsForm(channel: "demo")
            form.identity = uid
            XCTAssertThrowsError(try form.generate(appID: app, certificate: certificate))
        }
    }

    func testFormRejectsNonASCIIUserAccountsRequiredByRTCSDK() {
        let form = TokenToolsForm(usesAccount: true, channel: "demo", identity: "user-\u{00e9}")
        XCTAssertThrowsError(try form.generate(appID: app, certificate: certificate))
    }

    func testFormPreservesMaximumUIDAndSubscriberPermissions() throws {
        var form = TokenToolsForm(channel: "demo", identity: "4294967295", role: .subscriber)
        form.privilegeExpiry = "600"
        let decoded = try AgoraTokenService.decode(form.generate(appID: app, certificate: certificate))
        XCTAssertEqual(decoded.services[0].details.account, "4294967295")
        XCTAssertEqual(decoded.services[0].privileges, ["1": 600])
    }

    func testRTMFormIgnoresHiddenRTCFields() throws {
        var form = TokenToolsForm(isRTM: true, identity: "RTM-User")
        form.privilegeExpiry = "invalid"; form.channel = ""; form.includeRTM = true; form.rtmExpiry = "invalid"
        let decoded = try AgoraTokenService.decode(form.generate(appID: app, certificate: certificate))
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].details.user_id, "RTM-User")
    }

    func testFormRequiresValidActiveExpiryFields() {
        for expiry in ["0", "-1", "4294967296", "", "3600 seconds"] {
            var form = TokenToolsForm(channel: "demo")
            form.tokenExpiry = expiry
            XCTAssertThrowsError(try form.generate(appID: app, certificate: certificate))
        }
    }
}
