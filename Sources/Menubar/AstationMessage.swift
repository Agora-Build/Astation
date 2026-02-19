import Foundation

// JSON message protocol for communication between Atem and Astation
enum AstationMessage: Codable {
    case projectListRequest
    case projectListResponse(projects: [AgoraProject], timestamp: Date)
    
    case tokenRequest(channel: String, uid: String, projectId: String?)
    case tokenResponse(token: String, channel: String, uid: String, expiresIn: String, timestamp: Date)
    
    case userCommand(command: String, context: [String: String])
    case commandResponse(output: String, success: Bool, timestamp: Date)
    
    case statusUpdate(status: String, data: [String: String])
    case systemStatusRequest
    case systemStatusResponse(status: SystemStatus, timestamp: Date)
    
    case claudeLaunchRequest(context: String?)
    case claudeLaunchResponse(success: Bool, message: String, timestamp: Date)
    
    case authRequest(sessionId: String, hostname: String, otp: String, timestamp: Date)
    case authResponse(sessionId: String, success: Bool, token: String?, timestamp: Date)

    case voiceToggle(active: Bool)
    case videoToggle(active: Bool)
    case atemInstanceList(instances: [AtemInstanceInfo])

    case heartbeat(timestamp: Date)
    case pong(timestamp: Date)

    // Voice command routing (Astation → Atem)
    case voiceCommand(text: String, isFinal: Bool)

    // Mark task routing (Chisel → Astation → Atem)
    case markTaskNotify(taskId: String, status: String, description: String)
    case markTaskAssignment(taskId: String, receivedAtMs: UInt64)
    case markTaskResult(taskId: String, success: Bool, message: String)

    // Agent hub (Astation ↔ Atem)
    case agentListRequest
    case agentListResponse(agents: [AtemAgentInfo])
    case credentialSync(customerId: String, customerSecret: String)
    
