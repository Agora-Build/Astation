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
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/pair"]
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
  replicas: 2
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
            path: /api/pair
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
curl http://localhost:3000/api/pair

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

### Horizontal Scaling

**Docker Compose:**
```bash
docker compose up -d --scale station-relay-server=3 --scale station-webapp=3
```

**Kubernetes:**
```bash
kubectl scale deployment relay-server --replicas=5 -n astation
kubectl scale deployment webapp --replicas=10 -n astation
```

### Load Balancing

The API server is stateless except for in-memory session stores. For multi-instance deployments, consider:

1. **Session affinity** - Use sticky sessions for WebSocket connections
2. **Redis store** - Replace in-memory stores with Redis for shared state
3. **Health checks** - Configure load balancer health checks on `/api/pair`

## Security

1. **HTTPS Required** - Microphone access requires HTTPS (except localhost)
2. **CORS** - API allows all origins by default (consider restricting in production)
3. **Rate Limiting** - Add rate limiting for `/api/rtc-sessions` endpoints
4. **Firewall** - Restrict access to port 3000 (API should only be accessed via nginx proxy)
5. **Token Validation** - Ensure Agora tokens have appropriate expiry times

## Troubleshooting

**Webapp can't connect to API:**
- Check nginx proxy configuration
- Verify API server is running: `curl http://localhost:3000/api/pair`
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

# Restart services (zero-downtime with multiple replicas)
docker compose up -d

# Verify new version
docker compose logs | grep "version"
```

## Backup

The API server stores data in-memory only. Sessions expire after 4 hours. No backup needed for stateless services.

## Support

- GitHub Issues: https://github.com/Agora-Build/Astation/issues
- Documentation: See webapp/TESTING.md for testing guide
