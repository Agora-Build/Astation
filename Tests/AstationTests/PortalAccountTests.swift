import AppKit
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
        "/api/connections": (#"{"agora":{"ready":true,"connect":true,"connected":true,"name":"Agora Lab"}}"#, 200),
        "/api/connections/agora/projects": (#"{"projects":[{"projectId":"p1","appId":"app1","name":"Voice Lab","status":"active"}]}"#, 200),
        "/api/connections/agora/certificate": (#"{"projectId":"p1","appId":"app1","certificate":"test-certificate"}"#, 200)
    ]
    var gate: PortalGate?
    var offline = false
    var blockedPath = "/api/connections/agora/projects"
    func goOffline() { offline = true }
    func block(_ gate: PortalGate, path: String = "/api/connections/agora/projects") { self.gate = gate; blockedPath = path }
    func set(_ path: String, _ body: String, _ status: Int = 200) { responses[path] = (body, status) }
    func requests() -> [URLRequest] { calls }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        let response = responses[path]!
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
        auth = AstationAccountAuth(configuration: authConfig, storage: storage)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacy = SsoSessionStore(storageURL: directory.appendingPathComponent("sso"))
        try legacy.save(legacySession)
        hub = AstationHubManager(skipProjectLoad: true,
            deviceSessionStore: SessionStore(storageURL: directory.appendingPathComponent("devices")), sessionStore: legacy,
            atemE2EIdentity: AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography()), sessionJournal: AtemSessionJournal(),
            portalSettings: config, portalAuth: auth, portalAPI: PortalAPIClient(http: http),
            projectCache: PortalProjectCache(storage: cacheStorage), accountDefaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

final class AccountServiceSettingsTests: XCTestCase {
    func testDefaultsOverridesPersistenceAndURLValidation() throws {
        let suite = "Astation.portal-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = try AccountServiceSettings.load(defaults: defaults, environment: [:], info: [:])
        XCTAssertEqual(initial.portalURL, "https://dev.agora.build")
        XCTAssertEqual(initial.issuer, "https://auth.dev.agora.build")
        XCTAssertEqual(try initial.oidcConfiguration.apiScopes, ["agora:projects", "agora:certificates"])
        let settings = try AccountServiceSettings(portalURL: " https://portal.example/ ", issuer: "https://auth.example/",
            clientID: "native-test", resource: "https://api.example")
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
}

@MainActor final class PortalAccountTests: XCTestCase {
    private let appID = "0123456789abcdef0123456789abcdef"
    private let certificate = "abcdef0123456789abcdef0123456789"
    private func settings(_ suffix: String = "") throws -> AccountServiceSettings {
        try AccountServiceSettings(portalURL: "https://portal\(suffix).example", issuer: "https://auth\(suffix).example",
            clientID: "astation-test", resource: "https://api\(suffix).example")
    }
    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Portal operation")
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
        await http.set("/api/connections/agora/certificate", #"{"projectId":"another","appId":"app1","certificate":"wrong"}"#)
        do { _ = try await api.certificate(project: projects[0], settings: config, token: "portal-access"); XCTFail("Mixed project certificate") }
        catch { XCTAssertEqual(error as? PortalAPIError, .invalidResponse) }
        for (code, expected) in [(401, PortalAPIError.signInRequired), (403, .permission), (503, .unavailable), (302, .unavailable)] {
            await http.set("/api/connections", "{}", code)
            do { _ = try await api.connection(settings: config, token: "portal-access"); XCTFail("Accepted HTTP \(code)") }
            catch { XCTAssertEqual(error as? PortalAPIError, expected) }
        }
    }

    func testUnlinkedAgoraShowsConnectWithoutRequestingProjectsOrCertificates() async throws {
        let http = PortalHTTP()
        await http.set("/api/connections", #"{"agora":{"ready":true,"connect":true,"connected":false}}"#)
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
        XCTAssertEqual(calls.map { $0.url!.path }, ["/api/connections"])
    }

    private func linkedHTTP() async -> PortalHTTP {
        let http = PortalHTTP()
        await http.set("/api/connections/agora/projects", "{\"projects\":[{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"name\":\"Voice Lab\",\"status\":\"active\"}]}")
        await http.set("/api/connections/agora/certificate", "{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"certificate\":\"\(certificate)\"}")
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
        await http.set("/api/connections/agora/certificate", "{\"projectId\":\"p1\",\"appId\":\"\(appID)\",\"certificate\":\"\(rotated)\"}")
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.selectedProject?.signKey == rotated }
        let response = await fixture.hub.generateRTCToken(channel: "rotated", uid: 42)
        XCTAssertTrue(try AgoraTokenService.verify(response.token, certificate: rotated))
        XCTAssertFalse(try AgoraTokenService.verify(response.token, certificate: certificate))
        await http.set("/api/connections/agora/projects", #"{"projects":[]}"#)
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
        await http.set("/api/connections", #"{"agora":{"ready":true,"connect":true,"connected":false}}"#)
        fixture.hub.refreshProjects()
        await waitUntil { fixture.hub.projectLoadError != nil }
        XCTAssertEqual(fixture.hub.projectLoadError, PortalAPIError.connectAgora.localizedDescription)
        XCTAssertTrue(fixture.hub.projects.isEmpty)
        XCTAssertNil(try fixture.cacheStorage.read())
    }

    func testLateCertificateAfterLogoutCannotRepopulateTheCache() async throws {
        let http = await linkedHTTP(), gate = PortalGate()
        await http.block(gate, path: "/api/connections/agora/certificate")
        let fixture = try PortalHubFixture(config: settings(), http: http)
        defer { fixture.cleanup() }
        fixture.hub.refreshProjects()
        await waitUntil { await http.requests().contains { $0.url?.path == "/api/connections/agora/certificate" } }
        try await fixture.hub.signOutAccount()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(try fixture.cacheStorage.read())
        XCTAssertTrue(fixture.hub.projects.isEmpty)
    }

    func testGeneralShowsAccountAndEditableServersAtMinimumWidth() throws {
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
        let fields = all.compactMap { $0 as? NSTextField }.filter { ["Portal URL", "Auth URL", "Client ID", "API resource"].contains($0.accessibilityLabel() ?? "") }
        XCTAssertEqual(fields.count, 4)
        for field in fields {
            XCTAssertGreaterThan(field.bounds.width, 240)
            XCTAssertLessThanOrEqual(field.convert(field.bounds, to: general).maxX, general.bounds.width)
        }
        XCTAssertTrue(all.compactMap { $0 as? NSButton }.contains { $0.title == "Sign in to agora.build" })
        XCTAssertFalse(all.compactMap { $0 as? NSButton }.contains { $0.title == "Sign in with Agora" })
        let scroll = try XCTUnwrap(general as? NSScrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
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
        await waitUntil { await http.requests().contains { $0.url?.path == "/api/connections/agora/projects" } }
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
        XCTAssertNil(try fixture.cacheStorage.read())
        XCTAssertEqual(fixture.legacy.load(), fixture.legacySession)
        let calls = await http.requests()
        XCTAssertFalse(calls.contains { $0.url?.path == "/api/connections/agora/certificate" })
    }
}
