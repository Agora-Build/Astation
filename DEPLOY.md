# Deployment Guide

## Overview

The Astation system consists of:
1. **macOS App** - Menubar app with RTC capabilities (`.pkg` installer)
2. **API Server** - Rust backend for session management + WebSocket relay
3. **Webapp** - Stoa for meeting/sharing and Agent for remote-agent chat

The webapp image serves Stoa at `/stoa/` and Agent at `/agent/`. Stoa owns the
complete meeting/sharing app under `webapp/stoa/`, including its RTC code. Agent
lives in `webapp/agent/`. The relay handles APIs and WebSocket transport.

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
deploy is done. `/health` reports the running commit, and the final workflow
check requires the commit built by this run. Intermediate health waits do not
require it because old and new replicas coexist during a rolling deploy.
A public health request identifies only the replica that answers; it cannot
prove that every replica has updated. Coolify deployment completion remains
the per-application rollout check.

`RELAY_DEPLOY_HOOKS` is required: if it is empty or unset the run fails
before calling anything. One relay is one line.

The deploy job's `timeout-minutes` (90) fits three relay hooks. Each hook can
take about 20 minutes (Coolify wait up to 15, health wait up to 3) and the
webapp plus the final check about 30 more, so raise it in
`.github/workflows/deploy-station.yml` before adding a fourth relay
(about 20 × hooks + 30).

### Station on Volumetric (Coolify)

2026-10-30: the owner chose to reuse these resources for the development
Station at `https://station.dev.agora.build`. Production deployment is deferred
until verification. The original configuration/database are backed up; the
existing encrypted store is retained. The original production workflow and
resource table below describe the previous setup: its deployment hooks now
point at the reused dev applications. Keep them separate from a future
production rollout; do not treat a main workflow run as dev verification.

The following workflow description is the previous production setup, and a
worked example of the section above. The current dev state is recorded below.

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
   those checks are switched on, see below), the expected relay build commit,
   the `/agent/` app and its assets with the expected MIME and security headers,
   and an identity WebSocket
   connection to `wss://station.agora.build/ws`.

The workflow can also be run manually on `main` from GitHub Actions.

Release tags continue to publish versioned and `:latest` images and the macOS
installer. They do not deploy production; Coolify tracks `:main` so publishing
an older release tag cannot roll production back.

The Coolify resources on Volumetric are:

| Resource | Coolify UUID | Image | Host port |
| --- | --- | --- | --- |
| Relay A (`relay-a`, the original relay) | `oss4444o8ss40ckgwc40og4c` | `ghcr.io/agora-build/station-relay-server:main` | `3000` |
| Relay B (`relay-b`) | `am8lrcacts572trbli1bmvnu` | `ghcr.io/agora-build/station-relay-server:main` | none |
| Valkey (relay live state) | `minf9gdzuc2fwzxoq188eiw8` | `valkey/valkey:8` | none |
| Webapp | `c0wwgk4c0owk0w4gsww4k0ss` | `ghcr.io/agora-build/station-webapp:main` | `3010` |

Required GitHub Actions secrets:

- `COOLIFY_API_TOKEN`: Coolify token with `deploy` and `read` permissions.
- `RELAY_DEPLOY_HOOKS`: the relays' Coolify deploy webhooks, one per line,
  relay-a first:
  ```
  https://smt.agora.build/api/v1/deploy?uuid=oss4444o8ss40ckgwc40og4c&force=false
  https://smt.agora.build/api/v1/deploy?uuid=am8lrcacts572trbli1bmvnu&force=false
  ```
  With one relay, only the first line. Required: there is no fallback to the
  older per-relay secrets, which are no longer read and can be deleted.
- `COOLIFY_WEBAPP_WEBHOOK_URL`: `https://smt.agora.build/api/v1/deploy?uuid=c0wwgk4c0owk0w4gsww4k0ss&force=false`.

GitHub Actions repository variables (both checks are **off while unset**, so
a single relay without Redis still deploys):

