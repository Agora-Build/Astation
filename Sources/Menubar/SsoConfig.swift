import Foundation

/// Resolves SSO and BFF base URLs.
/// Priority: env var > UserDefaults > baked-in default.
/// Mirrors the existing pattern in SettingsWindowController.currentAstationRelayUrl.
enum SsoConfig {
    static let ssoUrlKey = "AstationSsoUrl"
    static let bffUrlKey = "AstationBffUrl"

    static let defaultSsoUrl = "https://sso2.agora.io"
    static let defaultBffUrl = "https://agora-cli.agora.io"

    static var currentSsoUrl: String {
        if let env = ProcessInfo.processInfo.environment["ASTATION_SSO_URL"], !env.isEmpty {
            return env
        }
        let saved = UserDefaults.standard.string(forKey: ssoUrlKey) ?? ""
        return saved.isEmpty ? defaultSsoUrl : saved
    }

    static var currentBffUrl: String {
        if let env = ProcessInfo.processInfo.environment["ASTATION_BFF_URL"], !env.isEmpty {
            return env
        }
        let saved = UserDefaults.standard.string(forKey: bffUrlKey) ?? ""
        return saved.isEmpty ? defaultBffUrl : saved
    }
}
