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
`GET /metrics` serves per-replica Prometheus text (sockets by role, rooms,
bus publish/receive, Redis latency histogram and errors, slow-client closes,
rate-limit refusals). It is outside rate limiting, **unauthenticated**, and
**not** proxied by the webapp nginx (which answers 404): it relies on network
isolation, so scrape each relay container directly on the internal network.
The standalone `docker-compose.yml` publishes port 3000 on the host, which
exposes `/metrics` too: firewall that port or bind it to localhost
(`"127.0.0.1:3000:3000"`). `relay_rate_limited_total{kind="http"}` counts
refusals by the shared limiter only; the per-replica governor's `429`s
are not counted.

On SIGTERM a relay drains: `/health` and new `/ws` upgrades get `503`, every
WebSocket is closed with `1012` (reconnect), its room entries are withdrawn,
and in-flight HTTP gets at most 5 s more. A second SIGTERM exits at once (143;
SIGINT 130).

Each WebSocket's send queue holds at most 1,000 frames or 4 MB
(`MAX_QUEUED_FRAMES`, `MAX_QUEUED_BYTES` in `src/cluster/local.rs`); a frame
that doesn't fit is dropped, and a client whose queue stays full for 10 s is
closed with `1013`.

With Redis, a frame for a socket on another replica travels over Valkey
pub/sub. A message over 8 MiB serialized (`BUS_MAX_FRAME_BYTES` in
`src/cluster/bus.rs`) is not published: it is dropped with a warning and
counted in `relay_bus_oversize_dropped_total`, since Valkey would disconnect
the receiving replica's subscriber (`client-output-buffer-limit pubsub`, hard
32 MB by default). Frames between sockets on one replica are unaffected.

