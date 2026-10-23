import Foundation
import AstationRemote

/// Local service credentials only; this cache never authorizes device enrollment or relay access.
struct PortalProjectCache {
    struct Record: Codable {
        let subject: String
        let updatedAt: Date
        let metadata: [PortalAPIClient.Project]
        let projects: [AgoraProject]
    }
    let storage: AccountDataStorage

    init(settings: AccountServiceSettings) {
        storage = AccountKeychainDataStorage(service: "build.agora.astation.portal-projects-v1." + settings.storageContext,
            account: "linked-projects")
    }
    init(storage: AccountDataStorage) { self.storage = storage }

    func load(subject: String) throws -> Record? {
        guard let data = try storage.read() else { return nil }
        guard data.count <= 2_097_152,
              let record = try? PropertyListDecoder().decode(Record.self, from: data) else { throw AccountLoginError.storage }
        guard record.subject == subject else { return nil }
        guard record.projects.count <= 1000, record.metadata.count == record.projects.count,
              Set(record.projects.map(\.id)).count == record.projects.count,
              Set(record.metadata.map(\.projectId)).count == record.metadata.count,
              Set(record.metadata.map(\.appId)) == Set(record.projects.map(\.id)),
              record.projects.allSatisfy({ $0.id == $0.vendorKey }) else { throw AccountLoginError.storage }
        return record
    }

    func save(subject: String, metadata: [PortalAPIClient.Project], projects: [AgoraProject], updatedAt: Date) throws {
        let data = try PropertyListEncoder().encode(Record(subject: subject, updatedAt: updatedAt, metadata: metadata, projects: projects))
        guard data.count <= 2_097_152, projects.count <= 1000 else { throw AccountLoginError.storage }
        try storage.write(data)
    }

    func clear() throws { try storage.write(nil) }
}
