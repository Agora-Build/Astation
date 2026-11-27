import AtemClient
import CoreFoundation
import Foundation

public protocol RemoteControlRecoveryRetentionTransport: Sendable {
    func retainControlRecoveryCopies(context: RemoteControlRecoveryContext,
        copiesJSON: String) async throws -> RemoteControlRecoveryRetention
}

/// Storage acknowledgment only. It supplies no feed effect or reopening authority.
public struct RemoteControlRecoveryRetention: Equatable, Sendable {
    public let recordIDs: [String]
    public let reconstructionHash: String

    static func requestIDs(context: RemoteControlRecoveryContext, json: String) throws -> [String] {
        try context.validate()
        guard json.utf8.count <= 262_144,
              let value = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: json).utf8)) as? [String: Any],
              Set(value.keys) == ["evidence_hash", "replacements"],
              value["evidence_hash"] as? String == context.evidenceHash,
              let rows = value["replacements"] as? [[String: Any]], (1...64).contains(rows.count) else {
            throw RemoteChannelError.invalidInput
        }
        var ids = Set<String>(), originals = Set<String>(), result: [String] = []
        for row in rows {
            guard Set(row.keys) == ["original_record_id", "record"],
                  let original = row["original_record_id"] as? String,
                  RemoteControlRecoveryContext.validUUID(original), originals.insert(original).inserted,
                  let record = row["record"] as? [String: Any] else { throw RemoteChannelError.invalidInput }
            let body = try parseControlRecord(recordJson: String(decoding: JSONSerialization.data(withJSONObject: record), as: UTF8.self))
            // The request names the original by ID. The journal and Station,
            // which also hold the original, check its feed against the signed copy.
            guard body.accountId == context.accountID, body.genesisHash == context.genesisHash,
                  body.signer.hasPrefix("member:"), ["revoke", "interrupt_running"].contains(body.action),
                  body.origin == nil || body.origin == context.stationOrigin,
                  RemoteControlRecoveryContext.validUUID(body.recordId), body.recordId != original,
                  ids.insert(body.recordId).inserted else { throw RemoteChannelError.invalidInput }
            result.append(body.recordId)
        }
        guard ids.isDisjoint(with: originals) else { throw RemoteChannelError.invalidInput }
        return result
    }

    public static func decode(_ bytes: Data, context: RemoteControlRecoveryContext, recordIDs: [String]) throws -> Self {
        try context.validate()
        guard bytes.count <= 8_192, let text = String(data: bytes, encoding: .utf8),
              let value = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8)) as? [String: Any],
              Set(value.keys) == ["version", "account_id", "genesis_hash", "origin", "generation", "plan_id",
                "evidence_hash", "record_ids", "reconstruction_hash", "retained_only", "recovery_ready"],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1",
              value["account_id"] as? String == context.accountID, value["genesis_hash"] as? String == context.genesisHash,
              value["origin"] as? String == context.stationOrigin, value["generation"] as? String == String(context.generation),
              value["plan_id"] as? String == context.planID, value["evidence_hash"] as? String == context.evidenceHash,
              (1...64).contains(recordIDs.count), Set(recordIDs).count == recordIDs.count,
              recordIDs.allSatisfy(RemoteControlRecoveryContext.validUUID), value["record_ids"] as? [String] == recordIDs,
              let hash = value["reconstruction_hash"] as? String, RemoteRecoveryKit.validHash(hash),
              let retained = value["retained_only"] as? NSNumber, CFGetTypeID(retained) == CFBooleanGetTypeID(), retained.boolValue,
              let ready = value["recovery_ready"] as? NSNumber, CFGetTypeID(ready) == CFBooleanGetTypeID(), !ready.boolValue else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return Self(recordIDs: recordIDs, reconstructionHash: hash)
    }
}
