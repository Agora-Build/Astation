# Approval push: Astation relay and app integration

Status: aligned product policy, awaiting r9 wire schemas and fixtures,
2026-10-19. Host ingress, sealed push, authenticated seen and escalation are
not enabled by today's provider adapters.

The shared signed formats and protocol are owned by **[Atem PR #80](https://github.com/Agora-Build/Atem/pull/80)**.
Use [#81](https://github.com/Agora-Build/Atem/issues/81) for handoffs/questions
and the [confirmed policy](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276488130).
This document specifies Astation responsibilities and acceptance checks, not
a second signing domain, channel profile or competing wire protocol. The
[remote API design](remote-agent-api.md) is the Astation implementation plan.

## Identity and authority

Only the jointly specified host proof and manager-authorized host membership
record can bind account/genesis, atem_device_id, host trust/key generation and
actual host key. SSO, relay room and a claimed identifier cannot supply that
identity. Verify signed bytes and current authority against the pinned chain;
apply removals and failed-journal fences before authority-dependent effects.
The relay independently checks provenance for routing/abuse; apps and Atem
verify end-to-end and never trust a relay identity assertion alone.

Capture immutable validated host context before asynchronous dispatch. A
connection proof binds a fresh single-use challenge, audience and socket
generation with a bounded lifetime. Exact fields, algorithm/encoding domains
and replay limits must come from r9's vectors. No draft NUL-prefix domain or
old attestation/freshness scheme from earlier Astation proposals is a wire
requirement. A durable signed accepted event can be processed after the
originating socket closes; a later mutable connection lookup cannot replace
its captured identity. Restart/reconnect requires fresh connection proof.

## Sealed opens and resolutions

Atem sends opens immediately, signing immutable original approval creation
and expiry plus full account/root, host key/trust, session/process/approval
identity. Resolution uses the same identity and dominates delayed opens.
Pin exact event identifiers, digests, encoding, time-skew, dedup retention and
signature inputs with Atem before either side emits new fields.

Tool/summary are HPKE-sealed independently to each eligible control device's
signed X25519 notification/encryption key. This key is separate from its
biometric authentication/signing key. Shared vectors fix suite, info/AAD,
recipient key ID and ciphertext signature/digest binding. No plaintext
fallback, raw arguments/transcripts, credentials or decrypted hints in relay
logs, records, provider diagnostics or APIs.

Send one bounded recipient envelope per provider notification. Account for
APNs's complete payload budget, including the aps wrapper, instead of sending
a whole fanout list. Use approval_id as APNs collapse ID / FCM tag under the
agreed full-identity mapping. Keep device names/content sealed. The recipient
verifies/opens the exact authenticated envelope; neither it nor provider
success makes an actionable card. Tap reconnects and fetches current host state.

The iOS notification service extension uses mutable-content: 1 and the approved
protected notification key. It cannot perform an interactive biometric manager
signature. If the key is unavailable while locked or the extension cannot run,
show a generic hint and fetch after unlock. Mac/native and future Android
clients follow equivalent verification and plaintext-free fallback behavior.

## Approved schedule and active-user seen

| Condition | Result |
| --- | --- |
| Approval opens | Connected eligible clients receive the live card immediately. |
| No desktop Astation connected | Send desktop OS notification immediately; presence is only a routing hint. |
| Mobile preference requests immediate | Eligible mobile push may be sent at creation instead of waiting. |
| 60 s, unanswered/open/unexpired and not seen | Send mobile push; an optional desktop reminder is allowed. |
| Foreground active-user seen | Suppress mobile escalation; retain the pending actionable card until host resolution or expiry. |
| Authenticated answer/closure | Cancel pending sends and clear/coalesce delivered notices where supported. |
| At/after expires_at minus agreed margin | Suppress provider delivery; do not mislabel the still-valid approval expired or disable it early. |

Every deadline derives from the host's signed original created_at, not retry,
relay admission, catch-up or wake time. Pin the numeric margin and exact
routing/late-open semantics in r9 fixtures. The former desktop 60 s / mobile
180 s policy is superseded; no 180 s reminder remains a requirement.

Seen is emitted only after the actual card is rendered in a focused foreground
window with an active user (or unlocked foreground phone app). Background
transport delivery, provider ACK, a lease, an unopened notification and an
unattended open app do not count. Bind the signal to the authenticated current
eligible device and full approval identity, using the r9 proof/encoding.
Bound, deduplicate and persist it across replicas/restarts. A stale, revoked,
cross-account or different-target signal must not suppress delivery.

Seen is not an answer, lease change, closure or authority grant. A seen-after-
resolution race never reopens a card/job. Suppressing push must not remove the
card from other clients. A later explicit host resolution remains authoritative.

Register delivery class/preference and token generation under device proof;
never infer account permissions from APNs/FCM token possession. Desktop/mobile
classification is only notification routing. Filter before OS submission;
client-only filtering cannot reliably hide a suspended app's notification.

## Durable relay lifecycle

1. Validate bounded/canonical event, captured host identity, chain/key proof,
   signature, target, ciphertext binding and immutable time constraints. Body
   claims cannot widen the authenticated context.
2. Transactionally persist event/dedup receipt, approval lifecycle, seen or
   resolution tombstone and recipient/stage jobs before returning accepted.
   Same identity/digest returns the original receipt; changed bytes conflict.
   A resolution received before the open suppresses all delayed opens.
3. Persist jobs, bounded claims/attempts and completion across relay-a/relay-b
   sharing Postgres/Valkey. Presence is a hint, not durable authorization.
   Reconnect, retry or failover cannot move creation time or duplicate stages.
4. Before each provider attempt recheck unresolved/unseen policy, expiry margin,
   current host/recipient roles and key generation, preference and token
   generation. No send after a known removal. Invalid-token replies may clear
   only the failed generation, never a newly rotated token.
5. Retry temporary/unknown external-send outcomes with the same identity/stage
   and original expiry. APNs/FCM are best effort and at least once; provider
   acceptance is not user attendance or an agent answer. Recheck resolution
   immediately before submission. A race after external submission can still
   cause a late notice; a tap always fetches current state.

Keep native live-card dedup separate from provider-stage receipts and active
seen. An already received card must not suppress mobile escalation until the
foreground/active-user condition is met. Opting out of OS push does not remove
the inbox or grant/remove control. Windows/Linux desktop delivery needs its
own verified provider adapter; APNs provisioning does not implement it.

## Shared acceptance tests

Use real independent keys and fake providers/clocks without a phone UI:

- Wrong host/root/account/key/generation, challenge replay/expiry/audience,
  changed sealed recipient/content, forged seen, revoked member and scope.
- Immediate live card, desktop-connected/no-desktop routing, mobile t=59.999 s
  vs t=60 s, immediate mobile preference, optional desktop reminder and no
  former 180 s stage.
- Active foreground card vs focused-but-unattended, background delivery,
  notification unopened, app locked and mobile suspended.
- Seen suppressing pending mobile delivery across both replicas; seen after
  resolution, answer crossing seen/send, closed-before-open, duplicate catch-up,
  late workers/opens, token rotation and worker restart.
- Signed expiry/margin boundary, clock skew, created_at unchanged on redelivery,
  malformed/future times, and still-valid card remaining actionable during the
  provider-suppression margin.
- HPKE/signature cross-language vectors, wrong recipient key, key unavailable
  while locked, generic fallback and full provider payload-size budget.

Then verify real APNs/FCM credentials, entitlements, background extension
behavior and on-device owner authentication separately. Provider setup remains
in [push-notifications.md](../../docs/push-notifications.md). No test bypass
or login-only enrollment is allowed in release builds.
