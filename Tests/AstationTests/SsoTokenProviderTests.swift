import XCTest
@testable import Menubar

/// Minimal in-memory store conforming to a protocol that SsoTokenProvider talks to.
private final class FakeStore: SsoSessionStoring {
    var session: SsoSession?
    var loadCalls = 0
    var saveCalls = 0
    var deleteCalls = 0
    func load() -> SsoSession? { loadCalls += 1; return session }
    func save(_ s: SsoSession) throws { saveCalls += 1; session = s }
    func delete() throws { deleteCalls += 1; session = nil }
    var hasSession: Bool { session != nil }
}

private final class FakeRefresher: SsoTokenRefreshing {
    var nextResult: Result<SsoSession, Error> = .failure(SsoError.refreshFailed("not set"))
    var calls = 0
    func refresh(refreshToken: String, ssoUrl: String) async throws -> SsoSession {
        calls += 1
        return try nextResult.get()
    }
}

final class SsoTokenProviderTests: XCTestCase {
    func testReturnsAccessTokenWithoutRefreshIfFresh() async throws {
        let store = FakeStore()
        store.session = SsoSession(
            accessToken: "FRESH",
            refreshToken: "ref",
            expiresAt: SsoSession.nowSecs() + 3600,
            loginId: "u"
        )
        let refresher = FakeRefresher()
        let p = SsoTokenProvider(store: store, refresher: refresher, ssoUrl: { "https://sso2.agora.io" })
        let token = try await p.validToken()
        XCTAssertEqual(token, "FRESH")
        XCTAssertEqual(refresher.calls, 0)
    }

    func testRefreshesWhenNearExpiry() async throws {
        let store = FakeStore()
        store.session = SsoSession(
            accessToken: "OLD",
            refreshToken: "old_ref",
            expiresAt: SsoSession.nowSecs() + 30,  // < 60s buffer
            loginId: "u"
        )
        let refresher = FakeRefresher()
        refresher.nextResult = .success(SsoSession(
            accessToken: "NEW",
            refreshToken: "new_ref",
            expiresAt: SsoSession.nowSecs() + 3600,
            loginId: "u"
        ))
        let p = SsoTokenProvider(store: store, refresher: refresher, ssoUrl: { "https://sso2.agora.io" })
        let token = try await p.validToken()
        XCTAssertEqual(token, "NEW")
        XCTAssertEqual(refresher.calls, 1)
        XCTAssertEqual(store.session?.accessToken, "NEW")
        XCTAssertEqual(store.session?.refreshToken, "new_ref")
    }

    func testThrowsNotSignedInWhenStoreEmpty() async {
        let store = FakeStore()
        let refresher = FakeRefresher()
        let p = SsoTokenProvider(store: store, refresher: refresher, ssoUrl: { "https://sso2.agora.io" })
        do {
            _ = try await p.validToken()
            XCTFail("expected notSignedIn")
        } catch SsoError.notSignedIn {
            // ok
        } catch {
            XCTFail("expected notSignedIn, got \(error)")
        }
    }

    func testDeletesSessionAndThrowsOnRefreshFailure() async {
        let store = FakeStore()
        store.session = SsoSession(
            accessToken: "old",
            refreshToken: "ref",
            expiresAt: 1,                              // already expired
            loginId: nil
        )
        let refresher = FakeRefresher()
        refresher.nextResult = .failure(SsoError.refreshFailed("invalid_grant"))
        let p = SsoTokenProvider(store: store, refresher: refresher, ssoUrl: { "https://sso2.agora.io" })
        do {
            _ = try await p.validToken()
            XCTFail("expected throw")
        } catch {
            // expected
        }
        XCTAssertNil(store.session, "session should be cleared after refresh failure")
        XCTAssertEqual(store.deleteCalls, 1)
    }
}
