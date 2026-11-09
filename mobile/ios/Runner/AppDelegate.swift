import Flutter
import UIKit
import AstationRemote
import AtemClient

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var workspace: MobileWorkspaceBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    workspace = MobileWorkspaceBridge(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

@MainActor
private final class MobileWorkspaceBridge: NSObject, FlutterStreamHandler {
  private var contextID = UUID().uuidString
  private var revision: Int64 = 0
  private var sink: FlutterEventSink?
  private var environment: String
  private let developmentBuild: Bool
  private var accountLogin: MobileAccountLogin?
  private var notice: String?

  init(messenger: FlutterBinaryMessenger) {
    #if DEBUG
    developmentBuild = true
    environment = UserDefaults.standard.string(forKey: "mobile.environment") ?? "development"
    #else
    developmentBuild = false
    environment = "production"
    #endif
    super.init()
    accountLogin = try? MobileAccountLogin(development: environment == "development")
    uniffiEnsureAtemClientFfiInitialized()
    let methods = FlutterMethodChannel(name: "build.agora.astation/mobile.v1", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, reply in self?.handle(call, reply: reply) }
    FlutterEventChannel(name: "build.agora.astation/workspace.v1", binaryMessenger: messenger).setStreamHandler(self)
    Task { [weak self] in
      guard let self, let login = self.accountLogin else { return }
      do { try await login.restore() }
      catch { if self.accountLogin === login { self.notice = error.localizedDescription } }
      if self.accountLogin === login { self.publish(reset: true) }
    }
  }

  private func snapshot() -> [String: Any] {
    ["bridgeVersion": 1, "context": contextID, "revision": revision,
     "environment": environment,
     "account": accountLogin?.subject.map { ["id": $0, "name": "Agora.Build account"] } as Any? ?? NSNull(),
     "access": "notEnrolled",
     "deviceName": UIDevice.current.model, "deviceId": "", "loginAvailable": accountLogin != nil,
     "enrollmentAvailable": false,
     "hosts": [], "agents": [], "approvals": [], "profiles": [], "conversations": [], "rules": [],
     "notice": notice ?? "Verify this device before connecting to your agents."]
  }

  private func publish(reset: Bool = false) {
    if reset { contextID = UUID().uuidString }
    revision += 1
    sink?(snapshot())
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "readState": reply(snapshot())
    case "refresh", "setForeground":
      guard call.method != "setForeground" || args["foreground"] as? Bool == true,
            accountLogin?.subject != nil else { reply(nil); return }
      accountOperation(reply: reply) { try await $0.refresh(); return nil }
    case "signIn":
      accountOperation(reply: reply, reset: true) { try await $0.signIn(); return nil }
    case "signOut":
      accountOperation(reply: reply, reset: true) { try await $0.signOut(); return nil }
    case "verifyLogin":
      guard developmentBuild else { reply(FlutterMethodNotImplemented); return }
      accountOperation(reply: reply) { try await $0.verifyLogin() }
    case "selectEnvironment":
      guard developmentBuild, let selected = args["environment"] as? String,
            ["development", "production"].contains(selected) else {
        reply(FlutterError(code: "invalid_environment", message: "Server selection is available in development builds.", details: nil))
        return
      }
      Task {
        do {
          try await accountLogin?.signOut()
          environment = selected
          UserDefaults.standard.set(selected, forKey: "mobile.environment")
          accountLogin = try MobileAccountLogin(development: selected == "development")
          notice = nil
          publish(reset: true); reply(nil)
        } catch { reply(FlutterError(code: "account_error", message: error.localizedDescription, details: nil)) }
      }
    case "openExternal":
      guard let text = args["url"] as? String, let url = URL(string: text),
            url.scheme == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil else {
        reply(FlutterError(code: "invalid_url", message: "This link cannot be opened safely.", details: nil))
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        reply(opened ? nil : FlutterError(code: "browser_unavailable", message: "The browser could not open this link.", details: nil))
      }
    case "enrollDevice":
      reply(FlutterError(code: "enrollment_not_ready", message: "Device setup is not available in this build yet. Your account is signed in, but this device cannot access agents until trusted-device enrollment is implemented.", details: nil))
    default:
      reply(FlutterError(code: "not_authenticated", message: "Sign in and verify this device before connecting to an Atem.", details: nil))
    }
  }

  private func accountOperation(reply: @escaping FlutterResult, reset: Bool = false,
                                operation: @escaping (MobileAccountLogin) async throws -> Any?) {
    guard let login = accountLogin else {
      reply(FlutterError(code: "account_unavailable", message: "Account sign-in is unavailable.", details: nil)); return
    }
    Task {
      do {
        let result = try await operation(login)
        guard accountLogin === login else { throw AccountLoginError.changed }
        notice = nil; publish(reset: reset); reply(result)
      } catch {
        if accountLogin === login { notice = error.localizedDescription; publish() }
        reply(FlutterError(code: "account_error", message: error.localizedDescription, details: nil))
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; events(snapshot()); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
}
