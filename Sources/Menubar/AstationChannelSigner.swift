import AppKit
import AtemClient
import AstationRemote
import Foundation

/// This adapter is independent of membership-entry confirmation, which is always fresh.
@MainActor
final class AstationChannelSigner {
    enum PreparationStage { case waitingForForeground, confirmingOwner }

    private let routine: RemoteRoutineChannelSigner
    private let foreground: () -> Bool
    private var generation = UUID()
    private var activationWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(identity: AtemE2EIdentity, keyID: String,
         active: (() -> Bool)? = nil, confirm: (() async -> Bool)? = nil,
         restoreForeground: (() -> Void)? = nil) throws {
        let expected = try identity.remotePublicKeys().signing
        let foreground = active ?? { NSApplication.shared.isActive }
        self.foreground = foreground
        weak var authenticationWindow: NSWindow?
        var hadAuthenticationWindow = false
        let authenticate = confirm ?? {
            await withCheckedContinuation { continuation in
                DeviceOwnerAuth.authenticate(reason: "connect to your verified Atem hosts") {
                    continuation.resume(returning: $0)
                }
            }
        }
        routine = RemoteRoutineChannelSigner(keyID: keyID,
            now: { RemoteSystemClock.now().monoMs }, active: foreground,
            waitForForeground: { stage in
                if stage == .afterConfirmation {
                    Log.info("[R9] Restoring Astation focus after successful owner authentication")
                    if let restoreForeground { restoreForeground() }
                    else if !hadAuthenticationWindow || authenticationWindow?.isVisible == true {
                        authenticationWindow?.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                try await Self.waitForForeground(active: foreground)
            },
            confirm: {
                authenticationWindow = Self.presentationWindow(keyWindow: NSApp?.keyWindow, mainWindow: NSApp?.mainWindow)
                hadAuthenticationWindow = authenticationWindow != nil
                Log.info("[R9] Requesting owner authentication; foreground=\(foreground())")
                let approved = await authenticate()
                Log.info("[R9] Owner authentication returned; approved=\(approved), foreground=\(foreground())")
                return approved
            }, sign: { request in try identity.signChannel(request, keyID: keyID, expectedPublicKey: expected) })
        for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                               (NotificationCenter.default, NSApplication.didResignActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
                               (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSApplication.didBecomeActiveNotification { self?.resumeActivationWaiters() }
                    else if name == NSApplication.didResignActiveNotification { self?.routine.clearReuse() }
                    else { self?.invalidate() }
                }
            }
            observers.append((center, observer))
        }
    }

    func sign(_ request: SignRequest, isCurrent: () -> Bool) async throws -> Data {
        try await routine.sign(request, isCurrent: isCurrent)
    }

    func prepare(isCurrent: () -> Bool, stageChanged: (PreparationStage) -> Void = { _ in }) async throws {
        let expectedGeneration = generation
        if !foreground() {
            stageChanged(.waitingForForeground)
            // No handshake or owner prompt exists yet, so background time is not a connection timeout.
            try await waitForActivation(generation: expectedGeneration, isCurrent: isCurrent)
        }
        stageChanged(.confirmingOwner)
        try await routine.prepare(isCurrent: isCurrent)
    }

    func invalidate() {
        generation = UUID()
        routine.invalidate()
        resumeActivationWaiters()
    }

    private func waitForActivation(generation expected: UUID, isCurrent: () -> Bool) async throws {
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        activationWaiters[id] = continuation
        defer { activationWaiters.removeValue(forKey: id); continuation.finish() }
        continuation.yield(())
        for await _ in events {
            guard !Task.isCancelled else { throw RemoteOwnerAuthenticationError.cancelled }
            guard generation == expected else { throw RemoteOwnerAuthenticationError.invalidated }
            guard isCurrent() else { throw RemoteOwnerAuthenticationError.staleContext }
            if foreground() { return }
        }
        throw RemoteOwnerAuthenticationError.cancelled
    }

    private func resumeActivationWaiters() {
        for continuation in activationWaiters.values { continuation.yield(()) }
    }

    static func presentationWindow(keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
        // A dismissed modal alert can remain key while its Settings window stays visible.
        [keyWindow?.sheetParent, mainWindow, keyWindow].compactMap { $0 }.first { $0.isVisible }
    }

    /// AppKit may restore activation after the system authentication callback.
    /// No channel traffic starts during this bounded, cancellable wait.
    static func waitForForeground(active: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !active() {
            guard !Task.isCancelled else { throw RemoteOwnerAuthenticationError.cancelled }
            guard clock.now < deadline else { throw RemoteOwnerAuthenticationError.notForeground }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }
}
