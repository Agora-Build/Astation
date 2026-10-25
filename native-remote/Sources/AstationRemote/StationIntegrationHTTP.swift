import AtemClient
import Foundation

/// The response is untrusted until RemoteServiceApproval verifies the body on
/// the native account's independently anchored membership log.
public struct StationServiceDraft: Decodable, Sendable {
    public let integrationId: String
    public let ownerAccount: String
    public let issuer: String
    public let stationOrigin: String
    public let genesisHash: String
    public let bodyJSON: String
    public let fingerprint: String
}

public struct StationIntegrationHTTP: Sendable {
    private let origin: String
    private let http: AccountOIDCHTTP
    private let accessToken: @Sendable () async throws -> String

    public init(origin: String, http: AccountOIDCHTTP = AccountURLSessionHTTP(),
        accessToken: @escaping @Sendable () async throws -> String) throws {
        guard PortalIntegrationRecord.validOrigin(origin) else { throw AccountLoginError.configuration }
        self.origin = origin; self.http = http; self.accessToken = accessToken
    }

    @MainActor
    public func prepare(record: PortalIntegrationRecord, ownerAccount: String, issuer: String,
        log: MembershipLog, managerID: String, hosts: [String], sessions: [String]?, projects: [String]?,
        signedAt: UInt64) async throws -> StationServiceDraft {
        guard record.stationOrigin == origin, record.role == "owner", record.state == "awaiting_approval",
              PortalIntegrationRecord.validID(record.id), !hosts.isEmpty,
              hosts.count <= 64, Set(hosts).count == hosts.count else { throw AccountLoginError.changed }
        var body: [String: Any] = ["genesisHash": log.genesisHash(), "managerId": managerID,
            "expectedHead": ["seq": log.head().seq, "hash": log.head().hash], "signedAt": signedAt, "hosts": hosts]
        if let sessions { body["sessions"] = sessions }
        if let projects { body["projects"] = projects }
        var request = URLRequest(url: URL(string: origin + "/agora-build/v1/integrations/\(record.id)/provision")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, code) = try await http.send(request)
        guard code == 200 else {
            if code == 401 { throw AccountLoginError.signInRequired }
            if [403, 404, 409].contains(code) { throw AccountLoginError.changed }
            throw AccountLoginError.unavailable
        }
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else { throw AccountLoginError.invalidResponse }
        let draft = try JSONDecoder().decode(StationServiceDraft.self, from: Data(canonicalJson(json: text).utf8))
        guard draft.integrationId == record.id, draft.ownerAccount == ownerAccount, draft.issuer == issuer,
              draft.stationOrigin == origin, draft.genesisHash == log.genesisHash() else { throw AccountLoginError.changed }
        return draft
    }
}

public struct RemoteServiceReview: Equatable, Sendable {
    public let account: String
    public let serviceID: String
    public let manager: String
    public let predecessor: String
    public let hosts: [String]
    public let sessions: [String]?
    public let projects: [String]?
    public let operations: [String]
    public let expiresAt: Date

    public func check(record: PortalIntegrationRecord, hosts: [String], sessions: [String]?, projects: [String]?, now: Date = Date()) throws {
        let mapping: [String: [String]] = ["agent.view": ["view"], "agent.prompt": ["prompt"],
            "agent.approve": ["approval", "rule_revoke"], "agent.interrupt": ["interrupt", "stop"], "agent.terminal": ["terminal"]]
        let expected = Set(record.scopes.flatMap { mapping[$0] ?? [] }).union(["view"])
        guard Set(self.hosts) == Set(hosts), self.sessions.map(Set.init) == sessions.map(Set.init),
              self.projects.map(Set.init) == projects.map(Set.init), Set(operations) == expected,
              let expiry = record.expiry, expiresAt <= expiry, expiresAt > now else { throw AccountLoginError.changed }
    }

    public init(approval: RemoteServiceApproval) throws {
        guard let body = try JSONSerialization.jsonObject(with: Data(approval.bodyJSON.utf8)) as? [String: Any],
              let account = body["account_id"] as? String, let manager = body["signer"] as? String,
              let predecessor = body["prev_hash"] as? String,
              let member = body["member"] as? [String: Any], let id = member["device_id"] as? String,
              let expiry = member["expires_at"] as? NSNumber, let scope = member["scope"] as? [String: Any],
              let hosts = scope["hosts"] as? [String], let operations = scope["ops"] as? [String]
        else { throw AccountLoginError.invalidResponse }
        self.account = account; self.serviceID = id; self.manager = manager; self.predecessor = predecessor
        self.hosts = hosts; self.operations = operations
        sessions = scope["sessions"] as? [String]; projects = scope["projects"] as? [String]
        expiresAt = Date(timeIntervalSince1970: expiry.doubleValue / 1000)
    }
}
