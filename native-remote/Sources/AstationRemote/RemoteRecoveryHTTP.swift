import AtemClient
import CryptoKit
import Foundation

public enum RemoteRecoveryTransportError: LocalizedError {
    case authenticationRequired, registrationRequired, permissionRequired, accessDenied, recordNotFound, unavailable, invalidResponse, insecureURL

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "Authorize your Agora.Build account for this Station, then retry."
        case .registrationRequired: return "This Mac has not registered with the selected Station. Reconnect to the Station, then retry account security setup."
        case .permissionRequired: return "Your Station authorization does not include account recovery access. Authorize Station access again."
        case .accessDenied: return "This Station refused access to the account's recovery data. Your saved setup was retained."
        case .recordNotFound: return "The selected Station does not have this account's saved security data, or it is not accessible to this sign-in. Connect your existing account security to this Station; your keys and verification are retained."
        case .unavailable: return "Account recovery is unavailable on this relay. Your saved operation was retained; retry later."
        case .invalidResponse: return "The relay returned recovery data that could not be verified. Nothing was trusted from this response."
        case .insecureURL: return "Account recovery requires an HTTPS relay, or a local loopback relay."
        }
    }
}

public struct RemoteRecoveryLogPage: Sendable {
    public let head: LogHead
    public let entries: [String]
    public let more: Bool

    public init(head: LogHead, entries: [String], more: Bool) {
        self.head = head; self.entries = entries; self.more = more
    }
}

public enum RemoteRecoveryAppendReply: Sendable {
    case stored
    case conflict(RemoteRecoveryLogPage)
}

public protocol RemoteRecoveryTransport: Sendable {
    func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage
    func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply
    func uploadBackup(genesisHash: String, envelopeJSON: String, signedEntryJSON: String) async throws -> UInt64?
    func backup(log: MembershipLog) async throws -> String
    func hostAccept(genesisHash: String, hostID: String, initFrame: Data) async throws -> Data
}

public protocol RemoteControlTransport: Sendable {
    func controlHeads(genesisHash: String) async throws -> String
    func reserveControlTime(genesisHash: String, principal: String, managerID: String, expected: LogHead) async throws -> UInt64
    @MainActor func publishControl(log: MembershipLog, recordJSON: String) async throws -> Bool
}

public protocol RemoteControlFeedTransport: RemoteControlTransport {
    func controlSync(genesisHash: String, callJSON: String) async throws -> String
}

public protocol RemoteControlStationTransport: RemoteRecoveryTransport, RemoteControlTransport {
    var controlStationOrigin: String { get }
}

private final class RecoveryRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Only an authenticated GET to this plan's Station can construct this proof.
public struct RemoteStationPlanEnd: Sendable {
    public enum Outcome: String, Sendable { case abandoned, published }
    public let outcome: Outcome
    let context: RemoteControlRecoveryContext
    fileprivate init(context: RemoteControlRecoveryContext, outcome: Outcome) {
        self.context = context
        self.outcome = outcome
    }
}

public struct RemoteStationAbandonment: Sendable {
    let receipt: RemoteStationPlanEnd
    fileprivate init(receipt: RemoteStationPlanEnd) { self.receipt = receipt }
}

/// An SDK-decoded challenge received from the selected Station for this exact plan.
public struct RemoteStationSignerChallenge: Sendable {
    public let context: RemoteControlRecoveryContext
    public let json: String
    public let challenge: SignerReportChallenge

    fileprivate init(context: RemoteControlRecoveryContext, json: String, challenge: SignerReportChallenge) {
        self.context = context
        self.json = json
        self.challenge = challenge
    }
}

/// TLS/account login limits storage access. Only the shared verifier grants cryptographic trust.
public final class RemoteRecoveryHTTP: RemoteControlStationTransport, RemoteDeviceEnrollmentTransport, RemoteControlFeedTransport, RemoteControlStatusTransport, RemoteControlRecoveryOriginalsTransport, RemoteControlRecoveryRetentionTransport, RemoteStationVerifierTransport, RemoteManagedServiceVerifierTransport, RemoteVerifierReportTransport, @unchecked Sendable {
    private let baseURL: URL
    private let stationOrigin: String
    public var controlStationOrigin: String { stationOrigin }
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String

    public convenience init(relayURL: String, accessToken: @escaping @Sendable () async throws -> String) throws {
        try self.init(relayURL: relayURL, configuration: .ephemeral, accessToken: accessToken)
    }

