# Astation review of Atem's agent API response r2

Reviewed 2026-10-17. Source: [Atem PR #74](https://github.com/Agora-Build/Atem/pull/74),
commit `13f81b3c58b0f592e38e99847196cd1d7a4661a9`, response r2,
the r8 draft appendix in `designs/protocol/atem-session-v1.md`, all 12
`r8-*` fixtures, their schema, and the changes that mark them NOT RUN.

**Design sign-off: Atem can start implementing r8.** The four findings in the
[r1 review](agent-control-api-atem-r1-review.md) are closed at the contract level.
No blocking protocol/security finding remains in this review. The fixture
corrections below belong in the implementation work before the shared test
gate passes. This is design approval, not a claim that r8 works or is safe to
deploy. Do not advertise/ship r8 features until their real Rust and Swift
fixtures and the joint integration checks pass.

## Findings: draft fixture corrections

1. **Medium: long-turn fixture has the wrong open counter.**
   [r8-long-turn-is-recovered-in-bounded-pages.json:391](https://github.com/Agora-Build/Atem/blob/13f81b3c58b0f592e38e99847196cd1d7a4661a9/designs/protocol/fixtures/r8-long-turn-is-recovered-in-bounded-pages.json#L391)
   expects `chat_opens: 1`. It opens once at step 0, explicitly closes at
   step 6, then the step 7 `recover` sends another `open`. The schema defines
   this counter as the number of host `opened` replies, so it must be 2.
   A conforming implementation would fail this final assertion. Correct the
   assertion; do not change the counter semantics to hide the second open.

2. **Low: client truncation fixture has inconsistent wire-byte metadata.**
   [r8-client-shows-truncation-and-resyncs-only-on-a-sequence-gap.json:148](https://github.com/Agora-Build/Atem/blob/13f81b3c58b0f592e38e99847196cd1d7a4661a9/designs/protocol/fixtures/r8-client-shows-truncation-and-resyncs-only-on-a-sequence-gap.json#L148)
   declares `wire_bytes: 300`. The initial history message plus `history_end`
   total 675 bytes as compact UTF-8 JSON, including the unchanged three-digit
   byte count itself. Even the end envelope alone exceeds 300. The draft says
   this field is the sum of serialized page envelopes. Generate an accurate
   value from the same encoder the harness uses; otherwise a client that
   validates page totals rejects a fixture intended to test truncation.

These are fixture issues, not reasons to postpone implementing the agreed
contract. Both should be corrected before promoting the fixtures from
`requires: "r8"` to conformance tests.

## Accepted resolutions

| r1 finding | r2 resolution | Astation responsibility |
| --- | --- | --- |
| Welcome-only revision admitted incompatible clients | Appendix A requires integer `hello.revision: 8`, rejects incompatible admission before any attachment/work, validates welcome revision, gates features and refuses removed forms. | Send r8 only in the coordinated r8 client; validate before registry/control/chat work. No fallback. |
| Pages could overwrite newer live messages | Appendix B snapshots and enqueues each page atomically in one ordered conversation stream, ending with sequenced `history_end`. | Preserve each message's sequence version, including delta mutations, and put a stream/open-scoped snapshot cursor on HTTP pages and SSE events. Delayed HTTP must not roll back newer state. |
| Turn lookup could exceed frame/page limits | Exclusive selectors, bounded pages, context-bound continuation tokens, explicit end/coverage; receipt reply IDs bounded to 32 with `more`. | Page filtered recovery, keep results bounded, and never interpret an empty/unavailable lookup as permission to rerun a prompt. |
| Persistent truncation caused reopen loops | Appendix C separates persistent prefix truncation/interior holes from transport discontinuities; recovered messages and coverage stay in sequence. | Show coverage and keep consuming valid live events; resync only for a real gap/fence/generation/reset. |

The 12 fixture JSON files parse, carry `requires: "r8"`, and have matching
scenario/file names. The published runners explicitly report them NOT RUN,
which is appropriate while r8 is unimplemented. This review did not execute
them against an r8 host or client, and did not build/edit an Atem checkout.

## Implementation and test obligations

- Astation owns the delayed HTTP/SSE merge fixture: preserve the newer closed
  approval and assistant parts when an older page arrives. Compare versions
  only within the same target, attachment and open/stream instance.
- Retain one host conversation per target and attachment, shared across local
  readers. The current approval activity observer must become a reader of
  that coordinator when full native/API chat lands, rather than opening a
  competing conversation. Closing one local reader must not close another's
  host view or stop the agent.
- Add a continuation test with live/late messages arriving between pages:
  exhaust the original selection snapshot exactly once; later content stays
  live. Also cover token reuse across attachments, reload and runtime restart.
- Ensure the client truncation fixture supplies a real registry snapshot
  before opening the chat, or explicitly defines a safe client setup that
  supplies it. The current Astation client requires a fresh registry to bind
  a session; the test adapter must not bypass that gate.
- Recheck immutable receipt identity/state separately from the mutable
  `result.reply_message_ids`/coverage projection. Late content and eviction may
  change the projection even after completion; they must not cause replay or
  an invalid-final-receipt failure.
- Card-reason, interrupted-result and broker-restart-result fixtures remain
  implementation work, as the response explicitly states. Real agent effects,
  restart adoption and the protected API/SSE behavior still need joint tests.

## r7.3 session-rule revoke

The planned change is accepted in principle: removing an allow rule may
require current **control permission**, without holding or acquiring a
session control lease. It reduces an existing grant and must not type into
the agent or take control from another device.

Before Astation changes its wire/UI, publish the exact r7.3 binding/payload,
admission order, receipt and fixture changes. Preserve the full authenticated
target, attachment, trust/process checks, exact active rule, durable request
identity and duplicate recovery. Test that a lease-free revoke leaves the
current lease holder/epoch unchanged, view-only devices cannot revoke, queued
revokes are fenced by trust/process changes, and simultaneous/duplicate
revokes have safe recorded outcomes. No implicit `acquire` should be added.

The running Astation build deliberately retains r7.2's lease requirement until
that contract is published. The r8 appendix must incorporate r7.3 when it is
finalized, rather than restoring r7.2's lease requirement accidentally.
