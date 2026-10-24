import AtemClient
import Foundation

/// R9.6 owner-confirmation reuse applies only to channel transcript signatures.
@MainActor
public final class RemoteRoutineChannelSigner {
    private let keyID: String
    private let now: () -> UInt64
    private let active: () -> Bool
    private let confirm: () async -> Bool
    private let primitive: (SignRequest) throws -> Data
    private var confirmedAt: UInt64?
    private var pending: (id: UUID, task: Task<UInt64?, Never>)?
    private var generation = UUID()

    public init(keyID: String, now: @escaping () -> UInt64, active: @escaping () -> Bool,
        confirm: @escaping () async -> Bool, sign: @escaping (SignRequest) throws -> Data) {
        self.keyID = keyID
        self.now = now
        self.active = active
        self.confirm = confirm
        primitive = sign
    }

    public nonisolated static func validate(_ request: SignRequest, keyID: String) throws {
        guard request.keyId == keyID, request.purpose == .channel, !request.freshConfirmation,
              request.bodyJson == nil, request.label == "atem-ch1-client-sig-v1",
              request.input.count >= 32,
              request.input == signingInput(label: .channelClient, payload: Data(request.input.suffix(32))) else {
            throw RemoteChannelError.invalidInput
        }
    }

    public func sign(_ request: SignRequest, isCurrent: () -> Bool) async throws -> Data {
        try Self.validate(request, keyID: keyID)
        guard active() else { invalidate(); throw RemoteRecoveryError.confirmationRequired }
        guard isCurrent(), !Task.isCancelled else { throw RemoteRecoveryError.confirmationRequired }
        let time = now()
        if let confirmedAt, time < confirmedAt { invalidate() }
        let context = generation
        if confirmedAt.map({ time >= $0 && time - $0 < 300_000 }) != true {
            let confirmation: (id: UUID, task: Task<UInt64?, Never>)
            if let pending { confirmation = pending }
            else {
                confirmation = (UUID(), Task { [confirm, now] in await confirm() ? now() : nil })
                pending = confirmation
            }
            let acceptedAt = await confirmation.task.value
            guard generation == context else { throw RemoteRecoveryError.confirmationRequired }
            if pending?.id == confirmation.id { pending = nil }
            guard active() else { invalidate(); throw RemoteRecoveryError.confirmationRequired }
            guard isCurrent(), !Task.isCancelled else {
                throw RemoteRecoveryError.confirmationRequired
            }
            guard let acceptedAt else { throw RemoteRecoveryError.confirmationRequired }
            confirmedAt = max(confirmedAt ?? acceptedAt, acceptedAt)
        }
        let signingTime = now()
        guard generation == context, active(), isCurrent(), !Task.isCancelled,
              let confirmedAt, signingTime >= confirmedAt, signingTime - confirmedAt < 300_000 else {
            throw RemoteRecoveryError.confirmationRequired
        }
        do { return try primitive(request) }
        catch { invalidate(); throw error }
    }

    public func invalidate() {
        generation = UUID()
        confirmedAt = nil
        pending?.task.cancel()
        pending = nil
    }
}
