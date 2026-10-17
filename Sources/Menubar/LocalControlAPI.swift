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
        let message: String?
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
                    return .json(["api": "v1", "session_contract": "r7", "account_wide_access": "gated",
                                  "host_push_ingress": "gated"])
                case "/api/v1/sessions":
                    let sessions = clients().sorted { $0.key < $1.key }.flatMap { id, client -> [Session] in
                        let descriptors = client.registry.values.sorted { $0.session_id < $1.session_id }
                        if descriptors.isEmpty {
                            return [Session(client_id: id, phase: String(describing: client.phase), status: client.status,
                                            target: nil, descriptor: nil, controls: false)]
                        }
                        return descriptors.map {
                            let target = client.target(sessionId: $0.session_id, process: $0.process_gen)
                            return Session(client_id: id, phase: String(describing: client.phase), status: client.status,
                                           target: target, descriptor: $0, controls: target.map(client.controls) ?? false)
                        }
                    }
                    return .json(sessions)
                case "/api/v1/approvals":
                    return .json(inbox.entries.map {
                        Approval(client_id: $0.sourceID, target: $0.target, request: $0.request, provider: $0.provider,
                                 host: $0.host, can_answer: $0.canAnswer, status: $0.status, resolution: $0.resolution)
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
            guard ["/api/v1/sessions/acquire", "/api/v1/sessions/release", "/api/v1/sessions/submit",
                   "/api/v1/approvals/answer"].contains(path) else { return .error("not_found", status: .notFound) }
            let operation = try JSONDecoder().decode(Operation.self, from: body)
            guard operation.target.valid else { throw AtemSessionJSON.Invalid.json }
            guard let client = clients()[operation.client_id],
                  client.target(sessionId: operation.target.session_id, process: operation.target.process_gen) == operation.target else {
                return .error("stale_target", status: .conflict)
            }
            switch path {
            case "/api/v1/sessions/acquire":
                guard client.welcome?.permissions?.contains("control") == true else { return .error("forbidden", status: .forbidden) }
                client.acquire(operation.target, takeover: operation.takeover ?? false)
                return .json(["status": client.controls(operation.target) ? "held" : "requested"], status: .accepted)
            case "/api/v1/sessions/release":
                client.release(operation.target)
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
                _ = try AtemApprovalAnswer.validate(payload)
            } else {
                guard let requestedKind = operation.kind, ["prompt", "interrupt", "stop"].contains(requestedKind),
                      requestedKind == "prompt" || operation.text == nil else { throw AtemSessionJSON.Invalid.json }
                kind = requestedKind
                payload = kind == "prompt" ? .object(["text": .string(operation.text ?? "")]) : .object([:])
            }
            let digest = try payload.digest()
            if let previous = records().first(where: { $0.requestId == requestID }) {
                guard previous.target == operation.target, previous.kind == kind, previous.digest == digest else {
                    return .error("request_id_reused", status: .conflict)
                }
                return .json(["request_id": requestID, "status": "journaled"], status: .accepted)
            }
            let submitted: String?
            if kind == "approval", let approval = operation.approval,
               let entry = inbox.entries.first(where: { $0.sourceID == operation.client_id && $0.target == operation.target
                   && $0.request == approval && $0.canAnswer }) {
                submitted = entry.client.answerApproval(approval, decision: AtemApprovalAnswer.Decision(rawValue: operation.decision!)!,
                    ruleID: operation.rule?.rule_id, message: operation.message, requestID: requestID)
            } else if kind != "approval" {
                submitted = client.submit(operation.target, kind: kind, text: operation.text, requestID: requestID)
            } else { submitted = nil }
            guard let submitted else { return .error("not_actionable", status: .conflict) }
            return .json(["request_id": submitted, "status": "journaled"], status: .accepted)
        } catch { return .error("invalid_request", status: .badRequest) }
    }
}
