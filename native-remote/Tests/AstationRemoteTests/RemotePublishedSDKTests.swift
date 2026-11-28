import AtemClient
@testable import AstationRemote
import Foundation
import XCTest

final class RemotePublishedSDKTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func rows(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(value as? [[String: Any]])
    }

    private func log(_ vector: [String: Any], reports: [String: Any]? = nil) throws -> MembershipLog {
        let source = try fixture("r9-vectors-membership-log")
        let base = try rows(source["log"])
        let extra = try rows(source["others"]) + (reports.map { try rows($0["entries"]) } ?? [])
        let entries = Dictionary(uniqueKeysWithValues: try extra.map { row in
            (try XCTUnwrap(row["label"] as? String), try XCTUnwrap(row["entry"]))
        })
        let chain = try (vector["chain"] as? [String] ?? []).map { try json(XCTUnwrap(entries[$0])) }
        let clock = HostClock(wallMs: (vector["now_ms"] as? NSNumber)?.uint64Value ?? 1_793_264_001_000,
            monoMs: 1_000, bootId: "published-sdk")
        let log = try MembershipLog.verify(accountId: XCTUnwrap(source["account_id"] as? String),
            genesisHash: XCTUnwrap(source["genesis_hash"] as? String),
            entries: base.map { try json(XCTUnwrap($0["entry"])) } + chain, now: clock)
        if let freeze = vector["freeze"] as? String {
            _ = try log.extend(entries: [json(XCTUnwrap(entries[freeze]))], now: clock)
        }
        return log
    }

    func testPublishedClassifierChecksAll56BodiesWithoutLocalProtocolRules() throws {
        let cases = try rows(fixture("r9-vectors-required-verifier")["cases"])
        XCTAssertEqual(cases.count, 56)
        for vector in cases {
            let body = try XCTUnwrap(vector["body_json"] as? String)
            if vector["reject"] as? Bool == true {
                XCTAssertThrowsError(try membershipRequiredVersion(bodyJson: body)) { error in
                    guard case let AtemError.Membership(code, detail, index) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(code, "membership_invalid")
                    XCTAssertEqual(detail, vector["reason"] as? String)
                    XCTAssertNil(index)
                }
            } else {
                let actual = try membershipRequiredVersion(bodyJson: body)
                if let expected = vector["requirement"] as? [String: Any] {
                    XCTAssertEqual(actual?.action, expected["action"] as? String)
                    XCTAssertEqual(actual?.minimumVersion, (expected["minimum_version"] as? NSNumber)?.uint32Value)
                } else { XCTAssertNil(actual) }
            }
        }
    }

    func testPublishedReportChallengesAreStrictAndBounded() throws {
        let cases = try rows(fixture("r9-vectors-verifier-report")["challenges"])
        XCTAssertEqual(cases.count, 38)
        for vector in cases {
            let text = try XCTUnwrap(vector["text"] as? String)
            if let expected = vector["fields"] as? [String: Any] {
                let actual = try parseVerifierReportChallenge(challengeJson: text)
                XCTAssertEqual(actual.signer, expected["signer"] as? String)
                XCTAssertEqual(actual.slot, expected["slot"] as? String)
                XCTAssertEqual(actual.origin, expected["origin"] as? String)
                XCTAssertEqual(actual.connection, (expected["connection"] as? NSNumber)?.uint64Value)
                XCTAssertEqual(actual.nonce, expected["nonce"] as? String)
                XCTAssertEqual(actual.issuedAt, (expected["issued_at"] as? NSNumber)?.uint64Value)
                XCTAssertEqual(actual.expiresAt, (expected["expires_at"] as? NSNumber)?.uint64Value)
            } else {
                XCTAssertThrowsError(try parseVerifierReportChallenge(challengeJson: text)) { error in
                    guard case let AtemError.Report(code, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(code, vector["code"] as? String)
                }
            }
        }
    }

    func testPublishedReportsCheckExactSignerSlotHeadAndSignature() throws {
        let source = try fixture("r9-vectors-verifier-report")
        let cases = try rows(source["valid"]) + rows(source["invalid"])
        XCTAssertEqual(cases.count, 105)
        for vector in cases {
            let membership = try log(vector, reports: source)
            let verify = {
                try verifyVerifierReport(log: membership, reportJson: XCTUnwrap(vector["report"] as? String),
                    expectedChallengeJson: self.json(XCTUnwrap(vector["challenge"])),
                    nowMs: XCTUnwrap(vector["now_ms"] as? NSNumber).uint64Value)
            }
            if let expected = vector["expect"] as? [String: Any] {
                let actual = try verify()
                XCTAssertEqual(actual.signer, expected["signer"] as? String)
                XCTAssertEqual(actual.slot, expected["slot"] as? String)
                XCTAssertEqual(actual.process, expected["process"] as? String)
                XCTAssertEqual(actual.atHead, expected["at_head"] as? Bool)
                XCTAssertEqual(actual.kind, expected["kind"] as? String == "native" ? .native : .service)
                XCTAssertEqual(actual.connection, (expected["connection"] as? NSNumber)?.uint64Value)
                XCTAssertEqual(actual.expiresAt, (expected["expires_at"] as? NSNumber)?.uint64Value)
                let head = try XCTUnwrap(expected["head"] as? [String: Any])
                XCTAssertEqual(actual.head.hash, head["hash"] as? String)
                XCTAssertEqual(actual.head.seq, (head["seq"] as? NSNumber)?.uint64Value)
                let inventory = try XCTUnwrap(expected["inventory"] as? [String: Any])
                XCTAssertEqual(actual.inventory.version, (inventory["version"] as? NSNumber)?.uint32Value)
                XCTAssertEqual(actual.inventory.actions, inventory["actions"] as? [String])
            } else {
                XCTAssertThrowsError(try verify(), "\(vector["label"] ?? "report")") { error in
                    guard case let AtemError.Report(code, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(code, vector["code"] as? String)
                }
            }
        }
    }

    func testPublishedBuilderSuppliesItsOwnProcessAndNeverRequestsConfirmation() throws {
        let source = try fixture("r9-vectors-verifier-report")
        let cases = try rows(source["builder"]) + rows(source["request"])
        XCTAssertEqual(cases.count, 20)
        for vector in cases {
            let membership = try log(vector, reports: source)
            let build = {
                try VerifierReportRequest(log: membership, challengeJson: self.json(XCTUnwrap(vector["challenge"])),
                    signer: XCTUnwrap(vector["signer"] as? String), slot: XCTUnwrap(vector["slot"] as? String),
                    origin: XCTUnwrap(vector["station"] as? String), keyId: "existing-key",
                    nowMs: XCTUnwrap(vector["now_ms"] as? NSNumber).uint64Value)
            }
            if let expected = vector["body_but_process"] as? [String: Any] {
                let request = try build()
                let body = request.bodyJson()
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                XCTAssertEqual(value.removeValue(forKey: "process") as? String, verifierReportProcess())
                XCTAssertEqual(try canonicalJson(json: json(value)), try canonicalJson(json: json(expected)))
                let signing = request.signRequest()
                XCTAssertEqual(signing.purpose, .verifierReport)
                XCTAssertFalse(signing.freshConfirmation)
                XCTAssertEqual(signing.bodyJson, body)
                XCTAssertEqual(signing.input, encodeFields(fields: [Data(signing.label.utf8), Data(body.utf8)]))
                XCTAssertThrowsError(try request.finish(signature: Data(repeating: 0, count: 64)))
                XCTAssertEqual(request.bodyJson(), body)
            } else {
                XCTAssertThrowsError(try build()) { error in
                    guard case let AtemError.Report(code, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(code, vector["code"] as? String)
                }
            }
        }
    }

    func testPublishedSignerReportPlanPredicate() throws {
        let source = try fixture("r9-vectors-signer-report")
        let cases = try rows(source["plan_predicate"])
        XCTAssertEqual(cases.count, 32)
        for vector in cases {
            let label = try XCTUnwrap(vector["label"] as? String)
            let membership = try log(vector, reports: source)
            let body = try XCTUnwrap(vector["body"] as? String)
            let member = try XCTUnwrap(vector["member"] as? String)
            let origin = try XCTUnwrap(vector["origin"] as? String)
            let classify = { try signerReportPlanRecord(log: membership, bodyJson: body, member: member, origin: origin) }
            if let code = vector["code"] as? String {
                XCTAssertThrowsError(try classify(), label) { error in
                    guard case let AtemError.Report(actual, _) = error else { return XCTFail("\(label): \(error)") }
                    XCTAssertEqual(actual, code, label)
                }
            } else if try XCTUnwrap(vector["in_plan"] as? Bool) {
                XCTAssertEqual(try classify(), .inPlan, label)
            } else {
                let reason = try XCTUnwrap(vector["reason"] as? String)
                XCTAssertEqual(try classify(), .notInPlan(reason: reason), label)
            }
        }
    }

    func testPublishedStationBindingProofsUseThePackagedVerifier() throws {
        let source = try fixture("r9-vectors-station-binding")
        let valid = try rows(source["valid"])
        let invalid = try rows(source["invalid"])
        XCTAssertEqual(valid.count, 16)
        XCTAssertEqual(invalid.count, 153)
        for vector in valid + invalid {
            let membership = try log(vector, reports: source)
            let proof = try XCTUnwrap(vector["proof"] as? String)
            let challenge = try json(XCTUnwrap(vector["challenge"]))
            let now = try XCTUnwrap(vector["now_ms"] as? NSNumber).uint64Value
            let verify = {
                try verifyStationBinding(log: membership, proofJson: proof, expectedChallengeJson: challenge, nowMs: now)
            }
            if let code = vector["code"] as? String {
                XCTAssertThrowsError(try verify()) { error in
                    guard case let AtemError.Report(actual, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(actual, code)
                }
            } else {
                let expected = try XCTUnwrap(vector["expect"] as? [String: Any])
                let result = try verify()
                XCTAssertEqual(result.atHead, expected["at_head"] as? Bool)
                XCTAssertEqual(result.signer, expected["signer"] as? String)
                XCTAssertEqual(result.subject, expected["subject"] as? String)
                XCTAssertEqual(result.nonce, expected["nonce"] as? String)
            }
        }
    }

    func testFirstBindingConfirmationExplainsOtherRoomOwnersConsent() {
        func prompt(_ action: BindingAction, _ previous: ExpectedBinding) -> String {
            RemoteStationBindingApproval.Review(action: action, origin: "https://station-dev.agora.build",
                accountID: "device-list", subject: "owner", previous: previous).confirmation
        }
        let notice = "Rooms owned by other Agora.Build accounts move only with their owners' consent."
        XCTAssertTrue(prompt(.bind, .neverBound).contains(notice))
        XCTAssertFalse(prompt(.bind, .released(bindingId: "test", version: 2, owner: "prior")).contains(notice))
        XCTAssertFalse(prompt(.transfer, .bound(bindingId: "test", version: 1, owner: "prior")).contains(notice))
    }

    @MainActor
    func testNativeBindingSignsOnlyTheTransferReviewedAgainstTheLoginAndLocalHead() async throws {
        let source = try fixture("r9-vectors-station-binding")
        let vector = try XCTUnwrap(rows(source["valid"]).first { $0["label"] as? String == "transfer_p256" })
        let log = try self.log(vector, reports: source)
        let json = try self.json(XCTUnwrap(vector["challenge"]))
        let challenge = try parseStationBindingChallenge(challengeJson: json)
        let originalProof = try XCTUnwrap(vector["proof"] as? String)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(originalProof.utf8)) as? [String: Any])
        let sig = try XCTUnwrap(RemoteRecoveryKit.decodeBase64URL(XCTUnwrap(envelope["sig"] as? String), count: 64))
        let station = "https://station-dev.agora.build"
        let config = try AccountOIDCConfiguration(issuer: "https://auth.dev.agora.build", clientID: "astation",
            resource: station, requiredScope: "astation.remote")
        let login = AccountLoginSession(configuration: config, subject: challenge.subject, accessToken: "test-bearer",
            refreshToken: "", expiresAt: Date(timeIntervalSince1970: Double(challenge.expiresAt) / 1000),
            authenticatedAt: Int64(challenge.authTime))
        let transport = BindingChallengeHTTP(challenge: Data(json.utf8))
        let client = try RemoteStationBindingApproval(origin: station, http: transport)
        var clock = challenge.issuedAt
        var stillCurrent = true
        var confirmations = 0
        var signatures = 0
        func prove(_ action: BindingAction, previous: ExpectedBinding, confirm: () -> Bool) async throws -> String {
            try await client.prove(action: action, previous: previous, session: login, managerID: "dev-phone",
                membership: { log }, now: { clock }, current: { stillCurrent }, confirm: { review in
                    confirmations += 1
                    XCTAssertEqual(review.origin, station)
                    XCTAssertEqual(review.subject, login.subject)
                    XCTAssertEqual(review.accountID, log.accountId())
                    if case .bound(_, _, let owner) = previous { XCTAssertTrue(review.confirmation.contains(owner)) }
                    return confirm()
                }, sign: { approved, key in
                    signatures += 1
                    XCTAssertEqual(key, log.member(deviceId: "dev-phone")?.authKey)
                    let request = try approved.consume()
                    XCTAssertEqual(request.label, "atem-station-binding-v1")
                    XCTAssertTrue(request.freshConfirmation)
                    XCTAssertThrowsError(try approved.consume())
                    return sig
                })
        }
        let proof = try await prove(.transfer, previous: challenge.expectedBinding) { true }
        XCTAssertEqual(try canonicalJson(json: proof), try canonicalJson(json: originalProof))
        let sent = await transport.lastRequest
        XCTAssertEqual(sent?.url?.absoluteString, station + "/agora-build/v1/logs/" + log.genesisHash() + "/binding/challenge")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "transfer")
        XCTAssertEqual(body["signer"] as? String, "member:dev-phone")
        for (action, previous) in [(BindingAction.unbind, challenge.expectedBinding), (.transfer, .neverBound)] {
            do { _ = try await prove(action, previous: previous) { true }; XCTFail("changed intent") }
            catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        }
        XCTAssertEqual(confirmations, 1)
        do { _ = try await prove(.transfer, previous: challenge.expectedBinding) { false }; XCTFail("cancelled") }
        catch { XCTAssertNotNil(error as? RemoteRecoveryError) }
        do { _ = try await prove(.transfer, previous: challenge.expectedBinding) { stillCurrent = false; return true }; XCTFail("retired login") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        stillCurrent = true
        do { _ = try await prove(.transfer, previous: challenge.expectedBinding) { clock = challenge.expiresAt; return true }; XCTFail("expired") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        XCTAssertEqual(signatures, 1)
    }

    @MainActor
    func testStationBindingReceiptRetryUsesTheSavedProofAndChecksTheAccountAndVersion() async throws {
        let source = try fixture("r9-vectors-station-binding")
        let vector = try XCTUnwrap(rows(source["valid"]).first { $0["label"] as? String == "transfer_p256" })
        let proof = try XCTUnwrap(vector["proof"] as? String)
        let challenge = try parseStationBindingChallenge(challengeJson: json(XCTUnwrap(vector["challenge"])))
        guard case let .bound(id, version, _) = challenge.expectedBinding else { return XCTFail("transfer predecessor") }
        let config = try AccountOIDCConfiguration(issuer: challenge.issuer, clientID: "astation",
            resource: challenge.origin, requiredScope: "astation.remote")
        func login(_ authTime: UInt64) -> AccountLoginSession {
            AccountLoginSession(configuration: config, subject: challenge.subject, accessToken: "test-bearer",
                refreshToken: "", expiresAt: Date(timeIntervalSince1970: Double(challenge.expiresAt) / 1000 + 60),
                authenticatedAt: Int64(authTime))
        }
        var receipt: [String: Any] = ["account": challenge.subject, "accountId": challenge.accountId,
            "genesisHash": challenge.genesisHash, "bindingId": id, "version": version + 1, "bindingState": "bound"]
        let ok = try JSONSerialization.data(withJSONObject: receipt)
        let pending = Data(#"{"pending":true}"#.utf8)
        let expired = Data(#"{"error":{"code":"binding_proof_expired"}}"#.utf8)
        receipt["version"] = version
        let wrongVersion = try JSONSerialization.data(withJSONObject: receipt)
        let http = BindingReceiptHTTP([(pending, 202), (ok, 200), (ok, 200), (pending, 202), (expired, 410), (wrongVersion, 200)])
        let client = try RemoteStationBindingApproval(origin: challenge.origin, http: http)
        func retry(_ authenticatedAt: UInt64) async throws -> RemoteStationBindingReceipt {
            try await client.submit(proof: proof, session: login(authenticatedAt), accountID: challenge.accountId,
                genesisHash: challenge.genesisHash, retry: true, now: { challenge.issuedAt }, current: { true })
        }
        let first = try await retry(challenge.authTime)
        let replay = try await retry(challenge.authTime + 1)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.ownership, .bound(bindingId: id, version: version + 1, owner: challenge.subject))
        do { _ = try await retry(challenge.authTime + 1); XCTFail("another login must never submit a pending proof") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        do { _ = try await retry(challenge.authTime); XCTFail("expired proof") }
        catch RemoteStationBindingError.expiredWithoutCommit { }
        do { _ = try await retry(challenge.authTime); XCTFail("stale receipt") }
        catch { XCTAssertEqual(error as? AccountLoginError, .invalidResponse) }
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["receipt","commit","receipt","receipt","receipt","receipt"])
        XCTAssertTrue(requests.allSatisfy { $0.httpBody == Data(proof.utf8) && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer" })
    }

    @MainActor
    func testIndependentOwnerReviewsTheExactChallengeBeforeSendingConsent() async throws {
        let source = try fixture("r9-vectors-station-binding")
        let vector = try XCTUnwrap(rows(source["valid"]).first { $0["label"] as? String == "transfer_p256" })
        let body = try XCTUnwrap(vector["challenge"] as? [String: Any])
        let challenge = try parseStationBindingChallenge(challengeJson: json(body))
        guard case let .bound(_, _, owner) = challenge.expectedBinding else { return XCTFail("transfer owner") }
        let config = try AccountOIDCConfiguration(issuer: challenge.issuer, clientID: "astation",
            resource: challenge.origin, requiredScope: "astation.remote")
        func login(_ subject: String) -> AccountLoginSession {
            .init(configuration: config, subject: subject, accessToken: "owner-session", refreshToken: "",
                expiresAt: Date(timeIntervalSince1970: Double(challenge.expiresAt) / 1000 + 60),
                authenticatedAt: Int64(challenge.issuedAt / 1000))
        }
        let request = Data(try json(["request": body]).utf8)
        let none = Data(#"{"request":null}"#.utf8)
        let ok = Data(#"{"consented":true}"#.utf8)
        let http = BindingReceiptHTTP([(none, 200), (request, 200), (request, 200), (request, 200),
                                       (request, 200), (request, 200), (ok, 200)])
        let client = try RemoteStationBindingApproval(origin: challenge.origin, http: http)
        var time = challenge.issuedAt
        var current = true
        func review(_ subject: String, confirm: (StationBindingChallenge) -> Bool) async throws -> RemoteStationBindingApproval.ConsentOutcome {
            try await client.reviewConsent(session: login(subject), now: { time }, current: { current }, confirm: confirm)
        }
        let empty = try await review(owner) { _ in XCTFail("empty request"); return true }
        XCTAssertEqual(empty, .noRequest)
        let cancelled = try await review(owner) { seen in XCTAssertEqual(seen, challenge); return false }
        XCTAssertEqual(cancelled, .cancelled)
        do { _ = try await review(challenge.subject) { _ in XCTFail("own transfer"); return true }; XCTFail("wrong owner") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        do { _ = try await review(owner) { _ in current = false; return true }; XCTFail("changed account") }
        catch { XCTAssertEqual(error as? AccountLoginError, .changed) }
        current = true
        do { _ = try await review(owner) { _ in time = challenge.expiresAt; return true }; XCTFail("expired review") }
        catch RemoteStationBindingError.consentExpired {}
        time = challenge.issuedAt
        let recorded = try await review(owner) { seen in XCTAssertEqual(seen, challenge); return true }
        XCTAssertEqual(recorded, .recorded)
        let calls = await http.requests
        XCTAssertEqual(calls.dropLast().map { $0.httpMethod }, Array(repeating: "GET", count: 6))
        XCTAssertTrue(calls.dropLast().allSatisfy { $0.url?.path == "/agora-build/v1/binding/consent-request" })
        let posted = try XCTUnwrap(calls.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(posted.url?.absoluteString, challenge.origin + "/agora-build/v1/logs/" + challenge.genesisHash + "/binding/transfer-consent")
        XCTAssertEqual(posted.value(forHTTPHeaderField: "Authorization"), "Bearer owner-session")
        XCTAssertEqual(try canonicalJson(json: String(decoding: XCTUnwrap(posted.httpBody), as: UTF8.self)),
                       try canonicalJson(json: json(body)))
    }

    @MainActor
    func testManagerWaitsForConsentAndRetriesTheOriginalProof() async throws {
        let source = try fixture("r9-vectors-station-binding")
        let vector = try XCTUnwrap(rows(source["valid"]).first { $0["label"] as? String == "transfer_p256" })
        let proof = try XCTUnwrap(vector["proof"] as? String)
        let challenge = try parseStationBindingChallenge(challengeJson: json(XCTUnwrap(vector["challenge"])))
        guard case let .bound(id, version, _) = challenge.expectedBinding else { return XCTFail("transfer owner") }
        let config = try AccountOIDCConfiguration(issuer: challenge.issuer, clientID: "astation",
            resource: challenge.origin, requiredScope: "astation.remote")
        let session = AccountLoginSession(configuration: config, subject: challenge.subject, accessToken: "manager-session",
            refreshToken: "", expiresAt: Date(timeIntervalSince1970: Double(challenge.expiresAt) / 1000 + 60),
            authenticatedAt: Int64(challenge.authTime))
        let waiting = Data(#"{"awaiting_consent":true}"#.utf8)
        let receipt = Data(try json(["account": challenge.subject, "accountId": challenge.accountId,
            "genesisHash": challenge.genesisHash, "bindingId": id, "version": version + 1, "bindingState": "bound"]).utf8)
        let http = BindingReceiptHTTP([(waiting, 202), (receipt, 200), (waiting, 202),
            (Data(#"{"error":{"code":"binding_proof_expired"}}"#.utf8), 410)])
        let client = try RemoteStationBindingApproval(origin: challenge.origin, http: http)
        var time = challenge.issuedAt
        var waits = 0
        func submit(expire: Bool) async throws -> RemoteStationBindingReceipt {
            try await client.submit(proof: proof, session: session, accountID: challenge.accountId,
                genesisHash: challenge.genesisHash, retry: false, now: { time }, current: { true }, awaitingConsent: {
                    waits += 1
                    if expire { time = challenge.expiresAt }
                })
        }
        let confirmed = try await submit(expire: false)
        XCTAssertEqual(confirmed.version, version + 1)
        do { _ = try await submit(expire: true); XCTFail("expired consent") }
        catch RemoteStationBindingError.expiredWithoutCommit {}
        XCTAssertEqual(waits, 2)
        let calls = await http.requests
        XCTAssertEqual(calls.map { $0.url?.lastPathComponent }, ["commit", "commit", "commit", "receipt"])
        XCTAssertTrue(calls.allSatisfy { $0.httpBody == Data(proof.utf8) })
    }

    @MainActor
    func testOwnershipRefusalsIdentifyTheStationWithoutAskingForAnotherLogin() async throws {
        let origin = "https://station-dev.agora.build"
        let configuration = try AccountOIDCConfiguration(issuer: "https://auth.dev.agora.build", clientID: "astation",
            resource: origin, requiredScope: "astation.remote")
        let session = AccountLoginSession(configuration: configuration, subject: "owner", accessToken: "test-token",
            refreshToken: "", expiresAt: .distantFuture, authenticatedAt: 0)
        let cases: [(Int, String, RemoteStationBindingError)] = [
            (503, #"{"error":{"code":"host_work_not_verified"}}"#, .featureUnavailable),
            (409, #"{"error":{"code":"binding_unavailable"}}"#, .requestRefused),
            (429, #"{"error":{"code":"binding_busy"}}"#, .stationBusy),
            (503, "<html>Temporary outage</html>", .stationUnavailable),
            (503, #"{"error":{"code":"host_work_not_verified","account":"unexpected"}}"#, .stationUnavailable)
        ]
        for (status, body, expected) in cases {
            let http = BindingReceiptHTTP([(Data(body.utf8), status)])
            let client = try RemoteStationBindingApproval(origin: origin, http: http)
            do {
                _ = try await client.reviewConsent(session: session, now: { 1000 }, current: { true }) { _ in
                    XCTFail("A refused request cannot be confirmed"); return false
                }
                XCTFail("Expected refusal")
            } catch { XCTAssertEqual(error as? RemoteStationBindingError, expected) }
        }
    }

    func testAllPublishedSnapshotCasesUseTheActualConsistencyChecker() throws {
        let source = try fixture("r9-vectors-host-work-control")
        let records = Dictionary(uniqueKeysWithValues: try rows(source["records"]).map {
            (try XCTUnwrap($0["label"] as? String), try json(XCTUnwrap($0["record"])))
        })
        let cases = try rows(source["snapshots"])
        XCTAssertEqual(cases.count, 44)
        for vector in cases {
            let membership = try log(vector)
            func recordSet(_ key: String) throws -> [String] {
                try XCTUnwrap(vector[key] as? [String]).map { try XCTUnwrap(records[$0]) }
            }
            let marks = try XCTUnwrap(vector["marks"] as? [String: NSNumber]).map {
                ControlSnapshotMark(principal: $0.key, markMs: $0.value.uint64Value)
            }
            let result = try checkControlSnapshotConsistency(log: membership,
                origin: XCTUnwrap(vector["origin"] as? String), candidateFeedId: XCTUnwrap(vector["candidate_feed_id"] as? String),
                retainedJson: recordSet("retained"), snapshotJson: recordSet("snapshot"),
                marks: marks, covered: XCTUnwrap(vector["covered"] as? [String]))
            let expected = try XCTUnwrap(vector["expect"] as? [String: Any])
            if expected["consistent"] as? Bool == true { XCTAssertEqual(result, .consistent) }
            else {
                guard case let .inconsistent(index, code, principal, recordID, reason, effect, revokeSeq) = result else {
                    XCTFail("inconsistent snapshot accepted: \(vector["label"] ?? "snapshot")"); continue
                }
                XCTAssertEqual(index, (expected["index"] as? NSNumber)?.uint64Value)
                XCTAssertEqual(code, expected["code"] as? String)
                XCTAssertEqual(principal, expected["principal"] as? String)
                XCTAssertEqual(recordID, expected["record_id"] as? String)
                XCTAssertEqual(reason, expected["reason"] as? String)
                XCTAssertEqual(effect, expected["effect"] as? String)
                XCTAssertEqual(revokeSeq, (expected["revoke_seq"] as? NSNumber)?.uint64Value)
            }
        }
    }
}


private actor BindingReceiptHTTP: AccountOIDCHTTP {
    private var replies: [(Data, Int)]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [(Data, Int)]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw AccountLoginError.unavailable }
        return replies.removeFirst()
    }
}

private actor BindingChallengeHTTP: AccountOIDCHTTP {
    let challenge: Data
    private(set) var lastRequest: URLRequest?

    init(challenge: Data) { self.challenge = challenge }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lastRequest = request
        return (challenge, 200)
    }
}
