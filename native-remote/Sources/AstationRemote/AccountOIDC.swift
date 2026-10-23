import AtemClient
import CryptoKit
import Foundation
import Security

public enum AccountLoginError: Error, LocalizedError, Equatable {
    case configuration, unavailable, invalidResponse, rejected, cancelled, signInRequired, storage, changed, busy, freshProofUnavailable
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Check the agora.build server URLs and client registration in Settings > General."
        case .unavailable: return "The agora.build account service is unavailable. Try again later."
        case .invalidResponse, .rejected: return "The account service returned an invalid or rejected sign-in."
        case .cancelled: return "Account sign-in was cancelled."
        case .signInRequired: return "Sign in to Agora.Build in Settings > Account to continue."
        case .storage: return "Account credentials could not be saved securely. Sign in again after unlocking this device."
        case .changed: return "The account session changed while this operation was pending. Try again."
        case .busy: return "Finish the current account sign-in first."
        case .freshProofUnavailable: return "This account service does not provide the fresh sign-in proof required for an offline merge. Approve the merge on the other Mac instead."
        }
    }
}

public struct AccountOIDCConfiguration: Codable, Equatable, Sendable {
    public let issuer: String
    public let clientID: String
    public let resource: String
    public let requiredScope: String
    public let additionalScopes: [String]?

    public var apiScopes: [String] { [requiredScope] + (additionalScopes ?? []) }

    public init(issuer: String, clientID: String, resource: String, requiredScope: String, additionalScopes: [String] = []) throws {
        _ = try Self.endpoint(issuer)
        _ = try Self.endpoint(resource)
        let scopes = [requiredScope] + additionalScopes
        guard !clientID.isEmpty, clientID.utf8.count <= 128, !clientID.contains(where: { $0.isWhitespace }),
              scopes.count <= 8, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 &&
                  $0.utf8.allSatisfy({ $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0) }) &&
                  !["openid", "profile", "offline_access"].contains($0) }) else { throw AccountLoginError.configuration }
        self.issuer = issuer; self.clientID = clientID; self.resource = resource; self.requiredScope = requiredScope
        self.additionalScopes = additionalScopes.isEmpty ? nil : additionalScopes
    }

    static func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || url.scheme == "http" && (["127.0.0.1", "::1", "localhost"].contains(host) || host.hasSuffix(".localhost"))
        else { throw AccountLoginError.configuration }
        return url
    }

    public func permitsRelay(_ value: String) -> Bool {
        guard var relay = URLComponents(string: value), let api = URLComponents(string: resource) else { return false }
        if relay.scheme == "wss" { relay.scheme = "https" }
        if relay.scheme == "ws" { relay.scheme = "http" }
        return relay.user == nil && relay.password == nil && relay.host == api.host && relay.scheme == api.scheme
            && (relay.port ?? (relay.scheme == "https" ? 443 : 80)) == (api.port ?? (api.scheme == "https" ? 443 : 80))
    }
}

public struct AccountLoginAttempt: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String
    public let nonce: String
    public init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountLoginError.unavailable }
            return AccountOIDCClient.encode(Data(bytes))
        }
        verifier = try random(); challenge = AccountOIDCClient.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = try random(); nonce = try random()
    }

    public func callbackCode(method: String, uri: String) throws -> String {
        guard method == "GET", uri.utf8.count <= 8192, uri.hasPrefix("/callback?"),
              let parts = URLComponents(string: "http://127.0.0.1" + uri), parts.path == "/callback",
              parts.fragment == nil, let items = parts.queryItems else { throw AccountLoginError.rejected }
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states[0].value == state else { throw AccountLoginError.rejected }
        let errors = items.filter { $0.name == "error" }
        if errors.count == 1, errors[0].value != nil, codes.isEmpty { throw AccountLoginError.cancelled }
        guard codes.count == 1,
              let code = codes[0].value, !code.isEmpty, code.utf8.count <= 4096,
              !items.contains(where: { $0.name == "error" }) else { throw AccountLoginError.rejected }
        return code
    }
}

