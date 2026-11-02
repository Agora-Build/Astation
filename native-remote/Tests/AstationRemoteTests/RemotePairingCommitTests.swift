import Foundation
import XCTest
@testable import AstationRemote

final class RemotePairingCommitTests: XCTestCase {
    private let context = RemotePairingContext(accountID: "account-a", hostID: "host-a", linkGeneration: UUID())

    private func message(_ generation: String = "3", host: String = "host-a", commitment: String = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") -> Data {
        Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"\(host)\",\"commitment\":\"\(commitment)\",\"host_trust_gen\":\(generation)}}".utf8)
    }

    func testOriginalIntegerAndContextAreCapturedImmutably() throws {
        for generation: UInt64 in [1, 3, 9_007_199_254_740_991] {
            var original = message(String(generation))
            let capture = try RemotePairingCommit(originalJSON: original, context: context)
            original.removeAll()
            XCTAssertEqual(capture.hostTrustGeneration, generation)
            XCTAssertEqual(capture.context, context)
            XCTAssertEqual(capture.commitment, Data(repeating: 0, count: 32))
        }
        let reconnect = RemotePairingContext(accountID: context.accountID, hostID: context.hostID, linkGeneration: UUID())
        XCTAssertNotEqual(context, reconnect)
    }

    func testLossyDecoderCannotTurnInvalidGenerationIntoAnInteger() {
        for generation in ["3.0", "3e0", "true", "null", "\"3\"", "0", "-0", "-1", "9007199254740992", "18446744073709551616"] {
            XCTAssertThrowsError(try RemotePairingCommit(originalJSON: message(generation), context: context), generation)
        }
    }

    func testDuplicateMissingAndWrongEnvelopeAreRefused() {
        let valid = String(data: message(), encoding: .utf8)!
        let invalid = [
            valid.replacingOccurrences(of: "\"host_trust_gen\":3", with: "\"host_trust_gen\":3,\"host_trust_gen\":4"),
            valid.replacingOccurrences(of: "\"device_id\":\"host-a\"", with: "\"device_id\":\"other\",\"device_id\":\"host-a\""),
            valid.replacingOccurrences(of: ",\"host_trust_gen\":3", with: ""),
            valid.replacingOccurrences(of: "verifyCommit", with: "verifyReveal"),
            valid + " trailing"
        ]
        for raw in invalid {
            XCTAssertThrowsError(try RemotePairingCommit(originalJSON: Data(raw.utf8), context: context))
        }
    }

    func testHostCommitmentAndEncodingAreChecked() {
        XCTAssertThrowsError(try RemotePairingCommit(originalJSON: message(host: "other-host"), context: context))
        for commitment in ["", "AAAA", "invalid base64"] {
            XCTAssertThrowsError(try RemotePairingCommit(originalJSON: message(commitment: commitment), context: context))
        }
        let emptyAccount = RemotePairingContext(accountID: "", hostID: context.hostID, linkGeneration: context.linkGeneration)
        XCTAssertThrowsError(try RemotePairingCommit(originalJSON: message(), context: emptyAccount))
        XCTAssertThrowsError(try RemotePairingCommit(originalJSON: Data([0xff]), context: context))
        XCTAssertThrowsError(try RemotePairingCommit(originalJSON: Data(repeating: 32, count: 262_145), context: context))
    }
}
