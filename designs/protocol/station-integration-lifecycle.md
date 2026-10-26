# Station integration lifecycle

The native approval screen, protected provisioning endpoints, authenticated
background feed polling and typed hosted agent adapter are wired. Hosted
execution remains hard disabled by `HOSTED_EXECUTION_ENABLED = false` in
`hosted_agents.rs`; MCP/LLM and legacy voice routes retain their closed gates.
The implementation is available for review and controlled tests, not activation.

## Contract pins and remaining interoperability

- Auth PR #9: `d7de4416e74f2fcc85dcf4befa0a6bd8ad9ffb64`, merged `ca657bb`.
  The exact 42 public token vectors are pinned in relay tests.
- Portal PR #17: `83e6543592b6142fca6bf02a15ce302194b8b828`, merged
  `efde3bc1a7aa796ac301e776c5512350dcf5f6ac`. It closes Portal #16:
  authenticated snapshots include `ownerAccount`; HTTP 409 with
  `code: cursor_ahead` requires a full cursor-zero reconciliation.
- R9 contract and host pins remain `c685abab` and `6526e1cf`. The consumed
  Rust and verified Apple client package now pin
  `04140840fc0cec4086072ab6326b7a1b46b25be4` (Atem PR #98). Fingerprinting
  delegates to the shared helper; wire and signature formats are unchanged.
- [Portal #18](https://github.com/Agora-Build/Portal/issues/18) is closed by
  test-only Portal #19, tested `998301e8` and merged `7319e365`.
  Real-HTTP device-flow tests against Auth `ca657bb` and its reference Station
  verifier establish exact custom-resource native issuance and
  owner/resource/client/audience refusals. Auth drops unavailable scopes and
  can return HTTP 200 with empty scope; both native and Rust Station consumers
  already refuse missing required scope. This does not establish actual native
  PKCE/protected approval/real Rust Station and Atem host interoperability.
  Never forward a public-resource bearer to an unrelated localhost origin.

## Consent and publication

`RemoteServiceApproval` binds one operation ID, integration ID, Auth issuer,
verified owner account, genesis, selected custom HTTPS Station origin,
exact canonical R9 add body and service-key
fingerprint. Settings > Integrations shows the actual account/root, service key,
host/session/project scope, operations, expiry and predecessor for native
manager approval. No extra fields are added to the signed R9 body.

The manager must be an active native member with manage authority. The
core's draft-entry builder checks the existing body against the anchored log
and real signed-at time. Service-only roles, no account encryption key,
expiry and the current membership head are checked before preparation and
again before signing. A changed account, setup context or head requires new
consent. The application also rechecks its live operation/account generation
around asynchronous confirmation. Use existing Touch ID / Face ID / supported
OS password fallback; a Portal checkbox cannot substitute for it.

The entire immutable consent context is persisted in the protected native
membership-publication checkpoint before a key provider is called. The
existing fresh, single-use confirmation wrapper signs only that exact stored
request. Signature and body survive a restart; uncertain storage stops the
operation until a protected-store reload. A lost append reply retries the
same saved signature and expected head. A CAS conflict verifies the winning
log and requires a new approval for a different body. Leaving the screen does
not erase the checkpoint. "Review Changed Request" can clear an unsigned review;
a signed review is retained until an independently anchored winning entry at
the same sequence proves it was superseded. Its checkpoint and consent are
archived before preparing a replacement (at most 16 retained reviews). A
committed service cannot be discarded through this action.

`PortalIntegrationHTTP` uses a separate native scope profile
`integrations:read integrations:approve` for the configured Portal resource.
It captures the verified owner session and filters owned pending integrations for the selected Station and refuses a
stale list. Before POSTing `{r9Svc}` it requires the exact entry to exist in
the committed publication, the original stored consent context, an active
unchanged service member, current expiry and the same fingerprint. Signing
alone cannot authorize this call. A lost HTTP reply is reconciled through
the integration list; the transport does not replay the POST automatically.
The response is Provisioning, never evidence of host readiness.

## Protected keys

Station holds a distinct P-256 R9 service key per integration. Its AEAD
context binds configured issuer, owner account, integration, selected Station,
genesis and service principal. A separate operator-protected wrapping key
encrypts PKCS8 material with AES-256-GCM and a random nonce. Postgres holds
only that encrypted envelope and public metadata. Neither native account K,
native identities nor Portal refresh tokens are copied to Station.

The encrypted record must commit before its public key is returned for
approval. Concurrent pending creation uses the winning stored key. Loading
an approved identity checks its expected current R9 fingerprint and never
generates a replacement after loss, corruption or a wrong wrapping key.
Re-enrollment is an explicit new native approval. Operator key files are bounded regular files, refuse symlinks and group/world
permissions, and are never generated or replaced at startup. The separate
durable fingerprint is saved before public-key exposure, so deleting a pending
key after a draft was exposed cannot silently rotate it either. See
[deployment instructions](../../DEPLOY.md#custom-station-integrations) for
operator backup and replacement procedures.

The service key implements the shared `KeyProvider` and signs only the
domain-separated ChannelClient transcript hash for its own key ID. Membership,
recovery, browser delegation, host signatures, X25519 and HPKE are refused.
The Station report key is a separate type and cannot be used as an R9 key
provider. Registration sends only its public JWK to Portal.

## Authenticated current policy

`PortalReportClient` authenticates as the registered `s-...` report client
using private_key_jwt: unique jti, iss=sub=client, iat=now, exp=now+60 and
audience `<configured issuer>/token`. It requests only station.report for
the pinned Portal origin. Token caching is local and bounded by the returned
lifetime, measured from before the request. Redirects, unbounded documents
and credential forwarding to a discovered caller-selected endpoint are refused.

The authenticated feed alone supplies current Portal control metadata. Its
event IDs are globally increasing safe integers, with legitimate gaps between
one Station's events. Historical event.state never overrides the current
integration snapshot, including on unknown event kinds. A full snapshot
reconciles removals; it does not replace private keys, signed R9 membership or
native consent. Owner metadata is mandatory and an integration ID cannot
silently move to another owner.

Policy, cursor, freshness, denial and a local revision commit atomically in
one Postgres CAS checkpoint. An older response cannot overwrite a newer
revocation across replicas. A Portal 401/403 durably denies the checkpoint
under a row lock and invalidates the cached report token. A network outage
does not advance freshness. The current-policy accessor refuses snapshots
older than 120 seconds (an additional local admission bound), clock rollback,
owner mismatch and expiry. A caller must still require the appropriate
state/operation and current host-verified R9 authority before dispatch.

An unsigned `{cursor}` nudge is only a coalesced request to poll. It must
never set a cursor, owner, policy, readiness or trusted log head. The POST nudge route wakes the background worker. Startup reconciles from zero;
normal polling is once per minute. Full pages and conflicts drain promptly,
with an atomic Postgres claim limiting the whole replica fleet to one feed
request per second. Only the exact authenticated `cursor_ahead` response clears
the cursor through a durable denial fence; an unrelated 409 does not. After a
known Portal restore, restart workers to force cursor-zero reconciliation even
when the restore is not detectable as an ahead cursor.

Readiness reports use the separate Station report credential. With the hosted
gate closed they retain `waiting_for_host` and explain the verification gate;
they never advertise Ready. The readiness adapter requires an authenticated R9
service welcome and registry from every allowed host before it can report
Ready after activation. Reports recheck current policy, are bounded to eight
integrations per cycle and four concurrent checks, and reconcile via the feed.

## Activation and remaining gates

Implemented: native review and durable approval retry, protected operator/service
keys, native-authenticated provisioning, owner-bound Portal polling and
cursor recovery, fleet quota checks, and typed shared-client sessions/history/
prompts/approvals/receipts/events APIs. The HTTP API and its limits are in
[hosted agent API](station-hosted-agent-api.md).

Activation still requires actual native custom-resource Auth issuance, owner
confirmation and persistence, a pinned/released host, selected-relay-only
same-generation stored-policy ACKs, real-agent admission/execution and
revocation, reconnect, Mac-off and replica tests. Controlled cryptographic
host tests and test tokens do not satisfy this live gate. There is no
runtime environment switch to bypass it.

The two Atem #96 review findings are addressed by merged
[Atem #97](https://github.com/Agora-Build/Atem/pull/97), `8815bf766ef515f2d72eced75d47aa5b92d47789`.
The source adds a polled writer-receipt barrier on immediate and deferred
close, a five-second bound, link-generation fencing and fail-closed reads
independent of config.toml. Focused paused-writer/save-failure/real-runtime
restart tests and successful CI `40170347648` were reviewed, without building
or changing an Atem checkout. The previous findings do not remain unresolved
code objections. They still require a released or explicitly pinned host and
joint live verification before selected-relay-only activation. Native accepts
only stored:true with the expected value on the same authenticated generation;
loss or timeout never enables the integration.

### Native transport-policy reconciliation

The previous revision described native ACK enforcement before it was wired.
The native controller now persists the desired account/issuer/selected-Station
policy and complete verified host set before sending any change. No saved
policy means no automatic `false`: another controller's host policy must not
be cleared merely by opening Astation. A storage fault blocks admission until
the checkpoint can be reloaded.

Each pending request captures the authenticated device and local verification
key pin, pairing session, connection and transport generation before dispatch.
Only the expected value
with `stored:true` on that same current context, before its monotonic deadline,
confirms it. Host refusal, timeout, disconnect, account change and reconnect
remove confirmation. Reauthentication sends the durable desired value again.
An opposite policy change reconnects an already-used transport before resending:
the existing wire has no request ID, so a true/false/true change on one socket
would make an old true ACK indistinguishable from a new one.

While relay-only is desired, direct agent channels are denied immediately;
the shared listener and credential protocol remain available to complete
policy migration. A direct ACK never establishes relay readiness. Every host
in the verified membership must acknowledge on the current selected relay;
offline hosts keep the account transition pending. These policy ACKs do not
establish device identity or grant service authority: signed membership and
the authenticated R9 host channel remain independently required. Hosted
execution remains hard disabled during this work.

The desired policy shares the existing durable session security journal.
Version 2 retains version-1 receipts and trust floors on load; writes use
version 2 so older journal readers fail closed instead of silently dropping
transport policy. ACKs themselves are never restored as live confirmation.
Settings > Integrations exposes an explicit relay-only request and a separate
allow-direct action, with confirmation. Neither action enables integrations.

Hosted execution, Discord, MCP and LLM admission remain disabled. No live
account/trust migration, app replacement, main merge or deploy occurs here.

## Validation of this increment

Local validation on 2026-10-25:

- Relay: 545 regular tests pass; 130 environment cases are not selected in
  that run. All 65 explicitly selected isolated Postgres cases pass with
  zero skips, including real encrypted service-channel and WebSocket adapter
  traffic, policy denial, same-key renewal, rich history and fleet polling.
- Native library: 138 tests, one optional OIDC environment skip, no failures.
  App recovery coordinator: 25 tests, no failures, including uncertain relay/
  Portal replies, restart without re-signing, account change during owner
  confirmation and an anchored competing head.
- App build and production Rust check pass. The verified prebuilt Apple
  dependency passes its 19 production consumer checks.
- Full unsigned app run: 1013 tests, 14 skips, four failures. Three protected
  identity tests cannot create Secure Enclave keys in this unsigned process;
  the existing caption-scroll test fails its scroll-position assertion on
  this Mac. Excluding exactly those four cases: 1009 tests, 14 skips, no
  failures. These exclusions are verification gaps, not passing evidence.
- The saved personal provisioning profile expired on 2026-10-24. An isolated
  signing refresh attempt fails because Xcode cannot load account credentials
  (`No Accounts` / no matching profile). No app is replaced or relaunched.

Previous d566cd7 CI is green (40173354182), but is not validation of this new
increment. Real owner authentication and real Auth/custom-Station issuance,
host execution, Mac-off and replica admission remain release gates.

## 2026-10-26 verification follow-up

- Implemented native policy sending/reconciliation, direct-agent gating and
  explicit Settings controls described above. Fourteen new policy tests cover
  actual wire decoding, persistence/restart, save faults, exact deadlines,
  wrong/refused/duplicate ACKs, account/pairing/generation/key-pin changes,
  offline hosts, unknown hosts and rapid true/false/true changes. Two additional
  Hub tests exercise authenticated relay sends/reconnects and direct-channel
  migration without removing the pairing.
- Full app test run: **1,026 tests, 14 skips, zero failures**, excluding exactly
  the three previously failing protected identity tests
  `testRealProtectedIdentityReloadsRecoveryPinsAndEpochs`,
  `testRealSecureEnclaveMaterialSealsEncryptionKeyAndSigns` and
  `testRealProtectedMigrationJournalRecoversAndCommitsOnceAfterIdentityReload`.
  These excluded cases remain unverified. The caption-scroll test passes in
  this run. After the final status-message change, all 40 selected policy/Hub
  tests pass with zero skips/failures. The app builds successfully.
- Retried automatic personal-team provisioning in a fresh DerivedData directory.
  The development certificate is valid, but renewal still exits 65 with
  `No Accounts` and no matching Mac App Development profile. The user's personal
  Xcode sign-in is required before protected tests can run. No existing signed
  app was replaced or relaunched.
- The installed local Atem reports session r8 and is unsuitable as r9 host
  evidence. A disposable fixing host/session and registered custom Station
  are requested from the Atem/Portal agents through #81 and the shared vaults.
  No production pairing/profile or credential agent was changed.
- Hosted execution remains hard disabled. The real native/host execution,
  revocation/reconnect, policy persistence, Mac-off and replica matrix has
  **not run** in this follow-up.
