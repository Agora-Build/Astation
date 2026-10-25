# Auth and Station admission

Implementation starts with the Auth-to-Station trust boundary from the
[shared design](../unified-integrations.md) and the [Agora.Build companion](https://genie.netbird.cloud:44259/AGORA-BUILD-INTEGRATIONS.md)
(owner decisions dated 2026-10-24). This contract applies to the default relay
and registered custom Stations. It does not grant R9 device authority.

## Verification order

1. Accept a bounded signed access token, never an ID token, refresh token,
   query-string credential or an unsigned account/device assertion.
2. Require `typ=at+jwt` or `application/at+jwt` (case insensitive),
   `alg=ES256`, a bounded `kid`, the configured Auth issuer, and the selected
   Station's exact origin in the string or array audience.
   Portal-audience tokens cannot authorize Station. HTTP is permitted only
   for loopback development issuers/resources.
   Missing/partial configuration never falls back to a userinfo endpoint;
   the former `AGORA_ACCOUNT_*` verifier is removed. Historical identity rows
   remain preserved for explicit migration.
3. Verify the signature with the configured issuer's discovery/JWKS. Do not
   follow redirects or token-provided key URLs. Discovery must retain the
   issuer and its JWKS origin. Bound document sizes and network timeouts.
4. Enforce expiration, issuance/not-before times with Auth's 60-second skew,
   the `ab` + ULID owner subject,
   client ID and the route's exact scope. Check time again after key retrieval.
5. Keep token purposes separate. Native login accepts no integration client
   or assistant session. Integration access lasts at most 300 seconds,
   requires `r9_svc`, and cannot use an assistant `sid`.
6. Integration admission additionally matches the verified issuer, owner,
   `client_id` and `r9_svc` to the current approved Station binding. Require
   active account access, an active unexpired integration, and the operation
   in both token and Station policy. Recheck this current policy at dispatch;
   a previously verified token is not a reusable authorization decision.
7. Execute only through the native-approved R9 service identity. Atem still
   verifies membership, possession, scope, revocation and process/session
   targets. Auth authentication cannot enroll a device or extend its grant.

The binding passed to integration admission is trusted internal policy loaded
by the provisioning/change-feed layer, not a JSON body supplied by the caller.
It is keyed by `(issuer, owner, integration ID)` and its fingerprint comes from
the approved service identity. `r9_svc` is lowercase hex SHA-256 of the decoded
current member `auth_key.pub` bytes: 65-byte uncompressed SEC1 for P-256 or
32 raw bytes for Ed25519. Hash no JSON, algorithm prefix, PEM or DER.
Native and Rust tests match both public Auth vectors. The native and relay implementations use the shared fingerprint helper from
Atem PR #98, pinned at `04140840fc0cec4086072ab6326b7a1b46b25be4`.

The verifier consumes Auth PR #9 `d7de4416e74f2fcc85dcf4befa0a6bd8ad9ffb64`
(subsequently merged as `ca657bb`). All 42 pinned vectors match their verdict,
HTTP error, principal and scope expectations. Integration binding is checked
before required scope: an incorrect `r9_svc` is `invalid_token`, not
`insufficient_scope`. Missing/non-Bearer authorization is 401 with a plain
Bearer challenge; malformed Bearer is 400, insufficient scope 403 and key
retrieval failure 503 with a five-second Retry-After. No token is logged.

## Rotation, revocation and outages

- Cache signing keys for 60 seconds before refreshing. Refresh an unknown
  `kid` with a shared five-second refresh budget; untrusted random IDs cannot
  create an unbounded cache or an Auth request for every API call.
- During a discovery/JWKS outage, a previously verified key set may be used
  for at most one hour from its last successful fetch. Never use an unknown
  key from a failed fetch, extend token expiry, or reset the cache age on a
  failure. At the one-hour boundary fail closed. An unknown key after a failed
  refresh returns 503, including during backoff; backoff starts when that fetch
  finishes rather than when it started.
- A successful JWKS replacement is authoritative for signing keys: removed
  keys, including an empty key set, do not survive in a fallback cache.
- Integration client-key rotation has a ten-minute overlap at Auth. It does
  not change the R9 service key or bypass the five-minute access-token limit.
- Portal sends an unsigned, bounded/coalesced poll hint. It contains no policy
  authority and its cursor is never adopted. Only the authenticated Station
  report-token feed applies pauses/revocations/account-access changes; poll
  every minute and fetch a full 500-event page again immediately.
  Missing tokens expire within five minutes.
  A local policy denial wins even while an access token's signature is valid.
- A stream or queued command must be checked against current expiry/policy
  before dispatch; reconnect and token refresh never revive revoked work.

## Runtime placement

`station.agora.build` stays an opaque relay and encrypted store. MCP, LLM and
agent modules are disabled there. A registered custom Station is required to
enable Station AI. Its MCP/LLM/Agent switches default off. Any enabled switch
requires the whole account to use its selected relay rather than direct
port 8080. Auth validation remains required on both kinds of Station.

No credential payload is exported into assistant context. New custom LLM or
Discord credentials are separately consented, write-only provisioning directly
to the chosen Station, encrypted at rest and never sent to Portal/Auth.

## Validation and remaining integration work

The former `/api/llm/chat` and `/api/voice-sessions` HTTP bridge accepted a
session identifier rather than scoped Auth/R9 admission. Those endpoints now
use the same closed runtime gate; there is no unauthenticated legacy fallback.
This disables the former voice bridge in this branch until its replacement
uses the approved assistant token/session contract. RTC sharing is unchanged.

The first increment tests signed tokens against a real local discovery/JWKS
server: audience and issuer confusion, token-purpose confusion, owner/client/
service-key mismatches, policy revocation, expiry while fetching keys, key
rotation/removal and bounded Auth outages. Existing signed native login and
recovery HTTP tests continue to exercise production account routing.

The Redis suite tests cross-replica voice-store delivery, early replies and
timeouts directly, without reopening the retired HTTP bridge. Separate
production-router checks refuse the bridge on both replicas before and during
a Redis outage, with no disclosure or mutation of retained session content.
Local validation passes 530 regular relay tests (120 environment-gated tests
ignored in that run), plus all 65 explicitly selected Redis tests against an
isolated Valkey 8.1 server, with zero failures or skips in the Redis run.

Native consent, protected publication retries, a Settings > Integrations review
screen and scoped Portal approval are wired. Station provisioning persists the
protected service key and identity before exposing its canonical draft. The
worker authenticates the feed, handles cursor-ahead restoration, and commits
policy/cursor/freshness atomically. Hosted HTTP/WebSocket handlers use that
policy plus the current R9 grant, durable owner/root mapping and fleet quotas.
Every membership-head change fences a channel, including a same-key renewal.
See [the integration lifecycle](station-integration-lifecycle.md) and
[typed API contract](station-hosted-agent-api.md).

Hosted execution stays disabled pending actual custom-resource Auth/native/host
interoperability, selected-relay-only policy ACKs and Mac-off/replica tests.
Station AI account-wide settings, integration deletion propagation and Discord
remain separate increments. Assistant session tokens (`assistant.chat`, `sid`, up to 72 hours) need their
own active-session verifier; they must not enter the five-minute agent-token
or native-login paths. Real dev Auth/Station interoperability remains a gate;
local test tokens are not evidence of production registration or deployment.

## Owner assignments

The user asked for delegation through Atem memory. The implementation plan has
ten tasks; an assignment is not a claim that another agent has started it.

| Task | Owner | Current status |
| --- | --- | --- |
| 1. Auth to Station validation | Station/Astation | Local verifier and policy checks implemented; live Auth interoperability pending. |
| 2. Credentials and registered Stations | Auth | Contract and 42 vectors consumed from PR #9; actual deployment/live Station interoperability pending. |
| 3. Integration/Station management and change APIs | Portal | PR #17 owner/cursor contract consumed at 83e6543 (merge efde3bc); #16 closed. |
| 4. Native approval and protected R9 provisioning | Station/Astation, shared core from Atem | Native review, durable consent/retries, provisioning endpoints and protected keys wired and tested; actual-owner confirmation pending. |
| 5. Typed agent APIs/events/receipts | Station/Astation, shared client from Atem | Typed HTTP/WebSocket shared-client adapter wired; controlled encrypted-host tests pass; hosted execution remains closed. |
| 6. Durable lifecycle/export/deletion | Station/Astation | Integration-specific persistence and deletion propagation pending. |
| 7. Station AI settings | Astation | Pending authenticated account-wide configuration. |
| 8. Relay-only policy and ACKs | Astation + Atem host | Atem [#97](https://github.com/Agora-Build/Atem/pull/97) merged as `8815bf7`; fixes both #96 findings, source/CI reviewed. Release and joint live policy/ACK verification remain. |
| 9. Discord | Portal + Station/Astation | Official app after API foundations; own app later. |
| 10. Joint end-to-end verification | All owners | Local adversarial tests run; live grants/owner/no-Mac/replica matrix pending. |

MCP execution, contextual LLM and voice are subsequent phases. Their disabled
route guards do not advertise a working implementation. Auth/Portal handoff is
vault `v-xZDT9aGD` e13; Atem handoff is `v-8ut37j7X` e107. Memory assignments:
Auth/Portal `28c18f4b`, Atem `4efc63af`, Station/Astation `ed1b104f`.
