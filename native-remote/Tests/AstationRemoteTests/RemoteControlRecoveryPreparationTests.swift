import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

final class RemoteControlRecoveryPreparationTests: XCTestCase {
    private let anchorHash = String(repeating: "a", count: 64)
    private let origin = "https://station-dev.agora.build"

    private func value(origin: String? = nil) -> [String: Any] {
        ["version": 1, "account_id": "account-a", "genesis_hash": anchorHash,
         "origin": origin ?? self.origin, "generation": String(Int64.max),
         "plan_id": "165ec51c-9b59-433a-b43b-fbc6ca805db4",
         "candidate_feed_id": "e3a2b1f6-0800-4231-a29b-2208984c5f64",
         "source_hash": String(repeating: "b", count: 64), "evidence_hash": String(repeating: "c", count: 64),
         "reconstruction_hash": String(repeating: "d", count: 64), "membership_head": ["seq": 7, "hash": anchorHash],
         "retained_history_only": true, "complete_history": false, "signing_clock_complete": false,
         "snapshot_complete": false, "recovery_ready": false]
    }

    private func decode(_ data: Data) throws -> RemoteControlRecoveryPreparation {
        try .decode(data, accountID: "account-a", genesisHash: anchorHash, stationOrigin: origin,
            expected: LogHead(seq: 7, hash: anchorHash))
    }

    func testExactAuthenticatedContextPreservesTheFullDeploymentGeneration() throws {
        let result = try decode(JSONSerialization.data(withJSONObject: value()))
        XCTAssertEqual(result.context.accountID, "account-a")
        XCTAssertEqual(result.context.stationOrigin, origin)
        XCTAssertEqual(result.context.generation, UInt64(Int64.max))
        XCTAssertEqual(result.context.membershipHead, LogHead(seq: 7, hash: anchorHash))
        XCTAssertEqual(result.reconstructionHash, String(repeating: "d", count: 64))
    }

    func testForeignStaleOrAuthoritativeClaimsAreNeverAcceptedAsPreparedEvidence() throws {
        let changes: [(String, Any)] = [
            ("account_id", "account-b"), ("genesis_hash", String(repeating: "f", count: 64)),
            ("origin", "https://station.agora.build"), ("generation", "01"), ("generation", "0"),
            ("generation", "9223372036854775808"), ("generation", 2), ("version", true),
            ("membership_head", ["seq": 8, "hash": anchorHash]), ("membership_head", ["seq": true, "hash": anchorHash]),
            ("membership_head", ["seq": 7, "hash": anchorHash, "extra": "bad"]),
            ("plan_id", "not-a-plan"), ("candidate_feed_id", "e3a2b1f6-0800-1231-a29b-2208984c5f64"),
            ("source_hash", NSNull()), ("evidence_hash", "bad"), ("reconstruction_hash", "bad"),
            ("retained_history_only", false), ("retained_history_only", 1),
            ("complete_history", true), ("signing_clock_complete", true),
            ("snapshot_complete", true), ("recovery_ready", true), ("extra", NSNull())
        ]
        for (key, replacement) in changes {
            var bad = value(); bad[key] = replacement
            XCTAssertThrowsError(try decode(JSONSerialization.data(withJSONObject: bad)), key)
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value()), as: UTF8.self)
        XCTAssertThrowsError(try decode(Data(json.replacingOccurrences(of: "\"version\":1",
            with: "\"version\":1,\"version\":1").utf8)))
        XCTAssertThrowsError(try decode(Data(repeating: 32, count: 8_193)))
    }

    func testHTTPUsesTheSelectedStationAndNativeBearerWithoutAnySigningCall() async throws {
        let host = "recovery-" + UUID().uuidString.lowercased() + ".example", anchorHash = anchorHash
        let bytes = try JSONSerialization.data(withJSONObject: value(origin: "https://" + host))
        RecoveryHTTPStub.install(host: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(anchorHash)/control/recovery")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-native-token")
            return (200, bytes)
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: "https://" + host, configuration: config, accessToken: { "test-native-token" })
        let result = try await http.controlRecoveryReview(accountID: "account-a", genesisHash: anchorHash,
            expected: LogHead(seq: 7, hash: anchorHash))
        XCTAssertEqual(result.context.stationOrigin, "https://" + host)
        do {
            _ = try await http.controlRecoveryReview(accountID: "account-a", genesisHash: anchorHash,
                expected: LogHead(seq: 8, hash: anchorHash))
            XCTFail("stale membership response was accepted")
        } catch {}
    }

    func testInvalidSelectorsNeverAcquireATokenOrMakeARequest() async throws {
        let http = try RemoteRecoveryHTTP(relayURL: origin, accessToken: {
            XCTFail("invalid input must be refused before token acquisition")
            return "unused"
        })
        for (account, genesis, head) in [("", anchorHash, LogHead(seq: 7, hash: anchorHash)),
            ("account-a", "bad", LogHead(seq: 7, hash: anchorHash)),
            ("account-a", anchorHash, LogHead(seq: 0, hash: anchorHash))] {
            do { _ = try await http.controlRecoveryReview(accountID: account, genesisHash: genesis, expected: head); XCTFail() }
            catch {}
        }
    }
}
