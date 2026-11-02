import Foundation
import AstationRemote

enum PortalAPIError: LocalizedError, Equatable {
    case signInRequired, connectAgora, permission, unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to Agora.Build in Settings > Account."
        case .connectAgora: return "Connect or reconnect Agora Console through Agora.Build, then refresh Projects."
        case .permission: return "Agora.Build has not granted the requested project or certificate access. Sign in again with the required permissions."
        case .unavailable: return "Agora projects are unavailable. Check your Agora.Build connection and try again."
        case .invalidResponse: return "The Agora.Build service returned an invalid project response."
        }
    }
}

struct PortalAgoraConnection: Decodable, Equatable, Sendable {
    let ready: Bool
    let connect: Bool
    let connected: Bool
    let name: String?
    var reconnect: Bool? = nil
}

/// Uses the Portal's documented bearer API. Upstream Agora tokens stay on the Portal.
struct PortalAPIClient: Sendable {
    let http: AccountOIDCHTTP
    init(http: AccountOIDCHTTP = AccountURLSessionHTTP()) { self.http = http }

    private func request<T: Decodable>(_ path: String, settings: AccountServiceSettings, token: String,
                                       body: [String: String]? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: settings.portalURL + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, code) = try await http.send(request)
        switch code {
        case 200: break
        case 401:
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reconnect = object["reconnect"] as? NSNumber,
               CFGetTypeID(reconnect) == CFBooleanGetTypeID(), reconnect.boolValue {
                throw PortalAPIError.connectAgora
            }
            throw PortalAPIError.signInRequired
        case 403: throw PortalAPIError.permission
        default: throw PortalAPIError.unavailable
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PortalAPIError.invalidResponse }
    }

    func connection(settings: AccountServiceSettings, token: String) async throws -> PortalAgoraConnection {
        struct Envelope: Decodable { let agora: PortalAgoraConnection }
        let result: Envelope = try await request("/api/v1/connections", settings: settings, token: token)
        return result.agora
    }

    func connection(settings: AccountServiceSettings, auth: AstationAccountAuth) async throws -> PortalAgoraConnection {
        try await authorized(settings: settings, auth: auth) { token in try await connection(settings: settings, token: token) }
    }

    struct Project: Codable, Sendable {
        let projectId: String
        let appId: String
        let name: String
        let status: String
        var localProject: AgoraProject {
            AgoraProject(id: appId, name: name, vendorKey: appId, signKey: "", status: status, created: 0)
        }
    }

    func projects(settings: AccountServiceSettings, token: String) async throws -> [Project] {
        struct Envelope: Decodable { let projects: [Project] }
        let result: Envelope = try await request("/api/v1/connections/agora/projects", settings: settings, token: token)
        guard Set(result.projects.map(\.appId)).count == result.projects.count,
              Set(result.projects.map(\.projectId)).count == result.projects.count,
              result.projects.allSatisfy({ !$0.appId.isEmpty && !$0.projectId.isEmpty })
        else { throw PortalAPIError.invalidResponse }
        return result.projects
    }

    func projects(settings: AccountServiceSettings, auth: AstationAccountAuth) async throws -> [Project] {
        try await authorized(settings: settings, auth: auth) { token in try await projects(settings: settings, token: token) }
    }

    func certificate(project: Project, settings: AccountServiceSettings, token: String) async throws -> AgoraProject {
        struct Certificate: Decodable { let projectId: String; let appId: String; let certificate: String? }
        let result: Certificate = try await request("/api/v1/connections/agora/certificate", settings: settings,
            token: token, body: ["projectId": project.projectId])
        guard result.projectId == project.projectId, result.appId == project.appId else { throw PortalAPIError.invalidResponse }
        return AgoraProject(id: project.appId, name: project.name, vendorKey: project.appId,
            signKey: result.certificate ?? "", status: project.status, created: 0)
    }

    func certificate(project: Project, settings: AccountServiceSettings, auth: AstationAccountAuth) async throws -> AgoraProject {
        try await authorized(settings: settings, auth: auth) { token in try await certificate(project: project, settings: settings, token: token) }
    }

    private func authorized<Value: Sendable>(settings: AccountServiceSettings, auth: AstationAccountAuth,
        operation: @Sendable (String) async throws -> Value) async throws -> Value {
        guard auth.configuration == (try settings.oidcConfiguration) else { throw AccountLoginError.changed }
        return try await auth.performAuthorized(operation, unauthorized: { $0 as? PortalAPIError == .signInRequired })
    }
}