Each replica accepts at most 200 concurrent `/ws` connections per client IP
(`RELAY_WS_MAX_PER_IP`); the next upgrade gets `429` "Too many WebSocket
connections from this address" until one closes. The count is per replica, so
behind N replicas one IP can hold up to about N × the limit. The client IP is
`CF-Connecting-IP`, then the first `X-Forwarded-For` entry, then `X-Real-IP`,
then the peer address. Cloudflare sets `CF-Connecting-IP` itself, so in
production it can't be forged; a relay reachable without Cloudflare in front
trusts client-sent `X-Forwarded-For`/`X-Real-IP` and its per-IP limit can be
dodged. A room holds at most 2 pending (not yet verified) Astation sockets
from one client IP (the same address as above) and 32 in all
(`MAX_PENDING_ASTATIONS_PER_IP`, `MAX_PENDING_ASTATIONS_PER_ROOM` in
`src/relay.rs`); one more is closed with `1013`.

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
owner. A socket also goes pending when the room already has a verified owner,
even if this replica's key cache doesn't know the key yet (the room directory
is authoritative); its proof is then checked against the database. Registered keys are cached in memory (loaded at startup, written
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

- `POST /api/memory/batch {ops: [...]}` → `{"results": [OpResult]}` - Batch add/delete/invalidate memory ops (body limit 2 MB, at most 64 ops)
- `GET /api/memory [?since=<seq>&limit=<n>]` → `{"memories": [MemoryRow]}` - Pull memories (default `since=0`, `limit=200`, capped at 500). There is no `next_since`: the next cursor is the highest `seq` in the page.
- `POST /api/skills/batch {ops: [...]}` → `{"results": [OpResult]}` - Batch push/delete/purge skill ops (body limit 16 MB, at most 16 ops)
- `GET /api/skills [?since=<seq>&limit=<n>]` → `{"skills": [SkillRow]}` - Pull skills (default `since=0`, `limit=200`, capped at 500; no `next_since`)
- `GET /api/skills/versions?scope=&project=&name=` → `{"versions": [{version, created_at, source_agent, source_machine, file_count, deleted, purged}]}` - One skill's history, newest first, no file contents (unknown skill → empty list)
- `GET /api/skills/version?scope=&project=&name=&version=<n>` → `{"skill": SkillRow}` - One version with its files. 404 `no such skill version` (unknown, or another account's), 410 `skill version purged`; a delete marker comes back as `deleted: true` with `files: {}`. A bad scope/name → 400 `invalid skill`, no `version` → 400 `missing version`

Memory ops and validity (Atem Memory 1.1, migration 0004):

- `{"op":"add","memory":MemoryRow}` — the row may carry `valid_at` (when the fact became true; must be > 0). The client's `deleted`, `deleted_at`, `invalid_at`, `superseded_by` and `seq` are ignored.
- `{"op":"delete","id"}` — blanks the text and sets `deleted_at` (the first deletion time is kept).
- `{"op":"invalidate","id","invalid_at","superseded_by"?}` — marks a fact outdated without touching its text; `invalid_at` must be > 0. **Final:** once set it never changes. A repeat, or an unknown, deleted or other-account id, is `{ok:true, seq:0}` (no change). A change takes a new `seq`, so every atem pulls it. `superseded_by` is only a hint: it is not checked for existence or account.
- Within one batch, a `delete`/`invalidate` whose `id` or `superseded_by` names an id an earlier `add` was deduplicated onto is rewritten to that `canonical_id`.
- Memory rows carry `deleted` (computed from `deleted_at`, for older atems), `deleted_at`, `valid_at`, `invalid_at` and `superseded_by`. The dedup index covers only rows that are neither deleted nor invalid, so a fact that becomes true again is a new memory.
- `purge` also sets `skill_versions.purged` (migration 0005); that's the `purged` flag in skill history. Versions purged before 0005 report as `deleted`.

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
(add is idempotent by id, delete/invalidate/purge are idempotent, a retried skill push
appends a harmless duplicate version). Per-op refusals are permanent (atem
acks them), so they are only ever input problems:

- a credential-shaped value (`knowledge_secrets::find_secrets`/`check_bytes`)
  → `possible credential: ...`; the reserved `atem:memory:` token →
  `reserved token` (memories) / `possible credential: <path>: reserved token`
  (skill files);
- an invalid scope, or a NUL (`\u0000`, which Postgres can't store) in any
  memory string field, an invalidate `id`/`superseded_by`, an `invalid_at`
  or `valid_at` that isn't positive → `invalid memory`; in a skill's
  name/project/source/hash or a file relpath → `invalid skill`;
- skill file bytes that aren't canonical standard base64 → `invalid base64`;
- a memory id owned by another account → `id conflict`.

Skill files are sent base64-encoded in the request body and decoded
server-side (no `base64` crate — a small hand-rolled RFC 4648 decoder in
`knowledge_routes.rs`). Dedup, tombstones, and purge semantics are
implemented by `KnowledgeStore` (`knowledge_store.rs`).

Production nginx (`webapp/nginx.conf`) raises its 1 MB body cap to 16 MB for
`/api/skills/batch` and 2 MB for `/api/memory/batch` only.
The skill-history GETs need no nginx change: they fall under `location /api/`, and the body cap applies to requests only.

Rollback: after migration 0004 the `memories.deleted` column is gone, so a
relay binary built before it can't write memories. Roll back by restoring a
database backup, not by redeploying the old image, and deploy as a
single-instance swap (no old and new relay running against one database).

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
| `REDIS_URL` | _(unset)_ | Redis/Valkey for shared relay state: rooms, pairing/OTP, voice and RTC sessions, shared rate-limit counters, replica-to-replica delivery. Required to run more than one replica. Unset: in-memory, one replica only. At startup Redis is tried 10 times, 3 s apart (about 27 s if refused, up to about 57 s if it doesn't answer), then the relay exits 1; a malformed URL or wrong password exits 1 at once. The URL (and its password) is never logged. |
| `RELAY_WS_MAX_PER_IP` | `200` | Concurrent `/ws` connections allowed per client IP on each replica; over it the upgrade gets `429`. Raise it for load tests that open many sockets from one machine. Blank means unset (default `200`); any other value that isn't a positive integer exits 1 at startup. |
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
cargo test  # unit + in-memory integration suites (auth, sessions, relay + relay identity, RTC, Voice, Vault, Knowledge sync, validation)
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

### Load test

`loadtest/` is a separate crate (its own workspace and `Cargo.lock`), so it
adds nothing to the relay binary, its Docker image or `cargo test`; CI
builds it and runs its unit tests. It speaks the real protocol: each room is an Astation socket
(`role=astation`, id `astation-lt-<run-id>-<n>`) that answers the relay's
`relayAuthChallenge` with a `relayAuth` signed by its own fresh P-256 key,
plus Atem sockets (`role=atem`) on the *other* replicas. Every interval each
Atem sends a frame (enveloped by the relay), the Astation answers it with a
targeted envelope and broadcasts one frame to all its Atems. Rooms are
spread round-robin over the `--url`s and their ticks spread over the
interval.

Default run (the spec's target): `--astations 10000 --atems-per-astation 2`
(30k sockets), ramp 500 sockets/s, then 30 minutes of traffic every 5 s.

**Safety.** Only loopback URLs (`localhost`, `127.0.0.0/8`, `::1`) are
accepted; anything else needs `--i-know-this-is-production`. Never point it at
the production relays without a planned window: it opens tens of thousands
of sockets, and each room registers an Astation key in the identity store.
With Postgres, clean up afterwards. The ids are
`astation-lt-<run-id>-0` … `-<astations - 1>`; the run id is printed on the
first line. With `REDIS_URL` set, use `forget-key`, which also evicts the key
from every replica's cache:

```bash
# in any relay container (it has DATABASE_URL and REDIS_URL set)
for n in $(seq 0 9999); do station-relay-server admin forget-key "astation-lt-<run-id>-$n"; done
```

A raw `DELETE FROM astation_keys WHERE astation_id LIKE 'astation-lt-%';` is
quicker but leaves the keys in the relays' caches until each relay restarts.
`forget-key` doesn't.

**Two local relays + Valkey:**

```bash
# Client host limits (30k sockets from one machine):
ulimit -n 65535
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"

docker run --rm -d --name relay-lt-valkey -p 127.0.0.1:56380:6379 valkey/valkey:8
cargo build --release
for port in 3341 3342; do
  REDIS_URL=redis://127.0.0.1:56380/ RELAY_REPLICAS_EXPECTED=2 \
  RELAY_WS_MAX_PER_IP=20000 PORT=$port RUST_LOG=warn \
    ./target/release/station-relay-server > relay-$port.log 2>&1 &
done
# The relays need `ulimit -n` above their share of sockets too (start them
# from the same shell). RELAY_WS_MAX_PER_IP must exceed each replica's share
# of sockets from the load host (default 200 refuses the rest with 429).

cd loadtest && cargo build --release
./target/release/relay-loadtest --url ws://127.0.0.1:3341/ws --url ws://127.0.0.1:3342/ws \
  --astations 50 --atems-per-astation 3 --duration-secs 60 --interval-ms 1000   # smoke
./target/release/relay-loadtest --url ws://127.0.0.1:3341/ws --url ws://127.0.0.1:3342/ws  # full 30k

# Meanwhile, every few minutes: relay memory and sockets.
docker stats --no-stream   # containerized relays, or: ps -o rss= -p <relay pid>
curl -s 127.0.0.1:3341/metrics | grep -E '^relay_(sockets|rooms|slow)'

kill %1 %2; docker rm -f relay-lt-valkey
```

Every 10 s it prints the phase, open sockets, frames received/sent per flow
(`up` Atem → Astation, `bcast` Astation → all Atems, `uni` Astation → one
Atem) and that window's p50/p99; at the end the totals and `PASS` or `FAIL`
(exit 0 or 1).

**Pass criteria** (spec, "Scaling to 10k+"): `PASS`, meaning p99 frame
latency under 100 ms over the whole run, no lost frames in any flow, no
sequence gaps, duplicates or reordering (each receiver checks every sender's
`seq` per flow), and no failed connect, rejected `relayAuth`, incomplete room or socket dropped
before the end; **and** each relay's memory (`docker stats` / RSS) flat over
the 30 minutes after the ramp (the client can't see that). Expect a ~40 ms
bump on a few frames once a minute, right after the relay's 60 s ping of each
socket (seen in local runs); it is far too rare to move the p99.

**Before claiming 10k:** run the full 30k test against production-like relays
(two replicas, Valkey, `RELAY_WS_MAX_PER_IP=20000` for the run) and record
the result (date, commit, hosts, the `total:` line, relay memory at start and
end) in `../DEPLOY.md`'s sizing paragraph. No 10k claim without that record;
rerun it before raising any limit.


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
"Admin reset"). Exit codes: 0 done, 1 database/Redis error (with `REDIS_URL` set but Redis unreachable, nothing is deleted), 2 bad arguments.

**Monitoring:** Check `docker compose logs -f`

---

## Troubleshooting

- **CORS errors**: Set `CORS_ORIGIN` env var to match your domain
- **429 Rate limit**: Normal - client exceeded 60/600 req/min limit
- **429 on `/ws` "Too many WebSocket connections from this address"**: that IP already has `RELAY_WS_MAX_PER_IP` (200) sockets open on the replica; raise it for load tests
- **404 Session not found**: Session expired, or the relay restarted in in-memory mode (or Valkey restarted)
- **503 "Relay state unavailable"**: the relay can't reach Redis (`REDIS_URL`); `/health` shows `"redis":"unavailable"`

---

## Support

- Issues: [GitHub Issues](https://github.com/Agora-Build/Astation/issues)
- Security: security@agora.build
- Docs: See SECURITY.md for deployment details
