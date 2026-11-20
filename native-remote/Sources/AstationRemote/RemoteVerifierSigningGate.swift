import AtemClient
import Foundation

public enum RemoteVerifierGateError: LocalizedError, Equatable {
    case invalidRoster
    case staleMembership
    case staleConnection
    case invalidInventory
    case downgradedInventory
    case unconfirmedVerifiers
    case unsupportedEntry

    public var errorDescription: String? {
        switch self {
        case .unconfirmedVerifiers, .invalidInventory, .downgradedInventory:
            return "All account devices and servers must confirm support before this change can be signed. Reconnect or upgrade them and try again."
        case .staleConnection, .staleMembership:
            return "Account access changed. Refresh the device list and review the change again."
        case .invalidRoster:
            return "The complete account verifier inventory is not available. Host sending changes remain disabled."
        case .unsupportedEntry:
            return "This signing request is not supported."
        }
    }
}

public enum RemoteVerifierID: Hashable, Sendable {
    case host(String)
    case member(String)
    case stationReplica(String)
    case other(String)
}

/// Inventories are live evidence, never restored from a checkpoint or inferred from a feature flag.
/// The caller must independently enumerate ALL Station replicas and other SDK consumers, in addition
/// to the signed list's hosts/members. This object does not discover or authenticate that roster.
public final class RemoteVerifierSigningGate: @unchecked Sendable {
    private static let evidenceClock = ContinuousClock()
    private static let evidenceEpoch = evidenceClock.now

    /// Receipt timestamps must use this clock, which also advances during system sleep.
    public static func evidenceTimeMilliseconds() -> UInt64 {
        let elapsed = evidenceEpoch.duration(to: evidenceClock.now).components
        return UInt64(elapsed.seconds) * 1_000 + UInt64(elapsed.attoseconds / 1_000_000_000_000_000)
    }

    public struct Connection: Equatable, Sendable {
        fileprivate let verifier: RemoteVerifierID
        fileprivate let generation: UUID
    }

    private struct State {
        var connection: Connection?
        var confirmed: VerifierInventory?
        var highest: VerifierInventory?
        var validBefore: UInt64?
    }

    private let lock = NSLock()
    private let accountID: String
    private let genesisHash: String
    private let head: LogHead
    private let hostGenerations: [String: UInt64]
    private let now: () -> UInt64
    private var states: [RemoteVerifierID: State]

    /// A roster is valid for one exact signed head. Changing membership requires a fresh roster
    /// and fresh reports; an unsigned server response cannot silently remove an offline verifier.
    public init(log: MembershipLog, verifiers: [RemoteVerifierID],
                now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) throws {
        var required = Set(log.members().filter { $0.status == .active }.map { RemoteVerifierID.member($0.deviceId) })
        var hosts: [String: UInt64] = [:]
        for entry in log.entries() {
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            if let host = body?["host"] as? [String: Any], let id = host["host_id"] as? String,
               let current = log.host(hostId: id) { hosts[id] = current.hostTrustGen }
        }
        required.formUnion(hosts.keys.map { .host($0) })
        let roster = Set(verifiers)
        guard log.frozen() == nil, !verifiers.isEmpty, verifiers.count <= 4096,
              roster.count == verifiers.count, required.isSubset(of: roster),
              verifiers.contains(where: { if case .stationReplica = $0 { return true }; return false }),
              verifiers.allSatisfy({ id in
                  let name: String
                  switch id {
                  case .host(let value), .member(let value): name = value
                  case .stationReplica(let value), .other(let value): name = value
                  }
                  return !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains(where: { $0.value < 32 })
              }) else { throw RemoteVerifierGateError.invalidRoster }
        accountID = log.accountId()
        genesisHash = log.genesisHash()
        head = log.head()
        hostGenerations = hosts
        self.now = now
        states = Dictionary(uniqueKeysWithValues: verifiers.map { ($0, State()) })
    }

    public func connect(_ verifier: RemoteVerifierID) throws -> Connection {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[verifier] else { throw RemoteVerifierGateError.invalidRoster }
        let connection = Connection(verifier: verifier, generation: UUID())
        state.connection = connection
        state.confirmed = nil
        state.validBefore = nil
        states[verifier] = state
        return connection
    }

    /// An evidence adapter must bind its authenticated source to this exact
    /// anchor before confirming a non-host consumer through observeConsumer.
    public func requireMembership(_ log: MembershipLog) throws {
        guard log.accountId() == accountID, log.genesisHash() == genesisHash,
              log.head() == head, log.frozen() == nil else {
            throw RemoteVerifierGateError.staleMembership
        }
    }

    public func disconnect(_ connection: Connection) {
        lock.lock(); defer { lock.unlock() }
        guard states[connection.verifier]?.connection == connection else { return }
        states[connection.verifier]?.connection = nil
        states[connection.verifier]?.confirmed = nil
    }

    /// Only call after authenticating this consumer and its connection. A host's report must
    /// instead come from its encrypted, shared-core-verified welcome via observeHostWelcome.
    public func observeConsumer(_ inventory: VerifierInventory?, on connection: Connection) throws {
        if case .host = connection.verifier { throw RemoteVerifierGateError.invalidInventory }
        try observe(inventory, on: connection)
    }

