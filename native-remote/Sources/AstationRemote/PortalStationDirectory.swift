import AtemClient
import Foundation

/// Discovery metadata only. Listing a Station grants no R9 or verifier authority.
public struct PortalStationDirectoryEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let origin: String
    public let name: String?
    public let builtIn: Bool
    public let access: String
    public let role: String
    public let status: String
    public let removedAt: String?
    public let removalStartedAt: String?
    public let completeBy: String?
    public let membership: String?
    public let membershipEndedAt: String?
    public let integrationsEnabled: Bool
    public let createdAt: String

    public var availableForIntegrations: Bool {
        status == "active" && membership != "ended" && integrationsEnabled
    }

    func validate() throws {
        guard RemoteRecoveryKit.validID(id), PortalIntegrationRecord.validOrigin(origin),
              let created = Self.date(createdAt), ["active", "removing", "removed"].contains(status),
              (status == "removed") == (removedAt != nil),
              removedAt == nil || Self.date(removedAt!) != nil,
              membershipEndedAt == nil || Self.date(membershipEndedAt!) != nil,
              name == nil || (!name!.isEmpty && name!.utf8.count <= 320 &&
                !name!.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })),
              !integrationsEnabled || (status == "active" && membership != "ended") else {
            throw AccountLoginError.invalidResponse
        }
        if removalStartedAt != nil || completeBy != nil || status == "removing" {
            guard !builtIn, status != "active", let removalStartedAt, let completeBy,
                  let start = Self.date(removalStartedAt), let deadline = Self.date(completeBy),
                  start >= created, deadline > start,
                  removedAt.flatMap(Self.date).map({ $0 >= start }) ?? true else {
                throw AccountLoginError.invalidResponse
            }
        }
        if builtIn {
            guard access == "any_account", role == "built_in", membership == nil, membershipEndedAt == nil else {
                throw AccountLoginError.invalidResponse
            }
        } else {
            guard access == "members", name == nil else { throw AccountLoginError.invalidResponse }
            switch role {
            case "owner":
                guard membership == nil, membershipEndedAt == nil else { throw AccountLoginError.invalidResponse }
            case "member":
                guard membership.map({ ["current", "ended"].contains($0) }) == true,
                      (membership == "ended") == (membershipEndedAt != nil) else {
                    throw AccountLoginError.invalidResponse
                }
            default: throw AccountLoginError.invalidResponse
            }
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

public struct PortalStationDirectoryPage: Decodable, Equatable, Sendable {
    public let stations: [PortalStationDirectoryEntry]
    public let nextCursor: String?
    public let stale: Bool
    public let complete: Bool

    static func validCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= 1_024 && cursor.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func decode(_ bytes: Data, limit: Int = 100) throws -> Self {
        guard (1...100).contains(limit), bytes.count <= 262_144,
              let text = String(data: bytes, encoding: .utf8) else { throw AccountLoginError.invalidResponse }
        let canonical = Data(try canonicalJson(json: text).utf8)
        let originalFields: Set<String> = ["id", "origin", "name", "builtIn", "access", "role", "status",
            "removedAt", "membership", "membershipEndedAt", "integrationsEnabled", "createdAt"]
        let removalFields = originalFields.union(["removalStartedAt", "completeBy"])
        guard let object = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              Set(object.keys) == ["stations", "nextCursor", "stale", "complete"],
              let rows = object["stations"] as? [[String: Any]], rows.count <= limit,
              rows.allSatisfy({ Set($0.keys) == originalFields || Set($0.keys) == removalFields }) else {
            throw AccountLoginError.invalidResponse
        }
        let result = try JSONDecoder().decode(Self.self, from: canonical)
        guard Set(result.stations.map(\.id)).count == result.stations.count,
              result.nextCursor == nil || (validCursor(result.nextCursor!) && !result.stations.isEmpty),
              !result.complete || (result.nextCursor == nil && !result.stale) else {
            throw AccountLoginError.invalidResponse
        }
        for station in result.stations { try station.validate() }
        return result
    }
}

/// A bounded traversal, not an atomic account inventory or permission to remove
/// a retained route. Keyset pages may change while the directory is read.
public struct PortalStationDirectorySnapshot: Equatable, Sendable {
    public let stations: [PortalStationDirectoryEntry]
    public let stale: Bool
    public let complete: Bool
}
