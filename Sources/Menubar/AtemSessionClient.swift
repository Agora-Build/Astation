import Foundation

struct AtemSessionContext: Equatable {
    let route: RemoteTerminalConnection
    let account: String
    let device: String
    let pairingSession: String
    let transportGeneration: String

    init(route: RemoteTerminalConnection, account: String, device: String, pairingSession: String,
         transportGeneration: String? = nil) {
        self.route = route
        self.account = account
        self.device = device
        self.pairingSession = pairingSession
        self.transportGeneration = transportGeneration ?? route.connectionId
    }
}

/// Compatibility mode only: this context must come from the hub's existing
/// authenticated, safety-code-verified connection. Section 9 features stay off.
final class AtemSessionClient {
    enum Phase: Equatable { case offline, connecting, reconnecting, ready, failed }
    struct ConnectionStatus: Equatable {
        let phase: Phase
        let message: String
        let hasRegistrySnapshot: Bool
        let canReconnect: Bool
    }
    private(set) var phase: Phase = .offline
    private(set) var status = "Connect a verified Atem to use sessions."
    private(set) var context: AtemSessionContext?
    private(set) var welcome: AtemSessionMessage?
    private(set) var registry: [String: AtemSessionDescriptor] = [:]
    private(set) var latestReceipt: AtemSessionReceipt?
    private(set) var approvals: [String: AtemApprovalRequest] = [:]
    private(set) var closedApprovals: [String: String] = [:]
    var onChange: (() -> Void)?

    private struct Pending {
        let message: AtemSessionMessage
        let sent: TimeInterval
        let previousDeadline: TimeInterval?
    }
    private struct Lease {
        let target: AtemSessionTarget
        let epoch: UInt64
        let deadline: TimeInterval
        let renewAt: TimeInterval
    }
    private let currentContext: () -> AtemSessionContext?
    private let sendMessage: (AtemSessionMessage, RemoteTerminalConnection) -> Bool
    private let reconnectTransport: (AtemSessionContext) -> Bool
    private let now: () -> TimeInterval
    private let makeID: () -> String
    let journal: AtemSessionJournal
    private var pending: [String: Pending] = [:]
    private var leases: [String: Lease] = [:]
    private var highestLeaseEpoch: [String: UInt64] = [:]
    private var revokedLeaseEpoch: [String: UInt64] = [:]
    private var authorizationDeadline: TimeInterval = 0
    private(set) var runtimeEpoch: UInt64?
    private var runtimeGeneration: String?
    private(set) var sequence: UInt64?
    private var resyncing = true
    private var tombstones: [String: Set<String>] = [:]
    private var started = false
    private var lastHelloContext: AtemSessionContext?
    private var lastReceiptQuery: TimeInterval = 0
    var hasRegistrySnapshot: Bool { phase == .ready && !resyncing }
    var connectionStatus: ConnectionStatus {
        ConnectionStatus(phase: phase, message: status, hasRegistrySnapshot: hasRegistrySnapshot,
            canReconnect: phase == .failed && context != nil && context == currentContext() && !journal.loadFailed)
    }
    var canReviewApprovals: Bool {
        hasRegistrySnapshot && context == currentContext() && now() < authorizationDeadline
            && welcome?.permissions?.contains("control") == true
    }

    init(context: @escaping () -> AtemSessionContext?,
         send: @escaping (AtemSessionMessage, RemoteTerminalConnection) -> Bool,
         journal: AtemSessionJournal = AtemSessionJournal(),
         makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reconnect: @escaping (AtemSessionContext) -> Bool = { _ in false }) {
        currentContext = context
        sendMessage = send
        reconnectTransport = reconnect
        self.journal = journal
        self.now = now
        self.makeID = makeID
    }

    func start() { started = true; connectionChanged() }

    func connectionChanged() {
        guard started else { return }
        let current = currentContext()
        guard current != context else { return }
        context = current
        clearAttachment()
        phase = current == nil ? .offline : .connecting
        status = current == nil ? "Atem is offline. Unconfirmed requests will only be queried, never replayed."
            : "Opening an authenticated Atem session..."
        guard let current else { changed(); return }
        guard !journal.loadFailed else {
            fail("Session recovery metadata is unreadable. Remote control is disabled."); changed(); return
        }
        if let previous = lastHelloContext, previous.route == current.route,
           previous.transportGeneration == current.transportGeneration {
            reconnect()
            return
        }
        lastHelloContext = current
        _ = request(AtemSessionMessage(op: "hello"))
        changed()
    }

