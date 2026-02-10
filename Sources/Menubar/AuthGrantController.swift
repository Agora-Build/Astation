import Cocoa
import Foundation

struct AuthRequest {
    let sessionId: String
    let hostname: String   // tag from the requesting Atem instance
    let otp: String        // 8-digit one-time password
    let timestamp: Date
}

struct AuthSession {
    let request: AuthRequest
    var granted: Bool?     // nil = pending, true = granted, false = denied
    var sessionToken: String?
}

class AuthGrantController {
    private var pendingSessions: [String: AuthSession] = [:]

    /// Show a Grant/Deny dialog for an auth request.
    /// Returns true if granted, false if denied.
    func showAuthDialog(request: AuthRequest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Atem Access Request"
        alert.informativeText = """
        Atem on "\(request.hostname)" is requesting access.

        Session ID: \(request.sessionId.prefix(8))...
        OTP: \(request.otp)

        Do you want to grant access?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        // Set the Allow button as the default but make it require deliberate action
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"  // Escape

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// Handle an auth request: show dialog, generate token if granted.
    func handleAuthRequest(_ request: AuthRequest) -> AuthSession {
        var session = AuthSession(request: request)

        let granted = showAuthDialog(request: request)
        session.granted = granted

        if granted {
            session.sessionToken = generateSessionToken()
        }

        pendingSessions[request.sessionId] = session
        return session
    }

    /// Generate a random session token.
    private func generateSessionToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Get a pending session by ID.
    func getSession(_ sessionId: String) -> AuthSession? {
        return pendingSessions[sessionId]
    }

    /// Clean up expired sessions (older than 5 minutes).
    func cleanupExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-300) // 5 minutes
        pendingSessions = pendingSessions.filter { $0.value.request.timestamp > cutoff }
    }
}
