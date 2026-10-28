import AtemClient
import Foundation

public enum RemoteOwnerAuthenticationError: String, Error, Equatable {
    case notForeground
    case staleContext
    case cancelled
    case invalidated
    case denied
    case expired
}

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
        try await prepare(isCurrent: isCurrent)
        let time = now()
        try checkContext(isCurrent)
        guard let confirmedAt, time >= confirmedAt, time - confirmedAt < 300_000 else { throw RemoteOwnerAuthenticationError.expired }
        do { return try primitive(request) }
        catch { invalidate(); throw error }
    }

    /// Prepare owner presence before starting a time-bounded network handshake.
    /// This grants no signing authority beyond routine, validated channel transcripts.
    public func prepare(isCurrent: () -> Bool) async throws {
        try checkContext(isCurrent)
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
            guard generation == context else { throw RemoteOwnerAuthenticationError.invalidated }
            if pending?.id == confirmation.id { pending = nil }
            try checkContext(isCurrent)
            guard let acceptedAt else { throw RemoteOwnerAuthenticationError.denied }
            confirmedAt = max(confirmedAt ?? acceptedAt, acceptedAt)
        }
        let signingTime = now()
        guard generation == context else { throw RemoteOwnerAuthenticationError.invalidated }
        try checkContext(isCurrent)
        guard let confirmedAt, signingTime >= confirmedAt, signingTime - confirmedAt < 300_000 else { throw RemoteOwnerAuthenticationError.expired }
    }

    private func checkContext(_ isCurrent: () -> Bool) throws {
        guard active() else { clearReuse(); throw RemoteOwnerAuthenticationError.notForeground }
        guard isCurrent() else { throw RemoteOwnerAuthenticationError.staleContext }
        guard !Task.isCancelled else { throw RemoteOwnerAuthenticationError.cancelled }
    }

    /// System authentication can temporarily take focus. Retain its in-flight
    /// result, but never cache or use it until the app is foreground again.
    public func clearReuse() {
        confirmedAt = nil
    }

    public func invalidate() {
        generation = UUID()
        confirmedAt = nil
        pending?.task.cancel()
        pending = nil
    }
}