    private func clearAttachment() {
        welcome = nil
        registry = [:]
        approvals = [:]
        closedApprovals = [:]
        latestReceipt = nil
        leases = [:]
        highestLeaseEpoch = [:]
        revokedLeaseEpoch = [:]
        pending = [:]
        sequence = nil
        runtimeEpoch = nil
        runtimeGeneration = nil
        tombstones = [:]
        resyncing = true
        authorizationDeadline = 0
    }

    private func reconnect() {
        guard let context, context == currentContext(), !journal.loadFailed else { return }
        clearAttachment()
        phase = .reconnecting
        status = "Session reset; reconnecting..."
        changed()
        if !reconnectTransport(context) {
            fail("Session reset. Reconnect this Atem to open a fresh session connection.")
            changed()
        }
    }

    func target(sessionId: String, process: String) -> AtemSessionTarget? {
        guard phase == .ready, context == currentContext(), now() < authorizationDeadline, !resyncing,
              let context, let welcome, let trust = welcome.host_trust_gen,
              let descriptor = registry[sessionId], descriptor.process_gen == process, descriptor.state != "removed" else { return nil }
        return AtemSessionTarget(account_id: context.account, atem_device_id: context.device,
                                 host_trust_gen: trust, session_id: sessionId, process_gen: process)
    }

    func binding(for target: AtemSessionTarget, mutation: Bool) -> AtemSessionBinding? {
        guard target == self.target(sessionId: target.session_id, process: target.process_gen),
              let attachment = welcome?.attachment_gen else { return nil }
        if mutation {
            guard welcome?.permissions?.contains("control") == true, registry[target.session_id]?.state == "running",
                  let lease = leases[target.session_id], lease.target == target, now() < lease.deadline else { return nil }
            return AtemSessionBinding(target: target, attachment_gen: attachment, lease_epoch: lease.epoch)
        }
        return AtemSessionBinding(target: target, attachment_gen: attachment)
    }

    func controls(_ target: AtemSessionTarget) -> Bool { binding(for: target, mutation: true) != nil }
    func controlDeadline(for target: AtemSessionTarget) -> TimeInterval? { leases[target.session_id]?.deadline }

    func acquiring(_ target: AtemSessionTarget) -> Bool {
        pending.values.contains { $0.message.op == "acquire" && $0.message.binding?.target == target }
    }

    func acquire(_ target: AtemSessionTarget, takeover: Bool = true) {
        guard welcome?.permissions?.contains("control") == true, let binding = binding(for: target, mutation: false),
              registry[target.session_id]?.state == "running", !acquiring(target) else { return }
        if let old = leases[target.session_id], now() >= old.deadline {
            leases.removeValue(forKey: target.session_id)
            pending = pending.filter { $0.value.message.binding?.target != target || !["acquire", "renew"].contains($0.value.message.op) }
        }
        var message = AtemSessionMessage(op: "acquire")
        message.binding = binding
        message.takeover = takeover
        _ = request(message, deadline: leases[target.session_id]?.deadline)
        status = "Requesting control of this session..."
        changed()
    }

    func release(_ target: AtemSessionTarget) {
        let binding = binding(for: target, mutation: true)
        leases.removeValue(forKey: target.session_id)
        pending = pending.filter { $0.value.message.binding?.target != target || !["acquire", "renew"].contains($0.value.message.op) }
        if let binding {
            var message = AtemSessionMessage(op: "release")
            message.binding = binding
            _ = request(message)
        }
        status = "Viewing. Control has been released."
        changed()
    }

    func releaseAll() {
        let targets = leases.values.map(\.target)
        for target in targets { release(target) }
    }

    func renew(_ target: AtemSessionTarget) {
        guard let binding = binding(for: target, mutation: true),
              !pending.values.contains(where: { $0.message.op == "renew" && $0.message.binding?.target == target }),
              let deadline = leases[target.session_id]?.deadline else { return }
        var message = AtemSessionMessage(op: "renew")
        message.binding = binding
        _ = request(message, deadline: deadline)
    }

