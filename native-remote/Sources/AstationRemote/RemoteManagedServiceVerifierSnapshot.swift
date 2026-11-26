import AtemClient
import Foundation

public protocol RemoteManagedServiceVerifierTransport: Sendable {
    func managedServiceVerifiers(genesisHash: String, memberIDs: [String], expected: LogHead) async throws -> RemoteManagedServiceVerifierSnapshot
}

/// A Station can report only its own services, after opening their existing
/// protected keys. This is not evidence for a native or third-party SDK member.
public struct RemoteManagedServiceVerifierSnapshot: Sendable {
    public let station: RemoteStationVerifierSnapshot
    public let services: [String: PublicKeyData]
    public let memberIDs: [String]

    static func validIDs(_ ids: [String]) -> Bool {
        (1...64).contains(ids.count) && ids == ids.sorted() && Set(ids).count == ids.count && ids.allSatisfy {
            (1...128).contains($0.utf8.count) && $0.utf8.allSatisfy { (33...126).contains($0) }
        }
    }

    static func decode(_ bytes: Data, origin: String, genesis: String, memberIDs: [String], startedAt: UInt64) throws -> Self {
        guard bytes.count <= 262_144, validIDs(memberIDs), let text = String(data: bytes, encoding: .utf8) else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        _ = try canonicalJson(json: text)
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rows = object.removeValue(forKey: "services") as? [[String: Any]], rows.count == memberIDs.count else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        let station = try RemoteStationVerifierSnapshot.decode(JSONSerialization.data(withJSONObject: object),
            origin: origin, genesis: genesis, startedAt: startedAt)
        var keys: [String: PublicKeyData] = [:]
        for (row, id) in zip(rows, memberIDs) {
            guard row["id"] as? String == id, Set(row.keys) == ["id"] || Set(row.keys) == ["id", "auth_key"] else {
                throw RemoteRecoveryTransportError.invalidResponse
            }
            if let value = row["auth_key"] {
                keys[id] = try serviceKey(value)
            }
        }
        return Self(station: station, services: keys, memberIDs: memberIDs)
    }

    static func serviceKey(_ value: Any) throws -> PublicKeyData {
        guard let key = value as? [String: Any], Set(key.keys) == ["alg", "pub"],
              key["alg"] as? String == "p256", let encoded = key["pub"] as? String,
              let raw = RemoteRecoveryKit.decodeBase64URL(encoded, count: 65), raw.first == 4 else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return PublicKeyData(alg: .p256, raw: raw)
    }
}

@MainActor
public final class RemoteManagedServiceVerifierEvidence {
    public struct Poll: Equatable { fileprivate let id: UUID }
    private let gate: RemoteVerifierSigningGate
    private let station: RemoteStationVerifierEvidence
    private let roster: RemoteStationVerifierRoster
    private let log: MembershipLog
    private let members: [String]
    private let keys: [String: PublicKeyData]
    private let prospective: (id: String, request: SignRequest)?
    private var poll: (id: Poll, station: RemoteStationVerifierEvidence.Poll)?
    private var connections: [RemoteVerifierSigningGate.Connection] = []
    private var retired = false
    private var reviewedGenerations: [UInt64]?

