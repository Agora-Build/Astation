import AtemClient
import Foundation

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

    public init(origin: String, http: AccountOIDCHTTP = AccountURLSessionHTTP(maximumResponseBytes: 4096)) throws {
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
        guard status == 200 else {
            if status == 401 { throw AccountLoginError.signInRequired }
            if [403, 404, 409].contains(status) { throw AccountLoginError.changed }
            throw AccountLoginError.unavailable
        }
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
