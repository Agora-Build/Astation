# Coolify Deployment Guide

Deploy Station Relay Server to your Coolify instance in minutes.

---

## Prerequisites

- Coolify instance running (v4+)
- GitHub repository access
- Domain name configured in Cloudflare (for Tunnel integration)

---

## Quick Deploy

### Option 1: Docker Compose (Recommended)

Coolify has native Docker Compose support with auto-deploy from GitHub.

#### Step 1: Create New Service

1. Open Coolify dashboard
2. Click **"+ New Resource"** → **"Service"**
3. Choose **"Docker Compose"**
4. Select source: **GitHub Repository**
   - Repository: `https://github.com/Agora-Build/Astation`
   - Branch: `main`
   - Path: `relay-server`

#### Step 2: Configure Environment

Add environment variables:

```bash
CORS_ORIGIN=https://station.agora.build
PORT=3000
RUST_LOG=info
```

#### Step 3: Configure Domain

- **Domain:** `station.agora.build`
- **HTTPS:** Enabled (automatic via Coolify)
- **Port:** 3000

#### Step 4: Deploy

Click **"Deploy"** and wait for build to complete (~2-5 minutes).

**Health Check URL:** `https://station.agora.build/api/pair`

---

### Option 2: Dockerfile (Alternative)

If you prefer single-container deployment:

#### Step 1: Create New Application

1. Click **"+ New Resource"** → **"Application"**
2. Choose **"Dockerfile"**
3. Repository: `https://github.com/Agora-Build/Astation`
4. Branch: `main`
5. Dockerfile path: `relay-server/Dockerfile`
6. Build context: `relay-server`

#### Step 2: Configure

Same as Option 1 (environment variables + domain).

---

## Coolify Configuration

### Environment Variables

Set in Coolify UI under **Service → Environment**:

| Variable | Value | Required |
|----------|-------|----------|
| `CORS_ORIGIN` | `https://station.agora.build` | Yes |
| `PORT` | `3000` | No (default) |
| `RUST_LOG` | `info` | No (default) |

### Health Check

Coolify will automatically detect the healthcheck from `docker-compose.yml`:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/api/pair"]
  interval: 30s
  timeout: 10s
  retries: 3
```

**Health Check Endpoint:** `GET /api/pair`

### Resource Limits

Default limits from `docker-compose.yml`:
- **CPU:** 1.0 core (max), 0.25 core (reserved)
- **Memory:** 512MB (max), 128MB (reserved)

Adjust in Coolify UI if needed.

---

## Deployment Methods

### Auto-Deploy (Recommended)

Coolify automatically deploys on every push to main branch.

**Setup:**
1. In Coolify, enable **"Auto Deploy"** for the service
2. Webhook automatically configured for GitHub
3. Push to main → Coolify builds and deploys

### Manual Deploy

```bash
# Via Coolify CLI (if installed)
coolify deploy --service station-relay-server

# Or via Coolify UI
# → Service → Deploy button
```

---

## Integration with Cloudflare Tunnel

For enhanced security, route Coolify through Cloudflare Tunnel.

### Architecture

```
Internet
    ↓
Cloudflare (DDoS, HTTPS)
    ↓
Cloudflare Tunnel
    ↓
Coolify (Docker)
    ↓
Station Relay Server (localhost:3000)
```

### Setup

#### 1. Install cloudflared on Coolify Host

```bash
# SSH into Coolify server
ssh user@your-coolify-server.com

# Install cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Authenticate
cloudflared tunnel login
```

#### 2. Create Tunnel

```bash
# Create tunnel
cloudflared tunnel create station-relay

# Output: Tunnel ID and credentials file path
# Copy the tunnel ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

#### 3. Configure Tunnel

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <YOUR_TUNNEL_ID>
credentials-file: /root/.cloudflared/<YOUR_TUNNEL_ID>.json

ingress:
  # Route to Coolify-managed container
  - hostname: station.agora.build
    service: http://localhost:3000

  # Catch-all rule (required)
  - service: http_status:404
```

#### 4. Configure DNS

```bash
# Add DNS record in Cloudflare
cloudflared tunnel route dns station-relay station.agora.build
```

#### 5. Run Tunnel as Service

```bash
# Create systemd service
sudo tee /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel run station-relay
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
sudo systemctl status cloudflared
```

#### 6. Update Coolify Service

In Coolify, change port binding to localhost only:

```yaml
ports:
  - "127.0.0.1:3000:3000"
