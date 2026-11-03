import AstationRemote
import SwiftUI

struct AgentLaunchView: View {
    @ObservedObject var hub: AstationHubManager
    let clientID: String
    let onAttach: (AtemAgentInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfile: String?
    @State private var work: RemoteHostWork?
    @State private var receiptID = ""
    @State private var trackMessage = true

    var body: some View {
        let _ = hub.hostWorkRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("New Agent").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text("Choose a profile approved on this Atem. Its project, provider and credentials stay on the host.")
                    .foregroundStyle(.secondary)
                if let work {
                    Text(work.status).font(.callout).textSelection(.enabled)
                    if work.needsReconnect {
                        Button("Reconnect to Check") { hub.sessionClient(for: clientID)?.reconnectForHostWorkRecovery() }
                    }
                    if work.loadingProfiles { ProgressView().controlSize(.small) }
                    if !work.profiles.isEmpty {
                        Picker("Launch profile", selection: $selectedProfile) {
                            Text("Choose a profile").tag(String?.none)
                            ForEach(work.profiles) { profile in
                                Text("\(profile.label) - \(profile.provider)").tag(Optional(profile.id))
                            }
                        }
                        HStack {
                            Button("Refresh Profiles") { work.refreshProfiles() }
                                .disabled(!work.available || work.loadingProfiles)
                            Spacer()
                            Button("Launch Agent") {
                                if let profile = work.profiles.first(where: { $0.id == selectedProfile }) {
                                    _ = work.launch(profile)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!work.available || work.storageFailed || work.needsReconnect || selectedProfile == nil
                                || work.currentLaunches.contains { ($0.status == nil && $0.refusal == nil) || $0.status?.state == .starting })
                        }
                    } else if !work.loadingProfiles {
                        Button("Refresh Profiles") { work.refreshProfiles() }.disabled(!work.available)
                    }
                    if !work.currentLaunches.isEmpty {
                        Divider()
                        HStack {
                            Text("Launches").font(.headline)
                            Spacer()
                            Button("Check Status") { work.refresh() }.disabled(!work.available)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(work.currentLaunches) { record in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.profile.label).font(.body.weight(.medium))
                                            Text(record.refusal.map { "Launch refused: \($0)" } ?? launchLabel(record.status)).font(.caption).foregroundStyle(.secondary)
                                            Text(record.requestID).font(.caption2.monospaced()).textSelection(.enabled)
                                        }
                                        Spacer()
                                        if let launch = record.status, launch.state == .started,
                                           hub.sessionClient(for: clientID)?.registry[launch.session_id]?.process_gen == launch.process_gen,
                                           let agent = hub.agentsByClientId[clientID]?.first(where: { $0.id == launch.session_id }) {
                                            Button("Attach") { onAttach(agent) }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 210)
                    }
                    Divider()
                    HStack {
                        Picker("Receipt", selection: $trackMessage) {
                            Text("Message").tag(true)
                            Text("Task").tag(false)
                        }.frame(width: 155)
                        TextField("Message or task ID", text: $receiptID)
                        Button("Track") {
                            if trackMessage { work.track(messageID: receiptID.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            else { work.track(taskID: receiptID.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }.disabled(receiptID.isEmpty)
                    }
                    ForEach(work.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Message \(message.id)").font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(message.recipients) { recipient in
                                Text(recipient.delivery.work.map { $0.state == "awaiting_result"
                                    ? "Turn finished - awaiting task result" : $0.state.replacingOccurrences(of: "_", with: " ") }
                                    ?? (recipient.delivery.state == "stored" ? "Stored on host" : "Refused: \(recipient.delivery.code ?? "forbidden")"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !work.work.isEmpty {
                        Divider()
                        Text("Tasks").font(.headline)
                        ForEach(work.work) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.state == "awaiting_result" ? "Turn finished - awaiting task result"
                                    : task.state.replacingOccurrences(of: "_", with: " ").capitalized)
                                Text(task.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Reconnect and verify this Atem before launching an agent.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 320, idealHeight: 540, maxHeight: 650)
        .task { work = hub.hostWorkClient(for: clientID) }
    }

    private func launchLabel(_ launch: RemoteLaunchStatus?) -> String {
        switch launch?.state {
        case .starting: return "Starting agent"
        case .started: return "Started - waiting for its session if Attach is unavailable"
        case .failed: return "Launch failed - check the host profile"
        case .outcome_unknown: return "Outcome unknown - check the host before launching again"
        case nil: return "Awaiting confirmation - the original launch will be queried"
        }
    }
}
