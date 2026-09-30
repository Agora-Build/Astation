# Deployment Guide

## Overview

The Astation system consists of:
1. **macOS App** - Menubar app with RTC capabilities (`.pkg` installer)
2. **API Server** - Rust backend for session management + WebSocket relay
3. **Webapp** - Web client for joining RTC sessions via shareable links

## GitHub Actions Release

When you push a git tag, GitHub Actions automatically builds and publishes:

```bash
git tag v0.4.0
git push origin v0.4.0
```

This triggers `.github/workflows/release.yml` which:
1. **Builds macOS app** → Creates `.pkg` installer + `.tar.gz` bundle
2. **Builds API server Docker image** → Pushes to `ghcr.io/agora-build/station-relay-server:latest`
3. **Builds webapp Docker image** → Pushes to `ghcr.io/agora-build/station-webapp:latest`
4. **Creates GitHub release** → Uploads artifacts

## Production Deployment

### Station on Volumetric (Coolify)

Every push to `main` runs `.github/workflows/deploy-station.yml`. It builds both
Linux AMD64 images, publishes `:main` and `:sha-<commit>` tags to GHCR, deploys
the relay followed by the webapp, and waits for each Coolify deployment to finish.
The final check requires public HTTPS, `/health`, and an identity WebSocket
connection to `wss://station.agora.build/ws` to succeed. The workflow can also
be run manually on `main` from GitHub Actions.

Release tags continue to publish versioned and `:latest` images and the macOS
installer. They do not deploy production; Coolify tracks `:main` so publishing
an older release tag cannot roll production back.

The existing Coolify applications on Volumetric are:

| Application | Coolify UUID | Image | Host port |
| --- | --- | --- | --- |
| Relay | `oss4444o8ss40ckgwc40og4c` | `ghcr.io/agora-build/station-relay-server:main` | `3000` |
| Webapp | `c0wwgk4c0owk0w4gsww4k0ss` | `ghcr.io/agora-build/station-webapp:main` | `3010` |

Required GitHub Actions secrets:

- `COOLIFY_API_TOKEN`: Coolify token with `deploy` and `read` permissions.
- `COOLIFY_RELAY_SERVER_WEBHOOK_URL`: `https://smt.agora.build/api/v1/deploy?uuid=oss4444o8ss40ckgwc40og4c&force=false`.
- `COOLIFY_WEBAPP_WEBHOOK_URL`: `https://smt.agora.build/api/v1/deploy?uuid=c0wwgk4c0owk0w4gsww4k0ss&force=false`.

Runtime configuration:

- Relay: `PUBLIC_BASE_URL=https://station.agora.build`,
  `CORS_ORIGIN=https://station.agora.build`, `PORT=3000`, and the existing
  PostgreSQL `DATABASE_URL`. Keep its `station-relay-server` network alias.
- Webapp: `STATION_RELAY_UPSTREAM=station-relay-server:3000`. Both containers
  must use the `coolify` Docker network. nginx uses Docker DNS to refresh the
  relay address when Coolify replaces its container.
- Cloudflare: publish `station.agora.build` on the existing Volumetric tunnel
  with origin `http://10.0.0.1:3010` and a proxied CNAME to that tunnel's
  `<tunnel-id>.cfargotunnel.com`. TLS terminates at Cloudflare; the tunnel
  forwards `/`, `/health`, `/api/*`, and `/ws` to the webapp. `localhost` inside
  the cloudflared container refers to that container, not Volumetric.

Verification:

```bash
# Node.js 22 or newer; checks HTTPS, relay health, and WebSocket upgrade.
node .github/scripts/verify-station.mjs

# Inspect deployment history in GitHub Actions.
gh run list --workflow deploy-station.yml
```

If DNS returns `NXDOMAIN`, restore the Cloudflare hostname and DNS record.
If `/health` returns `502` while `http://127.0.0.1:3000/health` works on
Volumetric, check the webapp's relay upstream and Docker DNS resolution.
A successful deployment webhook only means the deployment was queued; the
workflow also checks the final deployment status and public endpoints.

#### Relay identity (Astation keys + session bindings)

Vault and Atem Memory authorize a session only through a binding pushed by an
Astation that proved its relay key (protocol: `relay-server/README.md`,
security notes: `relay-server/SECURITY.md`). Keys and bindings live in the
relay's Postgres (`astation_keys`, `session_bindings`, migration
`0003_astation_identity`, applied automatically at startup).