```

This ensures the service is only accessible via Cloudflare Tunnel.

---

## Monitoring in Coolify

### Logs

View logs in Coolify UI:
- **Service → Logs** → Real-time streaming logs
- **Filter:** Error, Warn, Info, Debug

### Metrics

Coolify shows:
- **CPU Usage:** Current and historical
- **Memory Usage:** Current and historical
- **Network:** In/out traffic
- **Health:** Up/down status

### Alerts

Configure in **Coolify Settings → Notifications**:
- **Deployment Failure:** Email/Slack notification
- **Service Down:** Health check failure alerts
- **Resource Usage:** CPU/Memory thresholds

---

## Scaling

### Horizontal Scaling

Coolify supports multiple replicas (Swarm mode):

```yaml
deploy:
  replicas: 3
  update_config:
    parallelism: 1
    delay: 10s
  restart_policy:
    condition: on-failure
```

Add to `docker-compose.yml` and redeploy.

### Load Balancing

Coolify automatically load balances between replicas using Docker Swarm ingress network.

---

## Backup & Restore

### Service Configuration Backup

Export service config from Coolify UI:
- **Service → Settings → Export Configuration**

### Restore

Import configuration:
- **+ New Resource → Import Configuration**

**Note:** Relay server is stateless (in-memory storage only), so no data backup needed.

---

## Troubleshooting

### Service Won't Start

**Check logs:**
```bash
# Via Coolify UI
Service → Logs

# Or SSH into server
docker logs station-relay-server
```

**Common issues:**
1. **Port conflict:** Change PORT env var
2. **CORS_ORIGIN:** Set correct domain
3. **Build failure:** Check Dockerfile path in Coolify config

### Health Check Failing

```bash
# Test health endpoint
curl http://localhost:3000/api/pair

# Should return:
# {"error": "Room not found"} or similar
```

**Fix:** Ensure service is running and listening on correct port.

### CORS Errors

```
Access-Control-Allow-Origin header missing
```

**Fix:** Set `CORS_ORIGIN=https://station.agora.build` in Coolify environment variables.

### Memory Issues

**Symptoms:** Service crashes, OOM errors

**Fix:**
1. Increase memory limit in `docker-compose.yml`
2. Or in Coolify UI: **Service → Resources → Memory Limit**

---

## Comparison: Coolify vs Cloudflare Tunnel

| Feature | Coolify | Cloudflare Tunnel | Both |
|---------|---------|-------------------|------|
| **HTTPS** | ✅ Automatic | ✅ Automatic | ✅ Best |
| **DDoS Protection** | ⚠️ Basic | ✅ Advanced | ✅ Best |
| **Zero-Trust** | ❌ No | ✅ Yes | ✅ Best |
| **Cost** | Free (self-hosted) | Free | Free |
| **Complexity** | Low | Medium | Medium |
| **Performance** | Fast (direct) | Good (proxied) | Good |

**Recommendation:** Use **Coolify + Cloudflare Tunnel** for best security and performance.

---

## Production Checklist

### Before Going Live

- [ ] Set `CORS_ORIGIN` to your production domain
- [ ] Configure health checks in Coolify
- [ ] Set resource limits (CPU/Memory)
- [ ] Enable auto-deploy from main branch
- [ ] Configure Cloudflare Tunnel (recommended)
- [ ] Set up monitoring alerts
- [ ] Test all 3 APIs (Auth, Pairing, RTC)

### Testing

```bash
# Test auth sessions
curl -X POST https://station.agora.build/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"hostname":"test-host"}'

# Test pairing
curl -X POST https://station.agora.build/api/pair \
  -H "Content-Type: application/json" \
  -d '{"hostname":"test-host"}'

# Test health
curl https://station.agora.build/api/pair
```

---

## Support

- **Coolify Docs:** https://coolify.io/docs
- **Cloudflare Tunnel:** https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/
- **GitHub Issues:** https://github.com/Agora-Build/Astation/issues

---

## Example Coolify Configuration

Complete service configuration for Coolify:

```yaml
# Service Name
name: station-relay-server

# Source
source:
  type: github
  repository: Agora-Build/Astation
  branch: main
  path: relay-server

# Build
build:
  type: docker-compose
  file: docker-compose.yml

# Environment
environment:
  CORS_ORIGIN: https://station.agora.build
  PORT: 3000
  RUST_LOG: info

# Domain
domains:
  - station.agora.build

# Resources
resources:
  cpu: 1.0
  memory: 512M

# Health Check
healthcheck:
  enabled: true
  url: /api/pair
  interval: 30s

# Auto Deploy
autodeploy:
  enabled: true
  branch: main
```

Save this as `coolify.yml` in your repository for easy import.

---

**Ready to deploy?** Follow the steps above and you'll have Station Relay Server running on Coolify in 5 minutes!

🚀 Built with SMT <smt@agora.build>
