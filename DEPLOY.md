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

### Running several relays (any platform)

The relay can run as several identical replicas behind the webapp's nginx.
Nothing in the relay or the deploy workflow is tied to Coolify; any platform
that can run a Docker image and redeploy it from a webhook works. The relays
need:

- **The same image**: `ghcr.io/agora-build/station-relay-server:main` (or one
  `:sha-<commit>` tag) on every replica, with the same environment.
- **Shared state**: the same Postgres `DATABASE_URL` (durable data) and the
  same Valkey/Redis `REDIS_URL` (live rooms, sessions, cross-replica frames;
  see "Relay replicas and Valkey" below), plus
  `RELAY_REPLICAS_EXPECTED=<number of relays>` (above 1 the relay refuses to
  start without `REDIS_URL`).
- **One DNS name for all of them**: nginx reaches the relays through
  `STATION_RELAY_UPSTREAM` (`<name>:3000`) and re-resolves `<name>` every
  10 s, spreading requests over every address it returns. The name must
  resolve to every relay (a shared Docker network alias, a headless service,
  round-robin DNS). A relay the name doesn't resolve to still counts in
  `/health`'s `"replicas"` (presence is in Valkey) but never gets traffic.
- **SIGTERM to stop**: the relay drains on SIGTERM (see "Shutdown" below), so
  the platform should send SIGTERM and allow about 15 s before SIGKILL.
- **A health check** on `GET /health`, port 3000, so the platform keeps the old
  container serving until the new one is healthy.

**Deploy hooks.** The workflow deploys relays from the GitHub Actions secret
`RELAY_DEPLOY_HOOKS`: the relays' deploy webhook URLs, **one per line** (blank
lines and surrounding whitespace are ignored), deployed **in that order**,
one at a time (`.github/scripts/deploy-relays.mjs`). For each hook:

1. trigger it. With the `COOLIFY_API_TOKEN` secret set, every hook must be a
   Coolify `/api/v1/deploy?uuid=...` URL (all lines are checked before any is
   triggered): it is called with the token and the workflow waits until that
   Coolify deployment has finished. Without the
   token the hook gets a plain `POST` (the shape most platforms' deploy hooks
   accept) and the workflow does not wait for the platform;
2. wait until `/health` is healthy (as `verify-station.mjs --wait-health`,
   honoring `STATION_REQUIRE_REDIS` and `STATION_MIN_REPLICAS`) before
   triggering the next hook, so the other relays keep serving while one
   restarts.

Any failure stops the run: later hooks are not triggered and keep serving the
previous image. Hook URLs are masked in the logs and the script never prints
them; it refers to them as "relay hook 1/N".

Without the Coolify token the workflow can't see the platform's deploy, so
the health wait right after a trigger can pass against the old, still-healthy
container while the new one is still starting. On other platforms rely on the
platform's own rolling deploy and health check (it keeps the old container
until the new one passes `/health`), or use a hook that returns only once the
deploy is done. A possible improvement: have `/health` report the running
commit, so the workflow can wait until that relay serves this run's commit.

`RELAY_DEPLOY_HOOKS` is required: if it is empty or unset the run fails
before calling anything. One relay is one line.

The deploy job's `timeout-minutes` (90) fits three relay hooks. Each hook can
take about 20 minutes (Coolify wait up to 15, health wait up to 3) and the
webapp plus the final check about 30 more, so raise it in
`.github/workflows/deploy-station.yml` before adding a fourth relay
(about 20 × hooks + 30).

### Station on Volumetric (Coolify)

This is the production setup, and a worked example of the section above.

Every push to `main` runs `.github/workflows/deploy-station.yml`. It builds both
Linux AMD64 images, publishes `:main` and `:sha-<commit>` tags to GHCR, then
deploys one application at a time, waiting for each Coolify deployment to
finish:

1. each relay in `RELAY_DEPLOY_HOOKS` order (relay-a, then relay-b), waiting
   after each until `https://station.agora.build/health` is healthy (polled
   every 5 s, up to 36 times);
