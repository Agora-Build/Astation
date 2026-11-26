import AppKit
import AtemClient
@testable import AstationRemote
import CryptoKit
import os
import Security
import Vision
import XCTest
@testable import Menubar

private actor ApprovalReportMailbox: RemoteVerifierReportTransport {
    private var reports: [String: [String]] = [:]
    private(set) var reads: [String] = []
    var discardOnRead = false
    func discardReports() { discardOnRead = true }

    func submitVerifierChallenge(genesisHash: String, challengeJSON: String, expected: LogHead) throws -> RemoteVerifierReportMailbox {
        XCTAssertNil(reports[challengeJSON], "Approval must not reissue a nonce after confirmation")
        reports[challengeJSON] = []
        return RemoteVerifierReportMailbox(challengeJSON: challengeJSON, reports: [])
    }
    func verifierReports(genesisHash: String, challengeJSON: String, expected: LogHead) throws -> RemoteVerifierReportMailbox {
        reads.append(challengeJSON)
        return RemoteVerifierReportMailbox(challengeJSON: challengeJSON,
            reports: discardOnRead ? [] : try XCTUnwrap(reports[challengeJSON]))
    }
    func verifierChallenges(genesisHash: String, signer: String, slot: String, expected: LogHead) throws -> [String] {
        try reports.keys.filter {
            let challenge = try parseVerifierReportChallenge(challengeJson: $0)
            return challenge.signer == signer && challenge.slot == slot
        }
    }
    func publishVerifierReport(genesisHash: String, challengeJSON: String, expected: LogHead, reportJSON: String) throws -> RemoteVerifierReportMailbox {
        XCTAssertNotNil(reports[challengeJSON])
        reports[challengeJSON] = [reportJSON]
        return RemoteVerifierReportMailbox(challengeJSON: challengeJSON, reports: [reportJSON])
    }
}

private final class RecoveryReportHTTPStub: URLProtocol {
    static let lock = NSLock()
    static var response: ((URLRequest, Data) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let reply = try Self.lock.withLock { try XCTUnwrap(Self.response)(request, bytes) }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}

@MainActor
private final class RecoveryMemoryCheckpoint: AstationRecoveryCheckpointStorage {
    var bytes: Data?
    var failAfterWrite = false
    var failAtEntryCount: Int?
    var failOnRemoval = false
    var failOnControlSignature = false
    var failOnVerifierRoster = false
    var failOnProcessRoster = false
    var writes = 0
    var readFailure = false
    func read() throws -> Data? {
        if readFailure { throw RemoteRecoveryStoreError.keychain(errSecInteractionNotAllowed) }
        return bytes
    }
    func write(_ data: Data) throws {
        writes += 1
        bytes = data
        if failOnProcessRoster,
           let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           saved["processRosters"] != nil {
            failOnProcessRoster = false
            throw RemoteRecoveryError.storageUncertain
        }
        if failOnVerifierRoster,
           let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           (saved["verifierRosters"] as? [String: Any])?.isEmpty == false {
            failOnVerifierRoster = false
            throw RemoteRecoveryError.storageUncertain
        }
        if failOnControlSignature,
           let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let controls = saved["controlPublications"] as? [String: Data],
           try controls.values.contains(where: { bytes in
               let journal = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
               return (journal?["operations"] as? [[String: Any]])?.contains(where: { $0["recordJSON"] != nil }) == true
           }) {
            failOnControlSignature = false
            throw RemoteRecoveryError.storageUncertain
        }
        if failOnRemoval, let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           saved["serviceRemoval"] != nil {
            failOnRemoval = false
            throw RemoteRecoveryError.storageUncertain
        }
        if let count = failAtEntryCount,
           let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           (saved["entries"] as? [String])?.count == count {
            failAtEntryCount = nil
            throw RemoteRecoveryError.storageUncertain
        }
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

private actor RecoveryMemoryRelay: RemoteControlStationTransport, RemoteDeviceEnrollmentTransport, RemoteControlFeedTransport, RemoteControlStatusTransport, RemoteControlRecoveryReviewTransport, RemoteControlRecoveryRetentionTransport, RemoteStationVerifierTransport {
    nonisolated let controlStationOrigin: String
    init(stationOrigin: String = "https://configured.example", controlFeedID: String = UUID().uuidString.lowercased()) {
        controlStationOrigin = stationOrigin
        self.controlFeedID = controlFeedID
    }
    var log: MembershipLog?
    var account = "account-a"
    var appends: [AppendRequest] = []
    var uploads: [String] = []
    var envelopes: [UInt64: String] = [:]
    var loseAppendReply = false
    var loseAppendNumber: Int?
    var loseUploadReply = false
    var hostOnline = false
    var nextEntries: [String]?
    var entriesUnavailable = false
    var beforeEntriesReply: (@Sendable () async -> Void)?
    var ignoreAppends = false
    var nextAppendLog: MembershipLog?
    var pageSize = 64
    let hostKey = Curve25519.Signing.PrivateKey()
    var deviceMailboxes: [String: RemoteDeviceEnrollmentMailbox] = [:]
    var loseDeviceResponseReply = false
    let controlFeedID: String
    var controlRecords: [String] = []
    var controlAttempts = 0
    var loseControlReply = false
    var outageAfterControlReply = false
    var controlTime: UInt64 = 1
    var controlStatusWaiter: CheckedContinuation<Void, Never>?
    var holdControlStatus = false
    var statusReads: [[String]] = []
    var syncReads: [UInt64] = []
    var holdControlSync = false
    var controlSyncWaiter: CheckedContinuation<Void, Never>?
    var wrongSyncCorrelation = false
    var verifierGeneration: UInt64 = 1
    var verifierReplicas = ["a", "b"]
    var preparedRecovery: RemoteControlRecoveryPreparation?
    var recoveryReviewWaiter: CheckedContinuation<Void, Never>?
    var holdRecoveryReview = false
    var recoveryCopies: [String] = []
    var loseRecoveryCopyReply = false
    var holdRecoveryCopy = false
    var recoveryCopyWaiter: CheckedContinuation<Void, Never>?

    func sentRecoveryCopies() -> [String] { recoveryCopies }
    func loseNextRecoveryCopyReply() { loseRecoveryCopyReply = true }
    func holdNextRecoveryCopy() { holdRecoveryCopy = true }
    func recoveryCopyIsWaiting() -> Bool { recoveryCopyWaiter != nil }
    func releaseRecoveryCopy() { holdRecoveryCopy = false; recoveryCopyWaiter?.resume(); recoveryCopyWaiter = nil }
    func retainControlRecoveryCopies(context: RemoteControlRecoveryContext, copiesJSON: String) async throws -> RemoteControlRecoveryRetention {
        XCTAssertEqual(context, preparedRecovery?.context)
        let ids = try RemoteControlRecoveryRetention.requestIDs(context: context, json: copiesJSON)
        recoveryCopies.append(copiesJSON)
        if holdRecoveryCopy { await withCheckedContinuation { recoveryCopyWaiter = $0 } }
        if loseRecoveryCopyReply { loseRecoveryCopyReply = false; throw RemoteRecoveryTransportError.unavailable }
        return RemoteControlRecoveryRetention(recordIDs: ids, reconstructionHash: String(repeating: "e", count: 64))
    }

    func setRecoveryReview(_ value: RemoteControlRecoveryPreparation) { preparedRecovery = value }
    func holdNextRecoveryReview() { holdRecoveryReview = true }
    func releaseRecoveryReview() { holdRecoveryReview = false; recoveryReviewWaiter?.resume(); recoveryReviewWaiter = nil }
    func recoveryReviewIsWaiting() -> Bool { recoveryReviewWaiter != nil }
    func controlRecoveryReview(accountID: String, genesisHash: String, expected: LogHead) async throws -> RemoteControlRecoveryPreparation {
        XCTAssertEqual(accountID, account)
        XCTAssertEqual(genesisHash, log?.genesisHash())
        XCTAssertEqual(expected, log?.head())
        if holdRecoveryReview { await withCheckedContinuation { recoveryReviewWaiter = $0 } }
        guard let preparedRecovery else { throw RemoteRecoveryTransportError.unavailable }
        return preparedRecovery
    }

    func setVerifierRoster(generation: UInt64, replicas: [String]) { verifierGeneration = generation; verifierReplicas = replicas }
    private var verifierConnection: UInt64?
    func setVerifierConnection(_ value: UInt64?) { verifierConnection = value }
    func stationVerifiers(genesisHash: String) throws -> RemoteStationVerifierSnapshot {
        let log = try XCTUnwrap(log)
        XCTAssertEqual(genesisHash, log.genesisHash())
        let data = try JSONSerialization.data(withJSONObject: ["origin": controlStationOrigin,
            "roster_generation": verifierGeneration, "account_id": account, "genesis_hash": genesisHash,
            "head": ["seq": log.head().seq, "hash": log.head().hash],
            "replicas": verifierReplicas.map { id -> [String: Any] in
                guard let verifierConnection else { return ["id": id] }
                let inventory = verifierInventory()
                return ["id": id, "connection_generation": verifierConnection, "authorization_ms_left": 30_000,
                        "verifier": ["version": inventory.version, "actions": inventory.actions]]
            }])
        return try RemoteStationVerifierSnapshot.decode(data, origin: controlStationOrigin, genesis: genesisHash,
            startedAt: RemoteVerifierSigningGate.evidenceTimeMilliseconds())
    }

    func holdNextControlSync() { holdControlSync = true }
    func releaseControlSync() { holdControlSync = false; controlSyncWaiter?.resume(); controlSyncWaiter = nil }
    func corruptControlSync(_ value: Bool = true) { wrongSyncCorrelation = value }
    func replaceControlRecords(_ records: [String]) { controlRecords = records }
    func controlSync(genesisHash: String, callJSON: String) async throws -> String {
        guard case .controlSync(let id, let origin, let feed, let after) = try relayDecodeToStation(message: callJSON) else {
            throw RemoteChannelError.invalidInput
        }
        XCTAssertEqual(log?.genesisHash(), genesisHash)
        XCTAssertEqual(feed, controlFeedID)
        syncReads.append(after)
        if holdControlSync { await withCheckedContinuation { controlSyncWaiter = $0 } }
        let records = controlRecords.enumerated().filter { UInt64($0.offset + 1) > after }.prefix(64)
            .map { RelayFeedRecord(feedSeq: UInt64($0.offset + 1), recordJson: $0.element) }
        return try relayControlSyncResult(requestId: wrongSyncCorrelation ? UUID().uuidString.lowercased() : id,
            origin: origin, feedId: controlFeedID, after: after, head: UInt64(controlRecords.count),
            stationTime: AstationRecoveryCoordinator.clock().wallMs, records: records)
    }

    func holdNextControlStatus() { holdControlStatus = true }
    func releaseControlStatus() { holdControlStatus = false; controlStatusWaiter?.resume(); controlStatusWaiter = nil }
    func controlStatus(genesisHash: String, recordIDs: [String], expected: LogHead) async throws -> [String: RemoteControlApplicationState] {
        XCTAssertEqual(log?.genesisHash(), genesisHash)
        XCTAssertEqual(log?.head(), expected)
        statusReads.append(recordIDs)
        if holdControlStatus { await withCheckedContinuation { controlStatusWaiter = $0 } }
        return Dictionary(uniqueKeysWithValues: recordIDs.map { ($0, .awaitingApplication) })
    }

    func dropControlReply(disableEntries: Bool = false) { loseControlReply = true; outageAfterControlReply = disableEntries }
    func controls() -> [String] { controlRecords }
    func controlCallCount() -> Int { controlAttempts }
    func controlHeads(genesisHash: String) async throws -> String {
        let log = try XCTUnwrap(log)
        XCTAssertEqual(log.genesisHash(), genesisHash)
        return try relayHeads(feeds: [RelayFeedHead(origin: controlStationOrigin, feedId: controlFeedID,
            head: UInt64(controlRecords.count), stationTime: AstationRecoveryCoordinator.clock().wallMs)], membership: log.head())
    }
    func reserveControlTime(genesisHash: String, principal: String, managerID: String, expected: LogHead) async throws -> UInt64 {
        XCTAssertEqual(log?.head(), expected)
        controlTime = max(controlTime + 1, AstationRecoveryCoordinator.clock().wallMs)
        return controlTime
    }
    @MainActor func publishControl(log: MembershipLog, recordJSON: String) async throws -> Bool {
        guard case .valid = try verifyControlRecord(log: log, recordJson: recordJSON) else { throw RemoteRecoveryTransportError.invalidResponse }
        return try await acceptControl(recordJSON, expected: log.head())
    }
    private func acceptControl(_ record: String, expected: LogHead) throws -> Bool {
        controlAttempts += 1
        XCTAssertEqual(log?.head(), expected)
        let appended = !controlRecords.contains(record)
        if appended { controlRecords.append(record) }
        if loseControlReply {
            loseControlReply = false
            if outageAfterControlReply { entriesUnavailable = true; outageAfterControlReply = false }
            throw RemoteRecoveryTransportError.unavailable
        }
        return appended
    }

    func dropNextDeviceResponseReply() { loseDeviceResponseReply = true }

    func createEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        if deviceMailboxes[invitation.id] == nil {
            deviceMailboxes[invitation.id] = RemoteDeviceEnrollmentMailbox(expires: invitation.expires, request: nil, response: nil)
        }
        return deviceMailboxes[invitation.id]!
    }
    func readEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        guard let value = deviceMailboxes[invitation.id] else { throw RemoteDeviceEnrollmentTransportError.notFound }
        return value
    }
    func submitEnrollment(_ request: RemoteDeviceEnrollmentRequest, invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        let previous = try await readEnrollment(invitation, now: now)
        guard previous.request == nil || previous.request == request else { throw RemoteDeviceEnrollmentTransportError.conflict }
        let value = RemoteDeviceEnrollmentMailbox(expires: invitation.expires, request: request, response: previous.response)
        deviceMailboxes[invitation.id] = value
        return value
    }
    func publishEnrollment(_ response: RemoteDeviceEnrollmentHandoff, request: RemoteDeviceEnrollmentRequest,
        invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        let previous = try await readEnrollment(invitation, now: now)
        guard previous.request == request, previous.response == nil || previous.response == response else {
            throw RemoteDeviceEnrollmentTransportError.conflict
        }
        let value = RemoteDeviceEnrollmentMailbox(expires: invitation.expires, request: request, response: response)
        deviceMailboxes[invitation.id] = value
        if loseDeviceResponseReply { loseDeviceResponseReply = false; throw RemoteRecoveryTransportError.unavailable }
        return value
    }
    func cancelEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation) async throws { deviceMailboxes.removeValue(forKey: invitation.id) }

    func dropNextAppendReply() { loseAppendReply = true }
    func dropAppendReply(number: Int) { loseAppendNumber = number }
    func dropNextUploadReply() { loseUploadReply = true }
    func setHostOnline(_ value: Bool) { hostOnline = value }
    func hostPublicKey() -> Data { hostKey.publicKey.rawRepresentation }
    func injectNextEntries(_ entries: [String]) { nextEntries = entries }
    func setEntriesUnavailable(_ value: Bool) { entriesUnavailable = value }
    func whenEntriesReply(_ action: @escaping @Sendable () async -> Void) { beforeEntriesReply = action }
    func setIgnoreAppends(_ value: Bool) { ignoreAppends = value }
    func setPageSize(_ value: Int) { pageSize = value }
    func replaceLog(_ value: MembershipLog) { log = value.snapshot() }
    func replaceAtNextAppend(_ value: MembershipLog) { nextAppendLog = value.snapshot() }

    func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage {
        if entriesUnavailable { throw RemoteRecoveryTransportError.unavailable }
        guard let log else { throw RemoteRecoveryTransportError.recordNotFound }
        // Reads are untrusted: tests may deliberately return a different root.
        let page = nextEntries ?? Array(log.entriesAfter(seq: after).prefix(pageSize))
        nextEntries = nil
        await beforeEntriesReply?()
        return RemoteRecoveryLogPage(head: log.head(), entries: page, more: after + UInt64(page.count) < log.head().seq)
    }
    func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply {
        appends.append(request)
        if let nextAppendLog { log = nextAppendLog; self.nextAppendLog = nil }
        if ignoreAppends { return .stored }
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
        if loseAppendReply || loseAppendNumber == appends.count {
            loseAppendReply = false; loseAppendNumber = nil
            throw RemoteRecoveryTransportError.unavailable
        }
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
    func backup(log: MembershipLog) async throws -> String {
        guard let value = envelopes[try XCTUnwrap(log.kBackup()).blobVersion] else {
            throw RemoteRecoveryTransportError.recordNotFound
        }
        return value
    }
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

private actor ServiceApprovalPortal: AccountOIDCHTTP {
    var state = "awaiting_approval"
    var scopes = ["agent.prompt", "agent.view"]
    var fingerprint: String?
    var posts = 0
    var loseReply = false
    var expired = false
    var interruptRunning = false
    var convergeInterrupt = true
    var revokeError: (String, Int)?
    var beforeRevokeReply: (@Sendable () async -> Void)?
    func revoke(expired: Bool = false, fingerprint: String? = nil) {
        state = "revoking"; self.expired = expired
        if let fingerprint { self.fingerprint = fingerprint }
    }
    func setState(_ value: String) { state = value }
    func setScopes(_ value: [String]) { scopes = value }
    func dropNextReply() { loseReply = true }
    func keepEarlierInterruptChoice() { convergeInterrupt = false }
    func refuseRevoke(_ code: String, status: Int = 409) { revokeError = (code, status) }
    func whenRevokeReplies(_ action: @escaping @Sendable () async -> Void) { beforeRevokeReply = action }
    func count() -> Int { posts }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST" {
            posts += 1
            if request.url?.path.hasSuffix("/revoke") == true {
                if let (code, status) = revokeError {
                    await beforeRevokeReply?()
                    return (try JSONSerialization.data(withJSONObject: ["error": "Interruption refused.", "code": code]), status)
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let choice = try XCTUnwrap(body["interruptRunning"] as? Bool)
                if !["revoking", "revoked"].contains(state) {
                    interruptRunning = choice
                    state = "revoking"
                } else if convergeInterrupt {
                    interruptRunning = interruptRunning || choice
                }
            } else {
                fingerprint = (try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])?["r9Svc"]
                state = "provisioning"
            }
            if loseReply { loseReply = false; throw AccountLoginError.unavailable }
        }
        var record: [String: Any] = ["id": "i-01234567890123456789012345", "name": "Test bot", "stationOrigin": "https://configured.example",
            "state": state, "scopes": scopes, "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(expired ? -3600 : 3600)), "role": "owner"]
        if let fingerprint { record["r9Svc"] = fingerprint }
        if ["revoking", "revoked"].contains(state) { record["interruptRunning"] = interruptRunning }
        return (try JSONSerialization.data(withJSONObject: request.httpMethod == "POST" ? record : ["stale": false, "integrations": [record]]), 200)
    }
}

@MainActor
private final class RecoveryCopyAuthority: RemoteControlRecoveryAuthorizing {
    var context: RemoteControlRecoveryContext?
    var original: String?
    var complete = true
    var reservations = 0
    var reservedTime: UInt64?
    var afterReserve: (() async throws -> Void)?
    func reserve(originalRecordJSON: String, context: RemoteControlRecoveryContext,
        managerID: String, log: MembershipLog) async throws -> UInt64 {
        guard complete, context == self.context, originalRecordJSON == original,
              log.head() == context.membershipHead else { throw RemoteRecoveryError.requiresReview }
        reservations += 1
        let time = try parseControlRecord(recordJson: originalRecordJSON).issuedAt + 1000
        reservedTime = time
        try await afterReserve?()
        return time
    }
    func authorize(_ review: RemoteControlRecoveryReview, log: MembershipLog) throws {
        guard complete, review.context == context, review.originalRecordJSON == original,
              log.head() == review.context.membershipHead, review.body.issuedAt == reservedTime else {
            throw RemoteRecoveryError.requiresReview
        }
    }
}

@MainActor
private final class RecoveryCopySavePanel: NSSavePanel {
    var destination: URL?
    var reply: ((NSApplication.ModalResponse) -> Void)?
    var cancellations = 0
    override var url: URL? { destination }
    override func beginSheetModal(for window: NSWindow,
        completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) { reply = handler }
    override func cancel(_ sender: Any?) { cancellations += 1; reply?(.cancel) }
}

@MainActor
private final class RecoveryCoordinatorHarness {
    let store = RecoveryMemoryCheckpoint()
    let keys = RecoveryMemoryKeys()
    let relay = RecoveryMemoryRelay()
    var authorBytes: [String: Data] = [:]
    var verifierHistoryBytes: [String: Data] = [:]
    var protectedJournal: ((MembershipLog, String) throws -> RemoteControlSigningJournal)?
    let identityStorage = TestAtemStorage()
    let identityCryptography = TestAtemCryptography()
    lazy var identity = AtemE2EIdentity(storage: identityStorage, crypto: identityCryptography)
    var ownerRequests: [SignRequest] = []
    var savedKits: [String] = []
    var approve = true
    var save = true
    var ownerConfirmation: ((SignRequest) async throws -> Bool)?
    var serviceOwnerConfirmation: ((RemoteServiceApproval, SignRequest) async -> Bool)?

    func coordinator(relayURL: String = "https://configured.example", transport: RemoteRecoveryTransport? = nil,
        checkpointStore: AstationRecoveryCheckpointStorage? = nil,
        authorizeDelegatedControl: ((MembershipLog) throws -> Void)? = nil,
        controlRecoveryAuthority: RemoteControlRecoveryAuthorizing? = nil,
        authorizeNewMembership: ((SignRequest, MembershipLog) throws -> Void)? = nil,
        additionalControlStations: ((MembershipLog) throws -> [String: RemoteControlStationTransport])? = nil,
        retainedControlTransport: ((String) throws -> RemoteControlStationTransport)? = nil,
        confirmVerifierRoster: ((AstationRecoveryCoordinator.VerifierRosterReview) async -> Bool)? = nil,
        confirmProcessRoster: (() async -> Bool)? = nil,
        verifierTime: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) throws -> AstationRecoveryCoordinator {
        try AstationRecoveryCoordinator(accountID: "account-a", managerID: "manager-a", identity: identity,
            relayURL: relayURL, store: checkpointStore ?? store, transport: transport ?? relay, dataKeys: keys,
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
            }, confirmServiceOwner: serviceOwnerConfirmation, authorizeDelegatedControl: authorizeDelegatedControl,
            controlRecoveryAuthority: controlRecoveryAuthority, controlSigningJournal: { [unowned self] log, member in
                if let protectedJournal { return try protectedJournal(log, member) }
                return try RemoteControlSigningJournal(log: log, memberID: member, read: { self.authorBytes[member] },
                    persist: { self.authorBytes[member] = $0 })
            },
            authorizeNewMembership: authorizeNewMembership, additionalControlStations: additionalControlStations,
            retainedControlTransport: retainedControlTransport,
            confirmVerifierRoster: confirmVerifierRoster, confirmProcessRoster: confirmProcessRoster,
            verifierHistory: { [unowned self] log, origin, creating in
                try RemoteMemberVerifierJournal(log: log, origin: origin, creating: creating,
                    read: { self.verifierHistoryBytes[origin] }, persist: { self.verifierHistoryBytes[origin] = $0 })
            }, verifierTime: verifierTime)
    }
}

@MainActor
final class AstationRecoveryCoordinatorTests: XCTestCase {
    private func localVerifierGate(_ h: RecoveryCoordinatorHarness, others: [RemoteVerifierID] = []) async throws
        -> (MembershipLog, RemoteVerifierSigningGate, SignRequest) {
        let stored = await h.relay.log
        let log = try XCTUnwrap(stored).snapshot()
        let gate = try RemoteVerifierSigningGate(log: log,
            verifiers: [.member("manager-a"), .stationReplica("server")] + others)
        let server = try gate.connect(.stationReplica("server"))
        try gate.observeConsumer(verifierInventory(), on: server)
        let body = try log.draftEntry(signer: "manager-a", signedAt: AstationRecoveryCoordinator.clock().wallMs,
            actionJson: hostSenderRevokeAction(hostId: "host-a", interruptRunning: false,
                signedAt: AstationRecoveryCoordinator.clock().wallMs))
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager-a")
        return (log, gate, request)
    }

