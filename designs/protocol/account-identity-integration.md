# Account identity integration

Status: Astation account login uses the configurable agora.build portal and OIDC
issuer. Current development URLs are `https://dev.agora.build` and
`https://auth.dev.agora.build`; discovery and the portal auth configuration are
reachable as of 2026-10-23. The login/project integration and registration
handoff are in [agora-build-login.md](../../docs/agora-build-login.md), reviewed
against Auth PR #8 `edef0b8` and Portal PR #13 `a211c7a`. App APIs use
`/api/v1/...` and the resource is the exact Portal origin, without a trailing
slash. Portal login worked before that audience/API migration; the new grant
needs sign-in again. The separate Station grant/deployment and live relay
recovery ceremony remain unverified. Shared handoff: vault `v-xZDT9aGD`.

## Separate accounts and service connections

The agora.build portal grant reads the linked Agora account's projects and
fetches certificates on demand. At the user's request, native token generation
uses the shared local Atem library, with previously loaded project credentials
stored in the device-only Keychain for offline use. The cache is isolated by
account and environment and cleared on sign-out; it conveys no relay or device
authority. Upstream Agora tokens remain on the portal.
Relay account/recovery requests use a separate resource grant for the same
issuer and subject. Previously consented legacy service credentials remain
isolated for existing Atem consumers; neither account token substitutes for
those credentials. No direct Agora login remains in the native UI.

Native login uses issuer discovery, a public client, PKCE S256, state and nonce,
and a random-port `http://127.0.0.1:<port>/callback`. It requests the registered
API `resource` and scopes. `offline_access` requires `prompt=consent`.
Configuration comes from the operator's actual client/resource registration;
the example Atem client in Auth's documentation is not an Astation registration.

Discovery must match the configured issuer exactly. Back-channel endpoints
stay on its origin; HTTP is allowed only for explicit loopback development.
Token requests follow no redirects, carry no ambient cookies, and use bounded
responses. The callback accepts GET on the exact path, a single matching state
and a single code; unsolicited requests never finish the pending login.

The app verifies ES256 access and ID tokens against discovered signing keys,
including token type, issuer, audience, lifetime, scope and ID-token nonce.
The stable subject is Auth's permanent `ab` + Crockford ULID identity, never email.
Access tokens stay in memory; refresh credentials and account/configuration
binding are stored in the device-only Keychain. Refreshes are
serialized and share one in-flight operation. A rotated refresh token is saved
before its access token is exposed. An uncertain refresh or failed persistence
requires sign-in; an old refresh token must not be sent again. Sign-out fences
late refresh/login replies and does not remove device keys or recovery state.
Portal 401s share a single refresh and one retry; `reconnect:true` instead
retains the Agora.Build login and asks for Agora Console reconnection.

## Live pairing bootstrap gap (2026-10-28)

The [pairing and service authorization design](pairing-and-service-authorization.md)
records the owner-approved separation, guided native flow, diagram, trust
boundaries, candidate v1 wire and joint tests. The native candidate is
implemented; Atem's wire confirmation and receiver build remain required.

The provisioned native app reaches the selected dev Station. For the
`DP4E-QG58` attempt, the native log records the dev WebSocket URL at
18:22:01.996 UTC; the Station records the native owner joining the host's
existing pairing room at 18:22:02.051 UTC. The host subsequently times out.
Changing the relay URL is not the remedy for this attempt.

The native `connectToRelay` path in that running build called `sendCredentials`, which
requires the legacy Agora service session. With only Agora.Build login, it
logs `No session - skipping credentialSync` and sends no identity handoff.
Read-only inspection of joint Atem source `e7dff6d` confirms its
`runtime/ops.rs::credentials_from` waits for `CredentialSync` before learning
the Astation identity and opening its authenticated identity connection.
Pairing therefore still depends on an obsolete service-token prerequisite.

The joint correction must separate host pairing from optional upstream
service credentials. A token-free, explicitly versioned bootstrap may supply
the native routing identity; it must not grant device membership or supply
trusted account identity. The existing authenticated identity connection,
safety-code comparison, owner authentication and signed membership ceremony
remain required. Portal and Station access/refresh tokens must never be
substituted into legacy `credentialSync`, and empty or fabricated credentials
must not be used to make the old receiver proceed.

