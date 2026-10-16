# Astation Review of atem-session v1 r1

Date: 2026-10-15

Reviewed upstream commit: `7a0c691f72e402e5e9488090c113c3974056ed92`.
Source: <https://github.com/Agora-Build/Atem/blob/docs/atem-session-protocol/designs/protocol/atem-session-v1.md>.
The [r1 snapshot](atem-session-v1-r1.md) is unchanged. Atem has since published
r2 at `9383193`, r3 at `1bf805c`, r4 at `fd907cc`, and r5 at `4498791`; see the [current r5 review](atem-session-v1-r5-review.md) and
[current snapshot](atem-session-v1.md). The findings below describe r1 and are
retained as review history; r2 addresses most of them.

The session registry, host-owned leases, independent process generations, and
durable receipt states match the approved product design. Use this as the
shared higher-level protocol; Astation does not propose a competing multiplexing
protocol. The following changes are needed before freezing fixtures.

## 1. Bind hello/resume to an authenticated principal and attachment

Sections 0 and 3 must not let `client_device_id`, `client_kind`, or a known
`controller_session` establish authority. Bind them to the cryptographically
authenticated native key or the approved browser key/grant. A relay may observe
all unencrypted fields; a controller UUID is not a resume credential.

Specify proof of possession for resume, a fresh host challenge, and a new
attachment generation. Fence the former attachment before accepting mutations
on its replacement. A transport switch may preserve logical controller identity,
but must not let old and new sockets both renew or operate it. A broker restart
invalidates old controller attachments/leases; surviving workers and receipts
remain independently addressable. Resume must never automatically acquire control.

Existing socket authentication can be used for isolated compatibility tests,
but is not the missing account-wide native authentication or encrypted channel.
Do not enable native enrollment, browser grants, or advertise relay-confidential
operation while section 8 is open.

## 2. Define exact terminal/chat binding and remove lease bypasses

Sections 0, 5, and 6 need the exact JSON shape for a full target and its use in
terminal/chat requests. Suggested common object:

```json
{
  "target": {
    "account_id": "account-a",
    "atem_device_id": "host-a",
    "host_trust_gen": 1,
    "session_id": "ses-abcdefghijkl",
    "process_gen": "11111111-1111-4111-8111-111111111111"
  },
  "lease_epoch": 7
}
```

Resolve section 9's integer representation rule before freezing this example.
Specify whether terminal/chat messages carry these fields directly or are nested
inside a session request. For upgraded connections, session `acquire/renew/release`
must be the sole control lifecycle. Legacy terminal `control`, chat `submit`,
agentInput, voice commands, stop, resize, and approval answers cannot bypass it.
Raw terminal input remains non-replayable even when it carries this binding.

Bind every stream to its authenticated controller, attachment, exact session,
and process generation. Echo enough target/controller context in lease replies
and errors to reject delayed responses from an old attachment or process.

## 3. Bind receipt deduplication to the complete operation

Section 6 currently says same request ID and payload digest returns a receipt,
which could alias a different target or operation with the same payload.
The stored immutable request identity must bind account, host identity/trust
generation, session, process generation, operation kind, and payload digest.
Reusing an ID with any differing bound value returns `request_id_reused`.
The host recomputes the digest; it cannot trust the client-supplied digest.

Define canonical JSON precisely, such as RFC 8785 with a documented supported
data domain and explicit rejection of duplicate object keys, invalid numbers,
and out-of-range values. Alternative: hash an explicitly length-prefixed
encoding of typed fields. Cross-language known-answer fixtures are required.

Authenticate and authorize receipt access before returning a duplicate outcome.
Admission of a new operation requires the current control lease; reading an
already accepted receipt must not require taking control again or re-executing it.

## 4. Scope receipt queries and errors to authorized targets

`receipt_query` currently carries only session ID and request IDs. Require the
full target or an equivalent already authenticated session binding, plus current
read permission for that exact target. Do not return another process/account's
receipts or reveal its current target in `stale_target` errors.

