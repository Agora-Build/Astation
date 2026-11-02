import Foundation
import AtemClient
import AstationRemote

struct AtemVerificationRoute: Hashable, Codable {
    let clientId: String
    let connectionId: String
    let deviceId: String
    let deviceName: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clientId == rhs.clientId && lhs.connectionId == rhs.connectionId && lhs.deviceId == rhs.deviceId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(clientId)
        hasher.combine(connectionId)
        hasher.combine(deviceId)
    }
}

struct AtemVerificationApproval {
    let deviceName: String
    let safetyCode: String
}

struct AtemPreparedHostMembership {
    // The exact body is already protected before the safety-code prompt appears.
    let publish: (UInt64, @escaping () -> Bool, @escaping (Result<[String], Error>) -> Void) -> Void
    var cancel: () -> Void = {}
}

final class AtemVerificationController {
    private struct Attempt {
        let id = UUID()
        let route: AtemVerificationRoute
        let commit: RemotePairingCommit
        let expires: Date
        var keys: AtemVerifyKeys?
        var approving = false
        var cancelPreparation: (() -> Void)?
    }

    let identity: AtemE2EIdentity
    private let account: () -> String
    private let key: (String, String?) throws -> AccountDataKey?
    private let isCurrent: (AtemVerificationRoute) -> Bool
    private let send: (AstationMessage, AtemVerificationRoute) -> Void
    private let approve: (AtemVerificationApproval, @escaping (Bool) -> Void) -> (() -> Void)
    private let prepareKeys: (String, Data, @escaping (Result<AtemVerifyKeys, Error>) -> Void) -> Void
    private let prepareHost: (RemotePairingCommit, RemotePairingReveal, AtemVerifyKeys,
        @escaping (Result<AtemPreparedHostMembership, Error>) -> Void) -> Void
    private let now: () -> Date
    private var attempts: [AtemVerificationRoute: Attempt] = [:]
    private var approvalInFlight: UUID?
    private var promptId: UUID?
    private var cancelPrompt: (() -> Void)?
    private let timeout: TimeInterval = 180

    init(identity: AtemE2EIdentity, account: @escaping () -> String,
        key: @escaping (String, String?) throws -> AccountDataKey?,
        isCurrent: @escaping (AtemVerificationRoute) -> Bool,
        send: @escaping (AstationMessage, AtemVerificationRoute) -> Void,
        approve: @escaping (AtemVerificationApproval, @escaping (Bool) -> Void) -> (() -> Void),
        prepareKeys: @escaping (String, Data, @escaping (Result<AtemVerifyKeys, Error>) -> Void) -> Void,
        prepareHost: @escaping (RemotePairingCommit, RemotePairingReveal, AtemVerifyKeys,
            @escaping (Result<AtemPreparedHostMembership, Error>) -> Void) -> Void,
        now: @escaping () -> Date = Date.init) {
        self.identity = identity
        self.account = account
        self.key = key
        self.isCurrent = isCurrent
        self.send = send
        self.approve = approve
        self.prepareKeys = prepareKeys
        self.prepareHost = prepareHost
        self.now = now
    }

    func start(_ commit: AtemVerifyCommit, route: AtemVerificationRoute, account capturedAccount: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route), capturedAccount == account() else { return }
        prune()
        do {
            guard commit.deviceId == route.deviceId, commit.deviceId.utf8.count <= 256 else {
                throw AtemIdentityError.invalidState
            }
            let captured = try RemotePairingCommit(context: RemotePairingContext(accountID: capturedAccount,
                hostID: route.deviceId, linkGeneration: UUID()), hostTrustGeneration: commit.hostTrustGeneration, commitment: commit.commitment)
            guard attempts[route] == nil, attempts.count < 32 else { throw RemoteRecoveryError.busy }
            let attempt = Attempt(route: route, commit: captured, expires: now().addingTimeInterval(timeout))
            attempts[route] = attempt
            prepareKeys(capturedAccount, try AtemSecureEnclaveCryptography.random32()) { [weak self] result in
                guard let self, self.current(attempt) else { return }
                do {
                    let keys = try result.get()
                    _ = try keys.remote()
                    self.attempts[route]?.keys = keys
                    self.send(.verifyKeys(keys), route)
                } catch { self.abort(route, reason: error.localizedDescription) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.attempts[route]?.id == attempt.id else { return }
                self.abort(route, reason: "Verification expired; start again")
            }
        } catch { abort(route, reason: error.localizedDescription) }
    }

