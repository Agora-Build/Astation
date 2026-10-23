# Independent agent API readiness

The remote API is being built for native/mobile Astation and scoped bots that
connect to the original Atem host without a running Mac. It uses the shared
`atem-client` and the jointly reviewed r9 contract. The relay transports
encrypted messages; it does not answer agent operations itself.

## Implemented on this branch

`GET /api/remote/v1/capabilities` is a public, non-sensitive discovery endpoint.
It returns HTTP 200 with `Cache-Control: no-store` and:

```json
{
  "api": "atem-remote",
  "version": 1,
  "status": "not_ready",
  "admission_enabled": false,
  "recovery_storage_durable": false,
  "recovery_head_probe": false,
  "required_session_revision": 9,
  "supported_session_revisions": [9],
  "transports": ["websocket"],
  "transport_implemented": true,
  "admission_authority": "host_signed_membership",
  "push_ready": false
}
```

This reports implementation readiness, independently of `/health` and the
Mac's existing local API. With durable Postgres recovery storage, status becomes
`r9_transport_ready`, and admission/storage/probe flags become true. This says
the transport is installed; account authentication and a host-verified enrolled
device are still required. Clients check the flags and supported transport.
The response carries no
account, device, session, presence, token or provider-configuration data. It is
discovery only, never proof of identity or permission.

Other unimplemented paths under `/api/remote/v1` return HTTP 503 with error
code `remote_api_unavailable`, `admission_enabled: false` and `no-store`.
An account token, local Mac bearer token or body claiming verification does
not enable these routes. Unsupported methods on an implemented route return
the router's HTTP 405. No r8 or plaintext fallback is provided here. Existing
pairing and account-data synchronization retain their separate routes.
Native agent control and the local API use only encrypted r9; there is no
plaintext session hello, terminal or chat fallback.

With a local relay running on its default port:

```sh
curl -i http://127.0.0.1:3000/api/remote/v1/capabilities
```

This endpoint is not deployed until this branch is merged and deployed.

## Independent Encrypted WebSocket

For the proposed Discord/custom-app setup and simple Bearer-token gateway, see
the [unified Integrations design](../designs/unified-integrations.md). That gateway
is an optional decrypting endpoint on user-chosen infrastructure; it is not
implemented by the opaque relay routes described here. Agora.Build manages
account/setup, while the chosen Station stores ciphertext and routes encrypted
traffic. A raw-token agent API issues/validates its own credentials and needs
separate native-authorized service membership. A shared relay must not gain
plaintext access merely by hosting the transport; its operator is an additional
trusted reader if the user also hosts the decrypting gateway on that machine.

`GET /api/remote/v1/channels?genesis={genesis_hash}&host={host_id}` upgrades to
WebSocket. Use WSS and an `Authorization: Bearer` account token. Never put the
token in the URL. The account login authorizes routing privacy only; Atem
authenticates the endpoint using the signed membership log and `atem-ch1`.
The client must already hold its independent genesis/host anchors and its
enrolled native or scoped service key. Login alone cannot operate an agent.

There is one encrypted channel per controller WebSocket. Send the shared
`channel/open` envelope within ten seconds, then forward the shared client's
original `channel/frame` bytes. The relay substitutes an isolated, random
handle bound to the current host socket; it never modifies the inner frame.
Replies restore the client's handle. Session list/change events, whole chat
messages/history, approvals and durable receipts all travel inside this stream.
These are host operations, not plaintext HTTP endpoints on the relay.

The portable `AstationRemote.RemoteRelayClient` owns the WebSocket, ordered
writer and shared r9 client. Its host is fixed at construction:

```swift
let client = try RemoteRelayClient(relayURL: relayURL, genesis: genesisHash,
    hostID: hostID, accessToken: accountToken, observe: handleEvent)
try client.connect(identity: enrolledIdentity, log: anchoredLog, sign: signChannel)
// After the verified ready event:
try client.perform(.list)
```

Keep the client alive while subscribed. After disconnect, construct a new one
and complete a fresh handshake; query uncertain receipts rather than resending
commands. Native signing uses platform keys and owner authentication. A service
uses its own enrolled scoped key through the same shared client; it never uses
the Mac's local API token. Browser grants and a shipped mobile app remain
separate integration work.

Limits and failure behavior:

- Envelopes are at most 2 MiB; each controller outbox allows 64 frames/4 MiB,
  including a frame currently being written.
- At most 16 channels per account and 1,024 per replica; one hour per relay
  socket, followed by a fresh connection. Host authorization may expire earlier.
- Every client frame checks the bound host generation; five-second checks
  also detect an idle replaced/disconnected host.
