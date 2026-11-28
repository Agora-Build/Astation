import AtemClient
import Foundation

/// Protected observation history, not live capability evidence or a roster. Expiry,
/// restart and a new connection cannot forget an observed downgrade floor or conflict.
@MainActor
public final class RemoteMemberVerifierJournal {
    private struct Key: Hashable { let member: String; let slot: String }
    private struct Row: Codable {
        let member: String
        let slot: String
        var version: UInt32?
        var actions: [String]?
        var conflicted: Bool
        var inventory: VerifierInventory? {
            guard let version, let actions else { return nil }
            return VerifierInventory(version: version, actions: actions)
        }
    }
    private struct Checkpoint: Codable {
        let v: Int
        let account: String
        let genesis: String
        let origin: String
        let rows: [Row]
    }
    private let account: String
    private let genesis: String
    private let origin: String
    private let read: () throws -> Data?
    private let persist: (Data) throws -> Void
    private var saved: Data?
    private var rows: [Key: Row] = [:]
    public private(set) var storageUncertain = false

    public convenience init(log: MembershipLog, origin: String, creating: Bool = false) throws {
        let scope = hashFields(fields: ["astation-member-verifier-history-v1", log.accountId(), log.genesisHash(), origin].map { Data($0.utf8) })
        let store = try RemoteRecoveryStore(accountID: scope, operation: "member-verifiers")
        try self.init(log: log, origin: origin, creating: creating, read: { try store.read() }, persist: { try store.write($0) })
    }

    /// The backend must be protected, atomic and exclusively owned across app processes.
    /// Production uses the no-interaction Keychain store and its cross-process file lock.
    /// `creating` is only for the initial protected roster review. Reopening a
    /// previously accepted roster must use the default and refuse missing history.
    public init(log: MembershipLog, origin: String, creating: Bool = false, read: @escaping () throws -> Data?,
                persist: @escaping (Data) throws -> Void) throws {
        account = log.accountId(); genesis = log.genesisHash(); self.origin = origin
        self.read = read; self.persist = persist
        saved = try read()
        if saved == nil {
            guard creating else { throw RemoteVerifierGateError.invalidInventory }
            let bytes = try JSONEncoder().encode(Checkpoint(v: 1, account: account, genesis: genesis, origin: origin, rows: []))
            try persist(bytes)
            guard try read() == bytes else { throw RemoteRecoveryStoreError.changed }
            saved = bytes
        }
        if let saved {
            guard saved.count <= 4_194_304, let text = String(data: saved, encoding: .utf8) else {
                throw RemoteVerifierGateError.invalidInventory
            }
            _ = try canonicalJson(json: text)
            guard let raw = try JSONSerialization.jsonObject(with: saved) as? [String: Any],
                  Set(raw.keys) == ["v", "account", "genesis", "origin", "rows"],
                  let entries = raw["rows"] as? [[String: Any]], entries.count <= 4096,
                  entries.allSatisfy({ Set($0.keys) == ["member", "slot", "conflicted"] ||
                      Set($0.keys) == ["member", "slot", "version", "actions", "conflicted"] }) else {
                throw RemoteVerifierGateError.invalidInventory
            }
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: saved)
            guard checkpoint.v == 1, checkpoint.account == account, checkpoint.genesis == genesis,
                  checkpoint.origin == origin else { throw RemoteVerifierGateError.staleMembership }
            for row in checkpoint.rows {
                let key = Key(member: row.member, slot: row.slot)
                guard RemoteRecoveryKit.validID(row.member), RemoteRecoveryKit.validID(row.slot), rows[key] == nil,
                      row.inventory != nil || row.conflicted else { throw RemoteVerifierGateError.invalidInventory }
                if let inventory = row.inventory { try RemoteVerifierSigningGate.validateInventory(inventory) }
                rows[key] = row
            }
            guard entries.allSatisfy({ entry in
                !entry.values.contains(where: { $0 is NSNull })
            }) else { throw RemoteVerifierGateError.invalidInventory }
        }
    }

    func require(log: MembershipLog, origin: String) throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard log.accountId() == account, log.genesisHash() == genesis, origin == self.origin else {
            throw RemoteVerifierGateError.staleMembership
        }
        do {
            guard try read() == saved else { throw RemoteRecoveryStoreError.changed }
        } catch { storageUncertain = true; throw error }
    }

    func retained(_ slot: RemoteMemberVerifierSlot) -> (highest: VerifierInventory?, conflicted: Bool) {
        let row = rows[Key(member: slot.memberID, slot: slot.slot)]
        return (row?.inventory, row?.conflicted ?? false)
    }

    /// Conflicts belong to a member and slot even after its reviewed process is replaced.
    public func nativeConflicts(log: MembershipLog, origin: String) throws -> [(member: String, slot: String)] {
        try require(log: log, origin: origin)
        var conflicts: [(member: String, slot: String)] = []
        for row in rows.values where row.conflicted {
            guard let member = log.member(deviceId: row.member) else { throw RemoteVerifierGateError.staleMembership }
            if member.kind == "native" { conflicts.append((row.member, row.slot)) }
        }
        return conflicts.sorted { ($0.member, $0.slot) < ($1.member, $1.slot) }
    }

    func record(_ slot: RemoteMemberVerifierSlot, inventory: VerifierInventory? = nil, conflict: Bool = false) throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        let key = Key(member: slot.memberID, slot: slot.slot)
        var row = rows[key] ?? Row(member: slot.memberID, slot: slot.slot, conflicted: false)
        if let inventory {
            try RemoteVerifierSigningGate.validateInventory(inventory)
            if let highest = row.inventory {
                guard inventory.version >= highest.version, Set(highest.actions).isSubset(of: Set(inventory.actions)),
                      inventory.version != highest.version || inventory == highest else {
                    throw RemoteVerifierGateError.downgradedInventory
                }
            }
            row.version = inventory.version; row.actions = inventory.actions
        }
        row.conflicted = row.conflicted || conflict
        var next = rows; next[key] = row
        guard next.count <= 4096 else { throw RemoteVerifierGateError.invalidRoster }
        let ordered = next.values.sorted { [$0.member, $0.slot].lexicographicallyPrecedes([$1.member, $1.slot]) }
        let bytes = try JSONEncoder().encode(Checkpoint(v: 1, account: account, genesis: genesis, origin: origin, rows: ordered))
        guard bytes.count <= 4_194_304 else { throw RemoteVerifierGateError.invalidInventory }
        do {
            guard try read() == saved else { throw RemoteRecoveryStoreError.changed }
            try persist(bytes)
            guard try read() == bytes else { throw RemoteRecoveryStoreError.changed }
        } catch { storageUncertain = true; throw error }
        saved = bytes; rows = next
    }
}
