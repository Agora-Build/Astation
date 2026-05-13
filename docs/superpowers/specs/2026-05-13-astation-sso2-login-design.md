# Astation SSO2 Login — Design

Status: approved
Date: 2026-05-13
Related: `Atem/src/sso_auth.rs`, `Atem/src/credentials.rs`, `Atem/src/agora_api.rs`,
`Atem/src/convo_test_server.rs`

## Goal

Replace Astation's manual "Customer ID + Customer Secret" credential entry with the
same OAuth 2.0 + PKCE login flow Atem uses against `sso2.agora.io`. After this
change Astation:

- has no UI for typing or storing Agora REST API customer credentials,
- signs in once via the system browser and persists an SSO session locally,
- uses Bearer tokens against the BFF (`agora-cli.agora.io`) for project listing,
- uses `Authorization: agora token=<rtc_token>` for ConvoAI calls (same pattern as
  `atem serv convo`),
- pushes its SSO session to paired Atems via the existing `credentialSync` WS
  message, with the payload redefined to carry SSO fields.

## Non-goals

- No `atem pair`-style flow originating from Astation (Astation only has its own
  session — there's no per-Atem paired store on the Astation side).
- No background timer that pre-refreshes the access token; refresh is lazy.
- No fallback path for paste-the-URL when the loopback listener can't bind — the
  UI shows the error and a retry button. Atem's stdin fallback only exists because
  it's a CLI.
- No backwards-compatible reading of the old `AgoraCredentials` file. Old files
  are deleted on first launch and the user signs in again.

## Architecture overview

```
            +----------------------+         +-------------------------+
            |  SettingsWindow /    |         |   SsoAuthManager        |
            |  StatusBar menu      |  -----> |   - runLoginFlow()      |
            +----------------------+         |   - PKCE + state        |
                                             |   - NIO loopback listener|
                                             |   - HTML success page    |
                                             +-----------+-------------+
                                                         |
                                                         v
                                             +-------------------------+
                                             |   SsoSessionStore        |
                                             |   AES-GCM + HKDF +       |
                                             |   hardware UUID          |
                                             |   credentials.enc        |
                                             +-----------+-------------+
                                                         |
                +----------------------------------------+
                |
                v
   +-----------------------------+
   |  SsoTokenProvider (actor)   |   <-- single entry: validToken()
   |  - lazy refresh on use      |       lazy refreshes via POST /oauth/token
   +-----------+-----------------+
               |
       +-------+--------+--------------------+--------------------+
       v                v                    v                    v
 +------------+   +-----------+      +----------------+    +---------------+
 | AgoraAPI   |   | ConvoAI   |      | HubManager     |    | SettingsUI    |
 | Bearer →   |   | mints RTC |      | credentialSync |    | identity row  |
 | /api/cli/v1|   | token →   |      | to paired Atem |    |               |
 | /projects  |   | agora     |      |                |    |               |
 +------------+   | token=    |      +----------------+    +---------------+
                  +-----------+
```

## Components

### 1. `SsoSession` + `SsoSessionStore`

Replaces `AgoraCredentials` and `CredentialManager`. Same file path
(`~/Library/Application Support/Astation/credentials.enc`), same encryption
parameters (AES-GCM, HKDF/SHA-256 with the hardware UUID as IKM, salt
`com.agora.astation`, info `credentials`).

```swift
struct SsoSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: UInt64        // unix seconds
    var loginId: String?
    func needsRefresh() -> Bool {
        expiresAt < UInt64(Date().timeIntervalSince1970) + 60
    }
}

final class SsoSessionStore {
    func load() -> SsoSession?
    func save(_ session: SsoSession) throws
    func delete() throws
    var hasSession: Bool { get }
}
```

Old-shape files (those that decode to `{customerId, customerSecret}`) are
treated the same as a corrupt file by `load()` — returns nil. The first run
after upgrade deletes the file so we don't keep stale ciphertext on disk.

### 2. `SsoTokenProvider`

An actor wrapping the store plus refresh.

```swift
actor SsoTokenProvider {
    init(store: SsoSessionStore, ssoUrl: () -> String, urlSession: URLSession)

    /// Loads the session; refreshes if `needsRefresh()`; persists; returns access token.
    /// Throws .notSignedIn if the store is empty, .refreshFailed if the SSO server
    /// rejects the refresh token.
    func validToken() async throws -> String
}
```

Mirrors `Atem/src/sso_auth.rs::valid_token`. The refresh request is
`POST {sso}/api/v0/oauth/token` with form fields `grant_type=refresh_token`,
`client_id=atem`, `refresh_token=<…>`. On success it parses
`{access_token, refresh_token, expires_in}` and persists the new session.

### 3. `SsoAuthManager`

```swift
final class SsoAuthManager {
    init(ssoUrl: String, urlSession: URLSession = .shared, openURL: (URL) -> Void = ...)
    func runLoginFlow() async throws -> SsoSession
}
```

Steps (1:1 with `Atem/src/sso_auth.rs::run_login_flow`):

1. Generate PKCE verifier (32 random bytes → base64url) and SHA-256 challenge.
2. Generate 16-byte base64url state token.
3. Bind a SwiftNIO `HTTP1` server on `127.0.0.1:0`; capture the chosen port.
4. Build the authorize URL:
   ```
   {sso}/api/v0/oauth/authorize
     ?response_type=code
     &client_id=atem
     &redirect_uri=http://127.0.0.1:<port>/oauth/callback
     &scope=basic_info,console
     &state=<state>
     &code_challenge=<challenge>
     &code_challenge_method=S256
   ```
5. `NSWorkspace.shared.open(url)` to launch the browser.
6. Wait up to 5 minutes for the single GET request. Parse `code`, `state`,
   `loginId` from the query (URL-decoded). Validate state matches.
7. Reply with an HTML "Login successful" page (port the markup from
   `Atem/src/sso_auth.rs` so the success UX matches).
8. `POST {sso}/api/v0/oauth/token` with `grant_type=authorization_code`,
   `client_id=atem`, `code`, `code_verifier`, `redirect_uri`.
9. Decode `{access_token, refresh_token, expires_in}` →
   `SsoSession(expiresAt = now + expires_in, loginId)`.

Errors are surfaced as a `LoginError` enum:

- `.loopbackBindFailed(Error)`
- `.browserOpenFailed`
- `.timeout` (no callback in 5 min)
- `.stateMismatch`
- `.tokenExchangeFailed(status: Int, body: String)`
- `.network(Error)`

Reuse the existing `client_id=atem` registration (same as `Atem/src/sso_auth.rs::CLIENT_ID`). No new client registration in the SSO server is needed; Astation is effectively a second deployment of the same OAuth client.

`SsoAuthManager` depends only on a SwiftNIO `EventLoopGroup` and a URLSession,
so it is unit-testable by passing a stub `openURL` closure and driving the
loopback listener from a test harness.

### 4. URL & env-var configuration

| Setting   | Default                       | UserDefaults key      | Env override            |
|-----------|-------------------------------|-----------------------|-------------------------|
| SSO URL   | `https://sso2.agora.io`       | `AstationSsoUrl`      | `ASTATION_SSO_URL`      |
| BFF URL   | `https://agora-cli.agora.io`  | `AstationBffUrl`      | `ASTATION_BFF_URL`      |
| Relay URL | (existing)                    | `AstationRelayUrl`    | `ASTATION_RELAY_URL`    |

Resolution order is the same `env > UserDefaults > default` pattern already
used for the relay URL in `SettingsWindowController.currentAstationRelayUrl`.
The two new keys are read-only for now (no UI to change them; env var is the
escape hatch). They are passed in to `SsoAuthManager` and `AgoraAPIClient` by
their callers rather than read globally inside those classes, so tests can
override them.

### 5. `AgoraAPIClient` changes

```swift
func fetchProjects(accessToken: String, bffUrl: String) async throws -> [AgoraProject]
```

- URL: `{bff}/api/cli/v1/projects`.
- Header: `Authorization: Bearer <accessToken>`, plus the existing
  `Content-Type: application/json`.
- Response envelope: `{ items: [BffProject] }` where
  ```swift
  struct BffProject: Codable {
      let projectId: String         // JSON: "projectId"
      let name: String
      let appId: String             // JSON: "appId"
      let signKey: String?          // JSON: "signKey"
      let status: String
      let createdAt: String         // JSON: "createdAt", e.g. "2025-01-08T00:00:00Z"
      let vid: UInt64?
  }
  ```
- Mapping to the in-memory `AgoraProject` preserves the **wire shape that
  Atems already receive over WebSocket**. Specifically:
  - `id = appId`
  - `vendorKey = appId`
  - `signKey = signKey ?? ""`
  - `name`, `status` passthrough
  - `created`: parse `createdAt` ISO-8601 into unix seconds. If parsing fails,
    fall back to `0` (the existing behavior when `created` was missing).
- On `401 Unauthorized`, throw `AgoraAPIError.unauthorized`. `loadProjects`
  catches that case, calls `SsoSessionStore.delete()`, and surfaces "Session
  expired — please sign in again." in `projectLoadError`.

### 6. `ConvoAIClient` changes

Drop the `credentials: AgoraCredentials` parameter. Add `appCertificate:
String`. Both `createAgent` and `stopAgent` now build a short-lived RTC token
via the existing C bridge:

```swift
let token = astation_rtc_build_token(
    appId, appCertificate, channel, agentRtcUid,
    /* role = publisher */ 1,
    /* expire */ 7200,
    /* privilege */ 7200
)
// ... use returned C string, free with astation_token_free
request.setValue("agora token=\(rtcToken)", forHTTPHeaderField: "Authorization")
```

The body, URLs, and response parsing are unchanged. For `stopAgent`, the token
is regenerated fresh (same as `atem serv convo`'s `leave_token`).

Caller updates: `VoiceCodingManager` and any other site that previously fetched
`credentials` from `HubManager` now passes the active project's `vendorKey`
(appId) + `signKey` (cert) instead.

### 7. WebSocket `credentialSync` rewire

Both Astation and Atem update in lockstep.

**Astation `AstationMessage.credentialSync`** — payload redefined:

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

JSON keys (snake_case): `access_token`, `refresh_token`, `expires_at`,
`login_id`, `astation_id`, `save_credentials`. The `customerId` /
`customerSecret` cases and their `CodingKeys` are removed.

**Astation `AstationHubManager`**:

- `broadcastCredentials()` / `sendCredentials(toClientId:)` call
  `await tokenProvider.validToken()` first, then read the session and emit
  the new `credentialSync`. If `validToken()` throws, the broadcast is
  skipped and a warning is logged — paired Atems will retry on next connect.
- `saveCredentials`: defaults to `false`. If a `pairSavePreference` arrives
  from an Atem during pairing, that preference is captured against the
  client ID and used on subsequent sends. (Existing pair flow logic is
  preserved.)

**Atem side**. The user explicitly chose to repurpose `credentialSync`
rather than send the existing `SsoTokenSync` (even though Atem already
accepts that one). This requires migrating all three `SsoTokenSync` sites
in Atem and updating the `CredentialSync` variant:

1. `Atem/src/websocket_client.rs:223` — `CredentialSync` struct fields
   change from `{customer_id, customer_secret, astation_id}` to
   `{access_token, refresh_token, expires_at, login_id, astation_id,
   save_credentials}`. `#[serde(rename = "credentialSync")]` stays.
2. `Atem/src/websocket_client.rs:236` — delete the `SsoTokenSync` variant
   entirely (no longer reachable once Astation stops sending it and the
   two callers below are migrated).
3. `Atem/src/cli.rs:1144` (`atem pair` blocking loop) — change the
   `match Some(SsoTokenSync { … })` to `match Some(CredentialSync { … })`.
   Body is identical: build `CredentialEntry::new_paired(...)` and persist.
4. `Atem/src/app.rs:2017` (TUI dispatcher) — same rename:
   `AstationMessage::SsoTokenSync { … } =>` becomes
   `AstationMessage::CredentialSync { … } =>`. Body is identical.
5. Delete the old `customer_id`/`customer_secret` handler for
   `CredentialSync` if one exists; the new shape replaces it entirely.
6. Tests at `websocket_client.rs:1711` (`credential_sync_roundtrip`),
   `:1737` (`credential_sync_deserialize_from_json`), and the three
   `sso_token_sync_*` tests at `:2079`/`:2112`/`:2135` — rewrite the
   first two for the new payload, delete the last three.

Wire compatibility note: this is a coordinated change. An older Atem
build talking to a new Astation will fail to decode the new
`credentialSync` payload (missing required fields). Acceptable because
Astation and Atem ship from the same monorepo and we control rollout.

The Astation build owns the source of both sides via the monorepo, so we
update both in the same PR.

### 8. Settings UI

`SettingsWindowController` keeps:

- Server Info section (relay URL, WebSocket endpoints) — unchanged.

Replaces:

- The "Agora Console Credentials" section (Customer ID / Customer Secret
  fields, Save, Delete) is removed.

Adds:

- **Agora Account section**:
  ```
  Agora Account
  ─────────────
  Signed in as: brent@agora.io          ← when logged in
  Token expires in: 59m                  ← formatted from expiresAt
  [ Sign out ]

  -- OR --

  [ Sign in with Agora ]                 ← when logged out
  (status line for in-flight / error)
  ```
  - "Sign in with Agora" → spawns `Task { try await
    SsoAuthManager().runLoginFlow() }`. Disables the button, shows
    "Waiting for browser…". On success: persists the session, posts
    `.credentialsChanged`, refreshes the UI. On `LoginError`: shows the
    message inline with a Retry button.
  - "Sign out" → `SsoSessionStore.delete()`, clears `HubManager.projects`,
    posts `.credentialsChanged`.

**Menubar**: `StatusBarController` adds a single new menu item that mirrors
the same state — `Sign in with Agora…` when logged out, or `Signed in as
<loginId>` (disabled label) + `Sign out` (action) when logged in.

### 9. Notifications

The existing `Notification.Name.credentialsChanged` is reused as the single
fan-out signal for "the SSO session changed (login, logout, or refresh)".
`AstationHubManager.handleCredentialsChanged` is renamed `handleSessionChanged`
and re-runs:

1. `refreshProjects()` (which now needs a token).
2. `broadcastCredentials()` (which now ships the new payload to all paired
   Atems).

## Error handling

| Failure                             | Behavior                                                       |
|-------------------------------------|----------------------------------------------------------------|
| Login: loopback bind fails          | Show `LoginError.loopbackBindFailed` with retry                |
| Login: state mismatch               | Show error; do not store anything; retry button                |
| Login: 5-min timeout                | Show "Login timed out"; retry button                           |
| Login: token exchange HTTP error    | Show status + truncated body; retry button                     |
| API call: 401                       | Delete session, post `.credentialsChanged`, show "Sign in again"|
| Refresh: 4xx/5xx                    | Same as 401 — treat session as dead                            |
| ConvoAI: no active project          | Existing error path (no project selected) is unchanged         |
| WS broadcast: no session            | Skip; log info; paired Atem will not auth until login          |

## Tests

Unit tests (new files in `Tests/`):

- `SsoSessionStoreTests.swift` — round-trip via a temp file path; old-shape
  files return nil; corrupted files return nil; file permissions are `0600`.
- `SsoAuthManagerTests.swift` — PKCE generator produces base64url(SHA256(v));
  state is unique; query parser handles missing / extra / URL-encoded params
  (port Atem's tests); end-to-end loopback test with a stub openURL closure,
  a synthetic HTTP request driver, and a mocked URLSession returning
  `{access_token, refresh_token, expires_in}`.
- `SsoTokenProviderTests.swift` — fresh token returned without HTTP call;
  near-expiry triggers refresh and persists the new tokens; refresh failure
  deletes the session and throws `.notSignedIn`.
- `AgoraAPIClientTests.swift` — Bearer header present; BFF→AgoraProject
  mapping (`appId`, `signKey`, ISO-8601 date parsing); 401 throws `.unauthorized`.
- `ConvoAIClientTests.swift` — Authorization header equals `agora token=<…>`;
  body shape unchanged.
- `AstationMessageTests.swift` — `credentialSync` codable round-trip with all
  fields; missing optional `login_id` decodes correctly.

Atem side: rewrite `websocket_client.rs::credential_sync_roundtrip` and
`credential_sync_deserialize_from_json` for the new payload; delete
`sso_token_sync_roundtrip`, `sso_token_sync_deserialize_from_json`, and
`sso_token_sync_without_login_id` (`websocket_client.rs:2079`–`:2154`).

Manual smoke (post-merge):

1. Fresh install → Settings shows "Sign in with Agora".
2. Click → browser opens, log in → success page → Settings shows identity.
3. Pair an Atem → run `atem list project` from Atem → projects returned via
   BFF.
4. Voice coding session → ConvoAI agent joins channel.
5. `defaults delete com.agora.astation AstationSsoUrl` and set
   `ASTATION_SSO_URL` env var → flow uses the override.

## Migration

On first launch after upgrade:

```swift
// During SsoSessionStore.load(), if decryption succeeds but the JSON has
// "customerId" or "customerSecret", treat as old-shape: delete the file
// and return nil. A one-time `Log.info` notes the deletion. The user sees
// the unchanged "Sign in with Agora" prompt in Settings.
```

No data is preserved across the migration — customer ID/secret pairs can't
be derived from an SSO session.

## Out of scope (YAGNI)

- Per-Atem paired-credential store on the Astation side. Astation has exactly
  one Agora session (its own SSO login). Note: the existing
  `Sources/Menubar/SessionStore.swift` keeps a per-Atem **session-token**
  registry (relay auth) which is unrelated and stays as-is — that store is
  about "who may talk to me", not "what Agora credentials to give them".
- Web-paste-URL fallback for failed loopback (browser-issue case). Show the
  error and retry.
- Auto-refresh on a timer. Lazy-on-use only.
- Multiple-account UI. One session per machine.
- `Logout` from the menubar pop-up notification. Settings + menubar item is
  sufficient.

## Open questions

- BFF endpoint shape: this design assumes `/api/cli/v1/projects` is the same
  endpoint Astation should use (it's what Atem uses). If the SSO/BFF team
  prefers a different path for desktop apps, it's a one-line change to the
  default constant.

## File touch list

New:

- `Sources/Menubar/SsoSession.swift`
- `Sources/Menubar/SsoSessionStore.swift`
- `Sources/Menubar/SsoAuthManager.swift`
- `Sources/Menubar/SsoTokenProvider.swift`
- `Tests/MenubarTests/Sso*Tests.swift` (5 files per the test list)

Modified:

- `Sources/Menubar/CredentialManager.swift` → delete (replaced by
  `SsoSessionStore`)
- `Sources/Menubar/AgoraAPIClient.swift` → Bearer + BFF mapping
- `Sources/Menubar/ConvoAIClient.swift` → `agora token=<rtc_token>`
- `Sources/Menubar/AstationMessage.swift` → new `credentialSync` payload
- `Sources/Menubar/AstationHubManager.swift` → `tokenProvider`, broadcast,
  loadProjects refactor
- `Sources/Menubar/SettingsWindowController.swift` → Agora Account section
- `Sources/Menubar/StatusBarController.swift` → menubar Sign in / out item
- `Sources/Menubar/VoiceCodingManager.swift` (and other ConvoAI callers) →
  pass appId + signKey
- Atem `src/websocket_client.rs` → `CredentialSync` payload swap + remove
  `SsoTokenSync` variant + rewrite credential_sync tests + delete
  sso_token_sync tests (lines 2079–2154)
- Atem `src/cli.rs:1144` (`atem pair` blocking match) → use `CredentialSync`
- Atem `src/app.rs:2017` (TUI dispatcher match) → use `CredentialSync`
- `CLAUDE.md` → update the "Mark Task Routing" section's adjacent
  credentials notes to mention SSO instead of customer_id/secret
