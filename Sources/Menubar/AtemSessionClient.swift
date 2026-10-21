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

/// The hub supplies the authenticated, safety-code-verified connection.
/// Protocol r8 is required; section 9's membership gates remain enforced.
final class AtemSessionClient {
    enum Phase: Equatable { case offline, connecting, reconnecting, ready, failed }
    private enum WelcomeFailure: Error {
        enum Field: String {
            case account = "account_id", device = "atem_device_id", clientKind = "client_kind"
            case permissions, authorization = "authorization_ms_left", hostError = "host_error"
        }
        case invalid(Field)
        case trustRollback(received: UInt64, minimum: UInt64)
        case storage

        var diagnostic: String {
            switch self {
            case .invalid(let field): return "welcome.\(field.rawValue)"
            case .trustRollback(let received, let minimum):
                return "welcome.host_trust_gen_rollback received=\(received) minimum=\(minimum)"
            case .storage: return "welcome.journal_storage"
            }
        }

        var message: String {
            switch self {
            case .invalid(let field):
                return "Atem's session welcome failed validation (\(field.rawValue)). Reconnect the verified Atem."
            case .trustRollback(let received, let minimum):
                return "Atem reported an older trust generation (\(received); previously accepted \(minimum)). Resolve its trust state before reconnecting."
            case .storage:
                return "Could not save the session's verification state. Check this Mac's local storage before reconnecting."
            }
        }
    }
    struct ConnectionStatus: Equatable {
        let phase: Phase
        let message: String
        let hasRegistrySnapshot: Bool
        let canReconnect: Bool
        let unsupportedVersion: Bool
    }
    private(set) var phase: Phase = .offline
    private(set) var status = "Connect a verified Atem to use sessions."
    private(set) var context: AtemSessionContext?
    private(set) var welcome: AtemSessionMessage?
    private(set) var features: Set<String> = []
    private(set) var unsupportedVersion = false
    private(set) var registry: [String: AtemSessionDescriptor] = [:]
    private(set) var latestReceipt: AtemSessionReceipt?
    private(set) var approvals: [String: AtemApprovalRequest] = [:]
    private(set) var closedApprovals: [String: String] = [:]
    private(set) var approvalRules: [String: [AtemApprovalRule]] = [:]
    private var regrantedAfterRevoke: Set<String> = []
    var approvalActivities: [AtemApprovalActivity] { canReviewApprovals ? chat.activities : [] }
    var onChange: (() -> Void)?

    private struct Pending {
        let message: AtemSessionMessage
        let sent: TimeInterval
        let previousDeadline: TimeInterval?
        let owner: String
        var mayAdoptControl = true
    }
    private struct Lease {
        let target: AtemSessionTarget
        let epoch: UInt64
        let deadline: TimeInterval
        let renewAt: TimeInterval
        let owner: String
    }
    private let currentContext: () -> AtemSessionContext?
    private let sendMessage: (AtemSessionMessage, RemoteTerminalConnection) -> Bool
    private let reconnectTransport: (AtemSessionContext) -> Bool
    private let now: () -> TimeInterval
    private let makeID: () -> String
    private let sendChat: (AgentChatWire, RemoteTerminalConnection) -> Bool
    private lazy var chat = AtemSessionChat(now: now, features: { [weak self] in self?.features ?? [] }) { [weak self] message in
        guard let self, let context = self.context, context == self.currentContext(),
              message.binding?.attachment_gen == self.welcome?.attachment_gen else { return false }
        return self.sendChat(message, context.route)
    }
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
    private var helloRefusedBeforeVerification = false
    private var verificationCompleted = false
    private var retriedAfterVerification = false
    private var lastReceiptQuery: TimeInterval = 0
    var hasRegistrySnapshot: Bool { phase == .ready && !resyncing }
    var connectionStatus: ConnectionStatus {
        ConnectionStatus(phase: phase, message: status, hasRegistrySnapshot: hasRegistrySnapshot,
            canReconnect: phase == .failed && context != nil && context == currentContext() && !journal.loadFailed,
            unsupportedVersion: unsupportedVersion)
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
         reconnect: @escaping (AtemSessionContext) -> Bool = { _ in false },
         sendChat: @escaping (AgentChatWire, RemoteTerminalConnection) -> Bool = { _, _ in false }) {
        currentContext = context
        sendMessage = send
        reconnectTransport = reconnect
        self.journal = journal
        self.now = now
        self.makeID = makeID
        self.sendChat = sendChat
    }

