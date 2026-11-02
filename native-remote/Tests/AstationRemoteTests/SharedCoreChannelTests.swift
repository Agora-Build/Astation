import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

final class SharedCoreChannelTests: XCTestCase {
    private struct Vectors: Decodable {
        let account_id: String
        let genesis_hash: String
    }

    @MainActor
    func testSuppliedCoreVerifiesLogStartsChannelAndRejectsMalformedAccept() throws {
        // Public signed vector prefix: no software key provider or live identity is used.
        let url = Bundle.module.url(forResource: "membership-prefix", withExtension: "json", subdirectory: "Fixtures")!
        let bytes = try Data(contentsOf: url)
        let vectors = try JSONDecoder().decode(Vectors.self, from: bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let raw = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), as: UTF8.self) }
        let log = try MembershipLog.verify(accountId: vectors.account_id, genesisHash: vectors.genesis_hash,
                                           entries: raw, now: HostClock(wallMs: 1_792_400_003_000, monoMs: 100, bootId: "test-boot"))
        let route = try RemoteChannelRoute(linkGeneration: UUID(), handle: "real-core")
        var sent: [Data] = []
        var closes = 0
        var signatures = 0
        let channel = try RemoteAgentChannel(route: route, hostID: "host-a",
            identity: ClientIdentity(kind: .native, deviceId: "dev-phone", keyId: "phone-key", grantJson: nil),
            log: log, clock: { 100 }, sign: { _ in signatures += 1; return Data() },
            send: { _, frame in sent.append(frame) }, close: { _ in closes += 1 }, observe: { _ in })
        try channel.start()
        let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
        XCTAssertEqual(frame["ch"] as? String, "atem-ch1")
        XCTAssertEqual(frame["op"] as? String, "init")
        XCTAssertEqual(channel.phase, .awaitingAccept)
        channel.receive(Data("{}".utf8), from: route)
        XCTAssertEqual(channel.phase, .closed)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(signatures, 0)
        XCTAssertEqual(sent.count, 1)
        channel.disconnect()
        XCTAssertEqual(closes, 1)
        XCTAssertThrowsError(try channel.perform(.list))

        let tampered = raw.enumerated().map { index, entry in
            index == 2 ? entry.replacingOccurrences(of: "dev-phone", with: "attacker") : entry
        }
        XCTAssertThrowsError(try MembershipLog.verify(accountId: vectors.account_id, genesisHash: vectors.genesis_hash,
            entries: tampered, now: HostClock(wallMs: 1_792_400_003_000, monoMs: 100, bootId: "test-boot")))
    }
}
