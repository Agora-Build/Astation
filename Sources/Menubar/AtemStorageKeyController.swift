import Foundation

enum AtemUnlockDecision { case approve, deny, revoke }

struct AtemUnlockApproval {
    let deviceName: String
    let bootId: String
    let requestTime: Date
    let lastUnlock: Date?
}

final class AtemStorageKeyController {
    private struct Attempt {
        let id = UUID()
        let route: AtemVerificationRoute
        let account: String
        let authorization: AtemUnlockAuthorization
        let expires: Date
    }

    private let identity: AtemE2EIdentity
    private let account: () -> String
    private let isCurrent: (AtemVerificationRoute) -> Bool
    private let send: (AstationMessage, AtemVerificationRoute) -> Void
    private let approve: (AtemUnlockApproval, @escaping (AtemUnlockDecision) -> Void) -> (() -> Void)
    private let now: () -> Date
    private let timeout: TimeInterval
    private var attempt: Attempt?
    private var cancelPrompt: (() -> Void)?

    init(
        identity: AtemE2EIdentity, account: @escaping () -> String,
        isCurrent: @escaping (AtemVerificationRoute) -> Bool,
        send: @escaping (AstationMessage, AtemVerificationRoute) -> Void,
        approve: @escaping (AtemUnlockApproval, @escaping (AtemUnlockDecision) -> Void) -> (() -> Void),
        now: @escaping () -> Date = Date.init, timeout: TimeInterval = 180
    ) {
        self.identity = identity
        self.account = account
        self.isCurrent = isCurrent
        self.send = send
        self.approve = approve
        self.now = now
        self.timeout = timeout
    }

    func unlock(_ wire: AtemUnlockRequestWire, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route) else { return }
        expireIfNeeded()
        do {
            let account = account()
            let authorization = try identity.prepareUnlock(wire, account: account, deviceId: route.deviceId, now: now())
            guard attempt == nil else {
                deny(route, reason: "Another unlock approval is in progress; retry shortly.")
                return
            }
            let pending = Attempt(route: route, account: account, authorization: authorization, expires: now().addingTimeInterval(timeout))
            attempt = pending
            let request = authorization.request
            let approval = AtemUnlockApproval(
                deviceName: route.deviceName, bootId: request.bootId,
                requestTime: Date(timeIntervalSince1970: TimeInterval(request.time)),
                lastUnlock: authorization.lastUnlock.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
            let cancel = approve(approval) { [weak self] decision in
                self?.complete(pending, decision: decision)
            }
            // Presenters can finish synchronously; never retain their stale cancellation handle.
            if attempt?.id == pending.id { cancelPrompt = cancel } else { cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.attempt?.id == pending.id else { return }
                self.cancel()
                self.deny(route, reason: "Unlock approval expired; retry.")
            }
        } catch { deny(route, error: error) }
    }

    func rotate(_ wire: AtemStorageRotateWire, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route) else { return }
        do {
            let ack = try identity.rotateStorageKey(wire, account: account(), deviceId: route.deviceId)
            if isCurrent(route) { send(.storageKeyAck(ack: ack), route) }
        } catch {
            if isCurrent(route) {
                send(.storageKeyRejected(reason: error.localizedDescription, pendingKid: (error as? AtemStorageKeyError)?.pendingKid), route)
            }
        }
    }

    func settle(_ signed: AtemSignedWire, abandoning: Bool, route: AtemVerificationRoute) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(route) else { return }
        // Confirm/abandon have no reply. Their signatures authorize all changes.
        try? identity.settleStorageKey(signed, account: account(), deviceId: route.deviceId, abandoning: abandoning)
    }

    func disconnect(clientId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if attempt?.route.clientId == clientId { cancel() }
    }

    private func current(_ pending: Attempt) -> Bool {
        attempt?.id == pending.id && pending.account == account() &&
            pending.expires > now() && isCurrent(pending.route)
    }

    private func complete(_ pending: Attempt, decision: AtemUnlockDecision) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard attempt?.id == pending.id else { return }
        guard current(pending) else {
            cancel()
            deny(pending.route, reason: "Unlock approval expired or the account changed; retry.")
            return
        }
        cancel()
        do {
            switch decision {
            case .approve:
                let grant = try identity.unlockGrant(pending.authorization, now: now())
                if isCurrent(pending.route) { send(.unlockGrant(grant), pending.route) }
            case .deny:
                deny(pending.route, reason: "Storage-key unlock was denied.")
            case .revoke:
                try identity.revokeDevice(pending.authorization)
                deny(pending.route, reason: "Unlock was denied and this device's verification was revoked.", revoked: true)
            }
        } catch { deny(pending.route, error: error) }
    }

    private func expireIfNeeded() {
        if let pending = attempt, !current(pending) {
            cancel()
            deny(pending.route, reason: "Unlock approval expired; retry.")
        }
    }

    private func cancel() {
        attempt = nil
        let cancel = cancelPrompt
        cancelPrompt = nil
        cancel?()
    }

    private func deny(_ route: AtemVerificationRoute, error: Error) {
        var revoked = false
        if case .unverifiedDevice? = error as? AtemStorageKeyError { revoked = true }
        deny(route, reason: error.localizedDescription, revoked: revoked)
    }

    private func deny(_ route: AtemVerificationRoute, reason: String, revoked: Bool = false) {
        if isCurrent(route) { send(.unlockDenied(reason: reason, revoked: revoked), route) }
    }
}