- `STATION_REQUIRE_REDIS`: `1` makes the health waits and the final check
  require `"redis":"ok"`. Any other value, or unset, skips the check.
- `STATION_MIN_REPLICAS`: the minimum live relay replicas (`"replicas"` in
  `/health`) the health waits and the final check require: `2` for the current
  production deployment. Unset or `0` skips the check.

Set both explicitly (`STATION_REQUIRE_REDIS=1`, `STATION_MIN_REPLICAS=2`) so a
deploy cannot pass with Redis down or with a production replica missing.

The relay image embeds `ASTATION_BUILD_COMMIT` from the Docker build argument.
Deploy and release workflows pass the full Git commit; manual image builds
can use `docker build --build-arg ASTATION_BUILD_COMMIT="$(git rev-parse HEAD)" relay-server`.
Without the argument, `/health` reports `build_commit: unknown`.
The final deployment check sets `STATION_EXPECTED_COMMIT` from the workflow's
commit automatically. For manual verification, this optional environment
variable must be a full 40-character Git commit; a missing or different
reported commit fails the check. Leave it unset for readiness-only checks
during a rolling deploy.

Runtime configuration:

- Relay (relay-a and relay-b, identical): `PUBLIC_BASE_URL=https://station.agora.build`,
  `CORS_ORIGIN=https://station.agora.build`, `PORT=3000`, `RUST_LOG=info`, the
  existing PostgreSQL `DATABASE_URL`, `REDIS_URL` (Valkey, a Coolify secret),
  and `RELAY_REPLICAS_EXPECTED=2`. Above 1 without `REDIS_URL` the relay refuses to start
  (exit 1), and a value that isn't a positive integer also exits 1. Both apps
  carry the `station-relay-server` network alias, so nginx sees every replica.
  Health check `GET /health` on port 3000.
- Account registration: configure the three `ACCOUNT_OIDC_*` settings with the
  registered Auth issuer, exact Station origin and `astation.remote` scope.
  `ACCOUNT_OIDC_AUDIENCE` must equal `PUBLIC_BASE_URL` exactly. Missing or partial
  configuration fails closed; the old `AGORA_ACCOUNT_*` userinfo verifier has
  been removed. Existing identity/data rows are retained.
- Webapp: `STATION_RELAY_UPSTREAM=station-relay-server:3000`. All containers
  must use the `coolify` Docker network. nginx re-resolves the alias through
  Docker DNS every 10 s and spreads requests across every address it returns,
  so replaced and added relay containers are picked up.
- Cloudflare: publish `station.agora.build` on the existing Volumetric tunnel
  with origin `http://10.0.0.1:3010` and a proxied CNAME to that tunnel's
  `<tunnel-id>.cfargotunnel.com`. TLS terminates at Cloudflare; the tunnel
  forwards `/`, `/stoa/*`, `/agent/*`, `/health`, `/api/*`, and `/ws` to the webapp. `localhost` inside
  the cloudflared container refers to that container, not Volumetric.

### Stoa and Agent webapps

This change configures Stoa at `https://station.agora.build/stoa/` and Agent at
`https://station.agora.build/agent/` after deployment. Stoa is intended to move
to its own Stoa subdomain/space under agora.build; see
[the migration guide](docs/stoa.md). Agent's HTML, CSS, JavaScript modules and
icon live in `webapp/agent/` and are packaged in the
existing webapp image. Nginx serves them directly with restrictive CSP,
no-store/no-referrer headers and JavaScript module MIME types. Missing assets
return 404 rather than the RTC page. The relay provides `/ws` transport and
`/api/*`; it does not package browser UI. Deploy through the normal workflow
so the webapp and relay stay compatible. See [webapp structure](webapp/README.md)
for the Stoa and Agent app boundaries.

The final deployment verifier requests both apps and their assets through
the public origin. It rejects 404s, the RTC app's HTML fallback, incorrect module
MIME types and missing privacy/security headers. This runs after the webapp
deployment; intermediate relay health waits remain unchanged.

