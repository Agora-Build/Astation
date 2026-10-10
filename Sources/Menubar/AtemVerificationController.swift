import Foundation

struct AtemVerificationRoute: Hashable {
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

final class AtemVerificationController {
    private struct Attempt {
        let id = UUID()
        let route: AtemVerificationRoute
        let account: String
        let commitment: Data
        let keys: AtemVerifyKeys
        let expires: Date
        var approving = false
    }

    let identity: AtemE2EIdentity
    private let account: () -> String
    private let key: (String, String?) throws -> AccountDataKey?
    private let isCurrent: (AtemVerificationRoute) -> Bool
    private let send: (AstationMessage, AtemVerificationRoute) -> Void
    private let approve: (AtemVerificationApproval, @escaping (Bool) -> Void) -> Void
    private let saveRecovery: (String, @escaping (Bool) -> Void) -> Void
    private let kit: () throws -> String
    private let now: () -> Date
    private var attempts: [AtemVerificationRoute: Attempt] = [:]
    private var approvalInFlight: UUID?
    private let timeout: TimeInterval = 180

    init(
        identity: AtemE2EIdentity, account: @escaping () -> String,
        key: @escaping (String, String?) throws -> AccountDataKey?,
        isCurrent: @escaping (AtemVerificationRoute) -> Bool,
        send: @escaping (AstationMessage, AtemVerificationRoute) -> Void,
        approve: @escaping (AtemVerificationApproval, @escaping (Bool) -> Void) -> Void,
        saveRecovery: @escaping (String, @escaping (Bool) -> Void) -> Void,
        kit: @escaping () throws -> String, now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.account = account
        self.key = key
        self.isCurrent = isCurrent
        self.send = send
        self.approve = approve
        self.saveRecovery = saveRecovery
        self.kit = kit
        self.now = now
    }

    func start(_ commit: AtemVerifyCommit, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route) else { return }
        prune()
        guard commit.deviceId == route.deviceId, !commit.deviceId.isEmpty,
              commit.deviceId.utf8.count <= 256, commit.commitment.count == 32 else {
            abort(route, reason: "Verification identity or commitment is invalid")
            return
        }
        guard attempts[route] == nil, attempts.count < 32 else {
            abort(route, reason: "Verification is already pending; start again")
            return
        }
        do {
            let keys = try identity.verificationKeys(nonce: AtemSecureEnclaveCryptography.random32())
            let attempt = Attempt(route: route, account: account(), commitment: commit.commitment, keys: keys, expires: now().addingTimeInterval(timeout))
            attempts[route] = attempt
            send(.verifyKeys(keys), route)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.attempts[route]?.id == attempt.id else { return }
                self.abort(route, reason: "Verification expired; start again")
            }
        } catch {
            abort(route, reason: error.localizedDescription)
        }
    }

    func reveal(_ reveal: AtemVerifyReveal, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let attempt = attempts[route], current(attempt), !attempt.approving else {
            abort(route, reason: "No active verification commitment")
            return
        }
        do {
            guard try reveal.commitment() == attempt.commitment else {
                abort(route, reason: "Verification commitment did not match")
                return
            }
            guard approvalInFlight == nil else {
                abort(route, reason: "Another device's approval is in progress; retry shortly")
                return
            }
            attempts[route]?.approving = true
            approvalInFlight = attempt.id
            let approval = AtemVerificationApproval(deviceName: route.deviceName, safetyCode: try reveal.safetyCode(keys: attempt.keys))
            approve(approval) { [weak self] accepted in
                guard let self else { return }
                guard self.current(attempt) else { self.finishApproval(attempt); return }
                guard accepted else {
                    self.finishApproval(attempt)
                    self.abort(route, reason: "Device verification was denied")
                    return
                }
                do {
                    if try self.identity.recoveryIsSaved() {
                        self.finish(attempt, reveal: reveal)
                        self.finishApproval(attempt)
                    } else {
                        self.saveRecovery(try self.kit()) { [weak self] saved in
                            guard let self else { return }
                            defer { self.finishApproval(attempt) }
                            guard self.current(attempt) else { return }
                            guard saved else { self.abort(route, reason: "Recovery kit was not saved"); return }
                            do {
                                try self.identity.markRecoverySaved(signingPublicKey: attempt.keys.signPub)
                                self.finish(attempt, reveal: reveal)
                            } catch { self.abort(route, reason: error.localizedDescription) }
                        }
                    }
                } catch {
                    self.finishApproval(attempt)
                    self.abort(route, reason: error.localizedDescription)
                }
            }
        } catch { abort(route, reason: "Verification keys are invalid") }
    }

    func cancel(route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        attempts.removeValue(forKey: route)
    }

    func disconnect(clientId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        attempts = attempts.filter { $0.key.clientId != clientId }
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
            attempt.account == account() && isCurrent(attempt.route)
    }

    private func finishApproval(_ attempt: Attempt) {
        if approvalInFlight == attempt.id { approvalInFlight = nil }
    }

    private func finish(_ attempt: Attempt, reveal: AtemVerifyReveal) {
        guard current(attempt) else { return }
        do {
            let state = try identity.state(account: attempt.account)
            let result = try identity.completeVerification(
                account: attempt.account, deviceId: attempt.route.deviceId, reveal: reveal,
                transcript: AtemE2ECrypto.transcript(commitment: attempt.commitment, nonceA: reveal.nonce, nonceS: attempt.keys.nonce),
                expectedSigningKey: attempt.keys.signPub, key: key(attempt.account, state?.kid)
            )
            attempts.removeValue(forKey: attempt.route)
            send(.deviceVerified(result), attempt.route)
        } catch { abort(attempt.route, reason: error.localizedDescription) }
    }

    private func abort(_ route: AtemVerificationRoute, reason: String) {
        attempts.removeValue(forKey: route)
        if isCurrent(route) { send(.verifyAbort(reason: reason), route) }
    }

    private func prune() {
        for attempt in Array(attempts.values) where !current(attempt) {
            abort(attempt.route, reason: "Verification expired; start again")
        }
    }
}
