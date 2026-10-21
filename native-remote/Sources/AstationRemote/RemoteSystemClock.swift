import AtemClient
import Darwin
import Foundation

public enum RemoteSystemClock {
    public static let bootIdentifier: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size <= 128 else { return UUID().uuidString }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let end = bytes.firstIndex(of: 0), end > 0 else { return UUID().uuidString }
        return String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    public static func now() -> HostClock {
        HostClock(wallMs: UInt64(max(0, Date().timeIntervalSince1970 * 1000)),
            monoMs: DispatchTime.now().uptimeNanoseconds / 1_000_000, bootId: bootIdentifier)
    }
}
