import Foundation
import XCTest
@testable import Menubar

private final class PairingTestSocket: IdentityRelaySocket, @unchecked Sendable {
    var closeCode = URLSessionWebSocketTask.CloseCode.invalid
    var closeReason: Data?
    var sent: [String] = []
    var cancelled = false
    var sendFailure: Error?
    var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode; closeReason = reason; cancelled = true
    }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message { sent.append(text) }
        completionHandler(sendFailure)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiver = completionHandler
    }
    func emit(_ text: String) { let callback = receiver; receiver = nil; callback?(.success(.string(text))) }
    func fail() { let callback = receiver; receiver = nil; callback?(.failure(URLError(.networkConnectionLost))) }
}

@MainActor
private final class PairingTestFixture {
    var context: NativePairingContext? = .init(accountGeneration: UUID(), account: "account-owner",
        station: "https://test-station.example", astationID: "astation-test")
    var sockets: [PairingTestSocket] = []
    var urls: [URL] = []
    var cancelledPeers: [NativePairingSession.Peer] = []
    var authorize: () async throws -> Void = {}
    var timeout: UInt64 = 600_000_000_000
    var introductionTimeout: UInt64 = 20_000_000_000
    lazy var pairing = NativePairingSession(context: { [unowned self] in self.context },
        authorize: { [unowned self] in try await self.authorize() }, makeSocket: { [unowned self] url in
            self.urls.append(url)
            let socket = PairingTestSocket(); self.sockets.append(socket); return socket
        }, deadline: timeout, introductionDeadline: introductionTimeout,
        changed: { _ in }, cancelPeer: { [unowned self] in self.cancelledPeers.append($0) })
    let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    func wrap(_ payload: String) -> String { #"{"atem_id":"device","connection_id":"11111111-2222-4333-8444-555555555555","payload":\#(payload)}"# }
    var hello: String { wrap(#"{"type":"pairing","data":{"v":1,"op":"hello","id":"\#(id)"}}"#) }
    func drain() async { for _ in 0..<15 { await Task.yield() } }
    func start() async throws -> PairingTestSocket {
        pairing.start(code: " abcd-2345 ")
        await drain()
        return try XCTUnwrap(sockets.last)
    }
}

@MainActor
final class NativePairingSessionTests: XCTestCase {
    func testAgoraBuildOnlyIntroductionHasNoCredentialsAndIsNotVerification() async throws {
        let f = PairingTestFixture()
        let socket = try await f.start()
        defer { f.pairing.cancel() }
        XCTAssertEqual(f.urls[0].absoluteString, "wss://test-station.example/ws?role=astation&code=ABCD-2345")
        XCTAssertTrue(socket.sent.isEmpty)
        socket.emit(#"{"type":"relayAuthChallenge","nonce":"untrusted"}"#)
        await f.drain()
        XCTAssertTrue(socket.sent.isEmpty)
        socket.emit(f.hello); await f.drain()
        let packet = try AtemSessionJSON.parse(Data(XCTUnwrap(socket.sent.first).utf8))["payload"]
        XCTAssertEqual(packet, .object(["type": .string("pairing"), "data": .object([
            "v": .integer(1), "op": .string("introduction"), "id": .string(f.id), "astation_id": .string("astation-test")])]))
        XCTAssertEqual(f.pairing.state, .waitingForVerification)
        XCTAssertFalse(socket.sent.joined().contains("credential"))
        XCTAssertFalse(socket.sent.joined().contains("account-owner"))
        XCTAssertTrue(f.cancelledPeers.isEmpty)
    }

    func testOnlyMatchingAuthenticatedAndDurablyVerifiedPeerCompletes() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        defer { f.pairing.cancel() }
        socket.emit(f.hello); await f.drain()
        XCTAssertFalse(f.pairing.beginAuthentication(code: "EFGH-6789", attemptID: f.id, device: "device", connection: "connection"))
        XCTAssertTrue(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"))
        XCTAssertFalse(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"), "Do not open concurrent owner prompts")
        socket.emit(f.hello); await f.drain()
        XCTAssertEqual(f.pairing.state, .confirmingPairing, "A retransmission cannot reset the owner prompt")
        let peer = NativePairingSession.Peer(device: "device", session: "session", connection: "connection")
        f.pairing.authenticated(peer, code: "ABCD-2345", attemptID: f.id)
        XCTAssertTrue(socket.cancelled)
        XCTAssertEqual(f.pairing.state, .verifying)
        f.pairing.verificationCompleted(.init(device: "device", session: "session", connection: "old-connection"))
        XCTAssertEqual(f.pairing.state, .verifying)
        f.pairing.verificationCompleted(peer)
        XCTAssertEqual(f.pairing.state, .verified)
        f.pairing.cancel()
        XCTAssertTrue(f.cancelledPeers.isEmpty, "Closing a completed dialog does not revoke a verified device")
    }

    func testDuplicateHelloIsIdempotentButCannotRetargetAttempt() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        socket.emit(f.hello); await f.drain()
        socket.emit(f.hello); await f.drain()
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertEqual(socket.sent[0], socket.sent[1])
        socket.emit(f.hello.replacingOccurrences(of: f.id, with: UUID().uuidString)); await f.drain()
        guard case .failed = f.pairing.state else { return XCTFail("Retargeted the attempt") }
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertTrue(socket.cancelled)
    }

    func testIntroductionTargetsOnlyTheOriginalHostConnection() async throws {
        for field in ["device", "11111111-2222-4333-8444-555555555555"] {
            let f = PairingTestFixture(); let socket = try await f.start()
            socket.emit(f.hello); await f.drain()
            let response = try AtemSessionJSON.parse(Data(XCTUnwrap(socket.sent.first).utf8))
            XCTAssertEqual(response["atem_id"]?.string, "device")
            XCTAssertEqual(response["connection_id"]?.string, "11111111-2222-4333-8444-555555555555")
            socket.emit(f.hello.replacingOccurrences(of: field, with: field == "device" ? "another-device" : UUID().uuidString))
            await f.drain()
            guard case .failed = f.pairing.state else { return XCTFail("Replacement host received an introduction") }
            XCTAssertEqual(socket.sent.count, 1)
        }
    }

    func testIdentityAuthenticationMustMatchAttemptCodeAndHost() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        defer { f.pairing.cancel() }
        socket.emit(f.hello); await f.drain()
        XCTAssertFalse(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: UUID().uuidString, device: "device", connection: "connection"))
        XCTAssertFalse(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "different-device", connection: "connection"))
        XCTAssertEqual(f.pairing.state, .waitingForVerification)
        XCTAssertTrue(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"))
        XCTAssertFalse(f.pairing.canFinishAuthentication(code: "ABCD-2345", attemptID: UUID().uuidString, device: "device", connection: "connection"))
        XCTAssertFalse(f.pairing.canFinishAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "replacement-connection"))
    }

    func testIdentityDisconnectEndsOnlyTheMatchingPendingCeremony() async throws {
        for verifying in [false, true] {
            let f = PairingTestFixture(); let socket = try await f.start()
            socket.emit(f.hello); await f.drain()
            XCTAssertTrue(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"))
            if verifying {
                f.pairing.authenticated(.init(device: "device", session: "session", connection: "connection"), code: "ABCD-2345", attemptID: f.id)
            }
            let pending = f.pairing.state
            f.pairing.identityConnectionClosed(device: "other-device", connection: "connection")
            f.pairing.identityConnectionClosed(device: "device", connection: "old-connection")
            XCTAssertEqual(f.pairing.state, pending)
            f.pairing.identityConnectionClosed(device: "device", connection: "connection")
            guard case .failed(let message) = f.pairing.state else { return XCTFail("Disconnected peer left pairing pending") }
            XCTAssertTrue(message.contains("atem pair verify"))
        }
    }

    func testDuplicateConnectKeepsTheSamePendingAttempt() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        defer { f.pairing.cancel() }
        f.pairing.start(code: "ABCD-2345"); await f.drain()
        XCTAssertEqual(f.sockets.count, 1)
        socket.emit(f.hello); await f.drain()
        f.pairing.start(code: "ABCD-2345"); await f.drain()
        XCTAssertEqual(f.sockets.count, 1)
        XCTAssertFalse(socket.cancelled)
        XCTAssertEqual(f.pairing.state, .waitingForVerification)
    }

    func testOpaqueRouteIdentifiersAreComparedAsBytes() {
        let route = PairingIntroductionFrame.Route(device: "device-\u{00e9}", connection: "connection")
        XCTAssertFalse(route.matches(device: "device-e\u{0301}"))
        XCTAssertNotEqual(route, .init(device: "device-e\u{0301}", connection: "connection"))
    }

    func testChangingAccountClearsCompletedProgressWithoutRevokingTheDevice() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        socket.emit(f.hello); await f.drain()
        XCTAssertTrue(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"))
        let peer = NativePairingSession.Peer(device: "device", session: "session", connection: "connection")
        f.pairing.authenticated(peer, code: "ABCD-2345", attemptID: f.id)
        f.pairing.verificationCompleted(peer)
        f.context = nil; f.pairing.contextChanged()
        XCTAssertEqual(f.pairing.state, .idle)
        XCTAssertTrue(f.cancelledPeers.isEmpty)
    }

    func testAmbiguousOrInvalidRelayWrappersAreRejected() {
        let f = PairingTestFixture()
        for text in [f.hello.replacingOccurrences(of: "\"atem_id\":\"device\"", with: "\"atem_id\":\"device\",\"atem_id\":\"other\""),
                     f.hello.replacingOccurrences(of: "11111111-2222-4333-8444-555555555555", with: "not-a-connection"),
                     f.hello.replacingOccurrences(of: "\"payload\":", with: "\"extra\":1,\"payload\":"),
                     #"{"type":"pairing","data":{"v":1,"op":"hello","id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}"#] {
            XCTAssertThrowsError(try PairingIntroductionFrame.parse(Data(text.utf8)))
        }
    }

    func testSignInAndValidCodeAreRequiredBeforeOpeningSocket() async throws {
        let f = PairingTestFixture()
        f.context = nil
        f.pairing.start(code: "ABCD-2345"); await f.drain()
        XCTAssertEqual(f.pairing.state, .failed("Sign in to Agora.Build before pairing Atem."))
        XCTAssertTrue(f.sockets.isEmpty)
        f.pairing.start(code: "not-a-code"); await f.drain()
        XCTAssertTrue(f.sockets.isEmpty)
    }

    func testDelayedAuthorizationIsFencedByAccountChange() async throws {
        let f = PairingTestFixture()
        var continuation: CheckedContinuation<Void, Never>?
        f.authorize = { await withCheckedContinuation { continuation = $0 } }
        f.pairing.start(code: "ABCD-2345"); await f.drain()
        XCTAssertNotNil(continuation)
        f.context = .init(accountGeneration: UUID(), account: "another-owner",
            station: "https://test-station.example", astationID: "astation-test")
        continuation?.resume(); await f.drain()
        XCTAssertTrue(f.sockets.isEmpty)
        guard case .failed = f.pairing.state else { return XCTFail("Old account opened pairing") }
    }

    func testCancelledAuthorizationCannotOpenSocketOnLateCompletion() async throws {
        let f = PairingTestFixture()
        var continuation: CheckedContinuation<Void, Never>?
        f.authorize = { await withCheckedContinuation { continuation = $0 } }
        f.pairing.start(code: "ABCD-2345"); await f.drain()
        f.pairing.cancel()
        continuation?.resume(); await f.drain()
        XCTAssertTrue(f.sockets.isEmpty)
        XCTAssertEqual(f.pairing.state, .cancelled)
    }

    func testQueuedOldSocketFrameCannotAffectNewAttempt() async throws {
        let f = PairingTestFixture(); let old = try await f.start()
        let queued = try XCTUnwrap(old.receiver)
        f.pairing.start(code: "EFGH-6789"); await f.drain()
        let next = try XCTUnwrap(f.sockets.last)
        XCTAssertTrue(old.cancelled)
        queued(.success(.string(f.hello))); await f.drain()
        XCTAssertTrue(next.sent.isEmpty)
        XCTAssertEqual(f.pairing.state, .waitingForHost)
        f.pairing.cancel()
    }

    func testRelayChangeFencesQueuedHello() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        f.context = .init(accountGeneration: UUID(), account: "account-owner",
            station: "https://second-station.example", astationID: "astation-test")
        socket.emit(f.hello); await f.drain()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(socket.cancelled)
        guard case .failed = f.pairing.state else { return XCTFail("Old Station sent an introduction") }
    }

