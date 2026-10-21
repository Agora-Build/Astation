import AppKit
import AtemClient
import AstationRemote
import Foundation

/// This adapter is independent of membership-entry confirmation, which is always fresh.
@MainActor
final class AstationChannelSigner {
    private let routine: RemoteRoutineChannelSigner
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(identity: AtemE2EIdentity, keyID: String) throws {
        let expected = try identity.remotePublicKeys().signing
        routine = RemoteRoutineChannelSigner(keyID: keyID,
            now: { RemoteSystemClock.now().monoMs }, active: { NSApplication.shared.isActive },
            confirm: {
                await withCheckedContinuation { continuation in
                    DeviceOwnerAuth.authenticate(reason: "connect to your verified Atem hosts") {
                        continuation.resume(returning: $0)
                    }
                }
            }, sign: { request in try identity.signChannel(request, keyID: keyID, expectedPublicKey: expected) })
        for (center, name) in [(NotificationCenter.default, NSApplication.didResignActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
                               (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
            observers.append((center, observer))
        }
    }

    func sign(_ request: SignRequest, isCurrent: () -> Bool) async throws -> Data {
        try await routine.sign(request, isCurrent: isCurrent)
    }

    func invalidate() { routine.invalidate() }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }
}
