import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class ControlPublicationKeys: AppKeyProvider, @unchecked Sendable {
    let key = Curve25519.Signing.PrivateKey()
    var signs = 0
    var beforeSign: (() throws -> Void)?
    func publicKey(keyId: String) throws -> PublicKeyData { PublicKeyData(alg: .ed25519, raw: key.publicKey.rawRepresentation) }
    func sign(request: SignRequest) throws -> Data {
        try beforeSign?()
        signs += 1
        return try key.signature(for: request.input)
    }
    func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.invalidInput }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data { throw RemoteChannelError.invalidInput }
}

@MainActor
private final class ControlPublicationFixture {
    let keys = ControlPublicationKeys()
    let origin = "https://station.example"
    let integration = "i-01234567890123456789012345"
    let feed = UUID().uuidString.lowercased()
    let clock = HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "control-publication")
    let log: MembershipLog
    var stored: Data?
    var writeFailure = false
    var failAfterWrite = false
    var journal: RemoteControlPublication!

    init() throws {
        let publicKey: [String: Any] = ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(keys.key.publicKey.rawRepresentation)]
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account-test",
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "manager",
            "signed_at": clock.wallMs, "member": ["device_id": "manager", "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": publicKey, "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Data(repeating: 7, count: 32))]],
            "recovery_key": publicKey]
        let genesis = try Self.signed(body, keys: keys)
        log = try MembershipLog.verify(accountId: "account-test", genesisHash: XCTUnwrap(signedObjectInfo(json: genesis).entryHash), entries: [genesis], now: clock)
        try append(["action": "add", "member": ["device_id": "service", "kind": "service", "roles": ["service"],
            "auth_key": publicKey, "scope": ["hosts": ["host"], "ops": ["view"]], "expires_at": clock.wallMs + 3_600_000]])
        journal = try RemoteControlPublication(accountID: log.accountId(), genesisHash: log.genesisHash(), stationOrigin: origin,
            persist: { [unowned self] in try persist($0) })
    }

    func append(_ action: [String: Any], signer: String = "manager", signingKeys: ControlPublicationKeys? = nil) throws {
        let body = try log.draftEntry(signer: signer, signedAt: clock.wallMs,
            actionJson: String(decoding: JSONSerialization.data(withJSONObject: action), as: UTF8.self))
        let entry = try Self.signed(JSONSerialization.jsonObject(with: Data(body.utf8)), keys: signingKeys ?? keys)
        let result = try log.extend(entries: [entry], now: clock)
        XCTAssertEqual(result.appended, 1)
    }

    func replaceManager() throws -> ControlPublicationKeys {
        let next = ControlPublicationKeys()
        try append(["action": "add", "member": ["device_id": "other-manager", "kind": "native",
            "roles": ["control", "manage", "view"],
            "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(next.key.publicKey.rawRepresentation)],
            "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]]])
        try append(["action": "set_roles", "device_id": "manager", "roles": ["control", "view"]])
        return next
    }

    private static func signed(_ body: Any, keys: ControlPublicationKeys) throws -> String {
        let info = try signedObjectInfo(json: String(decoding: JSONSerialization.data(withJSONObject: ["body": body,
            "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))]), as: UTF8.self))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["body": body,
            "sig": RemoteRecoveryKit.base64URL(keys.key.signature(for: info.signingInput))]), as: UTF8.self)
    }

    func persist(_ bytes: Data) throws {
        if writeFailure { throw RemoteControlPublicationError.storageUncertain }
        stored = bytes
        if failAfterWrite { failAfterWrite = false; throw RemoteControlPublicationError.storageUncertain }
    }
    func restore(_ data: Data? = nil) throws {
        journal = try RemoteControlPublication(checkpoint: XCTUnwrap(data ?? stored), accountID: log.accountId(),
            genesisHash: log.genesisHash(), stationOrigin: origin, persist: { [unowned self] in try persist($0) })
    }
    func body(action: String = "revoke", interrupt: Bool? = false) throws -> ControlRecordBody {
        ControlRecordBody(accountId: log.accountId(), genesisHash: log.genesisHash(), origin: origin, feedId: feed,
            principal: "service:service", principalKey: try serviceKeyFingerprint(authKey: keys.publicKey(keyId: "manager")),
            signer: "member:manager", action: action, interruptRunning: interrupt, revokeSeq: nil,
            recordId: UUID().uuidString.lowercased(), issuedAt: clock.wallMs, integrationId: integration, by: "owner")
    }
    func mirror(interrupt: Bool = false) throws -> RemoteControlPortalMirror {
        try RemoteControlPortalMirror(issuer: "https://auth.example", ownerAccount: "ab00000000000000000000000000",
            stationOrigin: origin, integrationID: integration, interruptRunning: interrupt)
    }
    func hostBody() throws -> ControlRecordBody {
        try append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(keys.key.publicKey.rawRepresentation)]]])
        try append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hostSenderRevokeAction(hostId: "host",
            interruptRunning: false, signedAt: clock.wallMs).utf8)) as? [String: Any]))
        return ControlRecordBody(accountId: log.accountId(), genesisHash: log.genesisHash(), origin: nil,
            feedId: nil, principal: "host:host", principalKey: nil, signer: "member:manager", action: "interrupt_running",
            interruptRunning: nil, revokeSeq: log.head().seq, recordId: UUID().uuidString.lowercased(),
            issuedAt: clock.wallMs, integrationId: nil, by: "owner")
    }
    func prepare(_ body: ControlRecordBody) throws -> SignRequest {
        try journal.prepare(body: body, log: log, portalMirror: body.action == "revoke" ? mirror(interrupt: body.interruptRunning!) : nil)
    }
    func sign(_ body: ControlRecordBody, current: () -> Bool = { true }) throws -> String {
        try journal.sign(recordID: body.recordId, log: log, provider: keys, confirmedAt: 100, now: { 100 }, current: current)
    }
}

