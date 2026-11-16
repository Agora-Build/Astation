import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

final class RecoveryHTTPStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    static let lock = NSLock()
    static var handlers: [String: Handler] = [:]
    static func install(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host!]
        Self.lock.unlock()
        do {
            let (status, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RemoteRecoveryHTTPTests: XCTestCase {
    private let genesis = String(repeating: "ab", count: 32)
    private func transport(handler: @escaping RecoveryHTTPStub.Handler) throws -> (RemoteRecoveryHTTP, String) {
        let host = "recovery-" + UUID().uuidString.lowercased() + ".example"
        RecoveryHTTPStub.install(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        return (try RemoteRecoveryHTTP(relayURL: "https://" + host, configuration: config, accessToken: { "test-account-token" }), host)
    }

    func testControlStatusBindsTheAccountHeadAndExactOrderedRecordIDs() async throws {
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }, hash = genesis
        let (http, host) = try transport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(hash)/control/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-account-token")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["record_ids"] as? [String], ids)
            let rows = zip(ids, ["unknown", "awaiting_application", "effects_reported"]).map { ["record_id": $0, "state": $1] }
            return (200, try JSONSerialization.data(withJSONObject: ["head": body["expected"]!, "records": rows]))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let result = try await http.controlStatus(genesisHash: genesis, recordIDs: ids, expected: LogHead(seq: 5, hash: genesis))
        XCTAssertEqual(result, [ids[0]: .unknown, ids[1]: .awaitingApplication, ids[2]: .effectsReported])
    }

    func testMalformedControlStatusCannotConfirmApplication() async throws {
        let id = UUID().uuidString.lowercased(), hash = genesis
        let good = "{\"head\":{\"seq\":5,\"hash\":\"\(hash)\"},\"records\":[{\"record_id\":\"\(id)\",\"state\":\"effects_reported\"}]}"
        for bad in [
            good.replacingOccurrences(of: "\"seq\":5", with: "\"seq\":4"),
            good.replacingOccurrences(of: hash, with: String(repeating: "cd", count: 32)),
            good.replacingOccurrences(of: id, with: UUID().uuidString.lowercased()),
            good.replacingOccurrences(of: "effects_reported", with: "applied"),
            good.replacingOccurrences(of: "\"state\":", with: "\"state\":null,\"state\":"),
            good.replacingOccurrences(of: "\"records\":[", with: "\"extra\":null,\"records\":["),
            "{\"head\":{\"seq\":5,\"hash\":\"\(hash)\"},\"records\":[]}"
        ] {
            let (http, host) = try transport { _ in (200, Data(bad.utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.controlStatus(genesisHash: hash, recordIDs: [id], expected: LogHead(seq: 5, hash: hash)); XCTFail("accepted malformed status") }
            catch {}
        }
        let (http, host) = try transport { _ in XCTFail("invalid selector requested an account token/HTTP request"); return (200, Data()) }
        defer { RecoveryHTTPStub.remove(host: host) }
        for ids in [[], [id, id], ["not-a-record-id"], (0..<65).map { _ in UUID().uuidString.lowercased() }] {
            do { _ = try await http.controlStatus(genesisHash: hash, recordIDs: ids, expected: LogHead(seq: 5, hash: hash)); XCTFail("accepted invalid selector") }
            catch {}
        }
    }

    func testLogRequestHasBoundedSelectorAndAccountAuthentication() async throws {
        let genesis = self.genesis
        let (http, host) = try transport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(genesis)/entries")
            XCTAssertEqual(request.url?.query, "after=4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-account-token")
            return (200, Data("{\"head\":{\"seq\":4,\"hash\":\"\(genesis)\"},\"entries\":[],\"more\":false}".utf8))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let page = try await http.entries(genesisHash: genesis, after: 4)
        XCTAssertEqual(page.head, LogHead(seq: 4, hash: genesis))
        XCTAssertFalse(page.more)
    }

    func testMalformedPagesUnsafeNumbersAndOversizedResponsesAreRefused() async throws {
        for body in [
            "{\"head\":{\"seq\":true,\"hash\":\"\(genesis)\"},\"entries\":[]}",
            "{\"head\":{\"seq\":9007199254740992,\"hash\":\"\(genesis)\"},\"entries\":[]}",
            "{\"head\":{\"seq\":0,\"hash\":\"\(genesis)\"},\"entries\":[],\"more\":1}",
            "{\"head\":{\"seq\":0,\"seq\":1,\"hash\":\"\(genesis)\"},\"entries\":[]}",
            String(repeating: " ", count: 262_145)
        ] {
            let (http, host) = try transport { _ in (200, Data(body.utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.entries(genesisHash: genesis, after: 0); XCTFail("accepted malformed page") }
            catch {}
        }
    }

    func testRedirectAndUnauthorizedRepliesCannotBecomeRecoveryData() async throws {
        for status in [301, 302, 307, 308, 401, 403, 500] {
            let (http, host) = try transport { _ in (status, Data("{}".utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.entries(genesisHash: genesis, after: 0); XCTFail("accepted HTTP \(status)") }
            catch {}
        }
    }

    func testForbiddenRepliesDistinguishRegistrationScopeAndAccountAccess() async throws {
        let cases: [(String, String)] = [
            ("recovery_creator_not_registered", RemoteRecoveryTransportError.registrationRequired.localizedDescription),
            ("insufficient_scope", RemoteRecoveryTransportError.permissionRequired.localizedDescription),
            ("wrong_account", RemoteRecoveryTransportError.accessDenied.localizedDescription)
        ]
        for (code, message) in cases {
            let (http, host) = try transport { _ in (403, Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.entries(genesisHash: genesis, after: 0); XCTFail("accepted forbidden response") }
            catch { XCTAssertEqual(error.localizedDescription, message) }
        }
        let (http, host) = try transport { _ in (403, Data(repeating: 0x20, count: 16_385)) }
        defer { RecoveryHTTPStub.remove(host: host) }
        do { _ = try await http.entries(genesisHash: genesis, after: 0); XCTFail("accepted oversized refusal") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteRecoveryTransportError.invalidResponse.localizedDescription) }
    }

    func testInsecureOriginsAreRefusedBeforeTokenProviderCanRun() {
        for url in ["http://relay.example", "ws://relay.example", "https://user@relay.example", "https://relay.example?token=x"] {
            XCTAssertThrowsError(try RemoteRecoveryHTTP(relayURL: url, accessToken: {
                XCTFail("an insecure or malformed origin requested a token")
                return "not-sent"
            }))
        }
    }

    func testMissingSecurityRecordIsDistinctFromAnOutageOrAnUnknownRoute() async throws {
        let cases: [(Int, String, RemoteRecoveryTransportError)] = [
            (404, #"{"error":{"code":"recovery_record_not_found"}}"#, .recordNotFound),
            (404, #"{"error":{"code":"not_found"}}"#, .unavailable),
            (404, "<html>Not Found</html>", .unavailable),
            (503, #"{"error":{"code":"recovery_record_not_found"}}"#, .unavailable),
            (401, #"{"error":{"code":"recovery_record_not_found"}}"#, .authenticationRequired)
        ]
        for (status, body, expected) in cases {
            let (http, host) = try transport { _ in (status, Data(body.utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do { _ = try await http.entries(genesisHash: genesis, after: 0); XCTFail("accepted HTTP \(status)") }
            catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, expected) }
        }
    }

    func testProbeUsesOneEscapedHostComponentAndReturnsOnlyBoundedStrictJSON() async throws {
        let (http, host) = try transport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/probes/%68%6F%73%74%3A%61"))
            return (200, Data(#"{"ch":"atem-ch1","op":"accept"}"#.utf8))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let reply = try await http.hostAccept(genesisHash: genesis, hostID: "host:a", initFrame: Data("{}".utf8))
        XCTAssertFalse(reply.isEmpty)
    }
}