    func testDisconnectBeforeIntroductionIsVisibleButHostHandoffIsNotSuccess() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        socket.fail(); await f.drain()
        guard case .failed = f.pairing.state else { return XCTFail("Silent disconnect") }
        let next = try await f.start()
        next.emit(f.hello); await f.drain()
        next.fail(); await f.drain()
        XCTAssertEqual(f.pairing.state, .waitingForVerification)
        f.pairing.cancel()
    }

    func testLegacyAndUnknownVersionFailWithoutCredentialFallback() async throws {
        for text in [#"{"type":"credentialSync","data":{"access_token":"never-use-this"}}"#,
                     #"{"type":"pairing","data":{"v":2,"op":"hello","id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}"#] {
            let f = PairingTestFixture(); let socket = try await f.start()
            socket.emit(f.wrap(text)); await f.drain()
            guard case .failed(let message) = f.pairing.state else { return XCTFail("Unsupported peer admitted") }
            XCTAssertTrue(message.contains("Upgrade Atem"))
            XCTAssertTrue(socket.sent.isEmpty)
        }
    }

    func testMalformedOrAmbiguousPacketsCannotReachIntroduction() {
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for version in ["1.0", "1e0", "true", "null", "\"1\""] {
            XCTAssertThrowsError(try PairingIntroductionFrame.parse(Data(PairingTestFixture().wrap("{\"type\":\"pairing\",\"data\":{\"v\":\(version),\"op\":\"hello\",\"id\":\"\(id)\"}}").utf8)))
        }
        for text in ["{\"type\":\"pairing\",\"data\":{\"v\":1,\"v\":1,\"op\":\"hello\",\"id\":\"\(id)\"}}",
                     "{\"type\":\"pairing\",\"data\":{\"v\":1,\"op\":\"hello\",\"id\":\"\(id)\",\"access_token\":\"no\"}}",
                     String(repeating: " ", count: 4097)] {
            XCTAssertThrowsError(try PairingIntroductionFrame.parse(Data(PairingTestFixture().wrap(text).utf8)))
        }
    }

    func testExpiryAndSendFailuresAreActionable() async throws {
        let f = PairingTestFixture(); f.timeout = 10_000_000
        _ = try await f.start()
        try await Task.sleep(nanoseconds: 40_000_000)
        guard case .failed(let message) = f.pairing.state else { return XCTFail("Pairing never expired") }
        XCTAssertTrue(message.contains("expired"))
        let g = PairingTestFixture(); let socket = try await g.start()
        socket.sendFailure = URLError(.networkConnectionLost)
        socket.emit(g.hello); await g.drain()
        guard case .failed = g.pairing.state else { return XCTFail("Silent send failure") }
        XCTAssertTrue(socket.cancelled)
    }

    func testSilentLegacyHostDoesNotLeaveTheUserWaitingIndefinitely() async throws {
        let f = PairingTestFixture(); f.introductionTimeout = 10_000_000
        let socket = try await f.start()
        try await Task.sleep(nanoseconds: 40_000_000)
        guard case .failed(let message) = f.pairing.state else { return XCTFail("Silent host left pairing pending") }
        XCTAssertTrue(message.contains("Upgrade Atem"))
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(socket.cancelled)
    }

    func testAbortedVerificationCancelsOnlyItsCurrentPendingCeremony() async throws {
        let f = PairingTestFixture(); let socket = try await f.start()
        socket.emit(f.hello); await f.drain()
        XCTAssertTrue(f.pairing.beginAuthentication(code: "ABCD-2345", attemptID: f.id, device: "device", connection: "connection"))
        let peer = NativePairingSession.Peer(device: "device", session: "session", connection: "connection")
        f.pairing.authenticated(peer, code: "ABCD-2345", attemptID: f.id)
        f.pairing.verificationFailed(.init(device: "device", session: "session", connection: "old-connection"))
        XCTAssertEqual(f.pairing.state, .verifying)
        f.pairing.verificationFailed(peer)
        XCTAssertEqual(f.cancelledPeers, [peer])
        guard case .failed(let message) = f.pairing.state else { return XCTFail("Aborted verification still spinning") }
        XCTAssertTrue(message.contains("atem pair verify"))
    }
}
