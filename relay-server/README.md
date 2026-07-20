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

### Staging (Coolify)
```bash
# Coolify UI:
# 1. New Docker Compose service
# 2. GitHub: Agora-Build/Astation, path: relay-server
# 3. Environment:
#    CORS_ORIGIN=https://station-staging.agora.build
#    PUBLIC_BASE_URL=https://station-staging.agora.build
# 4. Domain: station-staging.agora.build
# 5. Deploy
```

**URLs:**
- Production: `https://station.agora.build`
- Staging: `https://station-staging.agora.build`
- Dev: `http://localhost:3000`

---

## API Reference

### Auth Sessions
Deep link authentication for Astation app.

- `POST /api/sessions {hostname}` → `{id, otp}` - Create auth session (5min expiry)
- `GET /api/sessions/:id/status` → `{status, token?}` - Poll for grant/deny
- `POST /api/sessions/:id/grant {otp}` → `{token}` - User grants access (60 req/min limit)

### WebSocket Relay (Pairing)
Atem ↔ Astation message relay via pairing codes.

- `POST /api/pair {hostname}` → `{code}` - Create pairing room (10min expiry)
- `WS /ws?role={atem|astation}&code={CODE}` - Connect and relay messages

### RTC Sessions
Web screen sharing with up to 8 participants.

- `POST /api/rtc-sessions {app_id, channel, token, host_uid}` → `{id, url}` - Create session (4hr expiry)
- `GET /api/rtc-sessions/:id` → `{app_id, channel, host_uid}` - Get session info
- `POST /api/rtc-sessions/:id/join {name}` → `{app_id, channel, token, uid}` - Join session (assigns unique UID)

### Vault
Durable, append-only, versioned shared context store for collaborating atems.
Backed by Postgres (`DATABASE_URL`). All requests require
`Authorization: session <session_id>` and `?id=<client_id>`.

- `POST /api/vault {summary}` → `{vault_id}` - Create a vault
- `GET /api/vault` → `[{vault_id, summary}]` - List readable vaults
- `GET /api/vault/:id [?since=<seq>&history=true]` → `[VaultEntry]` - Read (current view or history)
- `POST /api/vault/:id {text, entry_id?}` → `{entry_no, version, seq}` - Append (no `entry_id`) or override (with `entry_id`)
- `POST /api/vault/:id/summary {text}` → `{}` - Update summary

Authz: in-session callers (same `work_session_id` = bound astation_id) get read+write;
out-of-session past content-writers get read-only; others are denied (403).

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
| `DATABASE_URL` | _(unset)_ | Postgres connection string for **vault** storage (e.g. `postgres://vault:vault@localhost:5432/vault`). When unset, vault storage falls back to **in-memory** (non-durable) and logs a warning. Migrations in `migrations/` run automatically at startup. |

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
cargo test  # 90 tests (auth, sessions, relay, RTC, validation)
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
