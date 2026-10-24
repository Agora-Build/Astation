import Foundation
import XCTest
@testable import AstationRemote

@MainActor
final class RemoteSocketQueueTests: XCTestCase {
    func testQueuePreservesOrderAndRefusesWritesBeforeExceedingItsByteBound() async throws {
        var writes: [Data] = [], completions: [(Error?) -> Void] = []
        let queue = RemoteSocketQueue(write: { writes.append($0); completions.append($1) }, failed: { _ in XCTFail() })
        let one = Data(repeating: 1, count: 2_097_152), two = Data(repeating: 2, count: 2_097_152)
        try queue.enqueue(one); try queue.enqueue(two)
        XCTAssertEqual(writes, [one])
        XCTAssertThrowsError(try queue.enqueue(Data([3])))
        completions[0](nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(writes, [one, two])
        completions[1](nil)
        for _ in 0..<10 { await Task.yield() }
        try queue.enqueue(Data([3]))
        XCTAssertEqual(writes.last, Data([3]))
        queue.disconnect()
    }

    func testCloseDiscardsUnsentCommandsAndRunsAfterTheInflightWrite() async throws {
        var writes: [Data] = [], completions: [(Error?) -> Void] = []
        let queue = RemoteSocketQueue(write: { writes.append($0); completions.append($1) }, failed: { _ in XCTFail() })
        try queue.enqueue(Data([1])); try queue.enqueue(Data([2]))
        queue.finish(with: Data([9]))
        XCTAssertThrowsError(try queue.enqueue(Data([3])))
        completions[0](nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(writes, [Data([1]), Data([9])])
        completions[1](nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertThrowsError(try queue.enqueue(Data([4])))
    }

    func testFailedWriteNeverReplaysAndLateCompletionAfterDisconnectDoesNothing() async throws {
        var writes: [Data] = [], completions: [(Error?) -> Void] = [], failures = 0
        let queue = RemoteSocketQueue(write: { writes.append($0); completions.append($1) }, failed: { _ in failures += 1 })
        try queue.enqueue(Data([1])); try queue.enqueue(Data([2]))
        completions[0](RemoteChannelError.staleLink)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(failures, 1); XCTAssertEqual(writes, [Data([1])])
        completions[0](nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(writes, [Data([1])])
        XCTAssertThrowsError(try queue.enqueue(Data([3])))
    }

    func testRelayWrappingRetainsRawFrameBytesAndRejectsDuplicateRoutingKeys() throws {
        let raw = Data(#"{"type":"channel","event":"frame","channel":"a","frame":{"counter":1e3,"value":"\u0061"}}"#.utf8)
        let bytes = try RemoteRelayEnvelope.wrap(raw, host: "host-a", connection: "socket-a")
        let result = try RemoteRelayEnvelope(bytes)
        XCTAssertEqual(result.payload, raw)
        XCTAssertEqual(result.host, "host-a"); XCTAssertEqual(result.connection, "socket-a")
        XCTAssertThrowsError(try RemoteRelayEnvelope(Data(#"{"atem_id":"a","atem_id":"b","connection_id":"c","payload":{}}"#.utf8)))
    }

    func testIndependentClientRefusesInsecureNonlocalEndpointsAndCredentialsInURLs() {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try RemoteRelayClient(relayURL: URL(string: url)!, genesis: String(repeating: "a", count: 64),
                hostID: "host-a", accessToken: "account-token", observe: { _ in }))
        }
    }
}
