import AppKit
@testable import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

private final class StationTestSession: AccountSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var record: AccountSessionRecord?
    init(configuration: AccountOIDCConfiguration, token: String, subject: String = "test-owner") {
        record = AccountSessionRecord(session: AccountLoginSession(configuration: configuration,
            subject: subject, accessToken: token, refreshToken: "test-refresh",
            expiresAt: Date().addingTimeInterval(600), authenticatedAt: nil))
    }
    func read() throws -> AccountSessionRecord? { lock.lock(); defer { lock.unlock() }; return record }
    func write(_ value: AccountSessionRecord?) throws { lock.lock(); defer { lock.unlock() }; record = value }
}

private final class StationTestCache: AccountDataStorage {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ value: Data?) throws { data = value }
}

private struct StationTestHTTP: AccountOIDCHTTP {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = request.url?.path == "/api/v1/connections"
            ? #"{"agora":{"ready":true,"connected":true}}"# : #"{"projects":[]}"#
        return (Data(body.utf8), 200)
    }
}

private final class StationTestSocket: IdentityRelaySocket, @unchecked Sendable {
    var sent: [String] = []
    var cancelled = false
    var closeCode = URLSessionWebSocketTask.CloseCode.invalid
    var closeReason: Data?
    var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let value) = message { sent.append(value) }
        completionHandler(nil)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) { receiver = completionHandler }
    func emit(_ text: String) { let receive = receiver; receiver = nil; receive?(.success(.string(text))) }
    var registrations: [String] { sent.filter { $0.contains("relayRegisterAccount") } }
}

@MainActor private final class StationAccountFixture {
    let origin: String
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "Astation.station-account.\(UUID())"
    let defaults: UserDefaults
    var sockets: [StationTestSocket] = []
    var urls: [URL] = []
    var hub: AstationHubManager!

    init(stationSubject: String = "test-owner", origin: String = "https://station-tests.example") throws {
        self.origin = origin
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = try AccountServiceSettings(portalURL: "https://portal.example", issuer: "https://auth.example",
            clientID: "astation", resource: "https://portal.example")
        let portalConfig = try settings.oidcConfiguration
        let stationConfig = try AccountOIDCConfiguration(issuer: settings.issuer, clientID: settings.clientID,
            resource: origin, requiredScope: "astation.remote")
        let http = StationTestHTTP()
        let portal = AstationAccountAuth(configuration: portalConfig,
            storage: StationTestSession(configuration: portalConfig, token: "test-portal-token"), http: http)
        let station = AstationAccountAuth(configuration: stationConfig,
            storage: StationTestSession(configuration: stationConfig, token: "test-station-token", subject: stationSubject), http: http)
        let key = RelayIdentityKey(softwareKey: P256.Signing.PrivateKey())
        let keyManager = RelayIdentityKeyManager(loadKey: { _ in key }, repairKey: { key },
            perform: { $0() }, deliver: { $0() }, schedule: { _, _ in })
        let sessions = SessionStore(storageURL: directory.appendingPathComponent("sessions"))
        _ = sessions.createTest(id: "retained-pairing", hostname: "test", lastActivity: Date())
        hub = AstationHubManager(skipProjectLoad: true, deviceSessionStore: sessions,
            sessionStore: SsoSessionStore(storageURL: directory.appendingPathComponent("sso")),
            relayIdentityKeyManager: keyManager, relayIdentityRepairDefaults: defaults,
            atemE2EIdentity: AtemE2EIdentity(storage: TestAtemStorage(), crypto: TestAtemCryptography()),
            dispatchMigration: { _ in }, makeIdentityRelayTask: { [weak self] url in
                let socket = StationTestSocket(); self?.urls.append(url); self?.sockets.append(socket); return socket
            }, portalSettings: settings, portalAuth: portal, stationAuth: station, portalAPI: PortalAPIClient(http: http),
            projectCache: PortalProjectCache(storage: StationTestCache()), accountDefaults: defaults)
        hub._testRelayUrlOverride = origin
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class StationAccountLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Station lifecycle event")
    }
    private func connected(_ fixture: StationAccountFixture) async throws -> StationTestSocket {
        fixture.hub.refreshProjects()
        try await waitUntil { fixture.hub.signedInAccount == "test-owner" }
        fixture.hub.startIdentityRelay()
        let socket = try XCTUnwrap(fixture.sockets.first)
        socket.emit(#"{"type":"relayAuthResult","status":"verified"}"#)
        try await waitUntil { socket.registrations.count == 1 }
        return socket
    }

    func testStartupConfiguresStationAudienceWithoutDeveloperOverrides() throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let hub = AstationHubManager(skipProjectLoad: true, accountDefaults: fixture.defaults)
        XCTAssertEqual(hub.accountAuth.configuration?.resource, hub.stationRelayUrl)
        XCTAssertEqual(hub.accountAuth.configuration?.requiredScope, "astation.remote")
    }