    func start() { started = true; connectionChanged() }

    func connectionChanged() {
        guard started else { return }
        let current = currentContext()
        guard current != context else { return }
        context = current
        clearAttachment()
        helloRefusedBeforeVerification = false
        verificationCompleted = false
        retriedAfterVerification = false
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
        var hello = AtemSessionMessage(op: "hello")
        hello.revision = AtemSessionWire.revision
        _ = request(hello)
        changed()
    }

    /// Only local verification completion can retry a refused initial hello.
    func verificationDidComplete(context verified: AtemSessionContext) {
        guard welcome == nil, [.connecting, .failed].contains(phase), !retriedAfterVerification,
              context == verified, verified == currentContext(), !journal.loadFailed else { return }
        verificationCompleted = true
        retryInitialHelloAfterVerification()
    }

    private func retryInitialHelloAfterVerification() {
        guard phase == .failed, welcome == nil, helloRefusedBeforeVerification,
              verificationCompleted, !retriedAfterVerification, context != nil,
              context == currentContext(), !journal.loadFailed else { return }
        retriedAfterVerification = true
        helloRefusedBeforeVerification = false
        clearAttachment()
        phase = .connecting
        status = "Verification complete. Opening an authenticated Atem session..."
        var hello = AtemSessionMessage(op: "hello")
        hello.revision = AtemSessionWire.revision
        _ = request(hello)
        changed()
    }

