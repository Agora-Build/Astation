import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

final class RemoteStationVerifierHTTPTests: XCTestCase {
    private let genesis = String(repeating: "ab", count: 32)

    private func body(origin: String) -> [String: Any] {
        let inventory = verifierInventory()
        return ["origin": origin, "roster_generation": 1, "account_id": "account", "genesis_hash": genesis,
            "head": ["seq": 5, "hash": genesis], "replicas": [
                ["id": "a", "connection_generation": 1,
                 "verifier": ["version": inventory.version, "actions": inventory.actions], "authorization_ms_left": 30_000],
                ["id": "b"]]]
    }

    func testReportUsesOriginScopedAccountHTTPAndStartsExpiryBeforeTokenAcquisition() async throws {
        let host = "verifier-" + UUID().uuidString.lowercased() + ".example", hash = genesis
        let origin = "https://" + host
        let reply = try JSONSerialization.data(withJSONObject: body(origin: origin))
        RecoveryHTTPStub.install(host: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(hash)/verifiers")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-token")
            return (200, reply)
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: origin, configuration: config, accessToken: {
            try await Task.sleep(nanoseconds: 20_000_000)
            return "scoped-token"
        })
        let before = RemoteVerifierSigningGate.evidenceTimeMilliseconds()
        let report = try await http.stationVerifiers(genesisHash: hash)
        XCTAssertEqual(report.roster.replicas, ["a", "b"])
        XCTAssertEqual(report.replicas[0].inventory, verifierInventory())
        XCTAssertNil(report.replicas[1].inventory)
        XCTAssertGreaterThanOrEqual(report.requestStartedAt, before)
        XCTAssertGreaterThanOrEqual(RemoteVerifierSigningGate.evidenceTimeMilliseconds() - report.requestStartedAt, 20)
    }

    func testMalformedOrWrongContextReportsCannotBecomeEvidence() throws {
        let origin = "https://station.example"
        var cases = [[String: Any]]()
        for (field, value) in [
            ("origin", "https://other.example" as Any), ("genesis_hash", String(repeating: "cd", count: 32)),
            ("roster_generation", 0), ("roster_generation", true), ("roster_generation", 9_007_199_254_740_992 as UInt64),
            ("extra", NSNull()), ("account_id", ""), ("replicas", []), ("head", ["seq": 5, "hash": "bad"])
        ] {
            var item = body(origin: origin); item[field] = value; cases.append(item)
        }
        for row: [String: Any] in [
            ["id": "a", "connection_generation": NSNull()],
            ["id": "a", "connection_generation": 0],
            ["id": "a", "connection_generation": true],
            ["id": "a", "connection_generation": 1, "verifier": NSNull(), "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["add"]]],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 0, "actions": ["add"]], "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["bad action"]], "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["add", "add"]], "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["remove", "add"]], "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["add"], "extra": true], "authorization_ms_left": 1],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["add"]], "authorization_ms_left": 30_001],
            ["id": "a", "connection_generation": 1, "verifier": ["version": 2, "actions": ["add"]], "authorization_ms_left": true],
            ["id": "bad id"], ["id": String(repeating: "x", count: 129)], ["id": "a", "extra": true]
        ] {
            var item = body(origin: origin); item["replicas"] = [row]; cases.append(item)
        }
        for ids in [["b", "a"], ["a", "a"], (0..<65).map { String(format: "a%02d", $0) }] {
            var item = body(origin: origin); item["replicas"] = ids.map { ["id": $0] }; cases.append(item)
        }
        for item in cases {
            XCTAssertThrowsError(try RemoteStationVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: item),
                origin: origin, genesis: genesis, startedAt: 100))
        }
        let good = String(decoding: try JSONSerialization.data(withJSONObject: body(origin: origin), options: [.sortedKeys]), as: UTF8.self)
        for bad in [good.replacingOccurrences(of: "\"roster_generation\":1", with: "\"roster_generation\":1,\"roster_generation\":1"),
                    good.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"version\":2"),
                    String(repeating: " ", count: 262_145)] {
            XCTAssertThrowsError(try RemoteStationVerifierSnapshot.decode(Data(bad.utf8), origin: origin, genesis: genesis, startedAt: 100))
        }
    }

    func testReplicaIdentityIsScopedToTheStationAndRosterIsRevalidatedAfterDecode() throws {
        let a = try RemoteStationVerifierRoster(origin: "https://a.example", generation: 1, replicas: ["a"])
        let b = try RemoteStationVerifierRoster(origin: "https://b.example", generation: 1, replicas: ["a"])
        XCTAssertNotEqual(a.verifierID("a"), b.verifierID("a"))
        XCTAssertEqual(try JSONDecoder().decode(RemoteStationVerifierRoster.self, from: JSONEncoder().encode(a)), a)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteStationVerifierRoster.self,
            from: Data(#"{"origin":"https://a.example","generation":1,"replicas":["b","a"]}"#.utf8)))
        for origin in ["https://user@station.example", "https://station.example/path", "https://station.example?token=x"] {
            XCTAssertThrowsError(try RemoteStationVerifierRoster(origin: origin, generation: 1, replicas: ["a"]))
        }
        _ = try RemoteStationVerifierRoster(origin: "http://127.0.0.1:8081", generation: 1, replicas: ["a"])
    }

    func testManagedServiceReportUsesExactReviewedIDsHeadAndOriginWithoutRenewingExpiry() async throws {
        let origin = "https://managed-" + UUID().uuidString.lowercased() + ".example"
        let host = URL(string: origin)!.host!, hash = genesis
        let id = "svc-i-01234567890123456789012345"
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        var object = body(origin: origin)
        object["services"] = [["id": id, "auth_key": ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(key)]]]
        let reply = try JSONSerialization.data(withJSONObject: object)
        RecoveryHTTPStub.install(host: host) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/agora-build/v1/logs/\(hash)/verifiers/services")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-token")
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(body?["member_ids"] as? [String], [id])
            XCTAssertEqual((body?["expected"] as? [String: Any])?["hash"] as? String, hash)
            return (200, reply)
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: origin, configuration: config, accessToken: {
            try await Task.sleep(nanoseconds: 20_000_000); return "scoped-token"
        })
        let before = RemoteVerifierSigningGate.evidenceTimeMilliseconds()
        let result = try await http.managedServiceVerifiers(genesisHash: hash, memberIDs: [id], expected: LogHead(seq: 5, hash: hash))
        XCTAssertEqual(result.memberIDs, [id])
        XCTAssertEqual(result.services[id], PublicKeyData(alg: .p256, raw: key))
        XCTAssertGreaterThanOrEqual(result.station.requestStartedAt, before)
        XCTAssertGreaterThanOrEqual(RemoteVerifierSigningGate.evidenceTimeMilliseconds() - result.station.requestStartedAt, 20)
        do {
            _ = try await http.managedServiceVerifiers(genesisHash: hash, memberIDs: [id], expected: LogHead(seq: 6, hash: hash))
            XCTFail("A report cannot confirm another device-list head")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse) }
    }

    func testManagedServiceReportsRefuseMalformedKeysAndMissingDuplicatedOrUnsolicitedRows() throws {
        let origin = "https://station.example", id = "service"
        let key: [String: Any] = ["alg": "p256", "pub": RemoteRecoveryKit.base64URL(P256.Signing.PrivateKey().publicKey.x963Representation)]
        for rows: [[String: Any]] in [[], [["id": "other"]], [["id": id], ["id": id]],
            [["id": id, "extra": true]], [["id": id, "auth_key": NSNull()]],
            [["id": id, "auth_key": ["alg": "ed25519", "pub": key["pub"]!]]],
            [["id": id, "auth_key": ["alg": "p256", "pub": "bad"]]],
            [["id": id, "auth_key": ["alg": "p256", "pub": key["pub"]!, "extra": true]]]] {
            var object = body(origin: origin); object["services"] = rows
            XCTAssertThrowsError(try RemoteManagedServiceVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: object),
                origin: origin, genesis: genesis, memberIDs: [id], startedAt: 100))
        }
        var object = body(origin: origin); object["services"] = [["id": id]]
        XCTAssertTrue(try RemoteManagedServiceVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: object),
            origin: origin, genesis: genesis, memberIDs: [id], startedAt: 100).services.isEmpty)
        let good = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertThrowsError(try RemoteManagedServiceVerifierSnapshot.decode(Data(good.replacingOccurrences(of: "\"services\":", with: "\"services\":[],\"services\":").utf8),
            origin: origin, genesis: genesis, memberIDs: [id], startedAt: 100))
        XCTAssertFalse(RemoteManagedServiceVerifierSnapshot.validIDs(["b", "a"]))
        XCTAssertFalse(RemoteManagedServiceVerifierSnapshot.validIDs([id, id]))
        XCTAssertFalse(RemoteManagedServiceVerifierSnapshot.validIDs([String(repeating: "a", count: 129)]))
    }
}