`/agent/?preview=1` is a labeled sample for reviewing the layout. Real sessions
start from a companion Astation build's **Open in Browser** action, using an
ephemeral authorization in the URL fragment and the existing `/ws` transport.
The companion macOS bridge is currently on `feat/remote-terminal`; Atem must
implement structured `chat-v1` events before live chat is usable. A working
preview does not validate prompt execution or provider replies. See
[the host contract](designs/agent-chat.md) and [the user guide](docs/agent-chat.md).

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
STATION_REQUIRE_REDIS=1 STATION_MIN_REPLICAS=2 STATION_EXPECTED_COMMIT="$(git rev-parse HEAD)" node .github/scripts/verify-station.mjs
# Just poll /health until it passes (what the workflow does after each relay):
STATION_REQUIRE_REDIS=1 STATION_MIN_REPLICAS=2 node .github/scripts/verify-station.mjs --wait-health

# What /health reports (any replica answers):
curl -s https://station.agora.build/health
# {"build_commit":"<full Git commit>","knowledge_store":"postgres","redis":"ok","replicas":2,"status":"ok","vault_store":"postgres","version":"0.1.0"}

# Inspect deployment history in GitHub Actions.
gh run list --workflow deploy-station.yml
```

If DNS returns `NXDOMAIN`, restore the Cloudflare hostname and DNS record.
If `/health` returns `502` while `http://127.0.0.1:3000/health` works on
Volumetric, check the webapp's relay upstream and Docker DNS resolution.
A successful deployment webhook only means the deployment was queued; the
workflow also checks the final deployment status and public endpoints.

#### Agent approval pushes (gated)

Push provider configuration and device-token registration are documented in
[Agent approval notifications](docs/push-notifications.md), including Apple
provisioning, Firebase service accounts, mounted secret files and the shared
Postgres migration. Configure both relay replicas consistently; roll one at a
time with health checks. There are no push credentials in the repository.

This preparation does not enable live approvals. Host authentication to the
relay, signed control membership, r7 catch-up/atomic decisions and a durable
dispatch outbox must be integrated first. A raw Atem room connection and an SSO
account login are not authorization for approval delivery or decisions.

#### Unified account login and recovery storage

Astation #63 separates agora.build login from Agora service credentials. The
implemented Auth contract is pinned at Agora-Build/Auth `bc1bfe7`,
`docs/integrating.md`. Its issuer is `https://auth.agora.build`; the issuer must
actually resolve and serve discovery before live account setup can work.

Ask the Auth operator to register Astation in its private clients file. The
following is a proposed registration, not an existing deployed client:

```json
{
  "resources": [{
    "indicator": "https://station.agora.build",
    "name": "Astation account storage",
    "scopes": ["station:account"]
  }],
  "clients": [{
    "id": "astation", "name": "Astation", "type": "native", "firstParty": true,
    "redirectUris": ["http://127.0.0.1/callback"],
    "grants": ["authorization_code", "refresh_token"],
    "scopes": ["openid", "profile", "offline_access", "astation.remote"],
    "resources": ["https://station.agora.build"]
  }]
}
```

Use the operator-confirmed values consistently; do not assume the example is
registered. The relay needs all three settings on every replica:

```text
ACCOUNT_OIDC_ISSUER=https://auth.agora.build
ACCOUNT_OIDC_AUDIENCE=https://station.agora.build
ACCOUNT_OIDC_REQUIRED_SCOPE=astation.remote
```

Set matching app build variables. The package build stamps these public values
into Info.plist before signing, so a Finder-launched app retains configuration:

```text
ASTATION_ACCOUNT_ISSUER=https://auth.agora.build
ASTATION_ACCOUNT_CLIENT_ID=astation
ASTATION_ACCOUNT_RESOURCE=https://station.agora.build
ASTATION_ACCOUNT_SCOPE=astation.remote
```