2. the webapp;
3. the final check: public HTTPS, a healthy `/health` (Postgres knowledge
   store; Redis `ok` and at least `STATION_MIN_REPLICAS` live replicas when
   those checks are switched on, see below), and an identity WebSocket
   connection to `wss://station.agora.build/ws`.

The workflow can also be run manually on `main` from GitHub Actions.

Release tags continue to publish versioned and `:latest` images and the macOS
installer. They do not deploy production; Coolify tracks `:main` so publishing
an older release tag cannot roll production back.

The Coolify resources on Volumetric are:

| Resource | Coolify UUID | Image | Host port |
| --- | --- | --- | --- |
| Relay A (`relay-a`, the original relay) | `oss4444o8ss40ckgwc40og4c` | `ghcr.io/agora-build/station-relay-server:main` | `3000` |
| Relay B (`relay-b`) | set when created | `ghcr.io/agora-build/station-relay-server:main` | none |
| Valkey (relay live state) | set when created | `valkey/valkey:8` | none |
| Webapp | `c0wwgk4c0owk0w4gsww4k0ss` | `ghcr.io/agora-build/station-webapp:main` | `3010` |

Required GitHub Actions secrets:

- `COOLIFY_API_TOKEN`: Coolify token with `deploy` and `read` permissions.
- `RELAY_DEPLOY_HOOKS`: the relays' Coolify deploy webhooks, one per line,
  relay-a first:
  ```
  https://smt.agora.build/api/v1/deploy?uuid=oss4444o8ss40ckgwc40og4c&force=false
  https://smt.agora.build/api/v1/deploy?uuid=<relay-b uuid>&force=false
  ```
  With one relay, only the first line. Required: there is no fallback to the
  older per-relay secrets, which are no longer read and can be deleted.
- `COOLIFY_WEBAPP_WEBHOOK_URL`: `https://smt.agora.build/api/v1/deploy?uuid=c0wwgk4c0owk0w4gsww4k0ss&force=false`.

GitHub Actions repository variables (both checks are **off while unset**, so
a single relay without Redis still deploys):

- `STATION_REQUIRE_REDIS`: `1` makes the health waits and the final check
  require `"redis":"ok"`. Any other value, or unset, skips the check.
- `STATION_MIN_REPLICAS`: the minimum live relay replicas (`"replicas"` in
  `/health`) the health waits and the final check require: `1` with relay-a
  only, `2` once relay-b exists. Unset or `0` skips the check.

Set both explicitly (`STATION_REQUIRE_REDIS=1`, `STATION_MIN_REPLICAS=2`) in
the same change that adds relay-b. Otherwise a deploy can pass with Redis
down or with a replica missing.

Runtime configuration:

- Relay (relay-a and relay-b, identical): `PUBLIC_BASE_URL=https://station.agora.build`,
  `CORS_ORIGIN=https://station.agora.build`, `PORT=3000`, `RUST_LOG=info`, the
  existing PostgreSQL `DATABASE_URL`, `REDIS_URL` (Valkey, a Coolify secret),
  and `RELAY_REPLICAS_EXPECTED` (`1` with relay-a only, `2` with relay-b). The
  last one is a guard: above 1 without `REDIS_URL` the relay refuses to start
  (exit 1), and a value that isn't a positive integer also exits 1. Both apps
  carry the `station-relay-server` network alias, so nginx sees every replica.
  Health check `GET /health` on port 3000.
- Webapp: `STATION_RELAY_UPSTREAM=station-relay-server:3000`. All containers
  must use the `coolify` Docker network. nginx re-resolves the alias through
  Docker DNS every 10 s and spreads requests across every address it returns,
  so replaced and added relay containers are picked up.
- Cloudflare: publish `station.agora.build` on the existing Volumetric tunnel
  with origin `http://10.0.0.1:3010` and a proxied CNAME to that tunnel's
  `<tunnel-id>.cfargotunnel.com`. TLS terminates at Cloudflare; the tunnel
  forwards `/`, `/health`, `/api/*`, and `/ws` to the webapp. `localhost` inside
  the cloudflared container refers to that container, not Volumetric.