    private func clearAttachment() {
        chat.reset(sendClose: false)
        approvalRules = [:]
        regrantedAfterRevoke = []
        welcome = nil
        features = []
        unsupportedVersion = false
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

    func binding(for target: AtemSessionTarget, mutation: Bool, owner: String = "native") -> AtemSessionBinding? {
        guard target == self.target(sessionId: target.session_id, process: target.process_gen),
              let attachment = welcome?.attachment_gen else { return nil }
        if mutation {
            guard welcome?.permissions?.contains("control") == true, registry[target.session_id]?.state == "running",
                  let lease = leases[target.session_id], lease.target == target, lease.owner == owner, now() < lease.deadline else { return nil }
            return AtemSessionBinding(target: target, attachment_gen: attachment, lease_epoch: lease.epoch)
        }
        return AtemSessionBinding(target: target, attachment_gen: attachment)
    }

    func controls(_ target: AtemSessionTarget) -> Bool { binding(for: target, mutation: true) != nil }
    func controlOwner(for target: AtemSessionTarget) -> String? {
        guard let lease = leases[target.session_id], lease.target == target, now() < lease.deadline else { return nil }
        return lease.owner
    }
    func controlDeadline(for target: AtemSessionTarget) -> TimeInterval? { leases[target.session_id]?.deadline }

    func acquiring(_ target: AtemSessionTarget) -> Bool {
        pending.values.contains { $0.message.op == "acquire" && $0.message.binding?.target == target }
    }

    @discardableResult
    func acquire(_ target: AtemSessionTarget, takeover: Bool = true, owner: String = "native") -> Bool {
        guard pending.count < 64, welcome?.permissions?.contains("control") == true, let binding = binding(for: target, mutation: false),
              registry[target.session_id]?.state == "running", !acquiring(target),
              controlOwner(for: target).map({ $0 == owner }) != false,
              !otherOwnerPending(target, owner: owner) else { return false }
        if let old = leases[target.session_id], now() >= old.deadline {
            leases.removeValue(forKey: target.session_id)
            pending = pending.filter { $0.value.message.binding?.target != target || !["acquire", "renew"].contains($0.value.message.op) }
        }
        var message = AtemSessionMessage(op: "acquire")
        message.binding = binding
        message.takeover = takeover
        _ = request(message, deadline: leases[target.session_id]?.deadline, owner: owner)
        status = "Requesting control of this session..."
        changed()
        return true
    }

    func release(_ target: AtemSessionTarget, owner: String = "native") {
        guard controlOwner(for: target).map({ $0 == owner }) != false else { return }
        let binding = binding(for: target, mutation: true, owner: owner)
        leases.removeValue(forKey: target.session_id)
        pending = pending.filter { $0.value.message.binding?.target != target || !["acquire", "renew"].contains($0.value.message.op) }
        // Keep receipt recovery, but a reply to a closed/backgrounded view
        // must never restore its authority.
        for (id, operation) in pending where operation.owner == owner && operation.message.binding?.target == target {
            pending[id]?.mayAdoptControl = false
        }
        if let binding {
            var message = AtemSessionMessage(op: "release")
            message.binding = binding
            _ = request(message)
        }
        status = "Viewing. Control has been released."
        changed()
    }

    func releaseAll() {
        let targets = Set(leases.values.filter { $0.owner == "native" }.map(\.target)
            + pending.values.filter { $0.owner == "native" }.compactMap { $0.message.binding?.target })
        for target in targets { release(target) }
    }

    private func otherOwnerPending(_ target: AtemSessionTarget, owner: String) -> Bool {
        pending.values.contains { $0.mayAdoptControl && $0.owner != owner && $0.message.binding?.target == target
            && ($0.message.op == "acquire" || ($0.message.op == "submit" && $0.message.kind == "prompt")) }
    }

    @discardableResult
    func renew(_ target: AtemSessionTarget, owner: String = "native") -> Bool {
        guard let binding = binding(for: target, mutation: true, owner: owner),
              !pending.values.contains(where: { $0.message.op == "renew" && $0.message.binding?.target == target }),
              let deadline = leases[target.session_id]?.deadline else { return false }
        var message = AtemSessionMessage(op: "renew")
        message.binding = binding
        _ = request(message, deadline: deadline, owner: owner)
        return true
    }

    @discardableResult
    func submit(_ target: AtemSessionTarget, kind: String, text: String? = nil,
                requestID: String = UUID().uuidString.lowercased(), takeover: AtemSessionController? = nil,
                owner: String = "native") -> String? {
        guard pending.count < 64, welcome?.permissions?.contains("control") == true,
              registry[target.session_id]?.state == "running", ["prompt", "interrupt", "stop"].contains(kind),
              controlOwner(for: target).map({ $0 == owner }) != false,
              !otherOwnerPending(target, owner: owner) else { return nil }
        if kind == "prompt", registry[target.session_id]?.capabilities.contains("chat-v1") != true {
            status = "This agent accepts terminal input only. Type or paste in its terminal."
            changed()
            return nil
        }
        let payload: AtemSessionJSON = kind == "prompt" ? .object(["text": .string(text ?? "")]) : .object([:])
        let held = binding(for: target, mutation: true, owner: owner)
        guard let binding = held ?? (kind == "prompt" && features.contains("chat.send_acquire")
            ? binding(for: target, mutation: false) : nil), kind == "prompt" || takeover == nil else { return nil }
        var message = AtemSessionMessage(op: "submit")
        message.binding = binding
        message.request_id = requestID
        message.kind = kind
        message.payload = payload
        if held == nil {
            message.acquire = true
            if let takeover { message.takeover = true; message.expected_controller = takeover }
        } else if takeover != nil { return nil }
        return submitDurably(message, owner: owner)
    }

    func canAnswer(_ approval: AtemApprovalRequest) -> Bool {
        guard canReviewApprovals, features.contains("approval.lease_free"), approvals[approval.approval_id] == approval,
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
            guard approval.always_rules.contains(where: { $0.rule_id == ruleID }) else { return nil }
        }
        let answer = AtemApprovalAnswer(approvalID: approval.approval_id, decision: decision, ruleID: ruleID, message: message)
        var submit = AtemSessionMessage(op: "submit")
        submit.binding = binding
        submit.request_id = requestID
        submit.kind = "approval"
        submit.payload = answer.payload
        return submitDurably(submit, approvalID: approval.approval_id)
    }

    func hasRule(_ rule: AtemApprovalRule, target: AtemSessionTarget) -> Bool {
        canReviewApprovals && features.contains("approval.session_rules") && target == self.target(sessionId: target.session_id, process: target.process_gen)
            && registry[target.session_id]?.state == "running" && approvalRules[target.session_id]?.contains(rule) == true
    }

