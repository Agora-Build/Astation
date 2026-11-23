import AtemClient
import Foundation

/// Accepted by a protected, complete process-roster review, never discovered from presence.
/// Restarting a process requires reviewing its new SDK process identity.
public struct RemoteMemberVerifierSlot: Hashable, Sendable {
    public let memberID: String
    public let slot: String
    public let process: String

    public init(memberID: String, slot: String, process: String) throws {
        guard RemoteRecoveryKit.validID(memberID), RemoteRecoveryKit.validID(slot),
              RemoteRecoveryKit.decodeBase64URL(process, count: 16) != nil else {
            throw RemoteVerifierGateError.invalidRoster
        }
        self.memberID = memberID; self.slot = slot; self.process = process
    }
}

/// Consumer-minted proofs for native/third-party service processes. Station may carry
/// the bytes, but neither its cached reports nor wall clock establish freshness here.
@MainActor
public final class RemoteMemberVerifierEvidence {
    public struct Challenge: Equatable, Sendable {
        public let json: String
        public let slot: RemoteMemberVerifierSlot
        fileprivate let id: UUID
    }

    private struct Pending {
        let challenge: Challenge
        let startedAt: UInt64
        let lifetime: UInt64
    }

    private struct State {
        var generation: UInt64 = 0
        var pending: Pending?
        var consumed: Pending?
        var inventory: VerifierInventory?
        var highest: VerifierInventory?
        var validBefore: UInt64?
        var conflicted = false
    }

    private let gate: RemoteVerifierSigningGate
    private let log: MembershipLog
    private let origin: String
    private let journal: RemoteMemberVerifierJournal
    private let now: () -> UInt64
    private let current: () -> Bool
    private var states: [RemoteMemberVerifierSlot: State]
    private var connections: [String: RemoteVerifierSigningGate.Connection] = [:]
    private var retired = false
    private var lastTime: UInt64

    /// The caller owns complete enumeration and protected retention of this roster,
    /// including unavailable processes. It must retire this owner on roster/account,
    /// key, recovery or transport-association changes; `current` checks those fences.
    public init(gate: RemoteVerifierSigningGate, log: MembershipLog, origin: String,
                slots: [RemoteMemberVerifierSlot], journal: RemoteMemberVerifierJournal, current: @escaping () -> Bool,
                now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) throws {
        try gate.requireMembership(log)
        guard PortalIntegrationRecord.validOrigin(origin), (1...4096).contains(slots.count),
              Set(slots).count == slots.count,
              Set(slots.map { [$0.memberID, $0.slot] }).count == slots.count,
              slots.allSatisfy({ slot in
                  guard let member = log.member(deviceId: slot.memberID), member.status == .active else { return false }
                  return member.kind == "native" || member.kind == "service"
              }) else { throw RemoteVerifierGateError.invalidRoster }
        self.gate = gate; self.log = log.snapshot(); self.origin = origin
        self.journal = journal
        self.current = current; self.now = now
        lastTime = now()
        try journal.require(log: log, origin: origin)
        states = Dictionary(uniqueKeysWithValues: slots.map {
            let retained = journal.retained($0)
            return ($0, State(highest: retained.highest, conflicted: retained.conflicted))
        })
        // Refuse an origin the shared report reader would normalize differently.
        for slot in slots {
            let challenge = try verifierReportChallenge(signer: signer(slot), slot: slot.slot, origin: origin,
                connection: 1, issuedAt: 1, expiresAt: 2)
            guard try parseVerifierReportChallenge(challengeJson: challenge).origin == origin else {
                throw RemoteVerifierGateError.invalidRoster
            }
        }
        for id in Set(slots.map(\.memberID)) { connections[id] = try gate.connect(.member(id)) }
    }

    deinit { for connection in connections.values { gate.disconnect(connection) } }

