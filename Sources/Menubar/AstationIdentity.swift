import Foundation

/// Manages persistent Astation identity across restarts.
/// Each Astation instance has a unique ID that persists across sessions.
/// This allows Atem clients to maintain separate sessions for different Astation instances.
class AstationIdentity {
    static let shared = AstationIdentity()

    /// Unique identifier for this Astation instance
    let id: String

    private init() {
        let path = Self.identityPath()

        // Try to load existing identity
        if let existing = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            self.id = existing
            Log.info("Loaded Astation identity: \(id)")
        } else {
            // Generate new identity
            self.id = "astation-\(UUID().uuidString)"

            // Save to disk
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try id.write(to: path, atomically: true, encoding: .utf8)
                Log.info("Generated new Astation identity: \(id)")
            } catch {
                Log.error("Failed to save Astation identity: \(error)")
            }
        }
    }

    /// Path to identity file: ~/Library/Application Support/Astation/identity.txt
    private static func identityPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let astationDir = appSupport.appendingPathComponent("Astation")
        return astationDir.appendingPathComponent("identity.txt")
    }

    /// For testing: clear saved identity (will regenerate on next access)
    #if DEBUG
    static func clearForTesting() {
        let path = identityPath()
        try? FileManager.default.removeItem(at: path)
    }
    #endif
}
