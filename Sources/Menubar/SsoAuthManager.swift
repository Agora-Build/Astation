import Foundation
import NIO
import NIOHTTP1
import AppKit

/// Runs the OAuth 2.0 + PKCE login flow against the Agora SSO server.
/// One-shot per login — caller throws this instance away after the flow
/// finishes (or fails). Designed so the network and browser-open paths
/// can be stubbed in tests.
final class SsoAuthManager {

    static let clientId = "atem"          // reuse Atem's registered OAuth client
    static let scope = "basic_info,console"

    private let ssoUrl: String
    private let urlSession: URLSession
    private let openURL: (URL) -> Void
    private let timeoutSecs: Int

    init(
        ssoUrl: String,
        urlSession: URLSession = .shared,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        timeoutSecs: Int = 300
    ) {
        self.ssoUrl = ssoUrl
        self.urlSession = urlSession
        self.openURL = openURL
        self.timeoutSecs = timeoutSecs
    }

    /// Run the full login flow. Returns the persisted SsoSession.
    func runLoginFlow() async throws -> SsoSession {
        let (verifier, challenge) = SsoPkce.generate()
        let state = SsoPkce.generateState()

        // Bind loopback first so we know the port for the redirect_uri.
        let listener = try await SsoLoopbackListener.bind(
            timeout: .seconds(Int64(timeoutSecs)),
            expectedState: state
        )
        let redirectUri = "http://127.0.0.1:\(listener.port)/oauth/callback"

        let authURL = Self.buildAuthorizeURL(
            ssoUrl: ssoUrl,
            redirectUri: redirectUri,
            state: state,
            challenge: challenge
        )
        guard let url = URL(string: authURL) else {
            throw SsoError.browserOpenFailed
        }

        openURL(url)
        Log.info("[SSO] Waiting for OAuth callback on \(redirectUri)")

        let callback = try await listener.awaitCallback()

        // Exchange code for tokens.
        let exchanged = try await exchangeCode(
            code: callback.code,
            verifier: verifier,
            redirectUri: redirectUri
        )

        var session = exchanged
        if !callback.loginId.isEmpty {
            session.loginId = callback.loginId
        }
        return session
    }

    /// Build the `/api/v0/oauth/authorize?…` URL. Exposed for unit tests.
    static func buildAuthorizeURL(
        ssoUrl: String,
        redirectUri: String,
        state: String,
        challenge: String
    ) -> String {
        let encodedRedirect = redirectUri
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? redirectUri
        return "\(ssoUrl)/api/v0/oauth/authorize"
            + "?response_type=code"
            + "&client_id=\(clientId)"
            + "&redirect_uri=\(encodedRedirect)"
            + "&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? scope)"
            + "&state=\(state)"
            + "&code_challenge=\(challenge)"
            + "&code_challenge_method=S256"
    }

    private func exchangeCode(code: String, verifier: String, redirectUri: String) async throws -> SsoSession {
        let url = URL(string: "\(ssoUrl)/api/v0/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = SsoNetworkRefresher.formBody([
            "grant_type": "authorization_code",
            "client_id": Self.clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
        ])
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SsoError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SsoError.tokenExchangeFailed(status: http.statusCode, body: body)
        }
        return try SsoNetworkRefresher.decodeTokenResponse(data)
    }
}

private extension CharacterSet {
    /// Safer percent-encoder than `.urlQueryAllowed` (which leaves `+` and `&` alone).
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}