Settings > Account signs in to Agora.Build. Agora Projects uses its separately
scoped Portal grant and protected certificate cache. Recovery HTTP and relay
account registration use only the Station token. The app sends it only
to the registered API origin; pasted Recovery Kit URLs cannot choose a token
recipient. Keychain stores the rotating refresh token and a durable refresh
intent. An interrupted refresh requires sign-in instead of replaying an old
one-use token. This does not delete recovery checkpoints, keys or paired hosts.

Migration `0010_account_identities.sql` preserves existing legacy principal
strings and records their `legacy:agora` namespace. Data-account IDs, signed
roots and backups do not change. Inventory legacy registrations before rollout:
ordinary registration refuses an identity change and retains the old binding.
An explicit verified legacy-to-unified binding migration is separate work.
Never relabel subjects, match by email, or clear live state to pass a test.

Validate discovery, a real registered native login, relay registration, and
recovery storage over the provisioned app/deployed relay before retrying the
retained isolated `atem pair verify` operation. Signing-key outage must fail
closed after a maximum one-hour JWKS outage window; keys refresh normally after
60 seconds, and removed keys do not survive a successful JWKS replacement.
Access-token expiration applies throughout the outage. JWT `iat` is not fresh-authentication
proof: if API tokens omit `auth_time`, offline data merges remain unavailable;
online owner approval still works. Login never authorizes membership or K.
Main merge/deployment still requires user approval. Atem #93 and other r9
admission gates remain independent.

#### Auth validation and custom Station registration

There is no legacy userinfo fallback. An unavailable or misconfigured issuer
leaves account registration/recovery unavailable without relabeling existing
principals or changing pairings/encryption. `/health` and `verify-station.mjs`
prove infrastructure availability, not Auth interoperability or R9 authority.

For a custom Station, first register its exact origin in Portal > Stations.
The built-in default uses internal operator setup, described under "Default
Station validation with dev Auth and Portal"; users do not register it.
Set the Portal-generated public `STATION_REGISTRATION_CHALLENGE` on every
replica. `GET /.well-known/agora-build-station` serves that exact value as
`text/plain` with `Cache-Control: no-store`; unset it after verification. This
proof endpoint is absent unless an operator sets the challenge, including on
the default relay. It never activates Station AI
or enrolls an account/device. Confirm the proof-response schema with Portal
before live registration; no control-plane secrets belong in the challenge.

Auth must register the origin/resource and allowed accounts before a token for
it can be issued. Agent access additionally needs Auth's five-minute
client-credentials tokens and the matching native-approved R9 service binding.
The [admission contract](designs/protocol/station-auth-validation.md) records
purpose isolation, key rotation/outage rules and remaining interoperability
work. `/api/agent/v1`, `/mcp` and `/v1/chat/completions` remain closed
until their respective runtime verification. Default and custom agent
endpoints require the same protected provisioning. Existing live R9 gates remain separate. No deployment is
authorized by adding configuration/examples to this document.
The old `/api/llm/chat` and `/api/voice-sessions` bridge now uses that closed
gate too; its session-ID-only authentication cannot substitute for the new
assistant session contract. The former voice coding bridge stops working in
this branch until the replacement is provisioned. RTC sharing is unaffected.

#### Relay replicas and Valkey

Each relay replica keeps only its own WebSockets. Rooms, pairing/OTP
sessions, voice and RTC sessions, and the shared rate-limit counters live in
Valkey (`REDIS_URL`), and replicas deliver frames to each other through Valkey
pub/sub. Postgres stays the only durable store. Design:
`docs/specs/2026-09-30-relay-multi-replica.md`.

`/health` (any replica answers it):

| Field / status | Meaning |
| --- | --- |
| `"version":"<package version>"` | Relay Cargo package version, included on healthy and unhealthy responses |
| `"build_commit":"<full Git commit>"` | Commit embedded in the relay binary, or `unknown` when built without metadata; included on every response |
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

