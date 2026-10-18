# Astation r5 review: r8 design sign-off

Reviewed 2026-10-18. Source: [Atem PR #74](https://github.com/Agora-Build/Atem/pull/74),
pinned commit `f9fa57aaed2cc7c57e097de678eb3733095af88a`, including the
contract, response addendum, fixture schema and all 42 `r8-*` scenarios.
GitHub's PR head matched that commit when checked.

**No blocking findings remain. Design sign-off is granted for this pinned
commit; Atem may start implementing r8.** The failed-revocation-fence
recovery finding and controller-session fixture correction from the
[r4 review](agent-control-api-atem-r4-review.md) are resolved. This is approval
of the design for implementation, not a passing conformance result or release
approval. r8 is not running in the provisioned local Astation.

## Why the revocation recovery finding is closed

[Section H](https://github.com/Agora-Build/Atem/blob/f9fa57aaed2cc7c57e097de678eb3733095af88a/designs/protocol/atem-session-v1.md#L1318)
now fails closed both within the run and after restart:

| Case | Required result at this commit |
| --- | --- |
| Fence or queued-rejection write fails | Fence the principal's attachments and lease, discard queued remote input at the write boundary, reject its queued work in memory and halt the journal. No queued work for any principal dispatches after the halt. |
| Halted run or crash, then control restored before reconnect | No clean-close marker exists for that run. Every recovered accepted request that had not started is durably rejected with `authorization history unknown`, including the old queued UUID. Current permission cannot revive it. |
| Failed write leaves a record on disk, or rollback removes it | The unclean-run rule applies to both outcomes; recovery does not infer authorization history from whichever writes survived. |
| Orderly shutdown with a healthy journal | The clean-close marker is written after admission stops and all other journal writes are durable. It names the run's `runtime_epoch`; startup matches it to the previous stored epoch and advances the epoch, preventing reuse by a later run. |
| Queued work recovered after a clean close | Check host trust and durable `control_gen`, then require that principal's control to be confirmed within 60 seconds. Another principal's reconnect does not confirm it; timeout is final rejection. |
| Work was already executing | Reconcile its outcome or report `outcome_unknown`; do not replay it. |

The recovery precedence is explicit: refusal-list entries become
`acceptance not confirmed` first; an unclean run gives `authorization history
unknown` next; only after a clean close do the trust, control-generation and
bounded confirmation checks apply. A failed recovery-resolution write disables
remote sessions and dispatch. Already durable rejections keep their detail.

This closes the r4 trace even when the revocation fence itself was lost and
control was regranted before authentication. The cost is explicit and
acceptable: after a crash, an accepted prompt that never started is rejected.
The client first confirms the old receipt is final; an intentional resend
uses a new request UUID. Uncertain delivery still uses the original UUID and
receipt recovery, never automatic replay with a new UUID.

The updated fixtures distinguish `crash_runtime` from an orderly
`restart_runtime`. The four new scenarios cover immediate in-memory fencing,
failed-fence recovery after regrant with both rollback outcomes, crash
recovery without authorization history, and clean-close recovery after
principal confirmation. Existing rejection-write-failure and
crash-after-acceptance scenarios now expect `authorization history unknown`.
The confirmation-timeout scenario now starts from a clean close. The delayed
client receipt scenario supplies a fresh `controller_session` on its second
attachment.

## Scope of sign-off

The agreed r8 design includes sequenced history pages and `history_end`,
bounded continuation and coverage, required revision/capability negotiation,
atomic chat Send/acquire and confirmed takeover, lease-free approval answers,
and the principal, revocation and persistence rules in sections H and I.
The earlier history fixture corrections remain intact.

Remote terminal input still requires explicit control. Ordinary Send never
silently takes over another holder. A takeover is bound to the controller and
lease epoch the user confirmed. Admission becomes durable before the lease
moves; duplicate UUIDs return the original receipt without acquiring again.
Interrupt and stop retain their explicit lease requirements. Approval answers
and rule revocation require control permission and leave the terminal lease
unchanged. Astation arbitrates native and API callers within its authenticated
principal and owns their renewal/release lifecycle.

This sign-off covers the current paired-native compatibility mode. The relay
remains a router, never an identity, authorization or encryption authority.
Account-wide enrollment, browser access, freshness proofs, E2EE and host push
ingress remain behind section 9's separate gates. A revocation and regrant
entirely while the host is down remain the authority's responsibility as
documented in H; the current confirmation flag must not be presented as a
complete account-wide authorization history.

## Required implementation and release verification

1. Pin this exact contract and fixture snapshot in both implementations.
   Extend the Rust host and Swift client harnesses for the schema steps they
   exercise, including crash versus orderly restart, and run the applicable
   scenarios. Skipped or unsupported steps must not count as passes.
2. Fault the revocation fence and rejection writes with both rollback
   outcomes. Verify journal halt blocks every queued dispatch and queued raw
   terminal writes at the PTY write boundary, not only receipt transitions.
3. Test refusal-list write, rename, replay and clear failures, plus crashes
   around clean-close creation, removal and durable epoch advancement.
   Repeated recovery must remain idempotent, a stale marker must not validate
   a later run, and failed recovery writes must disable dispatch.
4. Verify Astation's native/API ownership, takeover confirmation, delayed
   receipt rejection, explicit renewal/release and abandoned-caller behavior.
   Approval answers must preserve another holder's epoch, input and deadline.
5. Run joint disposable-session tests with Claude and Codex: atomic Send and
   ownership races, immediate disconnect after acceptance, reconnect and
   receipt recovery, process replacement, revocation, approval decisions,
   terminal-answer races and catch-up. Assert actual agent effects as well as
   receipts. Do not send r8-only payloads to an r7.3 host.

## Validation evidence

Fetched pinned source read-only through GitHub; no Atem checkout was changed
or built. All 42 r8 scenarios pass JSON parsing with duplicate-key rejection,
filename/name and revision checks, static capture/reference checks and the
replacement-controller UUID check. The earlier long-turn `chat_opens` value
remains 2; the corrected history page declares 675 wire bytes and its compact
UTF-8 envelopes total 675. Reviewed the changed contract, response, schema
and fixture traces, including the four updated existing scenarios.

The snapshot's 45 file sizes and SHA-256 values match its download manifest.
Key source hashes:

| Source | SHA-256 |
| --- | --- |
| `atem-session-v1.md` | `69a4ae87c756c89fd437cf8158daa7b64ed0f835285375a5212bc99c0ebd414d` |
| `agent-control-api-atem.md` | `da42f9d5a66e49dbee62f8835a1027b7745cb0f83e9fb82a9b6ee40044a1856c` |
| `fixtures/schema.md` | `6b46cf7010350026d72b5c084c482d90daddd9f0abddc58478e46bea3385c509` |

These are static review checks. Rust/Swift conformance, filesystem fault
tests and joint live r8 tests are **NOT RUN** because r8 implementation is
the next step. The installed personally provisioned Astation remains r7.3:
lease-free rule revocation, acquire-and-answer approvals, and no atomic chat
Send yet. The [handoff](chat-send-control.md) records the next work on each side.
