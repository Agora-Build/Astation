import AppKit
import AstationRemote
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
    private let outcomePush: @MainActor ([AnyHashable: Any], Bool) -> Bool
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
    private var outcomeBanner: NSPanel?
    private var outcomeBannerSource: String?
    private var outcomeBannerGeneration = UUID()
    private var outcomeWindowController: NSWindowController?
    private var controlBanner: NSPanel?
    private var controlBannerGeneration = UUID()
    private var controlActivityWindow: ControlActivityWindowController?
    var supportsPush: Bool { pushPlatform != nil }

    init(defaults: UserDefaults = .standard, platform: ApprovalPushPlatform? = ApprovalNotifications.platform,
         register: @escaping (ApprovalPushRegistration) -> Void,
         unregister: @escaping (ApprovalPushPlatform) -> Void, open: @escaping (ApprovalPushHint) -> Void,
         verifyPush: @escaping @MainActor ([AnyHashable: Any], Bool) -> ApprovalPushHint? = { _, _ in nil },
         outcomePush: @escaping @MainActor ([AnyHashable: Any], Bool) -> Bool = { _, _ in false }) {
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
        self.outcomePush = outcomePush
        reconciliation = ApprovalPushReconciliation(saved: defaults.data(forKey: "agentApprovalNotificationResolutions"))
        super.init()
        inbox.onNew = { [weak self] entry in self?.showInAppAlert(entry) }
        for name in [Notification.Name.accountLoginChanged, .serverInfoChanged, .relayIdentityKeyChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(clearControlBanner), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(clearControlBanner),
            name: NSWorkspace.willSleepNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func clearControlBanner() {
        controlBannerGeneration = UUID()
        controlBanner?.orderOut(nil)
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
        if !enabled { banner?.orderOut(nil); outcomeBanner?.orderOut(nil); clearControlBanner() }
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

    @MainActor func outcomesChanged(sourceID: String, work: RemoteHostWork, hub: AstationHubManager) {
        if outcomeBannerSource == sourceID && (!work.canReviewOutcomes || work.alerts.isEmpty) {
            outcomeBanner?.orderOut(nil)
        }
        guard inAppEnabled, hub.takeOutcomeReminder(clientID: sourceID, work: work),
              let first = work.alerts.first else { return }
        let generation = UUID()
        outcomeBannerGeneration = generation; outcomeBannerSource = sourceID
        let panel = outcomeBanner ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OutcomeBannerView(alert: first, count: work.alerts.count, review: { [weak self, weak hub] in
            guard let self, let hub else { return }
            self.outcomeBanner?.orderOut(nil)
            self.showOutcomes(sourceID: sourceID, hub: hub)
        }, dismiss: { [weak self] in self?.outcomeBanner?.orderOut(nil) }))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 424, y: frame.maxY - 256, width: 408, height: 240), display: true)
        }
        outcomeBanner = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.outcomeBannerGeneration == generation { self?.outcomeBanner?.orderOut(nil) }
        }
    }

    @MainActor func showOutcomes(sourceID: String, hub: AstationHubManager) {
        outcomeWindowController?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            HostOutcomeView(hub: hub, clientID: sourceID) { [weak self] in self?.outcomeWindowController?.close() }))
        window.title = "Host Outcomes"; window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        outcomeWindowController = NSWindowController(window: window)
        outcomeWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func controlReviewsChanged(_ notice: AstationHubManager.ControlReviewNotice, hub: AstationHubManager) {
        guard notice.current() else { clearControlBanner(); return }
        if notice.count == 0 { clearControlBanner(); return }
        guard inAppEnabled, notice.shouldNotify else { return }
        let generation = UUID()
        controlBannerGeneration = generation
        let panel = controlBanner ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ControlReviewBannerView(count: notice.count, review: { [weak self, weak hub] in
            guard let self, let hub, notice.current() else { return }
            clearControlBanner()
            if controlActivityWindow == nil { controlActivityWindow = ControlActivityWindowController(hub: hub) }
            controlActivityWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }, dismiss: { [weak self] in self?.clearControlBanner() }))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - 424, y: frame.maxY - 440, width: 408, height: 172), display: true)
        }
        controlBanner = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.controlBannerGeneration == generation { self?.clearControlBanner() }
        }
    }

    func received(userInfo: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let hint = self.verifyPush(userInfo, false) else { _ = self.outcomePush(userInfo, false); return }
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
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let self {
                let info = response.notification.request.content.userInfo
                if let hint = self.verifyPush(info, true) {
                    self.inbox.notificationHint = hint
                    self.open(hint)
                    self.showPreferences()
                } else { _ = self.outcomePush(info, true) }
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inAppEnabled, self.pushEnabled else {
                completionHandler([]); return
            }
            guard let hint = self.verifyPush(notification.request.content.userInfo, false) else {
                _ = self.outcomePush(notification.request.content.userInfo, false)
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

private struct ControlReviewBannerView: View {
    let count: Int
    let review: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Saved stops need manager review", systemImage: "exclamationmark.shield.fill").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss alert")
            }
            Text("\(count) saved stop\(count == 1 ? "" : "s") may need a fresh manager signature.")
            Text("Review current access before confirming a new copy.").font(.caption)
            HStack { Spacer(); Button("Review Control Activity", action: review).buttonStyle(.borderedProminent) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct OutcomeBannerView: View {
    let alert: RemoteOutcomeAlert
    let count: Int
    let review: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Task outcome needs review", systemImage: "exclamationmark.triangle.fill").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss alert")
            }
            Text("\(alert.host_id) / \(alert.session_id)").font(.caption).lineLimit(1)
            Text("Task: \(alert.task_id)\nSender: \(alert.sender)").font(.caption.monospaced()).lineLimit(3)
            Text(alert.reason).font(.callout).lineLimit(2)
            if count > 1 { Text("\(count) unresolved outcomes on this host").font(.caption) }
            HStack { Spacer(); Button("Review outcomes", action: review).buttonStyle(.borderedProminent) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
