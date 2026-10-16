import AppKit
import Security
import UserNotifications

/// OS delivery and registration only. Opening a hint hands off to authenticated
/// host catch-up; this delegate has no operation that can acquire or approve.
final class ApprovalNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let defaults: UserDefaults
    private let register: (ApprovalPushRegistration) -> Void
    private let unregister: (ApprovalPushPlatform) -> Void
    private let open: (ApprovalPushHint) -> Void
    private var reconciliation: ApprovalPushReconciliation
    private lazy var center = UNUserNotificationCenter.current()
    private let enabledKey = "agentApprovalNotificationsEnabled"
    private let platformKey = "agentApprovalNotificationsPlatform"
    private let resolutionsKey = "agentApprovalNotificationResolutions"
    private var permissionAttempt = UUID()

    init(defaults: UserDefaults = .standard, register: @escaping (ApprovalPushRegistration) -> Void,
         unregister: @escaping (ApprovalPushPlatform) -> Void, open: @escaping (ApprovalPushHint) -> Void) {
        self.defaults = defaults
        self.register = register
        self.unregister = unregister
        self.open = open
        reconciliation = ApprovalPushReconciliation(saved: defaults.data(forKey: "agentApprovalNotificationResolutions"))
        super.init()
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
        if defaults.bool(forKey: enabledKey), Self.platform != nil {
            center.delegate = self
            let attempt = permissionAttempt
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self, self.permissionAttempt == attempt else { return }
                    if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                        NSApp.registerForRemoteNotifications()
                    } else {
                        self.defaults.set(false, forKey: self.enabledKey)
                        if let platform = Self.platform { self.unregister(platform) }
                    }
                }
            }
        } else if let raw = defaults.string(forKey: platformKey), let platform = ApprovalPushPlatform(rawValue: raw) {
            unregister(platform)
        }
    }

    func showPreferences() {
        guard let platform = Self.platform else {
            let alert = NSAlert()
            alert.messageText = "Push notifications need a provisioned build"
            alert.informativeText = "Enable Push Notifications for Astation's app identifier in your Apple Developer account, then build with its matching provisioning profile. This build has no APNs entitlement."
            alert.runModal()
            return
        }
        let enabled = defaults.bool(forKey: enabledKey)
        let alert = NSAlert()
        alert.messageText = enabled ? "Approval notifications are enabled" : "Enable approval notifications?"
        alert.informativeText = "Notifications open Astation to reconnect and check the request with Atem. A notification never approves a command. Delivery also requires a compatible authenticated Atem host and relay push configuration."
        alert.addButton(withTitle: enabled ? "Disable Notifications" : "Enable Notifications")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        permissionAttempt = UUID()
        if enabled {
            defaults.set(false, forKey: enabledKey)
            unregister(platform)
            NSApp.unregisterForRemoteNotifications()
        } else {
            center.delegate = self
            let attempt = permissionAttempt
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self, self.permissionAttempt == attempt else { return }
                    self.defaults.set(granted, forKey: self.enabledKey)
                    if granted {
                        self.defaults.set(platform.rawValue, forKey: self.platformKey)
                        NSApp.registerForRemoteNotifications()
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Notifications are disabled"
                        alert.informativeText = "Allow Astation in System Settings > Notifications, then enable approval notifications again."
                        alert.runModal()
                    }
                }
            }
        }
    }

    func registered(deviceToken: Data) {
        guard defaults.bool(forKey: enabledKey), let platform = Self.platform,
              let registration = ApprovalPushRegistration(deviceToken: deviceToken, platform: platform) else { return }
        defaults.set(platform.rawValue, forKey: platformKey)
        register(registration)
    }

    func registrationFailed() {
        Log.warn("[Approvals] APNs registration failed; check the app's provisioning and network connection")
    }

    func received(userInfo: [String: Any]) {
        guard let hint = ApprovalPushHint(userInfo: userInfo) else { return }
        let remove = reconciliation.receive(hint, now: Date())
        defaults.set(reconciliation.saved, forKey: resolutionsKey)
        if remove {
            center.removeDeliveredNotifications(withIdentifiers: [hint.approvalID])
            center.removePendingNotificationRequests(withIdentifiers: [hint.approvalID])
            // The OS may assign its own identifier to an APNs delivery.
            center.getDeliveredNotifications { [weak self] notifications in
                let identifiers = notifications.filter {
                    guard let delivered = ApprovalPushHint(userInfo: $0.request.content.userInfo) else { return false }
                    return delivered.approvalID == hint.approvalID && delivered.atemDeviceID == hint.atemDeviceID
                }.map { $0.request.identifier }
                self?.center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let hint = ApprovalPushHint(userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async { [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let hint { self?.open(hint) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.defaults.bool(forKey: self.enabledKey),
                  let hint = ApprovalPushHint(userInfo: notification.request.content.userInfo) else {
                completionHandler([]); return
            }
            let remove = self.reconciliation.receive(hint, now: Date())
            self.defaults.set(self.reconciliation.saved, forKey: self.resolutionsKey)
            completionHandler(remove ? [] : [.banner, .sound])
        }
    }
}
