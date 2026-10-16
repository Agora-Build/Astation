import CryptoKit
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

    var contentBytes: Int {
        if id == "atem:truncated", kind == "text", markdown == "\u{2026} (truncated)" { return 0 }
        return (markdown?.utf8.count ?? 0) + (name?.utf8.count ?? 0) + (summary?.utf8.count ?? 0)
    }

    var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 128 else { return false }
        switch kind {
        case "text": return markdown != nil && name == nil && summary == nil
        case "tool": return markdown == nil && name != nil && summary != nil
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
}

struct BrowserChatFrame: Codable {
    let sessionId: String
    let nonce: String
    let sequence: UInt64
    let body: String
    let mac: String

    static func signingData(_ direction: String, sessionId: String, nonce: String,
                            sequence: UInt64, body: String) -> Data {
        var data = Data()
        for field in ["astation-browser-chat-\(direction)-v1", sessionId, nonce, String(sequence), body] {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(bytes)
        }
        return data
    }

    func open(key: SymmetricKey) -> [String: Any]? {
        guard sequence > 0, sequence <= 9_007_199_254_740_991, nonce.utf8.count <= 128,
              !nonce.isEmpty, body.utf8.count <= 131_072,
              let signature = Data(base64Encoded: mac), signature.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating:
                Self.signingData("request", sessionId: sessionId, nonce: nonce, sequence: sequence, body: body), using: key),
              let bytes = Data(base64Encoded: body),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return object
    }

    static func response(key: SymmetricKey, sessionId: String, nonce: String,
                         sequence: UInt64, object: [String: Any]) -> BrowserChatFrame? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let body = data.base64EncodedString()
        let signature = HMAC<SHA256>.authenticationCode(for:
            signingData("response", sessionId: sessionId, nonce: nonce, sequence: sequence, body: body), using: key)
        return BrowserChatFrame(sessionId: sessionId, nonce: nonce, sequence: sequence,
                                body: body, mac: Data(signature).base64EncodedString())
    }
}

/// A local capability grants a browser access to one authenticated agent, never a device identity.
final class BrowserAgentChat {
    private final class Session {
        let id = UUID().uuidString.lowercased()
        let key = SymmetricKey(size: .bits256)
        var conversationId = ""
        let route: RemoteTerminalConnection
        let agentId: String
        let agentName: String
        let hostname: String
        let capable: Bool
        let expiresAt: Date
        var browser: RemoteTerminalConnection?
        var nonce = ""
        var usedNonces: Set<String> = []
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var generation: String?
        var hostSequence: UInt64 = 0
        var openingAt: Date?
        var before: String?
        var closed = true
        var activity: AgentChatStatus?
        var activityAt: Date?
        var pendingRequest: String?
        var pendingAt: Date?
        var accepted = false
        var deliveryUnknown = false
        var blocked = false
        var notice = ""
        var requestIds: Set<String> = []
        var messages: [String: AgentChatWire] = [:]
        var transcriptBytes = 0
        var serializedBytes = 0
        var messageSizes: [String: Int] = [:]

        init(route: RemoteTerminalConnection, agent: AtemAgentInfo, hostname: String, expiresAt: Date) {
            self.route = route
            agentId = agent.id
            agentName = agent.kind
            self.hostname = hostname
            capable = agent.capabilities.contains("chat-v1")
            self.expiresAt = expiresAt
        }
    }

    enum OpenError: Error, LocalizedError {
        case offline, invalidURL, tooManySessions, sessionProtocolRequired
        var errorDescription: String? {
            switch self {
            case .offline: return "Connect Astation and this Atem to open a browser conversation."
            case .invalidURL: return "The relay URL must use HTTPS (or localhost HTTP for development)."
            case .tooManySessions: return "Eight browser sessions are already open. Wait for a session to expire before opening another."
            case .sessionProtocolRequired: return "Use Open Terminal for this Atem. Browser access to managed sessions requires the secure companion protocol."
            }
        }
    }

    private var sessions: [String: Session] = [:]
    private let currentRoute: (String) -> RemoteTerminalConnection?
    private let sendAgent: (AgentChatWire, RemoteTerminalConnection) -> Bool
    private let sendBrowser: (BrowserChatFrame, RemoteTerminalConnection) -> Void
    private let now: () -> Date

    init(currentRoute: @escaping (String) -> RemoteTerminalConnection?,
         sendAgent: @escaping (AgentChatWire, RemoteTerminalConnection) -> Bool,
         sendBrowser: @escaping (BrowserChatFrame, RemoteTerminalConnection) -> Void,
         now: @escaping () -> Date = Date.init) {
        self.currentRoute = currentRoute
        self.sendAgent = sendAgent
        self.sendBrowser = sendBrowser
        self.now = now
    }

