# Session transport recovery with r7.1

The contract and shared fixtures now pin Atem PR #72 at
`6edda2490f4a4b7634edb446f64aa02748e29fa2` (r7.1). A second non-resume hello on
the same authenticated transport replaces the host attachment. It fences the
old leases, streams, conversations and pending replies, preserving receipts,
pending approvals, permissions and the original authorization deadline. The
new attachment and controller-session identifiers are UUIDs. Old attachment
mutations receive stale_target; replacements within one second receive busy.

Astation keeps transport reconnect as its retry/sleep/wake recovery strategy.
This still works with r7.1 and covers a dead socket. A recreated session client
can send hello on a surviving authenticated link; the replacement welcome
starts with no control and recovers durable receipts without resubmitting.

## Lifecycle and security invariants

- Sleep immediately fences attachment state, control leases, queued replies,
  terminal writes and actionable approvals. Close the Mac's shared relay socket
  and authenticated direct sockets; wake reconnects the relay and the direct
  Atem reconnects to the existing listener. Do not re-pair or change credentials.
- Retry Session Connection requests a transport reconnect. A post-welcome
  unauthorized refusal automatically does the same once. An initial refusal
  stops with a neutral access error and an explicit reconnect action, avoiding
  an automatic reconnect loop or an incorrect verification instruction.
- Capture a local relay socket generation in the session context in addition
  to the relay's Atem connection id. The latter may remain unchanged when the
  Mac reconnects. Old callbacks, replies and control cannot inherit the new
  authenticated context. A loss/restoration of local session context on the
  same transport must reconnect rather than sending hello again.
- Reconnection needs fresh relay key verification and the saved Atem session
  proof. Send one hello after authentication. Never restore a lease or replay
  commands/approval answers; query durable receipts under the new attachment.
- A reconnect closes the shared Mac relay socket and temporarily affects every
  relay Atem attached through it. Fence all of them before reopening. Direct
  retry closes only the selected authenticated socket.
- Pairing-room sockets remain credential handoffs, never online Atems or
  session/control targets. Re-pairing must not introduce a room-code row.

## Validation

Cover workspace sleep/wake notifications, a surviving host connection id,
transient local context loss, explicit retry, post-welcome unauthorized,
initial unauthorized without a reconnect storm, stale socket callbacks and
old attachment messages, receipt-only recovery, lease loss, direct socket
recovery, and pairing with an already online host. The pinned r7.1 fixture
second-hello-replaces-the-attachment is a host scenario, not a client scenario.
Astation checks its actual request wire shapes with a UUID substituted for
${gen2} and separately exercises client recreation over the same authenticated
transport, old-grant fencing, explicit reacquisition and original-receipt
recovery. These tests do not execute the host's dispatch counters, replacement
rate limit or stale_target admission; those require Atem's host runner. See
[the joint validation matrix](../protocol/session-validation.md).
