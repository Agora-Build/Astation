import Foundation
import Darwin

struct AndroidNetworkAddress: Identifiable, Equatable {
    let interface: String
    let address: String
    var id: String { "\(interface)|\(address)" }
    var label: String { "\(address) (\(interface))" }
}

enum AndroidNetworkInterfaces {
    static func isIPv4(_ address: String) -> Bool {
        var value = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &value) } == 1
    }

    static func addresses() -> [AndroidNetworkAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var current = head
        var result: [AndroidNetworkAddress] = []
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(AndroidNetworkAddress(interface: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
        }
        return result.sorted { $0.id < $1.id }
    }
}
