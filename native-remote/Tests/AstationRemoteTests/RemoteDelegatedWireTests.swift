import AtemClient
import Foundation
import XCTest

final class RemoteDelegatedWireTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "r9-vectors-station-calls",
            withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func wire(_ vector: [String: Any]) throws -> String {
        if let wire = vector["wire"] as? String { return wire }
        let fill = try XCTUnwrap(vector["wire_fill"] as? [String: Any])
        return try XCTUnwrap(fill["prefix"] as? String)
            + String(repeating: XCTUnwrap(fill["fill"] as? String), count: XCTUnwrap(fill["count"] as? Int))
            + XCTUnwrap(fill["suffix"] as? String)
    }

    func testPublishedStationCallsUseTheRealSwiftBindingsAndBuilders() throws {
        let vectors = try vectors()
        for vector in try XCTUnwrap(vectors["calls"] as? [[String: Any]]) {
            do {
                let wire = try wire(vector)
                if vector["direction"] as? String == "to_station" {
                    let call = try relayDecodeToStation(message: wire)
                    let rebuilt: String
                    switch call {
                    case .controlSync(let id, let origin, let feed, let after):
                        rebuilt = try relayControlSync(requestId: id, origin: origin, feedId: feed, after: after)
                    case .membershipFetch(let after): rebuilt = try relayMembershipFetch(after: after)
                    case .controlAck(let ack): rebuilt = try relayControlAck(ack: ack)
                    }
                    XCTAssertEqual(try canonicalJson(json: rebuilt), try canonicalJson(json: wire))
                } else {
                    let message = try relayDecodeToHost(message: wire)
                    let rebuilt: String
                    switch message {
                    case .controlSyncResult(let id, let origin, let feed, let after, let head, let time, let records):
                        if records.contains(where: { (try? parseControlRecord(recordJson: $0.recordJson)) == nil }) {
                            XCTAssertThrowsError(try relayControlSyncResult(requestId: id, origin: origin, feedId: feed,
                                after: after, head: head, stationTime: time, records: records))
                            continue
                        }
                        rebuilt = try relayControlSyncResult(requestId: id, origin: origin, feedId: feed,
                            after: after, head: head, stationTime: time, records: records)
                    case .heads(let feeds, let membership): rebuilt = try relayHeads(feeds: feeds, membership: membership)
                    case .membershipFetchResult(let head, let entries): rebuilt = try relayMembershipFetchResult(head: head, entries: entries)
                    case .controlSyncRefused(let code): rebuilt = try relayControlSyncRefused(code: code)
                    case .membershipFetchRefused(let code): rebuilt = try relayMembershipFetchRefused(code: code)
                    case .controlAckRefused(let code): rebuilt = try relayControlAckRefused(code: code)
                    }
                    XCTAssertEqual(try canonicalJson(json: rebuilt), try canonicalJson(json: wire))
                }
            } catch { XCTFail("\(vector["name"] ?? "unknown vector"): \(error)") }
        }
    }

    func testStrictReadersRejectPublishedInvalidCallsAndKeepTheCompleteMessageBound() throws {
        let vectors = try vectors()
        for vector in try XCTUnwrap(vectors["invalid"] as? [[String: Any]]) {
            let wire = try wire(vector)
            if vector["reader"] as? String == "to_station" {
                XCTAssertThrowsError(try relayDecodeToStation(message: wire), "\(vector["name"] ?? "")")
            } else {
                XCTAssertThrowsError(try relayDecodeToHost(message: wire), "\(vector["name"] ?? "")")
            }
        }
        for vector in try XCTUnwrap(vectors["at_the_bound"] as? [[String: Any]]) {
            let wire = try wire(vector)
            XCTAssertEqual(wire.utf8.count, 262_144)
            _ = try relayDecodeToHost(message: wire)
        }
        XCTAssertEqual(controlWhyCodes(), try XCTUnwrap(vectors["why_codes"] as? [String]))
    }

    func testDelayedOldRepliesNeverAnswerAFreshCallAtTheSameCursor() throws {
        let vectors = try vectors()
        let codes: [String: RelaySyncVerdict] = ["answers": .answers, "request_id": .requestId,
            "origin": .origin, "feed_id": .feedId, "after": .after]
        for vector in try XCTUnwrap(vectors["matching"] as? [[String: Any]]) {
            let result = try XCTUnwrap(vector["result"] as? String)
            let calls = try XCTUnwrap(vector["calls"] as? [String])
            let verdicts = try XCTUnwrap(vector["verdicts"] as? [String])
            XCTAssertEqual(calls.count, verdicts.count)
            for (call, verdict) in zip(calls, verdicts) {
                XCTAssertEqual(try relayControlSyncAnswers(call: call, result: result), codes[verdict])
            }
        }
    }
}
