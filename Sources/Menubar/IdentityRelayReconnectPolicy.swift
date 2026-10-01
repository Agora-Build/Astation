import Foundation

struct IdentityRelayReconnectPolicy {
    static let serviceRestartCloseCode = 1012
    static let tryAgainLaterCloseCode = 1013

    private(set) var consecutiveFailures = 0

    mutating func delay(
        observedCloseCode: Int?,
        wasVerified: Bool,
        unitJitter: Double
    ) -> TimeInterval {
        let attempt = consecutiveFailures
        consecutiveFailures = min(consecutiveFailures + 1, 6)
        let closeCode = observedCloseCode ?? (wasVerified
            ? Self.serviceRestartCloseCode
            : Self.tryAgainLaterCloseCode)

        if closeCode == Self.serviceRestartCloseCode {
            // A draining replica has already withdrawn from service. Retry quickly,
            // but cap repeated drain responses so a bad route cannot spin tightly.
            return min(2.0, 0.5 * multiplier(for: attempt))
        }

        let initialDelay = closeCode == Self.tryAgainLaterCloseCode ? 2.0 : 1.0
        let exponentialDelay = min(30.0, initialDelay * multiplier(for: attempt))
        let clampedJitter = min(max(unitJitter, 0.0), 1.0)
        let jitterFactor = 0.8 + (clampedJitter * 0.4)
        return min(30.0, exponentialDelay * jitterFactor)
    }

    mutating func reset() {
        consecutiveFailures = 0
    }

    private func multiplier(for attempt: Int) -> TimeInterval {
        TimeInterval(1 << min(attempt, 5))
    }
}
