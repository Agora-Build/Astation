import XCTest
@testable import Menubar

final class BffProjectDecodeTests: XCTestCase {
    func testDecodesProjectWithAllFields() throws {
        let json = """
        {
          "projectId": "pid1",
          "name": "App",
          "appId": "0abc",
          "signKey": "cert1",
          "status": "active",
          "createdAt": "2025-01-08T00:00:00Z",
          "vid": 12345
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BffProject.self, from: json)
        XCTAssertEqual(p.projectId, "pid1")
        XCTAssertEqual(p.name, "App")
        XCTAssertEqual(p.appId, "0abc")
        XCTAssertEqual(p.signKey, "cert1")
        XCTAssertEqual(p.status, "active")
        XCTAssertEqual(p.createdAt, "2025-01-08T00:00:00Z")
        XCTAssertEqual(p.vid, 12345)
    }

    func testDecodeAllowsMissingSignKeyAndVid() throws {
        let json = """
        {"projectId":"p","name":"n","appId":"a","status":"active","createdAt":"2025-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(BffProject.self, from: json)
        XCTAssertNil(p.signKey)
        XCTAssertNil(p.vid)
    }

    func testEnvelopeDecodes() throws {
        let json = """
        {"items":[
          {"projectId":"p1","name":"One","appId":"a1","signKey":"c1","status":"active","createdAt":"2025-01-01T00:00:00Z"}
        ]}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(BffProjectsEnvelope.self, from: json)
        XCTAssertEqual(env.items.count, 1)
        XCTAssertEqual(env.items[0].appId, "a1")
    }
}

final class BffProjectMappingTests: XCTestCase {
    func testMapsBffProjectToAgoraProject() {
        let b = BffProject(projectId: "pid", name: "My App", appId: "0app",
                           signKey: "cert", status: "active",
                           createdAt: "2025-01-08T00:00:00Z", vid: 42)
        let p = AgoraProject(from: b)
        XCTAssertEqual(p.id, "0app")
        XCTAssertEqual(p.vendorKey, "0app")
        XCTAssertEqual(p.signKey, "cert")
        XCTAssertEqual(p.name, "My App")
        XCTAssertEqual(p.status, "active")
        // 2025-01-08T00:00:00Z → 1736294400
        XCTAssertEqual(p.created, 1_736_294_400)
    }

    func testMapsWithMissingSignKey() {
        let b = BffProject(projectId: "p", name: "n", appId: "a", signKey: nil,
                           status: "disabled", createdAt: "bogus", vid: nil)
        let p = AgoraProject(from: b)
        XCTAssertEqual(p.signKey, "")
        XCTAssertEqual(p.created, 0, "unparseable date falls back to 0")
    }
}

final class AgoraAPIErrorTests: XCTestCase {
    func testUnauthorizedDescription() {
        XCTAssertTrue(AgoraAPIError.unauthorized.errorDescription?
            .contains("Session expired") == true)
    }
}

// MARK: - AgoraProject Codable round-trip

final class AgoraProjectCodableTests: XCTestCase {
    func testAgoraProjectEncodeDecode() throws {
        let project = AgoraProject(
            id: "app123",
            name: "Round Trip",
            vendorKey: "app123",
            signKey: "cert789",
            status: "active",
            created: 1637153755
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AgoraProject.self, from: data)

        XCTAssertEqual(decoded.id, "app123")
        XCTAssertEqual(decoded.name, "Round Trip")
        XCTAssertEqual(decoded.vendorKey, "app123")
        XCTAssertEqual(decoded.signKey, "cert789")
        XCTAssertEqual(decoded.status, "active")
        XCTAssertEqual(decoded.created, 1637153755)
    }
}
