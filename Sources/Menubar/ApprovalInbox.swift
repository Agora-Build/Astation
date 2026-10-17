import AppKit
import SwiftUI

struct ApprovalInboxEntry: Identifiable {
    let id: String
    let sourceID: String
    let target: AtemSessionTarget
    let request: AtemApprovalRequest
    let host: String
    let provider: String
    let client: AtemSessionClient
    var available: Bool
    var resolution: String?

    var canAnswer: Bool { available && resolution == nil && client.canAnswer(request) }
    var status: String {
        if let receipt = client.journal.snapshot.requests.last(where: {
            $0.target == target && $0.approvalID == request.approval_id
        })?.receipt {
            switch receipt.state {
            case .accepted: return "Accepted by Atem; waiting for the agent."
            case .executing: return "Applying your decision."
            case .completed: return "Decision applied by the agent."
            case .rejected: return "The decision could not be applied. Check the agent before retrying."
            case .outcome_unknown: return "Outcome unknown. Check the agent before answering again."
            }
        }
        if let resolution {
            switch resolution {
            case "answered_remote": return "Answered remotely."
            case "answered_terminal": return "Already answered in the terminal."
            case "timed_out": return "This request expired."
            case "process_ended": return "The agent session ended."
            default: return "This request is closed."
            }
        }
        guard available else { return "Reconnect to check this request. Its status is unconfirmed." }
        return canAnswer ? "Waiting for your decision." : "Checking the decision receipt; it will not be sent again."
    }
}

/// Only the authenticated session registry populates this inbox. Push hints
/// can open it, but cannot create actionable cards or resolve a host request.
final class ApprovalInbox: ObservableObject {
    @Published private(set) var entries: [ApprovalInboxEntry] = []
    @Published var notificationHint: ApprovalPushHint?
    var onNew: ((ApprovalInboxEntry) -> Void)?
    private var seen: [String] = []

    var pendingCount: Int { entries.filter { $0.available && $0.resolution == nil }.count }

    func sync(sourceID: String, client: AtemSessionClient, host: String) {
        var next = entries
        for index in next.indices where next[index].sourceID == sourceID {
            next[index].available = false
            if let context = client.context, context.account == next[index].target.account_id,
               context.device == next[index].target.atem_device_id,
               client.welcome?.host_trust_gen == next[index].target.host_trust_gen {
                next[index].resolution = client.closedApprovals[next[index].request.approval_id] ?? next[index].resolution
            }
        }
        var newEntries: [ApprovalInboxEntry] = []
        if client.canReviewApprovals {
            for request in client.approvals.values.sorted(by: { $0.created_at < $1.created_at }) {
                guard let target = client.target(sessionId: request.session_id, process: request.process_gen) else { continue }
                let id = [target.account_id, target.atem_device_id, String(target.host_trust_gen), target.session_id,
                          target.process_gen, request.approval_id].joined(separator: "\u{0}")
                let entry = ApprovalInboxEntry(id: id, sourceID: sourceID, target: target, request: request,
                    host: host, provider: client.registry[request.session_id]?.provider ?? "Agent", client: client, available: true)
                if let index = next.firstIndex(where: { $0.id == id }) { next[index] = entry }
                else { next.insert(entry, at: 0) }
                if !seen.contains(id) { seen.append(id); newEntries.append(entry) }
            }
        }
        // Never evict a live pending request to make room for history.
        entries = Array(next.filter { $0.available && $0.resolution == nil }.prefix(128))
            + Array(next.filter { !$0.available || $0.resolution != nil }.prefix(64))
        if seen.count > 1024 { seen.removeFirst(seen.count - 1024) }
        for entry in newEntries { onNew?(entry) }
    }

    @discardableResult
    func answer(_ entry: ApprovalInboxEntry, decision: AtemApprovalAnswer.Decision,
                rule: AtemApprovalRule? = nil, message: String? = nil) -> String? {
        guard let current = entries.first(where: { $0.id == entry.id }), current.canAnswer,
              current.request == entry.request else { return nil }
        return current.client.answerApproval(current.request, decision: decision, ruleID: rule?.rule_id, message: message)
    }
}

struct ApprovalNotificationsView: View {
    @ObservedObject var notifications: ApprovalNotifications
    @ObservedObject var inbox: ApprovalInbox

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval Notifications").font(.title2.weight(.semibold))
                    Text("Review requests from your verified Atem hosts.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("In-app alerts", isOn: Binding(get: { notifications.inAppEnabled }, set: { notifications.setInAppEnabled($0) }))
                    Text("Show an alert while Astation is running. No push provisioning is required.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Offline APNs push", isOn: Binding(get: { notifications.pushEnabled }, set: { notifications.setPushEnabled($0) }))
                        .disabled(!notifications.supportsPush)
                    Text(notifications.pushStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            HStack {
                Text("Requests").font(.headline)
                Spacer()
                Text("\(inbox.pendingCount) pending").foregroundStyle(.secondary)
            }
            if let hint = inbox.notificationHint,
               !inbox.entries.contains(where: { $0.target.atem_device_id == hint.atemDeviceID && $0.request.approval_id == hint.approvalID }) {
                Label("Reconnecting to check the notification. Its status has not been confirmed.", systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if inbox.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.bubble").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("No approval requests received").font(.headline)
                            Text("Connect a verified Atem with approval hooks enabled. Requests appear here even when no device holds control.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.padding(32).frame(maxWidth: .infinity)
                    }
                    ForEach(inbox.entries) { entry in ApprovalRequestCard(entry: entry, inbox: inbox) }
                }
            }
            Text("Answering takes control of that session. Notifications never approve a command automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 560, minHeight: 520)
    }
}

private struct ApprovalRequestCard: View {
    let entry: ApprovalInboxEntry
    @ObservedObject var inbox: ApprovalInbox
    @State private var denial = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(entry.provider.capitalized) on \(entry.host)").font(.headline)
                Spacer()
                Text(entry.request.tool).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(entry.request.summary.isEmpty ? "Permission requested" : entry.request.summary).textSelection(.enabled)
            Text(entry.status).font(.caption).foregroundStyle(.secondary)
            if entry.canAnswer {
                TextField("Optional reason for denying", text: $denial)
                HStack {
                    Button("Deny", role: .destructive) {
                        _ = inbox.answer(entry, decision: .deny, message: denial.isEmpty ? nil : denial)
                    }.disabled(!AtemApprovalRequest.text(denial, minimum: 0, maximum: 512, newlines: true))
                    Spacer()
                    if entry.provider == "claude", !entry.request.always_rules.isEmpty {
                        Menu("Always allow") {
                            ForEach(entry.request.always_rules, id: \.rule_id) { rule in
                                Button("\(rule.label) - \(rule.scope)") { confirm(rule) }
                            }
                        }.fixedSize()
                    }
                    Button("Allow once") { _ = inbox.answer(entry, decision: .allowOnce) }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func confirm(_ rule: AtemApprovalRule) {
        let alert = NSAlert()
        alert.messageText = "Always allow this Claude rule?"
        alert.informativeText = "\(rule.label)\nScope: \(rule.scope)\nHost: \(entry.host)\n\nThis answers the current request and saves the exact rule offered by Claude."
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { _ = inbox.answer(entry, decision: .allowAlways, rule: rule) }
    }
}
