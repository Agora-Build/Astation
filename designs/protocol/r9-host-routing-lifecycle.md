# Independent host routing lifecycle

End-to-end validation on 2026-10-22 found a remaining transport lifecycle gate
in the identity-room route. It is separate from encrypted controller admission
and durable signed push ingestion. Account Auth #63 alone does not fix it.

## Observed behavior

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

## Acceptance tests

Run the actual host connection path with no Mac connected: disconnect/reconnect
the only host; expire/sweep its room while it remains live; restart both relay
replicas with a fresh directory; recover from the durable host binding. Then
remove/replace the host while reconnect is pending and verify the old generation
cannot restore it. Check independent controller reconnect, receipts and sealed
push ACKs after each recovery. Do not count fixture-side room recreation as a
production reconnect pass.