final class RemoteControlPublicationTests: XCTestCase {
    @MainActor
    func testHostFanoutHTTPUsesSeparateOriginCredentialsAndRejectsAFalseReceipt() async throws {
        let f = try ControlPublicationFixture(), body = try f.hostBody()
        let second = "https://fanout-" + UUID().uuidString.lowercased() + ".example"
        _ = try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [second])
        let record = try f.sign(body), canonicalRecord = try canonicalJson(json: record)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryHTTPStub.self]
        for (origin, token) in [(f.origin, "primary-test-token"), (second, "secondary-test-token")] {
            let host = try XCTUnwrap(URL(string: origin)?.host)
            RecoveryHTTPStub.install(host: host) { request in
                XCTAssertEqual(request.url?.absoluteString, origin + "/api/remote/v1/logs/" + body.genesisHash + "/control/records")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                        if count == 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let object = try JSONSerialization.data(withJSONObject: XCTUnwrap(sent["record"]))
                XCTAssertEqual(try canonicalJson(json: String(decoding: object, as: UTF8.self)), canonicalRecord)
                // A response naming another record must not become a durable receipt.
                return (200, try JSONSerialization.data(withJSONObject: [
                    "record_id": origin == second ? UUID().uuidString.lowercased() : body.recordId, "appended": true]))
            }
        }
        defer {
            RecoveryHTTPStub.remove(host: URL(string: f.origin)!.host!)
            RecoveryHTTPStub.remove(host: URL(string: second)!.host!)
        }
        let primaryHTTP = try RemoteRecoveryHTTP(relayURL: f.origin, configuration: config, accessToken: { "primary-test-token" })
        let secondaryHTTP = try RemoteRecoveryHTTP(relayURL: second, configuration: config, accessToken: { "secondary-test-token" })
        XCTAssertEqual(primaryHTTP.controlStationOrigin, f.origin)
        XCTAssertEqual(secondaryHTTP.controlStationOrigin, second)
        _ = try await primaryHTTP.publishControl(log: f.log, recordJSON: record)
        try f.journal.stationStored(XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log)))
        do { _ = try await secondaryHTTP.publishControl(log: f.log, recordJSON: record); XCTFail("foreign receipt") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse) }
        try f.restore()
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertTrue(delivery.stationStored)
        XCTAssertEqual(delivery.additionalStations, [second: false])
        XCTAssertFalse(delivery.allStationsStored)
    }

    @MainActor
    func testHostFanoutRetainsIndependentReceiptsAndExactSignatureAcrossRestart() throws {
        let f = try ControlPublicationFixture(), body = try f.hostBody()
        let second = "https://second.example", third = "https://third.example"
        _ = try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [third, second])
        XCTAssertEqual(try f.journal.stationOrigins(recordID: body.recordId), [f.origin, second, third])
        XCTAssertThrowsError(try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [second]),
            "a retry cannot narrow the reviewed recipients")
        let record = try f.sign(body), signs = f.keys.signs
        var delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        try f.journal.stationStored(delivery, stationOrigin: second)
        try f.restore()
        delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertFalse(delivery.stationStored, "another Station's receipt cannot settle the primary")
        XCTAssertEqual(delivery.additionalStations, [second: true, third: false])
        XCTAssertFalse(delivery.allStationsStored)
        XCTAssertTrue(try f.journal.stationDeliveryNeeded(recordID: body.recordId))
        XCTAssertFalse(try f.journal.stationDeliveryNeeded(recordID: body.recordId, stationOrigin: second))
        try f.journal.stationStored(delivery)
        XCTAssertEqual(try f.journal.pendingDeliveryIDs(), [body.recordId])
        try f.restore()
        XCTAssertEqual(try f.sign(body), record)
        XCTAssertEqual(f.keys.signs, signs, "fanout and retry must never sign again")
        delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        try f.journal.stationStored(delivery, stationOrigin: third)
        try f.restore()
        XCTAssertTrue(try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log)).allStationsStored)
        XCTAssertTrue(try f.journal.pendingDeliveryIDs().isEmpty)
        XCTAssertEqual(try f.journal.activity(log: f.log).first?.additionalStations, [second: true, third: true])
    }

    @MainActor
    func testFanoutRejectsServiceRecordsBadOriginsChangedTargetsAndInventedReceipts() throws {
        let f = try ControlPublicationFixture(), service = try f.body(), second = "https://second.example"
        XCTAssertThrowsError(try f.journal.prepare(body: service, log: f.log, portalMirror: f.mirror(), additionalStationOrigins: [second]))
        let body = try f.hostBody()
        for origins in [[f.origin], [second, second], ["http://second.example"], ["https://second.example/"],
            (0..<64).map { "https://station\($0).example" }] {
            XCTAssertThrowsError(try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: origins))
        }
        _ = try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [second])
        var checkpoint = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(f.stored), format: nil) as? [String: Any])
        var operations = try XCTUnwrap(checkpoint["operations"] as? [[String: Any]])
        operations[0]["additionalStations"] = [second: true]
        checkpoint["operations"] = operations
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: checkpoint, format: .binary, options: 0)),
            "an unsigned record cannot have a delivery receipt")
        try f.restore()
        _ = try f.sign(body)
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertThrowsError(try f.journal.stationStored(delivery, stationOrigin: "https://unreviewed.example"))
        XCTAssertFalse(try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId)).allStationsStored)
    }

    @MainActor
    func testUncertainFanoutReceiptFencesUntilReloadAndPreservesOtherTargets() throws {
        let f = try ControlPublicationFixture(), body = try f.hostBody(), second = "https://second.example"
        _ = try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [second])
        _ = try f.sign(body)
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.journal.stationStored(delivery, stationOrigin: second))
        XCTAssertThrowsError(try f.journal.pendingDeliveryIDs())
        try f.restore()
        let restored = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertTrue(restored.additionalStations[second] == true)
        XCTAssertFalse(restored.stationStored)
        XCTAssertEqual(restored.recordJSON, delivery.recordJSON)
        XCTAssertEqual(try f.journal.pendingDeliveryIDs(), [body.recordId])
    }

    @MainActor
    func testFreshManagerHostCopyPreservesFanoutWithoutCopyingReceipts() throws {
        let f = try ControlPublicationFixture(), body = try f.hostBody(), second = "https://second.example"
        _ = try f.journal.prepare(body: body, log: f.log, additionalStationOrigins: [second])
        _ = try f.sign(body)
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        try f.journal.stationStored(delivery, stationOrigin: second)
        let keys = try f.replaceManager()
        let review = try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 1, feedID: nil, log: f.log)
        XCTAssertEqual(try f.journal.stationOrigins(recordID: review.body.recordId), [f.origin, second])
        _ = try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 100, now: { 100 }, current: { true })
        try f.restore()
        XCTAssertEqual(try f.journal.pendingDeliveryIDs(), [review.body.recordId])
        let replacement = try XCTUnwrap(f.journal.delivery(recordID: review.body.recordId, log: f.log))
        XCTAssertFalse(replacement.stationStored)
        XCTAssertEqual(replacement.additionalStations, [second: false])
        XCTAssertEqual(try f.journal.retainedDelivery(recordID: body.recordId)?.additionalStations, [second: true])
        XCTAssertFalse(try f.journal.stationDeliveryNeeded(recordID: body.recordId, stationOrigin: second))
    }

    @MainActor
    func testFreshManagerCopyKeepsExactStopAndIndependentPortalIntentAcrossRestart() throws {
        let f = try ControlPublicationFixture(), body = try f.body(interrupt: true)
        _ = try f.prepare(body)
        let original = try f.sign(body)
        let keys = try f.replaceManager()
        let review = try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 1, feedID: f.feed, log: f.log)
        XCTAssertNotEqual(review.body.recordId, body.recordId)
        XCTAssertEqual(review.resignsRecordID, body.recordId)
        XCTAssertEqual(review.body.signer, "member:other-manager")
        XCTAssertEqual(review.body.principal, body.principal)
        XCTAssertEqual(review.body.principalKey, body.principalKey)
        XCTAssertEqual(review.body.action, "revoke")
        XCTAssertEqual(review.body.interruptRunning, true)
        XCTAssertEqual(review.body.integrationId, body.integrationId)
        XCTAssertEqual(review.body.by, body.by)
        XCTAssertTrue(review.request.freshConfirmation)
        XCTAssertEqual(keys.signs, 0, "preparing a review cannot ask the key to sign")
        try f.restore()
        let resumed = try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 100, feedID: UUID().uuidString.lowercased(), log: f.log)
        XCTAssertEqual(resumed, review, "resume the exact saved request instead of reserving another stop")
        XCTAssertTrue(try f.journal.stationDeliveryNeeded(recordID: body.recordId), "an unsigned draft cannot replace a signed stop")
        XCTAssertThrowsError(try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: f.keys,
            confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertEqual(keys.signs, 0)
        let signed = try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertFalse(try f.journal.stationDeliveryNeeded(recordID: body.recordId))
        let old = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
        XCTAssertEqual(old.recordJSON, original)
        XCTAssertFalse(old.stationStored, "superseding a retry cannot fabricate a receipt")
        XCTAssertNotNil(old.portalMirror)
        let new = try XCTUnwrap(f.journal.delivery(recordID: review.body.recordId, log: f.log))
        XCTAssertNil(new.portalMirror, "the copy must never create another Portal revoke")
        XCTAssertEqual(Set(try f.journal.pendingDeliveryIDs()), Set([body.recordId, review.body.recordId]))
        try f.journal.portalMirrored(old)
        try f.restore()
        XCTAssertEqual(try f.journal.pendingDeliveryIDs(), [review.body.recordId])
        XCTAssertEqual(try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 0, now: { 100_000 }, current: { true }), signed, "a signed retry needs no approval or key call")
        XCTAssertEqual(keys.signs, 1)
        XCTAssertEqual(try f.journal.activity(log: f.log).first(where: { $0.body.recordId == body.recordId })?.replacementRecordID,
            review.body.recordId)
    }

    @MainActor
    func testFreshManagerCopyRequiresRemovedSignerAndCurrentReviewHead() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        _ = try f.sign(body)
        XCTAssertThrowsError(try f.journal.prepareResign(recordID: body.recordId, managerID: "manager",
            issuedAt: body.issuedAt + 1, feedID: f.feed, log: f.log))
        let keys = try f.replaceManager()
        XCTAssertThrowsError(try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt, feedID: f.feed, log: f.log), "a stale reservation cannot create the replacement")
        let review = try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 1, feedID: f.feed, log: f.log)
        try f.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "manage", "view"]],
            signer: "other-manager", signingKeys: keys)
        XCTAssertThrowsError(try f.journal.signingRequest(recordID: review.body.recordId, log: f.log))
        XCTAssertThrowsError(try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 100, now: { 100 }, current: { true }))
        XCTAssertEqual(keys.signs, 0)
        try f.journal.cancelUnsigned(recordID: review.body.recordId)
        XCTAssertNil(try f.journal.savedResignReview(recordID: body.recordId))
        XCTAssertEqual(f.journal.recordIDs, [body.recordId])
    }

    @MainActor
    func testImportedRemovedManagerStopHasNoPortalAuthorityAndRetainsItsHistoricalHostRevoke() throws {
        let f = try ControlPublicationFixture()
        try f.append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(f.keys.key.publicKey.rawRepresentation)]]])
        try f.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hostSenderRevokeAction(hostId: "host",
            interruptRunning: false, signedAt: f.clock.wallMs).utf8)) as? [String: Any]))
        let body = ControlRecordBody(accountId: f.log.accountId(), genesisHash: f.log.genesisHash(), origin: nil,
            feedId: nil, principal: "host:host", principalKey: nil, signer: "member:manager", action: "interrupt_running",
            interruptRunning: nil, revokeSeq: f.log.head().seq, recordId: UUID().uuidString.lowercased(),
            issuedAt: f.clock.wallMs, integrationId: nil, by: "owner")
        let record = try buildControlRecord(provider: f.keys, keyId: "manager", body: body)
        let keys = try f.replaceManager()
        try f.journal.retainRemovedManagerStop(recordJSON: record, log: f.log)
        try f.restore()
        XCTAssertTrue(try f.journal.pendingDeliveryIDs().isEmpty)
        XCTAssertNil(try f.journal.retainedDelivery(recordID: body.recordId)?.portalMirror)
        let review = try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 1, feedID: UUID().uuidString.lowercased(), log: f.log)
        XCTAssertEqual(review.body.revokeSeq, body.revokeSeq)
        XCTAssertNil(review.body.origin)
        XCTAssertNil(review.body.feedId)
        XCTAssertNil(review.body.principalKey)
        XCTAssertNil(review.body.integrationId)
        _ = try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 100, now: { 100 }, current: { true })
        XCTAssertEqual(keys.signs, 1)
    }

    @MainActor
    func testImportedServiceStopCannotInventAPortalRevokeOrOverwriteAnotherBodyUnderTheSameID() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        let record = try buildControlRecord(provider: f.keys, keyId: "manager", body: body)
        XCTAssertThrowsError(try f.journal.retainRemovedManagerStop(recordJSON: record, log: f.log))
        _ = try f.replaceManager()
        try f.journal.retainRemovedManagerStop(recordJSON: record, log: f.log)
        try f.journal.retainRemovedManagerStop(recordJSON: record, log: f.log)
        XCTAssertEqual(f.journal.recordIDs, [body.recordId])
        XCTAssertNil(try f.journal.retainedDelivery(recordID: body.recordId)?.portalMirror)
        var conflict = body
        conflict.interruptRunning = true
        XCTAssertThrowsError(try f.journal.retainRemovedManagerStop(
            recordJSON: buildControlRecord(provider: f.keys, keyId: "manager", body: conflict), log: f.log))
        var foreign = body
        foreign.origin = "https://other.example"
        foreign.recordId = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try f.journal.retainRemovedManagerStop(
            recordJSON: buildControlRecord(provider: f.keys, keyId: "manager", body: foreign), log: f.log))
        XCTAssertEqual(f.journal.recordIDs, [body.recordId])
        try f.restore()
        XCTAssertTrue(try f.journal.pendingDeliveryIDs().isEmpty)
    }

    @MainActor
    func testUncertainFreshCopyWritesRecoverExactDraftAndSignatureAndRejectTamperedLinks() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        _ = try f.sign(body)
        let keys = try f.replaceManager()
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.journal.prepareResign(recordID: body.recordId, managerID: "other-manager",
            issuedAt: body.issuedAt + 1, feedID: f.feed, log: f.log))
        try f.restore()
        let review = try XCTUnwrap(f.journal.savedResignReview(recordID: body.recordId))
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 100, now: { 100 }, current: { true }))
        try f.restore()
        let signed = try XCTUnwrap(f.journal.retainedDelivery(recordID: review.body.recordId))
        XCTAssertEqual(try f.journal.sign(recordID: review.body.recordId, log: f.log, provider: keys,
            confirmedAt: 0, now: { 100_000 }, current: { true }), signed.recordJSON)
        XCTAssertEqual(keys.signs, 1)
        var checkpoint = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(f.stored), format: nil) as? [String: Any])
        var operations = try XCTUnwrap(checkpoint["operations"] as? [[String: Any]])
        operations[1]["resignsRecordID"] = UUID().uuidString.lowercased()
        checkpoint["operations"] = operations
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: checkpoint, format: .binary, options: 0)))
    }

    @MainActor
    func testControlActivityDistinguishesDraftStorageAndReportedHostEffectsAcrossRestart() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        let draft = try XCTUnwrap(f.journal.activity(log: f.log, status: [body.recordId: .effectsReported]).first)
        XCTAssertFalse(draft.signed)
        XCTAssertNil(draft.application, "a Station cannot give application status to an unsigned review")
        XCTAssertTrue(draft.summary.contains("confirmation required"))
        _ = try f.sign(body)
        try f.journal.stationStored(XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId)))
        try f.restore()
        let stored = try XCTUnwrap(f.journal.activity(log: f.log).first)
        XCTAssertTrue(stored.stationStored)
        XCTAssertTrue(stored.summary.contains("not checked"))
        let pending = try XCTUnwrap(f.journal.activity(log: f.log, status: [body.recordId: .awaitingApplication]).first)
        XCTAssertTrue(pending.summary.contains("Waiting for covered hosts"))
        let reported = try XCTUnwrap(f.journal.activity(log: f.log, status: [body.recordId: .effectsReported]).first)
        XCTAssertTrue(reported.summary.contains("Station reports"))
        XCTAssertTrue(reported.portalPending, "host evidence never settles the independent Portal mirror")
        XCTAssertEqual(f.keys.signs, 1)
        try f.restore()
        XCTAssertNil(try f.journal.activity(log: f.log).first?.application, "a fresh view must refresh Station reports")
    }

    @MainActor
    func testPendingReviewsRestoreTheExactHostDraftAndDisappearOnlyAfterStationReceipt() throws {
        let f = try ControlPublicationFixture()
        try f.append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(f.keys.key.publicKey.rawRepresentation)]]])
        try f.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hostSenderRevokeAction(hostId: "host",
            interruptRunning: false, signedAt: f.clock.wallMs).utf8)) as? [String: Any]))
        let body = ControlRecordBody(accountId: f.log.accountId(), genesisHash: f.log.genesisHash(), origin: nil,
            feedId: nil, principal: "host:host", principalKey: nil, signer: "member:manager", action: "interrupt_running",
            interruptRunning: nil, revokeSeq: f.log.head().seq, recordId: UUID().uuidString.lowercased(),
            issuedAt: f.clock.wallMs, integrationId: nil, by: "owner")
        let request = try f.journal.prepare(body: body, log: f.log)
        try f.restore()
        let unsigned = try XCTUnwrap(f.journal.pendingReviews().first)
        XCTAssertEqual(unsigned.body, body)
        XCTAssertEqual(unsigned.request, request)
        XCTAssertFalse(unsigned.signed)
        let record = try f.sign(body)
        try f.restore()
        let signed = try XCTUnwrap(f.journal.pendingReviews().first)
        XCTAssertEqual(signed.body, body)
        XCTAssertEqual(signed.request, request)
        XCTAssertTrue(signed.signed)
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertEqual(delivery.recordJSON, record)
        XCTAssertNil(delivery.portalMirror)
        try f.journal.stationStored(delivery)
        try f.restore()
        XCTAssertTrue(try f.journal.pendingReviews().isEmpty)
        XCTAssertEqual(try f.journal.retainedDelivery(recordID: body.recordId)?.recordJSON, record)
    }

    @MainActor
    func testExactSDKRequestIsPersistedBeforeSignAndBothDeliveriesSurviveRestart() throws {
        let f = try ControlPublicationFixture(), body = try f.body(interrupt: true)
        let request = try f.prepare(body)
        XCTAssertEqual(f.keys.signs, 0)
        XCTAssertEqual(request.purpose, .controlRecord)
        XCTAssertTrue(request.freshConfirmation)
        f.keys.beforeSign = {
            let saved = try XCTUnwrap(f.stored)
            let restored = try RemoteControlPublication(checkpoint: saved, accountID: f.log.accountId(), genesisHash: f.log.genesisHash(), stationOrigin: f.origin, persist: { _ in })
            XCTAssertEqual(restored.recordIDs, [body.recordId])
            XCTAssertNil(try restored.delivery(recordID: body.recordId, log: f.log))
        }
        let signed = try f.sign(body)
        f.keys.beforeSign = nil
        XCTAssertEqual(try signedObjectInfo(json: signed).bodyJcs, request.bodyJson)
        try f.restore()
        let first = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertEqual(first.recordJSON, signed)
        XCTAssertFalse(first.stationStored)
        XCTAssertFalse(first.portalMirrored)
        XCTAssertTrue(try XCTUnwrap(first.portalMirror).interruptRunning)
        try f.journal.stationStored(first)
        try f.restore()
        let second = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertTrue(second.stationStored)
        XCTAssertFalse(second.portalMirrored)
        try f.journal.portalMirrored(second)
        try f.restore()
        let final = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertTrue(final.stationStored)
        XCTAssertTrue(final.portalMirrored)
        XCTAssertEqual(final.recordJSON, signed)
        XCTAssertEqual(try f.sign(body), signed)
        XCTAssertEqual(f.keys.signs, 1, "a lost reply/restart never signs again")
    }

    @MainActor
    func testPreparedRecordRequiresSameHeadFreshExactConfirmationAndCurrentContext() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        let request = try f.prepare(body)
        let signer = try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 100 })
        var changed = request
        changed.keyId = "other-manager"
        XCTAssertThrowsError(try signer.sign(request: changed))
        _ = try signer.sign(request: request)
        XCTAssertThrowsError(try signer.sign(request: request))
        XCTAssertThrowsError(try RemoteConfirmedSigner(provider: f.keys, request: request, confirmedAt: 100, now: { 30_100 }))
        XCTAssertThrowsError(try f.sign(body, current: { false }))
        let signs = f.keys.signs
        try f.append(["action": "add_host", "host": ["host_id": "host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(f.keys.key.publicKey.rawRepresentation)]]])
        XCTAssertThrowsError(try f.sign(body)) { XCTAssertEqual($0 as? RemoteControlPublicationError, .requiresReview) }
        XCTAssertEqual(f.keys.signs, signs)
    }

    @MainActor
    func testNativeProviderRefusesServiceSignaturesAndHoldReleaseAndCoverBeforeSign() throws {
        let f = try ControlPublicationFixture()
        for action in ["cover", "hold", "release"] {
            let body = try f.body(action: action, interrupt: nil)
            XCTAssertThrowsError(try f.journal.prepare(body: body, log: f.log))
        }
        var own = try f.body()
        own.signer = own.principal
        XCTAssertThrowsError(try f.journal.prepare(body: own, log: f.log, portalMirror: f.mirror()))
        var wrongKey = try f.body()
        wrongKey.principalKey = String(repeating: "ff", count: 32)
        XCTAssertThrowsError(try f.prepare(wrongKey))
        let revoke = try f.body()
        XCTAssertThrowsError(try f.journal.prepare(body: revoke, log: f.log), "native service revoke must retain its Portal mirror")
        XCTAssertThrowsError(try f.journal.prepare(body: revoke, log: f.log, portalMirror: f.mirror(interrupt: true)))
        XCTAssertEqual(f.keys.signs, 0)
        XCTAssertNil(f.stored)
    }

    @MainActor
    func testSigningAndReceiptCommitFailuresFenceTheInstanceAndRequireReload() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        f.writeFailure = true
        XCTAssertThrowsError(try f.sign(body))
        XCTAssertTrue(f.journal.storageUncertain)
        XCTAssertThrowsError(try f.journal.delivery(recordID: body.recordId, log: f.log))
        f.writeFailure = false
        try f.restore()
        XCTAssertNil(try f.journal.delivery(recordID: body.recordId, log: f.log))
        let record = try f.sign(body)
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        f.writeFailure = true
        XCTAssertThrowsError(try f.journal.stationStored(delivery))
        f.writeFailure = false
        try f.restore()
        let retry = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertFalse(retry.stationStored)
        XCTAssertEqual(retry.recordJSON, record)
    }

    @MainActor
    func testReentrancyAndContextChangeDuringKeyCallbackCannotExposeASignature() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        var current = true
        f.keys.beforeSign = {
            XCTAssertThrowsError(try f.journal.delivery(recordID: body.recordId, log: f.log)) {
                XCTAssertEqual($0 as? RemoteControlPublicationError, .busy)
            }
            current = false
        }
        XCTAssertThrowsError(try f.sign(body, current: { current }))
        XCTAssertFalse(f.journal.storageUncertain)
        XCTAssertNil(try f.journal.delivery(recordID: body.recordId, log: f.log))
    }

    @MainActor
    func testAWriteThatCommittedBeforeThrowingRecoversItsExactSignatureAndReceipt() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.sign(body))
        XCTAssertTrue(f.journal.storageUncertain)
        try f.restore()
        let delivery = try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log))
        XCTAssertEqual(try f.sign(body), delivery.recordJSON)
        XCTAssertEqual(f.keys.signs, 1)
        f.failAfterWrite = true
        XCTAssertThrowsError(try f.journal.stationStored(delivery))
        try f.restore()
        XCTAssertTrue(try XCTUnwrap(f.journal.delivery(recordID: body.recordId, log: f.log)).stationStored)
    }

    @MainActor
    func testAStoredCheckpointWithADamagedSignatureCannotProduceAPortalIntent() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        _ = try f.sign(body)
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(f.stored), format: nil) as? [String: Any])
        var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
        let record = try XCTUnwrap(operations[0]["recordJSON"] as? String)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
        envelope["sig"] = RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))
        operations[0]["recordJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        object["operations"] = operations
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)))
    }

    @MainActor
    func testSignedRetryRevalidatesManagerAndRetainsEvidenceWhenItNeedsResigning() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        _ = try f.sign(body)
        try f.append(["action": "add", "member": ["device_id": "other-manager", "kind": "native",
            "roles": ["control", "manage", "view"],
            "auth_key": ["alg": "ed25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)],
            "enc_key": ["alg": "x25519", "pub": RemoteRecoveryKit.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]]])
        try f.append(["action": "set_roles", "device_id": "manager", "roles": ["control", "view"]])
        try f.restore()
        XCTAssertEqual(f.journal.recordIDs, [body.recordId])
        XCTAssertNotNil(try f.journal.retainedDelivery(recordID: body.recordId)?.portalMirror,
            "manager removal cannot erase the already-confirmed Portal revoke intent")
        XCTAssertThrowsError(try f.journal.delivery(recordID: body.recordId, log: f.log)) {
            XCTAssertEqual($0 as? RemoteControlPublicationError, .requiresReview)
        }
        let alert = try XCTUnwrap(f.journal.activity(log: f.log).first)
        XCTAssertEqual(alert.body.recordId, body.recordId)
        XCTAssertTrue(alert.managerReviewRequired)
        XCTAssertTrue(alert.summary.contains("Fresh manager review"))
        XCTAssertTrue(alert.portalPending)
        XCTAssertTrue(try XCTUnwrap(f.journal.activity(log: f.log, status: [body.recordId: .effectsReported]).first)
            .summary.contains("Station reports"), "an effect already reported in force needs no automatic re-sign")
        XCTAssertEqual(f.keys.signs, 1)
    }

    @MainActor
    func testCheckpointCannotMoveToAnotherAccountGenesisStationOrClaimAnUnsignedDelivery() throws {
        let f = try ControlPublicationFixture(), body = try f.body()
        _ = try f.prepare(body)
        let saved = try XCTUnwrap(f.stored)
        for (account, genesis, origin) in [("foreign", f.log.genesisHash(), f.origin),
            (f.log.accountId(), String(repeating: "aa", count: 32), f.origin),
            (f.log.accountId(), f.log.genesisHash(), "https://other.example")] {
            XCTAssertThrowsError(try RemoteControlPublication(checkpoint: saved, accountID: account, genesisHash: genesis, stationOrigin: origin, persist: { _ in }))
        }
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
        var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
        operations[0]["stationStored"] = true
        object["operations"] = operations
        XCTAssertThrowsError(try f.restore(PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)))
    }

    @MainActor
    func testSameIDCannotBeReusedAndDifferentReceiptsCannotSettleEachOther() throws {
        let f = try ControlPublicationFixture(), first = try f.body(), second = try f.body(interrupt: true)
        _ = try f.prepare(first)
        _ = try f.prepare(first)
        var changed = first
        changed.interruptRunning = true
        XCTAssertThrowsError(try f.prepare(changed))
        _ = try f.prepare(second)
        _ = try f.sign(first)
        _ = try f.sign(second)
        let one = try XCTUnwrap(f.journal.delivery(recordID: first.recordId, log: f.log))
        let two = try XCTUnwrap(f.journal.delivery(recordID: second.recordId, log: f.log))
        let forged = RemoteControlDelivery(recordID: first.recordId, recordJSON: two.recordJSON, stationOrigin: f.origin,
            stationStored: false, portalMirror: one.portalMirror, portalMirrored: false, portalRefusal: nil)
        XCTAssertThrowsError(try f.journal.stationStored(forged))
        try f.journal.portalMirrored(one)
        XCTAssertFalse(try XCTUnwrap(f.journal.delivery(recordID: second.recordId, log: f.log)).portalMirrored)
        XCTAssertFalse(try XCTUnwrap(f.journal.delivery(recordID: first.recordId, log: f.log)).stationStored)
    }

    @MainActor
    func testFinalPortalRefusalSurvivesRestartWithoutClaimingStationOrHostDelivery() throws {
        for reason: RemoteControlPortalRefusal in [.tooLate, .stationRemoved] {
            let f = try ControlPublicationFixture(), body = try f.body(interrupt: true)
            _ = try f.prepare(body)
            let signed = try f.sign(body)
            let delivery = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
            try f.journal.portalRefused(delivery, reason: reason)
            try f.restore()
            let settled = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
            XCTAssertTrue(settled.portalSettled)
            XCTAssertFalse(settled.portalMirrored)
            XCTAssertEqual(settled.portalRefusal, reason)
            XCTAssertFalse(settled.stationStored)
            XCTAssertEqual(settled.recordJSON, signed)
            XCTAssertEqual(try f.journal.pendingDeliveryIDs(), [body.recordId], "Station leg remains pending")
            XCTAssertThrowsError(try f.journal.portalMirrored(delivery), "final refusal must not become confirmation")
            try f.journal.portalRefused(delivery, reason: reason)
            XCTAssertThrowsError(try f.journal.portalRefused(delivery, reason: reason == .tooLate ? .stationRemoved : .tooLate))
            try f.journal.stationStored(settled)
            try f.restore()
            XCTAssertTrue(try f.journal.pendingDeliveryIDs().isEmpty)
            XCTAssertEqual(f.keys.signs, 1)
        }
    }

    @MainActor
    func testUncertainFinalSettlementRequiresReloadAndRetainsTheOriginalSignature() throws {
        for committed in [false, true] {
            let f = try ControlPublicationFixture(), body = try f.body(interrupt: true)
            _ = try f.prepare(body)
            let signed = try f.sign(body)
            let delivery = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
            try f.journal.stationStored(delivery)
            f.writeFailure = !committed
            f.failAfterWrite = committed
            XCTAssertThrowsError(try f.journal.portalRefused(delivery, reason: .tooLate))
            XCTAssertTrue(f.journal.storageUncertain)
            XCTAssertThrowsError(try f.journal.pendingDeliveryIDs())
            f.writeFailure = false
            try f.restore()
            let resumed = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
            XCTAssertEqual(resumed.recordJSON, signed)
            XCTAssertEqual(resumed.portalRefusal, committed ? .tooLate : nil)
            XCTAssertEqual(try f.journal.pendingDeliveryIDs(), committed ? [] : [body.recordId])
            XCTAssertEqual(f.keys.signs, 1)
        }
    }

    @MainActor
    func testFinalRefusalCannotSettleNoninterruptingOrAlreadyConfirmedMirrors() throws {
        for interrupt in [false, true] {
            let f = try ControlPublicationFixture(), body = try f.body(interrupt: interrupt)
            _ = try f.prepare(body)
            _ = try f.sign(body)
            let delivery = try XCTUnwrap(f.journal.retainedDelivery(recordID: body.recordId))
            if interrupt { try f.journal.portalMirrored(delivery) }
            XCTAssertThrowsError(try f.journal.portalRefused(delivery, reason: .stationRemoved))
            try f.restore()
            XCTAssertNil(try f.journal.retainedDelivery(recordID: body.recordId)?.portalRefusal)
        }
    }
}
