import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class RecoveryMemoryCheckpoint: AstationRecoveryCheckpointStorage {
    var bytes: Data?
    var failAfterWrite = false
    var writes = 0
    func read() throws -> Data? { bytes }
    func write(_ data: Data) throws {
        writes += 1
        bytes = data
        if failAfterWrite { failAfterWrite = false; throw RemoteRecoveryError.storageUncertain }
    }
}

private final class RecoveryMemoryKeys: AstationRecoveryDataKeys {
    var keys: [AccountDataKey] = []
    var installs = 0
    var failNextInstall = false
    var didInstall: (() -> Void)?
    func recoveryKeys(dataAccount: String) throws -> [AccountDataKey] { keys }
    func generate() throws -> AccountDataKey { AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x19, count: 32)) }
    func install(_ value: AccountDataKey, dataAccount: String) throws {
        if failNextInstall { failNextInstall = false; throw RemoteRecoveryError.storageUncertain }
        keys = [value] + keys.filter { $0.kid != value.kid }
        installs += 1
        didInstall?()
    }
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
    var nextEntries: [String]?
    let hostKey = Curve25519.Signing.PrivateKey()

    func dropNextAppendReply() { loseAppendReply = true }
    func dropNextUploadReply() { loseUploadReply = true }
    func setHostOnline(_ value: Bool) { hostOnline = value }
    func hostPublicKey() -> Data { hostKey.publicKey.rawRepresentation }
    func injectNextEntries(_ entries: [String]) { nextEntries = entries }

    func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage {
        let log = try XCTUnwrap(log)
        XCTAssertEqual(log.genesisHash(), genesisHash)
        let page = nextEntries ?? log.entriesAfter(seq: after)
        nextEntries = nil
        return RemoteRecoveryLogPage(head: log.head(), entries: page, more: false)
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
            if try !log!.entries().contains(where: { try signedObjectInfo(json: $0).entryHash == entry.entryHash }) {
                return .conflict(RemoteRecoveryLogPage(head: log!.head(),
                    entries: log!.entriesAfter(seq: request.expected.seq), more: false))
            }
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
    var ownerConfirmation: ((SignRequest) async throws -> Bool)?

    func coordinator() throws -> AstationRecoveryCoordinator {
        try AstationRecoveryCoordinator(accountID: "account-a", managerID: "manager-a", identity: identity,
            relayURL: "https://configured.example", store: store, transport: relay, dataKeys: keys,
            allowNewDataKey: { true }, confirmOwner: { [unowned self] request in
                ownerRequests.append(request)
                if let ownerConfirmation {
                    do { return try await ownerConfirmation(request) }
                    catch { XCTFail("owner-confirmation test hook failed: \(error)"); return false }
                }
                return approve
            }, confirmReplacement: { _ in true }, saveKit: { [unowned self] kit in
                savedKits.append(kit)
                return save
            })
    }
}

