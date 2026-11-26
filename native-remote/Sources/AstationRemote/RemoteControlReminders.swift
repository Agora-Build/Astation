import Foundation

/// Local notification bookkeeping only. Verified activity, never a push or a
/// storage receipt, determines whether a manager still needs to review a stop.
@MainActor
public final class RemoteControlReminders {
    private struct Station: Codable, Equatable {
        let origin: String
        let records: Set<String>
        let notifiedAt: UInt64
    }
    private struct Saved: Codable {
        let version: Int
        let account: String
        let genesis: String
        let device: String
        var stations: [Station]
    }
    private var saved: Saved
    private let persist: (Data) throws -> Void
    public private(set) var storageUncertain = false

    public init(accountID: String, genesisHash: String, deviceID: String, checkpoint: Data? = nil,
                persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validID(deviceID),
              RemoteRecoveryKit.validHash(genesisHash) else { throw RemoteRecoveryError.invalidCheckpoint }
        if let checkpoint {
            guard checkpoint.count <= 4 * 1024 * 1024,
                  let value = try? JSONDecoder().decode(Saved.self, from: checkpoint), value.version == 1,
                  value.account == accountID, value.genesis == genesisHash, value.device == deviceID,
                  value.stations.count <= 64, Set(value.stations.map(\.origin)).count == value.stations.count,
                  value.stations.allSatisfy({ PortalIntegrationRecord.validOrigin($0.origin) &&
                      !$0.records.isEmpty && $0.records.count <= 256 && $0.records.allSatisfy(Self.validRecordID) }) else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
            saved = value
        } else { saved = Saved(version: 1, account: accountID, genesis: genesisHash, device: deviceID, stations: []) }
        self.persist = persist
    }

    public static func reviewIDs(_ activity: [RemoteControlActivity]) -> Set<String> {
        let byID = Dictionary(activity.map { ($0.body.recordId, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(activity.filter { row in
            guard row.requiresManagerReview else { return false }
            // A second manager can lose access before their replacement takes effect.
            // Follow the saved copies to the last signed stop that hosts must apply.
            var copy = row
            var visited = Set<String>()
            while let id = copy.replacementRecordID {
                guard visited.insert(id).inserted, let next = byID[id] else { return true }
                guard next.signed else { break }
                copy = next
            }
            return !copy.allHostsApplied
        }.map { $0.body.recordId })
    }

    /// Commit before presentation. Store IDs and reminder times, never task,
    /// principal, signer, tool, or response content.
    public func offer(stationOrigin: String, activity: [RemoteControlActivity], now: UInt64) throws -> Bool {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard PortalIntegrationRecord.validOrigin(stationOrigin), activity.count <= 256,
              Set(activity.map { $0.body.recordId }).count == activity.count,
              activity.allSatisfy({ $0.body.accountId == saved.account && $0.body.genesisHash == saved.genesis &&
                  Self.validRecordID($0.body.recordId) && ($0.body.origin == nil || $0.body.origin == stationOrigin) }) else {
            throw RemoteChannelError.invalidInput
        }
        let ids = Self.reviewIDs(activity)
        let previous = saved.stations.first { $0.origin == stationOrigin }
        let notifiedAt = previous?.notifiedAt ?? now
        let changed = previous.map { !ids.isSubset(of: $0.records) } ?? true
        let due = !ids.isEmpty && (changed || (now >= notifiedAt && now - notifiedAt >= 86_400_000))
        var next = saved
        next.stations.removeAll { $0.origin == stationOrigin }
        if !ids.isEmpty {
            next.stations.append(Station(origin: stationOrigin, records: ids, notifiedAt: due ? now : notifiedAt))
        }
        next.stations.sort { $0.origin < $1.origin }
        guard next.stations.count <= 64 else { throw RemoteChannelWriteError.busy }
        guard next.stations != saved.stations else { return false }
        do { try persist(JSONEncoder().encode(next)) }
        catch { storageUncertain = true; throw RemoteRecoveryError.storageUncertain }
        saved = next
        return due
    }

    private static func validRecordID(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value) else { return false }
        return id.uuidString.lowercased() == value && value[value.index(value.startIndex, offsetBy: 14)] == "4"
    }
}
