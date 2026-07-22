import SwiftUI

enum AtemClientListModel {
    static func onlineClients(
        _ connectedClients: [ConnectedClient],
        preferredClientId: String? = nil
    ) -> [ConnectedClient] {
        var preferredByDevice: [String: ConnectedClient] = [:]

        for client in connectedClients where client.clientType == "Atem" {
            let deviceKey = client.atemId.map { "atem:\($0)" } ?? "client:\(client.id)"
            guard let existing = preferredByDevice[deviceKey] else {
                preferredByDevice[deviceKey] = client
                continue
            }

            if prefersClient(client, over: existing, preferredClientId: preferredClientId) {
                preferredByDevice[deviceKey] = client
            }
        }

        return preferredByDevice.values.sorted {
            let left = $0.hostname.localizedCaseInsensitiveCompare($1.hostname)
            return left == .orderedSame ? $0.id < $1.id : left == .orderedAscending
        }
    }

    private static func prefersClient(
        _ candidate: ConnectedClient,
        over existing: ConnectedClient,
        preferredClientId: String?
    ) -> Bool {
        if candidate.id == preferredClientId { return true }
        if existing.id == preferredClientId { return false }
        if candidate.isFocused != existing.isFocused { return candidate.isFocused }

        let candidateIsDirect = !candidate.id.hasPrefix("relay-")
        let existingIsDirect = !existing.id.hasPrefix("relay-")
        if candidateIsDirect != existingIsDirect { return candidateIsDirect }
        if candidate.connectedAt != existing.connectedAt {
            return candidate.connectedAt > existing.connectedAt
        }
        return candidate.id < existing.id
    }

    static func offlineSessions(
        activeSessions: [SessionInfo],
        connectedClients: [ConnectedClient]
    ) -> [SessionInfo] {
        let onlineAtemIds = Set(
            connectedClients
                .filter { $0.clientType == "Atem" }
                .compactMap(\.atemId)
        )

        var latestSessionByDevice: [String: SessionInfo] = [:]
        for session in activeSessions where session.isValid {
            // Legacy sessions cannot be matched to a live device until v2 auth
            // binds them to a stable Atem ID, so do not present a false offline row.
            guard let atemId = session.atemId else { continue }
            if onlineAtemIds.contains(atemId) {
                continue
            }

            let deviceKey = "atem:\(atemId)"
            if let existing = latestSessionByDevice[deviceKey],
               existing.lastActivity > session.lastActivity ||
               (existing.lastActivity == session.lastActivity && existing.id < session.id) {
                    continue
            }
            latestSessionByDevice[deviceKey] = session
        }

        return latestSessionByDevice.values.sorted {
            if $0.lastActivity != $1.lastActivity {
                return $0.lastActivity > $1.lastActivity
            }
            return $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
        }
    }
}

// MARK: - Main window view

struct ConnectionsView: View {
    @ObservedObject var hubManager: AstationHubManager
    let onRemoteControl: (String, AtemAgentInfo) -> Void
    /// Which client's agents are shown on the right panel.
    @State private var selectedClientId: String?

    var body: some View {
        HSplitView {
            ClientListPanel(hubManager: hubManager, selectedClientId: $selectedClientId)
                .frame(minWidth: 230, maxWidth: 310)

            AgentListPanel(
                hubManager: hubManager,
                clientId: selectedClientId,
                onRemoteControl: onRemoteControl
            )
                .frame(minWidth: 340)
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear {
            selectAvailableClientIfNeeded()
        }
        .onChange(of: hubManager.connectedClients.map(\.id)) { _, _ in
            selectAvailableClientIfNeeded()
        }
    }

    private func selectAvailableClientIfNeeded() {
        let onlineClients = AtemClientListModel.onlineClients(
            hubManager.connectedClients,
            preferredClientId: hubManager.pinnedClientId
        )
        let onlineIds = Set(onlineClients.map(\.id))
        if let selectedClientId, onlineIds.contains(selectedClientId) {
            return
        }
        selectedClientId = onlineClients.first(where: { $0.id == hubManager.pinnedClientId })?.id
            ?? onlineClients.first(where: \.isFocused)?.id
            ?? onlineClients.first?.id
    }
}

// MARK: - Client list panel

private struct ClientListPanel: View {
    @ObservedObject var hubManager: AstationHubManager
    @Binding var selectedClientId: String?

    private var onlineAtems: [ConnectedClient] {
        AtemClientListModel.onlineClients(
            hubManager.connectedClients,
            preferredClientId: hubManager.pinnedClientId
        )
    }

    private var offlineAtems: [SessionInfo] {
        AtemClientListModel.offlineSessions(
            activeSessions: hubManager.deviceSessionStore.getAllActive(),
            connectedClients: onlineAtems
        )
    }

