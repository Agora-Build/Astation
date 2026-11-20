import AtemClient
import CryptoKit
import Foundation

public protocol RemoteStationVerifierTransport: Sendable {
    func stationVerifiers(genesisHash: String) async throws -> RemoteStationVerifierSnapshot
}

/// Persist this roster only after protected manager review. An HTTP response cannot
/// authorize removing an unavailable participant from a previously accepted roster.
public struct RemoteStationVerifierRoster: Codable, Equatable, Sendable {
    public let origin: String
    public let generation: UInt64
    public let replicas: [String]

    private enum CodingKeys: String, CodingKey { case origin, generation, replicas }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(origin: fields.decode(String.self, forKey: .origin),
            generation: fields.decode(UInt64.self, forKey: .generation), replicas: fields.decode([String].self, forKey: .replicas))
    }

    public init(origin: String, generation: UInt64, replicas: [String]) throws {
        guard try RemoteRecoveryKit.checkedRelayURL(origin) == origin,
              let components = URLComponents(string: origin), let host = components.host,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              components.path.isEmpty, components.host == components.host?.lowercased(),
              components.port != (components.scheme == "https" ? 443 : 80),
              components.port == nil || (1...65535).contains(components.port!), components.url?.absoluteString == origin,
              (1...9_007_199_254_740_991).contains(generation),
              (1...64).contains(replicas.count), replicas == replicas.sorted(),
              Set(replicas).count == replicas.count, replicas.allSatisfy(Self.validID) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        self.origin = origin; self.generation = generation; self.replicas = replicas
    }

    public func verifierID(_ replica: String) -> RemoteVerifierID {
        let digest = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return .stationReplica(digest + ":" + replica)
    }

    private static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 58, 45].contains($0)
        }
    }
}

public struct RemoteStationVerifierSnapshot: Sendable {
    public struct Replica: Sendable {
        public let id: String
        public let connectionGeneration: UInt64?
        public let version: UInt32?
        public let actions: [String]?
        public let authorizationMilliseconds: UInt64?

        var inventory: VerifierInventory? {
            guard let version, let actions else { return nil }
            return VerifierInventory(version: version, actions: actions)
        }
    }

    public let roster: RemoteStationVerifierRoster
    public let accountID: String
    public let genesisHash: String
    public let head: LogHead
    public let replicas: [Replica]
    public let requestStartedAt: UInt64

    static func decode(_ bytes: Data, origin: String, genesis: String, startedAt: UInt64) throws -> Self {
        guard bytes.count <= 262_144, let text = String(data: bytes, encoding: .utf8) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        // The shared JSON reader refuses duplicate keys before Foundation reads fields.
        _ = try canonicalJson(json: text)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["origin", "roster_generation", "account_id", "genesis_hash", "head", "replicas"],
              object["origin"] as? String == origin, object["genesis_hash"] as? String == genesis,
              let account = object["account_id"] as? String, RemoteRecoveryKit.validID(account),
              let generation = integer(object["roster_generation"]),
              let head = object["head"] as? [String: Any], Set(head.keys) == ["seq", "hash"],
              let seq = integer(head["seq"]), let hash = head["hash"] as? String, RemoteRecoveryKit.validHash(hash),
              let rows = object["replicas"] as? [[String: Any]], (1...64).contains(rows.count) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        let replicas = try rows.map { row -> Replica in
            guard let id = row["id"] as? String else { throw RemoteRecoveryTransportError.invalidResponse }
            let keys = Set(row.keys)
            guard keys == ["id"] || keys == ["id", "connection_generation"] ||
                    keys == ["id", "connection_generation", "verifier", "authorization_ms_left"] else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            let connection = row["connection_generation"].flatMap { integer($0) }
            if row["connection_generation"] != nil && connection == nil { throw RemoteRecoveryTransportError.invalidResponse }
            guard let value = row["verifier"] else {
                return Replica(id: id, connectionGeneration: connection, version: nil, actions: nil, authorizationMilliseconds: nil)
            }
            guard let verifier = value as? [String: Any], Set(verifier.keys) == ["version", "actions"],
                  let version = integer(verifier["version"], maximum: UInt64(UInt32.max)),
                  let actions = verifier["actions"] as? [String], (1...64).contains(actions.count),
                  actions == actions.sorted(), Set(actions).count == actions.count,
                  actions.allSatisfy({ action in
                      let b = Array(action.utf8)
                      return (1...32).contains(b.count) && (97...122).contains(b[0]) &&
                          b.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
                  }), let lifetime = integer(row["authorization_ms_left"], maximum: 30_000) else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            return Replica(id: id, connectionGeneration: connection, version: UInt32(version), actions: actions,
                authorizationMilliseconds: lifetime)
        }
        let roster = try RemoteStationVerifierRoster(origin: origin, generation: generation, replicas: replicas.map(\.id))
        return Self(roster: roster, accountID: account, genesisHash: genesis,
            head: LogHead(seq: seq, hash: hash), replicas: replicas, requestStartedAt: startedAt)
    }

