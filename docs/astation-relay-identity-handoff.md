# Handoff: Astation relay identity + durable pairing (macOS build)

**For:** an agent or developer on **macOS** with Xcode / Swift 5.9+. The Swift code
below was written on a Linux machine with **no Swift toolchain**. It has been
reviewed carefully by reading, but **it has never been compiled or run.** Your job
is to build it, test it, verify it on a real Mac, and get it released **before**
the relay is deployed.

Status as of 2026-09-30.

---

## 1. Why this exists

The Station relay (`relay-server/`) never verified that a connecting Astation was
genuine. Anyone who knew an Astation's room code (its `astation-<UUID>` id, which
every paired atem stores in `~/.config/atem/config.toml` as `astation_relay_code`)
could connect as that Astation and approve their own session. That gave them the
account's **vault** and **Atem Memory** (memories + skills, and skills are
auto-applied to coding agents). This was `relay-server/SECURITY.md` blocker #1.

Product rule (from the user): **Astation is the control plane.**
- `atem login` unlocks only a limited set of functions.
- Pairing with Astation unlocks the full set: vault, memory, skills and sync.

So Astation must *prove* its identity to the relay. The relay must then learn
"which sessions belong to which Astation" **from the verified Astation**, durably.

### Decisions already made with the user

- **Key:** a P-256 signing key held by Astation, in the Secure Enclave when
  available and a software key otherwise, persisted via the Keychain.
- **First registration:** trust-on-first-use (TOFU). The first key that proves
  possession for an id is registered. A lost or replaced Mac needs an admin reset
  on the relay.
- **Old Astation versions:** they keep relaying chat and remote control, but only
  a **verified** Astation can grant vault/memory access. Users must update.
- **Bindings:** durable, stored in Postgres on the relay, and pushed by the
  verified Astation. They survive relay restarts, cover local-only pairings,
  are revoked when Astation removes a session, and slide on use (7 days).

---

## 2. Where the code is

| Repo / branch | What | Head |
|---|---|---|
| Astation `feat/relay-identity-swift` (this branch) | Swift: identity key + relay protocol + tests + CI step + this doc | `3050545` (+ this doc) |
| Astation `feat/knowledge-sync` | Relay: knowledge-sync endpoints, identity store, proof-of-possession, docs. `feat/relay-identity-swift` was branched from it at `6e2f5d9` | `8729cb8`, relay work complete and reviewed |
| Atem `feat/memory-pairing-auth` | atem client: sync via the pairing session, tier gates, docs | `46f86df` |

Binding plan (all tasks, exact contract): `docs/knowledge-sync-plan.md`. The
relevant part is "Extension: Astation proof-of-possession + durable pairing".
When `feat/knowledge-sync` lands, `relay-server/README.md` documents the exact
frames and acks.

---

## 3. The protocol (exact — the relay depends on it)

All frames are JSON text on the existing **relay identity WebSocket**
(`wss://<relay>/ws?role=astation&code=<astation_id>`).

**Relay → Astation.** Sent raw, immediately after the socket opens:
```json
{"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"<64 lowercase hex>"}
```

**Astation → relay.** The relay intercepts these and never forwards them to
Atems:
```json
{"type":"relayAuth","astation_id":"<room code>","public_key":"<hex>","signature":"<hex>"}
```
- `public_key`: P-256 **X9.63 uncompressed**, 65 bytes, lowercase hex (130
  chars, starts with `04`).
- `signature`: ECDSA over SHA-256, **DER** encoded, lowercase hex.
- Signed message: the UTF-8 string `station-relay-auth-v1\n<challenge>\n<astation_id>`.
  `astation_id` must equal the room `code` of this socket.
- The relay verifies with `ring` `ECDSA_P256_SHA256_ASN1`.

**Relay → Astation:**
```json
{"type":"relayAuthResult","status":"registered|verified|rejected","message":"<text>"}
```

**Only after `registered` or `verified`,** Astation → relay:
```json
{"type":"relaySessions","sessions":["<session_id>", …]}   // full resync, sent after every successful verification (≤ 1000 ids)
{"type":"relayBind","session_id":"<id>"}                  // a session was granted (any path)
{"type":"relayUnbind","session_id":"<id>"}                // a session was deleted or expired
```

**Relay → Astation ack:**
```json
{"type":"relayAck","for":"relaySessions|relayBind|relayUnbind","ok":true|false, …}
```
Astation only checks `ok`.

**Relay rules you'll observe:**
- The challenge must be answered within **10 s**. A wrong or missing proof for
  a registered id gets `rejected`, and the socket is closed.
- A registered id's new connection is **pending**. It does not replace the
  current owner or receive Atem traffic until it verifies.
- Ids with no registered key stay in **legacy mode**: relaying works, but no
  bindings are possible.

---

## 4. What the Swift change does (`feat/relay-identity-swift`)

