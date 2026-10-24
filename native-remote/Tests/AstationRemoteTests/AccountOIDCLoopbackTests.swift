import AtemClient
import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class LoopbackNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Opt-in integration against the actual local issuer, relay verifier and Postgres.
/// Synthetic identities never enter the user's Keychain, pairing or recovery state.
final class AccountOIDCLoopbackTests: XCTestCase {
    func testPKCELoginAndRefreshAuthorizeRealSignedRecoveryStorage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let issuer = environment["R9_TEST_ISSUER"], let resource = environment["R9_TEST_RESOURCE"] else {
            throw XCTSkip("Run the isolated OIDC/relay stack described in docs/r9-local-validation.md")
        }
        guard URL(string: issuer)?.host == "127.0.0.1", URL(string: resource)?.host == "127.0.0.1" else {
            return XCTFail("This integration fixture requires loopback services")
        }
        let configuration = try AccountOIDCConfiguration(issuer: issuer, clientID: "astation-local-r9",
            resource: resource, requiredScope: "astation.remote")
        let client = AccountOIDCClient(configuration: configuration)
        let attempt = try AccountLoginAttempt()
        let callback = "http://127.0.0.1:58432/callback"
        let url = try await client.authorizationURL(attempt: attempt, redirectURI: callback)
        let session = URLSession(configuration: .ephemeral, delegate: LoopbackNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (html, page) = try await session.data(from: url)
        XCTAssertEqual((page as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: html, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"name="request" value="([A-Za-z0-9_-]+)""#)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let id = (text as NSString).substring(with: match.range(at: 1))
        var consent = URLRequest(url: URL(string: issuer + "/authorize")!)
        consent.httpMethod = "POST"; consent.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        consent.httpBody = Data("request=\(id)".utf8)
        let (_, answer) = try await session.data(for: consent)
        let location = try XCTUnwrap((answer as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
        let redirect = try XCTUnwrap(URLComponents(string: location))
        let code = try attempt.callbackCode(method: "GET", uri: "/callback?" + XCTUnwrap(redirect.percentEncodedQuery))
        let login = try await client.exchange(code: code, attempt: attempt, redirectURI: callback)
        let renewed = try await client.refresh(login)
        XCTAssertEqual(renewed.subject, login.subject)
        XCTAssertTrue(renewed.refreshToken != login.refreshToken)

        let station = "local-r9-" + UUID().uuidString.lowercased()
        let relayKey = P256.Signing.PrivateKey()
        let socket = session.webSocketTask(with: URL(string: resource.replacingOccurrences(of: "http:", with: "ws:")
            + "/ws?role=astation&code=" + station)!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        func send(_ value: [String: Any]) async throws {
            try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)))
        }
        func receive() async throws -> [String: Any] {
            let bytes: Data
            switch try await socket.receive() {
            case .data(let value): bytes = value
            case .string(let value): bytes = Data(value.utf8)
            @unknown default: throw RemoteChannelError.invalidInput
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        let challengeFrame = try await receive()
        let challenge = try XCTUnwrap(challengeFrame["challenge"] as? String)
        let proof = try relayKey.signature(for: Data("station-relay-auth-v1\n\(challenge)\n\(station)".utf8))
        try await send(["type":"relayAuth", "astation_id":station,
            "public_key":hex(relayKey.publicKey.x963Representation), "signature":hex(proof.derRepresentation)])
        let authenticated = try await receive()
        XCTAssertEqual(authenticated["status"] as? String, "registered")
        try await send(["type":"relayRegisterAccount", "sso_access_token":renewed.accessToken, "label":"Isolated r9 test"])
        var dataAccount: String?
        for _ in 0..<8 {
            let frame = try await receive()
            if frame["type"] as? String == "relayAccountState" {
                dataAccount = (frame["devices"] as? [[String: Any]])?.first(where: { $0["astation_id"] as? String == station })?["data_account"] as? String
                break
            }
        }
        let account = try XCTUnwrap(dataAccount)

        let manager = Curve25519.Signing.PrivateKey()
        let clock = RemoteSystemClock.now()
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        func b64(_ bytes: Data) -> String { RemoteRecoveryKit.base64URL(bytes) }
        let body: [String: Any] = ["type":"atem-membership-entry", "v":1, "account_id":account,
            "seq":1, "prev_hash":String(repeating: "0", count: 64), "action":"genesis", "signer":station,
            "signed_at":clock.wallMs, "member":["device_id":station, "kind":"native", "roles":["control", "manage", "view"],
                "auth_key":["alg":"ed25519", "pub":b64(manager.publicKey.rawRepresentation)],
                "enc_key":["alg":"x25519", "pub":b64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)]],
            "recovery_key":["alg":"ed25519", "pub":b64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]
        let info = try signedObjectInfo(json: json(["body":body, "sig":b64(Data(repeating: 0, count: 64))]))
        let entry = try json(["body":body, "sig":b64(manager.signature(for: info.signingInput))])
        let genesis = try XCTUnwrap(info.entryHash)
        _ = try MembershipLog.verify(accountId: account, genesisHash: genesis, entries: [entry], now: clock)
        let transport = try RemoteRecoveryHTTP(relayURL: resource, accessToken: { renewed.accessToken })
        let append = AppendRequest(entryJson: entry, entryHash: genesis,
            expected: LogHead(seq: 0, hash: String(repeating: "0", count: 64)))
        guard case .stored = try await transport.append(genesisHash: genesis, request: append) else { return XCTFail("genesis not stored") }
        let pageBack = try await transport.entries(genesisHash: genesis, after: 0)
        XCTAssertEqual(pageBack.head.seq, 1)
        _ = try MembershipLog.verify(accountId: account, genesisHash: genesis, entries: pageBack.entries, now: clock)
        let denied = try RemoteRecoveryHTTP(relayURL: resource, accessToken: { "invalid-local-fixture-token" })
        do { _ = try await denied.entries(genesisHash: genesis, after: 0); XCTFail("invalid login authorized storage") }
        catch RemoteRecoveryTransportError.authenticationRequired { }
    }
}
