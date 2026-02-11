import Foundation

/// Raw API response from Agora Console REST API
struct AgoraAPIResponse: Codable {
    let projects: [AgoraAPIProject]
}

/// Raw project as returned by `GET https://api.agora.io/dev/v1/projects`
struct AgoraAPIProject: Codable {
    let id: String
    let name: String
    let vendor_key: String   // app_id
    let sign_key: String     // app_certificate
    let recording_server: String?
    let status: Int           // 1 = enabled
    let created: UInt64       // Unix timestamp
}

enum AgoraAPIError: LocalizedError {
    case noCredentials
    case httpError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Agora credentials configured. Open Settings to add them."
        case .httpError(let code):
            return "Agora API returned HTTP \(code)"
        case .decodingError(let detail):
            return "Failed to decode API response: \(detail)"
        }
    }
}

class AgoraAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch projects from the Agora Console API using stored credentials.
    func fetchProjects(credentials: AgoraCredentials) async throws -> [AgoraProject] {
        let url = URL(string: "https://api.agora.io/dev/v1/projects")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Basic auth: base64(customer_id:customer_secret)
        let authString = "\(credentials.customerId):\(credentials.customerSecret)"
        guard let authData = authString.data(using: .utf8) else {
            throw AgoraAPIError.noCredentials
        }
        let base64Auth = authData.base64EncodedString()
        request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgoraAPIError.httpError(0)
        }

        guard (200...201).contains(httpResponse.statusCode) else {
            throw AgoraAPIError.httpError(httpResponse.statusCode)
        }

        let apiResponse: AgoraAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(AgoraAPIResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            print("[AgoraAPI] Decode failed. Raw response: \(preview)")
            throw AgoraAPIError.decodingError(error.localizedDescription)
        }

        // Map API projects to our AgoraProject model
        return apiResponse.projects.map { raw in
            AgoraProject(
                id: raw.vendor_key,  // Use app_id as the project identifier
                name: raw.name,
                vendorKey: raw.vendor_key,
                signKey: raw.sign_key,
                status: raw.status == 1 ? "active" : "disabled",
                created: raw.created
            )
        }
    }
}
