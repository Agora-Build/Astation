import AtemClient
import AstationRemote
import Foundation

/// Evidence for this running binary only. A local key cannot confirm another
/// native device, hosted service or SDK consumer, even on the same account.
@MainActor
final class AstationLocalVerifierEvidence {
    private let gate: RemoteVerifierSigningGate
    private let memberID: String
    private let identity: AtemE2EIdentity
    private let account: String
    private let genesis: String
    private let head: LogHead
    private let current: () -> Bool
    private var connection: RemoteVerifierSigningGate.Connection?
    private var retired = false

    init(gate: RemoteVerifierSigningGate, log: MembershipLog, memberID: String,
         identity: AtemE2EIdentity, current: @escaping () -> Bool) throws {
        self.gate = gate; self.memberID = memberID; self.identity = identity
        account = log.accountId(); genesis = log.genesisHash(); head = log.head()
        self.current = current
        try refresh(log: log)
    }

    deinit { if let connection { gate.disconnect(connection) } }

    /// Call synchronously at the protected signing boundary as well as on
    /// identity/membership lifecycle events. Reading evidence never creates keys.
    func refresh(log: MembershipLog) throws {
        if let connection { gate.disconnect(connection) }
        connection = nil
        do {
            try gate.requireMembership(log)
            guard !retired, current(), log.accountId() == account, log.genesisHash() == genesis,
                  log.head() == head, log.frozen() == nil,
                  let member = log.member(deviceId: memberID), member.status == .active,
                  member.kind == "native" else { throw RemoteVerifierGateError.staleMembership }
            let keys = try identity.remotePublicKeys(create: false)
            guard member.authKey == PublicKeyData(alg: .p256, raw: keys.signing),
                  member.encKey == PublicKeyData(alg: .x25519, raw: keys.encryption) else {
                throw AtemIdentityError.identityChanged
            }
            let candidate = try gate.connect(.member(memberID))
            connection = candidate
            try gate.observeConsumer(verifierInventory(), on: candidate)
        } catch {
            retire()
            throw error
        }
    }

    func retire() {
        retired = true
        if let connection { gate.disconnect(connection) }
        connection = nil
    }
}
