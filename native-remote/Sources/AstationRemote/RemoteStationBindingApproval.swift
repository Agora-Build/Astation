import AtemClient
import Foundation

public struct RemoteStationBindingReceipt: Codable, Equatable, Sendable {
    public let account: String
    public let accountId: String
    public let genesisHash: String
    public let bindingId: String
    public let version: UInt64
    public let bindingState: String

    public var ownership: ExpectedBinding {
        if bindingState == "unbound" { return .unbound(bindingId: bindingId, version: version, owner: account) }
        return .bound(bindingId: bindingId, version: version, owner: account)
    }
}

public enum RemoteStationBindingError: LocalizedError {
    case expiredWithoutCommit, consentExpired, awaitingReceipt
    public var errorDescription: String? {
        switch self {
        case .expiredWithoutCommit: return "The previous approval expired before Station applied it. Review the ownership change again."
        case .consentExpired: return "This ownership request expired. Ask the manager to start a new request."
        case .awaitingReceipt: return "Station has not confirmed the outcome. Check the previous request again."
        }
    }
}

/// The account session and expected ownership come from the caller before the
/// request. An echoed Station challenge cannot supply either of them.
@MainActor
public struct RemoteStationBindingApproval {
    public struct Review {
        public let action: BindingAction
        public let origin: String
        public let accountID: String
        public let subject: String
        public let previous: ExpectedBinding

        public var confirmation: String {
            let operation: String
            switch (action, previous) {
            case (.transfer, .bound(_, _, let owner)):
                operation = "Transfer " + accountID + " from Agora.Build account " + owner + " to " + subject + "?"
            case (.unbind, _):
                operation = "Unbind " + accountID + " from Agora.Build account " + subject + "?"
            default:
                operation = "Bind " + accountID + " to Agora.Build account " + subject + "?"
            }
            return operation + " This decides which Agora.Build account's state controls whether " + origin + " serves this account's hosts."
        }
    }

    /// Only the confirmed flow can hand this request to the manager key.
    @MainActor
    public final class ApprovedKeyRequest {
        private var request: SignRequest?
        fileprivate init(_ request: SignRequest) { self.request = request }

        public func consume() throws -> SignRequest {
            guard let request else { throw RemoteRecoveryError.confirmationRequired }
            self.request = nil
            return request
        }

        fileprivate func invalidate() { request = nil }
    }

    private let origin: String
    private let http: AccountOIDCHTTP

    public init(origin: String, http: AccountOIDCHTTP = AccountURLSessionHTTP(maximumResponseBytes: 8192)) throws {
        guard ["https://station-dev.agora.build", "https://station.agora.build"].contains(origin) else {
            throw AccountLoginError.configuration
        }
        self.origin = origin
        self.http = http
    }

    public func prove(action: BindingAction, previous: ExpectedBinding, session: AccountLoginSession,
        managerID: String, membership: () throws -> MembershipLog, now: () -> UInt64,
        current: () -> Bool, confirm: (Review) async -> Bool,
        sign: (ApprovedKeyRequest, PublicKeyData) throws -> Data) async throws -> String {
        let manager = "member:" + managerID
        let config = session.configuration
        guard session.expiresAt.timeIntervalSince1970 * 1000 > Double(now()),
              config.resource == origin, config.clientID == "astation", config.apiScopes.contains("astation.remote"),
              !session.accessToken.isEmpty, let seconds = session.authenticatedAt, seconds >= 0 else {
            throw AccountLoginError.freshProofUnavailable
        }
        guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
        let log = try membership()
        let anchor = try RemoteVerifierReportAnchor(log: log)
        let head = log.head()
        let claims = AuthClaims(issuer: config.issuer, subject: session.subject, authTime: UInt64(seconds))
        let review = Review(action: action, origin: origin, accountID: anchor.accountID, subject: claims.subject, previous: previous)
        let url = URL(string: origin + "/agora-build/v1/logs/" + anchor.genesisHash + "/binding/challenge")!
        var call = URLRequest(url: url)
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        call.httpBody = try JSONSerialization.data(withJSONObject: ["action": Self.wire(action),
            "account_id": anchor.accountID, "head": ["seq": head.seq, "hash": head.hash] as [String: Any],
            "signer": manager, "expected_binding": Self.wire(previous)])
        let (bytes, status) = try await http.send(call)
        guard status == 200 else { throw Self.error(for: status) }
        guard bytes.count <= 4096, let wire = String(data: bytes, encoding: .utf8) else {
            throw AccountLoginError.invalidResponse
        }
        let challenge = try parseStationBindingChallenge(challengeJson: wire)
        guard challenge.action == action, challenge.expectedBinding == previous, challenge.head == head else {
            throw AccountLoginError.changed
        }
        func checkedRequest() throws -> (StationBindingRequest, MembershipLog, PublicKeyData) {
            let clock = now()
            guard current(), !Task.isCancelled, clock >= challenge.issuedAt, clock < challenge.expiresAt,
                  session.expiresAt.timeIntervalSince1970 * 1000 > Double(clock) else { throw AccountLoginError.changed }
            let latest = try membership()
            try anchor.require(latest)
            guard latest.head() == head, let key = latest.member(deviceId: managerID)?.authKey else {
                throw AccountLoginError.changed
            }
            return (try StationBindingRequest(log: latest, challengeJson: wire, signer: manager, origin: origin,
                expected: claims, keyId: managerID, nowMs: clock), latest, key)
        }
        let (held, _, key) = try checkedRequest()
        guard await confirm(review) else { throw RemoteRecoveryError.confirmationRequired }
        let (checked, _, currentKey) = try checkedRequest()
        guard key == currentKey, checked.signRequest() == held.signRequest() else { throw AccountLoginError.changed }
        let approved = ApprovedKeyRequest(held.signRequest())
        defer { approved.invalidate() }
        let signature = try sign(approved, key)
        let proof = try held.finish(signature: signature)
        let (_, latest, _) = try checkedRequest()
        guard try verifyStationBinding(log: latest, proofJson: proof, expectedChallengeJson: wire, nowMs: now()).atHead else {
            throw AccountLoginError.changed
        }
        return proof
    }

