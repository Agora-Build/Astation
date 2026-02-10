import Foundation
import IOKit

/// Reads the hardware UUID from IOKit (IOPlatformUUID).
/// This value is stable until OS reinstall.
struct MachineIdentity {
    /// Returns the machine's hardware UUID string (e.g., "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX").
    static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            // Fallback for environments where IOKit is unavailable
            return "fallback-\(ProcessInfo.processInfo.hostName)"
        }
        defer { IOObjectRelease(service) }

        guard let uuidCF = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else {
            return "fallback-\(ProcessInfo.processInfo.hostName)"
        }

        return uuidCF.takeRetainedValue() as? String ?? "fallback-\(ProcessInfo.processInfo.hostName)"
    }
}
