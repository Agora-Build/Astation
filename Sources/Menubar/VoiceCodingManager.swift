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
    private let silenceTimeoutSeconds: TimeInterval = 5.0

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    // MARK: - PTT (Push-to-Talk)

    /// Called on Ctrl+V key-down. Creates a relay session and unmutes mic.
    func startPTT() {
        guard mode == .off else {
            Log.info("[VoiceCoding] startPTT ignored — mode is \(mode)")
            return
        }
        mode = .ptt
        Log.info("[VoiceCoding] PTT started")

        createRelaySession { [weak self] sessionId in
            guard let self = self, let sessionId = sessionId else {
                Log.error("[VoiceCoding] Failed to create relay session for PTT")
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
        }
    }

    /// Called on Ctrl+V key-up. Mutes mic, triggers relay, sends voiceRequest.
    func stopPTT() {
        guard mode == .ptt else {
            Log.info("[VoiceCoding] stopPTT ignored — mode is \(mode)")
            return
        }
        Log.info("[VoiceCoding] PTT stopped")

        // Mute mic immediately
        if hubManager.rtcManager.isInChannel {
            hubManager.rtcManager.muteMic(true)
        }

        guard let sessionId = activeSessionId else {
            Log.warn("[VoiceCoding] stopPTT but no active session")
            cleanup()
            return
        }

        isWaitingForResponse = true

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
        Log.info("[VoiceCoding] Hands-Free started")

        createRelaySession { [weak self] sessionId in
            guard let self = self, let sessionId = sessionId else {
                Log.error("[VoiceCoding] Failed to create relay session for Hands-Free")
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
            guard let sessionId = activeSessionId else { return }

            isWaitingForResponse = true
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

    // MARK: - Internal

    private func sendVoiceRequestToAtem(sessionId: String, accumulatedText: String) {
        guard let atemId = targetAtemId ?? hubManager.routeToFocusedAtem() else {
            Log.warn("[VoiceCoding] No Atem available — dropping voice request")
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
                self.cleanup()
                return
            }
            self.activeSessionId = sessionId
            self.lastSpeechActivity = Date()
            Log.info("[VoiceCoding] Hands-Free session recycled: \(sessionId)")
        }
    }

    private func cleanup() {
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        if let sessionId = activeSessionId {
            deleteRelaySession(sessionId: sessionId)
        }
        activeSessionId = nil
        targetAtemId = nil
        isWaitingForResponse = false
        lastSpeechActivity = nil
        mode = .off
        Log.info("[VoiceCoding] Cleaned up — mode is off")
    }
}
