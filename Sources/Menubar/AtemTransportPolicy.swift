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

struct AtemTransportPolicyAck: Codable, Equatable {
    let relayOnly: Bool
    let stored: Bool
    var reason: String?
    enum CodingKeys: String, CodingKey { case relayOnly = "relay_only", stored, reason }
}

struct AtemTransportPolicyContext: Equatable {
    let route: AtemVerificationRoute
    let account: String
    let issuer: String
    let station: String
    let pairingSession: String
    let transportGeneration: String
    let verifiedPin: AtemDevicePin?
    var isRelay: Bool { route.clientId.hasPrefix("relay-") }
}

/// Outer ACKs are unverified routing reports, never activation or device authority.
final class AtemTransportPolicyController {
    enum Result: Equatable { case pending, reported, failed(String) }
    private struct Attempt {
        let context: AtemTransportPolicyContext
        let value: Bool
        let deadline: TimeInterval
        var result: Result
    }
    private let journal: AtemSessionJournal
    private let now: () -> TimeInterval
    private let current: (AtemTransportPolicyContext) -> Bool
    private let send: (Bool, AtemTransportPolicyContext) -> Void
    private let reconnect: (AtemTransportPolicyContext) -> Void
    private var attempts: [String: Attempt] = [:]
    private var fenced: [String: AtemTransportPolicyContext] = [:]
    var changed: (() -> Void)?

    init(journal: AtemSessionJournal, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         current: @escaping (AtemTransportPolicyContext) -> Bool,
         send: @escaping (Bool, AtemTransportPolicyContext) -> Void,
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
        }
        for context in connections { authenticated(context) }
        changed?()
    }

    func authenticated(_ context: AtemTransportPolicyContext) {
        guard !journal.loadFailed, current(context),
              let policy = policy(account: context.account, issuer: context.issuer) else { return }
        if fenced[context.route.clientId] == context { return }
        fenced.removeValue(forKey: context.route.clientId)
        guard policy.station == context.station else {
            attempts.removeValue(forKey: context.route.clientId)
            changed?()
            return
        }
        if let previous = attempts[context.route.clientId], previous.context == context {
            if previous.value != policy.relayOnly {
                // No request ID exists on this wire. A fresh link fences ABA replies.
                attempts.removeValue(forKey: context.route.clientId)
                fenced[context.route.clientId] = context
                reconnect(context)
            }
            return
        }
        attempts[context.route.clientId] = Attempt(context: context, value: policy.relayOnly,
            deadline: now() + 10, result: .pending)
        send(policy.relayOnly, context)
        changed?()
    }

    func receive(_ ack: AtemTransportPolicyAck, context: AtemTransportPolicyContext) {
        guard !journal.loadFailed, current(context),
              var attempt = attempts[context.route.clientId], attempt.context == context,
              attempt.result == .pending, now() < attempt.deadline,
              let policy = policy(account: context.account, issuer: context.issuer),
              policy.station == context.station, policy.relayOnly == attempt.value,
              ack.relayOnly == attempt.value else { return }
        attempt.result = ack.stored && ack.reason == nil ? .reported : .failed("Atem could not save the transport policy.")
        attempts[context.route.clientId] = attempt
        changed?()
        if context.isRelay == false && attempt.value { reconnect(context) }
    }

    func disconnected(clientID: String) {
        attempts.removeValue(forKey: clientID)
        changed?()
    }

    func tick() {
        for (id, var attempt) in Array(attempts) {
            guard current(attempt.context) else { attempts.removeValue(forKey: id); changed?(); continue }
            guard attempt.result == .pending, now() >= attempt.deadline else { continue }
            attempt.result = .failed("Atem did not confirm the transport policy. Reconnect to retry.")
            attempts[id] = attempt
            changed?()
            if !attempt.context.isRelay && attempt.value { reconnect(attempt.context) }
        }
    }

    func ready(account: String, issuer: String, station: String) -> Bool {
        // Atem #99: the relay can forge outer ACKs. Only the agreed authenticated
        // replacement can satisfy activation, even with a complete set of reports.
        false
    }

    func allHostsReported(account: String, issuer: String, station: String) -> Bool {
        guard !journal.loadFailed, let policy = policy(account: account, issuer: issuer),
              policy.relayOnly, policy.station == station else { return false }
        guard !attempts.values.contains(where: { current($0.context) && $0.context.account == account
            && $0.context.issuer == issuer && !policy.hosts.contains($0.context.route.deviceId) }) else { return false }
        return policy.hosts.allSatisfy { host in
            attempts.values.contains { attempt in
                attempt.context.account == account && attempt.context.issuer == issuer
                    && attempt.context.station == station && attempt.context.route.deviceId == host
                    && attempt.context.verifiedPin != nil && attempt.context.isRelay
                    && attempt.value && attempt.result == .reported && current(attempt.context)
            }
        }
    }

    func status(account: String, issuer: String, station: String) -> String {
        if journal.loadFailed { return "Transport policy storage is unavailable. Access is blocked until it can be reloaded." }
        guard let policy = policy(account: account, issuer: issuer) else { return "No transport policy has been requested on this Mac." }
        guard policy.station == station else { return "The saved policy belongs to another Station. Review the selected relay before continuing." }
        if !policy.relayOnly { return "Direct connections are permitted. Atems reconcile this policy when they authenticate." }
        if allHostsReported(account: account, issuer: issuer, station: station) {
            return "All enrolled Atem hosts reported relay-only. Authenticated policy confirmation is not available yet; hosted execution remains disabled."
        }
        for attempt in attempts.values where attempt.context.account == account && attempt.context.issuer == issuer
            && attempt.context.station == station && current(attempt.context) {
            if case .failed(let message) = attempt.result { return message + " Hosted execution remains disabled." }
        }
        return "Relay-only requested. Waiting for all enrolled Atem hosts to confirm on the selected relay; offline hosts remain pending."
    }
}
