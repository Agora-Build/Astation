# Auth and Station admission

Implementation starts with the Auth-to-Station trust boundary from the
[shared design](../unified-integrations.md) and the [Agora.Build companion](https://genie.netbird.cloud:44259/AGORA-BUILD-INTEGRATIONS.md)
(owner decisions dated 2026-10-24). This contract applies to the default relay
and registered custom Stations. It does not grant R9 device authority.

## Verification order

1. Accept a bounded signed access token, never an ID token, refresh token,
   query-string credential or an unsigned account/device assertion.
2. Require `typ=at+jwt`, `alg=ES256`, a bounded `kid`, the configured Auth
   issuer, and the selected Station's exact origin as the sole audience.
   Portal-audience tokens cannot authorize Station. HTTP is permitted only
   for loopback development issuers/resources.
   Missing/partial configuration never falls back to a userinfo endpoint;
   the former `AGORA_ACCOUNT_*` verifier is removed. Historical identity rows
   remain preserved for explicit migration.
3. Verify the signature with the configured issuer's discovery/JWKS. Do not
   follow redirects or token-provided key URLs. Discovery must retain the
   issuer and its JWKS origin. Bound document sizes and network timeouts.
4. Enforce expiration, issuance/not-before times, the `ab` + ULID owner subject,
   client ID and the route's exact scope. Check time again after key retrieval.
5. Keep token purposes separate. Native login accepts no integration service
   binding or assistant session. Integration access lasts at most 300 seconds,
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
the approved service identity. Until Auth and the shared-core owners publish
the fingerprint byte/encoding vector and the signed policy-feed format, this
increment does not expose a provisionable integration execution route.

## Rotation, revocation and outages

- Cache signing keys for 60 seconds before refreshing. Refresh an unknown
  `kid` with a shared five-second refresh budget; untrusted random IDs cannot
  create an unbounded cache or an Auth request for every API call.
- During a discovery/JWKS outage, a previously verified key set may be used
  for at most one hour from its last successful fetch. Never use an unknown
  key from a failed fetch, extend token expiry, or reset the cache age on a
  failure. At the one-hour boundary fail closed.
- A successful JWKS replacement is authoritative for signing keys: removed
  keys, including an empty key set, do not survive in a fallback cache.
- Integration client-key rotation has a ten-minute overlap at Auth. It does
  not change the R9 service key or bypass the five-minute access-token limit.
- Portal pushes authenticated pauses/revocations/account-access changes;
  Station also polls every minute. Missing tokens expire within five minutes.
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

Next: durable provisioning/change-feed bindings and account-access changes,
per-integration quotas, registered-Station proof, native Station AI settings and
relay-only acknowledgments, then shared-client execution/receipts and Discord.
Assistant session tokens (`assistant.chat`, `sid`, up to 72 hours) need their
own active-session verifier; they must not enter the five-minute agent-token
or native-login paths. Real dev Auth/Station interoperability remains a gate;
local test tokens are not evidence of production registration or deployment.

## Owner assignments

The user asked for delegation through Atem memory. The implementation plan has
ten tasks; an assignment is not a claim that another agent has started it.

| Task | Owner | Current status |
| --- | --- | --- |
| 1. Auth to Station validation | Station/Astation | Local verifier and policy checks implemented; live Auth interoperability pending. |
| 2. Credentials and registered Stations | Auth | Delegated; Station proof endpoint foundation implemented here. |
| 3. Integration/Station management and change APIs | Portal | Delegated; exact API/feed formats pending. |
| 4. Native approval and protected R9 provisioning | Station/Astation, shared core from Atem | Existing R9 primitives; integration lifecycle not wired. |
| 5. Typed agent APIs/events/receipts | Station/Astation, shared client from Atem | Existing native APIs; hosted integration execution remains closed. |
| 6. Durable lifecycle/export/deletion | Station/Astation | Integration-specific persistence and deletion propagation pending. |
| 7. Station AI settings | Astation | Pending authenticated account-wide configuration. |
| 8. Relay-only policy and ACKs | Astation + Atem host | Host proposal e105; pairing/generation/persistence review on #81. |
| 9. Discord | Portal + Station/Astation | Official app after API foundations; own app later. |
| 10. Joint end-to-end verification | All owners | Local adversarial tests run; live grants/owner/no-Mac/replica matrix pending. |

MCP execution, contextual LLM and voice are subsequent phases. Their disabled
route guards do not advertise a working implementation. Auth/Portal handoff is
vault `v-xZDT9aGD` e13; Atem handoff is `v-8ut37j7X` e107. Memory assignments:
Auth/Portal `28c18f4b`, Atem `4efc63af`, Station/Astation `ed1b104f`.
