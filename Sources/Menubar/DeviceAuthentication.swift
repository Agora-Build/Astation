import CryptoKit
import Foundation

enum DeviceAuthentication {
    static let protocolVersion = "2"

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
        let expected = proof(
            token: token,
            challenge: challenge,
            astationId: astationId,
            atemId: atemId,
            sessionId: sessionId
        )
        return constantTimeEqual(candidate.lowercased(), expected)
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

    fileprivate static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Secure random generation failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
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
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)

        fileURL = baseDirectory.appendingPathComponent(Self.filename)
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            token = existing
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return
        }

        let generated = DeviceAuthentication.randomHex(byteCount: 32)
        try Data((generated + "\n").utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        token = generated
    }
}