    private static func integer(_ value: Any?, maximum: UInt64 = 9_007_199_254_740_991) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              (1...maximum).contains(n.uint64Value), n.stringValue == String(n.uint64Value) else { return nil }
        return n.uint64Value
    }
}

/// One owner accepts the roster; each HTTP poll supplies only short-lived evidence
/// for that exact roster/head. No report or confirmation survives reconstruction.
@MainActor
public final class RemoteStationVerifierEvidence {
    public struct Poll: Equatable { fileprivate let id: UUID }
    private let gate: RemoteVerifierSigningGate
    private let roster: RemoteStationVerifierRoster
    private let account: String
    private let genesis: String
    private let head: LogHead
    private var poll: Poll?
    private var connections: [String: RemoteVerifierSigningGate.Connection] = [:]
    private var generations: [String: UInt64] = [:]

    public init(gate: RemoteVerifierSigningGate, roster: RemoteStationVerifierRoster, log: MembershipLog) throws {
        // Revalidate decoded checkpoints instead of trusting synthesized Codable initializers.
        _ = try RemoteStationVerifierRoster(origin: roster.origin, generation: roster.generation, replicas: roster.replicas)
        self.gate = gate; self.roster = roster
        account = log.accountId(); genesis = log.genesisHash(); head = log.head()
    }

    deinit { for connection in connections.values { gate.disconnect(connection) } }

    public func begin() -> Poll {
        let next = Poll(id: UUID()); poll = next
        return next
    }

    public func receive(_ snapshot: RemoteStationVerifierSnapshot, for expected: Poll) throws {
        guard poll == expected else { throw RemoteVerifierGateError.staleConnection }
        poll = nil
        disconnectEvidence()
        guard snapshot.roster == roster, snapshot.accountID == account, snapshot.genesisHash == genesis, snapshot.head == head else {
            throw RemoteVerifierGateError.staleMembership
        }
        for replica in snapshot.replicas {
            if let previous = generations[replica.id], let current = replica.connectionGeneration, current < previous {
                throw RemoteVerifierGateError.staleConnection
            }
        }
        do {
            for replica in snapshot.replicas {
                if let generation = replica.connectionGeneration { generations[replica.id] = generation }
                let connection = try gate.connect(roster.verifierID(replica.id))
                connections[replica.id] = connection
                if let inventory = replica.inventory, let lifetime = replica.authorizationMilliseconds {
                    try gate.observeConsumer(inventory, on: connection, receivedAt: snapshot.requestStartedAt,
                        authorizationMilliseconds: lifetime)
                }
            }
        } catch { disconnectEvidence(); throw error }
    }

    public func failed(_ expected: Poll) {
        guard poll == expected else { return }
        disconnect()
    }

    public func disconnect() { poll = nil; disconnectEvidence() }

    private func disconnectEvidence() {
        for connection in connections.values { gate.disconnect(connection) }
        connections.removeAll()
    }
}
