import AtemClient
import Foundation

public struct RemotePairingContext: Equatable, Sendable {
    public let accountID: String
    public let hostID: String
    public let linkGeneration: UUID

    public init(accountID: String, hostID: String, linkGeneration: UUID) {
        self.accountID = accountID
        self.hostID = hostID
        self.linkGeneration = linkGeneration
    }
}

/// Immutable input for the r9 ceremony; a platform decoder never reads the generation first.
public struct RemotePairingCommit: Equatable, Sendable {
    public let context: RemotePairingContext
    public let hostTrustGeneration: UInt64
    public let commitment: Data

    public init(originalJSON: Data, context: RemotePairingContext) throws {
        guard originalJSON.count <= 262_144,
              let json = String(data: originalJSON, encoding: .utf8) else {
            throw RemoteChannelError.invalidInput
        }
        let generation = try verifyCommitHostTrustGen(messageJson: json)
        struct Envelope: Decodable {
            struct Payload: Decodable { let device_id: String; let commitment: Data }
            let data: Payload
        }
        let payload = try JSONDecoder().decode(Envelope.self, from: originalJSON).data
        guard !context.accountID.isEmpty, payload.device_id == context.hostID,
              !context.hostID.isEmpty, payload.commitment.count == 32 else {
            throw RemoteChannelError.invalidInput
        }
        self.context = context
        hostTrustGeneration = generation
        commitment = payload.commitment
    }
}
