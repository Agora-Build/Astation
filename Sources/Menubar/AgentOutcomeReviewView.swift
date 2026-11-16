import AstationRemote
import SwiftUI

struct HostOutcomeView: View {
    @ObservedObject var hub: AstationHubManager
    let clientID: String
    let onClose: () -> Void
    @State private var work: RemoteHostWork?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Host Outcomes").font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let work {
                    if work.canReviewOutcomes {
                        AgentOutcomeListView(work: work, revision: hub.hostWorkRevision)
                    } else {
                        Text("Reconnect with control permission to review this host's outcomes.")
                            .foregroundStyle(.secondary)
                    }
                    if work.needsReconnect {
                        Button("Reconnect to Check") { hub.sessionClient(for: clientID)?.reconnectForHostWorkRecovery() }
                    }
                } else {
                    Text("This host's connection is unavailable.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(24).frame(width: 600, height: 520)
        .task { work = hub.hostWorkClient(for: clientID) }
    }
}

struct AgentOutcomeListView: View {
    let work: RemoteHostWork
    let revision: UInt64
    @State private var review: RemoteOutcomeReview?

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Unknown Outcomes", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Spacer()
                Button("Refresh") { work.refreshAlerts() }
                    .disabled(!work.canReviewOutcomes || work.loadingAlerts)
            }
            Text("These tasks may have run. Review the host before recording an outcome.")
                .font(.caption).foregroundStyle(.secondary)
            if work.loadingAlerts { ProgressView("Checking host outcomes...").controlSize(.small) }
            if let status = work.alertStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if work.alerts.count >= 32 {
                Text("\(work.alerts.count) tasks need review on this host.").font(.callout.weight(.semibold))
            }
            ForEach(work.alerts) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    Label(alert.reason, systemImage: "questionmark.circle")
                        .font(.callout.weight(.medium))
                    Text("Host: \(alert.host_id)\nSession: \(alert.session_id)\nTask: \(alert.task_id)\nSender: \(alert.sender)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if work.canResolveOutcomes {
                        Button("Review Outcome") { review = work.reviewOutcome(alert) }
                            .disabled(!work.alertsLoaded || work.isCheckingOutcome(alert.task_id))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if !work.loadingAlerts && work.alerts.isEmpty && work.alertStatus == nil {
                Text("No unresolved outcomes reported by this host.").foregroundStyle(.secondary)
            }
            if !work.alerts.isEmpty && !work.canResolveOutcomes {
                Text("Outcome resolution is not enabled on this connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $review) { review in
            AgentOutcomeReviewView(work: work, revision: revision, review: review) { self.review = nil }
        }
    }
}

struct AgentOutcomeReviewView: View {
    let work: RemoteHostWork
    let revision: UInt64
    let review: RemoteOutcomeReview
    let onClose: () -> Void
    @State private var markDone = false
    @State private var detail = ""
    @State private var snapshot = ""

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Task Outcome").font(.title2.weight(.semibold))
            Text("\(review.alert.host_id) / \(review.alert.session_id)").font(.caption)
            Text("Task: \(review.alert.task_id)\nSender: \(review.alert.sender)\nReason: \(review.alert.reason)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("Confirm what happened on the host. Recording an outcome settles this task without running it again.")
            Picker("Outcome", selection: $markDone) {
                Text("Mark failed").tag(false)
                Text("Mark done").tag(true)
            }.pickerStyle(.segmented)
            if markDone {
                Text("Paste the published memory or vault result snapshot, including kind, id, version, digest and text.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $snapshot).font(.body.monospaced()).frame(height: 150)
            } else {
                TextField("Why the task failed", text: $detail).textFieldStyle(.roundedBorder)
            }
            if !work.canResolve(review) {
                Text("The connection or task changed. Close this review and refresh outcomes before deciding.")
                    .foregroundStyle(.secondary)
            }
            if let status = work.alertStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(markDone ? "Confirm Done" : "Confirm Failed") {
                    let sent = markDone ? work.resolve(review, done: snapshot) : work.resolve(review, failed: detail)
                    if sent { onClose() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!work.canResolve(review)
                    || (markDone ? snapshot : detail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 560)
    }
}
