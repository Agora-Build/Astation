import Foundation
import CStationCore

/// HTTP client for the Agora Conversational AI Agent REST API.
///
/// Auth: `Authorization: agora token=<rtc_dynamic_token>`. The token is
/// minted from app_id + sign_key (a.k.a. project app_certificate) using
/// the existing C bridge. This is the same pattern atem serv convo uses
/// (Atem/src/convo_test_server.rs).
final class ConvoAIClient {
    private let session: URLSession

    static let baseURL = "https://api.agora.io/api/conversational-ai-agent/v2/projects"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `POST /projects/{appId}/join`. Returns the agent id on success.
    func createAgent(
        appId: String,
        appCertificate: String,
        channel: String,
        agentRtcUid: String,
        remoteRtcUid: String,
        token: String,
        llmUrl: String,
        systemPrompt: String
    ) async throws -> ConvoAIAgentResponse {
        let urlString = "\(Self.baseURL)/\(appId)/join"
        guard let url = URL(string: urlString) else { throw ConvoAIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rtcToken = try Self.mintToken(appId: appId, appCertificate: appCertificate,
                                          channel: channel, uid: agentRtcUid)
        req.setValue(Self.authorizationHeader(rtcToken: rtcToken),
                     forHTTPHeaderField: "Authorization")

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
                    "system_messages": [["role": "system", "content": systemPrompt]],
                    "max_history": 10,
                    "params": ["model": "atem-voice-proxy"]
                ] as [String: Any],
                "asr": ["language": "en-US"],
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        NetworkDebugLogger.logRequest(req, label: "ConvoAI-create")
        let (data, response) = try await session.data(for: req)
        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-create")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "no HTTP response")
        }
        guard (200...201).contains(http.statusCode) else {
            throw ConvoAIError.httpError(statusCode: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(ConvoAIAgentResponse.self, from: data) }
        catch { throw ConvoAIError.decodingError(error) }
    }

    /// `POST /projects/{appId}/leave`. Mints a fresh leave token.
    func stopAgent(appId: String, appCertificate: String, channel: String,
                   agentRtcUid: String, agentId: String) async throws {
        let urlString = "\(Self.baseURL)/\(appId)/leave"
        guard let url = URL(string: urlString) else { throw ConvoAIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rtcToken = try Self.mintToken(appId: appId, appCertificate: appCertificate,
                                          channel: channel, uid: agentRtcUid)
        req.setValue(Self.authorizationHeader(rtcToken: rtcToken),
                     forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["agent_id": agentId])

        NetworkDebugLogger.logRequest(req, label: "ConvoAI-stop")
        let (data, response) = try await session.data(for: req)
        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-stop")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "no HTTP response")
        }
        guard (200...204).contains(http.statusCode) else {
            throw ConvoAIError.httpError(statusCode: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Pure helper — kept static so tests don't need a network or RTC stack.
    static func authorizationHeader(rtcToken: String) -> String {
        "agora token=\(rtcToken)"
    }

    /// Mint a 2h RTC dynamic token via the C core. Throws if the C side
    /// returns nil (means invalid inputs).
    static func mintToken(appId: String, appCertificate: String,
                          channel: String, uid: String) throws -> String {
        // ConvoAI uses string UIDs but the RTC token builder takes uint32.
        // Atem's serv convo path uses the agent_user_id parsed as a u32
        // (see `RtcAccount::parse`). Match that: numeric uid → cast, else
        // fall back to 0.
        let uidNum = UInt32(uid) ?? 0
        guard let cstr = astation_rtc_build_token(
            appId, appCertificate, channel, uidNum,
            /* role = publisher */ 1,
            /* expire_secs */ 7200,
            /* privilege_secs */ 7200
        ) else {
            throw ConvoAIError.tokenMintFailed
        }
        defer { astation_token_free(cstr) }
        return String(cString: cstr)
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
    case tokenMintFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid ConvoAI URL"
        case .httpError(let s, let b): return "ConvoAI HTTP \(s): \(b)"
        case .decodingError(let e): return "ConvoAI decode: \(e)"
        case .tokenMintFailed: return "Could not mint RTC token (missing app cert?)"
        }
    }
}