    func testLocalVerifierUsesTheLoadedCoreAndExactExistingNativeKeys() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (log, gate, request) = try await localVerifierGate(h)
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        let evidence = try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: h.identity, current: { true })
        XCTAssertNoThrow(try gate.authorize(request, log: log))
        try evidence.refresh(log: log)
        XCTAssertNoThrow(try gate.authorize(request, log: log))
        evidence.retire()
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        XCTAssertThrowsError(try evidence.refresh(log: log))
    }

    func testLocalVerifierNeverConfirmsAnotherSDKAndDisposalDropsItsEvidence() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (log, gate, request) = try await localVerifierGate(h, others: [.other("sdk")])
        var evidence: AstationLocalVerifierEvidence? = try AstationLocalVerifierEvidence(gate: gate, log: log,
            memberID: "manager-a", identity: h.identity, current: { true })
        XCTAssertNotNil(evidence)
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        let sdk = try gate.connect(.other("sdk"))
        try gate.observeConsumer(verifierInventory(), on: sdk)
        XCTAssertNoThrow(try gate.authorize(request, log: log))
        evidence = nil
        XCTAssertThrowsError(try gate.authorize(request, log: log))
    }

    func testLocalVerifierMissingIdentityNeverCreatesReplacementKeys() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (log, gate, request) = try await localVerifierGate(h)
        let storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let missing = AtemE2EIdentity(storage: storage, crypto: crypto)
        XCTAssertThrowsError(try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: missing, current: { true }))
        XCTAssertNil(storage.data)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(crypto.creates, 0)
        XCTAssertThrowsError(try gate.authorize(request, log: log))
    }

    func testLocalVerifierWithRealProtectedKeysStopsWhenItsOwnTestIdentityIsRemoved() async throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Secure Enclave unavailable") }
        let name = "atem-local-verifier-test-" + UUID().uuidString
        let storage = AtemIdentityKeychainStorage(astationId: name)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "build.agora.astation.atem-e2e-v1", kSecAttrAccount as String: name,
            kSecUseDataProtectionKeychain as String: true]
        defer { SecItemDelete(query as CFDictionary) }
        let h = RecoveryCoordinatorHarness()
        h.identity = AtemE2EIdentity(storage: storage)
        let coordinator = try h.coordinator()
        do { _ = try await coordinator.setup() }
        catch {
            let ns = error as NSError
            let optional = ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] != "1"
            if optional, case AtemIdentityError.keychain(let status) = error,
               [errSecMissingEntitlement, errSecInteractionNotAllowed].contains(status) {
                throw XCTSkip("Provisioned signing and an unlocked Mac are required")
            }
            if optional, ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecInteractionNotAllowed) {
                throw XCTSkip("Unlock this Mac to test protected verifier keys")
            }
            throw error
        }
        let (log, gate, request) = try await localVerifierGate(h)
        let evidence = try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: h.identity, current: { true })
        XCTAssertNoThrow(try gate.authorize(request, log: log))
        XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
        XCTAssertThrowsError(try evidence.refresh(log: log))
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        XCTAssertNil(try storage.read(), "Inventory checks must never recreate removed protected keys")
    }

    func testLocalVerifierLosingProtectedStorageClearsEvidenceWithoutWriting() async throws {
        for missing in [false, true] {
            let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
            _ = try await coordinator.setup()
            let (log, gate, request) = try await localVerifierGate(h)
            let evidence = try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
                identity: h.identity, current: { true })
            XCTAssertNoThrow(try gate.authorize(request, log: log))
            let writes = h.identityStorage.writes, creates = h.identityCryptography.creates
            if missing { h.identityStorage.data = nil } else { h.identityStorage.failRead = true }
            XCTAssertThrowsError(try evidence.refresh(log: log))
            XCTAssertThrowsError(try gate.authorize(request, log: log))
            XCTAssertEqual(h.identityStorage.writes, writes)
            XCTAssertEqual(h.identityCryptography.creates, creates)
            if missing { XCTAssertNil(h.identityStorage.data) }
        }
    }

    func testLocalVerifierWrongKeysOrAnObsoleteAccountNeverConfirms() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (log, gate, request) = try await localVerifierGate(h)
        let other = AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography())
        _ = try other.remotePublicKeys()
        XCTAssertThrowsError(try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: other, current: { true }))
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        var active = true
        let evidence = try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: h.identity, current: { active })
        XCTAssertNoThrow(try gate.authorize(request, log: log))
        active = false
        XCTAssertThrowsError(try evidence.refresh(log: log))
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        active = true
        XCTAssertThrowsError(try evidence.refresh(log: log), "Retired account evidence cannot revive")
    }

    func testLocalVerifierHeadMovementClearsTheOldGateAndCannotCrossAnchors() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (log, gate, request) = try await localVerifierGate(h)
        let evidence = try AstationLocalVerifierEvidence(gate: gate, log: log, memberID: "manager-a",
            identity: h.identity, current: { true })
        _ = try await addSecondManager(harness: h)
        let stored = await h.relay.log
        let next = try XCTUnwrap(stored).snapshot()
        XCTAssertThrowsError(try evidence.refresh(log: next))
        XCTAssertThrowsError(try gate.authorize(request, log: log))
        XCTAssertThrowsError(try evidence.refresh(log: log), "An older snapshot cannot revive retired evidence")
        XCTAssertThrowsError(try AstationLocalVerifierEvidence(gate: gate, log: next, memberID: "manager-a",
            identity: h.identity, current: { true }))
        let roster = try RemoteStationVerifierRoster(origin: "https://configured.example", generation: 1, replicas: ["server"])
        XCTAssertThrowsError(try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: next))
        XCTAssertThrowsError(try gate.authorize(request, log: log))
    }

    func testVerifierRosterAcceptanceIsProtectedDurableAndGrantsNoLiveSigningEvidence() async throws {
        let h = RecoveryCoordinatorHarness()
        var confirmations = 0
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in confirmations += 1; return true })
        _ = try await coordinator.setup()
        let before = h.ownerRequests.count
        let review = try await coordinator.prepareStationVerifierRoster(current: { true })
        XCTAssertNil(try coordinator.acceptedStationVerifierRoster())
        XCTAssertEqual(review.candidate.replicas, ["a", "b"])
        XCTAssertTrue(HostSenderAccessWindowController.serverReviewText(review).contains("https://configured.example"))
        try await coordinator.acceptStationVerifierRoster(review, current: { true })
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(try coordinator.acceptedStationVerifierRoster(), review.candidate)
        XCTAssertEqual(h.ownerRequests.count, before, "Roster acceptance must not repurpose a membership signing request")
        XCTAssertFalse(coordinator.hostSenderControlsAvailable)
        let restarted = try h.coordinator()
        XCTAssertEqual(try restarted.acceptedStationVerifierRoster(), review.candidate)
        XCTAssertFalse(restarted.hostSenderControlsAvailable)
    }

    func testVerifierRosterDenyAndAccountChangeNeverSaveAcceptance() async throws {
        for fault in ["deny", "account"] {
            let h = RecoveryCoordinatorHarness()
            var active = true
            let coordinator = try h.coordinator(confirmVerifierRoster: { _ in
                if fault == "account" { active = false }
                return fault != "deny"
            })
            _ = try await coordinator.setup()
            let review = try await coordinator.prepareStationVerifierRoster(current: { active })
            do { try await coordinator.acceptStationVerifierRoster(review, current: { active }); XCTFail("accepted \(fault)") }
            catch { }
            XCTAssertNil(try coordinator.acceptedStationVerifierRoster())
        }
    }

    func testProcessReviewPersistsAllSlotsAndHeadChangesRequireReviewAgain() async throws {
        let h = RecoveryCoordinatorHarness(), process = verifierReportProcess()
        let member = "manager-a", active = { true }
        let coordinator = try h.coordinator(confirmProcessRoster: { true })
        _ = try await coordinator.setup()
        XCTAssertEqual(try coordinator.memberProcessReviews(), [.init(member: member, status: .needsReview)])
        let review = try await coordinator.prepareProcessReview(member: member, current: active)
        let lines = ["desktop " + process, "offline AQEBAQEBAQEBAQEBAQEBAQ"]
        try await coordinator.acceptProcessReview(review, lines: lines, current: active)
        let restarted = try h.coordinator(confirmProcessRoster: { true })
        let log = try await restarted.hostSenderMembership()
        XCTAssertEqual(try restarted.reviewedProcessSlots(member: member, log: log).map(\.slot), ["desktop", "offline"])
        XCTAssertEqual(try restarted.memberProcessReviews(), [.init(member: member, status: .reviewed(slots: 2))])
        XCTAssertFalse(restarted.hostSenderControlsAvailable)
        do { try await coordinator.acceptProcessReview(review, lines: lines, current: active); XCTFail("replayed review") } catch {}
        let foreign = try h.coordinator(relayURL: "https://another.example")
        XCTAssertThrowsError(try foreign.reviewedProcessSlots(member: member, log: log))
        XCTAssertEqual(try foreign.memberProcessReviews(), [.init(member: member, status: .needsReview)])
        _ = try await addSecondManager(harness: h)
        let changed = try await restarted.hostSenderMembership()
        XCTAssertEqual(try restarted.memberProcessReviews(), [.init(member: member, status: .previousRevision),
            .init(member: "manager-b", status: .needsReview)])
        XCTAssertThrowsError(try restarted.reviewedProcessSlots(member: member, log: changed))
        XCTAssertThrowsError(try restarted.reviewedProcessSlots(member: member, log: log))
        let next = try await restarted.prepareProcessReview(member: member, current: active)
        XCTAssertEqual(next.previous?.lines, lines, "Keep offline slots visible while re-reviewing the newer head")
        try await restarted.acceptProcessReview(next, lines: [lines[0]], current: active)
        XCTAssertEqual(try restarted.reviewedProcessSlots(member: member, log: changed).count, 1)
    }

    func testMacCollectsSignedReportsAcrossReviewedSlotsAndRefusesMissingHistory() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in true }, confirmProcessRoster: { true })
        _ = try await coordinator.setup()
        _ = try await addSecondManager(harness: h)
        let station = try await coordinator.prepareStationVerifierRoster(current: { true })
        try await coordinator.acceptStationVerifierRoster(station, current: { true })
        let review = try await coordinator.prepareProcessReview(member: coordinator.managerID, current: { true })
        try await coordinator.acceptProcessReview(review, lines: ["offline AQEBAQEBAQEBAQEBAQEBAQ",
            "truck " + verifierReportProcess()], current: { true })
        let peerOrigin = "https://second.example"
        let peer = RecoveryMemoryRelay(stationOrigin: peerOrigin)
        await peer.replaceLog(try await coordinator.hostSenderMembership())
        let peerManager = try h.coordinator(relayURL: peerOrigin, transport: peer,
            confirmVerifierRoster: { _ in true }, confirmProcessRoster: { true })
        let peerServers = try await peerManager.prepareStationVerifierRoster(current: { true })
        try await peerManager.acceptStationVerifierRoster(peerServers, current: { true })
        let peerReview = try await peerManager.prepareProcessReview(member: coordinator.managerID, current: { true })
        try await peerManager.acceptProcessReview(peerReview, lines: ["truck " + verifierReportProcess()], current: { true })
        let restarted = try h.coordinator()
        let log = try await restarted.hostSenderMembership()
        let origin = restarted.relayURL, member = restarted.managerID, identity = h.identity
        let anchor = try RemoteVerifierReportAnchor(log: log)
        let head: [String: Any] = ["seq": log.head().seq, "hash": log.head().hash]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryReportHTTPStub.self]
        var issued: [String: String] = [:]
        var reads = 0
        var rosterGeneration = 1
        let inventory = verifierInventory()
        RecoveryReportHTTPStub.lock.withLock {
            RecoveryReportHTTPStub.response = { request, data in
                let requestOrigin = "https://" + (try XCTUnwrap(request.url?.host))
                XCTAssertTrue([origin, peerOrigin].contains(requestOrigin))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + (requestOrigin == origin ? "selected-token" : "peer-token"))
                if request.url?.lastPathComponent == "verifiers" {
                    XCTAssertEqual(request.httpMethod, "GET")
                    let rows: [[String: Any]] = [
                        ["id": "a", "connection_generation": 2, "authorization_ms_left": 30_000,
                         "verifier": ["version": inventory.version, "actions": inventory.actions]],
                        ["id": "b", "connection_generation": 1]]
                    return try JSONSerialization.data(withJSONObject: ["origin": requestOrigin, "account_id": log.accountId(),
                        "genesis_hash": log.genesisHash(), "roster_generation": rosterGeneration, "head": head, "replicas": rows])
                }
                let nonce: String
                if request.httpMethod == "POST" {
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(body["expected"] as? NSDictionary, head as NSDictionary)
                    let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(body["challenge"]))
                    let json = String(decoding: bytes, as: UTF8.self)
                    nonce = try parseVerifierReportChallenge(challengeJson: json).nonce
                    issued[nonce] = json
                } else {
                    XCTAssertEqual(request.httpMethod, "GET")
                    nonce = try XCTUnwrap(request.url?.lastPathComponent)
                    reads += 1
                }
                let json = try XCTUnwrap(issued[nonce])
                let challenge = try parseVerifierReportChallenge(challengeJson: json)
                var reports: [Any] = []
                XCTAssertEqual(challenge.origin, requestOrigin)
                if request.httpMethod == "GET", challenge.slot == "truck", requestOrigin == origin {
                    let report = try identity.verifierReport(log: log, anchor: anchor, memberID: member,
                        challengeJSON: json, slot: challenge.slot, origin: origin,
                        wallMs: AstationRecoveryCoordinator.clock().wallMs, current: { true })
                    reports.append(try JSONSerialization.jsonObject(with: Data(report.utf8)))
                }
                return try JSONSerialization.data(withJSONObject: ["challenge": JSONSerialization.jsonObject(with: Data(json.utf8)),
                    "expected": head, "reports": reports] as [String: Any])
            }
        }
        defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
        var activeAccount = true
        func check(wait: @escaping @Sendable () async throws -> Void = {}) async throws -> AstationRecoveryCoordinator.ProcessCheck {
            try await restarted.checkMemberProcesses(current: { activeAccount }, transport: { target, active in
                try RemoteRecoveryHTTP(relayURL: target, configuration: config) {
                    guard await active() else { throw AccountLoginError.changed }
                    return target == origin ? "selected-token" : "peer-token"
                }
            }, waitForReport: wait, progress: { _, _, _ in })
        }
        let result = try await check()
        XCTAssertEqual(issued.count, 3)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(result.stations.map(\.origin), [origin, peerOrigin])
        let first = try XCTUnwrap(result.stations.first { $0.origin == origin })
        let second = try XCTUnwrap(result.stations.first { $0.origin == peerOrigin })
        XCTAssertEqual(first.slots, 2)
        XCTAssertEqual(first.unanswered.map(\.slot), ["offline"])
        XCTAssertEqual(first.pendingMembers, ["manager-b"])
        XCTAssertEqual(first.serverCount, 2)
        XCTAssertEqual(first.unconfirmedServers, ["b"])
        XCTAssertEqual(second.slots, 1)
        XCTAssertEqual(second.unanswered.map(\.slot), ["truck"])
        XCTAssertEqual(second.pendingMembers, [])
        XCTAssertEqual(second.serverCount, 2)
        XCTAssertEqual(second.unconfirmedServers, ["b"])
        XCTAssertFalse(restarted.hostSenderControlsAvailable)
        rosterGeneration = 2
        do { _ = try await check(); XCTFail("unreviewed server roster accepted") }
        catch RemoteVerifierGateError.staleMembership {}
        XCTAssertEqual(issued.count, 3, "validate the reviewed server list before creating challenges")
        rosterGeneration = 1
        do {
            _ = try await check { await MainActor.run { activeAccount = false } }
            XCTFail("signed-out check returned a result")
        } catch {}
        XCTAssertEqual(reads, 3, "a retired inspection cannot read the mailbox")
        activeAccount = true
        let requestsBeforeStorageLoss = issued.count
        h.verifierHistoryBytes.removeValue(forKey: origin)
        do { _ = try await check(); XCTFail("a missing journal was recreated") }
        catch RemoteVerifierGateError.invalidInventory {}
        XCTAssertEqual(issued.count, requestsBeforeStorageLoss)
        XCTAssertNil(h.verifierHistoryBytes[origin])
    }

    func testLiveServerCheckWorksBeforeProcessReviewAndDropsRepliesAfterAccountChange() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in true })
        _ = try await coordinator.setup()
        let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1)
        let request = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator.commitHost(request: request, confirmedAt: AstationRecoveryCoordinator.clock().monoMs,
            current: { true })
        let roster = try await coordinator.prepareStationVerifierRoster(current: { true })
        try await coordinator.acceptStationVerifierRoster(roster, current: { true })
        let log = try await coordinator.hostSenderMembership()
        let origin = coordinator.relayURL
        let body = try JSONSerialization.data(withJSONObject: ["origin": origin, "account_id": log.accountId(),
            "genesis_hash": log.genesisHash(), "roster_generation": 1, "replicas": [["id": "a"], ["id": "b"]],
            "head": ["seq": log.head().seq, "hash": log.head().hash]])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryReportHTTPStub.self]
        RecoveryReportHTTPStub.lock.withLock {
            RecoveryReportHTTPStub.response = { request, _ in
                XCTAssertEqual(request.url?.lastPathComponent, "verifiers")
                return body
            }
        }
        defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
        var selected = true
        func check(switchAccount: Bool) async throws -> AstationRecoveryCoordinator.ProcessCheck {
            try await coordinator.checkMemberProcesses(current: { selected }, transport: { target, _ in
                try RemoteRecoveryHTTP(relayURL: target, configuration: config) {
                    if switchAccount { await MainActor.run { selected = false } }
                    return "test-token"
                }
            }, progress: { _, _, _ in })
        }
        let result = try await check(switchAccount: false)
        let station = try XCTUnwrap(result.stations.first)
        XCTAssertEqual(station.unconfirmedServers, ["a", "b"])
        XCTAssertEqual(result.hostCount, 1)
        XCTAssertEqual(result.unconfirmedHosts, ["host-a"])
        XCTAssertEqual(station.pendingMembers, [coordinator.managerID])
        XCTAssertEqual(station.slots, 0)
        XCTAssertTrue(h.verifierHistoryBytes.isEmpty)
        do { _ = try await check(switchAccount: true); XCTFail("accepted a response for the previous account") }
        catch RemoteVerifierGateError.staleConnection {}
    }

    func testReviewedMacAnswersStationInboxAndRetriesOnlyUnconfirmedReports() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmProcessRoster: { true })
        _ = try await coordinator.setup()
        let origin = coordinator.relayURL, member = coordinator.managerID
        let log = try await coordinator.hostSenderMembership()
        let review = try await coordinator.prepareProcessReview(member: member, current: { true })
        try await coordinator.acceptProcessReview(review, lines: ["truck " + verifierReportProcess()], current: { true })
        // Model restarting under a new SDK process. The independently saved slot
        // still identifies this installation; the old expected process cannot sign.
        let bytes = try XCTUnwrap(h.store.bytes)
        var checkpoint = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var rosters = try XCTUnwrap(checkpoint["processRosters"] as? [String: [String: [String: Any]]])
        rosters[origin]?[member]?["lines"] = ["truck AQEBAQEBAQEBAQEBAQEBAQ"]
        checkpoint["processRosters"] = rosters
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: checkpoint, format: .binary, options: 0)
        let restarted = try h.coordinator(relayURL: "https://elsewhere.example")
        XCTAssertEqual(restarted.localVerifierOrigins, [origin])
        XCTAssertFalse(restarted.delegatedControlsAvailable)

        let wall = AstationRecoveryCoordinator.clock().wallMs
        let challenge = try verifierReportChallenge(signer: "member:" + member, slot: "truck",
            origin: origin, connection: 1, issuedAt: wall, expiresAt: wall + 30_000)
        let challengeObject = try JSONSerialization.jsonObject(with: Data(challenge.utf8))
        let head: [String: Any] = ["seq": log.head().seq, "hash": log.head().hash]
        var reads = 0, posts = 0
        RecoveryReportHTTPStub.lock.withLock {
            RecoveryReportHTTPStub.response = { request, bytes in
                let input = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer verifier-test")
                if request.url?.lastPathComponent == "verifier-requests" {
                    reads += 1
                    XCTAssertEqual(input["signer"] as? String, "member:" + member)
                    XCTAssertEqual(input["slot"] as? String, "truck")
                    XCTAssertEqual(input["expected"] as? NSDictionary, head as NSDictionary)
                    return try JSONSerialization.data(withJSONObject: ["challenges": [challengeObject]])
                }
                posts += 1
                var report = try XCTUnwrap(input["report"] as? [String: Any])
                let json = String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
                let checked = try verifyVerifierReport(log: log, reportJson: json, expectedChallengeJson: challenge, nowMs: wall)
                XCTAssertTrue(checked.atHead)
                XCTAssertEqual(checked.process, verifierReportProcess())
                XCTAssertEqual(checked.inventory, verifierInventory())
                // A real signed body paired with a corrupted signature is not a receipt.
                if posts == 1 { report["sig"] = "AA" }
                return try JSONSerialization.data(withJSONObject: ["challenge": challengeObject, "expected": head,
                    "reports": [report]] as [String: Any])
            }
        }
        defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryReportHTTPStub.self]
        func poll() async throws {
            try await restarted.answerVerifierChallenges(at: origin, current: { true }) { active in
                try RemoteRecoveryHTTP(relayURL: origin, configuration: config, accessToken: {
                    guard await active() else { throw AccountLoginError.changed }
                    return "verifier-test"
                })
            }
        }
        let prompts = h.ownerRequests.count
        do { try await poll(); XCTFail("missing retained report") } catch RemoteRecoveryTransportError.invalidResponse {}
        try await poll()
        try await poll()
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertEqual(h.identityCryptography.noninteractiveSigningCalls, 2)
        _ = try await addSecondManager(harness: h)
        _ = try await restarted.hostSenderMembership()
        XCTAssertTrue(restarted.localVerifierOrigins.isEmpty)
        try await restarted.answerVerifierChallenges(at: origin, current: { true }) { _ in
            XCTFail("stale roster started a request"); throw AccountLoginError.changed
        }
    }

    func testLocalVerifierNeedsAReviewedSlotAndCurrentContextThroughTokenAcquisition() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmProcessRoster: { true })
        _ = try await coordinator.setup()
        XCTAssertTrue(coordinator.localVerifierOrigins.isEmpty)
        try await coordinator.answerVerifierChallenges(at: coordinator.relayURL, current: { true }) { _ in
            XCTFail("unreviewed Mac requested a token"); throw AccountLoginError.changed
        }
        let review = try await coordinator.prepareProcessReview(member: coordinator.managerID, current: { true })
        try await coordinator.acceptProcessReview(review, lines: ["truck " + verifierReportProcess()], current: { true })
        var signedIn = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryReportHTTPStub.self]
        RecoveryReportHTTPStub.lock.withLock {
            RecoveryReportHTTPStub.response = { _, _ in XCTFail("signed-out request reached Station"); throw AccountLoginError.changed }
        }
        defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
        do {
            try await coordinator.answerVerifierChallenges(at: coordinator.relayURL, current: { signedIn }) { active in
                try RemoteRecoveryHTTP(relayURL: coordinator.relayURL, configuration: config, accessToken: {
                    await MainActor.run { signedIn = false }
                    guard await active() else { throw AccountLoginError.changed }
                    return "unexpected"
                })
            }
            XCTFail("changed context accepted")
        } catch AccountLoginError.changed {}
        XCTAssertEqual(h.identityCryptography.noninteractiveSigningCalls, 0)
    }

    func testProcessReviewRefusesInvalidRowsBeforeConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), process = verifierReportProcess()
        let coordinator = try h.coordinator(confirmProcessRoster: { XCTFail("confirmed an invalid candidate"); return true })
        _ = try await coordinator.setup()
        for lines in [[], ["a " + process, "a " + process], ["invalid/slot " + process], ["a malformed"], ["b " + process, "a " + process]] {
            let review = try await coordinator.prepareProcessReview(member: "manager-a", current: { true })
            do { try await coordinator.acceptProcessReview(review, lines: lines, current: { true }); XCTFail("accepted invalid candidate") } catch {}
        }
        let log = try await coordinator.hostSenderMembership()
        XCTAssertThrowsError(try coordinator.reviewedProcessSlots(member: "manager-a", log: log))
    }

    func testRecoveryProcessExportKeepsAnOfflineAndReplacedProcessAcrossRestartAndSavePanel() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), (_, plan) = try await preparedRecoverySource(h)
        let writer = try h.coordinator(confirmProcessRoster: { true })
        let local = verifierReportProcess(), other = "AQEBAQEBAQEBAQEBAQEBAQ", member = "manager-a"
        for lines in [["desktop " + local, "offline " + other], ["desktop " + other]] {
            let review = try await writer.prepareProcessReview(member: member, current: { true })
            try await writer.acceptProcessReview(review, lines: lines, current: { true })
        }
        let restarted = try h.coordinator()
        let panel = RecoveryCopySavePanel(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        panel.destination = url
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = ControlRecoveryWindowController(stationOrigin: plan.context.stationOrigin, loadAccess: {
            .init(coordinator: restarted, current: { true }, canSign: { true })
        }, makeSavePanel: { panel })
        showRecovery(controller)
        defer { controller.close() }
        let save = try recoveryButton("Save Reviewed Processes...", window: controller.window)
        XCTAssertFalse(save.isEnabled)
        try clickRecovery(recoveryButton("Load Station Review", window: controller.window))
        try await waitForRecoveryUI { save.isEnabled }
        try clickRecovery(save)
        try XCTUnwrap(panel.reply)(.OK)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(object["slots"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["slot"] as? String }, ["desktop", "desktop", "offline"])
        XCTAssertEqual(rows.compactMap { $0["process"] as? String }, [other, local, other])
        XCTAssertEqual(rows.compactMap { $0["selected"] as? Bool }, [true, false, false])
        XCTAssertEqual(object["evidence_hash"] as? String, plan.context.evidenceHash)
        XCTAssertEqual(object["reconstruction_hash"] as? String, plan.reconstructionHash)
        XCTAssertFalse(restarted.controlRecoveryAvailable)
        XCTAssertThrowsError(try restarted.exportAuthorRoster(plan, current: { false }))
        let foreign = try h.coordinator(relayURL: "https://another.example")
        XCTAssertThrowsError(try foreign.exportAuthorRoster(plan, current: { true }))
        h.store.readFailure = true
        XCTAssertThrowsError(try restarted.exportAuthorRoster(plan, current: { true }))
    }

    func testProcessReviewRefusesDeniedStaleOrSupersededConfirmation() async throws {
        for fault in ["denied", "head", "selection", "expiry", "superseded"] {
            let h = RecoveryCoordinatorHarness()
            var active = true, time: UInt64 = 5, confirmations = 0
            let coordinator = try h.coordinator(confirmProcessRoster: {
                confirmations += 1
                if fault == "head" {
                    do { _ = try await self.addSecondManager(harness: h) } catch { XCTFail("membership fixture failed") }
                }
                if fault == "selection" { active = false }
                return fault != "denied"
            }, verifierTime: { time })
            _ = try await coordinator.setup()
            let review = try await coordinator.prepareProcessReview(member: "manager-a", current: { active })
            if fault == "superseded" { _ = try await coordinator.prepareProcessReview(member: "manager-a", current: { active }) }
            if fault == "expiry" { time += 300_000 }
            do {
                try await coordinator.acceptProcessReview(review, lines: ["mac " + verifierReportProcess()], current: { active })
                XCTFail("accepted " + fault)
            } catch {}
            XCTAssertEqual(confirmations, ["expiry", "superseded"].contains(fault) ? 0 : 1)
            let log = try await coordinator.hostSenderMembership()
            XCTAssertThrowsError(try coordinator.reviewedProcessSlots(member: "manager-a", log: log))
        }
    }

    func testUncertainProcessListWriteRequiresReloadAndFreshEvidence() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmProcessRoster: { true })
        _ = try await coordinator.setup()
        let review = try await coordinator.prepareProcessReview(member: "manager-a", current: { true })
        h.store.failOnProcessRoster = true
        do {
            try await coordinator.acceptProcessReview(review, lines: ["mac " + verifierReportProcess()], current: { true })
            XCTFail("acknowledged uncertain write")
        } catch {}
        let restarted = try h.coordinator()
        let log = try await restarted.hostSenderMembership()
        XCTAssertThrowsError(try coordinator.reviewedProcessSlots(member: "manager-a", log: log))
        XCTAssertEqual(try restarted.reviewedProcessSlots(member: "manager-a", log: log).first?.process, verifierReportProcess())
        XCTAssertFalse(restarted.hostSenderControlsAvailable)
    }

    func testVerifierRosterChangedDuringConfirmationRequiresANewExactReview() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in
            await h.relay.setVerifierRoster(generation: 2, replicas: ["a"])
            return true
        })
        _ = try await coordinator.setup()
        let review = try await coordinator.prepareStationVerifierRoster(current: { true })
        do { try await coordinator.acceptStationVerifierRoster(review, current: { true }); XCTFail("saved a different roster") }
        catch { }
        XCTAssertNil(try coordinator.acceptedStationVerifierRoster())
    }

    func testVerifierRosterRemovalIsExplicitAndRollbackNeverReplacesAcceptedState() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in true })
        _ = try await coordinator.setup()
        let first = try await coordinator.prepareStationVerifierRoster(current: { true })
        try await coordinator.acceptStationVerifierRoster(first, current: { true })
        await h.relay.setVerifierRoster(generation: 2, replicas: ["a"])
        let changed = try await coordinator.prepareStationVerifierRoster(current: { true })
        XCTAssertEqual(changed.removed, ["b"])
        XCTAssertTrue(HostSenderAccessWindowController.serverReviewText(changed).contains("Servers removed from the current list:\nb"))
        XCTAssertEqual(try coordinator.acceptedStationVerifierRoster(), first.candidate)
        try await coordinator.acceptStationVerifierRoster(changed, current: { true })
        await h.relay.setVerifierRoster(generation: 1, replicas: ["a", "b"])
        do { _ = try await coordinator.prepareStationVerifierRoster(current: { true }); XCTFail("accepted a rolled back manifest") }
        catch { }
        XCTAssertEqual(try coordinator.acceptedStationVerifierRoster(), changed.candidate)
    }

    func testVerifierRosterUncertainWriteFencesTheInstanceAndReloadsOnlyTheConfirmedList() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in true })
        _ = try await coordinator.setup()
        let review = try await coordinator.prepareStationVerifierRoster(current: { true })
        h.store.failOnVerifierRoster = true
        do { try await coordinator.acceptStationVerifierRoster(review, current: { true }); XCTFail("uncertain write succeeded") }
        catch { }
        XCTAssertThrowsError(try coordinator.acceptedStationVerifierRoster())
        let reloaded = try h.coordinator()
        XCTAssertEqual(try reloaded.acceptedStationVerifierRoster(), review.candidate)
        XCTAssertFalse(reloaded.hostSenderControlsAvailable)
    }

    func testVerifierRosterManagerDemotionAndHeadMovementDuringConfirmationNeverSave() async throws {
        for demote in [false, true] {
            let h = RecoveryCoordinatorHarness()
            var manager: AtemE2EIdentity?
            let coordinator = try h.coordinator(confirmVerifierRoster: { _ in
                do {
                    try await self.append(["action": "set_roles", "device_id": "manager-a",
                        "roles": demote ? ["view"] : ["control", "manage", "view"]],
                        harness: h, signer: "manager-b", identity: manager)
                } catch { XCTFail("membership update failed: \(error)") }
                return true
            })
            _ = try await coordinator.setup()
            manager = try await addSecondManager(harness: h)
            let review = try await coordinator.prepareStationVerifierRoster(current: { true })
            do { try await coordinator.acceptStationVerifierRoster(review, current: { true }); XCTFail("saved an obsolete membership review") }
            catch { }
            let stored = await h.relay.log
            let log = try XCTUnwrap(stored)
            XCTAssertGreaterThan(log.head().seq, review.head.seq)
            XCTAssertNil(try coordinator.acceptedStationVerifierRoster())
        }
    }

    func testVerifierRosterReplacedOrConsumedReviewNeverReusesOwnerConfirmation() async throws {
        let h = RecoveryCoordinatorHarness()
        var confirmations = 0
        let coordinator = try h.coordinator(confirmVerifierRoster: { _ in confirmations += 1; return true })
        _ = try await coordinator.setup()
        let obsolete = try await coordinator.prepareStationVerifierRoster(current: { true })
        let current = try await coordinator.prepareStationVerifierRoster(current: { true })
        do { try await coordinator.acceptStationVerifierRoster(obsolete, current: { true }); XCTFail("accepted a replaced review") }
        catch { }
        XCTAssertEqual(confirmations, 0)
        try await coordinator.acceptStationVerifierRoster(current, current: { true })
        XCTAssertEqual(confirmations, 1)
        do { try await coordinator.acceptStationVerifierRoster(current, current: { true }); XCTFail("replayed a consumed review") }
        catch { }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(try coordinator.acceptedStationVerifierRoster(), current.candidate)
    }

    func testVerifierRosterExpiresBeforeOrDuringOwnerConfirmation() async throws {
        for duringConfirmation in [false, true] {
            let h = RecoveryCoordinatorHarness()
            var time: UInt64 = 100
            var confirmations = 0
            let coordinator = try h.coordinator(confirmVerifierRoster: { _ in
                confirmations += 1
                time += 300_000
                return true
            }, verifierTime: { time })
            _ = try await coordinator.setup()
            let review = try await coordinator.prepareStationVerifierRoster(current: { true })
            if !duringConfirmation { time = review.validBefore }
            do { try await coordinator.acceptStationVerifierRoster(review, current: { true }); XCTFail("accepted an expired review") }
            catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
            XCTAssertEqual(confirmations, duringConfirmation ? 1 : 0)
            XCTAssertNil(try coordinator.acceptedStationVerifierRoster())
        }
    }

    func testNativeEnrollmentQRCodePreservesTheCompleteTrustAnchorWhenDecoded() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let invitation = try await coordinator.startDeviceEnrollment(issuer: "https://auth.dev.agora.build", owner: "login-owner",
            roles: ["view"], current: { true })
        let json = try invitation.qrJSON()
        let image = try DeviceEnrollmentWindowController.qrImage(json)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, json)
    }

    private func deviceRequest(_ invitation: RemoteDeviceEnrollmentInvitation) throws -> RemoteDeviceEnrollmentRequest {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(invitation.qrJSON().utf8)) as? [String: Any])
        let secret = try XCTUnwrap(value["secret"] as? String)
        let key = P256.Signing.PrivateKey(), encryption = Curve25519.KeyAgreement.PrivateKey()
        let body: [String: Any] = ["version": 1, "invitation": try invitation.commitment,
            "device": "phone-" + UUID().uuidString.lowercased(), "name": "Test phone",
            "auth": recoveryTestBase64(key.publicKey.x963Representation),
            "encryption": recoveryTestBase64(encryption.publicKey.rawRepresentation), "roles": invitation.roles,
            "nonce": recoveryTestBase64(Data(repeating: 0x42, count: 32))]
        let canonical = try canonicalJson(json: recoveryTestJSON(body))
        let input = encodeFields(fields: [Data("astation-device-applicant-proof-v1".utf8), Data(canonical.utf8)])
        let signature = try RemoteP256Signature.normalize(key.signature(for: input).rawRepresentation)
        let macInput = encodeFields(fields: [Data("astation-device-request-auth-v1".utf8), Data(canonical.utf8), signature])
        let bytes = try XCTUnwrap(Data(base64Encoded: secret.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: bytes)))
        return try RemoteDeviceEnrollmentRequest(json: recoveryTestJSON(["body": body,
            "signature": recoveryTestBase64(signature), "mac": recoveryTestBase64(mac)]),
            invitation: invitation, now: AstationRecoveryCoordinator.clock())
    }

    private func deviceReview(_ coordinator: AstationRecoveryCoordinator, harness h: RecoveryCoordinatorHarness) async throws
        -> (RemoteDeviceEnrollmentInvitation, RemoteDeviceEnrollmentRequest, RemoteNativeEnrollment) {
        let invitation = try await coordinator.startDeviceEnrollment(issuer: "https://auth.dev.agora.build", owner: "login-owner",
            roles: ["control", "view"], current: { true })
        let request = try deviceRequest(invitation)
        _ = try await h.relay.submitEnrollment(request, invitation: invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        let received = try await coordinator.readDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner, current: { true })
        XCTAssertEqual(received.request, request)
        XCTAssertFalse(received.handedOff)
        let review = try await coordinator.prepareDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner,
            request: request, current: { true })
        return (invitation, request, review)
    }

    func testDeviceManagerUsesTheExistingWriterAndPublishesOnlyAfterFreshConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (invitation, request, review) = try await deviceReview(coordinator, harness: h)
        do { _ = try await coordinator.serviceMembership(); XCTFail("Pending device review must own the writer") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .busy) }
        let prompts = h.ownerRequests.count
        try await coordinator.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertEqual(h.ownerRequests.last?.bodyJson, review.bodyJSON)
        let log = try await coordinator.serviceMembership()
        XCTAssertEqual(log.member(deviceId: request.deviceID)?.roles, ["control", "view"])
        let mailbox = try await coordinator.readDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner, current: { true })
        XCTAssertTrue(mailbox.handedOff)
        let value = try await h.relay.readEnrollment(invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        XCTAssertNotNil(value.response)
        for key in h.keys.keys { XCTAssertFalse(try value.response!.json().contains(recoveryTestBase64(key.key))) }
    }

    func testDeviceManagerRestartReconcilesLostAppendAndHandoffRepliesWithoutResigning() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        let (invitation, request, review) = try await deviceReview(coordinator!, harness: h)
        await h.relay.dropNextAppendReply()
        do {
            try await coordinator!.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
            XCTFail("Lost append reply")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        let prompts = h.ownerRequests.count
        coordinator = nil
        coordinator = try h.coordinator()
        do {
            try await coordinator!.cancelDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner, current: { true })
            XCTFail("A signed uncertain append must not be discarded after restart")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        await h.relay.dropNextDeviceResponseReply()
        do {
            try await coordinator!.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
            XCTFail("Lost encrypted handoff reply")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        let original = try await h.relay.readEnrollment(invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        coordinator = nil
        coordinator = try h.coordinator()
        try await coordinator!.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
        let recovered = try await h.relay.readEnrollment(invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        XCTAssertEqual(recovered.response, original.response)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        let appends = await h.relay.appends
        XCTAssertEqual(try appends.filter { try signedObjectInfo(json: $0.entryJson).bodyJcs == review.bodyJSON }.count, 1)
        let log = try await coordinator!.serviceMembership()
        XCTAssertEqual(log.member(deviceId: request.deviceID)?.status, .active)
    }

    func testDeviceManagerDenialAndChangedAccountNeverAppendOrReleaseKeys() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let (invitation, request, review) = try await deviceReview(coordinator, harness: h)
        h.approve = false
        do {
            try await coordinator.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
            XCTFail("Denied confirmation")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        var current = true
        h.ownerConfirmation = { _ in current = false; return true }
        do {
            try await coordinator.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { current })
            XCTFail("Account changed during confirmation")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        let log = await h.relay.log
        XCTAssertNil(log?.member(deviceId: request.deviceID))
        let mailbox = try await h.relay.readEnrollment(invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        XCTAssertNil(mailbox.response)
        try await coordinator.cancelDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner, current: { true })
        _ = try await coordinator.serviceMembership()
    }

    func testDeviceManagerHeadMovementDuringOwnerPromptRequiresAnotherReview() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let manager = try await addSecondManager(harness: h)
        let (invitation, request, review) = try await deviceReview(coordinator, harness: h)
        h.ownerConfirmation = { _ in
            try await self.append(["action": "add_host", "host": ["host_id": "other-host", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]],
                harness: h, signer: "manager-b", identity: manager)
            return true
        }
        do {
            try await coordinator.approveDeviceEnrollment(review, issuer: invitation.issuer, owner: invitation.owner, current: { true })
            XCTFail("The owner reviewed an older head")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        let log = await h.relay.log
        XCTAssertNil(log?.member(deviceId: request.deviceID))
        let mailbox = try await h.relay.readEnrollment(invitation, now: AstationRecoveryCoordinator.clock().wallMs)
        XCTAssertNil(mailbox.response)
        try await coordinator.cancelDeviceEnrollment(issuer: invitation.issuer, owner: invitation.owner, current: { true })
        _ = try await coordinator.serviceMembership()
    }

    func testNewStationRetainsIdentityKeysKitAndHostsAndPublishesAnEncryptedBackup() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let (commit, reveal, keys) = try await hostAttempt(coordinator!, generation: 1)
        let request = try await coordinator!.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator!.commitHost(request: request, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        let oldLog = try await coordinator!.serviceMembership()
        let oldKit = try XCTUnwrap(h.savedKits.first)
        let dataKeys = h.keys.keys, identity = try h.identity.remotePublicKeys()
        coordinator = nil
        let target = RecoveryMemoryRelay()
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        do { _ = try await coordinator!.serviceMembership(); XCTFail("Station has no account log") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .recordNotFound) }
        try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
        let connected = try await coordinator!.serviceMembership()
        XCTAssertEqual(connected.genesisHash(), oldLog.genesisHash())
        XCTAssertEqual(connected.host(hostId: "host-a"), oldLog.host(hostId: "host-a"))
        XCTAssertEqual(Array(connected.entries().prefix(oldLog.entries().count)), oldLog.entries())
        XCTAssertEqual(try h.identity.remotePublicKeys().signing, identity.signing)
        XCTAssertEqual(try h.identity.remotePublicKeys().encryption, identity.encryption)
        XCTAssertEqual(h.keys.keys, dataKeys)
        XCTAssertEqual(h.savedKits, [oldKit])
        let envelope = try await target.backup(log: connected)
        XCTAssertEqual(try RemoteRecoveryKit(text: oldKit).openBackup(envelope), dataKeys.map { AccountKey(kid: $0.kid, k: $0.key) })
        let count = await target.appends.count
        try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
        let retryCount = await target.appends.count
        XCTAssertEqual(retryCount, count, "A duplicate connect must not append or rotate keys again")
    }

    func testStationPublicationRequiresOwnerConfirmationAndTheCurrentSelection() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        coordinator = nil
        let target = RecoveryMemoryRelay()
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        do {
            try await coordinator!.connectAccountSecurity(current: { true }, confirm: { false })
            XCTFail("Owner refused publication")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        var current = true
        do {
            try await coordinator!.connectAccountSecurity(current: { current }, confirm: { current = false; return true })
            XCTFail("Selection changed during confirmation")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        let count = await target.appends.count
        XCTAssertEqual(count, 0)
    }

    func testStationPublicationResumesAfterLostReplyAndAProcessRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        let old = try await coordinator!.serviceMembership()
        coordinator = nil
        let target = RecoveryMemoryRelay()
        await target.dropNextAppendReply()
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        do {
            try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
            XCTFail("Lost the stored genesis reply")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        coordinator = nil
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
        let connected = try await coordinator!.serviceMembership()
        XCTAssertEqual(connected.genesisHash(), old.genesisHash())
        let requests = await target.appends
        XCTAssertEqual(requests.filter { $0.expected.seq == 0 }.count, 1)
        XCTAssertEqual(h.savedKits.count, 1)
    }

    func testStationPublicationRejectsAConflictingLogAndAnUnavailableStationBeforeWriting() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let log = try await coordinator.serviceMembership()
        let other = RecoveryCoordinatorHarness(), otherCoordinator = try other.coordinator()
        _ = try await otherCoordinator.setup()
        let different = try await otherCoordinator.serviceMembership()
        let target = RecoveryMemoryRelay()
        await target.replaceLog(different)
        do {
            try await RemoteRecoveryLogReplication.publish(log: log, transport: target, current: { true })
            XCTFail("A different genesis is not a prefix")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        await target.setEntriesUnavailable(true)
        do {
            try await RemoteRecoveryLogReplication.publish(log: log, transport: target, current: { true })
            XCTFail("An outage is not an empty Station")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        let count = await target.appends.count
        XCTAssertEqual(count, 0)
    }

    func testStationPublicationRequiresReadbackAfterAcknowledgements() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let log = try await coordinator.serviceMembership(), target = RecoveryMemoryRelay()
        await target.setIgnoreAppends(true)
        do {
            try await RemoteRecoveryLogReplication.publish(log: log, transport: target, current: { true })
            XCTFail("Acknowledgements without persisted entries cannot enable access")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse) }
    }

    func testStationPublicationChecksEveryPageAndRejectsADifferentEntryUnderTheSameHead() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let log = try await coordinator.serviceMembership(), target = RecoveryMemoryRelay()
        await target.replaceLog(log)
        await target.setPageSize(1)
        try await RemoteRecoveryLogReplication.publish(log: log, transport: target, current: { true })
        await target.injectNextEntries([try XCTUnwrap(log.entries().last)])
        do {
            try await RemoteRecoveryLogReplication.publish(log: log, transport: target, current: { true })
            XCTFail("The advertised head cannot hide a mismatched prefix")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        let count = await target.appends.count
        XCTAssertEqual(count, 0)
    }

    func testStationConnectionRecoversALostBackupCommitReplyWithoutReplacingTheKeys() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        let old = try await coordinator!.serviceMembership(), keys = h.keys.keys
        coordinator = nil
        let target = RecoveryMemoryRelay()
        await target.dropAppendReply(number: old.entries().count + 1)
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        do {
            try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
            XCTFail("Lost the new encrypted backup commit reply")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        XCTAssertNotNil(try checkpoint(h.store)["backup"])
        coordinator = nil
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        try await coordinator!.connectAccountSecurity(current: { true }, confirm: { true })
        XCTAssertNil(try checkpoint(h.store)["backup"])
        XCTAssertEqual(h.keys.keys, keys)
        let connected = try await coordinator!.serviceMembership()
        XCTAssertEqual(connected.head().seq, old.head().seq + 1)
        XCTAssertEqual(connected.genesisHash(), old.genesisHash())
        let envelopes = await target.envelopes
        XCTAssertEqual(envelopes.count, 1)
    }

    func testStationConnectionNeverCreatesAReplacementForAMissingAccountKey() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        coordinator = nil
        h.keys.keys = []
        let target = RecoveryMemoryRelay()
        coordinator = try h.coordinator(relayURL: "https://new-station.example", transport: target)
        do {
            try await coordinator!.connectAccountSecurity(current: { true }, confirm: { XCTFail("Missing keys require recovery first"); return true })
            XCTFail("A Station switch cannot generate replacement keys")
        } catch { XCTAssertEqual(error.localizedDescription, DataEncryptionKeyError.invalidKey.localizedDescription) }
        XCTAssertTrue(h.keys.keys.isEmpty)
        XCTAssertEqual(h.savedKits.count, 1)
        let requests = await target.appends
        XCTAssertTrue(requests.isEmpty)
    }

    private func hostAttempt(_ coordinator: AstationRecoveryCoordinator, generation: UInt64, hostID: String = "host-a") async throws
        -> (RemotePairingCommit, RemotePairingReveal, AtemVerifyKeys) {
        let keys = try await coordinator.pairingKeys(nonce: Data(repeating: 8, count: 32))
        let reveal = try RemotePairingReveal(originalJSON: JSONSerialization.data(withJSONObject: [
            "type": "verifyReveal", "data": [
                "device_pub": Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                "device_sign_pub": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                "unlock_auth_pub": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                "host_channel_pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                "nonce": Data(repeating: 9, count: 32).base64EncodedString()
            ]]))
        let commit = try RemotePairingCommit(context: RemotePairingContext(accountID: "account-a", hostID: hostID, linkGeneration: UUID()),
            hostTrustGeneration: generation, commitment: reveal.commitment())
        return (commit, reveal, keys)
    }

    func testHostRetryRejectsSameGenerationBeforeDraftAndAcceptsHigherGenerationWithoutRemoval() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1)
        let first = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator.commitHost(request: first, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        let count = await h.relay.appends.count
        let (retry, retryReveal, retryKeys) = try await hostAttempt(coordinator, generation: 1)
        do { _ = try await coordinator.prepareHost(commit: retry, reveal: retryReveal, keys: retryKeys); XCTFail("duplicate generation") }
        catch { XCTAssertTrue(error is AstationHostEnrollmentError) }
        XCTAssertNil(try checkpoint(h.store)["publication"])
        let afterRefusal = await h.relay.appends.count
        XCTAssertEqual(count, afterRefusal)
        let (replacement, replacementReveal, replacementKeys) = try await hostAttempt(coordinator, generation: 2)
        let draft = try await coordinator.prepareHost(commit: replacement, reveal: replacementReveal, keys: replacementKeys)
        _ = try await coordinator.commitHost(request: draft, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        let log = try coordinator.channelMembership(hostID: "host-a")
        XCTAssertEqual(log.host(hostId: "host-a")?.hostTrustGen, 2)
        XCTAssertEqual(log.host(hostId: "host-a")?.hostKey.raw, replacementReveal.hostChannelPublicKey)
        _ = try replacementKeys.remote().membershipEntries(log: log, managerID: "manager-a", commit: replacement, reveal: replacementReveal)
    }

    func testHostHigherGenerationReconcilesLostCommittedReplyAcrossRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let (commit, reveal, keys) = try await hostAttempt(coordinator!, generation: 1)
        let first = try await coordinator!.prepareHost(commit: commit, reveal: reveal, keys: keys)
        await h.relay.dropNextAppendReply()
        do { _ = try await coordinator!.commitHost(request: first, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true }); XCTFail("lost reply") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        coordinator = nil
        coordinator = try h.coordinator()
        let (replacement, replacementReveal, replacementKeys) = try await hostAttempt(coordinator!, generation: 2)
        let draft = try await coordinator!.prepareHost(commit: replacement, reveal: replacementReveal, keys: replacementKeys)
        _ = try await coordinator!.commitHost(request: draft, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        XCTAssertEqual(try coordinator!.channelMembership(hostID: "host-a").host(hostId: "host-a")?.hostTrustGen, 2)
        XCTAssertNil(try checkpoint(h.store)["publication"])
    }

    func testHostHigherGenerationPreservesEvidenceOfInvalidSignedDuplicate() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let (commit, reveal, keys) = try await hostAttempt(coordinator!, generation: 1)
        let first = try await coordinator!.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator!.commitHost(request: first, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        let log = try coordinator!.channelMembership(hostID: "host-a")
        var pendingCheckpoint: Data?
        var invalid: RemoteMembershipPublication? = RemoteMembershipPublication(log: log, persist: { pendingCheckpoint = $0 })
        let body = try invalid!.prepareHost(commit: commit, hostChannelKey: PublicKeyData(alg: .ed25519, raw: reveal.hostChannelPublicKey),
            signer: "manager-a", signedAt: AstationRecoveryCoordinator.clock().wallMs)
        let provider = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a", publicKey: try h.identity.remotePublicKeys().signing)
        _ = try invalid!.sign(provider: provider, keyID: "manager-a")
        invalid = nil
        coordinator = nil
        var stored = try checkpoint(h.store)
        stored["publication"] = try XCTUnwrap(pendingCheckpoint)
        stored["hostBody"] = body
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
        coordinator = try h.coordinator()
        let (replacement, replacementReveal, replacementKeys) = try await hostAttempt(coordinator!, generation: 2)
        let draft = try await coordinator!.prepareHost(commit: replacement, reveal: replacementReveal, keys: replacementKeys)
        _ = try await coordinator!.commitHost(request: draft, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        XCTAssertEqual((try checkpoint(h.store)["supersededHostPublications"] as? [Data])?.count, 1)
        XCTAssertEqual(try coordinator!.channelMembership(hostID: "host-a").host(hostId: "host-a")?.hostTrustGen, 2)
    }

    func testAccountSecurityRequiresExplicitSetupAndSavedKit() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator()
        XCTAssertFalse(try coordinator.securitySetupComplete)
        do { _ = try await coordinator.serviceMembership(); XCTFail("uninitialized account admitted a service") }
        catch { XCTAssertTrue(h.ownerRequests.isEmpty); XCTAssertTrue(h.savedKits.isEmpty) }
        h.save = false
        do { _ = try await coordinator.setup(); XCTFail("unsaved kit completed setup") }
        catch { XCTAssertFalse(try coordinator.securitySetupComplete) }
        h.save = true
        _ = try await coordinator.setup()
        XCTAssertTrue(try coordinator.securitySetupComplete)
        let entries = try await coordinator.serviceMembership().entries()
        XCTAssertFalse(entries.isEmpty)
    }

    func testResumedSetupAndLaterExportsUseVerifiedConfiguredRelay() async throws {
        let h = RecoveryCoordinatorHarness()
        h.save = false
        do { _ = try await h.coordinator().setup(); XCTFail("unsaved kit completed setup") }
        catch { XCTAssertEqual(error.localizedDescription, AtemIdentityError.recoveryNotSaved.localizedDescription) }
        let original = try RemoteRecoveryKit(text: XCTUnwrap(h.savedKits.first))
        let previousBootstrap = try XCTUnwrap(checkpoint(h.store)["bootstrap"] as? Data)
        h.save = true
        let relay = "https://new-station.example"
        let resumed = try await h.coordinator(relayURL: relay).setup()
        let saved = try RemoteRecoveryKit(text: XCTUnwrap(h.savedKits.last))
        XCTAssertEqual(resumed.relayURL, relay)
        XCTAssertEqual(saved, resumed)
        XCTAssertEqual(resumed.genesisHash, original.genesisHash)
        XCTAssertEqual(resumed.recoveryKey, original.recoveryKey)
        XCTAssertEqual(resumed.text().replacingOccurrences(of: relay, with: original.relayURL), original.text())
        XCTAssertEqual(h.ownerRequests.filter { $0.purpose == .genesis }.count, 1)
        let before = try XCTUnwrap(PropertyListSerialization.propertyList(from: previousBootstrap, format: nil) as? [String: Any])
        let current = try XCTUnwrap(checkpoint(h.store)["bootstrap"] as? Data)
        let after = try XCTUnwrap(PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any])
        XCTAssertEqual(before["body"] as? String, after["body"] as? String)
        XCTAssertEqual(before["entry"] as? String, after["entry"] as? String)
        XCTAssertEqual(after["relayURL"] as? String, original.relayURL)
        let exported = try await h.coordinator(relayURL: "https://third-station.example").exportedKit()
        XCTAssertEqual(exported.relayURL, "https://third-station.example")
        XCTAssertEqual(exported.genesisHash, original.genesisHash)
        XCTAssertEqual(h.savedKits.count, 2, "Exporting a routing hint must not create another kit-saving acknowledgment")
    }

    func testRelayHintIsNotExportedWhenConfiguredStationCannotConfirmHistory() async throws {
        let h = RecoveryCoordinatorHarness()
        let original = try await h.coordinator().setup()
        let bootstrap = try XCTUnwrap(checkpoint(h.store)["bootstrap"] as? Data)
        let approvals = h.ownerRequests.count
        await h.relay.setEntriesUnavailable(true)
        do {
            _ = try await h.coordinator(relayURL: "https://unavailable-station.example").exportedKit()
            XCTFail("unavailable Station was exported as the recovery destination")
        } catch { XCTAssertTrue(error is RemoteRecoveryTransportError) }
        XCTAssertEqual(h.savedKits.count, 1)
        XCTAssertEqual(h.ownerRequests.count, approvals)
        XCTAssertEqual(try checkpoint(h.store)["bootstrap"] as? Data, bootstrap)
        await h.relay.setEntriesUnavailable(false)
        let retried = try await h.coordinator().exportedKit()
        XCTAssertEqual(retried, original)
    }

    private func service(_ coordinator: AstationRecoveryCoordinator, sessions: [String]? = nil,
                         projects: [String]? = nil, operations: [String] = ["prompt", "view"],
                         stationKey: P256.Signing.PublicKey? = nil) async throws -> RemoteServiceApproval {
        let log = try await coordinator.serviceMembership()
        let time = AstationRecoveryCoordinator.clock()
        var scope: [String: Any] = ["hosts": ["host-a"], "ops": operations]
        if let sessions { scope["sessions"] = sessions }
        if let projects { scope["projects"] = projects }
        let action: [String: Any] = ["action": "add", "member": ["device_id": "service-test", "kind": "service", "roles": ["service"],
            "auth_key": stationKey.map { ["alg": "p256", "pub": recoveryTestBase64($0.x963Representation)] }
                ?? ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)],
            "scope": scope, "expires_at": time.wallMs + 600_000]]
        return try RemoteServiceApproval(operationID: UUID().uuidString, integrationID: "i-01234567890123456789012345",
            issuer: "https://auth.example", ownerAccount: "ab01234567890123456789012345", stationOrigin: "https://configured.example",
            bodyJSON: log.draftEntry(signer: "manager-a", signedAt: time.wallMs, actionJson: recoveryTestJSON(action)),
            log: log, managerID: "manager-a", now: time)
    }

    private func portal(_ http: AccountOIDCHTTP) throws -> PortalIntegrationHTTP {
        let config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation", resource: "https://portal.example",
            requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
        return try PortalIntegrationHTTP(configuration: config, portalOrigin: "https://portal.example",
            ownerAccount: "ab01234567890123456789012345", http: http, accessToken: { "test-only-token" })
    }

    func testIntegrationApprovalRetainsSelectionAndVerifiedScopeWhenReopened() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator, sessions: ["ses-aaaaaaaaaaaa"])
        try await coordinator.prepareService(approval)
        let portal = try portal(transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Astation.integration-reopen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = try AccountServiceSettings(portalURL: "https://portal.example", issuer: "https://auth.example",
            clientID: "astation", resource: "https://portal.example")
        let hub = AstationHubManager(skipProjectLoad: true,
            deviceSessionStore: SessionStore(storageURL: directory.appendingPathComponent("devices")),
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso")),
            relayIdentityRepairDefaults: defaults, atemE2EIdentity: h.identity,
            sessionJournal: AtemSessionJournal(), portalSettings: settings, accountDefaults: defaults)
        hub._testRelayUrlOverride = "https://configured.example"
        let controller = IntegrationApprovalViewController(hub: hub)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        let approve = try button("Approve on This Mac…"), review = try button("Review Access")
        let load = try button("Load Requests")
        let sessions = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Session restrictions" })
        func shows(_ text: String) -> Bool {
            views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(text) }
        }
        var records = try await portal.owned(stationOrigin: coordinator.relayURL)
        let initialMembership = try await coordinator.serviceMembership()
        try controller.presentRequests(records, membership: initialMembership, coordinator: coordinator,
            portal: portal, current: { true })
        XCTAssertEqual(picker.titleOfSelectedItem, "Test bot · awaiting approval")
        XCTAssertTrue(approve.isEnabled)
        approve.performClick(nil)
        for _ in 0..<200 {
            if load.isEnabled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(load.isEnabled, "Approval must complete")
        XCTAssertEqual(picker.titleOfSelectedItem, "Test bot · provisioning", "Approval must not clear the integration selector")
        XCTAssertTrue(shows("The Station is preparing this integration"))
        XCTAssertFalse(approve.isEnabled)
        XCTAssertFalse(review.isEnabled)
        XCTAssertFalse(sessions.isEnabled)
        XCTAssertEqual(sessions.stringValue, "ses-aaaaaaaaaaaa")
        let posts = await transport.count()
        XCTAssertEqual(posts, 1)

        controller.cancelPending()
        XCTAssertEqual(picker.titleOfSelectedItem, "Load requests to choose an integration")
        XCTAssertFalse(shows("The Station is preparing this integration"), "Closing clears stale status text")
        XCTAssertEqual(sessions.stringValue, "")
        XCTAssertFalse(picker.isEnabled)
        await transport.setState("ready")
        records = try await portal.owned(stationOrigin: coordinator.relayURL)
        let membership = try await coordinator.serviceMembership()
        try controller.presentRequests(records, membership: membership, coordinator: coordinator,
            portal: portal, current: { true }, selectedID: approval.integrationID)
        XCTAssertEqual(picker.titleOfSelectedItem, "Test bot · ready")
        XCTAssertTrue(shows("The Station reports this integration as ready"))
        XCTAssertEqual(sessions.stringValue, "ses-aaaaaaaaaaaa")
        let host = try button("host-a")
        XCTAssertEqual(host.state, .on)
        XCTAssertFalse(host.isEnabled, "Approved scope is visible but cannot silently change")
        XCTAssertFalse(approve.isEnabled)
        XCTAssertFalse(review.isEnabled)
        XCTAssertThrowsError(try controller.presentRequests([], membership: membership, coordinator: coordinator,
            portal: portal, current: { false }))
        XCTAssertEqual(picker.titleOfSelectedItem, "Test bot · ready", "A delayed response from an old context cannot replace the list")

        // Reopening with no saved account authorization must finish without starting browser login.
        controller.cancelPending()
        controller.refreshForDisplay()
        for _ in 0..<200 {
            if load.isEnabled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(load.isEnabled)
        XCTAssertTrue(shows("Authorization needs to be renewed"))
        XCTAssertFalse(approve.isEnabled)
        XCTAssertFalse(review.isEnabled)
        let finalPosts = await transport.count()
        XCTAssertEqual(finalPosts, 1, "Reopening must not resubmit the approval")
        controller.cancelPending()
    }

    func testHostWorkApprovalCannotSignWithoutHostAuthorizationOrAfterHostDisconnectsDuringConfirmation() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in })
        let transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator, operations: ["launch", "view"])
        try await coordinator.prepareService(approval)
        let before = await h.relay.appends.count
        let confirmations = h.ownerRequests.count
        do {
            try await coordinator.approveService(approval, portal: portal(transport), current: { true })
            XCTFail("New operations require host authorization before signing")
        } catch StationIntegrationError.hostUpgradeRequired { }
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        var checks = 0
        do {
            try await coordinator.approveService(approval, portal: portal(transport), authorizeNewOperations: { log in
                XCTAssertEqual(log.accountId(), "account-a")
                checks += 1
                if checks == 2 { throw StationIntegrationError.hostUpgradeRequired }
            }, current: { true })
            XCTFail("A host that disconnected during owner authentication cannot be enrolled")
        } catch StationIntegrationError.hostUpgradeRequired { }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        let appends = await h.relay.appends.count, posts = await transport.count()
        XCTAssertEqual(appends, before)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(try coordinator.pendingServiceApproval(), approval)
    }

    func testNewServiceOperationsCannotUseHostFeaturesAsCompleteVerifierEvidence() async throws {
        for operations in [["launch", "view"], ["message", "view"], ["message", "notify", "prompt", "view"]] {
            let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
            _ = try await coordinator.setup()
            let approval = try await service(coordinator, operations: operations)
            try await coordinator.prepareService(approval)
            let appends = await h.relay.appends.count, confirmations = h.ownerRequests.count
            do {
                try await coordinator.approveService(approval, portal: portal(transport),
                    authorizeNewOperations: { _ in }, current: { true })
                XCTFail("Host features cannot confirm every strict verifier")
            } catch { XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers) }
            XCTAssertEqual(h.ownerRequests.count, confirmations)
            let after = await h.relay.appends.count, posts = await transport.count()
            XCTAssertEqual(after, appends)
            XCTAssertEqual(posts, 0)
        }
    }

    func testKeyProviderRequiresInventoryForServiceEnrollmentAndRoleChanges() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let key = try h.identity.remotePublicKeys(create: false).signing
        let provider = AstationMembershipKeyProvider(identity: h.identity, keyID: coordinator.managerID, publicKey: key)
        let log = try await coordinator.serviceMembership()
        let clock = AstationRecoveryCoordinator.clock()
        for operations in [["view"], ["launch", "view"], ["message", "view"], ["notify", "view"]] {
            let enrollment = try await service(coordinator, operations: operations)
            let roles: [String: Any] = ["action": "set_roles", "device_id": "service-test", "roles": ["service"],
                "scope": ["hosts": ["host-a"], "ops": operations], "expires_at": clock.wallMs + 600_000]
            let change = try log.draftEntry(signer: coordinator.managerID, signedAt: clock.wallMs, actionJson: recoveryTestJSON(roles))
            for body in [enrollment.bodyJSON, change] {
                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: coordinator.managerID)
                let before = h.identityCryptography.signingCalls
                if operations == ["view"] {
                    XCTAssertNoThrow(try provider.sign(request: request))
                    XCTAssertEqual(h.identityCryptography.signingCalls, before + 1)
                } else {
                    XCTAssertThrowsError(try provider.sign(request: request))
                    XCTAssertEqual(h.identityCryptography.signingCalls, before)
                }
            }
        }
    }

    func testServiceApprovalRequiresOutOfScopeHostAndRejectsReplacedChannelAtKey() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in }, confirmVerifierRoster: { _ in true })
        _ = try await coordinator.setup()
        for id in ["host-a", "host-b"] {
            let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1, hostID: id)
            let draft = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
            _ = try await coordinator.commitHost(request: draft, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        }
        let roster = try await coordinator.prepareStationVerifierRoster(current: { true })
        try await coordinator.acceptStationVerifierRoster(roster, current: { true })
        let approval = try await service(coordinator, operations: ["launch", "view"])
        try await coordinator.prepareService(approval)
        let portal = try portal(ServiceApprovalPortal())
        let original = UUID(), other = UUID()
        let before = h.identityCryptography.signingCalls
        let confirmations = h.ownerRequests.count
        let incomplete = try coordinator.serviceHostVerifier(for: approval, current: { true }) { gate, required in
            XCTAssertEqual(gate.enrolledHostIDs, ["host-a", "host-b"])
            XCTAssertEqual(required.action, "add")
            return ["host-a": [original]]
        }
        do {
            _ = try await coordinator.approveService(approval, portal: portal, authorizeNewOperations: incomplete, current: { true })
            XCTFail("An offline host outside this service's scope still verifies the account list")
        } catch { XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers) }
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        var checks = 0
        let replaced = try coordinator.serviceHostVerifier(for: approval, current: { true }) { _, _ in
            checks += 1
            return ["host-a": [original], "host-b": [checks < 3 ? other : UUID()]]
        }
        do {
            _ = try await coordinator.approveService(approval, portal: portal, authorizeNewOperations: replaced, current: { true })
            XCTFail("Replacement at the private key must cancel this signature")
        } catch { XCTAssertTrue(error is AtemError, "UniFFI wraps the refusal at the key provider") }
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(h.identityCryptography.signingCalls, before)
        XCTAssertEqual(try coordinator.pendingServiceApproval(), approval)
    }

    func testServiceApprovalChecksProtectedKeyAndBothReplicaProcessesThroughSigning() async throws {
        enum Scenario: CaseIterable { case healthy, missingKey, missingExistingService, replacedReplica, expiredAtKey, renewedPastReview }
        for scenario in Scenario.allCases {
            let h = RecoveryCoordinatorHarness(), portalServer = ServiceApprovalPortal()
            var extraTime: UInt64 = 0
            let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in },
                confirmVerifierRoster: { _ in true },
                verifierTime: { RemoteVerifierSigningGate.evidenceTimeMilliseconds() + extraTime })
            _ = try await coordinator.setup()
            let existingKey = P256.Signing.PrivateKey().publicKey.x963Representation
            let existingID = "existing-service"
            let existingAuth = ["alg": "p256", "pub": recoveryTestBase64(existingKey)]
            try await append(["action": "add", "member": ["device_id": existingID, "kind": "service", "roles": ["service"],
                "auth_key": existingAuth, "scope": ["hosts": ["host-a"], "ops": ["view"]],
                "expires_at": AstationRecoveryCoordinator.clock().wallMs + 600_000]], harness: h)
            let serverReview = try await coordinator.prepareStationVerifierRoster(current: { true })
            try await coordinator.acceptStationVerifierRoster(serverReview, current: { true })
            let key = P256.Signing.PrivateKey().publicKey
            let approval = try await service(coordinator, operations: ["launch", "view"], stationKey: key)
            let log = try await coordinator.serviceMembership()
            try await coordinator.prepareService(approval)
            await portalServer.setScopes(["agent.launch", "agent.view"])
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RecoveryReportHTTPStub.self]
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let head: [String: Any] = ["seq": log.head().seq, "hash": log.head().hash]
            let inventory = verifierInventory()
            RecoveryReportHTTPStub.lock.withLock {
                RecoveryReportHTTPStub.response = { request, bytes in
                    XCTAssertEqual(request.url?.path, "/agora-build/v1/logs/" + log.genesisHash() + "/verifiers/services")
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    XCTAssertEqual(body["member_ids"] as? [String], [existingID, "service-test"])
                    XCTAssertEqual(body["expected"] as? NSDictionary, head as NSDictionary)
                    let call = reads.withLock { $0 += 1; return $0 }
                    var member: [String: Any] = ["id": "service-test"]
                    if scenario != .missingKey { member["auth_key"] = ["alg": "p256", "pub": recoveryTestBase64(key.x963Representation)] }
                    var existing: [String: Any] = ["id": existingID]
                    if scenario != .missingExistingService { existing["auth_key"] = existingAuth }
                    let rows = serverReview.candidate.replicas.map { id -> [String: Any] in
                        let replaced = scenario == .replacedReplica && call == 2 && id == serverReview.candidate.replicas.last
                        let shortLease = scenario == .renewedPastReview && call == 1 && id == serverReview.candidate.replicas.last
                        return ["id": id, "connection_generation": replaced ? 2 : 1, "authorization_ms_left": shortLease ? 2_000 : 30_000,
                                "verifier": ["version": inventory.version, "actions": inventory.actions]]
                    }
                    return try JSONSerialization.data(withJSONObject: ["origin": approval.stationOrigin, "account_id": log.accountId(),
                        "genesis_hash": log.genesisHash(), "roster_generation": serverReview.candidate.generation,
                        "head": head, "replicas": rows, "services": [existing, member]])
                }
            }
            defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
            let reports = coordinator.serviceStationVerifier(for: approval, current: { true }) { _ in
                try RemoteRecoveryHTTP(relayURL: approval.stationOrigin, configuration: config) { "test-token" }
            }
            let before = h.identityCryptography.signingCalls, prompts = h.ownerRequests.count
            var checks = 0
            do {
                _ = try await coordinator.approveService(approval, portal: portal(portalServer), authorizeNewOperations: { _ in
                    checks += 1
                    if scenario == .expiredAtKey && checks == 3 { extraTime = 30_000 }
                    if scenario == .renewedPastReview && checks == 3 { extraTime = 2_000 }
                }, refreshServiceReports: reports, current: { true })
                XCTAssertEqual(scenario, .healthy)
            } catch {
                switch scenario {
                case .healthy: XCTFail("healthy Station reports refused: \(error)")
                case .missingKey, .missingExistingService: XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers)
                case .replacedReplica: XCTAssertEqual(error as? RemoteVerifierGateError, .staleConnection)
                case .expiredAtKey, .renewedPastReview: XCTAssertTrue(error is AtemError)
                }
            }
            let missing = scenario == .missingKey || scenario == .missingExistingService
            XCTAssertEqual(reads.withLock { $0 }, missing ? 1 : 2)
            XCTAssertEqual(h.ownerRequests.count, prompts + (missing ? 0 : 1))
            XCTAssertEqual(h.identityCryptography.signingCalls, before + (scenario == .healthy ? 1 : 0))
        }
    }

    func testServiceApprovalReadsEveryNativeSlotAndRechecksOriginalNonceAfterConfirmation() async throws {
        enum Scenario: CaseIterable { case healthy, missingMember, missingReply, expiredAtKey }
        for scenario in Scenario.allCases {
            let h = RecoveryCoordinatorHarness(), mailbox = ApprovalReportMailbox(), portalServer = ServiceApprovalPortal()
            var prompts = 0, extraTime: UInt64 = 0
            h.serviceOwnerConfirmation = { _, _ in
                prompts += 1
                if scenario == .missingReply { await mailbox.discardReports() }
                return true
            }
            let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in }, confirmVerifierRoster: { _ in true },
                confirmProcessRoster: { true }, verifierTime: { RemoteVerifierSigningGate.evidenceTimeMilliseconds() + extraTime })
            _ = try await coordinator.setup()
            if scenario == .missingMember { _ = try await addSecondManager(harness: h) }
            let serverReview = try await coordinator.prepareStationVerifierRoster(current: { true })
            try await coordinator.acceptStationVerifierRoster(serverReview, current: { true })
            let review = try await coordinator.prepareProcessReview(member: coordinator.managerID, current: { true })
            try await coordinator.acceptProcessReview(review, lines: ["truck " + verifierReportProcess()], current: { true })
            let approval = try await service(coordinator, operations: ["launch", "view"])
            try await coordinator.prepareService(approval)
            await portalServer.setScopes(["agent.launch", "agent.view"])
            let reports = coordinator.serviceMemberProcessVerifier(for: approval, current: { true }, transport: { _, _ in mailbox }, waitForReport: {})
            let signs = h.identityCryptography.signingCalls
            var checks = 0
            do {
                _ = try await coordinator.approveService(approval, portal: portal(portalServer), authorizeNewOperations: { _ in
                    checks += 1
                    if scenario == .expiredAtKey && checks == 3 { extraTime = 30_000 }
                }, refreshServiceReports: reports, current: { true })
                XCTAssertEqual(scenario, .healthy)
            } catch {
                switch scenario {
                case .healthy: XCTFail("A current signed manager report should pass: \(error)")
                case .missingMember: XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview)
                case .missingReply: XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse)
                case .expiredAtKey: XCTAssertTrue(error is AtemError)
                }
            }
            let reads = await mailbox.reads
            XCTAssertEqual(prompts, scenario == .missingMember ? 0 : 1)
            XCTAssertEqual(reads.count, scenario == .missingMember ? 0 : 2)
            XCTAssertEqual(Set(reads).count, scenario == .missingMember ? 0 : 1)
            XCTAssertEqual(h.identityCryptography.signingCalls, signs + (scenario == .healthy ? 1 : 0))
        }
    }

    func testServiceApprovalRequiresEveryReviewedServiceProcess() async throws {
        enum Scenario: CaseIterable { case healthy, offline, staleReview }
        for scenario in Scenario.allCases {
            let h = RecoveryCoordinatorHarness(), mailbox = ApprovalReportMailbox(), server = ServiceApprovalPortal()
            let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in }, confirmVerifierRoster: { _ in true },
                confirmProcessRoster: { true })
            _ = try await coordinator.setup()
            let key = Curve25519.Signing.PrivateKey(), id = "existing-service"
            try await append(["action": "add", "member": ["device_id": id, "kind": "service", "roles": ["service"],
                "auth_key": ["alg": "ed25519", "pub": recoveryTestBase64(key.publicKey.rawRepresentation)],
                "scope": ["hosts": ["host-a"], "ops": ["view"]], "expires_at": AstationRecoveryCoordinator.clock().wallMs + 600_000]], harness: h)
            let roster = try await coordinator.prepareStationVerifierRoster(current: { true })
            try await coordinator.acceptStationVerifierRoster(roster, current: { true })
            for (member, slots) in [(id, ["observer", "worker"]), (coordinator.managerID, ["truck"])] {
                if scenario == .staleReview && member == coordinator.managerID {
                    let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1, hostID: "host-b")
                    let draft = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
                    _ = try await coordinator.commitHost(request: draft, confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
                }
                let review = try await coordinator.prepareProcessReview(member: member, current: { true })
                try await coordinator.acceptProcessReview(review, lines: slots.map { $0 + " " + verifierReportProcess() }, current: { true })
            }
            let approval = try await service(coordinator, operations: ["launch", "view"])
            let log = try await coordinator.serviceMembership()
            try await coordinator.prepareService(approval)
            await server.setScopes(["agent.launch", "agent.view"])
            let reports = coordinator.serviceMemberProcessVerifier(for: approval, current: { true }, transport: { _, _ in mailbox }) {
                for slot in scenario == .offline ? ["worker"] : ["observer", "worker"] {
                    let requests = try await mailbox.verifierChallenges(genesisHash: log.genesisHash(), signer: "service:" + id,
                        slot: slot, expected: log.head())
                    let challenge = try XCTUnwrap(requests.first)
                    let request = try VerifierReportRequest(log: log, challengeJson: challenge, signer: "service:" + id,
                        slot: slot, origin: approval.stationOrigin, keyId: id, nowMs: AstationRecoveryCoordinator.clock().wallMs)
                    let report = try request.finish(signature: key.signature(for: request.signRequest().input))
                    _ = try await mailbox.publishVerifierReport(genesisHash: log.genesisHash(), challengeJSON: challenge,
                        expected: log.head(), reportJSON: report)
                }
            }
            let before = h.identityCryptography.signingCalls, confirmations = h.ownerRequests.count
            do {
                _ = try await coordinator.approveService(approval, portal: portal(server), authorizeNewOperations: { _ in },
                    refreshServiceReports: reports, current: { true })
                XCTAssertEqual(scenario, .healthy)
            } catch {
                switch scenario {
                case .healthy: XCTFail("Every reviewed process answered: \(error)")
                case .offline: XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers)
                case .staleReview: XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview)
                }
            }
            let healthy = scenario == .healthy
            XCTAssertEqual(h.identityCryptography.signingCalls - before, healthy ? 1 : 0)
            XCTAssertEqual(h.ownerRequests.count - confirmations, healthy ? 1 : 0)
            let reads = await mailbox.reads
            XCTAssertEqual(Set(reads).count, scenario == .staleReview ? 0 : 3)
            XCTAssertEqual(reads.count, healthy ? 6 : Set(reads).count)
        }
    }

    func testApprovalRequiresSignedProcessReportsAtEachReviewedStation() async throws {
        let previousOrigin = "https://second.example"
        for loseReply in [true, false] {
            let h = RecoveryCoordinatorHarness(), previous = RecoveryMemoryRelay(stationOrigin: previousOrigin)
            let initial = try h.coordinator()
            _ = try await initial.setup()
            await previous.replaceLog(try await initial.serviceMembership())
            let previousMailbox = ApprovalReportMailbox(), selectedMailbox = ApprovalReportMailbox()
            var confirmations = 0
            h.serviceOwnerConfirmation = { _, _ in
                confirmations += 1
                if loseReply { await previousMailbox.discardReports() }
                return true
            }
            for (origin, relay) in [(previousOrigin, previous), (initial.relayURL, h.relay)] {
                let manager = try h.coordinator(relayURL: origin, transport: relay,
                    confirmVerifierRoster: { _ in true }, confirmProcessRoster: { true })
                let servers = try await manager.prepareStationVerifierRoster(current: { true })
                try await manager.acceptStationVerifierRoster(servers, current: { true })
                let review = try await manager.prepareProcessReview(member: manager.managerID, current: { true })
                try await manager.acceptProcessReview(review, lines: ["desktop " + verifierReportProcess()], current: { true })
            }
            let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in })
            let approval = try await service(coordinator, operations: ["launch", "view"])
            try await coordinator.prepareService(approval)
            let server = ServiceApprovalPortal()
            await server.setScopes(["agent.launch", "agent.view"])
            let verify = coordinator.serviceMemberProcessVerifier(for: approval, current: { true }, transport: { origin, active in
                XCTAssertTrue(active())
                if origin == previousOrigin { return previousMailbox }
                XCTAssertEqual(origin, approval.stationOrigin)
                return selectedMailbox
            }, waitForReport: {})
            let before = h.identityCryptography.signingCalls
            do {
                _ = try await coordinator.approveService(approval, portal: portal(server), authorizeNewOperations: { _ in },
                    refreshServiceReports: verify, current: { true })
                XCTAssertFalse(loseReply)
            } catch {
                XCTAssertTrue(loseReply)
                XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse)
            }
            XCTAssertEqual(confirmations, 1)
            XCTAssertEqual(h.identityCryptography.signingCalls, before + (loseReply ? 0 : 1))
            let selectedReads = await selectedMailbox.reads, previousReads = await previousMailbox.reads
            for (origin, nonces) in [(approval.stationOrigin, selectedReads), (previousOrigin, previousReads)] {
                XCTAssertEqual(nonces.count, 2)
                XCTAssertEqual(Set(nonces).count, 1)
                XCTAssertEqual(try parseVerifierReportChallenge(challengeJson: XCTUnwrap(nonces.first)).origin, origin)
            }
            XCTAssertNotEqual(selectedReads.first, previousReads.first)
        }
    }

    func testServiceApprovalRechecksPreviouslyReviewedStationAfterChangingSelection() async throws {
        enum Scenario: CaseIterable { case healthy, unreviewed, offline, replaced, expiredAtKey }
        let origin = "https://second.example"
        for scenario in Scenario.allCases {
            let h = RecoveryCoordinatorHarness(), other = RecoveryMemoryRelay(stationOrigin: origin)
            let initial = try h.coordinator()
            _ = try await initial.setup()
            await other.replaceLog(try await initial.serviceMembership())
            let selected = try h.coordinator(relayURL: origin, transport: other, confirmVerifierRoster: { _ in true },
                confirmProcessRoster: { true })
            if scenario == .unreviewed {
                let review = try await selected.prepareProcessReview(member: selected.managerID, current: { true })
                try await selected.acceptProcessReview(review, lines: ["desktop " + verifierReportProcess()], current: { true })
            } else {
                let roster = try await selected.prepareStationVerifierRoster(current: { true })
                try await selected.acceptStationVerifierRoster(roster, current: { true })
            }
            if scenario != .offline { await other.setVerifierConnection(1) }
            var ticks: UInt64 = 0, confirmations = 0
            h.serviceOwnerConfirmation = { _, _ in
                confirmations += 1
                if scenario == .replaced { await other.setVerifierConnection(2) }
                return true
            }
            var origins: [String] = []
            let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in },
                verifierTime: { RemoteVerifierSigningGate.evidenceTimeMilliseconds() + ticks })
            let approval = try await service(coordinator, operations: ["launch", "view"])
            try await coordinator.prepareService(approval)
            let check = coordinator.serviceAdditionalStationVerifier(for: approval, current: { true }) { target, current in
                XCTAssertTrue(current())
                origins.append(target)
                return other
            }
            let server = ServiceApprovalPortal()
            await server.setScopes(["agent.launch", "agent.view"])
            let before = h.identityCryptography.signingCalls
            var checks = 0
            do {
                _ = try await coordinator.approveService(approval, portal: portal(server), authorizeNewOperations: { _ in
                    checks += 1
                    if scenario == .expiredAtKey && checks == 3 { ticks = 30_000 }
                }, refreshServiceReports: check, current: { true })
                XCTAssertEqual(scenario, .healthy)
            } catch {
                switch scenario {
                case .healthy: XCTFail("Current peer Station was refused: \(error)")
                case .unreviewed: XCTAssertEqual(error as? RemoteVerifierGateError, .invalidRoster)
                case .offline, .replaced: XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers)
                case .expiredAtKey: XCTAssertTrue(error is AtemError)
                }
            }
            if scenario == .unreviewed { XCTAssertEqual(origins, []) }
            else { XCTAssertEqual(origins, Array(repeating: origin, count: scenario == .offline ? 1 : 2)) }
            XCTAssertEqual(confirmations, scenario == .offline || scenario == .unreviewed ? 0 : 1)
            XCTAssertEqual(h.identityCryptography.signingCalls, before + (scenario == .healthy ? 1 : 0))
        }
    }

    func testServiceConfirmationExpiresWhileRecheckingParticipants() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let coordinator = try h.coordinator(authorizeNewMembership: { _, _ in })
        _ = try await coordinator.setup()
        let approval = try await service(coordinator, operations: ["launch", "view"])
        try await coordinator.prepareService(approval)
        let initialSigns = h.identityCryptography.signingCalls
        let tick = OSAllocatedUnfairLock(initialState: UInt64(10))
        var checks = 0
        do {
            _ = try await coordinator.approveService(approval, portal: portal(transport), authorizeNewOperations: { _ in
                checks += 1
                if checks == 2 { tick.withLock { $0 += 30_000 } }
            }, confirmationClock: { tick.withLock { $0 } }, current: { true })
            XCTFail("The post-confirmation checks consumed the approval window")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(h.identityCryptography.signingCalls, initialSigns)
        XCTAssertEqual(try coordinator.pendingServiceApproval(), approval)
    }

    func testNewServiceOperationsRecheckInventoryAfterConfirmationAndAtTheKeyBoundary() async throws {
        for failAt in [2, 3] {
            let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
            var checks = 0
            let coordinator = try h.coordinator(authorizeNewMembership: { request, log in
                XCTAssertEqual(request.purpose, .enroll)
                XCTAssertEqual(log.accountId(), "account-a")
                checks += 1
                if checks == failAt { throw RemoteVerifierGateError.unconfirmedVerifiers }
            })
            _ = try await coordinator.setup()
            let approval = try await service(coordinator, operations: ["launch", "view"])
            try await coordinator.prepareService(approval)
            let appends = await h.relay.appends.count, confirmations = h.ownerRequests.count
            do {
                try await coordinator.approveService(approval, portal: portal(transport),
                    authorizeNewOperations: { _ in }, current: { true })
                XCTFail("Expired inventory cannot authorize a service signature")
            } catch {
                if failAt == 2 { XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers) }
                else { XCTAssertTrue(error is AtemError, "UniFFI wraps a rejected key-provider callback: \(error)") }
            }
            XCTAssertEqual(checks, failAt)
            XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
            let after = await h.relay.appends.count, posts = await transport.count()
            XCTAssertEqual(after, appends)
            XCTAssertEqual(posts, 0)
            XCTAssertEqual(try coordinator.pendingServiceApproval(), approval)
        }
    }

    func testAlreadySignedServiceOperationsRecoverWithoutNewInventoryOrOwnerConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var checks = 0
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeNewMembership: { _, _ in checks += 1 })
        _ = try await coordinator!.setup()
        let approval = try await service(coordinator!, operations: ["launch", "view"])
        await transport.setScopes(["agent.launch", "agent.view"])
        try await coordinator!.prepareService(approval)
        await h.relay.dropNextAppendReply()
        do {
            try await coordinator!.approveService(approval, portal: portal(transport),
                authorizeNewOperations: { _ in }, current: { true })
            XCTFail("The durable append reply should be lost")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        XCTAssertEqual(checks, 3, "Check before/after owner confirmation and at the private key")
        let confirmations = h.ownerRequests.count
        let before = await h.relay.appends
        let signed = try XCTUnwrap(before.last).entryJson
        coordinator = nil
        let recovered = try h.coordinator(authorizeNewMembership: { _, _ in
            XCTFail("A saved signature is delivery recovery, never new signing")
            throw RemoteVerifierGateError.unconfirmedVerifiers
        })
        try await recovered.approveService(approval, portal: portal(transport), current: { true })
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let after = await h.relay.appends
        XCTAssertEqual(after.last?.entryJson, signed)
        XCTAssertNil(try recovered.pendingServiceApproval())
    }

    func testServiceConfirmationUsesTheExactReviewedApprovalAndCannotBeBypassed() async throws {
        let h = RecoveryCoordinatorHarness()
        var presented: [RemoteServiceApproval] = []
        var confirmed = false
        h.serviceOwnerConfirmation = { approval, _ in
            presented.append(approval)
            return confirmed
        }
        let coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        let before = await h.relay.appends.count
        let genericConfirmations = h.ownerRequests.count
        do {
            try await coordinator.approveService(approval, portal: portal(transport), current: { true })
            XCTFail("A refused integration confirmation cannot use the generic owner confirmation")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        let refusedAppends = await h.relay.appends.count
        let refusedPosts = await transport.count()
        XCTAssertEqual(refusedAppends, before)
        XCTAssertEqual(refusedPosts, 0)
        XCTAssertEqual(presented, [approval])
        XCTAssertEqual(h.ownerRequests.count, genericConfirmations)
        confirmed = true
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        XCTAssertEqual(presented, [approval, approval])
        let posts = await transport.count()
        XCTAssertEqual(posts, 1)
    }

    func testApprovedIntegrationScopeReloadsFromCommittedMembership() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator, sessions: ["ses-aaaaaaaaaaaa"], projects: ["h1.0123abcd." + String(repeating: "a", count: 64)])
        try await coordinator.prepareService(approval)
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        let record = try XCTUnwrap(records.first)
        let reloaded = try h.coordinator()
        let log = try await reloaded.serviceMembership()
        let scope = try XCTUnwrap(IntegrationApprovalViewController.approvedScope(record: record, log: log))
        XCTAssertEqual(scope.hosts, ["host-a"])
        XCTAssertEqual(scope.sessions, ["ses-aaaaaaaaaaaa"])
        XCTAssertEqual(scope.projects, ["h1.0123abcd." + String(repeating: "a", count: 64)])
        XCTAssertNil(try reloaded.pendingServiceApproval(), "Display must not depend on a completed approval's draft")
    }

    func testApprovedIntegrationUnrestrictedScopeDoesNotInventSessionRestrictions() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        let record = try XCTUnwrap(records.first)
        let log = try await coordinator.serviceMembership()
        let scope = try XCTUnwrap(IntegrationApprovalViewController.approvedScope(record: record, log: log))
        XCTAssertEqual(scope.hosts, ["host-a"])
        XCTAssertNil(scope.sessions)
        XCTAssertNil(scope.projects)
        let clock = AstationRecoveryCoordinator.clock()
        let now = HostClock(wallMs: clock.wallMs + 700_000, monoMs: clock.monoMs + 700_000, bootId: clock.bootId)
        XCTAssertNil(try IntegrationApprovalViewController.approvedScope(record: record, log: log, now: now), "An expired service must not appear active")
    }

    func testApprovedIntegrationDoesNotUseAnUncommittedOrDifferentServiceKey() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        _ = try await coordinator.setup()
        let before = try await coordinator.serviceMembership()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        let record = try XCTUnwrap(records.first)
        XCTAssertNil(try IntegrationApprovalViewController.approvedScope(record: record, log: before))
        let object: [String: Any] = ["id": record.id, "name": record.name, "stationOrigin": record.stationOrigin, "state": record.state,
                  "scopes": record.scopes, "expiresAt": record.expiresAt, "role": record.role, "r9Svc": String(repeating: "0", count: 64)]
        let differentKey = try JSONDecoder().decode(PortalIntegrationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let log = try await coordinator.serviceMembership()
        XCTAssertNil(try IntegrationApprovalViewController.approvedScope(record: differentKey, log: log))
        try await append(["action": "remove", "device_id": "service-test"], harness: h)
        let removed = await h.relay.log
        XCTAssertNil(try IntegrationApprovalViewController.approvedScope(record: record, log: XCTUnwrap(removed)), "A removed service must not appear approved")
    }

    func testServiceCommitNotifiesAfterDurabilityAndUnlockEvenWhenPortalReplyIsLost() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1)
        let request = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator.commitHost(request: request,
            confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        var heads: [LogHead] = []
        coordinator.onMembershipCommit = { head in
            heads.append(head)
            do {
                // This read refuses a busy coordinator and any uncommitted log.
                let log = try coordinator.channelMembership(hostID: "host-a")
                XCTAssertEqual(log.head(), head)
                XCTAssertEqual(log.member(deviceId: "service-test")?.roles, ["service"])
                let saved = try XCTUnwrap(self.checkpoint(h.store)["entries"] as? [String])
                XCTAssertEqual(saved, log.entries())
            } catch { XCTFail("Committed head was not available to the channel: \(error)") }
        }
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        XCTAssertTrue(heads.isEmpty, "Preparing an unsigned draft must not replace channels")
        let transport = ServiceApprovalPortal()
        await transport.dropNextReply()
        do { try await coordinator.approveService(approval, portal: portal(transport), current: { true }); XCTFail("lost reply") }
        catch { XCTAssertEqual(error as? AccountLoginError, .unavailable) }
        let committed = try coordinator.channelMembership(hostID: "host-a").head()
        XCTAssertEqual(heads, [committed], "A lost Portal reply cannot hide a durable membership change")
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        _ = try await coordinator.serviceMembership()
        try coordinator.checkpointPendingWaits()
        XCTAssertEqual(heads, [committed], "Retries and unchanged checkpoints cannot loop channel replacement")
        coordinator.onMembershipCommit = nil
    }

    func testUncertainCheckpointDoesNotAdvertiseANewMembershipHead() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        var heads: [LogHead] = []
        coordinator.onMembershipCommit = { heads.append($0) }
        h.store.failAtEntryCount = try XCTUnwrap(checkpoint(h.store)["entries"] as? [String]).count + 1
        do {
            try await coordinator.approveService(approval, portal: portal(ServiceApprovalPortal()), current: { true })
            XCTFail("uncertain checkpoint")
        }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        let remote = await h.relay.log
        XCTAssertNotNil(remote?.member(deviceId: "service-test"), "The relay stored the entry before local persistence failed")
        XCTAssertTrue(heads.isEmpty)
        XCTAssertThrowsError(try coordinator.channelMembership(hostID: "host-a"))
    }

    func testMultipleMembershipCommitsNotifyOnceAfterAccountOperationCompletes() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        var heads: [LogHead] = []
        coordinator.onMembershipCommit = { head in
            heads.append(head)
            do {
                try coordinator.checkpointPendingWaits()
                let entries = try XCTUnwrap(self.checkpoint(h.store)["entries"] as? [String])
                XCTAssertEqual(try signedObjectInfo(json: XCTUnwrap(entries.last)).entryHash, head.hash)
            } catch { XCTFail("Membership notification preceded its durable checkpoint: \(error)") }
        }
        _ = try await coordinator.setup()
        XCTAssertEqual(heads.count, 1, "Genesis and backup publication should reconcile channels once")
        XCTAssertGreaterThan(try XCTUnwrap(heads.last).seq, 1)
        _ = try await coordinator.serviceMembership()
        XCTAssertEqual(heads.count, 1, "Unchanged refreshes must not replace channels again")
        coordinator.onMembershipCommit = nil
    }

    private func revokedService(_ coordinator: AstationRecoveryCoordinator, transport: ServiceApprovalPortal,
                                expired: Bool = false) async throws -> PortalIntegrationRecord {
        _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        await transport.revoke(expired: expired)
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        return try XCTUnwrap(records.first)
    }

    private func activeService(_ coordinator: AstationRecoveryCoordinator, transport: ServiceApprovalPortal) async throws -> PortalIntegrationRecord {
        _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        try await coordinator.approveService(approval, portal: portal(transport), current: { true })
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        return try XCTUnwrap(records.first)
    }

    func testRevokedServiceRemovalPersistsAndNotifiesWithoutChangingOtherAccess() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport, expired: true)
        let before = try await coordinator.serviceMembership()
        let host = before.host(hostId: "host-a")
        var notified = false
        coordinator.onMembershipCommit = { head in
            let entries = (try? self.checkpoint(h.store)["entries"] as? [String]) ?? []
            notified = head.seq == before.head().seq + 1 && entries.count == Int(head.seq)
        }
        XCTAssertEqual(try AstationRecoveryCoordinator.removableService(record: record, log: before), "service-test")
        XCTAssertFalse(try AstationRecoveryCoordinator.serviceRemovalComplete(record: record, log: before))
        try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345",
            portal: portal(transport), current: { true })
        let after = try await coordinator.serviceMembership()
        XCTAssertEqual(after.member(deviceId: "service-test")?.status, .removed)
        XCTAssertEqual(after.host(hostId: "host-a"), host)
        XCTAssertEqual(after.member(deviceId: "manager-a")?.roles, before.member(deviceId: "manager-a")?.roles)
        XCTAssertNil(try coordinator.pendingServiceRemovalID())
        XCTAssertEqual(try checkpoint(h.store)["version"] as? Int, 3, "older readers must reject an account with removal state")
        XCTAssertTrue(notified)
        XCTAssertEqual(h.ownerRequests.last?.purpose, .remove)
        XCTAssertNil(try AstationRecoveryCoordinator.removableService(record: record, log: after))
        XCTAssertTrue(try AstationRecoveryCoordinator.serviceRemovalComplete(record: record, log: after))
    }

    func testServiceRemovalReopensChannelBeforeTheUIRefreshesAccountMembership() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let (commit, reveal, keys) = try await hostAttempt(coordinator, generation: 1)
        let enrollment = try await coordinator.prepareHost(commit: commit, reveal: reveal, keys: keys)
        _ = try await coordinator.commitHost(request: enrollment,
            confirmedAt: AstationRecoveryCoordinator.clock().monoMs, current: { true })
        let record = try await revokedService(coordinator, transport: transport)
        let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
            account: "account-a", device: "host-a", pairingSession: "pairing-a")
        var opened: [LogHead] = []
        let client = AtemSessionClient(context: { context }, send: { _, _ in false }, openChannel: { _ in
            do { opened.append(try coordinator.channelMembership(hostID: "host-a").head()) }
            catch { XCTFail("Channel initialization raced another account operation: \(error)") }
        })
        client.start()
        let before = try XCTUnwrap(opened.last)
        coordinator.onMembershipCommit = { _ in client.channelMembershipRefreshed(context: context) }
        try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345",
            portal: portal(transport), current: { true })
        let after = try await coordinator.serviceMembership()
        XCTAssertEqual(opened.map(\.seq), [before.seq, after.head().seq])
        XCTAssertEqual(after.head().seq, before.seq + 1)
        XCTAssertEqual(client.phase, .connecting)
        XCTAssertNil(client.welcome, "The replacement channel still requires an authenticated welcome")
    }

    func testRemovalLostReplyResumesExactSignatureWithoutAnotherOwnerPrompt() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let record = try await revokedService(coordinator!, transport: transport)
        await h.relay.dropNextAppendReply()
        do {
            try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("lost relay reply")
        } catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        let first = await h.relay.appends.last, confirmations = h.ownerRequests.count
        XCTAssertEqual(try coordinator!.pendingServiceRemovalID(), record.id)
        coordinator = nil; coordinator = try h.coordinator()
        try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
        let retry = await h.relay.appends.last
        XCTAssertEqual(first, retry)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertNil(try coordinator!.pendingServiceRemovalID())
        let log = try await coordinator!.serviceMembership()
        XCTAssertEqual(log.member(deviceId: "service-test")?.status, .removed)
    }

    func testRemovalAccountChangeOrDeclinedOwnerSendsNoEntry() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let count = await h.relay.appends.count
        var current = true
        h.ownerConfirmation = { _ in current = false; return true }
        do {
            try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { current })
            XCTFail("stale account")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        current = true; h.ownerConfirmation = { _ in false }
        do {
            try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { current })
            XCTFail("declined owner")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        let after = await h.relay.appends.count
        XCTAssertEqual(after, count)
    }

    func testRemovalRejectsActiveGrantAndChangedFingerprint() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        await transport.revoke(fingerprint: String(repeating: "f", count: 64))
        let count = h.ownerRequests.count
        do {
            try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("changed key")
        } catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        let records = try await portal(transport).owned(stationOrigin: "https://configured.example")
        let log = try await coordinator.serviceMembership()
        XCTAssertNil(try AstationRecoveryCoordinator.removableService(record: XCTUnwrap(records.first), log: log))
        await transport.setState("provisioning")
        let activeRecords = try await portal(transport).owned(stationOrigin: "https://configured.example")
        do {
            try await coordinator.removeRevokedService(XCTUnwrap(activeRecords.first), ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("an active grant needs Portal revocation first")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, count)
    }

    func testRemovalUncertainPreparedCheckpointCannotSendUntilReloaded() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let record = try await revokedService(coordinator!, transport: transport)
        let count = await h.relay.appends.count
        h.store.failOnRemoval = true
        do {
            try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("uncertain durable store")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        let after = await h.relay.appends.count
        XCTAssertEqual(after, count)
        XCTAssertThrowsError(try coordinator!.pendingServiceRemovalID())
        coordinator = nil; coordinator = try h.coordinator()
        try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
        let log = try await coordinator!.serviceMembership()
        XCTAssertEqual(log.member(deviceId: "service-test")?.status, .removed)
    }

    func testRemovalCompetingHeadRetainsEvidenceAndRequiresFreshConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let manager = try await addSecondManager(harness: h)
        h.ownerConfirmation = { _ in
            try await self.append(["action": "add_host", "host": ["host_id": "other-host", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]],
                harness: h, signer: "manager-b", identity: manager)
            return true
        }
        do {
            try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("head changed during confirmation")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertNil(try coordinator.pendingServiceRemovalID())
        XCTAssertEqual((try checkpoint(h.store)["supersededServiceRemovals"] as? [Data])?.count, 1)
        let confirmations = h.ownerRequests.count
        h.ownerConfirmation = nil
        try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
    }

    func testRemovalAcceptedBeforeUncertainCommitResumesWithoutAnotherAppend() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        let record = try await revokedService(coordinator!, transport: transport)
        let before = try await coordinator!.serviceMembership()
        h.store.failAtEntryCount = Int(before.head().seq + 1)
        do {
            try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("uncertain committed checkpoint")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        let count = await h.relay.appends.count, confirmations = h.ownerRequests.count
        coordinator = nil; coordinator = try h.coordinator()
        try await coordinator!.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
        let after = await h.relay.appends.count
        XCTAssertEqual(after, count)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertNil(try coordinator!.pendingServiceRemovalID())
    }

    func testRemovalManagerRevokedDuringConfirmationCannotSignOrSend() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let manager = try await addSecondManager(harness: h)
        h.ownerConfirmation = { _ in
            try await self.append(["action": "remove", "device_id": "manager-a"], harness: h,
                signer: "manager-b", identity: manager)
            return true
        }
        do {
            try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345", portal: portal(transport), current: { true })
            XCTFail("removed manager")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        let log = await h.relay.log
        XCTAssertEqual(log?.member(deviceId: "manager-a")?.status, .removed)
        XCTAssertEqual(log?.member(deviceId: "service-test")?.status, .active)
        h.ownerConfirmation = nil
    }

    func testServiceApprovalResumesAfterLostPortalReplyWithoutResigningOrReposting() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator()
        _ = try await coordinator!.setup()
        let approval = try await service(coordinator!)
        try await coordinator!.prepareService(approval)
        let transport = ServiceApprovalPortal()
        await transport.dropNextReply()
        do { try await coordinator!.approveService(approval, portal: portal(transport), current: { true }); XCTFail("reply should be lost") }
        catch { XCTAssertEqual(error as? AccountLoginError, .unavailable) }
        XCTAssertEqual(try coordinator!.pendingServiceApproval(), approval)
        let confirmations = h.ownerRequests.count
        coordinator = nil
        coordinator = try h.coordinator()
        try await coordinator!.approveService(approval, portal: portal(transport), current: { true })
        XCTAssertNil(try coordinator!.pendingServiceApproval())
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let count = await transport.count(); XCTAssertEqual(count, 1)
        let remote = await h.relay.log
        XCTAssertEqual(remote?.member(deviceId: "service-test")?.roles, ["service"])
    }

    func testServiceApprovalAccountChangeDuringConfirmationSendsNoEntryOrPortalRequest() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let coordinator = try h.coordinator(); _ = try await coordinator.setup()
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        var current = true
        h.ownerConfirmation = { _ in current = false; return true }
        do { try await coordinator.approveService(approval, portal: portal(transport), current: { current }); XCTFail("account changed") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        let remote = await h.relay.log, count = await transport.count()
        XCTAssertNil(remote?.member(deviceId: "service-test")); XCTAssertEqual(count, 0)
    }

    func testServiceApprovalLostRelayReplyRetriesItsDurablySavedSignature() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(); _ = try await coordinator!.setup()
        let approval = try await service(coordinator!)
        try await coordinator!.prepareService(approval)
        await h.relay.dropNextAppendReply()
        do { try await coordinator!.approveService(approval, portal: portal(transport), current: { true }); XCTFail("lost relay reply") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        let first = await h.relay.appends.last, confirmations = h.ownerRequests.count
        coordinator = nil; coordinator = try h.coordinator()
        XCTAssertThrowsError(try coordinator!.cancelUnsignedService(approval), "a signed retry must survive a new process")
        XCTAssertEqual(try coordinator!.pendingServiceApproval(), approval)
        try await coordinator!.approveService(approval, portal: portal(transport), current: { true })
        let retry = await h.relay.appends.last
        XCTAssertEqual(first, retry); XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertNil(try coordinator!.pendingServiceApproval())
    }

    func testServiceReviewCanBeReplacedOnlyAfterAnAnchoredHeadSupersedesIt() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(); _ = try await coordinator.setup()
        let otherManager = try await addSecondManager(harness: h)
        let approval = try await service(coordinator)
        try await coordinator.prepareService(approval)
        do { try await coordinator.reviewServiceAgain(approval); XCTFail("unresolved draft must remain") } catch {}
        try await append(["action": "add_host", "host": ["host_id": "other-host", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]],
            harness: h, signer: "manager-b", identity: otherManager)
        try await coordinator.reviewServiceAgain(approval)
        XCTAssertNil(try coordinator.pendingServiceApproval())
        XCTAssertEqual((try checkpoint(h.store)["supersededServiceReviews"] as? [Data])?.count, 1)
    }
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
        signer: String = "manager-a", identity: AtemE2EIdentity? = nil,
        authorizeNewMembership: ((SignRequest) throws -> Void)? = nil) async throws {
        let stored = await h.relay.log
        let log = try XCTUnwrap(stored)
        let publisher = RemoteMembershipPublication(log: log, persist: { _ in })
        _ = try publisher.prepare(actionJSON: recoveryTestJSON(action), signer: signer, signedAt: AstationRecoveryCoordinator.clock().wallMs)
        let identity = identity ?? h.identity
        let provider = AstationMembershipKeyProvider(identity: identity, keyID: signer, publicKey: try identity.remotePublicKeys().signing,
            authorizeNewMembership: authorizeNewMembership)
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

    func testDelegatedControlsStayOffByDefaultBeforeAnySignatureOrDelivery() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let before = h.ownerRequests.count
        XCTAssertFalse(coordinator.delegatedControlsAvailable)
        do {
            _ = try await coordinator.prepareServiceControl(record, portal: portal(transport), interruptOnly: false,
                interruptRunning: false, current: { true })
            XCTFail("production gate was bypassed")
        } catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        let controls = await h.relay.controls()
        XCTAssertTrue(controls.isEmpty)
        XCTAssertEqual(h.ownerRequests.count, before)
    }

    private func recoveryCopySource(_ h: RecoveryCoordinatorHarness, authority: RecoveryCopyAuthority,
        checkpointStore: AstationRecoveryCheckpointStorage? = nil) async throws
        -> (AstationRecoveryCoordinator, RemoteControlRecoveryContext, String) {
        let coordinator = try h.coordinator(checkpointStore: checkpointStore,
            authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
        let portalTransport = ServiceApprovalPortal()
        let record = try await activeService(coordinator, transport: portalTransport)
        let client = try portal(portalTransport)
        let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        let result = try await coordinator.commitServiceControl(review, portal: client, current: { true })
        let retainedLog = await h.relay.log
        let log = try XCTUnwrap(retainedLog)
        let context = try RemoteControlRecoveryContext(accountID: log.accountId(), genesisHash: log.genesisHash(),
            stationOrigin: "https://configured.example", generation: 2, planID: UUID().uuidString.lowercased(),
            sourceHash: String(repeating: "a", count: 64), evidenceHash: String(repeating: "b", count: 64),
            candidateFeedID: UUID().uuidString.lowercased(), membershipHead: log.head())
        authority.context = context; authority.original = result.recordJSON
        return (coordinator, context, review.recordID)
    }

    func testNativeSignerReportRequiresConsentAndRecoversExactReceiptAfterRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        let (_, context, _) = try await recoveryCopySource(h, authority: RecoveryCopyAuthority())
        let savedLog = await h.relay.log
        let log = try XCTUnwrap(savedLog)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryReportHTTPStub.self]
        let http = try RemoteRecoveryHTTP(relayURL: context.stationOrigin, configuration: config, accessToken: { "native-test" })
        let rosterOwner = try h.coordinator(confirmProcessRoster: { true })
        XCTAssertEqual(try rosterOwner.localSignerReportSlot(context), "astation-macos")
        let review = try await rosterOwner.prepareProcessReview(member: "manager-a", current: { true })
        try await rosterOwner.acceptProcessReview(review, lines: ["offline AQEBAQEBAQEBAQEBAQEBAQ",
            "truck " + verifierReportProcess()], current: { true })
        XCTAssertEqual(try rosterOwner.localSignerReportSlot(context), "truck")
        let wall = AstationRecoveryCoordinator.clock().wallMs
        let challenge = try signerReportChallenge(signer: "member:manager-a", slot: "truck", origin: context.stationOrigin,
            connection: 1, issuedAt: wall, expiresAt: wall + 30_000, recovery: context.signerReportRecovery)
        var deliveries: [Data] = []
        RecoveryReportHTTPStub.lock.withLock {
            RecoveryReportHTTPStub.response = { request, data in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-test")
                switch request.url?.lastPathComponent {
                case "entries":
                    return try JSONSerialization.data(withJSONObject: ["head": ["seq": log.head().seq, "hash": log.head().hash] as [String: Any],
                        "entries": [], "more": false] as [String: Any])
                case "signer-challenges":
                    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(fields["slot"] as? String, "truck")
                    return Data(challenge.utf8)
                case "signer-reports":
                    deliveries.append(data)
                    let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    func json(_ value: Any) throws -> String {
                        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                    }
                    let records = try XCTUnwrap(input["records"] as? [Any]).map(json)
                    let checked = try verifySignerReport(log: log, reportJson: json(XCTUnwrap(input["report"])),
                        expectedChallengeJson: challenge, exportedRecordsJson: records, nowMs: wall)
                    XCTAssertTrue(checked.atHead)
                    XCTAssertEqual(checked.slot, "truck")
                    XCTAssertEqual(checked.process, verifierReportProcess())
                    XCTAssertEqual(checked.journal.records, 1)
                    if deliveries.count == 1 { throw URLError(.networkConnectionLost) }
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return try JSONSerialization.data(withJSONObject: ["plan_id": context.planID,
                        "retained_only": true, "submission_hash": deliveries.count == 2 ? "wrong" : hash] as [String: Any])
                default: XCTFail("unexpected Station path"); throw URLError(.badURL)
                }
            }
        }
        defer { RecoveryReportHTTPStub.lock.withLock { RecoveryReportHTTPStub.response = nil } }
        let coordinator = try h.coordinator(transport: http, authorizeDelegatedControl: { _ in })
        let preview = try coordinator.localControlAuthorInventory(stationOrigin: context.stationOrigin, current: { true })
        weak var openJournal: RemoteControlSigningJournal?
        h.protectedJournal = { log, id in
            XCTAssertNil(openJournal, "A second operation must be able to acquire the key lock")
            let journal = try RemoteControlSigningJournal(log: log, memberID: id,
                read: { h.authorBytes[id] }, persist: { h.authorBytes[id] = $0 })
            openJournal = journal
            return journal
        }
        h.ownerConfirmation = { _ in
            XCTAssertNil(openJournal, "Only the durable hold should survive while waiting for the owner")
            return h.approve
        }
        defer { h.protectedJournal = nil; h.ownerConfirmation = nil }
        let prompts = h.ownerRequests.count
        do { try await coordinator.submitSignerReport(context, slot: "astation-macos", preview: preview, current: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertNoThrow(try coordinator.requireServiceStopChange(origin: context.stationOrigin))
        h.approve = false
        do { try await coordinator.submitSignerReport(context, slot: "truck", preview: preview, current: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        XCTAssertEqual(h.ownerRequests.last?.purpose, .signerReport)
        XCTAssertThrowsError(try coordinator.requireServiceStopChange(origin: context.stationOrigin)) {
            XCTAssertTrue($0 is RemoteControlRecoveryHold)
        }
        XCTAssertTrue(deliveries.isEmpty)
        h.approve = true
        do { try await coordinator.submitSignerReport(context, slot: "truck", preview: preview, current: { true }); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let count = h.ownerRequests.count
        let reopened = try h.coordinator(transport: http)
        do { _ = try await reopened.retrySignerReport(context, current: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse) }
        let ok = try await reopened.retrySignerReport(context, current: { true })
        XCTAssertTrue(ok)
        XCTAssertEqual(deliveries.count, 3)
        XCTAssertEqual(Set(deliveries).count, 1)
        XCTAssertEqual(h.ownerRequests.count, count)
        XCTAssertThrowsError(try reopened.requireServiceStopChange(origin: context.stationOrigin))
    }

    private func preparedRecoverySource(_ h: RecoveryCoordinatorHarness) async throws
        -> (AstationRecoveryCoordinator, RemoteControlRecoveryPreparation) {
        let coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let retained = await h.relay.log
        let log = try XCTUnwrap(retained)
        let context = try RemoteControlRecoveryContext(accountID: log.accountId(), genesisHash: log.genesisHash(),
            stationOrigin: "https://configured.example", generation: 2, planID: UUID().uuidString.lowercased(),
            sourceHash: String(repeating: "a", count: 64), evidenceHash: String(repeating: "b", count: 64),
            candidateFeedID: UUID().uuidString.lowercased(), membershipHead: log.head())
        let preparation = RemoteControlRecoveryPreparation(context: context, reconstructionHash: String(repeating: "c", count: 64))
        await h.relay.setRecoveryReview(preparation)
        return (coordinator, preparation)
    }

    func testPreparedRecoveryAcquisitionNeverInstallsAuthorityOrChangesProtectedState() async throws {
        let h = RecoveryCoordinatorHarness(), (coordinator, preparation) = try await preparedRecoverySource(h)
        let writes = h.store.writes, checkpoint = h.store.bytes, prompts = h.ownerRequests.count
        let value = try await coordinator.loadControlRecoveryPreparation(stationOrigin: preparation.context.stationOrigin, current: { true })
        XCTAssertEqual(value, preparation)
        XCTAssertFalse(coordinator.controlRecoveryAvailable)
        XCTAssertFalse(coordinator.delegatedControlsAvailable)
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(h.store.bytes, checkpoint)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        let copies = try coordinator.localControlRecoveryReviews(current: { true })
        XCTAssertTrue(copies.isEmpty)
    }

    func testPreparedRecoveryAcquisitionRefusesDelayedAccountAndProtectedCheckpointChanges() async throws {
        for changeProtectedState in [false, true] {
            let h = RecoveryCoordinatorHarness(), (coordinator, preparation) = try await preparedRecoverySource(h)
            let checkpoint = h.store.bytes, writes = h.store.writes
            var current = true
            await h.relay.holdNextRecoveryReview()
            let load = Task { try await coordinator.loadControlRecoveryPreparation(stationOrigin: preparation.context.stationOrigin, current: { current }) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await h.relay.recoveryReviewIsWaiting()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let waiting = await h.relay.recoveryReviewIsWaiting()
            XCTAssertTrue(waiting)
            if changeProtectedState { h.store.readFailure = true } else { current = false }
            await h.relay.releaseRecoveryReview()
            do { _ = try await load.value; XCTFail("a retired review was accepted") } catch {}
            XCTAssertEqual(h.store.bytes, checkpoint)
            XCTAssertEqual(h.store.writes, writes)
            XCTAssertFalse(coordinator.controlRecoveryAvailable)
        }
    }

    func testPreparedRecoveryWindowLoadsExactPlanWithSigningDisabled() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), (coordinator, preparation) = try await preparedRecoverySource(h)
        let prompts = h.ownerRequests.count, writes = h.store.writes
        let controller = ControlRecoveryWindowController(stationOrigin: preparation.context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        })
        showRecovery(controller)
        defer { controller.close() }
        let load = try recoveryButton("Load Station Review", window: controller.window)
        try clickRecovery(load)
        try await waitForRecoveryUI { load.isEnabled }
        XCTAssertFalse(try recoveryButton("Confirm Copy...", window: controller.window).isEnabled)
        func containsPlan(_ view: NSView) -> Bool {
            if let text = view as? NSTextView, text.string.contains(preparation.context.planID) { return true }
            return view.subviews.contains(where: containsPlan)
        }
        XCTAssertTrue(try XCTUnwrap(controller.window?.contentView).subviews.contains(where: containsPlan))
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertFalse(coordinator.controlRecoveryAvailable)
    }

    func testPreparedRecoveryWindowDiscardsAReplyAfterClosing() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), (coordinator, preparation) = try await preparedRecoverySource(h)
        let writes = h.store.writes
        let controller = ControlRecoveryWindowController(stationOrigin: preparation.context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        })
        await h.relay.holdNextRecoveryReview()
        showRecovery(controller)
        try clickRecovery(try recoveryButton("Load Station Review", window: controller.window))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await h.relay.recoveryReviewIsWaiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let refresh = try recoveryButton("Refresh", window: controller.window)
        controller.close()
        await h.relay.releaseRecoveryReview()
        try await waitForRecoveryUI { refresh.isEnabled }
        XCTAssertFalse(try recoveryButton("Confirm Copy...", window: controller.window).isEnabled)
        XCTAssertEqual(h.store.writes, writes)
    }

    func testRealProtectedRecoveryCopySurvivesStoreAndEnclaveIdentityReload() async throws {
        // Authority/owner answers are synthetic; storage and P-256 signing use the real protected implementations.
        let optional = ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] != "1"
        guard SecureEnclave.isAvailable else {
            if optional { throw XCTSkip("Secure Enclave unavailable") }
            throw AtemIdentityError.secureEnclaveUnavailable
        }
        let name = "atem-recovery-copy-test-" + UUID().uuidString
        let identityStorage = AtemIdentityKeychainStorage(astationId: name)
        var queries: [[String: Any]] = [
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "build.agora.astation.atem-e2e-v1", kSecAttrAccount as String: name,
             kSecUseDataProtectionKeychain as String: true],
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "build.agora.astation.recovery-v2", kSecAttrAccount as String: "account:" + name,
             kSecUseDataProtectionKeychain as String: true]
        ]
        defer {
            for query in queries {
                let status = SecItemDelete(query as CFDictionary)
                if !optional {
                    XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound,
                        "Required protected test cleanup failed: \(status)")
                }
            }
        }
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        var journalScope: String?
        h.protectedJournal = { log, member in
            let journal = try RemoteControlSigningJournal(log: log, memberID: member)
            if journalScope == nil {
                journalScope = journal.storageScope
                queries.append([kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "build.agora.astation.recovery-v2",
                    kSecAttrAccount as String: "control-author:" + journal.storageScope,
                    kSecUseDataProtectionKeychain as String: true])
            }
            XCTAssertEqual(journal.storageScope, journalScope)
            XCTAssertThrowsError(try RemoteControlSigningJournal(log: log, memberID: member)) { error in
                guard case RemoteRecoveryStoreError.locked = error else { return XCTFail("Expected key lock, got " + String(describing: error)) }
            }
            return journal
        }
        h.identity = AtemE2EIdentity(storage: identityStorage)
        var store: RemoteRecoveryStore?
        var coordinator: AstationRecoveryCoordinator?
        let context: RemoteControlRecoveryContext, original: String
        do {
            store = try RemoteRecoveryStore(accountID: name)
            (coordinator, context, original) = try await recoveryCopySource(h, authority: authority, checkpointStore: store)
        } catch {
            let status: OSStatus?
            switch error {
            case AtemIdentityError.keychain(let code), RemoteRecoveryStoreError.keychain(let code): status = code
            default:
                let ns = error as NSError
                status = ns.domain == NSOSStatusErrorDomain ? OSStatus(ns.code) : nil
            }
            if optional, let status, [errSecMissingEntitlement, errSecInteractionNotAllowed].contains(status) {
                throw XCTSkip("Provisioned signing and an unlocked Mac are required")
            }
            throw error
        }
        let review = try await coordinator!.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let prompts = h.ownerRequests.count
        let exported = try await coordinator!.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertEqual(authority.reservations, 1)
        let data = try XCTUnwrap(store?.read())
        let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(fields["version"] as? Int, 6)
        XCTAssertFalse(try XCTUnwrap(fields["controlRecoveryPublications"] as? [String: Data]).isEmpty)
        let retainedLog = await h.relay.log
        let log = try XCTUnwrap(retainedLog)
        XCTAssertEqual(log.member(deviceId: "manager-a")?.authKey.alg, .p256)

        coordinator = nil
        store = nil
        h.identity = AtemE2EIdentity(storage: identityStorage)
        store = try RemoteRecoveryStore(accountID: name)
        XCTAssertEqual(try store?.read(), data, "A newly opened protected store must retain the complete signed checkpoint")
        coordinator = try h.coordinator(checkpointStore: store)
        let local = try coordinator!.localControlAuthorInventory(stationOrigin: context.stationOrigin, current: { true })
        XCTAssertEqual(local.signedRecords.count, 2)
        XCTAssertTrue(local.unsignedDraftBodies.isEmpty)
        XCTAssertTrue(local.missingSignatureBodies.isEmpty)
        XCTAssertFalse(coordinator!.controlRecoveryAvailable)
        XCTAssertEqual(try coordinator!.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }), exported)
        coordinator = nil
        coordinator = try h.coordinator(checkpointStore: store,
            authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
        let retried = try await coordinator!.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(retried, exported)
        XCTAssertEqual(h.ownerRequests.count, prompts + 1, "Reloading saved signatures must not confirm or sign again")
        XCTAssertEqual(authority.reservations, 1)

        let outboxes = try XCTUnwrap(fields["controlPublications"] as? [String: Data]).map { origin, bytes in
            try RemoteControlPublication(checkpoint: bytes, accountID: context.accountID, genesisHash: context.genesisHash,
                stationOrigin: origin, persist: { _ in XCTFail("collecting a report cannot change a stop") })
        }
        let copies = try XCTUnwrap(fields["controlRecoveryPublications"] as? [String: Data]).map { origin, bytes in
            try RemoteControlRecoveryPublication(checkpoint: bytes, accountID: context.accountID, genesisHash: context.genesisHash,
                stationOrigin: origin, persist: { _ in XCTFail("collecting a report cannot change a copy") })
        }
        let challenge = try signerReportChallenge(signer: "member:manager-a", slot: "astation-macos",
            origin: context.stationOrigin, connection: 1, issuedAt: 100, expiresAt: 30_100,
            recovery: context.signerReportRecovery)
        do {
            let journal = try RemoteControlSigningJournal(log: log, memberID: "manager-a")
            let request = try journal.holdForReport(context: context, challengeJSON: challenge, log: log,
                slot: "astation-macos", nowMs: 100, outboxes: outboxes, recoveryCopies: copies)
            XCTAssertEqual(request.purpose, .signerReport)
        }
        // Reopen both protected stores. A saved signature can still be delivered.
        coordinator = nil
        store = nil
        store = try RemoteRecoveryStore(accountID: name)
        coordinator = try h.coordinator(checkpointStore: store,
            authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
        XCTAssertThrowsError(try coordinator!.requireControlChange(review.request)) {
            XCTAssertEqual(($0 as? RemoteControlRecoveryHold)?.context, context)
        }
        let retained = try await coordinator!.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(retained, exported)
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
    }

    func testLocalAuthorInventoryReadsAllRetainedOriginsOfflineWithoutChangingIntent() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let draft = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let other = "https://another.example"
        let offline = try h.coordinator(relayURL: other)
        let saved = h.store.bytes, author = h.authorBytes, prompts = h.ownerRequests.count
        XCTAssertFalse(offline.controlRecoveryAvailable)
        let view = try offline.localControlAuthorInventory(stationOrigin: context.stationOrigin, current: { true })
        XCTAssertEqual(view.signedRecords, [try XCTUnwrap(authority.original)])
        XCTAssertEqual(view.unsignedDraftBodies, [try XCTUnwrap(draft.request.bodyJson)])
        XCTAssertTrue(view.missingSignatureBodies.isEmpty)
        let unrelated = try offline.localControlAuthorInventory(stationOrigin: other, current: { true })
        XCTAssertTrue(unrelated.signedRecords.isEmpty)
        XCTAssertTrue(unrelated.unsignedDraftBodies.isEmpty)
        XCTAssertEqual(h.store.bytes, saved)
        XCTAssertEqual(h.authorBytes, author)
        XCTAssertEqual(h.ownerRequests.count, prompts)

        var root = try checkpoint(h.store)
        var outboxes = try XCTUnwrap(root["controlPublications"] as? [String: Data])
        outboxes[other] = Data([0xff])
        root["controlPublications"] = outboxes
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let damaged = try h.coordinator()
        XCTAssertThrowsError(try damaged.localControlAuthorInventory(stationOrigin: context.stationOrigin, current: { true }),
            "An unreadable origin may contain an originless host interrupt")
        XCTAssertThrowsError(try offline.localControlAuthorInventory(stationOrigin: context.stationOrigin, current: { true }),
            "An older coordinator cannot return cached evidence after a protected checkpoint changes")
    }

    func testMissingOrReplacedAuthorJournalBlocksRecoveryCopyWithNoKeyUse() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let retained = try XCTUnwrap(h.authorBytes["manager-a"])
        let signs = h.identityCryptography.signingCalls
        let log = await h.relay.log
        h.authorBytes.removeAll()
        for missing in [true, false] {
            if !missing {
                let replacement = try RemoteControlSigningJournal(log: XCTUnwrap(log), memberID: "manager-a",
                    read: { h.authorBytes["manager-a"] }, persist: { h.authorBytes["manager-a"] = $0 })
                try replacement.establish()
            }
            let reopened = try h.coordinator(authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
            do {
                _ = try await reopened.signControlRecoveryCopy(review, current: { true })
                XCTFail("A fresh journal must not replace an established signing history")
            } catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
            XCTAssertEqual(h.identityCryptography.signingCalls, signs)
        }
        h.authorBytes["manager-a"] = retained
        let reopened = try h.coordinator(authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
        _ = try await reopened.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(h.identityCryptography.signingCalls, signs + 1)
    }

    func testRecoveryCopiesUseProtectedCheckpointAndOwnerConfirmationWithoutOrdinaryDelivery() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        var (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let beforeExport = try coordinator.exportControlRecoveryEvidence(current: { true })
        let beforeControls = await h.relay.controls(), prompts = h.ownerRequests.count
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        XCTAssertEqual(authority.reservations, 1)
        XCTAssertEqual(h.ownerRequests.count, prompts, "preparing a draft is not owner confirmation")
        let copy = try await coordinator.signControlRecoveryCopy(review, current: { true })
        let savedCheckpoint = try XCTUnwrap(h.store.bytes)
        var savedFields = try XCTUnwrap(PropertyListSerialization.propertyList(from: savedCheckpoint, format: nil) as? [String: Any])
        XCTAssertEqual(savedFields["version"] as? Int, 6)
        savedFields["version"] = 3
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: savedFields, format: .binary, options: 0)
        XCTAssertThrowsError(try h.coordinator(), "a downgraded checkpoint must not hide retained recovery clocks")
        h.store.bytes = savedCheckpoint
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertEqual(h.ownerRequests.last, review.request)
        XCTAssertEqual(try coordinator.exportControlRecoveryEvidence(current: { true }), beforeExport)
        let afterControls = await h.relay.controls()
        XCTAssertEqual(afterControls, beforeControls, "recovery signatures never enter the ordinary feed")
        coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, controlRecoveryAuthority: authority)
        let retried = try await coordinator.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(retried, copy)
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertEqual(authority.reservations, 1)
        let offline = try h.coordinator()
        XCTAssertFalse(offline.controlRecoveryAvailable)
        XCTAssertEqual(try offline.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }), copy)
        XCTAssertEqual(try offline.exportControlRecoveryEvidence(current: { true }), beforeExport)
    }

    private func signedRecoverySource(_ h: RecoveryCoordinatorHarness) async throws -> (AstationRecoveryCoordinator, RemoteControlRecoveryReview) {
        let authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let draft = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        _ = try await coordinator.signControlRecoveryCopy(draft, current: { true })
        let signed = try XCTUnwrap(coordinator.localControlRecoveryReviews(current: { true }).first)
        await h.relay.setRecoveryReview(RemoteControlRecoveryPreparation(context: context, reconstructionHash: String(repeating: "c", count: 64)))
        return (try h.coordinator(), signed)
    }

    func testRecoveryCopyRetentionRetriesExactSignatureAfterLostReplyAndRestartWithoutNewAuthority() async throws {
        let h = RecoveryCoordinatorHarness()
        var (coordinator, signed) = try await signedRecoverySource(h)
        let checkpoint = h.store.bytes, writes = h.store.writes, prompts = h.ownerRequests.count
        let controls = await h.relay.controls()
        XCTAssertFalse(coordinator.controlRecoveryAvailable)
        await h.relay.loseNextRecoveryCopyReply()
        do { _ = try await coordinator.retainControlRecoveryCopy(signed, current: { true }); XCTFail() } catch {}
        XCTAssertEqual(h.store.writes, writes)
        coordinator = try h.coordinator()
        let reloadedWrites = h.store.writes
        let receipt = try await coordinator.retainControlRecoveryCopy(signed, current: { true })
        XCTAssertEqual(receipt.recordIDs, [signed.body.recordId])
        let copies = await h.relay.sentRecoveryCopies()
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies[0], copies[1])
        XCTAssertEqual(h.store.bytes, checkpoint)
        XCTAssertEqual(h.store.writes, reloadedWrites)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        let after = await h.relay.controls()
        XCTAssertEqual(after, controls)
    }

    func testRecoveryCopyRetentionRejectsChangedContextOrProtectedStoreBeforeSending() async throws {
        for missingStore in [false, true] {
            let h = RecoveryCoordinatorHarness(), (coordinator, signed) = try await signedRecoverySource(h)
            let writes = h.store.writes
            var current = true
            await h.relay.holdNextRecoveryReview()
            let operation = Task { try await coordinator.retainControlRecoveryCopy(signed, current: { current }) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await h.relay.recoveryReviewIsWaiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let waiting = await h.relay.recoveryReviewIsWaiting()
            XCTAssertTrue(waiting)
            if missingStore { h.store.bytes = nil } else { current = false }
            await h.relay.releaseRecoveryReview()
            do { _ = try await operation.value; XCTFail() } catch {}
            let copies = await h.relay.sentRecoveryCopies()
            XCTAssertTrue(copies.isEmpty)
            XCTAssertEqual(h.store.writes, writes)
            if missingStore { XCTAssertNil(h.store.bytes) }
        }
    }

    func testRecoveryCopyRetentionDiscardsALateReceiptAndKeepsTheProtectedSignature() async throws {
        let h = RecoveryCoordinatorHarness(), (coordinator, signed) = try await signedRecoverySource(h)
        let checkpoint = h.store.bytes, writes = h.store.writes
        var current = true
        await h.relay.holdNextRecoveryCopy()
        let operation = Task { try await coordinator.retainControlRecoveryCopy(signed, current: { current }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await h.relay.recoveryCopyIsWaiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await h.relay.recoveryCopyIsWaiting()
        XCTAssertTrue(waiting)
        current = false
        await h.relay.releaseRecoveryCopy()
        do { _ = try await operation.value; XCTFail() } catch {}
        XCTAssertEqual(h.store.bytes, checkpoint)
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(try coordinator.localControlRecoveryReviews(current: { true }), [signed])
    }

    func testRecoveryCopyWindowSendsSavedSignatureWithSigningDisabled() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), (coordinator, signed) = try await signedRecoverySource(h)
        let prompts = h.ownerRequests.count
        let controller = ControlRecoveryWindowController(stationOrigin: signed.context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        })
        showRecovery(controller); defer { controller.close() }
        XCTAssertFalse(try recoveryButton("Confirm Copy...", window: controller.window).isEnabled)
        let send = try recoveryButton("Send to Station", window: controller.window)
        XCTAssertTrue(send.isEnabled)
        try clickRecovery(send)
        try await waitForRecoveryUI { send.isEnabled }
        let copies = await h.relay.sentRecoveryCopies()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertFalse(coordinator.controlRecoveryAvailable)
    }

    func testRecoveryCopyDefaultGateDenialAndChangedAccountPreventSigning() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let production = try h.coordinator(authorizeDelegatedControl: { _ in })
        XCTAssertFalse(production.controlRecoveryAvailable)
        let prompts = h.ownerRequests.count
        do { _ = try await production.prepareControlRecoveryCopy(recordID: original, context: context, current: { true }); XCTFail() }
        catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        XCTAssertEqual(authority.reservations, 0)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        h.approve = false
        do { _ = try await coordinator.signControlRecoveryCopy(review, current: { true }); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        h.approve = true
        do { _ = try await coordinator.signControlRecoveryCopy(review, current: { false }); XCTFail() }
        catch {}
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertThrowsError(try coordinator.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }))
    }

    func testRecoveryCopyChecksAuthorityAgainAfterOwnerConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        h.ownerConfirmation = { _ in authority.complete = false; return true }
        do { _ = try await coordinator.signControlRecoveryCopy(review, current: { true }); XCTFail() }
        catch {}
        XCTAssertThrowsError(try coordinator.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }))
        authority.complete = true
        h.ownerConfirmation = nil
        let copy = try await coordinator.signControlRecoveryCopy(review, current: { true })
        let resumed = try h.coordinator()
        h.store.bytes = nil
        XCTAssertThrowsError(try resumed.exportControlRecoveryCopies(context: context, recordIDs: [review.body.recordId], current: { true }))
        XCTAssertFalse(copy.isEmpty)
    }

    func testRecoveryCopyReservationReplyCannotCrossMembershipChange() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        authority.afterReserve = {
            try await self.append(["action": "set_roles", "device_id": "manager-a", "roles": ["control", "manage", "view"]], harness: h)
        }
        let prompts = h.ownerRequests.count
        do { _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true }); XCTFail() }
        catch {}
        XCTAssertEqual(h.ownerRequests.count, prompts)
        let state = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(h.store.bytes), format: nil) as? [String: Any])
        XCTAssertNil(state["controlRecoveryPublications"])
    }

    func testServiceRemovalNeverLowersRecoveryCheckpointVersion() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let initial = try h.coordinator()
        let record = try await revokedService(initial, transport: transport)
        var saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(h.store.bytes), format: nil) as? [String: Any])
        saved["version"] = 4
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        let coordinator = try h.coordinator()
        try await coordinator.removeRevokedService(record, ownerAccount: "ab01234567890123456789012345",
            portal: portal(transport), current: { true })
        saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(h.store.bytes), format: nil) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 4)
        let log = try await coordinator.serviceMembership()
        XCTAssertEqual(log.member(deviceId: "service-test")?.status, .removed)
    }

    func testRecoveryCopyUnknownOriginExportsNeverConsumeRetainedJournalCapacity() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let checkpoint = h.store.bytes, writes = h.store.writes, prompts = h.ownerRequests.count
        for index in 0..<80 {
            let unknown = try RemoteControlRecoveryContext(accountID: context.accountID, genesisHash: context.genesisHash,
                stationOrigin: "https://unknown-\(index).example", generation: context.generation,
                planID: context.planID, sourceHash: context.sourceHash, evidenceHash: context.evidenceHash,
                candidateFeedID: context.candidateFeedID, membershipHead: context.membershipHead)
            XCTAssertThrowsError(try coordinator.exportControlRecoveryCopies(context: unknown,
                recordIDs: [original], current: { true }))
            XCTAssertTrue(try coordinator.localControlRecoveryReviews(stationOrigin: unknown.stationOrigin,
                current: { true }).isEmpty)
        }
        XCTAssertEqual(h.store.bytes, checkpoint)
        XCTAssertEqual(h.store.writes, writes)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertEqual(authority.reservations, 0)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let copy = try await coordinator.signControlRecoveryCopy(review, current: { true })
        XCTAssertEqual(try coordinator.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }), copy)
        let elsewhere = try h.coordinator(relayURL: "https://other-selected.example")
        XCTAssertEqual(try elsewhere.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true }), copy,
            "retained evidence does not require selecting or contacting its original Station")
    }

    func testLegacyCheckpointWithoutRecoveryJournalNeverEstablishesSigningAuthority() async throws {
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        var checkpoint = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(h.store.bytes), format: nil) as? [String: Any])
        checkpoint["version"] = 3
        checkpoint.removeValue(forKey: "controlRecoveryPublications")
        checkpoint.removeValue(forKey: "controlJournalIDs")
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: checkpoint, format: .binary, options: 0)
        let legacy = try h.coordinator(authorizeDelegatedControl: { _ in })
        let prompts = h.ownerRequests.count, reservations = authority.reservations
        XCTAssertFalse(legacy.controlRecoveryAvailable)
        do {
            _ = try await legacy.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
            XCTFail("a legacy/empty journal is not complete signing-clock evidence")
        } catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertEqual(authority.reservations, reservations)
    }

    private func recoveryButton(_ title: String, window: NSWindow?) throws -> NSButton {
        func search(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.compactMap(search).first
        }
        return try XCTUnwrap(window?.contentView.flatMap(search))
    }

    private func waitForRecoveryUI(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "recovery UI operation did not complete")
    }

    private func clickRecovery(_ button: NSButton) throws {
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }

    private func showRecovery(_ controller: ControlRecoveryWindowController) {
        // Headless AppKit animations can occupy all interactive worker threads.
        controller.window?.animationBehavior = .none
        controller.showWindow(nil)
    }

    func testRecoveryWindowPreparesFirstCopyThenConfirmsSeparatelyWithoutChangingOriginalDelivery() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        await h.relay.setRecoveryReview(.init(context: context, reconstructionHash: String(repeating: "c", count: 64)))
        let prompts = h.ownerRequests.count, beforeControls = await h.relay.controls()
        var shown: [RemoteControlRecoveryReview] = []
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        }, confirm: { shown.append($0); return true })
        showRecovery(controller)
        defer { controller.close() }
        let prepare = try recoveryButton("Prepare Copy...", window: controller.window)
        XCTAssertFalse(prepare.isEnabled, "a Station plan must be loaded first")
        let load = try recoveryButton("Load Station Review", window: controller.window)
        try clickRecovery(load)
        try await waitForRecoveryUI { prepare.isEnabled }
        try clickRecovery(prepare)
        let sign = try recoveryButton("Confirm Copy...", window: controller.window)
        try await waitForRecoveryUI { sign.isEnabled }
        let draft = try XCTUnwrap(coordinator.localControlRecoveryReviews(current: { true }).first)
        XCTAssertEqual(draft.originalRecordID, original)
        XCTAssertEqual(draft.context, context)
        XCTAssertFalse(draft.signed)
        XCTAssertEqual(authority.reservations, 1)
        XCTAssertEqual(h.ownerRequests.count, prompts, "preparation cannot confirm or sign")
        XCTAssertFalse(try recoveryButton("Save Signed Copy...", window: controller.window).isEnabled)
        try clickRecovery(prepare)
        try await waitForRecoveryUI { prepare.isEnabled }
        XCTAssertEqual(try coordinator.localControlRecoveryReviews(current: { true }), [draft])
        XCTAssertEqual(authority.reservations, 1, "exact preparation retry retains its reservation and draft")
        try clickRecovery(sign)
        try await waitForRecoveryUI { (try? self.recoveryButton("Save Signed Copy...", window: controller.window).isEnabled) == true }
        XCTAssertEqual(shown, [draft])
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        let controls = await h.relay.controls()
        XCTAssertEqual(controls, beforeControls)
        XCTAssertEqual(try coordinator.localControlRecoveryOriginals(stationOrigin: context.stationOrigin,
            current: { true }).map { $0.body.recordId }, [original])
    }

    func testRecoveryWindowCannotPrepareWithReadOnlyMetadataAndNoAuthority() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (_, context, original) = try await recoveryCopySource(h, authority: authority)
        await h.relay.setRecoveryReview(.init(context: context, reconstructionHash: String(repeating: "c", count: 64)))
        let coordinator = try h.coordinator(), prompts = h.ownerRequests.count, checkpoint = h.store.bytes
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        })
        showRecovery(controller)
        defer { controller.close() }
        XCTAssertEqual(try coordinator.localControlRecoveryOriginals(stationOrigin: context.stationOrigin,
            current: { true }).map { $0.body.recordId }, [original])
        let load = try recoveryButton("Load Station Review", window: controller.window)
        try clickRecovery(load)
        try await waitForRecoveryUI { load.isEnabled }
        let prepare = try recoveryButton("Prepare Copy...", window: controller.window)
        XCTAssertFalse(prepare.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(prepare.action), to: prepare.target, from: prepare))
        XCTAssertEqual(h.store.bytes, checkpoint)
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertEqual(authority.reservations, 0)
        XCTAssertTrue(try coordinator.localControlRecoveryReviews(current: { true }).isEmpty)
    }

    func testRecoveryWindowRetiresPreparationAfterClosingOrAccountChangeDuringReservation() async throws {
        _ = NSApplication.shared
        for closeWindow in [false, true] {
            let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
            let (coordinator, context, _) = try await recoveryCopySource(h, authority: authority)
            await h.relay.setRecoveryReview(.init(context: context, reconstructionHash: String(repeating: "c", count: 64)))
            let prompts = h.ownerRequests.count
            var live = true, answer: CheckedContinuation<Void, Never>?
            authority.afterReserve = { await withCheckedContinuation { answer = $0 } }
            let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
                .init(coordinator: coordinator, current: { live }, canSign: { true })
            })
            showRecovery(controller)
            defer { controller.close() }
            try clickRecovery(recoveryButton("Load Station Review", window: controller.window))
            let prepare = try recoveryButton("Prepare Copy...", window: controller.window)
            try await waitForRecoveryUI { prepare.isEnabled }
            try clickRecovery(prepare)
            try await waitForRecoveryUI { answer != nil }
            if closeWindow { controller.close() }
            else {
                live = false
                NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
            }
            answer?.resume()
            try await waitForRecoveryUI { (try? self.recoveryButton("Refresh", window: controller.window).isEnabled) == true }
            XCTAssertEqual(authority.reservations, 1, "the spent reservation must not create a draft in retired context")
            XCTAssertTrue(try coordinator.localControlRecoveryReviews(current: { true }).isEmpty)
            XCTAssertEqual(h.ownerRequests.count, prompts)
            XCTAssertFalse(try recoveryButton("Confirm Copy...", window: controller.window).isEnabled)
        }
    }

    func testRecoveryPreparationRechecksProtectedStoreBeforeReservationAndDraftPersistence() async throws {
        for beforeReservation in [false, true] {
            let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
            let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
            let prompts = h.ownerRequests.count, checkpoint = h.store.bytes
            if beforeReservation { h.store.bytes = nil }
            else { authority.afterReserve = { h.store.bytes = nil } }
            do {
                _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
                XCTFail("an unreadable protected journal must not prepare a recovery copy")
            } catch {}
            XCTAssertNil(h.store.bytes, "network membership refresh must not recreate the lost protected journal")
            h.store.bytes = checkpoint
            XCTAssertEqual(authority.reservations, beforeReservation ? 0 : 1)
            XCTAssertEqual(h.ownerRequests.count, prompts)
            let restarted = try h.coordinator()
            XCTAssertTrue(try restarted.localControlRecoveryReviews(current: { true }).isEmpty)
            XCTAssertEqual(try restarted.localControlRecoveryOriginals(stationOrigin: context.stationOrigin,
                current: { true }).map { $0.body.recordId }, [original])
        }
    }

    func testRecoveryConfirmationNeverRecreatesAProtectedDraftLostBeforeOrDuringOwnerPrompt() async throws {
        for beforeConfirmation in [false, true] {
            let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
            let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
            let draft = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
            let checkpoint = h.store.bytes, prompts = h.ownerRequests.count, signingCalls = h.identityCryptography.signingCalls
            if beforeConfirmation { h.store.bytes = nil }
            else { h.ownerConfirmation = { _ in h.store.bytes = nil; return true } }
            do {
                _ = try await coordinator.signControlRecoveryCopy(draft, current: { true })
                XCTFail("a lost durable draft must never be signed from memory")
            } catch {}
            XCTAssertEqual(h.ownerRequests.count, prompts + (beforeConfirmation ? 0 : 1))
            XCTAssertEqual(h.identityCryptography.signingCalls, signingCalls)
            XCTAssertNil(h.store.bytes, "membership refresh must not overwrite the missing checkpoint")
            h.store.bytes = checkpoint
            let restarted = try h.coordinator()
            XCTAssertFalse(try XCTUnwrap(restarted.localControlRecoveryReviews(current: { true }).first).signed)
        }
    }

    func testRecoveryPreparationAndConfirmationNeverOverwriteCheckpointLostDuringMembershipFetch() async throws {
        for signing in [false, true] {
            let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
            let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
            let draft = signing ? try await coordinator.prepareControlRecoveryCopy(recordID: original,
                context: context, current: { true }) : nil
            let checkpoint = h.store.bytes, prompts = h.ownerRequests.count, signingCalls = h.identityCryptography.signingCalls
            let reservations = authority.reservations
            await h.relay.whenEntriesReply { await MainActor.run { h.store.bytes = nil } }
            do {
                if let draft { _ = try await coordinator.signControlRecoveryCopy(draft, current: { true }) }
                else { _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true }) }
                XCTFail("a network response must never recreate the lost protected journal")
            } catch {}
            XCTAssertNil(h.store.bytes)
            XCTAssertEqual(h.ownerRequests.count, prompts)
            XCTAssertEqual(h.identityCryptography.signingCalls, signingCalls)
            XCTAssertEqual(authority.reservations, reservations)
            h.store.bytes = checkpoint
            let restarted = try h.coordinator()
            XCTAssertTrue(try restarted.localControlRecoveryReviews(current: { true }).allSatisfy { !$0.signed })
        }
    }

    func testRecoveryWindowRetainsOfflineCopyExportWhenMembershipIsFrozen() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let draft = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        _ = try await coordinator.signControlRecoveryCopy(draft, current: { true })
        let expected = try coordinator.exportControlRecoveryCopies(context: context,
            recordIDs: [draft.body.recordId], current: { true })
        let storedChain = await h.relay.log
        let chain = try XCTUnwrap(storedChain)
        let genesis = try MembershipLog.verify(accountId: "account-a", genesisHash: context.genesisHash,
            entries: [XCTUnwrap(chain.entries().first)], now: AstationRecoveryCoordinator.clock())
        let body = try genesis.draftEntry(signer: "manager-a", signedAt: AstationRecoveryCoordinator.clock().wallMs,
            actionJson: recoveryTestJSON(["action": "add_host", "host": ["host_id": "fork-host", "host_trust_gen": 1,
                "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]]))
        let provider = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a", publicKey: try h.identity.remotePublicKeys().signing)
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: "manager-a")
        let entry = try recoveryTestJSON(["body": JSONSerialization.jsonObject(with: Data(body.utf8)),
            "sig": recoveryTestBase64(provider.sign(request: request))])
        await h.relay.injectNextEntries([entry])
        do { _ = try await coordinator.exportedKit(); XCTFail("a conflicting chain must freeze membership") } catch {}
        XCTAssertThrowsError(try coordinator.localControlRecoveryOriginals(stationOrigin: context.stationOrigin, current: { true }))
        let panel = RecoveryCopySavePanel(), destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        panel.destination = destination
        defer { try? FileManager.default.removeItem(at: destination) }
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { false })
        }, makeSavePanel: { panel })
        showRecovery(controller)
        defer { controller.close() }
        try clickRecovery(recoveryButton("Save Signed Copy...", window: controller.window))
        try XCTUnwrap(panel.reply)(.OK)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), expected)
        XCTAssertFalse(try recoveryButton("Prepare Copy...", window: controller.window).isEnabled)
    }

    func testRecoveryCopyWindowConfirmsExactDraftAndExportsOfflineWithoutResigning() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let prompts = h.ownerRequests.count, beforeControls = await h.relay.controls()
        var shown: [RemoteControlRecoveryReview] = []
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        }, confirm: { shown.append($0); return true })
        showRecovery(controller)
        defer { controller.close() }
        let sign = try recoveryButton("Confirm Copy...", window: controller.window)
        XCTAssertFalse(try recoveryButton("Save Signed Copy...", window: controller.window).isEnabled)
        try clickRecovery(sign)
        try await waitForRecoveryUI { (try? self.recoveryButton("Save Signed Copy...", window: controller.window).isEnabled) == true }
        XCTAssertEqual(shown, [review])
        XCTAssertEqual(h.ownerRequests.count, prompts + 1)
        XCTAssertEqual(h.ownerRequests.last, review.request)
        XCTAssertFalse(sign.isEnabled)
        let afterControls = await h.relay.controls()
        XCTAssertEqual(afterControls, beforeControls)
        let expected = try coordinator.exportControlRecoveryCopies(context: context,
            recordIDs: [review.body.recordId], current: { true })
        let offline = try h.coordinator(), panel = RecoveryCopySavePanel()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        panel.destination = destination
        defer { try? FileManager.default.removeItem(at: destination) }
        let saved = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: offline, current: { true }, canSign: { false })
        }, makeSavePanel: { panel })
        showRecovery(saved)
        defer { saved.close() }
        XCTAssertFalse(try recoveryButton("Confirm Copy...", window: saved.window).isEnabled)
        try clickRecovery(recoveryButton("Save Signed Copy...", window: saved.window))
        try XCTUnwrap(panel.reply)(.OK)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(h.ownerRequests.count, prompts + 1, "offline export never prompts or signs")
        XCTAssertEqual(authority.reservations, 1)
    }

    func testRecoveryCopyWindowCancelsReviewOnAccountChangeBeforeOwnerPrompt() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let prompts = h.ownerRequests.count
        var live = true
        let entered = expectation(description: "recovery review shown")
        var answer: CheckedContinuation<Bool, Never>?
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { live }, canSign: { true })
        }, confirm: { _ in
            await withCheckedContinuation { answer = $0; entered.fulfill() }
        })
        showRecovery(controller)
        defer { controller.close() }
        try clickRecovery(recoveryButton("Confirm Copy...", window: controller.window))
        await fulfillment(of: [entered], timeout: 5)
        live = false
        NotificationCenter.default.post(name: .accountLoginChanged, object: nil)
        answer?.resume(returning: true)
        try await waitForRecoveryUI { (try? self.recoveryButton("Refresh", window: controller.window).isEnabled) == true }
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertFalse(try recoveryButton("Save Signed Copy...", window: controller.window).isEnabled)
        XCTAssertFalse(try XCTUnwrap(coordinator.localControlRecoveryReviews(current: { true }).first).signed)
    }

    func testRecoveryCopyWindowDefaultGateAndRejectedReviewNeverPrompt() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let prompts = h.ownerRequests.count, offline = try h.coordinator()
        let disabled = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: offline, current: { true }, canSign: { true })
        })
        showRecovery(disabled)
        defer { disabled.close() }
        XCTAssertFalse(try recoveryButton("Confirm Copy...", window: disabled.window).isEnabled)
        var reviews = 0
        let denied = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        }, confirm: { _ in reviews += 1; return false })
        showRecovery(denied)
        defer { denied.close() }
        let sign = try recoveryButton("Confirm Copy...", window: denied.window)
        try clickRecovery(sign)
        try await waitForRecoveryUI { reviews == 1 && sign.isEnabled }
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertFalse(try recoveryButton("Save Signed Copy...", window: denied.window).isEnabled)
    }

    func testRecoveryCopyWindowClosesSavePanelAndIgnoresLateReply() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        _ = try await coordinator.signControlRecoveryCopy(review, current: { true })
        let panel = RecoveryCopySavePanel(), destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        panel.destination = destination
        defer { try? FileManager.default.removeItem(at: destination) }
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { false })
        }, makeSavePanel: { panel })
        showRecovery(controller)
        try clickRecovery(recoveryButton("Save Signed Copy...", window: controller.window))
        let reply = try XCTUnwrap(panel.reply)
        controller.close()
        XCTAssertEqual(panel.cancellations, 1)
        reply(.OK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRecoveryCopyWindowDismissesRealReviewSheetWhenClosed() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        _ = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        let prompts = h.ownerRequests.count
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { true })
        })
        showRecovery(controller)
        defer { controller.close() }
        try clickRecovery(recoveryButton("Confirm Copy...", window: controller.window))
        try await waitForRecoveryUI { controller.window?.attachedSheet != nil }
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        controller.close()
        try await waitForRecoveryUI { !sheet.isVisible }
        showRecovery(controller)
        try await waitForRecoveryUI { (try? self.recoveryButton("Refresh", window: controller.window).isEnabled) == true }
        try clickRecovery(recoveryButton("Refresh", window: controller.window))
        XCTAssertEqual(h.ownerRequests.count, prompts)
        XCTAssertFalse(try XCTUnwrap(coordinator.localControlRecoveryReviews(current: { true }).first).signed)
    }

    func testRecoveryCopyWindowRechecksDurableCheckpointBeforeSaving() async throws {
        _ = NSApplication.shared
        let h = RecoveryCoordinatorHarness(), authority = RecoveryCopyAuthority()
        let (coordinator, context, original) = try await recoveryCopySource(h, authority: authority)
        let review = try await coordinator.prepareControlRecoveryCopy(recordID: original, context: context, current: { true })
        _ = try await coordinator.signControlRecoveryCopy(review, current: { true })
        let panel = RecoveryCopySavePanel(), destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        panel.destination = destination
        defer { try? FileManager.default.removeItem(at: destination) }
        let controller = ControlRecoveryWindowController(stationOrigin: context.stationOrigin, loadAccess: {
            .init(coordinator: coordinator, current: { true }, canSign: { false })
        }, makeSavePanel: { panel })
        showRecovery(controller)
        defer { controller.close() }
        try clickRecovery(recoveryButton("Save Signed Copy...", window: controller.window))
        h.store.bytes = nil
        try XCTUnwrap(panel.reply)(.OK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try coordinator.localControlRecoveryReviews(current: { true }))
    }

    func testNativeStopAndPortalMirrorRetryTheirExactSavedIntentAfterBothRepliesAreLost() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(coordinator!, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator!.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        let confirmations = h.ownerRequests.count
        await h.relay.dropControlReply()
        await transport.dropNextReply()
        let pending = try await coordinator!.commitServiceControl(review, portal: client, current: { true })
        XCTAssertFalse(pending.stationStored)
        XCTAssertFalse(pending.portalMirrored)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        XCTAssertEqual(h.ownerRequests.last, review.request)
        XCTAssertEqual(review.request.purpose, .controlRecord)
        let initial = await h.relay.controls()
        XCTAssertEqual(initial.count, 1)
        let body = try parseControlRecord(recordJson: XCTUnwrap(initial.first))
        XCTAssertEqual(body.recordId, review.recordID)
        XCTAssertEqual(body.interruptRunning, true)
        let ordinary = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a",
            publicKey: try h.identity.remotePublicKeys().signing)
        XCTAssertThrowsError(try ordinary.sign(request: review.request), "ordinary account signing must not bypass the delegated gate")
        coordinator = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let results = try await resumed.retryPendingControls(portal: client, current: { true })
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.stationStored)
        XCTAssertTrue(result.portalMirrored)
        XCTAssertEqual(result.recordJSON, initial.first)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1, "a retry never asks the key to sign again")
        let final = await h.relay.controls()
        XCTAssertEqual(final, initial, "no new record or changed signature is emitted")
        let remaining = try await resumed.retryPendingControls(portal: client, current: { true })
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(IntegrationApprovalViewController.controlStatus(result).contains("Host application is not confirmed"))
    }

    func testNativeStopDenialAndAnAccountChangeSendNothing() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: false, current: { true })
        h.approve = false
        do { _ = try await coordinator.commitServiceControl(review, portal: client, current: { true }); XCTFail("denial ignored") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        h.approve = true
        do { _ = try await coordinator.commitServiceControl(review, portal: client, current: { false }); XCTFail("account change ignored") }
        catch {}
        try coordinator.cancelUnsignedControl(review)
        let controls = await h.relay.controls()
        XCTAssertTrue(controls.isEmpty)
    }

    func testLaterNativeInterruptHasItsOwnConfirmationAndNeverRepeatsPortalRevocation() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }), transport = ServiceApprovalPortal()
        let record = try await revokedService(coordinator, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: true,
            interruptRunning: false, current: { true })
        let posts = await transport.count()
        let confirmations = h.ownerRequests.count
        let result = try await coordinator.commitServiceControl(review, portal: client, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertNil(result.portalMirror)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        let finalPosts = await transport.count()
        XCTAssertEqual(finalPosts, posts)
        let body = try parseControlRecord(recordJson: result.recordJSON)
        XCTAssertEqual(body.action, "interrupt_running")
        XCTAssertNil(body.interruptRunning)
    }

    func testSavedControlsResumeInTheAccountCoordinatorWithoutAnIntegrationWindow() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var first: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await revokedService(first!, transport: transport)
        let client = try portal(transport)
        let review = try await first!.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: false, current: { true })
        await h.relay.dropControlReply()
        let pending = try await first!.commitServiceControl(review, portal: client, current: { true })
        XCTAssertFalse(pending.stationStored)
        XCTAssertTrue(pending.portalMirrored)
        first = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let finished = expectation(description: "account background delivery")
        resumed.onControlDelivery = { delivery in
            XCTAssertEqual(delivery.recordID, review.recordID)
            XCTAssertTrue(delivery.stationStored)
            XCTAssertTrue(delivery.portalMirrored)
            finished.fulfill()
        }
        resumed.resumeControlDelivery(portal: client, current: { true })
        await fulfillment(of: [finished], timeout: 2)
    }

    func testRecoveryEvidenceExportsRetainedOriginWithoutNetworkGateOrOwnerPrompt() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var first: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(first!, transport: transport), client = try portal(transport)
        let review = try await first!.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await h.relay.dropControlReply(disableEntries: true)
        let pending = try await first!.commitServiceControl(review, portal: client, current: { true })
        first = nil
        let selected = RecoveryMemoryRelay(stationOrigin: "https://new.example")
        let resumed = try h.coordinator(relayURL: "https://new.example", transport: selected)
        XCTAssertFalse(resumed.delegatedControlsAvailable)
        let confirmations = h.ownerRequests.count, before = h.store.bytes, writes = h.store.writes
        let exported = try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { true })
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertEqual(value["station_origin"] as? String, pending.stationOrigin)
        XCTAssertTrue(exported.contains(pending.recordJSON))
        XCTAssertEqual((value["records"] as? [Any])?.count, 1)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertEqual(h.store.bytes, before)
        XCTAssertEqual(h.store.writes, writes)
        let newRecords = await selected.controls()
        XCTAssertTrue(newRecords.isEmpty)
        XCTAssertThrowsError(try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { false }))
        h.store.readFailure = true
        XCTAssertThrowsError(try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { true }))
        h.store.readFailure = false
        XCTAssertEqual(try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { true }), exported)
        var changed = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(h.store.bytes), format: nil) as? [String: Any])
        changed["managerID"] = "other-manager"
        h.store.bytes = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
        XCTAssertThrowsError(try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { true }))
        h.store.bytes = before
        XCTAssertThrowsError(try resumed.exportControlRecoveryEvidence(stationOrigin: pending.stationOrigin, current: { true }),
            "A detected external change fences the instance even if its older bytes return")
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertEqual(h.store.writes, writes)
    }

    func testSavedServiceStopRetriesItsOriginalStationAfterSelectionAndProcessChange() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var first: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(first!, transport: transport), client = try portal(transport)
        let review = try await first!.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await h.relay.dropControlReply()
        let pending = try await first!.commitServiceControl(review, portal: client, current: { true })
        XCTAssertFalse(pending.stationStored)
        let confirmations = h.ownerRequests.count, selected = RecoveryMemoryRelay(stationOrigin: "https://new.example")
        first = nil
        var requested: [String] = []
        let resumed = try h.coordinator(relayURL: "https://new.example", transport: selected,
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { origin in
                requested.append(origin)
                XCTAssertEqual(origin, pending.stationOrigin)
                return h.relay
            })
        let delivered = expectation(description: "retained Station delivery after changing selection")
        resumed.onControlDelivery = { result in
            XCTAssertEqual(result.stationOrigin, pending.stationOrigin)
            XCTAssertEqual(result.recordJSON, pending.recordJSON)
            XCTAssertTrue(result.stationStored)
            XCTAssertTrue(result.portalMirrored)
            delivered.fulfill()
        }
        resumed.resumeControlDelivery(portal: client, current: { true })
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertFalse(requested.isEmpty)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let oldRecords = await h.relay.controls(), newRecords = await selected.controls()
        XCTAssertEqual(oldRecords, [pending.recordJSON], "a lost receipt retries identical bytes")
        XCTAssertTrue(newRecords.isEmpty, "selection never redirects a service-bound stop")
        XCTAssertTrue(try resumed.localControlActivity().isEmpty)
        XCTAssertTrue(try XCTUnwrap(resumed.localControlActivity(stationOrigin: pending.stationOrigin).first).stationStored)
    }

    func testRetainedStopStillMirrorsPortalWhenItsStationIsOffline() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(first, transport: transport), client = try portal(transport)
        let review = try await first.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await h.relay.dropControlReply(disableEntries: true)
        await transport.dropNextReply()
        let pending = try await first.commitServiceControl(review, portal: client, current: { true })
        XCTAssertFalse(pending.stationStored)
        XCTAssertFalse(pending.portalMirrored)
        let confirmations = h.ownerRequests.count
        let resumed = try h.coordinator(relayURL: "https://new.example",
            transport: RecoveryMemoryRelay(stationOrigin: "https://new.example"),
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { _ in h.relay })
        let results = try await resumed.retryPendingControls(portal: client,
            stationOrigin: pending.stationOrigin, current: { true })
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.stationStored)
        XCTAssertTrue(result.portalMirrored)
        XCTAssertEqual(result.recordJSON, pending.recordJSON)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
    }

    func testRetainedStopRejectsMislabeledAndUnreviewedDestinations() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(first, harness: h)
        let review = try await first.prepareHostInterrupt(hostID: "host-a", current: { true })
        await h.relay.dropControlReply()
        let pending = try await first.commitHostInterrupt(review, current: { true })
        let wrong = RecoveryMemoryRelay(stationOrigin: "https://wrong.example")
        var requested: [String] = []
        let resumed = try h.coordinator(relayURL: "https://new.example",
            transport: RecoveryMemoryRelay(stationOrigin: "https://new.example"),
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { origin in requested.append(origin); return wrong })
        let client = try portal(transport)
        do {
            _ = try await resumed.retryPendingControls(portal: client, stationOrigin: "https://unreviewed.example", current: { true })
            XCTFail("unknown journals cannot trigger authorization or delivery")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertTrue(requested.isEmpty)
        let results = try await resumed.retryPendingControls(portal: client,
            stationOrigin: pending.stationOrigin, current: { true })
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.stationStored)
        XCTAssertEqual(requested, [pending.stationOrigin])
        let wrongRecords = await wrong.controls()
        XCTAssertTrue(wrongRecords.isEmpty)
    }

    func testRetainedStopCannotPublishAfterItsAccountContextChangesDuringRefresh() async throws {
        @MainActor final class Context { var current = true }
        let context = Context(), h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(first, harness: h)
        let review = try await first.prepareHostInterrupt(hostID: "host-a", current: { true })
        await h.relay.dropControlReply()
        let pending = try await first.commitHostInterrupt(review, current: { true })
        let attempts = await h.relay.controlCallCount()
        let resumed = try h.coordinator(relayURL: "https://new.example",
            transport: RecoveryMemoryRelay(stationOrigin: "https://new.example"),
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { _ in h.relay })
        await h.relay.whenEntriesReply { await MainActor.run { context.current = false } }
        do {
            _ = try await resumed.retryPendingControls(portal: portal(transport), stationOrigin: pending.stationOrigin,
                current: { context.current })
            XCTFail("retired account sent a saved stop")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        let after = await h.relay.controlCallCount()
        XCTAssertEqual(after, attempts)
        XCTAssertFalse(try XCTUnwrap(resumed.localControlActivity(stationOrigin: pending.stationOrigin).first).stationStored)
    }

    func testRetainedStopBackgroundRetryRotatesPastAnOfflineJournal() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(first, harness: h)
        let oldReview = try await first.prepareHostInterrupt(hostID: "host-a", current: { true })
        await h.relay.dropControlReply()
        let oldPending = try await first.commitHostInterrupt(oldReview, current: { true })
        let secondOrigin = "https://second.example", second = RecoveryMemoryRelay(stationOrigin: "https://second.example")
        await second.replaceLog(try await first.hostSenderMembership())
        let secondCoordinator = try h.coordinator(relayURL: secondOrigin, transport: second, authorizeDelegatedControl: { _ in })
        let secondReview = try await secondCoordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        await second.dropControlReply()
        let secondPending = try await secondCoordinator.commitHostInterrupt(secondReview, current: { true })
        await h.relay.setEntriesUnavailable(true)
        let confirmations = h.ownerRequests.count
        let resumed = try h.coordinator(relayURL: "https://new.example",
            transport: RecoveryMemoryRelay(stationOrigin: "https://new.example"),
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { origin in
                if origin == oldPending.stationOrigin { return h.relay }
                XCTAssertEqual(origin, secondOrigin)
                return second
            })
        let failed = expectation(description: "offline saved journal stays pending")
        let delivered = expectation(description: "another saved journal can complete")
        resumed.onControlDelivery = { result in
            if result.recordID == oldPending.recordID {
                XCTAssertFalse(result.stationStored); failed.fulfill()
            } else {
                XCTAssertEqual(result.recordJSON, secondPending.recordJSON)
                XCTAssertTrue(result.stationStored); delivered.fulfill()
            }
        }
        let client = try portal(transport)
        resumed.resumeControlDelivery(portal: client, current: { true })
        await fulfillment(of: [failed], timeout: 5)
        resumed.resumeControlDelivery(portal: client, current: { true })
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let records = await second.controls()
        XCTAssertEqual(records, [secondPending.recordJSON])
    }

    func testSavedStopBatchesRotatePastEightUnavailableRecords() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var first: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(first!, transport: transport), client = try portal(transport)
        var pending: [RemoteControlDelivery] = []
        for _ in 0..<9 {
            let review = try await first!.prepareServiceControl(record, portal: client, interruptOnly: false,
                interruptRunning: false, current: { true })
            await h.relay.dropControlReply()
            pending.append(try await first!.commitServiceControl(review, portal: client, current: { true }))
        }
        XCTAssertTrue(pending.allSatisfy { !$0.stationStored })
        let confirmations = h.ownerRequests.count
        first = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        await h.relay.setEntriesUnavailable(true)
        let unavailable = try await resumed.retryPendingControls(portal: client, current: { true })
        XCTAssertEqual(unavailable.map(\.recordID), Array(pending.prefix(8)).map(\.recordID))
        XCTAssertTrue(unavailable.allSatisfy { !$0.stationStored })
        await h.relay.setEntriesUnavailable(false)
        let retried = try await resumed.retryPendingControls(portal: client, current: { true })
        XCTAssertEqual(retried.count, 8)
        XCTAssertEqual(retried.first?.recordID, pending.last?.recordID,
            "the ninth stop must get its turn even when the first eight remain pending")
        XCTAssertTrue(retried.allSatisfy(\.stationStored))
        let remaining = try await resumed.retryPendingControls(portal: client, current: { true })
        XCTAssertEqual(remaining.map(\.recordID), [pending[7].recordID])
        XCTAssertTrue(remaining.allSatisfy(\.stationStored))
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let stored = await h.relay.controls()
        XCTAssertEqual(stored, pending.map(\.recordJSON), "retries never change or duplicate the original signatures")
    }

    func testRetainedHostStopRetriesOnlyItsPreviouslyReviewedFanout() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        _ = try await revokedSender(first, harness: h)
        await second.replaceLog(try await first.hostSenderMembership())
        let review = try await first.prepareHostInterrupt(hostID: "host-a", current: { true })
        await second.dropControlReply()
        let pending = try await first.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(pending.stationStored)
        XCTAssertFalse(pending.allStationsStored)
        let primaryCalls = await h.relay.controlCallCount(), confirmations = h.ownerRequests.count
        let selected = RecoveryMemoryRelay(stationOrigin: "https://new.example")
        var requested: [String] = []
        let resumed = try h.coordinator(relayURL: "https://new.example", transport: selected,
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { requestedOrigin in
                requested.append(requestedOrigin)
                XCTAssertEqual(requestedOrigin, origin)
                return second
            })
        let results = try await resumed.retryPendingControls(portal: portal(transport),
            stationOrigin: pending.stationOrigin, current: { true })
        let delivered = try XCTUnwrap(results.first)
        XCTAssertTrue(delivered.allStationsStored)
        XCTAssertEqual(delivered.recordJSON, pending.recordJSON)
        XCTAssertFalse(requested.isEmpty)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let after = await h.relay.controlCallCount(), selectedRecords = await selected.controls(), records = await second.controls()
        XCTAssertEqual(after, primaryCalls, "a settled destination must not be republished")
        XCTAssertTrue(selectedRecords.isEmpty, "selection is not a reviewed delivery destination")
        XCTAssertEqual(records, [pending.recordJSON])
    }

    func testRetainedStopRechecksTheOldStationsManagerAuthorityBeforePublishing() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let first = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(first, harness: h)
        let other = try await addSecondManager(harness: h)
        let review = try await first.prepareHostInterrupt(hostID: "host-a", current: { true })
        await h.relay.dropControlReply()
        let pending = try await first.commitHostInterrupt(review, current: { true })
        let attempts = await h.relay.controlCallCount(), confirmations = h.ownerRequests.count
        try await append(["action": "set_roles", "device_id": "manager-a", "roles": ["control", "view"]],
            harness: h, signer: "manager-b", identity: other)
        let resumed = try h.coordinator(relayURL: "https://new.example",
            transport: RecoveryMemoryRelay(stationOrigin: "https://new.example"),
            authorizeDelegatedControl: { _ in }, retainedControlTransport: { _ in h.relay })
        let results = try await resumed.retryPendingControls(portal: portal(transport),
            stationOrigin: pending.stationOrigin, current: { true })
        XCTAssertFalse(try XCTUnwrap(results.first).stationStored)
        let after = await h.relay.controlCallCount()
        XCTAssertEqual(after, attempts, "a retained signature cannot bypass a later manager removal")
        XCTAssertEqual(h.ownerRequests.count, confirmations, "delivery never asks for another signature")
        let activity = try XCTUnwrap(resumed.localControlActivity(stationOrigin: pending.stationOrigin).first)
        XCTAssertTrue(activity.managerReviewRequired)
    }

    func testNativeInterruptingRevokeKeepsItsMirrorPendingIfANonInterruptingRevokeWonFirst() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(coordinator, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await transport.revoke()
        await transport.keepEarlierInterruptChoice()
        let result = try await coordinator.commitServiceControl(review, portal: client, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertFalse(result.portalMirrored, "an earlier Portal false must not confirm the native true choice")
        XCTAssertEqual(result.portalMirror?.interruptRunning, true)
        let signed = try parseControlRecord(recordJson: result.recordJSON)
        XCTAssertEqual(signed.interruptRunning, true)
    }

    func testNativeInterruptingMirrorConvergesWithAnEarlierNoninterruptingPortalRevoke() async throws {
        let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(coordinator, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await transport.revoke()
        let result = try await coordinator.commitServiceControl(review, portal: client, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertTrue(result.portalMirrored)
        XCTAssertTrue(result.portalSettled)
        XCTAssertNil(result.portalRefusal)
    }

    func testFinalPortalConflictsSettleAcrossRestartWhileStationDeliveryStillRetries() async throws {
        for reason: RemoteControlPortalRefusal in [.tooLate, .stationRemoved] {
            let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
            var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
            let record = try await activeService(coordinator!, transport: transport)
            let client = try portal(transport)
            let review = try await coordinator!.prepareServiceControl(record, portal: client, interruptOnly: false,
                interruptRunning: true, current: { true })
            let approvals = h.ownerRequests.count
            await transport.revoke()
            await transport.refuseRevoke(reason.rawValue)
            await h.relay.dropControlReply()
            let result = try await coordinator!.commitServiceControl(review, portal: client, current: { true })
            XCTAssertFalse(result.stationStored)
            XCTAssertFalse(result.portalMirrored)
            XCTAssertTrue(result.portalSettled)
            XCTAssertEqual(result.portalRefusal, reason)
            let posts = await transport.count()
            let status = IntegrationApprovalViewController.controlStatus(result)
            XCTAssertTrue(status.contains("mirror settled"))
            XCTAssertTrue(status.contains(reason == .tooLate ? "window has ended" : "Station was removed"))
            XCTAssertTrue(status.contains("Host application is not confirmed"))
            XCTAssertFalse(status.contains("revocation is confirmed"))
            coordinator = nil
            let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
            let retries = try await resumed.retryPendingControls(portal: client, current: { true })
            let retry = try XCTUnwrap(retries.first)
            XCTAssertTrue(retry.stationStored)
            XCTAssertTrue(retry.portalSettled)
            XCTAssertFalse(retry.portalMirrored)
            XCTAssertEqual(retry.portalRefusal, reason)
            XCTAssertEqual(retry.recordJSON, result.recordJSON)
            let after = await transport.count()
            XCTAssertEqual(after, posts, "a final mirror is never resent after restart")
            XCTAssertEqual(h.ownerRequests.count, approvals + 1, "same signed stop, no repeated owner approval")
            let controls = await h.relay.controls()
            XCTAssertEqual(controls, [result.recordJSON])
            let remaining = try await resumed.retryPendingControls(portal: client, current: { true })
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testUnrecognizedOrUnauthenticatedPortalConflictsRemainPending() async throws {
        for (code, status) in [("invalid_state", 409), ("too_late", 401), ("station_removed", 503)] {
            let h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
            let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
            let record = try await activeService(coordinator, transport: transport)
            let client = try portal(transport)
            let review = try await coordinator.prepareServiceControl(record, portal: client, interruptOnly: false,
                interruptRunning: true, current: { true })
            await transport.refuseRevoke(code, status: status)
            let result = try await coordinator.commitServiceControl(review, portal: client, current: { true })
            XCTAssertTrue(result.stationStored)
            XCTAssertFalse(result.portalSettled)
            XCTAssertNil(result.portalRefusal)
            let posts = await transport.count()
            _ = try await coordinator.retryPendingControls(portal: client, current: { true })
            let after = await transport.count()
            XCTAssertEqual(after, posts + 1)
        }
    }

    func testDelayedFinalRefusalCannotSettleAfterTheNativeContextChanges() async throws {
        @MainActor final class Context { var current = true }
        let context = Context(), h = RecoveryCoordinatorHarness(), transport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let record = try await activeService(coordinator!, transport: transport)
        let client = try portal(transport)
        let review = try await coordinator!.prepareServiceControl(record, portal: client, interruptOnly: false,
            interruptRunning: true, current: { true })
        await transport.refuseRevoke("too_late")
        await transport.whenRevokeReplies { await MainActor.run { context.current = false } }
        do {
            _ = try await coordinator!.commitServiceControl(review, portal: client, current: { context.current })
            XCTFail("retired response settled")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        let posts = await transport.count()
        let approvals = h.ownerRequests.count
        coordinator = nil
        await transport.whenRevokeReplies {}
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let retries = try await resumed.retryPendingControls(portal: client, current: { true })
        let result = try XCTUnwrap(retries.first)
        XCTAssertTrue(result.stationStored)
        XCTAssertEqual(result.portalRefusal, .tooLate)
        let after = await transport.count()
        XCTAssertEqual(after, posts + 1, "the retired reply left its mirror pending")
        XCTAssertEqual(h.ownerRequests.count, approvals)
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

extension AstationRecoveryCoordinatorTests {
    private func senderHost(_ coordinator: AstationRecoveryCoordinator, harness h: RecoveryCoordinatorHarness) async throws {
        _ = try await coordinator.setup()
        try await append(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 1,
            "host_key": ["alg": "ed25519", "pub": recoveryTestBase64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]], harness: h)
    }

    func testHostSenderControlsCannotSignThroughTheOrdinaryProductionProvider() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        try await senderHost(coordinator, harness: h)
        let before = h.ownerRequests.count
        XCTAssertFalse(coordinator.hostSenderControlsAvailable)
        do {
            _ = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: false), current: { true })
            XCTFail("Production must wait for live verifier inventory and joint checks")
        } catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        let relayLog = await h.relay.log
        let log = try XCTUnwrap(relayLog)
        let review = try RemoteHostSenderReview(stationOrigin: coordinator.relayURL, log: log, managerID: "manager-a",
            hostID: "host-a", operation: .revoke(interruptRunning: false), now: AstationRecoveryCoordinator.clock())
        let request = try review.signingRequest(managerID: "manager-a")
        let key = try h.identity.remotePublicKeys().signing
        let ordinary = AstationMembershipKeyProvider(identity: h.identity, keyID: "manager-a", publicKey: key)
        XCTAssertThrowsError(try ordinary.sign(request: request))
        XCTAssertThrowsError(try h.identity.signMembership(request, expectedPublicKey: key))
        XCTAssertEqual(h.ownerRequests.count, before)
    }

    func testNativeHostSenderRevokeAndReadmitCommitTheReviewedSharedEntries() async throws {
        let h = RecoveryCoordinatorHarness()
        var checks = 0
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in checks += 1 })
        try await senderHost(coordinator, harness: h)
        let confirmations = h.ownerRequests.count
        let revoke = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: true), current: { true })
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(try coordinator.pendingHostSenderReview(), revoke)
        do { _ = try await coordinator.exportedKit(); XCTFail("Another account writer must wait for this review") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .busy) }
        try await coordinator.commitHostSender(revoke, current: { true })
        XCTAssertEqual(checks, 4, "Check before review, before and after confirmation and at the real key callback")
        XCTAssertNil(try coordinator.pendingHostSenderReview())
        let revoked = try await coordinator.hostSenderMembership()
        guard case .revoked = revoked.hostSenderState(hostId: "host-a") else { return XCTFail("revoke was not applied") }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(revoke.bodyJSON.utf8)) as? [String: Any])
        XCTAssertEqual(body["interrupt_running"] as? Bool, true)
        XCTAssertEqual(h.ownerRequests.last, try revoke.signingRequest(managerID: "manager-a"))
        let readmit = try await coordinator.prepareHostSender(hostID: "host-a", operation: .readmit, current: { true })
        try await coordinator.commitHostSender(readmit, current: { true })
        let admitted = try await coordinator.hostSenderMembership()
        XCTAssertEqual(admitted.hostSenderState(hostId: "host-a"), .authorized(generation: admitted.head().seq))
        XCTAssertEqual(h.ownerRequests.count, confirmations + 2)
        XCTAssertTrue(h.ownerRequests.suffix(2).allSatisfy { $0.purpose == .hostSender && $0.freshConfirmation })
    }

    func testNativeHostSenderLostReplyReconcilesAfterRestartWithoutSigningOrAppendingAgain() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in })
        try await senderHost(coordinator!, harness: h)
        let review = try await coordinator!.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: true), current: { true })
        await h.relay.dropNextAppendReply()
        do { try await coordinator!.commitHostSender(review, current: { true }); XCTFail("lost reply") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .unavailable) }
        XCTAssertThrowsError(try coordinator!.cancelUnsignedHostSender(review), "A signed entry cannot be discarded")
        let confirmations = h.ownerRequests.count
        let appends = await h.relay.appends.count
        coordinator = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in XCTFail("Already signed") })
        XCTAssertEqual(try resumed.pendingHostSenderReview(), review)
        try await resumed.commitHostSender(review, current: { true })
        XCTAssertNil(try resumed.pendingHostSenderReview())
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let after = await h.relay.appends.count
        XCTAssertEqual(after, appends)
    }

    func testNativeHostSenderWriteThatCommitsThenThrowsResumesTheExactSignature() async throws {
        let h = RecoveryCoordinatorHarness()
        var checks = 0
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in
            checks += 1
            if checks == 4 { h.store.failAfterWrite = true }
        })
        try await senderHost(coordinator!, harness: h)
        let review = try await coordinator!.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: false), current: { true })
        let count = await h.relay.appends.count
        do { try await coordinator!.commitHostSender(review, current: { true }); XCTFail("uncertain commit") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        XCTAssertThrowsError(try coordinator!.pendingHostSenderReview())
        let beforeRestart = await h.relay.appends.count
        XCTAssertEqual(beforeRestart, count, "Never send after uncertain protected persistence")
        let confirmations = h.ownerRequests.count
        coordinator = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in XCTFail("Saved signature must be reused") })
        try await resumed.commitHostSender(review, current: { true })
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let after = await h.relay.appends
        XCTAssertEqual(after.count, count + 1)
        XCTAssertEqual(try signedObjectInfo(json: XCTUnwrap(after.last).entryJson).bodyJcs, review.bodyJSON)
    }

    func testNativeHostSenderVerifierDisconnectDuringOwnerConfirmationPreventsSignature() async throws {
        let h = RecoveryCoordinatorHarness()
        var online = true
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in
            guard online else { throw RemoteVerifierGateError.unconfirmedVerifiers }
        })
        try await senderHost(coordinator, harness: h)
        let review = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: false), current: { true })
        let appends = await h.relay.appends.count
        h.ownerConfirmation = { _ in online = false; return true }
        do { try await coordinator.commitHostSender(review, current: { true }); XCTFail("Offline strict verifier") }
        catch { XCTAssertEqual(error as? RemoteVerifierGateError, .unconfirmedVerifiers) }
        let after = await h.relay.appends.count
        XCTAssertEqual(after, appends)
        XCTAssertEqual(try coordinator.pendingHostSenderReview(), review)
        try coordinator.cancelUnsignedHostSender(review)
        XCTAssertNil(try coordinator.pendingHostSenderReview())
    }

    func testNativeHostSenderDemotionDuringConfirmationNeverSignsOrReusesTheReview() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in })
        try await senderHost(coordinator, harness: h)
        let manager = try await addSecondManager(harness: h)
        let review = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: false), current: { true })
        h.ownerConfirmation = { _ in
            try await self.append(["action": "set_roles", "device_id": "manager-a", "roles": ["view"]],
                harness: h, signer: "manager-b", identity: manager)
            return true
        }
        do { try await coordinator.commitHostSender(review, current: { true }); XCTFail("Demoted manager") }
        catch { }
        let relayLog = await h.relay.log
        let log = try XCTUnwrap(relayLog)
        XCTAssertNotEqual(log.hostSenderState(hostId: "host-a"), .revoked(seq: log.head().seq))
        XCTAssertFalse(log.entries().contains { (try? signedObjectInfo(json: $0).bodyJcs) == review.bodyJSON })
        try coordinator.cancelUnsignedHostSender(review)
    }

    func testNativeHostSenderConcurrentNoninterruptingRevokeCannotSatisfyAnInterruptingIntent() async throws {
        for interrupt in [false, true] {
            let h = RecoveryCoordinatorHarness()
            let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in })
            try await senderHost(coordinator, harness: h)
            let manager = try await addSecondManager(harness: h)
            let review = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: interrupt), current: { true })
            let action = try JSONSerialization.jsonObject(with: Data(hostSenderRevokeAction(hostId: "host-a", interruptRunning: false,
                signedAt: AstationRecoveryCoordinator.clock().wallMs).utf8)) as! [String: Any]
            try await append(action, harness: h, signer: "manager-b", identity: manager, authorizeNewMembership: { _ in })
            let confirmations = h.ownerRequests.count
            do {
                try await coordinator.commitHostSender(review, current: { true })
                XCTAssertFalse(interrupt, "Do not silently downgrade interrupt_running")
            } catch { XCTAssertTrue(interrupt); XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
            XCTAssertNil(try coordinator.pendingHostSenderReview())
            XCTAssertEqual(h.ownerRequests.count, confirmations)
            XCTAssertEqual((try checkpoint(h.store)["supersededHostSenderPublications"] as? [Data])?.count, 1)
        }
    }

    func testNativeHostSenderRowsKeepRevokedRemovedHostsAndReadmitExplainsNewWorkOnly() async throws {
        let h = RecoveryCoordinatorHarness()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in })
        try await senderHost(coordinator, harness: h)
        let revoke = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: false), current: { true })
        XCTAssertTrue(HostSenderAccessWindowController.explanation(revoke).contains("not interrupted"))
        try await coordinator.commitHostSender(revoke, current: { true })
        try await append(["action": "remove_host", "host_id": "host-a"], harness: h)
        let log = try await coordinator.hostSenderMembership()
        XCTAssertEqual(try HostSenderAccessWindowController.senderRows(log: log), [
            HostSenderAccessWindowController.Row(hostID: "host-a", projects: [], revoked: true, removed: true,
                latestRevokeSeq: try AstationRecoveryCoordinator.latestHostSenderRevocation(log: log, hostID: "host-a"))])
        let readmit = try await coordinator.prepareHostSender(hostID: "host-a", operation: .readmit, current: { true })
        let notice = HostSenderAccessWindowController.explanation(readmit)
        XCTAssertTrue(notice.contains("Only newly sent work"))
        XCTAssertTrue(notice.contains("Cancelled tasks do not return"))
        try coordinator.cancelUnsignedHostSender(readmit)
    }

    func testNativeHostSenderCASRaceRetainsTheLosingSignatureAndDoesNotReSign() async throws {
        for interrupt in [false, true] {
            let h = RecoveryCoordinatorHarness()
            let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, authorizeNewMembership: { _, _ in })
            try await senderHost(coordinator, harness: h)
            let other = try await addSecondManager(harness: h)
            let stored = await h.relay.log
            let rival = try XCTUnwrap(stored).snapshot()
            let publisher = RemoteMembershipPublication(log: rival, persist: { _ in })
            _ = try publisher.prepare(actionJSON: hostSenderRevokeAction(hostId: "host-a", interruptRunning: false,
                signedAt: AstationRecoveryCoordinator.clock().wallMs), signer: "manager-b", signedAt: AstationRecoveryCoordinator.clock().wallMs)
            let rivalKeys = AstationMembershipKeyProvider(identity: other, keyID: "manager-b",
                publicKey: try other.remotePublicKeys().signing, authorizeNewMembership: { _ in })
            let entry = try publisher.sign(provider: rivalKeys, keyID: "manager-b")
            _ = try rival.extend(entries: [entry.entryJson], now: AstationRecoveryCoordinator.clock())
            let review = try await coordinator.prepareHostSender(hostID: "host-a", operation: .revoke(interruptRunning: interrupt), current: { true })
            await h.relay.replaceAtNextAppend(rival)
            let confirmations = h.ownerRequests.count
            do {
                try await coordinator.commitHostSender(review, current: { true })
                XCTAssertFalse(interrupt, "Conflicting revoke lost interruption intent")
            } catch {
                XCTAssertTrue(interrupt, "An equivalent concurrent revoke is already done")
                XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview)
            }
            XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
            XCTAssertNil(try coordinator.pendingHostSenderReview())
            let evidence = try XCTUnwrap((try checkpoint(h.store)["supersededHostSenderPublications"] as? [Data])?.first)
            // The actual signed publication is retained, not just the unsigned review.
            let archived = try PropertyListSerialization.propertyList(from: evidence, format: nil) as? [String: Any]
            XCTAssertNotNil(archived?["prepared"] as? String)
            let appends = await h.relay.appends
            XCTAssertEqual(try signedObjectInfo(json: XCTUnwrap(appends.last).entryJson).bodyJcs, review.bodyJSON)
            let final = try await coordinator.hostSenderMembership()
            XCTAssertEqual(final.head(), rival.head())
        }
    }
}

