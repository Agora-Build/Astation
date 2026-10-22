import Foundation

enum AtemSessionWire {
    static let revision: UInt64 = 9
    static let features: Set<String> = ["chat.history_end", "chat.history", "chat.lookup", "chat.coverage",
        "receipt.result", "approval.session_rules", "approval.card_reason", "chat.send_acquire", "approval.lease_free"]
    static let maximumCounter = UInt64(AtemSessionJSON.maximumInteger)
    static let submissionKinds = ["prompt", "interrupt", "stop", "approval", "approval_rule_revoke"]
    static func diagnosticErrorCode(_ value: String?) -> String {
        let codes: Set<String> = ["unsupported_version", "unauthorized", "forbidden", "stale_target",
            "unknown_session", "lease_held", "stale_lease", "request_id_reused", "receipt_limit",
            "session_closed", "busy", "paused", "invalid_request"]
        return value.flatMap { codes.contains($0) ? $0 : nil } ?? "unknown_error"
    }
    static func uuid(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
    static func opaque(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    }
    static func session(_ value: String) -> Bool {
        value.range(of: #"^ses-[a-z2-7]{12}$"#, options: .regularExpression) != nil
    }
    static func check(_ condition: Bool) throws { if !condition { throw AtemSessionJSON.Invalid.json } }
}

struct AtemSessionTarget: Codable, Equatable, Hashable {
    let account_id: String
    let atem_device_id: String
    let host_trust_gen: UInt64
    let session_id: String
    let process_gen: String

    var valid: Bool {
        AtemSessionWire.opaque(account_id) && AtemSessionWire.opaque(atem_device_id)
            && host_trust_gen <= AtemSessionWire.maximumCounter
            && AtemSessionWire.session(session_id) && AtemSessionWire.uuid(process_gen)
    }
}

struct AtemSessionBinding: Codable, Equatable {
    let target: AtemSessionTarget
    let attachment_gen: String
    var lease_epoch: UInt64?
    var valid: Bool {
        target.valid && AtemSessionWire.uuid(attachment_gen)
            && lease_epoch.map { $0 <= AtemSessionWire.maximumCounter } != false
    }
}

struct AtemSessionController: Codable, Equatable {
    let controller_session: String
    let lease_epoch: UInt64
    var valid: Bool { AtemSessionWire.uuid(controller_session) && lease_epoch <= AtemSessionWire.maximumCounter }
}

struct AtemSessionDescriptor: Codable, Equatable {
    let session_id: String
    let process_gen: String
    let provider: String
    let cwd_label: String
    let state: String
    let activity: String
    let activity_since: UInt64
    let controller: AtemSessionController?
    let capabilities: [String]
    let created_at: UInt64

    enum CodingKeys: String, CodingKey {
        case session_id, process_gen, provider, cwd_label, state, activity, activity_since, controller, capabilities, created_at
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try AtemSessionWire.check(c.contains(.controller))
        session_id = try c.decode(String.self, forKey: .session_id)
        process_gen = try c.decode(String.self, forKey: .process_gen)
        provider = try c.decode(String.self, forKey: .provider)
        cwd_label = try c.decode(String.self, forKey: .cwd_label)
        state = try c.decode(String.self, forKey: .state)
        activity = try c.decode(String.self, forKey: .activity)
        activity_since = try c.decode(UInt64.self, forKey: .activity_since)
        controller = try c.decodeIfPresent(AtemSessionController.self, forKey: .controller)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        created_at = try c.decode(UInt64.self, forKey: .created_at)
        try AtemSessionWire.check(valid)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session_id, forKey: .session_id)
        try c.encode(process_gen, forKey: .process_gen)
        try c.encode(provider, forKey: .provider)
        try c.encode(cwd_label, forKey: .cwd_label)
        try c.encode(state, forKey: .state)
        try c.encode(activity, forKey: .activity)
        try c.encode(activity_since, forKey: .activity_since)
        try c.encode(controller, forKey: .controller)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(created_at, forKey: .created_at)
    }
    var valid: Bool {
        AtemSessionWire.session(session_id) && AtemSessionWire.uuid(process_gen)
            && !provider.isEmpty && provider.utf8.count <= 128 && cwd_label.utf8.count <= 256
            && ["running", "exited", "interrupted", "recovery_required", "closed", "removed"].contains(state)
            && ["ready", "working", "waiting", "unknown"].contains(activity)
            && activity_since <= AtemSessionWire.maximumCounter && created_at <= AtemSessionWire.maximumCounter
            && controller?.valid != false && capabilities.count <= 32
            && capabilities.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
    }
}

enum AtemReceiptState: String, Codable {
    case accepted, executing, completed, rejected, outcome_unknown
    var final: Bool { self == .completed || self == .rejected || self == .outcome_unknown }
    func permits(_ next: Self) -> Bool {
        self == next || (self == .accepted && [.executing, .rejected, .completed, .outcome_unknown].contains(next))
            || (self == .executing && next.final)
    }
}

struct AtemSessionResult: Codable, Equatable {
    let turn_id: String
    let user_message_id: String
    let outcome: String
    let reply_message_ids: [String]
    let more: Bool
    let replies: String

