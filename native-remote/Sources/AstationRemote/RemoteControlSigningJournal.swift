import AtemClient
import CryptoKit
import Foundation

/// The device keeps every possibly signed stop under the member key, across
/// ordinary delivery, manager re-signs, recovery copies and Station origins.
@MainActor
public final class RemoteControlSigningJournal {
    private struct Entry: Codable {
        let body: String
        var record: String?
    }

    private struct Barrier: Codable {
        let context: RemoteControlRecoveryContext
        let revision: UInt64
        let records: [String]
        let drafts: [String]
        let signedRecords: [String]
        let challengeJSON: String
        let slot: String
        var exposedReport: String?
        var supersededBy: RemoteControlRecoveryContext?
        var abandoned: Bool?
        var published: Bool?
        var hasTerminalReceipt: Bool { abandoned == true || published == true }
        var isHeld: Bool { supersededBy == nil && !hasTerminalReceipt }

        func request(log: MembershipLog, id: Data, since: UInt64, member: String, nowMs: UInt64) throws -> SignerReportRequest {
            try SignerReportRequest(log: log, challengeJson: challengeJSON, signer: "member:" + member,
                slot: slot, origin: context.stationOrigin, journal: SignerJournalView(id: RemoteRecoveryKit.base64URL(id),
                    since: since, revision: revision, records: records, drafts: drafts), keyId: member, nowMs: nowMs)
        }
    }

    private struct Checkpoint: Codable {
        var version: Int
        let account: String
        let genesis: String
        let member: String
        let algorithm: String
        let key: Data
        let id: Data
        let since: UInt64
        var revision: UInt64
        var entries: [String: Entry]
        var barriers: [String: Barrier]?
        // First attachment revision for each loaded SDK process. Only a
        // journal created with tracking has an attachment at revision zero.
        var processAttachments: [String: UInt64]?
    }

    private let read: () throws -> Data?
    private let persist: (Data) throws -> Void
    private let key: PublicKeyData
    private let log: MembershipLog
    private var saved: Checkpoint
    private var expected: Data?
    private var operating = false
    private var uncertain = false

    public var storageScope: String {
        let keyScope = Self.keyScope(key)
        return Self.scope(keyScope: keyScope, account: saved.account, genesis: saved.genesis, memberID: saved.member)
    }

    private static func keyScope(_ key: PublicKeyData) -> String {
        let algorithm = key.alg == .p256 ? "p256" : "ed25519"
        return hashFields(fields: [Data("astation-stop-author-v1".utf8), Data(algorithm.utf8), key.raw])
    }

    private static func scope(keyScope: String, account: String, genesis: String, memberID: String) -> String {
        hashFields(fields: [keyScope, account, genesis, memberID].map { Data($0.utf8) })
    }

    public var id: Data { saved.id }
    public var revision: UInt64 { saved.revision }
    /// Draft preparation can attach several processes before the first signing
    /// pin. A missing pin must still refuse a journal with any signing history.
    public var canEstablishInitialPin: Bool {
        let attachments = saved.processAttachments?.values.filter { $0 > 0 }.count ?? 0
        return saved.entries.isEmpty && saved.barriers?.isEmpty == true && saved.revision == UInt64(attachments)
    }

    public convenience init(log: MembershipLog, memberID: String) throws {
        guard let key = log.member(deviceId: memberID)?.authKey else {
            throw RemoteControlPublicationError.requiresReview
        }
        let keyScope = Self.keyScope(key)
        let scope = Self.scope(keyScope: keyScope, account: log.accountId(), genesis: log.genesisHash(), memberID: memberID)
        let store = try RemoteRecoveryStore(controlJournalScope: scope, keyScope: keyScope)
        try self.init(log: log, memberID: memberID, read: { try store.read() }, persist: { try store.write($0) })
    }

