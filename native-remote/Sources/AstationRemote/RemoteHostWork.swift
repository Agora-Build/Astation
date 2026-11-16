import AtemClient
import Foundation

public struct RemoteWorkHost: Codable, Equatable, Hashable, Sendable {
    public let account_id: String
    public let atem_device_id: String
    public let host_trust_gen: UInt64

    public init(account: String, device: String, trust: UInt64) {
        account_id = account; atem_device_id = device; host_trust_gen = trust
    }
}

public struct RemoteLaunchProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let revision: UInt64
    public let label: String
    public let provider: String
}

public struct RemoteLaunchStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case starting, started, failed, outcome_unknown }
    public let request_id: String
    public let session_id: String
    public let process_gen: String
    public let state: State
}

/// Recovery metadata deliberately excludes message/context contents and credentials.
public struct RemoteLaunchRecord: Codable, Equatable, Identifiable, Sendable {
    public let host: RemoteWorkHost
    public let requestID: String
    public let profile: RemoteLaunchProfile
    public let expiresAt: UInt64
    public var status: RemoteLaunchStatus?
    public var refusal: String?
    public var id: String { requestID }
}

public struct RemoteWorkProgress: Codable, Equatable, Identifiable, Sendable {
    public struct Resolution: Codable, Equatable, Sendable {
        public let by: String
        public let at: UInt64
    }
    public let task_id: String
    public let receipt_id: String
    public let state: String
    public let detail: String
    public let result: RemoteWorkResult?
    public let resolved: Resolution?
    public var id: String { task_id }
}

public struct RemoteWorkResult: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public let version: UInt64
    public let digest: String
    public let text: String
}

public struct RemoteOutcomeAlert: Decodable, Equatable, Identifiable, Sendable {
    public let alert_id: String
    public let seq: UInt64
    public let kind: String
    public let host_id: String
    public let session_id: String
    public let task_id: String
    public let sender: String
    public let reason: String
    public let created_at: UInt64
    public var id: String { alert_id }
}

public struct RemoteOutcomeReview: Equatable, Identifiable, Sendable {
    public let alert: RemoteOutcomeAlert
    public let id: UUID
    fileprivate let generation: UUID
}

public struct RemoteMessageProgress: Decodable, Equatable, Identifiable, Sendable {
    public struct Recipient: Decodable, Equatable, Identifiable, Sendable {
        public struct Delivery: Decodable, Equatable, Sendable {
            public let state: String
            public let code: String?
            public let work: RemoteWorkProgress?
        }
        public let recipient_id: String
        public let delivery: Delivery
        public var id: String { recipient_id }
    }
    public let message_id: String
    public let digest: String
    public let sender: String
    public let recipients: [Recipient]
    public var id: String { message_id }
}

/// UI adapter for the shared SDK's host-work Family events. Only query operations
/// are retried: a lost launch response never creates another process.
@MainActor
public final class RemoteHostWork {
    public private(set) var profiles: [RemoteLaunchProfile] = []
    public private(set) var launches: [RemoteLaunchRecord]
    public private(set) var work: [RemoteWorkProgress] = []
    public private(set) var messages: [RemoteMessageProgress] = []
    public private(set) var status = "Connect a verified Atem to launch an agent."
    public private(set) var loadingProfiles = false
    public private(set) var available = false
    public private(set) var storageFailed = false
    public private(set) var needsReconnect = false
    public private(set) var trackingStatus: String?
    public private(set) var alerts: [RemoteOutcomeAlert] = []
    public private(set) var loadingAlerts = false
    public private(set) var alertsLoaded = false
    public private(set) var alertStatus: String?
    public var onChange: (() -> Void)?
    public var onStarted: ((RemoteLaunchStatus) -> Void)?

    private struct Pending {
        let op: String
        let identity: String?
        let sent: UInt64
    }
    private var host: RemoteWorkHost?
    private var attachment: String?
    private var features: Set<String> = []
    private var hasControl = false
    private let resolutionEnabled: Bool
    private var alertScan: [RemoteOutcomeAlert] = []
    private var settledTasks: Set<String> = []
    private var lastAlertQuery: UInt64 = 0
    private var outcomeGeneration = UUID()
    private var pending: [String: Pending] = [:]
    private var lastQuery: UInt64 = 0
    private var trackedTasks: [RemoteWorkHost: Set<String>] = [:]
    private var trackedMessages: [RemoteWorkHost: Set<String>] = [:]
    private let save: ([RemoteLaunchRecord]) throws -> Void
    private let send: (String) -> Bool
    private let clock: () -> UInt64
    private let makeID: () -> String

