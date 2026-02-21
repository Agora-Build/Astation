import Foundation
import SystemConfiguration

/// Monitors network changes and notifies observers.
class NetworkMonitor {
    static let shared = NetworkMonitor()

    private var reachability: SCNetworkReachability?
    private var isMonitoring = false

    private init() {}

    /// Start monitoring network changes.
    func startMonitoring() {
        guard !isMonitoring else { return }

        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let reachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else {
            Log.error("Failed to create reachability")
            return
        }

        self.reachability = reachability

        var context = SCNetworkReachabilityContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCNetworkReachabilityCallBack = { (_, flags, info) in
            guard let info = info else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.networkChanged(flags: flags)
        }

        if SCNetworkReachabilitySetCallback(reachability, callback, &context) {
            if SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                isMonitoring = true
                Log.info("Network monitoring started")
            }
        }
    }

    /// Stop monitoring network changes.
    func stopMonitoring() {
        guard isMonitoring, let reachability = reachability else { return }

        SCNetworkReachabilityUnscheduleFromRunLoop(reachability, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.reachability = nil
        isMonitoring = false

        Log.info("Network monitoring stopped")
    }

    private func networkChanged(flags: SCNetworkReachabilityFlags) {
        Log.info("Network configuration changed")

        // Post notification for UI to update
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .networkChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let networkChanged = Notification.Name("NetworkChanged")
}