public struct AccountLoginSession: Codable, Equatable, Sendable {
    public let configuration: AccountOIDCConfiguration
    public let subject: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let authenticatedAt: Int64?

    public func removingAccessToken() -> Self {
        Self(configuration: configuration, subject: subject, accessToken: "", refreshToken: refreshToken,
            expiresAt: .distantPast, authenticatedAt: nil)
    }
}

public protocol AccountOIDCHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

private final class AccountNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class AccountURLSessionHTTP: AccountOIDCHTTP, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: AccountNoRedirect(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 65536 else { throw AccountLoginError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65536 else { throw AccountLoginError.invalidResponse }
                data.append(byte)
            }
            return (data, response.statusCode)
        } catch let error as AccountLoginError { throw error }
        catch { throw AccountLoginError.unavailable }
    }
}

public actor AccountOIDCClient {
    public let configuration: AccountOIDCConfiguration
    private let http: AccountOIDCHTTP
    private let now: @Sendable () -> Date
    private struct Discovery: Decodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let jwks_uri: String
    }
    private var discoveryCache: (Discovery, Date)?
    private var keyCache: ([String: P256.Signing.PublicKey], Date)?
    private var keyAttempt: Date?

    public init(configuration: AccountOIDCConfiguration, http: AccountOIDCHTTP = AccountURLSessionHTTP(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.http = http; self.now = now
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8),
              let value = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8)) as? [String: Any]
        else { throw AccountLoginError.invalidResponse }
        return value
    }

    private func endpoint(_ value: String) throws -> URL {
        let endpoint = try AccountOIDCConfiguration.endpoint(value)
        let issuer = try AccountOIDCConfiguration.endpoint(configuration.issuer)
        guard endpoint.scheme == issuer.scheme, endpoint.host == issuer.host,
              endpoint.port == issuer.port else { throw AccountLoginError.invalidResponse }
        return endpoint
    }

    private func discovery() async throws -> Discovery {
        if let (value, at) = discoveryCache, now().timeIntervalSince(at) >= 0, now().timeIntervalSince(at) < 60 { return value }
        let url = configuration.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.well-known/openid-configuration"
        let (data, status) = try await http.send(URLRequest(url: try endpoint(url)))
        guard status == 200 else { throw AccountLoginError.unavailable }
        _ = try object(data)
        let metadata = try JSONDecoder().decode(Discovery.self, from: data)
        guard metadata.issuer == configuration.issuer else { throw AccountLoginError.invalidResponse }
        _ = try endpoint(metadata.authorization_endpoint); _ = try endpoint(metadata.token_endpoint); _ = try endpoint(metadata.jwks_uri)
        discoveryCache = (metadata, now())
        return metadata
    }

    public func authorizationURL(attempt: AccountLoginAttempt, redirectURI: String, fresh: Bool = false) async throws -> URL {
        let metadata = try await discovery()
        guard let redirect = URLComponents(string: redirectURI), redirect.scheme == "http", redirect.host == "127.0.0.1",
              redirect.port != nil, redirect.path == "/callback", redirect.user == nil, redirect.password == nil,
              redirect.query == nil, redirect.fragment == nil else { throw AccountLoginError.configuration }
        var parts = URLComponents(url: try endpoint(metadata.authorization_endpoint), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile offline_access " + configuration.apiScopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: configuration.resource), URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: attempt.state), URLQueryItem(name: "nonce", value: attempt.nonce),
            URLQueryItem(name: "code_challenge", value: attempt.challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        if fresh { parts.queryItems?.append(URLQueryItem(name: "max_age", value: "0")) }
        guard let url = parts.url else { throw AccountLoginError.configuration }
        return url
    }

    private func token(_ fields: [String: String]) async throws -> [String: Any] {
        let metadata = try await discovery()
        var request = URLRequest(url: try endpoint(metadata.token_endpoint)); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, status) = try await http.send(request)
        guard status == 200 else {
            if status == 400, (try? object(data)["error"] as? String) == "invalid_grant" {
                throw AccountLoginError.signInRequired
            }
            throw status >= 500 ? AccountLoginError.unavailable : AccountLoginError.rejected
        }
        return try object(data)
    }

    public func exchange(code: String, attempt: AccountLoginAttempt, redirectURI: String) async throws -> AccountLoginSession {
        let result = try await token(["grant_type": "authorization_code", "client_id": configuration.clientID,
            "code": code, "code_verifier": attempt.verifier, "redirect_uri": redirectURI, "resource": configuration.resource])
        guard let idToken = result["id_token"] as? String else { throw AccountLoginError.invalidResponse }
        let id = try await claims(idToken, type: "JWT", audience: configuration.clientID)
        guard id["nonce"] as? String == attempt.nonce, let subject = id["sub"] as? String else { throw AccountLoginError.rejected }
        return try await session(result, expectedSubject: subject, oldRefresh: nil)
    }

    public func refresh(_ old: AccountLoginSession) async throws -> AccountLoginSession {
        guard old.configuration == configuration else { throw AccountLoginError.changed }
        let result = try await token(["grant_type": "refresh_token", "client_id": configuration.clientID,
            "refresh_token": old.refreshToken, "resource": configuration.resource])
        if let idToken = result["id_token"] as? String {
            let id = try await claims(idToken, type: "JWT", audience: configuration.clientID)
            guard id["sub"] as? String == old.subject else { throw AccountLoginError.changed }
        }
        return try await session(result, expectedSubject: old.subject, oldRefresh: old.refreshToken)
    }

    private func session(_ result: [String: Any], expectedSubject: String, oldRefresh: String?) async throws -> AccountLoginSession {
        guard (result["token_type"] as? String)?.lowercased() == "bearer",
              let access = result["access_token"] as? String, let refresh = result["refresh_token"] as? String,
              !refresh.isEmpty, refresh.utf8.count <= 16384, refresh != oldRefresh else { throw AccountLoginError.invalidResponse }
        let value = try await claims(access, type: "at+jwt", audience: configuration.resource)
        guard value["sub"] as? String == expectedSubject,
              value["client_id"] as? String == configuration.clientID,
              let scopes = value["scope"] as? String,
              Set(configuration.apiScopes).isSubset(of: Set(scopes.split(separator: " ").map(String.init))),
              let exp = integer(value["exp"]) else { throw AccountLoginError.rejected }
        return AccountLoginSession(configuration: configuration, subject: expectedSubject, accessToken: access,
            refreshToken: refresh, expiresAt: Date(timeIntervalSince1970: Double(exp)), authenticatedAt: integer(value["auth_time"]))
    }

    private func claims(_ token: String, type: String, audience: String) async throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16384, parts.count == 3 else { throw AccountLoginError.rejected }
        let header = try object(Self.decode(String(parts[0])))
        let validType = type == "JWT" ? header["typ"] == nil || header["typ"] as? String == "JWT" : header["typ"] as? String == type
        guard header["alg"] as? String == "ES256", validType,
              header["crit"] == nil, let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count <= 128 else { throw AccountLoginError.rejected }
        let payload = try object(Self.decode(String(parts[1])))
        let audiences = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        if type == "JWT", audiences.count > 1 || payload["azp"] != nil {
            guard payload["azp"] as? String == configuration.clientID else { throw AccountLoginError.rejected }
        }
        guard payload["iss"] as? String == configuration.issuer, audiences.contains(audience),
              let subject = payload["sub"] as? String, subject.hasPrefix("ab"), subject.utf8.count == 28,
              subject.dropFirst(2).utf8.allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8.contains($0) }),
              let exp = integer(payload["exp"]), let iat = integer(payload["iat"]), iat >= 0,
              Double(exp) > now().timeIntervalSince1970, Double(iat) <= now().timeIntervalSince1970 + 30,
              exp > iat, exp - iat <= (type == "at+jwt" ? 900 : 3600) else { throw AccountLoginError.rejected }
        if let nbf = payload["nbf"] { guard let nbf = integer(nbf), Double(nbf) <= now().timeIntervalSince1970 else { throw AccountLoginError.rejected } }
        if let auth = payload["auth_time"] { guard let auth = integer(auth), auth >= 0, auth <= iat + 30 else { throw AccountLoginError.rejected } }
        let key = try await signingKey(kid)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.decode(String(parts[2])))
        guard key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)) else { throw AccountLoginError.rejected }
        return payload
    }

    private func signingKey(_ kid: String) async throws -> P256.Signing.PublicKey {
        let fresh = keyCache.map { now().timeIntervalSince($0.1) >= 0 && now().timeIntervalSince($0.1) < 60 } ?? false
        if fresh, let key = keyCache?.0[kid] { return key }
        if let attempted = keyAttempt, now().timeIntervalSince(attempted) < 5 { throw fresh ? AccountLoginError.rejected : AccountLoginError.unavailable }
        keyAttempt = now()
        let metadata = try await discovery()
        let (data, status) = try await http.send(URLRequest(url: try endpoint(metadata.jwks_uri)))
        guard status == 200, let values = try object(data)["keys"] as? [[String: Any]], !values.isEmpty, values.count <= 64 else { throw AccountLoginError.unavailable }
        var keys: [String: P256.Signing.PublicKey] = [:]
        for value in values {
            guard value["kty"] as? String == "EC", value["crv"] as? String == "P-256" else { continue }
            if let alg = value["alg"] as? String, alg != "ES256" { continue }
            if let use = value["use"] as? String, use != "sig" { continue }
            if let ops = value["key_ops"] as? [String], !ops.contains("verify") { continue }
            guard let id = value["kid"] as? String, !id.isEmpty, id.utf8.count <= 128, keys[id] == nil,
                  let x = value["x"] as? String, let y = value["y"] as? String else { throw AccountLoginError.invalidResponse }
            let dx = try Self.decode(x), dy = try Self.decode(y)
            guard dx.count == 32, dy.count == 32 else { throw AccountLoginError.invalidResponse }
            keys[id] = try P256.Signing.PublicKey(x963Representation: Data([4]) + dx + dy)
        }
        guard !keys.isEmpty else { throw AccountLoginError.unavailable }
        keyCache = (keys, now())
        guard let key = keys[kid] else { throw AccountLoginError.rejected }
        return key
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.int64Value
    }
    static func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ string: String) throws -> Data {
        let padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - string.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), encode(bytes) == string else { throw AccountLoginError.rejected }
        return bytes
    }
}