@MainActor
final class AstationRecoveryCoordinatorTests: XCTestCase {
    func testChannelRefreshCommitsSignedMembershipAndAllowsViewOnlyButNeverRemovedDevices() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(await h.relay.hostPublicKey())]]], harness: h)
        let manager = try await addSecondManager(harness: h)
        try await append(["action": "set_roles", "device_id": "manager-a", "roles": ["view"]],
            harness: h, signer: "manager-b", identity: manager)
        let updatedValue = await h.relay.log
        let updated = try XCTUnwrap(updatedValue)
        try await coordinator!.refreshChannelMembership(hostID: "host-a", requiredHead: updated.head())
        XCTAssertEqual(try coordinator!.channelMembership(hostID: "host-a").member(deviceId: "manager-a")?.roles, ["view"])
        coordinator = nil
        coordinator = try h.coordinator()
        XCTAssertEqual(try coordinator!.channelMembership(hostID: "host-a").head(), updated.head())
        XCTAssertThrowsError(try coordinator!.channelMembership(hostID: "unknown-host"))
        do {
            try await coordinator!.refreshChannelMembership(hostID: "host-a", requiredHead: LogHead(seq: updated.head().seq, hash: String(repeating: "f", count: 64)))
            XCTFail("An authenticated head still needs a verified matching chain")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        try await append(["action": "remove", "device_id": "manager-a"], harness: h, signer: "manager-b", identity: manager)
        let removedValue = await h.relay.log
        let removed = try XCTUnwrap(removedValue)
        try await coordinator!.refreshChannelMembership(hostID: "host-a", requiredHead: removed.head())
        XCTAssertThrowsError(try coordinator!.channelMembership(hostID: "host-a"))
    }

    private func checkpoint(_ store: RecoveryMemoryCheckpoint) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(store.bytes), format: nil) as? [String: Any])
    }

    func testOldEntryOnlyCheckpointMigratesAndCommitsImmediatelyWithoutNetworkOrResigning() async throws {
        let h = RecoveryCoordinatorHarness()
        _ = try await h.coordinator().setup()
        var old = try checkpoint(h.store)
        old.removeValue(forKey: "membership")
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        let writes = h.store.writes
        let signatures = h.ownerRequests.count
        let appends = await h.relay.appends.count
        let loaded = try h.coordinator()
        XCTAssertEqual(h.store.writes, writes + 1)
        XCTAssertNotNil(try checkpoint(h.store)["membership"] as? String)
        XCTAssertEqual(h.ownerRequests.count, signatures)
        let after = await h.relay.appends.count
        XCTAssertEqual(after, appends)
        try loaded.checkpointPendingWaits()
    }

    func testFailedImmediateLoadCommitPreventsAnyOperationAndReloadReconcilesCommittedBytes() async throws {
        let h = RecoveryCoordinatorHarness()
        _ = try await h.coordinator().setup()
        let appends = await h.relay.appends.count
        let installs = h.keys.installs
        h.store.failAfterWrite = true
        XCTAssertThrowsError(try h.coordinator())
        XCTAssertEqual(h.keys.installs, installs)
        let after = await h.relay.appends.count
        XCTAssertEqual(after, appends)
        let resumed = try h.coordinator()
        _ = try await resumed.exportedKit()
        XCTAssertEqual(h.keys.installs, installs)
    }

    func testCorruptMembershipSnapshotFailsClosedWithoutDiscardingCheckpoint() async throws {
        let h = RecoveryCoordinatorHarness()
        _ = try await h.coordinator().setup()
        var corrupt = try checkpoint(h.store)
        corrupt["membership"] = "{}"
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: corrupt, format: .binary, options: 0)
        let before = h.store.bytes
        let writes = h.store.writes
        XCTAssertThrowsError(try h.coordinator())
        XCTAssertEqual(h.store.bytes, before)
        XCTAssertEqual(h.store.writes, writes)
    }

    func testConflictFreezeIsCommittedBeforeRefusalAndSurvivesAppRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let kit = try await coordinator!.setup()
        let storedChain = await h.relay.log
        let chain = try XCTUnwrap(storedChain)
        let genesis = try MembershipLog.verify(accountId: "account-a", genesisHash: kit.genesisHash,
            entries: [XCTUnwrap(chain.entries().first)], now: AstationRecoveryCoordinator.clock())
        let body = try genesis.draftEntry(signer: "manager-a", signedAt: AstationRecoveryCoordinator.clock().wallMs,
            actionJson: recoveryTestJSON(["action": "add_host", "host": ["host_id": "fork-host", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]]))
        let provider = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a", publicKey: try h.identity.remotePublicKeys().signing)
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager-a")
        let entry = try recoveryTestJSON(["body": JSONSerialization.jsonObject(with: Data(body.utf8)),
            "sig": recoveryTestBase64(provider.sign(request: request))])
        await h.relay.injectNextEntries([entry])
        do { _ = try await coordinator!.exportedKit(); XCTFail("fork must stop the operation") } catch {}
        let stored = try XCTUnwrap(checkpoint(h.store)["membership"] as? String)
        XCTAssertNotNil(try MembershipLog.fromStored(accountId: "account-a", genesisHash: kit.genesisHash,
            storedJson: stored, now: AstationRecoveryCoordinator.clock()).frozen())
        coordinator = nil
        coordinator = try h.coordinator()
        let signatures = h.ownerRequests.count
        do { _ = try await coordinator!.pairingKeys(nonce: Data(repeating: 8, count: 32)); XCTFail("freeze survives restart") } catch {}
        XCTAssertEqual(h.ownerRequests.count, signatures)
    }

    func testPendingRecoveryPeriodicCheckpointSurvivesRestartAndHaltsOnWriteFailure() async throws {
        let h = RecoveryCoordinatorHarness()
        let kit = try await h.coordinator().setup()
        let hostKey = await h.relay.hostPublicKey()
        try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(hostKey)]]], harness: h)
        await h.relay.setHostOnline(true)
        let store = RecoveryMemoryCheckpoint()
        let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        let keys = RecoveryMemoryKeys()
        let first = AstationRecoveryCoordinator.clock()
        var time = first
        func replacement() throws -> AstationRecoveryCoordinator {
            try AstationRecoveryCoordinator(accountID: "account-a", managerID: "replacement-a", identity: identity,
                relayURL: "https://configured.example", store: store, transport: h.relay, dataKeys: keys,
                allowNewDataKey: { false }, confirmOwner: { _ in false }, confirmReplacement: { _ in true },
                saveKit: { _ in false }, now: { time })
        }
        var coordinator: AstationRecoveryCoordinator? = try replacement()
        _ = try await coordinator!.restoreAccount(kit: kit)
        func at(_ hours: UInt64) -> HostClock {
            HostClock(wallMs: first.wallMs + hours * 3_600_000,
                monoMs: first.monoMs + hours * 3_600_000, bootId: first.bootId)
        }
        func deadline() throws -> UInt64? {
            let saved = try XCTUnwrap(checkpoint(store)["membership"] as? String)
            let log = try MembershipLog.fromStored(accountId: "account-a", genesisHash: kit.genesisHash, storedJson: saved, now: time)
            return try log.pendingRecovery(now: time).first?.effectiveAt
        }
        let original = try XCTUnwrap(deadline())
        time = at(10)
        try coordinator!.checkpointPendingWaits()
        coordinator = nil
        time = at(12)
        coordinator = try replacement()
        XCTAssertEqual(try deadline(), original, "An app restart must not restart the 24-hour wait")
        let appends = await h.relay.appends.count
        let installs = keys.installs
        store.failAfterWrite = true
        time = at(13)
        XCTAssertThrowsError(try coordinator!.checkpointPendingWaits())
        do { _ = try await coordinator!.exportedKit(); XCTFail("Uncertain periodic write must halt") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        let after = await h.relay.appends.count
        XCTAssertEqual(after, appends)
        XCTAssertEqual(keys.installs, installs)
    }

    private func append(_ action: [String: Any], harness h: RecoveryCoordinatorHarness,
        signer: String = "manager-a", identity: AtemE2EIdentity? = nil) async throws {
        let stored = await h.relay.log
        let log = try XCTUnwrap(stored)
        let publisher = RemoteMembershipPublication(log: log, persist: { _ in })
        _ = try publisher.prepare(actionJSON: recoveryTestJSON(action), signer: signer, signedAt: AstationRecoveryCoordinator.clock().wallMs)
        let identity = identity ?? h.identity
        let provider = AstationMembershipKeyProvider(identity: identity, keyID: signer, publicKey: try identity.remotePublicKeys().signing)
        let request = try publisher.sign(provider: provider, keyID: signer)
        _ = try await h.relay.append(genesisHash: log.genesisHash(), request: request)
        _ = try publisher.relayStored(now: AstationRecoveryCoordinator.clock())
    }

    private func addSecondManager(harness h: RecoveryCoordinatorHarness) async throws -> AtemE2EIdentity {
        let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        let keys = try identity.remotePublicKeys()
        try await append(["action": "add", "member": ["device_id": "manager-b", "kind": "native",
            "roles": ["control", "manage", "view"],
            "auth_key": ["alg": "p256", "pub": recoveryTestBase64(keys.signing)],
            "enc_key": ["alg": "x25519", "pub": recoveryTestBase64(keys.encryption)]]], harness: h)
        return identity
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

    func testKeychainInstallFailureAfterBackupCommitResumesWithoutAnotherSignatureOrUpload() async throws {
        let h = RecoveryCoordinatorHarness()
        h.keys.failNextInstall = true
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        do { _ = try await coordinator!.setup(); XCTFail("Keychain failure must be reported") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        XCTAssertTrue(h.keys.keys.isEmpty)
        let committedValue = await h.relay.log
        let committed = try XCTUnwrap(committedValue)
        XCTAssertEqual(committed.head().seq, 2)
        let requests = h.ownerRequests
        let uploads = await h.relay.uploads
        coordinator = nil
        coordinator = try h.coordinator()
        let kit = try await coordinator!.setup()
        XCTAssertEqual(kit.genesisHash, committed.genesisHash())
        XCTAssertEqual(h.ownerRequests, requests)
        let retriedUploads = await h.relay.uploads
        XCTAssertEqual(retriedUploads, uploads)
        XCTAssertEqual(h.keys.keys.map(\.kid), committed.kBackup()?.kids)
        XCTAssertEqual(h.keys.installs, 1)
        XCTAssertEqual(try h.identity.state(account: "account-a")?.mode, "off")
    }

    func testUncertainCheckpointAfterKeyInstallHaltsThenRestartsIdempotently() async throws {
        let h = RecoveryCoordinatorHarness()
        h.keys.didInstall = { h.store.failAfterWrite = true }
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        do { _ = try await coordinator!.setup(); XCTFail("the final checkpoint reply was lost") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        let installed = h.keys.keys
        XCTAssertEqual(installed.count, 1)
        let appends = await h.relay.appends
        let uploads = await h.relay.uploads
        do { _ = try await coordinator!.setup(); XCTFail("uncertain storage must halt this instance") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        h.keys.didInstall = nil
        coordinator = nil
        coordinator = try h.coordinator()
        _ = try await coordinator!.setup()
        XCTAssertEqual(h.keys.keys, installed)
        XCTAssertEqual(h.keys.installs, 1)
        let finalAppends = await h.relay.appends
        let finalUploads = await h.relay.uploads
        XCTAssertEqual(finalAppends, appends)
        XCTAssertEqual(finalUploads, uploads)
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup])
    }

    func testRotationWithLostCommitReplyKeepsOldKeyUntilRestartConfirmsTheExactBackup() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let kit = try await coordinator!.setup()
        let old = h.keys.keys
        let next = AccountDataKey(kid: "89abcdef", key: Data(repeating: 0x72, count: 32))
        await h.relay.dropNextAppendReply()
        do { try await coordinator!.installBackedUpKey(next); XCTFail("the commit reply was lost") } catch {}
        XCTAssertEqual(h.keys.keys, old)
        let committedValue = await h.relay.log
        let committed = try XCTUnwrap(committedValue)
        let committedHead = committed.head()
        let envelope = try await h.relay.backup(log: committed)
        XCTAssertEqual(try kit.openBackup(envelope), ([next] + old).map { AccountKey(kid: $0.kid, k: $0.key) })
        coordinator = nil
        coordinator = try h.coordinator()
        try await coordinator!.installBackedUpKey(next)
        XCTAssertEqual(h.keys.keys, [next] + old)
        let finalLogValue = await h.relay.log
        let finalLog = try XCTUnwrap(finalLogValue)
        XCTAssertEqual(finalLog.head(), committedHead)
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup, .keyBackup])
        let uploads = await h.relay.uploads
        XCTAssertTrue(uploads.dropFirst().allSatisfy { $0 == envelope })
    }

    func testConcurrentSetupWhileOwnerDialogIsOpenIsBusyAndCreatesOnlyOneRoot() async throws {
        let h = RecoveryCoordinatorHarness()
        let entered = expectation(description: "owner confirmation is open")
        var release: CheckedContinuation<Bool, Never>?
        h.ownerConfirmation = { request in
            if request.purpose == .genesis {
                return await withCheckedContinuation { release = $0; entered.fulfill() }
            }
            return true
        }
        let coordinator = try h.coordinator()
        let first = Task { try await coordinator.setup() }
        await fulfillment(of: [entered], timeout: 5)
        do { _ = try await coordinator.exportedKit(); XCTFail("overlapping operations must be refused") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .busy) }
        let beforeApproval = await h.relay.appends
        XCTAssertTrue(beforeApproval.isEmpty)
        release?.resume(returning: true)
        let kit = try await first.value
        let reexported = try await coordinator.exportedKit()
        XCTAssertEqual(kit, reexported)
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup])
    }

    func testMembershipCASRaceRequiresConfirmationOfTheNewExactBackupBody() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator()
        let kit = try await coordinator.setup()
        let old = h.keys.keys
        let manager = try await addSecondManager(harness: h)
        var raced = false
        h.ownerConfirmation = { [self] request in
            if request.purpose == .keyBackup, !raced {
                raced = true
                let hostKey = await h.relay.hostPublicKey()
                try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
                    "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(hostKey)]]], harness: h,
                    signer: "manager-b", identity: manager)
            }
            XCTAssertEqual(h.keys.keys, old)
            return true
        }
        defer { h.ownerConfirmation = nil }
        let next = AccountDataKey(kid: "89abcdef", key: Data(repeating: 0x72, count: 32))
        try await coordinator.installBackedUpKey(next)
        let backups = Array(h.ownerRequests.filter { $0.purpose == .keyBackup }.dropFirst())
        XCTAssertEqual(backups.count, 2)
        XCTAssertNotEqual(backups.first?.bodyJson, backups.last?.bodyJson)
        let logValue = await h.relay.log
        let log = try XCTUnwrap(logValue)
        XCTAssertNotNil(log.host(hostId: "host-a"))
        XCTAssertEqual(log.head().seq, 5)
        let envelope = try await h.relay.backup(log: log)
        XCTAssertEqual(try kit.openBackup(envelope).map(\.kid), h.keys.keys.map(\.kid))
        XCTAssertEqual(h.keys.keys, [next] + old)
        XCTAssertEqual(h.keys.installs, 2)
    }

    func testManagerRemovalDuringOwnerConfirmationCannotCommitBackupOrInstallKey() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        let old = h.keys.keys
        let manager = try await addSecondManager(harness: h)
        h.ownerConfirmation = { [self] request in
            if request.purpose == .keyBackup {
                try await append(["action": "remove", "device_id": "manager-a"], harness: h,
                    signer: "manager-b", identity: manager)
            }
            return true
        }
        defer { h.ownerConfirmation = nil }
        let next = AccountDataKey(kid: "89abcdef", key: Data(repeating: 0x72, count: 32))
        do { try await coordinator!.installBackedUpKey(next); XCTFail("a removed manager cannot commit") } catch {}
        XCTAssertEqual(h.keys.keys, old)
        let logValue = await h.relay.log
        let log = try XCTUnwrap(logValue)
        XCTAssertEqual(log.kBackup()?.kids, old.map(\.kid))
        coordinator = nil
        coordinator = try h.coordinator()
        do { _ = try await coordinator!.setup(); XCTFail("restart must retain the removal") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.keys.installs, 1)
        XCTAssertEqual(h.ownerRequests.map(\.purpose), [.genesis, .keyBackup, .keyBackup])
    }

    func testRestoreWithLostEnrollmentReplyResumesWithoutASecondConsentOrReplacementEntry() async throws {
        let h = RecoveryCoordinatorHarness()
        let kit = try await h.coordinator().setup()
        let hostKey = await h.relay.hostPublicKey()
        try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(hostKey)]]], harness: h)
        await h.relay.setHostOnline(true)
        let store = RecoveryMemoryCheckpoint()
        let keys = RecoveryMemoryKeys()
        let identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        var approvals = 0
        func replacement() throws -> AstationRecoveryCoordinator {
            try AstationRecoveryCoordinator(accountID: "account-a", managerID: "replacement-a", identity: identity,
                relayURL: "https://configured.example", store: store, transport: h.relay, dataKeys: keys,
                allowNewDataKey: { false }, confirmOwner: { _ in XCTFail("retain the original genesis"); return false },
                confirmReplacement: { _ in approvals += 1; return true }, saveKit: { _ in false })
        }
        await h.relay.dropNextAppendReply()
        var coordinator: AstationRecoveryCoordinator? = try replacement()
        do { _ = try await coordinator!.restoreAccount(kit: kit); XCTFail("the enrollment reply was lost") } catch {}
        XCTAssertEqual(keys.keys, h.keys.keys)
        XCTAssertEqual(approvals, 1)
        let committedValue = await h.relay.log
        let head = try XCTUnwrap(committedValue).head()
        coordinator = nil
        coordinator = try replacement()
        _ = try await coordinator!.restoreAccount(kit: kit)
        XCTAssertEqual(approvals, 1)
        let resumedValue = await h.relay.log
        XCTAssertEqual(try XCTUnwrap(resumedValue).head(), head)
        let requests = await h.relay.appends
        let recovery = try requests.filter {
            let object = try JSONSerialization.jsonObject(with: Data($0.entryJson.utf8)) as? [String: Any]
            return (object?["body"] as? [String: Any])?["action"] as? String == "recovery_add"
        }
        XCTAssertFalse(recovery.isEmpty)
        XCTAssertTrue(recovery.allSatisfy { $0 == recovery.first })
        do { _ = try await coordinator!.pairingKeys(nonce: Data(repeating: 9, count: 32)); XCTFail("still pending") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .enrollmentPending) }
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
