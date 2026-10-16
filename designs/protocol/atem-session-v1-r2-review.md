# Astation Review of atem-session v1 r2

Date: 2026-10-15

Reviewed upstream commit: `9383193eb80d5f1cf57d8e0d19ff749f9870fa7a`.
The [r2 snapshot](atem-session-v1-r2.md) is unchanged. Atem has since published
r5; see the [current review](atem-session-v1-r5-review.md) and
[current snapshot](atem-session-v1.md). The [r1 review](atem-session-v1-review.md)
is also retained for context. The findings below describe r2.

R2 addresses the main r1 concerns: authenticated principals, attachment fencing,
one target binding, host-computed canonical digests, target-scoped receipts,
durable dispatch boundaries, monotonic leases, registry revisions, and bounded
representations. Accept these choices as the shared design direction. The
following details still need agreement and fixtures before the wire contract
is frozen. Account-wide trust and browser activation remain gated by section 9.

## 1. Apply one session authority across legacy and upgraded connections

Section 0 rejects legacy mutations only on an upgraded connection while leaving
non-upgraded connections unchanged. That allows a second authenticated legacy
connection to evade a lease held through the upgraded connection. Upgrade state
is not the session's control authority.

Once a session uses session-v1 control, every remote mutation of that session
must pass the same host authority, regardless of socket, transport, or message
family. Reject incompatible legacy operations against that session, including
unscoped requests that cannot identify a safe target. Alternatively, switch the
whole host into the new control mode. Preserve legacy compatibility only where
it cannot compete with or bypass the new authority.

Add a two-connection fixture: an upgraded controller acquires a session; a
non-upgraded connection attempts agentInput, voice, terminal control, resize,
stop, and chat submission. Assert no writes, dispatches, resize, or stop. Local
terminal input continues to revoke remote authority first.

## 2. Specify renewal reply correlation and the client deadline

Section 5 matches replies by attachment, target, and epoch. These values remain
the same across renewals, so they do not distinguish an old or duplicate reply
from the current renewal. Matching the binding alone must not extend control.

Require `re` to match one outstanding acquire/renew request and consume that
response once. Derive a conservative deadline from the request's monotonic send
time, bounded by the returned remaining lifetime and authorization deadline.
Do not set a fresh 15-second deadline from response arrival. Repeated acquire
must not extend the existing deadline.

Before applying a renewal reply, check the previously acknowledged local
deadline. If it already expired, discard the reply, become a viewer, and require
explicit acquisition. This check must work even if the UI timer never fired.

Fixtures: acquire at t=0, renew at t=5, reply at t=17 without any timeout tick;
duplicate an earlier reply while a later renewal is pending; return a repeated
acquire response near expiry. None may resurrect or silently extend control.
The initial native compatibility client has a regression for the first case.

## 3. Complete registry snapshot, restart, and visibility rules

Section 4 scopes revisions to runtime generation but also requires replacement
snapshots to have a revision at least as high as the last applied revision.
Apply that comparison only within the same runtime generation. A new accepted
runtime starts a fresh revision domain; a snapshot at revision 1 must replace
the old runtime's revision 100. Delayed snapshots from an older runtime must
never switch the client back.

Define when subscription begins and serialize snapshot delivery with subsequent
changes. Buffer/reconcile changes during resynchronization so a late snapshot
cannot overwrite a newer applied state. Define duplicate changes as harmless
or explicitly requiring a resync, with no state resurrection in either case.

Filtering also needs a revision rule. If the global revision advances for a
session the attachment cannot see, a later visible change creates a gap. Use
an attachment-visible sequence/checkpoint or explicitly define safe relisting
for filtered gaps. A ten-minute tombstone is not a substitute for ordering and
runtime fencing.

Fixtures: old runtime revision 100 followed by a new runtime snapshot at 1;
an old-runtime snapshot delivered afterward; snapshot/change reordering; hidden
session changes between visible updates; a late update after a tombstone.

## 4. Freeze complete terminal/chat wire examples and receipt states

Section 2 says terminal/chat carry a top-level binding but lacks an exact full
envelope showing its location. Include fixtures for terminal subscribe, input,
resize, and stop, plus chat open and submit. Specify which legacy generation
field is being compared when chat operations nest their payload. All decoders
must agree whether binding is inside `data`, inside a chat payload, or beside
the outer envelope. Use one unambiguous encoding for each family.

Section 6 should explicitly enumerate the five receipt states (`accepted`,
`executing`, `completed`, `rejected`, `outcome_unknown`) and legal transitions.
Make the handling of nonterminal accepted work after a crash distinct from
replaying an operation whose side effect may have started. Receipts, response
IDs, and original target/kind remain immutable through recovery.

## 5. Finish cross-language and failure fixtures

The five provided digest vectors have consistent canonical strings and SHA-256
values. They are useful starting points, not proof of full RFC 8785 compliance.
Add UTF-16 property-order cases (including supplementary Unicode), required
escaping and invalid Unicode, safe-integer boundaries, and a raw duplicate-key
case that each parser must reject before information is lost.

Complete the listed negative scenarios, plus the cases above. Add receipt-query
authorization, changed-target request-ID reuse, interrupted durable writes,
crash after executing, trust change before first dispatch, local reclaim at
the PTY boundary, and old attachment/runtime input. Fixtures must assert the
absence of side effects and disclosure, not just an error reply.

The fixture schema also needs a defined initial host account/device/trust and
runtime context, a deterministic clock, and a way to deliver/reorder delayed
responses. Setup must not derive identity or permissions from untrusted message
fields. Run the same fixtures against Rust, Swift, and browser implementations;
the two sample scenarios are not yet a passing integration suite.

## Security and implementation status

Section 9 remains a release gate for account-wide access, resume, independent
browser clients, and relay confidentiality. Legacy session authentication and
retained pins do not supply live possession of verified endpoint keys or an
encrypted channel. Relay account identifiers, presence, and timestamps cannot
establish native membership or refresh trust.

Correction: the original implementation paragraph referred to an unpublished,
uncommitted Atem experiment based on `10d3ea874ef25347dd4447fa27e7c64654785a13`.
It did not describe an Atem GitHub commit or release. That work has stopped;
all Atem implementation belongs to the Atem agent, whose lifecycle work is
reported on `feat/status-pair-verify`. The experiment's blocked chat-submit
path is not claimed as behavior of the owner's build. See the
[exact provenance and optional diff](atem-implementation-handoff.md).
