# Relay multi-replica design

Status: design, approved in discussion 2026-09-30. Steps 1–5 built
(`feat/relay-multi-replica`); step 6 (10k+ readiness): bounded send queues
built, the rest not yet.
Operations: `DEPLOY.md`, "Relay replicas and Valkey".

## Goal

Run the relay (`relay-server/`) as several replicas behind the webapp:

1. **Now: failover.** A relay crash, out-of-memory kill, or deploy causes no
   outage. All replicas run on one server (Volumetric).
2. **Long term: 10k+ users.** Roughly 10k online Astations plus ~20k Atems,
   about **30k WebSockets**, with pairing and voice traffic on top.

Any replica must be able to serve any request. The same code covers 2
replicas for failover and N replicas for scale.

## Non-goals

- Surviving loss of the whole server, Redis failover (Sentinel), and
  multiple regions. Nothing here blocks them later: replicas reach Redis
  and Postgres over the network, so moving replicas to other servers is a
  deploy change.
- Guaranteed delivery. Frames stay "best effort while connected", as today.
  Clients already reconnect and resync.
- Any change to the Postgres schema or to the client protocol. Astation and
  Atem don't change.

## Why the relay can't run twice today

Postgres-backed state (vault, Atem Memory, identity keys and bindings) is
already safe for multiple replicas. Everything below lives in one process's
memory:

| State | Where | Breaks with 2 replicas because |
|---|---|---|
| Rooms: Astation owner, pending Astations, Atem connections | `relay.rs` `RelayHub.rooms` | An Astation and its Atems on different replicas never meet |
| Astation key cache | `relay.rs` `RelayHub.keys` | A key registered or reset on one replica is unknown to the others |
| Pairing/OTP sessions | `session_store.rs` | Create, grant, poll and WebSocket connect must all reach one replica |
| Voice sessions and waiters | `voice_session.rs`, `llm_proxy.rs` | ConvoAI's request waits up to 30 s in-process for the Atem's answer, which may arrive on another replica |
| RTC sessions (8-person cap, uid counter) | `rtc_session.rs` | Create on one replica, join on another fails; the cap and uids are per process |
| Per-IP rate limits | `main.rs` (`tower_governor`) | N replicas allow N× the requests |

On Coolify, replicas are several containers sharing the
`station-relay-server` network alias. Docker DNS returns all of them and
nginx spreads requests across them with no stable order. So the design can't
depend on a client always reaching the same replica.

## Approach

**Stateless replicas + Redis (Valkey).** Each replica keeps only its own live
sockets. Shared live state (rooms, sessions, rate counters) moves to Redis,
and replicas deliver frames to each other through Redis pub/sub. Postgres
stays the source of truth for durable data. Redis holds only live state:
losing it means everyone reconnects, never data loss.

Rejected:

- **Shard by room code** (nginx `hash $arg_code consistent`): consistent
  hashing needs a fixed upstream list, which Coolify's changing container IPs
  don't give; adding a replica moves rooms; routes not keyed by room code
  still need shared state.
- **Failover without Redis now, stateless later:** reworks the relay core
  twice.

## Architecture

```
Cloudflare → webapp (nginx) ──round-robin──▶ relay-1 ┐
                                           ▶ relay-2 ├──▶ Postgres  (durable: vault, memory, identity)
                                           ▶ relay-N ┘──▶ Valkey    (live state only)
```

Each unit sits behind a trait with an in-memory version (tests, single
instance, local dev) and a Redis version (production), following the
existing `InMemory…Store` / `Pg…Store` pattern.

| Unit | Job | Production backing |
|---|---|---|
| `RoomDirectory` | Room membership and ownership. Atomic claim and release of ownership | Redis hashes + Lua scripts; expiry refreshed by heartbeats |
| `ReplicaBus` | Deliver to a connection on any replica; close a connection; broadcast `key-changed` | Redis pub/sub: one inbox channel per replica plus one broadcast channel |
| `LocalSockets` | This replica's live WebSockets (connection id → sender). The only per-process state | Memory |
| `SessionStore` | Pairing/OTP sessions | Redis hash per session |
| `VoiceSessionStore` | Voice sessions and the reply wait | Redis hash per session + a pub/sub channel per wait |
| `RtcSessionStore` | RTC sessions | Redis hash per session |
| `KeyCache` | Astation public keys | Memory, loaded from Postgres; changes announced on the bus |
| `RateLimiter` | Per-IP limits | Redis counters |