Metrics: each relay serves Prometheus text at `GET :3000/metrics`. The
endpoint is unauthenticated and relies on network isolation: the webapp nginx
answers 404 for `/metrics` on purpose, so scrape each relay container directly
on the coolify network (never through the public hostname).

Shutdown (Coolify redeploy or stop, i.e. SIGTERM): the relay drains. `/health`
and new `/ws` upgrades get `503` (nginx then retries another replica), every
WebSocket is closed with code `1012` (clients reconnect, landing on another
replica), the relay waits up to 5 s for its sockets to leave their rooms,
withdraws its presence (a Valkey call, up to 3 s), and in-flight HTTP requests
get at most 5 s more before the relay exits. A long voice request
(`/api/llm/chat`, which can wait up to 30 s) still running then is abandoned.
With nothing in flight the drain takes well under a second; the worst case is
about 13 s (5 + 3 + 5). Docker's default stop timeout is 10 s, so a stuck
drain may be SIGKILLed; its presence then ages out within 30 s and the other
replicas ignore its leftover room entries. A second SIGTERM during the drain
exits at once (code 143, or 130 for SIGINT).

Verification:

```bash
# Node.js 22 or newer; checks HTTPS, relay health, and WebSocket upgrade.
node .github/scripts/verify-station.mjs
# The same checks as the deploy workflow with two relays:
STATION_REQUIRE_REDIS=1 STATION_MIN_REPLICAS=2 node .github/scripts/verify-station.mjs
# Just poll /health until it passes (what the workflow does after each relay):
STATION_REQUIRE_REDIS=1 STATION_MIN_REPLICAS=2 node .github/scripts/verify-station.mjs --wait-health

# What /health reports (any replica answers):
curl -s https://station.agora.build/health
# {"knowledge_store":"postgres","redis":"ok","replicas":2,"status":"ok","vault_store":"postgres"}

# Inspect deployment history in GitHub Actions.
gh run list --workflow deploy-station.yml
```

If DNS returns `NXDOMAIN`, restore the Cloudflare hostname and DNS record.
If `/health` returns `502` while `http://127.0.0.1:3000/health` works on
Volumetric, check the webapp's relay upstream and Docker DNS resolution.
A successful deployment webhook only means the deployment was queued; the
workflow also checks the final deployment status and public endpoints.

#### Relay replicas and Valkey

Each relay replica keeps only its own WebSockets. Rooms, pairing/OTP
sessions, voice and RTC sessions, and the shared rate-limit counters live in
Valkey (`REDIS_URL`), and replicas deliver frames to each other through Valkey
pub/sub. Postgres stays the only durable store. Design:
`docs/specs/2026-09-30-relay-multi-replica.md`.

`/health` (any replica answers it):

| Field / status | Meaning |
| --- | --- |
| `"redis":"disabled"` | No `REDIS_URL`: in-memory mode, one replica |
| `"redis":"ok"` | Valkey reachable |
| `"replicas":<n>` | Live relay replicas as this replica last saw them: its cached copy of the `relay:replicas` presence index, refreshed every 10 s, so it can lag a change by up to 10 s (`1` in in-memory mode) |
| `503 {"status":"unhealthy","redis":"unavailable"}` | This replica can't reach Valkey |
| `503 {"status":"draining"}` | This replica is shutting down (nginx retries another) |
| `503 {"status":"unhealthy"}` | The Postgres store failed its check |

nginx (`webapp/nginx.conf`) retries `/ws` and `/health` on another replica
after a connection error, a timeout, a `502` or a `503` (at most 3 tries), and
skips a replica that failed that way for about 10 s. `502`/`503` are retried
only on these two locations. Everything else (`/api/*`, `/pair`, `/auth`)
uses nginx's default: retry only on a connection error or timeout, and never
retry a request with a non-idempotent method (POST) once it has been sent to a
relay.

**Valkey resource:** on the private `coolify` network only (no public port),
password protected (the password lives only in the `REDIS_URL` Coolify
secret; the relay never logs it), `maxmemory-policy noeviction` (live state
must never be dropped silently: if memory runs out, writes fail loudly), no
persistence, no backups. It holds only live state; Postgres holds everything
durable. **It is sensitive**: it holds pairing session ids, and a pending one
can authorize a WebSocket. Restrict access like the database.