    func createLink(relayURL: String, stationId: String, clientId: String,
                    agent: AtemAgentInfo, hostname: String) throws -> URL {
        tick()
        sessions = sessions.filter { !$0.value.blocked }
        guard let route = currentRoute(clientId) else { throw OpenError.offline }
        guard sessions.count < 8 else { throw OpenError.tooManySessions }
        guard var url = URLComponents(string: relayURL) else { throw OpenError.invalidURL }
        if url.scheme?.lowercased() == "wss" { url.scheme = "https" }
        if url.scheme?.lowercased() == "ws" { url.scheme = "http" }
        guard url.host != nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")),
              url.user == nil, url.password == nil else { throw OpenError.invalidURL }
        let session = Session(route: route, agent: agent, hostname: hostname,
                              expiresAt: now().addingTimeInterval(3600))
        let secret = session.key.withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "station", value: stationId),
                               URLQueryItem(name: "session", value: session.id), URLQueryItem(name: "key", value: secret)]
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = (url.path.isEmpty ? "" : "/" + url.path) + "/agent/"
        url.query = nil
        url.percentEncodedFragment = fragment.percentEncodedQuery
        guard let link = url.url else { throw OpenError.invalidURL }
        sessions[session.id] = session
        return link
    }

    func receive(_ frame: BrowserChatFrame, from source: RemoteTerminalConnection) {
        guard let session = sessions[frame.sessionId], now() < session.expiresAt,
              source.clientId == "relay-browser-\(session.id)",
              let body = frame.open(key: session.key), let operation = body["op"] as? String else { return }
        if frame.nonce != session.nonce {
            guard operation == "open", frame.sequence == 1, session.usedNonces.count < 32,
                  !session.usedNonces.contains(frame.nonce) else { return }
            session.usedNonces.insert(frame.nonce)
            session.nonce = frame.nonce
            session.received = 0
            session.sent = 0
            session.browser = source
        }
        guard session.browser == source, frame.sequence > session.received else { return }
        session.received = frame.sequence
        switch operation {
        case "open", "reopen": reopen(session)
        case "history":
            guard let before = body["before"] as? String, session.messages[before] != nil else { return }
            reopen(session, before: before)
        case "refresh": context(session)
        case "submit": submit(body, session: session)
        default: break
        }
    }

    private func reopen(_ session: Session, before: String? = nil) {
        guard session.capable, !session.blocked, isCurrent(session) else { context(session); return }
        // Fresh IDs keep delayed events from an earlier open out of the new sequence.
        closeHost(session)
        session.conversationId = UUID().uuidString.lowercased()
        session.openingAt = now()
        session.before = before
        session.closed = true
        session.hostSequence = 0
        session.notice = session.deliveryUnknown ? "Delivery is unknown. Check the terminal; prompts are never resent." : ""
        context(session)
        if !sendAgent(AgentChatWire(op: "open", conversationId: session.conversationId,
                                   agentId: session.agentId, before: before), session.route) {
            block(session, "The agent connection changed. Reopen it from Astation.")
        }
    }

    private func submit(_ body: [String: Any], session: Session) {
        if let id = body["requestId"] as? String, session.requestIds.contains(id) { context(session); return }
        guard session.capable, !session.blocked, !session.closed, !session.deliveryUnknown,
              session.openingAt == nil, isCurrent(session), let generation = session.generation,
              session.activity?.state == "ready", let activityAt = session.activityAt,
              now().timeIntervalSince(activityAt) <= 30,
              session.pendingRequest == nil, let requestId = body["requestId"] as? String,
              session.requestIds.count < 256, UUID(uuidString: requestId) != nil,
              let text = body["text"] as? String, Self.validPrompt(text) else {
            emit(session, ["op": "notice", "text": "This prompt was not sent. Wait for Ready or check the terminal.",
                           "requestId": body["requestId"] as? String ?? "", "delivery": "failed"])
            return
        }
        session.pendingRequest = requestId
        session.requestIds.insert(requestId)
        session.pendingAt = now()
        session.accepted = false
        session.notice = ""
        if !sendAgent(AgentChatWire(op: "submit", conversationId: session.conversationId,
                agentId: session.agentId, generation: generation, requestId: requestId, text: text), session.route) {
            block(session, "The connection changed. Delivery is unknown; the prompt will not be resent.")
        }
    }

    static func validPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.utf8.count <= 32_768
            && trimmed.first != "/" && trimmed.first != "!"
            && !text.unicodeScalars.contains {
                ($0.value < 32 && $0.value != 9 && $0.value != 10) || (127...159).contains($0.value)
            }
    }

    func receiveAgent(_ event: AgentChatWire, from source: RemoteTerminalConnection) {
        guard event.v == 1, let session = sessions.values.first(where: {
            $0.conversationId == event.conversationId && $0.agentId == event.agentId && $0.route == source
        }), now() < session.expiresAt, session.capable, !session.blocked, isCurrent(session),
              let encoded = try? JSONEncoder().encode(event), encoded.count <= 1_048_576,
              (event.text?.utf8.count ?? 0) <= 131_072 else { return }
        if event.op == "close", event.generation == nil, event.sequence == nil {
            session.closed = true
            session.openingAt = nil
            session.activity = nil
            if session.pendingRequest != nil, !session.accepted { session.deliveryUnknown = true }
            forward(event, session)
            if session.notice.isEmpty { session.notice = "The host closed this conversation. Reopen the view to load history." }
            context(session)
            return
        }
        if event.op == "error", event.generation == nil, event.sequence == nil,
           session.openingAt != nil, event.text != nil {
            session.notice = event.text ?? "Chat is unavailable."
            session.openingAt = nil
            session.closed = true
            forward(event, session)
            context(session)
            return
        }
        guard let sequence = event.sequence, sequence <= 9_007_199_254_740_991 else { return }
        if event.op == "opened" {
            guard session.openingAt != nil, sequence == 0, Self.identifier(event.generation),
                  let status = event.status, status.isValid else { return }
            if let pinned = session.generation, event.generation != pinned {
                block(session, "The agent process changed. Open a new browser session from Astation.")
                return
            }
            session.generation = event.generation
            session.hostSequence = 0
            session.openingAt = nil
            session.closed = false
            session.activity = status
            session.activityAt = now()
            // Ready after reopen permits new work only when earlier delivery was confirmed.
            if status.state == "ready", session.accepted {
                session.pendingRequest = nil
                session.pendingAt = nil
                session.deliveryUnknown = false
            }
        } else {
            guard !session.closed, session.openingAt == nil else { return }
            guard event.generation == session.generation else {
                block(session, "The agent process changed. Open a new browser session from Astation.")
                return
            }
            guard sequence > session.hostSequence else { return }
            guard sequence == session.hostSequence + 1 else {
                session.notice = "Conversation events are missing. Reopen the view; prompts will not be resent."
                session.closed = true
                if session.pendingRequest != nil, !session.accepted { session.deliveryUnknown = true }
                context(session)
                return
            }
            guard validate(event, session: session) else {
                block(session, "The agent sent an invalid conversation event. Use Open Terminal or reopen from Astation.")
                return
            }
            session.hostSequence = sequence
            if event.op == "status", let since = event.since {
                session.activity = AgentChatStatus(state: event.state ?? "unknown", since: since, detail: event.detail)
                session.activityAt = now()
            }
            if event.op == "error" { session.notice = event.text ?? "" }
            if event.requestId == session.pendingRequest, session.pendingRequest != nil {
                if event.op == "accepted" || (event.op == "message" && event.history == true && event.role == "user" && event.origin == "remote") {
                    session.accepted = true
                    session.deliveryUnknown = false
                    session.notice = ""
                    if event.history == true, session.activity?.state == "ready" { session.pendingRequest = nil; session.pendingAt = nil }
                }
                if event.op == "complete" || event.op == "error" {
                    if event.op == "error", event.text?.localizedCaseInsensitiveContains("delivery unknown") == true {
                        session.deliveryUnknown = true
                    } else {
                        session.pendingRequest = nil
                        session.pendingAt = nil
                        session.deliveryUnknown = false
                    }
                }
            }
        }
        forward(event, session)
        context(session)
    }

    private static func identifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.utf8.count <= 128
    }

    private func validate(_ event: AgentChatWire, session: Session) -> Bool {
        if let requestId = event.requestId, !Self.identifier(requestId) { return false }
        switch event.op {
        case "accepted": return Self.identifier(event.requestId)
        case "complete": return Self.identifier(event.turnId) && ["done", "interrupted"].contains(event.outcome ?? "")
        case "status":
            guard let since = event.since else { return false }
            return AgentChatStatus(state: event.state ?? "", since: since, detail: event.detail).isValid
        case "error": return event.text != nil
        case "message", "delta":
            guard Self.identifier(event.messageId), let id = event.messageId else { return false }
            let previous = session.messages[id]
            var message = event
            if event.op == "delta" {
                guard let old = previous, let part = event.part, part.isValid else { return false }
                message = old
                if !(old.parts ?? []).contains(where: { $0.id == part.id }) { message.parts?.append(part) }
            } else {
                guard ["user", "assistant"].contains(event.role ?? ""), Self.identifier(event.turnId),
                      event.createdAt?.date != nil, event.role != "user" || ["local", "remote"].contains(event.origin ?? ""),
                      previous == nil || (previous?.role == event.role && previous?.turnId == event.turnId) else { return false }
            }
            guard let parts = message.parts, parts.count <= 4096, parts.allSatisfy({ $0.isValid }),
                  Set(parts.map(\.id)).count == parts.count else { return false }
            let size = parts.reduce(0) { $0 + $1.contentBytes }
            let oldSize = previous?.parts?.reduce(0) { $0 + $1.contentBytes } ?? 0
            let oldSerializedSize = session.messageSizes[id] ?? 0
            guard size <= 131_072, session.transcriptBytes - oldSize + size <= 8_388_608,
                  previous != nil || session.messages.count < 512,
                  let encoded = try? JSONEncoder().encode(message), encoded.count <= 1_048_576,
                  session.serializedBytes - oldSerializedSize + encoded.count <= 16_777_216 else { return false }
            session.messages[id] = message
            session.transcriptBytes += size - oldSize
            session.serializedBytes += encoded.count - oldSerializedSize
            session.messageSizes[id] = encoded.count
            return true
        default: return true
        }
    }

    func tick() {
        for session in Array(sessions.values) {
            if now() >= session.expiresAt {
                block(session, "This browser session expired. Open a new session from Astation.")
                sessions.removeValue(forKey: session.id)
            } else if !session.blocked {
                if !isCurrent(session) {
                    block(session, "The authenticated agent connection changed. Reopen the agent from Astation.")
                } else if let at = session.pendingAt, !session.accepted, !session.deliveryUnknown,
                          now().timeIntervalSince(at) > 12 {
                    session.deliveryUnknown = true
                    session.notice = "Delivery is unknown. Check the terminal; this prompt will not be resent."
                    emit(session, ["op": "notice", "text": session.notice, "blocked": true,
                                   "requestId": session.pendingRequest ?? "", "delivery": "unknown"])
                    context(session)
                } else if let at = session.openingAt, now().timeIntervalSince(at) > 10 {
                    session.openingAt = nil
                    session.notice = "The agent did not open the conversation. Use Open Terminal or update Atem."
                    context(session)
                }
            }
        }
    }

    func invalidateAll() {
        for session in sessions.values { block(session, "Astation disconnected. Open a new browser session after it reconnects.") }
        sessions.removeAll()
    }

    private func isCurrent(_ session: Session) -> Bool { currentRoute(session.route.clientId) == session.route }

    private func closeHost(_ session: Session) {
        guard !session.conversationId.isEmpty, isCurrent(session) else { return }
        _ = sendAgent(AgentChatWire(op: "close", conversationId: session.conversationId, agentId: session.agentId), session.route)
    }

    private func block(_ session: Session, _ reason: String) {
        closeHost(session)
        session.blocked = true
        session.notice = reason
        emit(session, ["op": "notice", "text": reason, "blocked": true,
                       "requestId": session.pendingRequest ?? "", "delivery": session.accepted ? "delivered" : "unknown"])
        context(session)
    }

    private func context(_ session: Session) {
        let connected = !session.blocked && isCurrent(session)
        let reason = session.notice.isEmpty && !session.capable
            ? "Chat requires an updated Atem and a supported agent with active hooks. Use Open Terminal for this agent."
            : session.notice
        let object: [String: Any] = ["op": "context", "agentName": session.agentName, "hostname": session.hostname,
            "agentId": session.agentId, "conversationId": session.conversationId,
            "connected": connected, "supported": session.capable,
            "enabled": connected && session.capable && !session.closed && !session.deliveryUnknown,
            "closed": session.closed,
            "opening": session.openingAt != nil, "canReopen": connected && session.capable && session.openingAt == nil,
            "notice": reason, "pending": session.pendingRequest != nil, "pendingRequestId": session.pendingRequest ?? "",
            "before": session.before ?? "", "deliveryUnknown": session.deliveryUnknown]
        emit(session, object)
    }

    private func forward(_ event: AgentChatWire, _ session: Session) {
        guard let data = try? JSONEncoder().encode(event), let object = try? JSONSerialization.jsonObject(with: data) else { return }
        emit(session, ["op": "event", "event": object])
    }

    private func emit(_ session: Session, _ object: [String: Any]) {
        guard let route = session.browser, session.sent < 9_007_199_254_740_991 else { return }
        session.sent += 1
        guard let frame = BrowserChatFrame.response(key: session.key, sessionId: session.id, nonce: session.nonce,
                                                    sequence: session.sent, object: object) else { return }
        sendBrowser(frame, route)
    }
}
