# Push approvals: Astation implementation and Atem contract handoff

Date: 2026-10-16. Source: Atem #70 at
`1e5f4d004ef3cca5adb0a21a01ca745f1602b2c8`, "Push-based approvals".
The user approved push delivery independently of lease ownership. Older text in
that proposal requiring an existing lease does not override this decision.

Worktree: Astation-push-approvals, branch `feat/push-approvals`, based on #49's
green r6.2 commit `57e2758`. No Atem checkout is changed or built.

## Ready on Astation's side

- APNs native opt-in, entitlement detection, OS token callbacks and registration
  through the native device's verified relay control connection.
- Postgres token storage shared across replicas; rotation, idempotent upsert,
  exact-generation invalidation and opt-out. The signed connection, not request
  body fields, selects the token owner.
- APNs HTTP/2 / ES256 and FCM HTTP v1 / OAuth RS256 provider adapters. APNs
  provider JWTs are reused for 50 minutes; token credentials and response bodies
  are not logged. Alerts set mutable-content and collapse/tag identities.
  Expiry is checked again after authentication refresh, before dispatch.
- Resolution handling and persisted bounded transport tombstones. A tap wakes
  the native connection, but r6.2 review is explicitly unavailable. No decisions
  or separate acquire/submit approximation are sent.
- [Provisioning and relay deployment instructions](../../docs/push-notifications.md).
  APNs/FCM credentials have not been supplied or configured. Live delivery has
  not been verified.

## Required joint wire contract

1. **Host authentication to the relay.** Today's relay room socket binds a
   routing atem_id and connection generation, but proves no Atem device key.
   Existing session bindings authorize account data and do not authenticate
   the claimed client id. Define the host proof/challenge, pinned key binding,
   account and trust-generation context, freshness/revocation and reconnect
   behavior. push_approval.atem_device_id cannot supply this authority.
2. **Control membership.** Define the signed membership bytes, canonicalization,
   signatures, genesis/sequence/revocation rules and shared fixtures. Until that
   lands, only the verified paired Astation is eligible; do not fan out to all
   SSO devices or devices sharing memory/vault storage. Before activating
   delivery, bind registrations to the enrolled member key/trust generation;
   key replacement, removal and revocation must fence existing addresses until
   the device proves its current authority again. A routing device id alone
   must not transfer an old token to a replacement identity.
3. **r7 approval events and catch-up.** Supply exact envelopes, ids, full target
   and process binding, creation/expiry units, sequence/revision semantics,
   pending snapshots, resolution reasons and capability negotiation. Empty
   catch-up must be distinguishable from an unavailable/partial one.
4. **Atomic decision submission.** Define acquire:true placement, binding when
   no lease exists, the digest/receipt identity, permission/admission order,
   replay behavior and duplicate/takeover races. r6.2's submit requires a lease
   and rejects kind:approval; Astation will not relax it speculatively.
5. **Claude Always allow.** Define rule ids, exact rule representation/display,
   decision payload and immutable binding to this prompt. Codex must reject it.
   Astation must show the rule before confirming it, not derive one from a
   notification summary.
6. **Push frames.** Specify version, envelope, field limits, approval-id
   uniqueness and expires_at units, retry/ack semantics, resolving before an
   open arrives, and whether safe display labels come from authenticated host
   metadata. Generic labels are used until that metadata is defined. Define
   ciphertext/envelope changes separately when E2EE lands.

After these contracts, wire the typed trusted catch-up to the native approval
card, add the durable relay dispatch outbox and recipient checks, and execute
the joint host/device/provider tests. No multi-device controller support or
phone approval is claimed by this transport preparation.

## Validation

Final focused native run: 55 tests pass (`ApprovalPush`,
`RelayIdentityRecoveryLifecycle`, `NetworkDebugLogger`, `AtemSession`). Relay's
regular suite: 456 pass, 110 ignored. The new isolated Postgres
migration/rotation/reconnect test passes. Signing validation: 16 tests pass.
APNs and FCM tests use an injected transport and verify actual request
headers/body, provider refusals, OAuth refresh and expiration during refresh.
ES256 and RS256 signatures are verified locally; the RSA fixture is a public
test key with no provider account. No tests contact Apple or Google.

An earlier broader native run passed 136 tests. Its final rerun blocked on an
existing local Keychain read and was stopped without changing Keychain access;
the focused final run above includes the subsequent log-redaction test.

Required next scenarios include independent delivery without a lease, member
and host revocation during dispatch, duplicate/out-of-order open/resolved
messages, receipt loss/reconnect, immediate disconnection after accepting an
answer, simultaneous local/remote answers, stale process/host/trust generations,
late taps and showing the exact Claude rule. Current tests do not claim to run
an r7 host or real APNs/FCM devices.