    /// An authenticated HTTP report consumes its lifetime from request start,
    /// including token refresh and response delay. Replays cannot extend it.
    public func observeConsumer(_ inventory: VerifierInventory?, on connection: Connection,
                                receivedAt: UInt64, authorizationMilliseconds: UInt64) throws {
        switch connection.verifier {
        case .stationReplica, .member: break
        default: throw RemoteVerifierGateError.invalidInventory
        }
        let deadline = receivedAt.addingReportingOverflow(authorizationMilliseconds)
        let current = now()
        guard receivedAt <= current, (1...30_000).contains(authorizationMilliseconds),
              !deadline.overflow, current < deadline.partialValue else {
            try observe(nil, on: connection, validBefore: deadline.overflow ? current : deadline.partialValue)
            throw RemoteVerifierGateError.staleConnection
        }
        try observe(inventory, on: connection, validBefore: deadline.partialValue)
    }

    /// The authenticated channel owner must disconnect this evidence when the channel closes,
    /// expires or loses authority; merely retaining a WelcomeInfo is not a live connection.
    /// Capture receivedAt using evidenceTimeMilliseconds when the verified welcome arrives,
    /// before any deferred delivery (or the injected clock when testing).
    public func observeHostWelcome(_ welcome: WelcomeInfo, on connection: Connection,
                                   receivedAt: UInt64? = nil) throws {
        let current = now()
        let received = receivedAt ?? current
        let deadline = received.addingReportingOverflow(welcome.authorizationMsLeft)
        guard case .host(let id) = connection.verifier, welcome.atemDeviceId == id,
              welcome.accountId == accountID, welcome.head == head,
              welcome.revision == 9, (1...86_400_000).contains(welcome.authorizationMsLeft),
              received <= current, !deadline.overflow,
              hostGenerations[id] == welcome.hostTrustGen else {
            try observe(nil, on: connection)
            throw RemoteVerifierGateError.staleMembership
        }
        guard current < deadline.partialValue else {
            try observe(nil, on: connection, validBefore: deadline.partialValue)
            throw RemoteVerifierGateError.staleMembership
        }
        try observe(welcome.verifier, on: connection, validBefore: deadline.partialValue)
    }

    private func observe(_ inventory: VerifierInventory?, on connection: Connection,
                         validBefore: UInt64? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[connection.verifier], state.connection == connection else {
            throw RemoteVerifierGateError.staleConnection
        }
        state.confirmed = nil
        if let validBefore {
            // A missing or refused inventory cannot renew this channel's deadline later.
            state.validBefore = min(state.validBefore ?? validBefore, validBefore)
        }
        defer { states[connection.verifier] = state }
        guard let inventory else { return }
        guard inventory.version > 0, (1...64).contains(inventory.actions.count),
              inventory.actions == inventory.actions.sorted(), Set(inventory.actions).count == inventory.actions.count,
              inventory.actions.allSatisfy({ action in
                  let bytes = Array(action.utf8)
                  return (1...32).contains(bytes.count) && (97...122).contains(bytes[0]) &&
                      bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
              }) else { throw RemoteVerifierGateError.invalidInventory }
        if let highest = state.highest {
            guard inventory.version >= highest.version, Set(highest.actions).isSubset(of: Set(inventory.actions)),
                  inventory.version != highest.version || inventory == highest else {
                throw RemoteVerifierGateError.downgradedInventory
            }
        }
        state.highest = inventory
        state.confirmed = inventory
    }

    /// Recheck at the actual signing boundary, after the owner's confirmation, using the fresh log.
    /// A disconnected consumer or a changed roster/head invalidates the authorization.
    public func authorize(_ request: SignRequest, log: MembershipLog) throws {
        guard let json = request.bodyJson,
              request == (try RemoteConfirmedSigner.membershipRequest(bodyJSON: json, keyID: request.keyId)),
              let body = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let action = body["action"] as? String else { throw RemoteVerifierGateError.unsupportedEntry }
        let minimum: UInt32
        if ["project_set", "project_remove", "host_sender_revoke", "host_sender_readmit", "host_enc_key"].contains(action) {
            minimum = 2
        } else if ["add", "set_roles"].contains(action), Self.hasNewScopeOps(body) {
            minimum = 1
        } else { return }
        lock.lock(); defer { lock.unlock() }
        guard log.accountId() == accountID, log.genesisHash() == genesisHash, log.head() == head, log.frozen() == nil,
              body["account_id"] as? String == accountID,
              body["prev_hash"] as? String == head.hash, head.seq < UInt64.max,
              (body["seq"] as? NSNumber)?.uint64Value == head.seq + 1 else {
            throw RemoteVerifierGateError.staleMembership
        }
        if action == "add", let member = body["member"] as? [String: Any], let id = member["device_id"] as? String,
           states[.member(id)] == nil { throw RemoteVerifierGateError.unconfirmedVerifiers }
        let current = now()
        guard states.values.allSatisfy({ state in
            guard state.connection != nil, let inventory = state.confirmed else { return false }
            if let deadline = state.validBefore, current >= deadline { return false }
            return inventory.version >= minimum && inventory.actions.contains(action)
        }) else { throw RemoteVerifierGateError.unconfirmedVerifiers }
    }

    private static func hasNewScopeOps(_ body: [String: Any]) -> Bool {
        let member = body["member"] as? [String: Any]
        let scope = (member?["scope"] ?? body["scope"]) as? [String: Any]
        return (scope?["ops"] as? [String] ?? []).contains { ["launch", "message", "notify"].contains($0) }
    }
}