**Startup.** A relay with `REDIS_URL` tries Valkey 10 times, 3 s apart (each
attempt bounded at 3 s), then exits 1 and Coolify restarts it: about 27 s when
connections are refused, up to about 57 s when Valkey doesn't answer at all. A
permanent error (a malformed URL, a wrong password) exits 1 at once: check
`REDIS_URL`. If one of a replica's background tasks (bus subscriber, presence,
sweeps) ever dies, the replica drains as on SIGTERM and exits 1, so it is
restarted instead of looking healthy while broken.

**Per-connection send queue:** each WebSocket's outgoing queue holds at most
1,000 frames or 4 MB. A frame that doesn't fit is dropped, and a client whose
queue stays full for 10 s is closed with code `1013` (try again later).

**Connection limits:** each replica accepts at most 200 concurrent `/ws`
connections per client IP (`RELAY_WS_MAX_PER_IP`, raise it for load tests);
the next upgrade gets `429`. The count is per replica, so with N replicas one
IP can hold up to about N × the limit. The client IP is `CF-Connecting-IP`
(set by Cloudflare on the edge-to-origin hop), then the first
`X-Forwarded-For` entry, then `X-Real-IP`, then the peer address. Production
traffic always comes through the Cloudflare tunnel, so the limit can't be
dodged with forged headers there; keep the relay and webapp ports private (a
client reaching nginx directly could forge `X-Forwarded-For`). A room holds at
most 2 pending (not yet verified) Astation sockets from one client IP and 32
in all; one more is closed with `1013`. The per-IP cap keeps one address from
filling a room's pending slots and locking its owner's reconnects out.

**If Valkey is unreachable:** new WebSockets are refused (`503`), the pairing,
voice and RTC endpoints return `503`, and `/health` returns `503`. Vault and
Atem Memory keep working (Postgres only). Shared rate limits fall back to each
replica's own limit. Nothing durable is lost; rooms rebuild as clients
reconnect. Known behaviors:

- An outage longer than about 9 minutes lets live rooms expire in Valkey
  (10 min TTL, refreshed every minute); their sockets are then closed and the
  clients reconnect, recreating them.
- After a quiet outage the first Valkey call on a replica can fail once while
  the connection is re-established (the 10 s presence refresh usually absorbs
  it).
- A Valkey restart drops all live state: everyone reconnects.
- Frames between replicas go over pub/sub and are best effort, like frames to
  a socket that is dropping: one published while a replica is resubscribing is
  lost.
- A replaced socket whose close message was lost is closed at its next frame
  (each frame's sender is checked against the room; a cached room view that
  missed the change too can delay this by up to 30 s).

**Sizing:** each replica opens up to 5 Postgres connections, and
`admin forget-key` one more. Rule: Postgres `max_connections` must exceed
replicas × 5 (× 2 while a rolling redeploy briefly runs the old and new
container of the same app) + 1 (admin) + `superuser_reserved_connections`
(default 3). Two replicas: above 2 × 5 × 2 + 1 + 3 = 24, plus anything else
using that database.

**Rollout,** each step reversible:

1. Deploy Valkey (checklist below).
2. Set `REDIS_URL` on relay-a and deploy it, still one instance; verify
   `/health` shows `"redis":"ok"` and `"replicas":1`.
3. Add relay-b, set `RELAY_REPLICAS_EXPECTED=2` on both relays, add its
   webhook as the second line of `RELAY_DEPLOY_HOOKS`, and set the variables
   `STATION_REQUIRE_REDIS=1` and `STATION_MIN_REPLICAS=2`; verify
   `"replicas":2`.

**Rollback,** in this order:

1. Remove relay-b: remove its line from `RELAY_DEPLOY_HOOKS`, set
   `STATION_MIN_REPLICAS=1`, stop and delete relay-b in Coolify.
2. If Valkey itself is the problem: on relay-a set `RELAY_REPLICAS_EXPECTED=1`
   **first** (above 1 without `REDIS_URL` refuses to start), then remove
   `REDIS_URL`, delete the `STATION_REQUIRE_REDIS` variable, and redeploy
   relay-a. It is back to in-memory mode, exactly the single-relay behavior
   from before this change.

