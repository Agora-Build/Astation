import Foundation
import AstationRemote

struct AtemTransportPolicyRecord: Codable, Equatable {
    let account: String
    let issuer: String
    let station: String
    let relayOnly: Bool
    let hosts: [String]

    var valid: Bool {
        AtemSessionWire.opaque(account) && PortalIntegrationRecord.validOrigin(issuer)
            && PortalIntegrationRecord.validOrigin(station) && !hosts.isEmpty && hosts.count <= 64
            && hosts == Array(Set(hosts)).sorted() && hosts.allSatisfy(DeviceAuthentication.isValidAtemId)
    }
}

struct AtemHostPolicyBinding: Equatable {
    let genesis: String
    let manager: String
    let trust: UInt64
    let channel: String
    let attachment: String
    let supported: Bool
}

struct AtemTransportPolicyContext: Equatable {
    let route: AtemVerificationRoute
    let account: String
    let issuer: String
    let station: String
    let pairingSession: String
    let transportGeneration: String
    let verifiedPin: AtemDevicePin?
    var binding: AtemHostPolicyBinding?
    var isRelay: Bool { route.clientId.hasPrefix("relay-") }

    func matches(_ context: AtemSessionContext) -> Bool {
        account == context.account && route.deviceId == context.device && pairingSession == context.pairingSession
            && route.clientId == context.route.clientId && route.connectionId == context.route.connectionId
            && transportGeneration == context.transportGeneration
    }
}

/// Mutation identity survives a reconnect; channel confirmation never does.
struct AtemHostPolicyCheckpoint: Codable, Equatable {
    let account: String
    let issuer: String
    let station: String
    let host: String
    let genesis: String
    let manager: String
    let trust: UInt64
    let relayOnly: Bool
    let requestID: String?
    let expectedRevision: UInt64
    var completed: Bool

    var valid: Bool {
        AtemSessionWire.opaque(account) && PortalIntegrationRecord.validOrigin(issuer)
            && PortalIntegrationRecord.validOrigin(station) && DeviceAuthentication.isValidAtemId(host)
            && genesis.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            && AtemSessionWire.opaque(manager) && trust <= AtemSessionWire.maximumCounter
            && expectedRevision <= AtemSessionWire.maximumCounter
            && requestID.map(AtemSessionWire.uuid) != false && (completed || requestID != nil)
    }

    func matches(_ context: AtemTransportPolicyContext, value: Bool) -> Bool {
        account == context.account && issuer == context.issuer && station == context.station
            && host == context.route.deviceId && genesis == context.binding?.genesis
            && manager == context.binding?.manager && trust == context.binding?.trust && relayOnly == value
    }
}

struct AtemHostPolicyReply {
    let re: String
    let requestID: String?
    let outcome: String
    let relayOnly: Bool
    let revision: UInt64
    let state: String
    let confirmed: Bool
}

/// Owns durable user intent and presentation. The shared client owns wire
/// validation, cryptography, request correlation and per-attachment readiness.
final class AtemTransportPolicyController {
    private enum Result: Equatable { case pending, ready, failed(String) }
    private struct Attempt {
        let context: AtemTransportPolicyContext
        let value: Bool
        var deadline: TimeInterval
        var wireID: String?
        var mutation: AtemHostPolicyCheckpoint?
        var retryAt: TimeInterval?
        var result: Result = .pending
    }
    private let journal: AtemSessionJournal
    private let now: () -> TimeInterval
    private let current: (AtemTransportPolicyContext) -> Bool
    private let send: (RemoteAgentOperation, AtemTransportPolicyContext) -> String?
    private let reconnect: (AtemTransportPolicyContext) -> Void
    private var attempts: [String: Attempt] = [:]
    var changed: (() -> Void)?

    init(journal: AtemSessionJournal, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         current: @escaping (AtemTransportPolicyContext) -> Bool,
         send: @escaping (RemoteAgentOperation, AtemTransportPolicyContext) -> String?,
         reconnect: @escaping (AtemTransportPolicyContext) -> Void) {
        self.journal = journal; self.now = now; self.current = current
        self.send = send; self.reconnect = reconnect
    }

    func policy(account: String, issuer: String) -> AtemTransportPolicyRecord? {
        journal.snapshot.transportPolicies?.first { $0.account == account && $0.issuer == issuer }
    }

