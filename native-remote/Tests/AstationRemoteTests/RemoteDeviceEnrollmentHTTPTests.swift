import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

final class RemoteDeviceEnrollmentHTTPTests: XCTestCase {
    @MainActor
    private func fixture(status: Int = 200, code: String? = nil,
        handler: ((URLRequest, RemoteDeviceEnrollmentInvitation) throws -> Data)? = nil) throws -> (RemoteRecoveryHTTP, RemoteDeviceEnrollmentInvitation, EnrollmentFixture, String) {
        let f = try EnrollmentFixture()
        let host = "device-" + UUID().uuidString.lowercased() + ".example"
        let invitation = try RemoteDeviceEnrollmentInvitation(issuer: "https://auth.dev.agora.build", owner: "owner-login", station: "https://" + host,
            log: f.log, manager: "manager", roles: ["view"], now: f.clock)
        RecoveryHTTPStub.install(host: host) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(invitation.genesis)/device-enrollments/\(invitation.id)")
            if let code { return (status, Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)) }
            return (status, try handler?(request, invitation) ?? Self.mailbox(invitation))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        return (try RemoteRecoveryHTTP(relayURL: invitation.station, configuration: config, accessToken: { "synthetic-test-token" }), invitation, f, host)
    }

    private static func mailbox(_ invitation: RemoteDeviceEnrollmentInvitation, request: String? = nil, response: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["expires": invitation.expires,
            "request": try request.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull(),
            "response": try response.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()])
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testNativeMailboxRoundTripPublishesOnlyTheCommittedSealedHandoff() async throws {
        var applicant: String?, response: String?
        var methods = [String]()
        let (http, invitation, f, host) = try fixture { request, invitation in
            methods.append(request.httpMethod ?? "")
            switch request.httpMethod {
            case "POST":
                let body = try Self.body(request)
                XCTAssertEqual(Set(body.keys), ["stage", "message"])
                let message = try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: XCTUnwrap(body["message"])), as: UTF8.self))
                XCTAssertFalse(message.contains(invitation.secret))
                if body["stage"] as? String == "request" { applicant = message }
                else { response = message }
            case "DELETE": return Data("{\"closed\":true}".utf8)
            default: break
            }
            return try Self.mailbox(invitation, request: applicant, response: response)
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let phone = DeviceIdentityFixture(), identity = try phone.load(account: invitation.owner)
        let request = try await identity.enrollmentRequest(invitation: invitation, station: invitation.station, deviceName: "Test phone",
            now: { f.clock }, current: { true }, confirm: { true }, persist: { _ in })
        let session = try RemoteDeviceEnrollmentSession(invitation: invitation, now: f.clock, persist: { _ in })
        let empty = try await http.createEnrollment(invitation, now: f.clock.wallMs)
        XCTAssertNil(empty.request)
        let submitted = try await http.submitEnrollment(request, invitation: invitation, now: f.clock.wallMs)
        XCTAssertEqual(submitted.request, request)
        let received = try await http.readEnrollment(invitation, now: f.clock.wallMs)
        _ = try session.bind(requestJSON: XCTUnwrap(received.request).json(), now: f.clock)
        let review = try session.review(log: f.log, now: f.clock)
        _ = try review.prepare(publication: f.publication, managerID: "manager", now: f.clock)
        _ = try f.sign(review)
        _ = try f.publication.relayStored(now: f.clock)
        let committed = try review.committedLog(publication: f.publication, now: f.clock)
        let keys = [AccountKey(kid: "test-key", k: Data(repeating: 0x77, count: 32))]
        let handoff = try RemoteDeviceEnrollmentHandoff(json: session.handoff(committedLog: committed, keys: keys, now: f.clock),
            invitation: invitation, request: request, now: f.clock)
        let published = try await http.publishEnrollment(handoff, request: request, invitation: invitation, now: f.clock.wallMs)
        XCTAssertEqual(published.response, handoff)
        let delivered = try await http.readEnrollment(invitation, now: f.clock.wallMs)
        var saved: Data?
        let enrolled = try RemoteEnrolledDevice(handoff: XCTUnwrap(delivered.response), invitation: invitation, request: request,
            identity: identity, log: committed, now: f.clock, persist: { saved = $0 })
        XCTAssertEqual(enrolled.accountKeys, keys)
        XCTAssertNotNil(saved)
        try await http.cancelEnrollment(invitation)
        XCTAssertEqual(methods, ["PUT", "POST", "GET", "POST", "GET", "DELETE"])
    }

    @MainActor
    func testCreateUploadsOnlyExpiryAndKeepsTheScannedSecretOffTheNetwork() async throws {
        let (http, invitation, f, host) = try fixture { request, invitation in
            XCTAssertEqual(request.httpMethod, "PUT")
            let parsed = try Self.body(request)
            XCTAssertEqual(Set(parsed.keys), ["expires"])
            return try Self.mailbox(invitation)
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let mailbox = try await http.createEnrollment(invitation, now: f.clock.wallMs)
        XCTAssertEqual(mailbox.expires, invitation.expires)
        XCTAssertNil(mailbox.request)
    }

    @MainActor
    func testWrongStationIsRefusedBeforeRequestingAnAccountToken() async throws {
        let (_, invitation, f, host) = try fixture()
        defer { RecoveryHTTPStub.remove(host: host) }
        let wrong = try RemoteRecoveryHTTP(relayURL: "https://another-station.example", accessToken: {
            XCTFail("Wrong Station requested a token"); return "not-sent"
        })
        do { _ = try await wrong.createEnrollment(invitation, now: f.clock.wallMs); XCTFail("Wrong Station") }
        catch { XCTAssertEqual(error as? RemoteDeviceEnrollmentError, .wrongContext) }
    }

    @MainActor
    func testKnownConflictsClosureAndQuotaAreDistinctFromAnOutage() async throws {
        for (status, code, expected) in [(404, "device_enrollment_not_found", RemoteDeviceEnrollmentTransportError.notFound),
            (409, "device_enrollment_conflict", .conflict), (410, "device_enrollment_closed", .closed),
            (429, "device_enrollment_limit", .limit)] {
            let (http, invitation, f, host) = try fixture(status: status, code: code)
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.readEnrollment(invitation, now: f.clock.wallMs); XCTFail("HTTP \(status)") }
            catch { XCTAssertEqual(error as? RemoteDeviceEnrollmentTransportError, expected) }
        }
        let (http, invitation, _, host) = try fixture(status: 410, code: "device_enrollment_closed")
        defer { RecoveryHTTPStub.remove(host: host) }
        try await http.cancelEnrollment(invitation)
    }

    @MainActor
    func testMailboxCannotExtendInvitationOrSmuggleUnverifiedMessages() async throws {
        for kind in 0..<3 {
            let (http, invitation, f, host) = try fixture { _, invitation in
                var value: [String: Any] = ["expires": invitation.expires, "request": NSNull(), "response": NSNull()]
                if kind == 0 { value["expires"] = invitation.expires + 1 }
                if kind == 1 { value["request"] = ["body": ["verified": true]] }
                if kind == 2 { value["ignored"] = "extra" }
                return try JSONSerialization.data(withJSONObject: value)
            }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.readEnrollment(invitation, now: f.clock.wallMs); XCTFail("Unverified mailbox") }
            catch {}
        }
    }
}
