# Webapp Testing Guide

## Quick Start

```bash
cd webapp
docker compose up
```

Then open: http://localhost:8080

## Testing Screen Share & Microphone

### 1. Create a Test RTC Session

```bash
# Create a session with a test token (uid=0 wildcard)
curl -X POST http://localhost:8080/api/rtc-sessions \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "your_agora_app_id",
    "channel": "test-channel",
    "token": "your_uid0_token",
    "host_uid": 5678
  }'

# Response example:
# {
#   "id": "abc-123",
#   "url": "https://station.agora.build/session/abc-123"
# }
```

### 2. Open the Webapp

Visit: `http://localhost:8080/session/abc-123`

**Expected behavior:**
1. Loading screen appears
2. Name dialog shows with channel info
3. Enter your name → Click "Join"
4. Main app loads with:
   - Video area (waiting for screen share placeholder)
   - Sidebar with participant list
   - Bottom bar with mic toggle and leave button

### 3. Test Microphone

**Prerequisites:** Browser must have microphone permission

1. Click the microphone icon in the bottom bar
2. Grant microphone access if prompted
3. Icon should show as "on" (unmuted)
4. Click again to mute → icon changes to "off" with slash

**Verify:**
- Green indicator appears next to your name in participant list
- Clicking mic button toggles muted/unmuted state
- Audio track is published to RTC channel

### 4. Test Screen Share Display

**Prerequisites:** Host must be sharing screen via Astation

When the host (Astation) starts screen sharing:
1. Placeholder "Waiting for screen share..." disappears
2. Screen content appears in the large video area
3. Video track is subscribed and rendered

**Agora Web SDK behavior:**
- Subscribes to remote video tracks automatically
- Calls `user.videoTrack.play(videoMain)` to render
- Handles unpublish event (shows placeholder again)

## Architecture

```
Web Browser
  ↓ GET /session/abc-123
Nginx (port 80)
  ↓ /api/* → proxy to ${STATION_RELAY_UPSTREAM}
  ↓ /session/* → serve index.html (SPA)
API Server (port 3000)
  ↓ Rust Axum + RTC Session Store
  ↓ Returns: app_id, channel, token (uid=0), uid (1000+)
Agora Web SDK 4.x
  ↓ client.join(app_id, channel, token, uid)
  ↓ Subscribe to host's video (screen share)
  ↓ Publish local audio (microphone)
```

## Token Flow

1. **Host creates session** → POST /api/rtc-sessions with uid=0 wildcard token
2. **Web user joins** → POST /api/rtc-sessions/:id/join
3. **API assigns unique UID** → 1000, 1001, 1002, ... (atomic counter)
4. **Web SDK joins** → Uses uid=0 token with assigned numeric UID
5. **Agora validates** → uid=0 tokens accept any numeric UID

## Troubleshooting

**Session not found:**
- Check session ID in URL matches API response
- Sessions expire after 4 hours

**Microphone permission denied:**
- Check browser console for errors
- Ensure HTTPS in production (localhost HTTP is OK)
- Grant permission in browser settings

**Screen share not showing:**
- Verify host (Astation) is sharing screen
- Check Agora console for active users in channel
- Open browser console → look for videoTrack.play() errors

**CORS errors:**
- API server has CORS enabled for all origins
- Nginx proxies /api/* to avoid CORS issues

**Could not connect to server (Astation create link):**
- Ensure webapp can reach relay via `STATION_RELAY_UPSTREAM`.
- For separate containers in Coolify, set e.g. `STATION_RELAY_UPSTREAM=10.0.0.1:3000`.
- Validate from webapp container: `wget -qO- http://$STATION_RELAY_UPSTREAM/api/rtc-sessions` (should return 405/404, not DNS/connect error).

## Production Deployment

**Environment variables:**
- `PORT=3000` (API server)
- `RUST_LOG=info` (API server logging)
- `STATION_RELAY_UPSTREAM=<relay-host>:3000` (webapp nginx upstream)

**Docker compose production:**
```yaml
services:
  webapp:
    image: ghcr.io/agora-build/station-webapp:latest
    ports:
      - "80:80"
    environment:
      - STATION_RELAY_UPSTREAM=relay-server:3000
    depends_on:
      - relay-server
  relay-server:
    image: ghcr.io/agora-build/station-relay-server:latest
    environment:
      - RUST_LOG=info
      - PORT=3000
```

**Security notes:**
- Use HTTPS in production (required for mic access on non-localhost)
- Tokens should expire appropriately (set in Astation)
- Sessions auto-cleanup after 4 hours
- Rate limiting recommended for /api/rtc-sessions endpoints

## Key Features Implemented

✅ **Screen Share Display**
- Subscribes to remote video tracks (host's screen share)
- Renders in large video area
- Placeholder shown when no video
- Auto-switches when host starts/stops sharing

✅ **Microphone Publishing**
- Creates local audio track on join
- Publishes to RTC channel
- Toggle mute/unmute with button
- Visual indicator in participant list
- Handles permission denials gracefully

✅ **User Identity Persistence**
- Saves name to localStorage
- Pre-fills on return visits
- 7-day expiry for inactive users

✅ **Session Management**
- URL-based session routing (/session/:id)
- API verification before showing UI
- Unique UID assignment (1000+)
- Participant tracking with display names

✅ **Codec Fallback**
- Tries AV1 first (best quality)
- Falls back to VP8 if AV1 fails
- Configurable via codec.js module
