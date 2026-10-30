# Built-in Station: Astation review of Auth/Portal

Reviewed 2026-10-30:

- [Agora.Build integration design](https://genie.netbird.cloud:44259/AGORA-BUILD-INTEGRATIONS.md),
  sections 3.3.2, 3.3.2.1, 3.3.3 and questions Q5/Q6.
- Shared memory `mem_9c166f64282245909ef986e78efa18f1` and Portal/Auth vault
  `v-xZDT9aGD` entries e86-e93.
- Astation PR #58 at `c5cce91c7eaa0765088f3bbdb90ba2a4166a6839`.

The shared contract is accepted for implementation. No critical protocol issue
was found. Auth/Portal can build D24 without waiting for Astation's hosted
execution release. The remaining items below gate the relevant rollout, not
starting that implementation. Hosted execution remains disabled.

## Findings and required follow-up

1. **Medium: Phase 1 completion overstates Station-side revocation evidence.**
   Section 3.3.2.1 correctly records Portal/Auth's terminal revocation and the
   Station's final revoked report. Astation also verified native membership
   removal, sealed-key deletion and the final authenticated feed transition.
   Its live revocation observer expired before the owner clicked Revoke,
   however. These records do not demonstrate a still-valid token being denied
   or an existing public WebSocket closing on that revocation. The genuine
   new-token refusal requested from Auth also needs its own evidence. Keep
   these distinct from the passed pause/resume and positive HTTP/WSS canary.
   Repeat the missing checks with a new disposable integration and an armed
   observer before enabling hosted execution; never restore the revoked one.
   This evidence gap need not delay D24 code or migration tests.
2. **Medium: the native disclosure needs the operator's name.** The existing
   introduction in `IntegrationApprovalViewController.swift` says that the
   selected Station can read permitted agent messages. It does not explicitly
   say that Agora.Build operates the built-in Station. Add that disclosure to
   the exact integration review before owner authentication, and to Station AI
   opt-in when that feature is built. Custom Station consent must likewise
   identify the selected operator/origin. This is an Astation rollout item.
3. **Environment decision: Q6 is resolved.** The earlier owner-authorized
   test arrangement used `station.agora.build` with dev Auth/Portal. The newer
   companion records a separate dev Station decision. The owner finalized
   `station-dev.agora.build` after the earlier nested hostname needed extra
   Cloudflare certificate coverage, reusing the current deployment and
   deferring production until verification. Keep `auth.dev.agora.build` as
   the issuer: its exact-host HTTPS certificate and discovery are valid.
   Preserve the encrypted store and rollback
   configuration; do not automatically rebind a hosted approval to another
   origin. Q6 no longer blocks the shared implementation or dev deployment.

## Answers to Auth/Portal's four concerns

### 1. Internally seeded Station record: accepted

Replace the static resource entry with a configured built-in registered
Station in Auth. "Keep the default" means preserve its native contract and
user experience, not Auth's internal storage representation. Preserve the
exact origin, native `astation.remote` scope, owner `sub`, token-purpose checks,
900-second native lifetime and `auth_time`; integration tokens keep their
separate 300-second maximum and `r9_svc` binding. Existing native keys, account
data and pairings are not reset by this representation change.

No user Station registration, domain proof or membership ceremony is added.
Idempotent seeding must retain the same Station/report-client identity across
restarts and replicas. Test old native tokens through expiry, new native token
issuance, account isolation and key rotation during the migration. Configured
admins may pause/revoke but cannot approve as another account. The
`built_in`, `origin_taken` and disabled-creation `not_supported` refusals are
accepted, as are the shared report/feed and details/CORS contracts.

Auth/Portal must implement seeding and access modes before issuing the report
identity. Astation's earlier description of this as configuration-only was
incomplete. The report/wrapping keys are prepared but remain unmounted and
unregistered; private keys stay on Station.

### 2. Dev origin: Q6 resolved by the owner

Use isolated dev and production Station origins, each with its exact issuer,
Portal, protected keys, database and audience. No issuer/audience alias or
fallback is needed. The implementation must accept the configured origin;
neither dev nor production may inherit consent from the other.

### 3. Explicit content disclosure: accepted Astation work

The built-in integration review must state that Agora.Build's server can read
and process the agent messages permitted by the approved scope. Login and a
Station selection do not grant that access. No account K, vault contents or
stored credentials are included in the integration scope. Station AI needs
its own equivalent opt-in before processing is enabled.

### 4. Public report key: confirmed; the digest was encoded differently

Recomputed RFC 7638 from only the public EC members in e84, serialized in
lexicographic order with no whitespace:

```json
{"crv":"P-256","kty":"EC","x":"3X561csGbAJ7-wKmv6EW5vG6IbLMUZ9CNJS_IDFrtDw","y":"JcV-K7nbVtoXPEJD8qANibuadIzaAmMF8g6yZHnFySE"}
```

| Representation | Public digest |
| --- | --- |
| RFC 7638 SHA-256, Base64url without padding | `DtKKyOmuO417kdrkeG9NC7t0LOqLn_QOvC-QEIJ7fcw` |
| Same SHA-256 bytes, lowercase hex as supplied in e84 | `0ed28ac8e9ae3b8d7b91dae4786f4d0bbb742cea8b9ff40ebc2f9010827b7dcc` |

These are the same digest, not different keys. Auth can use the confirmed
Base64url RFC 7638 value. No report-key replacement or private-key transfer
is needed. Keep these public values in the review/public-key handoff; a memory
entry may point here without embedding them.

## Mobile and relay switching

Q5 recommendation: a future native phone may approve integrations only after
explicit enrollment as an R9 manager with its own protected keys and fresh
local user confirmation. An OAuth login or `integrations:approve` scope alone
cannot grant that role or sign membership. This needs Atem's joint review and
native implementation; it does not block D24 or grant browser manager access.
PKCE S256, exact mobile redirects and rotated refresh tokens are appropriate.

Switching Stations must invalidate the old UI/attachment context and obtain
exact-origin access and verified R9 membership at the selected Station.
Returning to a previously used origin must reconcile current trust and
revocation state, not reset trust or silently copy an old approval. Atem owns
confirmation of host-side switching behavior. This requires no new R9 wire
format solely for built-in versus custom admission.

## Execution and cleanup boundaries

Keep Portal's built-in `integrations` flag and Station's hosted release gate
closed until their real end-to-end checks pass. Auth/Portal may implement and
test D24 while these gates remain closed. Plan enforcement belongs to Portal;
parallel creation tests must verify that concurrent requests cannot exceed a
plan's active-integration limit.

The old integration is fully revoked and must not be revived. The isolated
test Station, its database and other keys are retained for coordinated work;
Station deletion and destructive cleanup remain pending. A green CI run and
final cleanup reports do not replace the missing live revocation checks.
