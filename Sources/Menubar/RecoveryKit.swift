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
    static func isValidAstationId(_ id: String) -> Bool {
        guard id.hasPrefix(idPrefix) else { return false }
        return UUID(uuidString: String(id.dropFirst(idPrefix.count))) != nil
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
        var relay = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(idLabel) {
                id = line.dropFirst(idLabel.count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(relayLabel) {
                relay = line.dropFirst(relayLabel.count).trimmingCharacters(in: .whitespaces)
            }
        }
        if id == nil {
            let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidAstationId(bare) { id = bare }
        }
        guard let id, isValidAstationId(id) else { return nil }
        return RecoveryKit(astationId: id, relayURL: relay)
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
