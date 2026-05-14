import Foundation

/// Storage abstraction the provider needs. SsoSessionStore conforms below.
protocol SsoSessionStoring: AnyObject {
    func load() -> SsoSession?
    func save(_ session: SsoSession) throws
    func delete() throws
    var hasSession: Bool { get }
}

extension SsoSessionStore: SsoSessionStoring {}

/// Refresh abstraction so tests can swap the network call.
protocol SsoTokenRefreshing: AnyObject {
    func refresh(refreshToken: String, ssoUrl: String) async throws -> SsoSession
}

/// Production refresher: hits `POST {sso}/api/v0/oauth/token` with grant_type=refresh_token.
final class SsoNetworkRefresher: SsoTokenRefreshing {
    private let urlSession: URLSession
    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    func refresh(refreshToken: String, ssoUrl: String) async throws -> SsoSession {
        let url = URL(string: "\(ssoUrl)/api/v0/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = SsoNetworkRefresher.formBody([
            "grant_type": "refresh_token",
            "client_id": SsoAuthManager.clientId,
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SsoError.refreshFailed("HTTP \(status) \(body)")
        }
        return try SsoNetworkRefresher.decodeTokenResponse(data)
    }

    /// application/x-www-form-urlencoded body.
    static func formBody(_ pairs: [String: String]) -> Data {
        let encoded = pairs.map { k, v in
            let kk = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let vv = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(kk)=\(vv)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// Parses {access_token, refresh_token, expires_in} → SsoSession.
    static func decodeTokenResponse(_ data: Data) throws -> SsoSession {
        struct Payload: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: UInt64
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        return SsoSession(
            accessToken: p.access_token,
            refreshToken: p.refresh_token,
            expiresAt: SsoSession.nowSecs() + p.expires_in,
            loginId: nil
        )
    }
}

/// Single entry point for any caller that needs an access token. Serializes
/// concurrent refreshes via actor isolation.
actor SsoTokenProvider {
    private let store: SsoSessionStoring
    private let refresher: SsoTokenRefreshing
    private let ssoUrl: () -> String

    init(store: SsoSessionStoring, refresher: SsoTokenRefreshing, ssoUrl: @escaping () -> String) {
        self.store = store
        self.refresher = refresher
        self.ssoUrl = ssoUrl
    }

    /// Returns a valid access token. Refreshes via the SSO server if needed.
    /// Throws `SsoError.notSignedIn` when the store is empty,
    /// or `SsoError.refreshFailed` when the refresh call fails.
    func validToken() async throws -> String {
        guard let current = store.load() else { throw SsoError.notSignedIn }
        if !current.needsRefresh() { return current.accessToken }

        do {
            var refreshed = try await refresher.refresh(refreshToken: current.refreshToken, ssoUrl: ssoUrl())
            // Preserve the human-readable loginId across refresh.
            refreshed.loginId = current.loginId
            try store.save(refreshed)
            return refreshed.accessToken
        } catch {
            try? store.delete()
            throw error
        }
    }
}