Atem owns the receiver and CLI state changes; Astation owns the sender and
visible pairing progress/errors. The native candidate removes automatic
credential sharing, correlates the introduction with the identity link and
waits for the existing durable verification callback. The candidate message
shape and new joint host pin require confirmation on Atem #81 before the
real joint ceremony. Regression
coverage must include Agora.Build-only login with no legacy session, refusal
without the required native account state, expired/missing rooms, disconnect,
account/relay changes during asynchronous work, duplicate attempts, and
absence of account bearer/refresh tokens from pairing traffic. This remains
a live pairing blocker, not a completed fix or an integration approval.

## Relay boundary

The relay accepts API access tokens only: ES256, `typ=at+jwt`, the configured
issuer and resource audience, unexpired lifetime and required scope. ID tokens,
opaque userinfo tokens and Agora service tokens cannot pass this check. The
configured issuer supplies discovery; a token cannot select an issuer or key
URL. JWKS are bounded, cached for at most 60 seconds and refreshed with a
bounded cooldown for unknown keys. Expired caches fail closed during outages.

Every `(issuer, subject)` maps to a durable internal login principal. The
migration records existing Agora subjects in the `legacy:agora` namespace
without changing any data-account IDs, device IDs, signed roots, K, ciphertext,
pending recovery operations or merge requests. New OIDC identities cannot
collide with or silently claim those legacy bindings. A registered device's
login principal cannot be changed by ordinary registration; an explicit
verified migration is required. No email matching or automatic account merge.

Login grants visibility to stored signed logs and sealed backups. Membership,
genesis, device keys, host-signed freshness proofs and recovery signatures
remain authoritative for trust and key access. The relay never approves a
device or an encryption transition merely because login succeeded.

Sensitive operations requiring recent authentication must receive a verified
`auth_time` proof. Token `iat` is not such a proof. If Auth does not include
`auth_time` in API tokens, those operations remain unavailable rather than
treating a refresh as fresh owner authentication.

The user confirmed retaining Agora.Build login for the current work. A relay
may be self-hosted or shared while keeping this admission gate, provided its
issuer/resource/scope are explicitly registered. A custom URL alone is not a
trusted token destination. Sharing the service grants no device membership,
decryption key or authority over another user's hosts. No login-free admission
or r9 wire change is introduced here.

## Deployment gate

Register the native Astation public client, loopback redirect, API resource and
scope in Auth's private client configuration. Configure matching app and relay
values, verify issuer discovery from both, and test one sign-in end to end.
Legacy `AGORA_ACCOUNT_*` settings remain unset. No guessed Agora userinfo URL,
identity bypass, re-pair or key reset is part of this integration.

Before production rollout, inventory legacy bindings. Existing bindings are
retained and changes are refused until their explicit migration is approved.
Before claiming #63 resolved live, run the isolated retained r9 verification
operation against the provisioned app and deployed relay. Atem #93 and the
remaining r9 admission gates are separate; this change does not enable them.

## Validation (2026-10-21)

- App: 977 tests, 14 environment-dependent skips, zero failures.
- Native adapters: 87 tests, zero failures. Real P-256 signatures cover token
  validation, signing-key rotation/outages, callback state/nonce, concurrent
  refresh, lost replies, persistence faults and sign-out races.
- Relay: 487 passed, 113 environment-dependent tests ignored in the general
  run. Four account Postgres cases pass separately against disposable schemas,
  including namespace isolation, restart-stable mappings and legacy migration
  preserving grouped data-account IDs and recovery records.
- The signed-token HTTP test covers registration and recovery, wrong-account
  refusal and retrying the exact operation after a signing-key outage.
- All four account boundary tests pass in the provisioned personal-team host,
  including loopback callbacks and Data Protection Keychain read/update/delete
  under a disposable service. The unprovisioned suite skips that Keychain case.
- Two build-metadata tests pass. No live account items or pairing state changed.

The configured dev issuer and portal now answer unauthenticated checks. No
completed user login, deployed Astation client/resource registration or matching
relay configuration has been confirmed. These tests establish the implementation against controlled
issuers, not a completed production login or live r9 verification ceremony.
