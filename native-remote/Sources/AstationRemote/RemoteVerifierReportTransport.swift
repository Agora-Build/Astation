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
        var acceptedBody: String?
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
        try await poll(slot, readExisting: false)
    }

    /// Finish the issued challenge even if the response was delayed past the
    /// normal ten-second rotation. Never replace it with a fresh challenge.
    public func readIssuedChallenge(_ slot: RemoteMemberVerifierSlot) async throws -> Bool {
        try await poll(slot, readExisting: true)
    }

    /// Bound concurrent Station requests while giving every slot its challenge
    /// before waiting for replies. A post-confirmation read uses the original nonces.
    public func pollSlots(_ slots: [RemoteMemberVerifierSlot], issue: Bool) async throws {
        for start in stride(from: 0, to: slots.count, by: 8) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for slot in slots[start..<min(start + 8, slots.count)] {
                    group.addTask {
                        if issue { _ = try await self.poll(slot) }
                        else { _ = try await self.readIssuedChallenge(slot) }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    private func poll(_ slot: RemoteMemberVerifierSlot, readExisting: Bool) async throws -> Bool {
        guard !retired else { throw RemoteVerifierGateError.staleConnection }
        if Task.isCancelled { retire(); throw CancellationError() }
        let log = try currentMembership()
        let time = now()
        if rounds[slot]?.inFlight == true { throw RemoteVerifierGateError.staleConnection }
        let creating: Bool
        if readExisting {
            guard rounds[slot] != nil else { throw RemoteVerifierGateError.staleConnection }
            creating = false
        } else if let round = rounds[slot], time >= round.started, time - round.started < 10_000 { creating = false }
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
            let current = try currentMembership()
            let challenge = try parseVerifierReportChallenge(challengeJson: round.challenge.json)
            guard try parseVerifierReportChallenge(challengeJson: mailbox.challengeJSON) == challenge,
                  mailbox.reports.count <= 4 else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            let receivedAt = now()
            let wallMs = wall()
            guard receivedAt >= round.started, receivedAt - round.started < challenge.expiresAt - challenge.issuedAt,
                  wallMs >= challenge.issuedAt, wallMs < challenge.expiresAt else {
                throw RemoteVerifierGateError.staleConnection
            }
            // A bad sibling or an ancestor from the expected process must never
            // hide an authenticated process conflict. Only positive evidence waits.
            var invalid: Error?
            var candidate: (body: String, report: String)?
            for report in mailbox.reports {
                let proof: VerifiedReport
                do {
                    proof = try verifyVerifierReport(log: current, reportJson: report,
                        expectedChallengeJson: round.challenge.json, nowMs: wallMs)
                } catch { invalid = error; continue }
                if proof.process != slot.process {
                    try evidence.receive(report, for: round.challenge, log: current, wallMs: wallMs)
                    throw RemoteVerifierGateError.staleConnection
                }
                let body = try signedObjectInfo(json: report).bodyJcs
                if let candidate, candidate.body != body { invalid = RemoteRecoveryTransportError.invalidResponse }
                candidate = (body, report)
            }
            if let invalid { throw invalid }
            // The Station retains one immutable body per process until closure.
            if let accepted = round.acceptedBody {
                guard accepted == candidate?.body else { throw RemoteRecoveryTransportError.invalidResponse }
            } else if let candidate {
                try evidence.receive(candidate.report, for: round.challenge, log: current, wallMs: wallMs)
                round.acceptedBody = candidate.body
            }
            round.inFlight = false
            rounds[slot] = round
            return evidence.confirmed(round.challenge)
        } catch {
            if rounds[slot]?.id == round.id {
                rounds.removeValue(forKey: slot)
                evidence.failed(round.challenge)
            }
            throw error
        }
    }

    private func currentMembership() throws -> MembershipLog {
        do {
            let log = try membership().snapshot()
            try evidence.refresh(log: log, wallMs: wall())
            return log
        } catch { retire(); throw error }
    }

    public func retire() {
        retired = true; rounds.removeAll(); evidence.retire()
    }
}
