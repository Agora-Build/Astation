import XCTest
@testable import Menubar

final class IdentityRelayReconnectPolicyTests: XCTestCase {
    func testServiceRestartRetriesPromptlyWithoutTightLoop() {
        var policy = IdentityRelayReconnectPolicy()

        XCTAssertEqual(policy.delay(observedCloseCode: 1012, wasVerified: true, unitJitter: 0.5), 0.5)
        XCTAssertEqual(policy.delay(observedCloseCode: 1012, wasVerified: true, unitJitter: 0.5), 1.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1012, wasVerified: true, unitJitter: 0.5), 2.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1012, wasVerified: true, unitJitter: 0.5), 2.0)
    }

    func testTryAgainLaterUsesBoundedExponentialBackoff() {
        var policy = IdentityRelayReconnectPolicy()

        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 2.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 4.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 8.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 16.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 30.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 30.0)
    }

    func testTryAgainLaterJitterStaysWithinBounds() {
        var lowPolicy = IdentityRelayReconnectPolicy()
        var highPolicy = IdentityRelayReconnectPolicy()

        XCTAssertEqual(
            lowPolicy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.0),
            1.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            highPolicy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 1.0),
            2.4,
            accuracy: 0.0001
        )
    }

    func testOrdinaryDisconnectAlsoBacksOff() {
        var policy = IdentityRelayReconnectPolicy()

        XCTAssertEqual(policy.delay(observedCloseCode: 1006, wasVerified: false, unitJitter: 0.5), 1.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1006, wasVerified: false, unitJitter: 0.5), 2.0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1006, wasVerified: false, unitJitter: 0.5), 4.0)
    }

    func testMissingCloseCodeUsesConnectionState() {
        var establishedPolicy = IdentityRelayReconnectPolicy()
        var unverifiedPolicy = IdentityRelayReconnectPolicy()

        XCTAssertEqual(
            establishedPolicy.delay(observedCloseCode: nil, wasVerified: true, unitJitter: 0.5),
            0.5
        )
        XCTAssertEqual(
            unverifiedPolicy.delay(observedCloseCode: nil, wasVerified: false, unitJitter: 0.5),
            2.0
        )
    }

    func testVerificationResetsBackoff() {
        var policy = IdentityRelayReconnectPolicy()
        _ = policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5)
        _ = policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5)

        policy.reset()

        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(policy.delay(observedCloseCode: 1013, wasVerified: false, unitJitter: 0.5), 2.0)
    }
}
