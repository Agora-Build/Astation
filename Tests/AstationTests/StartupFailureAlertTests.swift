import Darwin
import Foundation
import NIO
import XCTest

@testable import Menubar

final class StartupFailureAlertTests: XCTestCase {
    func testAddressInUseExplainsHowToRecover() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))

        let content = StartupFailureAlertContent.make(error: error, port: 8080)

        XCTAssertEqual(content.title, "Astation Could Not Start")
        XCTAssertTrue(content.message.contains("Port 8080 is already in use"))
        XCTAssertTrue(content.message.contains("Another Astation instance or application"))
        XCTAssertTrue(content.message.contains("open Astation again"))
    }

    func testNIOAddressInUseExplainsHowToRecover() {
        let error = IOError(errnoCode: EADDRINUSE, reason: "test bind")

        let content = StartupFailureAlertContent.make(error: error, port: 8080)

        XCTAssertTrue(content.message.contains("Port 8080 is already in use"))
        XCTAssertFalse(content.message.contains("test bind"))
    }

    func testOtherStartupFailureIncludesUnderlyingReason() {
        let error = NSError(
            domain: "build.agora.astation.tests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Test bind failure"]
        )

        let content = StartupFailureAlertContent.make(error: error, port: 9090)

        XCTAssertEqual(content.title, "Astation Could Not Start")
        XCTAssertTrue(content.message.contains("port 9090"))
        XCTAssertTrue(content.message.contains("Test bind failure"))
    }

    func testOtherNIOFailureIncludesErrnoDescription() {
        let error = IOError(errnoCode: EACCES, reason: "test bind")

        let content = StartupFailureAlertContent.make(error: error, port: 8080)

        XCTAssertTrue(content.message.contains("test bind"))
        XCTAssertTrue(content.message.contains("errno: \(EACCES)"))
    }
}
