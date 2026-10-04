import Foundation

struct AgoraTranscriptionTokens: Sendable {
    let appID: String
    let channel: String
    let publisherUID: UInt32
    let botUID: UInt32
    let publisherToken: String
    let botToken: String
}

final class AgoraTranscriptionClient: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    static func joinBody(tokens: AgoraTranscriptionTokens, settings: TranscriptionSettings, name: String) throws -> Data {
        guard tokens.appID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
              tokens.publisherUID != tokens.botUID, tokens.publisherUID > 0, tokens.botUID > 0,
              tokens.publisherToken.hasPrefix("007"), tokens.botToken.hasPrefix("007"),
              settings.translationLanguage != settings.language else {
            throw TranscriptionError.message("A valid Agora project, AccessToken2 tokens, and distinct channel UIDs are required.")
        }
        var body: [String: Any] = [
            "name": name, "languages": [settings.language], "maxIdleTime": 30,
            "rtcConfig": ["channelName": tokens.channel, "pubBotUid": String(tokens.botUID),
                          "pubBotToken": tokens.botToken, "subscribeAudioUids": [String(tokens.publisherUID)],
                          "enableJsonProtocol": true]
        ]
        if let target = settings.translationLanguage {
            body["translateConfig"] = ["languages": [["source": settings.language, "target": [target]]]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
    func join(tokens: AgoraTranscriptionTokens, settings: TranscriptionSettings) async throws -> String {
        let body = try Self.joinBody(tokens: tokens, settings: settings, name: "astation-\(UUID().uuidString)")
        let data = try await request(path: "join", tokens: tokens, body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["agent_id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw TranscriptionError.message("Agora returned an invalid transcription agent response.")
        }
        return id
    }
    func leave(agentID: String, tokens: AgoraTranscriptionTokens) async throws {
        guard agentID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw TranscriptionError.message("Invalid transcription agent ID.")
        }
        _ = try await request(path: "agents/\(agentID)/leave", tokens: tokens, body: nil)
    }
    private func request(path: String, tokens: AgoraTranscriptionTokens, body: Data?) async throws -> Data {
        guard tokens.appID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
              tokens.publisherToken.hasPrefix("007"), !tokens.publisherToken.contains(where: { $0 == "\"" || $0.isNewline }) else {
            throw TranscriptionError.message("Invalid Agora transcription authentication.")
        }
        let url = URL(string: "https://api.agora.io/api/speech-to-text/v1/projects/\(tokens.appID)/\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("agora token=\"\(tokens.publisherToken)\"", forHTTPHeaderField: "Authorization")
        // Deliberately do not pass token-bearing requests/responses to the debug logger.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TranscriptionError.message("No Agora transcription response.") }
        if path.hasSuffix("/leave") && response.statusCode == 404 { return data }
        guard (200...299).contains(response.statusCode) else {
            throw TranscriptionError.message("Agora transcription returned HTTP \(response.statusCode). Check sign-in, project access, and that Real-Time STT is enabled in Agora Console.")
        }
        return data
    }
}

protocol CloudAudioPublishing: AnyObject {
    func start(tokens: AgoraTranscriptionTokens, onCaption: @escaping @Sendable (Data) -> Void) async throws
    func push(_ samples: [Float]) async throws
    func renew(token: String) async throws
    func finishAudio() async throws
    func stop() async
}
extension CloudAudioPublishing { func finishAudio() async throws {} }

actor AgoraCloudTranscriber: LiveTranscribing {
    typealias TokenProvider = @Sendable () async throws -> AgoraTranscriptionTokens
    private let settings: TranscriptionSettings
    private let tokenProvider: TokenProvider
    private let client: AgoraTranscriptionClient
    private let publisher: CloudAudioPublishing
    private var tokens: AgoraTranscriptionTokens?
    private var agentID: String?
    private var renewal: Task<Void, Never>?
    private var closed = false
    private var renewalError: Error?
    private let renewalInterval: UInt64
    init(settings: TranscriptionSettings, tokenProvider: @escaping TokenProvider,
         client: AgoraTranscriptionClient = AgoraTranscriptionClient(), publisher: CloudAudioPublishing = CloudTranscriptionHelper(),
         renewalInterval: UInt64 = 2_700_000_000_000) {
        self.settings = settings; self.tokenProvider = tokenProvider; self.client = client; self.publisher = publisher
        self.renewalInterval = renewalInterval
    }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        do { try await startSession(onSegment: onSegment) }
        catch { await cancel(); throw error }
    }
    private func startSession(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        let credentials = try await tokenProvider()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        tokens = credentials
        let sourceID = settings.sourceID
        try await publisher.start(tokens: credentials) { data in
            guard let values = try? AgoraCaptionDecoder.decode(data, sourceID: sourceID, publisherUID: credentials.publisherUID) else { return }
            for value in values { onSegment(value) }
        }
        if closed { await publisher.stop(); throw CancellationError() }
        try Task.checkCancellation()
        let id = try await joinAgent(tokens: credentials)
        guard !closed, !Task.isCancelled else {
            await leaveAgent(id, tokens: credentials)
            throw CancellationError()
        }
        agentID = id
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.renewalInterval ?? 2_700_000_000_000)
                    try await self?.renewTokens()
                } catch {
                    if !Task.isCancelled { await self?.rememberRenewalError(error) }
                    return
                }
            }
        }
    }
    private func rememberRenewalError(_ error: Error) { renewalError = error }
    private func renewTokens() async throws {
        let fresh = try await tokenProvider()
        guard !closed, let previous = tokens else { return }
        guard fresh.appID == previous.appID, fresh.channel == previous.channel,
              fresh.publisherUID == previous.publisherUID, fresh.botUID == previous.botUID else {
            throw TranscriptionError.message("The Agora project changed. Restart cloud transcription.")
        }
        try await publisher.renew(token: fresh.publisherToken)
        guard !closed else { return }
        // Agent bot tokens are not updatable in STT 7.x. Recreate the agent before expiry.
        if let agentID { try await client.leave(agentID: agentID, tokens: fresh) }
        guard !closed else { return }
        agentID = nil; tokens = fresh
        let id = try await joinAgent(tokens: fresh)
        if closed { await leaveAgent(id, tokens: fresh) }
        else { agentID = id }
    }
    func consume(_ samples: [Float]) async throws {
        if let renewalError { throw renewalError }
        guard !closed else { throw CancellationError() }
        try await publisher.push(samples)
    }
    func finish() async throws {
        guard !closed else { return }
        try await publisher.finishAudio()
        // Allow bounded time for final server captions without keeping an agent alive indefinitely.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await cancel()
    }
    private func joinAgent(tokens: AgoraTranscriptionTokens) async throws -> String {
        let client = self.client, settings = self.settings
        // If cancellation races an HTTP join, still obtain the agent ID so it can be stopped.
        return try await Task.detached { try await client.join(tokens: tokens, settings: settings) }.value
    }
    private func leaveAgent(_ id: String, tokens: AgoraTranscriptionTokens) async {
        let client = self.client
        await Task.detached { try? await client.leave(agentID: id, tokens: tokens) }.value
    }
    func cancel() async {
        guard !closed else { return }
        closed = true; renewal?.cancel(); renewal = nil
        await publisher.stop()
        if let id = agentID, let credentials = tokens {
            await leaveAgent(id, tokens: credentials)
        }
        agentID = nil
    }
}
