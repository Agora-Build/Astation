import AtemClient
import Foundation

/// An app-local review of the exact device-list entry, not a new wire format.
public struct RemoteHostSenderReview: Codable, Equatable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case revoke(interruptRunning: Bool)
        case readmit
    }

    public let stationOrigin: String
    public let accountID: String
    public let genesisHash: String
    public let hostID: String
    public let operation: Operation
    public let bodyJSON: String

    @MainActor
    public init(stationOrigin: String, log: MembershipLog, managerID: String, hostID: String,
        operation: Operation, now: HostClock) throws {
        self.stationOrigin = stationOrigin
        accountID = log.accountId()
        genesisHash = log.genesisHash()
        self.hostID = hostID
        self.operation = operation
        bodyJSON = try log.draftEntry(signer: managerID, signedAt: now.wallMs,
            actionJson: Self.action(hostID: hostID, operation: operation, signedAt: now.wallMs))
        try validate(log: log, managerID: managerID, now: now)
    }

    public func signingRequest(managerID: String) throws -> SignRequest {
        try RemoteConfirmedSigner.membershipRequest(bodyJSON: bodyJSON, keyID: managerID)
    }

    public func checkpoint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    public func prepare(publication: RemoteMembershipPublication, managerID: String, now: HostClock) throws {
        try validate(log: publication.committedLog(), managerID: managerID, now: now)
        let signedAt = try signedTime()
        let body = try publication.prepare(actionJSON: Self.action(hostID: hostID, operation: operation, signedAt: signedAt),
            signer: managerID, signedAt: signedAt, operationContext: checkpoint())
        guard body == bodyJSON else { throw RemoteRecoveryError.requiresReview }
    }

    @MainActor
    public func sign(publication: RemoteMembershipPublication, provider: AppKeyProvider, managerID: String,
        validationClock: HostClock, confirmedAt: UInt64, now: @escaping @Sendable () -> UInt64,
        current: () -> Bool) throws -> AppendRequest {
        guard current(), publication.operationContext == (try checkpoint()) else { throw RemoteChannelError.staleLink }
        try validate(log: publication.committedLog(), managerID: managerID, now: validationClock)
        let signer = try RemoteConfirmedSigner(provider: provider, request: signingRequest(managerID: managerID),
            confirmedAt: confirmedAt, now: now)
        guard current() else { signer.invalidate(); throw RemoteChannelError.staleLink }
        let append = try publication.sign(provider: signer, keyID: managerID)
        guard try signedObjectInfo(json: append.entryJson).bodyJcs == bodyJSON else { throw RemoteRecoveryError.requiresReview }
        return append
    }

    @MainActor
    public func validate(log: MembershipLog, managerID: String, now: HostClock) throws {
        let log = log.snapshot()
        _ = try log.advance(now: now)
        guard PortalIntegrationRecord.validOrigin(stationOrigin), log.accountId() == accountID,
              log.genesisHash() == genesisHash, log.frozen() == nil,
              let manager = log.member(deviceId: managerID), manager.kind == "native",
              manager.status == .active, manager.roles.contains("manage"),
              let state = log.hostSenderState(hostId: hostID) else { throw RemoteRecoveryError.requiresReview }
        switch (operation, state) {
        case (.revoke, .authorized), (.readmit, .revoked): break
        default: throw RemoteRecoveryError.requiresReview
        }
        let time = try signedTime()
        guard time <= now.wallMs,
              try log.draftEntry(signer: managerID, signedAt: time,
                  actionJson: Self.action(hostID: hostID, operation: operation, signedAt: time)) == bodyJSON else {
            throw RemoteRecoveryError.requiresReview
        }
    }

    private func signedTime() throws -> UInt64 {
        guard let body = try JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any],
              let value = body["signed_at"] as? NSNumber else { throw RemoteRecoveryError.invalidCheckpoint }
        return value.uint64Value
    }

    private static func action(hostID: String, operation: Operation, signedAt: UInt64) throws -> String {
        switch operation {
        case .revoke(let interrupt): return try hostSenderRevokeAction(hostId: hostID, interruptRunning: interrupt, signedAt: signedAt)
        case .readmit: return try hostSenderReadmitAction(hostId: hostID, signedAt: signedAt)
        }
    }
}
