# Astation Review of atem-session v1 r5

Date: 2026-10-15

Reviewed upstream commit: `44987915fb24267960fd9d75221df4ed8c7838ec` on
`docs/atem-session-protocol`.
The [current snapshot](atem-session-v1.md) and `fixtures/` are unchanged copies
from that commit. All ten downloaded files were verified against their GitHub
git blob hashes. All Atem implementation belongs to the Atem agent.

## Review result

No new findings in the r5 changes. All three [r4 findings](atem-session-v1-r4-review.md)
are resolved. Astation accepts r5 as the compatibility-mode implementation
contract. Final conformance still requires the shared fixtures to pass in Rust,
Swift, and the browser, as required by the draft; section 9 remains the security
release gate.

Subsequent native client implementation and offline JavaScript fixture execution
are tracked in [the implementation evidence](astation-session-v1-implementation.md).
The validation section below records the scope of the original document review.

## Resolved findings

1. **Dispatch failures have durable terminal outcomes.** Section 6 permits
   `executing -> rejected` only with proof of no side effect, and uses
   `outcome_unknown` for possible partial effects. Every exit from `executing`
   must be fsynced before reporting it. Prompt, interrupt, and stop failures have
   defined handling, including bounded interrupt/stop observation. Final failure
   states cannot be automatically retried or later rewritten by an observed
   completion. The two new prompt-failure fixtures check duplicate submission
   and retrieval of the same final state after a runtime restart and fresh
   attachment, with one dispatch attempt.
2. **Descriptors are complete wire values.** Every documented descriptor field
   is required in snapshots and changes, including removals. Missing fields are
   rejected; changes are never patches. All six descriptors in the registry
   ordering fixture now contain the required fields.
3. **Expiry includes equality.** Host and client use `now >= deadline`. Applying
   a reply whose conservative deadline has already arrived immediately disables
   control and input. The late-renew fixture now expects both to be disabled at
   31500 ms, without an extra timer tick or millisecond.

## Validation scope

- All eight JSON fixture files parse with duplicate-key detection.
- The ten canonical digest/hash vectors and raw rejection cases are byte-for-byte
  unchanged from the independently verified r4 set.
- All six delivered registry descriptors include every required field.
- An independent lease-arithmetic replay matches all five client assertion
  steps, including immediate expiry at 31500 ms.
- The two new dispatch-failure fixtures have consistent request identity,
  transition sequences, duplicate final states, fresh reconnect attachments,
  target-scoped recovery queries, and single-dispatch assertions.

These checks validate fixture contents and deadline arithmetic. No Rust, Swift,
or browser implementation fixture runner was executed for this review. No Atem
code was changed, built, or tested. Implementation conformance must still cover
durable-write failures, partial effects, restart recovery, trust changes, local
input fencing, attachment/runtime changes, and the other scenarios listed in
section 8. The fixtures must use each implementation's actual wire decoders.

## Security gate

Keep account-wide native access, resume, browser clients, and relay
confidentiality disabled until section 9 is jointly specified, implemented, and
tested: trust anchor and enrollment authority, revocation ordering, bounded
authenticated freshness, authenticated end-to-end channels, and native-approved
QR grants. Compatibility acceptance does not satisfy those prerequisites.

Relay labels, account assertions, timestamps, and presence never establish
device identity, trust, lease authority, encryption state, or authorization
freshness. Existing socket authentication and retained pins remain limited to
the compatibility mode described in the protocol.
