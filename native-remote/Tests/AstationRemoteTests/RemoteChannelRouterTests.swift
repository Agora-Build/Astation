import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class RoutedCore: RemoteChannelCore {
    let acceptDeadline: UInt64? = 10_000
    var isClosed = false
    var frames: [Data] = []
    var finishes = 0
    var receiveError: Error?
    func start(now: UInt64) throws -> Data { Data(#"{"ch":"atem-ch1","op":"init"}"#.utf8) }
    func accept(_ frame: Data, now: UInt64) throws -> SignRequest {
        frames.append(frame)
        return SignRequest(keyId: "key", purpose: .channel, freshConfirmation: false,
            label: "atem-ch1-client", input: Data("proof".utf8), bodyJson: nil)
    }
    func finish(_ signature: Data, now: UInt64) throws -> Data {
        finishes += 1
        return Data(#"{"ch":"atem-ch1","op":"finish"}"#.utf8)
    }
    func welcome(_ frame: Data, now: UInt64) throws -> WelcomeInfo {
        frames.append(frame)
        return WelcomeInfo(principal: "device-a", clientKind: "native", permissions: ["view", "control"], revision: 9,
            features: [], accountId: "account-a", atemDeviceId: "host-a", hostTrustGen: 3,
            attachmentGen: "attachment-a", controllerSession: "controller-a", runtimeGen: "runtime-a",
            authorizationMsLeft: 60_000, serverTime: 0, head: LogHead(seq: 1, hash: "head"),
            pendingRecovery: [], channelId: "channel-a", scopeJson: nil, json: "{}")
    }
    func receive(_ frame: Data, now: UInt64) throws -> [ClientEvent] {
        frames.append(frame)
        if let receiveError { throw receiveError }
        return []
    }
    func perform(_ operation: RemoteAgentOperation, now: UInt64) throws -> Outgoing {
        Outgoing(id: "request", frame: Data(#"{"ch":"atem-ch1","op":"rec","ct":"ciphertext"}"#.utf8))
    }
    func disconnect() { isClosed = true }
}

@MainActor
private final class RoutingHarness {
    let generation = UUID()
    var writes: [Data] = []
    var refuseWrites = false
    lazy var router = RemoteChannelRouter(generation: generation, transport: .relay) { [unowned self] bytes in
        if refuseWrites { throw RemoteChannelWriteError.busy }
        writes.append(bytes)
    }
    func open(core: RoutedCore? = nil,
        sign: @escaping (SignRequest) async throws -> Data = { _ in Data("signature".utf8) }) throws -> RemoteAgentChannel {
        let core = core ?? RoutedCore()
        return try router.open(make: { route, send, close, observe in
            RemoteAgentChannel(route: route, core: core, clock: { 100 }, automaticTimer: false,
                sign: sign, send: send, close: close, observe: observe)
        }, observe: { _ in })
    }
    func frame(_ bytes: String = #"{"ch":"atem-ch1","op":"accept"}"#, to channel: RemoteAgentChannel,
        generation: UUID? = nil) throws {
        router.receive(try RemoteChannelEnvelope.frame(Data(bytes.utf8), route: channel.route), generation: generation ?? self.generation)
    }
    func welcome(_ channel: RemoteAgentChannel) async throws {
        try frame(to: channel)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(channel.phase, .awaitingWelcome)
        try frame(to: channel)
        XCTAssertEqual(channel.phase, .ready)
    }
}

final class RemoteChannelRouterTests: XCTestCase {
    func testReaderPreservesOriginalFrameIncludingWhitespaceNumbersAndEscapedDelimiters() throws {
        let original = #"{ "ch" : "atem-ch1", "n": 9007199254740991, "f": 3e0, "s":"}\\\"[,", "items":[{}, [1,2]] }"#
        let envelope = Data("{\"type\":\"channel\",\"channel\":\"c_1\",\"event\":\"frame\",\"frame\":\(original)}".utf8)
        XCTAssertEqual(try RemoteChannelEnvelope.readHost(envelope), .frame(handle: "c_1", bytes: Data(original.utf8)))
    }

    func testReaderRefusesAmbiguousRoutingFieldsAndMalformedShapes() {
        for input in [
            #"{"type":"channel","event":"frame","channel":"a","channel":"b","frame":{}}"#,
            #"{"type":"channel","event":"frame","channel":"a","frame":{},"identity":"manager"}"#,
            #"{"type":"channel","event":"frame","channel":"a","frame":[]}"#,
            #"{"type":"channel","event":"open","channel":"a","transport":"relay"}"#,
            #"{"type":"channel","event":"close","channel":"a","reason":"BAD"}"#,
            #"{"type":"channel","event":"close","channel":"a","reason":null}"#,
            #"{"type":"channel","event":"close","channel":"a/other"}"#,
            #"{"type":"channel","event":"close","channel":"a"}{}"#,
            #"{"type":"channel","event":"close","channel":"a","reason":""}"#
        ] { XCTAssertThrowsError(try RemoteChannelEnvelope.readHost(Data(input.utf8)), input) }
    }

    func testMaximumRecordAndExactOuterBoundPassButOneByteOverIsScopedFromHeaderOnly() throws {
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: String(repeating: "a", count: 64))
        let frame = Data("{\"ch\":\"atem-ch1\",\"op\":\"rec\",\"ct\":\"\(String(repeating: "x", count: 1_398_123))\"}".utf8)
        var envelope = try RemoteChannelEnvelope.frame(frame, route: route)
        XCTAssertEqual(envelope.count, 1_398_279)
        envelope.append(Data(repeating: 32, count: RemoteChannelEnvelope.maximumBytes - envelope.count))
        XCTAssertEqual(try RemoteChannelEnvelope.readHost(envelope), .frame(handle: route.handle, bytes: frame))
        envelope.append(32)
        XCTAssertThrowsError(try RemoteChannelEnvelope.readHost(envelope)) {
            XCTAssertEqual(($0 as? RemoteChannelReadError)?.handle, route.handle)
            XCTAssertEqual(($0 as? RemoteChannelReadError)?.reason, .tooLarge)
        }
        let lateHandle = Data(("{\"type\":\"channel\",\"frame\":{\"ct\":\"" + String(repeating: "x", count: RemoteChannelEnvelope.maximumBytes) + "\"},\"channel\":\"a\"}").utf8)
        XCTAssertThrowsError(try RemoteChannelEnvelope.readHost(lateHandle)) {
            XCTAssertNil(($0 as? RemoteChannelReadError)?.handle)
        }
    }

    @MainActor
    func testDemultiplexingKeepsBytesAndPeerCloseNeverAnswersOrAffectsAnotherChannel() async throws {
        let h = RoutingHarness(), first = RoutedCore(), second = RoutedCore()
        let a = try h.open(core: first), b = try h.open(core: second)
        try await h.welcome(a); try await h.welcome(b)
        let raw = #"{ "ch":"atem-ch1", "op":"rec", "ct":"A\\\"}B" }"#
        try h.frame(raw, to: a)
        XCTAssertEqual(first.frames.last, Data(raw.utf8))
        XCTAssertEqual(second.frames.count, 2)
        let writes = h.writes.count
        let close = RemoteChannelEnvelope.close(route: a.route)
        h.router.receive(close, generation: h.generation)
        h.router.receive(close, generation: h.generation)
        XCTAssertEqual(h.writes.count, writes)
        XCTAssertEqual(a.phase, .closed)
        XCTAssertEqual(b.phase, .ready)
        XCTAssertEqual(h.router.count, 1)
        XCTAssertEqual(try b.perform(.list), "request")
        h.router.linkLost()
    }

    @MainActor
    func testMalformedAndOversizedEnvelopesCloseOnlyTheirKnownChannel() async throws {
        for oversized in [false, true] {
            let h = RoutingHarness()
            let a = try h.open(), b = try h.open()
            try await h.welcome(a); try await h.welcome(b)
            let prefix = "{\"type\":\"channel\",\"channel\":\"\(a.route.handle)\",\"event\":\"frame\",\"frame\":{}"
            let input = oversized ? prefix + "}" + String(repeating: " ", count: RemoteChannelEnvelope.maximumBytes) : prefix + ",\"extra\":true}"
            h.router.receive(Data(input.utf8), generation: h.generation)
            XCTAssertEqual(a.phase, .closed)
            XCTAssertEqual(b.phase, .ready)
            XCTAssertEqual(h.router.count, 1)
            let close = try JSONSerialization.jsonObject(with: XCTUnwrap(h.writes.last)) as? [String: Any]
            XCTAssertEqual(close?["reason"] as? String, oversized ? "too_large" : "malformed")
            h.router.linkLost()
        }
    }

    @MainActor
    func testReplacedLinkAndDelayedSigningCannotSendOnTheNewGeneration() async throws {
        let h = RoutingHarness(), core = RoutedCore()
        var continuation: CheckedContinuation<Data, Error>?
        let channel = try h.open(core: core, sign: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        try h.frame(to: channel, generation: UUID())
        XCTAssertTrue(core.frames.isEmpty)
        try h.frame(to: channel)
        for _ in 0..<10 { await Task.yield() }
        let writes = h.writes.count
        h.router.linkLost()
        try XCTUnwrap(continuation).resume(returning: Data("late".utf8))
        for _ in 0..<10 { await Task.yield() }
        try h.frame(to: channel)
        XCTAssertEqual(channel.phase, .closed)
        XCTAssertEqual(core.finishes, 0)
        XCTAssertEqual(h.writes.count, writes)
        XCTAssertEqual(h.router.count, 0)
        XCTAssertThrowsError(try h.open())
    }

    @MainActor
    func testOpenHandshakeCapacityIsReleasedOnlyAfterWelcome() async throws {
        let h = RoutingHarness()
        var channels: [RemoteAgentChannel] = []
        for _ in 0..<16 { channels.append(try h.open()) }
        let before = h.writes.count
        XCTAssertThrowsError(try h.open())
        XCTAssertEqual(h.writes.count, before)
        try await h.welcome(channels[0])
        channels.append(try h.open())
        XCTAssertEqual(h.router.count, 17)
        h.router.linkLost()
        XCTAssertTrue(channels.allSatisfy { $0.phase == .closed })
    }

    @MainActor
    func testCoreFailureAndOutboundBackpressureDoNotCloseOtherChannelsOrReplayOperations() async throws {
        let h = RoutingHarness(), core = RoutedCore()
        let a = try h.open(core: core), b = try h.open()
        try await h.welcome(a); try await h.welcome(b)
        core.receiveError = RemoteChannelError.invalidInput
        try h.frame(to: a)
        XCTAssertEqual(a.phase, .closed)
        XCTAssertEqual(b.phase, .ready)
        h.refuseWrites = true
        XCTAssertThrowsError(try b.perform(.prompt(session: "session-a", request: "durable-request", text: "once")))
        XCTAssertEqual(b.phase, .closed)
        XCTAssertEqual(h.router.writer.pendingCloseCount, 1)
        h.refuseWrites = false
        let before = h.writes.count
        h.router.writer.flush()
        XCTAssertEqual(h.writes.count, before + 1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(h.writes.last)) as? [String: String],
            ["type": "channel", "event": "close", "channel": b.route.handle, "reason": "busy"])
    }
}