    // Custom encoding/decoding to handle the enum cases
    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case timestamp
    }
    
    private enum MessageType: String, Codable {
        case projectListRequest
        case projectListResponse
        case tokenRequest
        case tokenResponse
        case userCommand
        case commandResponse
        case statusUpdate
        case systemStatusRequest
        case systemStatusResponse
        case claudeLaunchRequest
        case claudeLaunchResponse
        case authRequest = "auth_request"
        case authResponse = "auth_response"
        case voiceToggle = "voice_toggle"
        case videoToggle = "video_toggle"
        case atemInstanceList = "atem_instance_list"
        case heartbeat
        case pong
        case voiceCommand
        case markTaskNotify
        case markTaskAssignment
        case markTaskResult
        case agentListRequest
        case agentListResponse
        case credentialSync
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .projectListRequest:
            try container.encode(MessageType.projectListRequest, forKey: .type)
            
        case .projectListResponse(let projects, let timestamp):
            try container.encode(MessageType.projectListResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: ProjectListKeys.self, forKey: .data)
            try dataContainer.encode(projects, forKey: .projects)
            
        case .tokenRequest(let channel, let uid, let projectId):
            try container.encode(MessageType.tokenRequest, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: TokenRequestKeys.self, forKey: .data)
            try dataContainer.encode(channel, forKey: .channel)
            try dataContainer.encode(uid, forKey: .uid)
            try dataContainer.encodeIfPresent(projectId, forKey: .projectId)
            
        case .tokenResponse(let token, let channel, let uid, let expiresIn, let timestamp):
            try container.encode(MessageType.tokenResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: TokenResponseKeys.self, forKey: .data)
            try dataContainer.encode(token, forKey: .token)
            try dataContainer.encode(channel, forKey: .channel)
            try dataContainer.encode(uid, forKey: .uid)
            try dataContainer.encode(expiresIn, forKey: .expiresIn)
            
        case .userCommand(let command, let context):
            try container.encode(MessageType.userCommand, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: UserCommandKeys.self, forKey: .data)
            try dataContainer.encode(command, forKey: .command)
            try dataContainer.encode(context, forKey: .context)
            
        case .commandResponse(let output, let success, let timestamp):
            try container.encode(MessageType.commandResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: CommandResponseKeys.self, forKey: .data)
            try dataContainer.encode(output, forKey: .output)
            try dataContainer.encode(success, forKey: .success)
            
        case .statusUpdate(let status, let data):
            try container.encode(MessageType.statusUpdate, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: StatusUpdateKeys.self, forKey: .data)
            try dataContainer.encode(status, forKey: .status)
            try dataContainer.encode(data, forKey: .data)
            
        case .systemStatusRequest:
            try container.encode(MessageType.systemStatusRequest, forKey: .type)
            
        case .systemStatusResponse(let status, let timestamp):
            try container.encode(MessageType.systemStatusResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: SystemStatusKeys.self, forKey: .data)
            try dataContainer.encode(status.connectedClients, forKey: .connectedClients)
            try dataContainer.encode(status.claudeRunning, forKey: .claudeRunning)
            try dataContainer.encode(status.uptimeSeconds, forKey: .uptimeSeconds)
            try dataContainer.encode(status.projects, forKey: .projects)
            
        case .claudeLaunchRequest(let context):
            try container.encode(MessageType.claudeLaunchRequest, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: ClaudeLaunchKeys.self, forKey: .data)
            try dataContainer.encodeIfPresent(context, forKey: .context)
            
        case .claudeLaunchResponse(let success, let message, let timestamp):
            try container.encode(MessageType.claudeLaunchResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: ClaudeResponseKeys.self, forKey: .data)
            try dataContainer.encode(success, forKey: .success)
            try dataContainer.encode(message, forKey: .message)
            
        case .authRequest(let sessionId, let hostname, let otp, let timestamp):
            try container.encode(MessageType.authRequest, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: AuthRequestKeys.self, forKey: .data)
            try dataContainer.encode(sessionId, forKey: .sessionId)
            try dataContainer.encode(hostname, forKey: .hostname)
            try dataContainer.encode(otp, forKey: .otp)

        case .authResponse(let sessionId, let success, let token, let timestamp):
            try container.encode(MessageType.authResponse, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            var dataContainer = container.nestedContainer(keyedBy: AuthResponseKeys.self, forKey: .data)
            try dataContainer.encode(sessionId, forKey: .sessionId)
            try dataContainer.encode(success, forKey: .success)
            try dataContainer.encodeIfPresent(token, forKey: .token)

        case .voiceToggle(let active):
            try container.encode(MessageType.voiceToggle, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: VoiceToggleKeys.self, forKey: .data)
            try dataContainer.encode(active, forKey: .active)

        case .videoToggle(let active):
            try container.encode(MessageType.videoToggle, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: VideoToggleKeys.self, forKey: .data)
            try dataContainer.encode(active, forKey: .active)

        case .atemInstanceList(let instances):
            try container.encode(MessageType.atemInstanceList, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: AtemInstanceListKeys.self, forKey: .data)
            try dataContainer.encode(instances, forKey: .instances)

        case .heartbeat(let timestamp):
            try container.encode(MessageType.heartbeat, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)

        case .pong(let timestamp):
            try container.encode(MessageType.pong, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)

        case .voiceCommand(let text, let isFinal):
            try container.encode(MessageType.voiceCommand, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: VoiceCommandKeys.self, forKey: .data)
            try dataContainer.encode(text, forKey: .text)
            try dataContainer.encode(isFinal, forKey: .isFinal)

        case .markTaskNotify(let taskId, let status, let description):
            try container.encode(MessageType.markTaskNotify, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: MarkTaskNotifyKeys.self, forKey: .data)
            try dataContainer.encode(taskId, forKey: .taskId)
            try dataContainer.encode(status, forKey: .status)
            try dataContainer.encode(description, forKey: .description)

        case .markTaskAssignment(let taskId, let receivedAtMs):
            try container.encode(MessageType.markTaskAssignment, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: MarkTaskAssignmentKeys.self, forKey: .data)
            try dataContainer.encode(taskId, forKey: .taskId)
            try dataContainer.encode(receivedAtMs, forKey: .receivedAtMs)

        case .markTaskResult(let taskId, let success, let message):
            try container.encode(MessageType.markTaskResult, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: MarkTaskResultKeys.self, forKey: .data)
            try dataContainer.encode(taskId, forKey: .taskId)
            try dataContainer.encode(success, forKey: .success)
            try dataContainer.encode(message, forKey: .message)

        case .agentListRequest:
            try container.encode(MessageType.agentListRequest, forKey: .type)

        case .agentListResponse(let agents):
            try container.encode(MessageType.agentListResponse, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: AgentListKeys.self, forKey: .data)
            try dataContainer.encode(agents, forKey: .agents)

        case .credentialSync(let customerId, let customerSecret):
            try container.encode(MessageType.credentialSync, forKey: .type)
            var dataContainer = container.nestedContainer(keyedBy: CredentialSyncKeys.self, forKey: .data)
            try dataContainer.encode(customerId, forKey: .customerId)
            try dataContainer.encode(customerSecret, forKey: .customerSecret)
        }
    }

    private enum CredentialSyncKeys: String, CodingKey {
        case customerId = "customer_id"
        case customerSecret = "customer_secret"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        
        switch type {
        case .projectListRequest:
            self = .projectListRequest
            
        case .projectListResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: ProjectListKeys.self, forKey: .data)
            let projects = try dataContainer.decode([AgoraProject].self, forKey: .projects)
            self = .projectListResponse(projects: projects, timestamp: timestamp)
            
        case .tokenRequest:
            let dataContainer = try container.nestedContainer(keyedBy: TokenRequestKeys.self, forKey: .data)
            let channel = try dataContainer.decode(String.self, forKey: .channel)
            let uid = try dataContainer.decode(String.self, forKey: .uid)
            let projectId = try dataContainer.decodeIfPresent(String.self, forKey: .projectId)
            self = .tokenRequest(channel: channel, uid: uid, projectId: projectId)
            
        case .tokenResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: TokenResponseKeys.self, forKey: .data)
            let token = try dataContainer.decode(String.self, forKey: .token)
            let channel = try dataContainer.decode(String.self, forKey: .channel)
            let uid = try dataContainer.decode(String.self, forKey: .uid)
            let expiresIn = try dataContainer.decode(String.self, forKey: .expiresIn)
            self = .tokenResponse(token: token, channel: channel, uid: uid, expiresIn: expiresIn, timestamp: timestamp)
            
        case .userCommand:
            let dataContainer = try container.nestedContainer(keyedBy: UserCommandKeys.self, forKey: .data)
            let command = try dataContainer.decode(String.self, forKey: .command)
            let context = try dataContainer.decode([String: String].self, forKey: .context)
            self = .userCommand(command: command, context: context)
            
        case .commandResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: CommandResponseKeys.self, forKey: .data)
            let output = try dataContainer.decode(String.self, forKey: .output)
            let success = try dataContainer.decode(Bool.self, forKey: .success)
            self = .commandResponse(output: output, success: success, timestamp: timestamp)
            
        case .statusUpdate:
            let dataContainer = try container.nestedContainer(keyedBy: StatusUpdateKeys.self, forKey: .data)
            let status = try dataContainer.decode(String.self, forKey: .status)
            let data = try dataContainer.decode([String: String].self, forKey: .data)
            self = .statusUpdate(status: status, data: data)
            
        case .systemStatusRequest:
            self = .systemStatusRequest
            
        case .systemStatusResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: SystemStatusKeys.self, forKey: .data)
            let connectedClients = try dataContainer.decode(Int.self, forKey: .connectedClients)
            let claudeRunning = try dataContainer.decode(Bool.self, forKey: .claudeRunning)
            let uptimeSeconds = try dataContainer.decode(UInt64.self, forKey: .uptimeSeconds)
            let projects = try dataContainer.decode(Int.self, forKey: .projects)
            let status = SystemStatus(
                connectedClients: connectedClients,
                claudeRunning: claudeRunning,
                uptimeSeconds: uptimeSeconds,
                projects: projects
            )
            self = .systemStatusResponse(status: status, timestamp: timestamp)
            
        case .claudeLaunchRequest:
            let dataContainer = try container.nestedContainer(keyedBy: ClaudeLaunchKeys.self, forKey: .data)
            let context = try dataContainer.decodeIfPresent(String.self, forKey: .context)
            self = .claudeLaunchRequest(context: context)
            
        case .claudeLaunchResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: ClaudeResponseKeys.self, forKey: .data)
            let success = try dataContainer.decode(Bool.self, forKey: .success)
            let message = try dataContainer.decode(String.self, forKey: .message)
            self = .claudeLaunchResponse(success: success, message: message, timestamp: timestamp)
            
        case .authRequest:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: AuthRequestKeys.self, forKey: .data)
            let sessionId = try dataContainer.decode(String.self, forKey: .sessionId)
            let hostname = try dataContainer.decode(String.self, forKey: .hostname)
            let otp = try dataContainer.decode(String.self, forKey: .otp)
            self = .authRequest(sessionId: sessionId, hostname: hostname, otp: otp, timestamp: timestamp)

        case .authResponse:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            let dataContainer = try container.nestedContainer(keyedBy: AuthResponseKeys.self, forKey: .data)
            let sessionId = try dataContainer.decode(String.self, forKey: .sessionId)
            let success = try dataContainer.decode(Bool.self, forKey: .success)
            let token = try dataContainer.decodeIfPresent(String.self, forKey: .token)
            self = .authResponse(sessionId: sessionId, success: success, token: token, timestamp: timestamp)

        case .voiceToggle:
            let dataContainer = try container.nestedContainer(keyedBy: VoiceToggleKeys.self, forKey: .data)
            let active = try dataContainer.decode(Bool.self, forKey: .active)
            self = .voiceToggle(active: active)

        case .videoToggle:
            let dataContainer = try container.nestedContainer(keyedBy: VideoToggleKeys.self, forKey: .data)
            let active = try dataContainer.decode(Bool.self, forKey: .active)
            self = .videoToggle(active: active)

        case .atemInstanceList:
            let dataContainer = try container.nestedContainer(keyedBy: AtemInstanceListKeys.self, forKey: .data)
            let instances = try dataContainer.decode([AtemInstanceInfo].self, forKey: .instances)
            self = .atemInstanceList(instances: instances)

        case .heartbeat:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            self = .heartbeat(timestamp: timestamp)

        case .pong:
            let timestamp = try container.decode(Date.self, forKey: .timestamp)
            self = .pong(timestamp: timestamp)

        case .voiceCommand:
            let dataContainer = try container.nestedContainer(keyedBy: VoiceCommandKeys.self, forKey: .data)
            let text = try dataContainer.decode(String.self, forKey: .text)
            let isFinal = try dataContainer.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
            self = .voiceCommand(text: text, isFinal: isFinal)

        case .markTaskNotify:
            let dataContainer = try container.nestedContainer(keyedBy: MarkTaskNotifyKeys.self, forKey: .data)
            let taskId = try dataContainer.decode(String.self, forKey: .taskId)
            let status = try dataContainer.decode(String.self, forKey: .status)
            let description = try dataContainer.decode(String.self, forKey: .description)
            self = .markTaskNotify(taskId: taskId, status: status, description: description)

        case .markTaskAssignment:
            let dataContainer = try container.nestedContainer(keyedBy: MarkTaskAssignmentKeys.self, forKey: .data)
            let taskId = try dataContainer.decode(String.self, forKey: .taskId)
            let receivedAtMs = try dataContainer.decodeIfPresent(UInt64.self, forKey: .receivedAtMs) ?? 0
            self = .markTaskAssignment(taskId: taskId, receivedAtMs: receivedAtMs)

        case .markTaskResult:
            let dataContainer = try container.nestedContainer(keyedBy: MarkTaskResultKeys.self, forKey: .data)
            let taskId = try dataContainer.decode(String.self, forKey: .taskId)
            let success = try dataContainer.decode(Bool.self, forKey: .success)
            let message = try dataContainer.decode(String.self, forKey: .message)
            self = .markTaskResult(taskId: taskId, success: success, message: message)

        case .agentListRequest:
            self = .agentListRequest

        case .agentListResponse:
            let dataContainer = try container.nestedContainer(keyedBy: AgentListKeys.self, forKey: .data)
            let agents = try dataContainer.decode([AtemAgentInfo].self, forKey: .agents)
            self = .agentListResponse(agents: agents)

        case .credentialSync:
            let dataContainer = try container.nestedContainer(keyedBy: CredentialSyncKeys.self, forKey: .data)
            let customerId = try dataContainer.decode(String.self, forKey: .customerId)
            let customerSecret = try dataContainer.decode(String.self, forKey: .customerSecret)
            self = .credentialSync(customerId: customerId, customerSecret: customerSecret)
        }
    }
}