- Replica delivery is acknowledged in both directions, with a two-second
  bound. Backpressure, bus reset or uncertain delivery closes the channel;
  ciphertext is never retried or silently dropped on a surviving channel.
- Disconnect and close affect only that controller. A host close is not echoed.
  The original Mac can remain offline for the entire connection.

The account verifier, durable recovery storage and outbound Atem link must be
available. `auth.agora.build` remains a deferred production dependency; the
implementation adds no authentication bypass. No production deployment is
claimed by the local test results.

## Recovery Storage and Fresh Head Probes

With Postgres configured, authenticated account storage is implemented:

| Method | Path under `/api/remote/v1` | Result |
| --- | --- | --- |
| GET | `/logs/{genesis_hash}/entries?after={seq}` | Bounded signed log page |
| POST | `/logs/{genesis_hash}/entries` | Signed CAS append or bounded 409 conflict |
| PUT | `/logs/{genesis_hash}/backups/{blob_version}` | Exact sealed envelope, put-if-absent |
| GET | `/logs/{genesis_hash}/backups/{blob_version}` | Only a committed-named envelope |
| POST | `/logs/{genesis_hash}/probes/{host_id}` | One fresh public host accept; 10-second bound |

These routes require the existing verified account access token; login controls
storage visibility, never membership. Initial genesis also requires the creator's
existing registration to that subject/data account. Clients independently pin
and verify the genesis, signed chain, backup and host challenge. Imported kit
URLs never receive the user's token. The probe can reach the host with the Mac
offline but cannot forward a controller handshake finish, encrypted records or
commands. Details are in [Recovery Kit v2](../designs/recovery-kit-v2.md).

The two recovery capability flags report durable backend availability and are
true only when Postgres is configured. The channel endpoint separately verifies
account visibility and resolves the signed host record for routing.
Without a durable backend, recovery storage returns 503; memory storage exists
only in tests. No new relay deployment is claimed.

## Notification policy foundation

`relay-server/src/approval_escalation.rs` evaluates a delivery stage using
explicit time and lifecycle inputs, without an app or external provider:

- Initial desktop OS notice when no desktop is connected; presence only
  affects routing and never supplies authorization.
- Mobile at original creation plus 60 seconds, or immediately if opted in;
  an authenticated active-user seen suppresses mobile without resolving it.
- Optional desktop reminder at 60 seconds; delivered stages are separate
  so an initial desktop notice does not consume a mobile notice.
- Known resolution, revoked authority or an already delivered stage prevents
  another provider attempt. Changing mobile preferences cannot resend it.
- The delivery cutoff is original expiry minus a supplied margin. It stops
  provider delivery without expiring an actionable approval card.

The policy takes original signed times, not a new relay receipt time; late
admission, restart and retry cannot postpone the 60-second deadline. The
margin remains an input; the signed-off r9 contract at `c685aba` specifies
15 seconds and agrees on the original-creation deadlines. Authenticated
lifecycle/shared-core integration still precedes ingress/provider wiring.

This module is not an authenticated ingress, durable outbox, job claimant,
retry scheduler or provider dispatcher. Its inputs must come from validated,
durable lifecycle records; a future worker must recheck current membership,
recipient key/token generation, resolution, seen and expiry before each
attempt. Per-recipient/stage receipts and claims need shared durable storage
across relay replicas. External provider delivery remains best effort; a
race after submission can produce a late notification, whose tap fetches the
current authoritative approval.

## Verification without phone apps

```sh
cd relay-server
cargo test remote_api
cargo test approval_escalation
```

These tests cover discovery, account privacy, independent concurrent channels,
exact frame bytes, generation scoping, backpressure, replay and the deterministic
notification policy. A real WebSocket test performs a P-256 native proof,
signed host accept, encrypted welcome and registry exchange without a Mac.
It consumes the shared responder/client library; it is not a test of a live
Claude/Codex process or production owner authentication. Durable provider
delivery and mobile OS conformance remain separate gates.

The r9 contract is signed off for implementation at
`c685abab92535b167f5f2658c814f0f72541d9a1`; see the
[review and remaining gates](../designs/protocol/remote-agent-api-atem-r5-review.md).
The remaining native/service operations, scoped Discord integration, signed
membership state and sealed push use the Atem-owned shared core. Signed
membership/K-backup storage, durable native recovery snapshots and independent
session routing are implemented. Push ingress/providers remain gated. Full testing uses real independent
controller/service keys and fake providers with the Mac off, as specified in the
[implementation plan](../designs/protocol/remote-agent-api.md). Real APNs/FCM,
notification extensions and platform owner authentication are separate checks.
