# Handoff for the Astation agent (2026-10-01)

Read this first, then `CLAUDE.md`, `README.md` and `DEPLOY.md`.

## Where things stand

**Production (`https://station.agora.build`) runs two relay replicas on Valkey.**
- `/health` returns `{"redis":"ok","replicas":2,"status":"ok",...}`.
- It runs on Coolify on the "Volumetric" server:

  | Resource | Coolify name | UUID |
  |---|---|---|
  | relay-a | station-relay-server | `oss4444o8ss40ckgwc40og4c` |
  | relay-b | station-relay-b | `am8lrcacts572trbli1bmvnu` |
  | Valkey | station-valkey | `minf9gdzuc2fwzxoq188eiw8` |
  | Postgres | astation-vault-postgres | `ags080m1qwqgkhsq7pu49uwr` |
  | webapp | station-webapp | `c0wwgk4c0owk0w4gsww4k0ss` |

**Recently merged and deployed:**

| PR | Change |
|---|---|
| #19 | Relay knowledge sync and **Astation relay identity**. Astation proves a P-256 key to the relay (`relayAuthChallenge` / `relayAuth`) and pushes durable pairing-session bindings (`relaySessions` / `relayBind` / `relayUnbind`). The Swift side shipped in Astation **v0.4.18 / v0.4.19**. |
| #22 | Relay support for Atem Memory 1.1: fact validity, the `invalidate` op, skill history endpoints, migrations 0004 and 0005. |
| #23 | Relay multi-replica: Valkey shared state, a pub/sub bus between replicas, SIGTERM drain, `/metrics`, connection limits, bounded send queues, and a load-test client in `relay-server/loadtest`. Spec: `docs/specs/2026-09-30-relay-multi-replica.md`. Plan: `docs/plans/2026-09-30-relay-multi-replica-plan.md`. |
| #24, #25 | The deploy workflow takes relay deploy URLs from the `RELAY_DEPLOY_HOOKS` secret (one per line) and deploys them one at a time, with a health check after each. The repo variables `STATION_REQUIRE_REDIS=1` and `STATION_MIN_REPLICAS=2` make the deploy require Redis and both relays. |

**Merging to `main` deploys production.** Ask the user before merging anything.

## Rules that apply here

- Every git commit ends with `🤖 Built with SMT <smt@agora.build>`. Every PR body ends with `Generated with SMT <smt@agora.build>`.
- Use a feature branch and a PR. Don't push to `main`.
- **GitHub CLI:** this machine's shell sets `GH_TOKEN` and `GH_CONFIG_DIR` to an account without write access. Prefix git and gh commands with `env -u GH_TOKEN -u GH_CONFIG_DIR`.
- **Coolify API token:** `https://smt.agora.build/api/v1` takes a write-capable token stored in `../Atem/.env.dev` as `COOLIFY_API_TOKEN="…"`. Strip the quotes, and never print or commit it. Don't change Coolify without the user's approval.
- **Relay code** (`relay-server/`) is Rust edition 2021, so no let-chains. Don't run `cargo fmt` over existing files; it reformats everything and buries the real changes.
- **Relay tests:**
  - `cd relay-server && cargo test`
  - Redis/Valkey suite:
    ```
    docker run --rm -d --name t-valkey -p 56379:6379 valkey/valkey:8
    TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
    docker rm -f t-valkey
    ```
  - Postgres suites: see `relay-server/README.md`.
  - CI runs the Valkey suite on every PR.
- **The Swift app** only builds on macOS. CI (`ci.yml`) builds it and runs `swift test --filter RelayIdentityTests`.

## What the Astation agent should work on

### 1. Check the Astation app against the new relay (do this first)
The relay changed behavior in #23. The macOS app reconnects on any close, but nobody has checked these cases on a real Mac:
- **Close 1012** ("service restart"): sent when a relay drains during a deploy. The app should reconnect promptly and verify again through `relayAuth`.
- **Close 1013** ("try again"): sent when Redis is unavailable, a client is too slow, or a room has too many pending Astations (cap: 2 per room per client IP, 32 per room). The app should reconnect with backoff, not in a tight loop.
- **Being replaced or evicted:** a socket that was replaced (another verified owner took over, or an admin ran `forget-key`) is closed, and anything it sends afterwards is dropped.
- **Key revocation:** `station-relay-server admin forget-key <astation_id>` now also disconnects the live verified session on every replica. On its next connect the Mac registers its key again by trust on first use.

Test against production, or a local two-relay setup per `relay-server/README.md`. Report findings, and fix any reconnect issues in `Sources/Menubar/AstationHubManager.swift`.

### 2. Finish the relay-identity follow-ups
See `docs/astation-relay-identity-handoff.md`. Sections 5.3 and 7 list:
- the manual Mac checklist, whose results were never reported back: first connect, restart, durable bindings, revocation, locked screen, rejection UI, Keychain prompts, compatibility with an old relay;
- an in-app "revoke device" action;
- backoff for key-load retries;
- recovery when the key is undecodable;
- clearer menu text that tells transient failures apart from permanent ones.

### 3. Open operations items (ask the user first)
- relay-a still publishes host port 3000. It's reachable only from the tailnet, but it bypasses Cloudflare and exposes `/metrics`. Decide whether to close it.
- Confirm Valkey has `maxmemory 512mb` and `maxmemory-policy noeviction`. That needs `ssh Volumetric`; the key has a passphrase.
- Delete the old secret `COOLIFY_RELAY_SERVER_WEBHOOK_URL`; nothing reads it now.
- Run the full 30k-socket / 30-minute load test (`relay-server/loadtest/README`) before claiming 10k+ users.

### 4. Parked relay improvements (low priority)
- `TCP_NODELAY` on accepted sockets. There's a roughly 40 ms latency blip at the 60 s ping; p99 is unaffected.
- A room-cache epoch per code instead of one global epoch. Only worth doing if the load test shows cache misses under churn.
- A narrow race between the key-cache placeholder and a concurrent full load. The directory being authoritative already covers the security side.
- Report the build commit in `/health`, so deploys on platforms other than Coolify can confirm the new version is live.

### 5. Future designs (start only when the user asks)
- **Agent-link:** agents on different paired atems message each other through `atem peers`, `atem send` and `atem inbox`. Astation decides which peers may type into an agent. It needs relay support plus an Astation permission UI.
- **Credentials vault:** end-to-end encrypted credential storage, with keys held by Astation. Today's `atem vault` is a plaintext shared notepad and must not hold secrets.

## Related Atem-side state
In the Atem repo, Memory 1.1 is merged (Atem #26) but not released. The last release is v0.6.7, and a release needs the user's go-ahead.
