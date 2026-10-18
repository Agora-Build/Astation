import Foundation

struct AtemApprovalActivity: Equatable {
    let target: AtemSessionTarget
    let messageID: String
    let createdAt: Date
    let part: AgentChatPart
}

/// Read-only, attachment-bound chat views. Cards are information, never approval
/// authority. One view per process is shared by the native inbox and local API.
final class AtemApprovalActivityObserver {
    private struct Subscription {
        let binding: AtemSessionBinding
        let conversationID: String
        var sequence: UInt64?
        var closed = false
    }
    private var subscriptions: [String: Subscription] = [:]
    private(set) var activities: [AtemApprovalActivity] = []
    private let send: (AgentChatWire) -> Bool

    init(send: @escaping (AgentChatWire) -> Bool) { self.send = send }

    func reset(sendClose: Bool = true) {
        for subscription in subscriptions.values where sendClose {
            _ = send(AgentChatWire(op: "close", conversationId: subscription.conversationID,
                agentId: subscription.binding.target.session_id, binding: subscription.binding))
        }
        subscriptions = [:]
        activities = []
    }

    func sync(_ bindings: [AtemSessionBinding]) {
        // Bound background subscriptions even if a host advertises a huge registry.
        let bindings = Array(bindings.sorted { $0.target.session_id < $1.target.session_id }.prefix(64))
        let current = Set(bindings.map(\.target))
        for (id, subscription) in subscriptions where !bindings.contains(subscription.binding) {
            _ = send(AgentChatWire(op: "close", conversationId: subscription.conversationID,
                agentId: id, binding: subscription.binding))
            subscriptions.removeValue(forKey: id)
        }
        activities.removeAll { !current.contains($0.target) }
        for binding in bindings where subscriptions[binding.target.session_id] == nil {
            let id = UUID().uuidString.lowercased()
            subscriptions[binding.target.session_id] = Subscription(binding: binding, conversationID: id)
            if !send(AgentChatWire(op: "open", conversationId: id, agentId: binding.target.session_id, binding: binding)) {
                subscriptions[binding.target.session_id]?.closed = true
            }
        }
    }

    func receive(_ event: AgentChatWire) -> Bool {
        guard event.v == 1, var subscription = subscriptions[event.agentId], !subscription.closed,
              event.conversationId == subscription.conversationID,
              let bytes = try? JSONEncoder().encode(event), bytes.count <= 1_048_576 else { return false }
        let previousActivities = activities
        func close() {
            subscription.closed = true
            subscriptions[event.agentId] = subscription
        }
        if ["error", "close"].contains(event.op), event.generation == nil, event.sequence == nil { close(); return false }
        guard event.generation == subscription.binding.target.process_gen,
              let sequence = event.sequence, sequence <= AtemSessionWire.maximumCounter else { return false }
        if event.op == "opened" {
            guard subscription.sequence == nil, sequence == 0, event.status?.isValid == true else { return false }
        } else {
            guard let previous = subscription.sequence, sequence > previous else { return false }
            // Leave recovery to an explicit refresh; never loop on truncated history.
            guard sequence == previous + 1 else { close(); return false }
        }
        if event.op == "message" {
            guard let messageID = event.messageId, !messageID.isEmpty, messageID.utf8.count <= 128,
                  ["user", "assistant"].contains(event.role ?? ""), let date = event.createdAt?.date,
                  let parts = event.parts, parts.count <= 128, parts.allSatisfy(\.isValid),
                  parts.reduce(0, { $0 + $1.contentBytes }) <= 131_072,
                  Set(parts.map(\.id)).count == parts.count else { close(); return false }
            activities.removeAll { $0.target == subscription.binding.target && $0.messageID == messageID }
            if event.role == "assistant", let part = parts.first(where: { $0.kind == "approval" && $0.state == "auto_allowed" }) {
                activities.append(AtemApprovalActivity(target: subscription.binding.target, messageID: messageID,
                    createdAt: date, part: part))
                activities.sort { $0.createdAt > $1.createdAt }
                activities = Array(activities.prefix(64))
            }
        }
        subscription.sequence = sequence
        if event.op == "close" { subscription.closed = true }
        subscriptions[event.agentId] = subscription
        return activities != previousActivities
    }
}