    func blocksDirect(account: String, issuer: String) -> Bool {
        journal.loadFailed || policy(account: account, issuer: issuer)?.relayOnly == true
    }

    func set(_ policy: AtemTransportPolicyRecord, connections: [AtemTransportPolicyContext]) throws {
        guard policy.valid else { throw AtemSessionJSON.Invalid.json }
        try journal.update { snapshot in
            var records = snapshot.transportPolicies ?? []
            records.removeAll { $0.account == policy.account && $0.issuer == policy.issuer }
            guard records.count < 128 else { throw AtemSessionJSON.Invalid.limit }
            records.append(policy); snapshot.transportPolicies = records
            snapshot.hostPolicies?.removeAll { $0.account == policy.account && $0.issuer == policy.issuer }
        }
        attempts = attempts.filter { $0.value.context.account != policy.account || $0.value.context.issuer != policy.issuer }
        for context in connections { authenticated(context) }
        changed?()
    }

    func authenticated(_ context: AtemTransportPolicyContext) {
        guard !journal.loadFailed, current(context), context.verifiedPin != nil, let binding = context.binding,
              let policy = policy(account: context.account, issuer: context.issuer), policy.station == context.station else { return }
        if let previous = attempts[context.route.clientId], previous.context == context, previous.value == policy.relayOnly { return }
        var attempt = Attempt(context: context, value: policy.relayOnly, deadline: now() + 15)
        if !binding.supported { attempt.result = .failed("Upgrade Atem to a build with encrypted host policy support.") }
        attempts[context.route.clientId] = attempt
        if binding.supported { transmit(.hostPolicyGet(desired: attempt.value), context: context) }
        else if !context.isRelay && attempt.value { reconnect(context) }
        changed?()
    }

    func receive(_ reply: AtemHostPolicyReply, context: AtemTransportPolicyContext) {
        guard !journal.loadFailed, current(context), var attempt = attempts[context.route.clientId],
              attempt.context == context, attempt.result == .pending, now() < attempt.deadline,
              attempt.wireID == reply.re,
              policy(account: context.account, issuer: context.issuer)?.relayOnly == attempt.value,
              attempt.mutation?.requestID == reply.requestID else { return }
        attempt.wireID = nil
        attempts[context.route.clientId] = attempt
        if reply.state == "uncertain" || reply.outcome == "uncertain" {
            attempt.retryAt = now() + 1; attempts[context.route.clientId] = attempt
            changed?(); return
        }
        do {
            if reply.confirmed, reply.state == "durable", reply.relayOnly == attempt.value,
               ["current", "committed", "unchanged"].contains(reply.outcome) {
                let saved = checkpoint(context, value: attempt.value, request: attempt.mutation?.requestID,
                    revision: attempt.mutation?.expectedRevision ?? reply.revision, completed: true)
                try save(saved)
                attempt.result = .ready; attempt.mutation = nil
                attempts[context.route.clientId] = attempt
                changed?()
                if !context.isRelay && attempt.value { reconnect(context) }
                return
            }
            if reply.outcome == "current" {
                let previous = journal.snapshot.hostPolicies?.first { $0.matches(context, value: attempt.value) }
                if let previous, previous.completed {
                    fail(context, "Another manager changed this host's policy. Review and apply the policy again.")
                    return
                }
                let mutation = previous ?? checkpoint(context, value: attempt.value, request: UUID().uuidString.lowercased(),
                    revision: reply.revision, completed: false)
                try save(mutation)
                attempt.mutation = mutation; attempts[context.route.clientId] = attempt
                transmit(.hostPolicyRetry(relayOnly: mutation.relayOnly, request: mutation.requestID!,
                    expectedRevision: mutation.expectedRevision), context: context)
            } else {
                fail(context, reply.outcome == "save_failed"
                    ? "Atem could not durably save the policy. Reconnect to retry the same request."
                    : "The policy request conflicts with a newer decision. Review and apply it again.")
            }
        } catch { fail(context, "Policy storage is unavailable. Reopen Astation to reconcile before continuing.") }
        changed?()
    }

    func receivedChange(context: AtemTransportPolicyContext) {
        guard current(context), var attempt = attempts[context.route.clientId], attempt.context == context else { return }
        attempt.result = .pending; attempt.wireID = nil; attempt.mutation = nil
        attempt.deadline = now() + 15
        attempts[context.route.clientId] = attempt
        transmit(.hostPolicyGet(desired: attempt.value), context: context)
        changed?()
    }