    @discardableResult
    func submit(_ target: AtemSessionTarget, kind: String, text: String? = nil,
                requestID: String = UUID().uuidString.lowercased()) -> String? {
        guard pending.count < 64, let binding = binding(for: target, mutation: true), ["prompt", "interrupt", "stop"].contains(kind) else { return nil }
        if kind == "prompt", registry[target.session_id]?.capabilities.contains("chat-v1") != true {
            status = "This agent accepts terminal input only. Type or paste in its terminal."
            changed()
            return nil
        }
        let payload: AtemSessionJSON = kind == "prompt" ? .object(["text": .string(text ?? "")]) : .object([:])
        var message = AtemSessionMessage(op: "submit")
        message.binding = binding
        message.request_id = requestID
        message.kind = kind
        message.payload = payload
        return submitDurably(message)
    }

    func canAnswer(_ approval: AtemApprovalRequest) -> Bool {
        guard canReviewApprovals, approvals[approval.approval_id] == approval,
              let target = target(sessionId: approval.session_id, process: approval.process_gen),
              registry[approval.session_id]?.state == "running" else { return false }
        return !journal.snapshot.requests.contains {
            $0.target == target && $0.approvalID == approval.approval_id && $0.receipt?.state != .rejected
        }
    }

    @discardableResult
    func answerApproval(_ approval: AtemApprovalRequest, decision: AtemApprovalAnswer.Decision,
                        ruleID: String? = nil, message: String? = nil,
                        requestID: String = UUID().uuidString.lowercased()) -> String? {
        guard pending.count < 64, canAnswer(approval),
              let target = target(sessionId: approval.session_id, process: approval.process_gen),
              let binding = binding(for: target, mutation: false) else { return nil }
        if decision == .allowAlways {
            guard registry[target.session_id]?.provider == "claude",
                  approval.always_rules.contains(where: { $0.rule_id == ruleID }) else { return nil }
        }
        let answer = AtemApprovalAnswer(approvalID: approval.approval_id, decision: decision, ruleID: ruleID, message: message)
        var submit = AtemSessionMessage(op: "submit")
        submit.binding = binding
        submit.request_id = requestID
        submit.kind = "approval"
        submit.payload = answer.payload
        return submitDurably(submit, approvalID: approval.approval_id)
    }

    private func submitDurably(_ message: AtemSessionMessage, approvalID: String? = nil) -> String? {
        guard let target = message.binding?.target, let payload = message.payload, let kind = message.kind else { return nil }
        do {
            try message.validate()
            let record = AtemSessionRequestRecord(requestId: message.request_id!, target: target, kind: kind,
                digest: try payload.digest(), approvalID: approvalID)
            if let previous = journal.snapshot.requests.first(where: { $0.requestId == record.requestId }) {
                guard previous.target == record.target, previous.kind == record.kind,
                      previous.digest == record.digest, previous.approvalID == record.approvalID else { return nil }
                return previous.requestId
            }
            // Persist the identity before sending. Reconnect uses receipt_query;
            // prompt text is never stored or automatically submitted again.
            try journal.update { state in
                if state.requests.count >= 4096, let oldestFinal = state.requests.firstIndex(where: { $0.receipt?.state.final == true }) {
                    state.requests.remove(at: oldestFinal)
                }
                state.requests.append(record)
            }
        } catch { status = "Could not save this request safely. Nothing was sent."; changed(); return nil }
        let delivered = request(message)
        latestReceipt = nil
        status = delivered ? "Submitted. Waiting for a durable receipt."
            : "Delivery is uncertain. Reconnect will query the request without resending it."
        changed()
        return message.request_id
    }

    func refresh() {
        if connectionStatus.canReconnect {
            reconnect()
            return
        }
        guard phase == .ready else { return }
        resyncing = true
        if !pending.values.contains(where: { $0.message.op == "list" }) { _ = request(AtemSessionMessage(op: "list")) }
    }

