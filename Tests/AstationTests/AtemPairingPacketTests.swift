import XCTest
@testable import Menubar

final class AtemPairingPacketTests: XCTestCase {
    private func packet(_ generation: String) -> Data {
        Data("{\"type\":\"verifyCommit\",\"data\":{\"device_id\":\"host-a\",\"commitment\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"host_trust_gen\":\(generation)}}".utf8)
    }

    func testCommitGenerationReachesTheAppWithoutNumericCoercion() throws {
        for generation: UInt64 in [1, 3, 9_007_199_254_740_991] {
            guard case .verifyCommit(let commit) = try AstationMessage.decodePacket(packet(String(generation))) else {
                return XCTFail("Expected a validated commitment")
            }
            XCTAssertEqual(commit.hostTrustGeneration, generation)
            XCTAssertEqual(commit.deviceId, "host-a")
            XCTAssertEqual(commit.commitment.count, 32)
        }
    }

    func testInvalidGenerationBecomesAnAbortWithoutCreatingACeremony() throws {
        for token in ["3.0", "3e0", "true", "null", "\"3\"", "0", "-1", "9007199254740992"] {
            guard case .invalidVerifyCommit = try AstationMessage.decodePacket(packet(token)) else {
                return XCTFail("Accepted invalid generation: \(token)")
            }
        }
        let missing = String(decoding: packet("3"), as: UTF8.self).replacingOccurrences(of: ",\"host_trust_gen\":3", with: "")
        guard case .invalidVerifyCommit = try AstationMessage.decodePacket(Data(missing.utf8)) else {
            return XCTFail("Accepted a missing generation")
        }
        let abort = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AstationMessage.invalidVerifyCommit)) as? [String: Any]
        XCTAssertEqual(abort?["type"] as? String, "verifyAbort")
    }

    func testDuplicateFieldsCannotReachThePlatformDecoder() {
        let duplicate = String(decoding: packet("3"), as: UTF8.self)
            .replacingOccurrences(of: "\"host_trust_gen\":3", with: "\"host_trust_gen\":3,\"host_trust_gen\":4")
        XCTAssertThrowsError(try AstationMessage.decodePacket(Data(duplicate.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AstationMessage.self, from: packet("3")),
            "A platform decoder without the original-packet validation cannot create a commitment")
    }

    func testRelayPayloadKeepsAnInvalidIntegerSpellingUntilValidation() throws {
        let envelope = Data("{\"atem_id\":\"host-a\",\"connection_id\":\"generation-a\",\"payload\":\(String(decoding: packet("3e0"), as: UTF8.self))}".utf8)
        let root = try AtemSessionJSON.validatePacket(envelope)
        let payload = try XCTUnwrap(root["payload"]).canonical(allowOtherNumbers: true)
        XCTAssertTrue(payload.contains("3e0"))
        guard case .invalidVerifyCommit = try AstationMessage.decodePacket(Data(payload.utf8)) else {
            return XCTFail("Relay decoding erased the exponent")
        }
    }
}
