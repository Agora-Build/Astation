import Foundation
import AstationRemote
import NIO
import WebSocketKit
import XCTest
@testable import Menubar

final class DirectConnectionTests: XCTestCase {
    @MainActor
    func testRelayOnlyMissingMembershipDoesNotCloseAuthenticatedLoopbackSocket() async throws {
        let hub = try TerminalHubFixture(relayOnly: true)
        let fixture = try DirectServerFixture(host: "127.0.0.1", hub: hub.hub)
        defer { fixture.shutdown() }
        hub.hub.disconnectDirectClient = { fixture.server.disconnectClientForSessionReset($0) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let (result, socket) = try await connect(host: "127.0.0.1", fixture: fixture, group: group,
            authMessage: loopbackAuthMessage(fixture: fixture, atemId: hub.deviceId)).get()
        defer { _ = socket.close() }
        XCTAssertEqual(result, "authenticated:local_proof")
        let closed = expectation(description: "Missing membership does not disconnect the local host")
        closed.isInverted = true
        socket.onClose.whenComplete { _ in closed.fulfill() }
        await hub.drain()
        await fulfillment(of: [closed], timeout: 0.15)

        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(fixture.server.getConnectedClientsCount(), 1)
        let client = try XCTUnwrap(hub.hub.connectedClients.first)
        XCTAssertEqual(hub.hub.remoteAccessBlockReason(for: client.id), .selectedRelayRequired)
        XCTAssertNil(hub.hub.sessionClient(for: client.id))
        XCTAssertTrue(hub.hub.supportedAtemClients.isEmpty)
        XCTAssertNotNil(fixture.sessions.get(sessionId: hub.session.id))
    }

    @MainActor
    func testLocalAPIIsOptInAuthenticatedAndRejectsBrowserRequests() async throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(fixture.port)/api/v1/status"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, disabled) = try await session.data(from: url)
        XCTAssertEqual((disabled as? HTTPURLResponse)?.statusCode, 404)
        let token = String(repeating: "ab", count: 32)
        let file = fixture.directory.appendingPathComponent("api-token")
        try Data(token.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        fixture.server.configureLocalControlAPI(LocalControlAPI(key: try LocalAPIKey(file: file.path),
            clients: { [:] }, inbox: ApprovalInbox(), records: { [] }))
        let (_, unauthorized) = try await session.data(from: url)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, authorized) = try await session.data(for: request)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil((authorized as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: String])?["api"], "v1")
        request.setValue("http://malicious.test", forHTTPHeaderField: "Origin")
        let (_, browser) = try await session.data(for: request)
        XCTAssertEqual((browser as? HTTPURLResponse)?.statusCode, 401)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, wrongContentType) = try await session.data(for: request)
        XCTAssertEqual((wrongContentType as? HTTPURLResponse)?.statusCode, 415)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(repeating: 32, count: LocalControlAPI.maximumBody + 1)
        let (_, oversized) = try await session.data(for: request)
        XCTAssertEqual((oversized as? HTTPURLResponse)?.statusCode, 413)
    }

    func testSessionResetClosesOnlySelectedAuthenticatedDirectSocket() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var firstID = ""
        let auth = loopbackAuthMessage(fixture: fixture, atemId: "reset-target")
        let (_, first) = try connect(host: "127.0.0.1", fixture: fixture, group: group, authMessage: {
            firstID = $0["clientId"] ?? ""
            return auth($0)
        }).wait()
        let (_, second) = try connect(host: "127.0.0.1", fixture: fixture, group: group,
            authMessage: loopbackAuthMessage(fixture: fixture, atemId: "unrelated-host")).wait()
        let closed = expectation(description: "Selected direct socket closes for recovery")
        first.onClose.whenComplete { _ in closed.fulfill() }
        fixture.server.disconnectClientForSessionReset(firstID)
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(second.isClosed == false)
        _ = second.close()
    }

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

    func testStationReconnectReauthenticatesSameLocalSocketAndFencesOldGeneration() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        try assertProxyReauthentication(fixture: fixture, host: "127.0.0.1",
            auth: loopbackAuthMessage(fixture: fixture, atemId: "proxy-host"))
    }

    func testStationReconnectReauthenticatesPairedLANSocketWithoutNewPairing() throws {
        guard let address = Self.nonLoopbackIPv4Address() else { throw XCTSkip("No LAN interface") }
        let fixture = try DirectServerFixture(host: "0.0.0.0")
        defer { fixture.shutdown() }
        let session = fixture.sessions.create(hostname: "LAN host", atemId: "proxy-host")
        try assertProxyReauthentication(fixture: fixture, host: address, auth: { fields in
            .statusUpdate(status: "auth", data: ["session_id": session.id, "atem_id": "proxy-host",
                "proof": DeviceAuthentication.proof(token: session.token, challenge: fields["challenge"] ?? "",
                    astationId: fields["astation_id"] ?? "", atemId: "proxy-host", sessionId: session.id)])
        })
    }

    func testProductionProxySocketReceivesMoreThanOneMiBFromRealWebSocket() async throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(fixture.port)/ws"))
        let socket = StationLocalProxy.socket(request: URLRequest(url: url))
        defer { socket.cancel(with: .goingAway, reason: nil) }
        XCTAssertEqual(socket.maximumMessageSize, RemoteChannelEnvelope.maximumBytes)
        socket.resume()
        guard case .string(let challenge) = try await socket.receive(),
              case .statusUpdate(_, let fields) = try AstationMessage.decodePacket(Data(challenge.utf8)) else {
            return XCTFail("Expected local authentication challenge")
        }
        let auth = loopbackAuthMessage(fixture: fixture, atemId: "large-proxy-frame")(fields)
        try await socket.send(.string(String(decoding: JSONEncoder().encode(auth), as: UTF8.self)))
        guard case .string(let reply) = try await socket.receive(),
              case .statusUpdate(let status, _) = try AstationMessage.decodePacket(Data(reply.utf8)),
              status == "auth" || status == "authenticated" else {
            return XCTFail("Expected authenticated socket")
        }
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: "large_1")
        let frame = try RemoteChannelEnvelope.frame(
            Data((#"{"ct":""# + String(repeating: "a", count: 1_100_000) + #""}"#).utf8), route: route)
        XCTAssertGreaterThan(frame.count, 1_048_576)
        let sent = expectation(description: "Large encrypted envelope written")
        fixture.server.sendChannel(frame, clientID: try XCTUnwrap(fields["clientId"])) { error in
            XCTAssertNil(error); sent.fulfill()
        }
        guard case .string(let received) = try await socket.receive() else { return XCTFail("Expected text envelope") }
        XCTAssertEqual(Data(received.utf8), frame)
        await fulfillment(of: [sent], timeout: 3)
    }

    func testLocalChannelTrackingIsBoundedAndCloseReleasesCapacity() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var clientID = ""
        let auth = loopbackAuthMessage(fixture: fixture, atemId: "bounded-channels")
        let (_, socket) = try connect(host: "127.0.0.1", fixture: fixture, group: group, authMessage: {
            clientID = $0["clientId"] ?? ""; return auth($0)
        }).wait()
        defer { _ = socket.close() }
        let opened = expectation(description: "Bounded channels opened")
        opened.expectedFulfillmentCount = AstationWebSocketServer.maximumChannelsPerClient
        for index in 0..<AstationWebSocketServer.maximumChannelsPerClient {
            let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: "bounded_\(index)")
            fixture.server.sendChannel(RemoteChannelEnvelope.open(route: route, transport: .direct), clientID: clientID) {
                XCTAssertNil($0); opened.fulfill()
            }
        }
        wait(for: [opened], timeout: 3)
        let overflow = try RemoteChannelRoute(linkGeneration: UUID(), handle: "overflow")
        let refused = expectation(description: "Extra channel refused")
        fixture.server.sendChannel(RemoteChannelEnvelope.open(route: overflow, transport: .direct), clientID: clientID) {
            XCTAssertEqual($0 as? RemoteChannelError, .notReady); refused.fulfill()
        }
        wait(for: [refused], timeout: 3)
        let released = expectation(description: "Close frees capacity on the same socket")
        let closing = try RemoteChannelRoute(linkGeneration: UUID(), handle: "bounded_0")
        fixture.server.sendChannel(RemoteChannelEnvelope.close(route: closing), clientID: clientID) { error in
            XCTAssertNil(error)
            fixture.server.sendChannel(RemoteChannelEnvelope.open(route: overflow, transport: .direct), clientID: clientID) {
                XCTAssertNil($0); released.fulfill()
            }
        }
        wait(for: [released], timeout: 3)
        XCTAssertFalse(socket.isClosed)
    }

    func testUnansweredProxyReauthenticationTimesOutWithoutClosingOtherLocalSocket() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var clientID = ""
        let auth = loopbackAuthMessage(fixture: fixture, atemId: "timeout-host")
        let (_, socket) = try connect(host: "127.0.0.1", fixture: fixture, group: group, authMessage: {
            clientID = $0["clientId"] ?? ""; return auth($0)
        }).wait()
        let (_, other) = try connect(host: "127.0.0.1", fixture: fixture, group: group,
            authMessage: loopbackAuthMessage(fixture: fixture, atemId: "unrelated-host")).wait()
        defer { _ = other.close(); _ = socket.close() }
        let closed = expectation(description: "Unanswered authentication expires")
        try socket.eventLoop.submit {
            socket.onText { _, _ in }
            socket.onClose.whenComplete { _ in closed.fulfill() }
        }.wait()
        let challenge = Data(#"{"type":"relay","op":"host_challenge","v":1}"#.utf8)
        fixture.server.sendStationProxy(challenge, clientID: clientID) { error in
            XCTAssertNil(error)
            fixture.server.sendStationProxy(challenge, clientID: clientID) {
                XCTAssertEqual($0 as? RemoteChannelError, .staleLink)
            }
        }
        wait(for: [closed], timeout: 12)
        XCTAssertFalse(other.isClosed)
    }

    private func assertProxyReauthentication(fixture: DirectServerFixture, host: String,
        auth: @escaping ([String: String]) -> AstationMessage) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        var firstID = "", nextID = ""
        let (_, socket) = try connect(host: host, fixture: fixture, group: group, authMessage: {
            firstID = $0["clientId"] ?? ""
            return auth($0)
        }).wait()
        let firstChallenge = expectation(description: "First proof challenge follows authentication")
        let retryChallenge = #"{"type":"relay","op":"host_challenge","v":1,"nonce":"after-suspension"}"#
        let receivedRetry = expectation(description: "Fresh proof challenge reaches the original local generation")
        let reauthenticated = expectation(description: "Fresh authentication on the same socket")
        let nextChallenge = expectation(description: "New generation gets its own challenge")
        let closedOldChannel = expectation(description: "Old channel closes before reauthentication")
        var sawOldClose = false
        try socket.eventLoop.submit { socket.onText { socket, text in
            if text == "first-proxy-challenge" { firstChallenge.fulfill(); return }
            if text == retryChallenge { XCTAssertFalse(sawOldClose); receivedRetry.fulfill(); return }
            if text == "next-proxy-challenge" { nextChallenge.fulfill(); return }
            if let fields = try? AtemSessionJSON.validatePacket(Data(text.utf8)), fields["type"]?.string == "channel",
               fields["channel"]?.string == "old_1", fields["event"]?.string == "close" {
                sawOldClose = true; closedOldChannel.fulfill(); return
            }
            guard let message = try? AstationMessage.decodePacket(Data(text.utf8)),
                  case .statusUpdate(let status, let fields) = message else { return }
            if status == "auth_required" {
                XCTAssertTrue(sawOldClose)
                nextID = fields["clientId"] ?? ""
                let response = try! JSONEncoder().encode(auth(fields))
                socket.send(String(decoding: response, as: UTF8.self))
            } else if status == "auth" || status == "authenticated" { reauthenticated.fulfill() }
        } }.wait()
        fixture.server.sendChannel(Data(#"{"type":"channel","event":"open","channel":"old_1","transport":"direct"}"#.utf8),
            clientID: firstID) { XCTAssertNil($0) }
        let challenge = Data(#"{"type":"relay","op":"host_challenge","v":1}"#.utf8)
        fixture.server.sendStationProxy(challenge, clientID: firstID) { error in
            XCTAssertNil(error)
            fixture.server.sendChannel(Data("first-proxy-challenge".utf8), clientID: firstID) { XCTAssertNil($0) }
        }
        wait(for: [firstChallenge], timeout: 3)
        fixture.server.sendStationProxy(Data(retryChallenge.utf8), clientID: firstID, retryChallenge: true) {
            XCTAssertNil($0)
        }
        wait(for: [receivedRetry], timeout: 3)
        XCTAssertTrue(nextID.isEmpty)
        fixture.server.sendStationProxy(challenge, clientID: firstID) { error in
            XCTAssertEqual(error as? RemoteChannelError, .staleLink)
        }
        wait(for: [closedOldChannel, reauthenticated], timeout: 3)
        XCTAssertNotEqual(nextID, firstID)
        XCTAssertFalse(nextID.isEmpty)
        XCTAssertFalse(socket.isClosed)
        let stale = expectation(description: "Old generation is fenced")
        fixture.server.sendChannel(Data("stale".utf8), clientID: firstID) { error in
            XCTAssertEqual(error as? RemoteChannelError, .staleLink); stale.fulfill()
        }
        fixture.server.sendStationProxy(challenge, clientID: nextID) { error in
            XCTAssertNil(error)
            fixture.server.sendChannel(Data("next-proxy-challenge".utf8), clientID: nextID) { XCTAssertNil($0) }
        }
        wait(for: [stale, nextChallenge], timeout: 3)
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

    func testRevokedDirectPairingRejectsTerminalTrafficInBothDirections() throws {
        for outbound in [false, true] {
            let fixture = try DirectServerFixture(host: "127.0.0.1")
            defer { fixture.shutdown() }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? group.syncShutdownGracefully() }
            var clientId = ""
            let authenticate = loopbackAuthMessage(fixture: fixture, atemId: "terminal-test")
            let (result, socket) = try connect(host: "127.0.0.1", fixture: fixture, group: group,
                authMessage: { data in
                    clientId = data["clientId"] ?? ""
                    return authenticate(data)
                }).wait()
            XCTAssertEqual(result, "authenticated:local_proof")
            XCTAssertFalse(clientId.isEmpty)
            let session = try XCTUnwrap(fixture.sessions.getAllActive().first)
            fixture.sessions.delete(sessionId: session.id)
            XCTAssertNil(fixture.sessions.get(sessionId: session.id))
            let closed = expectation(description: "Revoked terminal transport closes")
            socket.onClose.whenComplete { _ in closed.fulfill() }
            if outbound {
                fixture.server.sendMessageToClient(.terminal(.list), clientId: clientId)
            } else {
                socket.send(String(decoding: try JSONEncoder().encode(AstationMessage.terminal(.sessions([]))), as: UTF8.self))
            }
            wait(for: [closed], timeout: 2)
        }
    }

    func testPairingRemovalDisconnectsAuthenticatedDirectSocket() throws {
        let fixture = try DirectServerFixture(host: "127.0.0.1")
        defer { fixture.shutdown() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let (_, socket) = try connect(host: "127.0.0.1", fixture: fixture, group: group,
            authMessage: loopbackAuthMessage(fixture: fixture, atemId: "terminal-test")).wait()
        let session = try XCTUnwrap(fixture.sessions.getAllActive().first)
        let closed = expectation(description: "Removed pairing closes its direct socket")
        socket.onClose.whenComplete { _ in closed.fulfill() }
        fixture.server.disconnectClients(authenticatedWith: [session.id])
        wait(for: [closed], timeout: 2)
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

    init(host: String, hub: AstationHubManager? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstationDirectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessions = hub?.deviceSessionStore ?? SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        bootstrap = try LocalBootstrapStore(directory: directory)
        let hub = hub ?? AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions)
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
