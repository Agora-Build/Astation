import XCTest
@testable import Menubar

final class AndroidPortForwardTests: XCTestCase {
    func testEditablePortsValidateBeforeBinding() throws {
        let forward = try AndroidPortForward(sharedPort: "31000", localPort: "27183").validated()
        XCTAssertEqual(forward, AndroidForwardedPort(sharedPort: 31000, localPort: 27183))
        for invalid in ["", "0", "1023", "65536", "-1", " 27183", "27183x", "２７１８３"] {
            XCTAssertThrowsError(try AndroidPortForward(sharedPort: invalid).validated())
            XCTAssertThrowsError(try AndroidPortForward(localPort: invalid).validated())
        }
    }

    func testRejectsDuplicateAndOutOfRangePortsAndExcessiveListeners() {
        let forward = AndroidForwardedPort(sharedPort: 27183, localPort: 27183)
        XCTAssertNoThrow(try AndroidForwardedPort.validate([forward], sharingPort: 5038))
        XCTAssertThrowsError(try AndroidForwardedPort.validate([forward], sharingPort: 27183))
        XCTAssertThrowsError(try AndroidForwardedPort.validate([forward, forward], sharingPort: 5038))
        XCTAssertThrowsError(try AndroidForwardedPort.validate([.init(sharedPort: 0, localPort: 27183)], sharingPort: 5038))
        XCTAssertThrowsError(try AndroidForwardedPort.validate([.init(sharedPort: 27183, localPort: 65536)], sharingPort: 5038))
        let tooMany = (0...AndroidForwardedPort.maximumCount).map {
            AndroidForwardedPort(sharedPort: 28000 + $0, localPort: 29000 + $0)
        }
        XCTAssertThrowsError(try AndroidForwardedPort.validate(tooMany, sharingPort: 5038))
    }

    func testScrcpyCommandUsesRemoteADBAndDistinctTunnelPortWithLiteralSerial() {
        let command = AndroidCommands.scrcpyCommand(address: "100.80.1.2", port: 6107,
            serial: "phone'$(whoami)", forward: .init(sharedPort: 31000, localPort: 27183))
        XCTAssertEqual(command, "ADB_SERVER_SOCKET='tcp:100.80.1.2:6107' scrcpy --serial 'phone'\\''$(whoami)' --force-adb-forward --port=27183 --tunnel-host='100.80.1.2' --tunnel-port=31000")
    }

    @MainActor
    func testMappingsPersistWithoutOpeningPortsAndDefaultSuggestionsAvoidCollisions() {
        let suite = "android-ports-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AndroidDeviceManager(defaults: defaults)
        XCTAssertTrue(first.portForwards.isEmpty)
        first.portText = "27183"
        first.addPortForward()
        first.addPortForward()
        XCTAssertEqual(first.portForwards.map(\.sharedPort), ["27184", "27185"])
        first.portForwards[0].localPort = "31000"
        first.removePortForward(id: first.portForwards[1].id)
        let saved = first.portForwards
        first.shutdown()
        let restored = AndroidDeviceManager(defaults: defaults)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.portForwards, saved)
        XCTAssertFalse(restored.isSharing)
        XCTAssertTrue(restored.boundForwardedPorts.isEmpty)
        let device = AndroidDevice(serial: "phone", state: "device", model: "Phone", transport: "USB")
        XCTAssertNil(restored.scrcpyCommand(for: device, forward: .init(sharedPort: 27184, localPort: 31000)))
    }
}
