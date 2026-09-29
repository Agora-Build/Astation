# Station Relay Server

Secure relay and session management server for Astation ecosystem.

**Services:** Auth Sessions, WebSocket Relay (Atem ↔ Astation), RTC Sessions (web screen sharing)
**Security:** Rate limiting, input validation, CORS, XSS protection
**Status:** ✅ Production Ready | Test suite passing

`GET /health` returns `200` when the relay and its configured Vault store are ready,
and identifies the active store as `memory` or `postgres`.

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
- `WS /ws?role={atem|astation}&code={CODE}` - Connect and relay messages

For identity-room reconnects, the relay is the transport, not the device
authenticator. Astation sends a v2 challenge, verifies the Atem HMAC proof, and
only then returns `authenticated`. The relay binds a session to the room only
after observing that Astation response. See [`SECURITY.md`](SECURITY.md) for
current production blockers.

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
`Authorization: session <session_id>` and `?id=<client_id>`.

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
| Missing/invalid session | 401 (body never read) |
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
| `DATABASE_URL` | _(unset)_ | Postgres connection string shared by **vault** and **knowledge sync (Atem Memory)** storage (e.g. `postgres://vault:vault@localhost:5432/vault`), one pool for both. When unset, both fall back to **in-memory** (non-durable) and log a warning. Migrations in `migrations/` run automatically at startup. |

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
cargo test  # 235 tests (auth, sessions, relay, RTC, Voice, Vault, Knowledge sync, validation)
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

**Scaling:**
```yaml
# Add to docker-compose.yml
deploy:
  replicas: 3
```

**Monitoring:** Check `docker compose logs -f`

---

## Troubleshooting

- **CORS errors**: Set `CORS_ORIGIN` env var to match your domain
- **429 Rate limit**: Normal - client exceeded 60/600 req/min limit
- **404 Session not found**: Session expired or server restarted (in-memory storage)

---

## Support

- Issues: [GitHub Issues](https://github.com/Agora-Build/Astation/issues)
- Security: security@agora.build
- Docs: See SECURITY.md for deployment details
