import Foundation

enum RemoteAccessBlockReason: Error, LocalizedError, Equatable {
    case offline, authenticationRequired, verificationRequired, identityUnavailable

    var errorDescription: String? {
        switch self {
        case .offline:
            return "Atem is offline. Reconnect to view its sessions."
        case .authenticationRequired:
            return "Atem needs to authenticate its current connection. Reconnect Atem using its existing pairing."
        case .verificationRequired:
            return "This Atem is paired but not verified. On its host, run atem pair verify, compare safety codes, and approve on this Mac."
        case .identityUnavailable:
            return "Astation's verification identity is unavailable. Unlock this Mac and check Settings > Security before retrying."
        }
    }
}