    public init(load: () throws -> [RemoteLaunchRecord], save: @escaping ([RemoteLaunchRecord]) throws -> Void,
                clock: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) },
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
                resolutionEnabled: Bool = false,
                send: @escaping (String) -> Bool) {
        self.save = save; self.send = send; self.clock = clock; self.makeID = makeID
        self.resolutionEnabled = resolutionEnabled
        do {
            let records = try load()
            guard records.count <= 4096, Set(records.map(\.requestID)).count == records.count,
                  records.allSatisfy({ Self.uuid($0.requestID) && $0.expiresAt <= 9_007_199_254_740_991
                      && ($0.status == nil || $0.status?.request_id == $0.requestID) }) else {
                throw RemoteChannelError.invalidInput
            }
            launches = records
        } catch {
            launches = []; storageFailed = true
            status = "Launch recovery data is unreadable. New launches are disabled."
        }
    }

    public func connected(host: RemoteWorkHost?, attachment: String?, features: Set<String>, control: Bool) {
        guard self.host != host || self.attachment != attachment || self.features != features
                || hasControl != control
                || available != (host != nil && attachment != nil && control && features.contains("host.launch")) else { return }
        self.host = host; self.attachment = attachment; self.features = features
        hasControl = control
        available = host != nil && attachment != nil && control && features.contains("host.launch")
        pending = [:]; profiles = []; work = []; messages = []; loadingProfiles = false; lastQuery = 0; needsReconnect = false
        trackingStatus = nil
        alerts = []; alertScan = []; settledTasks = []; loadingAlerts = false; alertsLoaded = false; alertStatus = nil; lastAlertQuery = 0
        outcomeGeneration = UUID()
        if storageFailed { status = "Launch recovery data is unreadable. New launches are disabled." }
        else if available { status = "Choose a launch profile approved on this host." }
        else if host != nil { status = "Remote launch is unavailable. Enable hosting and approve a profile on Atem." }
        else { status = "Reconnect to check saved launches. Unconfirmed launches are never replayed." }
        onChange?()
        if available { refreshProfiles() }
        if host != nil { refresh() }
        refreshAlerts()
    }

    public var currentLaunches: [RemoteLaunchRecord] { launches.filter { $0.host == host }.reversed() }
    public var canTrackMessages: Bool { canQueryReceipts && features.contains("host.messages") }
    public var canTrackTasks: Bool { canQueryReceipts && features.contains("host.work") }
    public var canReviewOutcomes: Bool { canQueryReceipts && hasControl && features.contains("host.alerts") }
    public var canResolveOutcomes: Bool { canReviewOutcomes && resolutionEnabled && features.contains("host.delegated") }
    public func isCheckingOutcome(_ taskID: String) -> Bool { pending.values.contains { $0.identity == taskID && $0.op != "alert_list" } }
    public func canResolve(_ review: RemoteOutcomeReview) -> Bool {
        canResolveOutcomes && alertsLoaded && review.generation == outcomeGeneration && alerts.contains(review.alert)
            && !isCheckingOutcome(review.alert.task_id)
    }
    public func reviewOutcome(_ alert: RemoteOutcomeAlert) -> RemoteOutcomeReview? {
        guard canResolveOutcomes, alertsLoaded, alerts.contains(alert), !isCheckingOutcome(alert.task_id) else { return nil }
        return RemoteOutcomeReview(alert: alert, id: UUID(), generation: outcomeGeneration)
    }
    private var canQueryReceipts: Bool { host != nil && attachment != nil && !storageFailed && !needsReconnect }

    public func refreshProfiles() {
        guard available, !loadingProfiles, !storageFailed else { return }
        loadingProfiles = true
        if !request("host_profiles") { loadingProfiles = false }
        onChange?()
    }

    @discardableResult
    public func launch(_ profile: RemoteLaunchProfile) -> String? {
        guard available, !storageFailed, let host, profiles.contains(profile), launches.count < 4096,
              !needsReconnect, !currentLaunches.contains(where: { ($0.status == nil && $0.refusal == nil) || $0.status?.state == .starting }) else { return nil }
        let record = RemoteLaunchRecord(host: host, requestID: makeID(), profile: profile,
            expiresAt: clock() + 5 * 60_000, status: nil, refusal: nil)
        guard Self.uuid(record.requestID), persist(launches + [record]) else { return nil }
        // Persist before sending, even when a socket failure makes delivery uncertain.
        _ = request("host_launch", identity: record.requestID, fields: ["request_id": record.requestID,
            "profile_id": profile.id, "profile_revision": profile.revision, "expires_at": record.expiresAt])
        status = "Checking launch. A started process may still be preparing its chat."
        onChange?()
        return record.requestID
    }

    public func refresh() {
        guard let host, attachment != nil, !storageFailed, !needsReconnect else { return }
        for record in currentLaunches where available && ((record.status == nil && record.refusal == nil) || record.status?.state == .starting) {
            guard pending.count < 32 else { break }
            if !pending.values.contains(where: { $0.identity == record.requestID }) {
                _ = request("host_launch_query", identity: record.requestID, fields: ["request_id": record.requestID])
            }
        }
        for id in trackedTasks[host] ?? [] where features.contains("host.work") {
            guard pending.count < 32 else { break }
            if let progress = work.first(where: { $0.task_id == id }),
               ["completed", "failed", "cancelled", "expired"].contains(progress.state) { continue }
            if !pending.values.contains(where: { $0.identity == id }) {
                _ = request("work_query", identity: id, fields: ["task_id": id])
            }
        }
        for id in trackedMessages[host] ?? [] where features.contains("host.messages") {
            guard pending.count < 32 else { break }
            if let receipt = messages.first(where: { $0.message_id == id }), receipt.recipients.allSatisfy({ recipient in
                guard let work = recipient.delivery.work else { return ["stored", "refused"].contains(recipient.delivery.state) }
                return ["completed", "failed", "cancelled", "expired"].contains(work.state)
            }) { continue }
            if !pending.values.contains(where: { $0.identity == id }) {
                _ = request("message_query", identity: id, fields: ["message_id": id])
            }
        }
        lastQuery = clock()
    }

    /// Only a completed scan can remove old cards. A failed later page is not
    /// evidence that an outcome was resolved on the host.
    public func refreshAlerts() {
        guard canReviewOutcomes, !loadingAlerts else { return }
        alertScan = []; loadingAlerts = true; alertsLoaded = false; alertStatus = nil; lastAlertQuery = clock()
        if !request("alert_list") { loadingAlerts = false; alertStatus = "Could not check outcomes. Retry the host connection." }
        onChange?()
    }

    /// The caller must show an explicit review. The SDK validates the complete
    /// resolution and correlates the host's exact result; no operation is replayed.
    @discardableResult
    public func resolve(_ review: RemoteOutcomeReview, failed detail: String) -> Bool {
        resolve(review, resolution: ["kind": "failed", "detail": detail])
    }

    @discardableResult
    public func resolve(_ review: RemoteOutcomeReview, done snapshotJSON: String) -> Bool {
        guard snapshotJSON.utf8.count <= 1_048_576,
              let canonical = try? canonicalJson(json: snapshotJSON),
              let snapshot = try? JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any] else {
            alertStatus = "Paste a published memory or vault result snapshot."; onChange?(); return false
        }
        return resolve(review, resolution: ["kind": "done", "result": snapshot])
    }

    private func resolve(_ review: RemoteOutcomeReview, resolution: [String: Any]) -> Bool {
        guard canResolve(review) else { return false }
        let sent = request("work_resolve", identity: review.alert.task_id,
            fields: ["task_id": review.alert.task_id, "resolution": resolution])
        alertStatus = sent ? "Checking the host's resolution receipt."
            : "Resolution was not confirmed. Check the result snapshot and connection, then refresh outcomes."
        onChange?(); return sent
    }

    public func tick() {
        guard !storageFailed else { return }
        let time = clock()
        let expired = pending.filter { time >= $0.value.sent && time - $0.value.sent >= 15_000 }
        for (id, exchange) in expired {
            pending.removeValue(forKey: id)
            if exchange.op == "host_profiles" { loadingProfiles = false }
            if exchange.op == "alert_list" { loadingAlerts = false; alertScan = [] }
        }
        if !expired.isEmpty {
            needsReconnect = true
            status = "Response delayed. Reconnect to check the original request. No launch is replayed."
            if expired.values.contains(where: { ["message_query", "work_query"].contains($0.op) }) {
                trackingStatus = "Receipt response delayed. Reconnect to check again."
            }
            if expired.values.contains(where: { ["alert_list", "work_resolve"].contains($0.op) }) {
                alertStatus = "Outcome response delayed. Reconnect to check host state. A resolution is never replayed."
            }
            onChange?()
        }
        if time >= lastQuery && time - lastQuery >= 5_000 { refresh() }
        if time >= lastAlertQuery && time - lastAlertQuery >= 30_000 { refreshAlerts() }
    }

    /// Called only with an event already authenticated and correlated by atem-client.
    @discardableResult
    public func receive(_ json: String) -> Bool {
        guard !storageFailed, let raw = try? canonicalJson(json: json),
              let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              root["type"] as? String == "session", let data = root["data"] as? [String: Any],
              let re = data["re"] as? String, let exchange = pending[re] else { return false }
        if data["op"] as? String == "error" {
            pending.removeValue(forKey: re)
            if exchange.op == "host_profiles" { loadingProfiles = false }
            let code = data["code"] as? String ?? "unknown_error"
            if exchange.op == "alert_list" {
                loadingAlerts = false; alertScan = []
                alertStatus = "Atem could not list outcomes: \(code). Refresh to start a new scan."
            }
            if exchange.op == "work_resolve" {
                alertStatus = "Resolution was not confirmed: \(code). Refresh outcomes before deciding again."
                alertsLoaded = false; outcomeGeneration = UUID()
                lastAlertQuery = 0
            }
            if ["message_query", "work_query"].contains(exchange.op) {
                trackingStatus = "Atem refused the receipt lookup: \(code)."
            }
            if exchange.op == "host_launch", let index = launches.firstIndex(where: { $0.requestID == exchange.identity && $0.host == host }) {
                var next = launches; next[index].refusal = code
                guard persist(next) else { return true }
            }
            status = "Atem refused \(exchange.op): \(code). Saved launches can be checked again."
            onChange?(); return true
        }
        guard data["op"] as? String == "host_work_result", data["attachment_gen"] as? String == attachment,
              let hostJSON = data["host"], let result = data["result"] as? [String: Any],
              (try? Self.decode(RemoteWorkHost.self, hostJSON)) == host else { return false }
        do {
            switch result["kind"] as? String {
            case "profiles" where exchange.op == "host_profiles":
                profiles = try Self.decode([RemoteLaunchProfile].self, result["profiles"] as Any)
                loadingProfiles = false
                status = profiles.isEmpty ? "No launch profiles are approved for this device on Atem." : "Choose a launch profile approved on this host."
            case "launch" where ["host_launch", "host_launch_query"].contains(exchange.op):
                let launch = try Self.decode(RemoteLaunchStatus.self, result["launch"] as Any)
                guard launch.request_id == exchange.identity,
                      let index = launches.firstIndex(where: { $0.host == host && $0.requestID == launch.request_id }) else { return false }
                let previous = launches[index].status
                if let previous {
                    guard previous.session_id == launch.session_id, previous.process_gen == launch.process_gen,
                          previous.state == .starting || previous == launch else { return false }
                }
                var next = launches; next[index].status = launch
                guard persist(next) else { return true }
                status = launch.state == .started ? "Agent started. Attach when its session is ready."
                    : launch.state == .starting ? "Starting agent..."
                    : launch.state == .outcome_unknown ? "Launch outcome is unknown. Check the host before starting another agent."
                    : "Agent launch failed. Review the approved profile on the host."
                if launch.state == .started && previous?.state != .started { onStarted?(launch) }
            case "work" where ["work_query", "work_resolve"].contains(exchange.op):
                let progress = try Self.decode(RemoteWorkProgress.self, result["work"] as Any)
                guard progress.task_id == exchange.identity else { return false }
                if let index = work.firstIndex(where: { $0.task_id == progress.task_id }) { work[index] = progress }
                else { work.append(progress) }
                if ["awaiting_result", "completed", "failed", "cancelled", "expired"].contains(progress.state) {
                    settledTasks.insert(progress.task_id)
                    alerts.removeAll { $0.task_id == progress.task_id }
                }
                if exchange.op == "work_resolve" { alertStatus = "Resolution confirmed by Atem." }
                trackingStatus = nil
            case "alerts" where exchange.op == "alert_list":
                let page = try Self.decode([RemoteOutcomeAlert].self, result["alerts"] as Any)
                guard let more = result["more"] as? Bool, page.count <= 64, !more || !page.isEmpty,
                      alertScan.count + page.count <= 256,
                      !more || alertScan.count + page.count < 256 else { return false }
                var previous = alertScan.last?.seq ?? 0
                var ids = Set(alertScan.map(\.id)), tasks = Set(alertScan.map(\.task_id))
                for alert in page {
                    guard alert.host_id == host?.atem_device_id, alert.seq > previous,
                          ids.insert(alert.id).inserted, tasks.insert(alert.task_id).inserted else { return false }
                    previous = alert.seq
                }
                alertScan += page
                pending.removeValue(forKey: re)
                if more, let after = page.last?.id {
                    if !request("alert_list", identity: after, fields: ["after": after]) {
                        loadingAlerts = false; alertScan = []
                        alertStatus = "Outcome scan was interrupted. Refresh to check again."
                    }
                } else {
                    alerts = alertScan.filter { !settledTasks.contains($0.task_id) }
                    alertScan = []; loadingAlerts = false; alertsLoaded = true
                    alertStatus = nil
                }
            case "message" where exchange.op == "message_query":
                let message = try Self.decode(RemoteMessageProgress.self, result["message"] as Any)
                guard message.message_id == exchange.identity else { return false }
                if let index = messages.firstIndex(where: { $0.message_id == message.message_id }) { messages[index] = message }
                else { messages.append(message) }
                trackingStatus = nil
            default: return false
            }
            pending.removeValue(forKey: re); onChange?(); return true
        } catch { return false }
    }

    public func track(taskID: String) {
        guard let host, canTrackTasks else { return }
        guard Self.uuid(taskID), trackedTasks[host]?.contains(taskID) == true || (trackedTasks[host]?.count ?? 0) < 16 else {
            trackingStatus = "Enter a valid task UUID. Up to 16 tasks can be tracked per host."; onChange?(); return
        }
        trackingStatus = "Tracking task receipt."
        trackedTasks[host, default: []].insert(taskID)
        refresh()
        onChange?()
    }

    public func track(messageID: String) {
        guard let host, canTrackMessages else { return }
        guard Self.uuid(messageID), trackedMessages[host]?.contains(messageID) == true || (trackedMessages[host]?.count ?? 0) < 16 else {
            trackingStatus = "Enter a valid message UUID. Up to 16 messages can be tracked per host."; onChange?(); return
        }
        trackingStatus = "Tracking message receipt."
        trackedMessages[host, default: []].insert(messageID)
        refresh()
        onChange?()
    }

    private func request(_ op: String, identity: String? = nil, fields: [String: Any] = [:]) -> Bool {
        guard let host, attachment != nil, !needsReconnect, pending.count < 32 else { return false }
        let id = makeID()
        var data = fields
        data["v"] = 1; data["op"] = op; data["id"] = id
        data["host"] = ["account_id": host.account_id, "atem_device_id": host.atem_device_id, "host_trust_gen": host.host_trust_gen]
        guard let bytes = try? JSONSerialization.data(withJSONObject: ["type": "session", "data": data]),
              let json = String(data: bytes, encoding: .utf8) else { return false }
        pending[id] = Pending(op: op, identity: identity, sent: clock())
        if !send(json) { pending.removeValue(forKey: id); return false }
        return true
    }

    private func persist(_ records: [RemoteLaunchRecord]) -> Bool {
        do { try save(records); launches = records; return true }
        catch { storageFailed = true; status = "Could not save launch recovery data. New launches are disabled."; onChange?(); return false }
    }

    private static func uuid(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
