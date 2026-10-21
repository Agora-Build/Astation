import AtemClient
import Foundation

/// A restore never uses a relay-selected root or a persisted host challenge as freshness proof.
@MainActor
public final class RemoteRecoveryRestore {
    public enum Phase: Equatable {
        case needsFetch
        case waitingForHost([String])
        case readyToEnroll
        case enrollmentPending
        case published
        case refused(String)
        case storageUncertain
    }

    public struct Probe: Sendable {
        public let id: UUID
        public let hostID: String
        public let frame: Data
    }

    private struct PendingProbe {
        let connection: ClientConnection
        let frame: Data
        let deadline: UInt64
    }
    private struct StoredKey: Codable { let kid: String; let bytes: Data }
    private struct Checkpoint: Codable {
        var version = 1
        let accountID: String
        let genesisHash: String
        let kitTag: Data
        let keys: [StoredKey]
        let entries: [String]
        let prepared: String?
        let published: Bool
        let stopped: String?
    }

    public let kit: RemoteRecoveryKit
    public private(set) var phase: Phase = .needsFetch
    public var statusText: String {
        switch phase {
        case .needsFetch: return "Checking your account's signed device list."
        case .waitingForHost: return "Recovery needs to reach one of your Atem hosts to confirm the device list is current. Turn one on or join its network, then retry."
        case .readyToEnroll: return "Your encrypted data is recovered. Confirm adding this device to your account."
        case .enrollmentPending: return "Saving this device's recovery request. Retry safely if the connection is interrupted."
        case .published: return "Recovery requested. Another trusted device can approve it now; otherwise each host waits 24 hours before granting access."
        case .refused: return "Recovery could not confirm this account's current state. Your existing account was retained."
        case .storageUncertain: return RemoteRecoveryError.storageUncertain.localizedDescription
        }
    }
    private var core: RestoreSession
    private let persist: (Data) throws -> Void
    private var fetched: (entries: [String], envelope: String, log: MembershipLog)?
    private var probes: [UUID: PendingProbe] = [:]
    private var accepts: [(pair: HostAcceptPair, deadline: UInt64)] = []
    private var confirmed = false
    private var operating = false
    private var published = false
    private var stopped: String?
    private var keys: [AccountKey] = []
    private var freshnessGeneration = UUID()

    /// A bad kit is rejected by RemoteRecoveryKit before any transport or store is invoked.
    public init(kit: RemoteRecoveryKit, checkpoint: Data? = nil, persist: @escaping (Data) throws -> Void) throws {
        self.kit = kit
        self.persist = persist
        let handle = kit.handle
        if let checkpoint {
            guard checkpoint.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
            let saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
            guard saved.version == 1, saved.accountID == kit.accountID, saved.genesisHash == kit.genesisHash,
                  saved.kitTag == handle.kitTag(), !saved.published || saved.prepared == nil else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
            if let prepared = saved.prepared {
                core = try RestoreSession.resume(r: handle.secretR(), accountId: kit.accountID,
                    genesisHash: kit.genesisHash, kitTag: handle.kitTag(), preparedJson: prepared)
            } else {
                core = try RestoreSession.read(r: handle.secretR(), accountId: kit.accountID,
                    genesisHash: kit.genesisHash, kitTag: handle.kitTag())
            }
            // Stored keys/head are never treated as a fresh restore after a restart.
            published = saved.published
            stopped = saved.stopped
            if let stopped { phase = .refused(stopped) }
        } else {
            core = try RestoreSession.read(r: handle.secretR(), accountId: kit.accountID,
                genesisHash: kit.genesisHash, kitTag: handle.kitTag())
        }
    }

    /// Only an independently anchored, fully verified chain may supply probe host keys.
    public func fetched(entries: [String], envelopeJSON: String, now: HostClock) throws {
        try available()
        invalidateFreshness()
        do {
            let log = try MembershipLog.verify(accountId: kit.accountID, genesisHash: kit.genesisHash, entries: entries, now: now)
            fetched = (entries, envelopeJSON, log)
            _ = try attempt(now: now) // Produces the shared "no host reachable" waiting notice, with no write.
        } catch {
            if case .waitingForHost = phase { return }
            fetched = nil
            throw error
        }
    }

    public func beginHostProbe(hostID: String, replacementDeviceID: String, now: HostClock) throws -> Probe {
        try available()
        for id in probes.keys.filter({ probes[$0]!.deadline <= now.monoMs }) {
            probes.removeValue(forKey: id)?.connection.disconnect()
        }
        accepts.removeAll { $0.deadline <= now.monoMs }
        guard !confirmed, let fetched, probes.count + accepts.count < 64,
              now.monoMs <= UInt64.max - 10_000 else { throw RemoteRecoveryError.busy }
        let connection = try ClientConnection(hostId: hostID,
            identity: ClientIdentity(kind: .native, deviceId: replacementDeviceID, keyId: "recovery-probe", grantJson: nil),
            needBefore: nil)
        let frame = try connection.start(log: fetched.log, nowMs: now.monoMs)
        let id = UUID()
        probes[id] = PendingProbe(connection: connection, frame: frame, deadline: now.monoMs + 10_000)
        return Probe(id: id, hostID: hostID, frame: frame)
    }

