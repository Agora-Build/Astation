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
  the current owner is untouched.
- **Key cache.** The relay keeps every registered key in memory: loaded from
  Postgres at startup, written through on registration. Connecting does no
  database I/O (Pending vs legacy is decided from the cache), and a proof with
  the cached key verifies without the database (`last_verified_at` is updated
  in the background), so a connect flood or a database outage cannot lock
  registered Astations out of relay chat. Registering a new key needs the
  database; if it is down only that registration is rejected. A presented key
  that differs from the cached one makes the relay re-read the stored key
  before rejecting; if the database is unreachable it is rejected and the
  cached key stays. With several replicas (`REDIS_URL`), a registration, a
  re-read that finds a new key, or `admin forget-key` is announced on Valkey
  (`key-changed` on `relay:broadcast`) and every replica re-reads that key;
  if a re-read fails the key is marked stale and must be re-read before it
  verifies again (fail closed). Pub/sub is best effort, so a replica whose
  subscription reconnects re-reads every key.
- **Room closing.** The unauthenticated `DELETE /api/pair/:code` is refused
  (`409 {"error":"room is owned by a registered Astation"}`) for a code with a
  registered key, so knowing a room code no longer lets anyone evict a verified
  owner. Keyless pairing rooms can still be closed as before.
- **Legacy mode.** An Astation without a registered key (old versions ignore
  the challenge) still owns its room and relays chat and remote control as
  before, but it can never create bindings, so vault and Atem Memory do not
  work for its Atems until it is updated.
- **Bindings.** Only a verified connection may send `relaySessions` (full
  resync, at most 1000 ids), `relayBind` and `relayUnbind`. A session already
  bound to another Astation is never taken over. Relay-auth frames are
  intercepted and never forwarded to Atems.
- **Admin reset.** A lost, stolen or replaced Mac cannot prove the old key;
  an operator runs `station-relay-server admin forget-key <astation_id>` in a
  relay container (runbook: `../DEPLOY.md`, "Admin reset"). It deletes the
  `astation_keys` row, then announces `key-changed`: every relay replica drops
  the cached key and disconnects that Astation's live verified socket at once,
  so a compromised key is revoked immediately. Bindings are kept. The
  replacement Mac's Astation then connects with its new key, which registers
  by trust on first use; bring it online promptly, because until then the
  room is open to first-use squatting (below). With `REDIS_URL` set but
  Valkey unreachable, the command exits 1 without deleting anything. Without
  `REDIS_URL`, or if the
  announcement fails (the command says so and exits 1), or when the row is
  deleted by hand in SQL, the cached **old** key keeps verifying until every
  relay replica is restarted.
- Relay logs mask room codes and session ids (first 4 characters).

Residual risks:

- **Session squatting.** A binding is first-come: a verified Astation that
  learns another Astation's session id before that Astation binds it can bind
  it first (the rightful `relayBind` is then refused and logged). Session ids
  are UUIDv4 values that only travel between an Atem, its Astation and the
  relay, so this requires prior knowledge of the id.
- **First-use squatting.** Whoever proves a key first for a room code owns it,
  and the code is not secret: every Atem paired with that Astation stores it
  (`astation_relay_code` in its `config.toml`) and sends it in its WebSocket
  URL, and it appears in the pairing link. Anyone holding it can register their
  own key before the real Astation does. That squat locks the real Astation out
  of its relay room entirely (relay chat and remote control as well as vault
  and memory), because its connections stay pending and are rejected. Recovery
  is the admin reset. The rollout order in `../DEPLOY.md` (Astation update
  first, then the relay) keeps this window to the seconds between the relay
  restart and the updated Astations reconnecting.
- **Legacy rooms.** A room with no registered key can still be taken over as
  before (without gaining vault or memory access), and closed with
  `DELETE /api/pair/:code`, until its Astation updates and registers a key.

## Production blockers

1. ~~`role=astation` identity-room ownership is not authenticated.~~
   **Addressed** by the Astation relay identity above (TOFU key, pending
   connections, legacy mode without bindings, key cache, `DELETE` refused for
   keyed rooms, admin reset). Residual: the session-squatting, first-use
   squatting, and legacy-room risks listed there.
2. Voice, LLM, and RTC session endpoints are not consistently protected by an
   authenticated device session.
3. Vault authorization still accepts a session identifier at the HTTP boundary;
   it must be tied to the v2 device proof or a derived short-lived API token.
4. Per-Atem disconnect and replacement cleanup must be connection-generation
   aware so an old socket cannot remove its replacement.
5. WebSocket connection admission and message size/rate limits need explicit
   production bounds.
   Partly addressed: bounded per-connection send queues (1,000 frames / 4 MB;
   a client stalled for 10 s is closed with 1013).

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
- With several relay replicas, set `REDIS_URL` as a secret and keep Valkey on
  the private network with a password and no public port. It holds pairing
  session ids (a pending one can authorize a WebSocket): restrict access like
  the database. It holds only live state, so it needs no persistence or
  backups.

See `../docs/specs/2026-07-21-device-authentication-v2.md` for the coordinated
Astation/Atem protocol, rollout order, and current LAN limitation.
