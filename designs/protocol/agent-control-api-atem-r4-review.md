# Astation review of Atem's r8 revocation and persistence revision

Reviewed 2026-10-18. Source: [Atem PR #74](https://github.com/Agora-Build/Atem/pull/74),
pinned commit `7548fa05654a97a162844cb84a07e4f9673f9dc8`, including the
contract, response addendum, schema and all 38 `r8-*` scenarios.

**Sign-off pending one revocation recovery case below.** The admission
persistence contradiction, malformed captures and earlier history fixture
corrections from the [r3 review](agent-control-api-atem-r3-review.md) are
resolved. The new principal/control-generation model addresses the normal
revocation and failed-rejection-write paths. Its failed-fence-write path
still needs a durable recovery rule before implementation sign-off.

## Finding

**High: a failed fence write can lose a revocation permanently if control
is restored before the next authentication.**

[Section H, line 1338](https://github.com/Agora-Build/Atem/blob/7548fa05654a97a162844cb84a07e4f9673f9dc8/designs/protocol/atem-session-v1.md#L1338)
halts the journal and closes the new link when the fence write itself fails.
The [restart rule, line 1358](https://github.com/Agora-Build/Atem/blob/7548fa05654a97a162844cb84a07e4f9673f9dc8/designs/protocol/atem-session-v1.md#L1358)
then lets recovered work run once the principal is welcomed with control,
assuming the next authentication will report the lost permission again.
That assumption does not hold if permission has since been restored.

Concrete trace permitted by this text:

1. D has durable `control_gen = 1`; P2 is accepted under generation 1 and
   queued behind P1.
2. D loses control. Writing `control_revoked` for generation 2 fails and
   rollback succeeds, leaving no durable fence. The journal halts and no new
   attachment is welcomed.
3. The host restarts. The stored generation is still 1. Before D next
   authenticates, control is granted to D again.
4. D is welcomed with control within 60 seconds. Current permission is
   confirmed, but the new authentication carries no evidence of the missed
   revocation. P2's recorded generation equals the durable generation, so
   the stated recovery check allows it to run.

This violates H's explicit rule that regaining control cannot revive
pre-revocation work. The new failed-write fixture fails the *rejection*
write after the fence is already durable; it does not exercise failure of
the fence itself. The 60-second timeout does not protect step 4.

Specify a recovery rule that cannot forget an observed revocation: for
example, a durable pending-revocation marker recovered before confirmation,
or a monotonic authorization generation proved by the authority that
includes intervening revocations. If the host cannot persist the intent
or establish that history after an unclean run, keep affected recovered
work from executing automatically. A current `control` boolean alone
cannot establish that no intervening revocation occurred. This does not
require account-wide access or changes to the prompt digest.

Add a fixture that fails the first revocation write, restarts, restores
control before confirmation, and proves the old queued UUID is finally
rejected and never dispatched. Cover both rollback-success and uncertain
rollback outcomes. Keep the same-permission reconnect and ordinary crash
recovery cases working where no revocation is in doubt.

## Resolved review items

| r3 item | Resolution at 7548fa0 |
| --- | --- |
| Accepted work lost its submitter across disconnect/restart | H records authenticated principal and `control_gen`, checks both at dispatch and fences all attachments. The remaining failed-fence-write case is described above. |
| Conflicting failed-admission-write guarantees | I explicitly removes the double-I/O exception. A durable refusal precedes a definitive `busy`; restart records the UUID as rejected before dispatch. If no refusal can be persisted, delivery stays uncertain and the link closes. |
| Same-ID retry after failed admission | I keeps the refused UUID final. After confirming rejection, an explicit resend uses a new UUID. Uncertain delivery and `lease_held` keep the original UUID. |
| Captures nested in `match` | Both are now at step level; no undefined captures remain in the 38 scenarios. |
| History fixture counters and wire-byte total | `chat_opens` is 2; `page.wire_bytes` is 675 and matches the supplied compact UTF-8 envelopes. |
| Approval answers changing the deadline or queued input | A new scenario answers at 6000/9000 ms, checks the remaining lifetime without renewal, flushes queued input, checks expiry at 15000 ms, and answers again with no holder. |
| Late admitting receipt restoring control | F adds outstanding-request, attachment, epoch and send-time deadline checks; host and client scenarios cover superseded replies. |

The normal principal fence and the separate durable admission refusal record
are suitable design directions. A crash after durable acceptance but before
the grant correctly creates no lease on recovery. The explicit
`acceptance not confirmed`, `control revoked` and `control not confirmed`
outcomes give Astation actionable final receipt states without replay.

## Fixture and implementation obligations

One low-priority fixture correction remains:
[r8-client-delayed-send-reply-never-restores-control.json:344](https://github.com/Agora-Build/Atem/blob/7548fa05654a97a162844cb84a07e4f9673f9dc8/designs/protocol/fixtures/r8-client-delayed-send-reply-never-restores-control.json#L344)
reuses the first welcome's `controller_session` after the second hello.
Compatibility-mode replacement requires both a new attachment and a new
controller session (contract section 3). Give that welcome a fresh controller
UUID before running the fixture against the real client.

During implementation, test that a halted journal also blocks queued raw
terminal writes at the write boundary when revocation cannot be persisted;
those writes do not pass through the accepted-to-executing journal transition.
Also fault the separate refusal-list write and its atomic replacement,
including crashes before/after its rename and before/after the rejected
transition is durable. Its replay/clear operation must be idempotent and
must not permit a refused UUID to execute. These are implementation and
conformance obligations for the stated guarantees.

## Validation and next step

Fetched the exact commit's documents and fixtures read-only and recorded
their SHA-256 values. All 38 scenarios pass JSON parsing with duplicate-key
rejection, filename/name matching, `requires: "r8"` and static capture/reference
checks. The corrected history page's declared and actual bytes both equal
675. Reviewed the eight added scenarios and the changed persistence scenario.
These checks do not execute a Rust host or Swift client: the draft remains
unimplemented and the fixture gate remains NOT RUN.

Resolve the failed-fence-write recovery case and pin the corrected commit
for final sign-off. Astation's installed r7.3 build and current wire behavior
remain unchanged while that contract gate is open.
