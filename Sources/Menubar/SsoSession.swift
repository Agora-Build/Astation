import Foundation

/// One SSO session — what Astation persists after `Sign in with Agora`.
struct SsoSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: UInt64        // unix seconds (when the access token expires)
    var loginId: String?         // human-readable identifier returned by SSO

    /// True when the access token is within 60s of expiry (or already expired).
    func needsRefresh() -> Bool {
        expiresAt < Self.nowSecs() + 60
    }

    static func nowSecs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case loginId = "login_id"
    }
}

/// Errors raised by the SSO subsystem. Surfaced verbatim in the UI.
enum SsoError: Error, LocalizedError, Equatable {
    case notSignedIn
    case loopbackBindFailed(String)
    case browserOpenFailed
    case timeout
    case stateMismatch
    case tokenExchangeFailed(status: Int, body: String)
    case refreshFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in. Open Settings → Sign in with Agora."
        case .loopbackBindFailed(let s): return "Could not bind loopback listener: \(s)"
        case .browserOpenFailed: return "Could not open browser."
        case .timeout: return "Login timed out."
        case .stateMismatch: return "OAuth state mismatch — try signing in again."
        case .tokenExchangeFailed(let st, let body): return "Token exchange failed (\(st)): \(body)"
        case .refreshFailed(let s): return "Token refresh failed: \(s)"
        case .network(let s): return "Network error: \(s)"
        }
    }
}

import CryptoKit

/// PKCE verifier/challenge + state generator. Pure helpers — no I/O.
enum SsoPkce {
    /// Returns (verifier, challenge). Verifier is base64url(32 random bytes);
    /// challenge is base64url(SHA-256(verifier)).
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return (verifier, challenge)
    }

    /// 16 random bytes → base64url. Used for OAuth `state`.
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

/// Parsed OAuth callback query string.
struct SsoCallbackQuery: Equatable {
    let code: String
    let state: String
    let loginId: String

    /// `query` is the raw query string AFTER the `?` (no leading `?`).
    /// Missing fields come back as empty strings.
    static func parse(_ query: String) -> SsoCallbackQuery {
        var code = "", state = "", loginId = ""
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            switch key {
            case "code": code = value
            case "state": state = value
            case "loginId": loginId = value
            default: continue
            }
        }
        return SsoCallbackQuery(code: code, state: state, loginId: loginId)
    }
}

extension Data {
    /// base64url with no padding. RFC 7636-compatible.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
