import AtemClient
import Foundation

/// Carries durable, already-signed host stops. Channel replies never acknowledge a Station feed.
@MainActor
public final class RemoteControlCarriage {
    private struct Pending {
        let id: String
        let records: [String]
        let deadline: UInt64
    }

    private let log: MembershipLog
    private let hostID: String
    private let records: () throws -> [String]
    private let send: (RemoteAgentOperation) throws -> String
    private let failed: () -> Void
    private let now: () -> UInt64
    private var head: LogHead?
    private var active = false
    private var pending: Pending?
    private var settled: [String: String] = [:]
    private var retryAt: UInt64 = 0
    private var timer: Task<Void, Never>?

    public init(log: MembershipLog, hostID: String, records: @escaping () throws -> [String],
        send: @escaping (RemoteAgentOperation) throws -> String, failed: @escaping () -> Void,
        now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) {
        self.log = log.snapshot()
        self.hostID = hostID
        self.records = records
        self.send = send
        self.failed = failed
        self.now = now
    }

    deinit { timer?.cancel() }

    public func welcomed(_ welcome: WelcomeInfo, automaticTimer: Bool = true) {
        guard !active, welcome.clientKind == "native", welcome.accountId == log.accountId(),
              welcome.atemDeviceId == hostID, welcome.hostTrustGen == log.host(hostId: hostID)?.hostTrustGen,
              welcome.features.contains("host.senders") else { return }
        head = welcome.head
        active = true
        refresh()
        if automaticTimer && active {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, self.active else { return }
                    if self.pending != nil || self.retryAt > 0 { self.refresh() }
                }
            }
        }
    }

    public func disconnect() {
        active = false
        timer?.cancel(); timer = nil
        pending = nil
        settled.removeAll()
    }

    public func refresh() {
        guard active else { return }
        if let pending {
            if now() >= pending.deadline { stop() }
            return
        }
        guard now() >= retryAt, let head else { return }
        retryAt = 0
        do {
            let relation = try log.relation(head: head)
            guard relation == .same || relation == .hostBehind else { throw RemoteChannelError.staleLink }
            let retained = try records()
            guard retained.count <= 256 else { throw RemoteChannelError.invalidInput }
            var available: [(id: String, json: String)] = []
            var seen = Set<String>()
            for json in retained {
                let body = try parseControlRecord(recordJson: json)
                guard body.principal.hasPrefix("host:"), body.accountId == log.accountId(),
                      body.genesisHash == log.genesisHash(), seen.insert(body.recordId).inserted,
                      case .valid = try verifyControlRecord(log: log, recordJson: json) else {
                    throw RemoteChannelError.invalidInput
                }
                if let previous = settled[body.recordId] {
                    guard previous == json else { throw RemoteChannelError.invalidInput }
                } else { available.append((body.recordId, json)) }
            }
            guard settled.count + available.count <= 256 else { throw RemoteChannelError.invalidInput }
            guard !available.isEmpty else { return }
            if relation == .hostBehind {
                var entries: [String] = []
                var bytes = 256
                for entry in log.entriesAfter(seq: head.seq).prefix(64) {
                    let size = entry.utf8.count + 1
                    if bytes + size > 262_144 { break }
                    entries.append(entry); bytes += size
                }
                guard !entries.isEmpty else { throw RemoteChannelError.invalidInput }
                let id = try send(.membership(entries))
                pending = Pending(id: id, records: [], deadline: try deadline())
                return
            }
            let id = UUID().uuidString.lowercased()
            let prefix = "{\"type\":\"session\",\"data\":{\"v\":1,\"op\":\"control_records\",\"id\":\"\(id)\",\"records\":["
            let suffix = "]}}"
            var batch: [(id: String, json: String)] = []
            var bytes = prefix.utf8.count + suffix.utf8.count
            for record in available.prefix(64) {
                let size = record.json.utf8.count + (batch.isEmpty ? 0 : 1)
                if bytes + size > 262_144 { break }
                batch.append(record); bytes += size
            }
            guard !batch.isEmpty else { throw RemoteChannelError.invalidInput }
            // Keep the exact saved signed objects. sendJson's shared reader validates the whole call.
            let json = prefix + batch.map(\.json).joined(separator: ",") + suffix
            pending = Pending(id: id, records: batch.map(\.json), deadline: try deadline())
            _ = try send(.message(json))
        } catch { stop() }
    }

    /// Consume only events emitted by the shared channel core, after strict validation/correlation.
    @discardableResult
    public func receiveVerified(_ event: ClientEvent) -> Bool {
        guard active else { return false }
        switch event {
        case .membershipHead(_, let received, _):
            head = received
            if pending?.records.isEmpty == true { pending = nil }
            retryAt = 0
            refresh()
            return false
        case .family(let family, let op, let json) where family == "session" && op == "control_records_result":
            guard let pending, !pending.records.isEmpty else { return true }
            do {
                // This projects the SDK-validated result into local delivery state, not Station ACKs.
                let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                guard let data = object?["data"] as? [String: Any], data["re"] as? String == pending.id,
                      let results = data["results"] as? [[String: Any]], results.count == pending.records.count else {
                    throw RemoteChannelError.invalidInput
                }
                for (result, record) in zip(results, pending.records) {
                    let body = try parseControlRecord(recordJson: record)
                    guard result["record_id"] as? String == body.recordId,
                          let outcome = result["result"] as? String,
                          ["applied", "duplicate", "pending", "refused"].contains(outcome) else {
                        throw RemoteChannelError.invalidInput
                    }
                    if outcome != "pending" { settled[body.recordId] = record }
                }
                self.pending = nil
                retryAt = try now().adding(5_000)
            } catch { stop() }
            return true
        case .error(_, let re, _, _):
            guard let pending, re == pending.id else { return false }
            self.pending = nil
            do { retryAt = try now().adding(5_000) } catch { stop() }
            return true
        default: return false
        }
    }

    private func deadline() throws -> UInt64 { try now().adding(30_000) }

    private func stop() {
        disconnect()
        failed()
    }
}

private extension UInt64 {
    func adding(_ interval: UInt64) throws -> UInt64 {
        let value = addingReportingOverflow(interval)
        guard !value.overflow else { throw RemoteChannelError.deadlineExceeded }
        return value.partialValue
    }
}
