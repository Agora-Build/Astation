# Astation SSO2 Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Astation's customer_id/secret credential entry with OAuth 2.0 + PKCE login against `sso2.agora.io` (same flow as Atem), switch Astation's API calls to Bearer/BFF, switch ConvoAI to `agora token=<rtc_token>`, and repurpose the `credentialSync` WebSocket message to carry SSO tokens (with matching Atem-side migration).

**Architecture:** New `SsoSession`, `SsoSessionStore`, `SsoAuthManager`, and `SsoTokenProvider` files replace `CredentialManager` + `AgoraCredentials`. `AgoraAPIClient` hits `agora-cli.agora.io/api/cli/v1/projects` with Bearer; `ConvoAIClient` mints an RTC dynamic token and uses `Authorization: agora token=<token>`. `AstationMessage.credentialSync` payload swaps to `{access_token, refresh_token, expires_at, login_id, astation_id, save_credentials}`. Atem's `CredentialSync` struct, its pair-flow match arm, and the TUI dispatch site all migrate to the new payload; the now-redundant `SsoTokenSync` variant is removed. Settings UI gets an "Agora Account" section (Sign in with Agora / Signed in as …); the menubar gets a mirrored entry.

**Tech Stack:** Swift 5.9, SwiftNIO (already a dep — used for the loopback OAuth callback listener), Apple `CryptoKit` (AES-GCM + HKDF + SHA-256 + random bytes), `URLSession`, `NSWorkspace.open` for browser launch. Atem side: Rust + serde.

**Spec:** `docs/superpowers/specs/2026-05-13-astation-sso2-login-design.md`

---

## File Structure

**New (Swift):**
- `Sources/Menubar/SsoSession.swift` — `SsoSession` value type + `SsoError` enum.
- `Sources/Menubar/SsoSessionStore.swift` — encrypted single-entry store (replaces `CredentialManager`).
- `Sources/Menubar/SsoAuthManager.swift` — PKCE, loopback HTTP1 listener, browser open, token exchange.
- `Sources/Menubar/SsoTokenProvider.swift` — actor with `validToken()` (lazy refresh).
- `Sources/Menubar/SsoConfig.swift` — single source of `currentSsoUrl` / `currentBffUrl` (mirrors the existing `currentAstationRelayUrl` pattern).

**New (tests):**
- `Tests/AstationTests/SsoSessionStoreTests.swift`
- `Tests/AstationTests/SsoAuthManagerTests.swift`
- `Tests/AstationTests/SsoTokenProviderTests.swift`
- `Tests/AstationTests/SsoMessageTests.swift` — new `credentialSync` codable round-trip.

**Deleted:**
- `Sources/Menubar/CredentialManager.swift` — replaced by `SsoSessionStore`.

**Modified (Swift):**
- `Sources/Menubar/AstationMessage.swift` — `credentialSync` payload swap + keys.
- `Sources/Menubar/AgoraAPIClient.swift` — Bearer + BFF endpoint + new mapping.
- `Sources/Menubar/ConvoAIClient.swift` — `agora token=<rtc_token>` Authorization.
- `Sources/Menubar/AstationHubManager.swift` — own `SsoTokenProvider`, rewire `broadcastCredentials` / `sendCredentials`, `loadProjects`, `generateTokenForConvoAIAgent` callers.
- `Sources/Menubar/VoiceCodingManager.swift` — pass `appCertificate` instead of credentials.
- `Sources/Menubar/SettingsWindowController.swift` — replace customer_id/secret section with "Agora Account".
- `Sources/Menubar/StatusBarController.swift` — add "Sign in with Agora…" menu item (mirrors state).
- `Tests/AstationTests/VoiceCodingTests.swift` — drop the `AgoraCredentials` reference.
- `Tests/AstationTests/AgoraAPIClientTests.swift` — adjust to new BFF mapping.

**Modified (Atem, Rust):**
- `Atem/src/websocket_client.rs` — `CredentialSync` payload swap, remove `SsoTokenSync` variant, rewrite credential_sync tests, delete sso_token_sync tests.
- `Atem/src/cli.rs` — pair-flow match arm renamed `SsoTokenSync` → `CredentialSync`.
- `Atem/src/app.rs` — TUI dispatch match arm renamed `SsoTokenSync` → `CredentialSync`.

---

## Conventions

- Commit message footer: `🤖 Built with SMT <smt@agora.build>` (per `~/.claude/CLAUDE.md`).
- Run Astation Swift tests: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter <TestName>`
- Run Atem Rust tests: `cd /home/guohai/Dev/Agora.Build/Atem && cargo test <test_name>`
- Build Astation: `cd /home/guohai/Dev/Agora.Build/Astation && swift build` (the C++ core must be built once via `mkdir -p build && cd build && cmake .. -DBUILD_TESTING=ON && make` — assume that's already done by the developer).
- All new Swift files start with `import Foundation` (no UI imports unless needed).

---

## Task 1: Add `SsoSession` value type

**Files:**
- Create: `Sources/Menubar/SsoSession.swift`
- Create: `Tests/AstationTests/SsoSessionStoreTests.swift` (stub file with the round-trip test added in Task 2)

- [ ] **Step 1: Write the failing test**

Create `Tests/AstationTests/SsoSessionStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoSessionTests`
Expected: build error "cannot find 'SsoSession' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Menubar/SsoSession.swift`:

```swift
import Foundation

/// One SSO session — what Astation persists after `Sign in with Agora`.
struct SsoSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: UInt64        // unix seconds (when the access token expires)
    var loginId: String?         // human-readable identifier returned by SSO

    /// True when the access token is within 60s of expiry (or already expired).
    func needsRefresh() -> Bool {
        expiresAt < Self.nowSecs() + 60
    }

    static func nowSecs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case loginId = "login_id"
    }
}

/// Errors raised by the SSO subsystem. Surfaced verbatim in the UI.
enum SsoError: Error, LocalizedError, Equatable {
    case notSignedIn
    case loopbackBindFailed(String)
    case browserOpenFailed
    case timeout
    case stateMismatch
    case tokenExchangeFailed(status: Int, body: String)
    case refreshFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in. Open Settings → Sign in with Agora."
        case .loopbackBindFailed(let s): return "Could not bind loopback listener: \(s)"
        case .browserOpenFailed: return "Could not open browser."
        case .timeout: return "Login timed out."
        case .stateMismatch: return "OAuth state mismatch — try signing in again."
        case .tokenExchangeFailed(let st, let body): return "Token exchange failed (\(st)): \(body)"
        case .refreshFailed(let s): return "Token refresh failed: \(s)"
        case .network(let s): return "Network error: \(s)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoSessionTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoSession.swift Tests/AstationTests/SsoSessionStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add SsoSession value type and SsoError

First step toward replacing customer_id/secret with OAuth 2.0 + PKCE
login. Spec: docs/superpowers/specs/2026-05-13-astation-sso2-login-design.md.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 2: Add `SsoSessionStore` (replaces `CredentialManager`)

**Files:**
- Create: `Sources/Menubar/SsoSessionStore.swift`
- Modify: `Tests/AstationTests/SsoSessionStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AstationTests/SsoSessionStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoSessionStoreTests`
Expected: build error "cannot find 'SsoSessionStore' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Menubar/SsoSessionStore.swift`:

```swift
import Foundation
import CryptoKit

/// Encrypted single-entry SSO session store.
///
/// File format: AES-GCM combined blob (nonce + ciphertext + tag) of the
/// SsoSession JSON. Key is derived via HKDF/SHA-256 from the hardware UUID,
/// so the file cannot be decrypted on another machine.
///
/// Default path: ~/Library/Application Support/Astation/credentials.enc
final class SsoSessionStore {

    private let storageURL: URL
    private let symmetricKey: SymmetricKey

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageURL = appSupport
                .appendingPathComponent("Astation")
                .appendingPathComponent("credentials.enc")
        }

        let uuid = MachineIdentity.hardwareUUID()
        let ikm = SymmetricKey(data: Data(uuid.utf8))
        self.symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("com.agora.astation".utf8),
            info: Data("credentials".utf8),
            outputByteCount: 32
        )
    }

    var hasSession: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    func load() -> SsoSession? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        guard let data = try? Data(contentsOf: storageURL),
              let plain = try? decrypt(data) else {
            // Corrupt or different-machine ciphertext: treat as no session.
            return nil
        }
        if let session = try? JSONDecoder().decode(SsoSession.self, from: plain) {
            return session
        }
        // Old-shape file (customer_id/customer_secret): delete and return nil.
        if let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
           obj["customerId"] != nil || obj["customer_id"] != nil {
            try? FileManager.default.removeItem(at: storageURL)
            Log.info("[SSO] Deleted old-shape credentials file; please sign in again.")
        }
        return nil
    }

    func save(_ session: SsoSession) throws {
        let json = try JSONEncoder().encode(session)
        let cipher = try encrypt(json)

        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try cipher.write(to: storageURL)

        // 0600 permissions: owner read/write only.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: storageURL.path
        )
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }

    // MARK: - Test hook

    /// Encrypt arbitrary bytes with this store's key — only for tests that need
    /// to seed an "old-shape file" scenario. Not for production use.
    func _testEncrypt(_ plain: Data) throws -> Data {
        try encrypt(plain)
    }

    // MARK: - AES-GCM

    private func encrypt(_ plain: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: symmetricKey)
        guard let combined = sealed.combined else {
            throw SsoError.network("AES.GCM.seal returned nil combined")
        }
        return combined
    }

    private func decrypt(_ cipher: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: cipher)
        return try AES.GCM.open(box, using: symmetricKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoSessionStoreTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoSessionStore.swift Tests/AstationTests/SsoSessionStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add SsoSessionStore (AES-GCM, machine-bound)

Single-entry encrypted store for the SsoSession value type. Same path,
same encryption parameters as the soon-to-be-deleted CredentialManager,
but holds SSO tokens instead of customer_id/secret. Old-shape files are
detected on load() and deleted so the user gets a clean re-login path.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 3: Add `SsoConfig`

**Files:**
- Create: `Sources/Menubar/SsoConfig.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AstationTests/SsoSessionStoreTests.swift` (we keep small config tests there to avoid file fan-out):

```swift
final class SsoConfigTests: XCTestCase {
    func testDefaultSsoUrl() {
        // Clear UserDefaults + env to get the baked-in default.
        UserDefaults.standard.removeObject(forKey: SsoConfig.ssoUrlKey)
        unsetenv("ASTATION_SSO_URL")
        XCTAssertEqual(SsoConfig.currentSsoUrl, "https://sso2.agora.io")
    }

