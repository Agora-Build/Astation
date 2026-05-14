import Foundation

/// Envelope returned by `GET {bff}/api/cli/v1/projects`.
struct BffProjectsEnvelope: Codable {
    let items: [BffProject]
}

/// Project as returned by the BFF (CLI) API. Field names match Atem's BffProject
/// (Atem/src/agora_api.rs).
struct BffProject: Codable {
    let projectId: String
    let name: String
    let appId: String
    let signKey: String?
    let status: String
    let createdAt: String
    let vid: UInt64?
}

enum AgoraAPIError: LocalizedError {
    case unauthorized
    case httpError(Int, String)
    case decodingError(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired — please sign in again."
        case .httpError(let code, let body):
            return "Agora BFF returned HTTP \(code): \(body.prefix(200))"
        case .decodingError(let s):
            return "Failed to decode BFF response: \(s)"
        case .network(let s):
            return "Network error: \(s)"
        }
    }
}

final class AgoraAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch projects from the BFF using a Bearer access token.
    func fetchProjects(accessToken: String, bffUrl: String) async throws -> [AgoraProject] {
        guard let url = URL(string: "\(bffUrl)/api/cli/v1/projects") else {
            throw AgoraAPIError.network("invalid bff url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        NetworkDebugLogger.logRequest(req, label: "BFF")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            NetworkDebugLogger.logError(error, label: "BFF")
            throw AgoraAPIError.network(String(describing: error))
        }
        NetworkDebugLogger.logResponse(response, data: data, label: "BFF")

        guard let http = response as? HTTPURLResponse else {
            throw AgoraAPIError.network("no HTTP response")
        }
        if http.statusCode == 401 { throw AgoraAPIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgoraAPIError.httpError(http.statusCode, body)
        }

        do {
            let env = try JSONDecoder().decode(BffProjectsEnvelope.self, from: data)
            return env.items.map(AgoraProject.init(from:))
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            Log.error("[BFF] decode failed. Raw: \(preview)")
            throw AgoraAPIError.decodingError(String(describing: error))
        }
    }
}

extension AgoraProject {
    /// Convert a BFF project to the in-memory `AgoraProject` that the rest of
    /// Astation (and the WS protocol) already understands. App ID is used as
    /// the canonical id.
    init(from b: BffProject) {
        self.init(
            id: b.appId,
            name: b.name,
            vendorKey: b.appId,
            signKey: b.signKey ?? "",
            status: b.status,
            created: AgoraProject.unixSecondsFromISO8601(b.createdAt)
        )
    }

    static func unixSecondsFromISO8601(_ s: String) -> UInt64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return UInt64(d.timeIntervalSince1970) }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return UInt64(d.timeIntervalSince1970) }
        return 0
    }
}
