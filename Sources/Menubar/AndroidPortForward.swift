import Foundation

/// Editable port text is retained so an incomplete edit is not silently replaced on relaunch.
struct AndroidPortForward: Codable, Identifiable, Equatable {
    var id = UUID()
    var sharedPort = "27183"
    var localPort = "27183"

    func validated() throws -> AndroidForwardedPort {
        guard let shared = AndroidCommands.port(sharedPort), let local = AndroidCommands.port(localPort) else {
            throw AndroidSharingError.message("Each forwarded port must have a shared and local port between 1024 and 65535.")
        }
        return AndroidForwardedPort(sharedPort: shared, localPort: local)
    }
}

struct AndroidForwardedPort: Equatable, Identifiable {
    let sharedPort: Int
    let localPort: Int
    var id: Int { sharedPort }

    static let maximumCount = 16

    static func validate(_ forwards: [Self], sharingPort: Int) throws {
        guard forwards.count <= maximumCount else {
            throw AndroidSharingError.message("Use at most \(maximumCount) forwarded ports.")
        }
        var used = Set([sharingPort])
        for forward in forwards {
            guard (1024...65535).contains(forward.sharedPort), (1024...65535).contains(forward.localPort) else {
                throw AndroidSharingError.message("Forwarded ports must be between 1024 and 65535.")
            }
            guard used.insert(forward.sharedPort).inserted else {
                throw AndroidSharingError.message("Shared port \(forward.sharedPort) is used more than once. Choose distinct ports for ADB sharing and each forward.")
            }
        }
    }
}