    /// Call before acquiring tokens or handing the challenge to a carrier.
    /// Beginning another attempt withdraws this slot's previous evidence immediately.
    public func begin(_ slot: RemoteMemberVerifierSlot, log: MembershipLog, wallMs: UInt64,
                      lifetime: UInt64 = 30_000) throws -> Challenge {
        let started = now()
        try check(log)
        guard (1...30_000).contains(lifetime) else { throw RemoteVerifierGateError.invalidInventory }
        var lifetime = lifetime
        if let member = log.member(deviceId: slot.memberID), member.kind == "service" {
            guard let expiry = member.expiresAt, wallMs < expiry else {
                retire(); throw RemoteVerifierGateError.staleMembership
            }
            lifetime = min(lifetime, expiry - wallMs)
        }
        guard var state = states[slot], !state.conflicted,
              state.generation < 9_007_199_254_740_991, (1...30_000).contains(lifetime),
              wallMs <= UInt64.max - lifetime, started <= UInt64.max - lifetime else {
            throw RemoteVerifierGateError.invalidRoster
        }
        state.inventory = nil; state.validBefore = nil; state.pending = nil
        state.generation += 1
        states[slot] = state
        withdraw(slot.memberID)
        let json = try verifierReportChallenge(signer: signer(slot), slot: slot.slot, origin: origin,
            connection: state.generation, issuedAt: wallMs, expiresAt: wallMs + lifetime)
        let challenge = Challenge(json: json, slot: slot, id: UUID())
        states[slot]?.pending = Pending(challenge: challenge, startedAt: started, lifetime: lifetime)
        return challenge
    }

    public func receive(_ reportJSON: String, for challenge: Challenge, log: MembershipLog, wallMs: UInt64) throws {
        try check(log)
        guard var state = states[challenge.slot], !state.conflicted else {
            throw RemoteVerifierGateError.staleConnection
        }
        if let consumed = state.consumed, consumed.challenge == challenge {
            let time = now()
            if time >= consumed.startedAt, time - consumed.startedAt < consumed.lifetime,
               let report = try? verifyVerifierReport(log: log, reportJson: reportJSON,
                   expectedChallengeJson: challenge.json, nowMs: wallMs),
               report.process != challenge.slot.process {
                try conflict(challenge.slot)
            }
            throw RemoteVerifierGateError.staleConnection
        }
        guard let pending = state.pending, pending.challenge == challenge else {
            throw RemoteVerifierGateError.staleConnection
        }
        do {
            let time = now()
            guard time >= pending.startedAt, time - pending.startedAt < pending.lifetime else {
                states[challenge.slot]?.pending = nil
                throw RemoteVerifierGateError.staleConnection
            }
            let report = try verifyVerifierReport(log: log, reportJson: reportJSON,
                expectedChallengeJson: challenge.json, nowMs: wallMs)
            // Only an authenticated matching response consumes this challenge. Wrong
            // signer/slot/signature input cannot consume another process's expectation.
            state.pending = nil
            state.consumed = pending
            states[challenge.slot] = state
            // An authenticated ancestor cannot authorize signing, but its process
            // mismatch still conflicts with the protected roster in either order.
            guard report.process == challenge.slot.process else {
                try conflict(challenge.slot)
                throw RemoteVerifierGateError.staleConnection
            }
            guard report.atHead, report.head == self.log.head() else {
                throw RemoteVerifierGateError.staleMembership
            }
            if let highest = state.highest {
                guard report.inventory.version >= highest.version,
                      Set(highest.actions).isSubset(of: Set(report.inventory.actions)),
                      report.inventory.version != highest.version || report.inventory == highest else {
                    throw RemoteVerifierGateError.downgradedInventory
                }
            }
            try journal.record(challenge.slot, inventory: report.inventory)
            try check(log)
            state.highest = report.inventory
            state.inventory = report.inventory
            state.validBefore = pending.startedAt + pending.lifetime
            states[challenge.slot] = state
            try refreshMember(challenge.slot.memberID)
        } catch {
            states[challenge.slot]?.inventory = nil
            states[challenge.slot]?.validBefore = nil
            withdraw(challenge.slot.memberID)
            if journal.storageUncertain { retire() }
            throw error
        }
    }

