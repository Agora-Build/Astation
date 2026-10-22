import CryptoKit
import Darwin
import Foundation
import NIOHTTP1

struct LocalAPIResponse {
    let status: HTTPResponseStatus
    let body: Data

    static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> Self {
        Self(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ code: String, status: HTTPResponseStatus) -> Self {
        .json(["error": code], status: status)
    }
}

/// Explicit same-user automation authority. This never authenticates a device
/// to Atem or substitutes for the session client's verification and lease checks.
struct LocalAPIKey {
    private let digest: Data

    init(file: String) throws {
        let descriptor = Darwin.open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_size == 64 || info.st_size == 65 else { throw POSIXError(.EACCES) }
        var bytes = [UInt8](repeating: 0, count: 66)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count == Int(info.st_size) else { throw POSIXError(.EIO) }
        if count == 65 { guard bytes[64] == 10 else { throw POSIXError(.EINVAL) } }
        let token = Data(bytes.prefix(64))
        guard token.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw POSIXError(.EINVAL) }
        digest = Data(SHA256.hash(data: token))
    }

    func authorizes(_ request: HTTPRequestHead, peerAddress: String?) -> Bool {
        guard DirectConnectionScope(peerAddress: peerAddress) == .loopback,
              request.headers["origin"].isEmpty, request.headers["authorization"].count == 1,
              let value = request.headers["authorization"].first, value.hasPrefix("Bearer "),
              value.utf8.count == 71 else { return false }
        let candidate = Data(SHA256.hash(data: Data(value.dropFirst(7).utf8)))
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

final class LocalControlAPI {
    static let maximumBody = 65_536
    let key: LocalAPIKey
    private let clients: () -> [String: AtemSessionClient]
    private let inbox: ApprovalInbox
    private let records: () -> [AtemSessionRequestRecord]

    init(key: LocalAPIKey, clients: @escaping () -> [String: AtemSessionClient], inbox: ApprovalInbox,
         records: @escaping () -> [AtemSessionRequestRecord]) {
        self.key = key
        self.clients = clients
        self.inbox = inbox
        self.records = records
    }

    private struct Session: Encodable {
        let client_id: String
        let phase: String
        let status: String
        let target: AtemSessionTarget?
        let descriptor: AtemSessionDescriptor?
        let controls: Bool
        let control_owner: String?
        let features: [String]
    }
    private struct Approval: Encodable {
        let client_id: String
        let target: AtemSessionTarget
        let request: AtemApprovalRequest
        let provider: String
        let host: String
        let can_answer: Bool
        let status: String
        let resolution: String?
    }
    private struct Rule: Encodable {
        let client_id: String
        let target: AtemSessionTarget
        let rule: AtemApprovalRule
        let provider: String
        let host: String
        let can_revoke: Bool
        let controls: Bool
        let status: String
    }
    private struct Activity: Encodable {
        let client_id: String
        let target: AtemSessionTarget
        let message_id: String
        let created_at: Double
        let part: AgentChatPart
    }
    private struct Operation: Decodable {
        let client_id: String
        let target: AtemSessionTarget
        let request_id: String?
        let kind: String?
        let text: String?
        let takeover: Bool?
        let approval: AtemApprovalRequest?
        let decision: String?
        let rule: AtemApprovalRule?
        let rule_id: String?
        let message: String?
        let operator_id: String?
        let expected_controller: AtemSessionController?
        let before: String?
        let next: String?
        let turn_id: String?
        let page_id: String?
    }
    private struct ReceiptQuery: Decodable {
        let target: AtemSessionTarget
        let request_id: String
    }

    /// HTTP admission happens before dispatch. Everything here runs serially
    /// with native UI actions and rechecks current authority at the side effect.
    func handle(method: HTTPMethod, path: String, body: Data) -> LocalAPIResponse {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if method == .GET {
                guard body.isEmpty else { return .error("invalid_request", status: .badRequest) }
                switch path {
                case "/api/v1/status":
                    return .json(["api": "v1", "session_contract": "r9", "account_wide_access": "gated",
                                  "host_push_ingress": "gated", "rule_revocation": "lease_free",
                                  "approval_answers": "lease_free", "atomic_chat_send": "supported",
                                  "chat_history": "ordered_pages", "api_lease_renewal": "explicit_every_5s",
                                  "atem_upgrade_required": clients().values.contains(where: \.unsupportedVersion) ? "true" : "false"])
                case "/api/v1/sessions":
                    let sessions = clients().sorted { $0.key < $1.key }.flatMap { id, client -> [Session] in
                        guard !client.unsupportedVersion else { return [] }
                        let descriptors = client.registry.values.sorted { $0.session_id < $1.session_id }
                        if descriptors.isEmpty {
                            return [Session(client_id: id, phase: String(describing: client.phase), status: client.status,
                                            target: nil, descriptor: nil, controls: false, control_owner: nil,
                                            features: client.features.sorted())]
                        }
                        return descriptors.map {
                            let target = client.target(sessionId: $0.session_id, process: $0.process_gen)
                            return Session(client_id: id, phase: String(describing: client.phase), status: client.status,
                                           target: target, descriptor: $0, controls: target.flatMap { client.controlOwner(for: $0) } != nil,
                                           control_owner: target.flatMap { client.controlOwner(for: $0) }, features: client.features.sorted())
                        }
                    }
                    return .json(sessions)
                case "/api/v1/approvals":
                    return .json(inbox.entries.map {
                        Approval(client_id: $0.sourceID, target: $0.target, request: $0.request, provider: $0.provider,
                                 host: $0.host, can_answer: $0.canAnswer, status: $0.status, resolution: $0.resolution)
                    })
                case "/api/v1/approval-rules":
                    return .json(inbox.rules.filter { $0.client.hasRule($0.rule, target: $0.target) }.map {
                        Rule(client_id: $0.sourceID, target: $0.target, rule: $0.rule, provider: $0.provider,
                            host: $0.host, can_revoke: $0.client.canRevoke($0.rule, target: $0.target),
                            controls: $0.client.controls($0.target), status: $0.status)
                    })
                case "/api/v1/approval-activity":
                    return .json(clients().sorted { $0.key < $1.key }.flatMap { id, client in
                        client.approvalActivities.map { Activity(client_id: id, target: $0.target,
                            message_id: $0.messageID, created_at: $0.createdAt.timeIntervalSince1970 * 1000, part: $0.part) }
                    })
                default: return .error("not_found", status: .notFound)
                }
            }
            guard method == .POST else { return .error("method_not_allowed", status: .methodNotAllowed) }
            _ = try AtemSessionJSON.parse(body, limit: Self.maximumBody)
            if path == "/api/v1/receipts/query" {
                let query = try JSONDecoder().decode(ReceiptQuery.self, from: body)
                guard query.target.valid, AtemSessionWire.uuid(query.request_id) else { throw AtemSessionJSON.Invalid.json }
                guard let record = records().first(where: { $0.requestId == query.request_id && $0.target == query.target }) else {
                    return .error("unknown_request", status: .notFound)
                }
                return .json(record)
            }
            guard ["/api/v1/sessions/acquire", "/api/v1/sessions/renew", "/api/v1/sessions/release", "/api/v1/sessions/submit",
                   "/api/v1/chat/read", "/api/v1/chat/history", "/api/v1/chat/page",
                   "/api/v1/approvals/answer", "/api/v1/approval-rules/revoke"].contains(path) else { return .error("not_found", status: .notFound) }
            let operation = try JSONDecoder().decode(Operation.self, from: body)
            guard operation.target.valid, operation.operator_id.map(AtemSessionWire.opaque) != false,
                  operation.expected_controller?.valid != false else { throw AtemSessionJSON.Invalid.json }
            let owner = "api:" + (operation.operator_id ?? "local-api")
            guard let client = clients()[operation.client_id],
                  client.target(sessionId: operation.target.session_id, process: operation.target.process_gen) == operation.target else {
                return .error("stale_target", status: .conflict)
            }
            switch path {
            case "/api/v1/chat/read":
                guard let snapshot = client.readChat(operation.target) else { return .error("chat_unavailable", status: .conflict) }
                return .json(snapshot)
            case "/api/v1/chat/history":
                guard let pageID = client.chatHistory(operation.target, before: operation.before, next: operation.next,
                    turn: operation.turn_id, request: operation.request_id) else { return .error("history_unavailable", status: .conflict) }
                return .json(["page_id": pageID, "status": "requested"], status: .accepted)
            case "/api/v1/chat/page":
                guard let pageID = operation.page_id, AtemSessionWire.opaque(pageID),
                      let reply = client.chatPage(operation.target, pageID: pageID) else { return .error("unknown_page", status: .notFound) }
                return .json(reply)
            case "/api/v1/sessions/acquire":
                guard client.welcome?.permissions?.contains("control") == true else { return .error("forbidden", status: .forbidden) }
                guard client.acquire(operation.target, takeover: operation.takeover ?? false, owner: owner) else {
                    return .error("control_not_available", status: .conflict)
                }
                return .json(["status": client.controlOwner(for: operation.target) == owner ? "held" : "requested"], status: .accepted)
            case "/api/v1/sessions/renew":
                guard client.renew(operation.target, owner: owner) else { return .error("stale_lease", status: .conflict) }
                return .json(["status": "requested"], status: .accepted)
            case "/api/v1/sessions/release":
                guard client.controlOwner(for: operation.target).map({ $0 == owner }) != false else {
                    return .error("control_not_owned", status: .conflict)
                }
                client.release(operation.target, owner: owner)
                return .json(["status": "released"])
            default: break
            }
            guard let requestID = operation.request_id, AtemSessionWire.uuid(requestID) else { throw AtemSessionJSON.Invalid.json }
            let kind: String
            let payload: AtemSessionJSON
            if path == "/api/v1/approvals/answer" {
                guard let approval = operation.approval, approval.valid,
                      approval.session_id == operation.target.session_id, approval.process_gen == operation.target.process_gen,
                      let raw = operation.decision, let decision = AtemApprovalAnswer.Decision(rawValue: raw) else {
                    throw AtemSessionJSON.Invalid.json
                }
                if decision == .allowAlways {
                    guard let rule = operation.rule, approval.always_rules.contains(rule) else { throw AtemSessionJSON.Invalid.json }
                } else if operation.rule != nil { throw AtemSessionJSON.Invalid.json }
                kind = "approval"
                payload = AtemApprovalAnswer(approvalID: approval.approval_id, decision: decision,
                    ruleID: operation.rule?.rule_id, message: operation.message).payload
                try AtemApprovalAnswer.validate(payload)
            } else if path == "/api/v1/approval-rules/revoke" {
                guard let ruleID = operation.rule_id, AtemSessionWire.opaque(ruleID) else { throw AtemSessionJSON.Invalid.json }
                kind = "approval_rule_revoke"
                payload = .object(["rule_id": .string(ruleID)])
            } else {
                guard let requestedKind = operation.kind, ["prompt", "interrupt", "stop"].contains(requestedKind),
                      requestedKind == "prompt" || operation.text == nil else { throw AtemSessionJSON.Invalid.json }
                kind = requestedKind
                payload = kind == "prompt" ? .object(["text": .string(operation.text ?? "")]) : .object([:])
            }
            let digest = try payload.digest()
            guard operation.expected_controller == nil || (kind == "prompt" && operation.takeover == true),
                  operation.takeover != true || (kind == "prompt" && operation.expected_controller != nil) else {
                throw AtemSessionJSON.Invalid.json
            }
            if let previous = records().first(where: { $0.requestId == requestID }) {
                guard previous.target == operation.target, previous.kind == kind, previous.digest == digest else {
                    return .error("request_id_reused", status: .conflict)
                }
                if previous.receipt != nil || previous.refusal?.code != "lease_held" || operation.takeover != true {
                    return .json(["request_id": requestID, "status": "journaled"], status: .accepted)
                }
                guard operation.expected_controller == previous.refusal?.controller else {
                    return .error("stale_confirmation", status: .conflict)
                }
            }
            let submitted: String?
            if kind == "approval", let approval = operation.approval,
               let entry = inbox.entries.first(where: { $0.sourceID == operation.client_id && $0.target == operation.target
                   && $0.request == approval && $0.canAnswer }) {
                submitted = entry.client.answerApproval(approval, decision: AtemApprovalAnswer.Decision(rawValue: operation.decision!)!,
                    ruleID: operation.rule?.rule_id, message: operation.message, requestID: requestID)
            } else if kind == "approval_rule_revoke", let rule = client.approvalRules[operation.target.session_id]?.first(where: {
                $0.rule_id == operation.rule_id
            }) {
                submitted = client.revokeRule(rule, target: operation.target, requestID: requestID)
            } else if kind != "approval" && kind != "approval_rule_revoke" {
                submitted = client.submit(operation.target, kind: kind, text: operation.text, requestID: requestID,
                    takeover: operation.expected_controller, owner: owner)
            } else { submitted = nil }
            guard let submitted else { return .error("not_actionable", status: .conflict) }
            return .json(["request_id": submitted, "status": "journaled"], status: .accepted)
        } catch { return .error("invalid_request", status: .badRequest) }
    }
}
