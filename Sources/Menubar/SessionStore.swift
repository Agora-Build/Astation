import Darwin
import Foundation

/// Session information for a paired Atem device.
/// Sessions expire after 7 days of inactivity.
struct SessionInfo: Codable {
    let id: String
    let hostname: String
    var atemId: String?
    var lastActivity: Date
    let token: String
    let createdAt: Date

    /// Check if session is still valid (not expired).
    /// Expires after 7 days of inactivity.
    var isValid: Bool {
        let age = Date().timeIntervalSince(lastActivity)
        return age < 7 * 24 * 60 * 60  // 7 days in seconds
    }

    /// Get age in seconds since last activity.
    var ageSeconds: TimeInterval {
        return Date().timeIntervalSince(lastActivity)
    }
}

/// Manages pairing sessions for Atem devices.
/// Persists sessions to disk and handles expiry/cleanup.
class SessionStore {
    private var sessions: [String: SessionInfo] = [:]
    private let storePath: URL
    private let queue = DispatchQueue(label: "build.agora.SessionStore", attributes: .concurrent)

    /// Called on the main queue with the session ID after a session is granted
    /// (created, locally refreshed, or authenticated by proof). Used to push a
    /// relay binding. Set once from the main thread.
    var onSessionGranted: ((String) -> Void)?
    /// Called on the main queue with the IDs of sessions that were deleted or
    /// expired. Used to revoke relay bindings. Set once from the main thread.
    var onSessionsRemoved: (([String]) -> Void)?

    init(storageURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let astation = appSupport.appendingPathComponent("Astation")

        try? FileManager.default.createDirectory(
            at: astation,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: astation.path)

        storePath = storageURL ?? astation.appendingPathComponent("sessions.json")

        // Load existing sessions
        loadFromDisk()

        // Clean up expired sessions on startup
        cleanupExpired()

        Log.info("📦 SessionStore initialized at \(storePath.path)")
    }

    /// Validate a session ID. Returns true if session exists and is not expired.
    func validate(sessionId: String) -> Bool {
        return queue.sync {
            guard let session = sessions[sessionId] else {
                Log.debug("❌ Session validation failed: not found (\(sessionId.prefix(8)))")
                return false
            }

            let valid = session.isValid
            if !valid {
                Log.debug("❌ Session validation failed: expired (\(sessionId.prefix(8)), age: \(Int(session.ageSeconds))s)")
            }
            return valid
        }
    }

    /// Refresh session activity timestamp.
    func refresh(sessionId: String) {
        queue.async(flags: .barrier) {
            guard var session = self.sessions[sessionId] else { return }

            session.lastActivity = Date()
            self.sessions[sessionId] = session

            Log.debug("🔄 Session refreshed: \(sessionId.prefix(8)) (hostname: \(session.hostname))")

            // Save to disk after refresh
            self.saveToDisk()
        }
    }

    /// Create a new session after pairing approval.
    func create(hostname: String, atemId: String? = nil) -> SessionInfo {
        let created = queue.sync(flags: .barrier) { () -> SessionInfo in
            let session = SessionInfo(
                id: UUID().uuidString,
                hostname: hostname,
                atemId: atemId,
                lastActivity: Date(),
                token: generateToken(),
                createdAt: Date()
            )

            sessions[session.id] = session

            Log.info("✅ Session created: \(session.id.prefix(8)) (hostname: \(hostname))")

            // Save to disk
            saveToDisk()

            return session
        }
        notifyGranted(created.id)
        return created
    }

    /// Authenticate a device by proving possession of its session token.
    /// Legacy sessions are bound to the first atem_id that proves the token.
    func authenticate(
        sessionId: String,
        atemId: String,
        challenge: String,
        proof: String,
        astationId: String
    ) -> SessionInfo? {
        guard DeviceAuthentication.isValidSessionId(sessionId),
              DeviceAuthentication.isValidAtemId(atemId) else {
            return nil
        }
        let authenticated = queue.sync(flags: .barrier) { () -> SessionInfo? in
            guard var session = sessions[sessionId], session.isValid else { return nil }
            guard session.atemId == nil || session.atemId == atemId else { return nil }
            let bindsLegacySession = session.atemId == nil
            guard DeviceAuthentication.verify(
                proof: proof,
                token: session.token,
                challenge: challenge,
                astationId: astationId,
                atemId: atemId,
                sessionId: sessionId
            ) else { return nil }

            session.atemId = atemId
            session.lastActivity = Date()
            sessions[sessionId] = session
            saveToDisk()
            if bindsLegacySession {
                Log.info("Bound legacy session \(sessionId.prefix(8)) to Atem \(atemId)")
            }
            return session
        }
        if let authenticated {
            notifyGranted(authenticated.id)
        }
        return authenticated
    }

