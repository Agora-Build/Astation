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
        var prospectiveRequest: SignRequest?
    }

    private let lock = NSLock()
    private let accountID: String
    private let genesisHash: String
    private let head: LogHead
    private let hostGenerations: [String: UInt64]
    private let firstServiceExpiry: UInt64?
    private let wall: () -> UInt64
    private var serviceClock: (wall: UInt64, tick: UInt64)
    private let now: () -> UInt64
    private var states: [RemoteVerifierID: State]

    /// A roster is valid for one exact signed head. Changing membership requires a fresh roster
    /// and fresh reports; an unsigned server response cannot silently remove an offline verifier.
    public convenience init(log: MembershipLog, verifiers: [RemoteVerifierID],
                wall: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) },
                now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) throws {
        try self.init(log: log, verifiers: verifiers, includeMembership: false, wall: wall, now: now)
    }

    /// The signed list supplies all active members and hosts; the protected Station
    /// roster supplies its replica identities. None starts with live evidence.
    public convenience init(log: MembershipLog, station: RemoteStationVerifierRoster, prospectiveServiceID: String? = nil,
                wall: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) },
                now: @escaping () -> UInt64 = { RemoteVerifierSigningGate.evidenceTimeMilliseconds() }) throws {
        var verifiers = station.replicas.map(station.verifierID)
        if let prospectiveServiceID { verifiers.append(.member(prospectiveServiceID)) }
        try self.init(log: log, verifiers: verifiers, includeMembership: true, wall: wall, now: now)
    }

    private init(log: MembershipLog, verifiers: [RemoteVerifierID], includeMembership: Bool,
                 wall: @escaping () -> UInt64, now: @escaping () -> UInt64) throws {
        let members = log.members().filter { $0.status == .active }
        var required = Set(members.map { RemoteVerifierID.member($0.deviceId) })
        firstServiceExpiry = members.filter { $0.kind == "service" }.map { $0.expiresAt ?? 0 }.min()
        var hosts: [String: UInt64] = [:]
        for entry in log.entries() {
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            if let host = body?["host"] as? [String: Any], let id = host["host_id"] as? String,
               let current = log.host(hostId: id) { hosts[id] = current.hostTrustGen }
        }
        required.formUnion(hosts.keys.map { .host($0) })
        let supplied = Set(verifiers)
        let roster = includeMembership ? supplied.union(required) : supplied
        guard log.frozen() == nil, !roster.isEmpty, roster.count <= 4096,
              supplied.count == verifiers.count, required.isSubset(of: roster),
              roster.contains(where: { if case .stationReplica = $0 { return true }; return false }),
              roster.allSatisfy({ id in
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
        self.wall = wall
        serviceClock = (wall(), now())
        states = Dictionary(uniqueKeysWithValues: roster.map { ($0, State()) })
    }

    public func connect(_ verifier: RemoteVerifierID) throws -> Connection {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[verifier] else { throw RemoteVerifierGateError.invalidRoster }
        let connection = Connection(verifier: verifier, generation: UUID())
        state.connection = connection
        state.confirmed = nil
        state.validBefore = nil
        state.prospectiveRequest = nil
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
        states[connection.verifier]?.validBefore = nil
        states[connection.verifier]?.prospectiveRequest = nil
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
        try observeHTTPConsumer(inventory, on: connection, receivedAt: receivedAt,
            authorizationMilliseconds: authorizationMilliseconds)
    }

    /// A trusted evidence adapter must authenticate the proposed member's key before
    /// confirming it. Its finite evidence authorizes only this exact enrollment request.
    public func observeProspectiveMember(_ inventory: VerifierInventory?, request: SignRequest,
                                         on connection: Connection, receivedAt: UInt64,
                                         authorizationMilliseconds: UInt64) throws {
        do {
            guard case .member(let id) = connection.verifier, let json = request.bodyJson,
                  request == (try RemoteConfirmedSigner.membershipRequest(bodyJSON: json, keyID: request.keyId)),
                  let body = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  body["action"] as? String == "add", body["account_id"] as? String == accountID,
                  body["signer"] as? String == request.keyId,
                  body["prev_hash"] as? String == head.hash, head.seq < UInt64.max,
                  (body["seq"] as? NSNumber)?.uint64Value == head.seq + 1,
                  let member = body["member"] as? [String: Any], member["device_id"] as? String == id else {
                throw RemoteVerifierGateError.staleMembership
            }
            try observeHTTPConsumer(inventory, on: connection, receivedAt: receivedAt,
                authorizationMilliseconds: authorizationMilliseconds, prospectiveRequest: request)
        } catch {
            try observe(nil, on: connection)
            throw error
        }
    }

    private func observeHTTPConsumer(_ inventory: VerifierInventory?, on connection: Connection,
                                     receivedAt: UInt64, authorizationMilliseconds: UInt64,
                                     prospectiveRequest: SignRequest? = nil) throws {
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
        try observe(inventory, on: connection, validBefore: deadline.partialValue,
            prospectiveRequest: prospectiveRequest)
    }

    /// The authenticated channel owner must disconnect this evidence when the channel closes,
    /// expires or loses authority; merely retaining a WelcomeInfo is not a live connection.
    /// Capture receivedAt using evidenceTimeMilliseconds when the verified welcome arrives,
    /// before any deferred delivery (or the injected clock when testing).
    public func observeHostWelcome(_ welcome: WelcomeInfo, on connection: Connection,
                                   receivedAt: UInt64? = nil) throws {
        let current = now()
        guard case .host(let id) = connection.verifier,
              let deadline = hostDeadline(welcome, id: id, receivedAt: receivedAt ?? current, current: current) else {
            try observe(nil, on: connection)
            throw RemoteVerifierGateError.staleMembership
        }
        guard current < deadline else {
            try observe(nil, on: connection, validBefore: deadline)
            throw RemoteVerifierGateError.staleMembership
        }
        try observe(welcome.verifier, on: connection, validBefore: deadline)
    }

    public var enrolledHostIDs: [String] { hostGenerations.keys.sorted() }

    private func hostDeadline(_ welcome: WelcomeInfo, id: String, receivedAt: UInt64, current: UInt64) -> UInt64? {
        let deadline = receivedAt.addingReportingOverflow(welcome.authorizationMsLeft)
        guard welcome.atemDeviceId == id, welcome.accountId == accountID, welcome.head == head,
              welcome.revision == 9, (1...86_400_000).contains(welcome.authorizationMsLeft),
              receivedAt <= current, !deadline.overflow, hostGenerations[id] == welcome.hostTrustGen else { return nil }
        return deadline.partialValue
    }

    func hasHostReport(_ welcome: WelcomeInfo, id: String, receivedAt: UInt64, requirement: VerifierRequirement?) -> Bool {
        let current = now()
        guard let deadline = hostDeadline(welcome, id: id, receivedAt: receivedAt, current: current),
              current < deadline, let inventory = welcome.verifier,
              (try? Self.validateInventory(inventory)) != nil else { return false }
        guard let requirement else { return true }
        return inventory.version >= requirement.minimumVersion && inventory.actions.contains(requirement.action)
    }

    private func observe(_ inventory: VerifierInventory?, on connection: Connection,
                         validBefore: UInt64? = nil, prospectiveRequest: SignRequest? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[connection.verifier], state.connection == connection else {
            throw RemoteVerifierGateError.staleConnection
        }
        state.confirmed = nil
        state.prospectiveRequest = nil
        if let validBefore {
            // A missing or refused inventory cannot renew this channel's deadline later.
            state.validBefore = min(state.validBefore ?? validBefore, validBefore)
        }
        defer { states[connection.verifier] = state }
        guard let inventory else { return }
        try Self.validateInventory(inventory)
        if let highest = state.highest {
            guard inventory.version >= highest.version, Set(highest.actions).isSubset(of: Set(inventory.actions)),
                  inventory.version != highest.version || inventory == highest else {
                throw RemoteVerifierGateError.downgradedInventory
            }
        }
        state.highest = inventory
        state.confirmed = inventory
        state.prospectiveRequest = prospectiveRequest
    }

    static func validateInventory(_ inventory: VerifierInventory) throws {
        guard inventory.version > 0, (1...64).contains(inventory.actions.count),
              inventory.actions == inventory.actions.sorted(), Set(inventory.actions).count == inventory.actions.count,
              inventory.actions.allSatisfy({ action in
                  let bytes = Array(action.utf8)
                  return (1...32).contains(bytes.count) && (97...122).contains(bytes[0]) &&
                      bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
              }) else { throw RemoteVerifierGateError.invalidInventory }
    }

    /// Recheck at the actual signing boundary, after the owner's confirmation, using the fresh log.
    /// A disconnected consumer or a changed roster/head invalidates the authorization.
    public func authorize(_ request: SignRequest, log: MembershipLog) throws {
        try requireReports(request, log: log, participants: nil)
    }

    /// Only the protected service and the replicas serving it. The account-wide signer
    /// separately calls authorize for its complete inventory.
    func requireServiceReports(_ request: SignRequest, log: MembershipLog, participants: [RemoteVerifierID]) throws {
        guard !participants.isEmpty else { throw RemoteVerifierGateError.invalidRoster }
        try requireReports(request, log: log, participants: participants)
    }

    private func requireReports(_ request: SignRequest, log: MembershipLog, participants: [RemoteVerifierID]?) throws {
        guard let json = request.bodyJson,
              request == (try RemoteConfirmedSigner.membershipRequest(bodyJSON: json, keyID: request.keyId)),
              let body = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw RemoteVerifierGateError.unsupportedEntry
        }
        guard let requirement = try membershipRequiredVersion(bodyJson: json) else { return }
        let action = requirement.action
        let minimum = requirement.minimumVersion
        lock.lock(); defer { lock.unlock() }
        guard log.accountId() == accountID, log.genesisHash() == genesisHash, log.head() == head, log.frozen() == nil,
              body["account_id"] as? String == accountID,
              body["prev_hash"] as? String == head.hash, head.seq < UInt64.max,
              (body["seq"] as? NSNumber)?.uint64Value == head.seq + 1 else {
            throw RemoteVerifierGateError.staleMembership
        }
        var expiry = firstServiceExpiry
        if action == "add" {
            guard let member = body["member"] as? [String: Any], let id = member["device_id"] as? String,
                  let proposedExpiry = member["expires_at"] as? UInt64,
                  states[.member(id)]?.prospectiveRequest == request else {
                throw RemoteVerifierGateError.unconfirmedVerifiers
            }
            expiry = min(expiry ?? proposedExpiry, proposedExpiry)
        }
        let current = now()
        if let expiry {
            // A fresh replica report cannot extend signed membership through expiry or a clock rollback.
            guard current >= serviceClock.tick else { throw RemoteVerifierGateError.staleConnection }
            let elapsed = current - serviceClock.tick
            let projected = serviceClock.wall.addingReportingOverflow(elapsed)
            guard !projected.overflow else { throw RemoteVerifierGateError.staleConnection }
            serviceClock = (max(wall(), projected.partialValue), current)
            guard serviceClock.wall < expiry else { throw RemoteVerifierGateError.unconfirmedVerifiers }
        }
        func supports(_ state: State) -> Bool {
            guard state.connection != nil, let inventory = state.confirmed else { return false }
            if let deadline = state.validBefore, current >= deadline { return false }
            return inventory.version >= minimum && inventory.actions.contains(action)
        }
        let confirmed = participants.map { ids in ids.allSatisfy { states[$0].map(supports) == true } }
            ?? states.values.allSatisfy(supports)
        guard confirmed else { throw RemoteVerifierGateError.unconfirmedVerifiers }
    }

}
