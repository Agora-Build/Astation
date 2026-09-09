import XCTest
@testable import Menubar

final class AndroidDeviceTests: XCTestCase {
    func testParsesTransportAndAuthorizationWithoutMergingPhysicalPhones() {
        let result = AndroidDevice.parse("""
        * daemon started successfully *
        List of devices attached
        USB123 device usb:336592896X product:shiba model:Pixel_9 transport_id:1
        192.168.1.6:38001 device product:shiba model:Pixel_9 transport_id:2
        adb-USB123-test._adb-tls-connect._tcp device model:Pixel_9
        WAITING unauthorized usb:123
        LOST offline
        emulator-5554 device model:sdk_gphone64_arm64
        garbage
        """)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.first { $0.serial == "USB123" }?.transport, "USB")
        XCTAssertEqual(result.first { $0.serial == "USB123" }?.model, "Pixel 9")
        XCTAssertEqual(result.filter { $0.transport == "Wireless" }.count, 2)
        XCTAssertFalse(result.first { $0.serial == "WAITING" }!.isAuthorized)
        XCTAssertEqual(result.first { $0.serial == "LOST" }?.status, "Offline")
        XCTAssertEqual(result.first { $0.serial == "emulator-5554" }?.transport, "Emulator")
        XCTAssertTrue(AndroidDevice.parse("List of devices attached\n").isEmpty)
    }

    func testConfigurablePortValidationAndCommands() {
        XCTAssertEqual(AndroidCommands.port("6012"), 6012)
        for invalid in ["0", "1023", "65536", "-4", "5038x", "", " 5038", "５０３８"] {
            XCTAssertNil(AndroidCommands.port(invalid))
        }
        let command = AndroidCommands.deviceCommand(address: "100.70.1.2", port: 6012, serial: "phone'$(whoami)")
        XCTAssertEqual(command, "adb -H '100.70.1.2' -P 6012 -s 'phone'\\''$(whoami)' shell")
    }

    func testWirelessAddressesAndEnvironmentIsolation() {
        XCTAssertTrue(AndroidCommands.wirelessEndpoint("192.168.1.3:37121"))
        for invalid in ["localhost:1", "1.2.3.999:5555", "1.2.3.4:0", "1.2.3.4:65536", "1.2.3.4:5555;pwd"] {
            XCTAssertFalse(AndroidCommands.wirelessEndpoint(invalid))
        }
        let env = ADBClient.localEnvironment(["ADB_SERVER_SOCKET": "tcp:other:9999", "ANDROID_SERIAL": "other", "ADB_TRACE": "all", "PATH": "/usr/bin", "HOME": "/home/test"])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "HOME": "/home/test"])
        XCTAssertEqual(ADBClient.protocolVersion("Android Debug Bridge version 1.0.41\nVersion 36.0.0\n"), 41)
        XCTAssertNil(ADBClient.protocolVersion("not adb"))
    }

    @MainActor
    func testPortPersistsButSharingDoesNotResumeAfterRelaunch() {
        let suite = "android-sharing-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AndroidDeviceManager(defaults: defaults)
        XCTAssertEqual(first.portText, "5038")
        first.portText = "6107"
        first.selectedAddressID = "utun7|100.80.1.2"
        first.shutdown()
        let second = AndroidDeviceManager(defaults: defaults)
        defer { second.shutdown() }
        XCTAssertEqual(second.portText, "6107")
        XCTAssertEqual(second.selectedAddressID, "utun7|100.80.1.2")
        XCTAssertFalse(second.isSharing)
        XCTAssertNil(second.endpoint)
        XCTAssertNil(second.shellSetup)
    }
}

final class AndroidADBProcessTests: XCTestCase {
    private func executable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-adb-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPassesArgumentsLiterallyAndCapturesFailureOutput() async throws {
        let url = try executable("printf '%s\\n' \"$@\"\nprintf 'diagnostic' >&2\nexit 7\n")
        let result = try await ADBClient(executable: url.path).run(["shell", "$(not-a-command); echo unsafe"])
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.hasPrefix("-H\n127.0.0.1\n-P\n5037\nshell\n$(not-a-command); echo unsafe\n"))
        XCTAssertTrue(result.output.contains("diagnostic"))
    }

    func testCommandTimeoutAndCancellationTerminateOwnedProcess() async throws {
        let url = try executable("exec /bin/sleep 30\n")
        let start = Date()
        do {
            _ = try await ADBClient(executable: url.path).run([], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let task = Task { try await ADBClient(executable: url.path).run([]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testOutputLimitAndStdin() async throws {
        let input = try executable("read code\nprintf 'received:%s' \"$code\"\n")
        let result = try await ADBClient(executable: input.path).run(["pair", "192.168.1.2:1234"], input: "123456\n")
        XCTAssertEqual(result.output, "received:123456")
        let large = try executable("exec /usr/bin/yes output\n")
        do { _ = try await ADBClient(executable: large.path).run([]); XCTFail("Expected bounded output") }
        catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
    }
}
