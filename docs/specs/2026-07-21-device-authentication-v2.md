# Device Authentication v2

Status: implemented for direct and identity-relay WebSocket clients. Direct LAN
transport encryption and relay-owner authentication remain required before a
production rollout.

The matching Atem implementation is in `src/websocket_client.rs` in the Atem
repository. Astation and Atem must be released together.

## Connection matrix

| Path | Endpoint | Interactive pairing | Internet required |
|------|----------|---------------------|-------------------|
| Same Mac | `ws://127.0.0.1:8080/ws` | No | No |
| LAN | `ws://<astation-ip>:8080/ws` | First connection only | No |
| Remote | Identity room on the public WSS relay | First connection only | Yes |

All three paths can be active at the same time. A connection is local only when
the kernel reports a loopback peer address. A LAN address, VPN address, forwarded
header, hostname, or claimed role never receives the loopback policy.

The same-Mac policy relies on the bootstrap file and its parent directory being
owner-only (`0600`/`0700`); it proves access as the Astation OS account rather
than inspecting the connecting process UID.

## Protocol

Astation starts every direct connection with:

```json
{
  "type": "statusUpdate",
  "data": {
    "status": "auth_required",
    "data": {
      "astation_id": "astation-...",
      "challenge": "64 lowercase hex characters",
      "transport": "loopback|lan|relay",
      "protocol": "2"
    }
  }
}
```

The proof is lowercase hex HMAC-SHA256 over this exact UTF-8 string:

```text
astation-auth-v2\n<challenge>\n<astation_id>\n<atem_id>\n<session_id>
```

For loopback, `session_id` in the proof input is the literal `local`, and the
HMAC key is the same-user bootstrap token. For LAN and relay reconnects, the key
is the device session token and `session_id` is the saved session UUID.

Astation compares proofs in constant time, binds legacy sessions to the first
`atem_id` that proves possession, and rejects reuse with a different device ID.
The relay path does not register `hello` as an authenticated client; `hello`
only causes Astation to issue a targeted challenge.
Application broadcasts are delivered to authenticated direct and identity-relay
clients, while pending clients are excluded.
Direct connection state is confined to the NIO event loop; relay authentication
state and pairing UI are confined to the main queue.

## Local state

Astation stores files under `~/Library/Application Support/Astation/`:

| File | Mode | Purpose |
|------|------|---------|
| `local-bootstrap-token` | `0600` | Same-user loopback bootstrap key |
| `sessions.json` | `0600` | Device IDs, session tokens, and activity times |
| `identity.txt` | `0600` | Stable Astation routing identity |

The directory and `~/Library/Logs/Astation/` use mode `0700`. Astation log files
use `0600`. Network logging recursively redacts tokens, session IDs, proofs,
pairing codes, and common credential fields.

Atem stores paired device sessions in `~/.config/atem/sessions.json` with mode
`0600` under a `0700` directory. The bootstrap token is read only on macOS and
is rejected if group or other permission bits are present.

## Operations

Same-Mac Atem requires no configuration. It connects to the default endpoint:

```text
ws://127.0.0.1:8080/ws
```

For an offline LAN Atem, configure the Mac's reachable address:

```toml
astation_ws = "ws://192.168.1.20:8080/ws"
```

The first connection shows matching device/code information in Atem and an
approval dialog in Astation. Later connections use the saved session proof.
No DNS lookup, relay request, or internet service is required on this path.

## Rollout and migration

1. Merge both repository PRs before releasing either binary.
2. Release Astation and Atem as a coordinated version pair.
3. Existing session records remain readable, but old clients that send only a
   session ID cannot authenticate against v2.
4. On `pairing required`, the updated Atem retries interactive pairing on the
   same socket and saves the new token.
5. Validate loopback with Wi-Fi disabled, then validate LAN using an explicit IP.
6. Keep the current production binaries until LAN WSS and relay-owner auth land.

## Automated coverage

`DirectConnectionTests` starts the real NIO WebSocket server on ephemeral ports
and covers:

- loopback authentication with no network service;
- invalid same-user proof rejection;
- LAN session credentials rejected on the loopback scope;
- application broadcasts excluded from unauthenticated sockets;
- five concurrently authenticated loopback clients;
- a pre-paired connection through a real non-loopback interface, with no relay;
- cross-language HMAC test vectors and private file modes.

Run:

```bash
swift test --filter DirectConnectionTests
swift test
cd relay-server && cargo test
```

The Atem repository adds the matching HMAC vector and bootstrap permission tests.

## Remaining production blockers

- Replace plaintext direct LAN WebSocket with WSS and persistent certificate
  pinning or an equivalent authenticated encrypted channel.
- Authenticate the Astation owner connection before the relay creates or takes
  over an identity room.
- Require the authenticated device session on Voice, LLM, Vault, and RTC owner
  APIs rather than accepting a bare session identifier.
- Add device naming, session rotation, revocation, and connection history UI.
