import Foundation
import AstationRemote
import CryptoKit

extension Notification.Name {
    static let accountLoginChanged = Notification.Name("accountLoginChanged")
}

struct AccountServiceSettings: Equatable {
    static let portalKey = "AstationPortalURL"
    static let issuerKey = "AstationAccountIssuer"
    static let clientKey = "AstationAccountClientID"
    static let resourceKey = "AstationPortalResource"
    static let defaultPortal = "https://agora.build"
    static let defaultIssuer = "https://auth.agora.build"
    static let defaultClient = "astation"
    static let defaultResource = "https://api.agora.build"

    let portalURL: String
    let issuer: String
    let clientID: String
    let resource: String

    init(portalURL: String, issuer: String, clientID: String, resource: String) throws {
        self.portalURL = try Self.baseURL(portalURL)
        self.issuer = try Self.baseURL(issuer)
        self.resource = try Self.baseURL(resource)
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try oidcConfiguration
    }

    var oidcConfiguration: AccountOIDCConfiguration {
        get throws {
            try AccountOIDCConfiguration(issuer: issuer, clientID: clientID, resource: resource,
                requiredScope: "agora:projects", additionalScopes: ["agora:certificates"])
        }
    }

    static func load(defaults: UserDefaults = .standard,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws -> Self {
        func value(_ env: String, _ key: String, _ fallback: String) -> String {
            environment[env] ?? defaults.string(forKey: key) ?? info[key] as? String ?? fallback
        }
        let portal = value("ASTATION_PORTAL_URL", portalKey, defaultPortal)
        return try Self(portalURL: portal,
            issuer: issuerURL(forPortalURL: portal, environment: environment, info: info),
            clientID: value("ASTATION_ACCOUNT_CLIENT_ID", clientKey, defaultClient),
            resource: value("ASTATION_PORTAL_RESOURCE", resourceKey, defaultResource))
    }

    static func issuerURL(forPortalURL portalURL: String,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws -> String {
        let portal = try baseURL(portalURL)
        if let override = environment["ASTATION_ACCOUNT_ISSUER"] ?? info[issuerKey] as? String {
            return try baseURL(override)
        }
        guard var components = URLComponents(string: portal), let host = components.host,
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw AccountLoginError.configuration
        }
        components.host = "auth." + host
        guard let url = components.url else { throw AccountLoginError.configuration }
        return try baseURL(url.absoluteString)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(portalURL, forKey: Self.portalKey)
        // The portal determines Auth; old UI values must not pin a previous environment.
        defaults.removeObject(forKey: Self.issuerKey)
        defaults.set(clientID, forKey: Self.clientKey)
        defaults.set(resource, forKey: Self.resourceKey)
    }

    var accountURL: URL { URL(string: portalURL + "/account/")! }

    var storageContext: String {
        SHA256.hash(data: Data([portalURL, issuer, clientID, resource].joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func baseURL(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || parts.scheme == "http" &&
                (["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")),
              parts.port == nil || (1...65535).contains(parts.port!), parts.url != nil
        else { throw AccountLoginError.configuration }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
