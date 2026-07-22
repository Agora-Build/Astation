import Foundation
import NIO
import WebSocketKit
import XCTest
@testable import Menubar

final class DirectConnectionTests: XCTestCase {
    func testLoopbackAuthenticatesWithoutPairingOrNetwork() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let future = connect(
            host: "127.0.0.1",
            fixture: fixture,
            group: group,
            authMessage: loopbackAuthMessage(fixture: fixture, atemId: "local-test-atem")
        )
        let (result, socket) = try future.wait()
        XCTAssertEqual(result, "authenticated:local_proof")
        _ = socket.close()
    }

    func testInvalidLoopbackProofIsRejected() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let future = connect(
            host: "127.0.0.1",
            fixture: fixture,
            group: group,
            authMessage: { _ in
                .statusUpdate(status: "auth", data: [
                    "method": "local_proof",
                    "atem_id": "forged-atem",
                    "hostname": "test-mac",
                    "proof": "not-a-valid-proof"
                ])
            }
        )
        let (result, _) = try future.wait()
        XCTAssertEqual(result, "error:Local authentication failed")
    }

    func testUnauthenticatedSessionVerificationIsRejected() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let future = connect(
            host: "127.0.0.1",
            fixture: fixture,
            group: group,
            authMessage: { _ in
                .statusUpdate(status: "session_verify_request", data: [
                    "session_id": UUID().uuidString,
                    "request_id": UUID().uuidString
                ])
            }
        )

        let (result, _) = try future.wait()
        XCTAssertEqual(result, "error:Authentication required")
    }

    func testLANSessionTokenCannotAuthenticateAsLoopback() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let atemId = "cross-scope-atem"
        let session = fixture.sessions.create(hostname: "office", atemId: atemId)
        let future = connect(
            host: "127.0.0.1",
            fixture: fixture,
            group: group,
            authMessage: { challengeData in
                let proof = DeviceAuthentication.proof(
                    token: session.token,
                    challenge: challengeData["challenge"] ?? "",
                    astationId: challengeData["astation_id"] ?? "",
                    atemId: atemId,
                    sessionId: "local"
                )
                return .statusUpdate(status: "auth", data: [
                    "method": "local_proof",
                    "atem_id": atemId,
                    "hostname": "office",
                    "proof": proof
                ])
            }
        )

        let (result, _) = try future.wait()
        XCTAssertEqual(result, "error:Local authentication failed")
    }

    func testFiveLoopbackClientsAuthenticateConcurrently() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let connections = (0..<5).map { index in
            connect(
                host: "127.0.0.1",
                fixture: fixture,
                group: group,
                authMessage: loopbackAuthMessage(
                    fixture: fixture,
                    atemId: "local-test-atem-\(index)"
                )
            )
        }
        let results = try EventLoopFuture.whenAllSucceed(connections, on: group.next()).wait()

        XCTAssertEqual(results.map(\.0), Array(repeating: "authenticated:local_proof", count: 5))
        XCTAssertEqual(fixture.server.getConnectedClientsCount(), 5)
        results.forEach { _ = $0.1.close() }
    }

    func testPairedLANClientAuthenticatesDirectlyWithoutRelay() throws {
        guard let lanAddress = Self.nonLoopbackIPv4Address() else {
            throw XCTSkip("No non-loopback IPv4 interface is available")
        }
        let fixture = try DirectServerFixture(host: "0.0.0.0")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let atemId = "office-atem"
        let session = fixture.sessions.create(hostname: "office", atemId: atemId)
        let future = connect(
            host: lanAddress,
            fixture: fixture,
            group: group,
            authMessage: { challengeData in
                XCTAssertEqual(challengeData["transport"], "lan")
                let challenge = challengeData["challenge"] ?? ""
                let astationId = challengeData["astation_id"] ?? ""
                let proof = DeviceAuthentication.proof(
                    token: session.token,
                    challenge: challenge,
                    astationId: astationId,
                    atemId: atemId,
                    sessionId: session.id
                )
                return .statusUpdate(status: "auth", data: [
                    "session_id": session.id,
                    "atem_id": atemId,
                    "proof": proof
                ])
            }
        )
        let (result, socket) = try future.wait()

        XCTAssertEqual(result, "authenticated:session_proof")
        _ = socket.close()
    }

    func testUnauthenticatedClientDoesNotReceiveApplicationBroadcast() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let result = group.next().makePromise(of: (Bool, WebSocket).self)
        var challengeReceived = false
        var broadcastReceived = false
        let connection = WebSocket.connect(
            to: "ws://127.0.0.1:\(fixture.port)/ws",
            on: group
        ) { socket in
            socket.onText { socket, text in
                guard let data = text.data(using: .utf8),
                      let message = try? JSONDecoder().decode(AstationMessage.self, from: data) else {
                    return
                }
                switch message {
                case .statusUpdate(let status, _) where status == "auth_required" && !challengeReceived:
                    challengeReceived = true
                    fixture.server.broadcastMessage(.videoToggle(active: true))
                    socket.eventLoop.scheduleTask(in: .milliseconds(100)) {
                        result.succeed((broadcastReceived, socket))
                    }
                case .videoToggle:
                    broadcastReceived = true
                default:
                    break
                }
            }
        }
        connection.cascadeFailure(to: result)

        let (received, socket) = try result.futureResult.wait()
        XCTAssertFalse(received)
        _ = socket.close()
    }

    private func connect(
        host: String,
        fixture: DirectServerFixture,
        group: EventLoopGroup,
        authMessage: @escaping ([String: String]) -> AstationMessage
    ) -> EventLoopFuture<(String, WebSocket)> {
        let result = group.next().makePromise(of: (String, WebSocket).self)
        let connection = WebSocket.connect(
            to: "ws://\(host):\(fixture.port)/ws",
            on: group
        ) { socket in
            socket.onText { socket, text in
                guard let data = text.data(using: .utf8),
                      let message = try? JSONDecoder().decode(AstationMessage.self, from: data) else {
                    return
                }
                switch message {
                case .statusUpdate(let status, let data) where status == "auth_required":
                    let response = authMessage(data)
                    guard let encoded = try? JSONEncoder().encode(response),
                          let responseText = String(data: encoded, encoding: .utf8) else {
                        return result.fail(DirectTestFailure.encodingFailed)
                    }
                    socket.send(responseText)
                case .statusUpdate(let status, let data) where status == "auth":
                    result.succeed(("authenticated:\(data["method"] ?? "unknown")", socket))
                case .statusUpdate(let status, let data) where status == "authenticated":
                    result.succeed(("authenticated:\(data["method"] ?? "unknown")", socket))
                case .statusUpdate(let status, let data) where status == "error":
                    result.succeed(("error:\(data["message"] ?? "unknown")", socket))
                default:
                    break
                }
            }
        }
        connection.cascadeFailure(to: result)
        return result.futureResult
    }

    private func loopbackAuthMessage(
        fixture: DirectServerFixture,
        atemId: String
    ) -> ([String: String]) -> AstationMessage {
        { challengeData in
            XCTAssertEqual(challengeData["transport"], "loopback")
            let challenge = challengeData["challenge"] ?? ""
            let astationId = challengeData["astation_id"] ?? ""
            let proof = DeviceAuthentication.proof(
                token: fixture.bootstrap.token,
                challenge: challenge,
                astationId: astationId,
                atemId: atemId,
                sessionId: "local"
            )
            return .statusUpdate(status: "auth", data: [
                "method": "local_proof",
                "atem_id": atemId,
                "hostname": "test-mac",
                "proof": proof
            ])
        }
    }

    private static func nonLoopbackIPv4Address() -> String? {
        Host.current().addresses.first { address in
            address.split(separator: ".").count == 4 && !address.hasPrefix("127.")
        }
    }
}

private final class DirectServerFixture {
    let directory: URL
    let sessions: SessionStore
    let bootstrap: LocalBootstrapStore
    let server: AstationWebSocketServer
    private var stopped = false

    init(host: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationDirectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        bootstrap = try LocalBootstrapStore(directory: directory)
        let hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions)
        server = AstationWebSocketServer(
            hubManager: hub,
            sessionStore: sessions,
            localBootstrapStore: bootstrap
        )
        try server.start(host: host, port: 0)
    }

    var port: Int {
        server.listeningPort ?? 0
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        shutdown()
    }
}

private enum DirectTestFailure: Error {
    case encodingFailed
}
