import AstationRemote
import Foundation

/// Refreshes Portal status after the signed removal, without repeating consent.
@MainActor
enum IntegrationRevocationRefresh {
    static func run(
        record: PortalIntegrationRecord,
        current: () -> Bool,
        fetch: () async throws -> [PortalIntegrationRecord],
        update: (PortalIntegrationRecord) -> Void,
        wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> Bool {
        // Station cleanup runs on its feed worker, which can take a poll cycle.
        for seconds: UInt64 in [0, 1, 2, 4, 8, 15, 30, 30, 30] {
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            if seconds > 0 { try await wait(seconds * 1_000_000_000) }
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            let records: [PortalIntegrationRecord]
            do { records = try await fetch() }
            catch AccountLoginError.unavailable { continue }
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            guard let next = records.first(where: { $0.id == record.id }),
                  next.stationOrigin == record.stationOrigin, next.r9Svc == record.r9Svc,
                  ["revoking", "revoked"].contains(next.state) else {
                throw AccountLoginError.changed
            }
            update(next)
            if next.state == "revoked" { return true }
        }
        return false
    }
}
