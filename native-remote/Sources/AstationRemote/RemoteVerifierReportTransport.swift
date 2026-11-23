import AtemClient
import Foundation

public protocol RemoteVerifierReportTransport: Sendable {
    func submitVerifierChallenge(genesisHash: String, challengeJSON: String, expected: LogHead) async throws -> RemoteVerifierReportMailbox
    func verifierReports(genesisHash: String, challengeJSON: String, expected: LogHead) async throws -> RemoteVerifierReportMailbox
    func verifierChallenges(genesisHash: String, signer: String, slot: String, expected: LogHead) async throws -> [String]
    func publishVerifierReport(genesisHash: String, challengeJSON: String, expected: LogHead, reportJSON: String) async throws -> RemoteVerifierReportMailbox
}

/// Strict carriage and correlation only. Every report still needs independent
/// shared-library verification against the consumer's anchored membership.
public struct RemoteVerifierReportMailbox: Sendable {
    public let challengeJSON: String
    public let reports: [String]

    public static func decode(_ data: Data, challengeJSON: String, expected: LogHead) throws -> Self {
        guard (1...9_007_199_254_740_991).contains(expected.seq), RemoteRecoveryKit.validHash(expected.hash),
              data.count <= 262_144, let text = String(data: data, encoding: .utf8) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        _ = try canonicalJson(json: text)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["challenge", "expected", "reports"],
              let challenge = value["challenge"] as? [String: Any], let head = value["expected"] as? [String: Any],
              Set(head.keys) == ["seq", "hash"],
              let seq = head["seq"] as? NSNumber, CFGetTypeID(seq) != CFBooleanGetTypeID(),
              seq.stringValue == String(expected.seq), head["hash"] as? String == expected.hash,
              let reports = value["reports"] as? [[String: Any]], reports.count <= 4 else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: challenge), as: UTF8.self)
        guard try parseVerifierReportChallenge(challengeJson: json) == parseVerifierReportChallenge(challengeJson: challengeJSON) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        let carried = try reports.map { report -> String in
            let data = try JSONSerialization.data(withJSONObject: report)
            guard data.count <= 16_384 else { throw RemoteRecoveryTransportError.invalidResponse }
            return try canonicalJson(json: String(decoding: data, as: UTF8.self))
        }
        return Self(challengeJSON: challengeJSON, reports: carried)
    }
}

/// A caller schedules `poll` for each explicitly reviewed slot. Polling reuses
/// its original challenge for ten seconds, so later conflicting responses are
/// checked too. A new round withdraws the prior evidence before token work.
@MainActor
public final class RemoteMemberVerifierPoller {
    private struct Round {
        let id: UUID
        let challenge: RemoteMemberVerifierEvidence.Challenge
        let started: UInt64
        var seen: Set<String> = []
        var confirmed = false
        var inFlight = false
    }
    private let evidence: RemoteMemberVerifierEvidence
    private let transport: any RemoteVerifierReportTransport
    private let membership: () throws -> MembershipLog
    private let wall: () -> UInt64
    private let now: () -> UInt64
    private var rounds: [RemoteMemberVerifierSlot: Round] = [:]
    private var retired = false

    public init(evidence: RemoteMemberVerifierEvidence, transport: any RemoteVerifierReportTransport,
                membership: @escaping () throws -> MembershipLog,
                wall: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) },
                now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) {
        self.evidence = evidence; self.transport = transport; self.membership = membership
        self.wall = wall; self.now = now
    }

    @discardableResult
    public func poll(_ slot: RemoteMemberVerifierSlot) async throws -> Bool {
        guard !retired else { throw RemoteVerifierGateError.staleConnection }
        let log: MembershipLog
        do {
            try Task.checkCancellation()
            log = try membership().snapshot()
            try evidence.refresh(log: log, wallMs: wall())
        } catch { retire(); throw error }
        let time = now()
        if rounds[slot]?.inFlight == true { throw RemoteVerifierGateError.staleConnection }
        let creating: Bool
        if let round = rounds[slot], time >= round.started, time - round.started < 10_000 { creating = false }
        else {
            let challenge = try evidence.begin(slot, log: log, wallMs: wall())
            rounds[slot] = Round(id: UUID(), challenge: challenge, started: time)
            creating = true
        }
        var round = rounds[slot]!
        rounds[slot]?.inFlight = true
        do {
            let mailbox: RemoteVerifierReportMailbox
            if creating {
                mailbox = try await transport.submitVerifierChallenge(genesisHash: log.genesisHash(),
                    challengeJSON: round.challenge.json, expected: log.head())
            } else {
                mailbox = try await transport.verifierReports(genesisHash: log.genesisHash(),
                    challengeJSON: round.challenge.json, expected: log.head())
            }
            try Task.checkCancellation()
            guard !retired, rounds[slot]?.id == round.id else { throw RemoteVerifierGateError.staleConnection }
            let current = try membership().snapshot()
            try evidence.refresh(log: current, wallMs: wall())
            guard try parseVerifierReportChallenge(challengeJson: mailbox.challengeJSON) ==
                parseVerifierReportChallenge(challengeJson: round.challenge.json), mailbox.reports.count <= 4 else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            // Authenticate the whole batch before exposing any new evidence.
            for report in mailbox.reports {
                _ = try verifyVerifierReport(log: current, reportJson: report,
                    expectedChallengeJson: round.challenge.json, nowMs: wall())
            }
            for report in mailbox.reports {
                // A signer may produce a different valid signature over the same
                // immutable body. Such a retry cannot consume or renew proof.
                let body = try signedObjectInfo(json: report).bodyJcs
                guard !round.seen.contains(body) else { continue }
                try evidence.receive(report, for: round.challenge, log: current, wallMs: wall())
                round.seen.insert(body)
                round.confirmed = true
            }
            round.inFlight = false
            rounds[slot] = round
            return round.confirmed
        } catch {
            if rounds[slot]?.id == round.id {
                rounds.removeValue(forKey: slot)
                evidence.failed(round.challenge)
            }
            throw error
        }
    }

    public func retire() {
        retired = true; rounds.removeAll(); evidence.retire()
    }
}
