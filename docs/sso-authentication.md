# SSO Authentication Design

This document describes the implemented account login architecture. Device
pairing is a separate protocol documented in
[Device Authentication v2](specs/2026-07-21-device-authentication-v2.md).

## Architecture

```text
Settings / menu Sign In
         |
         v
SsoAuthManager -- system browser --> Agora SSO
         ^                              |
         |   loopback OAuth callback    |
         +------------------------------+
         |
         v
Authorization code + PKCE verifier --> token exchange
         |
         v
Hub saves session --> SsoSessionStore (encrypted local file)
                              |
                              v
                       SsoTokenProvider
                              |
                              v
                    Bearer token for Agora BFF
```

The app uses browser-based OAuth 2.0 with PKCE instead of accepting manual Agora
customer credentials. It reuses the registered OAuth client ID `atem` and requests
the `basic_info,console` scope.

## Login and token lifecycle

1. `SsoAuthManager` generates a PKCE verifier/challenge and random state.
2. It binds the loopback callback listener before opening the browser, using
   `http://127.0.0.1:<allocated-port>/oauth/callback` as the redirect URI.
3. The browser visits `/api/v0/oauth/authorize`. The callback is checked against
   the expected state; the default login timeout is five minutes.
4. The manager exchanges the authorization code and verifier at
   `/api/v0/oauth/token`, then makes a best-effort userinfo request for a display
   name. Failure to fetch a display name does not invalidate login.
5. The hub persists the returned session. `SsoTokenProvider.validToken()` loads
   that session and refreshes on demand when its expiry requires it. There is no
   background refresh timer.

Refresh uses `grant_type=refresh_token` and preserves the saved display name. The
current provider deletes the stored session if refresh or saving the refreshed
session fails. The caller then handles the error and subsequent sign-in. The
provider is an actor, but does not maintain a shared in-flight refresh task;
actor isolation alone should not be treated as a promise to deduplicate network
refreshes across suspension points.

## Session storage

`SsoSession` stores the access token, refresh token, expiry, and optional login
identifier. `SsoSessionStore` encrypts the JSON with AES-GCM and writes it to:

```text
~/Library/Application Support/Astation/credentials.enc
```

The encryption key is derived with HKDF/SHA-256 from the Mac's hardware UUID,
using salt `com.agora.astation` and info `credentials`. The saved file has mode
`0600`. This file is tied to its originating Mac and is not a portable credential
backup.

Loading an unreadable or invalid session returns no session. Recognized legacy
customer-credential payloads are deleted so the user signs in again through SSO.

## Consumers and boundaries

- `AgoraAPIClient` uses the access token as a Bearer token for the Agora BFF.
- `ConvoAIClient` uses a minted RTC token with `Authorization: agora token=...`;
  it does not reuse the BFF Bearer header for that API.
- The hub sends the SSO-shaped `credentialSync` payload to authenticated Atem
  clients. Device authentication controls who can receive account credentials.
- Android sharing uses a separate raw ADB TCP endpoint; SSO login and Atem pairing
  do not authenticate clients of that endpoint.

`SsoConfig` resolves SSO/BFF URLs from environment overrides, then UserDefaults,
then built-in defaults. See [README configuration](../README.md#configuration)
for exact setting names and values.

## Source and verification

The implementation lives in `Sources/Menubar/SsoAuthManager.swift`,
`SsoLoopbackListener.swift`, `SsoSession.swift`, `SsoSessionStore.swift`, and
`SsoTokenProvider.swift`. Related tests cover PKCE/callback handling, token
responses and refresh, encrypted storage/migration, and SSO message encoding.
Changes to login or credential synchronization should be checked against both
these tests and the authenticated-client routing tests.
