#if os(iOS)
import AuthenticationServices
import Foundation
import Security
import UIKit

private struct MobileAccountStorage: AccountSessionStorage {
    let environment: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "build.agora.astation.mobile.oidc.v1",
         kSecAttrAccount as String: environment,
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> AccountSessionRecord? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? PropertyListDecoder().decode(AccountSessionRecord.self, from: data)
        else { throw AccountLoginError.storage }
        return record
    }
    func write(_ record: AccountSessionRecord?) throws {
        guard let record else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountLoginError.storage }
            return
        }
        // Access tokens stay in memory; a durable pending marker prevents refresh reuse after a crash.
        let saved = AccountSessionRecord(session: record.session.removingAccessToken(), refreshPending: record.refreshPending)
        let data = try PropertyListEncoder().encode(saved)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccountLoginError.storage }
        } else if status != errSecSuccess { throw AccountLoginError.storage }
    }
}

/// iOS presentation and storage around the same OAuth verifier/provider used on Mac.
@MainActor
public final class MobileAccountLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    public let configuration: AccountOIDCConfiguration
    private let client: AccountOIDCClient
    private let provider: AccountTokenProvider
    private var browser: ASWebAuthenticationSession?
    private var completeBrowser: ((Result<URL, Error>) -> Void)?
    private var generation = UUID()
    public private(set) var subject: String?

    public init(development: Bool) throws {
        let configuration = try AccountOIDCConfiguration(
            issuer: development ? "https://auth.dev.agora.build" : "https://auth.agora.build",
            clientID: "astation-ios",
            resource: development ? "https://station-dev.agora.build" : "https://station.agora.build",
            requiredScope: "astation.remote")
        self.configuration = configuration
        client = AccountOIDCClient(configuration: configuration)
        provider = AccountTokenProvider(configuration: configuration, client: client,
            storage: MobileAccountStorage(environment: development ? "development" : "production"))
    }

    public func restore() async throws {
        let epoch = generation
        guard try await provider.current() != nil else { return }
        _ = try await provider.validToken()
        guard generation == epoch else { throw AccountLoginError.changed }
        subject = try await provider.current()?.session.subject
    }

    public func signIn() async throws {
        let epoch = generation
        let login = try await provider.beginLogin()
        do {
            let attempt = try AccountLoginAttempt()
            let redirect = configuration.mobileRedirectURI!
            let url = try await client.authorizationURL(attempt: attempt, redirectURI: redirect)
            guard generation == epoch else { throw AccountLoginError.changed }
            let callback = try await authenticate(url: url)
            guard generation == epoch else { throw AccountLoginError.changed }
            let code = try attempt.mobileCallbackCode(url: callback, configuration: configuration)
            let session = try await client.exchange(code: code, attempt: attempt, redirectURI: redirect)
            guard generation == epoch else { throw AccountLoginError.changed }
            try await provider.finishLogin(session, attempt: login)
            subject = session.subject
        } catch {
            await provider.cancelLogin(login)
            throw error
        }
    }

    public func refresh() async throws {
        let epoch = generation
        _ = try await provider.validToken()
        guard generation == epoch else { throw AccountLoginError.changed }
        subject = try await provider.current()?.session.subject
    }

    public func signOut() async throws {
        generation = UUID()
        subject = nil
        browser?.cancel()
        completeBrowser?(.failure(AccountLoginError.cancelled))
        try await provider.signOut()
    }

    /// Redacted acceptance evidence. A missing membership log is expected before enrollment.
    public func verifyLogin() async throws -> [String: Any] {
        let epoch = generation
        let before = try await provider.current()
        _ = try await provider.renewToken()
        guard generation == epoch, let after = try await provider.current(),
              let before, before.session.refreshToken != after.session.refreshToken,
              let authenticatedAt = after.session.authenticatedAt,
              before.session.authenticatedAt == authenticatedAt
        else { throw AccountLoginError.rejected }
        let token = try await provider.validToken()
        var request = URLRequest(url: URL(string: configuration.resource + "/api/remote/v1/logs/" + String(repeating: "0", count: 64) + "/entries?after=0")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, status) = try await AccountURLSessionHTTP().send(request)
        guard generation == epoch else { throw AccountLoginError.changed }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 404, (body?["error"] as? [String: Any])?["code"] as? String == "recovery_record_not_found" else {
            throw status == 401 ? AccountLoginError.signInRequired : AccountLoginError.rejected
        }
        return ["clientId": configuration.clientID, "station": configuration.resource,
                "refreshRotated": true, "authTimeUnchanged": true, "stationTokenAccepted": true,
                "memberChannelVerified": false]
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let finish: (Result<URL, Error>) -> Void = { [weak self] result in
                guard !completed else { return }
                completed = true
                self?.browser = nil
                self?.completeBrowser = nil
                continuation.resume(with: result)
            }
            completeBrowser = finish
            browser = ASWebAuthenticationSession(url: url, callbackURLScheme: "build.agora.astation.ios") { callback, _ in
                Task { @MainActor in
                    if let callback { finish(.success(callback)) }
                    else { finish(.failure(AccountLoginError.cancelled)) }
                }
            }
            browser?.presentationContextProvider = self
            guard browser?.start() == true else { finish(.failure(AccountLoginError.unavailable)); return }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
#endif
