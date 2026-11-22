import Foundation
import XCTest
@testable import AstationRemote

private actor DirectoryHTTP: AccountOIDCHTTP {
    private var replies: [(Data, Int)]
    private var requests: [URLRequest] = []
    private let cancelAtRequest: Int?

    init(_ replies: [(Data, Int)], cancelAtRequest: Int? = nil) {
        self.replies = replies; self.cancelAtRequest = cancelAtRequest
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if requests.count == cancelAtRequest { withUnsafeCurrentTask { $0?.cancel() } }
        guard !replies.isEmpty else { throw AccountLoginError.unavailable }
        return replies.removeFirst()
    }
    func sent() -> [URLRequest] { requests }
}

final class PortalStationDirectoryTests: XCTestCase {
    private func example() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "portal-station-directory",
            withExtension: "json", subdirectory: "Fixtures")))
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: example()) as? [String: Any])
    }

    private func page(id: String, cursor: String? = nil, stale: Bool = false) throws -> Data {
        var value = try object()
        var row = try XCTUnwrap((value["stations"] as? [[String: Any]])?.first)
        row["id"] = id
        value["stations"] = [row]
        value["nextCursor"] = cursor as Any? ?? NSNull()
        value["stale"] = stale
        value["complete"] = cursor == nil && !stale
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func client(_ http: DirectoryHTTP, readOnly: Bool = false) throws -> PortalIntegrationHTTP {
        let configuration = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation",
            resource: "https://portal.example", requiredScope: "integrations:read",
            additionalScopes: readOnly ? [] : ["integrations:approve"])
        return try PortalIntegrationHTTP(configuration: configuration, portalOrigin: "https://portal.example",
            ownerAccount: "ab00000000000000000000000000", http: http, accessToken: { "native-test-access" })
    }

    func testPortal42ExampleKeepsBuiltInOwnedEndedAndRemovedStations() throws {
        let directory = try PortalStationDirectoryPage.decode(example())
        XCTAssertTrue(directory.complete)
        XCTAssertFalse(directory.stale)
        XCTAssertNil(directory.nextCursor)
        XCTAssertEqual(directory.stations.count, 4)
        XCTAssertEqual(directory.stations.map(\.role), ["built_in", "owner", "member", "owner"])
        XCTAssertEqual(directory.stations.map(\.availableForIntegrations), [true, true, false, false])
        XCTAssertEqual(directory.stations[2].membership, "ended")
        XCTAssertEqual(directory.stations[2].membershipEndedAt, "2026-11-20T09:15:00.000Z")
        XCTAssertEqual(directory.stations[3].status, "removed")
        XCTAssertEqual(directory.stations[3].removedAt, "2026-11-21T14:30:12.044Z")
    }

    func testStrictPageReaderRefusesAmbiguousIncompleteOrExpandedShapes() throws {
        let data = try example()
        let text = String(decoding: data, as: UTF8.self)
        for mutation in [text.replacingOccurrences(of: "\"complete\": true", with: "\"complete\": true, \"complete\": true"),
            text.replacingOccurrences(of: "\"complete\": true", with: "\"complete\": true, \"comple\\u0074e\": true"),
            text.replacingOccurrences(of: "\"builtIn\": true", with: "\"builtIn\": true, \"builtIn\": true"),
            text.replacingOccurrences(of: "\"stale\": false", with: "\"stale\": 0"),
            text.replacingOccurrences(of: "\"complete\": true", with: "\"complete\": 1"),
            text.replacingOccurrences(of: "\"name\": \"Agora Station\",", with: ""),
            text.replacingOccurrences(of: "\"role\": \"owner\"", with: "\"role\": null"),
            text.replacingOccurrences(of: "\"stale\": false", with: "\"stale\": false, \"extra\": null"),
            text.replacingOccurrences(of: "\"role\": \"owner\"", with: "\"role\": \"owner\", \"authority\": true")] {
            XCTAssertNotEqual(mutation, text)
            XCTAssertThrowsError(try PortalStationDirectoryPage.decode(Data(mutation.utf8)))
        }
        XCTAssertThrowsError(try PortalStationDirectoryPage.decode(Data(repeating: 32, count: 262_145)))
        XCTAssertThrowsError(try PortalStationDirectoryPage.decode(data, limit: 3))
    }

    func testInconsistentAccessStatusOriginsAndContinuationAreRefused() throws {
        let original = try object()
        let rowChanges: [(String, Any)] = [("origin", "https://station-dev.agora.build/"), ("origin", "http://station.example"),
            ("origin", "https://other.example/path"), ("id", "bad id"), ("builtIn", 1),
            ("access", "members"), ("role", "owner"), ("status", "suspended"), ("status", "removed"),
            ("removedAt", "2026-11-21T14:30:12.044Z"), ("membership", "current"),
            ("createdAt", "bad"), ("name", "bad\nname")]
        for (key, replacement) in rowChanges {
            var value = original
            var rows = try XCTUnwrap(value["stations"] as? [[String: Any]])
            rows[0][key] = replacement; value["stations"] = rows
            XCTAssertThrowsError(try PortalStationDirectoryPage.decode(JSONSerialization.data(withJSONObject: value)), key)
        }
        for (key, replacement): (String, Any) in [("nextCursor", "next_page"), ("nextCursor", ""),
            ("nextCursor", "../other"), ("stale", true)] {
            var value = original; value[key] = replacement
            XCTAssertThrowsError(try PortalStationDirectoryPage.decode(JSONSerialization.data(withJSONObject: value)), key)
        }
        var duplicate = original
        let rows = try XCTUnwrap(original["stations"] as? [[String: Any]])
        duplicate["stations"] = [rows[0], rows[0]]
        XCTAssertThrowsError(try PortalStationDirectoryPage.decode(JSONSerialization.data(withJSONObject: duplicate)))
    }

    func testNativeBearerTraversesOnlyTheVersionedPortalAPIAndPreservesLostStations() async throws {
        let http = DirectoryHTTP([(try page(id: "first", cursor: "opaque_next"), 200), (try example(), 200)])
        let directory = try await client(http, readOnly: true).stationDirectory()
        XCTAssertTrue(directory.complete)
        XCTAssertEqual(directory.stations.count, 5)
        XCTAssertEqual(directory.stations.last?.status, "removed")
        let sent = await http.sent()
        XCTAssertEqual(sent.count, 2)
        for request in sent {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "portal.example")
            XCTAssertEqual(request.url?.path, "/api/v1/stations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-test-access")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
        }
        let query = URLComponents(url: try XCTUnwrap(sent[1].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "100")
        XCTAssertEqual(query?.first(where: { $0.name == "cursor" })?.value, "opaque_next")
    }

    func testAStaleOrExplicitlyIncompleteTailNeverBecomesComplete() async throws {
        for stale in [false, true] {
            var tail = try object(); tail["stale"] = stale; tail["complete"] = false
            let http = DirectoryHTTP([(try page(id: "first", cursor: "next"), 200),
                (try JSONSerialization.data(withJSONObject: tail), 200)])
            let directory = try await client(http).stationDirectory()
            XCTAssertFalse(directory.complete)
            XCTAssertEqual(directory.stale, stale)
            XCTAssertEqual(directory.stations.count, 5)
        }
    }

    func testMissingRefusedCyclicOrConflictingPagesNeverReturnASuccessfulPrefix() async throws {
        for status in [401, 403, 404, 429, 503] {
            let http = DirectoryHTTP([(try page(id: "first", cursor: "next"), 200), (Data("{}".utf8), status)])
            do { _ = try await client(http).stationDirectory(); XCTFail("accepted status \(status)") } catch {}
            let sent = await http.sent()
            XCTAssertEqual(sent.count, 2, "no cookie, production-origin or unversioned fallback")
        }
        let missing = DirectoryHTTP([(try page(id: "first", cursor: "next"), 200)])
        do { _ = try await client(missing).stationDirectory(); XCTFail("returned prefix after lost reply") } catch {}
        for last in [try page(id: "second", cursor: "next"), try page(id: "first")] {
            let http = DirectoryHTTP([(try page(id: "first", cursor: "next"), 200), (last, 200)])
            do { _ = try await client(http).stationDirectory(); XCTFail("accepted cycle or repeated identity") } catch {}
        }
    }

    func testInvalidRequestSelectorsNeverAcquireATokenOrCallHTTP() async throws {
        let http = DirectoryHTTP([])
        let config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation",
            resource: "https://portal.example", requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
        let portal = try PortalIntegrationHTTP(configuration: config, portalOrigin: "https://portal.example",
            ownerAccount: "ab00000000000000000000000000", http: http, accessToken: {
                XCTFail("invalid input reached token acquisition"); return "unused"
            })
        for (cursor, limit) in [(nil, 0), (nil, 101), (Optional(""), 100), (Optional("bad/cursor"), 100)] {
            do { _ = try await portal.stations(cursor: cursor, limit: limit); XCTFail() } catch {}
        }
        let sent = await http.sent()
        XCTAssertTrue(sent.isEmpty)
    }

    func testReadOnlyDirectoryAuthorizationCannotMutateAnIntegration() async throws {
        let http = DirectoryHTTP([])
        let config = try AccountOIDCConfiguration(issuer: "https://auth.example", clientID: "astation",
            resource: "https://portal.example", requiredScope: "integrations:read")
        let portal = try PortalIntegrationHTTP(configuration: config, portalOrigin: "https://portal.example",
            ownerAccount: "ab00000000000000000000000000", http: http, accessToken: {
                XCTFail("read-only mutation reached token acquisition"); return "unused"
            })
        let mirror = try RemoteControlPortalMirror(issuer: config.issuer, ownerAccount: portal.ownerAccount,
            stationOrigin: "https://station.example", integrationID: "i-00000000000000000000000000", interruptRunning: false)
        do { _ = try await portal.mirrorRevoke(mirror); XCTFail("read-only client attempted mutation") }
        catch { XCTAssertEqual(error as? AccountLoginError, .configuration) }
        let sent = await http.sent()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTraversalBoundsRefuseAnEndlessOrOversizedDirectoryWithoutReturningAPrefix() async throws {
        var template = try object()
        let row = try XCTUnwrap((template["stations"] as? [[String: Any]])?.first)
        for tailCount in [96, 97] {
            var replies: [(Data, Int)] = []
            for index in 0..<41 {
                template["stations"] = (0..<(index == 40 ? tailCount : 100)).map { offset in
                    var entry = row; entry["id"] = "station-\(index)-\(offset)"; return entry
                }
                template["nextCursor"] = index == 40 ? NSNull() : "page_\(index)" as Any
                template["complete"] = index == 40
                replies.append((try JSONSerialization.data(withJSONObject: template), 200))
            }
            let http = DirectoryHTTP(replies)
            do {
                let result = try await client(http).stationDirectory()
                XCTAssertEqual(tailCount, 96, "oversized traversal returned a prefix")
                XCTAssertEqual(result.stations.count, 4_096)
                XCTAssertTrue(result.complete)
            } catch {
                XCTAssertEqual(tailCount, 97)
                XCTAssertEqual(error as? AccountLoginError, .invalidResponse)
            }
            let sent = await http.sent()
            XCTAssertEqual(sent.count, 41)
        }
        let endless = DirectoryHTTP(try (0..<42).map {
            (try page(id: "station-\($0)", cursor: "page_\($0)"), 200)
        })
        do { _ = try await client(endless).stationDirectory(); XCTFail("endless traversal returned metadata") }
        catch { XCTAssertEqual(error as? AccountLoginError, .invalidResponse) }
        let sent = await endless.sent()
        XCTAssertEqual(sent.count, 41)
    }

    func testCancellationAfterAPageResponseDoesNotCommitThatPageOrContinue() async throws {
        let http = DirectoryHTTP([(try page(id: "first", cursor: "next"), 200), (try example(), 200)], cancelAtRequest: 1)
        let portal = try client(http)
        let operation = Task { try await portal.stationDirectory() }
        do { _ = try await operation.value; XCTFail("cancelled reply returned metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sent = await http.sent()
        XCTAssertEqual(sent.count, 1)
    }

    func testCancellationStopsBeforeFetchingAnotherDirectoryPage() async throws {
        let http = DirectoryHTTP([(try example(), 200)]), portal = try client(http)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await portal.stationDirectory()
        }
        do { _ = try await operation.value; XCTFail("cancelled traversal returned metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sent = await http.sent()
        XCTAssertTrue(sent.isEmpty)
    }
}
