@testable import AstationRemote
import Foundation
import XCTest
@testable import Menubar

final class AccountAuthBoundaryTests: XCTestCase {
    func testProvisionedAccountKeychainPreservesRotatingRefreshIntentAndClearsOnlyItsOwnItem() throws {
        let store = AccountKeychainStorage(service:"build.agora.astation.test-account-\(UUID())")
        defer { try? store.write(nil) }
        let config = try AccountOIDCConfiguration(issuer:"https://auth.example",clientID:"test",resource:"https://station.example",requiredScope:"station:account")
        let session = AccountLoginSession(configuration:config,subject:"ab01234567890123456789012345",
            accessToken:"test-access",refreshToken:"test-refresh",expiresAt:Date().addingTimeInterval(900),authenticatedAt:nil)
        do { try store.write(AccountSessionRecord(session:session)) }
        catch {
            if ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] != "1" {
                throw XCTSkip("Requires a provisioned XCTest host for Data Protection Keychain")
            }
            throw error
        }
        XCTAssertEqual(try store.read()?.session,session)
        try store.write(AccountSessionRecord(session:session,refreshPending:true))
        XCTAssertEqual(try store.read()?.refreshPending,true)
        try store.write(nil); XCTAssertNil(try store.read())
    }
    func testAccountConfigurationNeverReusesAgoraServiceConfiguration() {
        let suite = "Astation.account-boundary.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let serviceOnly = AstationAccountAuth(environment: ["ASTATION_SSO_URL": "https://sso2.agora.io"], info: [:], defaults: defaults)
        XCTAssertNil(serviceOnly.configuration)
        let auth = AstationAccountAuth(environment: ["ASTATION_ACCOUNT_CLIENT_ID":"astation-test",
            "ASTATION_ACCOUNT_RESOURCE":"https://station.example", "ASTATION_ACCOUNT_SCOPE":"station:account"], info: [:], defaults: defaults)
        XCTAssertEqual(auth.configuration?.issuer,AccountServiceSettings.defaultIssuer)
        XCTAssertEqual(auth.configuration?.clientID,"astation-test")
        XCTAssertFalse(auth.configuration!.permitsRelay("https://sso2.agora.io"))
    }

    func testLoopbackIgnoresUnsolicitedRequestsAndCompletesOnlyOnce() async throws {
        let attempt = try AccountLoginAttempt()
        let listener = try await AccountLoopbackListener.bind(attempt: attempt,deadline:.seconds(5))
        do {
            let base = "http://127.0.0.1:\(listener.port)"
            for path in ["/favicon.ico", "/other?state=\(attempt.state)&code=no", "/callback?state=wrong&code=no",
                         "/callback?state=\(attempt.state)&state=\(attempt.state)&code=no"] {
                let (_, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,400)
            }
            let url = URL(string: base + "/callback?state=\(attempt.state)&code=accepted")!
            let (data, response) = try await URLSession.shared.data(from:url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(attempt.state))
            let code = try await listener.code(); XCTAssertEqual(code,"accepted")
            let (_, replay) = try await URLSession.shared.data(from:url)
            XCTAssertEqual((replay as? HTTPURLResponse)?.statusCode,400)
        } catch { await listener.close(); throw error }
        await listener.close()
    }

    func testBrowserCancellationWithMatchingStateFinishesWithoutWaitingForTimeout() async throws {
        let attempt = try AccountLoginAttempt()
        let listener = try await AccountLoopbackListener.bind(attempt:attempt,deadline:.seconds(5))
        do {
            let url = URL(string:"http://127.0.0.1:\(listener.port)/callback?state=\(attempt.state)&error=access_denied")!
            let (_,response) = try await URLSession.shared.data(from:url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            do { _ = try await listener.code(); XCTFail("cancelled login completed") }
            catch { XCTAssertEqual(error as? AccountLoginError,.cancelled) }
        } catch { await listener.close(); throw error }
        await listener.close()
    }
}