Preserve these path-specific retry rules in custom proxies. In the isolated
hosted-API test deployment, a global `http_503` retry treated the intentional
`503 hosted_execution_not_verified` response as an upstream failure, marked
both healthy replicas unavailable, and turned subsequent requests into `502`.
Removing `http_503` from that proxy's general retry list restored twenty
consecutive expected gate responses without restarting either replica. An API
policy refusal must not mark a healthy relay unavailable or replay a mutation.

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

**Load test record** (`relay-server/README.md`, "Load test"):

| | 2026-10-02, local, production-like |
|---|---|
| Commit | `8c4f6ff` (main) |
| Setup | 2 relays (`REDIS_URL`, `RELAY_REPLICAS_EXPECTED=2`, `RELAY_WS_MAX_PER_IP=20000`) + Valkey 8 (`maxmemory 512mb`, `noeviction`), all on one Linux host (16 cores, 38 GB) with the load client; loopback, so no TLS or Cloudflare |
| Run | defaults: 10,000 rooms × (Astation + 2 Atems) = 30,000 sockets, ramp 60 s, 30 min of traffic every 5 s |
| `total:` | 21,599,994 samples, p50 0.2 ms, p99 41.0 ms, max 44.0 ms; lost frames 0 (up, bcast, uni); seq gaps 0; duplicates/reordered 0; connect errors 0; auth errors 0; incomplete rooms 0; dropped sockets 0. **PASS** |
| Relay memory (RSS) | relay-a 269 → 336 MB, relay-b 268 → 330 MB (2 min after the ramp → end). Growth slowed through the run (+37 MB, then +18 MB, then about 0 in the last 6 minutes), so it looks like warm-up, not a leak; a longer soak would confirm. About 22 KB per socket. |
| Valkey | 6.7 MB, flat |

Still to do before a 10k claim on the real deployment: the same run against
production-like hardware through Cloudflare (needs a planned window, a
temporary `RELAY_WS_MAX_PER_IP` raise, and `forget-key` cleanup of the
`astation-lt-*` keys).

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

# Use the canonical config for Stoa, Agent, module MIME types,
# privacy headers, API limits and WebSockets. A fixed local relay needs no
# Docker DNS resolver; keep that resolver for the container deployment.
sed -e 's|/usr/share/nginx/html|/var/www/astation|g' \
    -e 's|${STATION_RELAY_UPSTREAM}|127.0.0.1:3000|g' \
    -e '/^[[:space:]]*resolver /d' \
    -e 's/ resolve;/;/' \
    Astation-*/webapp/nginx.conf | sudo tee /etc/nginx/sites-available/astation

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

## Station Integrations

The production relay already runs independently of the Mac on Volumetric.
Use `mosh Volumetric` for interactive administration, or the same saved SSH
alias for automation. Its Cloudflare route is `http://10.0.0.1:3010`; the
webapp on that port proxies to the two Coolify relays. Check that origin and
each replica before treating a public failure as a relay outage. Cloudflare
may return error 1010 for Python's default User-Agent; use the actual native
client or a normal `curl` request to distinguish that from the hosted API's
`hosted_execution_not_verified` response.

Keep a development integration on a separate registered origin and isolated
database/Redis resources, even when using the same server. Moving its backend
off the Mac must preserve that exact origin, the complete durable database,
and its report/wrapping keys. Take a fresh snapshot after stopping the old
listener, restore it into the isolated destination, verify both replicas,
then move the tunnel with a saved rollback command. Retain the source
database. Hosts reprove their routes after reconnecting; do not regenerate
keys, re-pair, or transfer an approval to a different origin. Native R9
connections may require a fresh foreground owner confirmation after the
transport changes. Already approved service access remains independent of
that native connection.

The provisioning endpoints and authenticated feed worker require durable
Postgres. Auth seeds the built-in Station and stable report identity from
operator configuration, replacing its static resource entry while preserving
native token claims. Custom Stations require registration/proof first.
Both use the same protected keys and native service consent. Configure an
HTTPS origin, exactly matching
the Auth resource, without paths, credentials, query parameters or a trailing
slash. Each replica uses the same binding and protected keys:

