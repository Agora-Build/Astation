import Foundation
import XCTest
@testable import AstationRemote

final class RemoteChannelWriterTests: XCTestCase {
    private let object = Data(#"{"t":"rec","n":0,"ct":"example"}"#.utf8)

    func testFrameEnvelopeBoundsUseReceivedBytesIncludingWrapper() throws {
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: String(repeating: "h", count: 64))
        let empty = Data("{}".utf8)
        let overhead = try RemoteChannelEnvelope.frame(empty, route: route).count - empty.count
        let frame = Data(("{" + String(repeating: " ", count: RemoteChannelEnvelope.maximumBytes - overhead - 2) + "}").utf8)
        XCTAssertEqual(try RemoteChannelEnvelope.frame(frame, route: route).count, RemoteChannelEnvelope.maximumBytes)
        XCTAssertThrowsError(try RemoteChannelEnvelope.frame(frame + Data(" ".utf8), route: route)) {
            XCTAssertEqual($0 as? RemoteChannelWriteError, .tooLarge)
        }
    }

    func testFrameBytesArePreservedIncludingWideIntegersAndUnicode() throws {
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: "handle")
        let frame = Data(#" { "host_trust_gen":18446744073709551615,"text":"\u00e9" } "#.utf8)
        let envelope = try RemoteChannelEnvelope.frame(frame, route: route)
        XCTAssertNotNil(envelope.range(of: frame))
        XCTAssertTrue(String(decoding: envelope, as: UTF8.self).contains("18446744073709551615"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
    }

    func testFrameCannotEscapeItsObjectOrInjectEnvelopeFields() throws {
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: "handle")
        for raw in ["[]", "null", "true", "\"text\"", "{} {}", "{},\"channel\":\"other\"", "{\"x\":}"] {
            XCTAssertThrowsError(try RemoteChannelEnvelope.frame(Data(raw.utf8), route: route), raw)
        }
        XCTAssertThrowsError(try RemoteChannelEnvelope.frame(Data([123, 34, 120, 34, 58, 34, 255, 34, 125]), route: route))
        for handle in ["", "bad\"", "bad\\", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try RemoteChannelRoute(linkGeneration: UUID(), handle: handle))
        }
    }

    @MainActor
    func testOpenPrecedesFramesAndClosedHandlesAreNeverReused() throws {
        for transport in [RemoteChannelTransport.direct, .relay] {
            var sent: [Data] = []
            let writer = RemoteChannelWriter(generation: UUID(), transport: transport) { sent.append($0) }
            let first = try writer.open()
            try writer.send(object, to: first)
            writer.close(first)
            let second = try writer.open()
            XCTAssertNotEqual(first.handle, second.handle)
            XCTAssertFalse(writer.contains(first))
            XCTAssertTrue(writer.contains(second))
            let packets = try sent.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            XCTAssertEqual(packets.compactMap { $0["event"] as? String }, ["open", "frame", "close", "open"])
            XCTAssertEqual(packets[0]["transport"] as? String, transport.rawValue)
            XCTAssertEqual(Set(packets[0].keys), ["type", "event", "channel", "transport"])
            XCTAssertEqual(Set(packets[1].keys), ["type", "event", "channel", "frame"])
        }
    }

    @MainActor
    func testOldGenerationCannotWriteOrCloseReplacementHandle() throws {
        var oldSent: [Data] = [], newSent: [Data] = []
        let old = RemoteChannelWriter(generation: UUID(), transport: .relay) { oldSent.append($0) }
        let oldRoute = try old.open()
        old.linkLost()
        let replacement = RemoteChannelWriter(generation: UUID(), transport: .relay) { newSent.append($0) }
        let newRoute = try replacement.open()
        XCTAssertEqual(oldRoute.handle, newRoute.handle)
        XCTAssertThrowsError(try replacement.send(object, to: oldRoute))
        XCTAssertThrowsError(try replacement.welcomed(oldRoute))
        replacement.close(oldRoute)
        replacement.peerClosed(oldRoute)
        XCTAssertTrue(replacement.contains(newRoute))
        XCTAssertEqual(newSent.count, 1)
        XCTAssertThrowsError(try old.open())
        XCTAssertThrowsError(try old.send(object, to: oldRoute))
        XCTAssertEqual(oldSent.count, 1)
    }

    @MainActor
    func testHandshakeAndChannelCountsAreBounded() throws {
        let writer = RemoteChannelWriter(generation: UUID(), transport: .direct) { _ in }
        for _ in 0..<16 { _ = try writer.open() }
        XCTAssertThrowsError(try writer.open()) { XCTAssertEqual($0 as? RemoteChannelWriteError, .busy) }
        let ready = RemoteChannelWriter(generation: UUID(), transport: .relay) { _ in }
        for _ in 0..<64 { try ready.welcomed(ready.open()) }
        XCTAssertThrowsError(try ready.open()) { XCTAssertEqual($0 as? RemoteChannelWriteError, .busy) }
        XCTAssertEqual(ready.count, 64)
    }

