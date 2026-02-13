# Security Analysis: Station Relay Server & Webapp

## Executive Summary

**Current Security Status:** ⚠️ **NOT PRODUCTION READY**

The relay server and webapp have basic security measures but require significant hardening before going live. Critical gaps exist in authentication, rate limiting, input validation, and operational security.

## Security Assessment

### ✅ Currently Implemented

1. **XSS Protection**
   - HTML escaping in pairing pages (just fixed!)
   - URL encoding for deep links

2. **Session Management**
   - 5-minute expiry for auth sessions
   - 4-hour expiry for RTC sessions
   - Automatic cleanup of expired sessions
   - 8-person limit per RTC session

3. **Token Generation**
   - Cryptographically random OTPs (8 digits)
   - Cryptographically random session tokens (64 hex chars)
   - UUID v4 for session IDs

4. **Data Storage**
   - In-memory only (no persistent storage of sensitive data)
   - Automatic expiry prevents data accumulation

### ⚠️ Major Security Gaps

#### 1. **No HTTPS Enforcement**
- **Risk:** All traffic is HTTP, exposing tokens and credentials
- **Impact:** Man-in-the-middle attacks, credential theft
- **Mitigation:** Deploy behind TLS-terminating reverse proxy (Caddy, Nginx with Let's Encrypt)
- **Status:** CRITICAL - MUST FIX BEFORE PRODUCTION

#### 2. **No Rate Limiting**
- **Risk:** Brute force attacks on OTPs (8 digits = 100M combinations)
- **Impact:** Account takeover, resource exhaustion
- **Mitigation:** Add rate limiting middleware (10 attempts per IP per hour)
- **Example Attack:**
  ```bash
  # Attacker can try all OTPs without throttling
  for otp in {10000000..99999999}; do
    curl -X POST http://relay/api/sessions/$ID/grant -d "{\"otp\":\"$otp\"}"
  done
  ```
- **Status:** CRITICAL - MUST FIX BEFORE PRODUCTION

#### 3. **No Input Validation Limits**
- **Risk:** Hostname/name fields have no length limits
- **Impact:** Resource exhaustion, denial of service
- **Mitigation:** Add max length validation (hostname: 255, name: 100)
- **Status:** HIGH PRIORITY

#### 4. **No CORS Policy Enforcement**
- **Risk:** Any website can call your API
- **Impact:** CSRF attacks, unauthorized access
- **Mitigation:** Configure CORS to whitelist only your domain
- **Status:** HIGH PRIORITY

#### 5. **No Authentication for API Endpoints**
- **Risk:** Anyone can create RTC sessions without auth
- **Impact:** Resource abuse, unauthorized usage
- **Endpoints at risk:**
  - `POST /api/rtc-sessions` (no auth check)
  - `POST /api/pair` (no auth check)
- **Mitigation:** Require session token for RTC session creation
- **Status:** MEDIUM PRIORITY

#### 6. **WebSocket Relay Has No Message Validation**
- **Risk:** Malicious messages can be relayed between clients
- **Impact:** Command injection, protocol abuse
- **Mitigation:** Validate message format, size limits (max 64KB)
- **Status:** MEDIUM PRIORITY

#### 7. **No Logging/Monitoring**
- **Risk:** No audit trail for security incidents
- **Impact:** Cannot detect or investigate attacks
- **Mitigation:** Add structured logging for all auth events
- **Status:** MEDIUM PRIORITY

### 🔒 Additional Security Hardening Needed

#### 1. **Session Security**
- [ ] Add session token rotation on grant
- [ ] Implement token revocation mechanism
- [ ] Add IP address binding to prevent token theft
- [ ] Implement device fingerprinting

#### 2. **Input Validation**
```rust
// Current: No validation
pub struct CreateRtcSessionRequest {
    pub app_id: String,  // Could be 1GB string!
    pub channel: String,
    pub token: String,
    pub host_uid: u32,
}

// Needed: Validated input
pub struct CreateRtcSessionRequest {
    #[validate(length(min = 1, max = 255))]
    pub app_id: String,
    #[validate(length(min = 1, max = 64))]
    pub channel: String,
    #[validate(length(min = 1, max = 4096))]
    pub token: String,
    pub host_uid: u32,
}
```

#### 3. **Rate Limiting Implementation**
```rust
use tower_governor::{governor::GovernorConfigBuilder, GovernorLayer};

// Add to main.rs
let governor_conf = Box::new(
    GovernorConfigBuilder::default()
        .per_second(10)
        .burst_size(20)
        .finish()
        .unwrap(),
);

let app = Router::new()
    .route("/api/sessions/:id/grant", post(grant_session_handler))
    .layer(GovernorLayer { config: governor_conf });
```

#### 4. **CORS Configuration**
```rust
use tower_http::cors::{CorsLayer, AllowOrigin};

let cors = CorsLayer::new()
    .allow_origin(AllowOrigin::exact("https://station.agora.build".parse().unwrap()))
    .allow_methods([Method::GET, Method::POST, Method::DELETE])
    .allow_headers([header::CONTENT_TYPE]);

let app = Router::new()
    .route(...)
    .layer(cors);
```

#### 5. **Security Headers**
```nginx
# Add to nginx.conf
add_header X-Frame-Options "DENY";
add_header X-Content-Type-Options "nosniff";
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy "strict-origin-when-cross-origin";
add_header Content-Security-Policy "default-src 'self'; script-src 'self' https://download.agora.io; connect-src 'self' wss://station.agora.build;";
```

## Specific Vulnerabilities Found During Testing

### 1. XSS in Pairing Page (FIXED ✅)
- **Vulnerability:** Unescaped hostname in HTML rendering
- **Attack Vector:** `hostname: "<script>alert('xss')</script>"`
- **Fix:** Added `html_escape()` function to escape HTML entities
- **Test:** `test_pair_page_xss_protection`

### 2. No Participant Limit Enforcement (FIXED ✅)
- **Vulnerability:** No hard limit on RTC session participants
- **Attack Vector:** Join 1000+ users to exhaust resources
- **Fix:** Enforced 8-person limit with atomic counter
- **Test:** `test_join_session_full_handler`

## Webapp Security Concerns

### 1. No Content Security Policy
- **Risk:** XSS attacks can load external scripts
- **Fix:** Add CSP headers to restrict script sources

### 2. localStorage for User Identity
- **Risk:** XSS can steal user names from localStorage
- **Impact:** Low (only display names, no credentials)
- **Mitigation:** Acceptable risk, but document clearly

### 3. No Microphone Permission Verification
- **Risk:** Webapp assumes mic permission is granted
- **Fix:** Add error handling for permission denials

## Pre-Production Checklist

### Critical (Must Have)
- [ ] **Enable HTTPS** - Deploy behind reverse proxy with TLS
- [ ] **Implement Rate Limiting** - Prevent brute force attacks
- [ ] **Set CORS Policy** - Restrict API access to your domain
- [ ] **Input Validation** - Add length limits on all fields
- [ ] **Add Health Checks** - Monitor service availability

### High Priority
- [ ] **Session Token Rotation** - Rotate tokens on grant
- [ ] **IP Binding** - Tie sessions to source IP
- [ ] **Structured Logging** - Log all security events
- [ ] **Error Message Sanitization** - Don't leak internal info
- [ ] **Dependency Audit** - Run `cargo audit` regularly

### Medium Priority
- [ ] **WebSocket Message Validation** - Limit message size/format
- [ ] **Token Revocation API** - Allow manual token invalidation
- [ ] **Admin Dashboard** - Monitor active sessions
- [ ] **Alerting** - Notify on suspicious activity

### Optional Enhancements
- [ ] **2FA for Auth Sessions** - Add TOTP support
- [ ] **Captcha** - Add to prevent automated abuse
- [ ] **Geofencing** - Restrict access by region
- [ ] **Penetration Testing** - Hire security firm for audit

## Deployment Security

### Recommended Architecture
```
Internet
    ↓
Cloudflare/CDN (DDoS protection)
    ↓
Load Balancer (AWS ALB / GCP Load Balancer)
    ↓
Caddy/Nginx (TLS termination, rate limiting)
    ↓
Docker Containers (relay-server, webapp)
    ↓
Container Network (isolated)
```

### Environment Variables (Secrets)
```bash
# NEVER commit these to git!
AGORA_APP_ID=secret
AGORA_APP_CERTIFICATE=secret
SESSION_ENCRYPTION_KEY=random-32-bytes
ADMIN_API_KEY=random-32-bytes
```

### Firewall Rules
```bash
# Only allow HTTPS and SSH
ufw default deny incoming
ufw default allow outgoing
ufw allow 443/tcp  # HTTPS
ufw allow 22/tcp   # SSH (restrict to your IP only!)
ufw enable
```

## Monitoring & Incident Response

### Metrics to Monitor
1. **Auth failures per minute** - Detect brute force
2. **Session creation rate** - Detect abuse
3. **WebSocket connections** - Detect DoS
4. **RTC session participants** - Detect limit bypass
5. **Error rates** - Detect attacks or bugs

### Alerting Thresholds
- Auth failures > 100/min → Page on-call
- Session creation > 1000/hour → Page on-call
- WebSocket connections > 10,000 → Page on-call
- Error rate > 5% → Page on-call

## Legal & Compliance

### Data Privacy
- **No GDPR/CCPA compliance** - No user data stored beyond session lifetime
- **No cookies** - Session tokens only
- **No analytics** - No tracking

### Terms of Service
- Add rate limit disclosure
- Add abuse policy
- Add DMCA agent info (if applicable)

## Conclusion

**Verdict:** The relay server and webapp have a solid foundation but are **NOT secure enough for production** without the critical fixes listed above.

**Timeline to Production:**
- **1 week:** Implement HTTPS, rate limiting, CORS, input validation
- **2 weeks:** Add logging, monitoring, session security
- **3 weeks:** Security audit, penetration testing
- **4 weeks:** Ready for limited production (invite-only)
- **6 weeks:** Ready for public launch

**Estimated Cost:**
- Development: 40-60 hours
- Security audit: $5,000-$10,000
- Infrastructure: $100-500/month

**Risk Level Without Fixes:**
- **Critical:** Token theft, credential leakage (no HTTPS)
- **High:** Account takeover (no rate limiting)
- **Medium:** Resource exhaustion (no input validation)

**Recommendation:** Do NOT deploy to production until at least the "Critical" and "High Priority" items are addressed.