**Files:**
- `Sources/Menubar/RelayIdentityKey.swift` (new):
  - Loads or creates the key.
  - Keychain generic password: service `build.agora.astation.relay-identity`,
    account `astation-relay-key-v1`, accessible `AfterFirstUnlockThisDeviceOnly`.
  - Prefers a Secure Enclave key (`SecureEnclave.P256.Signing.PrivateKey`),
    created with access control `AfterFirstUnlockThisDeviceOnly` +
    `.privateKeyUsage` so it can sign while the screen is locked. Falls back to
    a software `P256.Signing.PrivateKey`.
  - **A new key is generated ONLY when no Keychain item exists.** If an item
    exists but can't be decoded, loading throws `.undecodableStoredKey`, logs the
    cause, and **never overwrites**. Overwriting a TOFU-registered key would lock
    the Astation out permanently.
  - Provides `publicKeyHex`, `sign(challenge:astationId:)`, and
    `static signingMessage(challenge:astationId:)`.
- `Sources/Menubar/AstationHubManager.swift`:
  - The key is preloaded once on a background queue when the identity relay
    starts. There is **no Keychain work** in the 10 s challenge window.
  - It handles raw `relayAuthChallenge` / `relayAuthResult` / `relayAck` frames
    on the identity socket (frames without `atem_id`/`connection_id` and with a
    known `type`). Atem traffic handling is unchanged.
  - On `registered`/`verified` it marks the socket verified and sends
    `relaySessions` from `SessionStore.getAllActive()`.
  - On `rejected` or a key-load failure it stays in legacy mode and shows a menu
    status:
    - "Relay rejected this Astation's key"
    - "Relay identity key unreadable — relay works, vault/memory unavailable"
  - Frames from a replaced socket are ignored, and the verified state resets on
    disconnect.
- `Sources/Menubar/SessionStore.swift`: grant hooks (`create`, `authenticate`,
  `createOrRefreshLocal`) → `relayBind`. Delete and expiry → `relayUnbind`,
  plus an hourly sweep. Hooks fire on main, outside the store's barrier. This
  covers relay, LAN and local/loopback pairing in one place.
- `Tests/AstationTests/RelayIdentityTests.swift` (new): 17 tests covering:
  - the signing-message format and hex;
  - sign → verify with a software key;
  - load/create with fake storage, including "never replaces an undecodable
    stored key";
  - the four outbound message JSONs;
  - relay message parsing;
  - the SessionStore bind/unbind hooks.
- `.github/workflows/ci.yml`: adds `swift test --filter RelayIdentityTests`
  after the Swift build. **This is the first time CI runs `swift test`**, so the
  whole existing test target must now compile and link.

**APIs that were never compiled (check these first if the build fails):**
- **CryptoKit:**
  - `SecureEnclave.isAvailable`
  - `SecureEnclave.P256.Signing.PrivateKey(accessControl:)` and `(dataRepresentation:)`, plus `.dataRepresentation`
  - `P256.Signing.PrivateKey()` and `(rawRepresentation:)`
  - `.publicKey.x963Representation`
  - `.signature(for:)` → `.derRepresentation`
  - `P256.Signing.PublicKey(x963Representation:)` / `ECDSASignature(derRepresentation:)` / `isValidSignature(_:for:)` (tests)
- **Security:** `SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)`, `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`.
- **Tests:** `@testable import Menubar` and XCTest.

---

## 5. Your tasks (macOS)

### 5.1 Build and unit-test
```bash
git fetch && git checkout feat/relay-identity-swift
swift build -c release
swift test --filter RelayIdentityTests
swift test                      # whole target — see note
```
- **Fix compile errors without changing the protocol** (§3): no field names,
  encodings, the signed-message string, or the Keychain names.
- If unrelated pre-existing tests in `AstationTests` fail to compile or run,
  don't delete them. Fix them if trivial. Otherwise report them and keep the CI
  step scoped to `RelayIdentityTests`.

### 5.2 Run a local relay to test against
Checkout `feat/knowledge-sync` (in another directory or a worktree):
```bash
docker run --rm -d --name station-pg -e POSTGRES_PASSWORD=pw -p 55432:5432 postgres:16
cd relay-server
DATABASE_URL=postgres://postgres:pw@localhost:55432/postgres cargo run --release
# relay listens on :3000 (check main.rs / README for the port)
```
Point Astation at it: `ASTATION_RELAY_URL=http://127.0.0.1:3000 swift run astation`,
or set the relay URL in Settings.

