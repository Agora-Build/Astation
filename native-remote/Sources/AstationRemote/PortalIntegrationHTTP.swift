import AtemClient
import Foundation

public struct PortalIntegrationRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let stationOrigin: String
    public let state: String
    public let scopes: [String]
    public let r9Svc: String?
    public let expiresAt: String
    public let role: String
    public let interruptRunning: Bool?

    func validate() throws {
        guard Self.validID(id), !name.isEmpty, name.utf8.count <= 320,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["owner", "station_owner"].contains(role),
              scopes.contains("agent.view"), scopes.count <= 8, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ ["agent.view", "agent.prompt", "agent.approve", "agent.interrupt", "agent.terminal",
                  "agent.launch", "agent.message", "agent.notify"].contains($0) }),
              !scopes.contains("agent.notify") || Set(scopes).isSuperset(of: ["agent.message", "agent.prompt"]),
              Self.validOrigin(stationOrigin), expiry != nil,
              r9Svc == nil || (r9Svc!.utf8.count == 64 && r9Svc!.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }))
        else { throw AccountLoginError.invalidResponse }
    }

    public var expiry: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }

    static func validID(_ value: String) -> Bool {
        value.hasPrefix("i-") && value.utf8.count == 28 && value.dropFirst(2).utf8.allSatisfy({
            Array("0123456789abcdefghjkmnpqrstvwxyz".utf8).contains($0)
        })
    }

    static func validAccountID(_ value: String) -> Bool {
        value.hasPrefix("ab") && value.utf8.count == 28 && value.dropFirst(2).utf8.allSatisfy({
            Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8).contains($0)
        })
    }

    public static func validOrigin(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host,
              host.contains("."), host == host.lowercased(), !host.hasSuffix("."), !host.contains(":"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty,
              parts.port == nil || ((1...65535).contains(parts.port!) && parts.port != 443),
              parts.url?.absoluteString == value else { return false }
        return true
    }

    func checked(stationOrigin: String, now: Date) throws -> Self {
        try validate()
        guard self.stationOrigin == stationOrigin, let expiry, expiry > now else { throw AccountLoginError.changed }
        return self
    }
}

public enum PortalIntegrationRevokeResult: Equatable, Sendable {
    case confirmed(PortalIntegrationRecord)
    case finalRefusal(RemoteControlPortalRefusal)
}

/// Native Portal discovery and consent transport. It cannot enroll a service or mark it Ready.
/// Use a separately scoped AccountTokenProvider; project login need not expand.
public struct PortalIntegrationHTTP: Sendable {
    public let configuration: AccountOIDCConfiguration
    private let portalOrigin: String
    public let ownerAccount: String
    private let http: AccountOIDCHTTP
    private let accessToken: @Sendable () async throws -> String

    public init(configuration: AccountOIDCConfiguration, portalOrigin: String, ownerAccount: String,
        http: AccountOIDCHTTP = AccountURLSessionHTTP(maximumResponseBytes: 262_144),
        accessToken: @escaping @Sendable () async throws -> String) throws {
        guard PortalIntegrationRecord.validAccountID(ownerAccount),
              let parts = URLComponents(string: portalOrigin), parts.url != nil, parts.path.isEmpty,
              configuration.resource == portalOrigin,
              configuration.apiScopes.contains("integrations:read")
        else { throw AccountLoginError.configuration }
        _ = try AccountOIDCConfiguration.endpoint(portalOrigin)
        self.configuration = configuration
        self.portalOrigin = portalOrigin
        self.ownerAccount = ownerAccount
        self.http = http
        self.accessToken = accessToken
    }

    public func pending(stationOrigin: String, now: Date = Date()) async throws -> [PortalIntegrationRecord] {
        try await owned(stationOrigin: stationOrigin, now: now).filter { $0.state == "awaiting_approval" }
            .map { try $0.checked(stationOrigin: stationOrigin, now: now) }
    }

    public func owned(stationOrigin: String, now: Date = Date()) async throws -> [PortalIntegrationRecord] {
        guard PortalIntegrationRecord.validOrigin(stationOrigin) else { throw AccountLoginError.configuration }
        struct List: Decodable { let integrations: [PortalIntegrationRecord]; let stale: Bool }
        let result: List = try await request(path: "/api/v1/integrations")
        guard !result.stale, result.integrations.count <= 500,
              Set(result.integrations.map(\.id)).count == result.integrations.count else { throw AccountLoginError.unavailable }
        return try result.integrations.filter {
            $0.role == "owner" && $0.stationOrigin == stationOrigin
        }.map { try $0.validate(); return $0 }
    }

    public func stations(cursor: String? = nil, limit: Int = 100) async throws -> PortalStationDirectoryPage {
        guard (1...100).contains(limit), cursor == nil || PortalStationDirectoryPage.validCursor(cursor!) else {
            throw AccountLoginError.configuration
        }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.queryItems!.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (bytes, code) = try await send(path: "/api/v1/stations?" + query.percentEncodedQuery!, jsonBody: nil)
        try checkStatus(code)
        return try PortalStationDirectoryPage.decode(bytes, limit: limit)
    }

