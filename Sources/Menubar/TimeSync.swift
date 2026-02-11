import Foundation

/// Cached time offset between local clock and Agora server.
/// Port of Atem/src/time_sync.rs.
class TimeSync {
    private var offsetSecs: Int64 = 0
    private var syncedAt: Date?
    private let maxAge: TimeInterval = 3600 // 1 hour

    /// Fetch server time from Agora API Date header, compute drift offset.
    func sync() async {
        do {
            var request = URLRequest(url: URL(string: "https://api.agora.io")!)
            request.httpMethod = "HEAD"

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
                let dateString = httpResponse.value(forHTTPHeaderField: "Date")
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "GMT")

                if let serverDate = formatter.date(from: dateString) {
                    let serverTime = Int64(serverDate.timeIntervalSince1970)
                    let localTime = Int64(Date().timeIntervalSince1970)
                    offsetSecs = serverTime - localTime
                    syncedAt = Date()

                    if abs(offsetSecs) > 30 {
                        print(
                            "[TimeSync] Warning: local clock is \(offsetSecs)s off from server")
                    }
                }
            }
        } catch {
            print("[TimeSync] Sync failed (\(error)), using local clock")
        }
    }

    /// Returns corrected current Unix timestamp. Auto-syncs if stale.
    func now() async -> UInt32 {
        let needsSync: Bool
        if let syncedAt = syncedAt {
            needsSync = Date().timeIntervalSince(syncedAt) > maxAge
        } else {
            needsSync = true
        }

        if needsSync {
            await sync()
        }

        let local = Int64(Date().timeIntervalSince1970)
        return UInt32(local + offsetSecs)
    }

    /// Raw offset for diagnostics.
    var offset: Int64 { offsetSecs }
}
