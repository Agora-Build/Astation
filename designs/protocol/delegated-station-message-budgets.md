# Delegated Station message budgets

Confirmed against Atem main `f345dbdb3e94f2dab0c305d47e586b186bbac9e0`,
Atem #120 comment 6815911988 and handoff vault `v-8ut37j7X` entry e286.
This corrects the earlier Astation review's 512 KiB membership-fetch wording.

## Relay control messages

R9.9 caps each serialized relay control message at **256 KiB (262,144 bytes)**,
including its envelope. This includes `control_sync`, `control_sync_result`,
`heads`, `control_ack`, `membership_fetch`, its result and typed refusals.
There is no membership-fetch exemption.

A membership page contains at most 64 entries and must also fit the byte
limit. Maximum-size signed entries plus JSON escaping and the envelope can
require a smaller page. Never truncate a signed entry to make it fit.
The host continues fetching until it reaches the advertised membership head.
The Station implementation must use the shared bounded builders and validate
the serialized size, rather than assuming 64 entries always fit.

## Other transports

The planned stage-3 host-sender mailbox calls have a separate **512 KiB**
encoded-call budget. That limit does not apply to relay control messages.
The existing encrypted member-channel WebSocket limit is **2 MiB**
(`relay-server/src/remote_api/channels.rs`); it is a separate transport bound.

## Current Station implementation

The Station does not yet implement the delegated `membership_fetch` or
`control_sync` handlers, so it has no 512 KiB response assumption to remove.
Its existing push ACK serializer already measures the complete envelope
against 262,144 bytes (`relay-server/src/remote_api/push_ack.rs`).
The forthcoming delegated handlers must preserve the R9.9 bound. This note
does not claim that their runtime enforcement or joint tests are complete.
