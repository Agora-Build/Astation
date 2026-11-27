import AtemClient
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
