import AppKit
import CryptoKit
import XCTest
@testable import AstationRemote
@testable import Menubar

private final class PortalAccountStorage: AccountSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var record: AccountSessionRecord?
    init(_ session: AccountLoginSession) { record = AccountSessionRecord(session: session) }
    func read() throws -> AccountSessionRecord? { lock.lock(); defer { lock.unlock() }; return record }
    func write(_ value: AccountSessionRecord?) throws { lock.lock(); defer { lock.unlock() }; record = value }
}
private actor PortalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private actor PortalHTTP: AccountOIDCHTTP {
    var calls: [URLRequest] = []
    var responses: [String: (String, Int)] = [
        "/api/v1/connections": (#"{"agora":{"ready":true,"connect":true,"connected":true,"name":"Agora Lab"}}"#, 200),
        "/api/v1/connections/agora/projects": (#"{"projects":[{"projectId":"p1","appId":"app1","name":"Voice Lab","status":"active"}]}"#, 200),
        "/api/v1/connections/agora/certificate": (#"{"projectId":"p1","appId":"app1","certificate":"test-certificate"}"#, 200)
    ]
    var gate: PortalGate?
    var offline = false
    var blockedPath = "/api/v1/connections/agora/projects"
    var rejectedToken: String?
    var rejectedPaths: Set<String> = []
    func goOffline() { offline = true }
    func block(_ gate: PortalGate, path: String = "/api/v1/connections/agora/projects") { self.gate = gate; blockedPath = path }
    func set(_ path: String, _ body: String, _ status: Int = 200) { responses[path] = (body, status) }
    func reject(_ token: String, paths: Set<String>) { rejectedToken = token; rejectedPaths = paths }
    func requests() -> [URLRequest] { calls }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        let response = rejectedPaths.contains(path) && request.value(forHTTPHeaderField: "Authorization") == rejectedToken.map({ "Bearer " + $0 })
            ? (#"{"error":"invalid_token"}"#, 401) : responses[path]!
        if path == blockedPath, let gate { await gate.wait() }
        return (Data(response.0.utf8), response.1)
    }
}

private final class PortalCacheStorage: AccountDataStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws { self.data = data }
}

@MainActor private final class PortalHubFixture {
    let directory: URL
    let suite = "Astation.portal-hub.\(UUID())"
    let defaults: UserDefaults
    let storage: PortalAccountStorage
    let stationStorage: PortalAccountStorage
    let auth: AstationAccountAuth
    let hub: AstationHubManager
    let legacy: SsoSessionStore
    let subject: String
    let cacheStorage: PortalCacheStorage
    let legacySession = SsoSession(accessToken: "agora-service", refreshToken: "agora-refresh", expiresAt: UInt64.max, loginId: "service")
    init(config: AccountServiceSettings, http: PortalHTTP, cacheStorage: PortalCacheStorage = PortalCacheStorage(),
         subject: String = "ab01234567890123456789012345") throws {
        self.subject = subject; self.cacheStorage = cacheStorage
        defaults = UserDefaults(suiteName: suite)!
        let authConfig = try config.oidcConfiguration
        storage = PortalAccountStorage(AccountLoginSession(configuration: authConfig, subject: subject,
            accessToken: "portal-access", refreshToken: "test-refresh", expiresAt: Date().addingTimeInterval(600), authenticatedAt: nil))
        auth = AstationAccountAuth(configuration: authConfig, storage: storage, http: http)
        let stationConfig = try AccountOIDCConfiguration(issuer: config.issuer, clientID: config.clientID,
            resource: "https://station.portal-tests.example", requiredScope: "astation.remote")
        stationStorage = PortalAccountStorage(AccountLoginSession(configuration: stationConfig, subject: subject,
            accessToken: "station-access", refreshToken: "station-refresh", expiresAt: Date().addingTimeInterval(600), authenticatedAt: nil))
        let stationAuth = AstationAccountAuth(configuration: stationConfig, storage: stationStorage, http: http)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacy = SsoSessionStore(storageURL: directory.appendingPathComponent("sso"))
        try legacy.save(legacySession)
        hub = AstationHubManager(skipProjectLoad: true,
            deviceSessionStore: SessionStore(storageURL: directory.appendingPathComponent("devices")), sessionStore: legacy,
            atemE2EIdentity: AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography()), sessionJournal: AtemSessionJournal(),
            portalSettings: config, portalAuth: auth, stationAuth: stationAuth, portalAPI: PortalAPIClient(http: http),
            projectCache: PortalProjectCache(storage: cacheStorage), accountDefaults: defaults)
        hub._testRelayUrlOverride = stationConfig.resource
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

final class AccountServiceSettingsTests: XCTestCase {
    func testDefaultsOverridesPersistenceAndURLValidation() throws {
        let suite = "Astation.portal-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:])
        XCTAssertEqual(initial.portalURL, "https://agora.build")
        XCTAssertEqual(initial.issuer, "https://auth.agora.build")
        XCTAssertEqual(initial.resource, "https://agora.build")
        XCTAssertEqual(try initial.oidcConfiguration.apiScopes, ["agora:projects", "agora:certificates"])
        let settings = try AccountServiceSettings(portalURL: " https://portal.example/ ", issuer: "https://auth.portal.example/",
            clientID: "native-test", resource: "https://portal.example")
        settings.save(defaults: defaults)
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:]), settings)
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults,
            environment: ["ASTATION_PORTAL_URL":"https://override.example"], info: [:]).portalURL, "https://override.example")
        XCTAssertEqual(settings.accountURL.absoluteString, "https://portal.example/account/")
        XCTAssertNotEqual(settings.storageContext, initial.storageContext)
        XCTAssertNotEqual(settings.storageContext, try AccountServiceSettings(portalURL: settings.portalURL,
            issuer: "https://other-auth.example", clientID: settings.clientID, resource: settings.resource).storageContext)
        for url in ["http://remote.example", "https://user:password@portal.example", "https://portal.example/path",
                    "https://portal.example?token=secret", "https://portal.example#x", "file:///tmp/account", "https://", "https://portal.example:0"] {
            XCTAssertThrowsError(try AccountServiceSettings.baseURL(url), url)
        }
        XCTAssertEqual(try AccountServiceSettings.baseURL("http://127.0.0.1:8081/"), "http://127.0.0.1:8081")
    }

    func testPortalChangesDeriveAuthWithoutReusingThePreviousIssuer() throws {
        let suite = "Astation.derived-auth.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://dev.agora.build", forKey: AccountServiceSettings.portalKey)
        defaults.set("https://old-auth.example", forKey: AccountServiceSettings.issuerKey)
        let initial = try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:])
        XCTAssertEqual(initial.issuer, "https://auth.dev.agora.build")
        XCTAssertEqual(initial.resource, "https://dev.agora.build")
        defaults.set("https://api.agora.build", forKey: AccountServiceSettings.resourceKey)
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:]).resource, initial.resource)
        let production = try AccountServiceSettings.load(defaults: defaults,
            environment: ["ASTATION_PORTAL_URL": "https://agora.build"], info: [:])
        XCTAssertEqual(production.issuer, "https://auth.agora.build")
        XCTAssertEqual(production.resource, "https://agora.build")
        XCTAssertNotEqual(production.storageContext, initial.storageContext)
        production.save(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: AccountServiceSettings.issuerKey))
        XCTAssertNil(defaults.string(forKey: AccountServiceSettings.resourceKey))
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:]), production)
        let custom = try AccountServiceSettings.load(defaults: defaults,
            environment: ["ASTATION_PORTAL_URL": "https://preview.example:8443"], info: [:])
        XCTAssertEqual(custom.issuer, "https://auth.preview.example:8443")
        XCTAssertEqual(custom.resource, "https://preview.example:8443")
        XCTAssertEqual(custom.clientID, initial.clientID)
    }

    func testExplicitDeveloperAuthOverrideSupportsSeparateLoopbackPorts() throws {
        let suite = "Astation.local-auth.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let portal = ["ASTATION_PORTAL_URL": "http://127.0.0.1:3000"]
        XCTAssertThrowsError(try AccountServiceSettings.load(defaults: defaults, environment: portal, info: [:]))
        var environment = portal
        environment["ASTATION_ACCOUNT_ISSUER"] = "http://127.0.0.1:4000"
        let settings = try AccountServiceSettings.load(defaults: defaults, environment: environment, info: [:])
        XCTAssertEqual(settings.issuer, "http://127.0.0.1:4000")
        XCTAssertEqual(settings.resource, "http://127.0.0.1:3000")
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: portal,
            info: [AccountServiceSettings.issuerKey: "http://127.0.0.1:5000"]).issuer, "http://127.0.0.1:5000")
        settings.save(defaults: defaults)
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: environment, info: [:]), settings)
        XCTAssertThrowsError(try AccountServiceSettings.issuerURL(forPortalURL: "https://[::1]", environment: [:], info: [:]))
        environment["ASTATION_PORTAL_RESOURCE"] = "http://127.0.0.1:6000/"
        XCTAssertEqual(try AccountServiceSettings.load(defaults: defaults, environment: environment, info: [:]).resource, "http://127.0.0.1:6000")
    }
}