public struct AccountSessionRecord: Codable, Sendable {
    public let session: AccountLoginSession
    public var refreshPending: Bool
    public init(session: AccountLoginSession, refreshPending: Bool = false) { self.session = session; self.refreshPending = refreshPending }
}
public protocol AccountSessionStorage: Sendable {
    func read() throws -> AccountSessionRecord?
    func write(_ record: AccountSessionRecord?) throws
}

/// Persist the one-use refresh intent before network I/O. A lost reply never
/// causes a second use of a rotated token, including after a process restart.
public actor AccountTokenProvider {
    private let storage: AccountSessionStorage
    private let client: AccountOIDCClient
    private let configuration: AccountOIDCConfiguration
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var login: UUID?
    private var refresh: Task<String, Error>?
    private var uncertain = false
    private var liveSession: AccountLoginSession?

    public init(configuration: AccountOIDCConfiguration, client: AccountOIDCClient, storage: AccountSessionStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.client = client; self.storage = storage; self.now = now
    }
    public func current() throws -> AccountSessionRecord? {
        let record = try storage.read()
        guard record == nil || record?.session.configuration == configuration else { throw AccountLoginError.changed }
        if let record, !record.refreshPending, let liveSession,
           liveSession.subject == record.session.subject, liveSession.refreshToken == record.session.refreshToken {
            return AccountSessionRecord(session: liveSession)
        }
        return record
    }
    public func beginLogin() throws -> UUID {
        guard login == nil else { throw AccountLoginError.busy }
        generation = UUID(); refresh?.cancel(); refresh = nil; login = generation; liveSession = nil
        return generation
    }
    public func finishLogin(_ session: AccountLoginSession, attempt: UUID) throws {
        guard generation == attempt, login == attempt, session.configuration == configuration else { throw AccountLoginError.changed }
        do { try storage.write(AccountSessionRecord(session: session)) }
        catch { uncertain = true; login = nil; throw AccountLoginError.storage }
        liveSession = session; uncertain = false; login = nil
    }
    public func cancelLogin(_ attempt: UUID) { if login == attempt { login = nil } }
    public func signOut() throws {
        generation = UUID(); login = nil; refresh?.cancel(); refresh = nil; liveSession = nil
        do { try storage.write(nil); uncertain = false }
        catch { uncertain = true; throw AccountLoginError.storage }
    }
    public func validToken() async throws -> String {
        try await validToken(rejectedToken: nil)
    }

    /// Retry a rejected access token once, sharing rotation with concurrent callers.
    /// A sign-out or new login fences both the retry and its eventual response.
    public func performAuthorized<Value: Sendable>(
        _ operation: @Sendable (String) async throws -> Value,
        unauthorized: @Sendable (Error) -> Bool
    ) async throws -> Value {
        try Task.checkCancellation()
        let epoch = generation
        let token = try await validToken()
        try Task.checkCancellation()
        guard generation == epoch else { throw AccountLoginError.changed }
        do {
            let value = try await operation(token)
            try Task.checkCancellation()
            guard generation == epoch else { throw AccountLoginError.changed }
            return value
        } catch {
            try Task.checkCancellation()
            guard generation == epoch else { throw AccountLoginError.changed }
            guard unauthorized(error) else { throw error }
        }
        let replacement = try await validToken(rejectedToken: token)
        try Task.checkCancellation()
        guard generation == epoch else { throw AccountLoginError.changed }
        let value = try await operation(replacement)
        try Task.checkCancellation()
        guard generation == epoch else { throw AccountLoginError.changed }
        return value
    }

    private func validToken(rejectedToken: String?) async throws -> String {
        guard !uncertain else { throw AccountLoginError.storage }
        guard login == nil else { throw AccountLoginError.busy }
        if let refresh {
            let epoch = generation
            let token = try await refresh.value
            guard generation == epoch else { throw AccountLoginError.changed }
            return token
        }
        guard let record = try current(), !record.refreshPending else { throw AccountLoginError.signInRequired }
        if !record.session.accessToken.isEmpty, record.session.accessToken != rejectedToken,
           record.session.expiresAt.timeIntervalSince(now()) > 60 { return record.session.accessToken }
        let epoch = generation
        let task = Task { try await self.rotate(record.session, epoch: epoch) }
        refresh = task
        defer { if generation == epoch { refresh = nil } }
        let token = try await task.value
        guard generation == epoch else { throw AccountLoginError.changed }
        return token
    }
    private func rotate(_ session: AccountLoginSession, epoch: UUID) async throws -> String {
        guard generation == epoch else { throw AccountLoginError.changed }
        do { try storage.write(AccountSessionRecord(session: session, refreshPending: true)) }
        catch { uncertain = true; throw AccountLoginError.storage }
        let next: AccountLoginSession
        do { next = try await client.refresh(session) }
        catch AccountLoginError.signInRequired {
            guard generation == epoch else { throw AccountLoginError.changed }
            liveSession = nil
            do { try storage.write(nil) }
            catch { uncertain = true; throw AccountLoginError.storage }
            throw AccountLoginError.signInRequired
        }
        guard generation == epoch, login == nil else { throw AccountLoginError.changed }
        do { try storage.write(AccountSessionRecord(session: next)) }
        catch {
            liveSession = nil; uncertain = true
            // If deletion also fails, the durable pending marker still prevents reuse.
            try? storage.write(nil)
            throw AccountLoginError.storage
        }
        liveSession = next
        return next.accessToken
    }
}
