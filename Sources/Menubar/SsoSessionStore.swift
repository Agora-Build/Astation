import Foundation
import CryptoKit

/// Encrypted single-entry SSO session store.
///
/// File format: AES-GCM combined blob (nonce + ciphertext + tag) of the
/// SsoSession JSON. Key is derived via HKDF/SHA-256 from the hardware UUID,
/// so the file cannot be decrypted on another machine.
///
/// Default path: ~/Library/Application Support/Astation/credentials.enc
final class SsoSessionStore {

    private let storageURL: URL
    private let symmetricKey: SymmetricKey

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageURL = appSupport
                .appendingPathComponent("Astation")
                .appendingPathComponent("credentials.enc")
        }

        let uuid = MachineIdentity.hardwareUUID()
        let ikm = SymmetricKey(data: Data(uuid.utf8))
        self.symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("com.agora.astation".utf8),
            info: Data("credentials".utf8),
            outputByteCount: 32
        )
    }

    var hasSession: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    func load() -> SsoSession? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        guard let data = try? Data(contentsOf: storageURL),
              let plain = try? decrypt(data) else {
            // Corrupt or different-machine ciphertext: treat as no session.
            return nil
        }
        if let session = try? JSONDecoder().decode(SsoSession.self, from: plain) {
            return session
        }
        // Old-shape file (customer_id/customer_secret): delete and return nil.
        if let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
           obj["customerId"] != nil || obj["customer_id"] != nil {
            try? FileManager.default.removeItem(at: storageURL)
            Log.info("[SSO] Deleted old-shape credentials file; please sign in again.")
        }
        return nil
    }

    func save(_ session: SsoSession) throws {
        let json = try JSONEncoder().encode(session)
        let cipher = try encrypt(json)

        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try cipher.write(to: storageURL)

        // 0600 permissions: owner read/write only.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: storageURL.path
        )
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }

    // MARK: - Test hook

    /// Encrypt arbitrary bytes with this store's key — only for tests that need
    /// to seed an "old-shape file" scenario. Not for production use.
    func _testEncrypt(_ plain: Data) throws -> Data {
        try encrypt(plain)
    }

    // MARK: - AES-GCM

    private func encrypt(_ plain: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: symmetricKey)
        guard let combined = sealed.combined else {
            throw SsoError.network("AES.GCM.seal returned nil combined")
        }
        return combined
    }

    private func decrypt(_ cipher: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: cipher)
        return try AES.GCM.open(box, using: symmetricKey)
    }
}
