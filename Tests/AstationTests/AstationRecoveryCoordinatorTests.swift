import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class RecoveryMemoryCheckpoint: AstationRecoveryCheckpointStorage {
    var bytes: Data?
    var failAfterWrite = false
    func read() throws -> Data? { bytes }
    func write(_ data: Data) throws {
        bytes = data
        if failAfterWrite { failAfterWrite = false; throw RemoteRecoveryError.storageUncertain }
    }
}

private final class RecoveryMemoryKeys: AstationRecoveryDataKeys {
    var keys: [AccountDataKey] = []
    var installs = 0
    func recoveryKeys(dataAccount: String) throws -> [AccountDataKey] { keys }
    func generate() throws -> AccountDataKey { AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x19, count: 32)) }
    func install(_ value: AccountDataKey, dataAccount: String) throws { keys = [value] + keys.filter { $0.kid != value.kid }; installs += 1 }
    func installRecovered(_ values: [AccountDataKey], dataAccount: String) throws { keys = values; installs += 1 }
}

private actor RecoveryMemoryRelay: RemoteRecoveryTransport {
    var log: MembershipLog?
    var account = "account-a"
    var appends: [AppendRequest] = []
    var uploads: [String] = []
    var envelopes: [UInt64: String] = [:]
    var loseAppendReply = false
    var loseUploadReply = false
    var hostOnline = false
    let hostKey = Curve25519.Signing.PrivateKey()

    func dropNextAppendReply() { loseAppendReply = true }
    func dropNextUploadReply() { loseUploadReply = true }
    func setHostOnline(_ value: Bool) { hostOnline = value }
    func hostPublicKey() -> Data { hostKey.publicKey.rawRepresentation }

    func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage {
        let log = try XCTUnwrap(log)
        XCTAssertEqual(log.genesisHash(), genesisHash)
        return RemoteRecoveryLogPage(head: log.head(), entries: log.entriesAfter(seq: after), more: false)
    }
    func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply {
        appends.append(request)
        if log == nil {
            log = try MembershipLog.verify(accountId: account, genesisHash: genesisHash, entries: [request.entryJson], now: AstationRecoveryCoordinator.clock())
        } else if log!.head() == request.expected {
            let result = try log!.extend(entries: [request.entryJson], now: AstationRecoveryCoordinator.clock())
            XCTAssertNil(result.stop)
            XCTAssertEqual(result.appended, 1)
        } else {
            let entry = try signedObjectInfo(json: request.entryJson)
            XCTAssertTrue(try log!.entries().contains { try signedObjectInfo(json: $0).entryHash == entry.entryHash })
        }
        if loseAppendReply { loseAppendReply = false; throw RemoteRecoveryTransportError.unavailable }
        return .stored
    }
    func uploadBackup(genesisHash: String, envelopeJSON: String, signedEntryJSON: String) async throws -> UInt64? {
        let info = try parseKBackup(envelopeJson: envelopeJSON)
        XCTAssertEqual(log?.genesisHash(), genesisHash)
        XCTAssertEqual(try signedObjectInfo(json: signedEntryJSON).bodyType, "atem-membership-entry")
        uploads.append(envelopeJSON)
        if let existing = envelopes[info.blobVersion], existing != envelopeJSON { return info.blobVersion }
        envelopes[info.blobVersion] = envelopeJSON
        if loseUploadReply { loseUploadReply = false; throw RemoteRecoveryTransportError.unavailable }
        return nil
    }
    func backup(log: MembershipLog) async throws -> String { try XCTUnwrap(envelopes[try XCTUnwrap(log.kBackup()).blobVersion]) }
    func hostAccept(genesisHash: String, hostID: String, initFrame: Data) async throws -> Data {
        guard hostOnline, let log else { throw RemoteRecoveryTransportError.unavailable }
        XCTAssertEqual(log.genesisHash(), genesisHash)
        XCTAssertEqual(hostID, "host-a")
        var accept: [String: Any] = ["ch": "atem-ch1", "op": "accept",
            "e": recoveryTestBase64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            "n": recoveryTestBase64(Data(repeating: 2, count: 32)),
            "head": ["seq": log.head().seq, "hash": log.head().hash], "sig": recoveryTestBase64(Data(repeating: 0, count: 64))]
        let th2 = try hostAcceptTh2(initJson: String(decoding: initFrame, as: UTF8.self), acceptJson: recoveryTestJSON(accept))
        let raw = Data(stride(from: 0, to: th2.count, by: 2).map { i in
            UInt8(th2.dropFirst(i).prefix(2), radix: 16)!
        })
        accept["sig"] = recoveryTestBase64(try hostKey.signature(for: signingInput(label: .channelHost, payload: raw)))
        return Data(try recoveryTestJSON(accept).utf8)
    }
}

