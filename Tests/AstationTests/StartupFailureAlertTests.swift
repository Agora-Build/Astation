import Darwin
import Foundation
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
}