### 5.3 Manual verification checklist (on a real Mac)
1. **First connect:** the relay logs `registered`; `SELECT * FROM astation_keys;` shows one row whose `public_key` equals the app's key.
2. **Restart Astation:** the relay logs `verified`, and the same key is reused (no new row, no Keychain prompt loop).
3. **Pair an atem** (`atem pair`, relay path) and pair one locally: `SELECT * FROM session_bindings;` lists both sessions, including the local-only pairing.
4. **Durability:** restart the relay (keep Postgres). With **no** atem TUI running, `atem memory add "test fact" && atem sync` and `atem vault list` succeed (no 401).
5. **Revocation:** let a session expire, or remove it, and confirm the binding disappears and that atem gets 401.
6. **Locked screen:** lock the Mac, restart the relay, wait more than 30 s, unlock. While it was locked the Astation should have reconnected and verified (check the relay log). Relay chat and remote control must keep working.
7. **Rejection UI:** `DELETE FROM astation_keys` and insert a different key for this id. Astation gets `rejected`, shows "Relay rejected this Astation's key", and relaying falls back to legacy. Then restore it (admin reset = `DELETE FROM astation_keys WHERE astation_id='<id>'`, and the next connect re-registers).
8. **Keychain:** after re-signing or rebuilding the app, note any "Astation wants to use confidential information" prompt. Denying it must leave legacy mode, and the stored key must not be overwritten.
9. **Old relay compatibility:** point the new Astation at the current production relay (`https://station.agora.build`). Everything must work exactly as before. The new code only reacts to `relayAuthChallenge`, which the old relay never sends.

### 5.4 Integrate
- Merge `feat/relay-identity-swift` into `feat/knowledge-sync`, or open a PR from
  it, so the Astation PR contains relay and Swift together. The PR's macOS CI
  (`ci.yml`) must be green.
- Report back: build fixes made, checklist results, and any deviations.

### 5.5 Release (needs the user's go-ahead: it's a public release)
- Releases build from a pushed tag matching `v*` (`.github/workflows/release.yml`).
- **The Astation release must ship BEFORE the relay deploy** (§6).

---

## 6. Deployment order (important)

1. **Ship the Astation update first.** It is inert against the old relay.
2. Users install and launch it. With the old relay it behaves exactly as before.
3. **Then deploy the relay** by merging `feat/knowledge-sync` to Astation `main`.
   `deploy-station.yml` builds GHCR images, deploys relay + webapp via Coolify,
   and verifies `/health` (it now requires `knowledge_store: "postgres"`) and a
   raw `role=astation` WebSocket open.
4. The relay restart makes updated Astations reconnect and **register within
   seconds**. That closes the TOFU window, where someone who knows a room code
   could register first.
5. Un-updated Astations keep relaying but can't grant vault/memory. atem shows:
   "The relay doesn't recognize this machine's Astation session. Make sure your
   Astation (latest version) is running and connected to the relay, then sync
   again. Changes stay queued."

**Rollback caveat:** a relay binary built before migration `0003` fails to start
against a DB that has it (sqlx `VersionMissing`).

**Admin reset** (lost or replaced Mac):
`DELETE FROM astation_keys WHERE astation_id = '<id>';`. The next verified
connect registers the new key. The relay caches keys in memory, so for a
**stolen Mac** restart the relay right after the DELETE; otherwise the old key
keeps verifying. Even then the id is keyless until the new Mac connects, and
whoever connects first registers by TOFU. So have the replacement Mac online
when you reset. Key pinning is a follow-up. The key cache assumes a single
relay instance.

---

## 7. Known limitations and follow-ups (not blockers)

- No in-app "revoke device" action. Revocation currently happens through session
  expiry (Astation's 7-day window). The relay's binding expiry slides on use
  independently.
- A failed key load is retried on every reconnect, about every 30 s. For a legacy
  (file) Keychain ACL prompt this could re-prompt. Consider backing off, or not
  retrying `.undecodableStoredKey`.
- No in-app recovery for an undecodable key. The manual path is to delete the
  Keychain item (`security delete-generic-password -s build.agora.astation.relay-identity -a astation-relay-key-v1`)
  and then do a relay admin reset.
- The menu text says "unreadable" for every key-load failure, including transient
  ones.
- Session squatting remains a residual risk: a verified Astation that learns
  another Astation's UUIDv4 session id before its owner binds it could claim it.
  It needs prior knowledge of that session id.
- Relay-side follow-ups: per-IP rate limits on `/ws`, and isolating each Postgres
  test harness in its own schema.

---

## 8. Contract checklist for reviewers

- [ ] The §3 JSON field names, types, lowercase hex, the `protocol` value and the signed-message string are unchanged.
- [ ] The Keychain service and account names are unchanged.
- [ ] A stored key is never overwritten.
- [ ] No Keychain I/O on main inside the challenge path.
- [ ] `relayBind`/`relayUnbind` are only sent while verified. `relaySessions` is sent after every `registered`/`verified`.
- [ ] Atem traffic handling is unchanged. The new code only reacts to known raw control `type`s.
- [ ] The CI `swift test --filter RelayIdentityTests` step is green.
