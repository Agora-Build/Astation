import SwiftUI

// MARK: - Main window view

struct ConnectionsView: View {
    @ObservedObject var hubManager: AstationHubManager
    /// Which client's agents are shown on the right panel.
    @State private var selectedClientId: String?

    var body: some View {
        HSplitView {
            ClientListPanel(hubManager: hubManager, selectedClientId: $selectedClientId)
                .frame(minWidth: 230, maxWidth: 310)

            AgentListPanel(hubManager: hubManager, clientId: selectedClientId)
                .frame(minWidth: 340)
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear {
            // Default to the currently active/focused client
            if selectedClientId == nil {
                selectedClientId = hubManager.pinnedClientId
                    ?? hubManager.focusedClient()?.id
                    ?? hubManager.connectedClients.first?.id
            }
        }
    }
}

// MARK: - Client list panel

private struct ClientListPanel: View {
    @ObservedObject var hubManager: AstationHubManager
    @Binding var selectedClientId: String?

    private var onlineAtems: [ConnectedClient] {
        hubManager.connectedClients.filter { $0.clientType == "Atem" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Atem Clients")
                    .font(.headline)
                Spacer()
                let n = onlineAtems.count
                Text(n == 0 ? "none online" : n == 1 ? "1 online" : "\(n) online")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Body ──────────────────────────────────────────────────────
            if onlineAtems.isEmpty && hubManager.offlineClients.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Online clients
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

                        // Offline section
                        if !hubManager.offlineClients.isEmpty {
                            HStack {
                                Text("Offline")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                            ForEach(hubManager.offlineClients) { offline in
                                OfflineClientRow(
                                    client: offline,
                                    onRemove: { hubManager.removeOfflineClient(id: offline.id) }
                                )
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
            Text("Start `atem` on a dev machine to connect.")
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

// MARK: - Offline client row

private struct OfflineClientRow: View {
    let client: OfflineClient
    let onRemove: () -> Void

    private var displayName: String {
        client.hostname.isEmpty || client.hostname == "unknown"
            ? String(client.id.prefix(8)) + "…"
            : client.hostname
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red.opacity(0.7))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("offline · last seen \(relativeTime(from: client.disconnectedAt))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Agent list panel

private struct AgentListPanel: View {
    @ObservedObject var hubManager: AstationHubManager
    let clientId: String?

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
                            AgentRow(agent: agent)
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
            return URL(string: url).flatMap {
                $0.host.map { h in
                    let port = $0.port.map { ":\($0)" } ?? ""
                    return h + port
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
