# Astation review of Atem's r8 Send and approval draft

Reviewed 2026-10-18. Source: [Atem PR #74](https://github.com/Agora-Build/Atem/pull/74),
commit `18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0`, the session contract,
response addendum, fixture schema and all 30 `r8-*` scenarios (18 new).

**Sign-off pending.** The Send/takeover and lease-free approval policy matches
the approved user behavior. Findings 1 and 2 need contract clarification before
the coordinated r8 implementation starts. Finding 3 and the remaining fixture
obligations must be resolved before conformance passes. The earlier sign-off
of the history/recovery design remains scoped to that earlier draft.

## Findings

1. **High: permission revocation is specified only for the old live attachment,
   leaving disconnected and recovered queued work uncovered.**
   [Appendix F, line 1167](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/atem-session-v1.md#L1167)
   rejects an attachment's queued work when that link re-authenticates with
   fewer permissions. However, the
   [recovery rule, line 423](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/atem-session-v1.md#L423)
   allows durable accepted work to run after restart based on its target and
   unchanged host trust generation; it does not specify an authenticated
   submitter identity or durable permission-revocation fence. The new fixture
   downgrades a still-connected attachment only.

   Concrete missing case: D submits P1 and queues P2, disconnects, then
   re-authenticates with view only before P1 finishes. The old attachment is
   already gone. P2 must be durably rejected as `control revoked`, including
   after a broker restart, rather than running under the older admission.
   Specify the stable authenticated principal and authorization generation
   retained with accepted work, how downgrade invalidates work from its prior
   attachments, and how that fence survives restart or a failed rejection
   write. This metadata need not change the payload digest. Disconnect,
   ordinary lease expiry and same-permission reconnect must still allow
   accepted work to complete; the relay supplies none of this authority.

2. **High: the failed-write promise conflicts with the inherited double-I/O
   exception.**
   [Appendix F, line 1102](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/atem-session-v1.md#L1102)
   promises that a failed accepted write returns `busy`, records nothing,
   changes no lease and executes nothing. But
   [section 6, line 372](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/atem-session-v1.md#L372)
   expressly permits a request answered `busy` to execute later if both the
   write and rollback fail. Appendix F retains section 6's lifecycle and
   does not say whether it replaces that exception. Rust and Swift therefore
   cannot agree whether this `busy` is a definitive refusal.

   Define one recoverable rule for append/fsync plus rollback failure, and
   for a crash after accepted becomes durable but before the in-memory lease
   grant. A definitive refusal must not later execute. An unresolved write
   must preserve the original UUID and be reconciled without silently
   granting control or being treated as a fresh Send. Add fixtures for the
   double failure and restart boundary, including a confirmed takeover while
   another controller holds the lease. The single `fail_next_fsync` action
   does not establish that behavior.

3. **Medium: two captures are nested inside `match`, making the new
   persistence fixture unexecutable as specified.**
   [r8-failed-persistence-changes-no-lease.json:129](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/fixtures/r8-failed-persistence-changes-no-lease.json#L129)
   and
   [line 298](https://github.com/Agora-Build/Atem/blob/18ae9fa3a8811b0b5d13a0a10a2d126c0e34b3a0/designs/protocol/fixtures/r8-failed-persistence-changes-no-lease.json#L298)
   put `capture` in the object that is matched against the receipt. The
   schema requires it beside `match`. The harness would seek a `capture`
   field in the wire reply, while `${e1}` and `${e2}` remain undefined.
   Move both objects to the step level. Static inspection found two misplaced
   captures and six subsequent unresolved references in this scenario.

## Accepted policy and wire decisions

- The proposed permission-loss rule is correct in principle: reject accepted
  work that has not started after its principal loses control permission;
  leave already executing work to its existing receipt lifecycle. Permission
  revocation is distinct from losing the writer lease. Finding 1 asks that
  this rule remain effective independently of a live connection.
- `acquire: true` only for prompts, with ordinary Send refusing another
  holder. Explicit takeover binds to the displayed controller and lease
  epoch. A changed holder requires new confirmation; an unowned session
  can be granted without taking anyone else's control.
- Admission flags stay outside the immutable prompt digest. A validated
  duplicate returns its existing receipt without acquiring, renewing or
  executing. The client keeps the same UUID and original text through
  refusal, confirmation and uncertain delivery.
- Acquisition follows durable acceptance; the admitting reply carries the
  lease. Ordinary Send under an existing lease never renews it. Astation
  owns renewal/release and arbitrates native/API callers sharing its one
  host attachment. Unknown controller identities use a neutral label;
  relay labels are not authenticated person/device identities.
- Lease-free approvals require current control permission and the exact
  pending request. First admitted answer wins; a different later answer is
  `stale_target`. Grant only the offered rule, ignore the binding's epoch,
  reject the removed `acquire` form and preserve the terminal holder.
- Terminal input, interrupt and stop retain explicit control. Neither a
  receipt lookup nor a chat/history reader acquires or renews a lease.

## Remaining conformance obligations

The new approval fixtures all start with a holder and run at clock zero.
They check holder/epoch and absence of lease-change messages, but cannot
detect an implicit renewal that resets the same deadline at that instant.
Add an answer at a later clock time, check the unchanged remaining lifetime
without renewing first, and prove the old holder's queued input remains
valid. Also test answering when nobody holds a lease. The schema's original
`open_approval` row still incorrectly says no live remote lease means silent
refusal; align it with control-permission-based delivery.

Add client scenarios for a delayed admitting receipt carrying `lease` after
local input, takeover, attachment replacement or local expiry. Applying the
new receipt field must not resurrect control. Include API/native arbitration
and renewal tests in Astation, plus the existing approval persistence,
terminal-answer race and catch-up tests against the r8 implementation.

The two earlier r2 fixture corrections remain unchanged in this commit:

| Fixture | Outstanding correction |
| --- | --- |
| `r8-long-turn-is-recovered-in-bounded-pages.json:391` | Two opens occur, but `chat_opens` is still 1. Set it to 2. |
| `r8-client-shows-truncation-and-resyncs-only-on-a-sequence-gap.json:148` | `page.wire_bytes` is still 300; the supplied history message plus end envelope total 675 compact UTF-8 JSON bytes. Generate it with the harness encoder. |

## Validation and implementation state

Fetched the pinned GitHub documents and fixtures read-only into a temporary
review directory, recording SHA-256 values. All 30 scenarios parse as JSON,
have matching names and carry `requires: "r8"`. Static capture/reference and
page-byte checks produced the findings above. No r8 host/client effects were
executed: the contract and runners explicitly mark these scenarios NOT RUN.
No Atem checkout was edited or built, and no agent prompt or approval was sent.

The installed personal provisioned Astation remains on r7.3, including direct
lease-free rule revocation. Await a revised pinned contract resolving the
two lifecycle findings before starting the coordinated r8 implementation.