The Postgres schema doesn't change in either direction, and any relay image
from before this change still runs against the same database.

#### Manual Coolify checklist (two relays + Valkey)

Do these in order; each step is reversible (see "Rollback" above). Record the
new Coolify UUIDs in the resource table at the top of this section.

1. **Create Valkey.** Coolify → Projects → Station → + New → Database → Redis.
   - Image: `valkey/valkey:8`.
   - Password: generate a strong one. Keep "Make it publicly available"
     **off** (no host port). Network: the default `coolify` network.
   - Custom configuration (Redis configuration / command arguments):
     `maxmemory 512mb`, `maxmemory-policy noeviction`, `save ""`,
     `appendonly no`. Keep Valkey's default
     `client-output-buffer-limit pubsub 32mb 8mb 60`: a relay's bus
     subscriber that falls more than 32 MB behind (or 8 MB for 60 s) is
     disconnected and loses every cross-replica frame until it resubscribes.
     So the relay never publishes a message over 8 MiB to another replica
     (`BUS_MAX_FRAME_BYTES`): a bigger client frame whose target socket is on
     another replica is dropped with a warning and counted in
     `relay_bus_oversize_dropped_total`. Frames between sockets on the same
     replica are not limited this way. Don't lower the pubsub limit below
     about 4 × 8 MiB.
   - Backups: none. Start it and copy its internal URL,
     `redis://default:<password>@<valkey container name>:6379`.
   - Check in the Valkey container's terminal:
     `valkey-cli -a '<password>' CONFIG GET maxmemory-policy` → `noeviction`,
     and `CONFIG GET save` → empty.
2. **Point relay-a at Valkey.** Relay app `oss4444o8ss40ckgwc40og4c` (rename
   it `relay-a` if you like). Environment: add `REDIS_URL` = the internal URL
   above, marked as a secret, and `RELAY_REPLICAS_EXPECTED=1`.
   **URL-encode** any special characters in the password (`@`, `:`, `/`, `#`,
   `%`, …), or the URL is malformed and the relay exits at once. Health check:
   **enabled**, path `/health`, port 3000, so Coolify keeps the old container
   serving until the new one is healthy. Keep its `station-relay-server`
   network alias. Redeploy relay-a. **If it doesn't become healthy, remove
   `REDIS_URL` at once and redeploy** (that is the rollback), then read the
   relay log.
   **Close host port 3000:** relay-a publishes `3000` on the host, which
   bypasses Cloudflare: anyone reaching it can read the unauthenticated
   `/metrics` and forge `X-Forwarded-For` past the per-IP WebSocket and
   pending-Astation caps. Remove the host port mapping (nginx reaches relays
   by the `station-relay-server` alias on the `coolify` network), or bind it
   to `127.0.0.1`, or firewall it so only the host can connect. Check from
   another machine: `curl -m 5 http://<server ip>:3000/health` must fail.
3. **Verify one relay with Redis** (these checks apply once the multi-replica
   relay image has been deployed from `main`; an older image reports no
   `redis`/`replicas`). `curl -s https://station.agora.build/health` shows
   `"redis":"ok"` and `"replicas":1`. The relay log shows, once at startup,
   `Shared relay state ready (Redis); replica <id>, 1 live replica(s)`.
   Optionally set the repository variables `STATION_REQUIRE_REDIS=1` and
   `STATION_MIN_REPLICAS=1` now and re-run "Deploy Station" on `main`.
4. **Create relay-b.** + New → Application → Docker Image
   `ghcr.io/agora-build/station-relay-server:main`, on the `coolify` network,
   **no host port** (relay-a already uses 3000), the same
   `station-relay-server` network alias as relay-a (set the same way), health
   check `/health` on port 3000, and the same environment as relay-a
   (`DATABASE_URL`, `REDIS_URL` as a secret, `CORS_ORIGIN`, `PUBLIC_BASE_URL`,
   `PORT=3000`, `RUST_LOG=info`). Set `RELAY_REPLICAS_EXPECTED=2` on **both**
   relays. Deploy relay-b, then redeploy relay-a.
   Check that the alias reaches both relays from the webapp container:
   `docker exec <webapp container> getent hosts station-relay-server` must
   print **two** addresses. A missing alias on relay-b still makes `/health`
   report `"replicas":2` (presence is in Valkey), but nginx would never route
   to relay-b.