    var valid: Bool {
        AtemSessionWire.opaque(turn_id) && AtemSessionWire.opaque(user_message_id)
            && ["done", "interrupted"].contains(outcome) && reply_message_ids.count <= 32
            && reply_message_ids.allSatisfy(AtemSessionWire.opaque)
            && Set(reply_message_ids).count == reply_message_ids.count
            && ["complete", "partial", "unavailable"].contains(replies)
    }
    func sameOutcome(as other: Self) -> Bool {
        turn_id == other.turn_id && user_message_id == other.user_message_id && outcome == other.outcome
    }
}

struct AtemSessionSendLease: Codable, Equatable {
    let lease_epoch: UInt64
    let ms_left: UInt64
    var valid: Bool { lease_epoch <= AtemSessionWire.maximumCounter && ms_left <= 15_000 }
}

struct AtemSessionReceipt: Codable, Equatable {
    let request_id: String
    let target: AtemSessionTarget
    let kind: String
    let state: AtemReceiptState
    let detail: String?
    let updated_at: UInt64
    var result: AtemSessionResult?
    var valid: Bool {
        AtemSessionWire.uuid(request_id) && target.valid && AtemSessionWire.submissionKinds.contains(kind)
            && (detail?.utf8.count ?? 0) <= 512 && updated_at <= AtemSessionWire.maximumCounter
            && (result == nil || (result?.valid == true && kind == "prompt" && state == .completed && result?.outcome == detail))
    }
}

/// The session family is flat inside AstationMessage.data. Authentication
/// context is supplied separately by the hub, never decoded from this object.
struct AtemSessionMessage: Codable, Equatable {
    var v = 1
    var op: String
    var id: String = UUID().uuidString.lowercased()
    var re: String?
    var binding: AtemSessionBinding?
    var account_id: String?
    var atem_device_id: String?
    var host_trust_gen: UInt64?
    var runtime_gen: String?
    var controller_session: String?
    var attachment_gen: String?
    var client_kind: String?
    var permissions: [String]?
    var authorization_ms_left: UInt64?
    var server_time: UInt64?
    var runtime_epoch: UInt64?
    var seq: UInt64?
    var sessions: [AtemSessionDescriptor]?
    var descriptor: AtemSessionDescriptor?
    var takeover: Bool?
    var ms_left: UInt64?
    var session_id: String?
    var process_gen: String?
    var controller: AtemSessionController?
    var lease_epoch: UInt64?
    var reason: String?
    var request_id: String?
    var target: AtemSessionTarget?
    var kind: String?
    var payload: AtemSessionJSON?
    var state: AtemReceiptState?
    var detail: String?
    var updated_at: UInt64?
    var request_ids: [String]?
    var receipts: [AtemSessionReceipt]?
    var code: String?
    var approval_id: String?
    var tool: String?
    var summary: String?
    var created_at: UInt64?
    var always_rules: [AtemApprovalRule]?
    var rules: [AtemApprovalRule]?
    var revision: UInt64?
    var features: [String]?
    var host_error: String?
    var acquire: Bool?
    var expected_controller: AtemSessionController?
    var lease: AtemSessionSendLease?
    var result: AtemSessionResult?

