# Account identity integration

Status: implementation for Astation #63. Auth's integration contract is pinned
to Agora-Build/Auth `bc1bfe727e8da52fc95b16354d610c050a8b5e2c`,
`docs/integrating.md`. This supersedes the old identity specification's claim
that the identity service has no implementation. Deployment and Astation's
client/resource registration still need to be verified.

## Separate accounts and service connections

The agora.build account session authenticates relay account registration and
recovery storage requests. The existing Agora session remains the separately
consented service connection used for projects, RTC credentials and
`credentialSync`. Neither token is substituted for the other.

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
The stable subject is Auth's permanent `acct_` identity, never email. Session
secrets are stored separately in the device-only Keychain. Refreshes are
serialized and share one in-flight operation. A rotated refresh token is saved
before its access token is exposed. An uncertain refresh or failed persistence
requires sign-in; an old refresh token must not be sent again. Sign-out fences
late refresh/login replies and does not remove device keys or recovery state.

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

The issuer still fails DNS resolution from this Mac. No deployed Astation
client/resource registration has been confirmed, and this relay change has not
been deployed. These tests establish the implementation against controlled
issuers, not a completed production login or live r9 verification ceremony.
