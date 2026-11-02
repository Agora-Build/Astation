import CryptoKit
import Foundation
import XCTest
@testable import AstationRemote

private final class CheckpointBackend: RecoveryCheckpointBackend {
    var bytes: Data?
    var failAfterWrite = false
    var beforeWrite: (() throws -> Void)?
    var creates = 0
    var updates = 0
    func read() throws -> Data? { bytes }
    func write(_ data: Data, creating: Bool) throws {
        try beforeWrite?()
        if creating { creates += 1 } else { updates += 1 }
        bytes = data
        if failAfterWrite { throw RemoteRecoveryError.storageUncertain }
    }
}

final class RemoteRecoveryStoreTests: XCTestCase {
    @MainActor
    func testDifferentRecoveryOperationsCannotOwnTheSameAccountConcurrently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteRecoveryStore(name: "bootstrap:account-a", directory: directory,
            backend: CheckpointBackend(), lockName: "account-a")
        XCTAssertThrowsError(try RemoteRecoveryStore(name: "backup:account-a", directory: directory,
            backend: CheckpointBackend(), lockName: "account-a"))
        XCTAssertNil(try store.read())
    }
    @MainActor
    func testProcessOwnershipAndAtomicCreateThenUpdateSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CheckpointBackend()
        var store: RemoteRecoveryStore? = try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend)
        XCTAssertNil(try store?.read())
        try store?.write(Data([1]))
        try store?.write(Data([2]))
        XCTAssertEqual(backend.creates, 1)
        XCTAssertEqual(backend.updates, 1)
        XCTAssertThrowsError(try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend))
        store = nil
        let resumed = try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend)
        XCTAssertEqual(try resumed.read(), Data([2]))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: files[0]), Data(), "The lock file contains no recovery material")
    }

    @MainActor
    func testUncertainWriteMustReloadEvenWhenTheBytesReachedTheBackend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CheckpointBackend()
        var store: RemoteRecoveryStore? = try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend)
        backend.failAfterWrite = true
        XCTAssertThrowsError(try store?.write(Data([3])))
        XCTAssertEqual(store?.storageUncertain, true)
        XCTAssertThrowsError(try store?.read())
        XCTAssertThrowsError(try store?.write(Data([4])))
        store = nil
        backend.failAfterWrite = false
        let resumed = try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend)
        XCTAssertEqual(try resumed.read(), Data([3]))
    }

    @MainActor
    func testOutOfBandChangeAndReentrantWritesCannotOverwriteTheCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CheckpointBackend()
        let store = try RemoteRecoveryStore(name: "account-a", directory: directory, backend: backend)
        backend.beforeWrite = { XCTAssertThrowsError(try store.write(Data([8]))) }
        try store.write(Data([1]))
        backend.bytes = Data([2])
        XCTAssertThrowsError(try store.write(Data([3])))
        XCTAssertEqual(backend.bytes, Data([2]))
        XCTAssertTrue(store.storageUncertain)
    }

    @MainActor
    func testSymlinkLockIsRefusedWithoutTouchingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data([5]).write(to: target)
        let hash = SHA256.hash(data: Data("account-a".utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(hash + ".lock"), withDestinationURL: target)
        XCTAssertThrowsError(try RemoteRecoveryStore(name: "account-a", directory: directory, backend: CheckpointBackend()))
        XCTAssertEqual(try Data(contentsOf: target), Data([5]))
    }
}