Rollout order (Astation first, so the first-use registration window is as
short as possible; see "First-use squatting" in `relay-server/SECURITY.md`):

1. **Ship the Astation update first.** Against the current relay it is inert:
   it only sends `relayAuth` in reply to a `relayAuthChallenge`, which the
   current relay never sends, and the binding messages only after a
   `registered`/`verified` result. Let users update before step 2.
2. **Deploy the relay.** The restart drops every relay socket; updated
   Astations reconnect within seconds, answer the challenge, register their
   key (trust on first use), and push their active sessions, so vault and Atem
   Memory keep working and bindings now survive relay restarts. Astations not
   yet updated ignore the challenge and stay in legacy mode: chat and remote
   control relay as before, but vault and memory return `401` for their Atems
   (the relay no longer derives bindings from auth traffic) until they update.
   Atems keep their changes queued meanwhile.

The relay loads all registered keys into memory at startup (logged as
`Loaded N Astation relay key(s)`) and serves connects and verifications from
that cache, so a database outage does not lock registered Astations out of
relay chat.

Admin reset, for a lost or replaced Mac (its Astation reports "Relay rejected
this Astation's key"). Relay logs show only the first 4 characters of an id, so
look it up first:

```sql
SELECT astation_id, registered_at, last_verified_at FROM astation_keys
 WHERE astation_id LIKE '<first chars>%';
DELETE FROM astation_keys WHERE astation_id = '<id>';
```

Bindings are kept. The next connect with a new key for that id registers it
(the mismatch makes the relay re-read the stored key). Until then the relay's
in-memory cache still accepts the old key, so **restart the relay after the
`DELETE` if the old key must be revoked immediately** (e.g. a stolen Mac). A
reset done while the relay can't reach the database is likewise picked up only
by a later re-read or a restart.

`DELETE /api/pair/:code` is refused with `409` for a code that has a registered
key; use the SQL above, not the API, to manage such rooms.

Rollback caveat: once `0003` has been applied, a relay image built before it
fails at startup (`sqlx` migrate error `VersionMissing(3)`: the database has a
migration the binary does not know). Roll back to an image that includes
`0003` (any `:sha-<commit>` from this change on). Only if you must run an older
image: `DELETE FROM _sqlx_migrations WHERE version = 3;` lets it start (the
tables stay and are ignored; a later deploy re-applies `0003`, which is
`CREATE … IF NOT EXISTS`).

### Option 1: Docker Compose (Recommended)

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  station-relay-server:
    image: ghcr.io/agora-build/station-relay-server:latest
    container_name: station-relay-server
    restart: unless-stopped
    environment:
      - RUST_LOG=info
      - PORT=3000
    ports:
      - "3000:3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  station-webapp:
    image: ghcr.io/agora-build/station-webapp:latest
    container_name: station-webapp
    restart: unless-stopped
    ports:
      - "80:80"
    depends_on:
      - station-relay-server
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
```

Deploy:

```bash
# Pull latest images
docker compose pull

# Start services
docker compose up -d

# Check logs
docker compose logs -f

# Check status
docker compose ps
```

Access:
- Webapp: http://your-server.com
- API: http://your-server.com/api/*

### Option 2: Kubernetes

Create `k8s/deployment.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: astation

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: relay-server
  namespace: astation
spec:
  replicas: 1  # must stay 1: rooms and the Astation key cache are in memory (see Scaling)
  strategy:
    type: Recreate  # never run two relay pods at once, even during a rollout
  selector:
    matchLabels:
      app: relay-server
  template:
    metadata:
      labels:
        app: relay-server
    spec:
      containers:
      - name: relay-server
        image: ghcr.io/agora-build/station-relay-server:latest
        ports:
        - containerPort: 3000
        env:
        - name: RUST_LOG
          value: info
        - name: PORT
          value: "3000"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 30
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"

---
apiVersion: v1
kind: Service
metadata:
  name: relay-server
  namespace: astation
spec:
  selector:
    app: relay-server
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: astation
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
      - name: webapp
        image: ghcr.io/agora-build/station-webapp:latest
        ports:
        - containerPort: 80
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "200m"

---
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: astation
spec:
  selector:
    app: webapp
  ports:
  - port: 80
    targetPort: 80
  type: LoadBalancer

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: astation-ingress
  namespace: astation
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - station.agora.build
    secretName: astation-tls
  rules:
  - host: station.agora.build
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: webapp
            port:
              number: 80
```

Deploy:

```bash
kubectl apply -f k8s/deployment.yaml

# Check status
kubectl get pods -n astation
kubectl get services -n astation
kubectl get ingress -n astation

# View logs
kubectl logs -n astation deployment/relay-server -f
kubectl logs -n astation deployment/webapp -f
```

### Option 3: Systemd (Bare Metal)

**API Server:**

```bash
# Download binary (or build from source)
wget https://github.com/Agora-Build/Astation/releases/latest/download/station-relay-server
chmod +x station-relay-server
sudo mv station-relay-server /usr/local/bin/

# Create systemd service
sudo tee /etc/systemd/system/astation-api.service << 'EOF'
[Unit]
Description=Astation API Server
After=network.target

[Service]
Type=simple
User=astation
WorkingDirectory=/opt/astation
ExecStart=/usr/local/bin/station-relay-server
Environment="RUST_LOG=info"
Environment="PORT=3000"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable astation-api
sudo systemctl start astation-api
sudo systemctl status astation-api
```

**Webapp (nginx):**

```bash
# Install nginx
sudo apt-get install nginx

# Download webapp files
mkdir -p /tmp/webapp
cd /tmp/webapp
wget https://github.com/Agora-Build/Astation/archive/refs/tags/latest.tar.gz
tar xzf latest.tar.gz
sudo cp -r Astation-*/webapp/* /var/www/astation/

# Configure nginx
sudo tee /etc/nginx/sites-available/astation << 'EOF'
server {
    listen 80;
    server_name station.agora.build;
    root /var/www/astation;
    index index.html;

    # SPA routing
    location /session/ {
        try_files $uri /index.html;
    }

    # Proxy API requests
    location /api/ {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # WebSocket support for relay
    location /ws {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    # Static assets
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/astation /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## HTTPS/SSL Setup

### Using Let's Encrypt (Recommended)

**With Docker Compose:**

Add Caddy as reverse proxy:

```yaml
services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config

  # Remove port mappings from webapp
  webapp:
    image: ghcr.io/agora-build/station-webapp:latest
    # ports: removed, accessed via caddy

volumes:
  caddy_data:
  caddy_config:
```

Caddyfile:

```
station.agora.build {
    reverse_proxy webapp:80
}
```

**With Kubernetes:**

Install cert-manager:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

Create ClusterIssuer (already in k8s/deployment.yaml above).

## Monitoring

### Health Checks

```bash
# API Server health
curl --fail http://localhost:3000/health

# Webapp health
curl http://localhost/

# RTC session creation (requires valid Agora credentials)
curl -X POST http://localhost:3000/api/rtc-sessions \
  -H "Content-Type: application/json" \
  -d '{"app_id":"test","channel":"test","token":"test","host_uid":1}'
```

### Logs

**Docker Compose:**
```bash
docker compose logs -f station-relay-server
docker compose logs -f station-webapp
```

**Kubernetes:**
```bash
kubectl logs -n astation -l app=relay-server -f
kubectl logs -n astation -l app=webapp -f
```

**Systemd:**
```bash
sudo journalctl -u astation-api -f
sudo tail -f /var/log/nginx/access.log
```

## Scaling

### The relay runs as exactly one instance

Do not scale the relay beyond one instance. It keeps state in memory that
every connection for an account must share:

- **Rooms.** An Astation and its Atems meet in an in-memory room keyed by the
  Astation's code. With two instances, an Astation on one and an Atem on the
  other never meet, so chat, remote control and pairing break.
- **The Astation key cache.** Relay identity keys are loaded into memory at
  startup and updated as Astations register (see "Relay identity" above). A
  key registered on one instance is unknown to another, which would treat
  that Astation as unregistered.

Sticky sessions don't fix this: the Astation and its Atems are separate
clients, so a load balancer can send them to different instances. Running
more than one relay would need shared room state and cache invalidation,
which the relay doesn't have.

Postgres data (vault, Atem Memory, keys, bindings) is already shared and
isn't the limit.

**If failover is ever needed** (not built): route by room code. Every relay
WebSocket carries it (`/ws?role=astation&code=<id>`, `/ws?role=atem&code=<id>`),
so nginx can hash on it (`hash $arg_code consistent;`), and send
`/api/pair/:code` the same way. An Astation and its Atems then always reach
the same instance. It still needs two changes:

- every instance learns about key changes (Postgres `LISTEN/NOTIFY`, or a
  rate-limited re-read on a cache miss);
- voice and RTC sessions are routed by their id or moved to Postgres.

This gives failover, since only a failed instance's rooms reconnect, not
more capacity per room. A single relay handles many thousands of idle
WebSockets, so capacity isn't the reason to add one.

### Scaling the webapp

The webapp (nginx plus static files) is stateless and can scale freely:

**Docker Compose:**
```bash
docker compose up -d --scale station-webapp=3
```

**Kubernetes:**
```bash
kubectl scale deployment webapp --replicas=10 -n astation
```

### Load Balancing

Put the load balancer in front of the webapp only; the webapp proxies
`/api/*` and `/ws` to the single relay. Configure health checks on
`/health`.

## Security

1. **HTTPS Required** - Microphone access requires HTTPS (except localhost)
2. **CORS** - Set `CORS_ORIGIN` to the public webapp origin in production
3. **Rate Limiting** - REST APIs are limited per client IP behind the trusted proxy
4. **Firewall** - Restrict access to port 3000 (API should only be accessed via nginx proxy)
5. **Token Validation** - Ensure Agora tokens have appropriate expiry times

## Troubleshooting

**Webapp can't connect to API:**
- Check nginx proxy configuration
- Verify API server is ready: `curl --fail http://localhost:3000/health`
- Check browser console for CORS errors

**Microphone not working:**
- Verify HTTPS is enabled (required for non-localhost)
- Check browser permissions
- Test with: `navigator.mediaDevices.getUserMedia({audio: true})`

**Screen share not displaying:**
- Verify host (Astation app) is sharing screen
- Check Agora console for active users in channel
- Inspect browser console for videoTrack errors

**Docker image pull fails:**
- Authenticate with GitHub Container Registry:
  ```bash
  echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
  ```
- Verify image exists: https://github.com/orgs/Agora-Build/packages

## Updating

```bash
# Pull latest images
docker compose pull

# Restart services. The relay restart drops every WebSocket for a few
# seconds; Astations and Atems reconnect on their own. Vault and Atem Memory
# data is in Postgres and survives.
docker compose up -d

# Verify new version
docker compose logs | grep "version"
```

## Backup

**Back up the relay's Postgres database.** It is the only durable state, and
losing it loses every account's data:

| Table | Holds | If lost |
| --- | --- | --- |
| `vaults`, `vault_entries` | Vault contents and history | Gone for good |
| `memories`, `skill_versions` | Atem Memory: memories and every skill version | Gone from the relay. Each machine still has its latest copy in `~/.config/atem/knowledge.db`, but skill history and anything not yet pulled is lost |
| `astation_keys` | Registered Astation relay keys | Every Astation re-registers on its next connect by trust on first use, which reopens the squatting window (`relay-server/SECURITY.md`) |
| `session_bindings` | Which pairing sessions each Astation authorized | Vault and Memory return 401 until each Astation reconnects and resyncs its sessions |

Everything else (rooms, WebSockets, the key cache) is in memory and rebuilt on
restart.

**On Volumetric (Coolify):** enable scheduled backups on the Postgres resource
the relay's `DATABASE_URL` points to (Coolify → the database → Backups), with
off-server storage (S3-compatible), not just local disk. Test a restore
occasionally.

**Anywhere else:**
```bash
# Daily dump (custom format, compressed)
pg_dump --format=custom --file=station-$(date +%F).dump "$DATABASE_URL"

# Restore into an empty database, then start the relay
pg_restore --clean --if-exists --dbname="$DATABASE_URL" station-YYYY-MM-DD.dump
```

- **Treat backups as sensitive.** Vault entries, memories and skills are
  stored unencrypted, so a backup is readable by anyone who holds it. Encrypt
  backups at rest and restrict who can access them.
- **Restoring an older backup rolls data back** to that point: newer memories
  and skill versions are lost on the relay. Atems still hold their own
  copies, but ops they already sent are not re-sent.
- **Keys and admin resets:** a restore brings back `astation_keys` as of the
  backup. An Astation whose key was reset after the backup is taken is
  rejected until you repeat the admin reset.

## Support

- GitHub Issues: https://github.com/Agora-Build/Astation/issues
- Documentation: See webapp/TESTING.md for testing guide