    /// The backing store must hold the key's interprocess lock until this journal is released.
    public init(log: MembershipLog, memberID: String, read: @escaping () throws -> Data?,
                persist: @escaping (Data) throws -> Void) throws {
        guard log.frozen() == nil, let member = log.member(deviceId: memberID), member.kind == "native" else {
            throw RemoteControlPublicationError.requiresReview
        }
        self.log = log
        self.read = read
        self.persist = persist
        key = member.authKey
        let algorithm = key.alg == .p256 ? "p256" : "ed25519"
        expected = try read()
        if let bytes = expected {
            guard bytes.count <= 8_388_608 else { throw RemoteControlPublicationError.invalidCheckpoint }
            saved = try PropertyListDecoder().decode(Checkpoint.self, from: bytes)
            guard (1...3).contains(saved.version), (saved.version == 1) == (saved.barriers == nil),
                  (saved.version == 3) == (saved.processAttachments != nil),
                  (saved.barriers?.count ?? 0) <= 64, saved.account == log.accountId(), saved.genesis == log.genesisHash(),
                  saved.member == memberID, saved.algorithm == algorithm, saved.key == key.raw,
                  saved.id.count == 16, saved.since > 0, saved.since <= log.head().seq,
                  saved.revision <= 9_007_199_254_740_991, saved.entries.count <= 4096 else {
                throw RemoteControlPublicationError.invalidCheckpoint
            }
            var minimumRevision = UInt64(saved.entries.count)
            for (id, entry) in saved.entries {
                let body = try checkedBody(entry.body)
                guard body.recordId == id else { throw RemoteControlPublicationError.invalidCheckpoint }
                if let record = entry.record {
                    try checkRecord(record, bodyJSON: entry.body)
                    minimumRevision += 1
                }
            }
            for (origin, barrier) in saved.barriers ?? [:] {
                try validate(barrier, origin: origin)
                minimumRevision += 1
            }
            if let attachments = saved.processAttachments {
                guard !attachments.isEmpty, Set(attachments.values).count == attachments.count,
                      attachments.allSatisfy({ process, revision in
                          RemoteRecoveryKit.decodeBase64URL(process, count: 16) != nil && revision <= saved.revision
                      }) else { throw RemoteControlPublicationError.invalidCheckpoint }
                minimumRevision += UInt64(attachments.values.filter { $0 > 0 }.count)
            }
            guard saved.revision >= minimumRevision else { throw RemoteControlPublicationError.invalidCheckpoint }
            try attachCurrentProcess()
        } else {
            saved = Checkpoint(version: 3, account: log.accountId(), genesis: log.genesisHash(),
                member: memberID, algorithm: algorithm, key: key.raw,
                id: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, since: log.head().seq,
                revision: 0, entries: [:], barriers: [:], processAttachments: [verifierReportProcess(): 0])
        }
    }

    private func attachCurrentProcess() throws {
        let process = verifierReportProcess()
        guard saved.processAttachments?[process] == nil else { return }
        guard saved.revision < 9_007_199_254_740_991 else { throw RemoteControlPublicationError.full }
        var next = saved
        next.version = 3
        next.revision += 1
        next.barriers = saved.barriers ?? [:]
        var attachments = saved.processAttachments ?? [:]
        attachments[process] = next.revision
        next.processAttachments = attachments
        try write(next)
    }