    func receive(_ message: AtemSessionMessage, from source: RemoteTerminalConnection) {
        guard context?.route == source, context == currentContext(), phase != .failed, phase != .reconnecting else { return }
        do {
            try message.validate()
            if message.op == "welcome" {
                guard phase == .connecting, let re = message.re, pending[re]?.message.op == "hello" else { return }
                try acceptWelcome(message); changed(); return
            }
            if message.op == "error", message.re == nil {
                if message.code == "unauthorized", welcome != nil { reconnect(); return }
                status = "Atem: " + AtemSessionWire.diagnosticErrorCode(message.code)
                if phase == .connecting || ["unauthorized", "paused", "unsupported_version"].contains(message.code ?? "") {
                    fail(status + ". Reconnect the session with matching Astation and Atem builds.")
                }
                changed(); return
            }
            if phase == .connecting, message.op == "error", let re = message.re, pending[re]?.message.op == "hello" {
                fail("Atem could not open a session: " + AtemSessionWire.diagnosticErrorCode(message.code)
                    + ". Reconnect to open a fresh session connection."); changed(); return
            }
            guard phase == .ready, now() < authorizationDeadline else { return }
            switch message.op {
            case "sessions", "session_changed": try acceptRegistry(message)
            case "approval_request":
                guard canReviewApprovals, let approval = message.approval,
                      target(sessionId: approval.session_id, process: approval.process_gen) != nil,
                      registry[approval.session_id]?.state == "running",
                      closedApprovals[approval.approval_id] == nil else { return }
                if let previous = approvals[approval.approval_id] {
                    try AtemSessionWire.check(previous.session_id == approval.session_id && previous.process_gen == approval.process_gen)
                }
                try AtemSessionWire.check(approvals.count < 64 || approvals[approval.approval_id] != nil)
                approvals[approval.approval_id] = approval
            case "approval_closed":
                guard canReviewApprovals, let id = message.approval_id, let reason = message.reason else { return }
                try AtemSessionWire.check(closedApprovals.count < 4096 || closedApprovals[id] != nil)
                closedApprovals[id] = reason
                approvals.removeValue(forKey: id)
            case "lease": acceptLease(message)
            case "lease_changed": acceptLeaseChange(message)
            case "lease_released":
                if let re = message.re, let operation = pending.removeValue(forKey: re), operation.message.op == "release" { break }
            case "receipt":
                if let re = message.re {
                    guard let operation = pending[re], operation.message.op == "submit",
                          operation.message.request_id == message.request_id,
                          operation.message.binding?.target == message.target,
                          operation.message.kind == message.kind else { return }
                    pending.removeValue(forKey: re)
                }
                if let receipt = message.receipt { try acceptReceipt(receipt) }
            case "receipts":
                guard let re = message.re, let operation = pending.removeValue(forKey: re), operation.message.op == "receipt_query" else { return }
                for receipt in message.receipts ?? [] {
                    guard operation.message.binding?.target == receipt.target,
                          operation.message.request_ids?.contains(receipt.request_id) == true else { throw AtemSessionJSON.Invalid.json }
                    try acceptReceipt(receipt)
                }
            case "error":
                guard let re = message.re, let operation = pending.removeValue(forKey: re) else { return }
                if let target = operation.message.binding?.target,
                   ["acquire", "renew", "release"].contains(operation.message.op) { leases.removeValue(forKey: target.session_id) }
                status = "Atem: " + AtemSessionWire.diagnosticErrorCode(message.code)
                handleRefusal(code: message.code ?? "request failed", target: operation.message.binding?.target)
                if message.code == "busy", operation.message.op == "submit" {
                    status = "Atem is busy. Checking the receipt without resending this request."
                }
                if message.code == "stale_target", operation.message.kind == "approval",
                   let id = operation.message.payload?["approval_id"]?.string {
                    approvals.removeValue(forKey: id)
                }
            default: break
            }
        } catch { fail("Atem sent an invalid or inconsistent session message. Reconnect to continue.") }
        changed()
    }

    func tick() {
        connectionChanged()
        guard phase == .ready else {
            if phase == .connecting, pending.values.contains(where: { now() - $0.sent >= 8 }) {
                fail("This Atem did not open a session. Update Atem to enable remote control.")
                changed()
            }
            return
        }
        let time = now()
        if time >= authorizationDeadline { fail("Session authorization expired. Reconnect the verified Atem."); changed(); return }
        for (session, lease) in leases {
            if time >= lease.deadline {
                leases.removeValue(forKey: session)
                status = "Control expired. Take Control explicitly to type again."
                changed()
            } else if time >= lease.renewAt, !pending.values.contains(where: { $0.message.op == "renew" && $0.message.binding?.target == lease.target }) {
                renew(lease.target)
            }
        }
        let timedOut = pending.filter { time - $0.value.sent >= 15 }
        for (id, operation) in timedOut {
            pending.removeValue(forKey: id)
            if operation.message.op == "submit" { status = "Receipt delayed. The request will not be replayed." }
        }
        if time - lastReceiptQuery >= 5 { queryUnresolvedReceipts() }
    }