// MARK: - Nested CodingKeys for different message types

private enum ProjectListKeys: String, CodingKey {
    case projects
}

private enum TokenRequestKeys: String, CodingKey {
    case channel, uid, projectId
}

private enum TokenResponseKeys: String, CodingKey {
    case token, channel, uid, expiresIn
}

private enum UserCommandKeys: String, CodingKey {
    case command, context
}

private enum CommandResponseKeys: String, CodingKey {
    case output, success
}

private enum StatusUpdateKeys: String, CodingKey {
    case status, data
}

private enum SystemStatusKeys: String, CodingKey {
    case connectedClients, claudeRunning, uptimeSeconds, projects
}

private enum ClaudeLaunchKeys: String, CodingKey {
    case context
}

private enum ClaudeResponseKeys: String, CodingKey {
    case success, message
}

private enum AuthRequestKeys: String, CodingKey {
    case sessionId, hostname, otp
}

private enum AuthResponseKeys: String, CodingKey {
    case sessionId, success, token
}

private enum VoiceToggleKeys: String, CodingKey {
    case active
}

private enum VideoToggleKeys: String, CodingKey {
    case active
}

private enum AtemInstanceListKeys: String, CodingKey {
    case instances
}

private enum VoiceCommandKeys: String, CodingKey {
    case text
    case isFinal = "is_final"
}

