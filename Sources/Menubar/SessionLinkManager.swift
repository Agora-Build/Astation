import Foundation

/// Manages creating and tracking shareable RTC session links via the API server.
class SessionLinkManager {
    private let hubManager: AstationHubManager
    private(set) var activeLinks: [SessionLink] = []
    let maxLinks = 8

    struct SessionLink {
        let id: String
        let url: String
        let channel: String
        let createdAt: Date
    }

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
    }

    var canCreateMore: Bool { activeLinks.count < maxLinks }

    /// Create a new share link for the current RTC session.
    /// Generates a uid=0 wildcard publisher token and POSTs to the API server.
    func createLink() async throws -> SessionLink {
        guard canCreateMore else {
            throw SessionLinkError.maxLinksReached
        }

        guard let channel = hubManager.rtcManager.currentChannel else {
            throw SessionLinkError.notInChannel
        }

        let hostUid = hubManager.rtcManager.currentUid

        // Generate a uid=0 wildcard publisher token
        let tokenResponse = await hubManager.generateRTCToken(
            channel: channel,
            uid: "0"
        )

        guard !tokenResponse.token.isEmpty else {
            throw SessionLinkError.tokenGenerationFailed
        }

        // Find the project to get appId
        let appId = hubManager.getProjects().first?.vendorKey ?? ""
        guard !appId.isEmpty else {
            throw SessionLinkError.noProject
        }

        // POST to api-server
        let urlString = "\(hubManager.stationRelayUrl)/api/rtc-sessions"
        guard let url = URL(string: urlString) else {
            throw SessionLinkError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "app_id": appId,
            "channel": channel,
            "token": tokenResponse.token,
            "host_uid": hostUid
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            throw SessionLinkError.serverError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let linkUrl = json["url"] as? String else {
            throw SessionLinkError.invalidResponse
        }

        let link = SessionLink(
            id: id,
            url: linkUrl,
            channel: channel,
            createdAt: Date()
        )

        activeLinks.append(link)
        print("[SessionLinkManager] Created link: \(linkUrl)")
        return link
    }

    /// Revoke a specific session link.
    func revokeLink(_ link: SessionLink) async {
        let urlString = "\(hubManager.stationRelayUrl)/api/rtc-sessions/\(link.id)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {
            let _ = try await URLSession.shared.data(for: request)
        } catch {
            print("[SessionLinkManager] Failed to revoke link \(link.id): \(error)")
        }

        activeLinks.removeAll { $0.id == link.id }
        print("[SessionLinkManager] Revoked link: \(link.id)")
    }

    /// Revoke all active session links.
    func revokeAll() async {
        let linksToRevoke = activeLinks
        for link in linksToRevoke {
            await revokeLink(link)
        }
    }
}

// MARK: - Errors

enum SessionLinkError: Error, LocalizedError {
    case maxLinksReached
    case notInChannel
    case tokenGenerationFailed
    case noProject
    case invalidServerURL
    case serverError
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .maxLinksReached: return "Maximum number of share links reached"
        case .notInChannel: return "Not currently in an RTC channel"
        case .tokenGenerationFailed: return "Failed to generate token"
        case .noProject: return "No Agora project available"
        case .invalidServerURL: return "Invalid server URL"
        case .serverError: return "Server returned an error"
        case .invalidResponse: return "Invalid server response"
        }
    }
}