    init(relayURL: String, configuration: URLSessionConfiguration,
        accessToken: @escaping @Sendable () async throws -> String) throws {
        var components = URLComponents(string: try RemoteRecoveryKit.checkedRelayURL(relayURL))!
        if components.scheme == "wss" { components.scheme = "https" }
        if components.scheme == "ws" { components.scheme = "http" }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host?.lowercased() ?? "")
        guard components.scheme == "https" || (components.scheme == "http" && local), let url = components.url else {
            throw RemoteRecoveryTransportError.insecureURL
        }
        baseURL = url.appendingPathComponent("api/remote/v1/logs", isDirectory: true)
        stationOrigin = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = accessToken
        let config = configuration
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: RecoveryRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func submitVerifierChallenge(genesisHash: String, challengeJSON: String, expected: LogHead) async throws -> RemoteVerifierReportMailbox {
        try validateVerifierChallenge(genesisHash: genesisHash, challengeJSON: challengeJSON, expected: expected)
        let (_, data) = try await perform(url: path(genesisHash, "verifier-reports"), method: "POST",
            body: Self.encode(["challenge": Self.object(challengeJSON), "expected": ["seq": expected.seq, "hash": expected.hash]]))
        return try RemoteVerifierReportMailbox.decode(data, challengeJSON: challengeJSON, expected: expected)
    }

    public func verifierReports(genesisHash: String, challengeJSON: String, expected: LogHead) async throws -> RemoteVerifierReportMailbox {
        let challenge = try validateVerifierChallenge(genesisHash: genesisHash, challengeJSON: challengeJSON, expected: expected)
        let (_, data) = try await perform(url: path(genesisHash, "verifier-reports").appendingPathComponent(challenge.nonce), method: "GET")
        return try RemoteVerifierReportMailbox.decode(data, challengeJSON: challengeJSON, expected: expected)
    }