    /// Return one stable device session for a locally authenticated Atem.
    func createOrRefreshLocal(hostname: String, atemId: String) -> SessionInfo {
        let local = queue.sync(flags: .barrier) { () -> SessionInfo in
            if var session = sessions.values.first(where: { $0.atemId == atemId && $0.isValid }) {
                session.lastActivity = Date()
                sessions[session.id] = session
                saveToDisk()
                return session
            }

            let session = SessionInfo(
                id: UUID().uuidString,
                hostname: hostname,
                atemId: atemId,
                lastActivity: Date(),
                token: generateToken(),
                createdAt: Date()
            )
            sessions[session.id] = session
            saveToDisk()
            return session
        }
        notifyGranted(local.id)
        return local
    }

    /// Delete a specific session.
    func delete(sessionId: String) {
        queue.async(flags: .barrier) {
            if let session = self.sessions.removeValue(forKey: sessionId) {
                Log.info("🗑️ Session deleted: \(sessionId.prefix(8)) (hostname: \(session.hostname))")
                self.saveToDisk()
                self.notifyRemoved([sessionId])
            }
        }
    }

    /// Remove every local pairing before changing this Mac to another
    /// Astation identity. This is synchronous so quitting cannot leave old
    /// bearer tokens on disk under the restored account.
    func deleteAll() throws {
        let removedIds = try queue.sync(flags: .barrier) { () throws -> [String] in
            let previous = sessions
            let ids = Array(previous.keys)
            sessions.removeAll()
            do {
                try persistToDisk()
                return ids
            } catch {
                sessions = previous
                throw error
            }
        }
        if !removedIds.isEmpty {
            Log.info("🗑️ Deleted all \(removedIds.count) paired device session(s)")
            notifyRemoved(removedIds)
        }
    }

    /// Get session info if valid.
    func get(sessionId: String) -> SessionInfo? {
        return queue.sync {
            guard let session = sessions[sessionId], session.isValid else {
                return nil
            }
            return session
        }
    }

    /// Get all active (non-expired) sessions.
    func getAllActive() -> [SessionInfo] {
        return queue.sync {
            sessions.values.filter { $0.isValid }
        }
    }

    /// Clean up expired sessions.
    func cleanupExpired() {
        queue.async(flags: .barrier) {
            let expiredIds = self.sessions.filter { !$0.value.isValid }.map { $0.key }
            for id in expiredIds {
                self.sessions.removeValue(forKey: id)
            }

            if !expiredIds.isEmpty {
                Log.info("🧹 Cleaned up \(expiredIds.count) expired session(s)")
                self.saveToDisk()
                self.notifyRemoved(expiredIds)
            }
        }
    }

    // MARK: - Change notifications

    /// Callbacks always hop to the main queue so they never run inside the
    /// store's barrier (a callback reading the store would otherwise deadlock).
    private func notifyGranted(_ sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onSessionGranted?(sessionId)
        }
    }

    private func notifyRemoved(_ sessionIds: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.onSessionsRemoved?(sessionIds)
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        // Must be called from queue with barrier
        do {
            try persistToDisk()
            Log.debug("💾 Sessions saved to disk (\(sessions.count) total)")
        } catch {
            Log.error("Failed to save sessions: \(error)")
        }
    }

    private func persistToDisk() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(sessions)
        try data.write(to: storePath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storePath.path)
    }

    private func loadFromDisk() {
        // Must be called from queue with barrier
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storePath.path) ||
                (try? fileManager.destinationOfSymbolicLink(atPath: storePath.path)) != nil else {
            Log.debug("No existing sessions file found")
            return
        }

        do {
            let values = try storePath.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            let attributes = try fileManager.attributesOfItem(atPath: storePath.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  owner == getuid() else {
                Log.error("Refusing to load insecure sessions file at \(storePath.path)")
                return
            }

            // Close the migration window before bearer tokens are read into memory.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storePath.path
            )
            let data = try Data(contentsOf: storePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            sessions = try decoder.decode([String: SessionInfo].self, from: data)

            Log.info("📂 Loaded \(sessions.count) session(s) from disk")
        } catch {
            Log.error("Failed to load sessions: \(error)")
        }
    }

    // MARK: - Token Generation

    private func generateToken() -> String {
        // Generate a secure random token (32 bytes = 64 hex chars)
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        if result == errSecSuccess {
            return bytes.map { String(format: "%02hhx", $0) }.joined()
        } else {
            // Fallback to UUID if SecRandom fails
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }
}

// MARK: - Testing Helpers

#if DEBUG
extension SessionStore {
    /// Create a session with specific parameters (for testing).
    func createTest(id: String, hostname: String, lastActivity: Date) -> SessionInfo {
        return queue.sync(flags: .barrier) {
            let session = SessionInfo(
                id: id,
                hostname: hostname,
                atemId: nil,
                lastActivity: lastActivity,
                token: generateToken(),
                createdAt: lastActivity
            )

            sessions[session.id] = session
            return session
        }
    }

    /// Get session count (for testing).
    var count: Int {
        return queue.sync {
            sessions.count
        }
    }
}
#endif