**Mode selection:** `REDIS_URL` set → Redis versions. Unset → in-memory
versions, exactly today's single-instance behavior (like `DATABASE_URL`
today). Running more than one replica without `REDIS_URL` is refused at
startup when `RELAY_REPLICAS_EXPECTED > 1`, and logged loudly otherwise.

**Replica identity:** each process picks a random `replica_id` at startup
and keeps `replica:<id>` alive in Redis (refreshed every 10 s, expiry 30 s).
Any directory entry pointing at a replica without a live presence key is
treated as gone.

## Redis keys

All keys are prefixed `relay:` so the Valkey instance can be shared safely
if ever needed.

| Key | Type | Contents | Expiry |
|---|---|---|---|
| `relay:replica:<replica_id>` | string | started-at | 30 s, refreshed every 10 s |
| `relay:replicas` | sorted set | Presence index: member `replica_id`, score = its expiry (unix seconds). Replicas list peers from it instead of scanning `relay:replica:*` | Entries past their score are ignored and trimmed on refresh |
| `relay:room:<code>` | hash | `owner_conn`, `owner_replica`, `verified`, `hostname`, `created_at`, `paired` | 10 min while unpaired (today's `ROOM_EXPIRY_SECS`); refreshed by heartbeats once connected |
| `relay:room:<code>:atems` | hash | `atem_id` → `connection_id\|replica_id` | Same as the room |
| `relay:room:<code>:pending` | hash | `connection_id` → `replica_id` | Same as the room |
| `relay:session:<id>` | hash | Pairing/OTP session fields | Pending: until its 5-min `expires_at` + 60 s (clients still see `expired`/`410`); granted or denied: 7 days, refreshed on each `?session=` connect |
| `relay:voice:<id>` | hash | Status, bounded text buffer, last activity | 60 s of inactivity |
| `relay:voice:<id>:reply` | string | The Atem's answer, if it arrived before anyone waited | 30 s |
| `relay:rtc:<id>` | hash | Session, participants (JSON), `next_uid` | 4 h |
| `relay:rl:<bucket>:<ip>:<minute>` | counter | Requests in that minute | 2 min |

Channels:

| Channel | Carries |
|---|---|
| `relay:inbox:<replica_id>` | `deliver {connection_ids, frame}` (one per target replica, fanned out locally), `close {connection_id, code, reason}` |
| `relay:voice-reply:<id>` | The Atem's answer for a waiting voice request |
| `relay:broadcast` | `key-changed {astation_id}`, `room-changed {code}` |

## Rooms and message flow

### Connect

On whichever replica receives the socket:

- **Atem** (`role=atem&code=C&atem_id=A`): check `relay:room:C` exists, as
  today (404 otherwise), then set `atems[A] = connection|replica`. Send the
  owner `relay_event: connected` through the bus.
- **Astation** (`role=astation&code=C`):
  - **Code without a registered key (legacy):** claim ownership with a Lua
    script. If an unverified owner exists, replace it, as today, and send
    `close` to its connection.
  - **Code with a registered key:** add to `:pending` and send the challenge.
    On a valid `relayAuth`, promote with one script: "set owner = me,
    verified = true, remove me from pending; return the previous owner".
    Then send `close` to the previous owner's connection. Two replicas can't
    both win.

The auth state machine (`Legacy`, `Pending`, `Verified`), the 10 s challenge
deadline and the binding messages stay on the replica holding the Astation's
socket, unchanged. Bindings already go to Postgres.

### Frames

- **Atem → Astation:** look up the owner; deliver locally, or publish
  `deliver` to the owner's replica inbox. Envelope unchanged
  (`{atem_id, connection_id, payload}`).
- **Astation → one Atem** (`atem_id` + `connection_id`): look up the Atem;
  drop if the connection id is stale (today's generation check); deliver
  locally or through the bus.
- **Astation → all Atems** (no `atem_id`): group the room's Atems by replica
  and publish one `deliver` per replica, which fans out locally.
- **Relay-generated frames** (`relayAuthChallenge`, `relayAuthResult`,
  `relayAck`, `relay_event`): produced on the replica holding the target
  socket, or sent through the bus when the target is elsewhere
  (`relay_event` to a remote owner).

**Cache:** a replica caches the directory entries of rooms it has local
sockets in. Changes to a room publish `room-changed {code}` and those
replicas refresh. The steady-state path is one local lookup plus at most one
publish per frame.

**Ordering:** Redis keeps order per publisher and channel. One
Astation → Atem stream always goes from one replica to one inbox, so order
is kept, as today.

### Disconnect and cleanup

- A closing socket removes its own entry (owner, Atem, or pending) with a
  script that checks the connection id, so a stale close can't remove a
  newer connection. The owner gets `relay_event: disconnected`, as today.
- Unpaired rooms expire through Redis (10 min). No sweep loop.
- Entries left by a crashed replica are ignored once its presence key
  expires, and overwritten when its clients reconnect.

### Pair endpoints

`POST /api/pair`, `GET /api/pair/:code` and `DELETE /api/pair/:code` read
and write `RoomDirectory`. `DELETE` still returns 409 for keyed rooms, and
otherwise sends `close` to the owner wherever it is.

## Sessions, voice, keys and rate limits

**Pairing/OTP sessions:** `relay:session:<id>` with the same 5-minute
expiry. Grant and deny are Lua scripts that only apply while the session is
pending, so two concurrent clicks can't both apply. Polling and the
`?session=` WebSocket work on any replica. The sweep loop is removed.

**Voice sessions:**

- Session data moves to `relay:voice:<id>`. The transcript buffer gets a size
  cap (64 KB); it's unbounded today.
- **The wait:** the replica handling `/api/llm/chat` first subscribes to
  `relay:voice-reply:<id>`, then checks `relay:voice:<id>:reply` for an
  answer that already arrived, then waits up to 30 s. Subscribing before
  checking means an answer can't slip through in between.
- `/api/voice-sessions/response` (any replica) stores the answer in `:reply`
  and publishes it. A timeout still returns 504 after 30 s.

**RTC sessions:** `relay:rtc:<id>` with a 4-hour expiry. `join` is a Lua
script that checks the 8-participant cap and takes `next_uid` atomically,
so concurrent joins on different replicas can't exceed the cap or share a
uid.

**Astation key cache:**

- Loaded from Postgres at startup, as today. Postgres stays authoritative.
- On registration, or on a mismatch re-read that finds a new key, the
  replica updates its cache and publishes `key-changed {astation_id}`.
  Other replicas re-read that one key from Postgres.
- This fixes a known issue: after an admin reset, the old key kept verifying
  until the relay restarted. Now every replica drops it immediately.
- New admin command `station-relay-server admin forget-key <astation_id>`:
  deletes the key in Postgres and publishes `key-changed`; every replica
  drops the key and disconnects that Astation's live verified socket. The
  runbook uses it.
  Deleting the row by hand in SQL still works, but then the replicas must be
  restarted.

**Rate limits:** the same limits (60/min for grant, 600/min general) as
fixed one-minute windows in Redis (`INCR` + `EXPIRE`), so N replicas don't
allow N× the requests. If Redis is unreachable they fall back to per-replica
limits (fail open), so a Redis blip doesn't lock everyone out.

**Background tasks:** mostly replaced by Redis expiry. Anything left is
idempotent and runs on every replica; no leader election.

## Failure handling

| Failure | Behavior |
|---|---|
| A replica crashes | Its sockets drop; clients reconnect with their existing backoff to healthy replicas. An Atem's new connection id replaces its entry. A keyed Astation re-verifies and its promotion evicts the stale owner; a legacy one replaces it. No one waits for the dead replica's entries to expire. Frames in flight to the dead replica are lost, as with any dropped socket today |
| Redis unreachable | New WebSockets are refused (close with a reconnect code), and the pairing, voice and RTC endpoints return 503. `/health` reports it. Vault and Atem Memory keep working (Postgres only). Rate limits fall back to per replica. Nothing durable is lost; rooms rebuild as clients reconnect |
| Postgres unreachable | Unchanged from today: vault and memory return 503; verification from the key cache keeps working; registrations are rejected |
| A slow client | See "Bounded send queues" below |

Redis calls on the connect path get a timeout (as identity-store calls do
today, 3 s), so a slow Redis can't stall the accept loop.

## Deploys

**SIGTERM drain:**

1. Fail `/health` so nginx stops sending new connections.
2. Close local sockets with close code 1012 ("service restart").
3. Remove this replica's directory entries and presence key.
4. Exit.

Clients reconnect to the other replicas within a second or two.

**Coolify:**

- Two applications, `relay-a` and `relay-b`, from the same image, both on the
  `coolify` network with the `station-relay-server` alias.
- `deploy-station.yml` updates them one at a time, waiting for each to be
  healthy before the next.
- **nginx** re-resolves the alias every 10 s (`resolver … valid=10s`, as
  today) and balances across all returned addresses. `proxy_next_upstream`
  retries a replica that refuses a connection.

**Valkey on Coolify:**

- On the private `coolify` network only, with no public port, password
  protected. `REDIS_URL` lives in Coolify secrets.
- `maxmemory-policy noeviction`: live state must never be dropped silently.
  If memory runs out, writes fail loudly instead.
- No persistence and no backup: it holds only live state.
- **Sensitive:** it holds pairing session ids, and a pending one can
  authorize a WebSocket. Restrict access like the database.

**Rollout,** each step reversible:

1. Deploy Valkey.
2. Deploy the new relay with `REDIS_URL`, still one instance; verify.
3. Add `relay-b`.

Rollback: remove `relay-b`, then unset `REDIS_URL` (back to in-memory mode).
The Postgres schema doesn't change.

## Scaling to 10k+

Working target: **30k WebSockets** (10k Astations + ~20k Atems) across two or
more replicas.

1. **Bounded send queues.** Each connection's queue gets a cap (1,000 frames
   or 4 MB). A client whose queue stays full for 10 s is closed with a
   reconnect code. Today's queues are unbounded, so one stalled client can
   grow memory without limit.
2. **Connection limits.** A per-IP limit on `/ws` connections and a cap on
   pending Astation sockets per room. These close the two open follow-ups
   from the relay identity work.
3. **Metrics** at `/metrics` (Prometheus), per replica: sockets by role,
   rooms, bus publish/receive rates, Redis latency, slow-client closes,
   rate-limit rejections.
4. **Load test.** A small Rust client (`relay-server/loadtest/`) that opens
   30k sockets across the replicas, pairs them into rooms, and sends
   realistic traffic. Pass criteria: p99 frame latency under 100 ms, no
   drops, stable memory over 30 minutes. Run it before claiming 10k and
   before raising any limit.
5. **Sizing.** Each replica's Postgres pool times the number of replicas
   stays under Postgres's `max_connections`. One Valkey handles this load
   (100k+ ops/s) comfortably.

## Testing

- **Units, in memory:** each unit gets tests against its in-memory version,
  reusing today's relay tests.
- **Redis versions:** the same tests against Valkey in Docker, as ignored
  tests like today's Postgres suites. CI's relay job adds a Valkey service
  and runs them.
- **Two relays in one test process,** sharing Redis and Postgres, with the
  Astation and Atems deliberately on different replicas:
  - chat both ways, unicast and broadcast, with order kept;
  - stale connection ids dropped;
  - pending on replica 1 → verify → evicting a verified owner on replica 2;
  - two Astations racing for ownership: exactly one wins;
  - pairing: create on 1, grant on 2, poll on 1, WebSocket on 2;
  - a voice wait on 1 answered on 2, the answer arriving before the wait,
    and the 30 s timeout;
  - concurrent RTC joins across replicas: cap holds, uids unique;
  - `forget-key` and registration reaching both replicas at once;
  - killing a replica: clients reconnect, rooms recover;
  - Redis down: 503s and a failing `/health`, while vault and memory work;
  - SIGTERM drain: close 1012, entries removed.
- **Production check:** `verify-station.mjs` also requires `/health` to show
  Redis connected and more than one live replica (`/health` gains
  `redis: "ok"` and `replicas: <n>`).

## Delivery order

| Step | Content | Gives |
|---|---|---|
| 1 | Units behind traits, in-memory versions; relay refactored onto them with no behavior change | Same relay, testable seams |
| 2 | Redis versions, Lua scripts, `ReplicaBus` | |
| 3 | Multi-replica tests, CI Valkey service | |
| 4 | SIGTERM drain, `admin forget-key`, `/health` fields | |
| 5 | Deploy: Valkey → one relay with Redis → `relay-b`; deploy workflow and `verify-station.mjs` updates; DEPLOY.md | **Failover** |
| 6 | Bounded queues, connection limits, metrics, load test | **10k+ readiness** |
