# Relay Server Session Support - TODO

## Current Status

✅ **Infrastructure Complete:**
- `session_verify.rs`: Caching layer for session validation (8 tests)
- `SessionVerifyCache` added to `AppState`
- Astation handles `session_verify_request` messages
- Background cleanup task for cache

❌ **Integration Incomplete:**
- Relay doesn't use the verification infrastructure yet
- Current relay only supports pairing-code-based rooms
- WebSocket message-based session auth not integrated

---

## Problem Statement

**Current relay architecture:**
```
1. Both Atem and Astation connect with ?role=X&code=Y
2. Relay creates room based on code
3. Messages forwarded bidirectionally
4. Simple pairing flow
```

**Universal session requirement:**
```
1. Atem connects to relay (needs to find correct Astation)
2. Atem sends session-based auth message (no pre-shared code)
3. Relay needs to:
   - Route Atem to correct Astation
   - Verify session is valid
   - Forward messages once authenticated
```

**Key challenge:** Without a pre-shared pairing code, how does Atem know which "room" to join to reach the correct Astation?

---

## Proposed Solutions

### Solution 1: Use astation_id as Room Code (RECOMMENDED)

**Concept:** The `astation_id` serves as the room identifier.

**Flow:**
```
1. Astation connects: ?role=astation&code=<astation_id>
   - Creates or joins room with ID = astation_id
   - Relay knows this Astation is available

2. Atem connects: ?role=atem&code=<astation_id>
   - Atem gets astation_id from local config or discovery
   - Joins the same room
   - Relay pairs them

3. Auth happens via messages:
   - Atem → { status: "auth", session_id: "..." }
   - Relay forwards to Astation
   - Astation validates (using SessionStore)
   - Astation → { status: "authenticated" } or error
   - Relay forwards to Atem

4. If session invalid:
   - Astation → { status: "error", message: "Session expired" }
   - Atem falls back to pairing
   - User approves on Astation
   - New session created
```

**Atem config:**
```toml
# Atem knows which Astation to connect to
astation_relay_code = "astation-abc123-def456..."  # The astation_id

# OR discover via DNS/mDNS/API
# astation_relay_url = "https://station.agora.build"
# relay auto-discovers astation_id from Astation
```

**Advantages:**
- ✅ Minimal changes to relay architecture
- ✅ Works with existing room-based pairing
- ✅ Session auth happens transparently (forwarded messages)
- ✅ Fallback to pairing still works

**Implementation:**
1. Update Atem config to include `astation_id` for relay connections
2. Atem uses `astation_id` as the code when connecting to relay
3. Astation also uses its own `astation_id` as code
4. No relay code changes needed (just message forwarding)!

**Files to modify:**
- Atem `src/config.rs`: Add `relay_astation_id` config
- Atem `src/websocket_client.rs`: Use `astation_id` as code for relay
- Astation `AstationApp.swift`: Connect to relay with `astation_id` as code

### Solution 2: Relay-Managed Session Verification

**Concept:** Relay actively verifies sessions with Astation.

**Flow:**
```
1. Astation connects first (any unique code or its astation_id)
2. Relay remembers which Astation is at which code

3. Atem connects without code: ?role=atem (no code)
   - Relay accepts connection, waits for auth message

4. Atem → { status: "auth", session_id: "...", astation_id: "..." }
   - Relay extracts astation_id from message
   - Relay finds Astation by astation_id
   - Relay checks SessionVerifyCache

5. If not cached:
   - Relay → Astation: { status: "session_verify_request", session_id, request_id }
   - Astation validates SessionStore
   - Astation → Relay: { status: "session_verify_response", valid: true/false }
   - Relay caches result (5 min TTL)

6. If valid:
   - Relay pairs Atem with Astation
   - Messages forwarded bidirectionally

7. If invalid:
   - Relay → Atem: { status: "error", message: "Session invalid" }
   - Atem falls back to pairing
```

**Advantages:**
- ✅ No need for Atem to know astation_id in advance
- ✅ Relay can enforce session validation
- ✅ Works with dynamic Astation discovery

**Disadvantages:**
- ❌ Requires significant relay code changes
- ❌ Relay needs to understand message protocol
- ❌ More complex state management

