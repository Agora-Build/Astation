# Station integration lifecycle

This increment consumes the published Auth and Portal contracts without
waiting for a larger release. Hosted execution remains hard disabled in
`station_ai.rs`. No native approval screen, Station provisioning endpoint,
background feed poller or hosted agent execution adapter is enabled by these
components. Their wiring is the next increment, followed by the full live flow.

## Contract pins and open follow-ups

- Auth PR #9: `d7de4416e74f2fcc85dcf4befa0a6bd8ad9ffb64`, merged `ca657bb`.
  The exact 42 public token vectors are pinned in the relay test fixtures.
- Portal PR #15: `bda6824c874afae1d878f10d47054d5513381c80`, subsequently
  merged as `ee57da31fb3b4b5a7c5f0f4aa383b420c1735a39`.
  Reports, report-token issuance and the existing feed envelope are consumed.
- [Portal #16](https://github.com/Agora-Build/Portal/issues/16) requests
  `ownerAccount` on every full integration snapshot, plus a defined repair
  for an ahead cursor after a Portal restore. The parser requires owner
  metadata and refuses the older incomplete snapshot. This is a specific
  shared-Station provisioning blocker, not a reason to stop component work.
- R9 contract, host and consumed client pins remain unchanged:
  `c685abab`, `6526e1cf` and `83c0776d` respectively. Atem owns those sources.

## Consent and publication

`RemoteServiceApproval` binds one operation ID, integration ID, Auth issuer,
verified owner account, genesis, selected custom HTTPS Station origin,
exact canonical R9 add body and service-key
fingerprint. The application must show its actual account/root, service key,
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
log and requires a new approval for a different body.

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
Re-enrollment is an explicit new native approval. Operator key-file loading,
rotation and backup wiring remain work for provisioning; the component is
not an unattended secret-configuration interface.

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
never set a cursor, owner, policy, readiness or trusted log head. Nudge route
and bounded poll-loop wiring wait for the Portal #16 recovery contract; no
placeholder endpoint claims to consume it today.

## Activation and remaining gates

1. Finish authenticated pending-service provisioning, the native review UI
   and account/operation fencing; consume Portal #16's owner/recovery fix.
2. Wire report-key/operator storage, durable feed polling and current-policy
   checks with account access and quotas across replicas.
3. Connect typed sessions/history/prompts/approvals/receipts/events APIs to
   the existing shared atem-client service channel. Keep unsupported authority
   unavailable; never implement a second R9 stack or infer readiness from a
   stored log entry. Require a verified service welcome from the target host.
4. Prove actual Auth issuance, native confirmation, protected persistence,
   host admission/execution, reconnect/revocation and operation with the Mac
   offline before enabling any hosted integration operation.

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

Hosted execution, Discord, MCP and LLM admission remain disabled. No live
account/trust migration, app replacement, main merge or deploy occurs here.