    @MainActor
    func testOversizeFrameClosesOnlyItsChannelBeforeForwarding() throws {
        var sent: [Data] = []
        let writer = RemoteChannelWriter(generation: UUID(), transport: .relay) { sent.append($0) }
        let first = try writer.open(), second = try writer.open()
        let tooLarge = Data(repeating: 32, count: RemoteChannelEnvelope.maximumBytes)
        XCTAssertThrowsError(try writer.send(tooLarge, to: first)) {
            XCTAssertEqual($0 as? RemoteChannelWriteError, .tooLarge)
        }
        XCTAssertFalse(writer.contains(first))
        XCTAssertTrue(writer.contains(second))
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent.allSatisfy { $0.count <= RemoteChannelEnvelope.maximumBytes })
        let close = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[2]) as? [String: Any])
        XCTAssertEqual(close["reason"] as? String, "too_large")
        try writer.send(object, to: second)
    }

    @MainActor
    func testFailedWritesAndPeerClosesDoNotLoopOrAffectOtherChannels() throws {
        var sent: [Data] = []
        var failNext = false
        let writer = RemoteChannelWriter(generation: UUID(), transport: .relay) {
            if failNext { failNext = false; throw RemoteChannelWriteError.busy }
            sent.append($0)
        }
        let first = try writer.open(), second = try writer.open()
        failNext = true
        XCTAssertThrowsError(try writer.send(object, to: first))
        XCTAssertFalse(writer.contains(first))
        XCTAssertTrue(writer.contains(second))
        let count = sent.count
        writer.close(first)
        writer.peerClosed(second)
        writer.peerClosed(second)
        writer.close(second)
        XCTAssertEqual(sent.count, count)
        XCTAssertEqual(writer.count, 0)
        failNext = true
        XCTAssertThrowsError(try writer.open())
        XCTAssertEqual(writer.count, 0)
    }

    @MainActor
    func testBlockedClosesStayBoundedAndFlushBeforeAnyNewOpen() throws {
        var blocked = false
        var sent: [Data] = []
        let writer = RemoteChannelWriter(generation: UUID(), transport: .relay) {
            if blocked { throw RemoteChannelWriteError.busy }
            sent.append($0)
        }
        var routes: [RemoteChannelRoute] = []
        for _ in 0..<64 {
            let route = try writer.open()
            try writer.welcomed(route)
            routes.append(route)
        }
        blocked = true
        for route in routes { writer.close(route); writer.close(route) }
        XCTAssertEqual(writer.count, 0)
        XCTAssertEqual(writer.pendingCloseCount, 64)
        XCTAssertThrowsError(try writer.open())
        writer.flush()
        XCTAssertEqual(writer.pendingCloseCount, 64)
        blocked = false
        let next = try writer.open()
        XCTAssertFalse(routes.contains(next))
        XCTAssertEqual(writer.pendingCloseCount, 0)
        let events = try sent.map { (try JSONSerialization.jsonObject(with: $0) as? [String: Any])?["event"] as? String }
        XCTAssertEqual(Array(events[64..<128]), Array(repeating: "close", count: 64))
        XCTAssertEqual(events.last, "open")
    }

    @MainActor
    func testPeerCloseAndLinkLossCancelQueuedClosesWithoutReply() throws {
        var blocked = false
        var sent: [Data] = []
        let writer = RemoteChannelWriter(generation: UUID(), transport: .direct) {
            if blocked { throw RemoteChannelWriteError.busy }
            sent.append($0)
        }
        let first = try writer.open(), second = try writer.open()
        blocked = true
        writer.close(first); writer.close(second)
        XCTAssertEqual(writer.pendingCloseCount, 2)
        writer.peerClosed(first)
        XCTAssertEqual(writer.pendingCloseCount, 1)
        writer.linkLost()
        blocked = false
        writer.flush()
        XCTAssertEqual(writer.pendingCloseCount, 0)
        XCTAssertEqual(sent.count, 2)
    }

    @MainActor
    func testReentrantLinkLossAndCloseCannotReviveOrDoubleClose() throws {
        var writer: RemoteChannelWriter!
        var sent: [Data] = []
        var onWrite: (() -> Void)?
        writer = RemoteChannelWriter(generation: UUID(), transport: .direct) {
            sent.append($0)
            onWrite?()
        }
        let route = try writer.open()
        onWrite = { writer.close(route) }
        writer.close(route)
        XCTAssertEqual(sent.count, 2)
        onWrite = { writer.linkLost() }
        XCTAssertThrowsError(try writer.open())
        XCTAssertEqual(writer.count, 0)
        XCTAssertFalse(writer.isConnected)
    }

    @MainActor
    func testLinkLossWhileFlushingPreventsTheNextOpen() throws {
        var writer: RemoteChannelWriter!
        var blocked = false
        var loseLink = false
        var sent: [Data] = []
        writer = RemoteChannelWriter(generation: UUID(), transport: .relay) {
            if blocked { throw RemoteChannelWriteError.busy }
            sent.append($0)
            if loseLink { writer.linkLost() }
        }
        let route = try writer.open()
        blocked = true
        writer.close(route)
        blocked = false; loseLink = true
        XCTAssertThrowsError(try writer.open()) { XCTAssertEqual($0 as? RemoteChannelError, .staleLink) }
        XCTAssertEqual(sent.count, 2, "Only the old open and queued close reached the sink")
        XCTAssertEqual(writer.count, 0)
    }
}
