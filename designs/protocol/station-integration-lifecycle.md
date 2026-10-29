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
  `ed0b45bad5db0a278c63efe8a464f12d4d548465` (Atem PR #100). Fingerprinting
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
authenticated, correlated durable policy confirmations, real-agent admission/execution and
revocation, reconnect, Mac-off and replica tests. Controlled cryptographic
host tests and test tokens do not satisfy this live gate. There is no
runtime environment switch to bypass it.

The two Atem #96 findings were addressed by merged
[Atem #97](https://github.com/Agora-Build/Atem/pull/97), `8815bf7`: the bounded
writer-receipt barrier and fail-closed policy reads remain part of the host.
A subsequent review found that the outer policy ACK was forgeable by the
relay. [Atem #99](https://github.com/Agora-Build/Atem/issues/99) is answered by
PR #100 at `ed0b45bad5db0a278c63efe8a464f12d4d548465`. Astation accepts R9.8a
for integration and consumes that exact shared Rust/Apple client pin. The
format review has no remaining critical objection; binding E2E and disposable
actual-host verification are still release obligations.

### Native transport-policy reconciliation

The native controller saves account, issuer, selected Station and the complete
reviewed host set before sending. No saved policy means no automatic `false`:
opening Astation cannot clear another manager's policy. Storage faults block
admission until reloaded.

A dedicated policy channel uses the same R9 connection/router/shared verifier
as normal agent channels, but sends only host-policy operations. Each fresh
attachment reads current policy first. Before a mutation is sent, the journal
saves its UUID, original expected revision, desired value and account/root/host/
manager/trust binding. Reconnect retries that exact mutation with fresh wire
correlation; it never converts a retry into a new decision. A superseded result
or another manager's conflicting change requires explicit review and apply.
Uncertain writes are polled within a 15-second monotonic attempt deadline.

Only the shared core's current, bound, durable confirmation can mark a host
ready. The native adapter also checks the current account, issuer, selected
Station, device pin, pairing/link generation, membership head and attachment.
Changed membership is verified before reconnecting. Readiness is never restored
from disk. Every reviewed host must confirm on the selected relay; offline or
new unreviewed hosts keep readiness false. Plaintext policy/ACK codecs and
handlers are removed entirely.

Saving relay-only intent immediately blocks direct terminal/chat/session
operations. An existing direct link may perform the restricted encrypted
migration, then closes on confirmation, refusal, conflict, save failure or
bounded timeout without deleting its pairing. A direct confirmation never
counts as relay readiness. Journal version 3 retains version-1/2 receipts and
trust floors; old readers fail closed instead of dropping mutation identity. Settings >
Integrations exposes explicit relay-only and allow-direct actions.

Native approval can publish reviewed service membership while a host is offline;
that publication does not enable execution. The production gate also prevents
Ready reports. Before opening it, verify actual encrypted policy and service
admission, revocation/reconnect, Mac-off and replicas; native cached readiness
is not Station authority. See the [review and security invariants](host-policy-r9-review.md).

## Verification status (2026-10-28)

Personal provisioning is resolved after Xcode reauthentication, using the
existing personal team and bundle. The renewed profile expires
**2026-11-02 23:59:57 UTC**. The signed pairing candidate in the task worktree
passes strict signature and bundled-resource checks and now replaces the
older running app.
No protected identity test is excluded. Secure Enclave signing, protected
identity/recovery-pin reload, migration journal restart/commit, storage-key
escrow and protected refresh/project/credential storage all pass.

Latest native pairing checks:

- The full unlocked-Mac provisioned suite passes 1,083 tests, with eight
  optional skips, zero failures and no exclusions. Protected Keychain,
  Secure Enclave, recovery, migration and credential tests run and pass.
- The subsequent diagnostic change passes all 21 provisioned pairing-state
  tests. Two opt-in tests against the deployed dev Station pass the stable
  host-route case and refusal of a Station-assigned mismatched host route.
- The retry-generation correction on Atem `03ca230` completed joint
  verification at generation 2 and membership seq 4. The real native service
  approval then published the service add at seq 5; Portal reports
  `waiting_for_host` with the approved fingerprint. Atem #101 `15311db`
  closes the strict reader in source, with macOS/Linux evidence reviewed;
  replacement runtime/package approval remains separate.
  The next session attempt expired during owner authentication; native now
  prepares owner presence before channel init while retaining shared host
  verification and handshake bounds. The `548c486` retry failed locally with
  `notForeground` before init. Native now explicitly activates on Retry and
  waits up to two seconds for AppKit activation to settle, preserving all
  authorization fences and the original confirmation time. The subsequent
  live log shows successful authentication leaving Astation inactive. The
  adapter now explicitly restores its originating visible window and requests
  activation after a successful, current confirmation, before the bounded
  wait. Denied or fenced contexts cannot request focus. The library's
  148 tests pass, with one optional skip. At 22:26:49 UTC the user's retry on
  `34efe40` succeeded: native R9 admission delivered the real Codex registry
  entry `ses-i5py5pldao4d`, matching Atem's disposable-host handoff. Native
  discovery is complete; actual service execution and the remaining joint
  gates are separate. The initial session is historical; Atem now reports
  actual model replies and `ready` activity on `ses-emcvcza5lnsj`, process
  generation `28c9e08d-1b3a-45f1-8a1a-3d06c0969e5e`. Operations still need
  the authoritative complete target from the admitted registry.
  See the [pairing lifecycle](pairing-and-service-authorization.md).
- The replacement integration `i-01m62bpj9tj16evs0bry3k27mf` received fresh
  native owner approval at 23:00:42.637 UTC and expires on 2026-11-04 at
  22:57:08.898 UTC. Its new protected R9 fingerprint is
  `7f53966e81b35717b5cf9fcbce748136f8687123fda87880dfa1e9fce29fedec`.
  Independent read-only checks confirm signed membership head seq 6, a healthy
  non-denied policy feed and `waiting_for_host`. Portal/Auth confirms the
  active service client in [Portal #20](https://github.com/Agora-Build/Portal/issues/20#issuecomment-6482950230).
  The state reason is "Hosted execution awaits end-to-end verification";
  native approval and request replacement are complete. This does not prove
  service token issuance, host admission or agent execution.
- The expired original integration `i-01m5znm96jfztp4nx95v8wg7b2` is revoked
  at Auth but remains `revoking` in Portal. Complete supported signed removal
  of its service member before reporting `revoked`; neither the old signed
  approval nor an Auth-only expiry extension authorizes its replacement.

Earlier R9.8a integration checks:

- **1,032 provisioned app tests, six environment skips, zero failures**, with
  `ASTATION_REQUIRE_KEYCHAIN_TESTS=1` and no exclusions. The skips concern live
  speech/polishing/screen capture or an unavailable-model branch on this Mac.
- **43 focused native policy/Hub tests, zero skips/failures**, including durable
  intent/mutation identity, uncertain writes, duplicates and late replies,
  reconnect, another manager's decision, stale/revoked/re-paired bindings,
  offline hosts and direct migration failure/timeout without losing pairing.
- **139 native library tests, one optional OIDC environment skip, zero failures**,
  plus **23 production Apple consumer assertions**. The published artifact's
  outer digest, payload digests and clean immutable source metadata are verified.
- **42 focused Rust tests, zero failures or ignored cases**, exercising hosted
  HTTP/WebSocket APIs, provisioning, Portal/feed clients, service keys, OIDC and
  integration authorization against isolated Postgres on the same shared pin.
  The headless API uses a controlled encrypted R9 host, not an actual coding
  agent, and does not stand in for native owner consent.

Earlier full CI on implementation `d061429` passed: macOS/relay/web jobs, 545
regular relay tests, all 65 Postgres, 65 Redis and eight load-client cases.
That run is historical evidence; CI must run on the new pushed implementation.

The isolated custom Station is registered on dev. Its actual background worker
obtained an Auth report token and consumed the authenticated Portal feed,
persisting cursor/revision 1 with denial false. Public health returns 200 and
unauthenticated details returns 401. These are real Auth/Portal/Station results;
no integration or native approval is inferred from registration.

Portal supplied the awaiting-approval integration ID and Atem delivered the
disposable policy-capable host and binding E2E, accepted for test integration
at `e7dff6d`. Those deliveries are no longer missing. The current live handoff
is Atem `03ca230`, whose generation-2 joint ceremony and native service approval
have completed. Native R9 session admission and fresh replacement-service
approval have also completed. The separate provisioning refusal is fixed
by resolving the external owner to its exact issuer-scoped storage principal;
policy/token/service-key bindings keep the external owner. Thirteen account
tests, five isolated provisioning tests and three isolated hosted API tests
pass, including different owner/principal namespaces and wrong-issuer denial.
The hosted API tests use a controlled encrypted host, not a real coding agent.
Next verify actual protected service token/channel execution and approvals,
host policy durability, old-service removal, revocation/reconnect, Mac-off and
replica behavior. Native discovery and Atem's reported real model replies do
not establish this service pipeline.
Hosted execution remains hard disabled without an override. No production
trust reset, credential-agent restart, Atem checkout edit/build or production
merge/deploy is part of this verification.

### Revoked service cleanup

Auth/Portal revocation denies new execution before native membership cleanup.
A native manager can then remove an integration already marked `revoking` or
`revoked` by the authenticated Portal. Resolve its exact service fingerprint
against the independently anchored signed membership, show the integration,
Station, service ID and key, and require owner confirmation of the existing R9
`remove` body. Expired grants remain removable; expiry never authorizes a new
grant. Portal metadata cannot supply a different member ID or signing key.

Persist the removal context, prepared body and signature in the same protected
account checkpoint used for enrollment. A lost reply or restart reuses the
exact signed entry. Preparing the first removal upgrades that checkpoint to
version 3 so older native readers fail closed instead of overwriting a saved
removal. Existing version-2 accounts remain readable. Account/Station changes, a changed fingerprint, manager
removal and uncertain storage fence the operation. A competing signed entry
requires review; retain the losing publication as evidence before replacing
it. Only a durable independently verified head change notifies active channels.

Station reports `revoked` only for a fresh, non-denied authenticated `revoking`
policy whose owner, provisioning context and service fingerprint agree with a
verified membership showing that exact service as removed. Missing membership,
an expired-but-present service, or Portal state alone is insufficient. Delete
the corresponding sealed service key durably before reporting completion.
Retries and replicas may repeat the idempotent report; they never manufacture
a membership signature or replacement key. Cleanup remains available while
hosted execution is disabled and after the integration expiry. No live trust
edit is performed without the native owner's actual confirmation.

Implementation verification on 2026-10-29: the native Integrations screen loads
revoking/revoked records and offers **Remove Revoked Access** for a matching
verified service or saved removal. Its action uses the existing coordinator,
publisher and owner-confirmed signer. Station's bounded background worker
verifies removal and deletes only that service's sealed key before reporting.

The full provisioned native suite passes **1,100 tests, eight optional skips**;
the shared library passes **148 tests, one optional skip**; the regular relay
suite passes **550 tests**. Six separately executed isolated Postgres cases
include signed-removal enforcement, issuer/owner binding, expired-policy
cleanup, failed key deletion, failed-report retry and refusal to regenerate a
revoked key. Native regressions cover eight removal lifecycle cases, including
lost replies, uncertain storage, changed context/key, manager revocation and
competing signed heads. No failures occur. These are implementation tests;
the actual old service still needs an owner-confirmed removal on the live
account. The hosted execution gate remains closed.
