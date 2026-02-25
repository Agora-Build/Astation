import Foundation

enum VoiceCodingMode {
    case off
    case ptt
    case handsFree
}

/// Orchestrates voice coding sessions using the relay server.
///
/// Two modes:
/// - **PTT** (Push-to-Talk): Ctrl+V down creates a relay session and unmutes the mic.
///   Ctrl+V up mutes, triggers the relay to get accumulated text, and sends a
///   `voiceRequest` to the target Atem.
/// - **Hands-Free**: Continuously listens and auto-triggers after 5 seconds of silence.
class VoiceCodingManager: NSObject {
    private let hubManager: AstationHubManager
    private(set) var mode: VoiceCodingMode = .off
    private(set) var activeSessionId: String?
    private(set) var isWaitingForResponse: Bool = false
    private var targetAtemId: String?
    private var handsFreeTimer: Timer?
    private var lastSpeechActivity: Date?
    private var pendingRtcJoinCompletions: [((Bool) -> Void)] = []
    private var rtcJoinObserver: NSObjectProtocol?
    private var rtcJoinTimeout: Timer?
    private var isPreparing: Bool = false
    private let silenceTimeoutSeconds: TimeInterval = 5.0

    // ConvoAI agent lifecycle
    private let convoAIClient = ConvoAIClient()
    private(set) var activeAgentId: String?
    private(set) var isAgentReady: Bool = false
    private var deferredStopPTT: Bool = false

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    private func updateStage(_ text: String, autoHideAfter: TimeInterval? = nil) {
        VoiceCodingHUD.shared.show(text, autoHideAfter: autoHideAfter)
    }

    private func ensureRTCJoined(completion: @escaping (Bool) -> Void) {
        if hubManager.rtcManager.isInChannel {
            completion(true)
            return
        }

        pendingRtcJoinCompletions.append(completion)
        if rtcJoinObserver != nil {
            return
        }

        let projects = hubManager.getProjects()
        guard let project = projects.first else {
            updateStage("Voice: No projects configured", autoHideAfter: 2.0)
            finishRtcJoin(success: false)
            return
        }

        let channel = "astation-default"
        let uid = Int.random(in: 1000...9999)
        updateStage("Voice: Joining RTC…")
        hubManager.initializeRTC(appId: project.vendorKey)
        hubManager.joinRTCChannel(channel: channel, uid: uid, projectId: project.id)

        rtcJoinObserver = NotificationCenter.default.addObserver(
            forName: .rtcJoinSuccess,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finishRtcJoin(success: true)
        }

        rtcJoinTimeout = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.finishRtcJoin(success: false)
        }
    }

    private func finishRtcJoin(success: Bool) {
        if let observer = rtcJoinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        rtcJoinObserver = nil
        rtcJoinTimeout?.invalidate()
        rtcJoinTimeout = nil

        if !success {
            updateStage("Voice: RTC join failed", autoHideAfter: 2.0)
        } else {
            updateStage("Voice: RTC joined")
        }

        let completions = pendingRtcJoinCompletions
        pendingRtcJoinCompletions.removeAll()
        for completion in completions {
            completion(success)
        }
    }

