# Security Analysis: Station Relay Server

## Current Security Status: ✅ PRODUCTION READY (with Cloudflare)

The relay server now includes **rate limiting**, **input validation**, and **CORS policy** protection. When deployed behind Cloudflare Tunnel with HTTPS, it provides adequate security for production use.

---

## ✅ Security Features Implemented

### 1. **Rate Limiting** (Application Level)
- **OTP Validation:** 60 requests/min per IP (burst: 10) - Prevents brute force attacks
- **General API:** 600 requests/min per IP (burst: 20) - Prevents abuse
- **WebSocket:** No rate limit (long-lived connections)

**Endpoints:**
```
POST /api/sessions/:id/grant      → 60/min  (strict - brute force protection)
POST /api/sessions                → 600/min (general)
POST /api/rtc-sessions            → 600/min (general)
POST /api/rtc-sessions/:id/join   → 600/min (general)
POST /api/pair                    → 600/min (general)
```

### 2. **Input Validation**
All user input is validated for length and format:
- **hostname:** 1-255 characters (sessions, pairing)
- **name:** 1-100 characters (RTC join)
- **channel:** 1-64 characters (RTC sessions)
- **app_id:** 1-255 characters (RTC sessions)
- **token:** 1-4096 characters (RTC sessions)

Returns `400 Bad Request` with error details if validation fails.

### 3. **CORS Policy**
- **Default:** `https://station.agora.build` (production)
- **Configurable:** Set `CORS_ORIGIN=*` for development (logs warning)
- **Methods:** GET, POST, DELETE, OPTIONS
- **Credentials:** Enabled (for secure cookies)

### 4. **XSS Protection**
- HTML escaping in all rendered pages (pairing page, auth page)
- URL encoding for deep link parameters

### 5. **Session Management**
- **Auth sessions:** 5-minute expiry, automatic cleanup
- **RTC sessions:** 4-hour expiry, automatic cleanup
- **Pairing rooms:** 10-minute expiry if unpaired
- **Participant limit:** Max 8 users per RTC session

### 6. **Cryptographic Tokens**
- **OTP:** 8-digit random (10^8 combinations)
- **Session tokens:** 64 hex characters (256-bit entropy)
- **Session IDs:** UUID v4 (122-bit entropy)
- **Pairing codes:** 8 chars, no ambiguous characters (0/O, 1/I/L excluded)

### 7. **In-Memory Storage**
- No persistent storage of sensitive data
- Sessions expire automatically
- No data survives server restart

---

## 🔒 Deployment Architecture

### Recommended Setup (with Cloudflare Tunnel)

```
Internet
    ↓
Cloudflare (DDoS protection, HTTPS termination, caching)
    ↓
Cloudflare Tunnel (secure tunnel, no exposed ports)
    ↓
Relay Server (localhost:3000, rate limiting, input validation)
```

**Advantages:**
- ✅ HTTPS automatically managed by Cloudflare
- ✅ DDoS protection included
- ✅ No exposed ports (Tunnel only)
- ✅ Zero-trust network access
- ✅ Free tier available

### Environment Variables

```bash
# CORS origin (required for production)
CORS_ORIGIN=https://station.agora.build

# Port (default: 3000)
PORT=3000

# Log level (default: info)
RUST_LOG=info
```

For development:
```bash
CORS_ORIGIN=*  # Allows all origins, logs warning
```

---

## 🔐 Astation Integration

The relay server provides three services used by the Astation macOS app:

### 1. **Auth Sessions** (Deep Link Authentication)
**Flow:**
```
Astation → POST /api/sessions {hostname} → {id, otp}
         → Opens browser: https://station.agora.build/auth?id={id}&tag={tag}
         → User clicks Grant/Deny
Browser  → POST /api/sessions/{id}/grant {otp} → {token}
Astation → Poll GET /api/sessions/{id}/status → {status: "granted", token}
         → Uses token for authenticated operations
```

**Security:**
- OTP visible only to user (shown on auth page)
- Rate limited: 60 attempts/min per IP
- 5-minute session expiry

