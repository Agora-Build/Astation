import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class AccountTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_800_000_000
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; seconds += value }
}
private final class AccountTestStorage: AccountSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var record: AccountSessionRecord?
    private var writes = 0
    var failWrite: Int?
    init(_ session: AccountLoginSession) { record = AccountSessionRecord(session: session) }
    func read() throws -> AccountSessionRecord? { lock.lock(); defer { lock.unlock() }; return record }
    func write(_ record: AccountSessionRecord?) throws {
        lock.lock(); defer { lock.unlock() }; writes += 1
        if writes == failWrite { throw AccountLoginError.storage }
        self.record = record
    }
}
private actor AccountHTTPGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor AccountTestHTTP: AccountOIDCHTTP {
    private var responses: [String: (Data, Int)] = [:]
    private var requests: [URLRequest] = []
    var tokenGate: AccountHTTPGate?
    func set(_ path: String, _ object: [String: Any], status: Int = 200) throws {
        responses[path] = (try JSONSerialization.data(withJSONObject: object), status)
    }
    func blockTokens(_ gate: AccountHTTPGate) { tokenGate = gate }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let path = request.url!.path
        if path == "/token", let gate = tokenGate { await gate.wait() }
        guard let response = responses[path] else { throw AccountLoginError.unavailable }
        return response
    }
    func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    func last(_ path: String) -> URLRequest? { requests.last { $0.url?.path == path } }
}
private struct AccountFixture {
    let config: AccountOIDCConfiguration
    let key = P256.Signing.PrivateKey()
    let clock = AccountTestClock()
    let http = AccountTestHTTP()
    let attempt: AccountLoginAttempt
    let client: AccountOIDCClient
    static let subject = "ab01234567890123456789012345"

    init() throws {
        config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation", resource: "https://station.example", requiredScope: "station:account")
        attempt = try AccountLoginAttempt()
        client = AccountOIDCClient(configuration: config, http: http, now: { [clock] in clock.now() })
    }
    func prepare() async throws {
        try await http.set("/.well-known/openid-configuration", ["issuer": config.issuer,
            "authorization_endpoint": config.issuer + "/authorize", "token_endpoint": config.issuer + "/token", "jwks_uri": config.issuer + "/keys"])
        try await keys(kid: "one")
        try await response()
    }
    func keys(kid: String) async throws {
        let raw = key.publicKey.x963Representation
        try await http.set("/keys", ["keys": [["kid": kid, "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig",
            "x": AccountOIDCClient.encode(raw.subdata(in: 1..<33)), "y": AccountOIDCClient.encode(raw.subdata(in: 33..<65))]]])
    }
    func jwt(_ overrides: [String: Any] = [:], id: Bool = false, header: [String: Any] = [:], signer: P256.Signing.PrivateKey? = nil) throws -> String {
        let now = Int64(clock.now().timeIntervalSince1970)
        var payload: [String: Any] = ["iss": config.issuer, "sub": Self.subject, "aud": id ? config.clientID : config.resource,
            "iat": now, "exp": now + (id ? 3600 : 900), "client_id": config.clientID, "scope": "openid station:account"]
        if id { payload["nonce"] = attempt.nonce; payload["auth_time"] = now }
        payload.merge(overrides) { _, next in next }
        var fields: [String: Any] = ["typ": id ? "JWT" : "at+jwt", "alg": "ES256", "kid": "one"]
        fields.merge(header) { _, next in next }
        let signed = AccountOIDCClient.encode(try JSONSerialization.data(withJSONObject: fields)) + "." + AccountOIDCClient.encode(try JSONSerialization.data(withJSONObject: payload))
        return signed + "." + AccountOIDCClient.encode(try (signer ?? key).signature(for: Data(signed.utf8)).rawRepresentation)
    }
    func response(access: [String: Any] = [:], id: [String: Any] = [:], header: [String: Any] = [:], refresh: String = "refresh-one", includeID: Bool = true) async throws {
        var body: [String: Any] = ["token_type": "Bearer", "refresh_token": refresh, "access_token": try jwt(access, header: header)]
        if includeID { body["id_token"] = try jwt(id, id: true, header: header["kid"].map { ["kid": $0] } ?? [:]) }
        try await http.set("/token", body)
    }
    func exchange() async throws -> AccountLoginSession { try await client.exchange(code: "code", attempt: attempt, redirectURI: "http://127.0.0.1:49152/callback") }
    func provider(_ store: AccountTestStorage) -> AccountTokenProvider {
        AccountTokenProvider(configuration: config, client: client, storage: store, now: { [clock] in clock.now() })
    }
}