private enum MarkTaskNotifyKeys: String, CodingKey {
    case taskId, status, description
}

private enum MarkTaskAssignmentKeys: String, CodingKey {
    case taskId, receivedAtMs
}

private enum MarkTaskResultKeys: String, CodingKey {
    case taskId, success, message
}

private enum AgentListKeys: String, CodingKey {
    case agents
}

/// Information about a connected Atem instance, broadcast to all clients.
struct AtemInstanceInfo: Codable {
    let id: String
    let hostname: String
    let tag: String
    let isFocused: Bool

    enum CodingKeys: String, CodingKey {
        case id, hostname, tag
        case isFocused = "is_focused"
    }
}

/// Snapshot of an agent registered in an Atem instance's AgentRegistry.
/// Mirrors Rust's `agent_client::AgentInfo` serialization.
struct AtemAgentInfo: Codable, Identifiable {
    let id: String
    let name: String
    /// Human-readable kind: "Claude Code", "Codex", or raw unknown string.
    let kind: String
    /// Protocol string from Rust: "Acp" or "Pty".
    let agentProtocol: String
    /// Status string from Rust: "Idle", "Thinking", "WaitingForInput", "Disconnected".
    let status: String
    let sessionIds: [String]
    let acpUrl: String?
    let ptyPid: UInt32?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, status
        case agentProtocol = "protocol"
        case sessionIds = "session_ids"
        case acpUrl = "acp_url"
        case ptyPid = "pty_pid"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Rust's AgentKind serializes as a plain string for unit variants
        // ("ClaudeCode", "Codex") or as {"Unknown": "..."} for the tuple variant.
        if let raw = try? c.decode(String.self, forKey: .kind) {
            switch raw {
            case "ClaudeCode": kind = "Claude Code"
            case "Codex":      kind = "Codex"
            default:           kind = raw
            }
        } else {
            kind = "Unknown"
        }
        agentProtocol = (try? c.decode(String.self, forKey: .agentProtocol)) ?? "Pty"
        status = (try? c.decode(String.self, forKey: .status)) ?? "Idle"
        sessionIds = (try? c.decode([String].self, forKey: .sessionIds)) ?? []
        acpUrl = try? c.decodeIfPresent(String.self, forKey: .acpUrl)
        ptyPid = try? c.decodeIfPresent(UInt32.self, forKey: .ptyPid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(agentProtocol, forKey: .agentProtocol)
        try c.encode(status, forKey: .status)
        try c.encode(sessionIds, forKey: .sessionIds)
        try c.encodeIfPresent(acpUrl, forKey: .acpUrl)
        try c.encodeIfPresent(ptyPid, forKey: .ptyPid)
    }
}