    func revokeRecord(_ rule: AtemApprovalRule, target: AtemSessionTarget) -> AtemSessionRequestRecord? {
        guard let digest = try? AtemSessionJSON.object(["rule_id": .string(rule.rule_id)]).digest() else { return nil }
        let record = journal.snapshot.requests.last { $0.target == target && $0.kind == "approval_rule_revoke" && $0.digest == digest }
        return record.flatMap { regrantedAfterRevoke.contains($0.requestId) ? nil : $0 }
    }

    func canRevoke(_ rule: AtemApprovalRule, target: AtemSessionTarget) -> Bool {
        hasRule(rule, target: target)
            && revokeRecord(rule, target: target).map { $0.receipt?.state == .rejected } != false
    }

    @discardableResult
    func revokeRule(_ rule: AtemApprovalRule, target: AtemSessionTarget,
                    requestID: String = UUID().uuidString.lowercased()) -> String? {
        guard pending.count < 64, canRevoke(rule, target: target), let binding = binding(for: target, mutation: false) else { return nil }
        var message = AtemSessionMessage(op: "submit")
        message.binding = binding
        message.request_id = requestID
        message.kind = "approval_rule_revoke"
        message.payload = .object(["rule_id": .string(rule.rule_id)])
        return submitDurably(message)
    }

    func receiveChat(_ event: AgentChatWire, from source: RemoteTerminalConnection) {
        guard hasRegistrySnapshot, context == currentContext(), now() < authorizationDeadline, source == context?.route,
              let descriptor = registry[event.agentId], descriptor.state == "running",
              descriptor.capabilities.contains("chat-v1") else { return }
        if let generation = event.generation, generation != descriptor.process_gen,
           let target = target(sessionId: descriptor.session_id, process: descriptor.process_gen),
           chat.snapshot(target)?.chat_id == event.conversationId {
            refresh()
            changed()
            return
        }
        if chat.receive(event) { changed() }
    }

    func chatSnapshot(_ target: AtemSessionTarget) -> AtemSessionChat.Snapshot? {
        guard target == self.target(sessionId: target.session_id, process: target.process_gen),
              features.contains("chat.history_end") else { return nil }
        return chat.snapshot(target)
    }

    func readChat(_ target: AtemSessionTarget) -> AtemSessionChat.Snapshot? {
        guard features.contains("chat.history_end"), registry[target.session_id]?.state == "running",
              registry[target.session_id]?.capabilities.contains("chat-v1") == true,
              let binding = binding(for: target, mutation: false) else { return nil }
        chat.requestView(binding)
        return chat.snapshot(target)
    }

    func chatHistory(_ target: AtemSessionTarget, before: String? = nil, next: String? = nil,
                     turn: String? = nil, request: String? = nil) -> String? {
        guard target == self.target(sessionId: target.session_id, process: target.process_gen) else { return nil }
        return chat.history(target, before: before, next: next, turn: turn, request: request, features: features)
    }

    func chatPage(_ target: AtemSessionTarget, pageID: String) -> AtemSessionChat.HistoryReply? {
        guard target == self.target(sessionId: target.session_id, process: target.process_gen) else { return nil }
        return chat.reply(target, pageID: pageID)
    }

    private func submitDurably(_ message: AtemSessionMessage, approvalID: String? = nil, owner: String = "native") -> String? {
        guard let target = message.binding?.target, let payload = message.payload, let kind = message.kind else { return nil }
        do {
            try message.validate()
            let record = AtemSessionRequestRecord(requestId: message.request_id!, target: target, kind: kind,
                digest: try payload.digest(), approvalID: approvalID)
            if let previous = journal.snapshot.requests.first(where: { $0.requestId == record.requestId }) {
                guard previous.target == record.target, previous.kind == record.kind,
                      previous.digest == record.digest, previous.approvalID == record.approvalID else { return nil }
                // Only an explicit retry of a definitive ownership refusal may
                // send again. Uncertain delivery always recovers the receipt.
                guard previous.receipt == nil, previous.refusal?.code == "lease_held",
                      message.takeover == true, message.expected_controller == previous.refusal?.controller else { return previous.requestId }
                try journal.update { state in
                    if let index = state.requests.firstIndex(where: { $0.requestId == record.requestId }) {
                        state.requests[index].refusal = nil
                    }
                }
            } else {
                try journal.update { state in
                    if state.requests.count >= 4096, let oldestFinal = state.requests.firstIndex(where: { $0.receipt?.state.final == true }) {
                        state.requests.remove(at: oldestFinal)
                    }
                    state.requests.append(record)
                }
            }
            // Persist the identity before sending. Reconnect uses receipt_query;
            // prompt text is never stored or automatically submitted again.
        } catch { status = "Could not save this request safely. Nothing was sent."; changed(); return nil }
        let delivered = request(message, deadline: leases[target.session_id]?.deadline, owner: owner)
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
        approvalRules = [:]
        chat.reset()
        resyncing = true
        if !pending.values.contains(where: { $0.message.op == "list" }) { _ = request(AtemSessionMessage(op: "list")) }
    }