    func reveal(_ reveal: AtemVerifyReveal, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let attempt = attempts[route], current(attempt), let keys = attempt.keys, !attempt.approving else {
            abort(route, reason: "No active verification commitment")
            return
        }
        do {
            let capturedReveal = try reveal.remote()
            guard try capturedReveal.commitment() == attempt.commit.commitment else {
                throw AtemIdentityError.invalidState
            }
            guard approvalInFlight == nil else { throw RemoteRecoveryError.busy }
            attempts[route]?.approving = true
            approvalInFlight = attempt.id
            prepareHost(attempt.commit, capturedReveal, keys) { [weak self] result in
                guard let self, self.current(attempt), self.approvalInFlight == attempt.id else {
                    if case .success(let prepared) = result { prepared.cancel() }
                    return
                }
                do {
                    let prepared = try result.get()
                    self.attempts[route]?.cancelPreparation = prepared.cancel
                    let approval = try AtemVerificationApproval(deviceName: route.deviceName,
                        safetyCode: capturedReveal.safetyCode(keys: keys.remote()))
                    self.presentPrompt({ self.approve(approval, $0) }) { [weak self] accepted in
                        guard let self else { return }
                        guard self.current(attempt) else { self.finishApproval(attempt); return }
                        guard accepted else { self.abort(route, reason: "Device verification was denied"); return }
                        let confirmedAt = DispatchTime.now().uptimeNanoseconds / 1_000_000
                        self.finishApproval(attempt)
                        prepared.publish(confirmedAt, { [weak self] in self?.current(attempt) == true }) { [weak self] published in
                            guard let self, self.current(attempt) else { return }
                            do {
                                let entries = try published.get()
                                let log = try MembershipLog.verify(accountId: attempt.commit.context.accountID,
                                    genesisHash: keys.remote().genesisHash, entries: entries, now: HostClock(
                                        wallMs: UInt64(max(0, self.now().timeIntervalSince1970 * 1000)),
                                        monoMs: DispatchTime.now().uptimeNanoseconds / 1_000_000, bootId: "astation-verification"))
                                _ = try keys.remote().membershipEntries(log: log, managerID: AstationIdentity.shared.id,
                                    commit: attempt.commit, reveal: capturedReveal)
                                let state = try self.identity.state(account: attempt.commit.context.accountID)
                                var certificate = try self.identity.completeVerification(account: attempt.commit.context.accountID,
                                    deviceId: route.deviceId, reveal: reveal, transcript: capturedReveal.transcript(keys: keys.remote()),
                                    expectedSigningKey: keys.signPub, key: self.key(attempt.commit.context.accountID, state?.kid))
                                certificate.membership = try AtemVerifiedMembership(entries: entries)
                                self.attempts.removeValue(forKey: route)
                                self.send(.deviceVerified(certificate), route)
                            } catch { self.abort(route, reason: error.localizedDescription) }
                        }
                    }
                } catch { self.abort(route, reason: error.localizedDescription) }
            }
        } catch { abort(route, reason: "Verification keys or commitment are invalid; upgrade Atem and retry") }
    }

    func cancel(route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let attempt = attempts.removeValue(forKey: route) {
            finishApproval(attempt)
            attempt.cancelPreparation?()
        }
    }

    func disconnect(clientId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        for route in Array(attempts.keys) where route.clientId == clientId { cancel(route: route) }
    }

    func requestKey(publicKey: String, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route) else { return }
        do {
            let account = account()
            guard let publicKey = Data(base64Encoded: publicKey), publicKey.count == 32,
                  let state = try identity.state(account: account), state.mode != "off",
                  let key = try key(account, state.kid) else { throw AtemIdentityError.invalidState }
            let grant = try identity.keyGrant(account: account, deviceId: route.deviceId, publicKey: publicKey, key: key)
            if isCurrent(route) { send(.keyGrant(grant: grant), route) }
        } catch { send(.error(message: error.localizedDescription), route) }
    }

    private func current(_ attempt: Attempt) -> Bool {
        attempts[attempt.route]?.id == attempt.id && attempt.expires > now() &&
            attempt.commit.context.accountID == account() && isCurrent(attempt.route)
    }

    private func finishApproval(_ attempt: Attempt) {
        guard approvalInFlight == attempt.id else { return }
        approvalInFlight = nil
        promptId = nil
        let cancel = cancelPrompt
        cancelPrompt = nil
        cancel?()
    }

    private func presentPrompt(_ present: (@escaping (Bool) -> Void) -> (() -> Void), completion: @escaping (Bool) -> Void) {
        let id = UUID()
        promptId = id
        let cancel = present { [weak self] accepted in
            guard let self, self.promptId == id else { return }
            self.promptId = nil
            self.cancelPrompt = nil
            completion(accepted)
        }
        if promptId == id { cancelPrompt = cancel } else { cancel() }
    }

    private func abort(_ route: AtemVerificationRoute, reason: String) {
        cancel(route: route)
        if isCurrent(route) { send(.verifyAbort(reason: reason), route) }
    }

    private func prune() {
        for attempt in Array(attempts.values) where !current(attempt) { abort(attempt.route, reason: "Verification expired; start again") }
    }
}
