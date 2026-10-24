# Independent host routing lifecycle

End-to-end validation on 2026-10-22 found a remaining transport lifecycle gate
in the identity-room route. It is separate from encrypted controller admission
and durable signed push ingestion. Account Auth #63 alone does not fix it.

## Accepted shared contract, 2026-10-22

Atem delivered R9.7b, its Rust shared verifier, public vectors and host runtime
at `83c0776d21fa35c656eefaee25edd03cbbd203ee` after correcting the bootstrap
and authentication-order findings. See the [review](remote-agent-api-host-route-review.md)
and [final handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6340237151).
Both Astation dependencies use this pin. The relay implements both carriers,
durable admission, verdicts and generation fencing. Controlled WebSocket,
Postgres and replica tests pass; the actual-host acceptance matrix remains open.

The contract distinguishes two carriers. Carrier A keeps the existing
owner-present Astation-authenticated room for pairing, first verification and
manager reconciliation of a held host, without a route proof. Carrier B is the
independent proved route: isolate the candidate until its proof verifies,
persist the `(genesis_hash, host_id)` binding, fence the previous connection
across replicas, then expose the route and send `host_route_ok`. Refuse it
with the shared verifier's code on failure. Never forward `type:"relay"`
messages between room members, including inside targeted envelopes. A valid
verdict survives overlapping Astation authentication in either order.

The upstream runtime tests exercise a fake relay. Astation must still prove
its own directory, database and replica lifecycle with the real runtime;
accepting the shared contract does not close #64.

## Original failure

`/ws?role=atem&code=<identity-room>&atem_id=<host>` requires the room to exist.
Both directory implementations remove an empty room after the last socket
leaves. A reconnect can therefore receive HTTP 404 if the Mac is offline.
An ownerless room can also expire after 600 seconds; having a host socket is
not currently sufficient to keep it through the directory sweep.

The granted `?session=` route recreates a room, but that route uses a distinct
`session-<id>` room. It is not evidence that the host rejoins the signed
membership's identity route. Read-only review of Atem #89 at `97f8e51` confirms
`src/websocket_client.rs` builds the code-based URL for
`connect_relay_identity_with_mode`. Joint live validation should still confirm
the runtime's selected path and saved-session binding.

The push WebSocket tests explicitly bootstrap the directory room for each
connection. They prove signed ingress/ACK persistence with no Mac socket, not
automatic restoration of that route. Existing independent encrypted channel
tests prove controller access while the host link is present, not indefinite
host-link survival or restoration after every relay has restarted.

## Required behavior

- An enrolled host can restore its own route while every Astation is offline,
  including after host/relay restart and loss of the ephemeral directory.
- The route is derived from current signed host membership and an authenticated
  host binding. A query-string host ID, room, account login or old pairing code
  cannot create authority or replace the current host connection.
- Removing or replacing the host fences the old binding before routed effects.
  Uncertainty refuses recovery; there is no plaintext/older-protocol fallback.
- A live authenticated host route survives ordinary presence sweeps. Empty
  pairing rooms retain their bounded lifetime and cleanup behavior.
- Restoring routing creates fresh connections/channels. Ciphertext, leases and
  uncertain agent submissions are not replayed across the old connection.

Coordinate the supported host reconnect/proof entry point with Atem on #81.
Use the shared verifier and an agreed binding; do not introduce an Astation-only
signing domain or promote an unauthenticated `atem_id` into host authority.

## Relay ordering and authority

The durable recovery root also stores each proved host connection, its full
signed proof and challenge. Its connection UUID and replica identify one
generation; neither is resumed after a disconnect. Proof admission, membership
append and route checks serialize on the same root lock (Postgres advisory
transaction lock in production). Rechecking the stored proof with the shared
verifier against the current log fences removal, rekeying and forks, including
proofs signed at an ancestor head.

Commit the binding before publishing presence or a verdict. Reacquire that
root lock and check the exact connection before publishing: a slower candidate
must not overwrite a newer candidate's presence. Directory presence is a
projection, not authority. Independent channel discovery uses the durable
binding, so directory expiry or a restart cannot authorize a stale socket.
The destination replica checks the binding again while admitting each frame
to its queue; the controller's reply broker does the same before admitting
host replies. Lost close/invalidation messages therefore cannot restore a
superseded connection. Already admitted ciphertext is never replayed.

An independent channel initially opened over carrier A also retains its root,
host and exact connection scope. Its destination queue and reply broker check
that scope under the same lock, plus fresh owner/host presence. A later proved
connection fences those older channels even if directory publication or a close
notification is delayed. Carrier A remains available for unpinned bootstrap and
manager reconciliation; these transport checks confer no device permissions.

Ownerless, absent and expired rooms accept only a bounded isolated challenge
candidate. Before proof, it has no presence, cannot replace an incumbent, and
cannot send room/channel/push traffic. An owner-present room retains carrier A
for bootstrap and manager reconciliation. Such an unproved join may replace
ordinary carrier-A presence, but cannot close or authorize the independent
binding. A proved socket survives directory sweeps; directory loss is repaired
from the current binding, under the root lock. Storage uncertainty closes the
route rather than granting authority from cached presence.

## Controlled validation

The relay suite passes 513 tests with 119 explicit environment ignores. A
separate isolated Postgres run executes all 47 remote API tests with no ignores
or failures. New checks include fresh-challenge replay refusal, isolated
candidates, owner-present bootstrap with no membership pin, expiry/sweep repair,
survival beyond the ten-second authentication deadline, full directory restart,
failed durable writes, removal/rekey and delayed effects at both replica queues
without close notifications. Carrier-A channels are also fenced when a proved
replacement commits. A P-256 native/Ed25519 host/AEAD registry exchange runs with
no Mac or directory presence; push disconnect/retry uses real route proofs.

These tests consume the shared production crate with software fixture keys;
they do not execute the Atem host or a live Claude/Codex session. No user keys,
pairings, trust floors or saved account configuration are changed. The runtime
matrix below and the provisioned owner ceremony remain release gates. Deploy
the relay replicas at the same revision, draining older replicas before
admitting independent routes; mixed revisions do not share these fences.

## Acceptance tests

Run the actual host connection path with no Mac connected: disconnect/reconnect
the only host; expire/sweep its room while it remains live; restart both relay
replicas with a fresh directory; recover from the durable host binding. Then
remove/replace the host while reconnect is pending and verify the old generation
cannot restore it. Check independent controller reconnect, receipts and sealed
push ACKs after each recovery. Do not count fixture-side room recreation as a
production reconnect pass.
