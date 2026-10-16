# Session Multiplexing: Initial Build Contract

Date: 2026-10-15

Status: historical initial proposal, superseded for managed sessions by
[atem-session v1 r5](protocol/atem-session-v1.md). Use the
[current implementation handoff](protocol/atem-implementation-handoff.md).
The optional terminal lease below is retained only as a legacy reference.

This contract proposed the first compatible layer of
[the approved design](session-multiplexing.md). The Astation and Atem agents
must use the same fixtures and field names. Product approval is not evidence
that every feature described in the design has shipped.

## Ownership and delivery

| Layer | Atem | Astation, relay, and webapp |
| --- | --- | --- |
| 1: explicit trust lifecycle and bounded control | Separate pair/verify; unified status; renewable host control leases | Verified-access UI/gates; exact session selection; lease renewal |
| 2: persistent host/session ownership | Shared per-profile broker; independent workers; durable receipts/history | Distinct hosts, sessions, generations, and multiple attachments |
| 3: account-wide native trust | Validate explicit account enrollment authority, native membership, freshness, and encrypted channels | Native enrollment/management, signed revocation, encrypted channels; opaque relay routing |
| 4: independent browser companion | Validate limited browser keys/grants and host control permissions | Native QR approval, pending requests, browser key handshake and scoped routing |

Each layer needs its own implementation and integration evidence. Do not
advertise account-wide native access, crash-surviving workers, independent
browser access, or live traffic confidentiality before the responsible layers
are implemented. Preserve existing processes and pairwise pins during upgrades.

## Current implementation limits

The Astation task worktree now uses the r5 client and common session lease in
the native remote terminal UI. Legacy controller code remains isolated for
unmanaged callers and regression coverage; it is not an authority fallback.
See [current evidence](protocol/astation-session-v1-implementation.md).

All Atem implementation belongs to the Atem agent. Lifecycle commands and trust
generation are published on `feat/status-pair-verify` through `207b0e9`; do not
duplicate that work.
A separate uncommitted local Atem experiment has been stopped and preserved
only as an optional reference diff. Its blanket refusal of remote chat submits
was an unfinished experimental policy, not behavior of a published Atem build.
See the [provenance correction and handoff](protocol/atem-implementation-handoff.md).

Host lease support and shared session integration must be verified with the
Atem owner's actual implementation. This Astation build does not establish
shared brokers/workers, durable receipts/history, account-wide enrollment,
independent QR companions, traffic E2EE, or complete key recovery.

## CLI lifecycle

`atem pair` only establishes a binding. If any persisted binding already exists
for this profile, including expired or unverified pairing, it reports that state
without network pairing, key rotation, or another verification exchange. An
expired login or locked key agent does not authorize replacing the binding.

`atem pair verify` operates only on the existing pairing, through an authenticated
connection to its exact Astation identity. Both endpoints compare the safety
code and explicitly approve. Valid verified bindings are idempotent. A timeout,
cancel, stale callback, identity mismatch, or persistence failure is not success.
Keep pairing available for an explicit retry; never silently replace revoked or
changed keys. Credential persistence preference remains separate from verification.

`atem cred unlock` and `atem cred lock` never initiate pairing or verification.
Unverified unlock fails with the exact next action `atem pair verify`. Unlock
can require fresh native Touch ID/password approval using existing trust. Lock
can clear local keys offline, including when no valid pairing exists. Lock and
unpair preserve stored account data, service credential records, and agent work.

`atem status` is one read-only, offline-capable status implementation. The legacy
`atem cred status` forwards to it. Its user-facing label is `Credentials`.
Distinguish account login, persisted pairing, cryptographic verification,
credential availability, authorization freshness, relay connectivity, and agent
liveness. Cached state is labelled stale or unknown; a saved PID or past relay
connection is not proof of a current connection. Status must not autostart a
key agent, perform verification, prompt for authentication, or mutate trust.

Local agent launch does not require pairing or verification. Remote operations
require the trust and authorization appropriate to their protocol layer.

## Terminal lease extension

Keep the outer `type: terminal` message and the inner terminal `v: 1` encoding.
This is an additive, explicitly negotiated extension, not an account-trust
protocol or a claim of live end-to-end encryption.

Each session descriptor advertises:

```json
{
  "terminal_id": "claude-process-a",
  "generation": "process-generation-a",
  "provider": "claude",
  "rows": 24,
  "cols": 80,
  "exit_status": null,
  "rendering": "vt100-screen-diff",
  "width_profile": "atem-unicode-width-0.1.14",
  "capabilities": ["terminal-lease-v1"],
  "agent_id": "agent-a",
  "label": "Claude / workspace-a"
}
```