    /// A superseded request's failure cannot clear newer evidence.
    public func failed(_ challenge: Challenge) {
        guard states[challenge.slot]?.pending?.challenge == challenge else { return }
        states[challenge.slot]?.pending = nil
        states[challenge.slot]?.inventory = nil
        states[challenge.slot]?.validBefore = nil
        withdraw(challenge.slot.memberID)
    }

    /// Recheck synchronously at the protected signing boundary, with the fresh log.
    public func refresh(log: MembershipLog, wallMs: UInt64) throws {
        try check(log)
        for id in Set(states.keys.map(\.memberID)) {
            if let member = log.member(deviceId: id), member.kind == "service",
               member.expiresAt.map({ wallMs >= $0 }) != false {
                retire(); throw RemoteVerifierGateError.staleMembership
            }
        }
        for id in Set(states.keys.map(\.memberID)) { try refreshMember(id) }
    }

    public func retire() {
        retired = true
        for id in Array(connections.keys) { withdraw(id) }
        for slot in Array(states.keys) {
            states[slot]?.pending = nil; states[slot]?.inventory = nil; states[slot]?.validBefore = nil
        }
    }

    private func check(_ log: MembershipLog) throws {
        do {
            let time = now()
            guard !retired, current(), time >= lastTime else { throw RemoteVerifierGateError.staleConnection }
            lastTime = time
            try gate.requireMembership(log)
            try journal.require(log: log, origin: origin)
            for slot in Array(states.keys) {
                let retained = journal.retained(slot)
                states[slot]?.highest = retained.highest
                let staleInventory: Bool
                if let inventory = states[slot]?.inventory, let highest = retained.highest {
                    staleInventory = inventory.version < highest.version ||
                        !Set(highest.actions).isSubset(of: Set(inventory.actions)) ||
                        (inventory.version == highest.version && inventory != highest)
                } else { staleInventory = false }
                if retained.conflicted || staleInventory {
                    states[slot]?.conflicted = retained.conflicted
                    states[slot]?.inventory = nil
                    states[slot]?.validBefore = nil
                    withdraw(slot.memberID)
                }
            }
        } catch { retire(); throw error }
    }

    private func signer(_ slot: RemoteMemberVerifierSlot) -> String {
        (log.member(deviceId: slot.memberID)?.kind == "service" ? "service:" : "member:") + slot.memberID
    }

    private func withdraw(_ id: String) {
        if let connection = connections.removeValue(forKey: id) { gate.disconnect(connection) }
    }

    private func conflict(_ slot: RemoteMemberVerifierSlot) throws {
        states[slot]?.conflicted = true
        withdraw(slot.memberID)
        do { try journal.record(slot, conflict: true) }
        catch { retire(); throw error }
    }

    private func refreshMember(_ id: String) throws {
        withdraw(id)
        let time = now()
        for slot in Array(states.keys) where slot.memberID == id {
            if let deadline = states[slot]?.validBefore, time >= deadline {
                states[slot]?.inventory = nil; states[slot]?.validBefore = nil
            }
        }
        let slots = states.filter { $0.key.memberID == id }.map(\.value)
        guard slots.allSatisfy({ !$0.conflicted && $0.pending == nil && $0.inventory != nil &&
            $0.validBefore.map { time < $0 } == true }),
              let first = slots.first?.inventory,
              let version = slots.compactMap({ $0.inventory?.version }).min(),
              let deadline = slots.compactMap(\.validBefore).min() else { return }
        let actions = slots.dropFirst().reduce(Set(first.actions)) { $0.intersection($1.inventory?.actions ?? []) }.sorted()
        guard !actions.isEmpty else { return }
        let connection = try gate.connect(.member(id))
        connections[id] = connection
        try gate.observeConsumer(VerifierInventory(version: version, actions: actions), on: connection,
            receivedAt: time, authorizationMilliseconds: deadline - time)
    }
}