    private func acceptWelcome(_ message: AtemSessionMessage) throws {
        guard phase == .connecting, let re = message.re, let hello = pending.removeValue(forKey: re), hello.message.op == "hello",
              let context, message.account_id == context.account, message.atem_device_id == context.device,
              message.client_kind == "native", message.permissions?.contains("view") == true,
              let remaining = message.authorization_ms_left, remaining > 0, remaining <= 86_400_000,
              let trust = message.host_trust_gen else { throw AtemSessionJSON.Invalid.json }
        try journal.update { state in
            if let index = state.hosts.firstIndex(where: { $0.account == context.account && $0.device == context.device }) {
                let previous = state.hosts[index]
                try AtemSessionWire.check(trust >= previous.trust)
                if trust > previous.trust { state.hosts[index] = AtemSessionHostFence(account: context.account, device: context.device, trust: trust) }
            } else { state.hosts.append(AtemSessionHostFence(account: context.account, device: context.device, trust: trust)) }
        }
        if let fence = journal.snapshot.hosts.first(where: { $0.account == context.account && $0.device == context.device }) {
            runtimeEpoch = fence.runtimeEpoch
            runtimeGeneration = fence.runtimeGeneration
        }
        authorizationDeadline = min(hello.sent + Double(remaining) / 1000, now() + Double(remaining) / 1000)
        try AtemSessionWire.check(now() < authorizationDeadline)
        welcome = message
        // Sequence numbers, removals and authority belong to this attachment;
        // only the durable trust/runtime floor survives a new welcome.
        registry = [:]
        sequence = nil
        tombstones = [:]
        leases = [:]
        highestLeaseEpoch = [:]
        revokedLeaseEpoch = [:]
        resyncing = true
        latestReceipt = nil
        phase = .ready
        status = "Viewing. Select a session and take control explicitly."
        refresh()
        queryUnresolvedReceipts()
    }

    private func acceptRegistry(_ message: AtemSessionMessage) throws {
        guard let epoch = message.runtime_epoch, let generation = message.runtime_gen, let incoming = message.seq else { return }
        if let runtimeEpoch, epoch < runtimeEpoch { return }
        if epoch == runtimeEpoch, let runtimeGeneration, generation != runtimeGeneration { throw AtemSessionJSON.Invalid.json }
        if generation != welcome?.runtime_gen {
            if let runtimeEpoch, epoch > runtimeEpoch {
                try persistRuntime(epoch: epoch, generation: generation)
                // The old attachment cannot be welcomed again. Wait for the
                // host's replacement authenticated connection before hello.
                registry = [:]
                sequence = nil
                tombstones = [:]
                resyncing = true
                fail("Atem restarted. Reconnect to open a fresh session attachment.")
            }
            return
        }
        let previousRegistry = registry
        let newEpoch = epoch != runtimeEpoch
        if newEpoch {
            try persistRuntime(epoch: epoch, generation: generation)
            sequence = nil
            leases = [:]
            highestLeaseEpoch = [:]
            revokedLeaseEpoch = [:]
            pending = pending.filter { !["acquire", "renew", "release"].contains($0.value.message.op) }
            registry = [:]
            tombstones = [:]
            resyncing = true
        }
        if message.op == "sessions" {
            guard sequence.map({ incoming >= $0 }) != false else { return }
            let descriptors = message.sessions ?? []
            try AtemSessionWire.check(Set(descriptors.map(\.session_id)).count == descriptors.count)
            var next: [String: AtemSessionDescriptor] = [:]
            for descriptor in descriptors {
                if tombstones[descriptor.session_id]?.contains(descriptor.process_gen) == true { continue }
                if descriptor.state == "removed" { tombstones[descriptor.session_id, default: []].insert(descriptor.process_gen) }
                else { next[descriptor.session_id] = descriptor }
            }
            registry = next
            sequence = incoming
            resyncing = false
            pending = pending.filter { $0.value.message.op != "list" }
        } else {
            guard !newEpoch, !resyncing, let previous = sequence else { refresh(); return }
            guard incoming > previous else { return }
            guard incoming == previous + 1 else { refresh(); return }
            guard let descriptor = message.descriptor else { return }
            sequence = incoming
            if descriptor.state == "removed" {
                registry.removeValue(forKey: descriptor.session_id)
                tombstones[descriptor.session_id, default: []].insert(descriptor.process_gen)
            } else if tombstones[descriptor.session_id]?.contains(descriptor.process_gen) != true { registry[descriptor.session_id] = descriptor }
        }
        for (id, lease) in leases where target(sessionId: id, process: lease.target.process_gen) != lease.target || registry[id]?.state != "running" {
            leases.removeValue(forKey: id)
        }
        for (id, descriptor) in previousRegistry where registry[id]?.process_gen != descriptor.process_gen {
            highestLeaseEpoch.removeValue(forKey: id)
            revokedLeaseEpoch.removeValue(forKey: id)
            pending = pending.filter { $0.value.message.binding?.target.session_id != id || !["acquire", "renew"].contains($0.value.message.op) }
        }
        approvals = approvals.filter { _, approval in
            registry[approval.session_id]?.process_gen == approval.process_gen && registry[approval.session_id]?.state == "running"
        }
        try AtemSessionWire.check(tombstones.values.reduce(0) { $0 + $1.count } <= 4096)
    }