// MARK: - PTT (Push-to-Talk)

    /// Called on Ctrl+V key-down. Creates a relay session and unmutes mic.
    func startPTT() {
        guard mode == .off else {
            Log.info("[VoiceCoding] startPTT ignored — mode is \(mode)")
            return
        }
        mode = .ptt
        isPreparing = true
        updateStage("Voice: Starting PTT…")
        Log.info("[VoiceCoding] PTT started")

        ensureRTCJoined { [weak self] joined in
            guard let self = self else { return }
            guard joined else {
                self.cleanup()
                return
            }
            self.beginPTTWorkflow()
        }
    }

    private func beginPTTWorkflow() {
        updateStage("Voice: Creating session…")
        createRelaySession { [weak self] sessionId in
            guard let self = self, let sessionId = sessionId else {
                Log.error("[VoiceCoding] Failed to create relay session for PTT")
                self?.updateStage("Voice: Session failed", autoHideAfter: 2.0)
                self?.cleanup()
                return
            }
            self.activeSessionId = sessionId
            self.targetAtemId = self.hubManager.routeToFocusedAtem()
            Log.info("[VoiceCoding] PTT session created: \(sessionId)")

            // Unmute mic
            if self.hubManager.rtcManager.isInChannel {
                self.hubManager.rtcManager.muteMic(false)
            }

            // Create ConvoAI agent for ASR/TTS
            self.updateStage("Voice: Starting agent…")
            self.createConvoAIAgent(sessionId: sessionId)
        }
    }

    /// Called on Ctrl+V key-up. Mutes mic, triggers relay, sends voiceRequest.
    func stopPTT() {
        guard mode == .ptt else {
            Log.info("[VoiceCoding] stopPTT ignored — mode is \(mode)")
            return
        }

        if isPreparing {
            Log.info("[VoiceCoding] stopPTT deferred — still preparing")
            deferredStopPTT = true
            return
        }

        // If the ConvoAI agent isn't ready yet, defer the stop until it is
        guard isAgentReady else {
            Log.info("[VoiceCoding] stopPTT deferred — agent not ready yet")
            deferredStopPTT = true
            return
        }

        Log.info("[VoiceCoding] PTT stopped")
        updateStage("Voice: Processing…")

        // Mute mic immediately
        if hubManager.rtcManager.isInChannel {
            hubManager.rtcManager.muteMic(true)
        }

        guard let sessionId = activeSessionId else {
            Log.warn("[VoiceCoding] stopPTT but no active session")
            updateStage("Voice: No active session", autoHideAfter: 1.5)
            cleanup()
            return
        }

        isWaitingForResponse = true
        updateStage("Voice: Waiting for response…")

        triggerRelaySession(sessionId: sessionId) { [weak self] accumulatedText in
            guard let self = self else { return }
            guard let text = accumulatedText, !text.isEmpty else {
                Log.info("[VoiceCoding] No accumulated text from relay — cleaning up")
                self.cleanup()
                return
            }
            self.sendVoiceRequestToAtem(sessionId: sessionId, accumulatedText: text)
        }
    }

    // MARK: - Hands-Free

    /// Start hands-free mode: create session, unmute, start silence timer.
    func startHandsFree() {
        guard mode == .off else {
            Log.info("[VoiceCoding] startHandsFree ignored — mode is \(mode)")
            return
        }
        mode = .handsFree
        isPreparing = true
        updateStage("Voice: Starting Hands-Free…")
        Log.info("[VoiceCoding] Hands-Free started")

        ensureRTCJoined { [weak self] joined in
            guard let self = self else { return }
            guard joined else {
                self.cleanup()
                return
            }
            self.beginHandsFreeWorkflow()
        }
    }

    private func beginHandsFreeWorkflow() {
        updateStage("Voice: Creating session…")
        createRelaySession { [weak self] sessionId in
            guard let self = self, let sessionId = sessionId else {
                Log.error("[VoiceCoding] Failed to create relay session for Hands-Free")
                self?.updateStage("Voice: Session failed", autoHideAfter: 2.0)
                self?.cleanup()
                return
            }
            self.activeSessionId = sessionId
            self.targetAtemId = self.hubManager.routeToFocusedAtem()
            self.lastSpeechActivity = Date()
            Log.info("[VoiceCoding] Hands-Free session created: \(sessionId)")

            // Unmute mic
            if self.hubManager.rtcManager.isInChannel {
                self.hubManager.rtcManager.muteMic(false)
            }

            // Create ConvoAI agent for ASR/TTS (persists across session recycling)
            self.updateStage("Voice: Starting agent…")
            self.createConvoAIAgent(sessionId: sessionId)

            // Start silence-check timer on main thread
            DispatchQueue.main.async {
                self.handsFreeTimer = Timer.scheduledTimer(
                    timeInterval: 1.0,
                    target: self,
                    selector: #selector(self.checkSilenceTimeout),
                    userInfo: nil,
                    repeats: true
                )
            }
        }
    }

    /// Stop hands-free mode from user action (menu).
    func stopHandsFree() {
        guard mode == .handsFree else { return }
        Log.info("[VoiceCoding] Hands-Free stopped by user")
        updateStage("Voice: Stopping…", autoHideAfter: 1.0)
        if hubManager.rtcManager.isInChannel {
            hubManager.rtcManager.muteMic(true)
        }
        cleanup()
    }

    @objc private func checkSilenceTimeout() {
        guard mode == .handsFree, let lastActivity = lastSpeechActivity else { return }
        guard !isWaitingForResponse else { return }

        let elapsed = Date().timeIntervalSince(lastActivity)
        if elapsed >= silenceTimeoutSeconds {
            Log.info("[VoiceCoding] Silence timeout (\(silenceTimeoutSeconds)s) — triggering")
            updateStage("Voice: Processing…")
            guard let sessionId = activeSessionId else { return }

            isWaitingForResponse = true
        updateStage("Voice: Waiting for response…")
            triggerRelaySession(sessionId: sessionId) { [weak self] accumulatedText in
                guard let self = self else { return }
                guard let text = accumulatedText, !text.isEmpty else {
                    Log.info("[VoiceCoding] Hands-Free: no text — recycling session")
                    self.recycleHandsFreeSession()
                    return
                }
                self.sendVoiceRequestToAtem(sessionId: sessionId, accumulatedText: text)
            }
        }
    }

    /// Called from audio callback to signal speech activity.
    func notifySpeechActivity() {
        lastSpeechActivity = Date()
    }

    // MARK: - Response from Atem

    func handleVoiceResponse(sessionId: String, success: Bool, message: String) {
        Log.info("[VoiceCoding] Response for \(sessionId): success=\(success) — \(message)")
        isWaitingForResponse = false
        updateStage(success ? "Voice: Done" : "Voice: Failed", autoHideAfter: 1.5)

        // Post notification for UI updates
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("VoiceCodingResponseReceived"),
                object: nil,
                userInfo: [
                    "sessionId": sessionId,
                    "success": success,
                    "message": message
                ]
            )
        }

        // Clean up the relay session
        deleteRelaySession(sessionId: sessionId)

        if mode == .ptt {
            cleanup()
        } else if mode == .handsFree {
            // Recycle: create a fresh session for the next utterance
            recycleHandsFreeSession()
        }
    }

    // MARK: - Relay HTTP

    private func createRelaySession(completion: @escaping (String?) -> Void) {
        let urlString = "\(hubManager.stationRelayUrl)/api/voice-sessions"
        guard let url = URL(string: urlString) else {
            Log.error("[VoiceCoding] Invalid create URL: \(urlString)")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [:])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Log.error("[VoiceCoding] Create session failed: \(error)")
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 || http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["session_id"] as? String else {
                Log.error("[VoiceCoding] Create session: unexpected response")
                completion(nil)
                return
            }
            Log.info("[VoiceCoding] Relay session created: \(sessionId)")
            completion(sessionId)
        }.resume()
    }

    private func triggerRelaySession(sessionId: String, completion: @escaping (String?) -> Void) {
        let urlString = "\(hubManager.stationRelayUrl)/api/voice-sessions/\(sessionId)/trigger"
        guard let url = URL(string: urlString) else {
            Log.error("[VoiceCoding] Invalid trigger URL: \(urlString)")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Log.error("[VoiceCoding] Trigger session failed: \(error)")
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accumulatedText = json["accumulated_text"] as? String else {
                Log.error("[VoiceCoding] Trigger session: unexpected response")
                completion(nil)
                return
            }
            Log.info("[VoiceCoding] Trigger result: \(accumulatedText.prefix(80))...")
            completion(accumulatedText)
        }.resume()
    }

    private func deleteRelaySession(sessionId: String) {
        let urlString = "\(hubManager.stationRelayUrl)/api/voice-sessions/\(sessionId)"
        guard let url = URL(string: urlString) else {
            Log.error("[VoiceCoding] Invalid delete URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.error("[VoiceCoding] Delete session failed: \(error)")
                return
            }
            if let http = response as? HTTPURLResponse {
                Log.info("[VoiceCoding] Delete session \(sessionId): \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: - ConvoAI Agent

    private func createConvoAIAgent(sessionId: String) {
        guard let credentials = hubManager.credentialManager.load(),
              let appId = hubManager.projects.first?.vendorKey,
              let channel = hubManager.rtcManager.currentChannel else {
            Log.warn("[VoiceCoding] Missing credentials/appId/channel — skipping ConvoAI agent")
            updateStage("Voice: Missing credentials", autoHideAfter: 2.0)
            cleanup()
            return
        }

        let localUid = String(hubManager.rtcManager.currentUid)
        let relayUrl = hubManager.stationRelayUrl

        Task {
            do {
                let agentToken = await hubManager.generateTokenForConvoAIAgent(channel: channel) ?? ""
                let llmUrl = "\(relayUrl)/api/llm/chat?session_id=\(sessionId)"

                let agentResp = try await self.convoAIClient.createAgent(
                    appId: appId,
                    credentials: credentials,
                    channel: channel,
                    agentRtcUid: "1001",
                    remoteRtcUid: localUid,
                    token: agentToken,
                    llmUrl: llmUrl,
                    systemPrompt: "You are a voice coding assistant."
                )
                self.activeAgentId = agentResp.agentId
                self.isAgentReady = true
                self.isPreparing = false
                Log.info("[VoiceCoding] ConvoAI agent created: \(agentResp.agentId)")
                self.updateStage(self.mode == .handsFree ? "Voice: Listening…" : "Voice: Listening…")

                if self.deferredStopPTT {
                    Log.info("[VoiceCoding] Executing deferred stopPTT")
                    self.stopPTT()
                }
            } catch {
                Log.error("[VoiceCoding] ConvoAI agent creation failed: \(error)")
                self.updateStage("Voice: Agent failed", autoHideAfter: 2.0)
                self.cleanup()
            }
        }
    }

    private func stopConvoAIAgent() {
        guard let agentId = activeAgentId,
              let credentials = hubManager.credentialManager.load(),
              let appId = hubManager.projects.first?.vendorKey else {
            return
        }

        Task {
            do {
                try await convoAIClient.stopAgent(appId: appId, credentials: credentials, agentId: agentId)
                Log.info("[VoiceCoding] ConvoAI agent stopped: \(agentId)")
            } catch {
                Log.error("[VoiceCoding] Failed to stop ConvoAI agent: \(error)")
            }
        }
    }

    // MARK: - Internal

    private func sendVoiceRequestToAtem(sessionId: String, accumulatedText: String) {
        guard let atemId = targetAtemId ?? hubManager.routeToFocusedAtem() else {
            Log.warn("[VoiceCoding] No Atem available — dropping voice request")
            updateStage("Voice: No target device", autoHideAfter: 2.0)
            cleanup()
            return
        }

        let message = AstationMessage.voiceRequest(
            sessionId: sessionId,
            accumulatedText: accumulatedText,
            relayUrl: hubManager.stationRelayUrl
        )
        hubManager.sendHandler?(message, atemId)
        Log.info("[VoiceCoding] Sent voiceRequest to \(atemId.prefix(8))...: \(accumulatedText.prefix(60))...")
    }

    private func recycleHandsFreeSession() {
        guard mode == .handsFree else { return }
        isWaitingForResponse = false
        activeSessionId = nil

        // Create a fresh session for the next utterance
        createRelaySession { [weak self] sessionId in
            guard let self = self, self.mode == .handsFree else { return }
            guard let sessionId = sessionId else {
                Log.error("[VoiceCoding] Failed to recycle hands-free session")
                self.updateStage("Voice: Session failed", autoHideAfter: 2.0)
                self.cleanup()
                return
            }
            self.activeSessionId = sessionId
            self.lastSpeechActivity = Date()
            self.updateStage("Voice: Listening…")
            Log.info("[VoiceCoding] Hands-Free session recycled: \(sessionId)")
        }
    }

    private func cleanup() {
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        if let sessionId = activeSessionId {
            deleteRelaySession(sessionId: sessionId)
        }

        // Stop the ConvoAI agent if one is active
        stopConvoAIAgent()

        activeSessionId = nil
        targetAtemId = nil
        isWaitingForResponse = false
        lastSpeechActivity = nil
        activeAgentId = nil
        isAgentReady = false
        deferredStopPTT = false
        isPreparing = false
        mode = .off
        Log.info("[VoiceCoding] Cleaned up — mode is off")
    }
}