    public enum ConsentOutcome { case noRequest, cancelled, recorded }

    public func reviewConsent(session: AccountLoginSession, now: () -> UInt64, current: () -> Bool,
                              confirm: (StationBindingChallenge) async -> Bool) async throws -> ConsentOutcome {
        func checkLogin() throws {
            let clock = now()
            guard current(), !Task.isCancelled, session.configuration.resource == origin,
                  session.configuration.clientID == "astation", session.configuration.apiScopes.contains("astation.remote"),
                  !session.accessToken.isEmpty, !session.subject.isEmpty, let authTime = session.authenticatedAt,
                  let seconds = UInt64(exactly: authTime), seconds <= clock / 1000,
                  session.expiresAt.timeIntervalSince1970 * 1000 > Double(clock) else { throw AccountLoginError.changed }
        }
        try checkLogin()
        var call = URLRequest(url: URL(string: origin + "/agora-build/v1/binding/consent-request")!)
        call.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let (data, status) = try await http.send(call)
        try checkLogin()
        guard status == 200 else { throw Self.error(for: status) }
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8)) as? [String: Any],
              envelope.count == 1, let request = envelope["request"] else { throw AccountLoginError.invalidResponse }
        if request is NSNull { return .noRequest }
        guard let object = request as? [String: Any] else { throw AccountLoginError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: object)
        let challenge = try parseStationBindingChallenge(challengeJson: String(decoding: body, as: UTF8.self))
        guard challenge.origin == origin, challenge.issuer == session.configuration.issuer,
              challenge.subject != session.subject else { throw AccountLoginError.changed }
        switch (challenge.action, challenge.expectedBinding) {
        case (.bind, .neverBound): break
        case let (.transfer, .bound(_, _, owner)) where owner == session.subject: break
        default: throw AccountLoginError.changed
        }
        func checkReview() throws {
            try checkLogin()
            let clock = now()
            guard clock >= challenge.issuedAt, clock < challenge.expiresAt else { throw RemoteStationBindingError.consentExpired }
        }
        try checkReview()
        guard await confirm(challenge) else { return .cancelled }
        try checkReview()
        call.url = URL(string: origin + "/agora-build/v1/logs/" + challenge.genesisHash + "/binding/transfer-consent")!
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = body
        let (reply, code) = try await http.send(call)
        try checkLogin()
        guard code == 200 else { throw Self.error(for: code) }
        guard reply.count <= 4096,
              try canonicalJson(json: String(decoding: reply, as: UTF8.self)) == #"{"consented":true}"# else {
            throw AccountLoginError.invalidResponse
        }
        return .recorded
    }

    private static func error(for status: Int) -> AccountLoginError {
        if status == 401 { return .signInRequired }
        if [403, 404, 409].contains(status) { return .changed }
        return .unavailable
    }

    /// Retry a protected, previously approved proof verbatim. The Station can return
    /// its durable receipt even after the challenge expires if the first request committed.
    public func submit(proof: String, session: AccountLoginSession, accountID: String, genesisHash: String, retry: Bool,
                       now: () -> UInt64, current: () -> Bool,
                       awaitingConsent: () -> Void = {}) async throws -> RemoteStationBindingReceipt {
        guard proof.utf8.count <= 16_384, current(), !Task.isCancelled,
              session.configuration.resource == origin, session.configuration.clientID == "astation",
              session.configuration.apiScopes.contains("astation.remote"), !session.accessToken.isEmpty,
              session.expiresAt.timeIntervalSince1970 * 1000 > Double(now()) else { throw AccountLoginError.changed }
        let object = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: proof).utf8)) as? [String: Any]
        guard let body = object?["body"] as? [String: Any] else { throw AccountLoginError.invalidResponse }
        let bytes = try JSONSerialization.data(withJSONObject: body)
        let challenge = try parseStationBindingChallenge(challengeJson: String(decoding: bytes, as: UTF8.self))
        guard challenge.origin == origin, challenge.issuer == session.configuration.issuer,
              challenge.subject == session.subject,
              challenge.accountId == accountID, challenge.genesisHash == genesisHash else { throw AccountLoginError.changed }
        let base = URL(string: origin + "/agora-build/v1/logs/" + genesisHash + "/binding/")!
        var call = URLRequest(url: base.appendingPathComponent(retry ? "receipt" : "commit"))
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        call.httpBody = Data(proof.utf8)
        func originalSession() -> Bool {
            guard let authTime = session.authenticatedAt else { return false }
            return UInt64(exactly: authTime) == challenge.authTime
        }
        guard retry || originalSession() else { throw AccountLoginError.changed }
        var inspecting = retry
        var reportedWait = false
        let data: Data
        while true {
            let clock = now()
            guard current(), !Task.isCancelled, session.expiresAt.timeIntervalSince1970 * 1000 > Double(clock) else {
                throw AccountLoginError.changed
            }
            if clock >= challenge.expiresAt { inspecting = true }
            call.url = base.appendingPathComponent(inspecting ? "receipt" : "commit")
            let (reply, status) = try await http.send(call)
            guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
            if status == 200 { data = reply; break }
            if inspecting && status == 410 && (try? canonicalJson(json: String(decoding: reply, as: UTF8.self))) == #"{"error":{"code":"binding_proof_expired"}}"# {
                throw RemoteStationBindingError.expiredWithoutCommit
            }
            guard status == 202 else { throw Self.error(for: status) }
            let response = try canonicalJson(json: String(decoding: reply, as: UTF8.self))
            if inspecting {
                guard response == #"{"pending":true}"#, originalSession() else { throw AccountLoginError.changed }
                guard now() < challenge.expiresAt else { throw RemoteStationBindingError.awaitingReceipt }
                inspecting = false
            } else {
                guard response == #"{"awaiting_consent":true}"# else { throw AccountLoginError.invalidResponse }
                if !reportedWait { awaitingConsent(); reportedWait = true }
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else {
            throw AccountLoginError.invalidResponse
        }
        let canonical = Data(try canonicalJson(json: text).utf8)
        let receipt = try JSONDecoder().decode(RemoteStationBindingReceipt.self, from: canonical)
        let allowedID = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        guard try canonicalJson(json: String(decoding: JSONEncoder().encode(receipt), as: UTF8.self)) == String(decoding: canonical, as: UTF8.self),
              receipt.account == session.subject, receipt.accountId == accountID, receipt.genesisHash == genesisHash,
              (1...128).contains(receipt.bindingId.utf8.count),
              receipt.bindingId.unicodeScalars.allSatisfy(allowedID.contains),
              receipt.bindingState == (challenge.action == .unbind ? "unbound" : "bound") else {
            throw AccountLoginError.invalidResponse
        }
        switch challenge.expectedBinding {
        case .neverBound:
            guard receipt.version == 1 else { throw AccountLoginError.invalidResponse }
        case .bound(let id, let version, _), .unbound(let id, let version, _), .released(let id, let version, _):
            guard receipt.bindingId == id, version < 9_007_199_254_740_991, receipt.version == version + 1 else {
                throw AccountLoginError.invalidResponse
            }
        }
        return receipt
    }

    private static func wire(_ action: BindingAction) -> String {
        switch action {
        case .bind: return "bind"
        case .transfer: return "transfer"
        case .unbind: return "unbind"
        }
    }

    private static func wire(_ record: ExpectedBinding) -> [String: Any] {
        switch record {
        case .neverBound: return ["state": "never_bound"]
        case .bound(let id, let version, let owner): return ["state": "bound", "binding_id": id, "version": version, "owner": owner]
        case .unbound(let id, let version, let owner): return ["state": "unbound", "binding_id": id, "version": version, "owner": owner]
        case .released(let id, let version, let owner): return ["state": "released", "binding_id": id, "version": version, "owner": owner]
        }
    }
}