5. **GitHub.** Set the secret `RELAY_DEPLOY_HOOKS` to both relays' webhooks,
   one per line, relay-a first:
   `https://smt.agora.build/api/v1/deploy?uuid=oss4444o8ss40ckgwc40og4c&force=false`
   and `https://smt.agora.build/api/v1/deploy?uuid=<relay-b uuid>&force=false`
   (`gh secret set RELAY_DEPLOY_HOOKS < hooks.txt`).
   Set the repository
   variables `STATION_REQUIRE_REDIS=1` and `STATION_MIN_REPLICAS=2`
   (explicitly; unset means "not checked"). Re-run
   "Deploy Station" on `main`: relay-a, health, relay-b, health, webapp,
   verify.
6. **Verify two replicas.** `/health` shows `"replicas":2` (repeat the curl a
   few times: either replica answers, and each one's count can lag up to 10 s
   after a replica starts or stops). The startup log line of the replica that
   started second says `2 live replica(s)`; the first one's said 1 and is not
   printed again.
7. **Postgres.** `SHOW max_connections;` on the relay database is above 24
   (see "Sizing" above).
8. **Failover drill.** With an Astation and an Atem connected and chatting,
   stop relay-a in Coolify. Expect: their sockets close with 1012 and
   reconnect within seconds to relay-b, chat keeps working, `/health` stays
   `200` (now `"replicas":1`). Start relay-a again, wait for `"replicas":2`,
   then repeat with relay-b.
9. **Rollback drill (optional).** Follow "Rollback" above on a quiet day and
   then roll forward again.

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

Each relay replica loads all registered keys into memory at startup (logged
as `Loaded N Astation relay key(s)`) and serves connects and verifications
from that cache, so a database outage does not lock registered Astations out
of relay chat. With `REDIS_URL`, a key change on one replica (a registration,
a re-read that finds a new key, or `admin forget-key`) is announced on Valkey
and every replica re-reads that key. If that re-read fails, the replica keeps
the id as a stale placeholder, so its connects stay pending and must prove the
key against Postgres (fail closed). After a Valkey resubscribe each replica
reloads every key, retrying with backoff (1 s doubling to 30 s) until it
succeeds. Room ownership in Valkey is authoritative: a socket without a key
proof never displaces a verified owner, even on a replica whose cache missed
the key; it waits as pending instead.

