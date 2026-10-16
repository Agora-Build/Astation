# Astation Review of atem-session v1 r3

Date: 2026-10-15

Reviewed upstream commit: `1bf805c021acc156600d43e9ac368ecd2e9a0717`.
The [r3 snapshot](atem-session-v1-r3.md) is unchanged. R4 addresses all three
findings below; see the [current review](atem-session-v1-r5-review.md) and
[current snapshot](atem-session-v1.md). The [r2 review](atem-session-v1-r2-review.md)
is retained for context. The findings below describe r3.

R3 addresses the main binding, reply-correlation, runtime-fencing, receipt-state,
and canonical-encoding concerns. Accept those choices as the basis for the
compatibility implementation. Three specific corrections remain before the
contract and fixtures are frozen; section 9 remains the security release gate.

## 1. Keep legacy unscoped input disabled for a managed session

Section 0 now shares one authority across connections, but permits legacy
unscoped mutations whenever no remote holder exists. After local input revokes
a lease, an old socket can immediately send agentInput or voice without an
explicit control acquisition. The same bypass becomes available after release
or expiry. This does not satisfy the approved rule that remote mutations need
the session's current control authority and reconnect cannot regain control.

Once a session uses the new authority, reject unscoped legacy mutations against
it whether or not a remote holder currently exists. Legacy terminal `control`
can map to the same explicit acquire/release authority, provided permission,
attachment, exact target, stream, generation, and deadline checks still apply.
Legacy behavior may remain for sessions that have never entered the managed
mode, without creating an alternate mutation path to a managed session.

Extend the legacy fixture to send unscoped mutations after local reclaim,
explicit release, and expiry. Assert no remote bytes or dispatches until a new
explicit acquisition succeeds. Local input remains available throughout.

## 2. Make the legacy takeover fixture executable without elided setup

`legacy-connection-cannot-bypass-lease.json` uses stream `s` for resize, stop,
and control without establishing that subscription. Its note says a missing
subscription is forbidden, but the later control step expects a successful
takeover. A real host cannot satisfy both expectations.

Add an explicit subscription and capture its attached stream ID for later
messages, or define a deterministic subscription in fixture setup. The schema
must define any captured-value substitution. Do not omit state that is needed
to authorize the successful part of a machine-checkable scenario. Keep the
invalid lease/epoch attempts and assert their exact errors as well as no side
effects.

## 3. Align the repeated-acquire fixture with the deadline formula

The final step of `late-renew-reply-does-not-resurrect-control.json` sends at
31000 ms and receives `ms_left: 500`. Section 5's formula gives a conservative
deadline of 31500 ms, but the fixture expects the old deadline of 32000 ms.
Its note explicitly keeps that old value. The normative rule and the test
currently disagree.

Use `min(previous_deadline, request_send_time + ms_left,
authorization_deadline)` for a repeated acquisition while already holding
control. This never extends the prior deadline and honors a shorter remaining
lifetime. Update that fixture to 31500 ms, and assert that input is disabled
when it expires. Explicit acquisition after expiry starts a new operation;
it must not be confused with a delayed reply restoring expired control.

## Validation and remaining work

All ten provided digest vectors have matching canonical strings and SHA-256
hashes, including UTF-16 key ordering. This is an independent vector-content
check; shared Rust/Swift/browser parser and scenario execution remains pending.
The raw rejection cases must still be consumed by those implementations.

Add `runtime_epoch` and `seq` to the representation table's bounded counters,
keep a fixed runtime UUID for each accepted epoch, and request a snapshot before
using changes from a newly accepted runtime. These are implementation details
to cover alongside the existing registry fixture, not a change to the approved
registry model.

Astation's optional `terminal-lease-v1` client work remains separate from full
session-v1 activation. All Atem implementation belongs to the Atem agent; the
[handoff](atem-implementation-handoff.md) corrects the earlier unpublished
experiment's provenance. Browser/native prompt integration must preserve the
owner's existing functionality while enforcing the shared session authority.
Account-wide native authority, resume, independent browser grants, and relay
confidentiality remain gated until section 9 is jointly specified, implemented,
and tested.
