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
    var tokenStatus = 400
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path == "/.well-known/openid-configuration" {
            return (Data(#"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","jwks_uri":"https://auth.example/jwks"}"#.utf8), 200)
        }
        if request.url?.path == "/token" { return (Data(#"{"error":"invalid_grant"}"#.utf8), tokenStatus) }
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
    let pairingSocket = StationTestSocket()
    var pairingURLs: [URL] = []
    var hub: AstationHubManager!
    let portalStorage: StationTestSession
    let stationStorage: StationTestSession
    var portalSignIns = 0
    var authorizePortal: (() async throws -> AccountLoginSession)?
    var signIns = 0
    var authorize: (() async throws -> AccountLoginSession)?

    init(stationSubject: String = "test-owner", origin: String = "https://station-tests.example", tokenStatus: Int = 400) throws {
        self.origin = origin
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = try AccountServiceSettings(portalURL: "https://portal.example", issuer: "https://auth.example",
            clientID: "astation", resource: "https://portal.example")
        let portalConfig = try settings.oidcConfiguration
        let stationConfig = try AccountOIDCConfiguration(issuer: settings.issuer, clientID: settings.clientID,
            resource: origin, requiredScope: "astation.remote")
        let http = StationTestHTTP(tokenStatus: tokenStatus)
        portalStorage = StationTestSession(configuration: portalConfig, token: "test-portal-token")
        stationStorage = StationTestSession(configuration: stationConfig, token: "test-station-token", subject: stationSubject)
        let portal = AstationAccountAuth(configuration: portalConfig, storage: portalStorage, http: http,
            authorize: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                self.portalSignIns += 1
                guard let authorize = self.authorizePortal else { throw AccountLoginError.cancelled }
                return try await authorize()
            })
        let station = AstationAccountAuth(configuration: stationConfig, storage: stationStorage, http: http,
            authorize: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                self.signIns += 1
                guard let authorize = self.authorize else { throw AccountLoginError.cancelled }
                return try await authorize()
            })
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
            }, makePairingRelayTask: { [unowned self] url in
                self.pairingURLs.append(url); return self.pairingSocket
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

    func testAgoraBuildLoginPairsWithoutLegacySessionOrSharingAccountTokens() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.hub.cancelRemotePairing(); fixture.cleanup() }
        let socket = try await connected(fixture)
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await fixture.hub.prepareAccountSecurityAccess()
        XCTAssertNil(fixture.hub.sessionStore.load(), "Only Agora.Build login is present")
        var agentTargets: [String] = []
        fixture.hub.sendHandler = { _, clientID in agentTargets.append(clientID) }
        fixture.hub.connectToRelay(code: "ABCD-2345")
        try await waitUntil { fixture.hub.pairingState == .waitingForHost }
        XCTAssertEqual(fixture.pairingURLs.first?.host, "station-tests.example")
        fixture.pairingSocket.emit(#"{"atem_id":"device","connection_id":"11111111-2222-4333-8444-555555555555","payload":{"type":"pairing","data":{"v":1,"op":"hello","id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}}"#)
        try await waitUntil { fixture.hub.pairingState == .waitingForVerification }
        let sent = try XCTUnwrap(fixture.pairingSocket.sent.first)
        XCTAssertEqual(fixture.pairingSocket.sent.count, 1)
        XCTAssertTrue(sent.contains("introduction"))
        XCTAssertTrue(sent.contains(AstationIdentity.shared.id))
        for forbidden in ["credentialSync", "test-portal-token", "test-station-token", "refresh_token", "access_token", "test-owner"] {
            XCTAssertFalse(sent.contains(forbidden), "Pairing leaked \(forbidden)")
        }
        XCTAssertTrue(fixture.hub.connectedClients.isEmpty)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().count, 1, "Introduction cannot enroll a host")
        fixture.hub.sendHandler?(.statusUpdate(status: "test", data: [:]), "existing-agent")
        XCTAssertEqual(agentTargets, ["existing-agent"], "Pairing cannot replace the agent transport handler")
    }

    func testPairingWaitingForRegistrationIsCancelledOnSignOut() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        fixture.hub.connectToRelay(code: "ABCD-2345")
        try await waitUntil { fixture.hub.pairingState == .preparing }
        try await fixture.hub.signOutAccount()
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await waitUntil { !fixture.hub.pairingState.active }
        XCTAssertTrue(fixture.pairingURLs.isEmpty)
        XCTAssertTrue(fixture.pairingSocket.sent.isEmpty)
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

    func testDefaultIntegrationConfigurationPreservesAuthorityAndLoopbackRemainsLocalOnly() async throws {
        for origin in ["https://station.agora.build", "https://station-dev.agora.build", "http://127.0.0.1:18573"] {
            let fixture = try StationAccountFixture(origin: origin); defer { fixture.cleanup() }
            let socket = try await connected(fixture)
            socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
            try await fixture.hub.prepareAccountSecurityAccess()
            XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, origin)
            XCTAssertTrue(socket.registrations[0].contains("test-station-token"))
            let generation = fixture.hub.integrationAccountGeneration
            let sent = socket.sent
            if origin.hasPrefix("https://") {
                XCTAssertNoThrow(try fixture.hub.configureIntegrationRelayAuth())
            } else {
                XCTAssertThrowsError(try fixture.hub.configureIntegrationRelayAuth()) {
                    XCTAssertEqual($0 as? AccountLoginError, .configuration)
                }
            }
            XCTAssertEqual(fixture.hub.integrationAccountGeneration, generation)
            XCTAssertEqual(socket.sent, sent, "Configuration cannot send an enrollment or new authority")
            XCTAssertFalse(socket.cancelled)
            XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().map(\.id), ["retained-pairing"])
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

    func testRelayChangeRetainsRoutingSocketButFencesItsLateRegistrationAck() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let old = try await connected(fixture)
        let access = Task { try await fixture.hub.prepareAccountSecurityAccess() }
        try await Task.sleep(nanoseconds: 30_000_000)
        fixture.hub._testRelayUrlOverride = "https://second-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        XCTAssertFalse(old.cancelled, "Existing pairings retain a routing-only handoff socket")
        XCTAssertEqual(fixture.urls.last?.host, "second-station.example")
        XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, "https://second-station.example")
        old.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        do { try await access.value; XCTFail("old Station admitted a new Station operation") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertFalse(fixture.hub.identityRelayVerified)
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().count, 1)
        XCTAssertEqual(old.registrations.count, 1, "A retired socket cannot register the new Station account")
        fixture.hub.accountSessionChanged()
        XCTAssertTrue(old.cancelled, "Account invalidation also closes routing-only sockets")
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

    func testBackgroundSecurityAccessUsesSavedAuthorizationAndNeverStartsSignIn() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await fixture.hub.prepareAccountSecurityAccess(allowSignIn: false)
        try await fixture.hub.accountAuth.clearSession()
        do {
            try await fixture.hub.prepareAccountSecurityAccess(allowSignIn: false)
            XCTFail("Missing saved authorization requires an explicit sign-in")
        } catch { XCTAssertEqual(error as? AccountLoginError, .signInRequired) }
        XCTAssertEqual(fixture.sockets.count, 1)
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

    func testVerificationRenewsOnlyStationAuthorizationWhilePortalStaysSignedIn() async throws {
        for state in ["missing", "refresh_pending", "invalid_grant"] {
            let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
            let socket = try await connected(fixture)
            socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
            try await fixture.hub.prepareAccountSecurityAccess()
            let saved = try XCTUnwrap(fixture.stationStorage.read())
            if state == "missing" { try fixture.stationStorage.write(nil) }
            else if state == "refresh_pending" {
                try fixture.stationStorage.write(AccountSessionRecord(session: saved.session, refreshPending: true))
            } else {
                let expired = AccountLoginSession(configuration: saved.session.configuration, subject: saved.session.subject,
                    accessToken: "expired", refreshToken: saved.session.refreshToken, expiresAt: .distantPast, authenticatedAt: nil)
                try fixture.stationStorage.write(AccountSessionRecord(session: expired))
            }
            fixture.authorize = {
                XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, fixture.origin)
                XCTAssertTrue(fixture.hub.accountSignInInProgress)
                XCTAssertTrue(fixture.hub.needsAccountSignIn)
                return saved.session
            }
            try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id)
            XCTAssertEqual(fixture.signIns, 1, state)
            XCTAssertEqual(fixture.hub.signedInAccount, "test-owner")
            XCTAssertFalse(fixture.hub.accountSignInRequired)
            XCTAssertFalse(fixture.hub.stationAccountSignInRequired)
            XCTAssertFalse(fixture.hub.needsAccountSignIn)
            XCTAssertFalse(fixture.hub.accountSignInInProgress)
            XCTAssertEqual(socket.registrations.count, 1)
            XCTAssertFalse(socket.registrations[0].contains("test-portal-token"))
        }
    }

    func testVerificationRecoversMissingPortalAndInterruptedStationRefreshForTheSavedOwner() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let portal = try XCTUnwrap(fixture.portalStorage.read())
        let station = try XCTUnwrap(fixture.stationStorage.read())
        try fixture.portalStorage.write(nil)
        try fixture.stationStorage.write(AccountSessionRecord(session: station.session, refreshPending: true))
        fixture.hub.refreshProjects()
        try await waitUntil { fixture.hub.projectLoadError != nil }
        XCTAssertNil(fixture.hub.signedInAccount)
        fixture.hub.startIdentityRelay()
        let socket = try XCTUnwrap(fixture.sockets.first)
        socket.emit(#"{"type":"relayAuthResult","status":"verified"}"#)
        fixture.authorizePortal = { portal.session }
        fixture.authorize = { station.session }
        let generation = fixture.hub.integrationAccountGeneration
        let pending = Task { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id) }
        try await waitUntil { socket.registrations.count == 1 }
        socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
        try await pending.value
        XCTAssertEqual(fixture.portalSignIns, 1)
        XCTAssertEqual(fixture.signIns, 1)
        XCTAssertEqual(fixture.hub.signedInAccount, "test-owner")
        XCTAssertFalse(fixture.hub.needsAccountSignIn)
        XCTAssertEqual(fixture.hub.integrationAccountGeneration, generation)
        XCTAssertTrue(socket.registrations[0].contains("test-station-token"))
        XCTAssertFalse(socket.registrations[0].contains("test-portal-token"))
        XCTAssertEqual(fixture.hub.deviceSessionStore.getAllActive().map(\.id), ["retained-pairing"])
    }

    func testVerificationRecoversPortalRefreshFailuresWithoutSigningInToStationAgain() async throws {
        for state in ["missing", "refresh_pending", "invalid_grant"] {
            let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
            let socket = try await connected(fixture)
            socket.emit(#"{"type":"relayAck","for":"relayRegisterAccount","ok":true}"#)
            let saved = try XCTUnwrap(fixture.portalStorage.read())
            if state == "missing" { try fixture.portalStorage.write(nil) }
            else if state == "refresh_pending" {
                try fixture.portalStorage.write(AccountSessionRecord(session: saved.session, refreshPending: true))
            } else {
                let expired = AccountLoginSession(configuration: saved.session.configuration, subject: saved.session.subject,
                    accessToken: "expired", refreshToken: saved.session.refreshToken, expiresAt: .distantPast, authenticatedAt: nil)
                try fixture.portalStorage.write(AccountSessionRecord(session: expired))
            }
            fixture.hub.refreshProjects()
            try await waitUntil { fixture.hub.accountSignInRequired && fixture.hub.projectLoadError != nil }
            fixture.authorizePortal = { saved.session }
            try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id)
            XCTAssertEqual(fixture.portalSignIns, 1, state)
            XCTAssertEqual(fixture.signIns, 0, state)
            XCTAssertFalse(fixture.hub.needsAccountSignIn)
            XCTAssertEqual(socket.registrations.count, 1)
        }
    }

    func testPortalRecoveryNeverOpensBrowserInBackgroundAndCancellationStopsVerification() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        try fixture.portalStorage.write(nil)
        do { try await fixture.hub.prepareAccountSecurityAccess(allowSignIn: false); XCTFail("missing Portal admitted access") }
        catch { XCTAssertEqual(error as? AccountLoginError, .signInRequired) }
        XCTAssertEqual(fixture.portalSignIns, 0)
        XCTAssertEqual(fixture.signIns, 0)
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("cancelled Portal login admitted access") }
        catch { XCTAssertEqual(error as? AccountLoginError, .cancelled) }
        XCTAssertEqual(fixture.portalSignIns, 1)
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertTrue(fixture.sockets.allSatisfy { $0.registrations.isEmpty })
        XCTAssertTrue(fixture.hub.accountSignInRequired)
        XCTAssertFalse(fixture.hub.accountSignInInProgress)
    }

    func testPortalRecoveryCannotReplaceTheSavedStationOwner() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let saved = try XCTUnwrap(fixture.portalStorage.read())
        try fixture.portalStorage.write(nil)
        fixture.authorizePortal = {
            AccountLoginSession(configuration: saved.session.configuration, subject: "different-owner",
                accessToken: "different-token", refreshToken: "different-refresh", expiresAt: Date().addingTimeInterval(600), authenticatedAt: nil)
        }
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("different owner admitted verification") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertNil(fixture.hub.signedInAccount)
        XCTAssertNil(try fixture.portalStorage.read(), "A different browser account cannot replace the saved owner")
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertTrue(fixture.sockets.allSatisfy { $0.registrations.isEmpty })
    }

    func testPortalRecoveryServiceFailureDoesNotStartBrowserSignIn() async throws {
        let fixture = try StationAccountFixture(tokenStatus: 503); defer { fixture.cleanup() }
        let saved = try XCTUnwrap(fixture.portalStorage.read())
        let expired = AccountLoginSession(configuration: saved.session.configuration, subject: saved.session.subject,
            accessToken: "expired", refreshToken: saved.session.refreshToken, expiresAt: .distantPast, authenticatedAt: nil)
        try fixture.portalStorage.write(AccountSessionRecord(session: expired))
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("unavailable Portal admitted verification") }
        catch { XCTAssertEqual(error as? AccountLoginError, .unavailable) }
        XCTAssertEqual(fixture.portalSignIns, 0)
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertTrue(fixture.sockets.allSatisfy { $0.registrations.isEmpty })
    }

    func testSignOutDuringPortalRecoveryFencesLateLogin() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let saved = try XCTUnwrap(fixture.portalStorage.read())
        try fixture.portalStorage.write(nil)
        var reply: CheckedContinuation<AccountLoginSession, Error>?
        fixture.authorizePortal = { try await withCheckedThrowingContinuation { reply = $0 } }
        let pending = Task { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id) }
        try await waitUntil { reply != nil }
        try await fixture.hub.signOutAccount()
        reply?.resume(returning: saved.session)
        do { try await pending.value; XCTFail("signed-out verification resumed") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertNil(try fixture.portalStorage.read())
        XCTAssertNil(try fixture.stationStorage.read())
        XCTAssertNil(fixture.hub.signedInAccount)
        XCTAssertEqual(fixture.signIns, 0)
    }

    func testRelayChangeDuringPortalRecoveryCannotRegisterEitherStation() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let saved = try XCTUnwrap(fixture.portalStorage.read())
        try fixture.portalStorage.write(nil)
        var reply: CheckedContinuation<AccountLoginSession, Error>?
        fixture.authorizePortal = { try await withCheckedThrowingContinuation { reply = $0 } }
        let pending = Task { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id) }
        try await waitUntil { reply != nil }
        fixture.hub._testRelayUrlOverride = "https://second-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        reply?.resume(returning: saved.session)
        do { try await pending.value; XCTFail("Portal recovery crossed Station origins") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertNil(fixture.hub.signedInAccount)
        XCTAssertTrue(fixture.sockets.allSatisfy { $0.registrations.isEmpty })
    }

    func testVerificationCancelledSignInIsVisibleAndBackgroundWorkNeverOpensBrowser() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        _ = try await connected(fixture)
        try await fixture.hub.accountAuth.clearSession()
        do { try await fixture.hub.prepareAccountSecurityAccess(allowSignIn: false); XCTFail("missing Station token admitted access") }
        catch { XCTAssertEqual(error as? AccountLoginError, .signInRequired) }
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertTrue(fixture.hub.needsAccountSignIn)
        XCTAssertFalse(fixture.hub.accountSignInRequired, "Station authorization cannot sign out the Portal")
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("cancelled login admitted verification") }
        catch { XCTAssertEqual(error as? AccountLoginError, .cancelled) }
        XCTAssertEqual(fixture.signIns, 1)
        XCTAssertTrue(fixture.hub.stationAccountSignInRequired)
        XCTAssertFalse(fixture.hub.accountSignInInProgress)
    }

    func testSignOutWhileVerificationReauthorizesCannotRestoreTheOldSession() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        _ = try await connected(fixture)
        let saved = try XCTUnwrap(fixture.stationStorage.read())
        try await fixture.hub.accountAuth.clearSession()
        var reply: CheckedContinuation<AccountLoginSession, Error>?
        fixture.authorize = { try await withCheckedThrowingContinuation { reply = $0 } }
        let pending = Task { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id) }
        try await waitUntil { reply != nil }
        try await fixture.hub.signOutAccount()
        reply?.resume(returning: saved.session)
        do { try await pending.value; XCTFail("signed-out verification resumed") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertNil(try fixture.stationStorage.read())
        XCTAssertNil(fixture.hub.signedInAccount)
        XCTAssertTrue(fixture.hub.needsAccountSignIn)
    }

    func testVerificationRejectsAnotherOwnerAfterReauthorization() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let socket = try await connected(fixture)
        let saved = try XCTUnwrap(fixture.stationStorage.read())
        try await fixture.hub.accountAuth.clearSession()
        fixture.authorize = {
            AccountLoginSession(configuration: saved.session.configuration, subject: "different-owner",
                accessToken: "different-token", refreshToken: "different-refresh", expiresAt: Date().addingTimeInterval(600), authenticatedAt: nil)
        }
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("different owner admitted verification") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertEqual(socket.registrations.count, 1)
        XCTAssertTrue(fixture.hub.stationAccountSignInRequired)
        XCTAssertEqual(fixture.hub.signedInAccount, "test-owner")
    }

    func testVerificationServiceFailureDoesNotStartBrowserSignIn() async throws {
        let fixture = try StationAccountFixture(tokenStatus: 503); defer { fixture.cleanup() }
        _ = try await connected(fixture)
        let saved = try XCTUnwrap(fixture.stationStorage.read())
        let expired = AccountLoginSession(configuration: saved.session.configuration, subject: saved.session.subject,
            accessToken: "expired", refreshToken: saved.session.refreshToken, expiresAt: .distantPast, authenticatedAt: nil)
        try fixture.stationStorage.write(AccountSessionRecord(session: expired))
        do { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id); XCTFail("unavailable service admitted verification") }
        catch { XCTAssertEqual(error as? AccountLoginError, .unavailable) }
        XCTAssertEqual(fixture.signIns, 0)
        XCTAssertEqual(fixture.hub.signedInAccount, "test-owner")
        XCTAssertFalse(fixture.hub.accountSignInRequired)
    }

    func testRelayChangeWhileVerificationReauthorizesCannotRegisterTheNewStation() async throws {
        let fixture = try StationAccountFixture(); defer { fixture.cleanup() }
        let old = try await connected(fixture)
        let saved = try XCTUnwrap(fixture.stationStorage.read())
        try await fixture.hub.accountAuth.clearSession()
        var reply: CheckedContinuation<AccountLoginSession, Error>?
        fixture.authorize = { try await withCheckedThrowingContinuation { reply = $0 } }
        let pending = Task { try await fixture.hub.prepareVerificationAccount(account: AstationIdentity.shared.id) }
        try await waitUntil { reply != nil }
        fixture.hub._testRelayUrlOverride = "https://second-station.example"
        NotificationCenter.default.post(name: .serverInfoChanged, object: nil)
        reply?.resume(returning: saved.session)
        do { try await pending.value; XCTFail("verification crossed Station origins") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertEqual(fixture.hub.accountAuth.configuration?.resource, "https://second-station.example")
        XCTAssertEqual(old.registrations.count, 1)
        XCTAssertTrue(fixture.sockets.dropFirst().allSatisfy { $0.registrations.isEmpty })
        XCTAssertTrue(fixture.hub.stationAccountSignInRequired)
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
