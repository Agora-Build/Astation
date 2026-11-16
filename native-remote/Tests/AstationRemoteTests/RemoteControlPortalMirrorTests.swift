import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

private actor ControlMirrorHTTP: AccountOIDCHTTP {
    var requests: [URLRequest] = []
    var status = 200
    var raw: Data?
    var body: [String: Any] = ["id": "i-01234567890123456789012345", "name": "Test integration",
        "stationOrigin": "https://station.example", "state": "revoking", "scopes": ["agent.view"],
        "expiresAt": "2026-01-01T00:00:00Z", "role": "owner", "interruptRunning": false]
    func reply(_ fields: [String: Any], status: Int = 200) {
        body.merge(fields) { _, next in next }
        self.status = status
    }
    func replyJSON(_ text: String, status: Int = 409) {
        raw = Data(text.utf8)
        self.status = status
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (try raw ?? JSONSerialization.data(withJSONObject: body), status)
    }
    func last() -> URLRequest? { requests.last }
    func count() -> Int { requests.count }
}

final class RemoteControlPortalMirrorTests: XCTestCase {
    private let owner = "ab00000000000000000000000000"
    private func client(_ http: ControlMirrorHTTP, owner: String? = nil) throws -> PortalIntegrationHTTP {
        let config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation",
            resource: "https://portal.example", requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
        return try PortalIntegrationHTTP(configuration: config, portalOrigin: "https://portal.example", ownerAccount: owner ?? self.owner,
            http: http, accessToken: { "test-account-access" })
    }
    private func mirror(interrupt: Bool, issuer: String = "https://auth.example", owner: String? = nil) throws -> RemoteControlPortalMirror {
        try RemoteControlPortalMirror(issuer: issuer, ownerAccount: owner ?? self.owner, stationOrigin: "https://station.example",
            integrationID: "i-01234567890123456789012345", interruptRunning: interrupt)
    }

    func testMirrorSendsAnExplicitBooleanWithExistingNativeScopeAndAllowsExpiredRevokes() async throws {
        for interrupt in [false, true] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.reply(["interruptRunning": interrupt])
            let reply = try await portal.mirrorRevoke(mirror(interrupt: interrupt))
            guard case .confirmed(let record) = reply else { return XCTFail("matching revocation not confirmed") }
            XCTAssertEqual(record.state, "revoking")
            let sent = await http.last()
            let request = try XCTUnwrap(sent)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://portal.example/api/v1/integrations/i-01234567890123456789012345/revoke")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-account-access")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["interruptRunning"])
            XCTAssertEqual(body["interruptRunning"] as? Bool, interrupt)
            XCTAssertEqual(CFGetTypeID(try XCTUnwrap(body["interruptRunning"] as? NSNumber)), CFBooleanGetTypeID())
        }
    }

    func testOnlyTheTwoAuthenticatedFinalConflictsSettleAnInterruptingMirror() async throws {
        for reason: RemoteControlPortalRefusal in [.tooLate, .stationRemoved] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.replyJSON("{\"error\":\"The interruption cannot be mirrored.\",\"code\":\"\(reason.rawValue)\"}")
            let result = try await portal.mirrorRevoke(mirror(interrupt: true))
            XCTAssertEqual(result, .finalRefusal(reason))
            let count = await http.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testFinalCodesCannotSettleOtherStatusesActionsOrMalformedResponses() async throws {
        for status in [200, 401, 403, 404, 429, 503] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.replyJSON("{\"error\":\"Expired.\",\"code\":\"too_late\"}", status: status)
            do { _ = try await portal.mirrorRevoke(mirror(interrupt: true)); XCTFail("status \(status) settled") }
            catch {}
        }
        for text in ["{}", "[]", "null", "not json",
            "{\"code\":\"too_late\"}", "{\"error\":null,\"code\":\"too_late\"}",
            "{\"error\":\"\",\"code\":\"too_late\"}", "{\"error\":\"Refused\",\"code\":null}",
            "{\"error\":\"Refused\",\"code\":\"too_late\",\"code\":\"station_removed\"}",
            "{\"error\":\"Refused\",\"code\":\"too_late\",\"other\":true}",
            "{\"error\":\"Refused\",\"code\":\"invalid_state\"}",
            "{\"error\":\"\(String(repeating: "a", count: 65_536))\",\"code\":\"too_late\"}"] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.replyJSON(text)
            do { _ = try await portal.mirrorRevoke(mirror(interrupt: true)); XCTFail("malformed/unknown conflict settled") }
            catch {}
        }
        let http = ControlMirrorHTTP(), portal = try client(http)
        await http.replyJSON("{\"error\":\"Refused\",\"code\":\"station_removed\"}")
        do { _ = try await portal.mirrorRevoke(mirror(interrupt: false)); XCTFail("noninterrupting mirror settled") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        do { _ = try await portal.owned(stationOrigin: "https://station.example"); XCTFail("list treated as settled") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
    }

    func testMirrorRefusesAnotherIssuerOrOwnerBeforeSending() async throws {
        let http = ControlMirrorHTTP(), portal = try client(http)
        for intent in [try mirror(interrupt: false, issuer: "https://other-auth.example"),
            try mirror(interrupt: false, owner: "ab11111111111111111111111111")] {
            do { _ = try await portal.mirrorRevoke(intent); XCTFail("foreign intent sent") }
            catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        }
        let count = await http.count()
        XCTAssertEqual(count, 0)
    }

    func testMirrorNeverSettlesTheWrongStationIntegrationRoleStateOrInterruptChoice() async throws {
        for fields: [String: Any] in [["stationOrigin": "https://other.example"], ["id": "i-11234567890123456789012345"],
            ["role": "station_owner"], ["state": "ready"], ["interruptRunning": false], ["interruptRunning": NSNull()]] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.reply(fields)
            do { _ = try await portal.mirrorRevoke(mirror(interrupt: true)); XCTFail("mismatched receipt accepted") }
            catch {}
        }
        for status in [401, 403, 404, 409, 429, 503] {
            let http = ControlMirrorHTTP(), portal = try client(http)
            await http.reply([:], status: status)
            do { _ = try await portal.mirrorRevoke(mirror(interrupt: false)); XCTFail("failed mirror accepted") }
            catch {}
        }
    }
}