### 2. **Pairing (Atem ↔ Astation)**
**Flow:**
```
Atem     → POST /api/pair {hostname} → {code: "ABCD-EFGH"}
         → Opens browser: https://station.agora.build/pair?code=ABCD-EFGH
         → User clicks "Open in Astation"
Astation → Deep link: astation://pair?code=ABCD-EFGH
         → WS /ws?role=astation&code=ABCD-EFGH
Atem     → WS /ws?role=atem&code=ABCD-EFGH
```

**Security:**
- 8-character pairing code (23^8 = 41 billion combinations)
- 10-minute expiry if unpaired
- WebSocket relay (no message inspection by server)

### 3. **RTC Sessions** (Web Sharing)
**Flow:**
```
Astation → Joins RTC channel (channel="room", uid=5678)
         → Generates uid=0 wildcard token (AccessToken2.buildTokenRTC)
         → POST /api/rtc-sessions {app_id, channel, token, host_uid} → {id, url}
         → Copies URL to clipboard
Web User → Opens https://station.agora.build/session/{id}
         → GET /api/rtc-sessions/{id} → {app_id, channel, host_uid}
         → POST /api/rtc-sessions/{id}/join {name} → {app_id, channel, token, uid: 1000}
         → Joins RTC with assigned UID
```

**Security:**
- uid=0 tokens allow any numeric UID (Agora feature)
- Max 8 participants enforced (atomic counter)
- 4-hour session expiry
- Names limited to 100 characters

---

## ⚠️ Remaining Risks

### 1. **OTP Brute Force** (Mitigated)
- **Risk:** 10^8 combinations for 8-digit OTP
- **Mitigation:** Rate limiting (60/min) makes brute force impractical
- **Math:** 100M combinations ÷ 60/min = 27 years per IP
- **Status:** ✅ Acceptable risk

### 2. **Cloudflare Bypass**
- **Risk:** Direct IP access bypasses Cloudflare protection
- **Mitigation:** Use Cloudflare Tunnel (no exposed ports)
- **Status:** ✅ Resolved with Tunnel

### 3. **Session Fixation**
- **Risk:** Attacker provides victim with known session ID
- **Mitigation:** OTP required, 5-minute expiry, UUID v4 IDs
- **Status:** ✅ Low risk

### 4. **Resource Exhaustion**
- **Risk:** Many concurrent sessions/connections
- **Mitigation:** Rate limiting, input validation, session expiry
- **Cloudflare:** Connection limits, DDoS protection
- **Status:** ✅ Mitigated

### 5. **WebSocket Message Injection**
- **Risk:** Malicious messages relayed between Atem/Astation
- **Mitigation:** None (pass-through relay by design)
- **Impact:** Low (endpoints trust each other after pairing)
- **Status:** ⚠️ Acceptable risk (intended behavior)

---

## 📋 Pre-Production Checklist

### Critical (Must Have) ✅ DONE
- [x] **HTTPS** - Deployed behind Cloudflare Tunnel
- [x] **Rate Limiting** - 60/min for OTP, 600/min for general API
- [x] **CORS Policy** - Whitelist station.agora.build
- [x] **Input Validation** - Max lengths enforced
- [x] **XSS Protection** - HTML escaping implemented

### Recommended (Should Have)
- [ ] **Structured Logging** - JSON logs for security events
- [ ] **Monitoring/Alerting** - Prometheus + Grafana or similar
- [ ] **Health Checks** - `/health` endpoint for uptime monitoring
- [ ] **Error Tracking** - Sentry or similar for crash reports

### Optional (Nice to Have)
- [ ] **Admin Dashboard** - View active sessions/connections
- [ ] **Token Revocation API** - Manual session invalidation
- [ ] **Audit Logs** - Track all auth/session operations
- [ ] **2FA for Admin** - TOTP for privileged operations

---

## 🚀 Deployment Steps

### 1. Build Docker Image
```bash
cd relay-server
docker build -t station-relay-server .
```