extension AstationRecoveryCoordinatorTests {
    private func revokedSender(_ coordinator: AstationRecoveryCoordinator, harness h: RecoveryCoordinatorHarness) async throws -> UInt64 {
        try await senderHost(coordinator, harness: h)
        let action = try JSONSerialization.jsonObject(with: Data(hostSenderRevokeAction(hostId: "host-a", interruptRunning: false,
            signedAt: AstationRecoveryCoordinator.clock().wallMs).utf8)) as! [String: Any]
        try await append(action, harness: h, authorizeNewMembership: { _ in })
        return try await coordinator.hostSenderMembership().head().seq
    }

    func testHostInterruptRequiresActivationAndAnEarlierRevoke() async throws {
        let h = RecoveryCoordinatorHarness(), off = try h.coordinator()
        try await senderHost(off, harness: h)
        let confirmations = h.ownerRequests.count
        do { _ = try await off.prepareHostInterrupt(hostID: "host-a", current: { true }); XCTFail("default gate bypassed") }
        catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        let on = try h.coordinator(authorizeDelegatedControl: { _ in })
        do { _ = try await on.prepareHostInterrupt(hostID: "host-a", current: { true }); XCTFail("no earlier revoke") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertTrue(try on.pendingHostInterrupts().isEmpty)
        let records = await h.relay.controls()
        XCTAssertTrue(records.isEmpty)
    }

    private func stopsByRemovedManager(_ coordinator: AstationRecoveryCoordinator,
        harness h: RecoveryCoordinatorHarness, count: Int = 1) async throws -> [String] {
        _ = try await revokedSender(coordinator, harness: h)
        let other = try await addSecondManager(harness: h)
        let value = await h.relay.log
        let log = try XCTUnwrap(value)
        let provider = AstationMembershipKeyProvider(identity: other, keyID: "manager-b",
            publicKey: try other.remotePublicKeys().signing, controlRecordsAllowed: true)
        let seq = try XCTUnwrap(AstationRecoveryCoordinator.latestHostSenderRevocation(log: log, hostID: "host-a"))
        var records: [String] = []
        for offset in 0..<count {
            let body = ControlRecordBody(accountId: log.accountId(), genesisHash: log.genesisHash(), origin: nil,
                feedId: nil, principal: "host:host-a", principalKey: nil, signer: "member:manager-b",
                action: "interrupt_running", interruptRunning: nil, revokeSeq: seq,
                recordId: UUID().uuidString.lowercased(), issuedAt: AstationRecoveryCoordinator.clock().wallMs + UInt64(offset),
                integrationId: nil, by: "owner")
            let record = try buildControlRecord(provider: provider, keyId: "manager-b", body: body)
            _ = try await h.relay.publishControl(log: log, recordJSON: record)
            records.append(record)
        }
        try await append(["action": "set_roles", "device_id": "manager-b", "roles": ["control", "view"]], harness: h)
        return records
    }

    func testBackgroundControlDiscoveryRunsWithoutAWindowAndNeverSigns() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let confirmations = h.ownerRequests.count
        let deliveries = await h.relay.controlCallCount()
        let found = expectation(description: "background review discovered")
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, log, activity in
            XCTAssertEqual(log.accountId(), coordinator.accountID)
            XCTAssertEqual(activity.map { $0.body.recordId }, records.compactMap { try? parseControlRecord(recordJson: $0).recordId })
            XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
            found.fulfill()
        }
        await fulfillment(of: [found], timeout: 5)
        coordinator.stopControlActivity()
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let attempts = await h.relay.controlCallCount()
        XCTAssertEqual(attempts, deliveries)
    }

    func testBackgroundControlDiscoveryContinuesPagesAndDeduplicatesAfterRestart() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h, count: 65)
        let first = expectation(description: "first bounded page"), second = expectation(description: "second bounded page")
        var scans = 0
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, _, activity in
            scans += 1
            if scans == 1 { XCTAssertEqual(activity.count, 64); first.fulfill() }
            else { XCTAssertEqual(activity.count, 65); second.fulfill() }
        }
        await fulfillment(of: [first], timeout: 5)
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [second], timeout: 5)
        coordinator.stopControlActivity()
        let reads = await h.relay.syncReads
        XCTAssertEqual(reads, [0, 64])
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let restarted = expectation(description: "restart retains all imported records")
        resumed.resumeControlActivity(generation: UUID(), current: { true }) { _, _, activity in
            XCTAssertEqual(activity.count, 65)
            XCTAssertEqual(Set(activity.map { $0.body.recordId }).count, 65)
            restarted.fulfill()
        }
        await fulfillment(of: [restarted], timeout: 5)
        resumed.stopControlActivity()
    }

    func testBackgroundControlDiscoveryDiscardsRetiredAccountReplies() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        await h.relay.holdNextControlSync()
        let unexpected = expectation(description: "retired account must not notify")
        unexpected.isInverted = true
        var current = true
        coordinator.resumeControlActivity(generation: UUID(), current: { current }) { _, _, _ in unexpected.fulfill() }
        for _ in 0..<1_000 {
            if await h.relay.controlSyncWaiter != nil { break }
            await Task.yield()
        }
        let waiting = await h.relay.controlSyncWaiter != nil
        XCTAssertTrue(waiting)
        current = false
        coordinator.stopControlActivity()
        await h.relay.releaseControlSync()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
    }

    func testBackgroundControlDiscoveryCannotBypassTheDefaultActivationGate() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator()
        _ = try await coordinator.setup()
        let unexpected = expectation(description: "default gate must not notify")
        unexpected.isInverted = true
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, _, _ in unexpected.fulfill() }
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [unexpected], timeout: 0.1)
        let reads = await h.relay.syncReads
        XCTAssertTrue(reads.isEmpty)
        coordinator.stopControlActivity()
    }

    func testBackgroundControlDiscoveryRetiresThePriorRegistrationBeforeStartingItsReplacement() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        await h.relay.holdNextControlSync()
        let old = expectation(description: "previous registration must not notify")
        old.isInverted = true
        let new = expectation(description: "replacement registration catches up")
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, _, _ in old.fulfill() }
        for _ in 0..<1_000 {
            if await h.relay.controlSyncWaiter != nil { break }
            await Task.yield()
        }
        let waiting = await h.relay.controlSyncWaiter != nil
        XCTAssertTrue(waiting)
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, _, activity in
            XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
            new.fulfill()
        }
        await h.relay.releaseControlSync()
        await fulfillment(of: [old], timeout: 0.1)
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [new], timeout: 5)
        coordinator.stopControlActivity()
    }

    func testBackgroundControlDiscoveryDoesNotPublishAnEmptyScanOnFailureAndRetries() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        await h.relay.corruptControlSync()
        var repaired = false
        let failed = expectation(description: "invalid source is not an empty resolved scan")
        failed.isInverted = true
        let recovered = expectation(description: "later bounded retry recovers")
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { _, _, activity in
            if !repaired { failed.fulfill() }
            else { XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1); recovered.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 0.1)
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        repaired = true
        await h.relay.corruptControlSync(false)
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [recovered], timeout: 5)
        coordinator.stopControlActivity()
        let reads = await h.relay.syncReads
        XCTAssertEqual(reads, [0, 0])
    }

    func testControlDiscoveryKeepsOtherStationEvidenceSeparateAndRetainsItAfterRestart() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        let confirmations = h.ownerRequests.count
        _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true })
        let activity = try await coordinator.refreshControlActivity(stationOrigin: origin, current: { true })
        XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        XCTAssertEqual(try coordinator.localControlActivity(stationOrigin: origin).map(\.body.recordId), activity.map(\.body.recordId))
        let restarted = try h.coordinator(authorizeDelegatedControl: { _ in })
        XCTAssertTrue(try restarted.localControlActivity().isEmpty)
        XCTAssertEqual(try restarted.localControlActivity(stationOrigin: origin).map(\.body.recordId), activity.map(\.body.recordId),
            "losing a directory source cannot erase a retained Station's evidence")
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let attempts = await second.controlCallCount()
        XCTAssertEqual(attempts, 0, "discovery must not publish or sign")
    }

    func testBackgroundControlDiscoveryRotatesPastAnUnavailablePrimary() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        await h.relay.setEntriesUnavailable(true)
        let failed = expectation(description: "primary outage produces no resolved notice")
        failed.isInverted = true
        let found = expectation(description: "secondary remains observable")
        var secondaryTick = false
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { source, _, activity in
            if !secondaryTick { failed.fulfill(); return }
            XCTAssertEqual(source, origin)
            XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
            found.fulfill()
        }
        await fulfillment(of: [failed], timeout: 0.1)
        secondaryTick = true
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [found], timeout: 5)
        coordinator.stopControlActivity()
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        XCTAssertEqual(try coordinator.localControlActivity(stationOrigin: origin).count, 1)
    }

    func testBackgroundControlDiscoveryMaintainsIndependentBoundedPagesForEveryOrigin() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        let records = try await stopsByRemovedManager(coordinator, harness: h, count: 65)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        let pages = (0..<4).map { expectation(description: "rotating page \($0)") }
        var scans = 0
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { source, _, activity in
            guard scans < pages.count else { XCTFail("unbounded scan"); return }
            XCTAssertEqual(source, scans.isMultiple(of: 2) ? coordinator.relayURL : origin)
            XCTAssertEqual(activity.count, scans < 2 ? 64 : 65)
            pages[scans].fulfill(); scans += 1
        }
        for index in pages.indices {
            await fulfillment(of: [pages[index]], timeout: 5)
            if index < pages.count - 1 { coordinator.refreshControlActivityInBackground() }
        }
        coordinator.stopControlActivity()
        let firstReads = await h.relay.syncReads, secondReads = await second.syncReads
        XCTAssertEqual(firstReads, [0, 64])
        XCTAssertEqual(secondReads, [0, 64])
    }

    func testControlDiscoveryRetiresADestinationRemovedDuringItsFeedRead() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        var destinations: [String: RemoteControlStationTransport] = [origin: second]
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in destinations })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        await second.holdNextControlSync()
        let scan = Task { try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true }) }
        for _ in 0..<1_000 {
            if await second.controlSyncWaiter != nil { break }
            await Task.yield()
        }
        let waiting = await second.controlSyncWaiter != nil
        XCTAssertTrue(waiting)
        destinations = [:]
        await second.releaseControlSync()
        do { _ = try await scan.value; XCTFail("removed source must not import a delayed page") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertTrue(try coordinator.localControlActivity(stationOrigin: origin).isEmpty)
        destinations = [origin: second]
        _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true })
        XCTAssertEqual(try coordinator.localControlActivity(stationOrigin: origin).count, 1)
        destinations = [:]
        do { _ = try await coordinator.refreshControlActivity(stationOrigin: origin, current: { true }); XCTFail("absent source") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertEqual(try coordinator.localControlActivity(stationOrigin: origin).count, 1)
    }

    func testControlDiscoveryRejectsAMislabeledDestinationBeforeReadingIt() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example", wrong = RecoveryMemoryRelay()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: wrong] })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        do { _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true }); XCTFail("misdirected token source") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        let reads = await wrong.syncReads
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(try coordinator.localControlActivity(stationOrigin: origin).isEmpty)
    }

    func testControlDiscoveryCannotReuseAnotherOriginsCursorEvenWithTheSameFeedID() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let feed = await h.relay.controlFeedID
        let second = RecoveryMemoryRelay(stationOrigin: origin, controlFeedID: feed)
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        let records = try await stopsByRemovedManager(coordinator, harness: h, count: 65)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords([records[0]])
        let first = try await coordinator.discoverControlActivity(previous: nil, current: { true })
        XCTAssertTrue(first.more)
        XCTAssertEqual(first.after, 64)
        _ = try await coordinator.discoverControlActivity(previous: first, stationOrigin: origin, current: { true })
        let reads = await second.syncReads
        XCTAssertEqual(reads, [0])
        XCTAssertEqual(try coordinator.localControlActivity(stationOrigin: origin).count, 1)
    }

    func testControlStatusRetiresARemovedDestinationWithoutClearingItsJournal() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        var destinations: [String: RemoteControlStationTransport] = [origin: second]
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in destinations })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true })
        await second.holdNextControlStatus()
        let scan = Task { try await coordinator.refreshControlActivity(stationOrigin: origin, current: { true }) }
        for _ in 0..<1_000 {
            if await second.controlStatusWaiter != nil { break }
            await Task.yield()
        }
        let waiting = await second.controlStatusWaiter != nil
        XCTAssertTrue(waiting)
        destinations = [:]
        await second.releaseControlStatus()
        do { _ = try await scan.value; XCTFail("removed source must not resolve an alert") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        let activity = try coordinator.localControlActivity(stationOrigin: origin)
        XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
        XCTAssertNil(activity.first?.application)
    }

    func testBackgroundDiscoveryUsesProtectedRetainedOriginsWithoutACompleteDirectoryOrPrimaryAccess() async throws {
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        let first = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        let records = try await stopsByRemovedManager(first, harness: h)
        let sharedLog = await h.relay.log
        await second.replaceLog(try XCTUnwrap(sharedLog))
        await second.replaceControlRecords(records)
        _ = try await first.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true })
        first.stopControlActivity()
        await h.relay.setEntriesUnavailable(true)
        var requests: [String] = []
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in }, retainedControlTransport: { requested in
            requests.append(requested)
            XCTAssertEqual(requested, origin)
            return second
        })
        // An arbitrary URL cannot cause token acquisition or a network request.
        do {
            _ = try await resumed.discoverControlActivity(previous: nil, stationOrigin: "https://unreviewed.example", current: { true })
            XCTFail("unretained destination")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertTrue(requests.isEmpty)
        let unavailable = expectation(description: "unavailable primary produces no notice")
        unavailable.isInverted = true
        let found = expectation(description: "retained secondary is polled after restart")
        var secondaryTick = false
        resumed.resumeControlActivity(generation: UUID(), current: { true }) { source, _, activity in
            guard secondaryTick else { unavailable.fulfill(); return }
            XCTAssertEqual(source, origin)
            XCTAssertEqual(activity.filter(\.requiresManagerReview).count, 1)
            found.fulfill()
        }
        await fulfillment(of: [unavailable], timeout: 0.1)
        secondaryTick = true
        resumed.refreshControlActivityInBackground()
        await fulfillment(of: [found], timeout: 5)
        resumed.stopControlActivity()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(try resumed.localControlActivity(stationOrigin: origin).count, 1)
    }

    func testFreshManagerReviewDiscoversAnotherManagersStopAndRetriesExactCopyAfterRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        let originals = try await stopsByRemovedManager(coordinator!, harness: h)
        let original = try XCTUnwrap(originals.first)
        let body = try parseControlRecord(recordJson: original)
        let confirmations = h.ownerRequests.count
        let page = try await coordinator!.discoverControlActivity(previous: nil, current: { true })
        XCTAssertFalse(page.more)
        XCTAssertEqual(page.after, 1)
        let alert = try XCTUnwrap(coordinator!.localControlActivity().first)
        XCTAssertEqual(alert.body, body)
        XCTAssertTrue(alert.managerReviewRequired)
        let review = try await coordinator!.prepareControlResign(recordID: body.recordId, current: { true })
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        XCTAssertEqual(review.body.signer, "member:manager-a")
        XCTAssertEqual(review.body.revokeSeq, body.revokeSeq)
        XCTAssertNotEqual(review.body.recordId, body.recordId)
        XCTAssertTrue(ControlActivityWindowController.explanation(review, station: coordinator!.relayURL).contains(body.recordId))
        h.approve = false
        do { _ = try await coordinator!.commitControlResign(review, current: { true }); XCTFail("owner denial ignored") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        h.approve = true
        await h.relay.dropControlReply()
        let pending = try await coordinator!.commitControlResign(review, current: { true })
        XCTAssertFalse(pending.stationStored)
        XCTAssertNil(pending.portalMirror)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 2)
        XCTAssertEqual(h.ownerRequests.last, review.request)
        let sent = await h.relay.controls()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, original)
        XCTAssertEqual(sent.last, pending.recordJSON)
        coordinator = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let saved = try await resumed.prepareControlResign(recordID: body.recordId, current: { true })
        XCTAssertEqual(saved.body, review.body)
        XCTAssertEqual(saved.request, review.request)
        XCTAssertTrue(saved.signed)
        h.approve = false
        let delivered = try await resumed.commitControlResign(saved, current: { true })
        XCTAssertTrue(delivered.stationStored)
        XCTAssertEqual(delivered.recordJSON, pending.recordJSON)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 2, "delivery retry cannot reuse or request an approval")
        let final = await h.relay.controls()
        XCTAssertEqual(final, sent)
    }

    func testFreshManagerReviewRejectsRetiredContextChangedHeadAndDefaultOffGateBeforeConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        let id = try parseControlRecord(recordJson: XCTUnwrap(records.first)).recordId
        _ = try await coordinator.discoverControlActivity(previous: nil, current: { true })
        let review = try await coordinator.prepareControlResign(recordID: id, current: { true })
        let confirmations = h.ownerRequests.count
        do { _ = try await coordinator.commitControlResign(review, current: { false }); XCTFail("retired account used") } catch {}
        try await append(["action": "set_roles", "device_id": "manager-b", "roles": ["view"]], harness: h)
        do { _ = try await coordinator.commitControlResign(review, current: { true }); XCTFail("membership movement ignored") }
        catch { XCTAssertEqual(error as? RemoteControlPublicationError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, confirmations, "reject a changed review before asking the owner")
        try coordinator.cancelUnsignedControlResign(recordID: id)
        XCTAssertNil(try coordinator.localControlActivity().first?.replacementRecordID)
        let disabled = try h.coordinator()
        for action in [0, 1] {
            do {
                if action == 0 { _ = try await disabled.discoverControlActivity(previous: nil, current: { true }) }
                else { _ = try await disabled.prepareControlResign(recordID: id, current: { true }) }
                XCTFail("activation gate bypassed")
            } catch { XCTAssertTrue(error is AstationDelegatedControlError) }
        }
        let sent = await h.relay.controls()
        XCTAssertEqual(sent, records)
    }

    func testControlDiscoveryUses64RecordPagesAndRestartsAfterMembershipMovement() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h, count: 65)
        let confirmations = h.ownerRequests.count
        let first = try await coordinator.discoverControlActivity(previous: nil, current: { true })
        XCTAssertEqual(first.after, 64)
        XCTAssertTrue(first.more)
        XCTAssertEqual(try coordinator.localControlActivity().count, 64)
        let last = try await coordinator.discoverControlActivity(previous: first, current: { true })
        XCTAssertEqual(last.after, 65)
        XCTAssertFalse(last.more)
        XCTAssertEqual(try coordinator.localControlActivity().count, 65)
        let reads = await h.relay.syncReads
        XCTAssertEqual(reads, [0, 64])
        try await append(["action": "set_roles", "device_id": "manager-b", "roles": ["view"]], harness: h)
        let restarted = try await coordinator.discoverControlActivity(previous: first, current: { true })
        XCTAssertEqual(restarted.after, 64)
        let restartedReads = await h.relay.syncReads
        XCTAssertEqual(restartedReads, [0, 64, 0])
        XCTAssertEqual(try coordinator.localControlActivity().count, 65)
        XCTAssertEqual(h.ownerRequests.count, confirmations, "discovery never asks for a signature")
    }

    func testControlDiscoveryRejectsUncorrelatedAndRetiredRepliesBeforeImportingEvidence() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        let confirmations = h.ownerRequests.count
        await h.relay.holdNextControlSync()
        var current = true
        let delayed = Task { try await coordinator.discoverControlActivity(previous: nil, current: { current }) }
        for _ in 0..<100 {
            if await h.relay.controlSyncWaiter != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await h.relay.controlSyncWaiter != nil
        XCTAssertTrue(waiting)
        current = false
        await h.relay.releaseControlSync()
        do { _ = try await delayed.value; XCTFail("retired feed response accepted") } catch {}
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        await h.relay.corruptControlSync()
        do { _ = try await coordinator.discoverControlActivity(previous: nil, current: { true }); XCTFail("uncorrelated reply accepted") }
        catch { XCTAssertEqual(error as? RemoteRecoveryTransportError, .invalidResponse) }
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
    }

    func testControlDiscoverySkipsForgedStopsWithoutLosingTheNextValidRecord() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let records = try await stopsByRemovedManager(coordinator, harness: h)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(records.first).utf8)) as? [String: Any])
        forged["sig"] = recoveryTestBase64(Data(repeating: 0, count: 64))
        let invalid = try recoveryTestJSON(forged)
        await h.relay.replaceControlRecords([invalid] + records)
        let confirmations = h.ownerRequests.count
        let page = try await coordinator.discoverControlActivity(previous: nil, current: { true })
        XCTAssertEqual(page.after, 2)
        XCTAssertFalse(page.more)
        let rows = try coordinator.localControlActivity()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.body.recordId, try parseControlRecord(recordJson: XCTUnwrap(records.first)).recordId)
        XCTAssertTrue(rows.first?.managerReviewRequired == true)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
    }

    func testControlDiscoveryRejectsMembershipMovementDuringAFeedRead() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await stopsByRemovedManager(coordinator, harness: h)
        await h.relay.holdNextControlSync()
        let delayed = Task { try await coordinator.discoverControlActivity(previous: nil, current: { true }) }
        for _ in 0..<100 {
            if await h.relay.controlSyncWaiter != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await h.relay.controlSyncWaiter != nil
        XCTAssertTrue(waiting)
        try await append(["action": "set_roles", "device_id": "manager-b", "roles": ["view"]], harness: h)
        await h.relay.releaseControlSync()
        do { _ = try await delayed.value; XCTFail("changed device list accepted") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertTrue(try coordinator.localControlActivity().isEmpty)
    }

    func testControlActivityShowsStoredHostStopAndRejectsARetiredStatusReply() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        _ = try await coordinator.commitHostInterrupt(review, current: { true })
        let confirmations = h.ownerRequests.count
        let rows = try await coordinator.refreshControlActivity(current: { true })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.body.recordId, review.recordID)
        XCTAssertEqual(rows.first?.application, .awaitingApplication)
        XCTAssertTrue(ControlActivityWindowController.description(rows[0]).contains(review.recordID))
        XCTAssertEqual(h.ownerRequests.count, confirmations, "read-only status must never request a signature")
        await h.relay.holdNextControlStatus()
        var current = true
        let delayed = Task { try await coordinator.refreshControlActivity(current: { current }) }
        for _ in 0..<100 {
            if await h.relay.controlStatusWaiter != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await h.relay.controlStatusWaiter != nil
        XCTAssertTrue(waiting)
        current = false
        await h.relay.releaseControlStatus()
        do { _ = try await delayed.value; XCTFail("retired context accepted a Station status") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertNil(try coordinator.localControlActivity().first?.application)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
    }

    func testControlActivityBatchesSavedRecordsAndStillRequiresTheActivationGate() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        for _ in 0..<65 {
            let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
            _ = try await coordinator.commitHostInterrupt(review, current: { true })
        }
        let confirmations = h.ownerRequests.count
        let rows = try await coordinator.refreshControlActivity(current: { true })
        let reads = await h.relay.statusReads
        XCTAssertEqual(reads.map(\.count), [64, 1])
        XCTAssertEqual(rows.count, 65)
        XCTAssertEqual(Set(reads.flatMap { $0 }), Set(rows.map { $0.body.recordId }))
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let disabled = try h.coordinator()
        _ = try await disabled.hostSenderMembership()
        XCTAssertEqual(try disabled.localControlActivity().count, 65)
        do { _ = try await disabled.refreshControlActivity(current: { true }); XCTFail("queried through a disabled gate") }
        catch { XCTAssertTrue(error is AstationDelegatedControlError) }
    }

    func testControlActivityDiscardsReportsWhenMembershipChangesDuringTheRead() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        _ = try await coordinator.commitHostInterrupt(review, current: { true })
        await h.relay.holdNextControlStatus()
        let delayed = Task { try await coordinator.refreshControlActivity(current: { true }) }
        for _ in 0..<100 {
            if await h.relay.controlStatusWaiter != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await h.relay.controlStatusWaiter != nil
        XCTAssertTrue(waiting)
        _ = try await addSecondManager(harness: h)
        await h.relay.releaseControlStatus()
        do { _ = try await delayed.value; XCTFail("accepted status across a membership change") }
        catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertNil(try coordinator.localControlActivity().first?.application)
    }

    func testHostInterruptBindsHistoricalRevokeAfterReadmitAndHostRemoval() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let seq = try await revokedSender(coordinator, harness: h)
        let readmit = try JSONSerialization.jsonObject(with: Data(hostSenderReadmitAction(hostId: "host-a",
            signedAt: AstationRecoveryCoordinator.clock().wallMs).utf8)) as! [String: Any]
        try await append(readmit, harness: h, authorizeNewMembership: { _ in })
        try await append(["action": "remove_host", "host_id": "host-a"], harness: h)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        XCTAssertEqual(review.body.revokeSeq, seq)
        XCTAssertEqual(review.body.principal, "host:host-a")
        XCTAssertNil(review.body.origin); XCTAssertNil(review.body.feedId); XCTAssertNil(review.body.principalKey)
        XCTAssertNil(review.body.interruptRunning); XCTAssertNil(review.body.integrationId)
        XCTAssertEqual(review.request.purpose, .controlRecord)
        XCTAssertTrue(review.request.freshConfirmation)
        XCTAssertTrue(HostSenderAccessWindowController.interruptExplanation(review).contains("before revoke #\(seq)"))
        XCTAssertTrue(HostSenderAccessWindowController.interruptExplanation(review).contains("other Stations"))
        let confirmations = h.ownerRequests.count
        let delivery = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        XCTAssertEqual(h.ownerRequests.last, review.request)
        XCTAssertTrue(delivery.stationStored)
        XCTAssertNil(delivery.portalMirror)
        XCTAssertEqual(try parseControlRecord(recordJson: delivery.recordJSON), review.body)
        XCTAssertTrue(try coordinator.pendingHostInterrupts().isEmpty)
    }

    func testDurableHostStopIsAvailableForNativeCarriageAfterStationStorageAndRestart() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        var committed: [[String]] = []
        coordinator.onControlCommit = {
            do {
                let log = try coordinator.channelMembership(hostID: "host-a")
                committed.append(try coordinator.signedHostControls(for: log))
            } catch { XCTFail("Commit callback must run after the account operation: \(error)") }
        }
        defer { coordinator.onControlCommit = nil }
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        let delivery = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(delivery.stationStored)
        XCTAssertEqual(committed.last, [delivery.recordJSON])
        let log = try coordinator.channelMembership(hostID: "host-a")
        XCTAssertEqual(try coordinator.signedHostControls(for: log), [delivery.recordJSON])
        let restored = try h.coordinator(authorizeDelegatedControl: { _ in })
        XCTAssertEqual(try restored.signedHostControls(for: log), [delivery.recordJSON])
        let disabled = try h.coordinator()
        XCTAssertEqual(try disabled.signedHostControls(for: log), [])
        _ = try await addSecondManager(harness: h)
        _ = try await restored.hostSenderMembership()
        XCTAssertThrowsError(try restored.signedHostControls(for: log), "An old channel head cannot reuse the source")
    }

    func testNativeControlSourceRetainsButDoesNotCarryARemovedManagersSignature() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        let manager = try await addSecondManager(harness: h)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        let delivery = try await coordinator.commitHostInterrupt(review, current: { true })
        try await append(["action": "set_roles", "device_id": "manager-a", "roles": ["control", "view"]],
            harness: h, signer: "manager-b", identity: manager)
        let currentLog = await h.relay.log
        let head = try XCTUnwrap(currentLog).head()
        try await coordinator.refreshChannelMembership(hostID: "host-a", requiredHead: head)
        let log = try coordinator.channelMembership(hostID: "host-a")
        XCTAssertEqual(try coordinator.signedHostControls(for: log), [])
        let activity = try XCTUnwrap(coordinator.localControlActivity().first { $0.body.recordId == delivery.recordID })
        XCTAssertTrue(activity.managerReviewRequired)
        XCTAssertTrue(activity.signed)
    }

    func testHostFanoutLostReplyRetriesOnlyPendingStationWithOneOwnerConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), second = RecoveryMemoryRelay(stationOrigin: "https://second.example"), origin = "https://second.example"
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in },
            additionalControlStations: { _ in [origin: second] })
        _ = try await revokedSender(coordinator!, harness: h)
        await second.replaceLog(try await coordinator!.hostSenderMembership())
        let review = try await coordinator!.prepareHostInterrupt(hostID: "host-a", current: { true })
        XCTAssertEqual(review.additionalStationOrigins, [origin])
        XCTAssertTrue(HostSenderAccessWindowController.interruptExplanation(review).contains(origin))
        let confirmations = h.ownerRequests.count
        await second.dropControlReply()
        let partial = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(partial.stationStored)
        XCTAssertEqual(partial.additionalStations, [origin: false])
        XCTAssertFalse(partial.allStationsStored)
        XCTAssertEqual(try coordinator!.pendingHostInterrupts(), [review])
        XCTAssertTrue(ControlActivityWindowController.description(try XCTUnwrap(coordinator!.localControlActivity().first)).contains(origin + ": Delivery pending"))
        coordinator = nil
        coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        XCTAssertEqual(try coordinator!.pendingHostInterrupts(), [review])
        let delivered = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(delivered.allStationsStored)
        XCTAssertEqual(delivered.recordJSON, partial.recordJSON)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        XCTAssertTrue(try coordinator!.pendingHostInterrupts().isEmpty)
        let firstRecords = await h.relay.controls(), secondRecords = await second.controls()
        XCTAssertEqual(firstRecords, [partial.recordJSON])
        XCTAssertEqual(secondRecords, firstRecords, "a lost reply must not append another record")
        let firstCalls = await h.relay.controlCallCount(), secondCalls = await second.controlCallCount()
        XCTAssertEqual(firstCalls, 1, "a receipt at the primary must prevent another HTTP publication")
        XCTAssertEqual(secondCalls, 2, "only the missing receipt is retried")
    }

    func testPortalDirectoryInterruptRequiresASelectionAndRetainsOnlySignedDestinations() async throws {
        struct Directory: AccountOIDCHTTP {
            let data: Data
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                XCTAssertEqual(request.url?.absoluteString, "https://portal.example/api/v1/stations?limit=100")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
                return (data, 200)
            }
        }
        let h = RecoveryCoordinatorHarness(), origin = "https://second.example", other = "https://third.example"
        let second = RecoveryMemoryRelay(stationOrigin: origin)
        var requests: [String] = []
        func restart() throws -> AstationRecoveryCoordinator {
            try h.coordinator(authorizeDelegatedControl: { _ in }, retainedControlTransport: { requested in
                requests.append(requested)
                guard requested == origin else { throw RemoteChannelError.staleLink }
                return second
            })
        }
        func directory(_ rows: [(String, Bool)], stale: Bool = false, complete: Bool = true) throws -> PortalIntegrationHTTP {
            let date = "2026-11-21T14:30:12.044Z"
            let stations: [[String: Any]] = rows.enumerated().map { index, row in
                ["id": "station-\(index)", "origin": row.0, "name": NSNull(), "builtIn": false, "access": "members",
                 "role": "owner", "status": row.1 ? "active" : "removed", "removedAt": row.1 ? NSNull() as Any : date,
                 "membership": NSNull(), "membershipEndedAt": NSNull(), "integrationsEnabled": row.1, "createdAt": date]
            }
            return try portal(Directory(data: JSONSerialization.data(withJSONObject:
                ["stations": stations, "nextCursor": NSNull(), "stale": stale, "complete": complete])))
        }

        var coordinator = try restart()
        _ = try await revokedSender(coordinator, harness: h)
        await second.replaceLog(try await coordinator.hostSenderMembership())
        let fresh = try directory([(origin, true), (other, true), ("https://removed.example", false)])
        do {
            _ = try await coordinator.prepareHostInterrupt(hostID: "host-a", directory: fresh.stationDirectory,
                chooseStations: { _ in ["https://removed.example"] }, current: { true })
            XCTFail("an unavailable destination was accepted")
        } catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        var current = true
        do {
            _ = try await coordinator.prepareHostInterrupt(hostID: "host-a", directory: {
                let snapshot = try await fresh.stationDirectory()
                current = false
                return snapshot
            }, chooseStations: { _ in XCTFail("account changed during discovery"); return [] }, current: { current })
            XCTFail("stale account prepared a review")
        } catch { XCTAssertEqual(error as? RemoteChannelError, .staleLink) }
        XCTAssertTrue(try coordinator.pendingHostInterrupts().isEmpty)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", directory: fresh.stationDirectory,
            chooseStations: { choice in
                XCTAssertTrue(choice.directoryComplete)
                XCTAssertEqual(choice.candidates, [origin, other])
                XCTAssertTrue(choice.previous.isEmpty)
                XCTAssertEqual(choice.unavailable, ["https://removed.example"])
                return [origin]
            }, current: { true })
        func uncheckedOrigins(_ manager: AstationRecoveryCoordinator) async throws -> [String] {
            let result = try await manager.checkMemberProcesses(current: { true }, transport: { _, _ in
                XCTFail("requested a bearer before server review")
                throw AccountLoginError.changed
            }, progress: { _, _, _ in })
            XCTAssertTrue(result.stations.allSatisfy { $0.serverCount == nil })
            XCTAssertNil(result.hostCount)
            return result.stations.map(\.origin)
        }
        let draftOrigins = try await uncheckedOrigins(coordinator)
        XCTAssertEqual(draftOrigins, [coordinator.relayURL])
        XCTAssertTrue(requests.isEmpty, "discovery and draft preparation must never contact the listed Stations")
        XCTAssertEqual(review.additionalStationOrigins, [origin])
        do {
            _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: origin, current: { true })
            XCTFail("an unsigned draft enrolled a Station in background monitoring")
        } catch RemoteChannelError.staleLink {}
        XCTAssertTrue(requests.isEmpty)
        await second.dropControlReply()
        let first = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertEqual(first.additionalStations, [origin: false])
        let confirmations = h.ownerRequests.count
        coordinator = try restart()
        let pending = try XCTUnwrap(coordinator.pendingHostInterrupts().first)
        let signedOrigins = try await uncheckedOrigins(coordinator)
        XCTAssertEqual(signedOrigins, [coordinator.relayURL, origin].sorted())
        let approval = try await service(coordinator, operations: ["launch", "view"])
        let check = coordinator.serviceAdditionalStationVerifier(for: approval, current: { true }) { _, _ in
            XCTFail("queried a Station before its replica roster was reviewed")
            return second
        }
        do {
            _ = try await check(try await coordinator.serviceMembership())
            XCTFail("service enrollment omitted the signed destination")
        } catch RemoteVerifierGateError.invalidRoster {}
        do {
            _ = try await coordinator.discoverControlActivity(previous: nil, stationOrigin: other, current: { true })
            XCTFail("a directory-only Station was contacted")
        } catch RemoteChannelError.staleLink {}
        let primaryScan = expectation(description: "selected Station checked first")
        let peerScan = expectation(description: "signed destination checked on its own turn")
        coordinator.resumeControlActivity(generation: UUID(), current: { true }) { source, _, _ in
            switch source {
            case coordinator.relayURL: primaryScan.fulfill()
            case origin: peerScan.fulfill()
            default: XCTFail("unexpected monitoring origin")
            }
        }
        await fulfillment(of: [primaryScan], timeout: 5)
        coordinator.refreshControlActivityInBackground()
        await fulfillment(of: [peerScan], timeout: 5)
        coordinator.stopControlActivity()
        let retry = try await coordinator.commitHostInterrupt(pending, current: { true })
        XCTAssertEqual(retry.recordJSON, first.recordJSON)
        XCTAssertEqual(retry.additionalStations, [origin: true])
        XCTAssertEqual(Set(requests), [origin])
        XCTAssertEqual(h.ownerRequests.count, confirmations)

        let omitted = try directory([])
        let removed = try directory([(origin, false)])
        let stale = try directory([(other, true)], stale: true, complete: false)
        let incomplete = try directory([(other, true)], complete: false)
        let outages: [(() async throws -> PortalStationDirectorySnapshot, Bool)] = [
            (omitted.stationDirectory, true), (removed.stationDirectory, true), (stale.stationDirectory, false),
            (incomplete.stationDirectory, false), ({ throw AccountLoginError.unavailable }, false)]
        for (read, complete) in outages {
            let next = try await coordinator.prepareHostInterrupt(hostID: "host-a", directory: read,
                chooseStations: { choice in
                    XCTAssertEqual(choice.directoryComplete, complete)
                    XCTAssertEqual(choice.candidates, [origin])
                    XCTAssertEqual(choice.previous, [origin])
                    return []
                }, current: { true })
            XCTAssertTrue(next.additionalStationOrigins.isEmpty)
            try coordinator.cancelUnsignedHostInterrupt(next)
        }
    }

    func testHostFanoutRejectsAMislabeledTransportBeforeConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), wrongStation = RecoveryMemoryRelay()
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in },
            additionalControlStations: { _ in ["https://second.example": wrongStation] })
        _ = try await revokedSender(coordinator, harness: h)
        let confirmations = h.ownerRequests.count
        do { _ = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true }); XCTFail("misdirected transport") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertTrue(try coordinator.pendingHostInterrupts().isEmpty)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
    }

    func testHostFanoutPrimaryOutageDoesNotPreventAnotherStationStoringTheStop() async throws {
        let h = RecoveryCoordinatorHarness(), second = RecoveryMemoryRelay(stationOrigin: "https://second.example"), origin = "https://second.example"
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        _ = try await revokedSender(coordinator, harness: h)
        await second.replaceLog(try await coordinator.hostSenderMembership())
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        // Signing refreshes authority, then the primary goes away on the first publish.
        await h.relay.dropControlReply(disableEntries: true)
        var result = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertFalse(result.stationStored)
        XCTAssertEqual(result.additionalStations, [origin: true])
        result = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertFalse(result.allStationsStored)
        XCTAssertEqual(result.additionalStations, [origin: true])
        await h.relay.setEntriesUnavailable(false)
        result = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(result.allStationsStored)
    }

    func testHostFanoutMissingRosterRetainsTargetsAndCannotRedirectASavedReview() async throws {
        let h = RecoveryCoordinatorHarness(), second = RecoveryMemoryRelay(stationOrigin: "https://second.example")
        let third = RecoveryMemoryRelay(stationOrigin: "https://unreviewed.example")
        let origin = "https://second.example", other = "https://unreviewed.example"
        var targets: [String: RemoteControlStationTransport] = [origin: second]
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in targets })
        _ = try await revokedSender(coordinator, harness: h)
        await second.replaceLog(try await coordinator.hostSenderMembership())
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        var altered = review
        altered.additionalStationOrigins = [other]
        let confirmations = h.ownerRequests.count
        do { _ = try await coordinator.commitHostInterrupt(altered, current: { true }); XCTFail("changed review") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        targets = [other: third]
        let partial = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(partial.stationStored)
        XCTAssertEqual(partial.additionalStations, [origin: false], "an absent target remains pending")
        let unreviewedRecords = await third.controls()
        XCTAssertTrue(unreviewedRecords.isEmpty)
        targets = [origin: second]
        let delivered = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(delivered.allStationsStored)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
    }

    func testHostFanoutRechecksManagerAuthorityAtEachStation() async throws {
        let h = RecoveryCoordinatorHarness(), second = RecoveryMemoryRelay(stationOrigin: "https://second.example"), origin = "https://second.example"
        let coordinator = try h.coordinator(authorizeDelegatedControl: { _ in }, additionalControlStations: { _ in [origin: second] })
        _ = try await revokedSender(coordinator, harness: h)
        let log = try await coordinator.hostSenderMembership()
        let other = try await addSecondManager(harness: h)
        let currentLog = await h.relay.log
        let fresh = try XCTUnwrap(currentLog)
        await second.replaceLog(fresh)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        // The secondary has a newer, valid demotion; a stale primary cannot authorize delivery there.
        let demoted = fresh.snapshot()
        let draft = try demoted.draftEntry(signer: "manager-b", signedAt: AstationRecoveryCoordinator.clock().wallMs,
            actionJson: "{\"action\":\"set_roles\",\"device_id\":\"manager-a\",\"roles\":[\"control\",\"view\"]}")
        let provider = AstationMembershipKeyProvider(identity: other, keyID: "manager-b", publicKey: try other.remotePublicKeys().signing)
        let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: draft, keyID: "manager-b")
        let entry = String(decoding: try JSONSerialization.data(withJSONObject: [
            "body": JSONSerialization.jsonObject(with: Data(draft.utf8)),
            "sig": recoveryTestBase64(provider.sign(request: request))]), as: UTF8.self)
        _ = try demoted.extend(entries: [entry], now: AstationRecoveryCoordinator.clock())
        await second.replaceLog(demoted)
        let result = try await coordinator.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertEqual(result.additionalStations, [origin: false])
        let records = await second.controls()
        XCTAssertTrue(records.isEmpty)
        XCTAssertGreaterThan(demoted.head().seq, log.head().seq)
    }

    func testHostInterruptUnsignedReviewAndLostReceiptRecoverAcrossRestart() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator!, harness: h)
        let review = try await coordinator!.prepareHostInterrupt(hostID: "host-a", current: { true })
        let confirmations = h.ownerRequests.count
        coordinator = nil
        coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        XCTAssertEqual(try coordinator!.pendingHostInterrupts(), [review])
        await h.relay.dropControlReply()
        let pending = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertFalse(pending.stationStored)
        XCTAssertThrowsError(try coordinator!.cancelUnsignedHostInterrupt(review))
        coordinator = nil
        coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        XCTAssertEqual(try coordinator!.pendingHostInterrupts(), [review])
        let result = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertEqual(result.recordJSON, pending.recordJSON)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
        let records = await h.relay.controls()
        XCTAssertEqual(records, [pending.recordJSON])
    }

    func testHostInterruptBackgroundRetryNeedsNoPortalRevokeOrAnotherConfirmation() async throws {
        let h = RecoveryCoordinatorHarness(), portalTransport = ServiceApprovalPortal()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator!, harness: h)
        let review = try await coordinator!.prepareHostInterrupt(hostID: "host-a", current: { true })
        await h.relay.dropControlReply()
        let pending = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertFalse(pending.stationStored)
        let confirmations = h.ownerRequests.count
        coordinator = nil
        let resumed = try h.coordinator(authorizeDelegatedControl: { _ in })
        let delivered = expectation(description: "host interruption background retry")
        resumed.onControlDelivery = { result in
            XCTAssertEqual(result.recordJSON, pending.recordJSON)
            XCTAssertTrue(result.stationStored)
            XCTAssertNil(result.portalMirror)
            delivered.fulfill()
        }
        resumed.resumeControlDelivery(portal: try portal(portalTransport), current: { true })
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let posts = await portalTransport.count()
        XCTAssertEqual(posts, 0)
    }

    func testHostInterruptDenialStaleContextAndChangedReviewNeverSend() async throws {
        let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator, harness: h)
        let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
        h.approve = false
        do { _ = try await coordinator.commitHostInterrupt(review, current: { true }); XCTFail("denied") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .confirmationRequired) }
        h.approve = true
        do { _ = try await coordinator.commitHostInterrupt(review, current: { false }); XCTFail("stale account") } catch {}
        var body = review.body; body.principal = "host:another-host"
        let changed = AstationRecoveryCoordinator.HostInterruptReview(stationOrigin: review.stationOrigin, body: body, request: review.request)
        let confirmations = h.ownerRequests.count
        do { _ = try await coordinator.commitHostInterrupt(changed, current: { true }); XCTFail("changed display") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .requiresReview) }
        XCTAssertEqual(h.ownerRequests.count, confirmations)
        let records = await h.relay.controls()
        XCTAssertTrue(records.isEmpty)
        try coordinator.cancelUnsignedHostInterrupt(review)
        XCTAssertTrue(try coordinator.pendingHostInterrupts().isEmpty)
    }

    func testHostInterruptAuthorityLossDuringConfirmationAndChangedHeadNeedFreshReview() async throws {
        for demote in [false, true] {
            let h = RecoveryCoordinatorHarness(), coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
            _ = try await revokedSender(coordinator, harness: h)
            let manager = try await addSecondManager(harness: h)
            let review = try await coordinator.prepareHostInterrupt(hostID: "host-a", current: { true })
            h.ownerConfirmation = { _ in
                try await self.append(demote
                    ? ["action": "set_roles", "device_id": "manager-a", "roles": ["control", "view"]]
                    : ["action": "remove_host", "host_id": "host-a"], harness: h, signer: "manager-b", identity: manager)
                return true
            }
            do { _ = try await coordinator.commitHostInterrupt(review, current: { true }); XCTFail("changed membership") } catch {}
            let records = await h.relay.controls()
            XCTAssertTrue(records.isEmpty)
            XCTAssertEqual(try coordinator.pendingHostInterrupts(), [review])
            try coordinator.cancelUnsignedHostInterrupt(review)
        }
    }

    func testHostInterruptUncertainSignatureWriteResumesWithoutAnotherConfirmation() async throws {
        let h = RecoveryCoordinatorHarness()
        var coordinator: AstationRecoveryCoordinator? = try h.coordinator(authorizeDelegatedControl: { _ in })
        _ = try await revokedSender(coordinator!, harness: h)
        let review = try await coordinator!.prepareHostInterrupt(hostID: "host-a", current: { true })
        let carriageLog = try coordinator!.channelMembership(hostID: "host-a")
        h.store.failOnControlSignature = true
        let confirmations = h.ownerRequests.count
        do { _ = try await coordinator!.commitHostInterrupt(review, current: { true }); XCTFail("uncertain write") }
        catch { XCTAssertEqual(error as? RemoteRecoveryError, .storageUncertain) }
        XCTAssertThrowsError(try coordinator!.signedHostControls(for: carriageLog), "An uncertain signature must not escape over a native channel")
        let records = await h.relay.controls()
        XCTAssertTrue(records.isEmpty)
        coordinator = nil
        h.ownerConfirmation = nil
        coordinator = try h.coordinator(authorizeDelegatedControl: { _ in })
        let result = try await coordinator!.commitHostInterrupt(review, current: { true })
        XCTAssertTrue(result.stationStored)
        XCTAssertEqual(h.ownerRequests.count, confirmations + 1)
    }
}