`capabilities` defaults to an empty list for an older descriptor. `agent_id` and
`label` are optional. Display labels and provider names never determine a target.
When selecting an agent, match its exact agent/session binding; ambiguous
same-provider sessions require explicit selection rather than selecting the
first session. Session/process IDs cannot be reused for replacement processes.

Existing `control` obtains/releases ownership. Grant a random `lease_id`, bound
to the authenticated attachment, stream, terminal ID, and process generation.
Expire it 15 seconds after grant or its last accepted renewal using a monotonic
clock. Client input itself does not renew a lease.

The new request is:

```json
{
  "v": 1,
  "op": "renew",
  "terminal_id": "claude-process-a",
  "generation": "process-generation-a",
  "stream_id": "stream-a",
  "lease_id": "lease-a"
}
```

An accepted renewal uses the existing response:

```json
{
  "v": 1,
  "op": "controller",
  "terminal_id": "claude-process-a",
  "generation": "process-generation-a",
  "stream_id": "stream-a",
  "lease_id": "lease-a"
}
```

Renew every five seconds only while holding the currently acknowledged lease.
Only a matching response advances the client's local control deadline. At 15
seconds without acknowledgment, disable client mutations, clear control, and
require explicit Take Control. A delayed response cannot resurrect expired
control. Never automatically retry terminal input or reacquire control.

The host checks expiry before input, resize, stop, and renewal, independently
of UI timers. Expired or mismatched renewal is rejected and cannot acquire a
lease. Expiry, disconnect, and local reclaim invalidate the PTY input epoch so
already queued remote bytes cannot cross a later ownership transition. Local
terminal input takes priority. Reattachment never revives an old lease.

Advertise the capability only after enforcing these rules. A new native client
may view a verified older host, but disables Take Control when the session lacks
`terminal-lease-v1`, with an update instruction. The relay forwards the terminal
envelope opaquely and never issues leases or interprets lease IDs as authority.

## Security and generation boundary for subsequent layers

Existing pairwise verification remains authoritative only for its current
binding. Relay account grouping, service login, presence, and ordinary socket
authentication cannot upgrade it into account-wide native trust.

Before enabling layer 3, define and implement the exact signed native membership
format, management delegation limits, enrollment bootstrap, durable host trust
generation, revocation ordering, and authenticated freshness proof. A fresh proof
must bind an unpredictable endpoint challenge to the accepted trust authority;
replaying a signed snapshot or asking the relay for its current time cannot
refresh the 24-hour window. Persist rollback protection across restarts and
fail closed when a reliable remaining lifetime cannot be established.

Protected operations must bind account, host/profile identity, host trust
generation, agent/session ID, process generation, authenticated controller,
attachment generation, permissions, request ID, and lease epoch. Authenticate
and encrypt payloads end to end with reviewed cryptographic primitives before
claiming relay confidentiality. Reject protocol downgrade, stale generations,
cross-target reuse, and unknown authority. No transport switch changes trust.

Before enabling layer 4, implement native-approved browser-key grants with a
two-minute QR request and at most a one-hour grant, fresh proof of browser key
possession, exact target/scope, replay prevention, and host validation independent
of the approving native app remaining online. A legacy URL capability forwarded
through Astation is not this protocol and must not be described as such.

## Shared fixtures and integration checks

The canonical fixture is
`Tests/AstationTests/Fixtures/session-multiplexing-v1.json`; Atem checks in the
same bytes at `tests/fixtures/session-multiplexing-v1.json`. Both decoders must
consume the renewable-lease requests, responses, and session metadata. Policy
durations are seconds; wire field names use the existing snake_case convention.

Required evidence for the first layer:

- Repeated pair on paired/unverified/expired profiles makes no binding changes.
- Explicit verification handles cancellation, timeout, retry, and revoked keys.
- Status and lock work offline without prompting or starting a key agent.
- Authenticated but unverified remote terminal/chat/mutation paths fail closed.
- Renewal before expiry keeps exactly the same lease; renewal after expiry,
  old generations, and old lease IDs cannot regain control.
- At lease expiry or local reclaim, queued input from the former owner is
  rejected at the PTY boundary; input is never replayed after reconnect.
- A verified legacy host can be viewed with a clear update requirement for
  renewable control. Both direct port 8080 and relay transport remain supported.

Remaining layers additionally require the complete acceptance matrix in the
product design, including multi-controller fanout, broker/worker crashes,
durable acceptance and receipt recovery, cross-device enrollment, signed
revocation races, and independent QR companion access.
