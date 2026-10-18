import Foundation

struct AtemApprovalRule: Codable, Equatable {
    let rule_id: String
    let label: String
    let scope: String

    var valid: Bool {
        AtemSessionWire.opaque(rule_id) && AtemApprovalRequest.text(label, minimum: 1, maximum: 256)
            && AtemApprovalRequest.text(scope, minimum: 1, maximum: 256)
    }

    static func validSessionList(_ rules: [Self]) -> Bool {
        rules.count <= 32 && rules.allSatisfy { $0.valid && $0.scope == "session" }
            && Set(rules.map(\.rule_id)).count == rules.count
    }
}

struct AtemApprovalRequest: Codable, Equatable {
    let approval_id: String
    let session_id: String
    let process_gen: String
    let tool: String
    let summary: String
    let created_at: UInt64
    let always_rules: [AtemApprovalRule]

    var valid: Bool {
        AtemSessionWire.uuid(approval_id) && AtemSessionWire.session(session_id) && AtemSessionWire.uuid(process_gen)
            && Self.text(tool, minimum: 1, maximum: 128) && Self.text(summary, minimum: 0, maximum: 512)
            && created_at <= AtemSessionWire.maximumCounter && always_rules.count <= 8
            && always_rules.allSatisfy(\.valid) && Set(always_rules.map(\.rule_id)).count == always_rules.count
    }

    static func text(_ value: String, minimum: Int, maximum: Int, newlines: Bool = false) -> Bool {
        (minimum...maximum).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            (newlines && $0.value == 10) || ($0.value >= 32 && !(127...159).contains($0.value))
        }
    }

    static let closeReasons = ["answered_remote", "answered_terminal", "interrupted", "timed_out", "released", "process_ended"]
}

struct AtemApprovalAnswer {
    enum Decision: String { case allowOnce = "allow_once", allowAlways = "allow_always", deny }
    let approvalID: String
    let decision: Decision
    var ruleID: String?
    var message: String?
    var acquire = true

    var payload: AtemSessionJSON {
        var fields: AtemSessionJSON.Object = ["approval_id": .string(approvalID), "decision": .string(decision.rawValue), "acquire": .bool(acquire)]
        if let ruleID { fields["rule_id"] = .string(ruleID) }
        if let message { fields["message"] = .string(message) }
        return .object(fields)
    }

    static func validate(_ payload: AtemSessionJSON) throws -> Bool {
        guard case .object(let fields) = payload,
              Set(fields.keys).isSubset(of: ["approval_id", "decision", "rule_id", "message", "acquire"]),
              let id = fields["approval_id"]?.string, AtemSessionWire.uuid(id),
              let raw = fields["decision"]?.string, let decision = Decision(rawValue: raw) else { throw AtemSessionJSON.Invalid.json }
        if decision == .allowAlways {
            try AtemSessionWire.check(fields["rule_id"]?.string.map(AtemSessionWire.opaque) == true)
        } else { try AtemSessionWire.check(fields["rule_id"] == nil) }
        if let message = fields["message"] {
            try AtemSessionWire.check(decision == .deny && message.string.map {
                AtemApprovalRequest.text($0, minimum: 0, maximum: 512, newlines: true)
            } == true)
        }
        if let acquire = fields["acquire"] {
            guard case .bool(let value) = acquire else { throw AtemSessionJSON.Invalid.json }
            return value
        }
        return false
    }
}