    private func persistRuntime(epoch: UInt64, generation: String) throws {
        guard let context, let trust = welcome?.host_trust_gen else { throw AtemSessionJSON.Invalid.json }
        try journal.update { state in
            guard let index = state.hosts.firstIndex(where: { $0.account == context.account && $0.device == context.device && $0.trust == trust }) else { throw AtemSessionJSON.Invalid.json }
            state.hosts[index].runtimeEpoch = epoch
            state.hosts[index].runtimeGeneration = generation
        }
        runtimeEpoch = epoch
        runtimeGeneration = generation
    }

    private func acceptLease(_ message: AtemSessionMessage) {
        guard let re = message.re, let operation = pending.removeValue(forKey: re), ["acquire", "renew"].contains(operation.message.op),
              let binding = message.binding, binding.attachment_gen == welcome?.attachment_gen,
              binding.target == operation.message.binding?.target,
              binding.target == target(sessionId: binding.target.session_id, process: binding.target.process_gen),
              let epoch = binding.lease_epoch, epoch >= (highestLeaseEpoch[binding.target.session_id] ?? 0),
              revokedLeaseEpoch[binding.target.session_id].map({ epoch > $0 }) != false,
              operation.message.op != "renew" || epoch == operation.message.binding?.lease_epoch else { return }
        if let previous = operation.previousDeadline, now() >= previous {
            leases.removeValue(forKey: binding.target.session_id)
            status = "Control confirmation arrived after expiry. Take Control again."
            return
        }
        var deadline = min(operation.sent + Double(message.ms_left ?? 0) / 1000, authorizationDeadline)
        if operation.message.op == "acquire", let previous = operation.previousDeadline { deadline = min(previous, deadline) }
        guard now() < deadline else { leases.removeValue(forKey: binding.target.session_id); return }
        highestLeaseEpoch[binding.target.session_id] = epoch
        leases[binding.target.session_id] = Lease(target: binding.target, epoch: epoch, deadline: deadline, renewAt: operation.sent + 5)
        status = "Controlling this session. Local input on Atem takes priority."
    }

    private func acceptLeaseChange(_ message: AtemSessionMessage) {
        guard let id = message.session_id, let epoch = message.lease_epoch,
              registry[id]?.process_gen == message.process_gen, epoch >= (highestLeaseEpoch[id] ?? 0) else { return }
        highestLeaseEpoch[id] = epoch
        if message.controller?.controller_session != welcome?.controller_session {
            revokedLeaseEpoch[id] = epoch
            pending = pending.filter { $0.value.message.binding?.target.session_id != id || !["acquire", "renew"].contains($0.value.message.op) }
        }
        if let lease = leases[id], epoch > lease.epoch || message.controller?.controller_session != welcome?.controller_session {
            leases.removeValue(forKey: id)
            pending = pending.filter { $0.value.message.binding?.target.session_id != id || !["acquire", "renew"].contains($0.value.message.op) }
            status = "Viewing. Control changed on Atem."
        }
        // r7 grants an approval's lease before returning its receipt. Adopt only
        // a grant caused by this attachment's explicit, still-pending answer.
        if message.controller?.controller_session == welcome?.controller_session,
           ["granted", "takeover"].contains(message.reason ?? ""),
           revokedLeaseEpoch[id].map({ epoch > $0 }) != false,
           let operation = pending.values.first(where: {
               $0.message.op == "submit" && $0.message.kind == "approval"
                   && $0.message.binding?.target.session_id == id
                   && $0.message.binding?.target.process_gen == message.process_gen
                   && $0.message.payload?["acquire"] == .bool(true)
           }), let target = operation.message.binding?.target,
           target == self.target(sessionId: id, process: target.process_gen) {
            let deadline = min(operation.sent + 15, authorizationDeadline)
            if now() < deadline {
                leases[id] = Lease(target: target, epoch: epoch, deadline: deadline, renewAt: operation.sent + 5)
            }
        }
    }

