import Foundation
import CryptoKit

/// Agora API credentials (customer ID + secret from console.agora.io)
struct AgoraCredentials: Codable {
    let customerId: String
    let customerSecret: String
}

/// Manages encrypted credential storage using machine-bound AES-GCM encryption.
/// Credentials are encrypted with a key derived from the machine's hardware UUID.
class CredentialManager {

    private let storageURL: URL
    private let symmetricKey: SymmetricKey

    init() {
        // Storage path: ~/Library/Application Support/Astation/credentials.enc
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let astationDir = appSupport.appendingPathComponent("Astation")
        self.storageURL = astationDir.appendingPathComponent("credentials.enc")

        // Derive 256-bit key from hardware UUID via HKDF
        let uuid = MachineIdentity.hardwareUUID()
        let inputKey = SymmetricKey(data: Data(uuid.utf8))
        let salt = Data("com.agora.astation".utf8)
        let info = Data("credentials".utf8)
        self.symmetricKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey, salt: salt, info: info, outputByteCount: 32)
    }

    /// Save credentials encrypted to disk.
    func save(_ credentials: AgoraCredentials) throws {
        let jsonData = try JSONEncoder().encode(credentials)
        let sealedBox = try AES.GCM.seal(jsonData, using: symmetricKey)

        // Combined representation includes nonce + ciphertext + tag
        guard let combined = sealedBox.combined else {
            throw CredentialError.encryptionFailed
        }

        // Ensure directory exists
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try combined.write(to: storageURL)
    }

    /// Load and decrypt credentials from disk. Returns nil if no file or decryption fails.
    func load() -> AgoraCredentials? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try JSONDecoder().decode(AgoraCredentials.self, from: decrypted)
        } catch {
            // Decryption failed -- wrong key, corrupted file, or tampered data
            return nil
        }
    }

    /// Delete stored credentials.
    func delete() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }

    /// Whether credentials are stored on disk.
    var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    enum CredentialError: Error, LocalizedError {
        case encryptionFailed

        var errorDescription: String? {
            switch self {
            case .encryptionFailed:
                return "Failed to encrypt credentials"
            }
        }
    }
}
