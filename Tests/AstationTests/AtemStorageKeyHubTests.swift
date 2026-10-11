import XCTest
@testable import Menubar

@MainActor
final class AtemStorageKeyHubTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testHubProcessesEscrowAbandonRotateAndConfirmInArrivalOrder() async throws {
        let f = try AtemStorageFixture(), account = AstationIdentity.shared.id
        _ = try f.identity.completeVerification(account: account, deviceId: f.deviceId, reveal: AtemVerifyReveal(
            devicePub: f.device.publicKey.rawRepresentation, deviceSignPub: f.signing.publicKey.rawRepresentation,
            unlockAuthPub: f.unlockAuth.publicKey.rawRepresentation, nonce: Data(repeating: 4, count: 32)
        ), transcript: Data(repeating: 9, count: 32), expectedSigningKey: f.keys.signPub, key: nil)
        let hub = AstationHubManager(skipProjectLoad: true, atemE2EIdentity: f.identity)
        let client = ConnectedClient(id: UUID().uuidString, clientType: "Atem", connectedAt: Date(), hostname: "Fixture", atemId: f.deviceId)
        hub.connectedClients = [client]
        var replies: [(AstationMessage, String)] = []
        hub.sendHandler = { replies.append(($0, $1)) }
        for message in [
            AstationMessage.storageKeyRotate(try f.rotate(account: account)),
            .storageKeyAbandon(abandon: try f.settlement(abandon: true, account: account)),
            .storageKeyRotate(try f.rotate(new: "4e5f6a7b", account: account)),
            .storageKeyConfirm(confirm: try f.settlement(kid: "4e5f6a7b", account: account)),
        ] { XCTAssertNil(hub.handleMessage(message, from: client.id)) }
        await drainMainQueue()
        XCTAssertEqual(replies.count, 2)
        for (message, id) in replies {
            guard case .storageKeyAck = message else { return XCTFail("Expected an escrow ack") }
            XCTAssertEqual(id, client.id)
        }
        let status = try f.identity.storageKeyStatus(account: account, deviceId: f.deviceId)
        XCTAssertEqual(status?.currentKid, "4e5f6a7b")
        XCTAssertNil(status?.pendingKid)
    }

    func testHubIgnoresUnregisteredConnectionsAndDeniesMalformedAuthenticatedRequests() async throws {
        let f = try AtemStorageFixture(), before = f.storage.data
        let hub = AstationHubManager(skipProjectLoad: true, atemE2EIdentity: f.identity)
        var replies: [AstationMessage] = []
        hub.sendHandler = { message, _ in replies.append(message) }
        let invalid = AstationMessage.unlockRequest(AtemUnlockRequestWire(request: Data(), signature: Data()))
        _ = hub.handleMessage(invalid, from: "missing-client")
        await drainMainQueue()
        XCTAssertTrue(replies.isEmpty)
        let client = ConnectedClient(id: UUID().uuidString, clientType: "Atem", connectedAt: Date(), atemId: f.deviceId)
        hub.connectedClients = [client]
        _ = hub.handleMessage(invalid, from: client.id)
        await drainMainQueue()
        XCTAssertEqual(replies.count, 1)
        guard case .unlockDenied = replies[0] else { return XCTFail("Expected an unlock denial") }
        XCTAssertEqual(f.storage.data, before)
    }
}