    private func checkedBody(_ json: String) throws -> ControlRecordBody {
        let request = try RemoteConfirmedSigner.controlRequest(bodyJSON: json, keyID: saved.member)
        let placeholder = RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))
        let body = try parseControlRecord(recordJson: "{\"body\":" + json + ",\"sig\":\"" + placeholder + "\"}")
        guard request.bodyJson == json, body.accountId == saved.account, body.genesisHash == saved.genesis else {
            throw RemoteControlPublicationError.invalidRecord
        }
        return body
    }

    private func validate(_ barrier: Barrier, origin: String) throws {
        let context = barrier.context
        try context.validate()
        guard context.stationOrigin == origin, context.accountID == saved.account, context.genesisHash == saved.genesis,
              barrier.revision > 0, barrier.revision <= saved.revision,
              barrier.signedRecords.count == barrier.records.count else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        guard barrier.abandoned != true || barrier.published != true else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        if let successor = barrier.supersededBy {
            try successor.validate()
            guard !barrier.hasTerminalReceipt, successor.accountID == context.accountID, successor.genesisHash == context.genesisHash,
                  successor.stationOrigin == origin, successor.generation > context.generation,
                  successor.planID != context.planID else { throw RemoteControlPublicationError.invalidCheckpoint }
        }
        let challenge = try parseSignerReportChallenge(challengeJson: barrier.challengeJSON)
        guard challenge.slot == barrier.slot, challenge.signer == "member:" + saved.member, challenge.origin == origin,
              challenge.recovery == context.signerReportRecovery else { throw RemoteControlPublicationError.invalidCheckpoint }
        if let report = barrier.exposedReport {
            try verifySignedObject(json: report, key: key)
        }
        var bodies: [String: String] = [:]
        for group in [barrier.records, barrier.drafts] {
            var seen = Set<String>()
            for json in group {
                let body = try checkedBody(json)
                guard try signerReportPlanRecord(log: log, bodyJson: json, member: "member:" + saved.member, origin: origin) == .inPlan,
                      seen.insert(body.recordId).inserted, bodies[body.recordId].map({ $0 == json }) ?? true else {
                    throw RemoteControlPublicationError.invalidCheckpoint
                }
                bodies[body.recordId] = json
            }
        }
        for (body, record) in zip(barrier.records, barrier.signedRecords) {
            try checkRecord(record, bodyJSON: body)
        }
    }

    private func checkRecord(_ record: String, bodyJSON: String) throws {
        guard try signedObjectInfo(json: record).bodyJcs == bodyJSON else { throw RemoteControlPublicationError.invalidRecord }
        try verifySignedObject(json: record, key: key)
    }

    private func checkStorage() throws {
        guard !uncertain else { throw RemoteControlPublicationError.storageUncertain }
        do {
            guard try read() == expected else { throw RemoteRecoveryStoreError.changed }
        } catch { uncertain = true; throw error }
    }

    private func append(id: String, entry: Entry) throws {
        var next = saved
        next.entries[id] = entry
        guard next.revision < 9_007_199_254_740_991, next.entries.count <= 4096 else {
            throw RemoteControlPublicationError.full
        }
        next.revision += 1
        try write(next)
    }

    /// Pin a newly created journal in the account checkpoint before signing with it.
    public func establish() throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        if expected == nil { try write(saved) }
    }

    private func write(_ next: Checkpoint) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(next)
        guard bytes.count <= 8_388_608 else { throw RemoteControlPublicationError.full }
        try checkStorage()
        do {
            try persist(bytes)
            guard try read() == bytes else { throw RemoteRecoveryStoreError.changed }
        } catch { uncertain = true; throw error }
        saved = next
        expected = bytes
    }

    public func inventory(stationOrigin: String, outboxes: [RemoteControlPublication],
                          recoveryCopies: [RemoteControlRecoveryPublication]) throws -> RemoteControlAuthorInventory {
        guard !operating else { throw RemoteControlPublicationError.busy }
        guard PortalIntegrationRecord.validOrigin(stationOrigin) else { throw RemoteControlPublicationError.invalidRecord }
        try checkStorage()
        var result = RemoteControlAuthorInventory(origin: stationOrigin, log: log,
            member: saved.member, key: key)
        for entry in saved.entries.values {
            try result.retain(body: checkedBody(entry.body), json: entry.body, key: key,
                record: entry.record, possiblySigned: true)
        }
        for barrier in (saved.barriers ?? [:]).values {
            for (json, record) in zip(barrier.records, barrier.signedRecords) {
                try result.retain(body: checkedBody(json), json: json, key: key, record: record, possiblySigned: true)
            }
            // A held draft cannot have been cancelled. An ended plan no longer
            // attests that its unsigned drafts are outstanding.
            if barrier.isHeld {
                if barrier.context.stationOrigin == stationOrigin { result.heldPlan = barrier.context }
                for json in barrier.drafts {
                    try result.retain(body: checkedBody(json), json: json, key: key, record: nil,
                        possiblySigned: false, unsignedDraft: true)
                }
            }
        }
        for box in outboxes { try box.collectAuthorEvidence(into: &result) }
        for copies in recoveryCopies { try copies.collectAuthorEvidence(into: &result) }
        try checkStorage()
        return result
    }

    /// The application can only obtain this request through a Station-issued challenge.
    public struct ReportReview {
        public let request: SignRequest
        fileprivate let context: RemoteControlRecoveryContext
    }

    public struct ReportKeyRequest {
        public let request: SignRequest
        fileprivate init(_ request: SignRequest) { self.request = request }
    }

    public struct Submission: Sendable {
        public let context: RemoteControlRecoveryContext
        let report: String
        let records: [String]
    }

    public func reviewReport(_ issued: RemoteStationSignerChallenge, log: MembershipLog,
        preview: RemoteControlAuthorInventory, nowMs: UInt64, outboxes: [RemoteControlPublication],
        recoveryCopies: [RemoteControlRecoveryPublication]) throws -> ReportReview {
        let request = try holdForReport(context: issued.context, challengeJSON: issued.json, log: log,
            slot: issued.challenge.slot, nowMs: nowMs, outboxes: outboxes, recoveryCopies: recoveryCopies, preview: preview)
        return ReportReview(request: request, context: issued.context)
    }

    public func finishReport(_ review: ReportReview, log: MembershipLog, nowMs: () -> UInt64,
        current: () -> Bool, sign: (ReportKeyRequest) throws -> Data) throws -> Submission {
        let result = try finishReport(context: review.context, reviewed: review.request, log: log,
            nowMs: nowMs, current: current, sign: { try sign(ReportKeyRequest($0)) })
        return Submission(context: review.context, report: result.report, records: result.records)
    }

    /// A lost HTTP reply may be recovered after lease expiry. Only already exposed bytes
    /// qualify. Recheck the signature and frozen records at their original challenge.
    public func exposedSubmission(for context: RemoteControlRecoveryContext, log: MembershipLog) throws -> Submission? {
        try checkStorage()
        guard let barrier = saved.barriers?[context.stationOrigin], barrier.isHeld,
              let report = barrier.exposedReport, barrier.context.planID == context.planID,
              barrier.context.generation == context.generation, barrier.context.candidateFeedID == context.candidateFeedID,
              barrier.context.sourceHash == context.sourceHash, barrier.context.accountID == context.accountID,
              barrier.context.genesisHash == context.genesisHash, log.accountId() == context.accountID,
              log.genesisHash() == context.genesisHash, context.membershipHead == log.head(),
              barrier.context.membershipHead == log.head() else { return nil }
        let challenge = try parseSignerReportChallenge(challengeJson: barrier.challengeJSON)
        let checked = try verifySignerReport(log: log, reportJson: report, expectedChallengeJson: barrier.challengeJSON,
            exportedRecordsJson: barrier.signedRecords, nowMs: challenge.issuedAt)
        guard checked.atHead, checked.journal.revision == barrier.revision, checked.journal.id == RemoteRecoveryKit.base64URL(id),
              checked.journal.since == saved.since else { throw RemoteControlPublicationError.invalidCheckpoint }
        return Submission(context: barrier.context, report: report, records: barrier.signedRecords)
    }

    /// Called under the member-key lock with every outbox from the locked account.
    /// Only the trusted collector may supply the Station's authenticated review and challenge.
    /// The hold is durable before the SDK signing request leaves the journal.
    func holdForReport(context: RemoteControlRecoveryContext, challengeJSON: String, log: MembershipLog,
                       slot: String, nowMs: UInt64, outboxes: [RemoteControlPublication],
                       recoveryCopies: [RemoteControlRecoveryPublication], preview: RemoteControlAuthorInventory? = nil) throws -> SignRequest {
        try context.validate()
        let origin = context.stationOrigin
        guard !operating, context.accountID == saved.account, context.genesisHash == saved.genesis,
              log.accountId() == saved.account, log.genesisHash() == saved.genesis,
              log.head() == context.membershipHead, log.member(deviceId: saved.member)?.authKey == key else {
            throw RemoteControlPublicationError.requiresReview
        }
        let challenge = try parseSignerReportChallenge(challengeJson: challengeJSON)
        guard challenge.recovery == context.signerReportRecovery else { throw RemoteControlPublicationError.requiresReview }
        let evidence = try inventory(stationOrigin: origin, outboxes: outboxes, recoveryCopies: recoveryCopies)
        guard evidence.missingSignatureBodies.isEmpty else { throw RemoteControlPublicationError.requiresReview }
        let records = evidence.reportRecordBodies, drafts = evidence.reportDraftBodies
        if let preview {
            guard preview.origin == origin, preview.account == saved.account, preview.genesis == saved.genesis,
                  preview.member == saved.member, preview.key == key, preview.signedRecords == evidence.signedRecords,
                  preview.reportDraftBodies == drafts else { throw RemoteControlPublicationError.requiresReview }
        }
        var heldRevision: UInt64?
        if let prior = saved.barriers?[origin] {
            // Never replace a different plan using a caller-supplied generation,
            // or mistake a restored outbox for the disappearance of a frozen draft.
            if prior.hasTerminalReceipt {
                guard context.generation > prior.context.generation, context.planID != prior.context.planID else {
                    throw RemoteControlPublicationError.requiresReview
                }
            } else if let successor = prior.supersededBy {
                guard context.generation >= successor.generation,
                      context.generation != successor.generation ||
                        (context.planID == successor.planID && context.candidateFeedID == successor.candidateFeedID &&
                         context.sourceHash == successor.sourceHash) else {
                    throw RemoteControlPublicationError.requiresReview
                }
            } else {
                guard prior.context.planID == context.planID, prior.context.generation == context.generation,
                      prior.context.candidateFeedID == context.candidateFeedID, prior.context.sourceHash == context.sourceHash,
                      prior.records == records, prior.drafts == drafts else { throw RemoteControlPublicationError.requiresReview }
                // The held revision identifies the frozen record and draft sets.
                // Renewing the challenge advances storage without moving that cut.
                heldRevision = prior.revision
                if prior.context == context, prior.slot == slot, prior.challengeJSON == challengeJSON {
                    return try prior.request(log: log, id: id, since: saved.since, member: saved.member, nowMs: nowMs).signRequest()
                }
            }
        }
        guard saved.revision < 9_007_199_254_740_991,
              saved.barriers?[origin] != nil || (saved.barriers?.count ?? 0) < 64 else {
            throw RemoteControlPublicationError.full
        }
        let revision = saved.revision + 1
        let barrier = Barrier(context: context, revision: heldRevision ?? revision, records: records, drafts: drafts,
            signedRecords: evidence.signedRecords, challengeJSON: challengeJSON, slot: slot)
        // Reject malformed, expired or unauthorized requests before acquiring a hold.
        let request = try barrier.request(log: log, id: id, since: saved.since, member: saved.member, nowMs: nowMs)
        // Both supported algorithms produce 64-byte signatures. Size the canonical
        // HTTP body before committing a hold that this Station could never accept.
        let signature = RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))
        let report = #"{"body":\#(request.bodyJson()),"sig":"\#(signature)"}"#
        _ = try RemoteRecoveryHTTP.submissionBytes(report: report, records: barrier.signedRecords)
        operating = true
        defer { operating = false }
        var next = saved
        next.revision = revision
        next.barriers = (next.barriers ?? [:]).merging([origin: barrier]) { _, new in new }
        try write(next)
        guard let committed = saved.barriers?[origin] else { throw RemoteControlPublicationError.storageUncertain }
        return try committed.request(log: log, id: id, since: saved.since, member: saved.member, nowMs: nowMs).signRequest()
    }

    /// The trusted owner-confirmation adapter supplies a one-shot signature of the
    /// exact reviewed request. No signed bytes leave before exposure is durable.
    func finishReport(context: RemoteControlRecoveryContext, reviewed: SignRequest, log: MembershipLog,
                      nowMs: () -> UInt64, current: () -> Bool,
                      sign: (SignRequest) throws -> Data) throws -> (report: String, records: [String]) {
        guard !operating else { throw RemoteControlPublicationError.busy }
        operating = true
        defer { operating = false }
        try checkStorage()
        guard current(), let barrier = saved.barriers?[context.stationOrigin], barrier.context == context, barrier.isHeld,
              context.accountID == log.accountId(), context.genesisHash == log.genesisHash(),
              context.membershipHead == log.head(), log.member(deviceId: saved.member)?.authKey == key else {
            throw RemoteControlPublicationError.requiresReview
        }
        let request = try barrier.request(log: log, id: id, since: saved.since, member: saved.member, nowMs: nowMs())
        guard request.signRequest() == reviewed else { throw RemoteControlPublicationError.requiresReview }
        let report: String
        if let exposed = barrier.exposedReport { report = exposed }
        else { report = try request.finish(signature: sign(reviewed)) }
        let checked = try verifySignerReport(log: log, reportJson: report, expectedChallengeJson: barrier.challengeJSON,
            exportedRecordsJson: barrier.signedRecords, nowMs: nowMs())
        guard current(), log.head() == context.membershipHead, checked.journal.revision == barrier.revision,
              try signedObjectInfo(json: report).bodyJcs == request.bodyJson() else {
            throw RemoteControlPublicationError.requiresReview
        }
        try checkStorage()
        if barrier.exposedReport == nil {
            var next = saved
            guard next.revision < 9_007_199_254_740_991 else { throw RemoteControlPublicationError.full }
            next.revision += 1
            next.barriers?[context.stationOrigin]?.exposedReport = report
            try write(next)
        }
        guard current(), log.frozen() == nil, log.head() == context.membershipHead,
              nowMs() < (try parseSignerReportChallenge(challengeJson: barrier.challengeJSON)).expiresAt else {
            throw RemoteControlPublicationError.requiresReview
        }
        return (report, barrier.signedRecords)
    }

    /// Only the HTTPS transport can attest the origin of the prepared successor.
    /// Keep the successor as a generation floor and retain all frozen signatures,
    /// including those that came only from an outbox at the time of the report.
    public func reconcileSupersedingPlan(_ review: RemoteControlRecoveryPreparation) throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        let successor = review.context, origin = successor.stationOrigin
        guard var barrier = saved.barriers?[origin], barrier.isHeld else { return }
        guard review.receivedFromStation, successor.accountID == saved.account, successor.genesisHash == saved.genesis,
              successor.generation > barrier.context.generation, successor.planID != barrier.context.planID else { return }
        barrier.supersededBy = successor
        try endBarrier(barrier)
    }

    public func reconcileAbandonment(_ proof: RemoteStationAbandonment) throws {
        try reconcilePlanEnd(proof.receipt)
    }

    public func reconcilePlanEnd(_ proof: RemoteStationPlanEnd) throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        let held = proof.context
        guard var barrier = saved.barriers?[held.stationOrigin], barrier.context == held, barrier.isHeld else {
            throw RemoteControlPublicationError.requiresReview
        }
        switch proof.outcome {
        case .abandoned: barrier.abandoned = true
        case .published: barrier.published = true
        }
        try endBarrier(barrier)
    }

    private func endBarrier(_ barrier: Barrier) throws {
        operating = true
        defer { operating = false }
        var next = saved
        var increments: UInt64 = 1
        for (json, record) in zip(barrier.records, barrier.signedRecords) {
            let id = try checkedBody(json).recordId
            if let prior = next.entries[id] {
                guard prior.body == json else { throw RemoteControlPublicationError.requiresReview }
                if prior.record != nil { continue }
                increments += 1
            } else { increments += 2 }
            next.entries[id] = Entry(body: json, record: record)
        }
        guard next.entries.count <= 4096, next.revision <= 9_007_199_254_740_991 - increments else {
            throw RemoteControlPublicationError.full
        }
        next.barriers?[barrier.context.stationOrigin] = barrier
        next.revision += increments
        try write(next)
    }

    /// Holds the interprocess lock through draft creation or cancellation.
    /// A service stop names one Station. A host interrupt may reach any of them.
    func withPermittedStopChange<T>(bodyJSON: String, _ change: () throws -> T) throws -> T {
        try requireStopChange(bodyJSON: bodyJSON)
        try establish()
        operating = true
        defer { operating = false }
        return try change()
    }

    public func requireStopChange(bodyJSON: String) throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        _ = try checkedBody(bodyJSON)
        try requirePermitted(bodyJSON: bodyJSON)
    }

    private func requirePermitted(bodyJSON: String) throws {
        guard let barriers = saved.barriers else { return }
        for origin in barriers.keys.sorted() {
            guard let barrier = barriers[origin], barrier.isHeld else { continue }
            if try signerReportPlanRecord(log: log, bodyJson: bodyJSON, member: "member:" + saved.member, origin: origin) == .inPlan {
                throw RemoteControlRecoveryHold(context: barrier.context)
            }
        }
    }

    public func requireStopChange(origin: String?) throws {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        try requirePermitted(origin: origin)
    }

    private func requirePermitted(origin: String?) throws {
        guard let barriers = saved.barriers else { return }
        if let origin {
            if let barrier = barriers[origin], barrier.isHeld {
                throw RemoteControlRecoveryHold(context: barrier.context)
            }
        } else if let station = barriers.keys.sorted().first(where: { barriers[$0]?.isHeld == true }),
                  let barrier = barriers[station] {
            throw RemoteControlRecoveryHold(context: barrier.context)
        }
    }

    enum SigningEvidence {
        case untouched
        case attempted
        case signed(String)
    }

    func evidence(bodyJSON: String, publicKey: PublicKeyData) throws -> SigningEvidence {
        guard !operating else { throw RemoteControlPublicationError.busy }
        try checkStorage()
        let body = try checkedBody(bodyJSON)
        guard key == publicKey else { throw RemoteControlPublicationError.requiresReview }
        guard let entry = saved.entries[body.recordId] else { return .untouched }
        guard entry.body == bodyJSON else { throw RemoteControlPublicationError.requiresReview }
        if let record = entry.record { return .signed(record) }
        return .attempted
    }

    func sign(bodyJSON: String, publicKey: PublicKeyData, makeRecord: () throws -> String) throws -> String {
        guard !operating else { throw RemoteControlPublicationError.busy }
        operating = true
        defer { operating = false }
        try checkStorage()
        let body = try checkedBody(bodyJSON)
        guard publicKey == key else { throw RemoteControlPublicationError.requiresReview }
        if let entry = saved.entries[body.recordId] {
            guard entry.body == bodyJSON else { throw RemoteControlPublicationError.requiresReview }
            if let record = entry.record { return record }
        }
        try requirePermitted(bodyJSON: bodyJSON)
        if expected == nil { try write(saved) }
        // Commit each attempt before invoking the key, including an exact retry.
        try append(id: body.recordId, entry: Entry(body: bodyJSON))
        let record = try makeRecord()
        try checkRecord(record, bodyJSON: bodyJSON)
        try append(id: body.recordId, entry: Entry(body: bodyJSON, record: record))
        return record
    }
}
