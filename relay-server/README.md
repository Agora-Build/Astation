# Station Relay Server

Secure relay and session management server for Astation ecosystem.

**Services:** Auth Sessions, WebSocket Relay (Atem ↔ Astation), RTC Sessions (web screen sharing)
**Security:** Rate limiting, input validation, CORS, XSS protection
**Status:** ✅ Production Ready | Test suite passing

`GET /health` returns `200` when the relay and its configured Vault store are ready,
and identifies the active store as `memory` or `postgres`. It also reports
`redis` (`disabled`, `ok`, `unavailable`) and `replicas` (live relay replicas),
and returns `503` while Redis is unreachable (`{"status":"unhealthy","redis":"unavailable"}`)
or the relay is draining (`{"status":"draining"}`).

The relay runs as one instance with everything in memory, or, with
`REDIS_URL`, as several replicas sharing rooms, sessions and rate limits
through Redis/Valkey (design: [`docs/specs/2026-09-30-relay-multi-replica.md`](../docs/specs/2026-09-30-relay-multi-replica.md)).
On SIGTERM a relay drains: `/health` and new `/ws` upgrades get `503`, every
WebSocket is closed with `1012` (reconnect), its room entries are withdrawn,
and in-flight HTTP gets at most 5 s more. A second SIGTERM exits at once (143;
SIGINT 130).

---

## Quick Start

### Development
```bash
# Local
export CORS_ORIGIN=* RUST_LOG=debug
cargo run

# Docker
docker compose -f docker-compose.dev.yml up
```

### Production
```bash
# 1. Configure
cp .env.example .env
# Edit: CORS_ORIGIN=https://station.agora.build
#       PUBLIC_BASE_URL=https://station.agora.build

# 2. Deploy
docker compose up -d
```

### Production (Coolify on Volumetric)