@MainActor final class PortalAccountTests: XCTestCase {
    private let appID = "0123456789abcdef0123456789abcdef"
    private let certificate = "abcdef0123456789abcdef0123456789"
    private func settings(_ suffix: String = "") throws -> AccountServiceSettings {
        try AccountServiceSettings(portalURL: "https://portal\(suffix).example", issuer: "https://auth.portal\(suffix).example",
            clientID: "astation-test", resource: "https://portal\(suffix).example")
    }
    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Portal operation")
    }

    func testProjectsWindowGatesActionsThroughSignInOfflineUseAndReauthentication() async throws {
        _ = NSApplication.shared
        let http = await linkedHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        let record = try XCTUnwrap(fixture.storage.read())
        try fixture.storage.write(nil)
        let controller = ProjectsWindowController(hubManager: fixture.hub)
        controller.showWindow()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Agora Projects" })
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(window.contentView))
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        let generate = try button("Generate Token...")
        let signIn = try button("Sign in to Agora.Build...")
        let connect = try button("Connect Agora Account...")
        let refresh = try button("Refresh Projects")
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let contextGenerate = try XCTUnwrap(table.menu?.items.first)
        XCTAssertFalse(generate.isEnabled)
        XCTAssertFalse(controller.validateMenuItem(contextGenerate))
        XCTAssertFalse(signIn.isHidden)
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(refresh.isEnabled)
        let prompt = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Sign in to Agora.Build to load your projects and generate tokens."
        })
        XCTAssertEqual(prompt.textColor, .secondaryLabelColor)
        window.setContentSize(NSSize(width: 820, height: 380))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThan(signIn.convert(signIn.bounds, to: nil).maxX, connect.convert(connect.bounds, to: nil).minX)

        try fixture.storage.write(record)
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.selectedProject?.signKey == self.certificate && generate.isEnabled }
        XCTAssertTrue(signIn.isHidden)
        XCTAssertTrue(connect.isEnabled)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(controller.validateMenuItem(contextGenerate))

        await http.goOffline()
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.usingSavedProjects && fixture.hub.projectLoadError != nil }
        XCTAssertTrue(generate.isEnabled, "A network outage must not disable authorized local token generation")

        try fixture.storage.write(AccountSessionRecord(session: record.session, refreshPending: true))
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.accountSignInRequired && !generate.isEnabled }
        XCTAssertFalse(signIn.isHidden)
        XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(controller.validateMenuItem(contextGenerate))
        XCTAssertEqual(fixture.hub.projects.count, 1, "Reauthentication must retain the protected project cache")

        try await fixture.hub.signOutAccount()
        await waitUntil { fixture.hub.signedInAccount == nil && !generate.isEnabled }
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertFalse(signIn.isHidden)
    }

    private func prepareRefresh(config: AccountServiceSettings, http: PortalHTTP) async throws {
        let key = P256.Signing.PrivateKey(), raw = key.publicKey.x963Representation
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Int64(Date().timeIntervalSince1970)
        let header = encode(Data(try json(["typ":"at+jwt", "alg":"ES256", "kid":"one"]).utf8))
        let payload = encode(Data(try json(["iss": config.issuer, "sub":"ab01234567890123456789012345",
            "aud": config.resource, "iat":now, "exp":now + 900, "client_id":config.clientID,
            "scope":"agora:projects agora:certificates"]).utf8))
        let signed = header + "." + payload
        let token = signed + "." + encode(try key.signature(for: Data(signed.utf8)).rawRepresentation)
        await http.set("/.well-known/openid-configuration", try json(["issuer":config.issuer,
            "authorization_endpoint": config.issuer + "/authorize", "token_endpoint":config.issuer + "/token", "jwks_uri":config.issuer + "/keys"]))
        await http.set("/keys", try json(["keys":[["kid":"one", "kty":"EC", "crv":"P-256", "alg":"ES256",
            "x":encode(raw.subdata(in: 1..<33)), "y":encode(raw.subdata(in: 33..<65))]]]))
        await http.set("/token", try json(["token_type":"Bearer", "access_token":token, "refresh_token":"refresh-two"]))
    }

    func testEachPortalEndpointRefreshesOnceAndKeepsLocalTokenGeneration() async throws {
        for path in ["/api/v1/connections", "/api/v1/connections/agora/projects", "/api/v1/connections/agora/certificate"] {
            let config = try settings(), http = PortalHTTP()
            try await prepareRefresh(config: config, http: http)
            await http.reject("portal-access", paths: [path])
            let fixture = try PortalHubFixture(config: config, http: http)
            defer { fixture.cleanup() }
            fixture.hub.refreshProjects()
            await waitUntil { fixture.hub.selectedProject?.signKey == "test-certificate" || fixture.hub.projectLoadError != nil }
            XCTAssertEqual(fixture.hub.selectedProject?.signKey, "test-certificate")
            XCTAssertNil(fixture.hub.projectLoadError)
            XCTAssertEqual(try fixture.storage.read()?.session.refreshToken, "refresh-two")
            let before = await http.requests()
            XCTAssertEqual(before.filter { $0.url?.path == "/token" }.count, 1)
            XCTAssertEqual(before.filter { $0.url?.path == path }.count, 2)
            _ = try await fixture.hub.projectWithCertificate(id: "app1")
            let after = await http.requests()
            XCTAssertEqual(after.count, before.count)
            XCTAssertEqual(fixture.legacy.load()?.accessToken, "agora-service")
        }
    }

    func testConsoleReconnectResponsesPreserveAgoraBuildLoginWithoutRefreshing() async throws {
        for path in ["/api/v1/connections", "/api/v1/connections/agora/projects"] {
            let http = PortalHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
            defer { fixture.cleanup() }
            await http.set(path, #"{"reconnect":true}"#, 401)
            fixture.hub.refreshProjects()
            await waitUntil { fixture.hub.projectLoadError != nil }
            XCTAssertEqual(fixture.hub.projectLoadError, PortalAPIError.connectAgora.localizedDescription)
            XCTAssertEqual(fixture.hub.signedInAccount, fixture.subject)
            XCTAssertNotNil(try fixture.storage.read())
            XCTAssertFalse(fixture.hub.agoraConnection?.connected ?? true)
            let calls = await http.requests()
            XCTAssertFalse(calls.contains { $0.url?.path == "/token" })
        }
    }

    func testConnectionReconnectFlagPreventsProjectRequests() async throws {
        let http = PortalHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        await http.set("/api/v1/connections", #"{"agora":{"ready":true,"connect":true,"connected":true,"reconnect":true}}"#)
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.projectLoadError != nil }
        XCTAssertEqual(fixture.hub.projectLoadError, PortalAPIError.connectAgora.localizedDescription)
        let calls = await http.requests()
        XCTAssertEqual(calls.map { $0.url!.path }, ["/api/v1/connections"])
    }

    func testPortalRejectsAnAuthProviderForAnotherEnvironmentBeforeSendingTokens() async throws {
        let http = PortalHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        do { _ = try await PortalAPIClient(http: http).connection(settings: settings("-other"), auth: fixture.auth); XCTFail("Wrong environment accepted") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        let calls = await http.requests(); XCTAssertTrue(calls.isEmpty)
    }
    func testPortalRoutesKeepTokensOnThePortalAndVerifyCertificateBinding() async throws {
        let http = PortalHTTP()
        let api = PortalAPIClient(http: http), config = try settings()
        let connection = try await api.connection(settings: config, token: "portal-access")
        XCTAssertEqual(connection.name, "Agora Lab")
        let projects = try await api.projects(settings: config, token: "portal-access")
        XCTAssertEqual(projects[0].localProject.signKey, "")
        let project = try await api.certificate(project: projects[0], settings: config, token: "portal-access")
        XCTAssertEqual(project.name, "Voice Lab"); XCTAssertEqual(project.signKey, "test-certificate")
        let calls = await http.requests()
        XCTAssertEqual(calls.map { $0.url!.host! }, Array(repeating: "portal.example", count: 3))
        XCTAssertTrue(calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer portal-access" })
        XCTAssertEqual(calls.last?.httpMethod, "POST")
        XCTAssertEqual(try JSONDecoder().decode([String:String].self, from: calls.last!.httpBody!), ["projectId":"p1"])
        await http.set("/api/v1/connections/agora/certificate", #"{"projectId":"another","appId":"app1","certificate":"wrong"}"#)
        do { _ = try await api.certificate(project: projects[0], settings: config, token: "portal-access"); XCTFail("Mixed project certificate") }
        catch { XCTAssertEqual(error as? PortalAPIError, .invalidResponse) }
        for (code, expected) in [(401, PortalAPIError.signInRequired), (403, .permission), (503, .unavailable), (302, .unavailable)] {
            await http.set("/api/v1/connections", "{}", code)
            do { _ = try await api.connection(settings: config, token: "portal-access"); XCTFail("Accepted HTTP \(code)") }
            catch { XCTAssertEqual(error as? PortalAPIError, expected) }
        }
    }

    func testUnlinkedAgoraShowsConnectWithoutRequestingProjectsOrCertificates() async throws {
        let http = PortalHTTP()
        await http.set("/api/v1/connections", #"{"agora":{"ready":true,"connect":true,"connected":false}}"#)
        let fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        let hub = fixture.hub
        hub.refreshProjects()
        await waitUntil { hub.projectLoadError != nil }
        XCTAssertEqual(hub.projectLoadError, PortalAPIError.connectAgora.localizedDescription)
        XCTAssertEqual(hub.signedInAccount, fixture.subject)
        XCTAssertFalse(hub.agoraConnection?.connected ?? true)
        XCTAssertTrue(hub.projects.isEmpty)
        let calls = await http.requests()
        XCTAssertEqual(calls.map { $0.url!.path }, ["/api/v1/connections"])
    }

    private func linkedHTTP() async -> PortalHTTP {
        let http = PortalHTTP()
        await http.set("/api/v1/connections/agora/projects", "{\"projects\":[{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"name\":\"Voice Lab\",\"status\":\"active\"}]}")
        await http.set("/api/v1/connections/agora/certificate", "{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"certificate\":\"\(certificate)\"}")
        return http
    }

    func testLocalTokensDoNotCallTheAPIAndSurviveAnOfflineRestart() async throws {
        let config = try settings(), online = await linkedHTTP(), cache = PortalCacheStorage()
        let first = try PortalHubFixture(config: config, http: online, cacheStorage: cache)
        defer { first.cleanup() }
        first.hub.refreshProjects()
        await waitUntil { first.hub.selectedProject?.signKey == self.certificate }
        let before = await online.requests().count
        for uid in 1...3 {
            let response = await first.hub.generateRTCToken(channel: "offline-room", uid: uid)
            XCTAssertTrue(try AgoraTokenService.verify(response.token, certificate: certificate))
        }
        let after = await online.requests().count
        XCTAssertEqual(after, before, "Token generation must not call Portal when the certificate is cached")
        let offline = PortalHTTP(); await offline.goOffline()
        let restarted = try PortalHubFixture(config: config, http: offline, cacheStorage: cache)
        defer { restarted.cleanup() }
        restarted.hub.refreshProjects()
        await waitUntil { restarted.hub.usingSavedProjects && restarted.hub.projectLoadError != nil }
        XCTAssertEqual(restarted.hub.selectedProject?.signKey, certificate)
        XCTAssertEqual(restarted.hub.projects.count, 1)
        let offlineBefore = await offline.requests().count
        let response = await restarted.hub.generateRTCToken(channel: "offline-room", uid: 42)
        XCTAssertTrue(try AgoraTokenService.verify(response.token, certificate: certificate))
        let offlineAfter = await offline.requests().count
        XCTAssertEqual(offlineAfter, offlineBefore)
        let expired = AccountLoginSession(configuration: try config.oidcConfiguration, subject: restarted.subject,
            accessToken: "expired-portal-access", refreshToken: "uncertain-refresh", expiresAt: .distantPast, authenticatedAt: nil)
        try restarted.storage.write(AccountSessionRecord(session: expired, refreshPending: true))
        restarted.hub.refreshProjects()
        await waitUntil { restarted.hub.projectLoadError?.contains("Sign in again") == true }
        let afterExpiredLogin = await restarted.hub.generateRTCToken(channel: "offline-room", uid: 43)
        XCTAssertTrue(try AgoraTokenService.verify(afterExpiredLogin.token, certificate: certificate))
        try await restarted.hub.signOutAccount()
        XCTAssertNil(try cache.read())
        XCTAssertTrue(restarted.hub.projects.isEmpty)
    }

    func testOnlineRefreshRotatesCertificateAndRemovesRevokedProjectsFromOfflineCache() async throws {
        let http = await linkedHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.selectedProject?.signKey == self.certificate }
        let rotated = "fedcba9876543210fedcba9876543210"
        await http.set("/api/v1/connections/agora/certificate", "{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"certificate\":\"\(rotated)\"}")
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.selectedProject?.signKey == rotated }
        let response = await fixture.hub.generateRTCToken(channel: "rotated", uid: 42)
        XCTAssertTrue(try AgoraTokenService.verify(response.token, certificate: rotated))
        XCTAssertFalse(try AgoraTokenService.verify(response.token, certificate: certificate))
        await http.set("/api/v1/connections/agora/projects", #"{"projects":[]}"#)
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.projects.isEmpty }
        let record = try PortalProjectCache(storage: fixture.cacheStorage).load(subject: fixture.subject)
        XCTAssertEqual(record?.projects.count, 0)
        await http.goOffline()
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.projectLoadError != nil }
        XCTAssertTrue(fixture.hub.projects.isEmpty)
    }

    func testOfflineCacheCannotBeUsedByAnotherAccount() async throws {
        let http = await linkedHTTP(), cache = PortalCacheStorage(), config = try settings()
        let first = try PortalHubFixture(config: config, http: http, cacheStorage: cache)
        defer { first.cleanup() }
        first.hub.refreshProjects()
        await waitUntil { first.hub.selectedProject?.signKey == self.certificate }
        let offline = PortalHTTP(); await offline.goOffline()
        let other = try PortalHubFixture(config: config, http: offline, cacheStorage: cache,
            subject: "ab99999999999999999999999999")
        defer { other.cleanup() }
        other.hub.refreshProjects()
        await waitUntil { other.hub.projectLoadError != nil }
        XCTAssertTrue(other.hub.projects.isEmpty)
        XCTAssertFalse(other.hub.usingSavedProjects)
    }

    func testUnlinkedAccountClearsPreviouslySavedCertificates() async throws {
        let http = await linkedHTTP(), fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.selectedProject?.signKey == self.certificate }
        await http.set("/api/v1/connections", #"{"agora":{"ready":true,"connect":true,"connected":false}}"#)
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.projectLoadError != nil }
        XCTAssertEqual(fixture.hub.projectLoadError, PortalAPIError.connectAgora.localizedDescription)
        XCTAssertTrue(fixture.hub.projects.isEmpty)
        XCTAssertNil(try fixture.cacheStorage.read())
    }

    func testLateCertificateAfterLogoutCannotRepopulateTheCache() async throws {
        let http = await linkedHTTP(), gate = PortalGate()
        await http.block(gate, path: "/api/v1/connections/agora/certificate")
        let fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        fixture.hub.refreshProjects()
        await waitUntil { await http.requests().contains { $0.url?.path == "/api/v1/connections/agora/certificate" } }
        try await fixture.hub.signOutAccount()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(try fixture.cacheStorage.read())
        XCTAssertTrue(fixture.hub.projects.isEmpty)
    }

    func testGeneralShowsUnifiedServersAtMinimumWidth() throws {
        _ = NSApplication.shared
        let fixture = try PortalHubFixture(config: settings(), http: PortalHTTP())
        defer { fixture.cleanup() }
        let controller = SettingsWindowController(hubManager: fixture.hub,
            hotkeyManager: HotkeyManager(defaults: fixture.defaults),
            recordingManager: AudioRecordingManager(defaults: fixture.defaults, applicationCatalog: { [] }))
        let general = controller.makeGeneralView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 519, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = general
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let all = descendants(general)
        let fields = all.compactMap { $0 as? NSTextField }.filter { ["Portal URL", "Relay URL"].contains($0.accessibilityLabel() ?? "") }
        XCTAssertEqual(fields.count, 2)
        XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { ["Client ID", "Auth URL", "API resource"].contains($0.accessibilityLabel() ?? "") })
        for field in fields {
            XCTAssertGreaterThan(field.bounds.width, 240)
            XCTAssertLessThanOrEqual(field.convert(field.bounds, to: general).maxX, general.bounds.width)
        }
        XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Servers & Connections" })
        XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Direct Atem connections") })
        XCTAssertTrue(all.compactMap { $0 as? NSButton }.contains { $0.title == "Save Servers" })
        XCTAssertFalse(all.compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Sign in") || $0.title == "Refresh Projects" })
        let scroll = try XCTUnwrap(general as? NSScrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        if let directory = ProcessInfo.processInfo.environment["ASTATION_SETTINGS_SNAPSHOT_DIR"],
           let bitmap = general.bitmapImageRepForCachingDisplay(in: general.bounds) {
            general.cacheDisplay(in: general.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("general-minimum.png"))
        }
    }

    func testSignOutDropsDelayedProjectResponseAndKeepsLegacyServiceCredentials() async throws {
        try await checkDelayedProjectResponse(changeServers: false)
    }

    func testServerChangeDropsDelayedProjectsAndCannotReuseTheOldSession() async throws {
        try await checkDelayedProjectResponse(changeServers: true)
    }

    private func checkDelayedProjectResponse(changeServers: Bool) async throws {
        let config = try settings(), http = PortalHTTP(), gate = PortalGate()
        await http.block(gate)
        let fixture = try PortalHubFixture(config: config, http: http)
        defer { fixture.cleanup() }
        let hub = fixture.hub
        hub.refreshProjects()
        await waitUntil { await http.requests().contains { $0.url?.path == "/api/v1/connections/agora/projects" } }
        XCTAssertEqual(hub.signedInAccount, fixture.subject)
        if changeServers {
            let next = try settings("-next")
            try await hub.updateAccountServices(next)
            XCTAssertEqual(hub.portalSettings, next)
            XCTAssertEqual(hub.portalAuth?.configuration?.issuer, next.issuer)
            XCTAssertFalse(hub.portalAuth === fixture.auth)
        } else { try await hub.signOutAccount() }
        await gate.open()
        await waitUntil { hub.projectLoadError != nil }
        XCTAssertTrue(hub.projects.isEmpty); XCTAssertNil(hub.selectedProject); XCTAssertNil(hub.signedInAccount)
        XCTAssertNil(try fixture.storage.read())
        XCTAssertNil(try fixture.stationStorage.read())
        XCTAssertNil(try fixture.cacheStorage.read())
        XCTAssertEqual(fixture.legacy.load(), fixture.legacySession)
        let calls = await http.requests()
        XCTAssertFalse(calls.contains { $0.url?.path == "/api/v1/connections/agora/certificate" })
    }
}
