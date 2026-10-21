import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

public enum RemoteRecoveryStoreError: LocalizedError {
    case locked
    case keychain(OSStatus)
    case changed
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .locked: return "Another Astation process is using this account's recovery state."
        case .keychain(let status): return "Recovery state is unavailable in the protected Keychain (\(status)). Unlock this device and retry."
        case .changed: return "Recovery state changed outside this operation. Reload it before continuing."
        case .invalidFile: return "The recovery-state lock could not be opened securely."
        }
    }
}

protocol RecoveryCheckpointBackend {
    func read() throws -> Data?
    func write(_ data: Data, creating: Bool) throws
}

private struct KeychainCheckpointBackend: RecoveryCheckpointBackend {
    let account: String
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "build.agora.astation.recovery-v2",
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context]
    }
    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data else { throw RemoteRecoveryStoreError.keychain(status) }
        return bytes
    }
    func write(_ data: Data, creating: Bool) throws {
        let status: OSStatus
        if creating {
            var item = query
            item.removeValue(forKey: kSecUseAuthenticationContext as String)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw RemoteRecoveryStoreError.keychain(status) }
    }
}

/// Own one instance for the entire operation. Its file lock serializes app processes;
/// the Data Protection Keychain atomically stores the secret and complete checkpoint.
@MainActor
public final class RemoteRecoveryStore {
    private let backend: RecoveryCheckpointBackend
    private let descriptor: Int32
    private var expected: Data?
    private var writing = false
    public private(set) var storageUncertain = false

    public convenience init(accountID: String, operation: String = "account") throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validID(operation) else {
            throw RemoteRecoveryError.invalidCheckpoint
        }
        let name = operation + ":" + accountID
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Astation/Account Trust", isDirectory: true)
        try self.init(name: name, directory: directory, backend: KeychainCheckpointBackend(account: name), lockName: accountID)
    }

    init(name: String, directory: URL, backend: RecoveryCheckpointBackend, lockName: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(), chmod(directory.path, 0o700) == 0 else {
            throw RemoteRecoveryStoreError.invalidFile
        }
        let hash = SHA256.hash(data: Data((lockName ?? name).utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(hash + ".lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteRecoveryStoreError.invalidFile }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
                throw RemoteRecoveryStoreError.invalidFile
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RemoteRecoveryStoreError.locked }
            expected = try backend.read()
            self.backend = backend
            descriptor = fd
        } catch { close(fd); throw error }
    }

    deinit { close(descriptor) }

    public func read() throws -> Data? {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !writing else { throw RemoteRecoveryError.busy }
        guard try backend.read() == expected else {
            storageUncertain = true
            throw RemoteRecoveryStoreError.changed
        }
        return expected
    }

    public func write(_ data: Data) throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !writing else { throw RemoteRecoveryError.busy }
        guard data.count <= 8_388_608 else { throw RemoteRecoveryError.invalidCheckpoint }
        writing = true
        defer { writing = false }
        do {
            guard try backend.read() == expected else { throw RemoteRecoveryStoreError.changed }
            try backend.write(data, creating: expected == nil)
            guard try backend.read() == data else { throw RemoteRecoveryStoreError.changed }
            expected = data
        } catch { storageUncertain = true; throw error }
    }
}