Every push to `main` builds the relay and webapp `:main` images, deploys both
through Coolify, and verifies public HTTPS and the identity WebSocket. See the
[production deployment guide](../DEPLOY.md#station-on-volumetric-coolify) for
application IDs, GitHub secrets, runtime configuration, and Cloudflare routing.

**URLs:**
- Production: `https://station.agora.build`
- Legacy staging alias: `https://station-staging.agora.build` (same deployment)
- Dev: `http://localhost:3000`

---

## API Reference

### Auth Sessions
Deep link authentication for Astation app.

- `POST /api/sessions {hostname}` → `{id, otp}` - Create auth session (5min expiry)
- `GET /api/sessions/:id/status` → `{status, token?}` - Poll for grant/deny
- `POST /api/sessions/:id/grant {otp}` → `{token}` - User grants access (60 req/min limit)

### WebSocket Relay (Pairing and Reconnect)
Atem <-> Astation message relay via pairing codes and persistent identity rooms.

- `POST /api/pair {hostname}` → `{code}` - Create pairing room (10min expiry)
- `DELETE /api/pair/:code` → `{closed: true}` - Close a room; `409 {"error":"room is owned by a registered Astation"}` when the code has a registered Astation key
- `WS /ws?role={atem|astation}&code={CODE}` - Connect and relay messages

For identity-room reconnects, the relay is the transport, not the device
authenticator. Astation sends a v2 challenge, verifies the Atem HMAC proof, and
only then returns `authenticated`. The relay does not derive bindings from that
traffic. See [`SECURITY.md`](SECURITY.md) for the security status.

### Astation relay identity + session bindings
Exact spec: [`docs/knowledge-sync-plan.md`](../docs/knowledge-sync-plan.md),
"Extension: Astation proof-of-possession + durable pairing". All frames are
raw JSON text on the `role=astation` socket; the relay handles them itself and
never forwards them to Atems.

1. Relay → Astation, first frame on every `role=astation` socket (old
   Astations ignore it):
   `{"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"<64 lowercase hex>"}`
2. Astation → relay, within 10 s:
   `{"type":"relayAuth","astation_id":"<room code>","public_key":"<hex>","signature":"<hex>"}`
   - `public_key`: P-256 X9.63 uncompressed, 65 bytes (130 hex chars, `04…`);
     either case, compared lowercase.
   - `signature`: DER ECDSA (SHA-256) over the UTF-8 string
     `station-relay-auth-v1\n<challenge>\n<astation_id>`.
3. Relay → Astation:
   `{"type":"relayAuthResult","status":"registered|verified|rejected","message":"<text>"}`
   - `registered`: no key existed for this code; this key is now it (TOFU).
   - `verified`: the proof matches the registered key.
   - `rejected`: wrong key, bad signature/encoding, `astation_id` ≠ the room
     code, late answer, no answer in 10 s (pending sockets), or the database
     is unavailable while registering a new key. The socket is then closed.
4. Only after `registered`/`verified`, Astation → relay:
   `{"type":"relaySessions","sessions":["<session_id>", …]}` (full resync;
   bindings become exactly this set; at most 1000 ids),
   `{"type":"relayBind","session_id":"<id>"}`,
   `{"type":"relayUnbind","session_id":"<id>"}`.
   Relay → Astation acks (clients only need `ok`):
   - `{"type":"relayAck","for":"relayBind","ok":true}` (same for `relayUnbind`,
     which is idempotent)
   - `{"type":"relayAck","for":"relaySessions","ok":true,"skipped":<n>}` —
     `skipped` counts listed sessions bound to another Astation (left alone)
   - `{"type":"relayAck","for":"<type>","ok":false,"message":"<text>"}` — not
     verified, more than 1000 ids, an invalid `session_id` (empty, over 128
     chars, or anything but visible ASCII), `relayBind` of a session bound to another
     Astation, or an identity-store error. Nothing is changed.

Connection states: with no key registered for the code the socket owns the
room at once (**legacy mode**: relays as before, cannot bind). With a key
registered it is **pending** — no room ownership, no Atem traffic or
`relay_event` notifications — until it verifies, then it replaces the room
owner. Registered keys are cached in memory (loaded at startup, written
through on registration): connects do no database I/O and a cached key
verifies even while the database is down; a different key forces a re-read
(admin reset) before rejection. Bindings live in Postgres (`astation_keys`, `session_bindings`) and are
the only thing `resolve_caller` (vault + Atem Memory) accepts; they expire
after 7 days without use.

### RTC Sessions
Web screen sharing with up to 8 participants.

- `POST /api/rtc-sessions {app_id, channel, token, host_uid}` → `{id, url}` - Create session (4hr expiry)
- `GET /api/rtc-sessions/:id` → `{app_id, channel, host_uid}` - Get session info
- `POST /api/rtc-sessions/:id/join {name}` → `{app_id, channel, token, uid}` - Join session (assigns unique UID)

### Vault
See the [Vault storage design](../docs/vault-storage.md) for versioning,
transaction boundaries, and the exact current access predicates.

Durable, append-only, versioned shared context store for collaborating atems.
Backed by Postgres (`DATABASE_URL`). All requests require
`Authorization: session <session_id>` and `?id=<client_id>`. The session must
be bound by a verified Astation (see above): `401` otherwise, `503` if the
identity store is unavailable.

- `POST /api/vault {summary}` → `{vault_id}` - Create a vault
- `GET /api/vault` → `[{vault_id, summary}]` - List readable vaults
- `GET /api/vault/:id [?since=<seq>&history=true]` → `[VaultEntry]` - Read (current view or history)
- `POST /api/vault/:id {text, entry_id?}` → `{entry_no, version, seq}` - Append (no `entry_id`) or override (with `entry_id`)
- `POST /api/vault/:id/summary {text}` → `{}` - Update summary

Authz: in-session callers (same `work_session_id` = bound astation_id) can read and
write content. Past content writers from another work session can read and update
the summary, but cannot write content. Others are denied (403).

### Knowledge sync (Atem Memory)
Durable sync store for Atem's shared memories and skills across an astation's
paired atem instances. Backed by Postgres (`DATABASE_URL`, same pool as
Vault). All requests require `Authorization: session <session_id>` and
`?id=<client_id>`; account = the caller's `work_session_id` (the paired
astation_id) — atems paired to different astations never see each other's
memories or skills.

