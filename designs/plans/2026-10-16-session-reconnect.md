# Session transport recovery before r7.1

The published Atem PR #72 contract at `5ce333e` rejects a second hello on an
already welcomed attachment. The Atem owner reports a future r7.1 replacement
hello, but its contract and shared fixture have not landed. Until then, recovery
must close and reopen the transport, not send hello on an existing attachment.

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
recovery, and pairing with an already online host. r7.1's shared replacement
fixture and old-attachment stale_target behavior remain a later contract gate.