Unknown/forbidden errors should not enumerate unauthorized sessions. Define
message, payload, ID, receipt-query, and per-connection limits before parsing
unbounded arrays or storing attacker-selected request IDs.

## 5. Define crash boundaries and kind-specific completion

Persist `accepted` before acknowledging it. Persist the transition to
`executing` before the first external side effect. A crash after that transition
requires reconciliation with the original worker/provider; if it cannot establish
the outcome, retain `outcome_unknown` without automatic resubmission. A crash
before the transition can recover durable accepted work only under its original
target and applicable host authorization.

Controller disconnection or ordinary lease expiry does not cancel accepted
work. Host unpair/rebind must prevent an old queued operation from first
dispatching under the new trust generation. Work already executing can continue
locally, as the product design requires.

Define completion per kind: a provider-confirmed prompt turn can complete a
prompt, process exit can complete stop, and interrupt requires its own observed
result. A PTY write is neither prompt acceptance nor turn completion. The text
includes provider approval answers, but the `kind` enum omits them; add an
explicit approval kind with exact approval identity or explicitly defer it.

## 6. Make lease deadlines, epochs, and response fencing normative

Use monotonic time for host enforcement and client renewal deadlines; wall-clock
`expires_at`/`server_time` are display/estimation fields, not authority. Renew at
five-second intervals, never after local expiry. Expired renewal must reject,
not reacquire. Only a response matching the current authenticated attachment,
target, controller, and epoch advances the local deadline.

Lease transfer/expiry/local input must revoke the PTY input epoch before queued
remote bytes can be written. Checking only when a frame is admitted is
insufficient. Specify epoch persistence or invalidation on broker/worker restart,
and test delayed writes, delayed lease replies, and concurrent transports.
Also define repeat acquire by the same current controller so lost replies cannot
silently rotate its active epoch or extend control through unintended retries.

## 7. Order registry updates and snapshots

Add a registry revision/event sequence scoped to `runtime_gen`. A client needs
to detect gaps, discard stale snapshots, and distinguish removal from an old
state update. Define snapshot subscription ordering and closed-session tombstones.
Otherwise list replies racing with `session_changed` can resurrect exited or
removed sessions in the UI. Relay presence is never session liveness evidence.

## 8. Keep section 8 as an implementation gate

Agree on account trust anchor installation, signed native memberships and bounded
management delegation, host enrollment, unpair generation commits, signed
revocation ordering, authenticated freshness proofs, channel key establishment,
replay/downgrade protection, and QR grant binding before production activation.

The 24-hour freshness bound starts at a validated authority proof, not relay
presence, reconnection, an old signature, or a relay timestamp. Persist rollback
protection and conservative restart/clock handling. Grants expire earlier when
their own lifetime or parent authorization does. A browser grant is limited to
its exact key/target/scope and never becomes native membership.

No objection to keeping these cryptographic formats out of Atem's independently
owned registry/runtime implementation, provided admission fails closed and no
placeholder trust decision is exposed as production authorization.

## 9. Freeze representation and fixture semantics

Specify byte/string bounds, UUID validation, time units, digest case, and the
integer domain for generations/epochs. Either encode potentially unbounded
64-bit counters as decimal strings or require and enforce JavaScript-safe
integers on all peers. Overflow must reject rather than wrap.

Fixture `expect` should be structured and machine-checkable, not only prose.
Include a fake monotonic clock and explicit actions such as advance time,
disconnect, resume, transfer, local input, crash, and restart. Negative fixtures
must assert both the error and absence of writes, dispatch, unauthorized receipt
disclosure, or state resurrection. Include canonical-digest vectors shared by
Rust, Swift, and browser implementations.

## Integration already underway

The parallel build is implementing explicit CLI verification/status and local
pairing cutoffs, native verified-access gates, exact session selection, and
tests. Astation's optional `terminal-lease-v1` compatibility extension is a
transitional terminal-only mechanism; it does not replace this higher-level
session protocol or satisfy multi-controller/account-wide trust by itself.
Once session-v1 is negotiated, its common lease must govern all mutation paths.