- `POST /api/memory/batch {ops: [...]}` → `{"results": [OpResult]}` - Batch add/delete memory ops (body limit 2 MB, at most 64 ops)
- `GET /api/memory [?since=<seq>&limit=<n>]` → `{"memories": [MemoryRow]}` - Pull memories (default `since=0`, `limit=200`, capped at 500). There is no `next_since`: the next cursor is the highest `seq` in the page.
- `POST /api/skills/batch {ops: [...]}` → `{"results": [OpResult]}` - Batch push/delete/purge skill ops (body limit 16 MB, at most 16 ops)
- `GET /api/skills [?since=<seq>&limit=<n>]` → `{"skills": [SkillRow]}` - Pull skills (default `since=0`, `limit=200`, capped at 500; no `next_since`)

Batch requests are authenticated before the body is read (so an
unauthenticated client can't make the relay buffer a large body), then:

| Condition | Response |
|-----------|----------|
| Missing/invalid/unbound session | 401 (body never read) |
| Missing `?id=` | 400 |
| Body over the byte limit | 413 |
| Over the op cap | 413 `{"error":"too many ops"}` |
| Malformed body or an unknown `op` | 400 for the whole batch (the atem client never sends unknown ops) |
| Backing-store (database) error | 503 `{"error":"temporarily unavailable"}` for the whole batch; processing stops, detail logged via `tracing::error!` |
| Per-op input problem | 200, that op's result is `{ok:false,error:"..."}`; the rest still apply |

A 503 is transient: atem keeps every op queued and retries, which is safe
(add is idempotent by id, delete/purge are idempotent, a retried skill push
appends a harmless duplicate version). Per-op refusals are permanent (atem
acks them), so they are only ever input problems:

- a credential-shaped value (`knowledge_secrets::find_secrets`/`check_bytes`)
  → `possible credential: ...`; the reserved `atem:memory:` token →
  `reserved token` (memories) / `possible credential: <path>: reserved token`
  (skill files);
- an invalid scope, or a NUL (`\u0000`, which Postgres can't store) in any
  memory string field → `invalid memory`; in a skill's name/project/source/
  hash or a file relpath → `invalid skill`;
- skill file bytes that aren't canonical standard base64 → `invalid base64`;
- a memory id owned by another account → `id conflict`.

Skill files are sent base64-encoded in the request body and decoded
server-side (no `base64` crate — a small hand-rolled RFC 4648 decoder in
`knowledge_routes.rs`). Dedup, tombstones, and purge semantics are
implemented by `KnowledgeStore` (`knowledge_store.rs`).

Production nginx (`webapp/nginx.conf`) raises its 1 MB body cap to 16 MB for
`/api/skills/batch` and 2 MB for `/api/memory/batch` only.

## Astation Integration

The Astation macOS app uses this relay server for:
1. **Auth Sessions** - `AstationHubManager.swift` handles deep link auth flow
2. **Pairing** - `AtemPairingManager.swift` connects WebSocket for Atem pairing
3. **RTC Sessions** - `SessionLinkManager.swift` creates shareable screen sharing links

Config: Set `relay_url` and `ws_url` in `.atem/config.toml`

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CORS_ORIGIN` | `https://station.agora.build` | Allowed origin for CORS (set to `*` for dev) |
| `PUBLIC_BASE_URL` | _(unset)_ | Public base URL used for generated session links (recommended in production) |
| `PORT` | `3000` | Server port |
| `RUST_LOG` | `info` | Log level (error, warn, info, debug, trace) |
| `REDIS_URL` | _(unset)_ | Redis/Valkey for shared relay state: rooms, pairing/OTP, voice and RTC sessions, shared rate-limit counters, replica-to-replica delivery. Required to run more than one replica. Unset: in-memory, one replica only. At startup an unreachable Redis is retried for about 30 s, then the relay exits 1; a malformed URL or wrong password exits 1 at once. The URL (and its password) is never logged. |
| `RELAY_REPLICAS_EXPECTED` | `1` | How many relay replicas the deployment runs. Above 1 without `REDIS_URL`, the relay refuses to start (exit 1); a value that isn't a positive integer also exits 1. |
| `DATABASE_URL` | _(unset)_ | Postgres connection string shared by **vault**, **knowledge sync (Atem Memory)**, and **relay identity** (Astation keys + session bindings) storage (e.g. `postgres://vault:vault@localhost:5432/vault`), one pool for all. When unset, all fall back to **in-memory** (non-durable: bindings and registered keys are lost on restart) and log a warning. Migrations in `migrations/` run automatically at startup. |

**Production:**
```bash
CORS_ORIGIN=https://station.agora.build
PUBLIC_BASE_URL=https://station.agora.build
PORT=3000
RUST_LOG=info
```

**Development:**
```bash
CORS_ORIGIN=*  # Allows all origins (logs warning)
PORT=3000
RUST_LOG=debug
```

---

## Testing

```bash
cargo test  # unit + in-memory integration suites
# Postgres suites are #[ignore]d; run each against a throwaway local database:
#   docker run --rm -d --name relay-test-pg -e POSTGRES_PASSWORD=pw -p 55433:5432 postgres:16
#   IDENTITY_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test identity_store -- --ignored
#   IDENTITY_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test relay:: -- --ignored
#   KNOWLEDGE_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test knowledge_store -- --ignored
#   docker rm -f relay-test-pg
# Redis suites (every Redis unit + two relays in one process) are #[ignore]d
# too; CI runs them against a Valkey service. TEST_REDIS_URL must point at
# localhost (the harness runs FLUSHDB):
#   docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
#   TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
#   docker rm -f relay-test-valkey
```


---

## Security

**See `SECURITY.md` for comprehensive security analysis.**

**Key Points:**
- ✅ Rate limiting (60/min for OTP, 600/min general)
- ✅ Input validation (max lengths enforced)
- ✅ CORS policy (configurable whitelist)
- ✅ XSS protection (HTML escaping)
- ✅ Session expiry (auto-cleanup)
- ✅ Production ready with Cloudflare Tunnel

**Production Readiness: 8.5/10**

---

## Deployment

**Production:**
```bash
docker compose up -d
# Use reverse proxy (Nginx/Caddy/Cloudflare) for HTTPS
```

**Scaling:** set `REDIS_URL` on every replica, then run as many replicas as
needed behind the webapp (see `../DEPLOY.md`, "Relay replicas"). Without
`REDIS_URL`, run exactly one.

**Admin:** `station-relay-server admin forget-key <astation_id>` deletes an
Astation's relay key and, with `REDIS_URL`, makes every replica drop it and
disconnect that Astation's verified socket at once (runbook: `../DEPLOY.md`,
"Admin reset"). Exit codes: 0 done, 1 database/Redis error, 2 bad arguments.

**Monitoring:** Check `docker compose logs -f`

---

## Troubleshooting

- **CORS errors**: Set `CORS_ORIGIN` env var to match your domain
- **429 Rate limit**: Normal - client exceeded 60/600 req/min limit
- **404 Session not found**: Session expired, or the relay restarted in in-memory mode (or Valkey restarted)
- **503 "Relay state unavailable"**: the relay can't reach Redis (`REDIS_URL`); `/health` shows `"redis":"unavailable"`

---

## Support

- Issues: [GitHub Issues](https://github.com/Agora-Build/Astation/issues)
- Security: security@agora.build
- Docs: See SECURITY.md for deployment details
