# Completing verification after a host rekey

An already proved host can be re-verified on its current relay socket. Native
Astation first publishes the new signed `add_host` durably, commits its local
membership log, then sends `deviceVerified`. Publication invalidates the old
route proof. The final certificate needs a separate, bounded transport path;
keeping the old route authorized would also admit stale agent traffic.

## Completion window

Station opens one window when a currently proved host sends a strict
`verifyCommit` naming its own host ID and an increasing `host_trust_gen`.
The window captures:

- the account genesis and original host binding;
- the current verified room owner connection, including its replica;
- the active native manager's signing key and the current membership sequence;
- the requested host trust generation;
- an absolute 180-second deadline, matching the native ceremony timeout.

Another commit cannot extend or replace the window. The deadline closes the
socket even when no traffic arrives. State is local to the host socket's replica,
is removed at disconnect, and is never recovered after a replica restart.

## Authorization and delivery

The original route proof continues to gate ordinary frames, channel messages,
service requests, terminal input, push and API routing. After it becomes stale,
those frames are dropped. Cleanup preserves only an eligible verification window.
No old proof is relabeled or restored.
Owner-present API routing also checks any existing socket proof, so it cannot
turn a stale proved socket into an unproved route during this window.

The completion path checks membership under the same root lock used for append
and route queue admission. The manager must remain active with the captured key;
the log must not be frozen. Both socket generations must still be current in a
fresh room-directory read. A different proved route, host removal, owner
disconnect/replacement, or a different trust generation invalidates the window.

Before publication, the original host record and binding must still be current.
After publication, the current host must have the requested generation in a new
`add_host` signed by that same manager. `deviceVerified` specifically requires
this published state. A removal followed by re-addition does not revive a window.

Only generation-targeted owner `verifyKeys`, `deviceVerified` and `verifyAbort`
frames use this path. Strict JSON rejects duplicate keys and ambiguous frame
types; the original signed payload bytes are forwarded unchanged. After the
proof is stale, host ingress can forward only `verifyAbort`, not arbitrary
payloads or another reveal. A reveal precedes publication in the native flow.

Cross-replica delivery uses a distinct internal `VerificationDeliver` operation
carrying the owner connection and room. The receiving replica rechecks them.
Generic delivery, including a generic frame named `deviceVerified`, never gains
the completion bypass. Mixed replicas fail closed if an older replica cannot
decode this new internal operation; a failed attempt can be retried after rollout.

On completion or abort, Station uses required queue admission, then closes the
old socket with WebSocket code 1013. The existing writer flushes queued messages
before the close, within its bounded close-flush timeout. If queue admission or
delivery fails, no success is inferred. Atem must verify and durably pin the
certificate, then reconnect and prove the new identity; no session or request is
replayed by Station.

## Verification and limits

The regression uses actual WebSockets and signed membership/route proofs:
prove the old host, start verification, publish a new host key, run cleanup and
attempt stale traffic, then deliver completion and reconnect with the new key.
It runs on one replica, across the production dispatcher on two in-process
replicas, and (as an explicit integration test) on real Redis with two Postgres
pools. The same regression fails on the previous implementation with
`host route changed`.

Additional cases cover a missing verification window, completion before publication,
connection replacement, delayed delivery from an old owner, host removal, strict
JSON, idle expiry and attempts to renew the deadline. Native controller tests
cover failed publication, account/connection changes, expiry and publication
before completion.

These tests do not substitute for a provisioned native ceremony with owner
confirmation and host-side receipt of the real certificate. That live check
remains part of Astation #80. Delegated Station/native work remains in #79;
activation and signing gates are unaffected.