private func recoveryTestBase64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func recoveryTestJSON(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@MainActor
private final class RecoveryCoordinatorHarness {
    let store = RecoveryMemoryCheckpoint()
    let keys = RecoveryMemoryKeys()
    let relay = RecoveryMemoryRelay()
    let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
    var ownerRequests: [SignRequest] = []
    var savedKits: [String] = []
    var approve = true
    var save = true

    func coordinator() throws -> AstationRecoveryCoordinator {
        try AstationRecoveryCoordinator(accountID: "account-a", managerID: "manager-a", identity: identity,
            relayURL: "https://configured.example", store: store, transport: relay, dataKeys: keys,
            allowNewDataKey: { true }, confirmOwner: { [unowned self] request in
                ownerRequests.append(request)
                return approve
            }, confirmReplacement: { _ in true }, saveKit: { [unowned self] kit in
                savedKits.append(kit)
                return save
            })
    }
}

@MainActor
final class AstationRecoveryCoordinatorTests: XCTestCase {
    private func append(_ action: [String: Any], harness h: RecoveryCoordinatorHarness) async throws {
        let stored = await h.relay.log
        let log = try XCTUnwrap(stored)
        let publisher = RemoteMembershipPublication(log: log, persist: { _ in })
        _ = try publisher.prepare(actionJSON: recoveryTestJSON(action), signer: "manager-a", signedAt: AstationRecoveryCoordinator.clock().wallMs)
        let provider = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a", publicKey: try h.identity.remotePublicKeys().signing)
        let request = try publisher.sign(provider: provider, keyID: "manager-a")
        _ = try await h.relay.append(genesisHash: log.genesisHash(), request: request)
        _ = try publisher.relayStored(now: AstationRecoveryCoordinator.clock())
    }

    func testRepeatedSetupReusesTheCommittedBackupWithoutSigningAgain() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator()
        let kit = try await coordinator.setup()
        let reexported = try await coordinator.exportedKit()
        XCTAssertEqual(kit, reexported)
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup])
        let uploads = await h.relay.uploads
        XCTAssertEqual(uploads.count, 1)
    }

    func testKeyRotationBacksUpCurrentAndRetainedKeysBeforeInstallAndRetriesExactBytes() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let kit = try await coordinator!.setup()
        let old = h.keys.keys
        let next = AccountDataKey(kid: "89abcdef", key: Data(repeating: 0x72, count: 32))
        await h.relay.dropNextUploadReply()
        do { try await coordinator!.installBackedUpKey(next); XCTFail("the upload reply was lost") } catch {}
        XCTAssertEqual(h.keys.keys, old)
        coordinator = nil
        coordinator = try h.coordinator()
        try await coordinator!.installBackedUpKey(next)
        XCTAssertEqual(h.keys.keys, [next] + old)
        let logValue = await h.relay.log
        let log = try XCTUnwrap(logValue)
        let envelope = try await h.relay.backup(log: log)
        XCTAssertEqual(try kit.openBackup(envelope), ([next] + old).map { AccountKey(kid: $0.kid, k: $0.key) })
        let uploads = await h.relay.uploads
        XCTAssertEqual(uploads[1], uploads[2])
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup, .keyBackup])
        XCTAssertEqual(try h.identity.state(account: "account-a")?.mode, "off")
    }

    func testRestoreWaitsForHostThenPublishesExactlyOneReplacementAndCanResumeAfterApproval() async throws {
        let h = RecoveryCoordinatorHarness()
        let kit = try await h.coordinator().setup()
        let hostKey = await h.relay.hostPublicKey()
        try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(hostKey)]]], harness: h)
        let restoredStore = RecoveryMemoryCheckpoint()
        let restoredKeys = RecoveryMemoryKeys()
        let restoredIdentity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        var replacementApprovals = 0
        func replacement() throws -> AstationRecoveryCoordinator {
            try AstationRecoveryCoordinator(accountID: "account-a", managerID: "replacement-a", identity: restoredIdentity,
                relayURL: "https://configured.example", store: restoredStore, transport: h.relay, dataKeys: restoredKeys,
                allowNewDataKey: { false }, confirmOwner: { _ in XCTFail("no new genesis or backup needed"); return false },
                confirmReplacement: { _ in replacementApprovals += 1; return true }, saveKit: { _ in XCTFail("retain the imported kit"); return false })
        }
        var coordinator: AstationRecoveryCoordinator? = try replacement()
        let waiting = try await coordinator!.restoreAccount(kit: kit)
        XCTAssertTrue(waiting.contains("reach one"))
        XCTAssertEqual(restoredKeys.installs, 0)
        XCTAssertEqual(replacementApprovals, 0)
        await h.relay.setHostOnline(true)
        let status = try await coordinator!.restoreAccount(kit: kit)
        XCTAssertTrue(status.contains("Recovery requested"))
        XCTAssertEqual(restoredKeys.keys, h.keys.keys)
        XCTAssertTrue(try restoredIdentity.recoveryIsSaved())
        XCTAssertEqual(replacementApprovals, 1)
        do {
            _ = try await coordinator!.pairingKeys(nonce: Data(repeating: 9, count: 32))
            XCTFail("a pending replacement cannot pair")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .enrollmentPending) }
        coordinator = nil
        coordinator = try replacement()
        _ = try await coordinator!.restoreAccount(kit: kit)
        XCTAssertEqual(replacementApprovals, 1)
        let storedLog = await h.relay.log
        let log = try XCTUnwrap(storedLog)
        let recovery = try XCTUnwrap(log.entries().last)
        let target = try XCTUnwrap(signedObjectInfo(json: recovery).entryHash)
        try await append(["action": "recovery_approve", "target": target], harness: h)
        let keys = try await coordinator!.pairingKeys(nonce: Data(repeating: 9, count: 32))
        XCTAssertEqual(keys.genesisHash, kit.genesisHash)
        let reexported = try await coordinator!.exportedKit()
        XCTAssertEqual(reexported, kit)
        XCTAssertEqual(replacementApprovals, 1)
        let published = await h.relay.appends
        XCTAssertEqual(try published.filter {
            let object = try JSONSerialization.jsonObject(with: Data($0.entryJson.utf8)) as? [String: Any]
            return (object?["body"] as? [String: Any])?["action"] as? String == "recovery_add"
        }.count, 1)
    }

    func testSetupPublishesGenesisAndBackupBeforeInstallingKAndPreservesEncryptionOff() async throws {
        let h = RecoveryCoordinatorHarness()
        let kit = try await h.coordinator().setup()
        XCTAssertEqual(kit.accountID, "account-a")
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup])
        XCTAssertEqual(h.savedKits, [kit.text()])
        XCTAssertEqual(h.keys.installs, 1)
        XCTAssertEqual(try h.identity.state(account: "account-a")?.mode, "off")
        let storedLog = await h.relay.log
        let log = try XCTUnwrap(storedLog)
        XCTAssertEqual(log.kBackup()?.kids, ["0123abcd"])
        XCTAssertEqual(log.head().seq, 2)
        XCTAssertEqual(kit.genesisHash, log.genesisHash())
    }

    func testLostGenesisReplyRestartsWithTheExactSignedEntryAndNoSecondGenesisConfirmation() async throws {
        let h = RecoveryCoordinatorHarness()
        await h.relay.dropNextAppendReply()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        do { _ = try await coordinator!.setup(); XCTFail("lost reply must be reported") } catch {}
        XCTAssertTrue(h.savedKits.isEmpty)
        XCTAssertTrue(h.keys.keys.isEmpty)
        coordinator = nil
        coordinator = try h.coordinator()
        _ = try await coordinator!.setup()
        let requests = await h.relay.appends
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(h.ownerRequests.filter { $0.purpose == .genesis }.count, 1)
        XCTAssertEqual(h.keys.installs, 1)
    }

    func testLostBackupUploadReplyRestartsWithoutResealingOrSigningASibling() async throws {
        let h = RecoveryCoordinatorHarness()
        await h.relay.dropNextUploadReply()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        do { _ = try await coordinator!.setup(); XCTFail("lost reply must be reported") } catch {}
        XCTAssertEqual(h.keys.installs, 0)
        coordinator = nil
        coordinator = try h.coordinator()
        _ = try await coordinator!.setup()
        let uploads = await h.relay.uploads
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0], uploads[1])
        XCTAssertEqual(h.ownerRequests.filter { $0.purpose == .keyBackup }.count, 1)
        XCTAssertEqual(h.keys.installs, 1)
    }

    func testOwnerOrKitSaveCancellationRetainsThePreparedOperationAndNeverInstallsKeys() async throws {
        for denyOwner in [false, true] {
            let h = RecoveryCoordinatorHarness()
            h.approve = !denyOwner; h.save = denyOwner
            let coordinator = try h.coordinator()
            do { _ = try await coordinator.setup(); XCTFail("cancellation must be reported") } catch {}
            XCTAssertNotNil(h.store.bytes)
            XCTAssertEqual(h.keys.installs, 0)
            if denyOwner { let requests = await h.relay.appends; XCTAssertTrue(requests.isEmpty) }
        }
    }

    func testUncertainCheckpointHaltsTheInstanceBeforeAnyNetworkEffect() async throws {
        let h = RecoveryCoordinatorHarness()
        h.store.failAfterWrite = true
        let coordinator = try h.coordinator()
        for _ in 0..<2 {
            do { _ = try await coordinator.setup(); XCTFail("uncertain storage must halt") } catch {}
        }
        let requests = await h.relay.appends
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(h.ownerRequests.isEmpty)
        XCTAssertEqual(h.keys.installs, 0)
    }
}
