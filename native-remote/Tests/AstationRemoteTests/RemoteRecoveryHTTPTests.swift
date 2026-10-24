import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

private final class RecoveryHTTPStub: URLProtocol, @unchecked Sendable {
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

    func testInsecureOriginsAreRefusedBeforeTokenProviderCanRun() {
        for url in ["http://relay.example", "ws://relay.example", "https://user@relay.example", "https://relay.example?token=x"] {
            XCTAssertThrowsError(try RemoteRecoveryHTTP(relayURL: url, accessToken: {
                XCTFail("an insecure or malformed origin requested a token")
                return "not-sent"
            }))
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
