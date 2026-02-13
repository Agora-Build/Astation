# Quick Deploy Reference

## URLs

| Environment | URL |
|-------------|-----|
| **Production** | `https://station.agora.build` |
| **Staging** | `https://station.staging.agora.build` |
| **Development** | `http://localhost:3000` |

---

## Production Deploy (Docker Compose)

```bash
cd relay-server

# Create .env
cp .env.example .env

# Edit .env
CORS_ORIGIN=https://station.agora.build
PORT=3000
RUST_LOG=info

# Deploy
docker compose up -d

# Verify
curl http://localhost:3000/api/pair
```

---

## Staging Deploy (Coolify)

**URL:** `https://station.staging.agora.build`

**Quick Setup:**

1. **Coolify** → New Docker Compose Service
2. **Source:**
   - Repository: `https://github.com/Agora-Build/Astation`
   - Branch: `main`
   - Path: `relay-server`
3. **Environment:**
   ```
   CORS_ORIGIN=https://station.staging.agora.build
   PORT=3000
   RUST_LOG=debug
   ```
4. **Domain:** `station.staging.agora.build`
5. **Deploy** → Done in 3 minutes!

**Verify:**
```bash
curl https://station.staging.agora.build/api/pair
```

---

## Development (Local)

```bash
cd relay-server

# Option 1: Cargo (fastest)
export CORS_ORIGIN=*
export RUST_LOG=debug
cargo run

# Option 2: Docker
docker compose -f docker-compose.dev.yml up
```

---

## Environment Files

| File | For |
|------|-----|
| `.env.example` | Production template |
| `.env.staging` | Staging (copy to Coolify) |
| `.env` | Production (git ignored) |

---

## Test Endpoints

### Production
```bash
# Health
curl http://localhost:3000/api/pair

# Auth session
curl -X POST http://localhost:3000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"hostname":"prod-test"}'
```

### Staging
```bash
# Health
curl https://station.staging.agora.build/api/pair

# Auth session
curl -X POST https://station.staging.agora.build/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"hostname":"staging-test"}'

# Pairing
curl -X POST https://station.staging.agora.build/api/pair \
  -H "Content-Type: application/json" \
  -d '{"hostname":"staging-test"}'
```

---

## Astation Config

### Production
```toml
[station]
relay_url = "https://station.agora.build"
ws_url = "wss://station.agora.build"
```

### Staging
```toml
[station]
relay_url = "https://station.staging.agora.build"
ws_url = "wss://station.staging.agora.build"
```

### Development
```toml
[station]
relay_url = "http://localhost:3000"
ws_url = "ws://localhost:3000"
```

---

## Commands

### Docker Compose
```bash
docker compose up -d              # Start
docker compose logs -f            # Logs
docker compose restart            # Restart
docker compose down               # Stop
docker compose ps                 # Status
```

### Coolify
- **Deploy:** UI → Deploy button
- **Logs:** UI → Real-time logs
- **Restart:** Automatic on push to main
- **Rollback:** UI → Deployments → Rollback

---

## Troubleshooting

### CORS Error
```
Access-Control-Allow-Origin missing
```
**Fix:** Check `CORS_ORIGIN` matches your domain exactly:
- Production: `https://station.agora.build`
- Staging: `https://station.staging.agora.build`
- No trailing slash!

### Service Not Starting
```bash
# Check logs
docker compose logs -f

# Common issues:
# 1. Port 3000 already in use → Change PORT env var
# 2. Invalid CORS_ORIGIN → Check URL format
```

### Rate Limit Test
```bash
# Should get 429 after 60 requests
for i in {1..70}; do
  curl -X POST https://station.staging.agora.build/api/sessions/test/grant \
    -d '{"otp":"12345678"}'
done
```

---

## Quick Links

- **Full Docs:** `README.md`
- **Security:** `SECURITY.md`
- **Coolify Guide:** `COOLIFY.md`
- **Staging Setup:** `STAGING-SETUP.md`

🤖 Built with SMT <smt@agora.build>