    func validate() throws {
        try AtemSessionWire.check(v == 1 && AtemSessionWire.uuid(id) && re.map(AtemSessionWire.uuid) != false)
        try AtemSessionWire.check(binding?.valid != false && target?.valid != false && (detail?.utf8.count ?? 0) <= 512)
        for counter in [host_trust_gen, authorization_ms_left, server_time, runtime_epoch, seq, ms_left, lease_epoch, updated_at, revision] {
            try AtemSessionWire.check(counter.map { $0 <= AtemSessionWire.maximumCounter } != false)
        }
        switch op {
        case "list": break
        case "welcome":
            try AtemSessionWire.check(account_id.map(AtemSessionWire.opaque) == true && atem_device_id.map(AtemSessionWire.opaque) == true
                && host_trust_gen != nil && runtime_gen.map(AtemSessionWire.uuid) == true
                && controller_session.map(AtemSessionWire.uuid) == true && attachment_gen.map(AtemSessionWire.uuid) == true
                && ["native", "browser"].contains(client_kind ?? "") && permissions != nil
                && permissions!.allSatisfy { ["view", "control"].contains($0) }
                && authorization_ms_left != nil && server_time != nil
                && features.map { $0.count <= 32 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
                    && Set($0).count == $0.count } != false && (host_error?.utf8.count ?? 0) <= 512)
        case "sessions", "session_changed":
            try AtemSessionWire.check(runtime_gen.map(AtemSessionWire.uuid) == true && runtime_epoch != nil && seq != nil)
            if op == "sessions" {
                try AtemSessionWire.check(sessions != nil && sessions!.count <= 1024 && sessions!.allSatisfy(\.valid))
            } else { try AtemSessionWire.check(descriptor?.valid == true) }
        case "acquire": try AtemSessionWire.check(binding != nil && binding?.lease_epoch == nil && takeover != nil)
        case "renew", "release": try AtemSessionWire.check(binding?.lease_epoch != nil)
        case "lease": try AtemSessionWire.check(re != nil && binding?.lease_epoch != nil && ms_left != nil && ms_left! <= 15_000)
        case "lease_released": try AtemSessionWire.check(re != nil)
        case "lease_changed":
            try AtemSessionWire.check(session_id.map(AtemSessionWire.session) == true && process_gen.map(AtemSessionWire.uuid) == true
                && lease_epoch != nil && controller?.valid != false
                && (controller == nil || controller?.lease_epoch == lease_epoch)
                && ["granted", "takeover", "local_input", "expired", "released", "revoked", "process_ended"].contains(reason ?? ""))
        case "submit":
            try AtemSessionWire.check(binding != nil && request_id.map(AtemSessionWire.uuid) == true
                && AtemSessionWire.submissionKinds.contains(kind ?? "") && payload != nil)
            let canonical = try payload!.canonical()
            try AtemSessionWire.check(canonical.utf8.count <= 65_536)
            if kind == "approval" { try AtemApprovalAnswer.validate(payload!) }
            try AtemSessionWire.check(acquire == nil || (acquire == true && kind == "prompt" && binding?.lease_epoch == nil))
            try AtemSessionWire.check(takeover == nil || (takeover == true && acquire == true && expected_controller?.valid == true))
            try AtemSessionWire.check(expected_controller == nil || takeover == true)
            if ["prompt", "interrupt", "stop"].contains(kind ?? ""), acquire != true {
                try AtemSessionWire.check(binding?.lease_epoch != nil)
            }
            if kind == "prompt" {
                guard case .object(let fields) = payload!, let text = fields["text"]?.string else { throw AtemSessionJSON.Invalid.json }
                try AtemSessionWire.check(fields.count == 1 && text.utf8.count <= 32_768)
            } else if kind == "approval_rule_revoke" {
                guard case .object(let fields) = payload! else { throw AtemSessionJSON.Invalid.json }
                try AtemSessionWire.check(fields.count == 1 && fields["rule_id"]?.string.map(AtemSessionWire.opaque) == true)
            } else if kind != "approval" { try AtemSessionWire.check(payload == .object([:])) }
        case "approval_request": try AtemSessionWire.check(approval?.valid == true)
        case "approval_rules":
            try AtemSessionWire.check(session_id.map(AtemSessionWire.session) == true && process_gen.map(AtemSessionWire.uuid) == true
                && rules.map(AtemApprovalRule.validSessionList) == true)
        case "approval_closed":
            try AtemSessionWire.check(approval_id.map(AtemSessionWire.uuid) == true && AtemApprovalRequest.closeReasons.contains(reason ?? ""))
        case "receipt":
            try AtemSessionWire.check(receipt?.valid == true && (lease == nil || (lease?.valid == true
                && state == .accepted && kind == "prompt" && re != nil)))
        case "receipt_query":
            try AtemSessionWire.check(binding != nil && binding?.lease_epoch == nil && request_ids != nil
                && request_ids!.count <= 64 && request_ids!.allSatisfy(AtemSessionWire.uuid))
        case "receipts": try AtemSessionWire.check(re != nil && receipts != nil && receipts!.count <= 64 && receipts!.allSatisfy(\.valid))
        case "error": try AtemSessionWire.check(code != nil && !code!.isEmpty && code!.utf8.count <= 128)
        default: throw AtemSessionJSON.Invalid.json
        }
    }

    var receipt: AtemSessionReceipt? {
        guard let request_id, let target, let kind, let state, let updated_at else { return nil }
        return AtemSessionReceipt(request_id: request_id, target: target, kind: kind, state: state, detail: detail, updated_at: updated_at, result: result)
    }

    var approval: AtemApprovalRequest? {
        guard let approval_id, let session_id, let process_gen, let tool, let summary, let created_at, let always_rules else { return nil }
        return AtemApprovalRequest(approval_id: approval_id, session_id: session_id, process_gen: process_gen,
            tool: tool, summary: summary, created_at: created_at, always_rules: always_rules)
    }
}
