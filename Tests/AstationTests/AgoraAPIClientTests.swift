import XCTest
@testable import Menubar

final class AgoraAPIClientTests: XCTestCase {

    // MARK: - AgoraAPIProject decoding

    func testDecodeProjectWithStringId() throws {
        let json = """
        {
            "id": "abc123",
            "name": "Test Project",
            "vendor_key": "4855aabb",
            "sign_key": "cert1234",
            "recording_server": null,
            "status": 1,
            "created": 1637153755
        }
        """.data(using: .utf8)!
        let project = try JSONDecoder().decode(AgoraAPIProject.self, from: json)
        XCTAssertEqual(project.id, "abc123")
        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.vendor_key, "4855aabb")
        XCTAssertEqual(project.sign_key, "cert1234")
        XCTAssertNil(project.recording_server)
        XCTAssertEqual(project.status, 1)
        XCTAssertEqual(project.created, 1637153755)
    }

    func testDecodeProjectWithRecordingServer() throws {
        let json = """
        {
            "id": "proj1",
            "name": "With Recording",
            "vendor_key": "vk1",
            "sign_key": "sk1",
            "recording_server": "10.0.0.1",
            "status": 0,
            "created": 1700000000
        }
        """.data(using: .utf8)!
        let project = try JSONDecoder().decode(AgoraAPIProject.self, from: json)
        XCTAssertEqual(project.recording_server, "10.0.0.1")
        XCTAssertEqual(project.status, 0)
    }

    // MARK: - AgoraAPIResponse decoding

    func testDecodeFullResponse() throws {
        let json = """
        {
            "projects": [
                {
                    "id": "p1",
                    "name": "Project One",
                    "vendor_key": "vk1",
                    "sign_key": "sk1",
                    "recording_server": null,
                    "status": 1,
                    "created": 1637153755
                },
                {
                    "id": "p2",
                    "name": "Project Two",
                    "vendor_key": "vk2",
                    "sign_key": "sk2",
                    "recording_server": "192.168.1.1",
                    "status": 0,
                    "created": 1700000000
                }
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(AgoraAPIResponse.self, from: json)
        XCTAssertEqual(response.projects.count, 2)
        XCTAssertEqual(response.projects[0].name, "Project One")
        XCTAssertEqual(response.projects[1].name, "Project Two")
    }

    func testDecodeEmptyProjects() throws {
        let json = """
        { "projects": [] }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(AgoraAPIResponse.self, from: json)
        XCTAssertTrue(response.projects.isEmpty)
    }

    func testDecodeInvalidJsonFails() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AgoraAPIResponse.self, from: json))
    }

    func testDecodeMissingFieldsFails() {
        // Missing vendor_key
        let json = """
        {
            "projects": [{
                "id": "p1",
                "name": "Test",
                "sign_key": "sk1",
                "status": 1,
                "created": 1637153755
            }]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AgoraAPIResponse.self, from: json))
    }

    // MARK: - AgoraProject mapping

    func testAPIProjectToAgoraProjectMapping() {
        let raw = AgoraAPIProject(
            id: "p1",
            name: "My Project",
            vendor_key: "app_id_123",
            sign_key: "cert_456",
            recording_server: nil,
            status: 1,
            created: 1637153755
        )

        let project = AgoraProject(
            id: raw.vendor_key,
            name: raw.name,
            vendorKey: raw.vendor_key,
            signKey: raw.sign_key,
            status: raw.status == 1 ? "active" : "disabled",
            created: raw.created
        )

        XCTAssertEqual(project.id, "app_id_123")
        XCTAssertEqual(project.name, "My Project")
        XCTAssertEqual(project.vendorKey, "app_id_123")
        XCTAssertEqual(project.signKey, "cert_456")
        XCTAssertEqual(project.status, "active")
        XCTAssertEqual(project.created, 1637153755)
    }

    func testDisabledProjectMapping() {
        let raw = AgoraAPIProject(
            id: "p2",
            name: "Disabled",
            vendor_key: "vk2",
            sign_key: "sk2",
            recording_server: nil,
            status: 0,
            created: 1700000000
        )

        let status = raw.status == 1 ? "active" : "disabled"
        XCTAssertEqual(status, "disabled")
    }

    // MARK: - AgoraAPIError

    func testErrorDescriptions() {
        XCTAssertEqual(
            AgoraAPIError.noCredentials.errorDescription,
            "No Agora credentials configured. Open Settings to add them."
        )
        XCTAssertEqual(
            AgoraAPIError.httpError(401).errorDescription,
            "Agora API returned HTTP 401"
        )
        XCTAssertTrue(
            AgoraAPIError.decodingError("bad format").errorDescription!.contains("bad format")
        )
    }

    // MARK: - AgoraProject Codable round-trip

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
