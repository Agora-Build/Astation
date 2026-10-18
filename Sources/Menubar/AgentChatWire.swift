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

    var contentBytes: Int {
        if id == "atem:truncated", kind == "text", markdown == "\u{2026} (truncated)" { return 0 }
        return (markdown?.utf8.count ?? 0) + (name?.utf8.count ?? 0) + (summary?.utf8.count ?? 0)
            + (tool?.utf8.count ?? 0) + (note?.utf8.count ?? 0)
            + (always_rules ?? []).reduce(0) { $0 + $1.rule_id.utf8.count + $1.label.utf8.count + $1.scope.utf8.count }
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
        default: return false
        }
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
}
