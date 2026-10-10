import Foundation
import LocalAuthentication
import Darwin

/// What a user saves off this Mac to get the Astation account back on another
/// one: the Astation ID (the account the relay files memory, skills and vaults
/// under) and the relay it was used with. The ID isn't a secret on its own,
/// since signing in to the relay also needs this Mac's device key, but
/// recovery isn't possible without it.
struct RecoveryKit: Equatable {
    let astationId: String
    let relayURL: String
    let recoveryKey: String?

    init(astationId: String, relayURL: String, recoveryKey: String? = nil) {
        self.astationId = astationId
        self.relayURL = relayURL
        self.recoveryKey = recoveryKey
    }

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
        let text = """
        Astation recovery kit
        Keep this somewhere off this Mac, for example in a password manager.
        On a new Mac: Astation Settings → Security → Restore Account…

        \(Self.idLabel) \(astationId)
        \(Self.relayLabel) \(relayURL)
        Created: \(date)
        """
        return recoveryKey.map { text + "\nRecovery key: " + $0 } ?? text
    }

    /// Reads a kit back from its saved text, or from the bare ID pasted on its
    /// own. Returns nil when no valid Astation ID is found.
    static func parse(_ text: String) -> RecoveryKit? {
        var id: String?
        var relay: String?
        var recovery: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(idLabel) {
                guard id == nil else { return nil }
                id = line.dropFirst(idLabel.count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(relayLabel) {
                guard relay == nil else { return nil }
                relay = line.dropFirst(relayLabel.count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Recovery key:") {
                guard recovery == nil else { return nil }
                let value = line.dropFirst("Recovery key:".count).trimmingCharacters(in: .whitespaces)
                let compact = value.filter { $0 != "-" }
                guard compact.count == 52, compact.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }),
                      compact.last == "A" || compact.last == "Q" else { return nil }
                recovery = value
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
        return RecoveryKit(astationId: canonicalId, relayURL: normalizedRelay, recoveryKey: recovery)
    }

    /// Writes sensitive recovery material and fails closed if the resulting
    /// file cannot be restricted to the current user.
    static func save(_ text: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".astation-recovery-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor); unlink(temporary.path) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Restrict the temporary file before writing any recovery secret, then replace atomically.
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & 0o777 == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