    /// The accept must answer a challenge generated by this live restore, within its deadline.
    public func receivedHostAccept(_ frame: Data, probeID: UUID, now: HostClock) throws {
        try available()
        guard let probe = probes.removeValue(forKey: probeID), let fetched else { throw RemoteChannelError.staleLink }
        defer { probe.connection.disconnect() }
        guard now.monoMs < probe.deadline, frame.count <= 65_536,
              let initJSON = String(data: probe.frame, encoding: .utf8),
              let acceptJSON = String(data: frame, encoding: .utf8) else { throw RemoteChannelError.deadlineExceeded }
        _ = try verifyHostAccept(initJson: initJSON, acceptJson: acceptJSON, log: fetched.log)
        accepts.append((HostAcceptPair(initJson: initJSON, acceptJson: acceptJSON), probe.deadline))
    }

    /// Keys and their verified chain commit together before enrollment or key installation is exposed.
    @discardableResult
    public func attempt(now: HostClock) throws -> RestoredInfo {
        try available()
        guard let fetched else { throw RemoteChannelError.notReady }
        confirmed = false
        keys = []
        let generation = freshnessGeneration
        operating = true
        defer { operating = false }
        do {
            let proofs = accepts.filter { now.monoMs < $0.deadline }.map(\.pair)
            let result = try core.attempt(relayEntries: fetched.entries, envelopeJson: fetched.envelope, hostAccepts: proofs, now: now)
            try checkpoint(keys: result.keys)
            guard generation == freshnessGeneration else { throw RemoteChannelError.staleLink }
            keys = result.keys
            confirmed = true
            phase = published ? .published : (core.outstanding() == nil ? .readyToEnroll : .enrollmentPending)
            return result
        } catch {
            guard phase != .storageUncertain else { throw error }
            if let hosts = core.waitingForHosts() { phase = .waitingForHost(hosts) }
            else { phase = .refused(core.lastErrorCode() ?? "restore_failed") }
            throw error
        }
    }

    /// The caller obtains fresh device-owner confirmation for this exact replacement member.
    public func enroll(confirmedMemberJSON: String, signedAt: UInt64) throws -> AppendRequest {
        try available()
        guard confirmed, !published, phase == .readyToEnroll else { throw RemoteChannelError.notReady }
        let generation = freshnessGeneration
        operating = true
        defer { operating = false }
        let request = try core.enroll(memberJson: confirmedMemberJSON, signedAt: signedAt)
        try checkpoint(keys: keys)
        guard generation == freshnessGeneration else { throw RemoteChannelError.staleLink }
        phase = .enrollmentPending
        return request
    }

    public func outstanding() throws -> AppendRequest? {
        try available()
        guard confirmed else { throw RemoteChannelError.notReady }
        return core.outstanding()
    }

    public func recoveredKeys() throws -> [AccountKey] {
        try available()
        guard confirmed else { throw RemoteChannelError.notReady }
        return keys
    }

    public func verifiedEntries() throws -> [String] {
        try available()
        guard confirmed, let log = core.log() else { throw RemoteChannelError.notReady }
        return log.entries()
    }

    @discardableResult
    public func relayStored(now: HostClock) throws -> EnrollmentOutcome {
        try available()
        guard confirmed, core.outstanding() != nil else { throw RemoteChannelError.notReady }
        operating = true
        defer { operating = false }
        let result = try core.appendStored(now: now)
        if case .published = result { published = true }
        try checkpoint(keys: keys)
        phase = published ? .published : .needsFetch
        return result
    }

    @discardableResult
    public func relayConflict(head: LogHead, entries: [String], more: Bool, now: HostClock) throws -> EnrollmentOutcome {
        try available()
        guard confirmed, core.outstanding() != nil else { throw RemoteChannelError.notReady }
        operating = true
        defer { operating = false }
        let previousLog = core.log()
        let result = try core.appendConflict(head: head, entries: entries, more: more, now: now)
        if case .stopped(let detail) = result { stopped = detail }
        // A verified conflict discards the core's restored result. Retain the old
        // checkpoint only for reconciliation; it never supplies fresh authority.
        try checkpoint(keys: [], fallbackLog: previousLog)
        invalidateFreshness()
        if let stopped { phase = .refused(stopped) }
        return result
    }

    /// Transport loss or a refetch removes all in-memory proof; a new challenge is mandatory.
    public func invalidateFreshness() {
        freshnessGeneration = UUID()
        confirmed = false
        keys = []
        for probe in probes.values { probe.connection.disconnect() }
        probes.removeAll()
        accepts.removeAll()
        if phase != .storageUncertain { phase = .needsFetch }
    }

    private func available() throws {
        guard phase != .storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard stopped == nil else { throw RemoteRecoveryError.requiresReview }
        guard !operating else { throw RemoteRecoveryError.busy }
    }

    private func checkpoint(keys: [AccountKey], fallbackLog: MembershipLog? = nil) throws {
        guard let log = core.log() ?? fallbackLog else { throw RemoteChannelError.notReady }
        let saved = Checkpoint(accountID: kit.accountID, genesisHash: kit.genesisHash, kitTag: kit.handle.kitTag(),
            keys: keys.map { StoredKey(kid: $0.kid, bytes: $0.k) }, entries: log.entries(),
            prepared: core.preparedJson(), published: published, stopped: stopped)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(saved)
            guard data.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
            try persist(data)
        } catch {
            confirmed = false
            self.keys = []
            phase = .storageUncertain
            throw error
        }
    }
}
