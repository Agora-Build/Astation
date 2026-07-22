import CryptoKit
import Darwin
import Foundation
import Security

enum DeviceAuthentication {
    static let protocolVersion = "2"
    static let maxAtemIdBytes = 255
    static let maxSessionIdBytes = 128
    static let maxRequestIdBytes = 128
    static let maxPairingCodeBytes = 32

    static func makeChallenge() -> String {
        randomHex(byteCount: 32)
    }

    static func deviceLabel(_ value: String) -> String {
        let cleaned = value.unicodeScalars.lazy
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(255)
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func proof(
        token: String,
        challenge: String,
        astationId: String,
        atemId: String,
        sessionId: String
    ) -> String {
        let message = canonicalMessage(
            challenge: challenge,
            astationId: astationId,
            atemId: atemId,
            sessionId: sessionId
        )
        let key = SymmetricKey(data: Data(token.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(
        proof candidate: String,
        token: String,
        challenge: String,
        astationId: String,
        atemId: String,
        sessionId: String
    ) -> Bool {
        guard isValidAtemId(atemId),
              isValidSessionId(sessionId),
              isValidProof(candidate) else {
            return false
        }
        let expected = proof(
            token: token,
            challenge: challenge,
            astationId: astationId,
            atemId: atemId,
            sessionId: sessionId
        )
        return constantTimeEqual(candidate.lowercased(), expected)
    }

    static func isValidAtemId(_ value: String) -> Bool {
        isBoundedText(value, maxBytes: maxAtemIdBytes)
    }

    static func isValidSessionId(_ value: String) -> Bool {
        isBoundedText(value, maxBytes: maxSessionIdBytes)
    }

    static func isValidRequestId(_ value: String) -> Bool {
        isBoundedText(value, maxBytes: maxRequestIdBytes)
    }

    static func isValidPairingCode(_ value: String) -> Bool {
        isBoundedText(value, maxBytes: maxPairingCodeBytes)
    }

    static func isValidBootstrapToken(_ value: String) -> Bool {
        isValidProof(value)
    }

    private static func canonicalMessage(
        challenge: String,
        astationId: String,
        atemId: String,
        sessionId: String
    ) -> String {
        "astation-auth-v2\n\(challenge)\n\(astationId)\n\(atemId)\n\(sessionId)"
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func isBoundedText(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isValidProof(_ value: String) -> Bool {
        var count = 0
        for byte in value.utf8 {
            count += 1
            guard count <= 64,
                  (48...57).contains(byte) ||
                  (65...70).contains(byte) ||
                  (97...102).contains(byte) else {
                return false
            }
        }
        return count == 64
    }

    fileprivate static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Secure random generation failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct RelayAuthenticationChallengeStore {
    private struct Entry {
        let challenge: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let maxPending: Int
    private let lifetime: TimeInterval

    init(maxPending: Int = 64, lifetime: TimeInterval = 120) {
        self.maxPending = maxPending
        self.lifetime = lifetime
    }

    mutating func issue(clientId: String, challenge: String, now: Date = Date()) -> Bool {
        removeExpired(now: now)
        guard entries[clientId] != nil || entries.count < maxPending else { return false }
        entries[clientId] = Entry(
            challenge: challenge,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        return true
    }

    mutating func challenge(for clientId: String, now: Date = Date()) -> String? {
        removeExpired(now: now)
        return entries[clientId]?.challenge
    }

    mutating func remove(clientId: String) {
        entries.removeValue(forKey: clientId)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func removeExpired(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

/// A same-user secret shared by Astation and local Atem processes. It removes
/// interactive pairing on loopback without trusting arbitrary browser pages.
final class LocalBootstrapStore {
    static let filename = "local-bootstrap-token"

    let token: String
    let fileURL: URL

    init(directory: URL? = nil) throws {
        let fileManager = FileManager.default
        let baseDirectory = directory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Astation", isDirectory: true)

        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryValues = try baseDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        let directoryAttributes = try fileManager.attributesOfItem(atPath: baseDirectory.path)
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              Self.isOwnedByCurrentUser(directoryAttributes) else {
            throw LocalBootstrapStoreError.insecureDirectory
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)

        fileURL = baseDirectory.appendingPathComponent(Self.filename)
        if Self.itemExists(at: fileURL, fileManager: fileManager) {
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            if let attributes,
               Self.isSecureTokenFile(fileURL, attributes: attributes),
               let existing = try? String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               DeviceAuthentication.isValidBootstrapToken(existing) {
                token = existing
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return
            }

            Log.warn("Replacing insecure or malformed local bootstrap token")
            try fileManager.removeItem(at: fileURL)
        }

        let generated = DeviceAuthentication.randomHex(byteCount: 32)
        try Data((generated + "\n").utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        token = generated
    }

    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isSecureTokenFile(
        _ url: URL,
        attributes: [FileAttributeKey: Any]
    ) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return false
        }
        return values?.isRegularFile == true &&
            values?.isSymbolicLink != true &&
            isOwnedByCurrentUser(attributes) &&
            permissions & 0o077 == 0
    }

    private static func isOwnedByCurrentUser(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
}

private enum LocalBootstrapStoreError: Error {
    case insecureDirectory
}
