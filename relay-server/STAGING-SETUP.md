# Staging Setup Guide (Coolify)

Quick setup for deploying Station Relay Server to **station.staging.agora.build** on your Coolify instance.

---

## 5-Minute Setup

### Step 1: Create Service in Coolify

1. Open your Coolify dashboard
2. Click **"+ New Resource"** → **"Service"**
3. Choose **"Docker Compose"**

### Step 2: Configure Source

- **Source Type:** GitHub Repository
- **Repository:** `https://github.com/Agora-Build/Astation`
- **Branch:** `main`
- **Path:** `relay-server`
- **Docker Compose File:** `docker-compose.yml`

### Step 3: Environment Variables

In Coolify UI, add these environment variables:

```bash
CORS_ORIGIN=https://station.staging.agora.build
PORT=3000
RUST_LOG=debug
```

**Or copy from `.env.staging`:**
- The `.env.staging` file contains all staging settings
- Copy values to Coolify UI environment section

### Step 4: Configure Domain

In Coolify → Service → Domains:

- **Domain:** `station.staging.agora.build`
- **HTTPS:** ✅ Enabled (automatic)
- **Force HTTPS:** ✅ Enabled
- **Port:** `3000`

### Step 5: Deploy

1. Click **"Deploy"** button
2. Wait for build (~2-3 minutes)
3. Check logs for successful startup

**Expected log output:**
```
[INFO] Astation server listening on http://0.0.0.0:3000
[INFO] Rate limiting configured:
[INFO]   - OTP validation: 60 requests/min per IP (burst: 10)
[INFO]   - General API: 600 requests/min per IP (burst: 20)
[INFO] CORS configured to allow origin: https://station.staging.agora.build
```

---

## Verify Deployment

### Health Check

```bash
curl https://station.staging.agora.build/api/pair
```

**Expected:** `400 Bad Request` (hostname missing) - This is correct! Server is running.

### Test Auth Session

```bash
curl -X POST https://station.staging.agora.build/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"hostname":"staging-test"}'
```

**Expected:** `201 Created` with session ID and OTP

### Test Pairing

```bash
curl -X POST https://station.staging.agora.build/api/pair \
  -H "Content-Type: application/json" \
  -d '{"hostname":"staging-test"}'
```

**Expected:** `201 Created` with pairing code

### Test RTC Session

```bash
curl -X POST https://station.staging.agora.build/api/rtc-sessions \
  -H "Content-Type: application/json" \
  -d '{
    "app_id":"test-app-id",
    "channel":"test-channel",
    "token":"test-token",
    "host_uid":1234
  }'
```

**Expected:** `201 Created` with session URL

---

## Auto-Deploy Setup

Enable auto-deploy from GitHub:

1. In Coolify → Service → Settings
2. Enable **"Auto Deploy"**
3. Select branch: `main`
4. Webhook: Automatically configured

**Now:** Every push to `main` → Coolify auto-deploys to staging!

---

## Configuration Differences

| Environment | URL | CORS | Logging |
|-------------|-----|------|---------|
| **Production** | `station.agora.build` | `station.agora.build` | `info` |
| **Staging** | `station.staging.agora.build` | `station.staging.agora.build` | `debug` |
| **Development** | `localhost:3000` | `*` (all origins) | `debug` |

---

## Monitoring in Coolify

### View Logs

Coolify → Service → **Logs**

**Filter by level:**
- `ERROR` - Critical issues
- `WARN` - Warnings (rate limits, full sessions)
- `INFO` - General info (connections, sessions)
- `DEBUG` - Detailed debugging (staging only)

### Check Metrics

Coolify → Service → **Metrics**

Monitor:
- **CPU Usage:** Should be <20% under normal load
- **Memory Usage:** ~128MB baseline, ~256MB under load
- **Network:** Bandwidth usage

### Health Status

Coolify → Service → **Health**

- **Status:** Should show "Healthy"
- **Last Check:** Updated every 30 seconds
- **Uptime:** Track availability

---

## Testing with Astation

### Update Astation Config (Staging)

In Astation app, create a staging config:

**`.atem/config.staging.toml`:**
```toml
[station]
relay_url = "https://station.staging.agora.build"
ws_url = "wss://station.staging.agora.build"

[agora]
app_id = "your_staging_app_id"
app_cert = "your_staging_app_certificate"
```

### Test Auth Flow

1. Run Astation with staging config
2. Click "Connect" in Astation
3. Browser opens: `https://station.staging.agora.build/auth?id=...`
4. Click "Grant" on auth page
5. Astation receives auth token

### Test Pairing

1. Run Atem CLI: `atem pair`
2. Browser opens: `https://station.staging.agora.build/pair?code=ABCD-EFGH`
3. Click "Open in Astation"
4. Astation connects via WebSocket
5. Commands relay between Atem and Astation

### Test RTC Session

1. Join RTC in Astation
2. Click "Share Screen" → Creates link
3. Open link in browser: `https://station.staging.agora.build/session/...`
4. Enter name and join
5. Browser receives screen share + publishes mic

---

## Troubleshooting

### Service Won't Start

**Check build logs:**
```bash
# In Coolify UI
Service → Build Logs
```

**Common issues:**
- Port conflict: Change `PORT` env var
- CORS error: Check `CORS_ORIGIN` matches domain
- Memory limit: Increase in Coolify → Resources

### Health Check Failing

```bash
# SSH into Coolify server
docker exec -it station-relay-server curl http://localhost:3000/api/pair
```

**Should return:** JSON response (not connection refused)

### CORS Errors in Browser

```
Access-Control-Allow-Origin header missing
```

**Fix:**
1. Check `CORS_ORIGIN` in Coolify environment
2. Must match: `https://station.staging.agora.build`
3. No trailing slash!

### Rate Limit Testing

```bash
# Test OTP rate limit (60/min)
for i in {1..70}; do
  curl -X POST https://station.staging.agora.build/api/sessions/test/grant \
    -H "Content-Type: application/json" \
    -d '{"otp":"12345678"}'
done

# Should see 429 after 60 requests
```

---

## Updating Staging

### Manual Update

In Coolify UI:
1. Service → **Deploy** button
2. Pulls latest from `main` branch
3. Rebuilds and redeploys

### Auto-Update (Recommended)

Already configured! Every push to `main` triggers:
1. GitHub webhook → Coolify
2. Coolify pulls latest code
3. Builds Docker image
4. Deploys with zero downtime

---

## Rollback

If deployment breaks:

1. Coolify → Service → **Deployments**
2. Find previous successful deployment
3. Click **"Rollback"**
4. Service reverts to previous version

---

## Next Steps

After staging is working:

1. ✅ Test all 3 APIs (Auth, Pairing, RTC)
2. ✅ Test with real Astation app
3. ✅ Monitor logs for errors
4. ✅ Load test (simulate 100+ users)
5. ✅ Fix any issues found
6. 🚀 Deploy to production with confidence!

---

## Production Deployment

Once staging is stable, deploy to production:

**Same steps, but use:**
- **Domain:** `station.agora.build`
- **Environment:** Copy from `.env.example`
- **Logging:** `RUST_LOG=info` (not debug)

See `COOLIFY.md` for complete production guide.

---

## Support

- **Coolify Docs:** https://coolify.io/docs
- **Relay Server Docs:** See `README.md` and `SECURITY.md`
- **Issues:** GitHub Issues with `[staging]` tag

---

**Happy staging!** 🎭

🤖 Built with SMT <smt@agora.build>
