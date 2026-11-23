import AtemClient
import CoreFoundation
import Foundation

public protocol RemoteControlRecoveryReviewTransport: Sendable {
    func controlRecoveryReview(accountID: String, genesisHash: String,
        expected: LogHead) async throws -> RemoteControlRecoveryPreparation
}

/// An authenticated view of retained evidence, never signing or reopening authority.
public struct RemoteControlRecoveryPreparation: Equatable, Sendable {
    public let context: RemoteControlRecoveryContext
    public let reconstructionHash: String
    // Plain decoded/exported JSON cannot release a protected signing hold.
    var stationReceipt: RemoteRecoveryHTTP.ReviewReceipt?
    var receivedFromStation: Bool { stationReceipt?.context == context }

    public static func decode(_ bytes: Data, accountID: String, genesisHash: String,
        stationOrigin: String, expected: LogHead) throws -> Self {
        guard bytes.count <= 8_192, let text = String(data: bytes, encoding: .utf8),
              let value = try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8)) as? [String: Any],
              Set(value.keys) == ["version", "account_id", "genesis_hash", "origin", "generation",
                "plan_id", "candidate_feed_id", "source_hash", "evidence_hash", "reconstruction_hash",
                "membership_head", "retained_history_only", "complete_history", "signing_clock_complete",
                "snapshot_complete", "recovery_ready"],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1", value["account_id"] as? String == accountID,
              value["genesis_hash"] as? String == genesisHash, value["origin"] as? String == stationOrigin,
              let rawGeneration = value["generation"] as? String, let generation = UInt64(rawGeneration),
              rawGeneration == String(generation),
              let plan = value["plan_id"] as? String, let candidate = value["candidate_feed_id"] as? String,
              let source = value["source_hash"] as? String, let evidence = value["evidence_hash"] as? String,
              let reconstruction = value["reconstruction_hash"] as? String, RemoteRecoveryKit.validHash(reconstruction),
              let head = value["membership_head"] as? [String: Any], Set(head.keys) == ["seq", "hash"],
              let seq = head["seq"] as? NSNumber, CFGetTypeID(seq) != CFBooleanGetTypeID(),
              seq.stringValue == String(expected.seq), head["hash"] as? String == expected.hash else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        for (key, expectedFlag) in [("retained_history_only", true), ("complete_history", false),
            ("signing_clock_complete", false), ("snapshot_complete", false), ("recovery_ready", false)] {
            guard let flag = value[key] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  flag.boolValue == expectedFlag else { throw RemoteRecoveryTransportError.invalidResponse }
        }
        let context = try RemoteControlRecoveryContext(accountID: accountID, genesisHash: genesisHash,
            stationOrigin: stationOrigin, generation: generation, planID: plan, sourceHash: source,
            evidenceHash: evidence, candidateFeedID: candidate, membershipHead: expected)
        return Self(context: context, reconstructionHash: reconstruction)
    }
}