    func testDefaultBffUrl() {
        UserDefaults.standard.removeObject(forKey: SsoConfig.bffUrlKey)
        unsetenv("ASTATION_BFF_URL")
        XCTAssertEqual(SsoConfig.currentBffUrl, "https://agora-cli.agora.io")
    }

    func testEnvVarOverridesDefault() {
        setenv("ASTATION_SSO_URL", "https://sso-staging.example", 1)
        XCTAssertEqual(SsoConfig.currentSsoUrl, "https://sso-staging.example")
        unsetenv("ASTATION_SSO_URL")
    }

    func testUserDefaultsOverridesDefault() {
        unsetenv("ASTATION_BFF_URL")
        UserDefaults.standard.set("https://bff.example", forKey: SsoConfig.bffUrlKey)
        XCTAssertEqual(SsoConfig.currentBffUrl, "https://bff.example")
        UserDefaults.standard.removeObject(forKey: SsoConfig.bffUrlKey)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoConfigTests`
Expected: "cannot find 'SsoConfig'".

- [ ] **Step 3: Write the implementation**

Create `Sources/Menubar/SsoConfig.swift`:

```swift
import Foundation

/// Resolves SSO and BFF base URLs.
/// Priority: env var > UserDefaults > baked-in default.
/// Mirrors the existing pattern in SettingsWindowController.currentAstationRelayUrl.
enum SsoConfig {
    static let ssoUrlKey = "AstationSsoUrl"
    static let bffUrlKey = "AstationBffUrl"

    static let defaultSsoUrl = "https://sso2.agora.io"
    static let defaultBffUrl = "https://agora-cli.agora.io"

    static var currentSsoUrl: String {
        if let env = ProcessInfo.processInfo.environment["ASTATION_SSO_URL"], !env.isEmpty {
            return env
        }
        let saved = UserDefaults.standard.string(forKey: ssoUrlKey) ?? ""
        return saved.isEmpty ? defaultSsoUrl : saved
    }

    static var currentBffUrl: String {
        if let env = ProcessInfo.processInfo.environment["ASTATION_BFF_URL"], !env.isEmpty {
            return env
        }
        let saved = UserDefaults.standard.string(forKey: bffUrlKey) ?? ""
        return saved.isEmpty ? defaultBffUrl : saved
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoConfigTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoConfig.swift Tests/AstationTests/SsoSessionStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add SsoConfig for SSO + BFF URL resolution

env > UserDefaults > default, mirroring currentAstationRelayUrl.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 4: Add PKCE + state generators + callback parser (pure helpers)

**Files:**
- Modify: `Sources/Menubar/SsoSession.swift` (add a pure-helpers extension at the bottom — they belong with the SSO domain types)
- Create: `Tests/AstationTests/SsoAuthManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AstationTests/SsoAuthManagerTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Menubar

final class SsoPkceTests: XCTestCase {
    func testPkceVerifierIsBase64UrlOf32Bytes() {
        let (v, _) = SsoPkce.generate()
        // 32 bytes → base64url with no padding → 43 chars
        XCTAssertEqual(v.count, 43)
        XCTAssertFalse(v.contains("="))
        XCTAssertFalse(v.contains("+"))
        XCTAssertFalse(v.contains("/"))
    }

    func testChallengeIsSha256OfVerifier() {
        let (v, c) = SsoPkce.generate()
        let hash = SHA256.hash(data: Data(v.utf8))
        let computed = Data(hash).base64URLEncoded()
        XCTAssertEqual(c, computed)
    }

    func testStateIsUnique() {
        let a = SsoPkce.generateState()
        let b = SsoPkce.generateState()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }
}

final class SsoCallbackParserTests: XCTestCase {
    func testExtractsCodeAndState() {
        let r = SsoCallbackQuery.parse("code=mycode123&state=mystate456")
        XCTAssertEqual(r.code, "mycode123")
        XCTAssertEqual(r.state, "mystate456")
        XCTAssertEqual(r.loginId, "")
    }

    func testExtractsLoginId() {
        let r = SsoCallbackQuery.parse("code=abc&loginId=52a4f560&state=xyz")
        XCTAssertEqual(r.loginId, "52a4f560")
    }

    func testUrlDecodesValues() {
        let r = SsoCallbackQuery.parse("code=hello%20world&state=foo%2Bbar")
        XCTAssertEqual(r.code, "hello world")
        XCTAssertEqual(r.state, "foo+bar")
    }

    func testHandlesMissing() {
        let r = SsoCallbackQuery.parse("")
        XCTAssertEqual(r.code, "")
        XCTAssertEqual(r.state, "")
        XCTAssertEqual(r.loginId, "")
    }

    func testIgnoresExtras() {
        let r = SsoCallbackQuery.parse("session_state=ignored&code=abc&state=xyz&loginId=u&extra=x")
        XCTAssertEqual(r.code, "abc")
        XCTAssertEqual(r.state, "xyz")
        XCTAssertEqual(r.loginId, "u")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoPkceTests`
Expected: "cannot find 'SsoPkce'".

- [ ] **Step 3: Write the implementation**

Append to `Sources/Menubar/SsoSession.swift`:

```swift
import CryptoKit

/// PKCE verifier/challenge + state generator. Pure helpers — no I/O.
enum SsoPkce {
    /// Returns (verifier, challenge). Verifier is base64url(32 random bytes);
    /// challenge is base64url(SHA-256(verifier)).
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return (verifier, challenge)
    }

    /// 16 random bytes → base64url. Used for OAuth `state`.
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

/// Parsed OAuth callback query string.
struct SsoCallbackQuery: Equatable {
    let code: String
    let state: String
    let loginId: String

    /// `query` is the raw query string AFTER the `?` (no leading `?`).
    /// Missing fields come back as empty strings.
    static func parse(_ query: String) -> SsoCallbackQuery {
        var code = "", state = "", loginId = ""
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            switch key {
            case "code": code = value
            case "state": state = value
            case "loginId": loginId = value
            default: continue
            }
        }
        return SsoCallbackQuery(code: code, state: state, loginId: loginId)
    }
}

extension Data {
    /// base64url with no padding. RFC 7636-compatible.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoPkceTests && swift test --filter SsoCallbackParserTests`
Expected: 3 + 5 = 8 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoSession.swift Tests/AstationTests/SsoAuthManagerTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add PKCE generator, state generator, callback query parser

Pure helpers ported from Atem/src/sso_auth.rs. base64url encoder on Data
shared with future SSO code.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 5: Add `SsoTokenProvider` (lazy refresh actor)

**Files:**
- Create: `Sources/Menubar/SsoTokenProvider.swift`
- Create: `Tests/AstationTests/SsoTokenProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AstationTests/SsoTokenProviderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoTokenProviderTests`
Expected: "cannot find 'SsoTokenProvider'".

- [ ] **Step 3: Write the implementation**

Create `Sources/Menubar/SsoTokenProvider.swift`:

```swift
import Foundation

/// Storage abstraction the provider needs. SsoSessionStore conforms below.
protocol SsoSessionStoring: AnyObject {
    func load() -> SsoSession?
    func save(_ session: SsoSession) throws
    func delete() throws
    var hasSession: Bool { get }
}

extension SsoSessionStore: SsoSessionStoring {}

/// Refresh abstraction so tests can swap the network call.
protocol SsoTokenRefreshing: AnyObject {
    func refresh(refreshToken: String, ssoUrl: String) async throws -> SsoSession
}

/// Production refresher: hits `POST {sso}/api/v0/oauth/token` with grant_type=refresh_token.
final class SsoNetworkRefresher: SsoTokenRefreshing {
    private let urlSession: URLSession
    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    func refresh(refreshToken: String, ssoUrl: String) async throws -> SsoSession {
        let url = URL(string: "\(ssoUrl)/api/v0/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = SsoNetworkRefresher.formBody([
            "grant_type": "refresh_token",
            "client_id": SsoAuthManager.clientId,
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SsoError.refreshFailed("HTTP \(status) \(body)")
        }
        return try SsoNetworkRefresher.decodeTokenResponse(data)
    }

    /// application/x-www-form-urlencoded body.
    static func formBody(_ pairs: [String: String]) -> Data {
        let encoded = pairs.map { k, v in
            let kk = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let vv = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(kk)=\(vv)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// Parses {access_token, refresh_token, expires_in} → SsoSession.
    static func decodeTokenResponse(_ data: Data) throws -> SsoSession {
        struct Payload: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: UInt64
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        return SsoSession(
            accessToken: p.access_token,
            refreshToken: p.refresh_token,
            expiresAt: SsoSession.nowSecs() + p.expires_in,
            loginId: nil
        )
    }
}

/// Single entry point for any caller that needs an access token. Serializes
/// concurrent refreshes via actor isolation.
actor SsoTokenProvider {
    private let store: SsoSessionStoring
    private let refresher: SsoTokenRefreshing
    private let ssoUrl: () -> String

    init(store: SsoSessionStoring, refresher: SsoTokenRefreshing, ssoUrl: @escaping () -> String) {
        self.store = store
        self.refresher = refresher
        self.ssoUrl = ssoUrl
    }

    /// Returns a valid access token. Refreshes via the SSO server if needed.
    /// Throws `SsoError.notSignedIn` when the store is empty,
    /// or `SsoError.refreshFailed` when the refresh call fails.
    func validToken() async throws -> String {
        guard let current = store.load() else { throw SsoError.notSignedIn }
        if !current.needsRefresh() { return current.accessToken }

        do {
            var refreshed = try await refresher.refresh(refreshToken: current.refreshToken, ssoUrl: ssoUrl())
            // Preserve the human-readable loginId across refresh.
            refreshed.loginId = current.loginId
            try store.save(refreshed)
            return refreshed.accessToken
        } catch {
            try? store.delete()
            throw error
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoTokenProviderTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoTokenProvider.swift Tests/AstationTests/SsoTokenProviderTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add SsoTokenProvider with lazy refresh

Actor wrapping the store + a swappable network refresher. validToken()
is the single entry point for any caller that needs an access token.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 6: Add `SsoAuthManager` (loopback listener + token exchange)

**Files:**
- Create: `Sources/Menubar/SsoAuthManager.swift`
- Modify: `Tests/AstationTests/SsoAuthManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AstationTests/SsoAuthManagerTests.swift`:

```swift
final class SsoAuthorizeURLTests: XCTestCase {
    func testAuthorizeURLContainsAllRequiredFields() {
        let url = SsoAuthManager.buildAuthorizeURL(
            ssoUrl: "https://sso2.agora.io",
            redirectUri: "http://127.0.0.1:54321/oauth/callback",
            state: "STATE",
            challenge: "CHAL"
        )
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertTrue(url.contains("client_id=atem"))
        XCTAssertTrue(url.contains("scope=basic_info,console"))
        XCTAssertTrue(url.contains("state=STATE"))
        XCTAssertTrue(url.contains("code_challenge=CHAL"))
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Foauth%2Fcallback"))
        XCTAssertTrue(url.hasPrefix("https://sso2.agora.io/api/v0/oauth/authorize?"))
    }
}

final class SsoTokenResponseDecodeTests: XCTestCase {
    func testDecodeFullResponse() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#.data(using: .utf8)!
        let session = try SsoNetworkRefresher.decodeTokenResponse(json)
        XCTAssertEqual(session.accessToken, "AT")
        XCTAssertEqual(session.refreshToken, "RT")
        // expiresAt is "now + 3600" — should be within 5s of that.
        let target = SsoSession.nowSecs() + 3600
        XCTAssertLessThan(abs(Int64(session.expiresAt) - Int64(target)), 5)
    }

    func testRejectsMissingFields() {
        let json = #"{"access_token":"AT"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try SsoNetworkRefresher.decodeTokenResponse(json))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoAuthorizeURLTests`
Expected: "cannot find 'SsoAuthManager'" (the buildAuthorizeURL static).

- [ ] **Step 3: Write the implementation**

Create `Sources/Menubar/SsoAuthManager.swift`:

```swift
import Foundation
import NIO
import NIOHTTP1
import AppKit

/// Runs the OAuth 2.0 + PKCE login flow against the Agora SSO server.
/// One-shot per login — caller throws this instance away after the flow
/// finishes (or fails). Designed so the network and browser-open paths
/// can be stubbed in tests.
final class SsoAuthManager {

    static let clientId = "atem"          // reuse Atem's registered OAuth client
    static let scope = "basic_info,console"

    private let ssoUrl: String
    private let urlSession: URLSession
    private let openURL: (URL) -> Void
    private let timeoutSecs: Int

    init(
        ssoUrl: String,
        urlSession: URLSession = .shared,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        timeoutSecs: Int = 300
    ) {
        self.ssoUrl = ssoUrl
        self.urlSession = urlSession
        self.openURL = openURL
        self.timeoutSecs = timeoutSecs
    }

    /// Run the full login flow. Returns the persisted SsoSession.
    func runLoginFlow() async throws -> SsoSession {
        let (verifier, challenge) = SsoPkce.generate()
        let state = SsoPkce.generateState()

        // Bind loopback first so we know the port for the redirect_uri.
        let listener = try await SsoLoopbackListener.bind(
            timeout: .seconds(Int64(timeoutSecs)),
            expectedState: state
        )
        let redirectUri = "http://127.0.0.1:\(listener.port)/oauth/callback"

        let authURL = Self.buildAuthorizeURL(
            ssoUrl: ssoUrl,
            redirectUri: redirectUri,
            state: state,
            challenge: challenge
        )
        guard let url = URL(string: authURL) else {
            throw SsoError.browserOpenFailed
        }

        openURL(url)
        Log.info("[SSO] Waiting for OAuth callback on \(redirectUri)")

        let callback = try await listener.awaitCallback()

        // Exchange code for tokens.
        let exchanged = try await exchangeCode(
            code: callback.code,
            verifier: verifier,
            redirectUri: redirectUri
        )

        var session = exchanged
        if !callback.loginId.isEmpty {
            session.loginId = callback.loginId
        }
        return session
    }

    /// Build the `/api/v0/oauth/authorize?…` URL. Exposed for unit tests.
    static func buildAuthorizeURL(
        ssoUrl: String,
        redirectUri: String,
        state: String,
        challenge: String
    ) -> String {
        let encodedRedirect = redirectUri
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? redirectUri
        return "\(ssoUrl)/api/v0/oauth/authorize"
            + "?response_type=code"
            + "&client_id=\(clientId)"
            + "&redirect_uri=\(encodedRedirect)"
            + "&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? scope)"
            + "&state=\(state)"
            + "&code_challenge=\(challenge)"
            + "&code_challenge_method=S256"
    }

    private func exchangeCode(code: String, verifier: String, redirectUri: String) async throws -> SsoSession {
        let url = URL(string: "\(ssoUrl)/api/v0/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = SsoNetworkRefresher.formBody([
            "grant_type": "authorization_code",
            "client_id": Self.clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
        ])
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SsoError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SsoError.tokenExchangeFailed(status: http.statusCode, body: body)
        }
        return try SsoNetworkRefresher.decodeTokenResponse(data)
    }
}

private extension CharacterSet {
    /// Safer percent-encoder than `.urlQueryAllowed` (which leaves `+` and `&` alone).
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}
```

Also create `Sources/Menubar/SsoLoopbackListener.swift`:

```swift
import Foundation
import NIO
import NIOHTTP1

/// One-shot HTTP/1 loopback listener that accepts a single OAuth callback,
/// validates the `state`, replies with a success HTML page, and surfaces
/// the (code, loginId) pair.
///
/// Lifetime: bind() → awaitCallback() → channel closes automatically.
/// The instance is single-use.
final class SsoLoopbackListener {
    let port: Int
    private let group: EventLoopGroup
    private let channel: Channel
    private let promise: EventLoopPromise<SsoCallbackQuery>
    private let timeout: TimeAmount
    private var timeoutTask: Scheduled<Void>?

    private init(group: EventLoopGroup, channel: Channel, port: Int,
                 promise: EventLoopPromise<SsoCallbackQuery>, timeout: TimeAmount) {
        self.group = group
        self.channel = channel
        self.port = port
        self.promise = promise
        self.timeout = timeout
    }

    static func bind(timeout: TimeAmount, expectedState: String) async throws -> SsoLoopbackListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: SsoCallbackQuery.self)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(SsoCallbackHandler(
                        expectedState: expectedState,
                        promise: promise
                    ))
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw SsoError.loopbackBindFailed(String(describing: error))
        }

        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw SsoError.loopbackBindFailed("no local address")
        }

        let listener = SsoLoopbackListener(group: group, channel: channel, port: port,
                                           promise: promise, timeout: timeout)
        listener.timeoutTask = group.next().scheduleTask(in: timeout) {
            promise.fail(SsoError.timeout)
        }
        return listener
    }

    func awaitCallback() async throws -> SsoCallbackQuery {
        defer {
            timeoutTask?.cancel()
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
        }
        return try await promise.futureResult.get()
    }
}

/// Reads one HTTP request, parses `code/state/loginId`, replies with HTML.
final class SsoCallbackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    private let expectedState: String
    private let promise: EventLoopPromise<SsoCallbackQuery>
    private var path: String?

    init(expectedState: String, promise: EventLoopPromise<SsoCallbackQuery>) {
        self.expectedState = expectedState
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
        case .body:
            break
        case .end:
            let uri = path ?? ""
            let query = uri.split(separator: "?", maxSplits: 1).count == 2
                ? String(uri.split(separator: "?", maxSplits: 1)[1])
                : ""
            let parsed = SsoCallbackQuery.parse(query)

            let html = Self.successHTML
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
            headers.add(name: "Content-Length", value: String(html.utf8.count))
            headers.add(name: "Connection", value: "close")
            let resp = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
            // Inbound-only handler: construct NIOAny directly (wrapOutboundOut
            // is only available on ChannelOutboundHandler conformers).
            context.write(NIOAny(HTTPServerResponsePart.head(resp)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: html.utf8.count)
            buf.writeString(html)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            context.close(promise: nil)

            if parsed.state != expectedState {
                promise.fail(SsoError.stateMismatch)
                return
            }
            if parsed.code.isEmpty {
                promise.fail(SsoError.tokenExchangeFailed(status: 0, body: "no code in callback"))
                return
            }
            promise.succeed(parsed)
        }
    }

}

extension SsoCallbackHandler {
    static let successHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>Login successful</title>
    <style>
      body{min-height:100vh;display:flex;align-items:center;justify-content:center;
           background:#0f0f11;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0}
      .card{text-align:center;padding:48px 56px;max-width:560px;width:100%;
            background:#18181b;border:1px solid #2a2a2e;border-radius:16px}
      .icon{font-size:36px;color:#22c55e;margin-bottom:20px}
      h1{font-size:20px;font-weight:600;color:#f4f4f5;margin-bottom:8px}
      p{font-size:14px;color:#71717a}
    </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#x2713;</div>
        <h1>Login successful</h1>
        <p>Return to Astation to continue.</p>
      </div>
    </body>
    </html>
    """
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoAuthorizeURLTests && swift test --filter SsoTokenResponseDecodeTests`
Expected: 1 + 2 = 3 tests pass. (Loopback flow is integration-tested in Task 7.)

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SsoAuthManager.swift Sources/Menubar/SsoLoopbackListener.swift Tests/AstationTests/SsoAuthManagerTests.swift
git commit -m "$(cat <<'EOF'
feat(sso): add SsoAuthManager + loopback listener

Mirrors Atem/src/sso_auth.rs::run_login_flow: PKCE + state, NIO HTTP1
loopback on 127.0.0.1:0, browser open, code exchange, success HTML
response.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 7: Integration test the loopback flow end-to-end

**Files:**
- Modify: `Tests/AstationTests/SsoAuthManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AstationTests/SsoAuthManagerTests.swift`:

```swift
import NIO

/// Spins up the real SsoLoopbackListener, fires an HTTP GET at it from the
/// test, and asserts the parsed callback is returned. No external network.
final class SsoLoopbackIntegrationTests: XCTestCase {
    func testRoundTripsValidCallback() async throws {
        let listener = try await SsoLoopbackListener.bind(timeout: .seconds(5), expectedState: "ST")

        // Fire the GET request from the test in parallel with awaitCallback.
        async let awaited = listener.awaitCallback()

        let url = URL(string: "http://127.0.0.1:\(listener.port)/oauth/callback?code=CODE&state=ST&loginId=u%40a.io")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Login successful") == true)

        let result = try await awaited
        XCTAssertEqual(result.code, "CODE")
        XCTAssertEqual(result.state, "ST")
        XCTAssertEqual(result.loginId, "u@a.io")
    }

    func testStateMismatchFails() async throws {
        let listener = try await SsoLoopbackListener.bind(timeout: .seconds(5), expectedState: "EXPECTED")
        async let awaited = listener.awaitCallback()

        let url = URL(string: "http://127.0.0.1:\(listener.port)/oauth/callback?code=C&state=WRONG")!
        _ = try? await URLSession.shared.data(from: url)

        do {
            _ = try await awaited
            XCTFail("expected stateMismatch")
        } catch SsoError.stateMismatch {
            // ok
        } catch {
            XCTFail("expected stateMismatch, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter SsoLoopbackIntegrationTests`
Expected: 2 tests pass.

(The implementation from Task 6 should already cover this; if not, fix Task 6's bugs before continuing.)

- [ ] **Step 3: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Tests/AstationTests/SsoAuthManagerTests.swift
git commit -m "$(cat <<'EOF'
test(sso): end-to-end loopback flow integration test

Spawns the real SsoLoopbackListener and fires an HTTP GET from the test
process. Catches regressions in the NIO pipeline wiring.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 8: Swap `AstationMessage.credentialSync` payload (Astation side)

**Files:**
- Modify: `Sources/Menubar/AstationMessage.swift`
- Create: `Tests/AstationTests/SsoMessageTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AstationTests/SsoMessageTests.swift`:

```swift
import XCTest
@testable import Menubar

final class CredentialSyncMessageTests: XCTestCase {
    func testEncodeIncludesAllFields() throws {
        let msg = AstationMessage.credentialSync(
            accessToken: "AT",
            refreshToken: "RT",
            expiresAt: 1_700_000_000,
            loginId: "u@a.io",
            astationId: "ast-1",
            saveCredentials: true
        )
        let data = try JSONEncoder().encode(msg)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""type":"credentialSync""#))
        XCTAssertTrue(s.contains(#""access_token":"AT""#))
        XCTAssertTrue(s.contains(#""refresh_token":"RT""#))
        XCTAssertTrue(s.contains(#""expires_at":1700000000"#))
        XCTAssertTrue(s.contains(#""login_id":"u@a.io""#))
        XCTAssertTrue(s.contains(#""astation_id":"ast-1""#))
        XCTAssertTrue(s.contains(#""save_credentials":true"#))
    }

    func testDecodeRequiredFields() throws {
        let json = """
        {"type":"credentialSync","timestamp":"2026-05-13T00:00:00Z","data":{
          "access_token":"AT","refresh_token":"RT","expires_at":1700000000,
          "login_id":"u","astation_id":"ast-1","save_credentials":false
        }}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .credentialSync(at, rt, ex, lid, aid, save) = msg else {
            return XCTFail("expected credentialSync")
        }
        XCTAssertEqual(at, "AT")
        XCTAssertEqual(rt, "RT")
        XCTAssertEqual(ex, 1_700_000_000)
        XCTAssertEqual(lid, "u")
        XCTAssertEqual(aid, "ast-1")
        XCTAssertFalse(save)
    }

    func testDecodeAllowsMissingLoginId() throws {
        let json = """
        {"type":"credentialSync","timestamp":"2026-05-13T00:00:00Z","data":{
          "access_token":"AT","refresh_token":"RT","expires_at":1700000000,
          "astation_id":"ast-1","save_credentials":true
        }}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(AstationMessage.self, from: json)
        guard case let .credentialSync(_, _, _, lid, _, _) = msg else {
            return XCTFail("expected credentialSync")
        }
        XCTAssertNil(lid)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter CredentialSyncMessageTests`
Expected: compile error in the test (the new associated values don't exist on the enum case).

- [ ] **Step 3: Update the AstationMessage enum**

In `Sources/Menubar/AstationMessage.swift`:

Replace the existing case at the enum declaration:
```swift
case credentialSync(customerId: String, customerSecret: String, astationId: String)
```
with:
```swift
case credentialSync(
    accessToken: String,
    refreshToken: String,
    expiresAt: UInt64,
    loginId: String?,
    astationId: String,
    saveCredentials: Bool
)
```

Replace the encode case (around line 244–249) with:
```swift
case .credentialSync(let at, let rt, let exp, let lid, let aid, let save):
    try container.encode(MessageType.credentialSync, forKey: .type)
    var dc = container.nestedContainer(keyedBy: CredentialSyncKeys.self, forKey: .data)
    try dc.encode(at, forKey: .accessToken)
    try dc.encode(rt, forKey: .refreshToken)
    try dc.encode(exp, forKey: .expiresAt)
    try dc.encodeIfPresent(lid, forKey: .loginId)
    try dc.encode(aid, forKey: .astationId)
    try dc.encode(save, forKey: .saveCredentials)
```

Replace the private `CredentialSyncKeys` enum (around line 253–257) with:
```swift
private enum CredentialSyncKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresAt = "expires_at"
    case loginId = "login_id"
    case astationId = "astation_id"
    case saveCredentials = "save_credentials"
}
```

Replace the decode case (around line 425–430) with:
```swift
case .credentialSync:
    let dc = try container.nestedContainer(keyedBy: CredentialSyncKeys.self, forKey: .data)
    let at = try dc.decode(String.self, forKey: .accessToken)
    let rt = try dc.decode(String.self, forKey: .refreshToken)
    let exp = try dc.decode(UInt64.self, forKey: .expiresAt)
    let lid = try dc.decodeIfPresent(String.self, forKey: .loginId)
    let aid = try dc.decodeIfPresent(String.self, forKey: .astationId) ?? AstationIdentity.shared.id
    let save = try dc.decodeIfPresent(Bool.self, forKey: .saveCredentials) ?? false
    self = .credentialSync(accessToken: at, refreshToken: rt, expiresAt: exp,
                           loginId: lid, astationId: aid, saveCredentials: save)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter CredentialSyncMessageTests`
Expected: 3 tests pass.

The Astation build will still be **broken** at this point — `AstationHubManager.broadcastCredentials` / `sendCredentials` still pass `customerId:`. We fix those in Task 11.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/AstationMessage.swift Tests/AstationTests/SsoMessageTests.swift
git commit -m "$(cat <<'EOF'
feat(msg): swap credentialSync payload to SSO fields

Astation side of the wire change. Build is intentionally broken on
HubManager call sites — fixed in a follow-up commit before this branch
merges.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 9: Switch `AgoraAPIClient` to BFF + Bearer

**Files:**
- Modify: `Sources/Menubar/AgoraAPIClient.swift`
- Modify: `Tests/AstationTests/AgoraAPIClientTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace the entire content of `Tests/AstationTests/AgoraAPIClientTests.swift` with:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter BffProjectDecodeTests`
Expected: "cannot find 'BffProject'", "cannot find 'BffProjectsEnvelope'".

- [ ] **Step 3: Rewrite `AgoraAPIClient.swift`**

Replace the entire file `Sources/Menubar/AgoraAPIClient.swift`:

```swift
import Foundation

/// Envelope returned by `GET {bff}/api/cli/v1/projects`.
struct BffProjectsEnvelope: Codable {
    let items: [BffProject]
}

/// Project as returned by the BFF (CLI) API. Field names match Atem's BffProject
/// (Atem/src/agora_api.rs).
struct BffProject: Codable {
    let projectId: String
    let name: String
    let appId: String
    let signKey: String?
    let status: String
    let createdAt: String
    let vid: UInt64?
}

enum AgoraAPIError: LocalizedError {
    case unauthorized
    case httpError(Int, String)
    case decodingError(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired — please sign in again."
        case .httpError(let code, let body):
            return "Agora BFF returned HTTP \(code): \(body.prefix(200))"
        case .decodingError(let s):
            return "Failed to decode BFF response: \(s)"
        case .network(let s):
            return "Network error: \(s)"
        }
    }
}

final class AgoraAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch projects from the BFF using a Bearer access token.
    func fetchProjects(accessToken: String, bffUrl: String) async throws -> [AgoraProject] {
        guard let url = URL(string: "\(bffUrl)/api/cli/v1/projects") else {
            throw AgoraAPIError.network("invalid bff url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        NetworkDebugLogger.logRequest(req, label: "BFF")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            NetworkDebugLogger.logError(error, label: "BFF")
            throw AgoraAPIError.network(String(describing: error))
        }
        NetworkDebugLogger.logResponse(response, data: data, label: "BFF")

        guard let http = response as? HTTPURLResponse else {
            throw AgoraAPIError.network("no HTTP response")
        }
        if http.statusCode == 401 { throw AgoraAPIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgoraAPIError.httpError(http.statusCode, body)
        }

        do {
            let env = try JSONDecoder().decode(BffProjectsEnvelope.self, from: data)
            return env.items.map(AgoraProject.init(from:))
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            Log.error("[BFF] decode failed. Raw: \(preview)")
            throw AgoraAPIError.decodingError(String(describing: error))
        }
    }
}

extension AgoraProject {
    /// Convert a BFF project to the in-memory `AgoraProject` that the rest of
    /// Astation (and the WS protocol) already understands. App ID is used as
    /// the canonical id.
    init(from b: BffProject) {
        self.init(
            id: b.appId,
            name: b.name,
            vendorKey: b.appId,
            signKey: b.signKey ?? "",
            status: b.status,
            created: AgoraProject.unixSecondsFromISO8601(b.createdAt)
        )
    }

    static func unixSecondsFromISO8601(_ s: String) -> UInt64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return UInt64(d.timeIntervalSince1970) }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return UInt64(d.timeIntervalSince1970) }
        return 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter BffProject`
Expected: all tests in `BffProjectDecodeTests`, `BffProjectMappingTests`, `AgoraAPIErrorTests` pass.

Astation build will still be broken at `AstationHubManager.loadProjects` (still passes a `credentials:` arg). We fix that in Task 11.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/AgoraAPIClient.swift Tests/AstationTests/AgoraAPIClientTests.swift
git commit -m "$(cat <<'EOF'
feat(api): switch AgoraAPIClient to BFF + Bearer

Hits {bff}/api/cli/v1/projects with Authorization: Bearer <token>. Maps
BffProject → AgoraProject preserving the wire shape that Atems already
receive.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 10: Switch `ConvoAIClient` to `agora token=<rtc_token>`

**Files:**
- Modify: `Sources/Menubar/ConvoAIClient.swift`
- Modify: `Tests/AstationTests/VoiceCodingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AstationTests/VoiceCodingTests.swift` (next to the existing voice tests):

```swift
final class ConvoAIAuthHeaderTests: XCTestCase {
    func testAuthorizationHeaderIsAgoraTokenFormat() {
        let header = ConvoAIClient.authorizationHeader(rtcToken: "abc.def.ghi")
        XCTAssertEqual(header, "agora token=abc.def.ghi")
    }
}
```

Also delete (or update) the existing test that uses `AgoraCredentials`:

Find this block in `VoiceCodingTests.swift` (around line 348):
```swift
let credentials = AgoraCredentials(customerId: "my-customer", customerSecret: "my-secret")
…
let authString = "\(credentials.customerId):\(credentials.customerSecret)"
```
Replace the whole containing test function with the new one above, or delete it if no longer meaningful. Run `grep -n AgoraCredentials Tests/AstationTests/VoiceCodingTests.swift` to confirm 0 references after.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter ConvoAIAuthHeaderTests`
Expected: "cannot find 'authorizationHeader' on ConvoAIClient" (also build error on the credentials line if not yet removed).

- [ ] **Step 3: Rewrite `ConvoAIClient.swift`**

Replace the entire file `Sources/Menubar/ConvoAIClient.swift`:

```swift
import Foundation
import CStationCore

/// HTTP client for the Agora Conversational AI Agent REST API.
///
/// Auth: `Authorization: agora token=<rtc_dynamic_token>`. The token is
/// minted from app_id + sign_key (a.k.a. project app_certificate) using
/// the existing C bridge. This is the same pattern atem serv convo uses
/// (Atem/src/convo_test_server.rs).
final class ConvoAIClient {
    private let session: URLSession

    static let baseURL = "https://api.agora.io/api/conversational-ai-agent/v2/projects"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `POST /projects/{appId}/join`. Returns the agent id on success.
    func createAgent(
        appId: String,
        appCertificate: String,
        channel: String,
        agentRtcUid: String,
        remoteRtcUid: String,
        token: String,
        llmUrl: String,
        systemPrompt: String
    ) async throws -> ConvoAIAgentResponse {
        let urlString = "\(Self.baseURL)/\(appId)/join"
        guard let url = URL(string: urlString) else { throw ConvoAIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rtcToken = try Self.mintToken(appId: appId, appCertificate: appCertificate,
                                          channel: channel, uid: agentRtcUid)
        req.setValue(Self.authorizationHeader(rtcToken: rtcToken),
                     forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "name": "atem-voice-\(Int(Date().timeIntervalSince1970))",
            "properties": [
                "channel": channel,
                "token": token,
                "agent_rtc_uid": agentRtcUid,
                "remote_rtc_uids": [remoteRtcUid],
                "enable_string_uid": false,
                "idle_timeout": 120,
                "llm": [
                    "url": llmUrl,
                    "api_key": "unused",
                    "style": "openai",
                    "system_messages": [["role": "system", "content": systemPrompt]],
                    "max_history": 10,
                    "params": ["model": "atem-voice-proxy"]
                ] as [String: Any],
                "asr": ["language": "en-US"],
                "tts": [
                    "vendor": "microsoft",
                    "params": [
                        "key": "placeholder",
                        "region": "eastus",
                        "voice_name": "en-US-AndrewMultilingualNeural"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        NetworkDebugLogger.logRequest(req, label: "ConvoAI-create")
        let (data, response) = try await session.data(for: req)
        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-create")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "no HTTP response")
        }
        guard (200...201).contains(http.statusCode) else {
            throw ConvoAIError.httpError(statusCode: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(ConvoAIAgentResponse.self, from: data) }
        catch { throw ConvoAIError.decodingError(error) }
    }

    /// `POST /projects/{appId}/leave`. Mints a fresh leave token.
    func stopAgent(appId: String, appCertificate: String, channel: String,
                   agentRtcUid: String, agentId: String) async throws {
        let urlString = "\(Self.baseURL)/\(appId)/leave"
        guard let url = URL(string: urlString) else { throw ConvoAIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let rtcToken = try Self.mintToken(appId: appId, appCertificate: appCertificate,
                                          channel: channel, uid: agentRtcUid)
        req.setValue(Self.authorizationHeader(rtcToken: rtcToken),
                     forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["agent_id": agentId])

        NetworkDebugLogger.logRequest(req, label: "ConvoAI-stop")
        let (data, response) = try await session.data(for: req)
        NetworkDebugLogger.logResponse(response, data: data, label: "ConvoAI-stop")

        guard let http = response as? HTTPURLResponse else {
            throw ConvoAIError.httpError(statusCode: 0, body: "no HTTP response")
        }
        guard (200...204).contains(http.statusCode) else {
            throw ConvoAIError.httpError(statusCode: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Pure helper — kept static so tests don't need a network or RTC stack.
    static func authorizationHeader(rtcToken: String) -> String {
        "agora token=\(rtcToken)"
    }

    /// Mint a 2h RTC dynamic token via the C core. Throws if the C side
    /// returns nil (means invalid inputs).
    static func mintToken(appId: String, appCertificate: String,
                          channel: String, uid: String) throws -> String {
        // ConvoAI uses string UIDs but the RTC token builder takes uint32.
        // Atem's serv convo path uses the agent_user_id parsed as a u32
        // (see `RtcAccount::parse`). Match that: numeric uid → cast, else
        // fall back to 0.
        let uidNum = UInt32(uid) ?? 0
        guard let cstr = astation_rtc_build_token(
            appId, appCertificate, channel, uidNum,
            /* role = publisher */ 1,
            /* expire_secs */ 7200,
            /* privilege_secs */ 7200
        ) else {
            throw ConvoAIError.tokenMintFailed
        }
        defer { astation_token_free(cstr) }
        return String(cString: cstr)
    }
}

struct ConvoAIAgentResponse: Decodable {
    let agentId: String
    let createTs: Int?
    let state: String?
}

enum ConvoAIError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case tokenMintFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid ConvoAI URL"
        case .httpError(let s, let b): return "ConvoAI HTTP \(s): \(b)"
        case .decodingError(let e): return "ConvoAI decode: \(e)"
        case .tokenMintFailed: return "Could not mint RTC token (missing app cert?)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter ConvoAIAuthHeaderTests`
Expected: 1 test passes.

Build still broken — `VoiceCodingManager` still calls the old `createAgent(credentials:…)` signature. Fixed in Task 12.

- [ ] **Step 5: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/ConvoAIClient.swift Tests/AstationTests/VoiceCodingTests.swift
git commit -m "$(cat <<'EOF'
feat(convoai): switch to `agora token=<rtc_token>` auth

Mirrors atem serv convo (Atem/src/convo_test_server.rs). Drops the
customer_id/secret parameter; takes app_certificate (a.k.a. signKey)
and mints a 2h RTC dynamic token via the C core for each call.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 11: Rewire `AstationHubManager` to use `SsoTokenProvider`

**Files:**
- Modify: `Sources/Menubar/AstationHubManager.swift`

- [ ] **Step 1: Edit the hub**

In `Sources/Menubar/AstationHubManager.swift`:

Replace line 21:
```swift
let credentialManager = CredentialManager()
```
with:
```swift
let sessionStore = SsoSessionStore()
let tokenProvider: SsoTokenProvider
```

In `init(skipProjectLoad:)` (around line 55–69), at the very top of the body, before `Log.info("Initializing…")`:
```swift
self.tokenProvider = SsoTokenProvider(
    store: SsoSessionStore(),                    // separate handle for the actor's loads
    refresher: SsoNetworkRefresher(),
    ssoUrl: { SsoConfig.currentSsoUrl }
)
```

Replace `getCredentials` / `checkCredentialStatus` / `reloadCredentials` / `broadcastCredentials` / `sendCredentials` (lines 186–228) with:

```swift
// MARK: - SSO Session

/// Whether an SSO session is on disk. Used by the UI to render
/// "Signed in" vs "Sign in".
var hasSession: Bool { sessionStore.hasSession }

/// Loaded session (no refresh). Use `tokenProvider.validToken()` if you
/// need a fresh access token for a network call.
func currentSession() -> SsoSession? { sessionStore.load() }

func checkSessionStatus() {
    if hasSession {
        Log.info("[AstationHub] SSO session found")
    } else {
        Log.info("[AstationHub] No SSO session. Open Settings → Sign in with Agora.")
    }
}

func reloadSession() {
    checkSessionStatus()
    refreshProjects()
    broadcastCredentials()
}

/// Broadcast a refreshed-on-use credentialSync to every connected Atem.
func broadcastCredentials() {
    Task { await pushCredentials(targetClientId: nil) }
}

/// Send credentialSync to one specific Atem (e.g. just-connected).
func sendCredentials(toClientId clientId: String) {
    Task { await pushCredentials(targetClientId: clientId) }
}

private func pushCredentials(targetClientId: String?) async {
    // validToken refreshes if near-expiry; we then load the full session
    // (including the refreshed refresh_token) to ship.
    do { _ = try await tokenProvider.validToken() }
    catch {
        Log.info("[AstationHub] No session — skipping credentialSync (\(error.localizedDescription))")
        return
    }
    guard let session = sessionStore.load() else { return }
    let msg = AstationMessage.credentialSync(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        expiresAt: session.expiresAt,
        loginId: session.loginId,
        astationId: AstationIdentity.shared.id,
        saveCredentials: false              // Atem decides via PairSavePreference at pair time
    )
    if let id = targetClientId {
        sendHandler?(msg, id)
        Log.info("[AstationHub] Sent credentialSync to \(id.prefix(8))…")
    } else {
        broadcastHandler?(msg)
        Log.info("[AstationHub] Broadcast credentialSync to all Atems")
    }
}
```

Replace line 59 inside `init`:
```swift
checkCredentialStatus()
```
with:
```swift
checkSessionStatus()
```

Replace `handleCredentialsChanged()` (line 71–73) to dispatch via the async push:
```swift
@objc private func handleCredentialsChanged() {
    Task { await pushCredentials(targetClientId: nil) }
}
```

Replace `loadProjects` (around lines 233–259):
```swift
private func loadProjects() {
    Task {
        let token: String
        do { token = try await tokenProvider.validToken() }
        catch {
            await MainActor.run {
                self.projects = []
                self.projectLoadError = error.localizedDescription
                Log.info("[AstationHub] Cannot load projects: \(error.localizedDescription)")
            }
            return
        }
        do {
            let fetched = try await apiClient.fetchProjects(accessToken: token,
                                                            bffUrl: SsoConfig.currentBffUrl)
            await MainActor.run {
                self.projects = fetched
                self.projectLoadError = nil
                Log.info(" Loaded \(fetched.count) projects from BFF")
            }
        } catch AgoraAPIError.unauthorized {
            try? self.sessionStore.delete()
            await MainActor.run {
                self.projects = []
                self.projectLoadError = "Session expired — please sign in again."
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            }
        } catch {
            await MainActor.run {
                self.projects = []
                self.projectLoadError = error.localizedDescription
                Log.error(" Failed to fetch projects: \(error)")
            }
        }
    }
}
```

Search for any remaining reference to `credentialManager` in the file (`grep -n credentialManager Sources/Menubar/AstationHubManager.swift`) and remove them all — there should be none left.

- [ ] **Step 2: Run tests + build**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift build`
Expected: build succeeds **except** for remaining references in `VoiceCodingManager`, `StatusBarController`, and `SettingsWindowController` (fixed in next 3 tasks). If anything ELSE fails, fix it before continuing.

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test --filter CredentialSyncMessageTests`
Expected: 3 tests still pass.

- [ ] **Step 3: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/AstationHubManager.swift
git commit -m "$(cat <<'EOF'
feat(hub): wire SsoTokenProvider into AstationHubManager

Replace credentialManager with sessionStore + tokenProvider.
broadcastCredentials/sendCredentials now refresh on use and ship the
new credentialSync payload. loadProjects pulls from the BFF with the
validated bearer token; 401 deletes the session and surfaces a re-login
prompt.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 12: Update `VoiceCodingManager` to use SSO + app certificate

**Files:**
- Modify: `Sources/Menubar/VoiceCodingManager.swift`

- [ ] **Step 1: Edit the two ConvoAI call sites**

Replace `createConvoAIAgent` (around lines 536–580):

```swift
private func createConvoAIAgent(sessionId: String) {
    guard let project = hubManager.projects.first,
          let channel = hubManager.rtcManager.currentChannel,
          !project.vendorKey.isEmpty,
          !project.signKey.isEmpty
    else {
        Log.warn("[VoiceCoding] Missing project (appId/signKey) or channel — skipping ConvoAI agent")
        updateStage("Voice: Missing project", autoHideAfter: 2.0)
        cleanup()
        return
    }
    let appId = project.vendorKey
    let appCert = project.signKey
    let localUid = String(hubManager.rtcManager.currentUid)
    let relayUrl = hubManager.stationRelayUrl

    Task {
        do {
            let agentToken = await hubManager.generateTokenForConvoAIAgent(channel: channel) ?? ""
            let llmUrl = "\(relayUrl)/api/llm/chat?session_id=\(sessionId)"
            let agentResp = try await self.convoAIClient.createAgent(
                appId: appId,
                appCertificate: appCert,
                channel: channel,
                agentRtcUid: "1001",
                remoteRtcUid: localUid,
                token: agentToken,
                llmUrl: llmUrl,
                systemPrompt: "You are a voice coding assistant."
            )
            self.activeAgentId = agentResp.agentId
            self.isAgentReady = true
            self.isPreparing = false
            Log.info("[VoiceCoding] ConvoAI agent created: \(agentResp.agentId)")
            self.updateStage(self.mode == .handsFree ? "Voice: Listening…" : "Voice: Listening…")
            if self.deferredStopPTT {
                Log.info("[VoiceCoding] Executing deferred stopPTT")
                self.stopPTT()
            }
        } catch {
            Log.error("[VoiceCoding] ConvoAI agent creation failed: \(error)")
            self.updateStage("Voice: Agent failed", autoHideAfter: 2.0)
            self.cleanup()
        }
    }
}
```

Replace `stopConvoAIAgent` (around lines 582–597):

```swift
private func stopConvoAIAgent() {
    guard let agentId = activeAgentId,
          let project = hubManager.projects.first,
          let channel = hubManager.rtcManager.currentChannel,
          !project.vendorKey.isEmpty,
          !project.signKey.isEmpty
    else { return }

    let appId = project.vendorKey
    let appCert = project.signKey

    Task {
        do {
            try await convoAIClient.stopAgent(
                appId: appId,
                appCertificate: appCert,
                channel: channel,
                agentRtcUid: "1001",
                agentId: agentId
            )
            Log.info("[VoiceCoding] ConvoAI agent stopped: \(agentId)")
        } catch {
            Log.error("[VoiceCoding] Failed to stop ConvoAI agent: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run build**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift build`
Expected: only StatusBarController + SettingsWindowController errors remain.

- [ ] **Step 3: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/VoiceCodingManager.swift
git commit -m "$(cat <<'EOF'
refactor(voice): pass app cert (signKey) to ConvoAI client

Removes the last hubManager.credentialManager call sites.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 13: Rewrite the Settings UI's credentials section

**Files:**
- Modify: `Sources/Menubar/SettingsWindowController.swift`

- [ ] **Step 1: Replace the credentials section**

Replace the entire `SettingsWindowController` class body (lines 19–319) by following these edits in order. Open the file once and apply all changes:

1. Replace properties (lines 19–27):
```swift
private var window: NSWindow?
private let hubManager: AstationHubManager
private var statusLabel: NSTextField!
private var signInButton: NSButton!
private var signOutButton: NSButton!
private var identityLabel: NSTextField!
private var stationUrlField: NSTextField!
private var serverStatusLabel: NSTextField!
private var serverInfoLabel: NSTextField!
```

2. Replace `init` (lines 30–41):
```swift
init(hubManager: AstationHubManager) {
    self.hubManager = hubManager
    super.init()
    NotificationCenter.default.addObserver(
        self, selector: #selector(networkChanged),
        name: .networkChanged, object: nil)
    NotificationCenter.default.addObserver(
        self, selector: #selector(sessionChanged),
        name: .credentialsChanged, object: nil)
}
```

3. Inside `showWindow()` (around line 47–174), replace the "Credentials Section" block (the part rendering `customerIdField` / `customerSecretField` / Save / Delete) with this Agora Account section. Keep the Server Info / Relay URL block above it unchanged:

```swift
// === Agora Account Section ===
let acctTitle = NSTextField(labelWithString: "Agora Account")
acctTitle.font = NSFont.boldSystemFont(ofSize: 14)
acctTitle.frame = NSRect(x: 20, y: 200, width: 410, height: 24)
contentView.addSubview(acctTitle)

let info = NSTextField(wrappingLabelWithString:
    "Sign in once with your Agora account. Astation uses this session to fetch projects and ship credentials to paired Atems. The session is encrypted on disk.")
info.font = NSFont.systemFont(ofSize: 11)
info.textColor = .secondaryLabelColor
info.frame = NSRect(x: 20, y: 150, width: 410, height: 46)
contentView.addSubview(info)

identityLabel = NSTextField(labelWithString: "")
identityLabel.font = NSFont.systemFont(ofSize: 12)
identityLabel.frame = NSRect(x: 20, y: 110, width: 410, height: 22)
contentView.addSubview(identityLabel)

signInButton = NSButton(title: "Sign in with Agora", target: self, action: #selector(signIn))
signInButton.bezelStyle = .rounded
signInButton.frame = NSRect(x: 20, y: 70, width: 180, height: 32)
contentView.addSubview(signInButton)

signOutButton = NSButton(title: "Sign out", target: self, action: #selector(signOut))
signOutButton.bezelStyle = .rounded
signOutButton.frame = NSRect(x: 210, y: 70, width: 100, height: 32)
contentView.addSubview(signOutButton)

statusLabel = NSTextField(labelWithString: "")
statusLabel.font = NSFont.systemFont(ofSize: 11)
statusLabel.frame = NSRect(x: 20, y: 40, width: 410, height: 22)
contentView.addSubview(statusLabel)

renderAccountState()
```

Also delete every line that still references `customerIdField`, `customerSecretField`, `saveButton`, `deleteButton`, `credentialManager`, `customerId`, `customerSecret`.

4. Add new methods (anywhere inside the class):

```swift
private func renderAccountState() {
    if let session = hubManager.currentSession() {
        let id = session.loginId ?? "—"
        identityLabel.stringValue = "Signed in as: \(id)"
        let mins = max(0, Int64(session.expiresAt) - Int64(Date().timeIntervalSince1970)) / 60
        statusLabel.stringValue = "Access token expires in \(mins) min"
        statusLabel.textColor = .secondaryLabelColor
        signInButton.isEnabled = false
        signOutButton.isEnabled = true
    } else {
        identityLabel.stringValue = "Not signed in"
        statusLabel.stringValue = ""
        signInButton.isEnabled = true
        signOutButton.isEnabled = false
    }
}

@objc private func signIn() {
    signInButton.isEnabled = false
    statusLabel.stringValue = "Waiting for browser…"
    statusLabel.textColor = .secondaryLabelColor

    Task { @MainActor in
        do {
            let mgr = SsoAuthManager(ssoUrl: SsoConfig.currentSsoUrl)
            let session = try await mgr.runLoginFlow()
            try hubManager.sessionStore.save(session)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            Log.info("[Settings] Signed in as \(session.loginId ?? "—")")
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
            signInButton.isEnabled = true
        }
    }
}

@objc private func signOut() {
    let alert = NSAlert()
    alert.messageText = "Sign out?"
    alert.informativeText = "Astation will lose access to your projects until you sign in again. Paired Atems will not receive credential updates."
    alert.addButton(withTitle: "Sign out")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    try? hubManager.sessionStore.delete()
    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
}

@objc private func sessionChanged() {
    DispatchQueue.main.async { [weak self] in self?.renderAccountState() }
}
```

5. Delete the old `saveCredentials` / `updateStatus` / `deleteCredentials` methods entirely.

- [ ] **Step 2: Update the caller in StatusBarController to pass `hubManager`**

In `Sources/Menubar/StatusBarController.swift:9`, replace:
```swift
private lazy var settingsWindowController = SettingsWindowController(credentialManager: hubManager.credentialManager)
```
with:
```swift
private lazy var settingsWindowController = SettingsWindowController(hubManager: hubManager)
```

- [ ] **Step 3: Run build**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift build`
Expected: build succeeds. If `Sources/Menubar/CredentialManager.swift` is still in the project, the build will fail on `CredentialManager` being unused / unresolvable — proceed to Task 14 to remove it.

- [ ] **Step 4: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add Sources/Menubar/SettingsWindowController.swift Sources/Menubar/StatusBarController.swift
git commit -m "$(cat <<'EOF'
feat(ui): replace credentials section with Agora Account

Sign in with Agora / Signed in as <login_id> / Sign out. Status line
shows time-to-expiry. Sign-in spawns SsoAuthManager and refreshes on
.credentialsChanged.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 14: Add menubar Sign in / Sign out menu items + delete `CredentialManager.swift`

**Files:**
- Modify: `Sources/Menubar/StatusBarController.swift`
- Delete: `Sources/Menubar/CredentialManager.swift`

- [ ] **Step 1: Add the menubar items**

`StatusBarController.swift` already rebuilds the menu on every open via the `NSMenuDelegate.menuNeedsUpdate(_:)` method (around line 50). So we don't need to manually rebuild — just slot the new item into the existing build flow and add a click handler.

Add this method on `StatusBarController` (near `openSettings()` at line 801):

```swift
@objc private func signInOrOut() {
    if hubManager.hasSession {
        try? hubManager.sessionStore.delete()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    } else {
        Task { @MainActor in
            do {
                let mgr = SsoAuthManager(ssoUrl: SsoConfig.currentSsoUrl)
                let session = try await mgr.runLoginFlow()
                try hubManager.sessionStore.save(session)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            } catch {
                Log.error("[StatusBar] sign-in failed: \(error)")
            }
        }
    }
}
```

In `menuNeedsUpdate(_:)` (the method that rebuilds the menu — around line 50), find the `// Settings` comment (around line 420) and the block that adds the Settings item (around line 422–424). Immediately BEFORE that Settings item, insert:

```swift
// Agora Account (Sign in / Sign out)
let acctTitle: String
if hubManager.hasSession {
    let id = hubManager.currentSession()?.loginId ?? "—"
    acctTitle = "Sign out (\(id))"
} else {
    acctTitle = "Sign in with Agora…"
}
let acctItem = NSMenuItem(title: acctTitle, action: #selector(signInOrOut), keyEquivalent: "")
acctItem.target = self
statusMenu.addItem(acctItem)
statusMenu.addItem(NSMenuItem.separator())
```

Because the menu is rebuilt on every open (`menuNeedsUpdate`), no notification observer is needed — the title automatically reflects current state next time the menu is opened.

- [ ] **Step 2: Delete `CredentialManager.swift`**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
rm Sources/Menubar/CredentialManager.swift
```

- [ ] **Step 3: Run build + full test**

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift build`
Expected: build succeeds with no warnings about unused symbols.

Run: `cd /home/guohai/Dev/Agora.Build/Astation && swift test`
Expected: every Astation test passes.

If anything still references `CredentialManager` or `AgoraCredentials`, `grep -r "CredentialManager\|AgoraCredentials" Sources/ Tests/` will surface it. Remove or update those sites.

- [ ] **Step 4: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add -u Sources/Menubar/ Tests/
git commit -m "$(cat <<'EOF'
feat(ui): add menubar Sign in/out item; remove CredentialManager

Mirrors Settings state in the status-bar menu. Old CredentialManager
and AgoraCredentials types are gone — everywhere uses SsoSession,
SsoSessionStore, and SsoTokenProvider now.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 15: Atem-side — swap `CredentialSync` payload + remove `SsoTokenSync`

**Files:**
- Modify: `Atem/src/websocket_client.rs`
- Modify: `Atem/src/cli.rs`
- Modify: `Atem/src/app.rs`

- [ ] **Step 1: Replace the `CredentialSync` variant**

In `Atem/src/websocket_client.rs` at line 223, replace the existing variant:

```rust
    /// Astation → Atem: Agora REST API credentials for use without env vars.
    /// Priority: synced (this) > env vars > config file.
    #[serde(rename = "credentialSync")]
    CredentialSync {
        #[serde(rename = "customer_id")]
        customer_id: String,
        #[serde(rename = "customer_secret")]
        customer_secret: String,
        /// Astation's persistent identity ID — store as astation_relay_code for future TUI auto-connect.
        #[serde(rename = "astation_id", default)]
        astation_id: Option<String>,
    },
```

with:

```rust
    /// Astation → Atem: SSO tokens to use for BFF calls + paired session
    /// resolution. Repurposed in 2026-05; previously carried customer_id/
    /// customer_secret. Identical payload to the now-removed SsoTokenSync.
    #[serde(rename = "credentialSync")]
    CredentialSync {
        access_token: String,
        refresh_token: String,
        expires_at: u64,
        #[serde(default)]
        login_id: Option<String>,
        astation_id: String,
        save_credentials: bool,
    },
```

- [ ] **Step 2: Delete the `SsoTokenSync` variant**

In `Atem/src/websocket_client.rs` at line 234, delete this entire variant (including the doc comment immediately above and the closing `},`):

```rust
    /// Astation → Atem: SSO tokens pushed after successful pairing or on Astation's own refresh.
    #[serde(rename = "ssoTokenSync")]
    SsoTokenSync {
        access_token: String,
        refresh_token: String,
        expires_at: u64,
        #[serde(default)]
        login_id: Option<String>,
        astation_id: String,
        save_credentials: bool,
    },
```

- [ ] **Step 3: Migrate the pair-flow match arm in `cli.rs`**

In `Atem/src/cli.rs` around line 1144, replace:
```rust
Some(crate::websocket_client::AstationMessage::SsoTokenSync {
```
with:
```rust
Some(crate::websocket_client::AstationMessage::CredentialSync {
```
The rest of the arm body is unchanged.

- [ ] **Step 4: Migrate the TUI dispatch match arm in `app.rs`**

In `Atem/src/app.rs` around line 2017, replace:
```rust
AstationMessage::SsoTokenSync {
```
with:
```rust
AstationMessage::CredentialSync {
```

Then **delete the now-duplicated old `CredentialSync` match arm** that exists just above it (the one that destructures `customer_id`, `customer_secret`, `astation_id` and writes them into env-var-style credentials). It was the previous handler and is replaced by this one. Find it by grepping `grep -n "AstationMessage::CredentialSync" Atem/src/app.rs`. If there's only one match arm after this step, you're done; if there are two, delete the older one.

- [ ] **Step 5: Rewrite the credential_sync tests**

In `Atem/src/websocket_client.rs` around lines 1711–1755, replace `credential_sync_roundtrip` and `credential_sync_deserialize_from_json` with:

```rust
    #[test]
    fn credential_sync_roundtrip() {
        let msg = AstationMessage::CredentialSync {
            access_token: "AT".to_string(),
            refresh_token: "RT".to_string(),
            expires_at: 1_700_000_000,
            login_id: Some("u@a.io".to_string()),
            astation_id: "ast-1".to_string(),
            save_credentials: true,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"credentialSync""#));
        assert!(json.contains(r#""access_token":"AT""#));
        assert!(json.contains(r#""refresh_token":"RT""#));
        assert!(json.contains(r#""expires_at":1700000000"#));
        assert!(json.contains(r#""login_id":"u@a.io""#));
        assert!(json.contains(r#""astation_id":"ast-1""#));
        assert!(json.contains(r#""save_credentials":true"#));
    }

    #[test]
    fn credential_sync_deserialize_from_json() {
        let json = r#"{"type":"credentialSync","data":{
            "access_token":"AT","refresh_token":"RT","expires_at":1700000000,
            "login_id":"u","astation_id":"ast-1","save_credentials":false
        }}"#;
        let msg: AstationMessage = serde_json::from_str(json).unwrap();
        match msg {
            AstationMessage::CredentialSync {
                access_token, refresh_token, expires_at, login_id,
                astation_id, save_credentials,
            } => {
                assert_eq!(access_token, "AT");
                assert_eq!(refresh_token, "RT");
                assert_eq!(expires_at, 1_700_000_000);
                assert_eq!(login_id.as_deref(), Some("u"));
                assert_eq!(astation_id, "ast-1");
                assert!(!save_credentials);
            }
            _ => panic!("expected CredentialSync"),
        }
    }

    #[test]
    fn credential_sync_without_login_id() {
        let json = r#"{"type":"credentialSync","data":{
            "access_token":"AT","refresh_token":"RT","expires_at":1,
            "astation_id":"ast-1","save_credentials":true
        }}"#;
        let msg: AstationMessage = serde_json::from_str(json).unwrap();
        match msg {
            AstationMessage::CredentialSync { login_id, .. } => assert!(login_id.is_none()),
            _ => panic!("expected CredentialSync"),
        }
    }
```

- [ ] **Step 6: Delete the SsoTokenSync tests**

In `Atem/src/websocket_client.rs` around lines 2076–2154, delete the section header `// ── SsoTokenSync / PairSavePreference ──…` and the three tests:
- `fn sso_token_sync_roundtrip()`
- `fn sso_token_sync_deserialize_from_json()`
- `fn sso_token_sync_without_login_id()`

Keep any `PairSavePreference` tests in that section.

- [ ] **Step 7: Run Atem tests**

Run: `cd /home/guohai/Dev/Agora.Build/Atem && cargo test credential_sync && cargo test pair_save_preference && cargo build`
Expected:
- `credential_sync_roundtrip`, `credential_sync_deserialize_from_json`, `credential_sync_without_login_id` pass (3 tests).
- pair_save_preference tests still pass.
- `cargo build` succeeds.

If anything mentions `SsoTokenSync`, grep with `grep -rn SsoTokenSync Atem/src/` and remove the last reference.

- [ ] **Step 8: Commit**

```bash
cd /home/guohai/Dev/Agora.Build/Atem
git add -u src/
git commit -m "$(cat <<'EOF'
refactor(ws): repurpose credentialSync to carry SSO tokens

credentialSync now matches the payload the removed SsoTokenSync variant
used to carry. The pair flow (cli.rs) and TUI dispatcher (app.rs) read
from CredentialSync directly. Atem is now compatible with the SSO2-
enabled Astation; old Astation builds (customer_id/secret) will fail to
decode credentialSync, which is intentional given monorepo lockstep.

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Task 16: End-to-end smoke + spec sign-off

**Files:**
- (none — verification only)

- [ ] **Step 1: Build both apps from a clean state**

```bash
cd /home/guohai/Dev/Agora.Build/Astation && swift build
cd /home/guohai/Dev/Agora.Build/Atem && cargo build
```
Expected: both succeed.

- [ ] **Step 2: Run full test suites**

```bash
cd /home/guohai/Dev/Agora.Build/Astation && swift test
cd /home/guohai/Dev/Agora.Build/Atem && cargo test
```
Expected: all green.

- [ ] **Step 3: Verify no leftover symbols**

```bash
cd /home/guohai/Dev/Agora.Build/Astation
grep -rn "CredentialManager\|AgoraCredentials\|customerId\|customerSecret" Sources/ Tests/
```
Expected: empty.

```bash
cd /home/guohai/Dev/Agora.Build/Atem
grep -rn "SsoTokenSync\|sso_token_sync" src/
```
Expected: empty.

- [ ] **Step 4: Manual UI smoke (REQUIRES MACOS)**

If running on macOS, do the manual smoke from the spec §7:
1. `swift run astation` → menubar appears.
2. Open Settings → confirm "Sign in with Agora" button is visible, no Customer ID field.
3. Click → browser opens to `sso2.agora.io/api/v0/oauth/authorize?...client_id=atem...`.
4. Complete login → success page shown in browser, Settings updates to "Signed in as …".
5. Menubar item also flips to "Sign out (…)".
6. Run `atem pair` from a local Atem checkout → completes, projects load via BFF.
7. Sign out → Settings goes back to "Sign in with Agora", projects clear, paired Atem stops getting credential updates.

If you don't have macOS, note this in the commit / PR description so the next person picks it up.

- [ ] **Step 5: Mark the spec status complete and commit**

Edit `docs/superpowers/specs/2026-05-13-astation-sso2-login-design.md`: change the `Status:` line at the top to `Status: implemented`.

```bash
cd /home/guohai/Dev/Agora.Build/Astation
git add docs/superpowers/specs/2026-05-13-astation-sso2-login-design.md
git commit -m "$(cat <<'EOF'
docs: mark SSO2 login spec implemented

🤖 Built with SMT <smt@agora.build>
EOF
)"
```

---

## Self-review checklist (run before handing off)

- [x] Spec §1 (SsoSession + SsoSessionStore) → Tasks 1, 2.
- [x] Spec §2 (SsoTokenProvider) → Task 5.
- [x] Spec §3 (SsoAuthManager) → Tasks 4, 6, 7.
- [x] Spec §4 (URL / env-var config) → Task 3.
- [x] Spec §5 (AgoraAPIClient → BFF Bearer) → Task 9.
- [x] Spec §6 (ConvoAIClient → agora token) → Task 10.
- [x] Spec §7 (credentialSync payload swap + Atem migration) → Tasks 8, 11, 15.
- [x] Spec §8 (Settings UI) → Task 13.
- [x] Spec §9 (menubar item) → Task 14.
- [x] Spec §10 (notifications) → Task 11 (reuse of `.credentialsChanged`).
- [x] Spec error handling section → covered in Tasks 5, 9, 11, 13.
- [x] Spec tests section → distributed across Tasks 1–10 + 15.
- [x] Spec migration (old-shape file delete) → Task 2.
