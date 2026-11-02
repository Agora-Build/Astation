import XCTest
@testable import Menubar

final class IntegrationAccessNoticeTests: XCTestCase {
    func testOnlyExactBuiltInOriginsIdentifyAgoraBuildAsOperator() {
        for origin in ["https://station.agora.build", "https://station-dev.agora.build"] {
            XCTAssertEqual(IntegrationAccessNotice.operatorName(stationOrigin: origin), "Agora.Build")
            XCTAssertTrue(IntegrationAccessNotice.disclosure(stationOrigin: origin).contains("Agora.Build can read and process"))
            let confirmation = IntegrationAccessNotice.ownerAuthenticationReason(stationOrigin: origin)
            XCTAssertTrue(confirmation.contains(origin))
            XCTAssertTrue(confirmation.contains("Agora.Build can read and process"))
        }
        for origin in ["https://custom.example", "https://station-dev.agora.build.evil.example",
                       "https://station-dev.agora.build:8443", "https://station.dev.agora.build"] {
            XCTAssertEqual(IntegrationAccessNotice.operatorName(stationOrigin: origin), "The operator of \(origin)")
        }
    }
}
