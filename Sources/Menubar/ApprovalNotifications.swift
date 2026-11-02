import AppKit
import Security
import SwiftUI
import UserNotifications

/// OS delivery and registration only. Opening a hint hands off to authenticated
/// host catch-up; this delegate has no operation that can acquire or approve.
final class ApprovalNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let inbox = ApprovalInbox()
    @Published private(set) var inAppEnabled: Bool
    @Published private(set) var pushEnabled: Bool
    @Published private(set) var pushStatus: String
    private let defaults: UserDefaults
    private let pushPlatform: ApprovalPushPlatform?
    private let register: (ApprovalPushRegistration) -> Void
    private let unregister: (ApprovalPushPlatform) -> Void
    private let open: (ApprovalPushHint) -> Void
    private let verifyPush: @MainActor ([AnyHashable: Any], Bool) -> ApprovalPushHint?
    private var reconciliation: ApprovalPushReconciliation
    private lazy var center = UNUserNotificationCenter.current()
    private let enabledKey = "agentApprovalNotificationsEnabled"
    private let inAppKey = "agentApprovalInAppNotificationsEnabled"
    private let platformKey = "agentApprovalNotificationsPlatform"
    private let resolutionsKey = "agentApprovalNotificationResolutions"
    private var permissionAttempt = UUID()
    private var windowController: NSWindowController?
    private var banner: NSPanel?
    private var bannerKey: String?
    private var alerted: [String] = []
    var supportsPush: Bool { pushPlatform != nil }

    init(defaults: UserDefaults = .standard, platform: ApprovalPushPlatform? = ApprovalNotifications.platform,
         register: @escaping (ApprovalPushRegistration) -> Void,
         unregister: @escaping (ApprovalPushPlatform) -> Void, open: @escaping (ApprovalPushHint) -> Void,
         verifyPush: @escaping @MainActor ([AnyHashable: Any], Bool) -> ApprovalPushHint? = { _, _ in nil }) {
        self.defaults = defaults
        pushPlatform = platform
        inAppEnabled = defaults.object(forKey: inAppKey) as? Bool ?? true
        pushEnabled = defaults.bool(forKey: enabledKey) && platform != nil
        pushStatus = platform == nil
            ? "Offline push is unavailable: this build has no APNs entitlement. A paid Apple Developer team and a push-enabled profile are required. In-app alerts work independently."
            : "Offline push requires macOS notification permission, relay APNs configuration and authenticated Atem push delivery."
        self.register = register
        self.unregister = unregister
        self.open = open
        self.verifyPush = verifyPush
        reconciliation = ApprovalPushReconciliation(saved: defaults.data(forKey: "agentApprovalNotificationResolutions"))
        super.init()
        inbox.onNew = { [weak self] entry in self?.showInAppAlert(entry) }
    }

    static var platform: ApprovalPushPlatform? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let environment = (entitlements["com.apple.developer.aps-environment"] ?? entitlements["aps-environment"]) as? String else { return nil }
        return ApprovalPushPlatform(entitlement: environment)
    }

    func start() {
        center.delegate = self
        if pushEnabled {
            let attempt = permissionAttempt
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self, self.permissionAttempt == attempt, self.pushEnabled else { return }
                    if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                        NSApp.registerForRemoteNotifications()
                    } else {
                        self.setPushEnabled(false)
                        self.pushStatus = "Offline push is disabled in macOS. Allow Astation in System Settings > Notifications. In-app alerts remain available."
                    }
                }
            }
        } else if let raw = defaults.string(forKey: platformKey), let platform = ApprovalPushPlatform(rawValue: raw) {
            unregister(platform)
        }
    }

    func showPreferences() {
        if windowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ApprovalNotificationsView(notifications: self, inbox: inbox)))
            window.title = "Approval Notifications"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 640))
            window.minSize = NSSize(width: 560, height: 520)
            window.center()
            windowController = NSWindowController(window: window)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setInAppEnabled(_ enabled: Bool) {
        inAppEnabled = enabled
        defaults.set(enabled, forKey: inAppKey)
        if !enabled { banner?.orderOut(nil) }
    }

    func setPushEnabled(_ enabled: Bool) {
        guard !enabled || supportsPush else { return }
        permissionAttempt = UUID()
        if !enabled {
            pushEnabled = false
            defaults.set(false, forKey: enabledKey)
            if let platform = pushPlatform { unregister(platform) }
            NSApp.unregisterForRemoteNotifications()
            if supportsPush { pushStatus = "Offline push is off. In-app alerts use their own setting." }
        } else {
            center.delegate = self
            let attempt = permissionAttempt
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self, self.permissionAttempt == attempt else { return }
                    self.pushEnabled = granted
                    self.defaults.set(granted, forKey: self.enabledKey)
                    if granted {
                        self.defaults.set(self.pushPlatform?.rawValue, forKey: self.platformKey)
                        self.pushStatus = "Registering for offline push. Relay APNs configuration and authenticated Atem push delivery are also required."
                        NSApp.registerForRemoteNotifications()
                    } else {
                        self.pushStatus = "Offline push is disabled in macOS. Allow Astation in System Settings > Notifications. In-app alerts remain available."
                    }
                }
            }
        }
    }

    func registered(deviceToken: Data) {
        guard pushEnabled, let platform = pushPlatform,
              let registration = ApprovalPushRegistration(deviceToken: deviceToken, platform: platform) else { return }
        defaults.set(platform.rawValue, forKey: platformKey)
        register(registration)
        pushStatus = "Push address sent to the relay. Delivery requires configured APNs credentials and authenticated Atem push support."
    }

    func registrationFailed() {
        pushStatus = "APNs registration failed. Check push provisioning and the network. In-app alerts remain available."
        Log.warn("[Approvals] APNs registration failed; check the app's provisioning and network connection")
    }

    func sessionChanged(sourceID: String, client: AtemSessionClient, host: String) {
        inbox.sync(sourceID: sourceID, client: client, host: host)
        if let entry = inbox.entries.first(where: {
            $0.sourceID == sourceID && $0.target.atem_device_id + "\u{0}" + $0.request.approval_id == bannerKey
        }), !entry.available || entry.resolution != nil { banner?.orderOut(nil) }
        guard let context = client.context else { return }
        for id in client.closedApprovals.keys where !reconciliation.resolutions.contains(where: {
            $0.host == context.device && $0.approval == id
        }) {
            if let hint = ApprovalPushHint(userInfo: ["kind": "resolved", "approval_id": id, "atem_device_id": context.device]) {
                receivedVerified(hint)
            }
        }
    }

    func received(userInfo: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let hint = self.verifyPush(userInfo, false) else { return }
            self.receivedVerified(hint)
        }
    }

    private func receivedVerified(_ hint: ApprovalPushHint) {
        let remove = reconciliation.receive(hint, now: Date())
        defaults.set(reconciliation.saved, forKey: resolutionsKey)
        if remove {
            if bannerKey == Self.key(hint) { banner?.orderOut(nil) }
            if hint.scope == nil {
                center.removeDeliveredNotifications(withIdentifiers: [hint.approvalID])
                center.removePendingNotificationRequests(withIdentifiers: [hint.approvalID])
            }
            // The OS may assign its own identifier to an APNs delivery.
            center.getDeliveredNotifications { [weak self] notifications in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let identifiers = notifications.filter {
                        self.verifyPush($0.request.content.userInfo, true)?.cacheKey == hint.cacheKey
                    }.map { $0.request.identifier }
                    self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let hint = self?.verifyPush(response.notification.request.content.userInfo, true) {
                self?.inbox.notificationHint = hint
                self?.open(hint)
                self?.showPreferences()
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inAppEnabled, self.pushEnabled,
                  let hint = self.verifyPush(notification.request.content.userInfo, false) else {
                completionHandler([]); return
            }
            let remove = self.reconciliation.receive(hint, now: Date())
            self.defaults.set(self.reconciliation.saved, forKey: self.resolutionsKey)
            let key = Self.key(hint)
            let duplicate = self.alerted.contains(key)
            if !remove && !duplicate { self.rememberAlert(key) }
            completionHandler(remove || duplicate ? [] : [.banner, .sound])
        }
    }

    private static func key(_ hint: ApprovalPushHint) -> String { hint.cacheKey }

    private func rememberAlert(_ key: String) {
        alerted.append(key)
        if alerted.count > 1024 { alerted.removeFirst(alerted.count - 1024) }
    }

    private func showInAppAlert(_ entry: ApprovalInboxEntry) {
        guard inAppEnabled, let hint = ApprovalPushHint(userInfo: ["kind": "approval", "approval_id": entry.request.approval_id,
            "atem_device_id": entry.target.atem_device_id, "session_id": entry.target.session_id]) else { return }
        let key = Self.key(hint)
        guard !alerted.contains(key), !reconciliation.receive(hint, now: Date()) else { return }
        rememberAlert(key)
        let panel = banner ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ApprovalBannerView(entry: entry, review: { [weak self] in
            self?.banner?.orderOut(nil)
            self?.showPreferences()
        }, dismiss: { [weak self] in self?.banner?.orderOut(nil) }))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 384, y: frame.maxY - 176, width: 368, height: 160), display: true)
        }
        banner = panel
        bannerKey = key
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.bannerKey == key { self?.banner?.orderOut(nil) }
        }
    }
}

private struct ApprovalBannerView: View {
    let entry: ApprovalInboxEntry
    let review: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bell.badge.fill").foregroundStyle(.tint)
                Text("Approval requested").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss alert")
            }
            Text("\(entry.provider.capitalized) on \(entry.host)").font(.subheadline)
            Text(entry.request.summary.isEmpty ? entry.request.tool : entry.request.summary).lineLimit(2)
            HStack { Spacer(); Button("Review request", action: review).buttonStyle(.borderedProminent) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
