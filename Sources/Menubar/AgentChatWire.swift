import Foundation

enum AgentChatTimestamp: Codable, Equatable {
    case milliseconds(Double)
    case iso8601(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .milliseconds(number) }
        else { self = .iso8601(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .milliseconds(let number): try value.encode(number)
        case .iso8601(let text): try value.encode(text)
        }
    }

    var date: Date? {
        switch self {
        case .milliseconds(let number):
            guard number.isFinite, number >= 0, number <= 8_640_000_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: number / 1000)
        case .iso8601(let text):
            guard text.utf8.count <= 64 else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
    }
}

struct AgentChatPart: Codable, Equatable {
    var id: String
    var kind: String
    var markdown: String?
    var name: String?
    var summary: String?
    var approval_id: String?
    var tool: String?
    var always_rules: [AtemApprovalRule]?
    var state: String?
    var rule_id: String?
    var note: String?
    var reason: String?

    var contentBytes: Int {
        if id == "atem:truncated", kind == "text", markdown == "\u{2026} (truncated)" { return 0 }
        let textBytes = [markdown, name, summary, tool, note].reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let ruleBytes = (always_rules ?? []).reduce(0) { total, rule in
            total + rule.rule_id.utf8.count + rule.label.utf8.count + rule.scope.utf8.count
        }
        return textBytes + ruleBytes
    }

    var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 128 else { return false }
        switch kind {
        case "text": return markdown != nil && name == nil && summary == nil
        case "tool": return markdown == nil && name != nil && summary != nil
        case "approval":
            return markdown == nil && name == nil && approval_id.map(AtemSessionWire.uuid) == true
                && tool.map { AtemApprovalRequest.text($0, minimum: 1, maximum: 128) } == true
                && summary.map { AtemApprovalRequest.text($0, minimum: 0, maximum: 512) } == true
                && always_rules.map { $0.count <= 8 && $0.allSatisfy(\.valid)
                    && Set($0.map(\.rule_id)).count == $0.count } == true
                && ["pending", "allowed", "always_allowed", "denied", "answered_terminal", "expired", "closed", "auto_allowed"].contains(state ?? "")
                && rule_id.map(AtemSessionWire.opaque) != false
                && (state != "auto_allowed" || (rule_id != nil && always_rules?.isEmpty == true))
                && note.map { AtemApprovalRequest.text($0, minimum: 0, maximum: 512, newlines: true) } != false
                && reason.map { AtemApprovalRequest.closeReasons.contains($0) } != false
                && (state != "pending" || reason == nil)
        default: return false
        }
    }

    var historyBytes: Int {
        let strings = [markdown, name, summary, tool, note, approval_id, rule_id]
        let text = strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let rules = (always_rules ?? []).reduce(0) { $0 + $1.rule_id.utf8.count + $1.label.utf8.count + $1.scope.utf8.count }
        return id.utf8.count + (kind == "approval" ? 1024 : 64) + text + rules
    }
}

struct AgentChatStatus: Codable, Equatable {
    var state: String
    var since: AgentChatTimestamp
    var detail: String?

    var isValid: Bool {
        ["ready", "working", "waiting", "unknown"].contains(state)
            && since.date != nil && (detail?.utf8.count ?? 0) <= 4096
    }
}

struct AgentChatWire: Codable, Equatable {
    var v = 1
    var op: String
    var conversationId: String
    var agentId: String
    var generation: String?
    var sequence: UInt64?
    var requestId: String?
    var messageId: String?
    var text: String?
    var state: String?
    var since: AgentChatTimestamp?
    var detail: String?
    var status: AgentChatStatus?
    var role: String?
    var origin: String?
    var turnId: String?
    var createdAt: AgentChatTimestamp?
    var parts: [AgentChatPart]?
    var part: AgentChatPart?
    var history: Bool?
    var before: String?
    var outcome: String?
    var code: String?
    var binding: AtemSessionBinding?
    var approvalRules: [AtemApprovalRule]?
    var page_id: String?
    var next: String?
    var turn_id: String?
    var request_id: String?
    var page: AtemChatPage?
    var oldest_retained: String?
    var truncated: Bool?
    var holes: [AtemChatHole]?
    var holes_more: Bool?
    var after_message_id: String?
    var reason: String?
    var unavailable: [String]?
    var recovered = false
    var wireBytes = 0

    enum CodingKeys: String, CodingKey {
        case v, op, conversationId, agentId, generation, sequence, requestId, messageId, text, state, since, detail
        case status, role, origin, turnId, createdAt, parts, part, history, before, outcome, code, binding, approvalRules
        case page_id, next, turn_id, request_id, page, oldest_retained, truncated, holes, holes_more, after_message_id, reason, unavailable
    }
}

struct AtemChatHole: Codable, Equatable {
    let after_message_id: String?
    let before_message_id: String?
    let count: UInt64?
    var valid: Bool {
        after_message_id.map(AtemSessionWire.opaque) != false && before_message_id.map(AtemSessionWire.opaque) != false
            && count.map { $0 <= AtemSessionWire.maximumCounter } != false
    }
}

struct AtemChatPage: Codable, Equatable {
    let selector: String
    let count: Int
    let content_bytes: Int
    let wire_bytes: Int
    let end: Bool
    let next: String?
    let coverage: String
    let oldest_retained: String?
    let truncated: Bool
    let holes: [AtemChatHole]
    var holes_more: Bool?

    var valid: Bool {
        ["newest", "before", "turn_id", "request_id"].contains(selector) && (0...50).contains(count)
            && (0...262_144).contains(content_bytes) && (0...1_048_576).contains(wire_bytes)
            && end == (next == nil) && next.map(Self.validToken) != false
            && ["complete", "partial", "unavailable"].contains(coverage)
            && oldest_retained.map(AtemSessionWire.opaque) != false && holes.count <= 16 && holes.allSatisfy(\.valid)
    }
    static func validToken(_ value: String) -> Bool {
        (1...512).contains(value.utf8.count)
            && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}
