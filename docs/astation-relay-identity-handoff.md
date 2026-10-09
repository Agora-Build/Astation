# Relay Identity and Durable Pairing

Reviewed on 2026-10-08 against `main` at `5460de4`. Relay identity is
implemented, built, tested, and deployed. Remaining work lives in the
[current agent handoff](agent-handoff.md). This document preserves the
protocol and operational references from the original implementation handoff.

## Purpose and current behavior

Astation proves possession of a P-256 signing key before it can grant
relay-side vault, memory, and skill access to pairing sessions. The verified
Astation owns the pairing bindings; knowing its room code alone is insufficient
to bind a session.

An identity with a registered key stays pending until its proof verifies.
A wrong proof or a missed authentication deadline is rejected and closed.
A keyless identity can relay in legacy mode, but cannot bind sessions until
its first valid proof registers a key by trust on first use (TOFU). Thus
"legacy mode" is not a fallback guarantee after failure of a registered key.

First-use and session-squatting risks are documented in the
[relay security notes](../relay-server/SECURITY.md).

## Signing key

Implementation: `Sources/Menubar/RelayIdentityKey.swift`.

- Prefer a Secure Enclave P-256 signing key, with software P-256 fallback
  when creating a key.
- Persist in Keychain service `build.agora.astation.relay-identity`,
  account `astation-relay-key-v1`, using
  `AfterFirstUnlockThisDeviceOnly`. The Secure Enclave access control
  includes `.privateKeyUsage`.
- Generate a new key only when the Keychain item does not exist. Read errors,
  an unavailable Secure Enclave for an existing key, and undecodable material
  leave the stored item untouched. Settings > Security can repair an unusable
  key after device-owner authentication and confirmation, using an atomic
  update that refuses to replace a key that has become readable.
- Preload off the main queue before answering challenges. The challenge path
  uses the cached key; a challenge received while loading waits for the result.

The Account Recovery Kit preserves the ID and relay URL, not this signing
key. Account-data encryption uses a separate key and recovery format.
Temporary key-access failures have bounded noninteractive retries; denied,
cancelled, or permanent failures require explicit retry or repair.
See [device key recovery](relay-device-key-recovery.md) for the recovery
pause, trust recovery, and administrator coordination implemented in PR #36.

## Base protocol: relay-auth-1

These are raw JSON text frames on the identity WebSocket:
`wss://<relay>/ws?role=astation&code=<astation_id>`.

Relay to Astation, immediately after the socket opens:

```json
{"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"<64 lowercase hex>"}
```

Astation to relay:

```json
{"type":"relayAuth","astation_id":"<room code>","public_key":"<hex>","signature":"<hex>"}
```

The relay intercepts this frame instead of forwarding it to Atems.

- `astation_id` must equal the socket's room code.
- `public_key` is the X9.63 uncompressed P-256 key: 65 bytes, lowercase hex
  (130 characters, starting with `04`).
- `signature` is DER-encoded ECDSA P-256/SHA-256 over the exact UTF-8 message
  `station-relay-auth-v1\n<challenge>\n<astation_id>`.
- The authentication deadline is 10 seconds. Field names, encodings, signing
  domain, and Keychain names are compatibility contracts.

Relay to Astation:

```json
{"type":"relayAuthResult","status":"registered|verified|rejected","message":"<text>"}
```

Only after `registered` or `verified`, Astation may send:

```json
{"type":"relaySessions","sessions":["<session_id>"]}
{"type":"relayBind","session_id":"<id>"}
{"type":"relayUnbind","session_id":"<id>"}
```

`relaySessions` resynchronizes all active sessions after each successful
verification (at most 1,000 IDs). Grant hooks bind relay, LAN, and loopback
sessions; removal and expiry hooks unbind them. Postgres bindings survive
relay restarts and slide on use for seven days.

The relay acknowledges each operation:

```json
{"type":"relayAck","for":"relaySessions|relayBind|relayUnbind","ok":true}
```

Failed acknowledgements use `ok: false` and may include `message`.
Account grouping and encryption add control frames; their encoders/parsers
are in `RelayIdentityKey.swift`, with relay handlers in
`relay-server/src/relay.rs`.

## Reconnection and revocation

`IdentityRelayReconnectPolicy.swift` supplies prompt, bounded retry after
1012 service restart and jittered exponential backoff after 1013 or ordinary
failures. Missing CFNetwork close codes use the prior verification state.
Successful verification resets the failure count and resynchronizes sessions.
Callbacks and outbound routing check the current socket, so replaced sockets
cannot continue handling traffic.
Recovery saves a pause before replacing or resetting trust in the local key.
It survives relaunch, remains active after rejection, and clears only after
`registered` or `verified` for that recovery operation.

Settings > Security provides removal of another offline device registered
under the same Agora account. Relay removal revokes its signing identity and
sessions, announces the key change to replicas, and disconnects its socket.
This differs from a recovery reset: removal prevents TOFU re-registration.

For a lost or replaced Mac, use the [admin-reset runbook](../DEPLOY.md) and
`station-relay-server admin forget-key <astation_id>`. With `REDIS_URL`,
the reset evicts cached keys and disconnects the verified socket across
replicas. A reset retains bindings and reopens TOFU; coordinate the replacement
Mac's connection because the first valid key to reconnect registers.
Use the runbook rather than the old handoff's SQL-only reset instructions.

## Verification entry points

On macOS, after building the C++ core as described in
[README.md](../README.md):

```bash
swift test --filter "RelayIdentityTests|IdentityRelayReconnectPolicyTests|DeviceAuthenticationTests|RecoveryKitTests"
```

For relay unit and WebSocket tests:

```bash
cargo test --manifest-path relay-server/Cargo.toml
```

See the [relay README](../relay-server/README.md) for the Valkey and Postgres
test setup and a local two-relay environment. Keep failure, revocation, and
restore experiments isolated from the user's production identity. The
[current handoff](agent-handoff.md) lists the specific manual results still
missing; completed build, integration, release, and rollout checklists are
preserved in Git history and the task vault.