Admin reset, for a lost, stolen or replaced Mac (its Astation reports "Relay
rejected this Astation's key"). A user who moves their account to a new Mac
does this: Settings → Security → **Restore Account…**, paste the recovery kit
they saved from the old Mac, then reopen Astation. The relay still holds the
old Mac's key for that id, so it rejects the new Mac until the reset below.
After the reset, the new Mac's key registers on first connect, the account's
bindings are kept, and its memory, skills and vaults are reachable again.
Relay logs show only the first 4 characters of an id, so look it up first:

```sql
SELECT astation_id, registered_at, last_verified_at FROM astation_keys
 WHERE astation_id LIKE '<first chars>%';
```

Then, in any relay container (Coolify → relay-a → Terminal, or
`docker exec -it <relay container> sh`):

```bash
station-relay-server admin forget-key <astation_id>
# Deleted the relay key of <astation_id>.
# Announced on relay:broadcast: every relay replica drops its cached key now.
```

It uses the container's `DATABASE_URL` (required) and `REDIS_URL`
(optional). It connects to both first: if `REDIS_URL` is set but Valkey is
unreachable it exits 1 **without deleting the key** (fix Valkey and retry).
It deletes the key in Postgres, then announces the change on
Valkey: every replica drops its cached key at once **and disconnects that
Astation's live verified socket**, so a stolen Mac is revoked immediately,
without a restart. Exit codes: `0` done (also when no key was registered),
`1` a database or Valkey error (including "the key was deleted, but
announcing it failed": then restart the relay replicas), `2` bad arguments.
Without `REDIS_URL` (in-memory mode) it only deletes the key and says so:
restart the relay to drop its cached key. Deleting the row by hand in SQL
still works, but likewise needs a restart of every relay replica.

Bindings are kept. Then get the replacement (or recovered) Mac online: its
Astation connects with its new key, which registers by trust on first use, and
it pushes its sessions again. After `forget-key` the **first** key to connect
wins (trust on first use), so the replacement Mac must connect before the
stolen one does: a stolen Mac that is still online reconnects on its own and
would re-register its old key. Do this promptly, since until then anyone holding
the room code could register first (see "First-use squatting" in
`relay-server/SECURITY.md`).

`DELETE /api/pair/:code` is refused with `409` for a code that has a registered
key; use `admin forget-key`, not the API, to manage such rooms.

Rollback caveat: once `0003` has been applied, a relay image built before it
fails at startup (`sqlx` migrate error `VersionMissing(3)`: the database has a
migration the binary does not know). Roll back to an image that includes
`0003` (any `:sha-<commit>` from this change on). Only if you must run an older
image: `DELETE FROM _sqlx_migrations WHERE version = 3;` lets it start (the
tables stay and are ignored; a later deploy re-applies `0003`, which is
`CREATE … IF NOT EXISTS`).

Memory rollback caveat: after migration `0004` (Atem Memory 1.1) the previous
relay binary can't write memories (the `memories.deleted` column is gone). Roll
back by restoring a database backup, not by redeploying the old image, and
deploy as a single-instance swap (never old and new relays on one database).

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
  replicas: 1  # more than 1 needs REDIS_URL (see Scaling)
  strategy:
    type: Recreate  # RollingUpdate is safe once REDIS_URL is set
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

### Relay replicas

With `REDIS_URL` set, the relay runs as any number of replicas behind the
webapp: any replica serves any request, and an Astation and its Atems may be
on different replicas. Without `REDIS_URL` it keeps rooms and sessions in
memory and must run as exactly one instance (`RELAY_REPLICAS_EXPECTED` above
1 without `REDIS_URL` refuses to start). See "Relay replicas and Valkey" above
for Valkey, sizing, rollout and rollback.

Replicas find each other only through Valkey; there is no leader. Each one
keeps a presence key alive (refreshed every 10 s, expiring after 30 s). A
crashed replica's clients reconnect to the others within seconds, and its
leftover room entries are ignored once its presence key expires. Redis keys
and channels: `docs/specs/2026-09-30-relay-multi-replica.md`, "Redis keys".

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
`/api/*` and `/ws` to the relay replicas. Configure health checks on
`/health`.

## Security

1. **HTTPS Required** - Microphone access requires HTTPS (except localhost)
2. **CORS** - Set `CORS_ORIGIN` to the public webapp origin in production
3. **Rate Limiting** - REST APIs are limited per client IP behind the trusted proxy; `/ws` allows 200 concurrent connections per client IP per replica (`RELAY_WS_MAX_PER_IP`), keyed on Cloudflare's `CF-Connecting-IP`
4. **Firewall** - Restrict access to port 3000 (API should only be accessed via nginx proxy). The docker-compose example publishes `3000:3000`, which also exposes the unauthenticated `/metrics`: firewall it or publish `127.0.0.1:3000:3000` instead
5. **Token Validation** - Ensure Agora tokens have appropriate expiry times
6. **Valkey** - Private network only, password in the `REDIS_URL` secret; it holds pairing session ids, so restrict it like the database

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

# Restart services. With one relay the restart drops every WebSocket for
# a few seconds; with several (REDIS_URL) update them one at a time and
# clients move to the others (close code 1012). Astations and Atems reconnect
# on their own. Vault and Atem Memory data is in Postgres and survives.
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

Everything else (rooms, sessions, WebSockets, the key cache) is live state in
memory or Valkey and is rebuilt as clients reconnect; Valkey is not backed up.

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