    func receive(_ message: AtemSessionMessage, from source: RemoteTerminalConnection) {
        guard context?.route == source, context == currentContext(), phase != .failed, phase != .reconnecting else { return }
        do {
            try message.validate()
            if message.op == "welcome" {
                guard phase == .connecting, let re = message.re, pending[re]?.message.op == "hello" else { return }
                guard message.revision == AtemSessionWire.revision, message.features != nil else {
                    failUnsupportedVersion(); return
                }
                try acceptWelcome(message); changed(); return
            }
            if message.op == "error", message.re == nil {
                if message.code == "unsupported_version" { failUnsupportedVersion(); return }
                if message.code == "unauthorized", welcome != nil { reconnect(); return }
                if message.code == "unauthorized", phase == .connecting,
                   pending.values.contains(where: { $0.message.op == "hello" }) {
                    helloRefusedBeforeVerification = true
                }
                status = "Atem: " + AtemSessionWire.diagnosticErrorCode(message.code)
                if phase == .connecting || ["unauthorized", "paused", "unsupported_version"].contains(message.code ?? "") {
                    fail(status + ". Reconnect the session with matching Astation and Atem builds.")
                }
                retryInitialHelloAfterVerification()
                changed(); return
            }
            if phase == .connecting, message.op == "error", let re = message.re, pending[re]?.message.op == "hello" {
                if message.code == "unsupported_version" { failUnsupportedVersion(); return }
                helloRefusedBeforeVerification = message.code == "unauthorized"
                fail("Atem could not open a session: " + AtemSessionWire.diagnosticErrorCode(message.code)
                    + ". Reconnect to open a fresh session connection.")
                retryInitialHelloAfterVerification()
                changed(); return
            }
            guard phase == .ready, now() < authorizationDeadline else { return }
            switch message.op {
            case "sessions", "session_changed": try acceptRegistry(message)
            case "approval_rules":
                guard canReviewApprovals, features.contains("approval.session_rules"), let id = message.session_id, let process = message.process_gen,
                      target(sessionId: id, process: process) != nil, registry[id]?.state == "running", let rules = message.rules else { return }
                approvalRules[id] = rules
                // A fresh host list may grant the same command again after a
                // completed revoke. Do not let the old receipt disable it forever.
                if let target = target(sessionId: id, process: process) {
                    for rule in rules {
                        if let record = revokeRecord(rule, target: target), record.receipt?.state == .completed {
                            regrantedAfterRevoke.insert(record.requestId)
                        }
                    }
                }
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
                    if let lease = message.lease, message.state == .accepted, operation.message.kind == "prompt" {
                        acceptSendLease(lease, operation: operation)
                    }
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
                if operation.message.op == "submit", let requestID = operation.message.request_id,
                   let index = journal.snapshot.requests.firstIndex(where: { $0.requestId == requestID }) {
                    let refusal = AtemSessionRefusal(code: message.code ?? "invalid_request", controller: message.controller)
                    if refusal.valid { try journal.update { $0.requests[index].refusal = refusal } }
                }
                if let target = operation.message.binding?.target,
                   ["acquire", "renew", "release"].contains(operation.message.op) { leases.removeValue(forKey: target.session_id) }
                status = "Atem: " + AtemSessionWire.diagnosticErrorCode(message.code)
                if !["approval", "approval_rule_revoke"].contains(operation.message.kind ?? "")
                    || ["unauthorized", "forbidden", "paused", "unsupported_version"].contains(message.code ?? "") {
                    handleRefusal(code: message.code ?? "request failed", target: operation.message.binding?.target)
                }
                if message.code == "busy", operation.message.op == "submit" {
                    status = "Atem refused this request as busy. It will not be resent automatically."
                } else if message.code == "lease_held" {
                    status = "Another controller holds this session. Confirm Take over and send to continue."
                }
                if message.code == "stale_target", operation.message.kind == "approval",
                   let id = operation.message.payload?["approval_id"]?.string {
                    approvals.removeValue(forKey: id)
                }
            default: break
            }
        } catch let failure as WelcomeFailure {
            // Only fixed check names and bounded counters belong in diagnostics.
            Log.warn("[Sessions] Rejected \(failure.diagnostic)")
            fail(failure.message)
        } catch {
            Log.warn("[Sessions] Rejected session message: validation_or_consistency")
            fail("Atem sent an invalid or inconsistent session message. Reconnect to continue.")
        }
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
        chat.tick()
        if time >= authorizationDeadline { fail("Session authorization expired. Reconnect the verified Atem."); changed(); return }
        for (session, lease) in leases {
            if time >= lease.deadline {
                leases.removeValue(forKey: session)
                status = "Control expired. Take Control explicitly to type again."
                changed()
            } else if lease.owner == "native", time >= lease.renewAt, !pending.values.contains(where: { $0.message.op == "renew" && $0.message.binding?.target == lease.target }) {
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
              let context,
              let trust = message.host_trust_gen, message.revision == AtemSessionWire.revision,
              let remaining = message.authorization_ms_left else { throw AtemSessionJSON.Invalid.json }
        guard message.account_id == context.account else { throw WelcomeFailure.invalid(.account) }
        guard message.atem_device_id == context.device else { throw WelcomeFailure.invalid(.device) }
        guard message.client_kind == "native" else { throw WelcomeFailure.invalid(.clientKind) }
        guard message.permissions?.contains("view") == true else { throw WelcomeFailure.invalid(.permissions) }
        guard remaining > 0, remaining <= 86_400_000 else { throw WelcomeFailure.invalid(.authorization) }
        guard message.host_error == nil else { throw WelcomeFailure.invalid(.hostError) }
        do {
            try journal.update { state in
                if let index = state.hosts.firstIndex(where: { $0.account == context.account && $0.device == context.device }) {
                    let previous = state.hosts[index]
                    guard trust >= previous.trust else { throw WelcomeFailure.trustRollback(received: trust, minimum: previous.trust) }
                    if trust > previous.trust { state.hosts[index] = AtemSessionHostFence(account: context.account, device: context.device, trust: trust) }
                } else { state.hosts.append(AtemSessionHostFence(account: context.account, device: context.device, trust: trust)) }
            }
        } catch let failure as WelcomeFailure {
            throw failure
        } catch {
            throw WelcomeFailure.storage
        }
        if let fence = journal.snapshot.hosts.first(where: { $0.account == context.account && $0.device == context.device }) {
            runtimeEpoch = fence.runtimeEpoch
            runtimeGeneration = fence.runtimeGeneration
        }
        authorizationDeadline = min(hello.sent + Double(remaining) / 1000, now() + Double(remaining) / 1000)
        guard now() < authorizationDeadline else { throw WelcomeFailure.invalid(.authorization) }
        welcome = message
        features = Set(message.features ?? []).intersection(AtemSessionWire.features)
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
            approvalRules = [:]
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
        for (id, lease) in leases where target(sessionId: id, process: lease.target.process_gen) != lease.target
            || registry[id]?.state != "running" || registry[id]?.controller?.controller_session != welcome?.controller_session
            || registry[id]?.controller?.lease_epoch != lease.epoch {
            leases.removeValue(forKey: id)
            revokedLeaseEpoch[id] = max(revokedLeaseEpoch[id] ?? 0, lease.epoch)
        }
        for (id, descriptor) in previousRegistry where registry[id]?.process_gen != descriptor.process_gen {
            highestLeaseEpoch.removeValue(forKey: id)
            revokedLeaseEpoch.removeValue(forKey: id)
            pending = pending.filter { $0.value.message.binding?.target.session_id != id || !["acquire", "renew"].contains($0.value.message.op) }
        }
        approvals = approvals.filter { _, approval in
            registry[approval.session_id]?.process_gen == approval.process_gen && registry[approval.session_id]?.state == "running"
        }
        approvalRules = approvalRules.filter { id, _ in
            registry[id]?.state == "running" && previousRegistry[id]?.process_gen == registry[id]?.process_gen
        }
        chat.sync(features.contains("chat.history_end") ? registry.values.compactMap { descriptor in
            guard descriptor.state == "running", descriptor.capabilities.contains("chat-v1"),
                  let target = target(sessionId: descriptor.session_id, process: descriptor.process_gen) else { return nil }
            return binding(for: target, mutation: false)
        } : [])
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
        leases[binding.target.session_id] = Lease(target: binding.target, epoch: epoch, deadline: deadline, renewAt: operation.sent + 5, owner: operation.owner)
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
    }

    private func acceptSendLease(_ lease: AtemSessionSendLease, operation: Pending) {
        guard operation.mayAdoptControl, features.contains("chat.send_acquire"), lease.valid,
              operation.message.binding?.attachment_gen == welcome?.attachment_gen,
              let target = operation.message.binding?.target,
              target == self.target(sessionId: target.session_id, process: target.process_gen),
              lease.lease_epoch >= (highestLeaseEpoch[target.session_id] ?? 0),
              revokedLeaseEpoch[target.session_id].map({ lease.lease_epoch > $0 }) != false,
              controlOwner(for: target).map({ $0 == operation.owner }) != false,
              operation.previousDeadline.map({ now() < $0 }) != false else { return }
        var deadline = min(operation.sent + Double(lease.ms_left) / 1000, authorizationDeadline)
        if let old = leases[target.session_id], old.epoch == lease.lease_epoch { deadline = min(deadline, old.deadline) }
        guard now() < deadline else { return }
        highestLeaseEpoch[target.session_id] = lease.lease_epoch
        leases[target.session_id] = Lease(target: target, epoch: lease.lease_epoch, deadline: deadline,
            renewAt: operation.sent + 5, owner: operation.owner)
    }

    private func acceptReceipt(_ incoming: AtemSessionReceipt) throws {
        var receipt = incoming
        if !features.contains("receipt.result") { receipt.result = nil }
        guard let context, receipt.target.account_id == context.account, receipt.target.atem_device_id == context.device,
              receipt.target.host_trust_gen == welcome?.host_trust_gen,
              let index = journal.snapshot.requests.firstIndex(where: { $0.requestId == receipt.request_id }) else { return }
        let record = journal.snapshot.requests[index]
        try AtemSessionWire.check(record.target == receipt.target && record.kind == receipt.kind)
        if let previous = record.receipt {
            if receipt.updated_at < previous.updated_at { return }
            try AtemSessionWire.check(previous.state.permits(receipt.state))
            if previous.state.final {
                try AtemSessionWire.check(previous.state == receipt.state && previous.detail == receipt.detail
                    && previous.updated_at == receipt.updated_at
                    && (previous.result == nil || receipt.result == nil
                        || receipt.result.map { previous.result!.sameOutcome(as: $0) } == true))
                if receipt.result == nil { receipt.result = previous.result }
            }
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
                && $0.target.host_trust_gen == trust && $0.receipt?.state.final != true && $0.refusal?.code != "lease_held"
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
    private func request(_ original: AtemSessionMessage, deadline: TimeInterval? = nil, owner: String = "native") -> Bool {
        var message = original
        message.id = makeID()
        guard let context, context == currentContext(), pending.count < 64, (try? message.validate()) != nil else { return false }
        pending[message.id] = Pending(message: message, sent: now(), previousDeadline: deadline, owner: owner)
        return sendMessage(message, context.route)
    }
    private func fail(_ text: String) {
        chat.reset()
        approvalRules = [:]
        features = []
        phase = .failed
        approvals = [:]
        leases = [:]
        pending = [:]
        status = text
    }
    private func failUnsupportedVersion() {
        unsupportedVersion = true
        fail("This Atem version is not supported. Upgrade Atem, then reconnect.")
        changed()
    }
    private func changed() { onChange?() }
}
