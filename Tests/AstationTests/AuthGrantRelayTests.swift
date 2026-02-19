import XCTest
@testable import Menubar
import Foundation

/// Tests that handleAuthResult POSTs to the relay server's grant/deny endpoints.
final class AuthGrantRelayTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(granted: Bool, otp: String = "12345678") -> AuthSession {
        let request = AuthRequest(
            sessionId: "test-session-id",
            hostname: "test-host",
            otp: otp,
            timestamp: Date()
        )
        var session = AuthSession(request: request)
        session.granted = granted
        if granted {
            session.sessionToken = "fake-token-abc123"
        }
        return session
    }

    // MARK: - Grant endpoint

    func testGrantPostBodyContainsOtp() throws {
        let exp = expectation(description: "grant POST received")

        // Spin up a tiny local HTTP server to capture the request.
        let server = MockHTTPServer(onRequest: { method, path, body in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/api/sessions/test-session-id/grant")
            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] {
                XCTAssertEqual(json["otp"], "12345678")
            } else {
                XCTFail("Could not parse grant body")
            }
            exp.fulfill()
            return (200, "{}")
        })
        let port = try server.start()

        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:\(port)")
        hub.postGrantToRelayServer(sessionId: "test-session-id", otp: "12345678")

        waitForExpectations(timeout: 3)
        server.stop()
    }

    func testDenyPostHitsCorrectEndpoint() throws {
        let exp = expectation(description: "deny POST received")

        let server = MockHTTPServer(onRequest: { method, path, _ in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/api/sessions/test-session-id/deny")
            exp.fulfill()
            return (200, "{}")
        })
        let port = try server.start()

        let hub = AstationHubManager(skipProjectLoad: true)
        hub.overrideRelayUrl("http://127.0.0.1:\(port)")
        hub.postDenyToRelayServer(sessionId: "test-session-id")

        waitForExpectations(timeout: 3)
        server.stop()
    }
}

// MARK: - AstationHubManager test extension

extension AstationHubManager {
    /// Override the relay URL for testing without touching UserDefaults.
    func overrideRelayUrl(_ url: String) {
        _testRelayUrlOverride = url
    }
}

// MARK: - Minimal mock HTTP server

final class MockHTTPServer {
    typealias Handler = (String, String, Data?) -> (Int, String)

    private let handler: Handler
    private var serverSocket: Int32 = -1
    private var thread: Thread?

    init(onRequest handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws -> Int {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(serverSocket, 5)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverSocket, $0, &addrLen)
            }
        }
        let port = Int(CFSwapInt16BigToHost(boundAddr.sin_port))

        let t = Thread {
            guard let clientFd = Optional(accept(self.serverSocket, nil, nil)), clientFd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(clientFd, &buf, buf.count, 0)
            guard n > 0 else { close(clientFd); return }

            let raw = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
            let lines = raw.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.components(separatedBy: " ")
            let method = parts.count > 0 ? parts[0] : ""
            let path   = parts.count > 1 ? parts[1] : ""

            // Extract body (after \r\n\r\n)
            var body: Data? = nil
            if let bodyRange = raw.range(of: "\r\n\r\n") {
                let bodyStr = String(raw[bodyRange.upperBound...])
                if !bodyStr.isEmpty { body = bodyStr.data(using: .utf8) }
            }

            let (status, responseBody) = self.handler(method, path, body)
            let response = "HTTP/1.1 \(status) OK\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n\(responseBody)"
            send(clientFd, response, response.utf8.count, 0)
            close(clientFd)
        }
        t.start()
        self.thread = t
        return port
    }

    func stop() {
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
    }
}
