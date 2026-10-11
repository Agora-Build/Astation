import Foundation
import LocalAuthentication
import Security

enum LocalCredentialError: LocalizedError {
    case invalidName, invalidProject, invalidValue, duplicate, changed, missing, corrupt, newer, denied, busy, accountChanged, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a credential name of 1-128 UTF-8 bytes without control characters."
        case .invalidProject: return "Enter a Git remote or a project key such as github.com/owner/repo."
        case .invalidValue: return "Enter a nonempty value of at most 64 KiB."
        case .duplicate: return "That name already exists in this scope. Select it and choose Update."
        case .changed: return "Credentials changed while this action was pending. Refresh and try again."
        case .missing: return "This credential no longer exists. Refresh and try again."
        case .corrupt: return "The credential store is unreadable. Its saved data was retained."
        case .newer: return "Update Astation to read this credential store. Its saved data was retained."
        case .denied: return "Touch ID was cancelled or unavailable. Nothing was changed or copied."
        case .busy: return "Finish the current Touch ID request first."
        case .accountChanged: return "This Mac's identity changed. Reopen Credentials and try again."
        case .keychain(errSecMissingEntitlement): return "Run a provisioned Astation build to use protected credential storage."
        case .keychain: return "Protected credential storage is unavailable. Unlock this Mac and retry."
        }
    }
}

protocol LocalCredentialStorage {
    func read() throws -> Data?
    func write(_ data: Data, creating: Bool) throws
}

struct LocalCredentialKeychainStorage: LocalCredentialStorage {
    static let service = "build.agora.astation.local-credentials-v1"
    let account: String

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service, kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LocalCredentialError.keychain(status) }
        guard let data = result as? Data else { throw LocalCredentialError.corrupt }
        return data
    }

    func write(_ data: Data, creating: Bool) throws {
        let status: OSStatus
        if creating {
            var request = query
            request.removeValue(forKey: kSecUseAuthenticationContext as String)
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            request[kSecValueData as String] = data
            status = SecItemAdd(request as CFDictionary, nil)
        } else {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw LocalCredentialError.keychain(status) }
    }
}

struct LocalCredentialMetadata: Codable, Equatable {
    let id: UUID
    let name: String
    let project: String?
    let version: UInt64
    let updatedAt: Date
    let projectLabel: String?

    init(id: UUID, name: String, project: String?, version: UInt64, updatedAt: Date, projectLabel: String? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.version = version
        self.updatedAt = updatedAt
        self.projectLabel = projectLabel
    }

    var scopeLabel: String { projectLabel ?? project ?? "Global" }
}

struct LocalCredentialSnapshot {
    let revision: UUID?
    let entries: [LocalCredentialMetadata]
}

final class LocalCredentialStore {
    let account: String
    private let storage: LocalCredentialStorage
    private let lock = NSLock()

    private struct Entry: Codable {
        var metadata: LocalCredentialMetadata
        var value: String
    }

    private struct Record: Codable {
        var format = 1
        var revision = UUID()
        var entries: [Entry] = []
    }

    init(account: String, storage: LocalCredentialStorage? = nil) {
        self.account = account
        self.storage = storage ?? LocalCredentialKeychainStorage(account: account)
    }

    static func name(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else {
            throw LocalCredentialError.invalidName
        }
        return value
    }

    static func project(_ raw: String?) throws -> String? {
        try projectLabel(raw)?.lowercased()
    }

