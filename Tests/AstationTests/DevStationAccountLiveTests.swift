import AstationRemote
import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import Menubar

private actor DevAccountHTTP: AccountOIDCHTTP {
    private let transport = AccountURLSessionHTTP()
    private var grants: [(kind: String, resource: String, status: Int)] = []

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let reply = try await transport.send(request)
        if request.url?.path == "/token", let body = request.httpBody {
            var form = URLComponents()
            form.percentEncodedQuery = String(decoding: body, as: UTF8.self)
            let items = form.queryItems ?? []
            grants.append((items.first { $0.name == "grant_type" }?.value ?? "",
                           items.first { $0.name == "resource" }?.value ?? "", reply.1))
        }
        return reply
    }

    func completed(_ kind: String, resource: String) -> Bool {
        grants.contains { $0.kind == kind && $0.resource == resource && $0.status == 200 }
    }
}

/// Opt-in operator check: uses the real browser and the provisioned app's Keychain.
/// Stop Astation first so two processes cannot rotate the same refresh token.
final class DevStationAccountLiveTests: XCTestCase {
    @MainActor func testDevSavedSecurityRecordIsAvailable() async throws {
        guard ProcessInfo.processInfo.environment["ASTATION_LIVE_DEV_SECURITY"] == "1" else {
            throw XCTSkip("Opt-in read-only check of the saved security record on the dev Station")
        }
        let account = AstationIdentity.shared.id
        let store = try RemoteRecoveryStore(accountID: account)
        let bytes = try XCTUnwrap(store.read())
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let entries = try XCTUnwrap(saved["entries"] as? [String])
        let genesis = try XCTUnwrap(signedObjectInfo(json: XCTUnwrap(entries.first)).entryHash)
        let log = try RemoteMembershipCheckpoint.load(accountID: account, genesisHash: genesis,
            entries: entries, storedJSON: saved["membership"] as? String, now: AstationRecoveryCoordinator.clock())
        let origin = "https://station-dev.agora.build", issuer = "https://auth.dev.agora.build"
        let config = try AccountOIDCConfiguration(issuer: issuer, clientID: "astation", resource: origin, requiredScope: "astation.remote")
        let context = SHA256.hash(data: Data([issuer, config.clientID, origin].joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let storage = AccountKeychainStorage(service: "build.agora.astation.station-account-v1." + context)
        let auth = AstationAccountAuth(configuration: config, storage: storage)
        let http = try RemoteRecoveryHTTP(relayURL: origin, accessToken: { try await auth.accessToken(relayURL: origin) })
        do {
            let page = try await http.entries(genesisHash: genesis, after: log.head().seq)
            let result = try log.extend(entries: page.entries, now: AstationRecoveryCoordinator.clock())
            XCTAssertNil(result.stop)
            XCTAssertEqual(log.head(), page.head)
            XCTAssertFalse(page.more)
            print("DEV_SECURITY_RECORD available; verified saved genesis and head; no local checkpoint changes")
        } catch RemoteRecoveryTransportError.recordNotFound {
            print("DEV_SECURITY_RECORD recovery_record_not_found; saved signed chain retained locally (\(entries.count) entries)")
            XCTFail("The selected dev Station does not yet have this Mac's saved account-security record. Connect it in Integrations.")
        }
    }

    @MainActor func testDevNativeIssuancePersistenceAndRefresh() async throws {
        guard ProcessInfo.processInfo.environment["ASTATION_LIVE_DEV_ACCOUNT"] == "1" else {
            throw XCTSkip("Opt-in browser sign-in against the dev built-in Station")
        }
        let origin = "https://station-dev.agora.build", issuer = "https://auth.dev.agora.build"
        let config = try AccountOIDCConfiguration(issuer: issuer, clientID: "astation",
            resource: origin, requiredScope: "astation.remote")
        let context = SHA256.hash(data: Data([issuer, config.clientID, origin].joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let storage = AccountKeychainStorage(service: "build.agora.astation.station-account-v1." + context)
        let http = DevAccountHTTP(), auth = AstationAccountAuth(configuration: config, storage: storage, http: http)
        try await auth.signIn()
        _ = try await auth.accessToken(relayURL: origin)
        let issued = try XCTUnwrap(storage.read())
        XCTAssertEqual(issued.session.configuration, config)
        XCTAssertTrue(issued.session.accessToken.isEmpty)
        XCTAssertFalse(issued.refreshPending)
        let exchanged = await http.completed("authorization_code", resource: origin)
        XCTAssertTrue(exchanged)

        // A new provider has only the saved refresh credential, as after app relaunch.
        let restored = AstationAccountAuth(configuration: config, storage: storage, http: http)
        _ = try await restored.accessToken(relayURL: origin)
        let rotated = try XCTUnwrap(storage.read())
        XCTAssertEqual(rotated.session.configuration, config)
        XCTAssertEqual(rotated.session.subject, issued.session.subject)
        XCTAssertTrue(rotated.session.accessToken.isEmpty)
        XCTAssertTrue(rotated.session.refreshToken != issued.session.refreshToken)
        XCTAssertFalse(rotated.refreshPending)
        let refreshed = await http.completed("refresh_token", resource: origin)
        XCTAssertTrue(refreshed)
        do {
            _ = try await restored.accessToken(relayURL: "https://station.agora.build")
            XCTFail("A dev grant cannot authorize the production Station")
        } catch { XCTAssertEqual(error as? AccountLoginError, .configuration) }
    }
}