final class AccountOIDCTests: XCTestCase {
    func testAdditionalAPIScopesAreRequestedAndMustAllBeGranted() async throws {
        let f = try AccountFixture(); try await f.prepare()
        let config = try AccountOIDCConfiguration(issuer: f.config.issuer, clientID: f.config.clientID,
            resource: f.config.resource, requiredScope: f.config.requiredScope, additionalScopes: ["agora:certificates"])
        let client = AccountOIDCClient(configuration: config, http: f.http, now: { f.clock.now() })
        let url = try await client.authorizationURL(attempt: f.attempt, redirectURI: "http://127.0.0.1:51091/callback")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value,
            "openid profile offline_access station:account agora:certificates")
        do { _ = try await client.exchange(code: "code", attempt: f.attempt, redirectURI: "http://127.0.0.1:51091/callback"); XCTFail("Missing certificate scope accepted") }
        catch { XCTAssertEqual(error as? AccountLoginError, .rejected) }
        try await f.response(access: ["scope":"openid station:account agora:certificates"])
        let session = try await client.exchange(code: "code", attempt: f.attempt, redirectURI: "http://127.0.0.1:51091/callback")
        XCTAssertEqual(session.subject, AccountFixture.subject)
        XCTAssertThrowsError(try AccountOIDCConfiguration(issuer: f.config.issuer, clientID: f.config.clientID,
            resource: f.config.resource, requiredScope: "agora:projects", additionalScopes: ["openid"]))
    }

    func testCurrentAccountIDFormatRejectsLegacyAndMalformedSubjectsEvenWhenBothTokensAgree() async throws {
        let f = try AccountFixture(); try await f.prepare()
        for subject in ["acct_01234567890123456789012345", "ab0123456789012345678901234I", "ab0123456789012345678901234a", "ab0123456789012345678901234"] {
            try await f.response(access: ["sub":subject], id: ["sub":subject])
            do { _ = try await f.exchange(); XCTFail("Accepted \(subject)") }
            catch { XCTAssertEqual(error as? AccountLoginError, .rejected) }
        }
    }

    func testAuthorizationUsesDiscoveryPKCEResourceAndConsent() async throws {
        let f = try AccountFixture(); try await f.prepare()
        let url = try await f.client.authorizationURL(attempt: f.attempt, redirectURI: "http://127.0.0.1:49152/callback", fresh: true)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.example"); XCTAssertEqual(url.path, "/authorize")
        XCTAssertEqual(fields["code_challenge_method"], "S256"); XCTAssertEqual(fields["code_challenge"], f.attempt.challenge)
        XCTAssertEqual(fields["state"], f.attempt.state); XCTAssertEqual(fields["nonce"], f.attempt.nonce)
        XCTAssertEqual(fields["resource"], f.config.resource); XCTAssertEqual(fields["prompt"], "consent"); XCTAssertEqual(fields["max_age"], "0")
        XCTAssertTrue(f.config.permitsRelay("wss://station.example/ws"))
        XCTAssertFalse(f.config.permitsRelay("https://other.example")); XCTAssertFalse(f.config.permitsRelay("https://station.example:444"))
        XCTAssertFalse(f.config.permitsRelay("https://user@station.example"))
    }

    func testCallbackRejectsWrongPathMethodStateDuplicatesAndError() throws {
        let attempt = try AccountLoginAttempt()
        let good = "/callback?state=\(attempt.state)&code=one"
        XCTAssertEqual(try attempt.callbackCode(method: "GET", uri: good), "one")
        for uri in ["/other?state=\(attempt.state)&code=one", good + "&state=\(attempt.state)", good + "&code=two",
                    "/callback?state=wrong&code=one", good + "&error=denied", good + "#fragment"] {
            XCTAssertThrowsError(try attempt.callbackCode(method: "GET", uri: uri))
        }
        XCTAssertThrowsError(try attempt.callbackCode(method: "POST", uri: good))
    }

    func testRealSignedAccessAndIDTokensAndTokenExchangeForm() async throws {
        let f = try AccountFixture(); try await f.prepare()
        let session = try await f.exchange()
        XCTAssertEqual(session.subject, AccountFixture.subject); XCTAssertEqual(session.configuration, f.config)
        XCTAssertNil(session.authenticatedAt) // The ID token's auth_time is not an API freshness proof.
        let request = await f.http.last("/token")!
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("code_verifier=" + f.attempt.verifier)); XCTAssertTrue(form.contains("resource="))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for (field, value) in [("iss", "https://evil.example"), ("aud", "another-api"), ("scope", "station:account-extra"),
                               ("client_id", "another-client"), ("sub", "ab98765432109876543210987654")] {
            try await f.response(access: [field: value])
            do { _ = try await f.exchange(); XCTFail("accepted \(field)") } catch {}
        }
        for overrides: [String: Any] in [["exp": 1_800_000_000], ["iat": 1_800_000_060], ["iat": true], ["nbf": 1_800_000_100], ["exp": 1_800_003_600]] {
            try await f.response(access: overrides)
            do { _ = try await f.exchange(); XCTFail("accepted invalid lifetime") } catch {}
        }
        try await f.response(id: ["nonce": "wrong"])
        do { _ = try await f.exchange(); XCTFail("accepted wrong nonce") } catch {}
        for header in [["typ": "JWT"], ["alg": "none"], ["crit": [String]()]] as [[String: Any]] {
            try await f.response(header: header)
            do { _ = try await f.exchange(); XCTFail("accepted invalid token header") } catch {}
        }
        try await f.http.set("/token", ["token_type":"Bearer", "refresh_token":"test", "id_token":f.jwt(id:true),
            "access_token":f.jwt(signer:P256.Signing.PrivateKey())])
        do { _ = try await f.exchange(); XCTFail("accepted invalid signature") } catch {}
    }

    func testDiscoveryIssuerAndEndpointSubstitutionAreRejectedBeforeTokenRequest() async throws {
        for metadata in [["issuer":"https://evil.example", "authorization_endpoint":"https://auth.example/authorize", "token_endpoint":"https://auth.example/token", "jwks_uri":"https://auth.example/keys"],
            ["issuer":"https://auth.example", "authorization_endpoint":"https://auth.example/authorize", "token_endpoint":"https://evil.example/token", "jwks_uri":"https://auth.example/keys"]] {
            let f = try AccountFixture(); try await f.prepare(); try await f.http.set("/.well-known/openid-configuration", metadata)
            do { _ = try await f.exchange(); XCTFail("accepted substituted metadata") } catch {}
            let count = await f.http.count("/token"); XCTAssertEqual(count, 0)
        }
    }

    func testKeyRotationCooldownAndExpiredCacheFailClosed() async throws {
        let f = try AccountFixture(); try await f.prepare(); _ = try await f.exchange()
        try await f.keys(kid: "two"); try await f.response(header: ["kid":"two"])
        do { _ = try await f.exchange(); XCTFail("unknown key bypassed cooldown") } catch {}
        var count = await f.http.count("/keys"); XCTAssertEqual(count, 1)
        f.clock.advance(6)
        _ = try await f.exchange()
        count = await f.http.count("/keys"); XCTAssertEqual(count, 2)
        try await f.http.set("/keys", [:], status:503)
        _ = try await f.exchange()
        f.clock.advance(61)
        do { _ = try await f.exchange(); XCTFail("expired key cache survived outage") } catch {}
    }

    func testConcurrentRefreshIsSingleUseAndSavedBeforeDelivery() async throws {
        let f = try AccountFixture(); try await f.prepare(); let old = try await f.exchange()
        let store = AccountTestStorage(old), provider = f.provider(store)
        f.clock.advance(850); try await f.response(refresh: "refresh-two", includeID:false)
        let gate = AccountHTTPGate(); await f.http.blockTokens(gate)
        let task = Task { try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await provider.validToken() } }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        } }
        while await f.http.count("/token") < 2 { await Task.yield() }
        await gate.release()
        let tokens = try await task.value
        XCTAssertEqual(tokens.count,12); XCTAssertEqual(Set(tokens).count,1)
        XCTAssertEqual(try store.read()?.session.refreshToken,"refresh-two"); XCTAssertEqual(try store.read()?.refreshPending,false)
        let count = await f.http.count("/token"); XCTAssertEqual(count,2) // One exchange and one refresh.
    }

    func testLostRefreshAndPersistenceFailureNeverReplayOldTokenAfterRestart() async throws {
        for failSave in [false,true] {
            let f = try AccountFixture(); try await f.prepare(); let old = try await f.exchange()
            let store = AccountTestStorage(old); if failSave { store.failWrite = 2 }
            let provider = f.provider(store); f.clock.advance(850)
            try await f.response(refresh:"refresh-two",includeID:false)
            if !failSave { try await f.http.set("/token",[:],status:503) }
            do { _ = try await provider.validToken(); XCTFail("uncertain refresh accepted") } catch {}
            XCTAssertEqual(try store.read()?.refreshPending,true)
            do { _ = try await provider.validToken(); XCTFail("old refresh retried") } catch {}
            let restarted = f.provider(store)
            do { _ = try await restarted.validToken(); XCTFail("old refresh retried after restart") } catch {}
            let count = await f.http.count("/token"); XCTAssertEqual(count,2)
        }
    }

    func testSignOutFencesLateRefreshAndLoginCompletion() async throws {
        let f = try AccountFixture(); try await f.prepare(); let old = try await f.exchange()
        let store = AccountTestStorage(old), provider = f.provider(store)
        f.clock.advance(850); try await f.response(refresh:"refresh-two",includeID:false)
        let gate = AccountHTTPGate(); await f.http.blockTokens(gate)
        let task = Task { try await provider.validToken() }
        while await f.http.count("/token") < 2 { await Task.yield() }
        try await provider.signOut(); await gate.release()
        do { _ = try await task.value; XCTFail("late refresh resurrected session") } catch {}
        XCTAssertNil(try store.read())
        let attempt = try await provider.beginLogin(); try await provider.signOut()
        do { try await provider.finishLogin(old,attempt:attempt); XCTFail("late login resurrected session") } catch {}
        XCTAssertNil(try store.read())
    }
}
