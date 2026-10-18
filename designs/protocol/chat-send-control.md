# Chat Send and session control

Status: user-approved behavior, implementation authorized 2026-10-18. This
records the Astation/Atem handoff for protocol design and implementation.
See the [joint API proposal](agent-control-api.md).

## Agreed user behavior

Chat and remote terminal interaction share one control lease per agent session.
Viewing either requires no lease. Remote terminal input continues to require
an explicit Take Control action. Chat avoids that separate step for normal
prompt submission:

| Authoritative ownership when sending | Behavior |
| --- | --- |
| Nobody holds control | Clicking Send atomically acquires control and submits the prompt. |
| This client holds control | Send immediately using its current control lease. |
| Another client holds control | Show who controls the session and offer Take over and send with confirmation. |

An ordinary Send never silently takes control from another operator. This
behavior applies consistently to the native chat view and protected local API;
API callers must explicitly authorize takeover rather than gaining it by default.

## Requirements for the joint contract

- Atem checks current ownership at admission, not the ownership last displayed
  by Astation. If another client acquires control before an ordinary Send
  arrives, the prompt is refused without execution and the UI offers an
  explicit takeover decision.
- Acquisition and prompt acceptance are one host operation. Astation must not
  emulate this with independent acquire and submit messages. The contract
  must define how lease changes and durable acceptance commit together,
  including validation or persistence failure without an unintended takeover.
- Every send retains the existing verified principal, control permission,
  full target, attachment, trust/process generation, capability and durable
  receipt checks. Control permission authorizes the operation; the lease
  coordinates writers. The relay never supplies either authority.
- Takeover confirmation identifies the target session and current controller
  from authenticated state. Changed ownership or target while confirming
  requires revalidation; a stale dialog cannot silently authorize a different
  takeover.
- Preserve the request UUID and canonical content across uncertain delivery.
  Check the original receipt before offering a new send or takeover attempt.
  Reconnecting or querying a receipt must not acquire control or replay a prompt.
- Once accepted, work follows the existing durable execution lifecycle. A
  client disconnect or later lease change is not proof that the prompt did
  not run and does not automatically cancel accepted work.
- Lease renewal and release have an explicit native/API owner. A chat read
  subscription or abandoned API caller must not retain control indefinitely.

The operation shape, revision/capability negotiation, refusal codes, request
identity rules, lease/receipt transaction boundary and fixtures are agreed
at the pinned r8 commit below. Existing r7.3 clients and hosts retain their
published semantics until the coordinated r8 implementation passes its checks.

## Required shared tests

Test Send with an unowned session, the current holder and another holder.
Include two simultaneous sends from different clients, ownership changing
between display and admission, local terminal input winning, and stale
takeover confirmations. A refused ordinary send must not take over or execute.

Verify that duplicate UUIDs, disconnection immediately after acceptance,
delayed receipts and reconnects never repeat the prompt or reacquire control.
Exercise failed persistence, expired leases, revoked device permission and
process replacement before dispatch. Terminal and chat must enforce the same
writer ownership without crossing sessions.

## Approval policy and host handoff

The user also authorized lease-independent approval actions on 2026-10-18.
Require the verified device's current control permission and an exact pending
approval, but leave the terminal controller unchanged for Allow once, the
exact offered Always allow rule, and Deny. Rule matching remains authoritative
on Atem; Astation must not add its own command matcher or grant an unoffered
rule. Pending-approval races must resolve atomically on the host with durable,
idempotent decisions and catch-up that closes stale cards everywhere.

Checked against Atem main `976e15462b834a0fc270a9b541cd6952632c522c`:

| Operation | Published host support | Astation work |
| --- | --- | --- |
| Revoke an active rule without holding a lease | Implemented in r7.3; exact payload `{rule_id}`, no lease side effect | Implemented locally with one Revoke confirmation, durable receipts, API and pinned fixture validation. |
| Answer a pending approval without changing the lease | Missing: current answers require a lease or `acquire: true`, which takes control | Preserve r7.3 behavior until the coordinated r8 implementation. |
| Acquire an unowned session and submit a chat prompt atomically | Missing: current prompt payload is exactly `{text}` and requires an existing lease | Await a host atomic operation; never use an acquire-then-submit workaround. |

### Implementation handoff

1. Atem implements the r8 host at the signed-off commit below, including
   durable admission/refusal, revocation fences and clean/unclean recovery.
   Run the host scenarios and filesystem fault tests listed in the r5 review.
2. Astation implements revision/capability negotiation, ordered history
   recovery, the shared native/API Send/takeover service and lease-free
   approval answers. Bind confirmation to the displayed controller and epoch;
   reject late replies that would restore obsolete control. Give native/API
   callers explicit ownership, renewal and release behavior.
3. Both sides pin and run the applicable shared fixtures without treating
   unsupported steps as passes. Use disposable Claude and Codex sessions for
   the joint mutation, approval and recovery matrix before release.

The host wire shapes and fixture corrections are agreed; implementation and
live acceptance remain. Terminal input and interrupt/stop keep explicit
lease checks, and section 9's security gates remain enforced. Atem changes
belong to its owner; the Astation agent has not edited or built an Atem checkout.

### Coordinated r8 implementation gate

The Atem agent published both missing operations for review on 2026-10-18 in
[Atem PR #74](https://github.com/Agora-Build/Atem/pull/74), branch
`docs/agent-control-api`, commit
`f9fa57aaed2cc7c57e097de678eb3733095af88a`. The contract adds
`chat.send_acquire` (prompt submission with `acquire: true` and optional
`takeover: true` plus `expected_controller`) and `approval.lease_free`
(answers require control permission, leave the lease unchanged and refuse
`acquire`). These are approved r8 wire shapes, not payloads Astation can send
to r7.3.

The [r5 review](agent-control-api-atem-r5-review.md) grants design sign-off
for this exact commit, with no remaining blocking findings. The lost-fence
case is resolved: any failed revocation write halts dispatch and fences input
in memory, and any unclean run rejects recovered queued work with
`authorization history unknown` before it can run. Only a healthy orderly
shutdown writes a clean-close marker bound to its runtime epoch. After a
clean close, trust/control checks and principal reconfirmation within 60
seconds still apply. The fixture UUID and earlier history corrections are
complete. Atem may start r8 implementation; static fixture checks are not
host/client conformance or release approval.

The provisioned local Astation remains on r7.3: direct rule
revocation is lease-free, approval answers still acquire control, and atomic
chat Send awaits the coordinated r8 implementation. The build executed 924 tests with
6 skipped and zero failures. A read-only live check found running Claude and
Codex sessions with no remote control held; no prompts or approval mutations
were sent to those working sessions.
