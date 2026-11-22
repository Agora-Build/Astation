import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
final class RemoteControlRecoveryRetentionTests: XCTestCase {
    private func fixture(origin: String? = nil) throws -> (RemoteControlRecoveryContext, String, String) {
        let f = try ControlPublicationFixture()
        let body = try f.body(interrupt: true)
        _ = try f.prepare(body)
        let record = try f.sign(body)
        let context = try RemoteControlRecoveryContext(accountID: f.log.accountId(), genesisHash: f.log.genesisHash(),
            stationOrigin: origin ?? f.origin, generation: UInt64(Int64.max), planID: UUID().uuidString.lowercased(),
            sourceHash: String(repeating: "a", count: 64), evidenceHash: String(repeating: "b", count: 64),
            candidateFeedID: f.feed, membershipHead: f.log.head())
        let bytes = "{\"evidence_hash\":\"" + context.evidenceHash + "\",\"replacements\":[{\"original_record_id\":\"" +
            UUID().uuidString.lowercased() + "\",\"record\":" + record + "}]}"
        return (context, bytes, body.recordId)
    }

    private func receipt(_ context: RemoteControlRecoveryContext, _ id: String) -> [String: Any] {
        ["version": 1, "account_id": context.accountID, "genesis_hash": context.genesisHash, "origin": context.stationOrigin,
         "generation": String(context.generation), "plan_id": context.planID, "evidence_hash": context.evidenceHash,
         "record_ids": [id], "reconstruction_hash": String(repeating: "c", count: 64), "retained_only": true, "recovery_ready": false]
    }

    func testRetentionReceiptCannotClaimAnotherOperationOrReopening() throws {
        let (context, _, id) = try fixture(), value = receipt(context, id)
        XCTAssertEqual(try RemoteControlRecoveryRetention.decode(JSONSerialization.data(withJSONObject: value),
            context: context, recordIDs: [id]).recordIDs, [id])
        for (key, replacement) in [("account_id", "other"), ("origin", "https://other.example"),
            ("genesis_hash", String(repeating: "0", count: 64)), ("generation", "01"), ("generation", 1),
            ("plan_id", UUID().uuidString.lowercased()), ("evidence_hash", String(repeating: "e", count: 64)),
            ("record_ids", [UUID().uuidString.lowercased()]), ("record_ids", [id, id]),
            ("version", true), ("retained_only", 1), ("retained_only", false), ("recovery_ready", true),
            ("reconstruction_hash", "bad"), ("unknown", NSNull())] as [(String, Any)] {
            var bad = value; bad[key] = replacement
            XCTAssertThrowsError(try RemoteControlRecoveryRetention.decode(JSONSerialization.data(withJSONObject: bad),
                context: context, recordIDs: [id]), key)
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        XCTAssertThrowsError(try RemoteControlRecoveryRetention.decode(Data(json.replacingOccurrences(of: "\"version\":1",
            with: "\"version\":1,\"version\":1").utf8), context: context, recordIDs: [id]))
        XCTAssertThrowsError(try RemoteControlRecoveryRetention.decode(Data(repeating: 32, count: 8_193), context: context, recordIDs: [id]))
    }

    func testMalformedOrForeignCopiesAreRejectedBeforeTokenAcquisition() async throws {
        let (context, json, _) = try fixture()
        let http = try RemoteRecoveryHTTP(relayURL: context.stationOrigin, accessToken: {
            XCTFail("invalid input acquired a token"); return "unused"
        })
        for bad in ["{}", json.replacingOccurrences(of: context.evidenceHash, with: String(repeating: "0", count: 64)),
            json.replacingOccurrences(of: "\"evidence_hash\":", with: "\"extra\":null,\"evidence_hash\":"),
            String(repeating: " ", count: 262_145)] {
            do { _ = try await http.retainControlRecoveryCopies(context: context, copiesJSON: bad); XCTFail() } catch {}
        }
    }

    func testNativeHTTPRetriesTheExactBytesAndRejectsAForeignReceipt() async throws {
        let (context, json, id) = try fixture()
        let bytes = try JSONSerialization.data(withJSONObject: receipt(context, id))
        RecoveryHTTPStub.install(host: "station.example") { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(context.genesisHash)/control/recovery/\(context.planID)/signatures")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-native-token")
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(body, Data(json.utf8))
            return (200, bytes)
        }
        defer { RecoveryHTTPStub.remove(host: "station.example") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: context.stationOrigin, configuration: configuration, accessToken: { "test-native-token" })
        for _ in 0..<2 {
            let result = try await http.retainControlRecoveryCopies(context: context, copiesJSON: json)
            XCTAssertEqual(result.recordIDs, [id])
        }
        var bad = receipt(context, id); bad["record_ids"] = [UUID().uuidString.lowercased()]
        let badBytes = try JSONSerialization.data(withJSONObject: bad)
        RecoveryHTTPStub.install(host: "station.example") { _ in (200, badBytes) }
        do { _ = try await http.retainControlRecoveryCopies(context: context, copiesJSON: json); XCTFail() } catch {}
    }
}
