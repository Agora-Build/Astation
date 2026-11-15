import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class DelegatedHTTPKeys: AppKeyProvider, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey()
    func publicKey(keyId: String) throws -> PublicKeyData { PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation) }
    func sign(request: SignRequest) throws -> Data { try key.signature(for: request.input) }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.invalidInput }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw RemoteChannelError.invalidInput }
}

final class RemoteDelegatedHTTPTests: XCTestCase {
    private let genesis = String(repeating: "ab", count: 32)
    private let feed = UUID().uuidString.lowercased()

    private func transport(_ handler: @escaping (URLRequest, String) throws -> (Int, Data)) throws -> (RemoteRecoveryHTTP, String) {
        let host = "delegated-" + UUID().uuidString.lowercased() + ".example"
        RecoveryHTTPStub.install(host: host) { try handler($0, "https://" + host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        return (try RemoteRecoveryHTTP(relayURL: "https://" + host, configuration: config, accessToken: { "native-token" }), host)
    }

    func testHeadsUseAuthenticatedTransportAndTheActualSharedReader() async throws {
        let (genesis, feed) = (genesis, feed)
        let (http, host) = try transport { request, origin in
            XCTAssertEqual(request.url?.path, "/api/remote/v1/logs/\(genesis)/control")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-token")
            return (200, Data(try relayHeads(feeds: [RelayFeedHead(origin: origin, feedId: feed, head: 0, stationTime: 100)],
                membership: LogHead(seq: 1, hash: genesis)).utf8))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        guard case .heads(let feeds, _) = try relayDecodeToHost(message: await http.controlHeads(genesisHash: genesis)) else {
            return XCTFail("missing heads")
        }
        XCTAssertEqual(feeds[0].feedId, feed)
    }

    func testWrongOriginHeadsAndDelayedSameCursorRepliesCannotBecomeProgress() async throws {
        let (genesis, feed) = (genesis, feed)
        for operation in ["heads", "sync"] {
            let (http, host) = try transport { _, origin in
                let text = operation == "heads"
                    ? try relayHeads(feeds: [RelayFeedHead(origin: "https://other.example", feedId: feed, head: 0, stationTime: 100)], membership: LogHead(seq: 1, hash: genesis))
                    : try relayControlSyncResult(requestId: UUID().uuidString.lowercased(), origin: origin,
                        feedId: feed, after: 0, head: 0, stationTime: 100, records: [])
                return (200, Data(text.utf8))
            }
            defer { RecoveryHTTPStub.remove(host: host) }
            do {
                if operation == "heads" { _ = try await http.controlHeads(genesisHash: genesis) }
                else {
                    let call = try relayControlSync(requestId: UUID().uuidString.lowercased(), origin: "https://" + host, feedId: feed, after: 0)
                    _ = try await http.controlSync(genesisHash: genesis, callJSON: call)
                }
                XCTFail("accepted stale or foreign response")
            } catch { XCTAssertTrue(error is RemoteRecoveryTransportError) }
        }
    }

    func testReservationsRejectUnsafeNumbersDuplicateFieldsAndUnknownFields() async throws {
        for body in [#"{"issued_at":true}"#, #"{"issued_at":9007199254740992}"#,
                     #"{"issued_at":1,"issued_at":2}"#, #"{"issued_at":1,"extra":1}"#,
                     #"{"issued_at":0}"#, #"{"issued_at":1.5}"#] {
            let (http, host) = try transport { _, _ in (200, Data(body.utf8)) }
            defer { RecoveryHTTPStub.remove(host: host) }
            do {
                _ = try await http.reserveControlTime(genesisHash: genesis, principal: "service:test", managerID: "manager", expected: LogHead(seq: 1, hash: genesis))
                XCTFail("accepted unsafe reservation")
            } catch {}
        }
        let (http, host) = try transport { request, _ in
            XCTAssertEqual(request.url?.path.hasSuffix("/control/reservations"), true)
            return (200, Data(#"{"issued_at":1234}"#.utf8))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let time = try await http.reserveControlTime(genesisHash: genesis, principal: "service:test", managerID: "manager", expected: LogHead(seq: 1, hash: genesis))
        XCTAssertEqual(time, 1234)
    }

    @MainActor
    private func signedFixture(origin: String) throws -> (MembershipLog, String) {
        let keys = DelegatedHTTPKeys()
        let now = HostClock(wallMs: 1_792_400_000_000, monoMs: 1, bootId: "test")
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        func signed(_ body: Any) throws -> String {
            let info = try signedObjectInfo(json: json(["body": body, "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]))
            return try json(["body": body, "sig": RemoteRecoveryKit.base64URL(keys.key.signature(for: info.signingInput))])
        }
        let publicKey: [String: Any] = ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(keys.key.publicKey.rawRepresentation)]
        let genesis = try signed(["type": "atem-membership-entry", "v": 1, "account_id": "account-test",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "manager", "signed_at": now.wallMs,
            "member": ["device_id": "manager", "kind": "native", "roles": ["control", "manage", "view"], "auth_key": publicKey,
                "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Data(repeating: 7, count: 32))]], "recovery_key": publicKey])
        let hash = try XCTUnwrap(signedObjectInfo(json: genesis).entryHash)
        let log = try MembershipLog.verify(accountId: "account-test", genesisHash: hash, entries: [genesis], now: now)
        let action = try json(["action": "add", "member": ["device_id": "service", "kind": "service", "roles": ["service"], "auth_key": publicKey,
            "scope": ["hosts": ["host"], "ops": ["view"]], "expires_at": now.wallMs + 3_600_000]])
        let body = try log.draftEntry(signer: "manager", signedAt: now.wallMs, actionJson: action)
        _ = try log.extend(entries: [signed(try JSONSerialization.jsonObject(with: Data(body.utf8)))], now: now)
        let record = try buildControlRecord(provider: keys, keyId: "manager", body: ControlRecordBody(
            accountId: log.accountId(), genesisHash: hash, origin: origin, feedId: feed,
            principal: "service:service", principalKey: try serviceKeyFingerprint(authKey: keys.publicKey(keyId: "manager")),
            signer: "member:manager", action: "revoke", interruptRunning: false, revokeSeq: nil,
            recordId: UUID().uuidString.lowercased(), issuedAt: now.wallMs,
            integrationId: "i-01234567890123456789012345", by: "owner"))
        return (log, record)
    }

    @MainActor
    func testPublicationChecksTheSignedRecordAndRequiresItsExactBooleanReceipt() async throws {
        var recordID = ""
        let (http, host) = try transport { request, _ in
            XCTAssertEqual(request.url?.path.hasSuffix("/control/records"), true)
            return (200, Data("{\"record_id\":\"\(recordID)\",\"appended\":false}".utf8))
        }
        defer { RecoveryHTTPStub.remove(host: host) }
        let (log, record) = try signedFixture(origin: "https://" + host)
        recordID = try parseControlRecord(recordJson: record).recordId
        let appended = try await http.publishControl(log: log, recordJSON: record)
        XCTAssertFalse(appended, "an idempotent retry is a valid receipt")
        for receipt in ["{\"record_id\":\"\(recordID)\",\"appended\":1}",
                        "{\"record_id\":\"wrong\",\"appended\":true}"] {
            RecoveryHTTPStub.install(host: host) { _ in (200, Data(receipt.utf8)) }
            do { _ = try await http.publishControl(log: log, recordJSON: record); XCTFail("accepted mismatched receipt") }
            catch { XCTAssertTrue(error is RemoteRecoveryTransportError) }
        }
        RecoveryHTTPStub.install(host: host) { _ in XCTFail("tampered record reached HTTP"); return (500, Data()) }
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
        var body = try XCTUnwrap(forged["body"] as? [String: Any]); body["interrupt_running"] = true; forged["body"] = body
        do { _ = try await http.publishControl(log: log, recordJSON: String(decoding: JSONSerialization.data(withJSONObject: forged), as: UTF8.self)); XCTFail("accepted forged signature") }
        catch { XCTAssertTrue(error is RemoteChannelError) }
    }
}
