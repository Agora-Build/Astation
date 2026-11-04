import AstationRemote
import SwiftUI

struct AgentActivityView: View {
    @ObservedObject var hub: AstationHubManager
    let clientID: String
    let target: AtemSessionTarget
    let hostName: String
    let onClose: () -> Void
    @State private var work: RemoteHostWork?
    @State private var historyPageID: String?
    @State private var historyBefore: String?
    @State private var historyNext: String?

    private var client: AtemSessionClient? {
        guard let client = hub.sessionClient(for: clientID, atemId: target.atem_device_id),
              client.target(sessionId: target.session_id, process: target.process_gen) == target else { return nil }
        return client
    }

    var body: some View {
        let _ = hub.hostWorkRevision
        let client = self.client
        let snapshot = client?.activitySnapshot(target)
        let history = historyPageID.flatMap { client?.chatPage(target, pageID: $0) }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity").font(.title2.weight(.semibold))
                    Text("\(hostName) - \(target.session_id)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let client {
                        if let snapshot {
                            if let status = snapshot.status {
                                Label {
                                    Text(status.detail ?? status.state.capitalized)
                                        .foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(status.state == "ready" ? Color.green : Color.secondary)
                                }
                                .font(.callout)
                            }
                            historyNotice(snapshot)
                            if !snapshot.loaded && !snapshot.closed {
                                ProgressView("Loading activity...")
                            }
                            if snapshot.loaded, client.features.contains("chat.history"),
                               let first = snapshot.messages.first?.messageId, !snapshot.locally_truncated,
                               snapshot.messages.count < 500,
                               history?.page?.end != true,
                               !(historyPageID == nil && snapshot.page?.selector == "newest" && snapshot.page?.end == true) {
                                Button(history?.error == nil ? "Load Earlier Activity" : "Retry Earlier Activity") {
                                    if history?.error == nil {
                                        historyNext = history?.page?.next
                                        historyBefore = historyNext == nil ? first : nil
                                    }
                                    historyPageID = client.chatHistory(target, before: historyBefore, next: historyNext)
                                }.disabled(history?.pending == true || snapshot.closed)
                            }
                            if history?.pending == true { ProgressView().controlSize(.small) }
                            if let error = history?.error {
                                Text("Earlier activity is unavailable: \(error.replacingOccurrences(of: "_", with: " ")).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.messages, id: \.messageId) { message in
                                AgentActivityMessageView(message: message).equatable()
                            }
                            if snapshot.loaded && snapshot.messages.isEmpty {
                                Text("No agent activity has been recorded yet.").foregroundStyle(.secondary)
                            }
                            if let error = snapshot.error {
                                Text("Activity: \(error.replacingOccurrences(of: "_", with: " ")).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Chat activity is unavailable for this agent. Available request outcomes are shown below.")
                                .foregroundStyle(.secondary)
                        }
                        if let work {
                            ForEach(work.currentLaunches.filter {
                                $0.status?.session_id == target.session_id && $0.status?.process_gen == target.process_gen
                            }) { launch in
                                Divider()
                                Label("Launched with \(launch.profile.label)", systemImage: "play.circle")
                                Text(launch.requestID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        let requests = client.activityRequests(target)
                        if !requests.isEmpty {
                            Divider()
                            Text("Requests from this Astation").font(.headline)
                            ForEach(requests, id: \.requestId) { request in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(request.kind.capitalized).fontWeight(.medium)
                                        Spacer()
                                        Text(request.receipt?.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
                                            ?? (request.refusal == nil ? "Awaiting confirmation" : "Refused"))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let detail = request.receipt?.detail ?? request.refusal?.code {
                                        Text(detail.replacingOccurrences(of: "_", with: " ")).font(.caption)
                                    }
                                    Text(request.requestId).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        Divider()
                        if let work {
                            AgentReceiptLookupView(work: work, revision: hub.hostWorkRevision,
                                reconnect: { client.reconnectForHostWorkRecovery() })
                        } else {
                            Text("Receipt lookup is unavailable on this connection.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This agent's connection is no longer available. Reconnect or select its current session in Remote Terminal.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
        .task(id: client?.welcome?.attachment_gen) {
            guard let client else { work = nil; return }
            work = hub.hostWorkClient(for: clientID)
            _ = client.readChat(target)
        }
        .onChange(of: snapshot?.chat_id) { _, _ in
            historyPageID = nil; historyBefore = nil; historyNext = nil
        }
    }

    @ViewBuilder
    private func historyNotice(_ snapshot: AtemSessionChat.Snapshot) -> some View {
        if snapshot.truncated {
            Text("Atem no longer retains some earlier activity.").font(.caption).foregroundStyle(.secondary)
        }
        if !snapshot.holes.isEmpty || snapshot.holes_more {
            Text("Atem reports gaps in this history. The available activity is shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if snapshot.locally_truncated {
            Text("This view has reached its history limit. The most recent retained activity is shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !snapshot.unavailable.isEmpty {
            Text("Not captured by this agent: " + snapshot.unavailable.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgentActivityMessageView: View, Equatable {
    let message: AgentChatWire

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == "user" ? "User" : "Agent").font(.subheadline.weight(.semibold))
                Spacer()
                if let date = message.createdAt?.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(message.parts ?? [], id: \.id) { part in
                if part.kind == "text", let markdown = part.markdown {
                    Text((try? AttributedString(markdown: markdown,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(part.name ?? part.tool ?? "Approval", systemImage: part.kind == "approval" ? "checkmark.shield" : "wrench.and.screwdriver")
                            .font(.callout.weight(.medium))
                        if let summary = part.summary { Text(summary).font(.callout.monospaced()) }
                        if let state = part.state {
                            Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = part.note { Text(note).font(.caption) }
                        if let reason = part.reason {
                            Text(reason.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
    }
}

private struct AgentReceiptLookupView: View {
    let work: RemoteHostWork
    let revision: UInt64
    let reconnect: () -> Void
    @State private var receiptID = ""
    @State private var trackMessage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receipt Lookup").font(.headline)
            Text("Look up a message or task on this Atem by its ID.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Receipt", selection: $trackMessage) {
                    Text("Message").tag(true)
                    Text("Task").tag(false)
                }.frame(width: 170)
                TextField(trackMessage ? "Message ID" : "Task ID", text: $receiptID)
                    .textFieldStyle(.roundedBorder)
                Button("Track") {
                    let id = receiptID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trackMessage { work.track(messageID: id) }
                    else { work.track(taskID: id) }
                }.disabled(receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(trackMessage ? work.canTrackMessages : work.canTrackTasks))
            }
            if let status = work.trackingStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if work.needsReconnect { Button("Reconnect to Check", action: reconnect) }
            if !work.canTrackMessages && !work.canTrackTasks && !work.needsReconnect {
                Text("Message and task receipt lookup is unavailable on this connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(work.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message \(message.id)").font(.caption.monospaced())
                    ForEach(message.recipients) { recipient in
                        Text(recipient.recipient_id).font(.caption.weight(.medium))
                        Text(recipient.delivery.work.map { workLabel($0.state) }
                            ?? (recipient.delivery.state == "stored" ? "Stored on host" : "Refused: \(recipient.delivery.code ?? "forbidden")"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let detail = recipient.delivery.work?.detail, !detail.isEmpty { Text(detail).font(.caption) }
                    }
                }
                .textSelection(.enabled)
            }
            ForEach(work.work) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task \(task.id)").font(.caption.monospaced())
                    Text(workLabel(task.state)).font(.callout)
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }

    private func workLabel(_ state: String) -> String {
        state == "awaiting_result" ? "Turn finished - awaiting task result" : state.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
