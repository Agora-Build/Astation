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

The operation shape and fixtures are implemented in the shared r8
session service. See [r8 client lifecycle](r9-client.md) and the
[local API guide](../../docs/local-control-api.md). Astation requires r8;
there is no r7 fallback.

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

The host and client now implement these operations at contract pin
`4f87bab1289848cb6a0da5707d2e7830eb5c057d`. Native Send offers one confirmation for
Take over and send, bound to the authenticated controller and epoch. API
callers explicitly pass that same expected_controller. Answers and rule
revocation use control permission without changing the lease.

The [r6 review](agent-control-api-atem-r6-review.md) confirms the four
implementation edits. All seven shared client scenarios execute in Swift;
provider approval/mutation acceptance still requires disposable live sessions.
Terminal input and interrupt/stop retain explicit lease checks. Section 9's
security gates remain enforced. Atem changes belong to its owner.
