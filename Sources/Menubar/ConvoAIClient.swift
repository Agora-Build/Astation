import Foundation

/// HTTP client for the Agora Conversational AI Agent REST API.
///
/// Manages agent lifecycle: create (join) and stop (leave).
/// Auth: Basic base64(customerId:customerSecret) — same pattern as AgoraAPIClient.
class ConvoAIClient {
    private let session: URLSession

    /// Base URL for ConvoAI API.
    static let baseURL = "https://api.agora.io/api/conversational-ai-agent/v2/projects"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// POST /api/conversational-ai-agent/v2/projects/{appId}/join
    func createAgent(
        appId: String,
        credentials: AgoraCredentials,
        channel: String,
        agentRtcUid: String,
        remoteRtcUid: String,
        token: String,
        llmUrl: String,
        systemPrompt: String
    ) async throws -> ConvoAIAgentResponse {
        let urlString = "\(Self.baseURL)/\(appId)/join"
        guard let url = URL(string: urlString) else {
            throw ConvoAIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let authString = "\(credentials.customerId):\(credentials.customerSecret)"
        guard let authData = authString.data(using: .utf8) else {
            throw ConvoAIError.missingCredentials
        }
        request.setValue(
            "Basic \(authData.base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )

        let body: [String: Any] = [
            "name": "atem-voice-\(Int(Date().timeIntervalSince1970))",
            "properties": [
                "channel": channel,
                "token": token,
                "agent_rtc_uid": agentRtcUid,
                "remote_rtc_uids": [remoteRtcUid],
                "enable_string_uid": false,
                "idle_timeout": 120,
                "llm": [
                    "url": llmUrl,
                    "api_key": "unused",
                    "style": "openai",
                    "system_messages": [
                        [
                            "role": "system",
                            "content": systemPrompt
                        ]
                    ],
                    "max_history": 10,
                    "params": [
                        "model": "atem-voice-proxy"
                    ]
                ] as [String: Any],
                "asr": [
                    "language": "en-US"
                ],
                "tts": [
                    "vendor": "microsoft",
                    "params": [
                        "key": "placeholder",
                        "region": "eastus",
                        "voice_name": "en-US-AndrewMultilingualNeural"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        NetworkDebugLogger.logRequest(request, label: "ConvoAI-create")

        let (data, response) = try await session.data(for: request)

        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-create")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "No HTTP response")
        }

        guard (200...201).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw ConvoAIError.httpError(statusCode: http.statusCode, body: responseBody)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ConvoAIAgentResponse.self, from: data)
        } catch {
            throw ConvoAIError.decodingError(error)
        }
    }

    /// POST /api/conversational-ai-agent/v2/projects/{appId}/leave
    func stopAgent(
        appId: String,
        credentials: AgoraCredentials,
        agentId: String
    ) async throws {
        let urlString = "\(Self.baseURL)/\(appId)/leave"
        guard let url = URL(string: urlString) else {
            throw ConvoAIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let authString = "\(credentials.customerId):\(credentials.customerSecret)"
        guard let authData = authString.data(using: .utf8) else {
            throw ConvoAIError.missingCredentials
        }
        request.setValue(
            "Basic \(authData.base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )

        let body: [String: Any] = ["agent_id": agentId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        NetworkDebugLogger.logRequest(request, label: "ConvoAI-stop")

        let (data, response) = try await session.data(for: request)

        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-stop")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "No HTTP response")
        }

        guard (200...204).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw ConvoAIError.httpError(statusCode: http.statusCode, body: responseBody)
        }
    }
}

struct ConvoAIAgentResponse: Decodable {
    let agentId: String
    let createTs: Int?
    let state: String?
}

enum ConvoAIError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ConvoAI API URL"
        case .httpError(let statusCode, let body):
            return "ConvoAI HTTP error \(statusCode): \(body)"
        case .decodingError(let error):
            return "ConvoAI decoding error: \(error)"
        case .missingCredentials:
            return "Missing Agora credentials for ConvoAI"
        }
    }
}