**Implementation:**
1. Update relay `/ws` handler to allow connections without code
2. Add message interception for auth messages
3. Implement session verification with Astation
4. Cache validation results
5. Dynamic room creation based on astation_id

**Files to modify:**
- `relay-server/src/relay.rs`: Major refactor
  - Support connections without code parameter
  - Intercept and parse auth messages
  - Implement verification protocol
  - Dynamic room management
- `relay-server/src/main.rs`: Already done ✅
- `relay-server/src/session_verify.rs`: Already done ✅

### Solution 3: Pure Proxy Mode (SIMPLEST)

**Concept:** Relay is a dumb pipe, no session awareness.

**Flow:**
```
1. Atem and Astation agree on a shared secret (pairing code or astation_id)
2. Both connect with ?code=<shared-secret>
3. Relay just forwards all messages
4. Session auth happens end-to-end (Atem ↔ Astation)
5. Relay doesn't know or care about sessions
```

**This is essentially Solution 1** with the astation_id as the shared secret.

**Advantages:**
- ✅ Zero relay changes needed
- ✅ Relay stays simple
- ✅ Session management entirely on endpoints

**Disadvantages:**
- ❌ Atem needs to know astation_id (config or discovery)
- ❌ No relay-side session enforcement

---

## Recommendation

**Use Solution 1 (astation_id as room code)** because:
1. ✅ Works with existing relay architecture (zero relay changes)
2. ✅ Simple and maintainable
3. ✅ Session auth happens transparently
4. ✅ Fallback to pairing works
5. ✅ Can be implemented quickly

**Implementation checklist:**

### Atem Changes
- [ ] Add `relay_astation_id` to `config.toml`
  ```toml
  astation_ws = "ws://127.0.0.1:8080/ws"  # Direct connection
  astation_relay_url = "https://station.agora.build"
  astation_relay_code = "astation-abc123..."  # The astation_id for relay routing
  ```

- [ ] Update `src/websocket_client.rs`
  ```rust
  // When connecting to relay, use astation_id as code
  let relay_url = if let Some(code) = &config.astation_relay_code {
      format!("{}?role=atem&code={}", relay_base, code)
  } else {
      // Fallback: try to discover astation_id
      // Or error: "relay_astation_id not configured"
  };
  ```

### Astation Changes
- [ ] Update relay connection to use `astation_id` as code
  ```swift
  // In relay connection logic
  let relayUrl = "wss://station.agora.build/ws?role=astation&code=\(AstationIdentity.shared.id)"
  ```

### Testing
- [ ] Atem → Local Astation: Already works ✅
- [ ] Atem → Relay → Astation: Test with astation_id as code
- [ ] Session-based auth through relay
- [ ] Pairing fallback through relay
- [ ] Multiple Atem instances to same Astation via relay

---

## Alternative: Implement Solution 2 Later

If we want relay-managed verification (Solution 2) later for better security/control:

**Phase 1 (Now):** Use Solution 1 (astation_id as code) - works immediately
**Phase 2 (Future):** Add Solution 2 (relay verification) - enhanced security

This gives us:
- ✅ Working universal sessions through relay NOW
- 🔄 Enhanced relay verification LATER (optional)

---

## Summary

**Current blocker:** Relay needs a way to pair Atem with the correct Astation.

**Quick solution:** Use `astation_id` as the pairing code (Solution 1).
- Zero relay changes
- Just config updates on Atem and Astation
- Works with existing message forwarding

**Next steps:**
1. Add `astation_relay_code` to Atem config
2. Update Atem to use code when connecting to relay
3. Update Astation to connect to relay with its `astation_id` as code
4. Test end-to-end

**Estimated time:** 1-2 hours (not 1-2 days!)

---

## Files Ready

✅ `relay-server/src/session_verify.rs` - Caching infrastructure
✅ `relay-server/src/main.rs` - SessionVerifyCache in AppState
✅ `AstationWebSocketServer.swift` - Handles verification requests

**These are ready for Solution 2 if we go that route later.**

For Solution 1, we don't need any relay changes - just Atem and Astation config updates.
