import Foundation
import LocalAuthentication

/// What a user saves off this Mac to get the Astation account back on another
/// one: the Astation ID (the account the relay files memory, skills and vaults
/// under) and the relay it was used with. The ID isn't a secret on its own,
/// since signing in to the relay also needs this Mac's device key, but
/// recovery isn't possible without it.
struct RecoveryKit: Equatable {
    let astationId: String
    let relayURL: String

    static let idPrefix = "astation-"
    private static let idLabel = "Astation ID:"
    private static let relayLabel = "Relay:"

    /// `astation-` followed by a UUID, the form `AstationIdentity` generates.
    static func canonicalAstationId(_ id: String) -> String? {
        guard id.lowercased().hasPrefix(idPrefix),
              let uuid = UUID(uuidString: String(id.dropFirst(idPrefix.count))) else { return nil }
        return "\(idPrefix)\(uuid.uuidString)"
    }

    static func isValidAstationId(_ id: String) -> Bool {
        canonicalAstationId(id) != nil
    }

    static func identifiesSameAstation(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = canonicalAstationId(lhs),
              let right = canonicalAstationId(rhs) else { return false }
        return left == right
    }

    /// The text the user saves (password manager, file, paper).
    func text(createdAt: Date = Date()) -> String {
        let date = ISO8601DateFormatter.string(from: createdAt, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        return """
        Astation recovery kit
        Keep this somewhere off this Mac, for example in a password manager.
        On a new Mac: Astation Settings → Security → Restore Account…

        \(Self.idLabel) \(astationId)
        \(Self.relayLabel) \(relayURL)
        Created: \(date)
        """
    }

    /// Reads a kit back from its saved text, or from the bare ID pasted on its
    /// own. Returns nil when no valid Astation ID is found.
    static func parse(_ text: String) -> RecoveryKit? {
        var id: String?
        var relay: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(idLabel) {
                guard id == nil else { return nil }
                id = line.dropFirst(idLabel.count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(relayLabel) {
                guard relay == nil else { return nil }
                relay = line.dropFirst(relayLabel.count).trimmingCharacters(in: .whitespaces)
            }
        }
        if id == nil {
            let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidAstationId(bare) { id = bare }
        }
        guard let id, let canonicalId = canonicalAstationId(id) else { return nil }
        let normalizedRelay: String
        if let relay {
            guard let validated = StationRelayURL.validatedBase(relay) else { return nil }
            normalizedRelay = validated
        } else {
            normalizedRelay = ""
        }
        return RecoveryKit(astationId: canonicalId, relayURL: normalizedRelay)
    }

    /// Writes sensitive recovery material and fails closed if the resulting
    /// file cannot be restricted to the current user.
    static func save(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o777 == 0o600 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// `astation-4630…7279625`: enough to recognize the account, shown
    /// before the user authenticates.
    static func masked(_ id: String) -> String {
        let rest = id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : id
        guard rest.count > 11 else { return id }
        return "\(idPrefix)\(rest.prefix(4))…\(rest.suffix(7))"
    }
}

/// Touch ID, or the Mac's password when Touch ID isn't available or fails.
enum DeviceOwnerAuth {
    /// Calls `completion` on the main queue with whether the user authenticated.
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.error("[RecoveryKit] Device owner authentication unavailable: \(error?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async { completion(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