    func refused(re: String?, context: AtemTransportPolicyContext) {
        guard let re, current(context), let attempt = attempts[context.route.clientId],
              attempt.context == context, attempt.wireID == re else { return }
        fail(context, "Atem refused the policy request. Check manager access and reconnect.")
    }

    func disconnected(clientID: String) { attempts.removeValue(forKey: clientID); changed?() }

    func tick() {
        for (id, attempt) in Array(attempts) {
            guard current(attempt.context) else { attempts.removeValue(forKey: id); changed?(); continue }
            guard attempt.result == .pending else { continue }
            if now() >= attempt.deadline {
                fail(attempt.context, "Atem did not confirm the policy. Reconnect to reconcile it.")
            } else if let retry = attempt.retryAt, now() >= retry {
                var next = attempt; next.retryAt = nil; next.mutation = nil
                attempts[id] = next
                transmit(.hostPolicyGet(desired: attempt.value), context: attempt.context)
            }
        }
    }

    func ready(account: String, issuer: String, station: String) -> Bool {
        guard !journal.loadFailed, let policy = policy(account: account, issuer: issuer),
              policy.relayOnly, policy.station == station else { return false }
        let live = attempts.values.filter { current($0.context) && $0.context.account == account && $0.context.issuer == issuer }
        guard !live.contains(where: { !policy.hosts.contains($0.context.route.deviceId) }) else { return false }
        return policy.hosts.allSatisfy { host in live.contains {
            $0.context.station == station && $0.context.route.deviceId == host && $0.context.verifiedPin != nil
                && $0.context.isRelay && $0.value && $0.result == .ready
        } }
    }

    func status(account: String, issuer: String, station: String) -> String {
        if journal.loadFailed { return "Policy storage is unavailable. Access is blocked until it can be reloaded." }
        guard let policy = policy(account: account, issuer: issuer) else { return "No transport policy has been requested on this Mac." }
        guard policy.station == station else { return "The saved policy belongs to another Station. Review the selected relay before continuing." }
        for attempt in attempts.values where attempt.context.account == account && attempt.context.issuer == issuer && current(attempt.context) {
            if case .failed(let message) = attempt.result { return message }
        }
        if !policy.relayOnly { return "Direct connections are permitted. Atems reconcile this policy when they authenticate." }
        if ready(account: account, issuer: issuer, station: station) {
            return "All enrolled Atem hosts confirmed relay-only on the selected Station. Hosted execution still requires live verification."
        }
        return "Relay-only requested. Waiting for encrypted confirmation from every enrolled host; offline hosts remain pending."
    }

    private func transmit(_ operation: RemoteAgentOperation, context: AtemTransportPolicyContext) {
        guard let id = send(operation, context), var attempt = attempts[context.route.clientId], attempt.context == context else {
            fail(context, "The encrypted policy channel is unavailable. Reconnect to reconcile it."); return
        }
        attempt.wireID = id; attempts[context.route.clientId] = attempt
    }

    private func fail(_ context: AtemTransportPolicyContext, _ text: String) {
        guard var attempt = attempts[context.route.clientId], attempt.context == context else { return }
        attempt.result = .failed(text); attempt.wireID = nil; attempts[context.route.clientId] = attempt; changed?()
        if !context.isRelay && attempt.value { reconnect(context) }
    }

    private func checkpoint(_ context: AtemTransportPolicyContext, value: Bool, request: String?, revision: UInt64,
                            completed: Bool) -> AtemHostPolicyCheckpoint {
        let binding = context.binding!
        return AtemHostPolicyCheckpoint(account: context.account, issuer: context.issuer, station: context.station,
            host: context.route.deviceId, genesis: binding.genesis, manager: binding.manager, trust: binding.trust,
            relayOnly: value, requestID: request, expectedRevision: revision, completed: completed)
    }

    private func save(_ checkpoint: AtemHostPolicyCheckpoint) throws {
        guard checkpoint.valid else { throw AtemSessionJSON.Invalid.json }
        try journal.update { snapshot in
            var records = snapshot.hostPolicies ?? []
            records.removeAll { $0.account == checkpoint.account && $0.issuer == checkpoint.issuer
                && $0.station == checkpoint.station && $0.host == checkpoint.host }
            guard records.count < 1024 else { throw AtemSessionJSON.Invalid.limit }
            records.append(checkpoint); snapshot.hostPolicies = records
        }
    }
}
