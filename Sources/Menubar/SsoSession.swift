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