    public func publishVerifierReport(genesisHash: String, challengeJSON: String, expected: LogHead, reportJSON: String) async throws -> RemoteVerifierReportMailbox {
        let challenge = try validateVerifierChallenge(genesisHash: genesisHash, challengeJSON: challengeJSON, expected: expected)
        guard reportJSON.utf8.count <= 16_384 else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(genesisHash, "verifier-reports").appendingPathComponent(challenge.nonce), method: "POST",
            body: Self.encode(["report": Self.object(reportJSON)]))
        return try RemoteVerifierReportMailbox.decode(data, challengeJSON: challengeJSON, expected: expected)
    }

    public func verifierChallenges(genesisHash: String, signer: String, slot: String, expected: LogHead) async throws -> [String] {
        let validation = try verifierReportChallenge(signer: signer, slot: slot, origin: stationOrigin,
            connection: 1, issuedAt: 1, expiresAt: 2)
        try validateVerifierChallenge(genesisHash: genesisHash, challengeJSON: validation, expected: expected)
        let (_, data) = try await perform(url: path(genesisHash, "verifier-requests"), method: "POST",
            body: Self.encode(["signer": signer, "slot": slot, "expected": ["seq": expected.seq, "hash": expected.hash]]))
        let object = try Self.dictionary(data)
        guard Set(object.keys) == ["challenges"], let values = object["challenges"] as? [[String: Any]], values.count <= 16 else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        var nonces = Set<String>()
        return try values.map { value in
            let json = try Self.json(value), challenge = try parseVerifierReportChallenge(challengeJson: json)
            guard challenge.signer == signer, challenge.slot == slot, challenge.origin == stationOrigin,
                  nonces.insert(challenge.nonce).inserted else { throw RemoteRecoveryTransportError.invalidResponse }
            return json
        }
    }

    @discardableResult
    private func validateVerifierChallenge(genesisHash: String, challengeJSON: String, expected: LogHead) throws -> VerifierReportChallenge {
        guard RemoteRecoveryKit.validHash(genesisHash), (1...9_007_199_254_740_991).contains(expected.seq),
              RemoteRecoveryKit.validHash(expected.hash) else { throw RemoteChannelError.invalidInput }
        let challenge = try parseVerifierReportChallenge(challengeJson: challengeJSON)
        guard challenge.origin == stationOrigin else { throw RemoteChannelError.invalidInput }
        return challenge
    }

    public func stationVerifiers(genesisHash: String) async throws -> RemoteStationVerifierSnapshot {
        guard RemoteRecoveryKit.validHash(genesisHash) else { throw RemoteChannelError.invalidInput }
        let startedAt = RemoteVerifierSigningGate.evidenceTimeMilliseconds()
        let (_, data) = try await perform(url: path(genesisHash, "verifiers"), method: "GET")
        return try RemoteStationVerifierSnapshot.decode(data, origin: stationOrigin, genesis: genesisHash, startedAt: startedAt)
    }

    public func managedServiceVerifiers(genesisHash: String, memberIDs: [String], expected: LogHead) async throws -> RemoteManagedServiceVerifierSnapshot {
        guard RemoteRecoveryKit.validHash(genesisHash), RemoteManagedServiceVerifierSnapshot.validIDs(memberIDs),
              expected.seq > 0, expected.seq <= 9_007_199_254_740_991, RemoteRecoveryKit.validHash(expected.hash) else {
            throw RemoteChannelError.invalidInput
        }
        let started = RemoteVerifierSigningGate.evidenceTimeMilliseconds()
        let url = URL(string: stationOrigin)!.appendingPathComponent("agora-build/v1/logs")
            .appendingPathComponent(genesisHash).appendingPathComponent("verifiers/services")
        let body = try JSONSerialization.data(withJSONObject: ["member_ids": memberIDs,
            "expected": ["seq": expected.seq, "hash": expected.hash]])
        let (_, bytes) = try await perform(url: url, method: "POST", body: body)
        let result = try RemoteManagedServiceVerifierSnapshot.decode(bytes, origin: stationOrigin,
            genesis: genesisHash, memberIDs: memberIDs, startedAt: started)
        guard result.station.head == expected else { throw RemoteRecoveryTransportError.invalidResponse }
        return result
    }

    public func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage {
        guard RemoteRecoveryKit.validHash(genesisHash), after <= 9_007_199_254_740_991 else { throw RemoteChannelError.invalidInput }
        var url = URLComponents(url: path(genesisHash, "entries"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "after", value: String(after))]
        let (_, data) = try await perform(url: url.url!, method: "GET")
        return try Self.page(data)
    }

    /// Announcements are synchronization hints, never a trusted device-list head.
    public func controlHeads(genesisHash: String) async throws -> String {
        guard RemoteRecoveryKit.validHash(genesisHash) else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(genesisHash, "control"), method: "GET")
        let text = String(decoding: data, as: UTF8.self)
        guard case .heads(let feeds, _) = try relayDecodeToHost(message: text),
              feeds.count == 1, feeds[0].origin == stationOrigin else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return text
    }

    public func retainControlRecoveryCopies(context: RemoteControlRecoveryContext,
        copiesJSON: String) async throws -> RemoteControlRecoveryRetention {
        guard context.stationOrigin == stationOrigin else { throw RemoteChannelError.invalidInput }
        let ids = try RemoteControlRecoveryRetention.requestIDs(context: context, json: copiesJSON)
        let (_, data) = try await perform(url: path(context.genesisHash, "control/recovery/\(context.planID)/signatures"),
            method: "POST", body: Data(copiesJSON.utf8))
        return try RemoteControlRecoveryRetention.decode(data, context: context, recordIDs: ids)
    }

    struct ReviewReceipt: Equatable, Sendable {
        let context: RemoteControlRecoveryContext
        fileprivate init(_ context: RemoteControlRecoveryContext) { self.context = context }
    }

    public func controlRecoveryReview(accountID: String, genesisHash: String,
        expected: LogHead) async throws -> RemoteControlRecoveryPreparation {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validHash(genesisHash),
              expected.seq > 0, expected.seq <= 9_007_199_254_740_991,
              RemoteRecoveryKit.validHash(expected.hash) else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(genesisHash, "control/recovery"), method: "GET")
        var review = try RemoteControlRecoveryPreparation.decode(data, accountID: accountID, genesisHash: genesisHash,
            stationOrigin: stationOrigin, expected: expected)
        review.stationReceipt = ReviewReceipt(review.context)
        return review
    }

    public func controlRecoveryOriginals(for review: RemoteControlRecoveryPreparation) async throws -> [String] {
        let context = review.context
        try context.validate()
        guard context.stationOrigin == stationOrigin, RemoteRecoveryKit.validHash(review.reconstructionHash) else {
            throw RemoteChannelError.invalidInput
        }
        let endpoint = path(context.genesisHash, "control/recovery/\(context.planID)/originals")
        var records: [String] = []
        var lastID = ""
        var size = 0
        while true {
            var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "review", value: review.reconstructionHash),
                              URLQueryItem(name: "offset", value: String(records.count))]
            let (_, bytes) = try await perform(url: url.url!, method: "GET")
            let page = try Self.dictionary(bytes)
            guard Set(page.keys) == ["plan_id", "reconstruction_hash", "offset", "records", "more"],
                  page["plan_id"] as? String == context.planID,
                  page["reconstruction_hash"] as? String == review.reconstructionHash,
                  let offset = page["offset"] as? NSNumber, CFGetTypeID(offset) != CFBooleanGetTypeID(),
                  offset.stringValue == String(records.count),
                  let rows = page["records"] as? [[String: Any]], rows.count <= 64,
                  let more = page["more"] as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID(),
                  records.count + rows.count <= 4096, !more.boolValue || (!rows.isEmpty && records.count + rows.count < 4096)
            else { throw RemoteRecoveryTransportError.invalidResponse }
            for row in rows {
                let json = try Self.json(row)
                let body = try parseControlRecord(recordJson: json)
                size += json.utf8.count
                guard size <= 16 * 1024 * 1024, RemoteControlRecoveryContext.validUUID(body.recordId),
                      body.recordId > lastID else { throw RemoteRecoveryTransportError.invalidResponse }
                lastID = body.recordId
                records.append(json)
            }
            if !more.boolValue { return records }
        }
    }

    func reserveRecoveryCopy(context: RemoteControlRecoveryContext, original: String,
        manager: String, issuedAt: UInt64?, after: UInt64) async throws -> UInt64 {
        try context.validate()
        let body = try parseControlRecord(recordJson: original)
        guard stationOrigin == context.stationOrigin, RemoteRecoveryKit.validID(manager),
              body.accountId == context.accountID, body.genesisHash == context.genesisHash,
              body.origin == nil || body.origin == stationOrigin else { throw RemoteChannelError.invalidInput }
        let hash = SHA256.hash(data: Data(try canonicalJson(json: original).utf8)).map { String(format: "%02x", $0) }.joined()
        var request: [String: Any] = ["manager":manager, "original_record_id":body.recordId, "original_hash":hash,
            "expected":["seq":context.membershipHead.seq, "hash":context.membershipHead.hash] as [String: Any],
            "recovery":["generation":String(context.generation), "plan_id":context.planID, "source_hash":context.sourceHash,
                        "candidate_feed_id":context.candidateFeedID, "evidence_hash":context.evidenceHash]]
        guard after <= 9_007_199_254_740_991, after == 0 || issuedAt == nil else { throw RemoteChannelError.invalidInput }
        if let issuedAt { request["issued_at"] = issuedAt }
        if after > 0 { request["after_issued_at"] = after }
        let (status, bytes) = try await perform(url: path(context.genesisHash, "control/recovery/copy-reservations"),
            method: "POST", body: Self.encode(request), allowConflict: true)
        if status == 409 {
            guard bytes.count <= 4096, try Self.json(Self.dictionary(bytes)) == #"{"error":{"code":"recovery_plan_changed"}}"# else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            throw RemoteRecoveryCopyReservationError.changed
        }
        guard bytes.count <= 4096 else { throw RemoteRecoveryTransportError.invalidResponse }
        let reply = try Self.dictionary(bytes)
        guard let number = reply["issued_at"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.stringValue == String(number.uint64Value), number.uint64Value <= 9_007_199_254_740_991,
              number.uint64Value > max(body.issuedAt, after), issuedAt == nil || issuedAt == number.uint64Value else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        request.removeValue(forKey: "after_issued_at")
        request["issued_at"] = number.uint64Value
        request["origin"] = stationOrigin
        request["account_id"] = context.accountID
        request["genesis_hash"] = context.genesisHash
        guard try Self.json(request) == Self.json(reply) else { throw RemoteRecoveryTransportError.invalidResponse }
        return number.uint64Value
    }

    public func planEnd(for held: RemoteControlRecoveryContext) async throws -> RemoteStationPlanEnd? {
        try held.validate()
        guard held.stationOrigin == stationOrigin else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(held.genesisHash, "control/recovery/" + held.planID + "/outcome"), method: "GET")
        guard data.count <= 4096 else { throw RemoteRecoveryTransportError.invalidResponse }
        let body = try Self.dictionary(data)
        guard Set(body.keys) == ["account_id", "genesis_hash", "origin", "generation", "plan_id", "candidate_feed_id", "source_hash", "outcome"],
              body["account_id"] as? String == held.accountID, body["genesis_hash"] as? String == held.genesisHash,
              body["origin"] as? String == stationOrigin, body["generation"] as? String == String(held.generation),
              body["plan_id"] as? String == held.planID, body["candidate_feed_id"] as? String == held.candidateFeedID,
              body["source_hash"] as? String == held.sourceHash else { throw RemoteRecoveryTransportError.invalidResponse }
        guard let raw = body["outcome"] as? String else { throw RemoteRecoveryTransportError.invalidResponse }
        if raw == "pending" { return nil }
        guard let outcome = RemoteStationPlanEnd.Outcome(rawValue: raw) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return RemoteStationPlanEnd(context: held, outcome: outcome)
    }

    public func abandonment(of held: RemoteControlRecoveryContext) async throws -> RemoteStationAbandonment? {
        guard let end = try await planEnd(for: held) else { return nil }
        guard end.outcome == .abandoned else { throw RemoteRecoveryTransportError.invalidResponse }
        return RemoteStationAbandonment(receipt: end)
    }

    public func signerChallenge(for context: RemoteControlRecoveryContext, memberID: String, slot: String,
        nowMs: @Sendable () -> UInt64) async throws -> RemoteStationSignerChallenge {
        try context.validate()
        guard stationOrigin == context.stationOrigin, RemoteRecoveryKit.validID(memberID),
              RemoteRecoveryKit.validID(slot) else { throw RemoteChannelError.invalidInput }
        let signer = "member:" + memberID
        let recovery = ["generation": String(context.generation), "plan_id": context.planID,
            "candidate_feed_id": context.candidateFeedID, "source_hash": context.sourceHash, "evidence_hash": context.evidenceHash]
        let bytes = try JSONSerialization.data(withJSONObject: ["signer": signer, "slot": slot, "recovery": recovery,
            "expected": ["seq": context.membershipHead.seq, "hash": context.membershipHead.hash]] as [String: Any])
        let (_, data) = try await perform(url: path(context.genesisHash, "control/recovery/signer-challenges"),
            method: "POST", body: bytes)
        guard data.count <= 4096, let json = String(data: data, encoding: .utf8) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        let challenge = try parseSignerReportChallenge(challengeJson: json)
        let now = nowMs()
        guard challenge.signer == signer, challenge.slot == slot, challenge.origin == stationOrigin,
              challenge.issuedAt <= now, now < challenge.expiresAt,
              challenge.recovery == SignerReportRecovery(generation: String(context.generation), planId: context.planID,
                candidateFeedId: context.candidateFeedID, sourceHash: context.sourceHash, evidenceHash: context.evidenceHash)
        else { throw RemoteRecoveryTransportError.invalidResponse }
        return RemoteStationSignerChallenge(context: context, json: json, challenge: challenge)
    }

    static func submissionBytes(report: String, records: [String], processes: [String]) throws -> Data {
        let recordSize = records.reduce(report.utf8.count, { $0 + $1.utf8.count })
        guard processes.reduce(recordSize, { $0 + $1.utf8.count }) <= 262_144 else {
            throw RemoteControlPublicationError.full
        }
        let bytes = try Self.encode(["report": Self.object(report), "records": records.map { try Self.object($0) }, "processes": processes])
        guard bytes.count <= 262_144 else { throw RemoteControlPublicationError.full }
        return bytes
    }

    /// True only for a receipt for these exact bytes. A retired challenge may be renewed
    /// after a reviewed retry. A storage or network failure leaves the outcome unknown.
    public func retainSignerReport(_ submission: RemoteControlSigningJournal.Submission) async throws -> Bool {
        let context = submission.context
        try context.validate()
        guard context.stationOrigin == stationOrigin else { throw RemoteChannelError.invalidInput }
        let bytes = try Self.submissionBytes(report: submission.report, records: submission.records, processes: submission.processes)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let (status, reply) = try await perform(url: path(context.genesisHash, "control/recovery/signer-reports"),
            method: "POST", body: bytes, allowConflict: true)
        let body = try Self.dictionary(reply)
        if status == 409, let error = body["error"] as? [String: Any],
           error["code"] as? String == "recovery_plan_changed" { return false }
        guard status == 200, Set(body.keys) == ["plan_id", "retained_only", "submission_hash"],
              body["plan_id"] as? String == context.planID, body["submission_hash"] as? String == hash,
              let retained = body["retained_only"] as? NSNumber, CFGetTypeID(retained) == CFBooleanGetTypeID(),
              retained.boolValue else { throw RemoteRecoveryTransportError.invalidResponse }
        return true
    }

    public func controlSync(genesisHash: String, callJSON: String) async throws -> String {
        guard RemoteRecoveryKit.validHash(genesisHash),
              case .controlSync(_, let origin, _, _) = try relayDecodeToStation(message: callJSON),
              origin == stationOrigin else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(genesisHash, "control/sync"), method: "POST", body: Data(callJSON.utf8))
        let text = String(decoding: data, as: UTF8.self)
        if case .controlSyncRefused = try relayDecodeToHost(message: text) {
            throw RemoteRecoveryTransportError.accessDenied
        }
        guard try relayControlSyncAnswers(call: callJSON, result: text) == .answers else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return text
    }

    public func reserveControlTime(genesisHash: String, principal: String, managerID: String, expected: LogHead) async throws -> UInt64 {
        guard RemoteRecoveryKit.validHash(genesisHash), RemoteRecoveryKit.validID(managerID),
              expected.seq > 0, expected.seq <= 9_007_199_254_740_991, RemoteRecoveryKit.validHash(expected.hash),
              ["service:", "host:"].contains(where: { principal.hasPrefix($0) && RemoteRecoveryKit.validID(String(principal.dropFirst($0.count))) }) else {
            throw RemoteChannelError.invalidInput
        }
        let (_, data) = try await perform(url: path(genesisHash, "control/reservations"), method: "POST",
            body: Self.encode(["principal": principal, "manager": managerID, "expected": ["seq": expected.seq, "hash": expected.hash]]))
        let reply = try Self.dictionary(data)
        guard Set(reply.keys) == ["issued_at"], let time = reply["issued_at"] as? NSNumber,
              CFGetTypeID(time) != CFBooleanGetTypeID(), time.uint64Value > 0,
              time.uint64Value <= 9_007_199_254_740_991, time.stringValue == String(time.uint64Value) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return time.uint64Value
    }

    public func controlStatus(genesisHash: String, recordIDs: [String], expected: LogHead) async throws -> [String: RemoteControlApplicationState] {
        guard RemoteRecoveryKit.validHash(genesisHash), expected.seq > 0,
              expected.seq <= 9_007_199_254_740_991, RemoteRecoveryKit.validHash(expected.hash),
              !recordIDs.isEmpty, recordIDs.count <= 64, Set(recordIDs).count == recordIDs.count,
              recordIDs.allSatisfy({ id in
                  guard let value = UUID(uuidString: id) else { return false }
                  return value.uuidString.lowercased() == id && id[id.index(id.startIndex, offsetBy: 14)] == "4"
              }) else { throw RemoteChannelError.invalidInput }
        let (_, data) = try await perform(url: path(genesisHash, "control/status"), method: "POST",
            body: Self.encode(["record_ids": recordIDs, "expected": ["seq": expected.seq, "hash": expected.hash]]))
        let reply = try Self.dictionary(data)
        guard Set(reply.keys) == ["head", "records"],
              let head = reply["head"] as? [String: Any], Set(head.keys) == ["seq", "hash"],
              let seq = head["seq"] as? NSNumber, CFGetTypeID(seq) != CFBooleanGetTypeID(),
              seq.stringValue == String(expected.seq), head["hash"] as? String == expected.hash,
              let records = reply["records"] as? [[String: Any]], records.count == recordIDs.count else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        var result: [String: RemoteControlApplicationState] = [:]
        for (index, record) in records.enumerated() {
            guard Set(record.keys) == ["record_id", "state"], record["record_id"] as? String == recordIDs[index],
                  let raw = record["state"] as? String, let state = RemoteControlApplicationState(rawValue: raw) else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            result[recordIDs[index]] = state
        }
        return result
    }

    /// Only delivers an already-signed, independently verified manager record.
    /// The native publisher owns confirmation and durable signing/delivery state.
    @MainActor
    public func publishControl(log: MembershipLog, recordJSON: String) async throws -> Bool {
        let log = log.snapshot()
        let body = try parseControlRecord(recordJson: recordJSON)
        guard log.frozen() == nil, body.genesisHash == log.genesisHash(), body.accountId == log.accountId(),
              body.origin == nil || body.origin == stationOrigin,
              body.signer.hasPrefix("member:"), ["revoke", "interrupt_running"].contains(body.action),
              case .valid = try verifyControlRecord(log: log, recordJson: recordJSON) else {
            throw RemoteChannelError.invalidInput
        }
        let head = log.head()
        let (_, data) = try await perform(url: path(log.genesisHash(), "control/records"), method: "POST",
            body: Self.encode(["record": Self.object(recordJSON), "expected": ["seq": head.seq, "hash": head.hash]]))
        let reply = try Self.dictionary(data)
        guard Set(reply.keys) == ["record_id", "appended"], reply["record_id"] as? String == body.recordId,
              let appended = reply["appended"] as? NSNumber, CFGetTypeID(appended) == CFBooleanGetTypeID() else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return appended.boolValue
    }

    public func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply {
        guard RemoteRecoveryKit.validHash(genesisHash) else { throw RemoteChannelError.invalidInput }
        let entry = try Self.object(request.entryJson)
        let body = try Self.encode(["entry": entry, "expected": ["seq": request.expected.seq, "hash": request.expected.hash]])
        let (status, data) = try await perform(url: path(genesisHash, "entries"), method: "POST", body: body, allowConflict: true)
        if status == 409 { return .conflict(try Self.page(data)) }
        let reply = try Self.dictionary(data)
        guard let stored = reply["entry"], try signedObjectInfo(json: Self.json(stored)).entryHash == request.entryHash else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return .stored
    }

    /// The entry is the already signed backup intent; this upload never commits that entry.
    public func uploadBackup(genesisHash: String, envelopeJSON: String, signedEntryJSON: String) async throws -> UInt64? {
        let info = try parseKBackup(envelopeJson: envelopeJSON)
        guard RemoteRecoveryKit.validHash(genesisHash), try Self.dictionary(Data(envelopeJSON.utf8))["genesis_hash"] as? String == genesisHash else {
            throw RemoteChannelError.invalidInput
        }
        let authorization = RemoteRecoveryKit.base64URL(Data(signedEntryJSON.utf8))
        guard authorization.utf8.count <= 16_384 else { throw RemoteChannelError.invalidInput }
        let (status, data) = try await perform(url: path(genesisHash, "backups/\(info.blobVersion)"), method: "PUT",
            body: Data(envelopeJSON.utf8), headers: ["X-Astation-Backup-Entry": authorization], allowConflict: true)
        if status == 200 { return nil }
        let body = try Self.dictionary(data)
        guard let value = body["max_occupied"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.uint64Value >= info.blobVersion, value.uint64Value <= 9_007_199_254_740_991,
              value.stringValue == String(value.uint64Value) else { throw RemoteRecoveryTransportError.invalidResponse }
        return value.uint64Value
    }

    public func backup(log: MembershipLog) async throws -> String {
        guard let expected = log.kBackup() else { throw RemoteChannelError.notReady }
        let (_, bytes) = try await perform(url: path(log.genesisHash(), "backups/\(expected.blobVersion)"), method: "GET")
        guard let text = String(data: bytes, encoding: .utf8) else { throw RemoteRecoveryTransportError.invalidResponse }
        let actual = try parseKBackup(envelopeJson: text)
        guard actual == expected else { throw RemoteRecoveryTransportError.invalidResponse }
        return text
    }

    public func hostAccept(genesisHash: String, hostID: String, initFrame: Data) async throws -> Data {
        guard RemoteRecoveryKit.validHash(genesisHash), RemoteRecoveryKit.validID(hostID), initFrame.count <= 65_536 else {
            throw RemoteChannelError.invalidInput
        }
        var url = URLComponents(url: path(genesisHash, "probes"), resolvingAgainstBaseURL: false)!
        url.percentEncodedPath += "/" + hostID.utf8.map { String(format: "%%%02X", $0) }.joined()
        let (_, bytes) = try await perform(url: url.url!, method: "POST", body: initFrame)
        guard bytes.count <= 65_536 else { throw RemoteRecoveryTransportError.invalidResponse }
        _ = try Self.dictionary(bytes)
        return bytes
    }

    public func createEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: stationOrigin, now: Self.enrollmentClock(now))
        let (_, bytes) = try await perform(url: enrollmentPath(invitation), method: "PUT",
            body: Self.encode(["expires": invitation.expires]), enrollmentErrors: true)
        return try enrollmentMailbox(bytes, invitation: invitation, now: now)
    }

    public func readEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: stationOrigin, now: Self.enrollmentClock(now))
        let (_, bytes) = try await perform(url: enrollmentPath(invitation), method: "GET", enrollmentErrors: true)
        return try enrollmentMailbox(bytes, invitation: invitation, now: now)
    }

    public func submitEnrollment(_ request: RemoteDeviceEnrollmentRequest, invitation: RemoteDeviceEnrollmentInvitation,
        now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        try request.validate(invitation: invitation, now: Self.enrollmentClock(now))
        let (_, bytes) = try await perform(url: enrollmentPath(invitation), method: "POST",
            body: Self.encode(["stage": "request", "message": Self.object(request.json())]), enrollmentErrors: true)
        let mailbox = try enrollmentMailbox(bytes, invitation: invitation, now: now)
        guard mailbox.request == request else { throw RemoteRecoveryTransportError.invalidResponse }
        return mailbox
    }

    public func publishEnrollment(_ response: RemoteDeviceEnrollmentHandoff, request: RemoteDeviceEnrollmentRequest,
        invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox {
        _ = try RemoteDeviceEnrollmentHandoff(json: response.json(), invitation: invitation, request: request, now: Self.enrollmentClock(now))
        let (_, bytes) = try await perform(url: enrollmentPath(invitation), method: "POST",
            body: Self.encode(["stage": "response", "message": Self.object(response.json())]), enrollmentErrors: true)
        let mailbox = try enrollmentMailbox(bytes, invitation: invitation, now: now)
        guard mailbox.request == request, mailbox.response == response else { throw RemoteRecoveryTransportError.invalidResponse }
        return mailbox
    }

    public func cancelEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation) async throws {
        do {
            let (_, bytes) = try await perform(url: enrollmentPath(invitation), method: "DELETE", enrollmentErrors: true)
            guard try Self.dictionary(bytes)["closed"] as? Bool == true else { throw RemoteRecoveryTransportError.invalidResponse }
        } catch RemoteDeviceEnrollmentTransportError.closed { return }
    }

    private func enrollmentPath(_ invitation: RemoteDeviceEnrollmentInvitation) throws -> URL {
        guard RemoteRecoveryKit.validHash(invitation.genesis),
              let id = RemoteRecoveryKit.decodeBase64URL(invitation.id, count: 32),
              RemoteRecoveryKit.base64URL(id) == invitation.id,
              // An invitation cannot redirect an existing account token.
              stationOrigin == invitation.station else {
            throw RemoteDeviceEnrollmentError.wrongContext
        }
        return path(invitation.genesis, "device-enrollments/" + invitation.id)
    }

    private func enrollmentMailbox(_ bytes: Data, invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) throws -> RemoteDeviceEnrollmentMailbox {
        let body = try Self.dictionary(bytes)
        guard Set(body.keys) == Set(["expires", "request", "response"]),
              let expires = body["expires"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID(),
              expires.stringValue == String(invitation.expires) else { throw RemoteRecoveryTransportError.invalidResponse }
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: invitation.station, now: Self.enrollmentClock(now))
        let request = try body["request"].flatMap { $0 is NSNull ? nil : try RemoteDeviceEnrollmentRequest(json: Self.json($0), invitation: invitation, now: Self.enrollmentClock(now)) }
        let response: RemoteDeviceEnrollmentHandoff?
        if let object = body["response"], !(object is NSNull) {
            guard let request else { throw RemoteRecoveryTransportError.invalidResponse }
            response = try RemoteDeviceEnrollmentHandoff(json: Self.json(object), invitation: invitation, request: request, now: Self.enrollmentClock(now))
        } else { response = nil }
        return RemoteDeviceEnrollmentMailbox(expires: invitation.expires, request: request, response: response)
    }

    private static func enrollmentClock(_ wall: UInt64) -> HostClock { HostClock(wallMs: wall, monoMs: 0, bootId: "enrollment-http") }

    private func path(_ genesis: String, _ suffix: String) -> URL {
        baseURL.appendingPathComponent(genesis, isDirectory: true).appendingPathComponent(suffix)
    }

    private func perform(url: URL, method: String, body: Data? = nil, headers: [String: String] = [:],
        allowConflict: Bool = false, enrollmentErrors: Bool = false) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await accessToken()
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw RemoteRecoveryTransportError.authenticationRequired
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw RemoteRecoveryTransportError.invalidResponse }
        if response.statusCode == 401 { throw RemoteRecoveryTransportError.authenticationRequired }
        if enrollmentErrors && [404, 409, 410, 429].contains(response.statusCode) {
            var data = Data()
            for try await byte in stream {
                guard data.count < 16_384 else { throw RemoteRecoveryTransportError.invalidResponse }
                data.append(byte)
            }
            let body = try Self.dictionary(data)
            let code = (body["error"] as? [String: Any])?["code"] as? String
            switch (response.statusCode, code) {
            case (404, "device_enrollment_not_found"): throw RemoteDeviceEnrollmentTransportError.notFound
            case (404, "recovery_record_not_found"): throw RemoteRecoveryTransportError.recordNotFound
            case (409, "device_enrollment_conflict"), (409, "device_enrollment_request_required"): throw RemoteDeviceEnrollmentTransportError.conflict
            case (410, "device_enrollment_closed"): throw RemoteDeviceEnrollmentTransportError.closed
            case (429, "device_enrollment_limit"): throw RemoteDeviceEnrollmentTransportError.limit
            default: throw RemoteRecoveryTransportError.invalidResponse
            }
        }
        if response.statusCode == 403 || response.statusCode == 404 {
            var data = Data()
            for try await byte in stream {
                guard data.count < 16_384 else { throw RemoteRecoveryTransportError.invalidResponse }
                data.append(byte)
            }
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            if response.statusCode == 404 {
                guard code?["code"] as? String == "recovery_record_not_found" else {
                    throw RemoteRecoveryTransportError.unavailable
                }
                throw RemoteRecoveryTransportError.recordNotFound
            }
            switch code?["code"] as? String {
            case "recovery_creator_not_registered": throw RemoteRecoveryTransportError.registrationRequired
            case "insufficient_scope": throw RemoteRecoveryTransportError.permissionRequired
            default: throw RemoteRecoveryTransportError.accessDenied
            }
        }
        guard response.statusCode == 200 || (allowConflict && response.statusCode == 409) else { throw RemoteRecoveryTransportError.unavailable }
        var data = Data()
        for try await byte in stream {
            guard data.count < 262_144 else { throw RemoteRecoveryTransportError.invalidResponse }
            data.append(byte)
        }
        return (response.statusCode, data)
    }

    private static func page(_ bytes: Data) throws -> RemoteRecoveryLogPage {
        let object = try dictionary(bytes)
        guard let head = object["head"] as? [String: Any], let sequence = head["seq"] as? NSNumber,
              CFGetTypeID(sequence) != CFBooleanGetTypeID(), sequence.uint64Value <= 9_007_199_254_740_991,
              sequence.stringValue == String(sequence.uint64Value), let hash = head["hash"] as? String,
              RemoteRecoveryKit.validHash(hash), let entries = object["entries"] as? [Any], entries.count <= 64,
              object["more"] == nil || (object["more"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return try RemoteRecoveryLogPage(head: LogHead(seq: sequence.uint64Value, hash: hash), entries: entries.map(json),
            more: object["more"] as? Bool ?? false)
    }

    private static func dictionary(_ bytes: Data) throws -> [String: Any] {
        guard let text = String(data: bytes, encoding: .utf8), let value = try object(text) as? [String: Any] else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return value
    }
    private static func object(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8))
    }
    private static func encode(_ object: Any) throws -> Data { Data(try json(object).utf8) }
    private static func json(_ object: Any) throws -> String {
        try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
