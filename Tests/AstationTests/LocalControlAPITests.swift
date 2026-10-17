import Foundation
import NIOHTTP1
import XCTest
@testable import Menubar

final class LocalControlAPITests: XCTestCase {
    func testKeyRequiresPrivateSameUserRegularFileAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("api-token")
        try Data(String(repeating: "ab", count: 32).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalAPIKey(file: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNoThrow(try LocalAPIKey(file: file.path))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try LocalAPIKey(file: link.path))
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try LocalAPIKey(file: file.path))
    }

    func testAdmissionRequiresBearerLoopbackAndNoBrowserOrigin() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let token = String(repeating: "ab", count: 32)
        try Data(token.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let key = try LocalAPIKey(file: file.path)
        var request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/api/v1/status")
        XCTAssertFalse(key.authorizes(request, peerAddress: "127.0.0.1"))
        request.headers.add(name: "Authorization", value: "Bearer " + token)
        XCTAssertTrue(key.authorizes(request, peerAddress: "127.0.0.1"))
        XCTAssertTrue(key.authorizes(request, peerAddress: "::1"))
        XCTAssertFalse(key.authorizes(request, peerAddress: "192.168.1.10"))
        XCTAssertFalse(key.authorizes(request, peerAddress: nil))
        request.headers.add(name: "Origin", value: "https://example.test")
        XCTAssertFalse(key.authorizes(request, peerAddress: "127.0.0.1"))
        request.headers.remove(name: "Origin")
        request.headers.add(name: "Authorization", value: "Bearer " + token)
        XCTAssertFalse(key.authorizes(request, peerAddress: "127.0.0.1"))
    }
}
