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

    @MainActor
    func testOriginalPagesRequireSameReviewAndStrictlyIncreasingRecordIDs() async throws {
        let review = try decode(JSONSerialization.data(withJSONObject: value()))
        let host = try XCTUnwrap(URL(string: origin)?.host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: origin, configuration: config, accessToken: { "native-test" })
        let fixture = try ControlPublicationFixture()
        var records: [[String: Any]] = []
        for _ in 0..<2 {
            let body = try fixture.body(interrupt: false)
            _ = try fixture.prepare(body)
            let signed = try fixture.sign(body)
            records.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(signed.utf8)) as? [String: Any]))
        }
        func id(_ record: [String: Any]) -> String { (record["body"] as! [String: Any])["record_id"] as! String }
        records.sort { id($0) < id($1) }
        defer { RecoveryHTTPStub.remove(host: host) }
        for scenario in ["valid", "stale", "duplicate", "empty_more", "wrong_offset", "nonboolean"] {
            RecoveryHTTPStub.install(host: host) { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(url.path, "/api/remote/v1/logs/" + review.context.genesisHash +
                    "/control/recovery/" + review.context.planID + "/originals")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-test")
                let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(query.first { $0.name == "review" }?.value, review.reconstructionHash)
                let offset = try XCTUnwrap(Int(query.first { $0.name == "offset" }?.value ?? ""))
                guard [0, 1].contains(offset) else { throw URLError(.badServerResponse) }
                var page: [String: Any] = ["plan_id": review.context.planID, "reconstruction_hash": review.reconstructionHash,
                    "records": [records[offset]], "offset": offset, "more": offset == 0]
                if offset == 1 {
                    switch scenario {
                    case "stale": page["reconstruction_hash"] = String(repeating: "e", count: 64)
                    case "duplicate": page["records"] = [records[0]]
                    case "empty_more": page["records"] = []; page["more"] = true
                    case "wrong_offset": page["offset"] = 0
                    case "nonboolean": page["more"] = 0
                    default: break
                    }
                }
                return (200, try JSONSerialization.data(withJSONObject: page))
            }
            do {
                let originals = try await http.controlRecoveryOriginals(for: review)
                XCTAssertEqual(scenario, "valid")
                XCTAssertEqual(try originals.map { try parseControlRecord(recordJson: $0).recordId }, records.map(id))
            } catch { XCTAssertNotEqual(scenario, "valid", String(describing: error)) }
        }
    }

    func testStationSignerChallengeChecksMemberSlotLeaseAndFullRecoveryContext() async throws {
        let context = try decode(JSONSerialization.data(withJSONObject: value())).context
        let host = try XCTUnwrap(URL(string: context.stationOrigin)?.host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: context.stationOrigin, configuration: config,
            accessToken: { "test-native-token" })
        defer { RecoveryHTTPStub.remove(host: host) }
        let target = SignerReportRecovery(generation: String(context.generation), planId: context.planID,
            candidateFeedId: context.candidateFeedID, sourceHash: context.sourceHash, evidenceHash: context.evidenceHash)
        for change in ["valid", "other-slot", "other-member", "other-plan", "expired"] {
            var recovery = target
            if change == "other-plan" { recovery.planId = UUID().uuidString.lowercased() }
            let response = try signerReportChallenge(signer: change == "other-member" ? "member:other" : "member:mac",
                slot: change == "other-slot" ? "other" : "astation-macos", origin: context.stationOrigin,
                connection: 5, issuedAt: 1000, expiresAt: 31_000, recovery: recovery)
            RecoveryHTTPStub.install(host: host) { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/" + context.genesisHash + "/control/recovery/signer-challenges")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-native-token")
                return (200, Data(response.utf8))
            }
            do {
                let result = try await http.signerChallenge(for: context, memberID: "mac", slot: "astation-macos",
                    nowMs: { change == "expired" ? 31_000 : 1001 })
                XCTAssertEqual(change, "valid")
                XCTAssertEqual(result.context, context)
                XCTAssertEqual(result.json, response)
            } catch {
                XCTAssertNotEqual(change, "valid", String(describing: error))
            }
        }
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