    func testSecurityAccessWaitsForRegistrationAckAndUsesOnlyStationToken() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        var completed = false
        let access = Task { try await fixture.hub.prepareAccountSecurityAccess(); completed = true }
        await Task.yield()
        XCTAssertFalse(completed)
        XCTAssertEqual(socket.registrations.count, 1)
        XCTAssertTrue(socket.registrations[0].contains("test-station-token"))
        XCTAssertFalse(socket.registrations[0].contains("test-portal-token"))
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await access.value
        try await fixture.hub.prepareAccountSecurityAccess()
        XCTAssertTrue(completed)
        XCTAssertEqual(socket.registrations.count, 1)
        XCTAssertNotNil(fixture.hub.deviceSessionStore.getAllActive().first { $0.id == "retained-pairing" })
    }

    func testAccountSecurityAllowsDefaultAndLoopbackStationsWithoutAllowingHostedIntegrations() async throws {
        for origin in ["https://station.agora.build", "http://127.0.0.1:18573"] {
            let fixture = try StationAccountFixture(origin: origin); defer { fixture.cleanup() }
            let socket = try await connected(fixture)
            socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
            try await fixture.hub.prepareAccountSecurityAccess()
            XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, origin)
            XCTAssertTrue(socket.registrations[0].contains("test-station-token"))
            XCTAssertThrowsError(try fixture.hub.configureIntegrationRelayAuth()) {
                XCTAssertEqual($0 as? AccountLoginError, .configuration)
            }
        }
    }

    func testRefusedRegistrationCanRetryWithoutResettingPairing() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        let first = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await Task.sleep(nanoseconds: 30_000_000)
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":false,"message":"refused"}"#)
        do { try await first.value; XCTFail("refused registration admitted security setup") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteRecoveryTransportError.registrationRequired.localizedDescription) }
        let retry = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await waitUntil { socket.registrations.count == 2 }
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await retry.value
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().count, 1)
    }

    func testRelayChangeClosesOldSocketAndFencesItsLateRegistrationAck() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let old = try await connected(fixture)
        let access = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await Task.sleep(nanoseconds: 30_000_000)
        fixture.hub._testRelayUrlOverride = "https://second-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(fixture.urls.last?.host, "second-station.example")
        XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, "https://second-station.example")
        old.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        do { try await access.value; XCTFail("old Station admitted a new Station operation") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertFalse(fixture.hub.identityRelayVerified)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().count, 1)
    }

    func testCancelledRegistrationWaitDoesNotResumeOnLateAck() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        let access = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await Task.sleep(nanoseconds: 30_000_000)
        access.cancel()
        do { try await access.value; XCTFail("cancelled security operation completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await fixture.hub.prepareAccountSecurityAccess()
        XCTAssertEqual(socket.registrations.count, 1)
    }

    func testMismatchedStationOwnerCannotRegisterOrSetUpRecovery() async throws {
        let fixture = try StationAccountFixture(stationSubject: "other-owner"); defer { fixture.cleanup() }
        fixture.hub.refreshProjects()
        try await waitUntil { fixture.hub.signedInAccount == "test-owner" }
        do { try await fixture.hub.prepareAccountSecurityAccess(); XCTFail("another owner admitted account security") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertTrue(fixture.sockets.isEmpty)
    }

    func testCancelledAccessCannotProceedWithAnAlreadyRegisteredAccount() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await fixture.hub.prepareAccountSecurityAccess()
        let access = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        access.cancel()
        do { try await access.value; XCTFail("cancelled operation reused account registration") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(socket.registrations.count, 1)
    }

    func testRegistrationTimeoutReconnectsAndCannotAcceptTheOldSocketAck() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let old = try await connected(fixture)
        do { try await fixture.hub.prepareAccountSecurityAccess(registrationTimeout: 0.02); XCTFail("missing acknowledgment admitted setup") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteRecoveryTransportError.registrationRequired.localizedDescription) }
        XCTAssertTrue(old.cancelled)
        let next = try XCTUnwrap(fixture.sockets.last)
        XCTAssertFalse(next === old)
        old.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        let retry = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        next.emit(#"{"type":"relayAuthResult","status":"verified"}"#)
        try await waitUntil { next.registrations.count == 1 }
        next.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await retry.value
    }

    func testSignOutFencesPendingRegistrationAndRetainsPairing() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let old = try await connected(fixture)
        let pending = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await Task.sleep(nanoseconds: 30_000_000)
        try await fixture.hub.signOutAccount()
        XCTAssertTrue(old.cancelled)
        old.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        do { try await pending.value; XCTFail("signed-out operation completed") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertNil(fixture.hub.signedInAccount)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().count, 1)
    }
}
