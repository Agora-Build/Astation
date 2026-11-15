import Foundation

/// Only authenticated complete host scans enter this book. Notification state
/// is committed before presentation; it does not authorize or settle any task.
@MainActor
public final class RemoteOutcomeReminders {
    private struct Host: Codable, Equatable {
        let identity: RemoteWorkHost
        var alerts: Set<String>
        var notifiedAt: UInt64
    }
    private struct Saved: Codable {
        let version: Int
        let account: String
        let genesis: String
        let device: String
        var hosts: [Host]
    }
    private var saved: Saved
    private let persist: (Data) throws -> Void
    public private(set) var storageUncertain = false

    public init(accountID: String, genesisHash: String, deviceID: String, checkpoint: Data? = nil,
                persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validID(deviceID),
              genesisHash.utf8.count == 64 else { throw RemoteRecoveryError.invalidCheckpoint }
        if let checkpoint {
            guard checkpoint.count <= 4 * 1024 * 1024,
                  let value = try? JSONDecoder().decode(Saved.self, from: checkpoint), value.version == 1,
                  value.account == accountID, value.genesis == genesisHash, value.device == deviceID,
                  value.hosts.count <= 64, Set(value.hosts.map { $0.identity.atem_device_id }).count == value.hosts.count,
                  value.hosts.allSatisfy({ $0.identity.account_id == accountID && $0.alerts.count <= 256 }) else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
            saved = value
        } else { saved = Saved(version: 1, account: accountID, genesis: genesisHash, device: deviceID, hosts: []) }
        self.persist = persist
    }

    /// Returns true for new alerts or after one day with unresolved outcomes.
    /// No task, sender, reason or result content is persisted here.
    public func offer(host: RemoteWorkHost, alerts: [RemoteOutcomeAlert], now: UInt64) throws -> Bool {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard host.account_id == saved.account, alerts.count <= 256,
              alerts.allSatisfy({ $0.host_id == host.atem_device_id }) else { throw RemoteChannelError.invalidInput }
        var next = saved
        let ids = Set(alerts.map(\.id))
        let previous = saved.hosts.first { $0.identity == host }
        let previousTime = previous?.notifiedAt ?? now
        let newAlerts = previous.map { !ids.isSubset(of: $0.alerts) } ?? true
        let due = !ids.isEmpty && (newAlerts || (now >= previousTime && now - previousTime >= 86_400_000))
        next.hosts.removeAll { $0.identity.atem_device_id == host.atem_device_id }
        if !ids.isEmpty {
            next.hosts.append(Host(identity: host, alerts: ids, notifiedAt: due ? now : previousTime))
        }
        next.hosts.sort { $0.identity.atem_device_id < $1.identity.atem_device_id }
        guard next.hosts.count <= 64 else { throw RemoteChannelWriteError.busy }
        guard next.hosts != saved.hosts else { return false }
        do { try persist(JSONEncoder().encode(next)) }
        catch { storageUncertain = true; throw RemoteRecoveryError.storageUncertain }
        saved = next
        return due
    }
}
