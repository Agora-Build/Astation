# Station Relay Security Status

The relay server is not yet production-ready as an authorization boundary.
TLS at the reverse proxy, CORS, validation, and rate limiting are necessary but
do not replace application authentication.

## Implemented controls

- HTTPS/WSS is supported through the deployment reverse proxy.
- Auth grant attempts and general API requests are rate limited by client IP.
- Pairing rooms expire after 10 minutes when no Astation is connected.
- Atem messages carry a stable, sanitized `atem_id` envelope.
- Astations prove a per-installation P-256 key before they may own a keyed
  identity room or bind sessions (see "Astation relay identity" below).
- Pairing/auth pages HTML-escape user-controlled values.
- Vault and Atem Memory (knowledge) authorization resolve a session only
  through a durable binding pushed by a verified Astation (Postgres
  `session_bindings`, sliding 7-day expiry).

## Device authentication v2

The relay transports the v2 challenge and HMAC proof but does not know the device
session token. Astation is the verifier and must not register a relay Atem or
process its application messages until verification succeeds.

```text
Atem -> relay -> Astation: hello
Atem <- relay <- Astation: auth_required {challenge, astation_id, protocol=2}
Atem -> relay -> Astation: auth {session_id, atem_id, proof}
Atem <- relay <- Astation: authenticated
```

The relay only transports this exchange. It no longer derives any
authorization from it: bindings come solely from a verified Astation's
`relayBind`/`relaySessions`. A session ID by itself is not device
authentication.

## Astation relay identity

Protocol: `../docs/knowledge-sync-plan.md`, "Extension: Astation
proof-of-possession + durable pairing"; summary in `README.md`.

- Every `role=astation` socket receives an in-band `relayAuthChallenge`. The
  Astation answers with `relayAuth`: its P-256 public key and a DER ECDSA
  signature over `station-relay-auth-v1\n<challenge>\n<astation_id>`, where
  `astation_id` must equal the socket's room code. The relay verifies it with
  `ring` (`ECDSA_P256_SHA256_ASN1`).
- **Trust on first use.** The first valid proof for a room code registers its
  key (`astation_keys`, atomic insert-if-absent). From then on only that key
  verifies.
- **Pending connections.** Once a key is registered, a new Astation socket for
  that code does not replace the room owner, receives no Atem traffic and no
  `relay_event` notifications, and its messages are dropped, until it proves
  the key. A wrong key, a signature over another challenge or code, or no
  answer within 10 s gets `relayAuthResult rejected` and the socket is closed;
  the current owner is untouched. If the key lookup itself fails (database
  down), the socket is treated as pending (fail closed).
- **Legacy mode.** An Astation without a registered key (old versions ignore
  the challenge) still owns its room and relays chat and remote control as
  before, but it can never create bindings, so vault and Atem Memory do not
  work for its Atems until it is updated.
- **Bindings.** Only a verified connection may send `relaySessions` (full
  resync, at most 1000 ids), `relayBind` and `relayUnbind`. A session already
  bound to another Astation is never taken over. Relay-auth frames are
  intercepted and never forwarded to Atems.
- **Admin reset.** A lost or replaced Mac cannot prove the old key; an operator
  deletes its `astation_keys` row (see `../DEPLOY.md`), and the next verified
  connect registers the new key. Bindings are kept.
- Relay logs mask room codes and session ids (first 4 characters).

Residual risks:

- **Session squatting.** A binding is first-come: a verified Astation that
  learns another Astation's session id before that Astation binds it can bind
  it first (the rightful `relayBind` is then refused and logged). Session ids
  are UUIDv4 values that only travel between an Atem, its Astation and the
  relay, so this requires prior knowledge of the id.
- **First-use squatting.** Whoever proves a key first for a room code owns it.
  Room codes are random per installation, so this needs prior knowledge of the
  code; recovery is the admin reset.
- **Legacy rooms.** A room with no registered key can still be taken over as
  before (without gaining vault or memory access) until its Astation updates.

## Production blockers

1. ~~`role=astation` identity-room ownership is not authenticated.~~
   **Addressed** by the Astation relay identity above (TOFU key, pending
   connections, legacy mode without bindings, admin reset). Residual: the
   session-squatting and first-use risks listed there.
2. Voice, LLM, and RTC session endpoints are not consistently protected by an
   authenticated device session.
3. Vault authorization still accepts a session identifier at the HTTP boundary;
   it must be tied to the v2 device proof or a derived short-lived API token.
4. Per-Atem disconnect and replacement cleanup must be connection-generation
   aware so an old socket cannot remove its replacement.
5. WebSocket connection admission and message size/rate limits need explicit
   production bounds.

Do not describe a deployment as production-ready until these items have tests
and the deployed configuration requires them.

## Deployment baseline

- Expose the service only through an HTTPS/WSS reverse proxy or tunnel.
- Do not publish the container port directly to the internet.
- Set a single explicit `CORS_ORIGIN`; never use `*` in production.
- Set `DATABASE_URL` for durable Vault, Atem Memory, and relay-identity
  (Astation keys + session bindings) storage.
- Keep secrets in the deployment secret store and out of URLs and logs.
- Use `RUST_LOG=info` or stricter in production.

See `../docs/specs/2026-07-21-device-authentication-v2.md` for the coordinated
Astation/Atem protocol, rollout order, and current LAN limitation.
