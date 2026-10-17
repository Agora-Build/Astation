# Astation Review of atem-session v1 r4

Date: 2026-10-15

Reviewed upstream commit: `fd907ccf0492a02fd5fce08453eefda661597df5` on
`docs/atem-session-protocol`.
The [r4 snapshot](atem-session-v1-r4.md) is unchanged. R5 resolves all three
findings below; see the [current review](atem-session-v1-r5-review.md) and
[current snapshot](atem-session-v1.md). The findings below describe r4 protocol
and fixture contents. All Atem implementation belongs to the Atem agent.

## Findings

### 1. P2: Define a terminal receipt outcome for ordinary dispatch failures

[Section 6, transition table](https://github.com/Agora-Build/Atem/blob/fd907ccf0492a02fd5fce08453eefda661597df5/designs/protocol/atem-session-v1.md#L284-L306)
requires durable `executing` before the first external side effect and forbids
every transition not listed. Its only exits from `executing` are successful
kind-specific completion and unresolved outcome after crash/restart.

An ordinary dispatch error has neither exit. For example, after persisting
`executing`, a PTY enqueue/write can fail before writing any bytes, or a stop
operation can fail while the process stays alive. No provider turn ends and no
process exits; no crash/restart occurs. The receipt remains `executing` forever,
and a duplicate request only returns that state. A transport `error` alone does
not resolve the durable receipt.

Specify and durably record the outcome for known failures as well as uncertain
partial dispatch. The contract can use an explicitly defined failure result or
allow an existing final state under precise conditions; it need not add a new
state. A rejection after `executing` is safe only with proof that no side effect
occurred. Uncertain dispatch must not be retried automatically. Add fixtures
for failure before any effect and failure after a possible partial effect,
including duplicate submission and recovery of the recorded outcome.

### 2. P2: Make descriptor fixtures agree with the wire schema

[The registry client fixture](https://github.com/Agora-Build/Atem/blob/fd907ccf0492a02fd5fce08453eefda661597df5/designs/protocol/fixtures/runtime-epoch-and-sequence-ordering.json#L37-L42)
delivers descriptors with only `session_id`, `process_gen`, and `state`, including
in its first two snapshots. The same abbreviation appears in changes.
[Section 4](https://github.com/Agora-Build/Atem/blob/fd907ccf0492a02fd5fce08453eefda661597df5/designs/protocol/atem-session-v1.md#L157-L167)
also lists `provider`, `cwd_label`, `activity`, `activity_since`, `controller`,
`capabilities`, and `created_at`, with no optional/default rules. The harness
schema defines `deliver_to_client` as delivering the supplied message; it does
not expand descriptor fields.

A decoder requiring the documented descriptor cannot reach the ordering
assertions; one that silently fills fields uses defaults the other languages
need not share. Supply complete descriptors in executable wire fixtures, or
explicitly specify optional fields and their defaults in the protocol. If
`session_changed` is intended as a patch, define that separately from a full
snapshot descriptor. Run this fixture through actual wire decoders, not only
against an in-memory registry model.

### 3. P3: Disable control at the newly computed expiry boundary

[The late-renew fixture](https://github.com/Agora-Build/Atem/blob/fd907ccf0492a02fd5fce08453eefda661597df5/designs/protocol/fixtures/late-renew-reply-does-not-resurrect-control.json#L275-L288)
now correctly computes the repeated-acquire deadline as 31500 ms. However,
its reply arrives at exactly 31500 ms and the next assertion still requires
`controls: true`. Only after another millisecond does it assert disabled input.
There is already zero remaining lifetime when the reply is applied.

Define the equality boundary explicitly (`now >= deadline` expires control),
and have the client disable input immediately when applying an already-expired
conservative deadline. Either expect disabled control/input at this step or
deliver the reply earlier and add a separate assertion at exactly 31500 ms.
This is a fixture and boundary-contract issue, not evidence of a shipped Atem
lease bug.

## Resolved from r3

R4 addresses all three findings in the [r3 review](atem-session-v1-r3-review.md):

- A session stays managed until it ends, so legacy unscoped input remains
  forbidden after local reclaim, release, or expiry.
- The legacy fixture explicitly subscribes, captures its stream ID, and uses
  schema-defined substitution.
- Repeated acquire uses the conservative minimum formula and the fixture's
  expected deadline is now 31500 ms. Finding 3 concerns the remaining equality
  assertion, not the previous arithmetic error.

R4 also bounds `runtime_epoch` and `seq`, fixes one runtime UUID per accepted
epoch, and requires a snapshot before applying changes from a new runtime.

## Validation and acceptance

All six fixture JSON files parse with duplicate-key detection. All ten digest
vectors have matching canonical strings and SHA-256 hashes, including UTF-16
key ordering. An independent fake-clock replay identifies the step at 31500 ms
where the lease assertion disagrees with expiry at zero remaining time.

These are content checks, not Rust, Swift, or browser implementation test
results. The raw rejection vectors and lifecycle scenarios still need execution
against those implementations. No Atem code was changed, built, or tested for
this review.

No new critical issue was found in the compatibility foundation. Resolve the
findings before freezing the contract and fixtures. Section 9 remains a release
gate: account-wide native access, resume, browser clients, and relay
confidentiality cannot be enabled until trust, freshness, authenticated channels,
and QR grants are jointly specified, implemented, and tested. The relay never
becomes authoritative for identity, trust, control, or encryption state.