    public init(gate: RemoteVerifierSigningGate, roster: RemoteStationVerifierRoster, log: MembershipLog, memberIDs: [String],
                prospectiveRequest: SignRequest? = nil) throws {
        try gate.requireMembership(log)
        var keys: [String: PublicKeyData] = [:]
        var prospective: (id: String, request: SignRequest)?
        if let request = prospectiveRequest {
            guard let body = request.bodyJson,
                  request == (try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: request.keyId)),
                  let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  object["action"] as? String == "add", object["signer"] as? String == request.keyId,
                  let manager = log.member(deviceId: request.keyId), manager.kind == "native", manager.status == .active,
                  manager.roles.contains("manage"), let member = object["member"] as? [String: Any],
                  let id = member["device_id"] as? String, member["kind"] as? String == "service", log.member(deviceId: id) == nil,
                  let signed = object["signed_at"] as? NSNumber,
                  let key = member["auth_key"],
                  try log.draftEntry(signer: request.keyId, signedAt: signed.uint64Value,
                    actionJson: String(decoding: JSONSerialization.data(withJSONObject: ["action": "add", "member": member]), as: UTF8.self)) == body,
                  memberIDs.contains(id) else { throw RemoteVerifierGateError.staleMembership }
            keys[id] = try RemoteManagedServiceVerifierSnapshot.serviceKey(key)
            prospective = (id, request)
        }
        guard RemoteManagedServiceVerifierSnapshot.validIDs(memberIDs), memberIDs.allSatisfy({ id in
            if keys[id] != nil { return true }
            guard let member = log.member(deviceId: id), member.kind == "service", member.status == .active else { return false }
            keys[id] = member.authKey
            return true
        }) else { throw RemoteVerifierGateError.invalidRoster }
        self.gate = gate; self.roster = roster; self.log = log.snapshot(); members = memberIDs
        self.keys = keys
        self.prospective = prospective
        station = try RemoteStationVerifierEvidence(gate: gate, roster: roster, log: log)
    }

    deinit { for connection in connections { gate.disconnect(connection) } }

    public func begin() throws -> Poll {
        guard !retired else { throw RemoteVerifierGateError.staleConnection }
        let next = Poll(id: UUID())
        poll = (next, station.begin())
        return next
    }

    /// The same protected service key and replica processes must answer on both
    /// sides of owner confirmation. The lease starts before token acquisition.
    public func refreshEnrollment(using transport: any RemoteManagedServiceVerifierTransport,
                                  current: () throws -> Void) async throws -> [UInt64] {
        guard prospective != nil else { throw RemoteVerifierGateError.unsupportedEntry }
        let expected = try begin()
        do {
            try current()
            let snapshot = try await transport.managedServiceVerifiers(genesisHash: log.genesisHash(),
                memberIDs: members, expected: log.head())
            try Task.checkCancellation()
            try current()
            let generations = snapshot.station.replicas.compactMap(\.connectionGeneration)
            guard generations.count == roster.replicas.count,
                  reviewedGenerations == nil || reviewedGenerations == generations else {
                throw RemoteVerifierGateError.staleConnection
            }
            try receive(snapshot, for: expected)
            try requireEnrollment(log: log)
            reviewedGenerations = generations
            return generations
        } catch {
            failed(expected)
            throw error
        }
    }

    public func requireEnrollment(log: MembershipLog) throws {
        guard !retired, poll == nil, let prospective else { throw RemoteVerifierGateError.staleConnection }
        try gate.requireServiceReports(prospective.request, log: log,
            participants: roster.replicas.map(roster.verifierID) + members.map(RemoteVerifierID.member))
    }

    public func receive(_ snapshot: RemoteManagedServiceVerifierSnapshot, for expected: Poll) throws {
        guard !retired, let pending = poll, pending.id == expected else { throw RemoteVerifierGateError.staleConnection }
        poll = nil
        disconnectMembers()
        do {
            guard snapshot.memberIDs == members, snapshot.station.roster == roster else {
                throw RemoteVerifierGateError.staleMembership
            }
            try gate.requireMembership(log)
            try station.receive(snapshot.station, for: pending.station)
            // The service may run on any of its owner's replicas. Every slot
            // must be live; use their common capabilities and shortest lifetime.
            let replicas = snapshot.station.replicas
            guard replicas.allSatisfy({ $0.inventory != nil && $0.authorizationMilliseconds != nil }),
                  let first = replicas.first?.actions, let version = replicas.compactMap(\.version).min(),
                  let lifetime = replicas.compactMap(\.authorizationMilliseconds).min() else { return }
            let actions = replicas.dropFirst().reduce(Set(first)) { $0.intersection($1.actions ?? []) }.sorted()
            guard !actions.isEmpty else { return }
            for id in members {
                guard let key = snapshot.services[id], keys[id] == key else { continue }
                let connection = try gate.connect(.member(id)); connections.append(connection)
                let inventory = VerifierInventory(version: version, actions: actions)
                if let prospective, prospective.id == id {
                    try gate.observeProspectiveMember(inventory, request: prospective.request, on: connection,
                        receivedAt: snapshot.station.requestStartedAt, authorizationMilliseconds: lifetime)
                } else {
                    try gate.observeConsumer(inventory, on: connection,
                        receivedAt: snapshot.station.requestStartedAt, authorizationMilliseconds: lifetime)
                }
            }
        } catch {
            station.disconnect(); disconnectMembers()
            throw error
        }
    }

    public func failed(_ expected: Poll) {
        guard poll?.id == expected else { return }
        poll = nil; station.disconnect(); disconnectMembers()
    }

    public func retire() {
        retired = true; poll = nil; station.disconnect(); disconnectMembers()
    }

    private func disconnectMembers() {
        for connection in connections { gate.disconnect(connection) }
        connections.removeAll()
    }
}