### 2. Run with Docker Compose
```bash
# docker-compose.yml
services:
  relay-server:
    image: station-relay-server
    environment:
      - RUST_LOG=info
      - PORT=3000
      - CORS_ORIGIN=https://station.agora.build
    ports:
      - "127.0.0.1:3000:3000"  # Only localhost access
    restart: unless-stopped
```

### 3. Configure Cloudflare Tunnel
```bash
# Install cloudflared
brew install cloudflare/cloudflare/cloudflared

# Authenticate
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create station-relay

# Configure tunnel
cat > ~/.cloudflared/config.yml <<EOF
tunnel: <TUNNEL_ID>
credentials-file: ~/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: station.agora.build
    service: http://localhost:3000
  - service: http_status:404
EOF

# Run tunnel
cloudflared tunnel run station-relay
```

### 4. Start Services
```bash
docker compose up -d
cloudflared tunnel run station-relay
```

### 5. Verify
```bash
# Check health
curl https://station.agora.build/api/pair

# Test rate limiting
for i in {1..70}; do
  curl -X POST https://station.agora.build/api/sessions/test/grant -d '{"otp":"12345678"}'
done
# Should see 429 Too Many Requests after 60 requests
```

---

## 📊 Monitoring

### Key Metrics
1. **Request Rate** - Requests/min by endpoint
2. **Error Rate** - 4xx/5xx responses
3. **Auth Success Rate** - Grant approvals vs denials
4. **Session Count** - Active auth/RTC sessions
5. **WebSocket Connections** - Active relay connections

### Logging
```bash
# Enable structured logging
RUST_LOG=info cargo run

# Example logs:
[INFO] Pair room created: ABCD-EFGH
[INFO] Join request for session abc-123: current participants = 3, name = Alice
[WARN] Session xyz-789 is full (8 participants)
```

### Alerts
- **Auth failures > 100/min** - Possible brute force attack
- **Session creation > 1000/hour** - Resource abuse
- **Error rate > 5%** - System issues
- **Memory usage > 80%** - Memory leak or high load

---

## 🔧 Troubleshooting

### CORS Errors
```
Access to fetch at 'https://station.agora.build/api/...' from origin 'https://other-domain.com' has been blocked by CORS policy
```

**Fix:** Check `CORS_ORIGIN` environment variable:
```bash
# Should be:
CORS_ORIGIN=https://station.agora.build

# Not:
CORS_ORIGIN=*  # Only for development!
```

### Rate Limiting Errors
```
HTTP 429 Too Many Requests
```

**Normal:** Client hit rate limit (60 or 600 req/min)
**Fix:** Add exponential backoff in client code

### Input Validation Errors
```
HTTP 400 Bad Request
{"error": "Validation error: hostname: length must be between 1 and 255"}
```

**Fix:** Truncate input before sending:
```swift
let hostname = String(hostName.prefix(255))
```

---

## 🎯 Production Readiness Score

| Category | Score | Notes |
|----------|-------|-------|
| Authentication | ✅ 9/10 | OTP with rate limiting, session expiry |
| Authorization | ⚠️ 6/10 | No auth on RTC session creation (intended) |
| Input Validation | ✅ 10/10 | All inputs validated with max lengths |
| Rate Limiting | ✅ 10/10 | Strict (60/min) + general (600/min) |
| CORS | ✅ 10/10 | Configurable, whitelisted by default |
| XSS Protection | ✅ 10/10 | HTML escaping + URL encoding |
| Data Privacy | ✅ 10/10 | In-memory only, auto-expiry |
| Monitoring | ⚠️ 5/10 | Basic logging, no structured metrics |
| Logging | ⚠️ 6/10 | tracing enabled, no audit logs |

**Overall: ✅ 8.5/10 - PRODUCTION READY with Cloudflare**

---

## 📞 Support

- **Documentation:** See `DEPLOY.md` for deployment guide
- **Issues:** GitHub Issues (include logs + environment details)
- **Security:** Email security@agora.build for vulnerabilities