    private func acceptReceipt(_ receipt: AtemSessionReceipt) throws {
        guard let context, receipt.target.account_id == context.account, receipt.target.atem_device_id == context.device,
              receipt.target.host_trust_gen == welcome?.host_trust_gen,
              let index = journal.snapshot.requests.firstIndex(where: { $0.requestId == receipt.request_id }) else { return }
        let record = journal.snapshot.requests[index]
        try AtemSessionWire.check(record.target == receipt.target && record.kind == receipt.kind)
        if let previous = record.receipt {
            if receipt.updated_at < previous.updated_at { return }
            try AtemSessionWire.check(previous.state.permits(receipt.state))
            if previous.state.final { try AtemSessionWire.check(previous == receipt); return }
        }
        try journal.update { $0.requests[index].receipt = receipt }
        guard journal.snapshot.requests.last(where: { $0.target == receipt.target })?.requestId == receipt.request_id else { return }
        latestReceipt = receipt
        status = receipt.state == .outcome_unknown ? "Outcome unknown. Inspect the agent before submitting another request."
            : "Request " + receipt.state.rawValue.replacingOccurrences(of: "_", with: " ") + "."
    }

    func handleRefusal(code: String, target: AtemSessionTarget?) {
        if let target, ["forbidden", "session_closed", "stale_lease", "stale_target", "unknown_session"].contains(code) {
            leases.removeValue(forKey: target.session_id)
            pending = pending.filter { $0.value.message.binding?.target != target || !["acquire", "renew"].contains($0.value.message.op) }
        }
        status = "Atem: " + AtemSessionWire.diagnosticErrorCode(code)
        if code == "unauthorized", welcome != nil {
            reconnect()
        } else if ["unauthorized", "paused", "unsupported_version"].contains(code) {
            fail("Session access refused (" + code + "). Reconnect the verified Atem with matching builds.")
        } else if ["session_closed", "stale_target", "unknown_session"].contains(code) { refresh() }
        changed()
    }

    private func queryUnresolvedReceipts() {
        guard let context, let trust = welcome?.host_trust_gen, let attachment = welcome?.attachment_gen else { return }
        lastReceiptQuery = now()
        let unresolved = journal.snapshot.requests.filter {
            $0.target.account_id == context.account && $0.target.atem_device_id == context.device
                && $0.target.host_trust_gen == trust && $0.receipt?.state.final != true
        }
        for (target, records) in Dictionary(grouping: unresolved, by: \.target) {
            if pending.values.contains(where: { $0.message.op == "receipt_query" && $0.message.binding?.target == target }) { continue }
            for offset in stride(from: 0, to: records.count, by: 64) {
                var message = AtemSessionMessage(op: "receipt_query")
                message.binding = AtemSessionBinding(target: target, attachment_gen: attachment)
                message.request_ids = Array(records[offset..<min(offset + 64, records.count)]).map(\.requestId)
                _ = request(message)
            }
        }
    }

    @discardableResult
    private func request(_ original: AtemSessionMessage, deadline: TimeInterval? = nil) -> Bool {
        var message = original
        message.id = makeID()
        guard let context, context == currentContext(), pending.count < 64, (try? message.validate()) != nil else { return false }
        pending[message.id] = Pending(message: message, sent: now(), previousDeadline: deadline)
        return sendMessage(message, context.route)
    }
    private func fail(_ text: String) {
        phase = .failed
        approvals = [:]
        leases = [:]
        pending = [:]
        status = text
    }
    private func changed() { onChange?() }
}