    static func projectLabel(_ raw: String?) throws -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 1024 else { throw LocalCredentialError.invalidProject }
        if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") {
            value = String(value.dropFirst(4).prefix(upTo: colon)) + "/" + value[value.index(after: colon)...]
        } else if value.contains("://") {
            guard let url = URLComponents(string: value), ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !url.path.isEmpty else { throw LocalCredentialError.invalidProject }
            value = host + url.path
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].contains("."),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }),
              !value.contains(where: { "@?#\\:".contains($0) }) else { throw LocalCredentialError.invalidProject }
        return value
    }

    static func projectLabels(_ names: [String]) -> [String] {
        var labels: [String: String] = [:]
        for raw in names {
            guard let label = try? projectLabel(raw) else { continue }
            let key = label.lowercased()
            if labels[key] == nil || (labels[key] == key && label != key) { labels[key] = label }
        }
        return labels.keys.sorted().compactMap { labels[$0] }
    }

    static func validateValue(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 65_536 else { throw LocalCredentialError.invalidValue }
    }

    private func read() throws -> Record? {
        guard let data = try storage.read() else { return nil }
        guard let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = header["format"] as? Int else { throw LocalCredentialError.corrupt }
        if format > 1 { throw LocalCredentialError.newer }
        guard format == 1, let record = try? JSONDecoder().decode(Record.self, from: data) else { throw LocalCredentialError.corrupt }
        var names = Set<String>(), ids = Set<UUID>()
        for entry in record.entries {
            guard (try? Self.name(entry.metadata.name)) == entry.metadata.name,
                  (try? Self.project(entry.metadata.project)) == entry.metadata.project,
                  entry.metadata.version > 0, entry.metadata.updatedAt.timeIntervalSince1970.isFinite,
                  ids.insert(entry.metadata.id).inserted,
                  names.insert(Self.binding(entry.metadata.name, entry.metadata.project)).inserted else { throw LocalCredentialError.corrupt }
            if let label = entry.metadata.projectLabel {
                guard (try? Self.projectLabel(label)) == label,
                      (try? Self.project(label)) == entry.metadata.project else { throw LocalCredentialError.corrupt }
            }
            do { try Self.validateValue(entry.value) } catch { throw LocalCredentialError.corrupt }
        }
        return record
    }

    private static func binding(_ name: String, _ project: String?) -> String {
        (project ?? "") + "\0" + name.lowercased()
    }

    func snapshot() throws -> LocalCredentialSnapshot {
        lock.lock(); defer { lock.unlock() }
        let record = try read()
        return LocalCredentialSnapshot(revision: record?.revision,
            entries: (record?.entries.map(\.metadata) ?? []).sorted { ($0.scopeLabel.lowercased(), $0.name.lowercased()) < ($1.scopeLabel.lowercased(), $1.name.lowercased()) })
    }

    func save(name: String, project: String?, value: String, updating id: UUID? = nil, expectedRevision: UUID?, now: Date = Date()) throws {
        let name = try Self.name(name), label = try Self.projectLabel(project), project = label?.lowercased()
        try Self.validateValue(value)
        lock.lock(); defer { lock.unlock() }
        let existing = try read()
        guard existing?.revision == expectedRevision else { throw LocalCredentialError.changed }
        var record = existing ?? Record()
        guard !record.entries.contains(where: { $0.metadata.id != id && Self.binding($0.metadata.name, $0.metadata.project) == Self.binding(name, project) }) else {
            throw LocalCredentialError.duplicate
        }
        let metadata: LocalCredentialMetadata
        if let id {
            guard let index = record.entries.firstIndex(where: { $0.metadata.id == id }) else { throw LocalCredentialError.missing }
            let old = record.entries[index].metadata
            guard old.version < UInt64.max else { throw LocalCredentialError.changed }
            metadata = LocalCredentialMetadata(id: id, name: name, project: project, version: old.version + 1, updatedAt: now, projectLabel: label)
            record.entries[index] = Entry(metadata: metadata, value: value)
        } else {
            metadata = LocalCredentialMetadata(id: UUID(), name: name, project: project, version: 1, updatedAt: now, projectLabel: label)
            record.entries.append(Entry(metadata: metadata, value: value))
        }
        record.revision = UUID()
        try storage.write(JSONEncoder().encode(record), creating: existing == nil)
    }

    func value(id: UUID, expectedRevision: UUID?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let record = try read() else { throw LocalCredentialError.missing }
        guard record.revision == expectedRevision else { throw LocalCredentialError.changed }
        guard let entry = record.entries.first(where: { $0.metadata.id == id }) else { throw LocalCredentialError.missing }
        return entry.value
    }

    func delete(id: UUID, expectedRevision: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try read() else { throw LocalCredentialError.missing }
        guard record.revision == expectedRevision else { throw LocalCredentialError.changed }
        guard record.entries.contains(where: { $0.metadata.id == id }) else { throw LocalCredentialError.missing }
        record.entries.removeAll { $0.metadata.id == id }
        record.revision = UUID()
        try storage.write(JSONEncoder().encode(record), creating: false)
    }
}