| Variable | Purpose |
| --- | --- |
| `PUBLIC_BASE_URL` | Exact Station origin; defaults to `https://station.agora.build` when absent. Required explicitly for custom Stations. |
| `ACCOUNT_OIDC_ISSUER` | Pinned Agora.Build Auth issuer; dev is `https://auth.dev.agora.build`. |
| `ACCOUNT_OIDC_AUDIENCE` | Must equal `PUBLIC_BASE_URL` exactly. |
| `ACCOUNT_OIDC_REQUIRED_SCOPE` | Native account scope `astation.remote`. |
| `STATION_PORTAL_ORIGIN` | Exact Portal transport/resource origin; dev is `https://dev.agora.build`. |
| `STATION_REPORT_CLIENT_ID` | Operator-provisioned built-in or registered custom Station's `s-...` report client ID. |
| `STATION_REPORT_KEY_FILE` | Mounted P-256 PKCS8 DER report-signing key, separate from service/native keys. |
| `STATION_SERVICE_WRAPPING_KEY_FILE` | Mounted raw 32-byte AES wrapping key for integration service keys. |
| `STATION_SERVICE_WRAPPING_KEY_ID` | Stable operator label binding every encrypted service-key envelope. |

Mount regular files with mode 0600 or stricter, readable only by the service
user. Symlinks, empty/oversized files and group/world permissions are refused.
Missing/invalid configuration leaves provisioning and hosted admission closed.
Startup never creates replacement keys. Prepare files outside the container
image, using a protected operator directory (example commands generate new
keys and must never overwrite an established deployment's files):

```sh
umask 077
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 |
  openssl pkcs8 -topk8 -nocrypt -outform DER -out station-report.der
openssl rand -out station-service-wrapping.bin 32
```

Provision only the report key's public JWK in the platform configuration for
the built-in, or register it in Portal for a custom Station. The authenticated
`GET /agora-build/v1/details` (`station.read`) returns it; exact Portal-origin
preflight is supported for that path. Keep native Station access tokens and
Portal approval/report tokens scoped to their own resource. A localhost
Portal process may sit behind the configured public HTTPS origin; do not send
public-resource bearer credentials to an unrelated transport origin. Confirm
Auth permits native `astation` issuance of `astation.remote` for this exact
Station, and issue `station.report` for its configured Portal origin.

#### Development built-in Station

Current backend rollout (2026-10-30):

| Component | Deployment |
| --- | --- |
| Public origin | `https://station.dev.agora.build`; DNS/tunnel routing is published, but public TLS still fails as of 2026-10-30 21:26 UTC. |
| Relay A | Existing Coolify `oss4444o8ss40ckgwc40og4c`, renamed `station-dev-relay-a`. |
| Relay B | Existing Coolify `am8lrcacts572trbli1bmvnu`, renamed `station-dev-relay-b`. |
| Webapp | Existing Coolify `c0wwgk4c0owk0w4gsww4k0ss`, renamed `station-dev-webapp`; host port `3010`. |
| Relay image | `127.0.0.1:5051/station-relay-server:dev-9004ca9`; source `9004ca9424add5e42df0e35e6598ad070d79e387`. |
| Webapp image | `127.0.0.1:5051/station-webapp:dev-6076bf9`; includes `/agora-build/` API forwarding. |
| Image storage | Persistent `station-dev-registry-data` volume; registry listens on host loopback only. Preserve it when redeploying these pinned images. |
| Durable store | Existing encrypted PostgreSQL store retained; no account reset or hosted approval is created by renaming the deployment. |
| Live state | Dedicated private `station-dev-redis` on the `coolify` network; no public Redis port. |
| Nginx upstream | `station-dev-relay:3000`; both relays carry this alias. |

Operator files and non-secret verification are in
`/home/guohai/astation-dev-20261030` on Volumetric. Its `protected/` directory
contains the original Coolify/container configuration, pre-rollout database
dump, dev runtime credentials and new dev-only report/wrapping keys; modes are
0700/0600. Do not copy those files into Git or logs. Public report JWK and
RFC 7638 thumbprint are in `public-handoff.json` and Portal/Auth vault
`v-xZDT9aGD` e96. The earlier production-origin report key remains unused.

The previous hostname `station.agora.build` now returns NXDOMAIN from both
Cloudflare and Google public resolvers. Existing clients still configured for
that hostname, including the shared-vault CLI, cannot connect. Migrate their
transport configuration after the dev origin passes HTTPS/WSS verification;
do not introduce an issuer or audience alias. The relays
are explicitly pinned to the dev issuer and dev audience. Their temporary
`station-relay-server` alias preserves the old webapp's route during rolling
replacement; it grants no additional token audience or hosted access.

The dev hostname uses a proxied CNAME to tunnel
`d7e78923-8981-4fda-9f12-7aa9e36a739a.cfargotunnel.com` and a tunnel public
hostname `station.dev.agora.build` with service `http://10.0.0.1:3010`.
The owner published routing on 2026-10-30. Public HTTP `/health` reaches the
expected relay build and reports PostgreSQL, Redis and two replicas. HTTPS
still fails during the Cloudflare edge handshake from both the Mac and
Volumetric, before an HTTP response or peer certificate is available. Check
SSL/TLS -> Edge Certificates for an active certificate covering this exact
hostname. A certificate for `*.agora.build` does not cover
`station.dev.agora.build`; Advanced Certificate Manager or Total TLS may be
needed for that nested hostname. Preserve unrelated ingress rules. Cloudflare
DNS/tunnel/certificate management access is separate from the connector's
runtime token. Do not redirect bearer-authenticated API calls between Station
origins.

Both relays and the webapp passed Coolify health checks. Actual backend
checks confirm PostgreSQL, Redis, two replicas and exact dev issuer/audience
configuration. Earlier public checks through the previous hostname passed
Stoa/Agent assets and identity WebSocket upgrades, before its DNS removal.
Those checks do not prove public HTTPS/WSS on the new hostname. The full
`verify-station.mjs` check currently fails on TLS. Public HTTP diagnostics
used only unauthenticated health/details/metrics routes: health is 200,
details is the expected closed-state 503, and metrics is 404. Authenticated
verification awaits valid HTTPS. Provisioning
and details return `station_integration_unavailable` until Auth/Portal's
built-in report identity is delivered; hosted APIs return
`hosted_execution_not_verified`. Both are intentional closed states, not a
completed integration test. Source/report configuration and native approvals
still need their own end-to-end verification.

The saved database/configuration are rollback evidence. Never restore a dump
over the retained live database or discard writes made after the snapshot.
Check migration compatibility before rolling back the executable; use a
separate restored database if the old image cannot read the newer schema.

The owner resolved Q6 on 2026-10-30: reuse the current Volumetric deployment
with the dev origin; deploy production after verification. This supersedes
the earlier proposal to combine the production origin with dev Auth.

```text
PUBLIC_BASE_URL=https://station.dev.agora.build
ACCOUNT_OIDC_ISSUER=https://auth.dev.agora.build
ACCOUNT_OIDC_AUDIENCE=https://station.dev.agora.build
ACCOUNT_OIDC_REQUIRED_SCOPE=astation.remote
STATION_PORTAL_ORIGIN=https://dev.agora.build
```

Preserve the selected built-in origin's native token contract. Auth replaces
its static resource entry with an internally seeded Station and report client;
Auth/Portal must implement this before provisioning the report identity.
Configure the public report key internally, and mount the protected
report and wrapping keys on both replicas. Reuse the existing ES256
`private_key_jwt`, Portal-resource `station.report` token and changes/reports
API schemas. The built-in report client resolves to the default origin and
its feed carries integrations from multiple accounts; every request still
matches its integration's exact owner. Portal must expose the built-in choice
without requiring account membership in a custom Station. Platform operators
manage its report key; end users cannot share/remove the built-in Station.
This is internal service configuration, not another user enrollment path.
Coordination: [Portal #21](https://github.com/Agora-Build/Portal/issues/21#issuecomment-6531544904).
The [review](designs/protocol/built-in-station-auth-portal-review.md) confirms
the public RFC 7638 key thumbprint and records the remaining disclosure,
environment and live-verification requirements. Keep execution disabled until
those requirements pass.

Native Astation uses the dev Portal for account/project and approval tokens,
and requests separate `station.dev.agora.build` tokens from the same dev issuer
for Station calls. Never reuse a Portal-audience token at Station, silently
fall back between issuers, or import dev account data into a production issuer.
Production Auth is a separate later configuration/registration, not an alias.

Before rollout, retain the current image/configuration and back up the durable
database and operator keys. Change one replica at a time; verify discovery,
native login, exact-origin token refusal, native service approval, host
admission, actual HTTP/WSS execution and revocation/reconnect. Use a new
disposable integration for terminal revocation; never restore the already
revoked integration. Do not reset existing principals, memberships, paired
hosts, keys or encrypted data to make a test pass. Health alone is insufficient.

Migrations 0012/0013 persist authenticated policy/cursor/denial, encrypted
service keys, immutable owner/root/integration mappings and exposed key
fingerprints, fleet poll pacing and quota counters. Back up these records
with the R9 membership/recovery tables and operator wrapping/report keys.
Protect the operator keys separately from database backups; test restoration
together. Losing a key must fail closed. Do not delete rows or regenerate
keys to recover an approved identity. Re-enrollment requires a new explicit
native approval. Wrapping-key rotation needs an offline, verified rewrap of
every envelope before restarting replicas; automatic key-ring rotation is
not implemented. Report-key replacement must also update Portal's registered
public key before the worker resumes.

Workers reconcile a current snapshot from cursor zero at startup, poll every
minute, and coalesce unsigned POST `/agora-build/v1/changes` hints. A durable
fleet claim caps feed requests at one per second. Only authenticated
`409 code:cursor_ahead` resets via a committed denial fence. After a known
Portal database restore, restart the worker replicas to reconcile from zero,
even if their old cursors are not ahead. Failed polls do not refresh policy;
admission refuses snapshots aged 120 seconds or more.

Settings > Integrations in Astation supplies the native review/owner approval
flow. The exact reviewed body and signature survive uncertain replies and
restarts. Provisioning returns a draft, not readiness. Hosted endpoints under
`/api/agent/v1/integrations/...` remain **hard disabled**, with no environment
override, until actual Auth/native/host/encrypted relay-only confirmation, reconnect/revocation,
Mac-off and replica tests pass. Readiness reports cannot advertise Ready with
this gate closed. Native host-policy reconciliation uses R9.8a through the
pinned shared client: only a current, correlated, durable response inside an
admitted native-manager `atem-ch1` channel confirms the selected relay policy.
Plaintext policy/ACK messages are removed. A confirmation on a direct
migration channel never establishes relay readiness. Policy confirmation
against the disposable actual host passed on 2026-10-29. A separate real Codex
test also passed with native Astation closed while the host reconnected to a
surviving Station replica and its accepted receipt/response were recovered
without replay. Both replicas and the same provisioned app were restored.
Genuine approval/rule cases and actual public HTTP admission still need live
verification before activation. See the
[policy review and lifecycle](designs/protocol/host-policy-r9-review.md) and
[service verification procedure](designs/protocol/station-hosted-agent-api.md#real-host-service-verification).
MCP, LLM and Discord activation are separate later work.
See the [typed API](designs/protocol/station-hosted-agent-api.md) and
[lifecycle](designs/protocol/station-integration-lifecycle.md).

## Support

- GitHub Issues: https://github.com/Agora-Build/Astation/issues
- Documentation: See webapp/TESTING.md for testing guide