    /// Finish the traversal before exposing new discovery metadata. Never return
    /// a successful prefix after a missing, repeated or conflicting page.
    public func stationDirectory() async throws -> PortalStationDirectorySnapshot {
        var cursor: String?, cursors = Set<String>(), ids = Set<String>()
        var stations: [PortalStationDirectoryEntry] = []
        for _ in 0..<41 {
            try Task.checkCancellation()
            let page = try await self.stations(cursor: cursor)
            try Task.checkCancellation()
            guard page.stations.allSatisfy({ ids.insert($0.id).inserted }),
                  stations.count + page.stations.count <= 4_096 else { throw AccountLoginError.invalidResponse }
            stations.append(contentsOf: page.stations)
            if page.stale || page.nextCursor == nil {
                return PortalStationDirectorySnapshot(stations: stations, stale: page.stale, complete: page.complete)
            }
            guard let next = page.nextCursor, cursors.insert(next).inserted else { throw AccountLoginError.invalidResponse }
            cursor = next
        }
        throw AccountLoginError.invalidResponse
    }

    /// The protected control journal retains this exact intent until this reply is committed.
    /// A Portal receipt alone never proves that a host has applied the native stop.
    public func mirrorRevoke(_ mirror: RemoteControlPortalMirror) async throws -> PortalIntegrationRevokeResult {
        try mirror.validate()
        guard mirror.issuer == configuration.issuer, mirror.ownerAccount == ownerAccount else {
            throw AccountLoginError.changed
        }
        let (bytes, code) = try await send(path: "/api/v1/integrations/\(mirror.integrationID)/revoke",
            jsonBody: JSONEncoder().encode(["interruptRunning": mirror.interruptRunning]))
        if code == 409, mirror.interruptRunning {
            let data = try responseJSON(bytes)
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(body.keys) == ["error", "code"], let message = body["error"] as? String, !message.isEmpty,
                  let value = body["code"] as? String else { throw AccountLoginError.invalidResponse }
            guard let refusal = RemoteControlPortalRefusal(rawValue: value) else { throw AccountLoginError.changed }
            return .finalRefusal(refusal)
        }
        try checkStatus(code)
        let result = try JSONDecoder().decode(PortalIntegrationRecord.self, from: responseJSON(bytes))
        try result.validate()
        guard result.id == mirror.integrationID, result.stationOrigin == mirror.stationOrigin,
              result.role == "owner", ["revoking", "revoked"].contains(result.state),
              result.interruptRunning != nil, !mirror.interruptRunning || result.interruptRunning == true else {
            throw AccountLoginError.changed
        }
        return .confirmed(result)
    }

    /// Publish only after the native checkpoint contains the exact signed entry.
    /// A lost HTTP reply is reconciled by listing; this method never retries it.
    @MainActor
    public func approve(_ approval: RemoteServiceApproval, publication: RemoteMembershipPublication,
        current: () -> Bool, now: Date = Date()) async throws -> PortalIntegrationRecord {
        let committedLog = try publication.committedLog()
        guard current(), publication.operationContext == (try approval.checkpoint()),
              configuration.issuer == approval.issuer, ownerAccount == approval.ownerAccount,
              committedLog.genesisHash() == approval.genesisHash,
              PortalIntegrationRecord.validID(approval.integrationID), PortalIntegrationRecord.validOrigin(approval.stationOrigin),
              committedLog.frozen() == nil,
              try committedLog.entries().contains(where: { try signedObjectInfo(json: $0).bodyJcs == approval.bodyJSON }),
              let body = try JSONSerialization.jsonObject(with: Data(approval.bodyJSON.utf8)) as? [String: Any],
              body["account_id"] as? String == committedLog.accountId(),
              let memberJSON = body["member"] as? [String: Any], let id = memberJSON["device_id"] as? String,
              let member = committedLog.member(deviceId: id), member.kind == "service", member.status == .active,
              member.roles == ["service"], member.encKey == nil,
              let expiry = member.expiresAt, Double(expiry) > now.timeIntervalSince1970 * 1000,
              try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: memberJSON), as: UTF8.self)) == member.memberJson,
              try RemoteServiceKeyFingerprint.compute(member.authKey) == approval.fingerprint
        else { throw AccountLoginError.changed }
        let result: PortalIntegrationRecord = try await request(path: "/api/v1/integrations/\(approval.integrationID)/approval",
            body: ["r9Svc": approval.fingerprint])
        guard current(), result.id == approval.integrationID, result.role == "owner",
              result.r9Svc == approval.fingerprint, result.state == "provisioning"
        else { throw AccountLoginError.changed }
        return try result.checked(stationOrigin: approval.stationOrigin, now: now)
    }

    private func request<T: Decodable>(path: String, body: [String: String]? = nil) async throws -> T {
        try await request(path: path, jsonBody: body.map { try JSONEncoder().encode($0) })
    }

    private func request<T: Decodable>(path: String, jsonBody: Data?) async throws -> T {
        let (bytes, code) = try await send(path: path, jsonBody: jsonBody)
        try checkStatus(code)
        return try JSONDecoder().decode(T.self, from: responseJSON(bytes))
    }

    private func send(path: String, jsonBody: Data?) async throws -> (Data, Int) {
        guard jsonBody == nil || configuration.apiScopes.contains("integrations:approve") else {
            throw AccountLoginError.configuration
        }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: portalOrigin + path)!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return try await http.send(request)
    }

    private func checkStatus(_ code: Int) throws {
        switch code {
        case 200: break
        case 401: throw AccountLoginError.signInRequired
        case 403, 404, 409: throw AccountLoginError.changed
        default: throw AccountLoginError.unavailable
        }
    }

    private func responseJSON(_ bytes: Data) throws -> Data {
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else { throw AccountLoginError.invalidResponse }
        return Data(try canonicalJson(json: text).utf8)
    }
}
