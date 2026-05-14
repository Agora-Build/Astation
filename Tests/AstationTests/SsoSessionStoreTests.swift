import XCTest
@testable import Menubar

final class SsoSessionTests: XCTestCase {
    func testNeedsRefreshWhenWithin60s() {
        let now = UInt64(Date().timeIntervalSince1970)
        let s = SsoSession(accessToken: "a", refreshToken: "r", expiresAt: now + 30, loginId: nil)
        XCTAssertTrue(s.needsRefresh())
    }

    func testDoesNotNeedRefreshWhenPlenty() {
        let now = UInt64(Date().timeIntervalSince1970)
        let s = SsoSession(accessToken: "a", refreshToken: "r", expiresAt: now + 3600, loginId: nil)
        XCTAssertFalse(s.needsRefresh())
    }

    func testCodableRoundTrip() throws {
        let s = SsoSession(accessToken: "acc", refreshToken: "ref", expiresAt: 1_700_000_000, loginId: "u@a.io")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SsoSession.self, from: data)
        XCTAssertEqual(back.accessToken, "acc")
        XCTAssertEqual(back.refreshToken, "ref")
        XCTAssertEqual(back.expiresAt, 1_700_000_000)
        XCTAssertEqual(back.loginId, "u@a.io")
    }
}

final class SsoSessionStoreTests: XCTestCase {
    private func tempPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SsoSessionStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.enc")
    }

    func testLoadReturnsNilWhenFileMissing() {
        let store = SsoSessionStore(storageURL: tempPath())
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasSession)
    }

    func testSaveAndLoadRoundTrip() throws {
        let path = tempPath()
        let store = SsoSessionStore(storageURL: path)
        let s = SsoSession(accessToken: "acc", refreshToken: "ref", expiresAt: 123, loginId: "u")
        try store.save(s)
        XCTAssertTrue(store.hasSession)

        let store2 = SsoSessionStore(storageURL: path)
        XCTAssertEqual(store2.load(), s)
    }

    func testFilePermissionsAre0600() throws {
        let path = tempPath()
        let store = SsoSessionStore(storageURL: path)
        try store.save(SsoSession(accessToken: "a", refreshToken: "r", expiresAt: 1, loginId: nil))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testCorruptedFileReturnsNil() throws {
        let path = tempPath()
        try Data("not valid ciphertext".utf8).write(to: path)
        let store = SsoSessionStore(storageURL: path)
        XCTAssertNil(store.load())
    }

    func testOldShapeFileIsDeletedAndReturnsNil() throws {
        let path = tempPath()
        // Build a valid AES-GCM ciphertext for old-shape JSON.
        let oldJson = #"{"customerId":"abc","customerSecret":"xyz"}"#.data(using: .utf8)!
        let store = SsoSessionStore(storageURL: path)
        let cipher = try store._testEncrypt(oldJson)
        try cipher.write(to: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                       "old-shape file should be deleted by load()")
    }

    func testDeleteRemovesFile() throws {
        let path = tempPath()
        let store = SsoSessionStore(storageURL: path)
        try store.save(SsoSession(accessToken: "a", refreshToken: "r", expiresAt: 1, loginId: nil))
        try store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