    private var statusText: String {
        switch (onlineAtems.count, offlineAtems.count) {
        case (0, 0): return "none paired"
        case (let online, 0): return online == 1 ? "1 online" : "\(online) online"
        case (0, let offline): return offline == 1 ? "1 paired offline" : "\(offline) paired offline"
        case (let online, let offline): return "\(online) online · \(offline) paired offline"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Atem Clients")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Body ──────────────────────────────────────────────────────
            if onlineAtems.isEmpty && offlineAtems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(onlineAtems) { client in
                            OnlineClientRow(
                                client: client,
                                isSelected: selectedClientId == client.id,
                                isPinned: hubManager.pinnedClientId == client.id,
                                onSelect: { selectedClientId = client.id },
                                onTogglePin: {
                                    if hubManager.pinnedClientId == client.id {
                                        hubManager.unpinClient()
                                    } else {
                                        hubManager.pinClient(id: client.id)
                                    }
                                },
                                onRefreshAgents: {
                                    hubManager.requestAgentList(from: client.id)
                                }
                            )
                        }

                        if !offlineAtems.isEmpty {
                            Text("Paired offline")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, onlineAtems.isEmpty ? 4 : 10)
                                .padding(.bottom, 3)

                            ForEach(offlineAtems, id: \.id) { session in
                                OfflineClientRow(session: session)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No Atem clients")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Pair an Atem to add it here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Online client row

private struct OnlineClientRow: View {
    let client: ConnectedClient
    let isSelected: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onRefreshAgents: () -> Void

    private var displayName: String {
        client.hostname == "unknown"
            ? String(client.id.prefix(8)) + "…"
            : client.hostname
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(isPinned ? .semibold : .regular)
                    if isPinned {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    } else if client.isFocused {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                HStack(spacing: 6) {
                    if !client.tag.isEmpty {
                        Text(client.tag)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("connected \(relativeTime(from: client.connectedAt))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Pin / unpin button
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .foregroundColor(isPinned ? .yellow : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin — revert to auto-routing" : "Pin as active routing target")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(isPinned ? "Unpin as Active" : "Pin as Active", action: onTogglePin)
            Button("Refresh Agents", action: onRefreshAgents)
        }
    }
}

// MARK: - Paired offline client row

private struct OfflineClientRow: View {
    let session: SessionInfo

    private var displayName: String {
        if session.hostname != "unknown" {
            return session.hostname
        }
        return session.atemId.map { id in
            id.count > 18 ? String(id.prefix(18)) + "…" : id
        }
            ?? String(session.id.prefix(8)) + "…"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(NSColor.tertiaryLabelColor))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.subheadline)
                Text("Paired · last seen \(relativeTime(from: session.lastActivity))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("offline")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .help("Pairing expires after 7 days without activity")
    }
}

// MARK: - Agent list panel

private struct AgentListPanel: View {
    @ObservedObject var hubManager: AstationHubManager
    let clientId: String?
    let onRemoteControl: (String, AtemAgentInfo) -> Void

    private var agents: [AtemAgentInfo] {
        guard let id = clientId else { return [] }
        return hubManager.agentsByClientId[id] ?? []
    }

    private var selectedClient: ConnectedClient? {
        guard let id = clientId else { return nil }
        return hubManager.connectedClients.first { $0.id == id }
    }

    private var clientIsOnline: Bool { selectedClient != nil }

    private var panelTitle: String {
        guard let c = selectedClient else {
            return clientId.map { String($0.prefix(8)) + "…" } ?? "No client selected"
        }
        return c.hostname == "unknown" ? String(c.id.prefix(8)) + "…" : c.hostname
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Agents")
                    .font(.headline)
                Spacer()
                if clientId != nil {
                    Text(panelTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if clientIsOnline, let id = clientId {
                        Button("Refresh") { hubManager.requestAgentList(from: id) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Body ──────────────────────────────────────────────────────
            if clientId == nil {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Select a client to view its agents")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if agents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No agents registered")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Agents appear when Claude Code or Codex\nare running on this Atem.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if clientIsOnline, let id = clientId {
                        Button("Request Agent List") { hubManager.requestAgentList(from: id) }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(agents) { agent in
                            AgentRow(
                                agent: agent,
                                onRemoteControl: {
                                    guard let clientId else { return }
                                    onRemoteControl(clientId, agent)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Agent row

private struct AgentRow: View {
    let agent: AtemAgentInfo
    let onRemoteControl: () -> Void

    private var statusColor: Color {
        switch agent.status {
        case "Idle":            return Color(NSColor.tertiaryLabelColor)
        case "Thinking":        return .yellow
        case "WaitingForInput": return .green
        case "Disconnected":    return .red
        default:                return Color(NSColor.tertiaryLabelColor)
        }
    }

    private var protocolBadge: String {
        agent.agentProtocol == "Acp" ? "ACP" : "PTY"
    }

    private var endpointLabel: String {
        if let url = agent.acpUrl {
            // Show just host:port to keep it compact
            return URL(string: url).flatMap { parsed in
                parsed.host.map { host in
                    let port = parsed.port.map { ":\($0)" } ?? ""
                    return host + port
                }
            } ?? url
        }
        return "pty"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(0.6), radius: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.kind)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(protocolBadge)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }

                HStack(spacing: 10) {
                    Label(endpointLabel, systemImage: agent.agentProtocol == "Acp" ? "network" : "terminal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if !agent.sessionIds.isEmpty {
                        let s = agent.sessionIds.count
                        Label("\(s) session\(s == 1 ? "" : "s")",
                              systemImage: "bubble.left.and.bubble.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(agent.status)
                        .font(.caption)
                        .foregroundColor(statusColor)
                }

                Button(action: onRemoteControl) {
                    Label("Remote Agent Control", systemImage: "keyboard")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(agent.status == "Disconnected")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }
}

// MARK: - Utility

private func relativeTime(from date: Date) -> String {
    let secs = Int(-date.timeIntervalSinceNow)
    if secs < 5  { return "just now" }
    if secs < 60 { return "\(secs)s ago" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    return "\(secs / 3600)h ago"
}
