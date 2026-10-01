# Relay multi-replica: implementation plan

> For the implementer: work task by task, in order. Every task is test-first:
> write the test, run it and watch it fail, implement, run it and watch it
> pass, commit. Do not skip the "run-fail" step. Commit only what the task
> lists. Every commit message ends with the line
> `🤖 Built with SMT <smt@agora.build>`.

**Goal.** Run the relay (`relay-server/`) as several replicas behind the
webapp, first for failover (2 replicas on Volumetric), later for 10k+ users
(~30k WebSockets), with any replica able to serve any request.

**Architecture.** Stateless replicas plus Redis (Valkey). Each replica keeps
only its own live sockets (`LocalSockets`). Everything shared moves behind a
trait with an in-memory version (default, today's single-instance behavior)
and a Redis version (selected by `REDIS_URL`): `RoomDirectory`, `ReplicaBus`,
`SessionStore` backend, `VoiceSessionStore` backend, `RtcSessionStore`
backend, `KeyCache` (memory, changes announced on the bus), and a shared
`RateLimiter`. Replicas reach each other's sockets through Redis pub/sub
(`relay:inbox:<replica>`, `relay:broadcast`, `relay:voice-reply:<id>`).
Postgres stays the only durable store and is not changed.

**Tech stack.** Rust 2021 (no let-chains), axum 0.7, tokio 1, sqlx 0.7
(Postgres), `redis` 0.27 (`aio`, `tokio-comp`, `connection-manager`,
`script`), tower_governor 0.4, tokio-tungstenite 0.24 (tests, load test).
Valkey 8 in production, CI and local tests.

**Spec (binding).** `docs/specs/2026-09-30-relay-multi-replica.md`.

**Redis client choice.** `redis` 0.27 (redis-rs). It is the most used async
Redis client for tokio; `ConnectionManager` reconnects automatically and is a
cheap `Clone` handle for commands; `aio::PubSub` gives a dedicated pub/sub
connection (`subscribe`, `psubscribe`, `into_on_message`); `Script` runs Lua
through `EVALSHA` and reloads on `NOSCRIPT`. It is already in the local cargo
registry (0.27.6) and its MSRV (1.70) is below the Docker toolchain (1.88).
`fred` would also work but adds a larger API surface we do not need.

## Global constraints

- Branch `feat/relay-multi-replica` off Astation `main`. All paths below are
  relative to the Astation repo root unless they start with `src/`, which
  means `relay-server/src/`.
- Client protocol unchanged byte for byte: frames, envelopes
  (`{atem_id, connection_id, payload}`), `relay_event`, `relayAuth*`,
  `relayAck`, HTTP status codes and bodies. The only new client-visible
  behavior: close code 1012 on drain, close code 1013 when shared state is
  unavailable or a client is too slow, HTTP 503 when Redis is down, HTTP 429
  from the new per-IP WebSocket limit.
- Redis keys and channels exactly as the spec's tables, prefix `relay:`.
  Client-supplied id parts are percent-escaped (`%`→`%25`, `:`→`%3A`; see
  pre-flight note 6); real ids never contain either character.
- Step 1 (Tasks 1–9) lands with no behavior change and every existing test
  green before any Redis code exists.
- `AppState` keeps its seven fields and their types. (25 test sites build it
  literally, one of them in `knowledge_routes.rs`, which another branch owns.)
- Do not touch `src/knowledge_store.rs`, `src/knowledge_routes.rs`, or
  `migrations/`. No migration is added.
- Every Redis call on the connect path is bounded by a 3 s timeout
  (`REDIS_TIMEOUT`), like identity-store calls today.
- Redis test suites are `#[ignore]` and read `TEST_REDIS_URL` (localhost
  only; the harness runs `FLUSHDB`). Every Redis-backed test's name contains
  `redis`, so `cargo test redis -- --ignored` selects exactly them.
  Throwaway Valkey, always removed afterwards:

  ```bash
  docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
  cd relay-server
  TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
  docker rm -f relay-test-valkey
  ```
- `cargo test` (no `--ignored`) must stay green after every task; `cargo
  clippy --all-targets` must not gain warnings.

## Pre-flight notes

Spec-versus-code mismatches and how this plan resolves them:

1. **AppState is built literally in 25 places** (including
   `knowledge_routes.rs`). The plan keeps `AppState` unchanged:
   `SessionStore`, `VoiceSessionStore` and `RtcSessionStore` stay concrete
   handle types, now wrapping `Arc<dyn …Backend>`, with the same `::new()`
   (in-memory). The per-process cluster pieces (directory, bus, local
   sockets, key cache, rate limiter, health, connection limiter) live inside
   `RelayHub`, so `RelayHub::new()` keeps working at every call site.
2. **Granted pairing sessions never expire today.** The sweep only removes
   expired *pending* sessions; granted and denied ones stay in memory
   forever, and `?session=` WebSockets rely on that. The spec says "same
   5-minute expiry". Resolution: in Redis, a pending session lives until
   `expires_at + 60 s` (the sweep ran every 60 s, so clients still see
   `expired` and `410` as today), and a granted or denied session lives
   7 days, refreshed on each `?session=` connect. In-memory mode keeps
   today's exact behavior.
3. **Rate limits.** Today `tower_governor` enforces a token bucket per
   replica (60/min with burst 10 for grant, 600/min with burst 20 general).
   It stays exactly as is on every route. The new shared limiter adds the
   same limits as fixed one-minute Redis windows in front of it. The
   in-memory `SharedRateLimiter` is a no-op, because with one replica the
   governor already is the whole limit (so step 1 changes nothing). "Fail
   open to per-replica limits" is then automatic: a Redis error allows the
   request and the governor still applies.
4. **Bus `deliver` carries a list.** The spec shows `deliver
   {connection_id, frame}` but also requires "one deliver per replica, which
   fans out locally" for broadcasts. The inbox message is
   `{"type":"deliver","connection_ids":[…],"frame":"…"}`. This is internal
   (replica to replica), not client protocol.
5. **Voice-reply subscription.** Each replica `PSUBSCRIBE`s
   `relay:voice-reply:*` once on its bus connection instead of a
   `SUBSCRIBE` per wait. A wait registers its local waiter *before* reading
   `relay:voice:<id>:reply`, which gives the spec's "subscribe before
   checking" guarantee. It also re-reads `:reply` every second as a safety
   net across a subscriber reconnect. Channel names are unchanged.
6. **Client-supplied ids in key names.** Room codes, voice session ids and
   the like come from query strings and headers. A room code `X:atems`
   would name room `X`'s Atem hash. Key parts are percent-escaped (`%`, `:`
   only). Real ids (pairing codes, `astation-…`, UUIDs) contain neither, so
   they appear verbatim as in the spec's table.
7. **Room expiry in Redis.** A room gets `EXPIRE 600` on creation, and
   again when an Astation claims it or goes pending. Otherwise a pairing room
   created 9+ minutes before its Astation connects would expire before the
   first heartbeat. Every 60 s each replica refreshes the rooms where it
   holds an Astation socket. It also closes its local Atem sockets whose room
   no longer exists: today's sweep removed the room and so dropped those
   sockets too.
8. **Drain with open-source nginx.** nginx has no active health checks, and
   Docker DNS keeps returning an unhealthy container, so failing `/health`
   alone does not stop new connections. A draining replica therefore also
   answers `/ws` with 503, and nginx gets `proxy_next_upstream … http_503` on
   `/ws` and `/health` so it retries another replica (GET is idempotent).
   Other HTTP APIs keep serving while draining, since their state is in
   Redis.
9. **"New WebSockets are refused (close with a reconnect code)."** Before the
   upgrade the relay answers HTTP 503 (nginx then tries another replica).
   After the upgrade it sends close code 1013 (try again later).
10. **"Two Astations racing for ownership: exactly one wins."** Today a later
    verified promotion replaces an earlier verified owner (an ordinary
    reconnect). The test asserts the resulting invariant: one final owner,
    the other socket closed, and the winner's promotion names the loser as
    the previous owner.
11. **Tests that reach into internals.** Some tests use `hub.rooms`,
    `PairRoom`, `AtemConnection`, `promote_verified_astation`,
    `RtcSessionInner`, the voice store's `sessions` map, and
    `register_waiter`. Each is ported to the new seam in the task that
    removes the internal, with the same assertions. All other tests stay
    unchanged apart from a mechanical `.unwrap()` on now-fallible store
    calls, applied by the exact `perl` commands given.
12. **CI never ran the Postgres `#[ignore]` suites.** That stays as is. The
    two-relay tests share one in-process `InMemoryIdentityStore`, vault and
    knowledge store as their "shared Postgres" (same traits). The Postgres
    suites remain manual (README).
13. **Binary name.** The binary is `station-relay-server`, so the command is
    `station-relay-server admin forget-key <astation_id>` (a `docker exec`
    into any relay container). It needs `DATABASE_URL`; `REDIS_URL` is
    optional (without it, it tells you to restart).
14. **`/health` fields move earlier.** They land in step 2 (Task 11), not
    step 4, because step 3's "Redis down" test needs them. In-memory mode
    reports `"redis":"disabled","replicas":1`.
15. **Step 6 numbers the spec leaves open**, chosen here: at most 200
    concurrent `/ws` connections per client IP per replica
    (`RELAY_WS_MAX_PER_IP`, raise it for the load test), and at most 4
    pending Astation sockets per room. Client IP for `/ws` is
    `CF-Connecting-IP`, then the first `X-Forwarded-For` entry, then
    `X-Real-IP`, then the peer address.
16. **Concurrent plan (Atem Memory 1.1).** This plan does not touch
    `knowledge_store.rs`, `knowledge_routes.rs`, or `migrations/`. It adds a
    `delete_key` method to the `IdentityStore` trait in `identity_store.rs`,
    with a default body, so an `IdentityStore` test double added on the other
    branch still compiles after both merge. Merge order doesn't matter:
    `AppState` keeps its fields and constructors, so the other branch's
    `AppState { … }` literals and `SessionStore::new()`-style calls compile
    unchanged. If it adds calls to `state.sessions`, `state.voice_sessions` or
    `state.rtc_sessions` methods, those now return `Result` and need `?` or
    `.unwrap()` after rebasing.
17. **Metrics** are rendered by hand in the Prometheus text format (atomics,
    no new crate). `/metrics` is not proxied by nginx: scrape each relay
    container directly on the `coolify` network.

Risks:

- **Pub/sub is fire-and-forget.** A message published while a subscriber
  reconnects is lost. Mitigations: on resubscribe, a replica clears its room
  cache and reloads all keys from Postgres. The room cache entries also
  expire after 30 s. Frames are best effort anyway.
- **A Valkey restart drops all live state.** Everyone reconnects; nothing
  durable is lost (spec). `maxmemory-policy noeviction` makes an
  out-of-memory condition fail loudly instead of silently dropping rooms.
- **Redis unreachable at startup.** The relay retries for about 30 s, then
  exits so Coolify restarts it. Replicas that are already running keep
  serving vault and memory.
- **Rolling deploy.** It only works when both relay apps are healthy before
  the next update. The workflow waits for `/health` to report the expected
  replica count after each relay deploy.
- **Client IP spoofing.** `X-Forwarded-For` is client-controlled unless
  Cloudflare overwrites it. The new WebSocket limiter prefers
  `CF-Connecting-IP`; the existing governor keeps its current
  `SmartIpKeyExtractor` (unchanged behavior).
- **Load-test host limits.** 30k sockets from one host need `ulimit -n
  65535` and a wide `net.ipv4.ip_local_port_range`, or several source hosts.

## File structure

```
relay-server/
  Cargo.toml                         + redis, tokio test-util (dev)
  src/
    main.rs                          mod list, router (shared limiter, /metrics), mode
                                     selection, health fields, drain, `admin` dispatch
    admin.rs                         NEW  `admin forget-key`
    relay.rs                         RelayHub over the cluster units; handle_ws rewritten;
                                     tests ported; test helpers made pub(crate)
    session_store.rs                 SessionStore handle + SessionBackend + InMemory
    voice_session.rs                 VoiceSessionStore handle + VoiceBackend + InMemory,
                                     ReplyWaiters, 64 KB buffer cap
    rtc_session.rs                   RtcSessionStore handle + RtcBackend + InMemory
    routes.rs, voice_routes.rs,
    llm_proxy.rs                     handlers map StoreError → 503
    identity_store.rs                + IdentityStore::delete_key
    vault_routes.rs                  one test line gets `.unwrap()`
    redis_multi_replica_tests.rs     NEW  two relays in one process (#[cfg(test)])
    cluster/
      mod.rs                         StoreError, ConnRef, replica ids, module list
      local.rs                       LocalSockets (+ bounded queues in step 6)
      bus.rs                         InboxMessage, BroadcastMessage, BusEvent,
                                     ReplicaBus, LoopbackBus, apply_inbox
      directory.rs                   RoomInfo, RoomDirectory, InMemoryRoomDirectory,
                                     shared scenarios
      keys.rs                        KeyCache
      ratelimit.rs                   SharedRateLimiter, NoopRateLimiter, middleware
      health.rs                      ClusterHealth, SingleInstance
      limits.rs                      WsConnLimiter (step 6)
      metrics.rs                     Metrics + Prometheus rendering (step 6)
      redis/
        mod.rs                       RedisConn, connect_cluster, RedisCluster, test_support
        keys.rs                      key and channel names
        presence.rs                  RedisHealth (presence key, live replicas)
        bus.rs                       RedisBus (publish + subscriber task)
        directory.rs                 RedisRoomDirectory (Lua)
        sessions.rs                  RedisSessionBackend (Lua grant/deny)
        voice.rs                     RedisVoiceBackend (Lua, reply wait)
        rtc.rs                       RedisRtcBackend (Lua join)
        ratelimit.rs                 RedisRateLimiter
  loadtest/                          NEW  separate crate: relay-loadtest
    Cargo.toml, Cargo.lock, src/main.rs
  README.md, SECURITY.md             docs
webapp/nginx.conf                    proxy_next_upstream on /ws and /health
webapp/tests/nginx.test.js           assertions for the above
.github/workflows/ci.yml             Valkey service, Redis suites, loadtest build
.github/workflows/deploy-station.yml relay-a, health wait, optional relay-b, health wait
.github/scripts/verify-station.mjs   redis + replica checks, --wait-health
.github/scripts/verify-station.test.mjs NEW
DEPLOY.md                            Valkey, relay-a/relay-b, rollout, forget-key, sizing
```

Task map (spec steps → tasks):

| Spec step | Tasks |
|---|---|
| 1 Units behind traits, in-memory, no behavior change | 1 LocalSockets · 2 ReplicaBus · 3 RoomDirectory · 4 KeyCache · 5 RelayHub refactor · 6 SessionStore · 7 VoiceSessionStore · 8 RtcSessionStore · 9 SharedRateLimiter |
| 2 Redis versions, Lua, ReplicaBus | 10 RedisConn + keys + harness · 11 health + presence + `/health` · 12 RedisBus · 13 RedisRoomDirectory · 14 room cache + dispatcher · 15 sessions · 16 voice · 17 RTC · 18 rate limiter · 19 mode selection |
| 3 Multi-replica tests, CI Valkey | 20 harness · 21 rooms and chat · 22 sessions, voice, RTC · 23 failures · 24 CI |
| 4 Drain, forget-key, `/health` | 25 SIGTERM drain · 26 `admin forget-key` |
| 5 Deploy | 27 nginx · 28 verify-station · 29 deploy workflow · 30 docs · manual Coolify checklist |
| 6 10k+ readiness | 31 bounded queues · 32 connection limits · 33 metrics · 34 load test |

---

## Step 1 — units behind traits, in-memory, no behavior change

### Task 1: `cluster` module and `LocalSockets`

**Files:** create `src/cluster/mod.rs`, `src/cluster/local.rs`; modify
`src/main.rs` (module list).

**Interfaces.**
Produces:
- `pub enum StoreError { Unavailable(String) }` (Display, Error, Clone, Eq)
- `pub struct ConnRef { pub conn: String, pub replica: String }` with
  `new(&str, &str)`, `encode(&self) -> String` (`conn|replica`),
  `decode(&str) -> Option<ConnRef>`; derives `Debug, Clone, PartialEq, Eq,
  Hash, PartialOrd, Ord`
- `pub fn new_replica_id() -> String` (12 lowercase hex);
  `pub const SINGLE_REPLICA_ID: &str = "local"`
- `pub enum SocketRole { Atem { atem_id: String }, Astation }`
- `pub type CloseRequest = Option<(u16, String)>`
- `pub struct SocketOutbox { pub frames: mpsc::UnboundedReceiver<String>, pub close: watch::Receiver<CloseRequest> }`
- `LocalSockets`: `new()`, `register(&self, &str, &str, SocketRole) -> SocketOutbox`,
  `send(&self, &str, String) -> bool`, `contains(&self, &str) -> bool`,
  `evict(&self, &str) -> bool`, `close_with(&self, &str, u16, &str) -> bool`,
  `connections_in_room(&self, &str) -> Vec<(String, SocketRole)>`,
  `codes_with_astations(&self) -> Vec<String>`, `codes_with_atems(&self) -> Vec<String>`,
  `connection_ids(&self) -> Vec<String>`, `count_by_role(&self) -> (usize, usize)` (atems, astations),
  `len(&self) -> usize`, `is_empty(&self) -> bool`

- [ ] **Step 1: create the branch.**

  ```bash
  cd /home/guohai/Dev/Agora.Build/Astation
  git checkout main && git pull --ff-only
  git checkout -b feat/relay-multi-replica
  ```

- [ ] **Step 2: write the tests.** Create `src/cluster/local.rs` containing
  only the test module for now:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[tokio::test]
      async fn frames_reach_a_registered_socket_only() {
          let local = LocalSockets::new();
          let mut outbox = local.register("c1", "room", SocketRole::Astation);
          assert!(local.send("c1", "hello".into()));
          assert!(!local.send("c2", "nobody".into()));
          assert_eq!(outbox.frames.recv().await.as_deref(), Some("hello"));
      }

      #[tokio::test]
      async fn evict_flushes_queued_frames_then_ends() {
          let local = LocalSockets::new();
          let mut outbox = local.register("c1", "room", SocketRole::Astation);
          local.send("c1", "last".into());
          assert!(local.evict("c1"));
          assert!(!local.contains("c1"));
          assert_eq!(outbox.frames.recv().await.as_deref(), Some("last"));
          assert_eq!(outbox.frames.recv().await, None);
          assert!(outbox.close.changed().await.is_err(), "evict sends no close code");
      }

      #[tokio::test]
      async fn close_with_carries_the_code() {
          let local = LocalSockets::new();
          let mut outbox = local.register("c1", "room", SocketRole::Astation);
          assert!(local.close_with("c1", 1012, "restart"));
          assert!(outbox.close.changed().await.is_ok());
          assert_eq!(*outbox.close.borrow(), Some((1012, "restart".to_string())));
          assert!(!local.close_with("c1", 1012, "again"), "already gone");
      }

      #[test]
      fn room_and_role_queries() {
          let local = LocalSockets::new();
          let _a = local.register("a1", "room-a", SocketRole::Astation);
          let _b = local.register("t1", "room-a", SocketRole::Atem { atem_id: "atem-1".into() });
          let _c = local.register("t2", "room-b", SocketRole::Atem { atem_id: "atem-2".into() });
          assert_eq!(local.codes_with_astations(), vec!["room-a".to_string()]);
          assert_eq!(
              local.codes_with_atems(),
              vec!["room-a".to_string(), "room-b".to_string()]
          );
          let mut in_a: Vec<String> = local
              .connections_in_room("room-a")
              .into_iter()
              .map(|(id, _)| id)
              .collect();
          in_a.sort();
          assert_eq!(in_a, vec!["a1".to_string(), "t1".to_string()]);
          assert_eq!(local.count_by_role(), (2, 1));
          assert_eq!(local.len(), 3);
          let mut ids = local.connection_ids();
          ids.sort();
          assert_eq!(ids, vec!["a1".to_string(), "t1".to_string(), "t2".to_string()]);
      }
  }
  ```

  Create `src/cluster/mod.rs` with its tests:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn conn_ref_round_trips() {
          let conn = ConnRef::new("43c8a181-6567-49ae-9191-8e103a66cc55", "a1b2c3d4e5f6");
          assert_eq!(conn.encode(), "43c8a181-6567-49ae-9191-8e103a66cc55|a1b2c3d4e5f6");
          assert_eq!(ConnRef::decode(&conn.encode()), Some(conn));
          assert_eq!(ConnRef::decode("no-separator"), None);
          assert_eq!(ConnRef::decode("|replica"), None);
          assert_eq!(ConnRef::decode("conn|"), None);
      }

      #[test]
      fn replica_ids_are_short_random_hex() {
          let a = new_replica_id();
          assert_eq!(a.len(), 12);
          assert!(a.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
          assert_ne!(a, new_replica_id());
      }
  }
  ```

  In `src/main.rs`, add `mod cluster;` directly after `mod auth;`.

- [ ] **Step 3: run and watch it fail.**
  `cd relay-server && cargo test cluster::` fails to compile
  (`LocalSockets`, `ConnRef` … not found).

- [ ] **Step 4: implement.** Put this above the test module in
  `src/cluster/mod.rs`:

  ```rust
  //! Building blocks for running the relay as several replicas
  //! (docs/specs/2026-09-30-relay-multi-replica.md). Each shared unit is a
  //! trait with an in-memory version (tests, single instance, local dev) and
  //! a Redis version (production, `REDIS_URL`).

  pub mod local;

  use std::fmt;

  /// Shared relay state (Redis) failed or timed out. HTTP handlers answer 503;
  /// a WebSocket closes with 1013 (try again later).
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum StoreError {
      Unavailable(String),
  }

  impl fmt::Display for StoreError {
      fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
          match self {
              StoreError::Unavailable(detail) => write!(f, "shared state unavailable: {detail}"),
          }
      }
  }

  impl std::error::Error for StoreError {}

  /// One WebSocket on one replica. Stored in Redis as `connection_id|replica_id`.
  #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
  pub struct ConnRef {
      pub conn: String,
      pub replica: String,
  }

  impl ConnRef {
      pub fn new(conn: &str, replica: &str) -> Self {
          Self {
              conn: conn.to_string(),
              replica: replica.to_string(),
          }
      }

      pub fn encode(&self) -> String {
          format!("{}|{}", self.conn, self.replica)
      }

      pub fn decode(value: &str) -> Option<Self> {
          let (conn, replica) = value.split_once('|')?;
          (!conn.is_empty() && !replica.is_empty()).then(|| Self::new(conn, replica))
      }
  }

  /// A random id for this process: 12 lowercase hex characters.
  pub fn new_replica_id() -> String {
      uuid::Uuid::new_v4().simple().to_string()[..12].to_string()
  }

  /// The replica id of in-memory (single-instance) mode.
  pub const SINGLE_REPLICA_ID: &str = "local";
  ```

  Put this above the test module in `src/cluster/local.rs`:

  ```rust
  //! This replica's live WebSockets: connection id → sender. The only
  //! per-process relay state. The map holds each socket's only sender, so
  //! removing an entry ends that socket: its writer flushes what is queued,
  //! then closes (exactly how a replaced socket closes today).

  use std::collections::{BTreeSet, HashMap};
  use std::sync::{Arc, Mutex, MutexGuard};
  use tokio::sync::{mpsc, watch};

  /// What a socket is, for room-wide operations (expiry, delete, drain).
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum SocketRole {
      Atem { atem_id: String },
      Astation,
  }

  /// A request to close with this code and reason, sent to the writer.
  pub type CloseRequest = Option<(u16, String)>;

  struct LocalConn {
      tx: mpsc::UnboundedSender<String>,
      close: watch::Sender<CloseRequest>,
      code: String,
      role: SocketRole,
  }

  /// The receiving half, owned by the socket's writer task.
  pub struct SocketOutbox {
      pub frames: mpsc::UnboundedReceiver<String>,
      pub close: watch::Receiver<CloseRequest>,
  }

  #[derive(Clone, Default)]
  pub struct LocalSockets {
      conns: Arc<Mutex<HashMap<String, LocalConn>>>,
  }

  impl LocalSockets {
      pub fn new() -> Self {
          Self::default()
      }

      fn lock(&self) -> MutexGuard<'_, HashMap<String, LocalConn>> {
          self.conns.lock().unwrap_or_else(|e| e.into_inner())
      }

      pub fn register(&self, connection_id: &str, code: &str, role: SocketRole) -> SocketOutbox {
          let (tx, frames) = mpsc::unbounded_channel();
          let (close, close_rx) = watch::channel(None);
          self.lock().insert(
              connection_id.to_string(),
              LocalConn {
                  tx,
                  close,
                  code: code.to_string(),
                  role,
              },
          );
          SocketOutbox {
              frames,
              close: close_rx,
          }
      }

      /// Queue a frame. False when the connection is not (or no longer) here.
      pub fn send(&self, connection_id: &str, frame: String) -> bool {
          match self.lock().get(connection_id) {
              Some(conn) => conn.tx.send(frame).is_ok(),
              None => false,
          }
      }

      pub fn contains(&self, connection_id: &str) -> bool {
          self.lock().contains_key(connection_id)
      }

      /// Drop the connection's sender: its writer flushes queued frames and
      /// closes without a close code (a replaced or evicted socket, as today).
      pub fn evict(&self, connection_id: &str) -> bool {
          self.lock().remove(connection_id).is_some()
      }

      /// Close with an explicit close code (1012 drain, 1013 try again later).
      pub fn close_with(&self, connection_id: &str, code: u16, reason: &str) -> bool {
          match self.lock().remove(connection_id) {
              Some(conn) => {
                  let _ = conn.close.send(Some((code, reason.to_string())));
                  true
              }
              None => false,
          }
      }

      pub fn connections_in_room(&self, code: &str) -> Vec<(String, SocketRole)> {
          self.lock()
              .iter()
              .filter(|(_, conn)| conn.code == code)
              .map(|(id, conn)| (id.clone(), conn.role.clone()))
              .collect()
      }

      fn codes_where(&self, astation: bool) -> Vec<String> {
          let codes: BTreeSet<String> = self
              .lock()
              .values()
              .filter(|conn| (conn.role == SocketRole::Astation) == astation)
              .map(|conn| conn.code.clone())
              .collect();
          codes.into_iter().collect()
      }

      /// Room codes where this replica holds an Astation socket (owner or pending).
      pub fn codes_with_astations(&self) -> Vec<String> {
          self.codes_where(true)
      }

      /// Room codes where this replica holds an Atem socket.
      pub fn codes_with_atems(&self) -> Vec<String> {
          self.codes_where(false)
      }

      pub fn connection_ids(&self) -> Vec<String> {
          self.lock().keys().cloned().collect()
      }

      /// (Atem sockets, Astation sockets) on this replica.
      pub fn count_by_role(&self) -> (usize, usize) {
          let conns = self.lock();
          let astations = conns
              .values()
              .filter(|conn| conn.role == SocketRole::Astation)
              .count();
          (conns.len() - astations, astations)
      }

      pub fn len(&self) -> usize {
          self.lock().len()
      }

      pub fn is_empty(&self) -> bool {
          self.lock().is_empty()
      }
  }
  ```

- [ ] **Step 5: run and watch it pass.** `cargo test cluster::` passes;
  `cargo test` passes (unchanged count plus 6).

- [ ] **Step 6: commit.**

  ```bash
  git add relay-server/src/cluster relay-server/src/main.rs
  git commit -m "feat(relay): LocalSockets, ConnRef, StoreError for multi-replica

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 2: `ReplicaBus` and the in-memory `LoopbackBus`

**Files:** create `src/cluster/bus.rs`; modify `src/cluster/mod.rs`.

**Interfaces.**
Consumes: `LocalSockets`, `StoreError` (Task 1).
Produces:
- `enum InboxMessage { Deliver { connection_ids: Vec<String>, frame: String }, Close { connection_id: String, code: Option<u16>, reason: String } }`
  (serde `tag = "type"`, kebab-case variant names)
- `enum BroadcastMessage { KeyChanged { astation_id: String }, RoomChanged { code: String } }`
- `fn apply_inbox(local: &LocalSockets, message: InboxMessage)`
- `#[async_trait] trait ReplicaBus: Send + Sync { fn backend_name(&self) -> &'static str; async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), StoreError>; async fn broadcast(&self, message: BroadcastMessage) -> Result<(), StoreError>; }`
- `struct LoopbackBus` with `new(replica_id: &str, local: LocalSockets) -> Self`

- [ ] **Step 1: write the tests** in a new `src/cluster/bus.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::local::SocketRole;
      use serde_json::json;

      #[test]
      fn messages_have_the_documented_shape() {
          let deliver = InboxMessage::Deliver {
              connection_ids: vec!["c1".into(), "c2".into()],
              frame: "{}".into(),
          };
          assert_eq!(
              serde_json::to_value(&deliver).unwrap(),
              json!({"type":"deliver","connection_ids":["c1","c2"],"frame":"{}"})
          );
          let close = InboxMessage::Close {
              connection_id: "c1".into(),
              code: Some(1012),
              reason: "restart".into(),
          };
          assert_eq!(
              serde_json::to_value(&close).unwrap(),
              json!({"type":"close","connection_id":"c1","code":1012,"reason":"restart"})
          );
          let evict = InboxMessage::Close {
              connection_id: "c1".into(),
              code: None,
              reason: String::new(),
          };
          assert_eq!(
              serde_json::to_value(&evict).unwrap(),
              json!({"type":"close","connection_id":"c1","code":null,"reason":""})
          );
          assert_eq!(
              serde_json::to_value(BroadcastMessage::KeyChanged { astation_id: "a".into() }).unwrap(),
              json!({"type":"key-changed","astation_id":"a"})
          );
          assert_eq!(
              serde_json::to_value(BroadcastMessage::RoomChanged { code: "X".into() }).unwrap(),
              json!({"type":"room-changed","code":"X"})
          );
          let parsed: InboxMessage = serde_json::from_value(serde_json::to_value(&deliver).unwrap()).unwrap();
          assert_eq!(parsed, deliver);
      }

      #[tokio::test]
      async fn loopback_applies_its_own_inbox() {
          let local = LocalSockets::new();
          let bus = LoopbackBus::new("local", local.clone());
          let mut a = local.register("a", "room", SocketRole::Astation);
          let mut b = local.register("b", "room", SocketRole::Astation);

          bus.send_inbox(
              "local",
              InboxMessage::Deliver {
                  connection_ids: vec!["a".into(), "b".into()],
                  frame: "x".into(),
              },
          )
          .await
          .unwrap();
          assert_eq!(a.frames.recv().await.as_deref(), Some("x"));
          assert_eq!(b.frames.recv().await.as_deref(), Some("x"));

          bus.send_inbox(
              "local",
              InboxMessage::Close { connection_id: "a".into(), code: None, reason: String::new() },
          )
          .await
          .unwrap();
          assert!(!local.contains("a"));

          bus.send_inbox(
              "local",
              InboxMessage::Close { connection_id: "b".into(), code: Some(1012), reason: "restart".into() },
          )
          .await
          .unwrap();
          assert!(b.close.changed().await.is_ok());
          assert_eq!(*b.close.borrow(), Some((1012, "restart".to_string())));

          // Single-instance mode has no other replica and nobody to broadcast to.
          bus.send_inbox(
              "elsewhere",
              InboxMessage::Deliver { connection_ids: vec!["zzz".into()], frame: "x".into() },
          )
          .await
          .unwrap();
          bus.broadcast(BroadcastMessage::KeyChanged { astation_id: "a".into() })
              .await
              .unwrap();
          assert_eq!(bus.backend_name(), "memory");
      }
  }
  ```

  Add `pub mod bus;` above `pub mod local;` in `src/cluster/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::bus` does not
  compile.

- [ ] **Step 3: implement** above the tests in `src/cluster/bus.rs`:

  ```rust
  //! Replica-to-replica delivery (spec: "Redis keys" → channels).
  //! `relay:inbox:<replica_id>` carries `InboxMessage`s for one replica's
  //! sockets; `relay:broadcast` carries `BroadcastMessage`s for all replicas.

  use async_trait::async_trait;
  use serde::{Deserialize, Serialize};

  use super::local::LocalSockets;
  use super::StoreError;

  #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(tag = "type", rename_all = "kebab-case")]
  pub enum InboxMessage {
      /// Queue `frame` on each listed local connection (one publish per
      /// target replica, fanned out there).
      Deliver {
          connection_ids: Vec<String>,
          frame: String,
      },
      /// End a connection. `code: None` evicts it (queued frames flushed,
      /// plain close: a replaced socket today); `Some(c)` sends close code `c`.
      Close {
          connection_id: String,
          code: Option<u16>,
          reason: String,
      },
  }

  #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(tag = "type", rename_all = "kebab-case")]
  pub enum BroadcastMessage {
      /// An Astation key was registered, replaced or deleted: re-read it.
      KeyChanged { astation_id: String },
      /// A room's directory entry changed: drop any cached copy.
      RoomChanged { code: String },
  }

  /// Apply an inbox message to this replica's sockets.
  pub fn apply_inbox(local: &LocalSockets, message: InboxMessage) {
      match message {
          InboxMessage::Deliver { connection_ids, frame } => {
              for connection_id in connection_ids {
                  local.send(&connection_id, frame.clone());
              }
          }
          InboxMessage::Close { connection_id, code: None, .. } => {
              local.evict(&connection_id);
          }
          InboxMessage::Close { connection_id, code: Some(code), reason } => {
              local.close_with(&connection_id, code, &reason);
          }
      }
  }

  #[async_trait]
  pub trait ReplicaBus: Send + Sync {
      fn backend_name(&self) -> &'static str;
      /// Publish to one replica's inbox.
      async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), StoreError>;
      /// Publish to every replica (including this one).
      async fn broadcast(&self, message: BroadcastMessage) -> Result<(), StoreError>;
  }

  /// Single-instance bus: this replica's inbox is applied directly and there
  /// is no other replica to reach.
  pub struct LoopbackBus {
      replica_id: String,
      local: LocalSockets,
  }

  impl LoopbackBus {
      pub fn new(replica_id: &str, local: LocalSockets) -> Self {
          Self {
              replica_id: replica_id.to_string(),
              local,
          }
      }
  }

  #[async_trait]
  impl ReplicaBus for LoopbackBus {
      fn backend_name(&self) -> &'static str {
          "memory"
      }

      async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), StoreError> {
          if replica_id == self.replica_id {
              apply_inbox(&self.local, message);
          } else {
              tracing::debug!("No replica {} in single-instance mode; message dropped", replica_id);
          }
          Ok(())
      }

      async fn broadcast(&self, _message: BroadcastMessage) -> Result<(), StoreError> {
          Ok(())
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test cluster::bus`.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): ReplicaBus trait with in-memory loopback

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 3: `RoomDirectory` and `InMemoryRoomDirectory`

**Files:** create `src/cluster/directory.rs`; modify `src/cluster/mod.rs`.

**Interfaces.**
Consumes: `ConnRef`, `StoreError`.
Produces:
- `pub const ROOM_EXPIRY_SECS: i64 = 600;` `pub const IDENTITY_HOSTNAME: &str = "identity";`
- `pub struct RoomInfo { pub hostname: String, pub created_at: i64, pub owner: Option<ConnRef>, pub verified: bool, pub atems: BTreeMap<String, ConnRef>, pub pending: Vec<ConnRef> }`
  with `new(&str, i64)`, `is_empty(&self)`, `is_expired(&self, now: i64)`.
  `pending` is always sorted.
- `enum AtemJoin { NoRoom, Joined { replaced: Option<ConnRef>, owner: Option<ConnRef> } }`
- `struct OwnerClaim { pub replaced: Option<ConnRef>, pub atems: Vec<(String, ConnRef)> }`
- `enum Promotion { NoRoom, AlreadyOwner, NotPending { evicted: Option<ConnRef> }, Promoted { previous_owner: Option<ConnRef>, atems: Vec<(String, ConnRef)> } }`
- `struct AtemLeave { pub removed: bool, pub owner: Option<ConnRef>, pub room_removed: bool }`
- trait `RoomDirectory` (all `async`, all `-> Result<_, StoreError>`):
  `create_room(code, hostname, now) -> ()`, `ensure_room(code, hostname, now) -> bool` (created),
  `get(code) -> Option<RoomInfo>`, `join_atem(code, atem_id, &ConnRef) -> AtemJoin`,
  `claim_owner(code, &ConnRef, now) -> OwnerClaim`,
  `add_pending(code, &ConnRef, now, max_pending: usize) -> bool` (0 = no cap),
  `promote(code, &ConnRef, was_pending: bool) -> Promotion`,
  `leave_atem(code, atem_id, connection_id) -> AtemLeave`,
  `leave_astation(code, connection_id) -> bool` (room removed),
  `delete_room(code) -> Option<RoomInfo>`, `touch(code) -> bool` (exists),
  `exists(&[String]) -> Vec<bool>`, `remove_expired(now) -> Vec<String>`;
  plus `fn backend_name(&self) -> &'static str`
- `InMemoryRoomDirectory` (`Clone`, `new()`, `#[cfg(test)] insert_for_test(&self, &str, RoomInfo)`)
- `#[cfg(test)] pub(crate) mod scenarios` (reused by Task 13 against Redis)

Semantics (identical to today's `PairRoom` handling in `relay.rs`, which each
test below pins):
- `claim_owner` and `add_pending` create a missing room with hostname
  `identity` (today's `or_insert_with` in `handle_ws`).
- `claim_owner` replaces any owner (verified or not) and resets `verified`.
- `promote`: owner is `conn` → set verified, `AlreadyOwner`. Otherwise an
  unverified owner is evicted first. If `!was_pending` or `conn` is not
  pending → `NotPending { evicted }`. Else `conn` leaves pending, becomes the
  verified owner → `Promoted { previous_owner: <owner before this call>, atems }`.
- A room is removed when an Atem or Astation leaves and it has no Atems, no
  owner and no pending socket.
- `remove_expired` removes rooms older than `ROOM_EXPIRY_SECS` that have no
  owner and no pending socket, and returns their codes.

- [ ] **Step 1: write the tests.** New file `src/cluster/directory.rs`
  containing:

  ```rust
  #[cfg(test)]
  pub(crate) mod scenarios {
      //! Backend-independent directory behavior, run against the in-memory
      //! directory here and against Redis in `cluster::redis::directory`.
      use super::*;
      use std::sync::Arc;

      const T0: i64 = 1_700_000_000;

      fn c(conn: &str, replica: &str) -> ConnRef {
          ConnRef::new(conn, replica)
      }

      pub async fn create_get_and_expiry(d: &dyn RoomDirectory) {
          assert_eq!(d.get("ROOM-1").await.unwrap(), None);
          d.create_room("ROOM-1", "host-1", T0).await.unwrap();
          let room = d.get("ROOM-1").await.unwrap().expect("created");
          assert_eq!(room, RoomInfo::new("host-1", T0));
          assert!(!room.is_expired(T0 + ROOM_EXPIRY_SECS - 1));
          assert!(room.is_expired(T0 + ROOM_EXPIRY_SECS));
      }

      pub async fn ensure_room_is_idempotent(d: &dyn RoomDirectory) {
          assert!(d.ensure_room("astation-1", IDENTITY_HOSTNAME, T0).await.unwrap());
          assert!(!d.ensure_room("astation-1", "other", T0 + 5).await.unwrap());
          let room = d.get("astation-1").await.unwrap().unwrap();
          assert_eq!((room.hostname.as_str(), room.created_at), (IDENTITY_HOSTNAME, T0));
      }

      pub async fn atem_join_requires_a_room_and_replaces(d: &dyn RoomDirectory) {
          assert_eq!(
              d.join_atem("NOPE", "atem-a", &c("t1", "r1")).await.unwrap(),
              AtemJoin::NoRoom
          );
          d.create_room("ROOM", "h", T0).await.unwrap();
          assert_eq!(
              d.join_atem("ROOM", "atem-a", &c("t1", "r1")).await.unwrap(),
              AtemJoin::Joined { replaced: None, owner: None }
          );
          d.claim_owner("ROOM", &c("s1", "r2"), T0).await.unwrap();
          assert_eq!(
              d.join_atem("ROOM", "atem-a", &c("t2", "r2")).await.unwrap(),
              AtemJoin::Joined {
                  replaced: Some(c("t1", "r1")),
                  owner: Some(c("s1", "r2")),
              }
          );
          let room = d.get("ROOM").await.unwrap().unwrap();
          assert_eq!(room.atems.get("atem-a"), Some(&c("t2", "r2")));
      }

      pub async fn claim_owner_creates_the_room_and_replaces_the_owner(d: &dyn RoomDirectory) {
          let first = d.claim_owner("astation-x", &c("s1", "r1"), T0).await.unwrap();
          assert_eq!(first, OwnerClaim { replaced: None, atems: vec![] });
          let room = d.get("astation-x").await.unwrap().unwrap();
          assert_eq!(room.hostname, IDENTITY_HOSTNAME);
          assert_eq!(room.owner, Some(c("s1", "r1")));
          assert!(!room.verified);
          d.join_atem("astation-x", "atem-a", &c("t1", "r2")).await.unwrap();
          let second = d.claim_owner("astation-x", &c("s2", "r2"), T0).await.unwrap();
          assert_eq!(
              second,
              OwnerClaim {
                  replaced: Some(c("s1", "r1")),
                  atems: vec![("atem-a".to_string(), c("t1", "r2"))],
              }
          );
      }

      pub async fn pending_respects_the_cap(d: &dyn RoomDirectory) {
          assert!(d.add_pending("astation-p", &c("p1", "r1"), T0, 2).await.unwrap());
          assert!(d.add_pending("astation-p", &c("p2", "r2"), T0, 2).await.unwrap());
          assert!(!d.add_pending("astation-p", &c("p3", "r1"), T0, 2).await.unwrap());
          assert!(
              d.add_pending("astation-p", &c("p3", "r1"), T0, 0).await.unwrap(),
              "0 means no cap"
          );
          let room = d.get("astation-p").await.unwrap().unwrap();
          assert_eq!(room.pending, vec![c("p1", "r1"), c("p2", "r2"), c("p3", "r1")]);
          assert_eq!(room.owner, None);
          assert_eq!(room.hostname, IDENTITY_HOSTNAME);
      }

      pub async fn promotion_rules(d: &dyn RoomDirectory) {
          assert_eq!(
              d.promote("none", &c("x", "r1"), true).await.unwrap(),
              Promotion::NoRoom
          );
          // An unverified owner (squatter) plus a pending socket.
          d.claim_owner("astation-race", &c("squatter", "r1"), T0).await.unwrap();
          d.add_pending("astation-race", &c("pending", "r2"), T0, 0).await.unwrap();
          d.join_atem("astation-race", "atem-a", &c("t1", "r1")).await.unwrap();

          // A verifier that is not pending (its socket was replaced) only evicts the squatter.
          assert_eq!(
              d.promote("astation-race", &c("registrar", "r1"), false).await.unwrap(),
              Promotion::NotPending { evicted: Some(c("squatter", "r1")) }
          );
          assert_eq!(d.get("astation-race").await.unwrap().unwrap().owner, None);

          // The pending socket takes over and learns the Atems.
          assert_eq!(
              d.promote("astation-race", &c("pending", "r2"), true).await.unwrap(),
              Promotion::Promoted {
                  previous_owner: None,
                  atems: vec![("atem-a".to_string(), c("t1", "r1"))],
              }
          );
          let room = d.get("astation-race").await.unwrap().unwrap();
          assert_eq!(room.owner, Some(c("pending", "r2")));
          assert!(room.verified);
          assert!(room.pending.is_empty());

          // The owner proving again is only marked verified.
          assert_eq!(
              d.promote("astation-race", &c("pending", "r2"), false).await.unwrap(),
              Promotion::AlreadyOwner
          );
          // A stale non-pending verifier leaves a verified owner alone.
          assert_eq!(
              d.promote("astation-race", &c("stale", "r1"), false).await.unwrap(),
              Promotion::NotPending { evicted: None }
          );
          // A pending reconnect replaces the verified owner (an ordinary reconnect).
          d.add_pending("astation-race", &c("again", "r1"), T0, 0).await.unwrap();
          assert_eq!(
              d.promote("astation-race", &c("again", "r1"), true).await.unwrap(),
              Promotion::Promoted {
                  previous_owner: Some(c("pending", "r2")),
                  atems: vec![("atem-a".to_string(), c("t1", "r1"))],
              }
          );
      }

      pub async fn legacy_owner_becomes_verified_when_it_proves(d: &dyn RoomDirectory) {
          d.claim_owner("astation-l", &c("s1", "r1"), T0).await.unwrap();
          assert_eq!(
              d.promote("astation-l", &c("s1", "r1"), false).await.unwrap(),
              Promotion::AlreadyOwner
          );
          assert!(d.get("astation-l").await.unwrap().unwrap().verified);
      }

      pub async fn leave_atem_ignores_a_stale_connection(d: &dyn RoomDirectory) {
          d.claim_owner("astation-s", &c("s1", "r1"), T0).await.unwrap();
          d.join_atem("astation-s", "atem-office", &c("replacement", "r2")).await.unwrap();
          assert_eq!(
              d.leave_atem("astation-s", "atem-office", "stale").await.unwrap(),
              AtemLeave { removed: false, owner: Some(c("s1", "r1")), room_removed: false }
          );
          assert_eq!(
              d.leave_atem("astation-s", "atem-office", "replacement").await.unwrap(),
              AtemLeave { removed: true, owner: Some(c("s1", "r1")), room_removed: false }
          );
          assert!(d.get("astation-s").await.unwrap().unwrap().atems.is_empty());
          assert_eq!(
              d.leave_atem("missing", "a", "c").await.unwrap(),
              AtemLeave { removed: false, owner: None, room_removed: false }
          );
      }

      pub async fn leaving_last_member_removes_the_room(d: &dyn RoomDirectory) {
          d.claim_owner("astation-e", &c("s1", "r1"), T0).await.unwrap();
          d.add_pending("astation-e", &c("p1", "r2"), T0, 0).await.unwrap();
          d.join_atem("astation-e", "atem-a", &c("t1", "r2")).await.unwrap();
          assert!(!d.leave_astation("astation-e", "p1").await.unwrap());
          assert!(!d.leave_astation("astation-e", "someone-else").await.unwrap());
          assert!(!d.leave_astation("astation-e", "s1").await.unwrap());
          let room = d.get("astation-e").await.unwrap().unwrap();
          assert_eq!(room.owner, None);
          assert!(!room.verified);
          assert!(room.pending.is_empty());
          assert_eq!(
              d.leave_atem("astation-e", "atem-a", "t1").await.unwrap(),
              AtemLeave { removed: true, owner: None, room_removed: true }
          );
          assert_eq!(d.get("astation-e").await.unwrap(), None);
          assert!(!d.leave_astation("astation-e", "s1").await.unwrap());
      }

      pub async fn delete_room_returns_its_members(d: &dyn RoomDirectory) {
          assert_eq!(d.delete_room("nope").await.unwrap(), None);
          d.claim_owner("ROOM-D", &c("s1", "r1"), T0).await.unwrap();
          d.add_pending("ROOM-D", &c("p1", "r2"), T0, 0).await.unwrap();
          d.join_atem("ROOM-D", "atem-a", &c("t1", "r2")).await.unwrap();
          let room = d.delete_room("ROOM-D").await.unwrap().expect("members");
          assert_eq!(room.owner, Some(c("s1", "r1")));
          assert_eq!(room.pending, vec![c("p1", "r2")]);
          assert_eq!(room.atems.get("atem-a"), Some(&c("t1", "r2")));
          assert_eq!(d.get("ROOM-D").await.unwrap(), None);
      }

      pub async fn touch_and_exists(d: &dyn RoomDirectory) {
          d.create_room("ROOM-T", "h", T0).await.unwrap();
          assert!(d.touch("ROOM-T").await.unwrap());
          assert!(!d.touch("ROOM-GONE").await.unwrap());
          assert_eq!(
              d.exists(&["ROOM-T".to_string(), "ROOM-GONE".to_string()]).await.unwrap(),
              vec![true, false]
          );
          assert_eq!(d.exists(&[]).await.unwrap(), Vec::<bool>::new());
      }

      /// Two sockets proving at once: one ends as owner, and its promotion
      /// names the other as the previous owner (so the other gets closed).
      pub async fn concurrent_promotions_leave_one_owner(d: Arc<dyn RoomDirectory>) {
          d.claim_owner("astation-c", &c("old", "r1"), T0).await.unwrap();
          d.promote("astation-c", &c("old", "r1"), false).await.unwrap();
          d.add_pending("astation-c", &c("a", "r1"), T0, 0).await.unwrap();
          d.add_pending("astation-c", &c("b", "r2"), T0, 0).await.unwrap();
          let (da, db) = (d.clone(), d.clone());
          let (ra, rb) = tokio::join!(
              tokio::spawn(async move { da.promote("astation-c", &c("a", "r1"), true).await.unwrap() }),
              tokio::spawn(async move { db.promote("astation-c", &c("b", "r2"), true).await.unwrap() }),
          );
          let (ra, rb) = (ra.unwrap(), rb.unwrap());
          let owner = d
              .get("astation-c")
              .await
              .unwrap()
              .unwrap()
              .owner
              .expect("an owner");
          let (winner, loser) = if owner.conn == "a" { (ra, "b") } else { (rb, "a") };
          match winner {
              Promotion::Promoted { previous_owner: Some(previous), .. } => {
                  assert_eq!(previous.conn, loser)
              }
              other => panic!("the winner's promotion was {other:?}"),
          }
      }
  }

  #[cfg(test)]
  mod tests {
      use super::*;

      macro_rules! memory_directory_tests {
          ($($name:ident),* $(,)?) => {
              $(
                  #[tokio::test]
                  async fn $name() {
                      let d = InMemoryRoomDirectory::new();
                      scenarios::$name(&d).await;
                  }
              )*
          };
      }

      memory_directory_tests!(
          create_get_and_expiry,
          ensure_room_is_idempotent,
          atem_join_requires_a_room_and_replaces,
          claim_owner_creates_the_room_and_replaces_the_owner,
          pending_respects_the_cap,
          promotion_rules,
          legacy_owner_becomes_verified_when_it_proves,
          leave_atem_ignores_a_stale_connection,
          leaving_last_member_removes_the_room,
          delete_room_returns_its_members,
          touch_and_exists,
      );

      #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
      async fn concurrent_promotions_leave_one_owner() {
          scenarios::concurrent_promotions_leave_one_owner(std::sync::Arc::new(
              InMemoryRoomDirectory::new(),
          ))
          .await;
      }

      #[tokio::test]
      async fn remove_expired_keeps_rooms_with_an_astation() {
          let d = InMemoryRoomDirectory::new();
          let now = 1_700_000_000;
          let old = now - ROOM_EXPIRY_SECS - 10;
          d.insert_for_test("OLD", RoomInfo::new("h", old));
          d.insert_for_test("NEW", RoomInfo::new("h", now));
          d.insert_for_test(
              "OWNED",
              RoomInfo { owner: Some(ConnRef::new("s", "r")), ..RoomInfo::new("h", old) },
          );
          d.insert_for_test(
              "PENDING",
              RoomInfo { pending: vec![ConnRef::new("p", "r")], ..RoomInfo::new("h", old) },
          );
          let mut atems = BTreeMap::new();
          atems.insert("atem".to_string(), ConnRef::new("t", "r"));
          d.insert_for_test("ATEM-ONLY", RoomInfo { atems, ..RoomInfo::new("h", old) });
          let mut removed = d.remove_expired(now).await.unwrap();
          removed.sort();
          assert_eq!(removed, vec!["ATEM-ONLY".to_string(), "OLD".to_string()]);
          assert!(d.get("NEW").await.unwrap().is_some());
          assert!(d.get("OWNED").await.unwrap().is_some());
          assert!(d.get("PENDING").await.unwrap().is_some());
      }
  }
  ```

  Add `pub mod directory;` to `src/cluster/mod.rs` (after `pub mod bus;`).

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::directory`
  does not compile.

- [ ] **Step 3: implement** above the scenarios in `src/cluster/directory.rs`:

  ```rust
  //! Room membership and ownership (spec: "Rooms and message flow"). A room
  //! is keyed by its code and records the owning Astation connection, the
  //! pending (unproven) Astation connections, and one connection per Atem.
  //! Connections are `ConnRef`s, so a room can span replicas.

  use std::collections::{BTreeMap, HashMap};
  use std::sync::{Arc, Mutex, MutexGuard};

  use async_trait::async_trait;

  use super::{ConnRef, StoreError};

  /// An unpaired room lives this long (today's ROOM_EXPIRY_SECS).
  pub const ROOM_EXPIRY_SECS: i64 = 600;

  /// Hostname of a room an Astation creates by connecting (identity room).
  pub const IDENTITY_HOSTNAME: &str = "identity";

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct RoomInfo {
      pub hostname: String,
      /// Unix seconds.
      pub created_at: i64,
      pub owner: Option<ConnRef>,
      /// The owner proved the room's registered key.
      pub verified: bool,
      /// atem_id → its current connection.
      pub atems: BTreeMap<String, ConnRef>,
      /// Astation connections that must prove the key first. Sorted.
      pub pending: Vec<ConnRef>,
  }

  impl RoomInfo {
      pub fn new(hostname: &str, created_at: i64) -> Self {
          Self {
              hostname: hostname.to_string(),
              created_at,
              owner: None,
              verified: false,
              atems: BTreeMap::new(),
              pending: Vec::new(),
          }
      }

      pub fn is_empty(&self) -> bool {
          self.atems.is_empty() && self.owner.is_none() && self.pending.is_empty()
      }

      /// No Astation owns it and it is older than ROOM_EXPIRY_SECS.
      pub fn is_expired(&self, now: i64) -> bool {
          self.owner.is_none() && now - self.created_at >= ROOM_EXPIRY_SECS
      }

      fn keep_on_sweep(&self, now: i64) -> bool {
          now - self.created_at < ROOM_EXPIRY_SECS || self.owner.is_some() || !self.pending.is_empty()
      }

      fn atem_list(&self) -> Vec<(String, ConnRef)> {
          self.atems
              .iter()
              .map(|(id, conn)| (id.clone(), conn.clone()))
              .collect()
      }
  }

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum AtemJoin {
      NoRoom,
      Joined {
          /// The Atem's previous connection (to be closed).
          replaced: Option<ConnRef>,
          /// The room owner (to be told `relay_event: connected`).
          owner: Option<ConnRef>,
      },
  }

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct OwnerClaim {
      /// The previous owner (to be closed).
      pub replaced: Option<ConnRef>,
      /// The room's Atems (the new owner is told about each).
      pub atems: Vec<(String, ConnRef)>,
  }

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum Promotion {
      NoRoom,
      /// The connection already owned the room; it is now verified.
      AlreadyOwner,
      /// Not pending (or no longer): at most an unverified owner was evicted.
      NotPending { evicted: Option<ConnRef> },
      /// The pending connection now owns the room.
      Promoted {
          previous_owner: Option<ConnRef>,
          atems: Vec<(String, ConnRef)>,
      },
  }

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct AtemLeave {
      /// The leaving connection was the Atem's current one.
      pub removed: bool,
      pub owner: Option<ConnRef>,
      pub room_removed: bool,
  }

  #[async_trait]
  pub trait RoomDirectory: Send + Sync {
      fn backend_name(&self) -> &'static str;
      /// POST /api/pair: a fresh room (replaces any room with this code).
      async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError>;
      /// Create the room if missing. True when it was created.
      async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError>;
      async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError>;
      async fn join_atem(&self, code: &str, atem_id: &str, conn: &ConnRef) -> Result<AtemJoin, StoreError>;
      /// A legacy (keyless) Astation takes the room, creating it if missing.
      async fn claim_owner(&self, code: &str, conn: &ConnRef, now: i64) -> Result<OwnerClaim, StoreError>;
      /// A keyed Astation waits to prove its key. False when `max_pending`
      /// (> 0) sockets are already pending.
      async fn add_pending(&self, code: &str, conn: &ConnRef, now: i64, max_pending: usize) -> Result<bool, StoreError>;
      /// Room bookkeeping after `conn` proved the room's key, atomically.
      async fn promote(&self, code: &str, conn: &ConnRef, was_pending: bool) -> Result<Promotion, StoreError>;
      /// Remove the Atem only if `connection_id` is its current connection.
      async fn leave_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Result<AtemLeave, StoreError>;
      /// Remove a pending or owning Astation connection. True if the room was removed.
      async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError>;
      /// Remove the room; returns its members so their sockets can be closed.
      async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError>;
      /// Heartbeat from a replica holding an Astation socket: keep the room alive.
      async fn touch(&self, code: &str) -> Result<bool, StoreError>;
      async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError>;
      /// Sweep expired rooms (in-memory only; Redis expires keys itself).
      async fn remove_expired(&self, now: i64) -> Result<Vec<String>, StoreError>;
  }

  /// In-memory directory: one mutex over all rooms, so every call is atomic.
  #[derive(Clone, Default)]
  pub struct InMemoryRoomDirectory {
      rooms: Arc<Mutex<HashMap<String, RoomInfo>>>,
  }

  impl InMemoryRoomDirectory {
      pub fn new() -> Self {
          Self::default()
      }

      fn lock(&self) -> MutexGuard<'_, HashMap<String, RoomInfo>> {
          self.rooms.lock().unwrap_or_else(|e| e.into_inner())
      }

      #[cfg(test)]
      pub(crate) fn insert_for_test(&self, code: &str, room: RoomInfo) {
          self.lock().insert(code.to_string(), room);
      }
  }

  #[async_trait]
  impl RoomDirectory for InMemoryRoomDirectory {
      fn backend_name(&self) -> &'static str {
          "memory"
      }

      async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError> {
          self.lock().insert(code.to_string(), RoomInfo::new(hostname, now));
          Ok(())
      }

      async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError> {
          let mut rooms = self.lock();
          if rooms.contains_key(code) {
              return Ok(false);
          }
          rooms.insert(code.to_string(), RoomInfo::new(hostname, now));
          Ok(true)
      }

      async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          Ok(self.lock().get(code).cloned())
      }

      async fn join_atem(&self, code: &str, atem_id: &str, conn: &ConnRef) -> Result<AtemJoin, StoreError> {
          let mut rooms = self.lock();
          let Some(room) = rooms.get_mut(code) else {
              return Ok(AtemJoin::NoRoom);
          };
          let replaced = room.atems.insert(atem_id.to_string(), conn.clone());
          Ok(AtemJoin::Joined {
              replaced,
              owner: room.owner.clone(),
          })
      }

      async fn claim_owner(&self, code: &str, conn: &ConnRef, now: i64) -> Result<OwnerClaim, StoreError> {
          let mut rooms = self.lock();
          let room = rooms
              .entry(code.to_string())
              .or_insert_with(|| RoomInfo::new(IDENTITY_HOSTNAME, now));
          let replaced = room.owner.replace(conn.clone());
          room.verified = false;
          Ok(OwnerClaim {
              replaced,
              atems: room.atem_list(),
          })
      }

      async fn add_pending(&self, code: &str, conn: &ConnRef, now: i64, max_pending: usize) -> Result<bool, StoreError> {
          let mut rooms = self.lock();
          let room = rooms
              .entry(code.to_string())
              .or_insert_with(|| RoomInfo::new(IDENTITY_HOSTNAME, now));
          if room.pending.contains(conn) {
              return Ok(true);
          }
          if max_pending > 0 && room.pending.len() >= max_pending {
              return Ok(false);
          }
          room.pending.push(conn.clone());
          room.pending.sort();
          Ok(true)
      }

      async fn promote(&self, code: &str, conn: &ConnRef, was_pending: bool) -> Result<Promotion, StoreError> {
          let mut rooms = self.lock();
          let Some(room) = rooms.get_mut(code) else {
              return Ok(Promotion::NoRoom);
          };
          if room.owner.as_ref().map(|owner| owner.conn == conn.conn).unwrap_or(false) {
              room.verified = true;
              return Ok(Promotion::AlreadyOwner);
          }
          let previous_owner = room.owner.clone();
          let mut evicted = None;
          if room.owner.is_some() && !room.verified {
              evicted = room.owner.take();
          }
          let position = room.pending.iter().position(|pending| pending.conn == conn.conn);
          let Some(position) = position.filter(|_| was_pending) else {
              return Ok(Promotion::NotPending { evicted });
          };
          room.pending.remove(position);
          room.owner = Some(conn.clone());
          room.verified = true;
          Ok(Promotion::Promoted {
              previous_owner,
              atems: room.atem_list(),
          })
      }

      async fn leave_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Result<AtemLeave, StoreError> {
          let mut rooms = self.lock();
          let Some(room) = rooms.get_mut(code) else {
              return Ok(AtemLeave { removed: false, owner: None, room_removed: false });
          };
          let removed = room
              .atems
              .get(atem_id)
              .map(|current| current.conn == connection_id)
              .unwrap_or(false);
          if removed {
              room.atems.remove(atem_id);
          }
          let owner = room.owner.clone();
          let room_removed = room.is_empty();
          if room_removed {
              rooms.remove(code);
          }
          Ok(AtemLeave { removed, owner, room_removed })
      }

      async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError> {
          let mut rooms = self.lock();
          let Some(room) = rooms.get_mut(code) else {
              return Ok(false);
          };
          room.pending.retain(|pending| pending.conn != connection_id);
          if room.owner.as_ref().map(|owner| owner.conn == connection_id).unwrap_or(false) {
              room.owner = None;
              room.verified = false;
          }
          let room_removed = room.is_empty();
          if room_removed {
              rooms.remove(code);
          }
          Ok(room_removed)
      }

      async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          Ok(self.lock().remove(code))
      }

      async fn touch(&self, code: &str) -> Result<bool, StoreError> {
          Ok(self.lock().contains_key(code))
      }

      async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError> {
          let rooms = self.lock();
          Ok(codes.iter().map(|code| rooms.contains_key(code)).collect())
      }

      async fn remove_expired(&self, now: i64) -> Result<Vec<String>, StoreError> {
          let mut rooms = self.lock();
          let expired: Vec<String> = rooms
              .iter()
              .filter(|(_, room)| !room.keep_on_sweep(now))
              .map(|(code, _)| code.clone())
              .collect();
          for code in &expired {
              rooms.remove(code);
          }
          Ok(expired)
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test cluster::directory`.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): RoomDirectory trait with in-memory implementation

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 4: `KeyCache`

**Files:** create `src/cluster/keys.rs`; modify `src/cluster/mod.rs`.

**Interfaces.**
Consumes: `IdentityStore`, `IdentityError` (`identity_store.rs`).
Produces:
- `pub struct CachedKey { pub public_key: String, pub stale: bool }`
- `KeyCache` (`Clone`, `Default`): `new()`,
  `async load(&self, &dyn IdentityStore) -> Result<usize, IdentityError>`,
  `get(&self, &str) -> Option<CachedKey>`, `contains(&self, &str) -> bool`,
  `set(&self, &str, &str)` (lowercases, clears `stale`), `forget(&self, &str)`,
  `async reload_one(&self, &dyn IdentityStore, &str)`
- `pub const KEY_REREAD_TIMEOUT: Duration` (3 s)

`stale`: a `key-changed` announcement whose re-read failed (database down).
The entry stays, so the id is still pending on connect, but the relay
re-reads before accepting a proof with it (fail closed, Task 5).

- [ ] **Step 1: write the tests** (new `src/cluster/keys.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::identity_store::{
          BindOutcome, InMemoryIdentityStore, RegisterOutcome, ReplaceOutcome,
      };

      /// A store whose every call fails (database down).
      struct DownStore;

      #[async_trait::async_trait]
      impl IdentityStore for DownStore {
          fn backend_name(&self) -> &'static str {
              "down"
          }
          async fn get_key(&self, _: &str) -> Result<Option<String>, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn register_key_if_absent(&self, _: &str, _: &str, _: i64) -> Result<RegisterOutcome, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn touch_key(&self, _: &str, _: i64) -> Result<(), IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn bind(&self, _: &str, _: &str, _: i64) -> Result<BindOutcome, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn unbind(&self, _: &str, _: &str) -> Result<bool, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn replace_all(&self, _: &str, _: &[String], _: i64) -> Result<ReplaceOutcome, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
          async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, IdentityError> {
              Err(IdentityError::Db("down".into()))
          }
      }

      #[tokio::test]
      async fn load_set_forget() {
          let store = InMemoryIdentityStore::new();
          store.register_key_if_absent("astation-a", "04AA", 1).await.unwrap();
          let cache = KeyCache::new();
          assert_eq!(cache.load(&store).await.unwrap(), 1);
          assert_eq!(
              cache.get("astation-a"),
              Some(CachedKey { public_key: "04aa".into(), stale: false })
          );
          cache.set("astation-b", "04BB");
          assert!(cache.contains("astation-b"));
          assert_eq!(cache.get("astation-b").unwrap().public_key, "04bb");
          cache.forget("astation-b");
          assert!(!cache.contains("astation-b"));
      }

      #[tokio::test]
      async fn reload_one_follows_the_store() {
          let store = InMemoryIdentityStore::new();
          let cache = KeyCache::new();
          cache.set("astation-a", "04aa");
          // The key was replaced in the store.
          store.register_key_if_absent("astation-a", "04CC", 1).await.unwrap();
          cache.reload_one(&store, "astation-a").await;
          assert_eq!(cache.get("astation-a").unwrap().public_key, "04cc");
          // A key registered elsewhere reaches this cache.
          store.register_key_if_absent("astation-new", "04dd", 1).await.unwrap();
          cache.reload_one(&store, "astation-new").await;
          assert!(cache.contains("astation-new"));
          // Deleted (admin reset): forgotten.
          cache.set("astation-gone", "04ee");
          cache.reload_one(&store, "astation-gone").await;
          assert!(!cache.contains("astation-gone"));
      }

      #[tokio::test]
      async fn failed_reload_marks_the_key_stale() {
          let cache = KeyCache::new();
          cache.set("astation-a", "04aa");
          cache.reload_one(&DownStore, "astation-a").await;
          assert_eq!(
              cache.get("astation-a"),
              Some(CachedKey { public_key: "04aa".into(), stale: true })
          );
          // Still pending on connect.
          assert!(cache.contains("astation-a"));
          // A later successful set clears it.
          cache.set("astation-a", "04aa");
          assert!(!cache.get("astation-a").unwrap().stale);
          // An unknown id stays unknown.
          cache.reload_one(&DownStore, "astation-unknown").await;
          assert!(!cache.contains("astation-unknown"));
      }
  }
  ```

  Add `pub mod keys;` to `src/cluster/mod.rs` (after `pub mod directory;`).

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::keys`.

- [ ] **Step 3: implement** above the tests:

  ```rust
  //! The relay's copy of the registered Astation keys (astation_id →
  //! lowercase hex). Postgres is authoritative; connects and verifications
  //! read this cache with no I/O, so a connect flood or a database outage
  //! can't lock registered Astations out. A change on one replica is announced
  //! on the bus (`key-changed`) and every replica re-reads that one key.

  use std::collections::HashMap;
  use std::sync::{Arc, RwLock};
  use std::time::Duration;

  use crate::identity_store::{IdentityError, IdentityStore};

  /// Bound on a re-read after a `key-changed` announcement.
  pub const KEY_REREAD_TIMEOUT: Duration = Duration::from_secs(3);

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct CachedKey {
      pub public_key: String,
      /// A `key-changed` re-read failed: re-read before trusting this key.
      pub stale: bool,
  }

  #[derive(Clone, Default)]
  pub struct KeyCache {
      keys: Arc<RwLock<HashMap<String, CachedKey>>>,
  }

  impl KeyCache {
      pub fn new() -> Self {
          Self::default()
      }

      /// Replace the cache with every key in `identity` (startup, resubscribe).
      pub async fn load(&self, identity: &dyn IdentityStore) -> Result<usize, IdentityError> {
          let keys: HashMap<String, CachedKey> = identity
              .list_keys()
              .await?
              .into_iter()
              .map(|(id, key)| {
                  (id, CachedKey { public_key: key.to_ascii_lowercase(), stale: false })
              })
              .collect();
          let count = keys.len();
          *self.keys.write().unwrap_or_else(|e| e.into_inner()) = keys;
          Ok(count)
      }

      pub fn get(&self, astation_id: &str) -> Option<CachedKey> {
          self.keys
              .read()
              .unwrap_or_else(|e| e.into_inner())
              .get(astation_id)
              .cloned()
      }

      pub fn contains(&self, astation_id: &str) -> bool {
          self.keys
              .read()
              .unwrap_or_else(|e| e.into_inner())
              .contains_key(astation_id)
      }

      pub fn set(&self, astation_id: &str, public_key: &str) {
          self.keys.write().unwrap_or_else(|e| e.into_inner()).insert(
              astation_id.to_string(),
              CachedKey { public_key: public_key.to_ascii_lowercase(), stale: false },
          );
      }

      pub fn forget(&self, astation_id: &str) {
          self.keys
              .write()
              .unwrap_or_else(|e| e.into_inner())
              .remove(astation_id);
      }

      fn mark_stale(&self, astation_id: &str) {
          if let Some(entry) = self
              .keys
              .write()
              .unwrap_or_else(|e| e.into_inner())
              .get_mut(astation_id)
          {
              entry.stale = true;
          }
      }

      /// After a `key-changed` announcement: re-read one key. If the store
      /// can't be read, a cached key is kept but marked stale, so it still
      /// makes connects pending and is re-read before it verifies anything.
      pub async fn reload_one(&self, identity: &dyn IdentityStore, astation_id: &str) {
          match tokio::time::timeout(KEY_REREAD_TIMEOUT, identity.get_key(astation_id)).await {
              Ok(Ok(Some(key))) => self.set(astation_id, &key),
              Ok(Ok(None)) => self.forget(astation_id),
              Ok(Err(error)) => {
                  tracing::warn!(
                      "Could not re-read the key of Astation {}: {}",
                      crate::relay::mask_code(astation_id),
                      error
                  );
                  self.mark_stale(astation_id);
              }
              Err(_) => {
                  tracing::warn!(
                      "Timed out re-reading the key of Astation {}",
                      crate::relay::mask_code(astation_id)
                  );
                  self.mark_stale(astation_id);
              }
          }
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test cluster::keys`.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): KeyCache with per-key reload and stale marking

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 5: `RelayHub` on the cluster units

`relay.rs` stops holding rooms and senders. `RelayHub` becomes a cheap
`Clone` handle over `HubParts`: a `RoomDirectory`, a `ReplicaBus`,
`LocalSockets`, and a `KeyCache`. `handle_ws` registers each socket in
`LocalSockets` and in the directory, and routes frames with
`deliver`/`deliver_many` (local, or the bus). Behavior is unchanged: every
existing WebSocket test passes as is.

**Files:** modify `src/relay.rs` (non-test code and the tests listed below).

**Interfaces.**
Consumes: Tasks 1–4.
Produces (in `relay.rs`):
- `pub(crate) const RELAY_AUTH_TIMEOUT_SECS: u64` (was private)
- `pub(crate) const CLOSE_TRY_AGAIN: u16 = 1013`
- `pub(crate) const MAX_PENDING_ASTATIONS_PER_ROOM: usize = 0` (0 = no cap; Task 32 sets 4)
- `pub(crate) struct HubParts { replica_id: String, directory: Arc<dyn RoomDirectory>, bus: Arc<dyn ReplicaBus>, local: LocalSockets, keys: KeyCache, auth_timeout: Duration }` (all fields `pub`)
- `RelayHub`: `new()`, `pub(crate) in_memory(InMemoryRoomDirectory, Duration)`,
  `pub(crate) from_parts(HubParts)`, `#[cfg(test)] with_auth_timeout(Duration)`,
  `replica_id(&self) -> &str`, `pub(crate) local(&self) -> &LocalSockets`,
  `pub(crate) keys(&self) -> &KeyCache`, `pub(crate) directory(&self) -> &dyn RoomDirectory`,
  `pub(crate) auth_timeout(&self) -> Duration`,
  `load_keys(&self, &dyn IdentityStore) -> Result<usize, IdentityError>`,
  `cleanup_expired(&self)`,
  `pub(crate) async create_room(&self, &str, &str, i64) -> Result<(), StoreError>`,
  `pub(crate) async ensure_room(&self, &str, &str, i64) -> Result<bool, StoreError>`,
  `pub(crate) async room(&self, &str) -> Result<Option<RoomInfo>, StoreError>`,
  `pub(crate) async close_room(&self, &str) -> Result<bool, StoreError>`,
  `pub(crate) async deliver(&self, &ConnRef, String)`,
  `pub(crate) async deliver_many(&self, Vec<ConnRef>, String)`,
  `pub(crate) async close_connection(&self, &ConnRef, Option<(u16, &str)>)`,
  `pub(crate) async promote_verified(&self, &str, &str, bool) -> Result<(), StoreError>`,
  `pub(crate) async announce_key_change(&self, &str)`,
  `pub(crate) async room_changed(&self, &str)`
- Removed: `PairRoom`, `AtemConnection`, `RelayHub.rooms`, `RelayHub.keys` map,
  `has_key`/`cached_key`/`cache_key`/`forget_key`, `send_self`,
  `promote_verified_astation` (now `RelayHub::promote_verified`).

- [ ] **Step 1: write the new tests.** Add to `relay.rs`'s test module (above
  `// --- Integration tests (HTTP endpoint tests) ---`):

  ```rust
  use crate::cluster::bus::{BroadcastMessage as BusBroadcast, InboxMessage, ReplicaBus as BusTrait};
  use crate::cluster::directory::{InMemoryRoomDirectory, RoomInfo};
  use crate::cluster::local::SocketRole;
  use crate::cluster::{ConnRef, StoreError as ClusterError, SINGLE_REPLICA_ID};

  fn now() -> i64 {
      chrono::Utc::now().timestamp()
  }

  fn test_conn(conn: &str) -> ConnRef {
      ConnRef::new(conn, SINGLE_REPLICA_ID)
  }

  /// A bus that records what a hub publishes to other replicas.
  #[derive(Default)]
  struct RecordingBus {
      inbox: std::sync::Mutex<Vec<(String, InboxMessage)>>,
  }

  #[async_trait::async_trait]
  impl BusTrait for RecordingBus {
      fn backend_name(&self) -> &'static str {
          "recording"
      }
      async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), ClusterError> {
          self.inbox.lock().unwrap().push((replica_id.to_string(), message));
          Ok(())
      }
      async fn broadcast(&self, _message: BusBroadcast) -> Result<(), ClusterError> {
          Ok(())
      }
  }

  #[tokio::test]
  async fn deliveries_stay_local_or_go_to_the_owning_replica() {
      let bus = std::sync::Arc::new(RecordingBus::default());
      let local = crate::cluster::local::LocalSockets::new();
      let hub = RelayHub::from_parts(HubParts {
          replica_id: "r1".to_string(),
          directory: std::sync::Arc::new(InMemoryRoomDirectory::new()),
          bus: bus.clone(),
          local: local.clone(),
          keys: crate::cluster::keys::KeyCache::new(),
          auth_timeout: TEST_AUTH_TIMEOUT,
      });
      let mut here = local.register("a", "room", SocketRole::Astation);
      hub.deliver_many(
          vec![ConnRef::new("a", "r1"), ConnRef::new("b", "r2"), ConnRef::new("c", "r2")],
          "frame".to_string(),
      )
      .await;
      assert_eq!(here.frames.recv().await.as_deref(), Some("frame"));
      hub.deliver(&ConnRef::new("x", "r3"), "one".to_string()).await;
      hub.close_connection(&ConnRef::new("y", "r2"), None).await;
      hub.close_connection(&ConnRef::new("a", "r1"), Some((1012, "restart"))).await;
      assert!(!local.contains("a"));
      let sent = bus.inbox.lock().unwrap().clone();
      assert_eq!(
          sent,
          vec![
              (
                  "r2".to_string(),
                  InboxMessage::Deliver {
                      connection_ids: vec!["b".into(), "c".into()],
                      frame: "frame".into(),
                  }
              ),
              (
                  "r3".to_string(),
                  InboxMessage::Deliver { connection_ids: vec!["x".into()], frame: "one".into() }
              ),
              (
                  "r2".to_string(),
                  InboxMessage::Close { connection_id: "y".into(), code: None, reason: String::new() }
              ),
          ]
      );
  }
  ```

- [ ] **Step 2: port the tests that used the removed internals.** In
  `relay.rs`'s test module make these exact replacements (each keeps the
  original assertions against the new seam):

  1. Delete `stale_atem_cleanup_does_not_remove_replacement` (covered by
     `cluster::directory::…::leave_atem_ignores_a_stale_connection`).
  2. Replace `relay_hub_create_and_lookup`, `relay_hub_cleanup_expired`,
     `relay_hub_cleanup_keeps_paired` and
     `test_cleanup_expired_keeps_recently_paired` with:

     ```rust
     #[tokio::test]
     async fn relay_hub_create_and_lookup() {
         let hub = RelayHub::new();
         hub.create_room("ABCD-EFGH", "test-host", now()).await.unwrap();
         let room = hub.room("ABCD-EFGH").await.unwrap().expect("room exists");
         assert_eq!(room.hostname, "test-host");
     }

     fn hub_over(directory: &InMemoryRoomDirectory) -> RelayHub {
         RelayHub::in_memory(directory.clone(), TEST_AUTH_TIMEOUT)
     }

     #[tokio::test]
     async fn relay_hub_cleanup_expired() {
         let directory = InMemoryRoomDirectory::new();
         let hub = hub_over(&directory);
         directory.insert_for_test("OLD1-CODE", RoomInfo::new("old-host", now() - ROOM_EXPIRY_SECS - 10));
         directory.insert_for_test("NEW1-CODE", RoomInfo::new("new-host", now()));
         hub.cleanup_expired().await;
         assert!(hub.room("OLD1-CODE").await.unwrap().is_none(), "Expired room should be removed");
         assert!(hub.room("NEW1-CODE").await.unwrap().is_some(), "Fresh room should remain");
     }

     #[tokio::test]
     async fn relay_hub_cleanup_keeps_paired() {
         let directory = InMemoryRoomDirectory::new();
         let hub = hub_over(&directory);
         directory.insert_for_test(
             "PAIR-CODE",
             RoomInfo {
                 owner: Some(test_conn("astation-test")),
                 ..RoomInfo::new("paired-host", now() - ROOM_EXPIRY_SECS - 10)
             },
         );
         hub.cleanup_expired().await;
         assert!(
             hub.room("PAIR-CODE").await.unwrap().is_some(),
             "Paired room should not be cleaned up"
         );
     }

     #[tokio::test]
     async fn test_cleanup_expired_keeps_recently_paired() {
         let directory = InMemoryRoomDirectory::new();
         let hub = hub_over(&directory);
         let mut atems = std::collections::BTreeMap::new();
         atems.insert("test-atem".to_string(), test_conn("connection-old"));
         directory.insert_for_test(
             "OLD-ATEM",
             RoomInfo { atems, ..RoomInfo::new("old-host", now() - ROOM_EXPIRY_SECS - 10) },
         );
         let mut atem = hub.local().register(
             "connection-old",
             "OLD-ATEM",
             SocketRole::Atem { atem_id: "test-atem".into() },
         );
         hub.cleanup_expired().await;
         // Removed (only an Astation keeps a room), and its Atem socket is closed.
         assert!(
             hub.room("OLD-ATEM").await.unwrap().is_none(),
             "Room with only atem connected should be cleaned up"
         );
         assert!(atem.frames.recv().await.is_none(), "the Atem's socket was closed");
     }
     ```

  3. In `test_pair_status_shows_unpaired_then_paired`, replace the block from
     `let room = PairRoom {` through
     `state.relay.rooms.write().await.insert(code.clone(), room);` with:

     ```rust
     state.relay.create_room(&code, "test-host", now()).await.unwrap();
     ```

     and replace the "Simulate both sides connecting" block (from
     `let (tx_astation, _rx) = mpsc::unbounded_channel::<String>();` through
     the closing `}` of the `{ let mut rooms = … }` block) with:

     ```rust
     state
         .relay
         .directory()
         .claim_owner(&code, &test_conn("astation-conn"), now())
         .await
         .unwrap();
     state
         .relay
         .directory()
         .join_atem(&code, "test-atem", &test_conn("connection-test"))
         .await
         .unwrap();
     ```

  4. In `delete_still_closes_keyless_rooms`, replace
     `assert!(!state.relay.rooms.read().await.contains_key(code));` with
     `assert!(state.relay.room(code).await.unwrap().is_none());`.
  5. Replace every `state.relay.has_key(code)` with
     `state.relay.keys().contains(code)` (three places).
  6. In `admin_reset_is_picked_up_on_key_mismatch`, `flaky.inner.delete_key(code).await;`
     stays as is in this task (Task 26 changes it).
  7. Replace `verification_evicts_an_unverified_owner` and
     `verification_keeps_a_verified_owner_until_a_pending_one_takes_over` with:

     ```rust
     /// First-registration race: an unverified socket that became owner is
     /// evicted when the registering (or a pending) connection verifies.
     #[tokio::test]
     async fn verification_evicts_an_unverified_owner() {
         let hub = RelayHub::new();
         let code = "astation-race";
         let mut squatter = hub.local().register("squatter", code, SocketRole::Astation);
         let _pending = hub.local().register("pending", code, SocketRole::Astation);
         hub.directory().claim_owner(code, &test_conn("squatter"), now()).await.unwrap();
         assert!(hub.directory().add_pending(code, &test_conn("pending"), now(), 0).await.unwrap());

         // The registering socket was replaced, so it is not the owner.
         hub.promote_verified(code, "registrar", false).await.unwrap();
         assert!(hub.room(code).await.unwrap().unwrap().owner.is_none());
         assert!(squatter.frames.recv().await.is_none(), "squatter's sender was dropped");

         hub.promote_verified(code, "pending", true).await.unwrap();
         let room = hub.room(code).await.unwrap().unwrap();
         assert_eq!(room.owner.map(|owner| owner.conn).as_deref(), Some("pending"));
         assert!(room.verified);
         assert!(room.pending.is_empty());
     }

     #[tokio::test]
     async fn verification_keeps_a_verified_owner_until_a_pending_one_takes_over() {
         let hub = RelayHub::new();
         let code = "astation-verified";
         let _owner = hub.local().register("owner", code, SocketRole::Astation);
         hub.directory().claim_owner(code, &test_conn("owner"), now()).await.unwrap();
         hub.promote_verified(code, "owner", false).await.unwrap();

         // A stale, non-pending verified socket doesn't disturb the owner.
         hub.promote_verified(code, "stale", false).await.unwrap();
         let room = hub.room(code).await.unwrap().unwrap();
         assert_eq!(room.owner.map(|owner| owner.conn).as_deref(), Some("owner"));
         assert!(room.verified);
         assert!(hub.local().contains("owner"));
     }
     ```

- [ ] **Step 3: run and watch it fail.** `cargo test relay::` does not
  compile (`HubParts`, `from_parts`, `room`, … missing).

- [ ] **Step 4: implement.** Edit `src/relay.rs` region by region.

  **4a. Imports.** Replace lines 1–17 (from `use axum::{` through
  `use crate::AppState;`) with:

  ```rust
  use axum::{
      extract::{
          ws::{CloseFrame, Message, WebSocket},
          Query, State, WebSocketUpgrade,
      },
      http::StatusCode,
      response::{Html, IntoResponse, Json, Response},
  };
  use futures_util::stream::SplitSink;
  use futures_util::{SinkExt, StreamExt};
  use rand::Rng;
  use serde::{Deserialize, Serialize};
  use std::collections::BTreeMap;
  use std::sync::Arc;
  use std::time::Duration;
  use tokio::time::Instant;
  use uuid::Uuid;
  use validator::Validate;

  use crate::cluster::bus::{BroadcastMessage, InboxMessage, LoopbackBus, ReplicaBus};
  use crate::cluster::directory::{
      AtemJoin, InMemoryRoomDirectory, Promotion, RoomDirectory, RoomInfo, IDENTITY_HOSTNAME,
      ROOM_EXPIRY_SECS,
  };
  use crate::cluster::keys::KeyCache;
  use crate::cluster::local::{LocalSockets, SocketOutbox, SocketRole};
  use crate::cluster::{ConnRef, StoreError, SINGLE_REPLICA_ID};
  use crate::identity_store::{BindOutcome, IdentityError, IdentityStore, RegisterOutcome};
  use crate::AppState;
  ```

  **4b. Constants.** Delete the two lines
  `/// Room expiry: 10 minutes if unpaired.` and
  `const ROOM_EXPIRY_SECS: u64 = 600;` (now imported). Change
  `const RELAY_AUTH_TIMEOUT_SECS: u64 = 10;` to
  `pub(crate) const RELAY_AUTH_TIMEOUT_SECS: u64 = 10;`. Directly after
  `const IDENTITY_STORE_TIMEOUT: …;` add:

  ```rust
  /// Close code: shared relay state unavailable, reconnect later (RFC 6455).
  pub(crate) const CLOSE_TRY_AGAIN: u16 = 1013;

  /// Pending Astation sockets allowed per room (0 = no cap).
  pub(crate) const MAX_PENDING_ASTATIONS_PER_ROOM: usize = 0;
  ```

  **4c. Hub.** Replace everything from `// --- Types ---` down to and
  including the `impl Default for RelayHub { … }` block (it ends just before
  `/// Generate an 8-char pairing code`) with:

  ```rust
  // --- Types ---

  fn relay_connection_event(atem_id: &str, connection_id: &str, event: &str) -> String {
      serde_json::json!({
          "atem_id": atem_id,
          "connection_id": connection_id,
          "relay_event": event,
      })
      .to_string()
  }

  /// An Atem frame wrapped for its Astation. A non-JSON frame travels as a
  /// JSON string payload.
  fn atem_envelope(atem_id: &str, connection_id: &str, text: &str) -> String {
      let payload = serde_json::from_str::<serde_json::Value>(text)
          .unwrap_or_else(|_| serde_json::Value::String(text.to_string()));
      serde_json::json!({
          "atem_id": atem_id,
          "connection_id": connection_id,
          "payload": payload,
      })
      .to_string()
  }

  /// What a hub is built from: in-memory parts by default, Redis-backed
  /// parts when REDIS_URL is set.
  pub(crate) struct HubParts {
      pub replica_id: String,
      pub directory: Arc<dyn RoomDirectory>,
      pub bus: Arc<dyn ReplicaBus>,
      pub local: LocalSockets,
      pub keys: KeyCache,
      pub auth_timeout: Duration,
  }

  struct HubInner {
      replica_id: String,
      directory: Arc<dyn RoomDirectory>,
      bus: Arc<dyn ReplicaBus>,
      local: LocalSockets,
      keys: KeyCache,
      auth_timeout: Duration,
  }

  /// The relay: this replica's sockets plus the shared room directory, the
  /// replica bus and the Astation key cache.
  #[derive(Clone)]
  pub struct RelayHub {
      inner: Arc<HubInner>,
  }

  impl RelayHub {
      /// Single-instance hub: in-memory directory, loopback bus.
      pub fn new() -> Self {
          Self::in_memory(
              InMemoryRoomDirectory::new(),
              Duration::from_secs(RELAY_AUTH_TIMEOUT_SECS),
          )
      }

      pub(crate) fn in_memory(directory: InMemoryRoomDirectory, auth_timeout: Duration) -> Self {
          let local = LocalSockets::new();
          Self::from_parts(HubParts {
              replica_id: SINGLE_REPLICA_ID.to_string(),
              directory: Arc::new(directory),
              bus: Arc::new(LoopbackBus::new(SINGLE_REPLICA_ID, local.clone())),
              local,
              keys: KeyCache::new(),
              auth_timeout,
          })
      }

      pub(crate) fn from_parts(parts: HubParts) -> Self {
          Self {
              inner: Arc::new(HubInner {
                  replica_id: parts.replica_id,
                  directory: parts.directory,
                  bus: parts.bus,
                  local: parts.local,
                  keys: parts.keys,
                  auth_timeout: parts.auth_timeout,
              }),
          }
      }

      #[cfg(test)]
      pub(crate) fn with_auth_timeout(auth_timeout: Duration) -> Self {
          Self::in_memory(InMemoryRoomDirectory::new(), auth_timeout)
      }

      pub fn replica_id(&self) -> &str {
          &self.inner.replica_id
      }

      pub(crate) fn local(&self) -> &LocalSockets {
          &self.inner.local
      }

      pub(crate) fn keys(&self) -> &KeyCache {
          &self.inner.keys
      }

      pub(crate) fn directory(&self) -> &dyn RoomDirectory {
          self.inner.directory.as_ref()
      }

      pub(crate) fn auth_timeout(&self) -> Duration {
          self.inner.auth_timeout
      }

      fn me(&self, connection_id: &str) -> ConnRef {
          ConnRef::new(connection_id, &self.inner.replica_id)
      }

      /// Replace the key cache with every key in `identity`. Called once at
      /// startup (before serving).
      pub async fn load_keys(&self, identity: &dyn IdentityStore) -> Result<usize, IdentityError> {
          self.inner.keys.load(identity).await
      }

      /// Queue a frame on a connection, here or on its replica.
      pub(crate) async fn deliver(&self, target: &ConnRef, frame: String) {
          if target.replica == self.inner.replica_id {
              self.inner.local.send(&target.conn, frame);
              return;
          }
          let message = InboxMessage::Deliver {
              connection_ids: vec![target.conn.clone()],
              frame,
          };
          if let Err(error) = self.inner.bus.send_inbox(&target.replica, message).await {
              tracing::debug!("Dropped a frame for replica {}: {}", target.replica, error);
          }
      }

      /// Queue a frame on many connections: one bus message per replica.
      pub(crate) async fn deliver_many(&self, targets: Vec<ConnRef>, frame: String) {
          let mut by_replica: BTreeMap<String, Vec<String>> = BTreeMap::new();
          for target in targets {
              by_replica.entry(target.replica).or_default().push(target.conn);
          }
          for (replica, connection_ids) in by_replica {
              if replica == self.inner.replica_id {
                  for connection_id in connection_ids {
                      self.inner.local.send(&connection_id, frame.clone());
                  }
                  continue;
              }
              let message = InboxMessage::Deliver {
                  connection_ids,
                  frame: frame.clone(),
              };
              if let Err(error) = self.inner.bus.send_inbox(&replica, message).await {
                  tracing::debug!("Dropped a broadcast for replica {}: {}", replica, error);
              }
          }
      }

      /// End a connection wherever it is. `None` evicts it like a replaced
      /// socket today; `Some((code, reason))` sends that close code.
      pub(crate) async fn close_connection(&self, target: &ConnRef, code: Option<(u16, &str)>) {
          if target.replica == self.inner.replica_id {
              match code {
                  None => {
                      self.inner.local.evict(&target.conn);
                  }
                  Some((code, reason)) => {
                      self.inner.local.close_with(&target.conn, code, reason);
                  }
              }
              return;
          }
          let message = InboxMessage::Close {
              connection_id: target.conn.clone(),
              code: code.map(|(code, _)| code),
              reason: code.map(|(_, reason)| reason.to_string()).unwrap_or_default(),
          };
          if let Err(error) = self.inner.bus.send_inbox(&target.replica, message).await {
              tracing::debug!("Could not close a connection on replica {}: {}", target.replica, error);
          }
      }

      /// A room's directory entry changed: other replicas drop cached copies.
      pub(crate) async fn room_changed(&self, code: &str) {
          let message = BroadcastMessage::RoomChanged { code: code.to_string() };
          if let Err(error) = self.inner.bus.broadcast(message).await {
              tracing::debug!("Could not announce a change of room {}: {}", mask_code(code), error);
          }
      }

      /// An Astation key was registered, replaced or forgotten here.
      pub(crate) async fn announce_key_change(&self, astation_id: &str) {
          let message = BroadcastMessage::KeyChanged { astation_id: astation_id.to_string() };
          if let Err(error) = self.inner.bus.broadcast(message).await {
              tracing::warn!(
                  "Could not announce a key change for Astation {}: {}",
                  mask_code(astation_id),
                  error
              );
          }
      }

      /// The room as frame routing sees it.
      async fn route_view(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          self.inner.directory.get(code).await
      }

      /// The room, read fresh (HTTP endpoints, connect checks).
      pub(crate) async fn room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          self.inner.directory.get(code).await
      }

      /// The current connection of `atem_id`, only if it is `connection_id`
      /// (stale generations are dropped).
      async fn find_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Option<ConnRef> {
          match self.route_view(code).await {
              Ok(room) => room
                  .and_then(|room| room.atems.get(atem_id).cloned())
                  .filter(|current| current.conn == connection_id),
              Err(error) => {
                  tracing::debug!("Room lookup failed for {}: {}", mask_code(code), error);
                  None
              }
          }
      }

      pub(crate) async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError> {
          self.inner.directory.create_room(code, hostname, now).await?;
          self.room_changed(code).await;
          Ok(())
      }

      pub(crate) async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError> {
          let created = self.inner.directory.ensure_room(code, hostname, now).await?;
          if created {
              self.room_changed(code).await;
          }
          Ok(created)
      }

      /// Remove a room and end every socket in it (DELETE /api/pair/:code).
      pub(crate) async fn close_room(&self, code: &str) -> Result<bool, StoreError> {
          let Some(room) = self.inner.directory.delete_room(code).await? else {
              return Ok(false);
          };
          self.room_changed(code).await;
          let members = room
              .owner
              .into_iter()
              .chain(room.pending)
              .chain(room.atems.into_values());
          for member in members {
              self.close_connection(&member, None).await;
          }
          Ok(true)
      }

      /// Room bookkeeping after `connection_id` proved the room's key
      /// (`RoomDirectory::promote`): an unverified owner is evicted, a pending
      /// connection takes over (replacing a verified owner too: an ordinary
      /// reconnect) and learns the connected Atems, and a connection that
      /// already owns the room is marked verified.
      pub(crate) async fn promote_verified(
          &self,
          code: &str,
          connection_id: &str,
          was_pending: bool,
      ) -> Result<(), StoreError> {
          let me = self.me(connection_id);
          match self.inner.directory.promote(code, &me, was_pending).await? {
              Promotion::NoRoom => return Ok(()),
              Promotion::AlreadyOwner => {}
              Promotion::NotPending { evicted } => {
                  if let Some(evicted) = evicted {
                      tracing::warn!(
                          "Evicting unverified Astation owner of keyed room {}",
                          mask_code(code)
                      );
                      self.close_connection(&evicted, None).await;
                  }
              }
              Promotion::Promoted { previous_owner, atems } => {
                  for (atem_id, connection) in &atems {
                      self.inner.local.send(
                          connection_id,
                          relay_connection_event(atem_id, &connection.conn, "connected"),
                      );
                  }
                  if let Some(previous) = previous_owner {
                      self.close_connection(&previous, None).await;
                  }
              }
          }
          self.room_changed(code).await;
          Ok(())
      }

      /// Close every local socket of a room that no longer exists.
      fn evict_room_locally(&self, code: &str) {
          for (connection_id, _) in self.inner.local.connections_in_room(code) {
              self.inner.local.evict(&connection_id);
          }
      }

      /// Periodic room upkeep, idempotent on every replica:
      /// - in-memory: remove rooms that are older than ROOM_EXPIRY_SECS and
      ///   have no Astation (Redis expires them itself);
      /// - keep alive the rooms where this replica holds an Astation socket;
      /// - close local Atem sockets whose room is gone (as today's sweep did).
      pub async fn cleanup_expired(&self) {
          let now = chrono::Utc::now().timestamp();
          match self.inner.directory.remove_expired(now).await {
              Ok(removed) => {
                  for code in removed {
                      self.evict_room_locally(&code);
                  }
              }
              Err(error) => tracing::warn!("Room sweep failed: {}", error),
          }
          for code in self.inner.local.codes_with_astations() {
              if let Err(error) = self.inner.directory.touch(&code).await {
                  tracing::debug!("Room heartbeat failed for {}: {}", mask_code(&code), error);
              }
          }
          let atem_codes = self.inner.local.codes_with_atems();
          if atem_codes.is_empty() {
              return;
          }
          match self.inner.directory.exists(&atem_codes).await {
              Ok(present) => {
                  for (code, exists) in atem_codes.iter().zip(present) {
                      if !exists {
                          self.evict_room_locally(code);
                      }
                  }
              }
              Err(error) => tracing::debug!("Room existence check failed: {}", error),
          }
      }
  }

  impl Default for RelayHub {
      fn default() -> Self {
          Self::new()
      }
  }
  ```

  **4d. Pair handlers and `ws_handler`.** Replace everything from
  `/// POST /api/pair — Register for pairing, get a code back.` down to the
  end of `ws_handler` (the line `.into_response()` followed by `}` just
  before `/// Percent-decode an incoming atem_id`) with:

  ```rust
  fn relay_state_unavailable(error: &StoreError) -> (StatusCode, Json<serde_json::Value>) {
      tracing::error!("Relay state unavailable: {}", error);
      (
          StatusCode::SERVICE_UNAVAILABLE,
          Json(serde_json::json!({"error": "relay state unavailable"})),
      )
  }

  fn ws_unavailable(error: &StoreError) -> Response {
      tracing::error!("Refused a WebSocket, relay state unavailable: {}", error);
      (StatusCode::SERVICE_UNAVAILABLE, "Relay state unavailable, retry shortly").into_response()
  }

  /// POST /api/pair — Register for pairing, get a code back.
  pub async fn create_pair_handler(
      State(state): State<AppState>,
      Json(body): Json<CreatePairRequest>,
  ) -> impl IntoResponse {
      // Validate input
      if let Err(e) = body.validate() {
          return (
              StatusCode::BAD_REQUEST,
              Json(serde_json::json!({"error": format!("Validation error: {}", e)})),
          )
              .into_response();
      }

      let code = generate_pairing_code();
      let now = chrono::Utc::now().timestamp();
      if let Err(error) = state.relay.create_room(&code, &body.hostname, now).await {
          return relay_state_unavailable(&error).into_response();
      }

      tracing::info!("Pair room created: {}", mask_code(&code));
      (StatusCode::CREATED, Json(CreatePairResponse { code })).into_response()
  }

  /// GET /api/pair/:code — Check pairing status.
  pub async fn pair_status_handler(
      State(state): State<AppState>,
      axum::extract::Path(code): axum::extract::Path<String>,
  ) -> impl IntoResponse {
      let room = match state.relay.room(&code).await {
          Ok(room) => room,
          Err(error) => return relay_state_unavailable(&error).into_response(),
      };
      let Some(room) = room else {
          return (
              StatusCode::NOT_FOUND,
              Json(serde_json::json!({"error": "Room not found"})),
          )
              .into_response();
      };
      let now = chrono::Utc::now().timestamp();
      let atem_count = room.atems.len();
      let atem_connected = atem_count > 0;
      let astation_connected = room.owner.is_some();
      let atem_ids = (atem_count > 0).then(|| room.atems.keys().cloned().collect());
      Json(PairStatusResponse {
          paired: atem_connected && astation_connected,
          hostname: room.hostname.clone(),
          atem_count,
          atem_ids,
          atem_connected,
          astation_connected,
          expired: room.is_expired(now),
      })
      .into_response()
  }

  /// DELETE /api/pair/:code — Close a pairing room.
  /// Removes the room, disconnecting both sides. Unauthenticated, so it is
  /// refused (409) for a code with a registered Astation key: that room belongs
  /// to a verified Astation and must not be closable by anyone who knows the code.
  pub async fn delete_pair_handler(
      State(state): State<AppState>,
      axum::extract::Path(code): axum::extract::Path<String>,
  ) -> impl IntoResponse {
      if state.relay.keys().contains(&code) {
          tracing::warn!("Refused DELETE of keyed room {}", mask_code(&code));
          return (
              StatusCode::CONFLICT,
              Json(serde_json::json!({"error": "room is owned by a registered Astation"})),
          )
              .into_response();
      }
      match state.relay.close_room(&code).await {
          Ok(true) => {
              tracing::info!("Pair room closed by client: {}", mask_code(&code));
              (StatusCode::OK, Json(DeletePairResponse { closed: true })).into_response()
          }
          Ok(false) => {
              (StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Room not found"}))).into_response()
          }
          Err(error) => relay_state_unavailable(&error).into_response(),
      }
  }

  /// GET /ws — WebSocket upgrade for relay.
  /// Auth methods:
  ///   1. Pairing: ?role=atem|astation&code=XXXX (short-lived, explicit approval)
  ///   2. Session: ?session=<session_id> (after HTTP auth, longer-lived)
  pub async fn ws_handler(
      State(state): State<AppState>,
      Query(params): Query<WsQuery>,
      ws: WebSocketUpgrade,
  ) -> impl IntoResponse {
      let hub = state.relay.clone();
      let now = chrono::Utc::now().timestamp();

      // Session-based auth (hybrid flow)
      if let Some(session_id) = params.session.clone() {
          let session = match state.sessions.get(&session_id).await {
              Ok(session) => session,
              Err(error) => return ws_unavailable(&error),
          };
          match session {
              Some(s) if s.status == crate::auth::SessionStatus::Granted => {
                  // Valid session - use session_id as room code, role defaults to "atem"
                  let code = format!("session-{}", session_id);
                  let role = params.role.clone().unwrap_or_else(|| "atem".to_string());
                  if let Err(error) = hub.ensure_room(&code, &s.hostname, now).await {
                      return ws_unavailable(&error);
                  }
                  if let Err(error) = state.sessions.touch(&session_id).await {
                      tracing::debug!("Could not refresh session {}: {}", mask_code(&session_id), error);
                  }
                  let atem_id = params.atem_id.clone().unwrap_or_else(|| "session-atem".to_string());
                  let identity = state.identity.clone();
                  return ws
                      .on_upgrade(move |socket| handle_ws(hub, identity, code, role, atem_id, socket))
                      .into_response();
              }
              _ => {
                  return (StatusCode::UNAUTHORIZED, "Invalid or expired session").into_response();
              }
          }
      }

      // Pairing-based auth (traditional flow)
      let code = match params.code.clone() {
          Some(c) => c,
          None => return (StatusCode::BAD_REQUEST, "Missing code or session parameter").into_response(),
      };
      let role = match params.role.clone() {
          Some(r) => r,
          None => return (StatusCode::BAD_REQUEST, "Missing role parameter").into_response(),
      };

      // For astation: auto-create identity room if it doesn't exist (allows persistent relay rooms).
      // For atem/other: verify the room exists and has not expired.
      if role == "astation" {
          match hub.ensure_room(&code, IDENTITY_HOSTNAME, now).await {
              Ok(true) => tracing::info!("Auto-creating identity room for code={}", mask_code(&code)),
              Ok(false) => {}
              Err(error) => return ws_unavailable(&error),
          }
      } else {
          match hub.room(&code).await {
              Err(error) => return ws_unavailable(&error),
              Ok(None) => return (StatusCode::NOT_FOUND, "Room not found").into_response(),
              // No Astation and older than the limit: 410 Gone.
              Ok(Some(room)) if room.is_expired(now) => {
                  return (StatusCode::GONE, "Pairing code has expired").into_response();
              }
              Ok(Some(_)) => {}
          }
      }

      // Sanitize atem_id. atem percent-encodes ids that may contain non-ASCII
      // (CJK hostnames), so decode first, then keep non-ASCII while restricting
      // ASCII to [A-Za-z0-9-] (matches atem's own identity rule).
      let atem_id = sanitize_atem_id(params.atem_id.as_deref());

      let identity = state.identity.clone();
      ws.on_upgrade(move |socket| handle_ws(hub, identity, code, role, atem_id, socket))
          .into_response()
  }
  ```

  `state.sessions.touch` and the `Result` from `state.sessions.get` come in
  Task 6. Until Task 6 lands, write the session block against today's
  `SessionStore`: replace the `let session = match … ;` statement with
  `let session = state.sessions.get(&session_id).await;` and delete the
  three-line `if let Err(error) = state.sessions.touch(…)` block. Task 6,
  Step 4 restores both exactly as shown above.

  **4e. `send_self`.** Delete the function `send_self` and its doc comment
  (`/// Send a frame to this connection while something still holds its sender` …).

  **4f. `verify_relay_auth`.** Replace the body from
  `    if let Some(cached) = hub.cached_key(astation_id) {` to the end of the
  function with:

  ```rust
      let keys = hub.keys();
      if let Some(cached) = keys.get(astation_id) {
          if cached.public_key == public_key && !cached.stale {
              touch_key_in_background(identity, astation_id, now);
              return Ok("verified");
          }
          // Mismatch, or an entry a failed re-read left stale: the cache may
          // predate an admin reset. Re-read the key.
          match tokio::time::timeout(IDENTITY_STORE_TIMEOUT, identity.get_key(astation_id)).await {
              Ok(Ok(Some(stored))) => {
                  let stored = stored.to_ascii_lowercase();
                  let changed = stored != cached.public_key;
                  keys.set(astation_id, &stored);
                  if changed {
                      hub.announce_key_change(astation_id).await;
                  }
                  if stored != public_key {
                      return Err(KEY_MISMATCH);
                  }
                  touch_key_in_background(identity, astation_id, now);
                  return Ok("verified");
              }
              Ok(Ok(None)) => {
                  // Admin reset: fall through to registration of the new key.
                  keys.forget(astation_id);
                  hub.announce_key_change(astation_id).await;
              }
              Ok(Err(error)) => {
                  tracing::error!(
                      "Identity store error re-reading the key of Astation {}: {}",
                      mask_code(astation_id),
                      error
                  );
                  return Err(KEY_MISMATCH);
              }
              Err(_) => {
                  tracing::error!(
                      "Identity store timed out re-reading the key of Astation {}",
                      mask_code(astation_id)
                  );
                  return Err(KEY_MISMATCH);
              }
          }
      }

      let registration = tokio::time::timeout(
          IDENTITY_STORE_TIMEOUT,
          identity.register_key_if_absent(astation_id, &public_key, now),
      )
      .await;
      match registration {
          Ok(Ok(RegisterOutcome::Registered)) => {
              keys.set(astation_id, &public_key);
              hub.announce_key_change(astation_id).await;
              Ok("registered")
          }
          Ok(Ok(RegisterOutcome::Existing(stored))) => {
              let stored = stored.to_ascii_lowercase();
              let known = keys.get(astation_id).map(|cached| cached.public_key);
              keys.set(astation_id, &stored);
              if known.as_deref() != Some(stored.as_str()) {
                  hub.announce_key_change(astation_id).await;
              }
              if stored == public_key {
                  touch_key_in_background(identity, astation_id, now);
                  Ok("verified")
              } else {
                  Err(KEY_MISMATCH)
              }
          }
          Ok(Err(error)) => {
              tracing::error!(
                  "Identity store error registering Astation {}: {}",
                  mask_code(astation_id),
                  error
              );
              Err("identity store unavailable")
          }
          Err(_) => {
              tracing::error!(
                  "Identity store timed out registering Astation {}",
                  mask_code(astation_id)
              );
              Err("identity store unavailable")
          }
      }
  }
  ```

  **4g. Promotion, control frames, `handle_ws`.** Replace everything from
  `/// Room bookkeeping after \`connection_id\` proved the room's key.` (the
  doc comment of `promote_verified_astation`) down to the end of `handle_ws`
  (the line `tracing::info!("WS disconnected: role={} code={}", role, mask_code(&code));`
  and its closing `}`) with:

  ```rust
  /// Handle a relay-auth frame from an Astation. Returns `false` when the
  /// connection must be closed (its rejection has been queued).
  async fn handle_astation_control(
      hub: &RelayHub,
      identity: &Arc<dyn IdentityStore>,
      code: &str,
      connection_id: &str,
      auth: &mut AstationAuth,
      kind: &str,
      message: &serde_json::Value,
  ) -> bool {
      let now = chrono::Utc::now().timestamp();
      match kind {
          "relayAuth" => {
              if auth.state == AuthState::Verified {
                  tracing::debug!("Ignoring repeated relayAuth from Astation {}", mask_code(code));
                  return true;
              }
              if Instant::now() >= auth.deadline {
                  tracing::warn!("Rejected late relayAuth from Astation {}", mask_code(code));
                  hub.local().send(
                      connection_id,
                      relay_auth_result_frame("rejected", "challenge expired"),
                  );
                  return false;
              }
              match verify_relay_auth(hub, identity, code, &auth.challenge, message, now).await {
                  Ok(status) => {
                      let message = if status == "registered" {
                          "key registered"
                      } else {
                          "key verified"
                      };
                      hub.local().send(connection_id, relay_auth_result_frame(status, message));
                      let was_pending = auth.state == AuthState::Pending;
                      auth.state = AuthState::Verified;
                      if let Err(error) = hub.promote_verified(code, connection_id, was_pending).await {
                          tracing::error!(
                              "Relay state unavailable promoting Astation {}: {}",
                              mask_code(code),
                              error
                          );
                          hub.local().close_with(connection_id, CLOSE_TRY_AGAIN, "relay state unavailable");
                          return false;
                      }
                      tracing::info!("Astation {} relay identity {}", mask_code(code), status);
                      true
                  }
                  Err(reason) => {
                      tracing::warn!("Rejected relayAuth for Astation {}: {}", mask_code(code), reason);
                      hub.local().send(connection_id, relay_auth_result_frame("rejected", reason));
                      false
                  }
              }
          }
          "relaySessions" | "relayBind" | "relayUnbind" => {
              let ack = if auth.state == AuthState::Verified {
                  apply_binding_message(identity.as_ref(), code, kind, message, now).await
              } else {
                  tracing::debug!(
                      "Refused {} from unverified Astation {}",
                      kind,
                      mask_code(code)
                  );
                  relay_ack_err(kind, "not verified")
              };
              hub.local().send(connection_id, ack);
              true
          }
          // Relay → Astation frame types echoed back: dropped.
          _ => true,
      }
  }

  /// How a new socket entered its room.
  enum Registration {
      Registered,
      /// An Atem's room is gone (removed since ws_handler checked).
      RoomGone,
      /// The room already has MAX_PENDING_ASTATIONS_PER_ROOM pending sockets.
      TooManyPending,
  }

  /// Put a new socket into its room and send its startup frames.
  async fn register_connection(
      hub: &RelayHub,
      code: &str,
      atem_id: &str,
      connection_id: &str,
      auth: Option<&mut AstationAuth>,
  ) -> Result<Registration, StoreError> {
      let me = hub.me(connection_id);
      let Some(auth) = auth else {
          return match hub.directory().join_atem(code, atem_id, &me).await? {
              AtemJoin::NoRoom => Ok(Registration::RoomGone),
              AtemJoin::Joined { replaced, owner } => {
                  hub.room_changed(code).await;
                  if let Some(replaced) = replaced {
                      hub.close_connection(&replaced, None).await;
                  }
                  if let Some(owner) = owner {
                      hub.deliver(&owner, relay_connection_event(atem_id, connection_id, "connected"))
                          .await;
                  }
                  Ok(Registration::Registered)
              }
          };
      };
      // The challenge is always the first frame.
      hub.local().send(connection_id, relay_auth_challenge_frame(&auth.challenge));
      // Decided from the key cache, with no I/O. A registration that lands
      // after this is handled by promote_verified, which evicts an
      // unverified owner.
      if hub.keys().contains(code) {
          auth.state = AuthState::Pending;
      }
      let now = chrono::Utc::now().timestamp();
      if auth.state == AuthState::Pending {
          let admitted = hub
              .directory()
              .add_pending(code, &me, now, MAX_PENDING_ASTATIONS_PER_ROOM)
              .await?;
          if !admitted {
              return Ok(Registration::TooManyPending);
          }
          hub.room_changed(code).await;
          return Ok(Registration::Registered);
      }
      let claim = hub.directory().claim_owner(code, &me, now).await?;
      hub.room_changed(code).await;
      if let Some(replaced) = claim.replaced {
          hub.close_connection(&replaced, None).await;
      }
      for (atem, connection) in &claim.atems {
          hub.local().send(
              connection_id,
              relay_connection_event(atem, &connection.conn, "connected"),
          );
      }
      Ok(Registration::Registered)
  }

  /// Forward queued frames to the socket, with periodic pings for NAT
  /// keepalive (URLSession and tungstenite answer server pings, no client
  /// change). Ends when the queue's sender is gone (flush, then a plain
  /// close) or on a close request (that close frame, at once).
  async fn write_loop(
      mut ws_sink: SplitSink<WebSocket, Message>,
      mut outbox: SocketOutbox,
      code: String,
  ) {
      let mut ping_interval = tokio::time::interval(Duration::from_secs(WS_PING_INTERVAL_SECS));
      ping_interval.tick().await; // skip the immediate first tick
      let mut watch_close = true;
      loop {
          tokio::select! {
              biased;
              changed = outbox.close.changed(), if watch_close => {
                  if changed.is_err() {
                      // Evicted: no close code; flush the queue below.
                      watch_close = false;
                      continue;
                  }
                  let request = outbox.close.borrow_and_update().clone();
                  if let Some((close_code, reason)) = request {
                      let _ = ws_sink
                          .send(Message::Close(Some(CloseFrame {
                              code: close_code,
                              reason: reason.into(),
                          })))
                          .await;
                      break;
                  }
              }
              msg = outbox.frames.recv() => {
                  match msg {
                      Some(text) => {
                          if ws_sink.send(Message::Text(text)).await.is_err() {
                              tracing::debug!("WS write failed for {}", mask_code(&code));
                              break;
                          }
                      }
                      None => {
                          let _ = ws_sink.close().await;
                          break;
                      }
                  }
              }
              _ = ping_interval.tick() => {
                  if ws_sink.send(Message::Ping(Vec::new())).await.is_err() {
                      tracing::debug!("WS ping failed for {} — removing dead connection", mask_code(&code));
                      break;
                  }
              }
          }
      }
  }

  /// Message routing protocol for multi-Atem rooms:
  ///
  /// Atem → Astation: relay wraps the message with `atem_id` and a per-socket `connection_id`.
  /// Astation → Atem: Astation echoes both IDs with the payload; stale generations are dropped.
  /// Astation → ALL:   Astation sends raw JSON (no `atem_id` key) → relay BROADCASTS to every Atem in the room
  /// Astation → relay: relay-auth frames (see above) are handled here, never forwarded.
  ///
  /// The socket may be on any replica; its peers may be on others (delivered
  /// through the bus).
  async fn handle_ws(
      hub: RelayHub,
      identity: Arc<dyn IdentityStore>,
      code: String,
      role: String,
      atem_id: String,
      socket: WebSocket,
  ) {
      let socket_role = match role.as_str() {
          "atem" => SocketRole::Atem { atem_id: atem_id.clone() },
          "astation" => SocketRole::Astation,
          _ => {
              tracing::warn!("Unknown role: {}", role);
              return;
          }
      };
      let (ws_sink, mut ws_stream) = socket.split();
      let connection_id = Uuid::new_v4().to_string();
      let local = hub.local().clone();
      let outbox = local.register(&connection_id, &code, socket_role);

      // An Astation gets a challenge; it must prove the key first when one is
      // registered for this room code (decided from the key cache, no I/O).
      let mut astation_auth = (role == "astation").then(|| AstationAuth {
          challenge: new_relay_challenge(),
          deadline: Instant::now() + hub.auth_timeout(),
          state: AuthState::Legacy,
      });

      // The writer runs from the start, so a refusal below still reaches the client.
      let mut write_task = tokio::spawn(write_loop(ws_sink, outbox, code.clone()));

      let registration =
          register_connection(&hub, &code, &atem_id, &connection_id, astation_auth.as_mut()).await;
      let refused = match registration {
          Ok(Registration::Registered) => false,
          Ok(Registration::RoomGone) => {
              tracing::warn!("Room {} disappeared before WS setup", mask_code(&code));
              local.evict(&connection_id);
              true
          }
          Ok(Registration::TooManyPending) => {
              tracing::warn!(
                  "Refused a pending Astation for room {}: too many pending connections",
                  mask_code(&code)
              );
              local.close_with(&connection_id, CLOSE_TRY_AGAIN, "too many pending connections");
              true
          }
          Err(error) => {
              tracing::error!(
                  "Relay state unavailable registering {} in room {}: {}",
                  role,
                  mask_code(&code),
                  error
              );
              local.close_with(&connection_id, CLOSE_TRY_AGAIN, "relay state unavailable");
              true
          }
      };
      if refused {
          let _ = tokio::time::timeout(Duration::from_secs(2), &mut write_task).await;
          write_task.abort();
          return;
      }

      tracing::info!(
          "WS connected: role={} code={}{}",
          role,
          mask_code(&code),
          match astation_auth.as_ref().map(|auth| auth.state) {
              Some(AuthState::Pending) => " (pending key proof)",
              _ => "",
          }
      );

      // Read incoming frames and forward to the other side.
      // A 90s idle timeout ensures dead connections (no pong response to our 60s ping)
      // are detected and cleaned up within 90s rather than waiting for the OS TCP timeout.
      //
      // Routing rules (see handle_ws comment above for full protocol spec):
      //  - Atem → relay: raw msg → relay adds atem_id and connection_id → Astation
      //  - Astation → relay:
      //      relay-auth frame                → handled here, never forwarded
      //      anything while pending          → dropped
      //      targeted envelope with both IDs → forward only to that exact socket generation
      //      raw msg (no atem_id)           → broadcast payload to ALL Atems in room
      let read_timeout = Duration::from_secs(WS_PING_INTERVAL_SECS + 30);
      // Set when the writer must flush (a rejection, a close frame) before
      // the socket goes.
      let mut flush_writer = false;
      loop {
          let pending_deadline = astation_auth
              .as_ref()
              .filter(|auth| auth.state == AuthState::Pending)
              .map(|auth| auth.deadline);
          if let Some(deadline) = pending_deadline {
              if Instant::now() >= deadline {
                  tracing::warn!(
                      "Pending Astation {} did not prove its key in time",
                      mask_code(&code)
                  );
                  local.send(
                      &connection_id,
                      relay_auth_result_frame("rejected", "authentication timed out"),
                  );
                  flush_writer = true;
                  break;
              }
          }
          let wait = pending_deadline
              .map(|deadline| deadline.saturating_duration_since(Instant::now()).min(read_timeout))
              .unwrap_or(read_timeout);
          let msg_result = match tokio::time::timeout(wait, ws_stream.next()).await {
              Ok(Some(msg)) => msg,
              Ok(None) => break, // stream ended
              Err(_) if pending_deadline.is_some_and(|deadline| Instant::now() >= deadline) => {
                  continue; // the deadline check at the top rejects it
              }
              Err(_) => {
                  tracing::debug!(
                      "WS idle timeout for {} {} — no frame in {}s",
                      role,
                      mask_code(&code),
                      WS_PING_INTERVAL_SECS + 30
                  );
                  break;
              }
          };
          match msg_result {
              Ok(Message::Text(text)) => match (role.as_str(), astation_auth.as_mut()) {
                  ("atem", _) => {
                      // A replaced or removed Atem socket is no longer registered here.
                      if !local.contains(&connection_id) {
                          tracing::debug!(
                              "Dropping stale Atem connection: code={} atem_id={}",
                              mask_code(&code),
                              atem_id
                          );
                          break;
                      }
                      log_atem_auth_attempt(&code, &atem_id, &text);
                      match hub.route_view(&code).await {
                          Ok(Some(RoomInfo { owner: Some(owner), .. })) => {
                              hub.deliver(&owner, atem_envelope(&atem_id, &connection_id, &text))
                                  .await;
                          }
                          Ok(_) => {}
                          Err(error) => tracing::debug!(
                              "Dropped an Atem frame for {}: {}",
                              mask_code(&code),
                              error
                          ),
                      }
                  }
                  ("astation", Some(auth)) => {
                      let parsed = serde_json::from_str::<serde_json::Value>(&text).ok();
                      if let Some(message) = parsed.as_ref() {
                          if let Some(kind) = relay_control_type(message) {
                              let keep_open = handle_astation_control(
                                  &hub,
                                  &identity,
                                  &code,
                                  &connection_id,
                                  auth,
                                  kind,
                                  message,
                              )
                              .await;
                              if !keep_open {
                                  flush_writer = true;
                                  break;
                              }
                              continue;
                          }
                      }
                      if auth.state == AuthState::Pending {
                          tracing::debug!(
                              "Dropping message from pending Astation {}",
                              mask_code(&code)
                          );
                          continue;
                      }
                      // A replaced owner is no longer registered here.
                      if !local.contains(&connection_id) {
                          tracing::debug!("Dropping stale Astation connection: code={}", mask_code(&code));
                          break;
                      }
                      // A generation-bound envelope goes to that exact Atem
                      // socket; raw JSON (no atem_id) goes to all Atems.
                      let Some(envelope) = parsed else {
                          continue;
                      };
                      if let Some(target_id) = envelope.get("atem_id").and_then(|v| v.as_str()) {
                          let Some(requested_connection_id) = envelope
                              .get("connection_id")
                              .and_then(|value| value.as_str())
                          else {
                              tracing::debug!(
                                  "Dropping generationless targeted message: code={} atem_id={}",
                                  mask_code(&code),
                                  target_id
                              );
                              continue;
                          };
                          let payload = envelope
                              .get("payload")
                              .cloned()
                              .unwrap_or(serde_json::Value::Null);
                          match hub.find_atem(&code, target_id, requested_connection_id).await {
                              Some(target) => hub.deliver(&target, payload.to_string()).await,
                              None => tracing::debug!(
                                  "Dropping message for stale or missing Atem connection: code={} atem_id={}",
                                  mask_code(&code),
                                  target_id
                              ),
                          }
                      } else {
                          let targets = match hub.route_view(&code).await {
                              Ok(Some(room)) => room.atems.into_values().collect(),
                              Ok(None) => Vec::new(),
                              Err(error) => {
                                  tracing::debug!(
                                      "Dropped a broadcast for {}: {}",
                                      mask_code(&code),
                                      error
                                  );
                                  Vec::new()
                              }
                          };
                          hub.deliver_many(targets, text.to_string()).await;
                      }
                  }
                  _ => {}
              },
              Ok(Message::Close(_)) => break,
              Ok(Message::Pong(_)) => {} // expected response to our Ping
              Err(e) => {
                  tracing::debug!("WS read error for {} {}: {}", role, mask_code(&code), e);
                  break;
              }
              _ => {}
          }
      }

      // Cleanup: leave the room (a stale close can't remove a newer connection).
      match role.as_str() {
          "atem" => match hub.directory().leave_atem(&code, &atem_id, &connection_id).await {
              Ok(leave) => {
                  if leave.removed || leave.room_removed {
                      hub.room_changed(&code).await;
                  }
                  if leave.removed {
                      if let Some(owner) = leave.owner {
                          hub.deliver(
                              &owner,
                              relay_connection_event(&atem_id, &connection_id, "disconnected"),
                          )
                          .await;
                      }
                  }
                  if leave.room_removed {
                      tracing::info!("Room {} removed (all sides disconnected)", mask_code(&code));
                  }
              }
              Err(error) => tracing::warn!(
                  "Could not remove an Atem from room {}: {}",
                  mask_code(&code),
                  error
              ),
          },
          _ => match hub.directory().leave_astation(&code, &connection_id).await {
              Ok(room_removed) => {
                  hub.room_changed(&code).await;
                  if room_removed {
                      tracing::info!("Room {} removed (all sides disconnected)", mask_code(&code));
                  }
              }
              Err(error) => tracing::warn!(
                  "Could not remove an Astation from room {}: {}",
                  mask_code(&code),
                  error
              ),
          },
      }

      // Drop our sender: the writer flushes what is queued and closes the socket.
      local.evict(&connection_id);
      if flush_writer {
          let _ = tokio::time::timeout(Duration::from_secs(2), &mut write_task).await;
      }
      write_task.abort();
      tracing::info!("WS disconnected: role={} code={}", role, mask_code(&code));
  }
  ```

  **4h. Pair page.** Replace the body of `pair_page_handler` (from
  `let (hostname, initial_status) = {` to the end of the function) with:

  ```rust
      let room = match state.relay.room(&params.code).await {
          Ok(room) => room,
          Err(error) => {
              tracing::error!("Relay state unavailable for the pair page: {}", error);
              return (
                  StatusCode::SERVICE_UNAVAILABLE,
                  Html("<h1>Temporarily unavailable</h1><p>Please retry in a moment.</p>".to_string()),
              )
                  .into_response();
          }
      };
      let Some(room) = room else {
          return (
              StatusCode::NOT_FOUND,
              Html("<h1>Pairing code not found</h1><p>The code may have expired.</p>".to_string()),
          )
              .into_response();
      };
      let now = chrono::Utc::now().timestamp();
      let initial_status = InitialPageStatus {
          atem_connected: !room.atems.is_empty(),
          astation_connected: room.owner.is_some(),
          expired: room.is_expired(now),
      };
      Html(render_pair_page(&params.code, &room.hostname, &initial_status)).into_response()
  ```

  **4i. `KeyCache::reload_one` uses `crate::relay::mask_code`**, which is
  already `pub(crate)`.

- [ ] **Step 5: run and watch it pass.**

  ```bash
  cargo test
  ```

  Every pre-existing test passes (the four removed-and-rewritten ones pass
  under their old names; `stale_atem_cleanup_does_not_remove_replacement` is
  gone), plus `deliveries_stay_local_or_go_to_the_owning_replica`. In
  particular these unchanged WebSocket tests must pass:
  `practical_websocket_replacement_rejects_stale_generation`,
  `legacy_astation_relays_but_creates_no_bindings`,
  `valid_proof_registers_key_and_later_connections_verify`,
  `wrong_key_is_rejected_and_does_not_take_over_the_room`,
  `pending_connection_times_out`, `connecting_does_no_identity_store_io`,
  `registered_astation_verifies_while_db_is_down`,
  `admin_reset_is_picked_up_on_key_mismatch`,
  `loaded_keys_make_known_ids_pending`,
  `atem_joining_while_an_astation_is_pending_is_not_announced_to_it`,
  `delete_is_refused_for_a_keyed_room`. Also run
  `cargo clippy --all-targets` and remove any unused import it reports in
  `relay.rs`.

- [ ] **Step 6: commit.**

  ```bash
  git add relay-server/src/relay.rs
  git commit -m "refactor(relay): route through RoomDirectory, LocalSockets and ReplicaBus

  No behavior change: in-memory directory and loopback bus by default.

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 6: `SessionStore` over a `SessionBackend` trait

**Files:** modify `src/session_store.rs`, `src/routes.rs`, `src/relay.rs`
(ws_handler session block, one test line), `src/vault_routes.rs` (one test
line), `src/main.rs` (sweep loop).

**Interfaces.**
Consumes: `StoreError`, `auth::{Session, SessionStatus, generate_session_token}`.
Produces (`session_store.rs`):
- `pub enum GrantOutcome { NotFound, NotPending(SessionStatus), Expired, InvalidOtp, Granted(Session) }` (Debug, Clone)
- `pub enum DenyOutcome { NotFound, NotPending(SessionStatus), Denied(Session) }` (Debug, Clone)
- `#[async_trait] pub trait SessionBackend: Send + Sync`:
  `create(Session) -> Result<(), StoreError>`, `get(&str) -> Result<Option<Session>, StoreError>`,
  `update(&str, Session) -> Result<(), StoreError>`, `delete(&str) -> Result<(), StoreError>`,
  `grant(&str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError>`,
  `deny(&str) -> Result<DenyOutcome, StoreError>`, `touch(&str) -> Result<(), StoreError>`,
  `cleanup_expired(&self) -> Result<(), StoreError>`
- `#[derive(Clone, Default)] pub struct InMemorySessionBackend`
- `SessionStore` (Clone): `new()`, `with_backend(Arc<dyn SessionBackend>)`, and
  `create/get/update/delete/deny/touch/cleanup_expired` delegating, plus
  `grant(&self, id: &str, otp: &str) -> Result<GrantOutcome, StoreError>`
  (generates the token)

Grant semantics equal today's handler: not found → `NotFound`; status not
pending → `NotPending(status)`; `now > expires_at` → `Expired`; wrong OTP →
`InvalidOtp`; else the session becomes granted with the token, atomically
(one lock in memory, one Lua script in Redis).

- [ ] **Step 1: make the existing tests use the fallible API.** Run this
  first, before adding new tests (it appends `.unwrap()` after every
  matching `.await` in test modules, so it must not see the new tests).
  From `relay-server/`:

  ```bash
  cat > /tmp/sessions-unwrap.pl <<'EOF'
  my ($head, $tests) = split(/(?=#\[cfg\(test\)\]\n(?:pub\(crate\) )?mod tests)/, $_, 2);
  $tests =~ s/(\b(?:store|store1|store2|state\.sessions)\s*\.\s*(?:create|get|update|delete|cleanup_expired)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s*\.await)/$1.unwrap()/g;
  $_ = $head . $tests;
  EOF
  perl -0pi /tmp/sessions-unwrap.pl src/session_store.rs src/routes.rs src/vault_routes.rs
  git diff --stat
  ```

  Expected: `session_store.rs` (26 lines), `routes.rs` (2), `vault_routes.rs`
  (1). Then in `src/relay.rs`'s test `vault_and_knowledge_routes_need_a_binding`
  change `state.sessions.create(granted).await;` to
  `state.sessions.create(granted).await.unwrap();`. Do not touch
  `knowledge_routes.rs`; it never calls the session store.

- [ ] **Step 2: write the new tests.** Append to the test module of
  `src/session_store.rs`:

  ```rust
  #[tokio::test]
  async fn grant_is_atomic_and_checks_in_order() {
      let store = SessionStore::new();
      let session = create_session("grant-host");
      let id = session.id.clone();
      let otp = session.otp.clone();
      store.create(session).await.unwrap();

      assert!(matches!(store.grant("missing", &otp).await.unwrap(), GrantOutcome::NotFound));
      assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::InvalidOtp));
      let granted = match store.grant(&id, &otp).await.unwrap() {
          GrantOutcome::Granted(session) => session,
          other => panic!("expected Granted, got {other:?}"),
      };
      assert_eq!(granted.status, SessionStatus::Granted);
      assert_eq!(granted.token.as_ref().map(String::len), Some(64));
      assert!(matches!(
          store.grant(&id, &otp).await.unwrap(),
          GrantOutcome::NotPending(SessionStatus::Granted)
      ));
      assert!(matches!(
          store.deny(&id).await.unwrap(),
          DenyOutcome::NotPending(SessionStatus::Granted)
      ));
  }

  #[tokio::test]
  async fn grant_of_an_expired_session_is_expired_even_with_the_right_otp() {
      let store = SessionStore::new();
      let now = Utc::now();
      let expired = Session {
          id: Uuid::new_v4().to_string(),
          otp: "12345678".to_string(),
          hostname: "late".to_string(),
          status: SessionStatus::Pending,
          token: None,
          created_at: now - Duration::minutes(10),
          expires_at: now - Duration::minutes(5),
          astation_id: None,
      };
      let id = expired.id.clone();
      store.create(expired).await.unwrap();
      assert!(matches!(store.grant(&id, "12345678").await.unwrap(), GrantOutcome::Expired));
      assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::Expired));
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  async fn concurrent_grants_apply_once() {
      let store = SessionStore::new();
      let session = create_session("race-host");
      let (id, otp) = (session.id.clone(), session.otp.clone());
      store.create(session).await.unwrap();
      let handles: Vec<_> = (0..8)
          .map(|_| {
              let (store, id, otp) = (store.clone(), id.clone(), otp.clone());
              tokio::spawn(async move { store.grant(&id, &otp).await.unwrap() })
          })
          .collect();
      let mut granted = 0;
      for handle in handles {
          if matches!(handle.await.unwrap(), GrantOutcome::Granted(_)) {
              granted += 1;
          }
      }
      assert_eq!(granted, 1);
  }

  #[tokio::test]
  async fn deny_applies_only_while_pending() {
      let store = SessionStore::new();
      let session = create_session("deny-host");
      let id = session.id.clone();
      store.create(session).await.unwrap();
      assert!(matches!(store.deny("missing").await.unwrap(), DenyOutcome::NotFound));
      match store.deny(&id).await.unwrap() {
          DenyOutcome::Denied(session) => assert_eq!(session.status, SessionStatus::Denied),
          other => panic!("expected Denied, got {other:?}"),
      }
      assert!(matches!(
          store.deny(&id).await.unwrap(),
          DenyOutcome::NotPending(SessionStatus::Denied)
      ));
  }
  ```

- [ ] **Step 3: run and watch it fail.** `cargo test session_store` does not
  compile (`grant`, `deny`, `GrantOutcome`, `Result` from `create`).

- [ ] **Step 4: implement.** Replace everything above `#[cfg(test)]` in
  `src/session_store.rs` with:

  ```rust
  //! Pairing/OTP sessions. In-memory by default; Redis-backed
  //! (`relay:session:<id>`) when REDIS_URL is set, so create, grant, poll and
  //! the `?session=` WebSocket can each reach a different replica.

  use std::collections::HashMap;
  use std::sync::Arc;

  use async_trait::async_trait;
  use chrono::{DateTime, Utc};
  use tokio::sync::RwLock;

  use crate::auth::{Session, SessionStatus};
  use crate::cluster::StoreError;

  /// Result of an OTP grant, applied atomically by the backend.
  #[derive(Debug, Clone)]
  pub enum GrantOutcome {
      NotFound,
      NotPending(SessionStatus),
      Expired,
      InvalidOtp,
      Granted(Session),
  }

  #[derive(Debug, Clone)]
  pub enum DenyOutcome {
      NotFound,
      NotPending(SessionStatus),
      Denied(Session),
  }

  #[async_trait]
  pub trait SessionBackend: Send + Sync {
      async fn create(&self, session: Session) -> Result<(), StoreError>;
      async fn get(&self, id: &str) -> Result<Option<Session>, StoreError>;
      async fn update(&self, id: &str, session: Session) -> Result<(), StoreError>;
      async fn delete(&self, id: &str) -> Result<(), StoreError>;
      /// Pending, unexpired and the OTP matches → granted with `token`.
      async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError>;
      /// Pending → denied.
      async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError>;
      /// A granted session was used (`?session=` WebSocket): keep it alive.
      async fn touch(&self, id: &str) -> Result<(), StoreError>;
      /// Remove expired pending sessions (in-memory; Redis expires keys).
      async fn cleanup_expired(&self) -> Result<(), StoreError>;
  }

  #[derive(Clone, Default)]
  pub struct InMemorySessionBackend {
      sessions: Arc<RwLock<HashMap<String, Session>>>,
  }

  #[async_trait]
  impl SessionBackend for InMemorySessionBackend {
      async fn create(&self, session: Session) -> Result<(), StoreError> {
          self.sessions.write().await.insert(session.id.clone(), session);
          Ok(())
      }

      async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
          Ok(self.sessions.read().await.get(id).cloned())
      }

      async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
          self.sessions.write().await.insert(id.to_string(), session);
          Ok(())
      }

      async fn delete(&self, id: &str) -> Result<(), StoreError> {
          self.sessions.write().await.remove(id);
          Ok(())
      }

      async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError> {
          let mut sessions = self.sessions.write().await;
          let Some(session) = sessions.get_mut(id) else {
              return Ok(GrantOutcome::NotFound);
          };
          if session.status != SessionStatus::Pending {
              return Ok(GrantOutcome::NotPending(session.status.clone()));
          }
          if now > session.expires_at {
              return Ok(GrantOutcome::Expired);
          }
          if session.otp != otp {
              return Ok(GrantOutcome::InvalidOtp);
          }
          session.status = SessionStatus::Granted;
          session.token = Some(token.to_string());
          Ok(GrantOutcome::Granted(session.clone()))
      }

      async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
          let mut sessions = self.sessions.write().await;
          let Some(session) = sessions.get_mut(id) else {
              return Ok(DenyOutcome::NotFound);
          };
          if session.status != SessionStatus::Pending {
              return Ok(DenyOutcome::NotPending(session.status.clone()));
          }
          session.status = SessionStatus::Denied;
          Ok(DenyOutcome::Denied(session.clone()))
      }

      async fn touch(&self, _id: &str) -> Result<(), StoreError> {
          Ok(())
      }

      /// Remove all sessions that have expired and are still pending.
      async fn cleanup_expired(&self) -> Result<(), StoreError> {
          let now = Utc::now();
          self.sessions
              .write()
              .await
              .retain(|_, session| !(now > session.expires_at && session.status == SessionStatus::Pending));
          Ok(())
      }
  }

  /// Pairing/OTP sessions, shared by every route that uses them.
  #[derive(Clone)]
  pub struct SessionStore {
      backend: Arc<dyn SessionBackend>,
  }

  impl SessionStore {
      pub fn new() -> Self {
          Self::with_backend(Arc::new(InMemorySessionBackend::default()))
      }

      pub fn with_backend(backend: Arc<dyn SessionBackend>) -> Self {
          Self { backend }
      }

      pub async fn create(&self, session: Session) -> Result<(), StoreError> {
          self.backend.create(session).await
      }

      pub async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
          self.backend.get(id).await
      }

      pub async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
          self.backend.update(id, session).await
      }

      pub async fn delete(&self, id: &str) -> Result<(), StoreError> {
          self.backend.delete(id).await
      }

      /// Validate the OTP and grant with a fresh session token, atomically.
      pub async fn grant(&self, id: &str, otp: &str) -> Result<GrantOutcome, StoreError> {
          let token = crate::auth::generate_session_token();
          self.backend.grant(id, otp, &token, Utc::now()).await
      }

      pub async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
          self.backend.deny(id).await
      }

      pub async fn touch(&self, id: &str) -> Result<(), StoreError> {
          self.backend.touch(id).await
      }

      pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
          self.backend.cleanup_expired().await
      }
  }

  impl Default for SessionStore {
      fn default() -> Self {
          Self::new()
      }
  }
  ```

  In `src/routes.rs`:
  - below the existing `use crate::auth::{self, SessionStatus};` add
    `use crate::cluster::StoreError;` and
    `use crate::session_store::{DenyOutcome, GrantOutcome};`;
  - add these helpers after `pub struct AuthPageQuery { … }`:

    ```rust
    fn store_unavailable(error: StoreError) -> (StatusCode, Json<ErrorResponse>) {
        tracing::error!("Session store unavailable: {}", error);
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ErrorResponse { error: "Temporarily unavailable".to_string() }),
        )
    }

    fn not_found() -> (StatusCode, Json<ErrorResponse>) {
        (
            StatusCode::NOT_FOUND,
            Json(ErrorResponse { error: "Session not found".to_string() }),
        )
    }

    fn already(status: &SessionStatus) -> (StatusCode, Json<ErrorResponse>) {
        (
            StatusCode::CONFLICT,
            Json(ErrorResponse {
                error: format!(
                    "Session is already {}",
                    serde_json::to_string(status)
                        .unwrap_or_default()
                        .trim_matches('"')
                ),
            }),
        )
    }
    ```

  - in `create_session_handler`, replace `state.sessions.create(session).await;`
    with:

    ```rust
    if let Err(error) = state.sessions.create(session).await {
        return store_unavailable(error).into_response();
    }
    ```

  - replace the bodies of `get_session_status_handler`,
    `grant_session_handler`, `deny_session_handler` and `auth_page_handler`
    (signatures unchanged) with, respectively:

    ```rust
    let session = match state.sessions.get(&id).await {
        Ok(Some(session)) => session,
        Ok(None) => return Err(not_found()),
        Err(error) => return Err(store_unavailable(error)),
    };
    // Check if session has expired
    let status = if session.status == SessionStatus::Pending
        && chrono::Utc::now() > session.expires_at
    {
        SessionStatus::Expired
    } else {
        session.status.clone()
    };
    let token = if status == SessionStatus::Granted {
        session.token.clone()
    } else {
        None
    };
    Ok(Json(SessionStatusResponse {
        id: session.id,
        status,
        token,
    }))
    ```

    ```rust
    match state.sessions.grant(&id, &body.otp).await {
        Err(error) => Err(store_unavailable(error)),
        Ok(GrantOutcome::NotFound) => Err(not_found()),
        Ok(GrantOutcome::NotPending(status)) => Err(already(&status)),
        Ok(GrantOutcome::Expired) => Err((
            StatusCode::GONE,
            Json(ErrorResponse { error: "Session has expired".to_string() }),
        )),
        Ok(GrantOutcome::InvalidOtp) => Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse { error: "Invalid OTP".to_string() }),
        )),
        Ok(GrantOutcome::Granted(session)) => Ok(Json(SessionStatusResponse {
            id: session.id,
            status: session.status,
            token: session.token,
        })),
    }
    ```

    ```rust
    match state.sessions.deny(&id).await {
        Err(error) => Err(store_unavailable(error)),
        Ok(DenyOutcome::NotFound) => Err(not_found()),
        Ok(DenyOutcome::NotPending(status)) => Err(already(&status)),
        Ok(DenyOutcome::Denied(session)) => Ok(Json(SessionStatusResponse {
            id: session.id,
            status: session.status,
            token: None,
        })),
    }
    ```

    ```rust
    match state.sessions.get(&params.id).await {
        Ok(Some(session)) => Ok(Html(auth_page::render_auth_page(
            &session.id,
            &params.tag,
            &session.otp,
        ))),
        Ok(None) => Err((
            StatusCode::NOT_FOUND,
            Html(
                "<h1>Session not found</h1><p>The requested session does not exist or has been removed.</p>"
                    .to_string(),
            ),
        )),
        Err(error) => {
            tracing::error!("Session store unavailable: {}", error);
            Err((
                StatusCode::SERVICE_UNAVAILABLE,
                Html("<h1>Temporarily unavailable</h1><p>Please retry in a moment.</p>".to_string()),
            ))
        }
    }
    ```

  In `src/relay.rs` `ws_handler`, restore the session block exactly as Task 5
  Step 4d shows it (the `match state.sessions.get(…)` with `ws_unavailable`,
  and the `state.sessions.touch(…)` call).

  In `src/main.rs`, replace `cleanup_sessions.cleanup_expired().await;` with:

  ```rust
  if let Err(error) = cleanup_sessions.cleanup_expired().await {
      tracing::debug!("Session sweep failed: {}", error);
  }
  ```

- [ ] **Step 5: run and watch it pass.** `cargo test` (all), then
  `cargo clippy --all-targets`.

- [ ] **Step 6: commit.**

  ```bash
  git add relay-server/src
  git commit -m "refactor(relay): SessionStore over a backend trait with atomic grant/deny

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 7: `VoiceSessionStore` over a `VoiceBackend` trait

**Files:** modify `src/voice_session.rs`, `src/llm_proxy.rs`,
`src/voice_routes.rs`, `src/main.rs` (sweep loop).

**Interfaces.**
Consumes: `StoreError`.
Produces (`voice_session.rs`):
- `pub enum WaitOutcome { Reply(String), TimedOut, Closed }` (Debug, Clone, PartialEq, Eq)
- `#[derive(Clone, Default)] pub struct ReplyWaiters` with
  `register(&self, &str) -> oneshot::Receiver<String>`,
  `wake(&self, &str, &str) -> usize`, `prune(&self, &str)`
- `#[async_trait] pub trait VoiceBackend: Send + Sync` with, all `-> Result<_, StoreError>`:
  `create(VoiceSession) -> ()`, `get(&str) -> Option<VoiceSession>`,
  `add_transcription(&str, String) -> Option<()>`, `trigger(&str) -> Option<String>`,
  `set_response(&str, String) -> Option<()>`, `increment_requests(&str) -> Option<u32>`,
  `get_state(&str) -> Option<VoiceSessionState>`, `delete(&str) -> ()`,
  `cleanup_expired() -> ()`, `get_by_atem(&str) -> Vec<VoiceSession>`,
  `list_session_ids() -> Vec<String>`, `wait_reply(&str, Duration) -> WaitOutcome`
- `#[derive(Clone, Default)] pub struct InMemoryVoiceBackend` (+ `#[cfg(test)] age_for_test(&self, &str, i64)`)
- `VoiceSessionStore` (Clone): `new()`, `with_backend(Arc<dyn VoiceBackend>)`,
  `create(String, String, String) -> Result<VoiceSession, StoreError>`, and the
  same methods as the trait (delegating). `register_waiter` is removed.
- `pub const LLM_WAIT_SECS: u64 = 30;` in `llm_proxy.rs`

`wait_reply` registers the waiter *before* checking for an answer that
already arrived (in memory: a `ResponseReady` session's `response`), then
waits up to the timeout.

- [ ] **Step 1: add tokio's test clock** (dev-only) to `Cargo.toml`
  `[dev-dependencies]`:

  ```toml
  tokio = { version = "1", features = ["full", "test-util"] }
  ```

- [ ] **Step 2: make the existing tests use the fallible API.** Run this
  before writing the new tests (it must not see them). From `relay-server/`:

  ```bash
  cat > /tmp/voice-unwrap.pl <<'EOF'
  my ($head, $tests) = split(/(?=#\[cfg\(test\)\]\n(?:pub\(crate\) )?mod tests)/, $_, 2);
  $tests =~ s/(\b(?:store|store1|store2|state\.voice_sessions|state_clone\.voice_sessions)\s*\.\s*(?:create|get|add_transcription|trigger|set_response|increment_requests|get_state|delete|cleanup_expired|get_by_atem|list_session_ids)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s*\.await)/$1.unwrap()/g;
  $_ = $head . $tests;
  EOF
  perl -0pi /tmp/voice-unwrap.pl src/voice_session.rs src/voice_routes.rs src/llm_proxy.rs
  ```

  Where an old line already unwrapped an `Option`
  (`store.get("x").await.unwrap()`), the result is
  `.await.unwrap().unwrap()`, which is correct. Handler code is outside the
  test modules and is untouched (Step 5 rewrites it).

- [ ] **Step 3: write the new tests.** In `src/voice_session.rs`'s test module,
  replace `waiter_mechanism` and `waiter_multiple_waiters_all_notified` with:

  ```rust
  #[tokio::test]
  async fn waiter_mechanism() {
      let store = VoiceSessionStore::new();
      store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await.unwrap();
      tokio::spawn({
          let store = store.clone();
          async move {
              tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
              store.set_response("test", "Response!".to_string()).await.unwrap();
          }
      });
      let result = store.wait_reply("test", std::time::Duration::from_secs(5)).await.unwrap();
      assert_eq!(result, WaitOutcome::Reply("Response!".to_string()));
  }

  #[tokio::test]
  async fn waiter_multiple_waiters_all_notified() {
      let store = VoiceSessionStore::new();
      store.create("test".to_string(), "atem".to_string(), "ch".to_string()).await.unwrap();
      let wait = std::time::Duration::from_secs(5);
      let (a, b, _) = tokio::join!(
          store.wait_reply("test", wait),
          store.wait_reply("test", wait),
          async {
              tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
              store.set_response("test", "Response!".to_string()).await.unwrap();
          }
      );
      assert_eq!(a.unwrap(), WaitOutcome::Reply("Response!".to_string()));
      assert_eq!(b.unwrap(), WaitOutcome::Reply("Response!".to_string()));
  }

  #[tokio::test]
  async fn wait_reply_returns_an_answer_that_arrived_first() {
      let store = VoiceSessionStore::new();
      store.create("early".to_string(), "atem".to_string(), "ch".to_string()).await.unwrap();
      store.set_response("early", "already here".to_string()).await.unwrap();
      let result = store.wait_reply("early", std::time::Duration::from_millis(50)).await.unwrap();
      assert_eq!(result, WaitOutcome::Reply("already here".to_string()));
  }

  #[tokio::test(start_paused = true)]
  async fn wait_reply_times_out() {
      let store = VoiceSessionStore::new();
      store.create("slow".to_string(), "atem".to_string(), "ch".to_string()).await.unwrap();
      let result = store.wait_reply("slow", std::time::Duration::from_secs(30)).await.unwrap();
      assert_eq!(result, WaitOutcome::TimedOut);
  }
  ```

  Replace `store_cleanup_expired_removes_old_sessions` with:

  ```rust
  #[tokio::test]
  async fn store_cleanup_expired_removes_old_sessions() {
      let backend = InMemoryVoiceBackend::default();
      let store = VoiceSessionStore::with_backend(std::sync::Arc::new(backend.clone()));
      store.create("fresh".to_string(), "atem".to_string(), "ch".to_string()).await.unwrap();
      backend.age_for_test("fresh", 120).await;
      store.cleanup_expired().await.unwrap();
      assert!(store.get("fresh").await.unwrap().is_none());
  }
  ```

  In `src/llm_proxy.rs`'s test module add:

  ```rust
  #[tokio::test(start_paused = true)]
  async fn test_triggered_times_out_with_504() {
      let state = create_test_state();
      state.voice_sessions.create(
          "test-timeout".to_string(),
          "atem-1".to_string(),
          "channel-1".to_string(),
      ).await.unwrap();
      state.voice_sessions.trigger("test-timeout").await.unwrap();
      let mut headers = axum::http::HeaderMap::new();
      headers.insert("x-voice-session-id", "test-timeout".parse().unwrap());
      let response = llm_chat_handler(
          State(state),
          Query(LlmChatQuery { session_id: None }),
          headers,
          Json(ChatCompletionRequest {
              messages: vec![ChatMessage { role: "user".to_string(), content: "go".to_string() }],
          }),
      ).await;
      assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
  }
  ```

- [ ] **Step 4: run and watch it fail.** `cargo test voice` does not compile
  (`wait_reply`, `WaitOutcome`, `InMemoryVoiceBackend`).

- [ ] **Step 5: implement.** In `src/voice_session.rs`, keep
  `VoiceSessionState`, `VoiceSession` and its `impl`, and the request and
  response types. Replace the imports and the `VoiceSessionStore`
  struct plus its `impl` (from `/// Store for managing multiple voice sessions`
  to the closing `}` of `impl VoiceSessionStore`) with the code below, and
  change the imports at the top to:

  ```rust
  use std::collections::HashMap;
  use std::sync::Arc;
  use std::time::Duration;

  use async_trait::async_trait;
  use chrono::{DateTime, Utc};
  use serde::{Deserialize, Serialize};
  use tokio::sync::{oneshot, RwLock};

  use crate::cluster::StoreError;
  ```

  ```rust
  /// How a wait for the Atem's answer ended.
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum WaitOutcome {
      Reply(String),
      TimedOut,
      /// The waiter was dropped without an answer.
      Closed,
  }

  /// Local `/api/llm/chat` requests waiting for an answer, by session id.
  /// In-memory mode wakes them directly; Redis mode wakes them from the
  /// `relay:voice-reply:<id>` channel.
  #[derive(Clone, Default)]
  pub struct ReplyWaiters {
      waiters: Arc<std::sync::Mutex<HashMap<String, Vec<oneshot::Sender<String>>>>>,
  }

  impl ReplyWaiters {
      fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Vec<oneshot::Sender<String>>>> {
          self.waiters.lock().unwrap_or_else(|e| e.into_inner())
      }

      pub fn register(&self, session_id: &str) -> oneshot::Receiver<String> {
          let (tx, rx) = oneshot::channel();
          self.lock().entry(session_id.to_string()).or_default().push(tx);
          rx
      }

      /// Hand `reply` to every waiter of `session_id`; returns how many.
      pub fn wake(&self, session_id: &str, reply: &str) -> usize {
          let senders = self.lock().remove(session_id).unwrap_or_default();
          let count = senders.len();
          for sender in senders {
              let _ = sender.send(reply.to_string());
          }
          count
      }

      /// Drop waiters whose request is gone (timed out).
      pub fn prune(&self, session_id: &str) {
          let mut waiters = self.lock();
          if let Some(senders) = waiters.get_mut(session_id) {
              senders.retain(|sender| !sender.is_closed());
              if senders.is_empty() {
                  waiters.remove(session_id);
              }
          }
      }
  }

  #[async_trait]
  pub trait VoiceBackend: Send + Sync {
      async fn create(&self, session: VoiceSession) -> Result<(), StoreError>;
      async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError>;
      async fn add_transcription(&self, session_id: &str, text: String) -> Result<Option<()>, StoreError>;
      async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError>;
      async fn set_response(&self, session_id: &str, response: String) -> Result<Option<()>, StoreError>;
      async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError>;
      async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError>;
      async fn delete(&self, session_id: &str) -> Result<(), StoreError>;
      async fn cleanup_expired(&self) -> Result<(), StoreError>;
      async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError>;
      async fn list_session_ids(&self) -> Result<Vec<String>, StoreError>;
      /// Wait up to `timeout` for the Atem's answer. The waiter is registered
      /// before an already-arrived answer is checked, so none slips through.
      async fn wait_reply(&self, session_id: &str, timeout: Duration) -> Result<WaitOutcome, StoreError>;
  }

  #[derive(Clone, Default)]
  pub struct InMemoryVoiceBackend {
      sessions: Arc<RwLock<HashMap<String, VoiceSession>>>,
      waiters: ReplyWaiters,
  }

  impl InMemoryVoiceBackend {
      #[cfg(test)]
      pub(crate) async fn age_for_test(&self, session_id: &str, seconds: i64) {
          if let Some(session) = self.sessions.write().await.get_mut(session_id) {
              session.last_activity = Utc::now() - chrono::Duration::seconds(seconds);
          }
      }
  }

  #[async_trait]
  impl VoiceBackend for InMemoryVoiceBackend {
      async fn create(&self, session: VoiceSession) -> Result<(), StoreError> {
          self.sessions
              .write()
              .await
              .insert(session.session_id.clone(), session);
          Ok(())
      }

      async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
          Ok(self.sessions.read().await.get(session_id).cloned())
      }

      async fn add_transcription(&self, session_id: &str, text: String) -> Result<Option<()>, StoreError> {
          Ok(self
              .sessions
              .write()
              .await
              .get_mut(session_id)
              .map(|session| session.add_transcription(text)))
      }

      async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
          Ok(self.sessions.write().await.get_mut(session_id).map(|session| {
              session.trigger();
              session.get_accumulated_text()
          }))
      }

      async fn set_response(&self, session_id: &str, response: String) -> Result<Option<()>, StoreError> {
          {
              let mut sessions = self.sessions.write().await;
              let Some(session) = sessions.get_mut(session_id) else {
                  tracing::warn!("Attempted to set response for nonexistent session: {}", session_id);
                  return Ok(None);
              };
              session.set_response(response.clone());
          }
          let woken = self.waiters.wake(session_id, &response);
          if woken > 0 {
              tracing::info!("Woke {} waiting LLM requests for session {}", woken, session_id);
          }
          Ok(Some(()))
      }

      async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
          Ok(self.sessions.write().await.get_mut(session_id).map(|session| {
              session.increment_requests();
              session.request_count
          }))
      }

      async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError> {
          Ok(self
              .sessions
              .read()
              .await
              .get(session_id)
              .map(|session| session.state.clone()))
      }

      async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
          self.sessions.write().await.remove(session_id);
          Ok(())
      }

      async fn cleanup_expired(&self) -> Result<(), StoreError> {
          let mut sessions = self.sessions.write().await;
          let expired: Vec<String> = sessions
              .iter()
              .filter(|(_, session)| session.is_expired())
              .map(|(id, _)| id.clone())
              .collect();
          for session_id in expired {
              sessions.remove(&session_id);
              tracing::info!("Cleaned up expired voice session: {}", session_id);
          }
          Ok(())
      }

      async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
          Ok(self
              .sessions
              .read()
              .await
              .values()
              .filter(|session| session.atem_id == atem_id)
              .cloned()
              .collect())
      }

      async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
          Ok(self.sessions.read().await.keys().cloned().collect())
      }

      async fn wait_reply(&self, session_id: &str, timeout: Duration) -> Result<WaitOutcome, StoreError> {
          let receiver = self.waiters.register(session_id);
          let arrived = self
              .sessions
              .read()
              .await
              .get(session_id)
              .filter(|session| session.state == VoiceSessionState::ResponseReady)
              .and_then(|session| session.response.clone());
          if let Some(reply) = arrived {
              self.waiters.prune(session_id);
              return Ok(WaitOutcome::Reply(reply));
          }
          let outcome = match tokio::time::timeout(timeout, receiver).await {
              Ok(Ok(reply)) => WaitOutcome::Reply(reply),
              Ok(Err(_)) => WaitOutcome::Closed,
              Err(_) => WaitOutcome::TimedOut,
          };
          self.waiters.prune(session_id);
          Ok(outcome)
      }
  }

  /// Voice sessions, shared by the voice routes and the LLM proxy.
  #[derive(Clone)]
  pub struct VoiceSessionStore {
      backend: Arc<dyn VoiceBackend>,
  }

  impl VoiceSessionStore {
      pub fn new() -> Self {
          Self::with_backend(Arc::new(InMemoryVoiceBackend::default()))
      }

      pub fn with_backend(backend: Arc<dyn VoiceBackend>) -> Self {
          Self { backend }
      }

      /// Create a new voice session
      pub async fn create(&self, session_id: String, atem_id: String, channel: String) -> Result<VoiceSession, StoreError> {
          let session = VoiceSession::new(session_id.clone(), atem_id, channel);
          self.backend.create(session.clone()).await?;
          tracing::info!("Created voice session: {}", session_id);
          Ok(session)
      }

      pub async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
          self.backend.get(session_id).await
      }

      pub async fn add_transcription(&self, session_id: &str, text: String) -> Result<Option<()>, StoreError> {
          self.backend.add_transcription(session_id, text).await
      }

      pub async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
          self.backend.trigger(session_id).await
      }

      pub async fn set_response(&self, session_id: &str, response: String) -> Result<Option<()>, StoreError> {
          self.backend.set_response(session_id, response).await
      }

      pub async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
          self.backend.increment_requests(session_id).await
      }

      pub async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError> {
          self.backend.get_state(session_id).await
      }

      pub async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
          self.backend.delete(session_id).await?;
          tracing::info!("Deleted voice session: {}", session_id);
          Ok(())
      }

      pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
          self.backend.cleanup_expired().await
      }

      pub async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
          self.backend.get_by_atem(atem_id).await
      }

      pub async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
          self.backend.list_session_ids().await
      }

      pub async fn wait_reply(&self, session_id: &str, timeout: Duration) -> Result<WaitOutcome, StoreError> {
          self.backend.wait_reply(session_id, timeout).await
      }
  }

  impl Default for VoiceSessionStore {
      fn default() -> Self {
          Self::new()
      }
  }
  ```

  In `src/llm_proxy.rs`:
  - add imports `use crate::cluster::StoreError;` and
    `use crate::voice_session::WaitOutcome;`;
  - add after the imports:

    ```rust
    /// How long a Triggered request waits for the Atem's answer.
    pub const LLM_WAIT_SECS: u64 = 30;

    fn voice_unavailable(session_id: &str, error: StoreError) -> Response {
        tracing::error!("Voice store unavailable for session {}: {}", session_id, error);
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({"error": "Temporarily unavailable"})),
        )
            .into_response()
    }
    ```

  - in `llm_chat_handler`, replace everything from
    `// Increment request counter` to the end of the function with:

    ```rust
    let voice = &state.voice_sessions;
    if let Err(error) = voice.increment_requests(&session_id).await {
        return voice_unavailable(&session_id, error);
    }
    if let Err(error) = voice.add_transcription(&session_id, last_message).await {
        return voice_unavailable(&session_id, error);
    }
    let session_state = match voice.get_state(&session_id).await {
        Ok(session_state) => session_state,
        Err(error) => return voice_unavailable(&session_id, error),
    };

    match session_state {
        Some(VoiceSessionState::Accumulating) => {
            tracing::debug!("Session {} in Accumulating state - returning empty response", session_id);
            create_empty_response().into_response()
        }
        Some(VoiceSessionState::Triggered) => {
            tracing::info!("Session {} in Triggered state - blocking for Atem response", session_id);
            match voice
                .wait_reply(&session_id, std::time::Duration::from_secs(LLM_WAIT_SECS))
                .await
            {
                Ok(WaitOutcome::Reply(response_text)) => {
                    tracing::info!("Session {}: Received response from Atem", session_id);
                    create_response(response_text).into_response()
                }
                Ok(WaitOutcome::Closed) => {
                    tracing::error!("Session {}: Waiter channel closed", session_id);
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({"error": "Response channel closed"})),
                    )
                        .into_response()
                }
                Ok(WaitOutcome::TimedOut) => {
                    tracing::error!("Session {}: Timeout waiting for Atem response", session_id);
                    (
                        StatusCode::GATEWAY_TIMEOUT,
                        Json(serde_json::json!({"error": "Timeout waiting for Atem response"})),
                    )
                        .into_response()
                }
                Err(error) => voice_unavailable(&session_id, error),
            }
        }
        Some(VoiceSessionState::ResponseReady) => match voice.get(&session_id).await {
            Err(error) => voice_unavailable(&session_id, error),
            Ok(Some(VoiceSession { response: Some(response_text), .. })) => {
                tracing::debug!("Session {} in ResponseReady state - returning cached response", session_id);
                // Clean up session after delivering response
                if let Err(error) = voice.delete(&session_id).await {
                    tracing::warn!("Could not delete voice session {}: {}", session_id, error);
                }
                create_response(response_text).into_response()
            }
            Ok(_) => {
                tracing::error!("Session {} in ResponseReady but no cached response", session_id);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"error": "Response ready but not found"})),
                )
                    .into_response()
            }
        },
        None => {
            tracing::warn!("Session {} not found", session_id);
            (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": "Session not found"})),
            )
                .into_response()
        }
    }
    ```

    and change `use crate::voice_session::VoiceSessionState;` to
    `use crate::voice_session::{VoiceSession, VoiceSessionState};`.

  In `src/voice_routes.rs`, add `use crate::cluster::StoreError;` and this
  helper after the imports:

  ```rust
  fn unavailable(error: StoreError) -> StatusCode {
      tracing::error!("Voice store unavailable: {}", error);
      StatusCode::SERVICE_UNAVAILABLE
  }
  ```

  and change the store calls in the handlers (only the lines shown):

  ```rust
  // create_voice_session_handler
  let session = state.voice_sessions.create(
      session_id.clone(),
      req.atem_id.clone(),
      req.channel.clone(),
  ).await.map_err(unavailable)?;

  // trigger_voice_session_handler
  let accumulated_text = state.voice_sessions.trigger(&session_id).await
      .map_err(unavailable)?
      .ok_or(StatusCode::NOT_FOUND)?;
  let session = state.voice_sessions.get(&session_id).await
      .map_err(unavailable)?
      .ok_or(StatusCode::NOT_FOUND)?;

  // atem_response_handler
  state.voice_sessions.set_response(&req.session_id, req.response.clone()).await
      .map_err(unavailable)?
      .ok_or(StatusCode::NOT_FOUND)?;

  // get_voice_session_handler
  let session = state.voice_sessions.get(&session_id).await
      .map_err(unavailable)?
      .ok_or(StatusCode::NOT_FOUND)?;

  // delete_voice_session_handler
  state.voice_sessions.delete(&session_id).await.map_err(unavailable)?;

  // list_voice_sessions_handler
  let session_ids = state.voice_sessions.list_session_ids().await.map_err(unavailable)?;
  ```

  In `src/main.rs`, replace `cleanup_voice.cleanup_expired().await;` with:

  ```rust
  if let Err(error) = cleanup_voice.cleanup_expired().await {
      tracing::debug!("Voice session sweep failed: {}", error);
  }
  ```

- [ ] **Step 6: run and watch it pass.** `cargo test` (all), then
  `cargo clippy --all-targets`.

- [ ] **Step 7: commit.**

  ```bash
  git add relay-server/Cargo.toml relay-server/Cargo.lock relay-server/src
  git commit -m "refactor(relay): VoiceSessionStore over a backend trait with a race-free reply wait

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 8: `RtcSessionStore` over an `RtcBackend` trait

**Files:** modify `src/rtc_session.rs`, `src/main.rs` (sweep loop).

**Interfaces.**
Consumes: `StoreError`.
Produces (`rtc_session.rs`):
- `pub const MAX_RTC_PARTICIPANTS: usize = 8;` `pub const RTC_FIRST_UID: u32 = 1000;`
  `pub const RTC_SESSION_TTL_HOURS: i64 = 4;`
- `#[derive(Debug)] pub enum JoinOutcome { NotFound, Full, Joined(JoinRtcSessionResponse) }`
- `#[async_trait] pub trait RtcBackend: Send + Sync`:
  `create(RtcSession) -> Result<(), StoreError>`, `get(&str) -> Result<Option<RtcSession>, StoreError>`,
  `join(&str, String, DateTime<Utc>) -> Result<JoinOutcome, StoreError>`,
  `delete(&str) -> Result<bool, StoreError>`, `cleanup_expired(DateTime<Utc>) -> Result<(), StoreError>`
- `#[derive(Clone, Default)] pub struct InMemoryRtcBackend`
- `RtcSessionStore`: `new()`, `with_backend(Arc<dyn RtcBackend>)`,
  `create(String, String, String, String, u32) -> Result<RtcSession, StoreError>`,
  `get(&str) -> Result<Option<RtcSession>, StoreError>`,
  `join(&str, String) -> Result<JoinRtcSessionResponse, String>` (unchanged signature),
  `delete(&str) -> Result<bool, StoreError>`, `cleanup_expired() -> Result<(), StoreError>`
- `RtcSession` keeps its fields; `uid_counter_value` is the next uid.
  `RtcSessionInner` is removed.

- [ ] **Step 1: make the existing tests use the fallible API.** Run this
  before writing the new tests (it must not see them).

  ```bash
  cat > /tmp/rtc-unwrap.pl <<'EOF'
  my ($head, $tests) = split(/(?=#\[cfg\(test\)\]\n(?:pub\(crate\) )?mod tests)/, $_, 2);
  $tests =~ s/(\b(?:store|store1|store2|state\.rtc_sessions)\s*\.\s*(?:create|get|delete|cleanup_expired)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s*\.await)/$1.unwrap()/g;
  $_ = $head . $tests;
  EOF
  perl -0pi /tmp/rtc-unwrap.pl src/rtc_session.rs
  ```

- [ ] **Step 2: write the new tests.** In `src/rtc_session.rs`'s test module
  replace `test_cleanup_expired` with:

  ```rust
  #[tokio::test]
  async fn test_cleanup_expired() {
      let backend = InMemoryRtcBackend::default();
      let store = RtcSessionStore::with_backend(Arc::new(backend.clone()));
      backend
          .create(RtcSession {
              id: "expired".into(),
              app_id: "a".into(),
              channel: "c".into(),
              token: "t".into(),
              uid_counter_value: RTC_FIRST_UID,
              host_uid: 1,
              created_at: Utc::now() - Duration::hours(5),
              expires_at: Utc::now() - Duration::hours(1),
              participants: Vec::new(),
          })
          .await
          .unwrap();
      store
          .create("active".into(), "a".into(), "c".into(), "t".into(), 1)
          .await
          .unwrap();

      store.cleanup_expired().await.unwrap();

      assert!(store.get("expired").await.unwrap().is_none());
      assert!(store.get("active").await.unwrap().is_some());
  }

  #[tokio::test]
  async fn join_handler_maps_an_unavailable_store_to_503() {
      assert_eq!(join_error_status("RTC session store unavailable: x"), StatusCode::SERVICE_UNAVAILABLE);
      assert_eq!(join_error_status("Session not found"), StatusCode::NOT_FOUND);
      assert_eq!(join_error_status("Session is full (maximum 8 participants)"), StatusCode::CONFLICT);
      assert_eq!(join_error_status("anything else"), StatusCode::INTERNAL_SERVER_ERROR);
  }
  ```

- [ ] **Step 3: run and watch it fail.** `cargo test rtc_session`.

- [ ] **Step 4: implement.** In `src/rtc_session.rs`:
  - replace the imports
    `use std::collections::HashMap; use std::sync::OnceLock; use std::sync::atomic::{AtomicU32, Ordering}; use std::sync::Arc; use tokio::sync::RwLock;`
    with:

    ```rust
    use std::collections::HashMap;
    use std::sync::{Arc, OnceLock};

    use async_trait::async_trait;

    use crate::cluster::StoreError;
    ```

  - delete `RtcSessionInner` and `impl RtcSessionInner { fn snapshot … }`;
  - keep `RtcSession` and its `#[derive(Clone, Debug)]` as they are;
  - replace the `// --- Store ---` section (from `#[derive(Clone)] pub struct RtcSessionStore`
    to the end of `impl Default for RtcSessionStore`) with:

    ```rust
    // --- Store ---

    pub const MAX_RTC_PARTICIPANTS: usize = 8;
    pub const RTC_FIRST_UID: u32 = 1000;
    pub const RTC_SESSION_TTL_HOURS: i64 = 4;

    #[derive(Debug)]
    pub enum JoinOutcome {
        NotFound,
        Full,
        Joined(JoinRtcSessionResponse),
    }

    #[async_trait]
    pub trait RtcBackend: Send + Sync {
        async fn create(&self, session: RtcSession) -> Result<(), StoreError>;
        async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError>;
        /// Take the next uid and add a participant, atomically, unless the
        /// session already has MAX_RTC_PARTICIPANTS.
        async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError>;
        async fn delete(&self, id: &str) -> Result<bool, StoreError>;
        async fn cleanup_expired(&self, now: DateTime<Utc>) -> Result<(), StoreError>;
    }

    #[derive(Clone, Default)]
    pub struct InMemoryRtcBackend {
        sessions: Arc<std::sync::Mutex<HashMap<String, RtcSession>>>,
    }

    impl InMemoryRtcBackend {
        fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, RtcSession>> {
            self.sessions.lock().unwrap_or_else(|e| e.into_inner())
        }
    }

    #[async_trait]
    impl RtcBackend for InMemoryRtcBackend {
        async fn create(&self, session: RtcSession) -> Result<(), StoreError> {
            self.lock().insert(session.id.clone(), session);
            Ok(())
        }

        async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
            Ok(self.lock().get(id).cloned())
        }

        async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError> {
            let mut sessions = self.lock();
            let Some(session) = sessions.get_mut(id) else {
                return Ok(JoinOutcome::NotFound);
            };
            let current_count = session.participants.len();
            tracing::info!(
                "Join request for session {}: current participants = {}, name = {}",
                id,
                current_count,
                name
            );
            // Enforce 8-person limit (including host)
            if current_count >= MAX_RTC_PARTICIPANTS {
                tracing::warn!("Session {} is full ({} participants)", id, current_count);
                return Ok(JoinOutcome::Full);
            }
            let uid = session.uid_counter_value;
            session.uid_counter_value += 1;
            session.participants.push(Participant {
                uid,
                display_name: Some(name.clone()),
                joined_at: now,
            });
            tracing::info!(
                "User {} joined session {} with UID {} (total participants: {})",
                name,
                id,
                uid,
                session.participants.len()
            );
            Ok(JoinOutcome::Joined(JoinRtcSessionResponse {
                app_id: session.app_id.clone(),
                channel: session.channel.clone(),
                token: session.token.clone(),
                uid,
                name,
            }))
        }

        async fn delete(&self, id: &str) -> Result<bool, StoreError> {
            Ok(self.lock().remove(id).is_some())
        }

        async fn cleanup_expired(&self, now: DateTime<Utc>) -> Result<(), StoreError> {
            self.lock().retain(|_, session| now <= session.expires_at);
            Ok(())
        }
    }

    #[derive(Clone)]
    pub struct RtcSessionStore {
        backend: Arc<dyn RtcBackend>,
    }

    impl RtcSessionStore {
        pub fn new() -> Self {
            Self::with_backend(Arc::new(InMemoryRtcBackend::default()))
        }

        pub fn with_backend(backend: Arc<dyn RtcBackend>) -> Self {
            Self { backend }
        }

        pub async fn create(
            &self,
            id: String,
            app_id: String,
            channel: String,
            token: String,
            host_uid: u32,
        ) -> Result<RtcSession, StoreError> {
            let now = Utc::now();
            let session = RtcSession {
                id,
                app_id,
                channel,
                token,
                uid_counter_value: RTC_FIRST_UID,
                host_uid,
                created_at: now,
                expires_at: now + Duration::hours(RTC_SESSION_TTL_HOURS),
                participants: Vec::new(),
            };
            self.backend.create(session.clone()).await?;
            Ok(session)
        }

        pub async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
            self.backend.get(id).await
        }

        /// Join a session; the error text drives the HTTP status (see
        /// `join_error_status`).
        pub async fn join(&self, id: &str, name: String) -> Result<JoinRtcSessionResponse, String> {
            match self.backend.join(id, name, Utc::now()).await {
                Ok(JoinOutcome::Joined(response)) => Ok(response),
                Ok(JoinOutcome::NotFound) => Err("Session not found".to_string()),
                Ok(JoinOutcome::Full) => Err("Session is full (maximum 8 participants)".to_string()),
                Err(error) => {
                    tracing::error!("RTC session store unavailable: {}", error);
                    Err(format!("RTC session store unavailable: {error}"))
                }
            }
        }

        pub async fn delete(&self, id: &str) -> Result<bool, StoreError> {
            self.backend.delete(id).await
        }

        pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
            self.backend.cleanup_expired(Utc::now()).await
        }
    }

    impl Default for RtcSessionStore {
        fn default() -> Self {
            Self::new()
        }
    }

    /// HTTP status for a `join` error message.
    fn join_error_status(error: &str) -> StatusCode {
        if error.contains("unavailable") {
            StatusCode::SERVICE_UNAVAILABLE
        } else if error.contains("not found") {
            StatusCode::NOT_FOUND
        } else if error.contains("full") {
            StatusCode::CONFLICT
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }

    fn rtc_unavailable(error: StoreError) -> (StatusCode, Json<RtcSessionError>) {
        tracing::error!("RTC session store unavailable: {}", error);
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(RtcSessionError { error: "Temporarily unavailable".to_string() }),
        )
    }
    ```

  - in `create_rtc_session_handler`, replace the
    `state.rtc_sessions.create(…).await;` statement with:

    ```rust
    if let Err(error) = state
        .rtc_sessions
        .create(id.clone(), body.app_id, body.channel, body.token, body.host_uid)
        .await
    {
        return rtc_unavailable(error).into_response();
    }
    ```

  - in `get_rtc_session_handler`, change `match state.rtc_sessions.get(&id).await {`
    to `match state.rtc_sessions.get(&id).await.map_err(rtc_unavailable)? {`
    and give the function the explicit return type
    `-> Result<Json<GetRtcSessionResponse>, (StatusCode, Json<RtcSessionError>)>`
    (replacing `-> impl IntoResponse`);
  - in `join_rtc_session_handler`, replace the `let status = if … else { … };`
    block with `let status = join_error_status(&error);`;
  - replace the body of `delete_rtc_session_handler` with:

    ```rust
    match state.rtc_sessions.delete(&id).await {
        Ok(true) => StatusCode::OK,
        Ok(false) => StatusCode::NOT_FOUND,
        Err(error) => rtc_unavailable(error).0,
    }
    ```

  In `src/main.rs` replace `cleanup_rtc.cleanup_expired().await;` with:

  ```rust
  if let Err(error) = cleanup_rtc.cleanup_expired().await {
      tracing::debug!("RTC session sweep failed: {}", error);
  }
  ```

- [ ] **Step 5: run and watch it pass.** `cargo test` (all).
  `test_concurrent_joins` (8 of 10 succeed, uids 1000..=1007) and
  `test_max_participants_enforced` must pass unchanged.

- [ ] **Step 6: commit.**

  ```bash
  git add relay-server/src
  git commit -m "refactor(relay): RtcSessionStore over a backend trait with atomic join

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 9: shared rate limiter (no-op in memory)

**Files:** create `src/cluster/ratelimit.rs`; modify `src/cluster/mod.rs`,
`src/relay.rs` (hub field), `src/main.rs` (router).

**Interfaces.**
Consumes: `RelayHub`, `StoreError`, `tower_governor::key_extractor::SmartIpKeyExtractor`.
Produces:
- `pub const GRANT_LIMIT_PER_MINUTE: u64 = 60;` `pub const GENERAL_LIMIT_PER_MINUTE: u64 = 600;`
- `pub enum RateDecision { Allowed, Limited { retry_after_secs: u64 } }`
- `#[async_trait] pub trait SharedRateLimiter: Send + Sync { fn backend_name(&self) -> &'static str; async fn hit(&self, bucket: &str, ip: &str, limit: u64, now: i64) -> Result<RateDecision, StoreError>; }`
- `pub struct NoopRateLimiter;`
- `pub fn window_decision(count: u64, limit: u64, now: i64) -> RateDecision`
- `#[derive(Clone)] pub struct SharedLimit { pub hub: RelayHub, pub bucket: &'static str, pub limit: u64 }`
- `pub async fn shared_rate_limit(State<SharedLimit>, Request, Next) -> Response`
- `HubParts.rate_limiter: Arc<dyn SharedRateLimiter>`; `RelayHub::rate_limiter(&self) -> Arc<dyn SharedRateLimiter>`;
  `#[cfg(test)] RelayHub::with_rate_limiter(Arc<dyn SharedRateLimiter>) -> Self`

- [ ] **Step 1: write the tests** (new `src/cluster/ratelimit.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use axum::body::{to_bytes, Body};
      use axum::routing::get;
      use axum::Router;
      use std::sync::Arc;
      use tower::ServiceExt;

      #[test]
      fn fixed_window_decision() {
          let now = 1_699_999_990; // 10 s into its minute
          assert_eq!(window_decision(60, 60, now), RateDecision::Allowed);
          assert_eq!(
              window_decision(61, 60, now),
              RateDecision::Limited { retry_after_secs: 50 }
          );
      }

      struct AlwaysLimited;

      #[async_trait]
      impl SharedRateLimiter for AlwaysLimited {
          fn backend_name(&self) -> &'static str {
              "limited"
          }
          async fn hit(&self, _: &str, _: &str, _: u64, _: i64) -> Result<RateDecision, StoreError> {
              Ok(RateDecision::Limited { retry_after_secs: 7 })
          }
      }

      struct Broken;

      #[async_trait]
      impl SharedRateLimiter for Broken {
          fn backend_name(&self) -> &'static str {
              "broken"
          }
          async fn hit(&self, _: &str, _: &str, _: u64, _: i64) -> Result<RateDecision, StoreError> {
              Err(StoreError::Unavailable("down".into()))
          }
      }

      fn app(limiter: Arc<dyn SharedRateLimiter>) -> Router {
          let limit = SharedLimit {
              hub: RelayHub::with_rate_limiter(limiter),
              bucket: "general",
              limit: GENERAL_LIMIT_PER_MINUTE,
          };
          Router::new()
              .route("/limited", get(|| async { "ok" }))
              .layer(axum::middleware::from_fn_with_state(limit, shared_rate_limit))
      }

      async fn call(app: Router) -> axum::response::Response {
          app.oneshot(
              axum::http::Request::builder()
                  .uri("/limited")
                  .header("x-forwarded-for", "203.0.113.20")
                  .body(Body::empty())
                  .unwrap(),
          )
          .await
          .unwrap()
      }

      #[tokio::test]
      async fn limited_requests_get_governor_shaped_429() {
          let response = call(app(Arc::new(AlwaysLimited))).await;
          assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
          assert_eq!(response.headers()["retry-after"], "7");
          let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
          assert_eq!(body.as_ref(), b"Too Many Requests! Wait for 7s");
      }

      #[tokio::test]
      async fn memory_limiter_and_a_broken_backend_let_requests_through() {
          assert_eq!(call(app(Arc::new(NoopRateLimiter))).await.status(), StatusCode::OK);
          assert_eq!(call(app(Arc::new(Broken))).await.status(), StatusCode::OK);
      }
  }
  ```

  Add `pub mod ratelimit;` to `src/cluster/mod.rs` (after `pub mod local;`).

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::ratelimit`.

- [ ] **Step 3: implement** above the tests in `src/cluster/ratelimit.rs`:

  ```rust
  //! Per-IP limits shared by all replicas (spec: "Rate limits").
  //! tower_governor keeps enforcing its per-replica token bucket on every
  //! route, unchanged. This layer adds the same limits as fixed one-minute
  //! windows shared through Redis, so N replicas don't allow N× the
  //! requests. In-memory mode needs no shared limit (one replica: the
  //! governor is the whole limit), so its limiter always allows. On a Redis
  //! error the request is allowed and the governor still applies (fail open).

  use async_trait::async_trait;
  use axum::extract::{Request, State};
  use axum::http::{HeaderValue, StatusCode};
  use axum::middleware::Next;
  use axum::response::{IntoResponse, Response};
  use tower_governor::key_extractor::{KeyExtractor, SmartIpKeyExtractor};

  use super::StoreError;
  use crate::relay::RelayHub;

  pub const GRANT_LIMIT_PER_MINUTE: u64 = 60;
  pub const GENERAL_LIMIT_PER_MINUTE: u64 = 600;

  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum RateDecision {
      Allowed,
      Limited { retry_after_secs: u64 },
  }

  #[async_trait]
  pub trait SharedRateLimiter: Send + Sync {
      fn backend_name(&self) -> &'static str;
      /// Count one request from `ip` in `bucket` for the minute containing
      /// `now` (unix seconds).
      async fn hit(&self, bucket: &str, ip: &str, limit: u64, now: i64) -> Result<RateDecision, StoreError>;
  }

  /// Single instance: the per-replica governor is the whole limit.
  pub struct NoopRateLimiter;

  #[async_trait]
  impl SharedRateLimiter for NoopRateLimiter {
      fn backend_name(&self) -> &'static str {
          "memory"
      }

      async fn hit(&self, _bucket: &str, _ip: &str, _limit: u64, _now: i64) -> Result<RateDecision, StoreError> {
          Ok(RateDecision::Allowed)
      }
  }

  /// The decision for the `count`-th request of a one-minute window.
  pub fn window_decision(count: u64, limit: u64, now: i64) -> RateDecision {
      if count <= limit {
          RateDecision::Allowed
      } else {
          RateDecision::Limited {
              retry_after_secs: (60 - now.rem_euclid(60)) as u64,
          }
      }
  }

  #[derive(Clone)]
  pub struct SharedLimit {
      pub hub: RelayHub,
      pub bucket: &'static str,
      pub limit: u64,
  }

  pub async fn shared_rate_limit(State(limit): State<SharedLimit>, request: Request, next: Next) -> Response {
      let ip = SmartIpKeyExtractor
          .extract(&request)
          .map(|ip| ip.to_string())
          .unwrap_or_else(|_| "unknown".to_string());
      let now = chrono::Utc::now().timestamp();
      match limit.hub.rate_limiter().hit(limit.bucket, &ip, limit.limit, now).await {
          Ok(RateDecision::Allowed) => next.run(request).await,
          Ok(RateDecision::Limited { retry_after_secs }) => too_many_requests(retry_after_secs),
          Err(error) => {
              tracing::debug!("Shared rate limit unavailable, per-replica limit applies: {}", error);
              next.run(request).await
          }
      }
  }

  /// Same status and body as tower_governor's rejection.
  fn too_many_requests(wait: u64) -> Response {
      let mut response = (
          StatusCode::TOO_MANY_REQUESTS,
          format!("Too Many Requests! Wait for {}s", wait),
      )
          .into_response();
      response
          .headers_mut()
          .insert("retry-after", HeaderValue::from(wait));
      response
  }
  ```

  In `src/relay.rs`:
  - add `use crate::cluster::ratelimit::{NoopRateLimiter, SharedRateLimiter};`;
  - add `pub rate_limiter: Arc<dyn SharedRateLimiter>,` to `HubParts` and
    `rate_limiter: Arc<dyn SharedRateLimiter>,` to `HubInner`;
  - in `from_parts` add `rate_limiter: parts.rate_limiter,`;
  - in `in_memory` add `rate_limiter: Arc::new(NoopRateLimiter),`;
  - in the test `deliveries_stay_local_or_go_to_the_owning_replica` add
    `rate_limiter: std::sync::Arc::new(crate::cluster::ratelimit::NoopRateLimiter),`
    to its `HubParts`;
  - add to `impl RelayHub`:

    ```rust
    pub(crate) fn rate_limiter(&self) -> Arc<dyn SharedRateLimiter> {
        self.inner.rate_limiter.clone()
    }

    #[cfg(test)]
    pub(crate) fn with_rate_limiter(rate_limiter: Arc<dyn SharedRateLimiter>) -> Self {
        let local = LocalSockets::new();
        Self::from_parts(HubParts {
            replica_id: SINGLE_REPLICA_ID.to_string(),
            directory: Arc::new(InMemoryRoomDirectory::new()),
            bus: Arc::new(LoopbackBus::new(SINGLE_REPLICA_ID, local.clone())),
            local,
            keys: KeyCache::new(),
            rate_limiter,
            auth_timeout: Duration::from_secs(RELAY_AUTH_TIMEOUT_SECS),
        })
    }
    ```

  In `src/main.rs` `router`: add
  `use cluster::ratelimit::{shared_rate_limit, SharedLimit, GENERAL_LIMIT_PER_MINUTE, GRANT_LIMIT_PER_MINUTE};`
  at the top, then change the two governor layers to:

  ```rust
  let auth_routes = Router::new()
      .route(
          "/api/sessions/:id/grant",
          post(routes::grant_session_handler),
      )
      .layer(GovernorLayer {
          config: governor_conf_strict,
      })
      .layer(axum::middleware::from_fn_with_state(
          SharedLimit {
              hub: state.relay.clone(),
              bucket: "grant",
              limit: GRANT_LIMIT_PER_MINUTE,
          },
          shared_rate_limit,
      ));
  ```

  and, after `.layer(GovernorLayer { config: governor_conf_general, })` in
  `general_routes`:

  ```rust
  .layer(axum::middleware::from_fn_with_state(
      SharedLimit {
          hub: state.relay.clone(),
          bucket: "general",
          limit: GENERAL_LIMIT_PER_MINUTE,
      },
      shared_rate_limit,
  ))
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test` (all; the existing
  `rate_limit_uses_forwarded_client_ip` must still pass).

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): shared rate-limit layer (no-op until Redis)

  🤖 Built with SMT <smt@agora.build>"
  ```

Step 1 is complete: run `cargo test` and `cargo clippy --all-targets` once
more; everything is green and the relay behaves as before.

---

## Step 2 — Redis versions, Lua scripts, `ReplicaBus`

### Task 10: `redis` dependency, `RedisConn`, key names, test harness

**Files:** modify `Cargo.toml`, `src/cluster/mod.rs`; create
`src/cluster/redis/mod.rs`, `src/cluster/redis/keys.rs`.

**Interfaces.**
Produces:
- `pub const REDIS_TIMEOUT: Duration` (3 s)
- `#[derive(Clone)] pub struct RedisConn` with
  `async connect(url: &str) -> Result<RedisConn, StoreError>`,
  `client(&self) -> &redis::Client`,
  `async run<T, F, Fut>(&self, op: F) -> Result<T, StoreError> where F: FnOnce(ConnectionManager) -> Fut, Fut: Future<Output = RedisResult<T>>`
  (bounded by `REDIS_TIMEOUT`), `async ping(&self) -> Result<(), StoreError>`
- `pub(crate) fn redis_error(redis::RedisError) -> StoreError`
- `keys`: `part(&str) -> Cow<str>`, `unpart(&str) -> String`, `replica(&str)`,
  `REPLICA_PREFIX`, `REPLICA_PATTERN`, `room`, `room_atems`, `room_pending`,
  `session`, `voice`, `voice_reply`, `VOICE_PREFIX`, `VOICE_PATTERN`, `rtc`,
  `rate(bucket, ip, minute: i64)`, `inbox_channel`, `BROADCAST_CHANNEL`,
  `voice_reply_channel`, `VOICE_REPLY_CHANNEL_PREFIX`, `VOICE_REPLY_PATTERN`
- `#[cfg(test)] pub(crate) mod test_support { REDIS_LOCK, is_local_redis_url, test_url, flush, fresh_conn }`

- [ ] **Step 1: add the dependency.** In `relay-server/Cargo.toml`
  `[dependencies]`, after `ring = "0.17"`:

  ```toml
  # Shared relay state across replicas (REDIS_URL): commands with automatic
  # reconnect, pub/sub, Lua scripts. Valkey-compatible.
  redis = { version = "0.27", default-features = false, features = ["aio", "tokio-comp", "connection-manager", "script", "keep-alive"] }
  ```

  Run `cargo build` to update `Cargo.lock`.

- [ ] **Step 2: write the tests.** Create `src/cluster/redis/keys.rs` with:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn names_match_the_spec_tables() {
          assert_eq!(replica("a1b2c3d4e5f6"), "relay:replica:a1b2c3d4e5f6");
          assert_eq!(room("ABCD-EFGH"), "relay:room:ABCD-EFGH");
          assert_eq!(room_atems("ABCD-EFGH"), "relay:room:ABCD-EFGH:atems");
          assert_eq!(room_pending("ABCD-EFGH"), "relay:room:ABCD-EFGH:pending");
          assert_eq!(session("s-1"), "relay:session:s-1");
          assert_eq!(voice("v-1"), "relay:voice:v-1");
          assert_eq!(voice_reply("v-1"), "relay:voice:v-1:reply");
          assert_eq!(rtc("r-1"), "relay:rtc:r-1");
          assert_eq!(rate("grant", "203.0.113.9", 28_333_333), "relay:rl:grant:203.0.113.9:28333333");
          assert_eq!(inbox_channel("a1b2"), "relay:inbox:a1b2");
          assert_eq!(BROADCAST_CHANNEL, "relay:broadcast");
          assert_eq!(voice_reply_channel("v-1"), "relay:voice-reply:v-1");
          assert_eq!(VOICE_REPLY_PATTERN, "relay:voice-reply:*");
          assert_eq!(REPLICA_PATTERN, "relay:replica:*");
      }

      #[test]
      fn client_supplied_parts_cannot_reach_other_keys() {
          assert_eq!(room("X:atems"), "relay:room:X%3Aatems");
          assert_eq!(voice("x:reply"), "relay:voice:x%3Areply");
          assert_eq!(rate("general", "::1", 1), "relay:rl:general:%3A%3A1:1");
          for raw in ["plain", "a:b", "100%", "%3A", "a%25:b", "日本:語"] {
              assert_eq!(unpart(&part(raw)), raw);
          }
      }
  }
  ```

  Create `src/cluster/redis/mod.rs` with:

  ```rust
  #[cfg(test)]
  pub(crate) mod test_support {
      //! Redis suites are #[ignore]d and need TEST_REDIS_URL (localhost only:
      //! the harness empties the database). See the plan's global constraints.
      use super::RedisConn;

      /// Redis tests share one database, so they run one at a time.
      pub(crate) static REDIS_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

      /// True only for a `redis://` URL whose host is this machine.
      pub(crate) fn is_local_redis_url(url: &str) -> bool {
          let rest = match url.split_once("://") {
              Some(("redis", rest)) => rest,
              _ => return false,
          };
          let authority = rest.split(['/', '?']).next().unwrap_or("");
          let hostport = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
          let host = if let Some(stripped) = hostport.strip_prefix('[') {
              stripped.split(']').next().unwrap_or("")
          } else {
              hostport.split(':').next().unwrap_or("")
          };
          matches!(host, "localhost" | "127.0.0.1" | "::1")
      }

      pub(crate) fn test_url() -> String {
          let url = std::env::var("TEST_REDIS_URL")
              .expect("set TEST_REDIS_URL to run the Redis tests");
          assert!(
              is_local_redis_url(&url),
              "TEST_REDIS_URL must point at localhost; the tests empty the database"
          );
          url
      }

      /// Empty the test database.
      pub(crate) async fn flush() {
          let conn = RedisConn::connect(&test_url()).await.expect("connect TEST_REDIS_URL");
          conn.run(|mut c| async move { redis::cmd("FLUSHDB").query_async::<()>(&mut c).await })
              .await
              .expect("FLUSHDB");
      }

      /// An empty database and a connection to it.
      pub(crate) async fn fresh_conn() -> RedisConn {
          flush().await;
          RedisConn::connect(&test_url()).await.expect("connect TEST_REDIS_URL")
      }
  }

  #[cfg(test)]
  mod tests {
      use super::test_support::*;
      use super::*;

      #[test]
      fn redis_url_guard_accepts_only_localhost() {
          assert!(is_local_redis_url("redis://127.0.0.1:56379/"));
          assert!(is_local_redis_url("redis://localhost:6379/0"));
          assert!(is_local_redis_url("redis://:pw@[::1]:6379"));
          assert!(!is_local_redis_url("redis://valkey.internal:6379"));
          assert!(!is_local_redis_url("redis://localhost.evil.com:6379"));
          assert!(!is_local_redis_url("redis://localhost@prod.example.com:6379"));
          assert!(!is_local_redis_url("rediss://127.0.0.1:6379"));
      }

      #[tokio::test]
      async fn unreachable_redis_is_a_store_error() {
          let error = RedisConn::connect("redis://127.0.0.1:1/").await.err().expect("no server on port 1");
          assert!(matches!(error, StoreError::Unavailable(_)));
      }

      #[tokio::test]
      #[ignore]
      async fn redis_conn_round_trip() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          conn.ping().await.unwrap();
          conn.run(|mut c| async move {
              redis::cmd("SET").arg("relay:test").arg("v").query_async::<()>(&mut c).await
          })
          .await
          .unwrap();
          let value: Option<String> = conn
              .run(|mut c| async move { redis::cmd("GET").arg("relay:test").query_async(&mut c).await })
              .await
              .unwrap();
          assert_eq!(value.as_deref(), Some("v"));
      }
  }
  ```

  In `src/cluster/mod.rs` add `pub mod redis;` after `pub mod ratelimit;`.
  Inside `src/cluster/redis/mod.rs` the external crate is `::redis` where a
  local name could clash; the code below uses plain `redis::…`, which
  resolves to the crate because this module does not declare an item named
  `redis`.

- [ ] **Step 3: run and watch it fail.** `cargo test cluster::redis`.

- [ ] **Step 4: implement.** Above the tests in `src/cluster/redis/keys.rs`:

  ```rust
  //! Redis key and channel names (spec: "Redis keys"). Everything is under
  //! `relay:`. Client-supplied parts are escaped (`%` → `%25`, `:` → `%3A`)
  //! so an id can't name another key (a room code `X:atems` would otherwise
  //! be room X's Atem hash). Real ids contain neither character.

  use std::borrow::Cow;

  pub fn part(raw: &str) -> Cow<'_, str> {
      if raw.contains(['%', ':']) {
          Cow::Owned(raw.replace('%', "%25").replace(':', "%3A"))
      } else {
          Cow::Borrowed(raw)
      }
  }

  pub fn unpart(escaped: &str) -> String {
      escaped.replace("%3A", ":").replace("%25", "%")
  }

  pub const REPLICA_PREFIX: &str = "relay:replica:";
  pub const REPLICA_PATTERN: &str = "relay:replica:*";
  pub const VOICE_PREFIX: &str = "relay:voice:";
  pub const VOICE_PATTERN: &str = "relay:voice:*";
  pub const BROADCAST_CHANNEL: &str = "relay:broadcast";
  pub const VOICE_REPLY_CHANNEL_PREFIX: &str = "relay:voice-reply:";
  pub const VOICE_REPLY_PATTERN: &str = "relay:voice-reply:*";

  pub fn replica(replica_id: &str) -> String {
      format!("{REPLICA_PREFIX}{}", part(replica_id))
  }

  pub fn room(code: &str) -> String {
      format!("relay:room:{}", part(code))
  }

  pub fn room_atems(code: &str) -> String {
      format!("relay:room:{}:atems", part(code))
  }

  pub fn room_pending(code: &str) -> String {
      format!("relay:room:{}:pending", part(code))
  }

  pub fn session(id: &str) -> String {
      format!("relay:session:{}", part(id))
  }

  pub fn voice(id: &str) -> String {
      format!("{VOICE_PREFIX}{}", part(id))
  }

  pub fn voice_reply(id: &str) -> String {
      format!("{VOICE_PREFIX}{}:reply", part(id))
  }

  pub fn rtc(id: &str) -> String {
      format!("relay:rtc:{}", part(id))
  }

  /// Fixed one-minute window counter; `minute` is unix seconds / 60.
  pub fn rate(bucket: &str, ip: &str, minute: i64) -> String {
      format!("relay:rl:{}:{}:{}", part(bucket), part(ip), minute)
  }

  pub fn inbox_channel(replica_id: &str) -> String {
      format!("relay:inbox:{}", part(replica_id))
  }

  pub fn voice_reply_channel(id: &str) -> String {
      format!("{VOICE_REPLY_CHANNEL_PREFIX}{}", part(id))
  }
  ```

  Above `test_support` in `src/cluster/redis/mod.rs`:

  ```rust
  //! Redis (Valkey) versions of the shared relay units, selected by
  //! REDIS_URL. Redis holds only live state; losing it makes clients
  //! reconnect but loses nothing durable.

  pub mod keys;

  use std::future::Future;
  use std::time::Duration;

  use redis::aio::{ConnectionManager, ConnectionManagerConfig};

  use super::StoreError;

  /// Bound on every Redis call, so a slow Redis can't stall a connect.
  pub const REDIS_TIMEOUT: Duration = Duration::from_secs(3);

  pub(crate) fn redis_error(error: redis::RedisError) -> StoreError {
      StoreError::Unavailable(error.to_string())
  }

  /// A reconnecting command connection plus the client (for pub/sub).
  #[derive(Clone)]
  pub struct RedisConn {
      client: redis::Client,
      manager: ConnectionManager,
  }

  impl RedisConn {
      pub async fn connect(url: &str) -> Result<Self, StoreError> {
          let client = redis::Client::open(url).map_err(redis_error)?;
          let config = ConnectionManagerConfig::new()
              .set_connection_timeout(REDIS_TIMEOUT)
              .set_response_timeout(REDIS_TIMEOUT)
              .set_number_of_retries(2);
          let manager = tokio::time::timeout(
              REDIS_TIMEOUT * 2,
              client.get_connection_manager_with_config(config),
          )
          .await
          .map_err(|_| StoreError::Unavailable("redis connect timed out".to_string()))?
          .map_err(redis_error)?;
          Ok(Self { client, manager })
      }

      pub fn client(&self) -> &redis::Client {
          &self.client
      }

      /// Run one operation (a command, pipeline or script) within REDIS_TIMEOUT.
      pub async fn run<T, F, Fut>(&self, op: F) -> Result<T, StoreError>
      where
          F: FnOnce(ConnectionManager) -> Fut,
          Fut: Future<Output = redis::RedisResult<T>>,
      {
          match tokio::time::timeout(REDIS_TIMEOUT, op(self.manager.clone())).await {
              Ok(Ok(value)) => Ok(value),
              Ok(Err(error)) => Err(redis_error(error)),
              Err(_) => Err(StoreError::Unavailable("redis call timed out".to_string())),
          }
      }

      pub async fn ping(&self) -> Result<(), StoreError> {
          self.run(|mut c| async move {
              redis::cmd("PING").query_async::<String>(&mut c).await.map(|_| ())
          })
          .await
      }
  }
  ```

- [ ] **Step 5: run and watch it pass.**

  ```bash
  cargo test cluster::redis
  docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
  TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
  docker rm -f relay-test-valkey
  ```

- [ ] **Step 6: commit.**

  ```bash
  git add relay-server/Cargo.toml relay-server/Cargo.lock relay-server/src/cluster
  git commit -m "feat(relay): Redis connection, key names and Valkey test harness

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 11: replica presence, liveness, `/health` fields

**Files:** create `src/cluster/health.rs`, `src/cluster/redis/presence.rs`;
modify `src/cluster/mod.rs`, `src/cluster/redis/mod.rs`, `src/relay.rs`,
`src/main.rs`.

**Interfaces.**
Consumes: `RedisConn`, `keys`.
Produces:
- `#[async_trait] pub trait ClusterHealth: Send + Sync { async fn redis_status(&self) -> &'static str; fn replicas(&self) -> usize; fn is_live(&self, replica_id: &str) -> bool; async fn withdraw(&self) -> Result<(), StoreError>; }`
  (`redis_status` is `"disabled"`, `"ok"` or `"unavailable"`)
- `pub struct SingleInstance;` (`"disabled"`, 1, always live)
- `pub const PRESENCE_TTL_SECS: u64 = 30;` `pub const PRESENCE_REFRESH_SECS: u64 = 10;`
- `#[derive(Clone)] pub struct RedisHealth` with `new(RedisConn, &str) -> Self`,
  `async refresh(&self) -> Result<usize, StoreError>`, `spawn_refresh(&self) -> JoinHandle<()>`
- `HubParts.health: Arc<dyn ClusterHealth>`;
  `pub(crate) fn HubParts::single_instance(InMemoryRoomDirectory, Duration) -> HubParts`;
  `RelayHub::redis_status(&self) -> &'static str` (async), `RelayHub::replica_count(&self) -> usize`,
  `#[cfg(test)] RelayHub::with_health(Arc<dyn ClusterHealth>) -> Self`
- `RelayHub::room` drops entries on replicas without a live presence key.
- `/health` 200 body gains `"redis"` and `"replicas"`; 503 `{"status":"unhealthy","redis":"unavailable"}` when Redis is down.

- [ ] **Step 1: write the tests.**

  New `src/cluster/health.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[tokio::test]
      async fn single_instance_reports_itself() {
          let health = SingleInstance;
          assert_eq!(health.redis_status().await, "disabled");
          assert_eq!(health.replicas(), 1);
          assert!(health.is_live("anything"));
          health.withdraw().await.unwrap();
      }
  }
  ```

  New `src/cluster/redis/presence.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

      #[tokio::test]
      #[ignore]
      async fn redis_presence_counts_live_replicas() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let a = RedisHealth::new(conn.clone(), "replica-a");
          let b = RedisHealth::new(conn.clone(), "replica-b");
          assert_eq!(a.refresh().await.unwrap(), 1);
          assert_eq!(b.refresh().await.unwrap(), 2);
          assert_eq!(a.refresh().await.unwrap(), 2);
          assert!(a.is_live("replica-b"));
          assert!(!a.is_live("replica-gone"));
          assert_eq!(a.redis_status().await, "ok");
          let ttl: i64 = conn
              .run(|mut c| async move { redis::cmd("TTL").arg("relay:replica:replica-a").query_async(&mut c).await })
              .await
              .unwrap();
          assert!((1..=PRESENCE_TTL_SECS as i64).contains(&ttl), "ttl {ttl}");
          b.withdraw().await.unwrap();
          assert_eq!(a.refresh().await.unwrap(), 1);
          assert!(!a.is_live("replica-b"));
      }
  }
  ```

  In `src/relay.rs`'s test module add:

  ```rust
  /// Health with a fixed set of live replicas.
  struct FakeHealth {
      live: Vec<&'static str>,
      redis: &'static str,
  }

  #[async_trait::async_trait]
  impl crate::cluster::health::ClusterHealth for FakeHealth {
      async fn redis_status(&self) -> &'static str {
          self.redis
      }
      fn replicas(&self) -> usize {
          self.live.len()
      }
      fn is_live(&self, replica_id: &str) -> bool {
          self.live.contains(&replica_id)
      }
      async fn withdraw(&self) -> Result<(), ClusterError> {
          Ok(())
      }
  }

  #[tokio::test]
  async fn entries_on_dead_replicas_are_treated_as_gone() {
      let hub = RelayHub::with_health(std::sync::Arc::new(FakeHealth {
          live: vec!["r1"],
          redis: "ok",
      }));
      let code = "astation-dead-owner";
      hub.directory()
          .claim_owner(code, &ConnRef::new("s1", "dead"), now())
          .await
          .unwrap();
      hub.directory().join_atem(code, "atem-live", &ConnRef::new("t1", "r1")).await.unwrap();
      hub.directory().join_atem(code, "atem-dead", &ConnRef::new("t2", "dead")).await.unwrap();
      hub.directory().add_pending(code, &ConnRef::new("p1", "dead"), now(), 0).await.unwrap();
      let room = hub.room(code).await.unwrap().unwrap();
      assert_eq!(room.owner, None);
      assert!(!room.verified);
      assert_eq!(room.atems.keys().collect::<Vec<_>>(), vec!["atem-live"]);
      assert!(room.pending.is_empty());
  }
  ```

  In `src/main.rs` tests, change the expected body in `health_reports_ready_store` to

  ```rust
  br#"{"knowledge_store":"memory","redis":"disabled","replicas":1,"status":"ok","vault_store":"memory"}"#
  ```

  and add:

  ```rust
  #[tokio::test]
  async fn health_fails_when_redis_is_unavailable() {
      struct Down;
      #[async_trait::async_trait]
      impl cluster::health::ClusterHealth for Down {
          async fn redis_status(&self) -> &'static str {
              "unavailable"
          }
          fn replicas(&self) -> usize {
              1
          }
          fn is_live(&self, _: &str) -> bool {
              true
          }
          async fn withdraw(&self) -> Result<(), cluster::StoreError> {
              Ok(())
          }
      }
      let state = AppState {
          relay: RelayHub::with_health(Arc::new(Down)),
          ..test_state()
      };
      let response = Router::new()
          .route("/health", get(health_handler))
          .with_state(state)
          .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
          .await
          .unwrap();
      assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
      let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
      assert_eq!(body.as_ref(), br#"{"redis":"unavailable","status":"unhealthy"}"#);
  }
  ```

  Add `pub mod health;` to `src/cluster/mod.rs` and `pub mod presence;` to
  `src/cluster/redis/mod.rs` (after `pub mod keys;`).

- [ ] **Step 2: run and watch it fail.** `cargo test health` does not compile.

- [ ] **Step 3: implement.** Above the tests in `src/cluster/health.rs`:

  ```rust
  //! What `/health` reports about the cluster, and which replicas are alive.
  //! A directory entry on a replica without a live presence key
  //! (`relay:replica:<id>`) is treated as gone.

  use async_trait::async_trait;

  use super::StoreError;

  #[async_trait]
  pub trait ClusterHealth: Send + Sync {
      /// "disabled" (no Redis), "ok" or "unavailable".
      async fn redis_status(&self) -> &'static str;
      /// Live replicas (including this one).
      fn replicas(&self) -> usize;
      fn is_live(&self, replica_id: &str) -> bool;
      /// Stop advertising this replica (drain).
      async fn withdraw(&self) -> Result<(), StoreError>;
  }

  /// In-memory mode: one replica, no Redis.
  pub struct SingleInstance;

  #[async_trait]
  impl ClusterHealth for SingleInstance {
      async fn redis_status(&self) -> &'static str {
          "disabled"
      }

      fn replicas(&self) -> usize {
          1
      }

      fn is_live(&self, _replica_id: &str) -> bool {
          true
      }

      async fn withdraw(&self) -> Result<(), StoreError> {
          Ok(())
      }
  }
  ```

  Above the tests in `src/cluster/redis/presence.rs`:

  ```rust
  //! Replica presence: `relay:replica:<id>` (value: started-at), expiring
  //! after 30 s and refreshed every 10 s. The refresh also lists the live
  //! replicas, which liveness checks and `/health` read without I/O.

  use std::collections::HashSet;
  use std::sync::{Arc, RwLock};

  use async_trait::async_trait;
  use tokio::task::JoinHandle;

  use super::{keys, RedisConn};
  use crate::cluster::health::ClusterHealth;
  use crate::cluster::StoreError;

  pub const PRESENCE_TTL_SECS: u64 = 30;
  pub const PRESENCE_REFRESH_SECS: u64 = 10;

  #[derive(Clone)]
  pub struct RedisHealth {
      conn: RedisConn,
      replica_id: String,
      started_at: i64,
      live: Arc<RwLock<HashSet<String>>>,
  }

  impl RedisHealth {
      pub fn new(conn: RedisConn, replica_id: &str) -> Self {
          let live = HashSet::from([replica_id.to_string()]);
          Self {
              conn,
              replica_id: replica_id.to_string(),
              started_at: chrono::Utc::now().timestamp(),
              live: Arc::new(RwLock::new(live)),
          }
      }

      /// Renew this replica's presence and re-list the live replicas.
      pub async fn refresh(&self) -> Result<usize, StoreError> {
          let presence = keys::replica(&self.replica_id);
          let started_at = self.started_at;
          let found: HashSet<String> = self
              .conn
              .run(|mut c| async move {
                  redis::cmd("SET")
                      .arg(&presence)
                      .arg(started_at)
                      .arg("EX")
                      .arg(PRESENCE_TTL_SECS)
                      .query_async::<()>(&mut c)
                      .await?;
                  let mut cursor: u64 = 0;
                  let mut ids = HashSet::new();
                  loop {
                      let (next, batch): (u64, Vec<String>) = redis::cmd("SCAN")
                          .arg(cursor)
                          .arg("MATCH")
                          .arg(keys::REPLICA_PATTERN)
                          .arg("COUNT")
                          .arg(1000)
                          .query_async(&mut c)
                          .await?;
                      ids.extend(
                          batch
                              .iter()
                              .filter_map(|key| key.strip_prefix(keys::REPLICA_PREFIX))
                              .map(keys::unpart),
                      );
                      if next == 0 {
                          break;
                      }
                      cursor = next;
                  }
                  Ok(ids)
              })
              .await?;
          let mut live = found;
          live.insert(self.replica_id.clone());
          let count = live.len();
          *self.live.write().unwrap_or_else(|e| e.into_inner()) = live;
          Ok(count)
      }

      pub fn spawn_refresh(&self) -> JoinHandle<()> {
          let health = self.clone();
          tokio::spawn(async move {
              let mut tick = tokio::time::interval(std::time::Duration::from_secs(PRESENCE_REFRESH_SECS));
              loop {
                  tick.tick().await;
                  if let Err(error) = health.refresh().await {
                      tracing::warn!("Could not refresh replica presence: {}", error);
                  }
              }
          })
      }
  }

  #[async_trait]
  impl ClusterHealth for RedisHealth {
      async fn redis_status(&self) -> &'static str {
          if self.conn.ping().await.is_ok() {
              "ok"
          } else {
              "unavailable"
          }
      }

      fn replicas(&self) -> usize {
          self.live.read().unwrap_or_else(|e| e.into_inner()).len()
      }

      fn is_live(&self, replica_id: &str) -> bool {
          self.live
              .read()
              .unwrap_or_else(|e| e.into_inner())
              .contains(replica_id)
      }

      async fn withdraw(&self) -> Result<(), StoreError> {
          let presence = keys::replica(&self.replica_id);
          self.conn
              .run(|mut c| async move { redis::cmd("DEL").arg(&presence).query_async::<()>(&mut c).await })
              .await
      }
  }
  ```

  In `src/relay.rs`:
  - add `use crate::cluster::health::{ClusterHealth, SingleInstance};`;
  - add `pub health: Arc<dyn ClusterHealth>,` to `HubParts` and
    `health: Arc<dyn ClusterHealth>,` to `HubInner`, and
    `health: parts.health,` in `from_parts`;
  - add, after the `HubParts` struct:

    ```rust
    impl HubParts {
        /// Single-instance parts: in-memory directory, loopback bus, no
        /// shared limits, no Redis.
        pub(crate) fn single_instance(directory: InMemoryRoomDirectory, auth_timeout: Duration) -> Self {
            let local = LocalSockets::new();
            Self {
                replica_id: SINGLE_REPLICA_ID.to_string(),
                directory: Arc::new(directory),
                bus: Arc::new(LoopbackBus::new(SINGLE_REPLICA_ID, local.clone())),
                local,
                keys: KeyCache::new(),
                rate_limiter: Arc::new(NoopRateLimiter),
                health: Arc::new(SingleInstance),
                auth_timeout,
            }
        }
    }
    ```

  - replace the bodies of `RelayHub::in_memory` and `RelayHub::with_rate_limiter`, and add `with_health`:

    ```rust
    pub(crate) fn in_memory(directory: InMemoryRoomDirectory, auth_timeout: Duration) -> Self {
        Self::from_parts(HubParts::single_instance(directory, auth_timeout))
    }

    #[cfg(test)]
    pub(crate) fn with_rate_limiter(rate_limiter: Arc<dyn SharedRateLimiter>) -> Self {
        Self::from_parts(HubParts {
            rate_limiter,
            ..HubParts::single_instance(
                InMemoryRoomDirectory::new(),
                Duration::from_secs(RELAY_AUTH_TIMEOUT_SECS),
            )
        })
    }

    #[cfg(test)]
    pub(crate) fn with_health(health: Arc<dyn ClusterHealth>) -> Self {
        Self::from_parts(HubParts {
            health,
            ..HubParts::single_instance(
                InMemoryRoomDirectory::new(),
                Duration::from_secs(RELAY_AUTH_TIMEOUT_SECS),
            )
        })
    }
    ```

  - in the test `deliveries_stay_local_or_go_to_the_owning_replica` replace
    the whole `HubParts { … }` literal with:

    ```rust
    HubParts {
        replica_id: "r1".to_string(),
        bus: bus.clone(),
        local: local.clone(),
        ..HubParts::single_instance(InMemoryRoomDirectory::new(), TEST_AUTH_TIMEOUT)
    }
    ```

  - add to `impl RelayHub`:

    ```rust
    /// "disabled", "ok" or "unavailable" (for /health).
    pub async fn redis_status(&self) -> &'static str {
        self.inner.health.redis_status().await
    }

    pub fn replica_count(&self) -> usize {
        self.inner.health.replicas()
    }

    /// A directory entry on a replica without a live presence key is gone.
    fn without_dead_replicas(&self, mut room: RoomInfo) -> RoomInfo {
        let health = &self.inner.health;
        if room.owner.as_ref().is_some_and(|owner| !health.is_live(&owner.replica)) {
            room.owner = None;
            room.verified = false;
        }
        room.atems.retain(|_, connection| health.is_live(&connection.replica));
        room.pending.retain(|connection| health.is_live(&connection.replica));
        room
    }
    ```

  - change `RelayHub::room` to:

    ```rust
    /// The room, read fresh (HTTP endpoints, connect checks), without
    /// entries left by dead replicas.
    pub(crate) async fn room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        Ok(self
            .inner
            .directory
            .get(code)
            .await?
            .map(|room| self.without_dead_replicas(room)))
    }
    ```

  In `src/main.rs` replace `health_handler` with:

  ```rust
  async fn health_handler(State(state): State<AppState>) -> impl IntoResponse {
      let redis = state.relay.redis_status().await;
      match state.vault.health_check().await {
          Ok(()) if redis != "unavailable" => (
              StatusCode::OK,
              Json(serde_json::json!({
                  "status": "ok",
                  "vault_store": state.vault.backend_name(),
                  "knowledge_store": state.knowledge.backend_name(),
                  "redis": redis,
                  "replicas": state.relay.replica_count(),
              })),
          ),
          Ok(()) => {
              tracing::error!("Health check failed: Redis unavailable");
              (
                  StatusCode::SERVICE_UNAVAILABLE,
                  Json(serde_json::json!({ "status": "unhealthy", "redis": redis })),
              )
          }
          Err(error) => {
              tracing::error!("Health check failed: {}", error);
              (
                  StatusCode::SERVICE_UNAVAILABLE,
                  Json(serde_json::json!({ "status": "unhealthy" })),
              )
          }
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test`, then the Redis suite
  (as in Task 10, Step 5).

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): replica presence, liveness and /health redis+replicas

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 12: `RedisBus` (publish + subscriber)

**Files:** create `src/cluster/redis/bus.rs`; modify `src/cluster/bus.rs`
(add `BusEvent`), `src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `RedisConn`, `keys`, `InboxMessage`, `BroadcastMessage`, `ReplicaBus`.
Produces:
- in `cluster/bus.rs`: `#[derive(Debug, Clone, PartialEq, Eq)] pub enum BusEvent { Inbox(InboxMessage), Broadcast(BroadcastMessage), VoiceReply { session_id: String, reply: String }, Resubscribed }`
- `pub struct RedisBus` implementing `ReplicaBus` (`backend_name` = `"redis"`) with
  `async start(conn: RedisConn, replica_id: &str) -> Result<(RedisBus, mpsc::UnboundedReceiver<BusEvent>, JoinHandle<()>), StoreError>`
  (returns once `relay:inbox:<id>`, `relay:broadcast` and `relay:voice-reply:*` are subscribed)
  and `publisher(conn: RedisConn, replica_id: &str) -> RedisBus` (publish only; used by `admin`)
- Voice replies are published by the voice script itself (Task 16), not by the bus.

After a lost subscription the task reconnects with backoff (100 ms doubling
to 5 s) and emits `BusEvent::Resubscribed`; the receiver side (Task 14)
clears its room cache and reloads keys, since messages sent in between are
lost.

- [ ] **Step 1: write the tests** (new `src/cluster/redis/bus.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

      async fn next_event(events: &mut mpsc::UnboundedReceiver<BusEvent>) -> BusEvent {
          tokio::time::timeout(std::time::Duration::from_secs(3), events.recv())
              .await
              .expect("no bus event within 3 s")
              .expect("bus closed")
      }

      #[tokio::test]
      #[ignore]
      async fn redis_bus_delivers_inbox_broadcast_and_voice_replies() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let (bus_a, mut events_a, task_a) = RedisBus::start(conn.clone(), "replica-a").await.unwrap();
          let (bus_b, mut events_b, task_b) = RedisBus::start(conn.clone(), "replica-b").await.unwrap();
          assert_eq!(bus_a.backend_name(), "redis");

          // Inbox: only the addressed replica gets it, in publish order.
          for n in 0..20 {
              bus_a
                  .send_inbox(
                      "replica-b",
                      InboxMessage::Deliver { connection_ids: vec!["c1".into()], frame: format!("{n}") },
                  )
                  .await
                  .unwrap();
          }
          for n in 0..20 {
              assert_eq!(
                  next_event(&mut events_b).await,
                  BusEvent::Inbox(InboxMessage::Deliver {
                      connection_ids: vec!["c1".into()],
                      frame: format!("{n}"),
                  })
              );
          }

          // Broadcast: everyone, including the sender.
          let message = BroadcastMessage::KeyChanged { astation_id: "astation-x".into() };
          bus_b.broadcast(message.clone()).await.unwrap();
          assert_eq!(next_event(&mut events_a).await, BusEvent::Broadcast(message.clone()));
          assert_eq!(next_event(&mut events_b).await, BusEvent::Broadcast(message));

          // Voice replies arrive on every replica, id unescaped.
          conn.run(|mut c| async move {
              redis::cmd("PUBLISH")
                  .arg(keys::voice_reply_channel("v:1"))
                  .arg("the answer")
                  .query_async::<i64>(&mut c)
                  .await
          })
          .await
          .unwrap();
          let expected = BusEvent::VoiceReply { session_id: "v:1".into(), reply: "the answer".into() };
          assert_eq!(next_event(&mut events_a).await, expected);
          assert_eq!(next_event(&mut events_b).await, expected);

          // A publisher-only bus (admin) reaches subscribers too.
          let admin = RedisBus::publisher(conn.clone(), "admin");
          admin
              .broadcast(BroadcastMessage::RoomChanged { code: "ROOM".into() })
              .await
              .unwrap();
          assert_eq!(
              next_event(&mut events_a).await,
              BusEvent::Broadcast(BroadcastMessage::RoomChanged { code: "ROOM".into() })
          );
          task_a.abort();
          task_b.abort();
      }
  }
  ```

  Add `pub mod bus;` to `src/cluster/redis/mod.rs` (after `pub mod keys;`).

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::redis::bus`
  (compile error).

- [ ] **Step 3: implement.** Append to `src/cluster/bus.rs` (above its tests):

  ```rust
  /// What a replica's bus subscription delivers to it.
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum BusEvent {
      Inbox(InboxMessage),
      Broadcast(BroadcastMessage),
      /// An Atem's answer for a waiting voice request (`relay:voice-reply:<id>`).
      VoiceReply { session_id: String, reply: String },
      /// The subscription was lost and re-established: anything published
      /// in between was missed.
      Resubscribed,
  }
  ```

  Above the tests in `src/cluster/redis/bus.rs`:

  ```rust
  //! ReplicaBus over Redis pub/sub. Each replica subscribes to its own inbox
  //! (`relay:inbox:<replica_id>`), the broadcast channel and, as a pattern,
  //! every voice-reply channel. Redis keeps order per publisher and channel,
  //! so one Astation → Atem stream (one replica to one inbox) stays ordered.

  use std::time::Duration;

  use async_trait::async_trait;
  use futures_util::StreamExt;
  use tokio::sync::{mpsc, oneshot};
  use tokio::task::JoinHandle;

  use super::{keys, redis_error, RedisConn, REDIS_TIMEOUT};
  use crate::cluster::bus::{BroadcastMessage, BusEvent, InboxMessage, ReplicaBus};
  use crate::cluster::StoreError;

  pub struct RedisBus {
      conn: RedisConn,
      replica_id: String,
  }

  impl RedisBus {
      /// Subscribe for `replica_id`; returns once the subscription is live.
      pub async fn start(
          conn: RedisConn,
          replica_id: &str,
      ) -> Result<(Self, mpsc::UnboundedReceiver<BusEvent>, JoinHandle<()>), StoreError> {
          let (events_tx, events_rx) = mpsc::unbounded_channel();
          let (ready_tx, ready_rx) = oneshot::channel();
          let task = tokio::spawn(subscriber_loop(
              conn.client().clone(),
              replica_id.to_string(),
              events_tx,
              Some(ready_tx),
          ));
          match tokio::time::timeout(REDIS_TIMEOUT * 2, ready_rx).await {
              Ok(Ok(())) => Ok((Self::publisher(conn, replica_id), events_rx, task)),
              _ => {
                  task.abort();
                  Err(StoreError::Unavailable("relay bus subscription failed".to_string()))
              }
          }
      }

      /// A bus that only publishes (no subscription).
      pub fn publisher(conn: RedisConn, replica_id: &str) -> Self {
          Self {
              conn,
              replica_id: replica_id.to_string(),
          }
      }

      async fn publish(&self, channel: String, payload: String) -> Result<(), StoreError> {
          self.conn
              .run(|mut c| async move {
                  redis::cmd("PUBLISH")
                      .arg(&channel)
                      .arg(&payload)
                      .query_async::<i64>(&mut c)
                      .await
                      .map(|_| ())
              })
              .await
      }
  }

  #[async_trait]
  impl ReplicaBus for RedisBus {
      fn backend_name(&self) -> &'static str {
          "redis"
      }

      async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), StoreError> {
          let payload = serde_json::to_string(&message)
              .map_err(|error| StoreError::Unavailable(error.to_string()))?;
          self.publish(keys::inbox_channel(replica_id), payload).await
      }

      async fn broadcast(&self, message: BroadcastMessage) -> Result<(), StoreError> {
          let payload = serde_json::to_string(&message)
              .map_err(|error| StoreError::Unavailable(error.to_string()))?;
          tracing::trace!("Replica {} broadcasting {}", self.replica_id, payload);
          self.publish(keys::BROADCAST_CHANNEL.to_string(), payload).await
      }
  }

  async fn subscribe(client: &redis::Client, replica_id: &str) -> Result<redis::aio::PubSub, StoreError> {
      let subscribing = async {
          let mut pubsub = client.get_async_pubsub().await?;
          pubsub.subscribe(keys::inbox_channel(replica_id)).await?;
          pubsub.subscribe(keys::BROADCAST_CHANNEL).await?;
          pubsub.psubscribe(keys::VOICE_REPLY_PATTERN).await?;
          Ok::<_, redis::RedisError>(pubsub)
      };
      match tokio::time::timeout(REDIS_TIMEOUT, subscribing).await {
          Ok(Ok(pubsub)) => Ok(pubsub),
          Ok(Err(error)) => Err(redis_error(error)),
          Err(_) => Err(StoreError::Unavailable("redis subscribe timed out".to_string())),
      }
  }

  fn decode(message: &redis::Msg) -> Option<BusEvent> {
      let channel = message.get_channel_name();
      let payload: String = message.get_payload().ok()?;
      if let Some(escaped_id) = channel.strip_prefix(keys::VOICE_REPLY_CHANNEL_PREFIX) {
          return Some(BusEvent::VoiceReply {
              session_id: keys::unpart(escaped_id),
              reply: payload,
          });
      }
      if channel == keys::BROADCAST_CHANNEL {
          return serde_json::from_str(&payload).ok().map(BusEvent::Broadcast);
      }
      serde_json::from_str(&payload).ok().map(BusEvent::Inbox)
  }

  async fn subscriber_loop(
      client: redis::Client,
      replica_id: String,
      events: mpsc::UnboundedSender<BusEvent>,
      mut ready: Option<oneshot::Sender<()>>,
  ) {
      let mut backoff = Duration::from_millis(100);
      loop {
          match subscribe(&client, &replica_id).await {
              Ok(pubsub) => {
                  backoff = Duration::from_millis(100);
                  match ready.take() {
                      Some(ready) => {
                          let _ = ready.send(());
                      }
                      None => {
                          if events.send(BusEvent::Resubscribed).is_err() {
                              return;
                          }
                      }
                  }
                  let mut stream = Box::pin(pubsub.into_on_message());
                  while let Some(message) = stream.next().await {
                      match decode(&message) {
                          Some(event) => {
                              if events.send(event).is_err() {
                                  return;
                              }
                          }
                          None => tracing::warn!(
                              "Dropped an undecodable bus message on {}",
                              message.get_channel_name()
                          ),
                      }
                  }
                  tracing::warn!("Relay bus subscription lost; reconnecting");
              }
              Err(error) => tracing::warn!("Relay bus subscribe failed: {}", error),
          }
          if events.is_closed() {
              return;
          }
          tokio::time::sleep(backoff).await;
          backoff = (backoff * 2).min(Duration::from_secs(5));
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test` and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): Redis pub/sub ReplicaBus (inbox, broadcast, voice replies)

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 13: `RedisRoomDirectory` (Lua)

**Files:** create `src/cluster/redis/directory.rs`; modify
`src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `RedisConn`, `keys`, `RoomDirectory` and its types, `directory::scenarios`.
Produces: `pub struct RedisRoomDirectory` with `new(RedisConn) -> Self`,
implementing `RoomDirectory` (`backend_name` = `"redis"`).

Storage (spec table): `relay:room:<code>` hash {`owner_conn`,
`owner_replica`, `verified` "0"/"1", `hostname`, `created_at`, `paired`
"0"/"1"}; `relay:room:<code>:atems` hash atem_id → `conn|replica`;
`relay:room:<code>:pending` hash conn → replica. Every mutation is one Lua
script over the three keys (so "set owner = me, verified, remove me from
pending, return the previous owner" happens atomically and two replicas
can't both win). The room key expires 600 s after creation, and again 600 s
after an Astation claims it or goes pending, or after `touch` (heartbeat);
the two hashes always carry the room's remaining TTL. `get` reads all three
in one `MULTI`. `remove_expired` returns nothing (Redis expires keys).

- [ ] **Step 1: write the tests** (new `src/cluster/redis/directory.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::directory::scenarios;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

      macro_rules! redis_directory_tests {
          ($($name:ident),* $(,)?) => {
              $(
                  #[tokio::test]
                  #[ignore]
                  async fn $name() {
                      let _guard = REDIS_LOCK.lock().await;
                      let d = RedisRoomDirectory::new(fresh_conn().await);
                      scenarios::$name(&d).await;
                  }
              )*
          };
      }

      mod redis_directory {
          use super::*;

          redis_directory_tests!(
              create_get_and_expiry,
              ensure_room_is_idempotent,
              atem_join_requires_a_room_and_replaces,
              claim_owner_creates_the_room_and_replaces_the_owner,
              pending_respects_the_cap,
              promotion_rules,
              legacy_owner_becomes_verified_when_it_proves,
              leave_atem_ignores_a_stale_connection,
              leaving_last_member_removes_the_room,
              delete_room_returns_its_members,
              touch_and_exists,
          );

          #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
          #[ignore]
          async fn concurrent_promotions_leave_one_owner() {
              let _guard = REDIS_LOCK.lock().await;
              let d = RedisRoomDirectory::new(fresh_conn().await);
              scenarios::concurrent_promotions_leave_one_owner(std::sync::Arc::new(d)).await;
          }

          #[tokio::test]
          #[ignore]
          async fn room_keys_follow_the_spec_and_expire() {
              let _guard = REDIS_LOCK.lock().await;
              let conn = fresh_conn().await;
              let d = RedisRoomDirectory::new(conn.clone());
              d.create_room("ROOM-K", "host", 1_700_000_000).await.unwrap();
              d.join_atem("ROOM-K", "atem-a", &ConnRef::new("t1", "r1")).await.unwrap();
              d.add_pending("ROOM-K", &ConnRef::new("p1", "r2"), 1_700_000_000, 0).await.unwrap();
              let (room, atems, pending): (HashMap<String, String>, HashMap<String, String>, HashMap<String, String>) = conn
                  .run(|mut c| async move {
                      redis::pipe()
                          .hgetall("relay:room:ROOM-K")
                          .hgetall("relay:room:ROOM-K:atems")
                          .hgetall("relay:room:ROOM-K:pending")
                          .query_async(&mut c)
                          .await
                  })
                  .await
                  .unwrap();
              assert_eq!(room["hostname"], "host");
              assert_eq!(room["created_at"], "1700000000");
              assert_eq!(room["owner_conn"], "");
              assert_eq!(room["verified"], "0");
              assert_eq!(room["paired"], "0");
              assert_eq!(atems["atem-a"], "t1|r1");
              assert_eq!(pending["p1"], "r2");
              for key in ["relay:room:ROOM-K", "relay:room:ROOM-K:atems", "relay:room:ROOM-K:pending"] {
                  let key = key.to_string();
                  let ttl: i64 = conn
                      .run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
                      .await
                      .unwrap();
                  assert!((590..=600).contains(&ttl), "{key} ttl {ttl}");
              }
              assert!(d.remove_expired(i64::MAX).await.unwrap().is_empty());
          }
      }
  }
  ```

  Add `pub mod directory;` to `src/cluster/redis/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::redis::directory`.

- [ ] **Step 3: implement** above the tests:

  ```rust
  //! RoomDirectory in Redis. Every mutation is one Lua script over
  //! KEYS[1] = relay:room:<code>, KEYS[2] = …:atems, KEYS[3] = …:pending.

  use std::collections::HashMap;

  use async_trait::async_trait;
  use redis::Script;

  use super::{keys, RedisConn};
  use crate::cluster::directory::{
      AtemJoin, AtemLeave, OwnerClaim, Promotion, RoomDirectory, RoomInfo, IDENTITY_HOSTNAME,
      ROOM_EXPIRY_SECS,
  };
  use crate::cluster::{ConnRef, StoreError};

  const PRELUDE: &str = r#"
  local function sync_ttl()
    local ttl = redis.call('PTTL', KEYS[1])
    if ttl > 0 then
      if redis.call('EXISTS', KEYS[2]) == 1 then redis.call('PEXPIRE', KEYS[2], ttl) end
      if redis.call('EXISTS', KEYS[3]) == 1 then redis.call('PEXPIRE', KEYS[3], ttl) end
    end
  end
  local function is_empty()
    return redis.call('HLEN', KEYS[2]) == 0
      and redis.call('HLEN', KEYS[3]) == 0
      and (redis.call('HGET', KEYS[1], 'owner_conn') or '') == ''
  end
  local function new_room(hostname, created_at, ttl)
    redis.call('HSET', KEYS[1], 'hostname', hostname, 'created_at', created_at,
      'owner_conn', '', 'owner_replica', '', 'verified', '0', 'paired', '0')
    redis.call('EXPIRE', KEYS[1], ttl)
  end
  local function keep_alive(ttl)
    redis.call('EXPIRE', KEYS[1], ttl)
    sync_ttl()
  end
  "#;

  // ARGV: hostname, created_at, ttl
  const CREATE_ROOM: &str = r#"
  redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
  new_room(ARGV[1], ARGV[2], ARGV[3])
  return '1'
  "#;

  // ARGV: hostname, created_at, ttl
  const ENSURE_ROOM: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 1 then return '0' end
  new_room(ARGV[1], ARGV[2], ARGV[3])
  return '1'
  "#;

  // ARGV: atem_id, conn|replica → {'1', replaced, owner_conn, owner_replica} or {'0'}
  const JOIN_ATEM: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'0'} end
  local replaced = redis.call('HGET', KEYS[2], ARGV[1]) or ''
  redis.call('HSET', KEYS[2], ARGV[1], ARGV[2])
  sync_ttl()
  return {'1', replaced,
    redis.call('HGET', KEYS[1], 'owner_conn') or '',
    redis.call('HGET', KEYS[1], 'owner_replica') or ''}
  "#;

  // ARGV: conn, replica, hostname, created_at, ttl → {prev_conn, prev_replica, atem pairs…}
  const CLAIM_OWNER: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then new_room(ARGV[3], ARGV[4], ARGV[5]) end
  local out = {redis.call('HGET', KEYS[1], 'owner_conn') or '',
               redis.call('HGET', KEYS[1], 'owner_replica') or ''}
  redis.call('HSET', KEYS[1], 'owner_conn', ARGV[1], 'owner_replica', ARGV[2],
    'verified', '0', 'paired', '1')
  keep_alive(ARGV[5])
  local atems = redis.call('HGETALL', KEYS[2])
  for i = 1, #atems do out[#out + 1] = atems[i] end
  return out
  "#;

  // ARGV: conn, replica, hostname, created_at, ttl, max_pending (0 = no cap) → '1' | '0'
  const ADD_PENDING: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then new_room(ARGV[3], ARGV[4], ARGV[5]) end
  local cap = tonumber(ARGV[6])
  if cap > 0 and redis.call('HEXISTS', KEYS[3], ARGV[1]) == 0
     and redis.call('HLEN', KEYS[3]) >= cap then
    return '0'
  end
  redis.call('HSET', KEYS[3], ARGV[1], ARGV[2])
  keep_alive(ARGV[5])
  return '1'
  "#;

  // ARGV: conn, replica, was_pending ('1'/'0')
  // → {'none'} | {'owner'} | {'not_pending', evicted_conn, evicted_replica}
  //   | {'promoted', prev_conn, prev_replica, atem pairs…}
  const PROMOTE: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'none'} end
  local oc = redis.call('HGET', KEYS[1], 'owner_conn') or ''
  local orp = redis.call('HGET', KEYS[1], 'owner_replica') or ''
  if oc == ARGV[1] then
    redis.call('HSET', KEYS[1], 'verified', '1')
    return {'owner'}
  end
  local ec, er = '', ''
  if oc ~= '' and (redis.call('HGET', KEYS[1], 'verified') or '0') ~= '1' then
    ec, er = oc, orp
    redis.call('HSET', KEYS[1], 'owner_conn', '', 'owner_replica', '', 'verified', '0', 'paired', '0')
  end
  if ARGV[3] ~= '1' or redis.call('HDEL', KEYS[3], ARGV[1]) == 0 then
    return {'not_pending', ec, er}
  end
  redis.call('HSET', KEYS[1], 'owner_conn', ARGV[1], 'owner_replica', ARGV[2],
    'verified', '1', 'paired', '1')
  local out = {'promoted', oc, orp}
  local atems = redis.call('HGETALL', KEYS[2])
  for i = 1, #atems do out[#out + 1] = atems[i] end
  return out
  "#;

  // ARGV: atem_id, connection_id → {removed, room_removed, owner_conn, owner_replica}
  const LEAVE_ATEM: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'0', '0', '', ''} end
  local removed = '0'
  local current = redis.call('HGET', KEYS[2], ARGV[1]) or ''
  if string.sub(current, 1, #ARGV[2] + 1) == ARGV[2] .. '|' then
    redis.call('HDEL', KEYS[2], ARGV[1])
    removed = '1'
  end
  local oc = redis.call('HGET', KEYS[1], 'owner_conn') or ''
  local orp = redis.call('HGET', KEYS[1], 'owner_replica') or ''
  local gone = '0'
  if is_empty() then
    redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
    gone = '1'
  end
  return {removed, gone, oc, orp}
  "#;

  // ARGV: connection_id → room_removed '1' | '0'
  const LEAVE_ASTATION: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return '0' end
  redis.call('HDEL', KEYS[3], ARGV[1])
  if (redis.call('HGET', KEYS[1], 'owner_conn') or '') == ARGV[1] then
    redis.call('HSET', KEYS[1], 'owner_conn', '', 'owner_replica', '', 'verified', '0', 'paired', '0')
  end
  if is_empty() then
    redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
    return '1'
  end
  return '0'
  "#;

  // → {} | {room pairs, atem pairs, pending pairs}
  const DELETE_ROOM: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {} end
  local out = {redis.call('HGETALL', KEYS[1]), redis.call('HGETALL', KEYS[2]),
               redis.call('HGETALL', KEYS[3])}
  redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
  return out
  "#;

  // ARGV: ttl → '1' | '0'
  const TOUCH: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return '0' end
  keep_alive(ARGV[1])
  return '1'
  "#;

  fn script(body: &str) -> Script {
      Script::new(&format!("{PRELUDE}\n{body}"))
  }

  fn at(values: &[String], index: usize) -> &str {
      values.get(index).map(String::as_str).unwrap_or("")
  }

  fn conn_ref(conn: &str, replica: &str) -> Option<ConnRef> {
      (!conn.is_empty()).then(|| ConnRef::new(conn, replica))
  }

  /// `[id, "conn|replica", id, …]` → pairs; malformed entries are skipped.
  fn atem_pairs(flat: &[String]) -> Vec<(String, ConnRef)> {
      flat.chunks(2)
          .filter_map(|pair| match pair {
              [atem_id, value] => ConnRef::decode(value).map(|conn| (atem_id.clone(), conn)),
              _ => None,
          })
          .collect()
  }

  fn flat_to_map(flat: &[String]) -> HashMap<String, String> {
      flat.chunks(2)
          .filter_map(|pair| match pair {
              [field, value] => Some((field.clone(), value.clone())),
              _ => None,
          })
          .collect()
  }

  fn room_info(
      room: &HashMap<String, String>,
      atems: &HashMap<String, String>,
      pending: &HashMap<String, String>,
  ) -> RoomInfo {
      let field = |name: &str| room.get(name).map(String::as_str).unwrap_or("");
      let mut pending: Vec<ConnRef> = pending
          .iter()
          .map(|(conn, replica)| ConnRef::new(conn, replica))
          .collect();
      pending.sort();
      RoomInfo {
          hostname: field("hostname").to_string(),
          created_at: field("created_at").parse().unwrap_or(0),
          owner: conn_ref(field("owner_conn"), field("owner_replica")),
          verified: field("verified") == "1",
          atems: atems
              .iter()
              .filter_map(|(atem_id, value)| ConnRef::decode(value).map(|conn| (atem_id.clone(), conn)))
              .collect(),
          pending,
      }
  }

  pub struct RedisRoomDirectory {
      conn: RedisConn,
      create_room: Script,
      ensure_room: Script,
      join_atem: Script,
      claim_owner: Script,
      add_pending: Script,
      promote: Script,
      leave_atem: Script,
      leave_astation: Script,
      delete_room: Script,
      touch: Script,
  }

  impl RedisRoomDirectory {
      pub fn new(conn: RedisConn) -> Self {
          Self {
              conn,
              create_room: script(CREATE_ROOM),
              ensure_room: script(ENSURE_ROOM),
              join_atem: script(JOIN_ATEM),
              claim_owner: script(CLAIM_OWNER),
              add_pending: script(ADD_PENDING),
              promote: script(PROMOTE),
              leave_atem: script(LEAVE_ATEM),
              leave_astation: script(LEAVE_ASTATION),
              delete_room: script(DELETE_ROOM),
              touch: script(TOUCH),
          }
      }

      /// Run a room script with the room's three keys and `args`.
      async fn eval<T>(&self, script: &Script, code: &str, args: Vec<String>) -> Result<T, StoreError>
      where
          T: redis::FromRedisValue + Send,
      {
          let (room, atems, pending) = (keys::room(code), keys::room_atems(code), keys::room_pending(code));
          self.conn
              .run(|mut c| async move {
                  let mut invocation = script.prepare_invoke();
                  invocation.key(&room).key(&atems).key(&pending);
                  for arg in &args {
                      invocation.arg(arg);
                  }
                  invocation.invoke_async(&mut c).await
              })
              .await
      }
  }

  #[async_trait]
  impl RoomDirectory for RedisRoomDirectory {
      fn backend_name(&self) -> &'static str {
          "redis"
      }

      async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError> {
          let _: String = self
              .eval(
                  &self.create_room,
                  code,
                  vec![hostname.to_string(), now.to_string(), ROOM_EXPIRY_SECS.to_string()],
              )
              .await?;
          Ok(())
      }

      async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError> {
          let created: String = self
              .eval(
                  &self.ensure_room,
                  code,
                  vec![hostname.to_string(), now.to_string(), ROOM_EXPIRY_SECS.to_string()],
              )
              .await?;
          Ok(created == "1")
      }

      async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          let (room_key, atems_key, pending_key) =
              (keys::room(code), keys::room_atems(code), keys::room_pending(code));
          let (room, atems, pending): (
              HashMap<String, String>,
              HashMap<String, String>,
              HashMap<String, String>,
          ) = self
              .conn
              .run(|mut c| async move {
                  redis::pipe()
                      .atomic()
                      .hgetall(&room_key)
                      .hgetall(&atems_key)
                      .hgetall(&pending_key)
                      .query_async(&mut c)
                      .await
              })
              .await?;
          if room.is_empty() {
              return Ok(None);
          }
          Ok(Some(room_info(&room, &atems, &pending)))
      }

      async fn join_atem(&self, code: &str, atem_id: &str, conn: &ConnRef) -> Result<AtemJoin, StoreError> {
          let out: Vec<String> = self
              .eval(&self.join_atem, code, vec![atem_id.to_string(), conn.encode()])
              .await?;
          if at(&out, 0) != "1" {
              return Ok(AtemJoin::NoRoom);
          }
          Ok(AtemJoin::Joined {
              replaced: ConnRef::decode(at(&out, 1)),
              owner: conn_ref(at(&out, 2), at(&out, 3)),
          })
      }

      async fn claim_owner(&self, code: &str, conn: &ConnRef, now: i64) -> Result<OwnerClaim, StoreError> {
          let out: Vec<String> = self
              .eval(
                  &self.claim_owner,
                  code,
                  vec![
                      conn.conn.clone(),
                      conn.replica.clone(),
                      IDENTITY_HOSTNAME.to_string(),
                      now.to_string(),
                      ROOM_EXPIRY_SECS.to_string(),
                  ],
              )
              .await?;
          Ok(OwnerClaim {
              replaced: conn_ref(at(&out, 0), at(&out, 1)),
              atems: atem_pairs(out.get(2..).unwrap_or(&[])),
          })
      }

      async fn add_pending(&self, code: &str, conn: &ConnRef, now: i64, max_pending: usize) -> Result<bool, StoreError> {
          let admitted: String = self
              .eval(
                  &self.add_pending,
                  code,
                  vec![
                      conn.conn.clone(),
                      conn.replica.clone(),
                      IDENTITY_HOSTNAME.to_string(),
                      now.to_string(),
                      ROOM_EXPIRY_SECS.to_string(),
                      max_pending.to_string(),
                  ],
              )
              .await?;
          Ok(admitted == "1")
      }

      async fn promote(&self, code: &str, conn: &ConnRef, was_pending: bool) -> Result<Promotion, StoreError> {
          let out: Vec<String> = self
              .eval(
                  &self.promote,
                  code,
                  vec![
                      conn.conn.clone(),
                      conn.replica.clone(),
                      if was_pending { "1" } else { "0" }.to_string(),
                  ],
              )
              .await?;
          Ok(match at(&out, 0) {
              "owner" => Promotion::AlreadyOwner,
              "not_pending" => Promotion::NotPending {
                  evicted: conn_ref(at(&out, 1), at(&out, 2)),
              },
              "promoted" => Promotion::Promoted {
                  previous_owner: conn_ref(at(&out, 1), at(&out, 2)),
                  atems: atem_pairs(out.get(3..).unwrap_or(&[])),
              },
              _ => Promotion::NoRoom,
          })
      }

      async fn leave_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Result<AtemLeave, StoreError> {
          let out: Vec<String> = self
              .eval(
                  &self.leave_atem,
                  code,
                  vec![atem_id.to_string(), connection_id.to_string()],
              )
              .await?;
          Ok(AtemLeave {
              removed: at(&out, 0) == "1",
              room_removed: at(&out, 1) == "1",
              owner: conn_ref(at(&out, 2), at(&out, 3)),
          })
      }

      async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError> {
          let removed: String = self
              .eval(&self.leave_astation, code, vec![connection_id.to_string()])
              .await?;
          Ok(removed == "1")
      }

      async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
          let out: Vec<Vec<String>> = self.eval(&self.delete_room, code, Vec::new()).await?;
          let [room, atems, pending] = match out.as_slice() {
              [room, atems, pending] => [room, atems, pending],
              _ => return Ok(None),
          };
          Ok(Some(room_info(
              &flat_to_map(room),
              &flat_to_map(atems),
              &flat_to_map(pending),
          )))
      }

      async fn touch(&self, code: &str) -> Result<bool, StoreError> {
          let exists: String = self
              .eval(&self.touch, code, vec![ROOM_EXPIRY_SECS.to_string()])
              .await?;
          Ok(exists == "1")
      }

      async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError> {
          if codes.is_empty() {
              return Ok(Vec::new());
          }
          let room_keys: Vec<String> = codes.iter().map(|code| keys::room(code)).collect();
          self.conn
              .run(|mut c| async move {
                  let mut pipe = redis::pipe();
                  for key in &room_keys {
                      pipe.exists(key);
                  }
                  pipe.query_async(&mut c).await
              })
              .await
      }

      async fn remove_expired(&self, _now: i64) -> Result<Vec<String>, StoreError> {
          Ok(Vec::new())
      }
  }
  ```

  Re-adding a connection that is already pending is allowed even at the cap
  (`HEXISTS` guard), matching the in-memory `contains` check that runs before
  the cap check.

- [ ] **Step 4: run and watch it pass.** `cargo test`, then the Redis suite:
  all eleven scenarios, the concurrent promotion and
  `room_keys_follow_the_spec_and_expire` pass against Valkey.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): Redis RoomDirectory with atomic Lua scripts

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 14: room cache and the bus dispatcher

**Files:** modify `src/relay.rs`.

**Interfaces.**
Consumes: `BusEvent`, `apply_inbox`, `KeyCache::reload_one`, `KeyCache::load`,
`ReplyWaiters` (Task 7).
Produces:
- `HubParts.cache_rooms: bool` (false in `single_instance`)
- `RelayHub::invalidate_room(&self, &str)`, `RelayHub::clear_room_cache(&self)`
- `RelayHub::spawn_bus_dispatcher(&self, identity: Arc<dyn IdentityStore>, waiters: ReplyWaiters, events: mpsc::UnboundedReceiver<BusEvent>) -> JoinHandle<()>`
- `route_view` serves from the cache when enabled (entries live 30 s,
  dropped on `room-changed`, all dropped on resubscribe); `find_atem`
  re-reads once on a cached miss.

The cache is filled only by routing lookups, which happen only for rooms
with local sockets. A read that raced an invalidation is not stored (a
global epoch counter).

- [ ] **Step 1: write the tests** in `relay.rs`'s test module:

  ```rust
  #[tokio::test]
  async fn cached_routing_follows_room_changed() {
      let directory = InMemoryRoomDirectory::new();
      let hub = RelayHub::from_parts(HubParts {
          cache_rooms: true,
          ..HubParts::single_instance(directory.clone(), TEST_AUTH_TIMEOUT)
      });
      let code = "astation-cache";
      directory.claim_owner(code, &test_conn("owner-1"), now()).await.unwrap();
      assert_eq!(
          hub.route_view(code).await.unwrap().unwrap().owner,
          Some(test_conn("owner-1"))
      );
      // Changed behind the hub's back (another replica): still cached …
      directory.claim_owner(code, &test_conn("owner-2"), now()).await.unwrap();
      assert_eq!(
          hub.route_view(code).await.unwrap().unwrap().owner,
          Some(test_conn("owner-1"))
      );
      // … until the room-changed announcement arrives.
      hub.invalidate_room(code);
      assert_eq!(
          hub.route_view(code).await.unwrap().unwrap().owner,
          Some(test_conn("owner-2"))
      );
      // A targeted frame for a connection the cache doesn't know re-reads once.
      directory.join_atem(code, "atem-a", &test_conn("t-new")).await.unwrap();
      assert_eq!(hub.find_atem(code, "atem-a", "t-new").await, Some(test_conn("t-new")));
      assert_eq!(hub.find_atem(code, "atem-a", "t-stale").await, None);
  }

  #[tokio::test]
  async fn bus_dispatcher_applies_every_event() {
      use crate::cluster::bus::BusEvent;
      let hub = RelayHub::from_parts(HubParts {
          cache_rooms: true,
          ..HubParts::single_instance(InMemoryRoomDirectory::new(), TEST_AUTH_TIMEOUT)
      });
      let identity = std::sync::Arc::new(InMemoryIdentityStore::new());
      identity.register_key_if_absent("astation-k", "04AB", 1).await.unwrap();
      let waiters = crate::voice_session::ReplyWaiters::default();
      let (events_tx, events_rx) = tokio::sync::mpsc::unbounded_channel();
      let task = hub.spawn_bus_dispatcher(identity.clone(), waiters.clone(), events_rx);

      let mut socket = hub.local().register("c1", "room", SocketRole::Astation);
      events_tx
          .send(BusEvent::Inbox(InboxMessage::Deliver {
              connection_ids: vec!["c1".into()],
              frame: "hi".into(),
          }))
          .unwrap();
      assert_eq!(socket.frames.recv().await.as_deref(), Some("hi"));

      let reply = waiters.register("voice-1");
      events_tx
          .send(BusEvent::VoiceReply { session_id: "voice-1".into(), reply: "answer".into() })
          .unwrap();
      assert_eq!(reply.await.unwrap(), "answer");

      events_tx
          .send(BusEvent::Broadcast(BusBroadcast::KeyChanged { astation_id: "astation-k".into() }))
          .unwrap();
      let mut learned = false;
      for _ in 0..100 {
          if hub.keys().contains("astation-k") {
              learned = true;
              break;
          }
          tokio::time::sleep(std::time::Duration::from_millis(10)).await;
      }
      assert!(learned, "key-changed made the hub re-read the key");

      drop(events_tx);
      task.await.unwrap();
  }
  ```

- [ ] **Step 2: run and watch it fail.** `cargo test relay::tests::cached`
  (compile error: `cache_rooms`, `invalidate_room`, `spawn_bus_dispatcher`).

- [ ] **Step 3: implement** in `src/relay.rs`:
  - imports: add `use crate::cluster::bus::{apply_inbox, BusEvent};`,
    `use crate::voice_session::ReplyWaiters;`,
    `use std::collections::HashMap;`,
    `use std::sync::atomic::{AtomicU64, Ordering};`,
    `use tokio::sync::mpsc;`, `use tokio::task::JoinHandle;`;
  - add `pub cache_rooms: bool,` to `HubParts` and `cache_rooms: false,` in
    `HubParts::single_instance`;
  - add `room_cache: Option<RoomCache>,` to `HubInner`, and in `from_parts`:
    `room_cache: parts.cache_rooms.then(RoomCache::default),`;
  - add above `pub(crate) struct HubParts`:

    ```rust
    /// Cached room entries live this long even without an invalidation.
    const ROOM_CACHE_TTL: Duration = Duration::from_secs(30);

    /// Above this many entries the cache is cleared rather than grown.
    const ROOM_CACHE_MAX: usize = 100_000;

    /// Directory entries of rooms this replica routes for. Invalidated by
    /// `room-changed`; the epoch keeps a read that raced an invalidation
    /// from being stored.
    #[derive(Default)]
    struct RoomCache {
        epoch: AtomicU64,
        entries: std::sync::Mutex<HashMap<String, (Instant, Option<RoomInfo>)>>,
    }

    impl RoomCache {
        fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, (Instant, Option<RoomInfo>)>> {
            self.entries.lock().unwrap_or_else(|e| e.into_inner())
        }

        fn get(&self, code: &str) -> Option<Option<RoomInfo>> {
            self.lock()
                .get(code)
                .filter(|(stored, _)| stored.elapsed() < ROOM_CACHE_TTL)
                .map(|(_, room)| room.clone())
        }

        fn put(&self, code: &str, room: Option<RoomInfo>, epoch: u64) {
            let mut entries = self.lock();
            if self.epoch.load(Ordering::SeqCst) != epoch {
                return;
            }
            if entries.len() >= ROOM_CACHE_MAX {
                entries.clear();
            }
            entries.insert(code.to_string(), (Instant::now(), room));
        }

        fn invalidate(&self, code: &str) {
            let mut entries = self.lock();
            self.epoch.fetch_add(1, Ordering::SeqCst);
            entries.remove(code);
        }

        fn clear(&self) {
            let mut entries = self.lock();
            self.epoch.fetch_add(1, Ordering::SeqCst);
            entries.clear();
        }
    }
    ```

  - replace `route_view` and `find_atem` with:

    ```rust
    /// The room as frame routing sees it: from the cache when enabled.
    async fn route_view(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        let Some(cache) = &self.inner.room_cache else {
            return self.inner.directory.get(code).await;
        };
        if let Some(hit) = cache.get(code) {
            return Ok(hit);
        }
        let epoch = cache.epoch.load(Ordering::SeqCst);
        let room = self.inner.directory.get(code).await?;
        cache.put(code, room.clone(), epoch);
        Ok(room)
    }

    /// The current connection of `atem_id`, only if it is `connection_id`
    /// (stale generations are dropped). A cached miss is re-read once: the
    /// Atem may have just reconnected on another replica.
    async fn find_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Option<ConnRef> {
        let lookup = |room: Option<RoomInfo>| {
            room.and_then(|room| room.atems.get(atem_id).cloned())
                .filter(|current| current.conn == connection_id)
        };
        match self.route_view(code).await {
            Ok(room) => {
                if let Some(found) = lookup(room) {
                    return Some(found);
                }
            }
            Err(error) => {
                tracing::debug!("Room lookup failed for {}: {}", mask_code(code), error);
                return None;
            }
        }
        if self.inner.room_cache.is_none() {
            return None;
        }
        self.invalidate_room(code);
        self.route_view(code).await.ok().and_then(lookup)
    }

    pub(crate) fn invalidate_room(&self, code: &str) {
        if let Some(cache) = &self.inner.room_cache {
            cache.invalidate(code);
        }
    }

    pub(crate) fn clear_room_cache(&self) {
        if let Some(cache) = &self.inner.room_cache {
            cache.clear();
        }
    }
    ```

  - make `room_changed` invalidate locally first:

    ```rust
    pub(crate) async fn room_changed(&self, code: &str) {
        self.invalidate_room(code);
        let message = BroadcastMessage::RoomChanged { code: code.to_string() };
        if let Err(error) = self.inner.bus.broadcast(message).await {
            tracing::debug!("Could not announce a change of room {}: {}", mask_code(code), error);
        }
    }
    ```

  - add the dispatcher to `impl RelayHub`:

    ```rust
    /// Apply what other replicas publish to this one (Redis mode).
    pub(crate) fn spawn_bus_dispatcher(
        &self,
        identity: Arc<dyn IdentityStore>,
        waiters: ReplyWaiters,
        mut events: mpsc::UnboundedReceiver<BusEvent>,
    ) -> JoinHandle<()> {
        let hub = self.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                match event {
                    BusEvent::Inbox(message) => apply_inbox(hub.local(), message),
                    BusEvent::Broadcast(BroadcastMessage::RoomChanged { code }) => {
                        hub.invalidate_room(&code)
                    }
                    BusEvent::Broadcast(BroadcastMessage::KeyChanged { astation_id }) => {
                        let (keys, identity) = (hub.keys().clone(), identity.clone());
                        tokio::spawn(async move {
                            keys.reload_one(identity.as_ref(), &astation_id).await;
                        });
                    }
                    BusEvent::VoiceReply { session_id, reply } => {
                        waiters.wake(&session_id, &reply);
                    }
                    BusEvent::Resubscribed => {
                        // Anything published while we were away is lost:
                        // drop cached rooms and re-read every key.
                        hub.clear_room_cache();
                        let (keys, identity) = (hub.keys().clone(), identity.clone());
                        tokio::spawn(async move {
                            if let Err(error) = keys.load(identity.as_ref()).await {
                                tracing::warn!("Could not reload relay keys after resubscribing: {}", error);
                            }
                        });
                    }
                }
            }
        })
    }
    ```

  - the new tests use `InMemoryIdentityStore`, already imported by the
    existing `use crate::identity_store::{ … InMemoryIdentityStore, … }`
    further down the test module (a `use` anywhere in a module covers the
    whole module).

- [ ] **Step 4: run and watch it pass.** `cargo test`.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/relay.rs
  git commit -m "feat(relay): room cache with room-changed invalidation, bus dispatcher

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 15: `RedisSessionBackend`

**Files:** create `src/cluster/redis/sessions.rs`; modify `src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `SessionBackend`, `GrantOutcome`, `DenyOutcome` (Task 6), `RedisConn`, `keys`.
Produces: `pub struct RedisSessionBackend` (`new(RedisConn)`), implementing
`SessionBackend`; `pub const PENDING_GRACE_SECS: i64 = 60;`
`pub const DECIDED_SESSION_TTL_SECS: i64 = 604_800;`
`pub fn session_ttl_secs(&Session, DateTime<Utc>) -> i64`.

`relay:session:<id>` hash fields: `id`, `otp`, `hostname`, `status`
(`pending|granted|denied`), `token` (empty = none), `created_at`,
`expires_at` (RFC 3339), `expires_at_ms`, `astation_id` (empty = none).
Expiry per pre-flight note 2.

- [ ] **Step 1: write the tests** (new `src/cluster/redis/sessions.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::auth::create_session;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
      use crate::session_store::SessionStore;
      use std::sync::Arc;

      async fn store() -> (SessionStore, RedisConn) {
          let conn = fresh_conn().await;
          (
              SessionStore::with_backend(Arc::new(RedisSessionBackend::new(conn.clone()))),
              conn,
          )
      }

      async fn ttl(conn: &RedisConn, id: &str) -> i64 {
          let key = keys::session(id);
          conn.run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
              .await
              .unwrap()
      }

      #[tokio::test]
      #[ignore]
      async fn redis_sessions_round_trip_and_expire_as_designed() {
          let _guard = REDIS_LOCK.lock().await;
          let (store, conn) = store().await;
          let mut session = create_session("mac");
          session.astation_id = Some("astation-1".into());
          let id = session.id.clone();
          store.create(session.clone()).await.unwrap();
          let loaded = store.get(&id).await.unwrap().expect("stored");
          assert_eq!(loaded.id, session.id);
          assert_eq!(loaded.otp, session.otp);
          assert_eq!(loaded.hostname, "mac");
          assert_eq!(loaded.status, SessionStatus::Pending);
          assert_eq!(loaded.token, None);
          assert_eq!(loaded.created_at, session.created_at);
          assert_eq!(loaded.expires_at, session.expires_at);
          assert_eq!(loaded.astation_id.as_deref(), Some("astation-1"));
          // Pending: until 60 s after the 5-minute expiry.
          let pending_ttl = ttl(&conn, &id).await;
          assert!((300..=360).contains(&pending_ttl), "pending ttl {pending_ttl}");

          let otp = session.otp.clone();
          assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::InvalidOtp));
          let granted = match store.grant(&id, &otp).await.unwrap() {
              GrantOutcome::Granted(granted) => granted,
              other => panic!("expected Granted, got {other:?}"),
          };
          assert_eq!(granted.token.as_ref().map(String::len), Some(64));
          assert_eq!(store.get(&id).await.unwrap().unwrap().token, granted.token);
          let granted_ttl = ttl(&conn, &id).await;
          assert!(granted_ttl > DECIDED_SESSION_TTL_SECS - 10, "granted ttl {granted_ttl}");
          assert!(matches!(
              store.grant(&id, &otp).await.unwrap(),
              GrantOutcome::NotPending(SessionStatus::Granted)
          ));
          store.touch(&id).await.unwrap();

          assert!(matches!(store.grant("missing", &otp).await.unwrap(), GrantOutcome::NotFound));
          store.delete(&id).await.unwrap();
          assert!(store.get(&id).await.unwrap().is_none());
      }

      #[tokio::test]
      #[ignore]
      async fn redis_sessions_expired_and_denied() {
          let _guard = REDIS_LOCK.lock().await;
          let (store, _conn) = store().await;
          let now = Utc::now();
          let mut expired = create_session("late");
          expired.created_at = now - chrono::Duration::minutes(5) - chrono::Duration::seconds(30);
          expired.expires_at = now - chrono::Duration::seconds(30);
          let expired_id = expired.id.clone();
          let otp = expired.otp.clone();
          store.create(expired).await.unwrap();
          assert!(store.get(&expired_id).await.unwrap().is_some(), "kept for the grace period");
          assert!(matches!(store.grant(&expired_id, &otp).await.unwrap(), GrantOutcome::Expired));

          let pending = create_session("deny-me");
          let pending_id = pending.id.clone();
          store.create(pending).await.unwrap();
          assert!(matches!(store.deny(&pending_id).await.unwrap(), DenyOutcome::Denied(_)));
          assert!(matches!(
              store.deny(&pending_id).await.unwrap(),
              DenyOutcome::NotPending(SessionStatus::Denied)
          ));
          assert!(matches!(store.deny("missing").await.unwrap(), DenyOutcome::NotFound));
      }

      #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
      #[ignore]
      async fn redis_sessions_concurrent_grants_apply_once() {
          let _guard = REDIS_LOCK.lock().await;
          let (store, _conn) = store().await;
          let session = create_session("race");
          let (id, otp) = (session.id.clone(), session.otp.clone());
          store.create(session).await.unwrap();
          let handles: Vec<_> = (0..8)
              .map(|_| {
                  let (store, id, otp) = (store.clone(), id.clone(), otp.clone());
                  tokio::spawn(async move { store.grant(&id, &otp).await.unwrap() })
              })
              .collect();
          let mut granted = 0;
          for handle in handles {
              if matches!(handle.await.unwrap(), GrantOutcome::Granted(_)) {
                  granted += 1;
              }
          }
          assert_eq!(granted, 1);
      }
  }
  ```

  Add `pub mod sessions;` to `src/cluster/redis/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::redis::sessions`.

- [ ] **Step 3: implement** above the tests:

  ```rust
  //! Pairing/OTP sessions in Redis (`relay:session:<id>` hash). Grant and
  //! deny are Lua scripts that apply only while the session is pending, so
  //! two concurrent clicks on different replicas can't both apply.

  use std::collections::HashMap;

  use async_trait::async_trait;
  use chrono::{DateTime, Utc};
  use redis::Script;

  use super::{keys, RedisConn};
  use crate::auth::{Session, SessionStatus};
  use crate::cluster::StoreError;
  use crate::session_store::{DenyOutcome, GrantOutcome, SessionBackend};

  /// A pending session stays this long after it expires, so polls still see
  /// `expired` (and grants `410`) as they did before the 60 s sweep.
  pub const PENDING_GRACE_SECS: i64 = 60;

  /// Granted and denied sessions: a week, refreshed on each `?session=` use.
  pub const DECIDED_SESSION_TTL_SECS: i64 = 7 * 24 * 60 * 60;

  // KEYS[1]; ARGV: otp, now_ms, token, decided_ttl
  const GRANT: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
  local status = redis.call('HGET', KEYS[1], 'status')
  if status ~= 'pending' then return {'not_pending', status} end
  if tonumber(ARGV[2]) > tonumber(redis.call('HGET', KEYS[1], 'expires_at_ms')) then
    return {'expired'}
  end
  if redis.call('HGET', KEYS[1], 'otp') ~= ARGV[1] then return {'invalid_otp'} end
  redis.call('HSET', KEYS[1], 'status', 'granted', 'token', ARGV[3])
  redis.call('EXPIRE', KEYS[1], ARGV[4])
  return {'granted'}
  "#;

  // KEYS[1]; ARGV: decided_ttl
  const DENY: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
  local status = redis.call('HGET', KEYS[1], 'status')
  if status ~= 'pending' then return {'not_pending', status} end
  redis.call('HSET', KEYS[1], 'status', 'denied')
  redis.call('EXPIRE', KEYS[1], ARGV[1])
  return {'denied'}
  "#;

  // KEYS[1]; ARGV: decided_ttl
  const TOUCH: &str = r#"
  if redis.call('HGET', KEYS[1], 'status') == 'granted' then
    redis.call('EXPIRE', KEYS[1], ARGV[1])
  end
  return {'1'}
  "#;

  fn status_name(status: &SessionStatus) -> String {
      serde_json::to_value(status)
          .ok()
          .and_then(|value| value.as_str().map(str::to_string))
          .unwrap_or_default()
  }

  fn parse_status(name: &str) -> Option<SessionStatus> {
      serde_json::from_value(serde_json::Value::String(name.to_string())).ok()
  }

  fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
      DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
  }

  fn non_empty(value: Option<&String>) -> Option<String> {
      value.filter(|value| !value.is_empty()).cloned()
  }

  /// How long a session stays in Redis (pre-flight note 2).
  pub fn session_ttl_secs(session: &Session, now: DateTime<Utc>) -> i64 {
      match session.status {
          SessionStatus::Pending => ((session.expires_at - now).num_seconds() + PENDING_GRACE_SECS).max(1),
          _ => DECIDED_SESSION_TTL_SECS,
      }
  }

  fn session_fields(session: &Session) -> Vec<(&'static str, String)> {
      vec![
          ("id", session.id.clone()),
          ("otp", session.otp.clone()),
          ("hostname", session.hostname.clone()),
          ("status", status_name(&session.status)),
          ("token", session.token.clone().unwrap_or_default()),
          ("created_at", session.created_at.to_rfc3339()),
          ("expires_at", session.expires_at.to_rfc3339()),
          ("expires_at_ms", session.expires_at.timestamp_millis().to_string()),
          ("astation_id", session.astation_id.clone().unwrap_or_default()),
      ]
  }

  fn session_from_hash(map: &HashMap<String, String>) -> Option<Session> {
      Some(Session {
          id: map.get("id")?.clone(),
          otp: map.get("otp")?.clone(),
          hostname: map.get("hostname")?.clone(),
          status: parse_status(map.get("status")?)?,
          token: non_empty(map.get("token")),
          created_at: parse_time(map.get("created_at"))?,
          expires_at: parse_time(map.get("expires_at"))?,
          astation_id: non_empty(map.get("astation_id")),
      })
  }

  pub struct RedisSessionBackend {
      conn: RedisConn,
      grant: Script,
      deny: Script,
      touch: Script,
  }

  impl RedisSessionBackend {
      pub fn new(conn: RedisConn) -> Self {
          Self {
              conn,
              grant: Script::new(GRANT),
              deny: Script::new(DENY),
              touch: Script::new(TOUCH),
          }
      }

      async fn write(&self, id: &str, session: &Session) -> Result<(), StoreError> {
          let key = keys::session(id);
          let fields = session_fields(session);
          let ttl = session_ttl_secs(session, Utc::now());
          self.conn
              .run(|mut c| async move {
                  redis::pipe()
                      .atomic()
                      .del(&key)
                      .ignore()
                      .hset_multiple(&key, &fields)
                      .ignore()
                      .expire(&key, ttl)
                      .ignore()
                      .query_async::<()>(&mut c)
                      .await
              })
              .await
      }

      async fn script(&self, script: &Script, id: &str, args: Vec<String>) -> Result<Vec<String>, StoreError> {
          let key = keys::session(id);
          self.conn
              .run(|mut c| async move {
                  let mut invocation = script.prepare_invoke();
                  invocation.key(&key);
                  for arg in &args {
                      invocation.arg(arg);
                  }
                  invocation.invoke_async(&mut c).await
              })
              .await
      }

      async fn load(&self, id: &str) -> Result<Option<Session>, StoreError> {
          let key = keys::session(id);
          let map: HashMap<String, String> = self
              .conn
              .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
              .await?;
          if map.is_empty() {
              return Ok(None);
          }
          session_from_hash(&map)
              .map(Some)
              .ok_or_else(|| StoreError::Unavailable(format!("malformed session {}", crate::relay::mask_code(id))))
      }
  }

  #[async_trait]
  impl SessionBackend for RedisSessionBackend {
      async fn create(&self, session: Session) -> Result<(), StoreError> {
          self.write(&session.id.clone(), &session).await
      }

      async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
          self.load(id).await
      }

      async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
          self.write(id, &session).await
      }

      async fn delete(&self, id: &str) -> Result<(), StoreError> {
          let key = keys::session(id);
          self.conn
              .run(|mut c| async move { redis::cmd("DEL").arg(&key).query_async::<()>(&mut c).await })
              .await
      }

      async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError> {
          let out = self
              .script(
                  &self.grant,
                  id,
                  vec![
                      otp.to_string(),
                      now.timestamp_millis().to_string(),
                      token.to_string(),
                      DECIDED_SESSION_TTL_SECS.to_string(),
                  ],
              )
              .await?;
          Ok(match out.first().map(String::as_str) {
              Some("granted") => match self.load(id).await? {
                  Some(session) => GrantOutcome::Granted(session),
                  None => GrantOutcome::NotFound,
              },
              Some("not_pending") => GrantOutcome::NotPending(
                  out.get(1).and_then(|name| parse_status(name)).unwrap_or(SessionStatus::Expired),
              ),
              Some("expired") => GrantOutcome::Expired,
              Some("invalid_otp") => GrantOutcome::InvalidOtp,
              _ => GrantOutcome::NotFound,
          })
      }

      async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
          let out = self
              .script(&self.deny, id, vec![DECIDED_SESSION_TTL_SECS.to_string()])
              .await?;
          Ok(match out.first().map(String::as_str) {
              Some("denied") => match self.load(id).await? {
                  Some(session) => DenyOutcome::Denied(session),
                  None => DenyOutcome::NotFound,
              },
              Some("not_pending") => DenyOutcome::NotPending(
                  out.get(1).and_then(|name| parse_status(name)).unwrap_or(SessionStatus::Expired),
              ),
              _ => DenyOutcome::NotFound,
          })
      }

      async fn touch(&self, id: &str) -> Result<(), StoreError> {
          let _ = self
              .script(&self.touch, id, vec![DECIDED_SESSION_TTL_SECS.to_string()])
              .await;
          Ok(())
      }

      async fn cleanup_expired(&self) -> Result<(), StoreError> {
          Ok(())
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test` and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): Redis pairing sessions with atomic grant/deny

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 16: `RedisVoiceBackend` and the 64 KB transcript cap

**Files:** create `src/cluster/redis/voice.rs`; modify `src/voice_session.rs`,
`src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `VoiceBackend`, `VoiceSession`, `VoiceSessionState`, `WaitOutcome`,
`ReplyWaiters` (Task 7), `RedisConn`, `keys`.
Produces:
- in `voice_session.rs`: `pub const MAX_VOICE_BUFFER_BYTES: usize = 65_536;`,
  `pub fn tail_within(text: &str, max: usize) -> &str`; `VoiceSession::add_transcription`
  keeps the buffer's total at most `MAX_VOICE_BUFFER_BYTES` by dropping the
  oldest chunks (a single longer chunk keeps its last 64 KB)
- `pub struct RedisVoiceBackend` (`new(RedisConn, ReplyWaiters)`), implementing `VoiceBackend`
- `pub const VOICE_IDLE_SECS: i64 = 60;` `pub const REPLY_TTL_SECS: i64 = 30;`

`relay:voice:<id>` hash: `session_id`, `atem_id`, `channel`, `state`,
`buffer` (JSON array of strings), `has_response`, `response`, `created_at`,
`last_activity`, `request_count`; it expires after 60 s without
transcription, trigger or response (today's inactivity rule). The answer
also goes to `relay:voice:<id>:reply` (30 s) and is published on
`relay:voice-reply:<id>`.

- [ ] **Step 1: write the tests.** In `src/voice_session.rs`'s test module:

  ```rust
  #[test]
  fn transcript_buffer_is_capped_at_64_kb() {
      let mut session = VoiceSession::new("cap".into(), "atem".into(), "ch".into());
      let chunk = "x".repeat(1024);
      for _ in 0..70 {
          session.add_transcription(chunk.clone());
      }
      let total: usize = session.buffer.iter().map(String::len).sum();
      assert!(total <= MAX_VOICE_BUFFER_BYTES);
      assert_eq!(session.buffer.len(), 64);
      session.add_transcription("the latest words".to_string());
      assert_eq!(session.buffer.last().map(String::as_str), Some("the latest words"));

      let mut big = VoiceSession::new("big".into(), "atem".into(), "ch".into());
      big.add_transcription(format!("{}é{}", "a".repeat(70_000), "tail"));
      assert_eq!(big.buffer.len(), 1);
      assert!(big.buffer[0].len() <= MAX_VOICE_BUFFER_BYTES);
      assert!(big.buffer[0].ends_with("étail"));
  }

  #[test]
  fn tail_within_cuts_at_a_character_boundary() {
      assert_eq!(tail_within("hello", 10), "hello");
      assert_eq!(tail_within("hello", 3), "llo");
      assert_eq!(tail_within("日本語", 4), "語");
  }
  ```

  New `src/cluster/redis/voice.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::bus::BusEvent;
      use crate::cluster::redis::bus::RedisBus;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
      use crate::voice_session::VoiceSessionStore;
      use std::sync::Arc;

      /// A replica's voice store plus the bus wiring that wakes its waiters.
      async fn replica(conn: &RedisConn, id: &str) -> (VoiceSessionStore, tokio::task::JoinHandle<()>) {
          let waiters = ReplyWaiters::default();
          let (_bus, mut events, bus_task) = RedisBus::start(conn.clone(), id).await.unwrap();
          let wake = waiters.clone();
          let forward = tokio::spawn(async move {
              while let Some(event) = events.recv().await {
                  if let BusEvent::VoiceReply { session_id, reply } = event {
                      wake.wake(&session_id, &reply);
                  }
              }
          });
          let store = VoiceSessionStore::with_backend(Arc::new(RedisVoiceBackend::new(conn.clone(), waiters)));
          (store, tokio::spawn(async move {
              let _ = forward.await;
              bus_task.abort();
          }))
      }

      #[tokio::test]
      #[ignore]
      async fn redis_voice_session_lifecycle() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let (store, _task) = replica(&conn, "voice-a").await;
          let created = store.create("v-1".into(), "atem-1".into(), "ch".into()).await.unwrap();
          let loaded = store.get("v-1").await.unwrap().unwrap();
          assert_eq!(loaded.session_id, created.session_id);
          assert_eq!(loaded.atem_id, "atem-1");
          assert_eq!(loaded.state, VoiceSessionState::Accumulating);
          assert_eq!(store.increment_requests("v-1").await.unwrap(), Some(1));
          assert_eq!(store.increment_requests("v-1").await.unwrap(), Some(2));
          assert_eq!(store.add_transcription("v-1", "Create".into()).await.unwrap(), Some(()));
          assert_eq!(store.add_transcription("v-1", "a function".into()).await.unwrap(), Some(()));
          assert_eq!(store.trigger("v-1").await.unwrap().as_deref(), Some("Create a function"));
          assert_eq!(store.get_state("v-1").await.unwrap(), Some(VoiceSessionState::Triggered));
          assert_eq!(store.set_response("v-1", "done".into()).await.unwrap(), Some(()));
          let ready = store.get("v-1").await.unwrap().unwrap();
          assert_eq!(ready.state, VoiceSessionState::ResponseReady);
          assert_eq!(ready.response.as_deref(), Some("done"));
          assert_eq!(ready.request_count, 2);
          assert_eq!(store.list_session_ids().await.unwrap(), vec!["v-1".to_string()]);
          assert_eq!(store.get_by_atem("atem-1").await.unwrap().len(), 1);
          assert!(store.get_by_atem("atem-2").await.unwrap().is_empty());
          store.delete("v-1").await.unwrap();
          assert!(store.get("v-1").await.unwrap().is_none());
          assert_eq!(store.trigger("missing").await.unwrap(), None);
          assert_eq!(store.set_response("missing", "x".into()).await.unwrap(), None);
          assert_eq!(store.increment_requests("missing").await.unwrap(), None);
      }

      #[tokio::test]
      #[ignore]
      async fn redis_voice_buffer_is_capped() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let (store, _task) = replica(&conn, "voice-a").await;
          store.create("v-cap".into(), "atem".into(), "ch".into()).await.unwrap();
          let chunk = "x".repeat(1024);
          for _ in 0..70 {
              store.add_transcription("v-cap", chunk.clone()).await.unwrap();
          }
          let session = store.get("v-cap").await.unwrap().unwrap();
          assert_eq!(session.buffer.len(), 64);
          assert!(session.buffer.iter().map(String::len).sum::<usize>() <= MAX_VOICE_BUFFER_BYTES);
      }

      #[tokio::test]
      #[ignore]
      async fn redis_voice_wait_is_answered_across_replicas() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let (one, _t1) = replica(&conn, "voice-1").await;
          let (two, _t2) = replica(&conn, "voice-2").await;
          one.create("v-x".into(), "atem".into(), "ch".into()).await.unwrap();
          one.trigger("v-x").await.unwrap();

          // Answered on replica two while replica one waits.
          let waiting = tokio::spawn({
              let one = one.clone();
              async move { one.wait_reply("v-x", std::time::Duration::from_secs(5)).await.unwrap() }
          });
          tokio::time::sleep(std::time::Duration::from_millis(200)).await;
          two.set_response("v-x", "from two".into()).await.unwrap();
          assert_eq!(waiting.await.unwrap(), WaitOutcome::Reply("from two".into()));

          // An answer that arrived before the wait is found at once.
          one.create("v-early".into(), "atem".into(), "ch".into()).await.unwrap();
          two.set_response("v-early", "early".into()).await.unwrap();
          let started = std::time::Instant::now();
          assert_eq!(
              one.wait_reply("v-early", std::time::Duration::from_secs(5)).await.unwrap(),
              WaitOutcome::Reply("early".into())
          );
          assert!(started.elapsed() < std::time::Duration::from_secs(1));

          // No answer: the wait times out.
          one.create("v-silent".into(), "atem".into(), "ch".into()).await.unwrap();
          let started = std::time::Instant::now();
          assert_eq!(
              one.wait_reply("v-silent", std::time::Duration::from_secs(1)).await.unwrap(),
              WaitOutcome::TimedOut
          );
          assert!(started.elapsed() >= std::time::Duration::from_secs(1));
      }
  }
  ```

  Add `pub mod voice;` to `src/cluster/redis/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test voice` (compile errors).

- [ ] **Step 3: implement.** In `src/voice_session.rs`, add below the imports:

  ```rust
  /// Cap on a voice session's transcript buffer (it was unbounded).
  pub const MAX_VOICE_BUFFER_BYTES: usize = 64 * 1024;

  /// The last `max` bytes of `text`, cut at a character boundary.
  pub fn tail_within(text: &str, max: usize) -> &str {
      if text.len() <= max {
          return text;
      }
      let mut start = text.len() - max;
      while !text.is_char_boundary(start) {
          start += 1;
      }
      &text[start..]
  }
  ```

  and replace `VoiceSession::add_transcription` with:

  ```rust
  /// Add transcription chunk to buffer. The buffer keeps its newest chunks
  /// within MAX_VOICE_BUFFER_BYTES.
  pub fn add_transcription(&mut self, text: String) {
      self.buffer.push(tail_within(&text, MAX_VOICE_BUFFER_BYTES).to_string());
      let mut total: usize = self.buffer.iter().map(String::len).sum();
      while total > MAX_VOICE_BUFFER_BYTES && self.buffer.len() > 1 {
          total -= self.buffer.remove(0).len();
      }
      self.last_activity = Utc::now();
  }
  ```

  Above the tests in `src/cluster/redis/voice.rs`:

  ```rust
  //! Voice sessions in Redis (`relay:voice:<id>` hash). The Atem's answer is
  //! stored in `relay:voice:<id>:reply` (30 s) and published on
  //! `relay:voice-reply:<id>`, which every replica receives through its bus
  //! (pattern subscription) and hands to its local waiters.

  use std::collections::HashMap;
  use std::time::Duration;

  use async_trait::async_trait;
  use chrono::{DateTime, Utc};
  use redis::Script;

  use super::{keys, RedisConn};
  use crate::cluster::StoreError;
  use crate::voice_session::{
      tail_within, ReplyWaiters, VoiceBackend, VoiceSession, VoiceSessionState, WaitOutcome,
      MAX_VOICE_BUFFER_BYTES,
  };

  pub const VOICE_IDLE_SECS: i64 = 60;
  pub const REPLY_TTL_SECS: i64 = 30;

  /// A wait also re-reads the stored answer this often, in case the
  /// pub/sub message was missed during a reconnect.
  const REPLY_POLL: Duration = Duration::from_secs(1);

  // KEYS[1]; ARGV: text, now, cap_bytes, idle_ttl → 1 | 0
  const ADD_TRANSCRIPTION: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
  local buffer = cjson.decode(redis.call('HGET', KEYS[1], 'buffer') or '[]')
  table.insert(buffer, ARGV[1])
  local total = 0
  for i = 1, #buffer do total = total + string.len(buffer[i]) end
  while total > tonumber(ARGV[3]) and #buffer > 1 do
    total = total - string.len(buffer[1])
    table.remove(buffer, 1)
  end
  redis.call('HSET', KEYS[1], 'buffer', cjson.encode(buffer), 'last_activity', ARGV[2])
  redis.call('EXPIRE', KEYS[1], ARGV[4])
  return 1
  "#;

  // KEYS[1]; ARGV: now, idle_ttl → buffer JSON | nil
  const TRIGGER: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return false end
  redis.call('HSET', KEYS[1], 'state', 'Triggered', 'last_activity', ARGV[1])
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  return redis.call('HGET', KEYS[1], 'buffer') or '[]'
  "#;

  // KEYS[1] session, KEYS[2] reply; ARGV: response, now, idle_ttl, reply_ttl, channel → 1 | 0
  const SET_RESPONSE: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
  redis.call('HSET', KEYS[1], 'state', 'ResponseReady', 'response', ARGV[1],
    'has_response', '1', 'last_activity', ARGV[2])
  redis.call('EXPIRE', KEYS[1], ARGV[3])
  redis.call('SET', KEYS[2], ARGV[1], 'EX', ARGV[4])
  redis.call('PUBLISH', ARGV[5], ARGV[1])
  return 1
  "#;

  // KEYS[1] → count | -1
  const INCREMENT: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return -1 end
  return redis.call('HINCRBY', KEYS[1], 'request_count', 1)
  "#;

  fn state_name(state: &VoiceSessionState) -> &'static str {
      match state {
          VoiceSessionState::Accumulating => "Accumulating",
          VoiceSessionState::Triggered => "Triggered",
          VoiceSessionState::ResponseReady => "ResponseReady",
      }
  }

  fn parse_state(name: &str) -> Option<VoiceSessionState> {
      match name {
          "Accumulating" => Some(VoiceSessionState::Accumulating),
          "Triggered" => Some(VoiceSessionState::Triggered),
          "ResponseReady" => Some(VoiceSessionState::ResponseReady),
          _ => None,
      }
  }

  fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
      DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
  }

  fn parse_buffer(raw: &str) -> Vec<String> {
      if raw == "{}" {
          return Vec::new(); // cjson encodes an empty table as an object
      }
      serde_json::from_str(raw).unwrap_or_default()
  }

  fn session_fields(session: &VoiceSession) -> Vec<(&'static str, String)> {
      vec![
          ("session_id", session.session_id.clone()),
          ("atem_id", session.atem_id.clone()),
          ("channel", session.channel.clone()),
          ("state", state_name(&session.state).to_string()),
          ("buffer", serde_json::to_string(&session.buffer).unwrap_or_else(|_| "[]".to_string())),
          ("has_response", if session.response.is_some() { "1" } else { "0" }.to_string()),
          ("response", session.response.clone().unwrap_or_default()),
          ("created_at", session.created_at.to_rfc3339()),
          ("last_activity", session.last_activity.to_rfc3339()),
          ("request_count", session.request_count.to_string()),
      ]
  }

  fn session_from_hash(map: &HashMap<String, String>) -> Option<VoiceSession> {
      Some(VoiceSession {
          session_id: map.get("session_id")?.clone(),
          atem_id: map.get("atem_id")?.clone(),
          channel: map.get("channel")?.clone(),
          state: parse_state(map.get("state")?)?,
          buffer: parse_buffer(map.get("buffer").map(String::as_str).unwrap_or("[]")),
          response: (map.get("has_response").map(String::as_str) == Some("1"))
              .then(|| map.get("response").cloned().unwrap_or_default()),
          created_at: parse_time(map.get("created_at"))?,
          last_activity: parse_time(map.get("last_activity"))?,
          request_count: map.get("request_count").and_then(|v| v.parse().ok()).unwrap_or(0),
      })
  }

  pub struct RedisVoiceBackend {
      conn: RedisConn,
      waiters: ReplyWaiters,
      add_transcription: Script,
      trigger: Script,
      set_response: Script,
      increment: Script,
  }

  impl RedisVoiceBackend {
      pub fn new(conn: RedisConn, waiters: ReplyWaiters) -> Self {
          Self {
              conn,
              waiters,
              add_transcription: Script::new(ADD_TRANSCRIPTION),
              trigger: Script::new(TRIGGER),
              set_response: Script::new(SET_RESPONSE),
              increment: Script::new(INCREMENT),
          }
      }

      async fn eval<T>(&self, script: &Script, keys: Vec<String>, args: Vec<String>) -> Result<T, StoreError>
      where
          T: redis::FromRedisValue + Send,
      {
          self.conn
              .run(|mut c| async move {
                  let mut invocation = script.prepare_invoke();
                  for key in &keys {
                      invocation.key(key);
                  }
                  for arg in &args {
                      invocation.arg(arg);
                  }
                  invocation.invoke_async(&mut c).await
              })
              .await
      }

      async fn stored_reply(&self, session_id: &str) -> Result<Option<String>, StoreError> {
          let key = keys::voice_reply(session_id);
          self.conn
              .run(|mut c| async move { redis::cmd("GET").arg(&key).query_async(&mut c).await })
              .await
      }

      /// Every voice session id (debug endpoints).
      async fn scan_ids(&self) -> Result<Vec<String>, StoreError> {
          self.conn
              .run(|mut c| async move {
                  let mut cursor: u64 = 0;
                  let mut ids = Vec::new();
                  loop {
                      let (next, batch): (u64, Vec<String>) = redis::cmd("SCAN")
                          .arg(cursor)
                          .arg("MATCH")
                          .arg(keys::VOICE_PATTERN)
                          .arg("COUNT")
                          .arg(1000)
                          .query_async(&mut c)
                          .await?;
                      for key in batch {
                          if let Some(escaped) = key.strip_prefix(keys::VOICE_PREFIX) {
                              if !escaped.contains(':') {
                                  ids.push(keys::unpart(escaped));
                              }
                          }
                      }
                      if next == 0 {
                          break;
                      }
                      cursor = next;
                  }
                  ids.sort();
                  Ok(ids)
              })
              .await
      }
  }

  #[async_trait]
  impl VoiceBackend for RedisVoiceBackend {
      async fn create(&self, session: VoiceSession) -> Result<(), StoreError> {
          let key = keys::voice(&session.session_id);
          let reply = keys::voice_reply(&session.session_id);
          let fields = session_fields(&session);
          self.conn
              .run(|mut c| async move {
                  redis::pipe()
                      .atomic()
                      .del(&key)
                      .ignore()
                      .del(&reply)
                      .ignore()
                      .hset_multiple(&key, &fields)
                      .ignore()
                      .expire(&key, VOICE_IDLE_SECS)
                      .ignore()
                      .query_async::<()>(&mut c)
                      .await
              })
              .await
      }

      async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
          let key = keys::voice(session_id);
          let map: HashMap<String, String> = self
              .conn
              .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
              .await?;
          Ok(if map.is_empty() { None } else { session_from_hash(&map) })
      }

      async fn add_transcription(&self, session_id: &str, text: String) -> Result<Option<()>, StoreError> {
          let added: i64 = self
              .eval(
                  &self.add_transcription,
                  vec![keys::voice(session_id)],
                  vec![
                      tail_within(&text, MAX_VOICE_BUFFER_BYTES).to_string(),
                      Utc::now().to_rfc3339(),
                      MAX_VOICE_BUFFER_BYTES.to_string(),
                      VOICE_IDLE_SECS.to_string(),
                  ],
              )
              .await?;
          Ok((added == 1).then_some(()))
      }

      async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
          let buffer: Option<String> = self
              .eval(
                  &self.trigger,
                  vec![keys::voice(session_id)],
                  vec![Utc::now().to_rfc3339(), VOICE_IDLE_SECS.to_string()],
              )
              .await?;
          Ok(buffer.map(|raw| parse_buffer(&raw).join(" ")))
      }

      async fn set_response(&self, session_id: &str, response: String) -> Result<Option<()>, StoreError> {
          let stored: i64 = self
              .eval(
                  &self.set_response,
                  vec![keys::voice(session_id), keys::voice_reply(session_id)],
                  vec![
                      response,
                      Utc::now().to_rfc3339(),
                      VOICE_IDLE_SECS.to_string(),
                      REPLY_TTL_SECS.to_string(),
                      keys::voice_reply_channel(session_id),
                  ],
              )
              .await?;
          if stored != 1 {
              tracing::warn!("Attempted to set response for nonexistent session: {}", session_id);
          }
          Ok((stored == 1).then_some(()))
      }

      async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
          let count: i64 = self
              .eval(&self.increment, vec![keys::voice(session_id)], Vec::new())
              .await?;
          Ok(u32::try_from(count).ok())
      }

      async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError> {
          let key = keys::voice(session_id);
          let state: Option<String> = self
              .conn
              .run(|mut c| async move { redis::cmd("HGET").arg(&key).arg("state").query_async(&mut c).await })
              .await?;
          Ok(state.as_deref().and_then(parse_state))
      }

      async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
          let (key, reply) = (keys::voice(session_id), keys::voice_reply(session_id));
          self.conn
              .run(|mut c| async move {
                  redis::cmd("DEL").arg(&key).arg(&reply).query_async::<()>(&mut c).await
              })
              .await
      }

      async fn cleanup_expired(&self) -> Result<(), StoreError> {
          Ok(())
      }

      async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
          let mut sessions = Vec::new();
          for id in self.scan_ids().await? {
              if let Some(session) = self.get(&id).await? {
                  if session.atem_id == atem_id {
                      sessions.push(session);
                  }
              }
          }
          Ok(sessions)
      }

      async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
          self.scan_ids().await
      }

      async fn wait_reply(&self, session_id: &str, timeout: Duration) -> Result<WaitOutcome, StoreError> {
          // The bus already listens on relay:voice-reply:* (pattern), so
          // registering the waiter is subscribing; it happens before the
          // stored answer is read, so an answer can't slip through between.
          let mut receiver = self.waiters.register(session_id);
          let deadline = tokio::time::Instant::now() + timeout;
          let mut first_check = true;
          loop {
              match self.stored_reply(session_id).await {
                  Ok(Some(reply)) => {
                      self.waiters.prune(session_id);
                      return Ok(WaitOutcome::Reply(reply));
                  }
                  Ok(None) => {}
                  Err(error) if first_check => {
                      self.waiters.prune(session_id);
                      return Err(error);
                  }
                  Err(error) => tracing::debug!("Voice reply poll failed for {}: {}", session_id, error),
              }
              first_check = false;
              let now = tokio::time::Instant::now();
              if now >= deadline {
                  self.waiters.prune(session_id);
                  return Ok(WaitOutcome::TimedOut);
              }
              match tokio::time::timeout((deadline - now).min(REPLY_POLL), &mut receiver).await {
                  Ok(Ok(reply)) => return Ok(WaitOutcome::Reply(reply)),
                  // The waiter was dropped (never in practice): register again, keep polling.
                  Ok(Err(_)) => receiver = self.waiters.register(session_id),
                  Err(_) => {}
              }
          }
      }
  }
  ```

  In `src/cluster/redis/voice.rs`'s tests, `WaitOutcome` and
  `VoiceSessionState` come in through `use super::*;`.

- [ ] **Step 4: run and watch it pass.** `cargo test` (the in-memory cap tests
  pass) and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): Redis voice sessions with cross-replica reply wait; 64 KB buffer cap

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 17: `RedisRtcBackend`

**Files:** create `src/cluster/redis/rtc.rs`; modify `src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `RtcBackend`, `JoinOutcome`, `RtcSession`, `Participant`,
`JoinRtcSessionResponse`, `MAX_RTC_PARTICIPANTS` (Task 8), `RedisConn`, `keys`.
Produces: `pub struct RedisRtcBackend` (`new(RedisConn)`), implementing `RtcBackend`.

`relay:rtc:<id>` hash: `id`, `app_id`, `channel`, `token`, `host_uid`,
`created_at`, `expires_at` (RFC 3339), `participants` (JSON array),
`next_uid`; expires at `expires_at` (4 h). `join` is one Lua script: check
the 8-participant cap, take `next_uid`, append the participant.

- [ ] **Step 1: write the tests** (new `src/cluster/redis/rtc.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
      use crate::rtc_session::RtcSessionStore;
      use std::sync::Arc;

      #[tokio::test]
      #[ignore]
      async fn redis_rtc_create_get_delete() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn.clone())));
          let created = store
              .create("rtc-1".into(), "app".into(), "ch".into(), "tok".into(), 42)
              .await
              .unwrap();
          let loaded = store.get("rtc-1").await.unwrap().unwrap();
          assert_eq!((loaded.app_id.as_str(), loaded.channel.as_str(), loaded.token.as_str()), ("app", "ch", "tok"));
          assert_eq!(loaded.host_uid, 42);
          assert_eq!(loaded.created_at, created.created_at);
          assert_eq!(loaded.uid_counter_value, RTC_FIRST_UID);
          assert!(loaded.participants.is_empty());
          let ttl: i64 = conn
              .run(|mut c| async move { redis::cmd("TTL").arg("relay:rtc:rtc-1").query_async(&mut c).await })
              .await
              .unwrap();
          assert!((4 * 3600 - 10..=4 * 3600).contains(&ttl), "ttl {ttl}");
          let joined = store.join("rtc-1", "Alice".into()).await.unwrap();
          assert_eq!(joined.uid, 1000);
          assert_eq!((joined.app_id.as_str(), joined.token.as_str()), ("app", "tok"));
          let loaded = store.get("rtc-1").await.unwrap().unwrap();
          assert_eq!(loaded.participants.len(), 1);
          assert_eq!(loaded.participants[0].display_name.as_deref(), Some("Alice"));
          assert_eq!(loaded.uid_counter_value, 1001);
          assert!(store.join("missing", "Bob".into()).await.unwrap_err().contains("not found"));
          assert!(store.delete("rtc-1").await.unwrap());
          assert!(!store.delete("rtc-1").await.unwrap());
      }

      #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
      #[ignore]
      async fn redis_rtc_concurrent_joins_hold_the_cap() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn)));
          store.create("rtc-c".into(), "a".into(), "c".into(), "t".into(), 1).await.unwrap();
          let handles: Vec<_> = (0..12)
              .map(|i| {
                  let store = store.clone();
                  tokio::spawn(async move { store.join("rtc-c", format!("User{i}")).await })
              })
              .collect();
          let mut uids = Vec::new();
          let mut full = 0;
          for handle in handles {
              match handle.await.unwrap() {
                  Ok(response) => uids.push(response.uid),
                  Err(error) => {
                      assert!(error.contains("full"), "{error}");
                      full += 1;
                  }
              }
          }
          uids.sort();
          assert_eq!(uids, (1000..1008).collect::<Vec<u32>>());
          assert_eq!(full, 4);
      }
  }
  ```

  Add `pub mod rtc;` to `src/cluster/redis/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::redis::rtc`.

- [ ] **Step 3: implement** above the tests:

  ```rust
  //! RTC sessions in Redis (`relay:rtc:<id>` hash, 4 h). `join` checks the
  //! participant cap and takes the next uid in one script, so concurrent
  //! joins on different replicas can't exceed the cap or share a uid.

  use std::collections::HashMap;

  use async_trait::async_trait;
  use chrono::{DateTime, Utc};
  use redis::Script;

  use super::{keys, RedisConn};
  use crate::cluster::StoreError;
  use crate::rtc_session::{
      JoinOutcome, JoinRtcSessionResponse, Participant, RtcBackend, RtcSession, MAX_RTC_PARTICIPANTS,
  };

  // KEYS[1]; ARGV: name, joined_at, max
  // → {'not_found'} | {'full', count} | {'joined', uid, app_id, channel, token, count}
  const JOIN: &str = r#"
  if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
  local raw = redis.call('HGET', KEYS[1], 'participants') or '[]'
  local participants = cjson.decode(raw)
  if #participants >= tonumber(ARGV[3]) then return {'full', tostring(#participants)} end
  local uid = redis.call('HINCRBY', KEYS[1], 'next_uid', 1) - 1
  table.insert(participants, {uid = uid, display_name = ARGV[1], joined_at = ARGV[2]})
  redis.call('HSET', KEYS[1], 'participants', cjson.encode(participants))
  return {'joined', tostring(uid), redis.call('HGET', KEYS[1], 'app_id'),
    redis.call('HGET', KEYS[1], 'channel'), redis.call('HGET', KEYS[1], 'token'),
    tostring(#participants)}
  "#;

  fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
      DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
  }

  fn parse_participants(raw: &str) -> Vec<Participant> {
      if raw == "{}" {
          return Vec::new(); // cjson encodes an empty table as an object
      }
      serde_json::from_str(raw).unwrap_or_default()
  }

  fn session_from_hash(map: &HashMap<String, String>) -> Option<RtcSession> {
      Some(RtcSession {
          id: map.get("id")?.clone(),
          app_id: map.get("app_id")?.clone(),
          channel: map.get("channel")?.clone(),
          token: map.get("token")?.clone(),
          uid_counter_value: map.get("next_uid")?.parse().ok()?,
          host_uid: map.get("host_uid")?.parse().ok()?,
          created_at: parse_time(map.get("created_at"))?,
          expires_at: parse_time(map.get("expires_at"))?,
          participants: parse_participants(map.get("participants").map(String::as_str).unwrap_or("[]")),
      })
  }

  pub struct RedisRtcBackend {
      conn: RedisConn,
      join: Script,
  }

  impl RedisRtcBackend {
      pub fn new(conn: RedisConn) -> Self {
          Self {
              conn,
              join: Script::new(JOIN),
          }
      }
  }

  #[async_trait]
  impl RtcBackend for RedisRtcBackend {
      async fn create(&self, session: RtcSession) -> Result<(), StoreError> {
          let key = keys::rtc(&session.id);
          let ttl = (session.expires_at - Utc::now()).num_seconds().max(1);
          let fields: Vec<(&str, String)> = vec![
              ("id", session.id.clone()),
              ("app_id", session.app_id.clone()),
              ("channel", session.channel.clone()),
              ("token", session.token.clone()),
              ("host_uid", session.host_uid.to_string()),
              ("created_at", session.created_at.to_rfc3339()),
              ("expires_at", session.expires_at.to_rfc3339()),
              (
                  "participants",
                  serde_json::to_string(&session.participants).unwrap_or_else(|_| "[]".to_string()),
              ),
              ("next_uid", session.uid_counter_value.to_string()),
          ];
          self.conn
              .run(|mut c| async move {
                  redis::pipe()
                      .atomic()
                      .del(&key)
                      .ignore()
                      .hset_multiple(&key, &fields)
                      .ignore()
                      .expire(&key, ttl)
                      .ignore()
                      .query_async::<()>(&mut c)
                      .await
              })
              .await
      }

      async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
          let key = keys::rtc(id);
          let map: HashMap<String, String> = self
              .conn
              .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
              .await?;
          Ok(if map.is_empty() { None } else { session_from_hash(&map) })
      }

      async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError> {
          let key = keys::rtc(id);
          let script = &self.join;
          let args = vec![name.clone(), now.to_rfc3339(), MAX_RTC_PARTICIPANTS.to_string()];
          let out: Vec<String> = self
              .conn
              .run(|mut c| async move {
                  let mut invocation = script.prepare_invoke();
                  invocation.key(&key);
                  for arg in &args {
                      invocation.arg(arg);
                  }
                  invocation.invoke_async(&mut c).await
              })
              .await?;
          let field = |index: usize| out.get(index).cloned().unwrap_or_default();
          Ok(match out.first().map(String::as_str) {
              Some("joined") => {
                  let uid: u32 = field(1)
                      .parse()
                      .map_err(|_| StoreError::Unavailable("malformed RTC uid".to_string()))?;
                  tracing::info!(
                      "User {} joined session {} with UID {} (total participants: {})",
                      name,
                      id,
                      uid,
                      field(5)
                  );
                  JoinOutcome::Joined(JoinRtcSessionResponse {
                      app_id: field(2),
                      channel: field(3),
                      token: field(4),
                      uid,
                      name,
                  })
              }
              Some("full") => {
                  tracing::warn!("Session {} is full ({} participants)", id, field(1));
                  JoinOutcome::Full
              }
              _ => JoinOutcome::NotFound,
          })
      }

      async fn delete(&self, id: &str) -> Result<bool, StoreError> {
          let key = keys::rtc(id);
          let removed: i64 = self
              .conn
              .run(|mut c| async move { redis::cmd("DEL").arg(&key).query_async(&mut c).await })
              .await?;
          Ok(removed > 0)
      }

      async fn cleanup_expired(&self, _now: DateTime<Utc>) -> Result<(), StoreError> {
          Ok(())
      }
  }
  ```

  `RTC_FIRST_UID` in the tests comes from `crate::rtc_session`; add
  `use crate::rtc_session::RTC_FIRST_UID;` to the test module.

- [ ] **Step 4: run and watch it pass.** `cargo test` and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): Redis RTC sessions with atomic capped join

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 18: `RedisRateLimiter`

**Files:** create `src/cluster/redis/ratelimit.rs`; modify `src/cluster/redis/mod.rs`.

**Interfaces.**
Consumes: `SharedRateLimiter`, `RateDecision`, `window_decision` (Task 9).
Produces: `pub struct RedisRateLimiter` (`new(RedisConn)`, `backend_name` = `"redis"`).
Counter `relay:rl:<bucket>:<ip>:<minute>`: `INCR`, then `EXPIRE 120`.

- [ ] **Step 1: write the tests** (new `src/cluster/redis/ratelimit.rs`):

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

      #[tokio::test]
      #[ignore]
      async fn redis_rate_limit_is_a_shared_fixed_window() {
          let _guard = REDIS_LOCK.lock().await;
          let conn = fresh_conn().await;
          let one = RedisRateLimiter::new(conn.clone());
          let two = RedisRateLimiter::new(conn.clone()); // another replica
          let now = 1_699_999_990; // 10 s into its minute
          assert_eq!(one.hit("grant", "203.0.113.5", 2, now).await.unwrap(), RateDecision::Allowed);
          assert_eq!(two.hit("grant", "203.0.113.5", 2, now).await.unwrap(), RateDecision::Allowed);
          assert_eq!(
              one.hit("grant", "203.0.113.5", 2, now).await.unwrap(),
              RateDecision::Limited { retry_after_secs: 50 }
          );
          assert_eq!(one.hit("grant", "203.0.113.6", 2, now).await.unwrap(), RateDecision::Allowed);
          assert_eq!(one.hit("general", "203.0.113.5", 2, now).await.unwrap(), RateDecision::Allowed);
          assert_eq!(one.hit("grant", "203.0.113.5", 2, now + 60).await.unwrap(), RateDecision::Allowed);
          let key = keys::rate("grant", "203.0.113.5", now / 60);
          let ttl: i64 = conn
              .run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
              .await
              .unwrap();
          assert!((1..=120).contains(&ttl), "ttl {ttl}");
      }
  }
  ```

  Add `pub mod ratelimit;` to `src/cluster/redis/mod.rs`.

- [ ] **Step 2: run and watch it fail.**

- [ ] **Step 3: implement** above the tests:

  ```rust
  //! Shared per-IP limits: a fixed one-minute window per bucket and IP.

  use async_trait::async_trait;

  use super::{keys, RedisConn};
  use crate::cluster::ratelimit::{window_decision, RateDecision, SharedRateLimiter};
  use crate::cluster::StoreError;

  /// A window's counter outlives its minute by one more.
  const WINDOW_KEY_TTL_SECS: i64 = 120;

  pub struct RedisRateLimiter {
      conn: RedisConn,
  }

  impl RedisRateLimiter {
      pub fn new(conn: RedisConn) -> Self {
          Self { conn }
      }
  }

  #[async_trait]
  impl SharedRateLimiter for RedisRateLimiter {
      fn backend_name(&self) -> &'static str {
          "redis"
      }

      async fn hit(&self, bucket: &str, ip: &str, limit: u64, now: i64) -> Result<RateDecision, StoreError> {
          let key = keys::rate(bucket, ip, now.div_euclid(60));
          let (count,): (u64,) = self
              .conn
              .run(|mut c| async move {
                  redis::pipe()
                      .atomic()
                      .incr(&key, 1)
                      .expire(&key, WINDOW_KEY_TTL_SECS)
                      .ignore()
                      .query_async(&mut c)
                      .await
              })
              .await?;
          Ok(window_decision(count, limit, now))
      }
  }
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test` and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src/cluster
  git commit -m "feat(relay): Redis fixed-window rate limiter

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 19: mode selection — `connect_cluster` and `main`

**Files:** modify `src/cluster/redis/mod.rs`, `src/main.rs`, `relay-server/.env.example`.

**Interfaces.**
Consumes: everything from Tasks 10–18.
Produces:
- `pub struct RedisCluster { pub relay: RelayHub, pub sessions: SessionStore, pub voice_sessions: VoiceSessionStore, pub rtc_sessions: RtcSessionStore, pub health: RedisHealth, tasks: Vec<JoinHandle<()>> }`
  with `abort(&self)` (stops its background tasks)
- `pub async fn connect_cluster(url: &str, identity: Arc<dyn IdentityStore>, auth_timeout: Duration) -> Result<RedisCluster, StoreError>`
- in `main.rs`: `fn redis_url() -> Option<String>`, `fn replicas_expected() -> usize`,
  `fn check_single_instance(expected_replicas: usize) -> Result<(), String>`

`REDIS_URL` set → Redis versions of every unit. Unset → in-memory, exactly
today's behavior; if `RELAY_REPLICAS_EXPECTED > 1` the relay refuses to start
(exit 1), otherwise it logs a warning that it must run as one replica. A
Redis that can't be reached at startup is retried 10 times, 3 s apart, then
the process exits so the orchestrator restarts it.

- [ ] **Step 1: write the tests.** In `src/main.rs`'s test module:

  ```rust
  #[test]
  fn several_replicas_need_redis() {
      assert!(check_single_instance(1).is_ok());
      let message = check_single_instance(2).unwrap_err();
      assert!(message.contains("RELAY_REPLICAS_EXPECTED=2"), "{message}");
      assert!(message.contains("REDIS_URL"), "{message}");
  }
  ```

  In `src/cluster/redis/mod.rs`'s test module:

  ```rust
  #[tokio::test]
  #[ignore]
  async fn redis_connect_cluster_builds_a_replica() {
      let _guard = REDIS_LOCK.lock().await;
      flush().await;
      let identity: std::sync::Arc<dyn crate::identity_store::IdentityStore> =
          std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new());
      let timeout = std::time::Duration::from_secs(10);
      let one = connect_cluster(&test_url(), identity.clone(), timeout).await.unwrap();
      let two = connect_cluster(&test_url(), identity, timeout).await.unwrap();
      assert_ne!(one.relay.replica_id(), two.relay.replica_id());
      assert_eq!(one.health.refresh().await.unwrap(), 2);
      assert_eq!(one.relay.redis_status().await, "ok");
      assert_eq!(one.relay.replica_count(), 2);
      one.relay.create_room("ROOM-C", "h", 1_700_000_000).await.unwrap();
      assert!(two.relay.room("ROOM-C").await.unwrap().is_some());
      one.abort();
      two.abort();
  }
  ```

- [ ] **Step 2: run and watch it fail.** `cargo test several_replicas`.

- [ ] **Step 3: implement.** Append to `src/cluster/redis/mod.rs` (above
  `test_support`), and add the module declarations
  `pub mod directory; pub mod presence; pub mod ratelimit; pub mod rtc; pub mod sessions; pub mod voice;`
  if an earlier task did not already:

  ```rust
  use std::sync::Arc;

  use tokio::task::JoinHandle;

  use crate::cluster::keys::KeyCache;
  use crate::cluster::local::LocalSockets;
  use crate::cluster::new_replica_id;
  use crate::identity_store::IdentityStore;
  use crate::relay::{HubParts, RelayHub};
  use crate::rtc_session::RtcSessionStore;
  use crate::session_store::SessionStore;
  use crate::voice_session::{ReplyWaiters, VoiceSessionStore};

  /// One relay replica whose shared state lives in Redis.
  pub struct RedisCluster {
      pub relay: RelayHub,
      pub sessions: SessionStore,
      pub voice_sessions: VoiceSessionStore,
      pub rtc_sessions: RtcSessionStore,
      pub health: presence::RedisHealth,
      tasks: Vec<JoinHandle<()>>,
  }

  impl RedisCluster {
      /// Stop this replica's background tasks (bus, dispatcher, presence).
      pub fn abort(&self) {
          for task in &self.tasks {
              task.abort();
          }
      }
  }

  /// Build a replica on Redis: presence, bus subscription, dispatcher,
  /// directory, sessions, voice, RTC and the shared rate limiter.
  pub async fn connect_cluster(
      url: &str,
      identity: Arc<dyn IdentityStore>,
      auth_timeout: Duration,
  ) -> Result<RedisCluster, StoreError> {
      let conn = RedisConn::connect(url).await?;
      let replica_id = new_replica_id();
      let (bus, events, bus_task) = bus::RedisBus::start(conn.clone(), &replica_id).await?;
      let health = presence::RedisHealth::new(conn.clone(), &replica_id);
      health.refresh().await?;
      let waiters = ReplyWaiters::default();
      let relay = RelayHub::from_parts(HubParts {
          replica_id: replica_id.clone(),
          directory: Arc::new(directory::RedisRoomDirectory::new(conn.clone())),
          bus: Arc::new(bus),
          local: LocalSockets::new(),
          keys: KeyCache::new(),
          rate_limiter: Arc::new(ratelimit::RedisRateLimiter::new(conn.clone())),
          health: Arc::new(health.clone()),
          cache_rooms: true,
          auth_timeout,
      });
      let dispatcher = relay.spawn_bus_dispatcher(identity, waiters.clone(), events);
      let presence_task = health.spawn_refresh();
      tracing::info!("Relay replica {} joined the cluster", replica_id);
      Ok(RedisCluster {
          sessions: SessionStore::with_backend(Arc::new(sessions::RedisSessionBackend::new(conn.clone()))),
          voice_sessions: VoiceSessionStore::with_backend(Arc::new(voice::RedisVoiceBackend::new(
              conn.clone(),
              waiters,
          ))),
          rtc_sessions: RtcSessionStore::with_backend(Arc::new(rtc::RedisRtcBackend::new(conn))),
          relay,
          health,
          tasks: vec![bus_task, dispatcher, presence_task],
      })
  }
  ```

  In `src/main.rs`:
  - add after the `AppState` struct:

    ```rust
    fn redis_url() -> Option<String> {
        std::env::var("REDIS_URL").ok().filter(|url| !url.trim().is_empty())
    }

    /// RELAY_REPLICAS_EXPECTED (default 1): how many replicas this deployment runs.
    fn replicas_expected() -> usize {
        std::env::var("RELAY_REPLICAS_EXPECTED")
            .ok()
            .and_then(|value| value.trim().parse().ok())
            .unwrap_or(1)
    }

    /// Without Redis every replica would have its own rooms and sessions.
    fn check_single_instance(expected_replicas: usize) -> Result<(), String> {
        if expected_replicas > 1 {
            return Err(format!(
                "RELAY_REPLICAS_EXPECTED={expected_replicas} but REDIS_URL is not set: \
                 several relay replicas need Redis for shared state. Set REDIS_URL or run one replica."
            ));
        }
        Ok(())
    }

    /// Connect to Redis, retrying for about 30 s, then give up so the
    /// orchestrator restarts the relay.
    async fn connect_redis_cluster(
        url: &str,
        identity: Arc<dyn identity_store::IdentityStore>,
    ) -> cluster::redis::RedisCluster {
        let auth_timeout = std::time::Duration::from_secs(relay::RELAY_AUTH_TIMEOUT_SECS);
        for attempt in 1..=10 {
            match cluster::redis::connect_cluster(url, identity.clone(), auth_timeout).await {
                Ok(cluster) => return cluster,
                Err(error) => {
                    tracing::error!("Redis connect attempt {}/10 failed: {}", attempt, error);
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                }
            }
        }
        tracing::error!("Could not reach REDIS_URL; exiting so the relay is restarted");
        std::process::exit(1);
    }
    ```

  - in `main`, delete the four lines
    `let sessions = SessionStore::new(); let relay = RelayHub::new(); let rtc_sessions = RtcSessionStore::new(); let voice_sessions = VoiceSessionStore::new();`
    (and the comment `// Initialize stores` above them), and insert directly
    after the `let (vault, knowledge, identity) … = match … { … };` block:

    ```rust
    // Rooms, pairing/voice/RTC sessions and rate limits: Redis when
    // REDIS_URL is set (several replicas), else in memory (one replica).
    let (relay, sessions, rtc_sessions, voice_sessions) = match redis_url() {
        Some(url) => {
            tracing::info!("Connecting to Redis for shared relay state...");
            let cluster = connect_redis_cluster(&url, identity.clone()).await;
            tracing::info!(
                "Shared relay state ready (Redis); replica {}",
                cluster.relay.replica_id()
            );
            (
                cluster.relay,
                cluster.sessions,
                cluster.rtc_sessions,
                cluster.voice_sessions,
            )
        }
        None => {
            if let Err(message) = check_single_instance(replicas_expected()) {
                tracing::error!("{}", message);
                std::process::exit(1);
            }
            tracing::warn!(
                "REDIS_URL not set — rooms, pairing/voice/RTC sessions and rate limits are \
                 IN-MEMORY: run exactly ONE relay replica. Set REDIS_URL to run several."
            );
            (
                RelayHub::new(),
                SessionStore::new(),
                RtcSessionStore::new(),
                VoiceSessionStore::new(),
            )
        }
    };
    ```

    The rest of `main` (key loading, sweeps, `AppState`) is unchanged: it
    uses these four bindings. `RedisCluster`'s background tasks keep running
    after the struct is dropped (tokio tasks are detached).

  In `relay-server/.env.example`, append:

  ```bash
  # ============================================
  # Multi-replica (shared relay state)
  # ============================================
  # Redis/Valkey for rooms, pairing/voice/RTC sessions and rate limits.
  # Unset: in-memory, and the relay must run as exactly one replica.
  # REDIS_URL=redis://default:<password>@<valkey-host>:6379
  # How many relay replicas this deployment runs. >1 without REDIS_URL
  # refuses to start.
  # RELAY_REPLICAS_EXPECTED=1
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test`, then the Redis suite.
  Then a manual two-replica smoke run on one machine:

  ```bash
  docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
  REDIS_URL=redis://127.0.0.1:56379/ PORT=3001 CORS_ORIGIN='*' cargo run &
  REDIS_URL=redis://127.0.0.1:56379/ PORT=3002 CORS_ORIGIN='*' cargo run &
  sleep 15
  curl -s localhost:3001/health   # "redis":"ok","replicas":2
  CODE=$(curl -s -XPOST localhost:3001/api/pair -H 'content-type: application/json' -d '{"hostname":"h"}' | sed 's/.*"code":"\([^"]*\)".*/\1/')
  curl -s localhost:3002/api/pair/$CODE   # the room created on 3001
  kill %1 %2; docker rm -f relay-test-valkey
  ```

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src relay-server/.env.example
  git commit -m "feat(relay): REDIS_URL selects the Redis-backed cluster; refuse replicas without it

  🤖 Built with SMT <smt@agora.build>"
  ```

---

## Step 3 — two relays in one process, CI Valkey

All tests in this step live in `src/redis_multi_replica_tests.rs`, are
`#[ignore]`d, and take `REDIS_LOCK`. Replica 1 and replica 2 each reach
Valkey through their own cuttable TCP proxy, so a test can take Redis away
from one replica (or "crash" it) while the other keeps working.

### Task 20: two-relay harness

**Files:** create `src/redis_multi_replica_tests.rs`; modify `src/main.rs`
(module list), `src/relay.rs` (test helpers become `pub(crate)`).

**Interfaces.**
Consumes: `connect_cluster`, `RedisCluster`, `test_support`, relay test helpers.
Produces (test-only): `CutProxy { start(SocketAddr), url(), cut() }`,
`Shared::new()`, `Replica { state, cluster, ws, proxy }` with `id()`,
`crash()`; `two_replicas() -> (Shared, Replica, Replica)`;
`http(&AppState, method, uri, body, headers) -> (StatusCode, serde_json::Value)`;
`eventually(what, check)`; `wait_closed(&mut TestSocket)`;
`expect_close_code(&mut TestSocket) -> u16`; `refused_status(String) -> u16`.

- [ ] **Step 1: expose the relay test helpers.** In `src/relay.rs` change
  `mod tests {` (the `#[cfg(test)]` module) to `pub(crate) mod tests {`, and
  add `pub(crate)` in front of each of these items in it:
  `type TestSocket`, `async fn next_client_json`, `struct TestKey`, and its
  methods `fn generate`, `fn public_hex`, `fn sign_hex`, `fn relay_auth`;
  `const TEST_AUTH_TIMEOUT`, `async fn spawn_relay`, `async fn connect_astation`,
  `async fn connect_atem`, `async fn send_json`, `async fn authenticate`,
  `async fn verified_astation`, `async fn control`, `async fn assert_closed`,
  `async fn assert_silent`.

- [ ] **Step 2: write the harness and its smoke test.** Create
  `src/redis_multi_replica_tests.rs`:

  ```rust
  //! Two relays in one process sharing Valkey, with the Astation and its
  //! Atems deliberately on different replicas (spec: "Testing"). An
  //! in-process identity store, vault and knowledge store stand in for the
  //! shared Postgres (same traits). Every test is #[ignore]d:
  //!
  //!   docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
  //!   TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
  //!   docker rm -f relay-test-valkey

  use std::net::SocketAddr;
  use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
  use std::sync::{Arc, Mutex};
  use std::time::Duration;

  use axum::body::Body;
  use axum::http::{Request, StatusCode};
  use futures_util::StreamExt;
  use tokio::task::JoinHandle;
  use tokio_tungstenite::tungstenite::Message as ClientMessage;
  use tower::ServiceExt;

  use crate::cluster::redis::test_support::{flush, test_url, REDIS_LOCK};
  use crate::cluster::redis::{connect_cluster, RedisCluster};
  use crate::identity_store::{IdentityStore, InMemoryIdentityStore};
  use crate::knowledge_store::{InMemoryKnowledgeStore, KnowledgeStore};
  use crate::relay::tests::{
      assert_closed, assert_silent, authenticate, connect_astation, connect_atem, next_client_json,
      send_json, spawn_relay, verified_astation, TestKey, TestSocket, TEST_AUTH_TIMEOUT,
  };
  use crate::vault_store::{InMemoryVaultStore, VaultStore};
  use crate::AppState;

  /// A TCP forwarder in front of Valkey. `cut()` drops every link and
  /// refuses new ones: that replica loses Redis, the other doesn't.
  struct CutProxy {
      port: u16,
      cut: Arc<AtomicBool>,
      links: Arc<Mutex<Vec<JoinHandle<()>>>>,
      accept: JoinHandle<()>,
  }

  impl CutProxy {
      async fn start(target: SocketAddr) -> Self {
          let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
          let port = listener.local_addr().unwrap().port();
          let cut = Arc::new(AtomicBool::new(false));
          let links: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
          let accept = tokio::spawn({
              let (cut, links) = (cut.clone(), links.clone());
              async move {
                  while let Ok((mut inbound, _)) = listener.accept().await {
                      if cut.load(Ordering::SeqCst) {
                          continue; // dropped: the connection is refused
                      }
                      let link = tokio::spawn(async move {
                          if let Ok(mut outbound) = tokio::net::TcpStream::connect(target).await {
                              let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
                          }
                      });
                      links.lock().unwrap().push(link);
                  }
              }
          });
          Self { port, cut, links, accept }
      }

      fn url(&self) -> String {
          format!("redis://127.0.0.1:{}/", self.port)
      }

      fn cut(&self) {
          self.cut.store(true, Ordering::SeqCst);
          for link in self.links.lock().unwrap().drain(..) {
              link.abort();
          }
      }
  }

  impl Drop for CutProxy {
      fn drop(&mut self) {
          self.accept.abort();
          self.cut();
      }
  }

  /// TEST_REDIS_URL as a socket address (it must carry no credentials).
  fn valkey_addr() -> SocketAddr {
      let url = test_url();
      assert!(!url.contains('@'), "the two-relay tests need TEST_REDIS_URL without credentials");
      let hostport = url
          .trim_start_matches("redis://")
          .split(['/', '?'])
          .next()
          .unwrap_or("")
          .replacen("localhost", "127.0.0.1", 1);
      hostport.parse().expect("TEST_REDIS_URL must look like redis://127.0.0.1:56379/")
  }

  /// The durable stores both replicas share (Postgres in production).
  #[derive(Clone)]
  struct Shared {
      identity: Arc<dyn IdentityStore>,
      vault: Arc<dyn VaultStore>,
      knowledge: Arc<dyn KnowledgeStore>,
  }

  impl Shared {
      fn new() -> Self {
          Self {
              identity: Arc::new(InMemoryIdentityStore::new()),
              vault: Arc::new(InMemoryVaultStore::new()),
              knowledge: Arc::new(InMemoryKnowledgeStore::new()),
          }
      }
  }

  struct Replica {
      state: AppState,
      cluster: RedisCluster,
      /// ws://127.0.0.1:<port>/ws
      ws: String,
      proxy: CutProxy,
      server: JoinHandle<()>,
  }

  impl Replica {
      fn id(&self) -> &str {
          self.state.relay.replica_id()
      }

      /// Crash: Redis goes first (so nothing is cleaned up), then every
      /// socket drops and the replica's tasks stop.
      fn crash(&self) {
          self.proxy.cut();
          self.cluster.abort();
          self.server.abort();
          for connection_id in self.state.relay.local().connection_ids() {
              self.state.relay.local().evict(&connection_id);
          }
      }
  }

  impl Drop for Replica {
      fn drop(&mut self) {
          self.server.abort();
          self.cluster.abort();
      }
  }

  async fn start_replica(shared: &Shared) -> Replica {
      let proxy = CutProxy::start(valkey_addr()).await;
      let cluster = connect_cluster(&proxy.url(), shared.identity.clone(), TEST_AUTH_TIMEOUT)
          .await
          .expect("start replica");
      cluster.relay.load_keys(shared.identity.as_ref()).await.unwrap();
      let state = AppState {
          sessions: cluster.sessions.clone(),
          relay: cluster.relay.clone(),
          rtc_sessions: cluster.rtc_sessions.clone(),
          voice_sessions: cluster.voice_sessions.clone(),
          vault: shared.vault.clone(),
          knowledge: shared.knowledge.clone(),
          identity: shared.identity.clone(),
      };
      let (ws, server) = spawn_relay(state.clone()).await;
      Replica { state, cluster, ws, proxy, server }
  }

  /// A fresh database and two replicas that know each other.
  async fn two_replicas() -> (Shared, Replica, Replica) {
      flush().await;
      let shared = Shared::new();
      let one = start_replica(&shared).await;
      let two = start_replica(&shared).await;
      one.cluster.health.refresh().await.unwrap();
      (shared, one, two)
  }

  static NEXT_IP: AtomicU8 = AtomicU8::new(1);

  /// One HTTP request through a replica's full router.
  async fn http(
      state: &AppState,
      method: &str,
      uri: &str,
      body: &str,
      headers: &[(&str, &str)],
  ) -> (StatusCode, serde_json::Value) {
      let ip = format!("198.51.100.{}", NEXT_IP.fetch_add(1, Ordering::Relaxed));
      let mut request = Request::builder()
          .method(method)
          .uri(uri)
          .header("content-type", "application/json")
          .header("x-forwarded-for", ip);
      for (name, value) in headers {
          request = request.header(*name, *value);
      }
      let response = crate::router(state.clone())
          .oneshot(request.body(Body::from(body.to_string())).unwrap())
          .await
          .unwrap();
      let status = response.status();
      let bytes = axum::body::to_bytes(response.into_body(), usize::MAX).await.unwrap();
      (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
  }

  async fn eventually(what: &str, check: impl Fn() -> bool) {
      for _ in 0..150 {
          if check() {
              return;
          }
          tokio::time::sleep(Duration::from_millis(20)).await;
      }
      panic!("timed out waiting until {what}");
  }

  /// Wait for the socket to close, ignoring any frames before that.
  async fn wait_closed(socket: &mut TestSocket) {
      let closed = tokio::time::timeout(Duration::from_secs(5), async {
          loop {
              match socket.next().await {
                  None | Some(Err(_)) | Some(Ok(ClientMessage::Close(_))) => return,
                  Some(Ok(_)) => {}
              }
          }
      })
      .await;
      assert!(closed.is_ok(), "socket was not closed");
  }

  /// The close code the relay sent (0: closed without one).
  async fn expect_close_code(socket: &mut TestSocket) -> u16 {
      tokio::time::timeout(Duration::from_secs(5), async {
          loop {
              match socket.next().await {
                  Some(Ok(ClientMessage::Close(Some(frame)))) => return u16::from(frame.code),
                  Some(Ok(ClientMessage::Close(None))) | None | Some(Err(_)) => return 0,
                  Some(Ok(_)) => {}
              }
          }
      })
      .await
      .expect("no close within 5 s")
  }

  /// The HTTP status a refused WebSocket upgrade got.
  async fn refused_status(url: String) -> u16 {
      match tokio_tungstenite::connect_async(url).await {
          Err(tokio_tungstenite::tungstenite::Error::Http(response)) => response.status().as_u16(),
          Err(other) => panic!("unexpected connect error: {other}"),
          Ok(_) => panic!("the WebSocket was accepted"),
      }
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_two_replicas_share_rooms() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      assert_ne!(one.id(), two.id());
      let (status, created) = http(&one.state, "POST", "/api/pair", r#"{"hostname":"h"}"#, &[]).await;
      assert_eq!(status, StatusCode::CREATED);
      let code = created["code"].as_str().unwrap().to_string();
      let (status, room) = http(&two.state, "GET", &format!("/api/pair/{code}"), "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(room["hostname"], "h");
      let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(health["redis"], "ok");
      assert_eq!(health["replicas"], 2);
  }
  ```

  In `src/main.rs`, add under the module list:

  ```rust
  #[cfg(test)]
  mod redis_multi_replica_tests;
  ```

  Helpers the later tasks use (`assert_closed`, `assert_silent`,
  `authenticate`, `connect_astation`, `connect_atem`, `next_client_json`,
  `send_json`, `verified_astation`, `TestKey`, `eventually`, `wait_closed`,
  `expect_close_code`, `refused_status`) are defined or imported now; until
  Tasks 21–25 use them the compiler would warn. Make
  `#![allow(unused_imports, dead_code)]` the first line of the file in this
  task; Task 25, Step 1 deletes it (by then every helper is used).

- [ ] **Step 3: run and watch it fail**, then pass once Step 1–2 compile:

  ```bash
  docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
  TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis_multi_replica -- --ignored --test-threads=1
  ```

  (It fails to compile before Step 1 makes the helpers visible.)

- [ ] **Step 4: commit.**

  ```bash
  git add relay-server/src
  git commit -m "test(relay): two-relays-in-one-process harness over Valkey

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 21: rooms and chat across replicas

**Files:** modify `src/redis_multi_replica_tests.rs`.

Covers the spec's list: chat both ways, unicast and broadcast, with order
kept; stale connection ids dropped; pending on replica 1 → verify →
evicting a verified owner on replica 2; two Astations racing for ownership.

- [ ] **Step 1: write the tests** (append):

  ```rust
  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_chat_crosses_replicas_both_ways_in_order() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-cross";
      let key = TestKey::generate();
      let mut astation = verified_astation(&one.ws, code, &key, "registered").await;
      let mut remote_atem = connect_atem(&two.ws, code, "atem-remote").await;
      let connected = next_client_json(&mut astation).await;
      assert_eq!(connected["relay_event"], "connected");
      assert_eq!(connected["atem_id"], "atem-remote");
      let remote_id = connected["connection_id"].as_str().unwrap().to_string();
      let mut local_atem = connect_atem(&one.ws, code, "atem-local").await;
      assert_eq!(next_client_json(&mut astation).await["atem_id"], "atem-local");

      // Atem (replica 2) → Astation (replica 1), order kept.
      for seq in 0..50 {
          send_json(&mut remote_atem, serde_json::json!({ "seq": seq })).await;
      }
      for seq in 0..50 {
          let frame = next_client_json(&mut astation).await;
          assert_eq!(frame["atem_id"], "atem-remote");
          assert_eq!(frame["connection_id"], remote_id.as_str());
          assert_eq!(frame["payload"]["seq"], seq);
      }

      // Astation → one Atem on the other replica, order kept.
      for seq in 0..50 {
          send_json(
              &mut astation,
              serde_json::json!({"atem_id": "atem-remote", "connection_id": remote_id, "payload": {"seq": seq}}),
          )
          .await;
      }
      for seq in 0..50 {
          assert_eq!(next_client_json(&mut remote_atem).await["seq"], seq);
      }
      assert_silent(&mut local_atem, 150).await;

      // Astation → all Atems (one local, one remote).
      send_json(&mut astation, serde_json::json!({"probe": "all"})).await;
      assert_eq!(next_client_json(&mut local_atem).await["probe"], "all");
      assert_eq!(next_client_json(&mut remote_atem).await["probe"], "all");

      // Disconnect notices cross replicas too.
      remote_atem.close(None).await.unwrap();
      let gone = next_client_json(&mut astation).await;
      assert_eq!(gone["relay_event"], "disconnected");
      assert_eq!(gone["connection_id"], remote_id.as_str());
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_stale_connection_ids_are_dropped_across_replicas() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-stale";
      let (mut astation, _challenge) = connect_astation(&one.ws, code).await; // legacy owner
      let mut original = connect_atem(&two.ws, code, "atem-office").await;
      let original_id = next_client_json(&mut astation).await["connection_id"]
          .as_str()
          .unwrap()
          .to_string();
      let mut replacement = connect_atem(&one.ws, code, "atem-office").await;
      let replacement_id = next_client_json(&mut astation).await["connection_id"]
          .as_str()
          .unwrap()
          .to_string();
      assert_ne!(original_id, replacement_id);
      // The original (replica 2) is closed through the bus.
      wait_closed(&mut original).await;

      send_json(
          &mut astation,
          serde_json::json!({"atem_id": "atem-office", "connection_id": original_id, "payload": {"probe": "stale"}}),
      )
      .await;
      assert_silent(&mut replacement, 150).await;
      send_json(
          &mut astation,
          serde_json::json!({"atem_id": "atem-office", "connection_id": replacement_id, "payload": {"probe": "current"}}),
      )
      .await;
      assert_eq!(next_client_json(&mut replacement).await["probe"], "current");
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_pending_on_one_replica_evicts_the_verified_owner_on_the_other() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-move";
      let key = TestKey::generate();
      let mut old = verified_astation(&two.ws, code, &key, "registered").await;
      let mut atem = connect_atem(&one.ws, code, "atem-a").await;
      assert_eq!(next_client_json(&mut old).await["relay_event"], "connected");
      eventually("replica 1 knows the key", || one.state.relay.keys().contains(code)).await;

      let (mut new, challenge) = connect_astation(&one.ws, code).await;
      // Pending: no ownership, no Atem traffic.
      send_json(&mut atem, serde_json::json!({"probe": "while-pending"})).await;
      assert_eq!(next_client_json(&mut old).await["payload"]["probe"], "while-pending");
      assert_silent(&mut new, 150).await;

      let result = authenticate(&mut new, &key, code, &challenge).await;
      assert_eq!(result["status"], "verified", "{result}");
      let connected = next_client_json(&mut new).await;
      assert_eq!(connected["relay_event"], "connected");
      assert_eq!(connected["atem_id"], "atem-a");
      assert_closed(&mut old).await;

      send_json(&mut atem, serde_json::json!({"probe": "to-new-owner"})).await;
      assert_eq!(next_client_json(&mut new).await["payload"]["probe"], "to-new-owner");
      let room = two.state.relay.room(code).await.unwrap().unwrap();
      assert_eq!(room.owner.map(|owner| owner.replica), Some(one.id().to_string()));
      assert!(room.verified);
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_racing_astations_leave_exactly_one_owner() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-race";
      let key = TestKey::generate();
      let mut first_owner = verified_astation(&one.ws, code, &key, "registered").await;
      eventually("replica 2 knows the key", || two.state.relay.keys().contains(code)).await;

      let (mut on_one, challenge_one) = connect_astation(&one.ws, code).await;
      let (mut on_two, challenge_two) = connect_astation(&two.ws, code).await;
      let (result_one, result_two) = tokio::join!(
          authenticate(&mut on_one, &key, code, &challenge_one),
          authenticate(&mut on_two, &key, code, &challenge_two),
      );
      assert_eq!(result_one["status"], "verified");
      assert_eq!(result_two["status"], "verified");

      let owner = one.state.relay.room(code).await.unwrap().unwrap().owner.expect("an owner");
      let (winner, loser) = if owner.replica == one.id() {
          (&mut on_one, &mut on_two)
      } else {
          (&mut on_two, &mut on_one)
      };
      wait_closed(loser).await;
      wait_closed(&mut first_owner).await;

      // The winner owns the room: an Atem on either replica reaches it.
      let mut atem = connect_atem(&two.ws, code, "atem-after-race").await;
      assert_eq!(next_client_json(winner).await["relay_event"], "connected");
      send_json(&mut atem, serde_json::json!({"probe": "winner"})).await;
      assert_eq!(next_client_json(winner).await["payload"]["probe"], "winner");
  }
  ```

- [ ] **Step 2: run.** With Valkey up:
  `TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis_multi_replica -- --ignored --test-threads=1`.
  These tests exercise Tasks 5 and 12–14. If one fails, fix the relay code
  (not the test) and re-run.

- [ ] **Step 3: commit.**

  ```bash
  git add relay-server/src/redis_multi_replica_tests.rs
  git commit -m "test(relay): chat, stale ids, pending takeover and ownership race across replicas

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 22: pairing sessions, voice and RTC across replicas

**Files:** modify `src/redis_multi_replica_tests.rs`.

Covers: pairing create on 1, grant on 2, poll on 1, WebSocket on 2 (and a
double grant on both); a voice wait on 1 answered on 2, the answer arriving
before the wait, and the timeout; concurrent RTC joins across replicas.

- [ ] **Step 1: write the tests** (append):

  ```rust
  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_pairing_session_create_grant_poll_and_websocket_across_replicas() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let (status, created) = http(&one.state, "POST", "/api/sessions", r#"{"hostname":"mac"}"#, &[]).await;
      assert_eq!(status, StatusCode::CREATED);
      let id = created["id"].as_str().unwrap().to_string();
      let otp = created["otp"].as_str().unwrap().to_string();
      let grant_uri = format!("/api/sessions/{id}/grant");
      let grant_body = serde_json::json!({ "otp": otp }).to_string();

      // Two clicks on different replicas: exactly one applies.
      let (on_two, on_one) = tokio::join!(
          http(&two.state, "POST", &grant_uri, &grant_body, &[]),
          http(&one.state, "POST", &grant_uri, &grant_body, &[]),
      );
      let mut statuses = vec![on_two.0, on_one.0];
      statuses.sort();
      assert_eq!(statuses, vec![StatusCode::OK, StatusCode::CONFLICT]);

      let (status, polled) = http(&one.state, "GET", &format!("/api/sessions/{id}/status"), "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(polled["status"], "granted");
      assert_eq!(polled["token"].as_str().map(str::len), Some(64));

      let (_atem, _) = tokio_tungstenite::connect_async(format!("{}?session={id}&atem_id=atem-s", two.ws))
          .await
          .expect("session WebSocket on replica 2");
      let code = format!("session-{id}");
      let mut seen = false;
      for _ in 0..100 {
          if let Some(room) = one.state.relay.room(&code).await.unwrap() {
              if room.atems.contains_key("atem-s") {
                  seen = true;
                  break;
              }
          }
          tokio::time::sleep(Duration::from_millis(20)).await;
      }
      assert!(seen, "replica 1 sees the Atem that connected to replica 2");
  }

  async fn voice_session(replica: &Replica) -> String {
      let (status, created) = http(
          &replica.state,
          "POST",
          "/api/voice-sessions",
          r#"{"atem_id":"atem-v","channel":"ch"}"#,
          &[],
      )
      .await;
      assert_eq!(status, StatusCode::OK);
      created["session_id"].as_str().unwrap().to_string()
  }

  async fn llm_chat(state: &AppState, id: &str) -> (StatusCode, serde_json::Value) {
      http(
          state,
          "POST",
          &format!("/api/llm/chat?session_id={id}"),
          r#"{"messages":[{"role":"user","content":"go"}]}"#,
          &[],
      )
      .await
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_voice_wait_on_one_replica_is_answered_on_the_other() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;

      // Waiting on 1, answered on 2.
      let id = voice_session(&one).await;
      let (status, _) = http(&one.state, "POST", &format!("/api/voice-sessions/{id}/trigger"), "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      let waiting = tokio::spawn({
          let state = one.state.clone();
          let id = id.clone();
          async move { llm_chat(&state, &id).await }
      });
      tokio::time::sleep(Duration::from_millis(300)).await;
      let answer = serde_json::json!({"session_id": id, "response": "done on two"}).to_string();
      let (status, _) = http(&two.state, "POST", "/api/voice-sessions/response", &answer, &[]).await;
      assert_eq!(status, StatusCode::OK);
      let (status, body) = waiting.await.unwrap();
      assert_eq!(status, StatusCode::OK);
      assert_eq!(body["choices"][0]["message"]["content"], "done on two");

      // The answer arrives before anyone waits.
      let early = voice_session(&one).await;
      http(&one.state, "POST", &format!("/api/voice-sessions/{early}/trigger"), "", &[]).await;
      let answer = serde_json::json!({"session_id": early, "response": "early"}).to_string();
      http(&two.state, "POST", "/api/voice-sessions/response", &answer, &[]).await;
      assert_eq!(
          one.state.voice_sessions.wait_reply(&early, Duration::from_secs(5)).await.unwrap(),
          crate::voice_session::WaitOutcome::Reply("early".to_string())
      );
      let (status, body) = llm_chat(&one.state, &early).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(body["choices"][0]["message"]["content"], "early");

      // Nobody answers: the wait times out (the handler's 30 s is the same
      // wait with LLM_WAIT_SECS; see llm_proxy::test_triggered_times_out_with_504).
      let silent = voice_session(&one).await;
      http(&one.state, "POST", &format!("/api/voice-sessions/{silent}/trigger"), "", &[]).await;
      assert_eq!(
          one.state.voice_sessions.wait_reply(&silent, Duration::from_secs(1)).await.unwrap(),
          crate::voice_session::WaitOutcome::TimedOut
      );
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_concurrent_rtc_joins_across_replicas_hold_the_cap() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let (status, created) = http(
          &one.state,
          "POST",
          "/api/rtc-sessions",
          r#"{"app_id":"app","channel":"ch","token":"tok","host_uid":1}"#,
          &[],
      )
      .await;
      assert_eq!(status, StatusCode::CREATED);
      let id = created["id"].as_str().unwrap().to_string();
      let joins: Vec<_> = (0..12)
          .map(|i| {
              let state = if i % 2 == 0 { one.state.clone() } else { two.state.clone() };
              let id = id.clone();
              tokio::spawn(async move { state.rtc_sessions.join(&id, format!("user-{i}")).await })
          })
          .collect();
      let mut uids = Vec::new();
      let mut full = 0;
      for join in joins {
          match join.await.unwrap() {
              Ok(response) => uids.push(response.uid),
              Err(error) => {
                  assert!(error.contains("full"), "{error}");
                  full += 1;
              }
          }
      }
      uids.sort();
      assert_eq!(uids, (1000..1008).collect::<Vec<u32>>());
      assert_eq!(full, 4);
      let (status, _) = http(&two.state, "GET", &format!("/api/rtc-sessions/{id}"), "", &[]).await;
      assert_eq!(status, StatusCode::OK);
  }
  ```

- [ ] **Step 2: run** (as in Task 21, Step 2) and fix relay code on failure.

- [ ] **Step 3: commit.**

  ```bash
  git add relay-server/src/redis_multi_replica_tests.rs
  git commit -m "test(relay): pairing, voice and RTC sessions across replicas

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 23: a replica crashing, and Redis going away

**Files:** modify `src/redis_multi_replica_tests.rs`.

Covers: killing a replica (clients reconnect, rooms recover); Redis down
(503s and a failing `/health`, while vault and memory keep working).

- [ ] **Step 1: write the tests** (append):

  ```rust
  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_a_crashed_replica_is_recovered_by_reconnecting_clients() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-crash";
      let key = TestKey::generate();
      let mut astation = verified_astation(&one.ws, code, &key, "registered").await;
      let mut atem = connect_atem(&two.ws, code, "atem-a").await;
      assert_eq!(next_client_json(&mut astation).await["relay_event"], "connected");
      eventually("replica 2 knows the key", || two.state.relay.keys().contains(code)).await;

      one.crash();
      wait_closed(&mut astation).await;

      // The Astation reconnects to the healthy replica; its promotion
      // replaces the owner entry the dead replica left behind.
      let mut astation = verified_astation(&two.ws, code, &key, "verified").await;
      let connected = next_client_json(&mut astation).await;
      assert_eq!(connected["relay_event"], "connected");
      assert_eq!(connected["atem_id"], "atem-a");
      send_json(&mut atem, serde_json::json!({"probe": "after-crash"})).await;
      assert_eq!(next_client_json(&mut astation).await["payload"]["probe"], "after-crash");
      send_json(&mut astation, serde_json::json!({"probe": "to-atem"})).await;
      assert_eq!(next_client_json(&mut atem).await["probe"], "to-atem");

      let (status, pair) = http(&two.state, "GET", &format!("/api/pair/{code}"), "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(pair["astation_connected"], true);
      assert_eq!(pair["paired"], true);
  }

  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_down_means_503s_but_vault_and_memory_keep_working() {
      let _guard = REDIS_LOCK.lock().await;
      let (shared, one, two) = two_replicas().await;
      let now = chrono::Utc::now().timestamp();
      shared.identity.bind("sess-down", "astation-down", now).await.unwrap();

      one.proxy.cut();

      for (method, uri, body) in [
          ("POST", "/api/pair", r#"{"hostname":"h"}"#),
          ("POST", "/api/sessions", r#"{"hostname":"h"}"#),
          ("POST", "/api/rtc-sessions", r#"{"app_id":"a","channel":"c","token":"t","host_uid":1}"#),
          ("POST", "/api/voice-sessions", r#"{"atem_id":"a","channel":"c"}"#),
      ] {
          let (status, _) = http(&one.state, method, uri, body, &[]).await;
          assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{method} {uri}");
      }
      let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
      assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
      assert_eq!(health["redis"], "unavailable");
      assert_eq!(
          refused_status(format!("{}?role=astation&code=astation-down", one.ws)).await,
          503
      );

      // Vault and Atem Memory only need Postgres.
      let auth = [("authorization", "session sess-down")];
      let (status, _) = http(&one.state, "POST", "/api/vault?id=atem-a", r#"{"summary":"x"}"#, &auth).await;
      assert_eq!(status, StatusCode::OK);
      let (status, _) = http(&one.state, "GET", "/api/memory?id=atem-a", "", &auth).await;
      assert_eq!(status, StatusCode::OK);

      // The other replica is unaffected.
      let (status, health) = http(&two.state, "GET", "/health", "", &[]).await;
      assert_eq!(status, StatusCode::OK);
      assert_eq!(health["redis"], "ok");
  }
  ```

- [ ] **Step 2: run** (as in Task 21, Step 2) and fix relay code on failure.

- [ ] **Step 3: commit.**

  ```bash
  git add relay-server/src/redis_multi_replica_tests.rs
  git commit -m "test(relay): replica crash recovery and Redis outage behavior

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 24: CI runs the Valkey suites

**Files:** modify `.github/workflows/ci.yml`.

The Postgres `#[ignore]` suites are not run in CI today and stay that way.

- [ ] **Step 1: edit the `test-relay-server` job.** Add a `services:` block
  between `runs-on: ubuntu-latest` and `steps:`:

  ```yaml
      services:
        valkey:
          image: valkey/valkey:8
          ports:
            - 56379:6379
          options: >-
            --health-cmd "valkey-cli ping"
            --health-interval 5s
            --health-timeout 3s
            --health-retries 10
  ```

  and, after the `Run relay server tests` step, add:

  ```yaml
        - name: Run relay Redis (Valkey) suites
          working-directory: relay-server
          env:
            TEST_REDIS_URL: redis://127.0.0.1:56379/
          run: cargo test redis -- --ignored --test-threads=1
  ```

- [ ] **Step 2: check it.** Push the branch and open a draft PR (or run
  `gh workflow run ci.yml` on the branch); the `Relay Server Tests` job must
  show both steps green and the Redis step must list the
  `redis_multi_replica_tests::…`, `cluster::redis::…` tests as `ok`, not
  `ignored`.

- [ ] **Step 3: commit.**

  ```bash
  git add .github/workflows/ci.yml
  git commit -m "ci(relay): run the Valkey-backed relay suites

  🤖 Built with SMT <smt@agora.build>"
  ```

---

## Step 4 — SIGTERM drain, `admin forget-key`

(`/health`'s `redis` and `replicas` fields already landed in Task 11.)

### Task 25: SIGTERM drain

**Files:** modify `src/relay.rs`, `src/main.rs`, `src/redis_multi_replica_tests.rs`.

**Interfaces.**
Produces:
- `pub(crate) const CLOSE_SERVICE_RESTART: u16 = 1012;` `pub const DRAIN_GRACE: Duration` (5 s)
- `RelayHub::is_draining(&self) -> bool`, `RelayHub::drain(&self, grace: Duration)`
- `ws_handler` answers 503 while draining; `/health` answers
  503 `{"status":"draining"}` while draining.

Drain order (spec): 1. fail `/health` (and refuse new sockets); 2. close
local sockets with 1012 ("service restart"); 3. each socket's own cleanup
removes its directory entry (waited for, up to `grace`), then the presence
key is deleted; 4. the server finishes in-flight HTTP requests and exits.

- [ ] **Step 1: write the tests.** In `src/relay.rs`'s test module:

  ```rust
  async fn close_code(socket: &mut TestSocket) -> u16 {
      tokio::time::timeout(std::time::Duration::from_secs(5), async {
          loop {
              match socket.next().await {
                  Some(Ok(ClientMessage::Close(Some(frame)))) => return u16::from(frame.code),
                  Some(Ok(ClientMessage::Close(None))) | None | Some(Err(_)) => return 0,
                  Some(Ok(_)) => {}
              }
          }
      })
      .await
      .expect("no close within 5 s")
  }

  #[tokio::test]
  async fn drain_closes_sockets_with_1012_and_empties_the_room() {
      let state = memory_identity_state();
      let (base_url, server) = spawn_relay(state.clone()).await;
      let code = "astation-drain";
      let (mut astation, _challenge) = connect_astation(&base_url, code).await;
      let mut atem = connect_atem(&base_url, code, "atem-a").await;
      assert_eq!(next_client_json(&mut astation).await["relay_event"], "connected");

      state.relay.drain(std::time::Duration::from_secs(5)).await;

      assert_eq!(close_code(&mut atem).await, 1012);
      assert_eq!(close_code(&mut astation).await, 1012);
      assert!(state.relay.room(code).await.unwrap().is_none(), "entries removed");
      assert!(state.relay.local().is_empty());

      let response = crate::router(state.clone())
          .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
          .await
          .unwrap();
      assert_eq!(response.status(), HttpStatusCode::SERVICE_UNAVAILABLE);
      let body = axum::body::to_bytes(response.into_body(), usize::MAX).await.unwrap();
      assert_eq!(body.as_ref(), br#"{"status":"draining"}"#);

      match tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code=late")).await {
          Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
              assert_eq!(response.status().as_u16(), 503)
          }
          other => panic!("a draining relay accepted a socket: {:?}", other.map(|_| ())),
      }
      server.abort();
  }
  ```

  In `src/redis_multi_replica_tests.rs`, delete the first line
  `#![allow(unused_imports, dead_code)]` and append:

  ```rust
  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_drain_closes_with_1012_and_removes_entries_and_presence() {
      let _guard = REDIS_LOCK.lock().await;
      let (_shared, one, two) = two_replicas().await;
      let code = "astation-drain";
      let (mut astation, _challenge) = connect_astation(&two.ws, code).await;
      let mut atem = connect_atem(&one.ws, code, "atem-a").await;
      let atem_id = next_client_json(&mut astation).await["connection_id"]
          .as_str()
          .unwrap()
          .to_string();

      one.state.relay.drain(Duration::from_secs(5)).await;

      assert_eq!(expect_close_code(&mut atem).await, 1012);
      let gone = next_client_json(&mut astation).await;
      assert_eq!(gone["relay_event"], "disconnected");
      assert_eq!(gone["connection_id"], atem_id.as_str());
      assert!(two.state.relay.room(code).await.unwrap().unwrap().atems.is_empty());
      assert_eq!(two.cluster.health.refresh().await.unwrap(), 1, "presence withdrawn");

      let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
      assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
      assert_eq!(health["status"], "draining");
      assert_eq!(refused_status(format!("{}?role=astation&code=x", one.ws)).await, 503);
  }
  ```

- [ ] **Step 2: run and watch it fail.** `cargo test drain` (compile error).

- [ ] **Step 3: implement** in `src/relay.rs`:
  - imports: extend `use std::sync::atomic::{AtomicU64, Ordering};` to
    `use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};`;
  - constants, after `MAX_PENDING_ASTATIONS_PER_ROOM`:

    ```rust
    /// Close code on drain (RFC 6455 "service restart"): reconnect elsewhere.
    pub(crate) const CLOSE_SERVICE_RESTART: u16 = 1012;

    /// How long a drain waits for its sockets to leave their rooms.
    pub const DRAIN_GRACE: Duration = Duration::from_secs(5);
    ```

  - `HubInner` gains `draining: AtomicBool,` and `active_sockets: AtomicUsize,`;
    `from_parts` sets `draining: AtomicBool::new(false), active_sockets: AtomicUsize::new(0),`;
  - add after `impl Default for RelayHub`:

    ```rust
    /// Counts a live `handle_ws` so a drain can wait for every socket to
    /// leave its room.
    struct ActiveSocket(RelayHub);

    impl ActiveSocket {
        fn new(hub: &RelayHub) -> Self {
            hub.inner.active_sockets.fetch_add(1, Ordering::SeqCst);
            Self(hub.clone())
        }
    }

    impl Drop for ActiveSocket {
        fn drop(&mut self) {
            self.0.inner.active_sockets.fetch_sub(1, Ordering::SeqCst);
        }
    }
    ```

  - add to `impl RelayHub`:

    ```rust
    pub fn is_draining(&self) -> bool {
        self.inner.draining.load(Ordering::SeqCst)
    }

    /// SIGTERM: refuse new sockets and fail /health, close every local
    /// socket with 1012, wait (up to `grace`) until they have left their
    /// rooms, then withdraw this replica's presence.
    pub async fn drain(&self, grace: Duration) {
        self.inner.draining.store(true, Ordering::SeqCst);
        let connection_ids = self.inner.local.connection_ids();
        tracing::info!("Draining {} relay socket(s)", connection_ids.len());
        for connection_id in &connection_ids {
            self.inner
                .local
                .close_with(connection_id, CLOSE_SERVICE_RESTART, "relay restarting");
        }
        let deadline = Instant::now() + grace;
        while self.inner.active_sockets.load(Ordering::SeqCst) > 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        if let Err(error) = self.inner.health.withdraw().await {
            tracing::warn!("Could not withdraw replica presence: {}", error);
        }
    }
    ```

  - at the top of `ws_handler`, before `let hub = state.relay.clone();`:

    ```rust
    if state.relay.is_draining() {
        return (StatusCode::SERVICE_UNAVAILABLE, "Relay is restarting, reconnect").into_response();
    }
    ```

  - in `handle_ws`: add `let _active = ActiveSocket::new(&hub);` as the first
    statement (before the `socket_role` match); after
    `let outbox = local.register(…);` add
    `let mut reader_close = outbox.close.clone();`; before the read `loop {`
    add `let mut watch_close = true;`; and replace

    ```rust
          let msg_result = match tokio::time::timeout(wait, ws_stream.next()).await {
    ```

    with

    ```rust
          let next = tokio::select! {
              biased;
              changed = reader_close.changed(), if watch_close => {
                  match changed {
                      // Closed with a code (drain, overload): let the
                      // writer send the close frame, then leave.
                      Ok(()) if reader_close.borrow().is_some() => {
                          flush_writer = true;
                          break;
                      }
                      Ok(()) => continue,
                      // Evicted (no code): keep reading until the client goes.
                      Err(_) => {
                          watch_close = false;
                          continue;
                      }
                  }
              }
              next = tokio::time::timeout(wait, ws_stream.next()) => next,
          };
          let msg_result = match next {
    ```

  In `src/main.rs`:
  - at the top of `health_handler` add:

    ```rust
    if state.relay.is_draining() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({ "status": "draining" })),
        );
    }
    ```

  - add:

    ```rust
    /// SIGTERM (docker stop, Coolify redeploy) or Ctrl-C.
    async fn shutdown_signal() {
        let ctrl_c = async {
            let _ = tokio::signal::ctrl_c().await;
        };
        #[cfg(unix)]
        let terminate = async {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(mut signal) => {
                    signal.recv().await;
                }
                Err(error) => {
                    tracing::error!("Could not listen for SIGTERM: {}", error);
                    std::future::pending::<()>().await;
                }
            }
        };
        #[cfg(not(unix))]
        let terminate = std::future::pending::<()>();
        tokio::select! {
            _ = ctrl_c => {}
            _ = terminate => {}
        }
    }
    ```

  - in `main`, replace `let app = router(state);` with

    ```rust
    let shutdown_hub = state.relay.clone();
    let app = router(state);
    ```

    and the final `axum::serve(…).await.expect("Server error");` with:

    ```rust
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        shutdown_signal().await;
        tracing::info!("Shutdown signal received: draining relay sockets");
        shutdown_hub.drain(relay::DRAIN_GRACE).await;
    })
    .await
    .expect("Server error");
    tracing::info!("Relay stopped");
    ```

- [ ] **Step 4: run and watch it pass.** `cargo test`, the Redis suite, and
  a manual check: `cargo run`, connect a socket
  (`websocat 'ws://localhost:3000/ws?role=astation&code=x'`), send SIGTERM
  (`kill -TERM <pid>`): the client sees close code 1012 and the process exits.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): SIGTERM drain — fail /health, close 1012, leave rooms, withdraw presence

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 26: `station-relay-server admin forget-key <astation_id>`

**Files:** create `src/admin.rs`; modify `src/identity_store.rs`,
`src/main.rs`, `src/relay.rs` (one test line), `src/redis_multi_replica_tests.rs`.

**Interfaces.**
Produces:
- `IdentityStore::delete_key(&self, astation_id: &str) -> Result<bool, IdentityError>`
  (in-memory and Postgres; bindings are kept). It has a default body that
  returns an error, so the test doubles (`FlakyIdentity` in `relay.rs`,
  `FailingIdentity` in `vault_routes.rs`, `DownStore` in `cluster/keys.rs`)
  and any double the concurrent Atem Memory branch adds keep compiling
  unchanged.
- `admin::USAGE`, `#[derive(Debug, PartialEq, Eq)] pub struct ForgetOutcome { pub deleted: bool, pub announced: bool }`,
  `pub async fn forget_key(&dyn IdentityStore, Option<&dyn ReplicaBus>, &str) -> Result<ForgetOutcome, String>`,
  `pub async fn main(args: &[String]) -> i32`
- `main()` dispatches `admin …` before starting the server.

`forget-key` deletes the key in Postgres (`DATABASE_URL`, required) and
publishes `key-changed` on `relay:broadcast` (`REDIS_URL`, optional). Every
replica re-reads the key, finds none, and drops it at once, so the old key
stops verifying without a restart. Without `REDIS_URL` it prints that the
relay must be restarted.

- [ ] **Step 1: write the tests.**

  In `src/identity_store.rs`'s `scenarios` module add:

  ```rust
  pub async fn delete_key_removes_only_that_key(s: &dyn IdentityStore) {
      s.register_key_if_absent(A, KEY1, T0).await.unwrap();
      s.register_key_if_absent(B, KEY2, T0).await.unwrap();
      s.bind("s1", A, T0).await.unwrap();
      assert!(s.delete_key(A).await.unwrap());
      assert!(!s.delete_key(A).await.unwrap());
      assert_eq!(s.get_key(A).await.unwrap(), None);
      assert_eq!(s.get_key(B).await.unwrap().as_deref(), Some(KEY2));
      // An admin reset keeps bindings.
      assert_eq!(s.resolve("s1", T0 + 1).await.unwrap().as_deref(), Some(A));
      // The next key registers.
      assert_eq!(
          s.register_key_if_absent(A, KEY2, T0 + 2).await.unwrap(),
          RegisterOutcome::Registered
      );
  }
  ```

  and add `delete_key_removes_only_that_key,` to both the `mem_tests!(…)` and
  the `pg_tests!(…)` lists.

  New `src/admin.rs` with its tests:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::cluster::bus::LoopbackBus;
      use crate::cluster::local::LocalSockets;
      use crate::identity_store::InMemoryIdentityStore;

      #[tokio::test]
      async fn forget_key_deletes_and_announces() {
          let identity = InMemoryIdentityStore::new();
          identity.register_key_if_absent("astation-a", "04aa", 1).await.unwrap();
          let bus = LoopbackBus::new("admin", LocalSockets::new());
          assert_eq!(
              forget_key(&identity, Some(&bus), "astation-a").await.unwrap(),
              ForgetOutcome { deleted: true, announced: true }
          );
          assert_eq!(identity.get_key("astation-a").await.unwrap(), None);
          assert_eq!(
              forget_key(&identity, None, "astation-a").await.unwrap(),
              ForgetOutcome { deleted: false, announced: false }
          );
      }

      #[tokio::test]
      async fn bad_arguments_print_usage() {
          assert_eq!(main(&[]).await, 2);
          assert_eq!(main(&["forget-key".to_string()]).await, 2);
          assert_eq!(main(&["drop-everything".to_string(), "x".to_string()]).await, 2);
      }
  }
  ```

  In `src/redis_multi_replica_tests.rs` append:

  ```rust
  #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
  #[ignore]
  async fn redis_forget_key_and_registration_reach_both_replicas() {
      let _guard = REDIS_LOCK.lock().await;
      let (shared, one, two) = two_replicas().await;
      let code = "astation-forget";
      let old_key = TestKey::generate();
      let owner = verified_astation(&one.ws, code, &old_key, "registered").await;
      eventually("both replicas know the key", || {
          one.state.relay.keys().contains(code) && two.state.relay.keys().contains(code)
      })
      .await;

      let admin_conn = crate::cluster::redis::RedisConn::connect(&test_url()).await.unwrap();
      let publisher = crate::cluster::redis::bus::RedisBus::publisher(admin_conn, "admin");
      let outcome = crate::admin::forget_key(shared.identity.as_ref(), Some(&publisher), code)
          .await
          .unwrap();
      assert_eq!(outcome, crate::admin::ForgetOutcome { deleted: true, announced: true });
      eventually("both replicas dropped the key", || {
          !one.state.relay.keys().contains(code) && !two.state.relay.keys().contains(code)
      })
      .await;
      drop(owner);

      // A new key registers on replica 2 and reaches replica 1.
      let new_key = TestKey::generate();
      let _new_owner = verified_astation(&two.ws, code, &new_key, "registered").await;
      let expected = new_key.public_hex();
      eventually("replica 1 learned the new key", || {
          one.state.relay.keys().get(code).map(|cached| cached.public_key) == Some(expected.clone())
      })
      .await;

      // The old key is refused on replica 1 at once, without a restart.
      let (mut old, challenge) = connect_astation(&one.ws, code).await;
      let result = authenticate(&mut old, &old_key, code, &challenge).await;
      assert_eq!(result["status"], "rejected", "{result}");
  }
  ```

- [ ] **Step 2: run and watch it fail.** `cargo test admin` (compile error).

- [ ] **Step 3: implement.**

  `src/identity_store.rs`:
  - in `trait IdentityStore`, after `list_keys`, add:

    ```rust
    /// Admin reset: delete the registered key (bindings are kept). Returns
    /// whether a key was deleted. Stores that can't delete keep the default.
    async fn delete_key(&self, _astation_id: &str) -> Result<bool, IdentityError> {
        Err(IdentityError::Db("this identity store cannot delete keys".to_string()))
    }
    ```

  - delete the test-only inherent `InMemoryIdentityStore::delete_key`
    (the `/// Test stand-in for the admin reset …` function);
  - in `impl IdentityStore for InMemoryIdentityStore` add:

    ```rust
    async fn delete_key(&self, astation_id: &str) -> Result<bool, IdentityError> {
        Ok(self.state.lock().await.keys.remove(astation_id).is_some())
    }
    ```

  - in `impl IdentityStore for PgIdentityStore` add:

    ```rust
    async fn delete_key(&self, astation_id: &str) -> Result<bool, IdentityError> {
        let result = sqlx::query("DELETE FROM astation_keys WHERE astation_id = $1")
            .bind(astation_id)
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        Ok(result.rows_affected() > 0)
    }
    ```

  `src/relay.rs` tests: in `admin_reset_is_picked_up_on_key_mismatch`
  change `flaky.inner.delete_key(code).await;` to
  `flaky.inner.delete_key(code).await.unwrap();` (it now calls the trait
  method, which returns a `Result`).

  Above the tests in `src/admin.rs`:

  ```rust
  //! Operator commands: `station-relay-server admin <command>` (runbook:
  //! DEPLOY.md, "Admin reset").

  use crate::cluster::bus::{BroadcastMessage, ReplicaBus};
  use crate::cluster::redis::bus::RedisBus;
  use crate::cluster::redis::RedisConn;
  use crate::identity_store::{IdentityStore, PgIdentityStore};

  pub const USAGE: &str = "usage: station-relay-server admin forget-key <astation_id>\n\
  \n\
  Deletes the Astation's registered relay key (DATABASE_URL, required) and\n\
  announces it on relay:broadcast (REDIS_URL, optional) so every relay\n\
  replica drops the cached key at once. Bindings are kept.";

  #[derive(Debug, PartialEq, Eq)]
  pub struct ForgetOutcome {
      pub deleted: bool,
      pub announced: bool,
  }

  pub async fn forget_key(
      identity: &dyn IdentityStore,
      bus: Option<&dyn ReplicaBus>,
      astation_id: &str,
  ) -> Result<ForgetOutcome, String> {
      let deleted = identity
          .delete_key(astation_id)
          .await
          .map_err(|error| format!("could not delete the key: {error}"))?;
      let announced = match bus {
          Some(bus) => {
              bus.broadcast(BroadcastMessage::KeyChanged {
                  astation_id: astation_id.to_string(),
              })
              .await
              .map_err(|error| {
                  format!(
                      "the key was deleted, but announcing it failed ({error}); \
                       restart the relay replicas to drop the cached key now"
                  )
              })?;
              true
          }
          None => false,
      };
      Ok(ForgetOutcome { deleted, announced })
  }

  /// `admin` arguments (after the word `admin`); returns the exit code.
  pub async fn main(args: &[String]) -> i32 {
      let astation_id = match args {
          [command, id] if command == "forget-key" && !id.is_empty() => id.clone(),
          _ => {
              eprintln!("{USAGE}");
              return 2;
          }
      };
      let Some(database_url) = std::env::var("DATABASE_URL").ok().filter(|url| !url.is_empty()) else {
          eprintln!("DATABASE_URL is required");
          return 2;
      };
      let pool = match sqlx::postgres::PgPoolOptions::new()
          .max_connections(1)
          .connect(&database_url)
          .await
      {
          Ok(pool) => pool,
          Err(error) => {
              eprintln!("could not connect to DATABASE_URL: {error}");
              return 1;
          }
      };
      let identity = PgIdentityStore::new(pool);
      let bus = match std::env::var("REDIS_URL").ok().filter(|url| !url.trim().is_empty()) {
          Some(url) => match RedisConn::connect(&url).await {
              Ok(conn) => Some(RedisBus::publisher(conn, "admin")),
              Err(error) => {
                  eprintln!("could not connect to REDIS_URL: {error}");
                  return 1;
              }
          },
          None => None,
      };
      match forget_key(&identity, bus.as_ref().map(|bus| bus as &dyn ReplicaBus), &astation_id).await {
          Ok(outcome) => {
              if outcome.deleted {
                  println!("Deleted the relay key of {astation_id}.");
              } else {
                  println!("No relay key was registered for {astation_id}.");
              }
              if outcome.announced {
                  println!("Announced on relay:broadcast: every relay replica drops its cached key now.");
              } else {
                  println!("REDIS_URL is not set: restart the relay to drop its cached key.");
              }
              0
          }
          Err(message) => {
              eprintln!("{message}");
              1
          }
      }
  }
  ```

  `src/main.rs`:
  - add `mod admin;` at the top of the module list;
  - rename `async fn main() {` (with its `#[tokio::main]` attribute) to a
    plain `async fn serve() {` (remove `#[tokio::main]` from it) and delete
    its first statement, the `tracing_subscriber::fmt()…init();` call;
  - add above `serve`:

    ```rust
    #[tokio::main]
    async fn main() {
        // Initialize tracing/logging
        tracing_subscriber::fmt()
            .with_target(false)
            .with_level(true)
            .init();

        // `station-relay-server admin …`: an operator command, not the server.
        let args: Vec<String> = std::env::args().skip(1).collect();
        if args.first().map(String::as_str) == Some("admin") {
            std::process::exit(admin::main(&args[1..]).await);
        }
        serve().await;
    }
    ```

- [ ] **Step 4: run and watch it pass.** `cargo test`, the Redis suite, and
  optionally the Postgres identity suite (README instructions) to cover
  `pg::delete_key_removes_only_that_key`. Then try the binary:
  `cargo run -- admin` prints the usage and exits 2.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): admin forget-key revokes a key on every replica at once

  🤖 Built with SMT <smt@agora.build>"
  ```

---

## Step 5 — deploy: Valkey → one relay with Redis → `relay-b`

### Task 27: nginx retries another replica

**Files:** modify `webapp/nginx.conf`, `webapp/tests/nginx.test.js`.

- [ ] **Step 1: write the test.** In `webapp/tests/nginx.test.js`, replace the
  last line `console.log("nginx health proxy test passed");` with:

  ```js
  for (const path of ["ws", "health"]) {
    const location = config.match(
      new RegExp(`location\\s*=\\s*\\/${path}\\s*\\{([\\s\\S]*?)\\}`),
    );
    assert.ok(location, `nginx must proxy the exact /${path} path`);
    assert.match(
      location[1],
      /proxy_next_upstream\s+error\s+timeout\s+http_502\s+http_503;/,
      `/${path} must move on to another relay replica when one refuses, fails or drains`,
    );
  }

  assert.match(
    config,
    /resolver\s+127\.0\.0\.11\s+valid=10s/,
    "nginx must re-resolve the relay alias every 10 s",
  );
  assert.match(
    config,
    /server\s+\$\{STATION_RELAY_UPSTREAM\}\s+resolve;/,
    "nginx must balance across every address of the relay alias",
  );

  console.log("nginx proxy tests passed");
  ```

- [ ] **Step 2: run and watch it fail.** `node webapp/tests/nginx.test.js`
  fails ("/ws must move on to another relay replica…").

- [ ] **Step 3: implement.** In `webapp/nginx.conf`:
  - replace the comment line in the `upstream` block
    `# Coolify replaces containers on deploy; refresh their Docker DNS addresses.`
    with:

    ```nginx
        # Coolify replaces containers on deploy; refresh their Docker DNS
        # addresses. Every relay replica (relay-a, relay-b) carries the same
        # network alias: `resolve` adds each address and requests are spread
        # across them round-robin.
    ```

  - in `location = /health { … }` add, before its closing `}`:

    ```nginx
        # A draining (503) or unreachable replica: ask another one.
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 3;
    ```

  - in `location = /ws { … }` add, before its closing `}`:

    ```nginx
        # A replica that refuses the connection, fails, or is draining (503)
        # is skipped for the next one; the upgrade is an idempotent GET.
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 3;
    ```

- [ ] **Step 4: run and watch it pass.** `node webapp/tests/nginx.test.js`,
  then check the syntax with the production image:

  ```bash
  docker run --rm -e STATION_RELAY_UPSTREAM=127.0.0.1:3000 \
    -v "$PWD/webapp/nginx.conf:/etc/nginx/templates/default.conf.template:ro" \
    nginx:1.28-alpine nginx -t
  ```

- [ ] **Step 5: commit.**

  ```bash
  git add webapp/nginx.conf webapp/tests/nginx.test.js
  git commit -m "feat(webapp): nginx retries another relay replica on refusal or drain

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 28: `verify-station.mjs` checks Redis and the replica count

**Files:** modify `.github/scripts/verify-station.mjs`; create
`.github/scripts/verify-station.test.mjs`.

**Interfaces.** Produces (ES module exports):
`healthProblems(health, { minReplicas, requireRedis }) -> string[]`,
`settingsFromEnv(env) -> { origin, minReplicas, requireRedis }`,
`waitForHealth({ origin, minReplicas, requireRedis, fetchImpl, sleep, log, attempts }) -> Promise<health>`,
`verifyStation(settings) -> Promise<void>`. CLI: `node verify-station.mjs`
(full check) and `node verify-station.mjs --wait-health` (poll `/health`
up to 3 minutes). Env: `STATION_URL`, `STATION_MIN_REPLICAS` (default `1`),
`STATION_REQUIRE_REDIS` (default on; `0` turns it off, e.g. after a rollback
to in-memory mode).

- [ ] **Step 1: write the tests** (new `.github/scripts/verify-station.test.mjs`):

  ```js
  import assert from 'node:assert/strict';
  import test from 'node:test';
  import { healthProblems, settingsFromEnv, waitForHealth } from './verify-station.mjs';

  const healthy = { status: 'ok', knowledge_store: 'postgres', redis: 'ok', replicas: 2 };

  test('a healthy cluster has no problems', () => {
    assert.deepEqual(healthProblems(healthy, { minReplicas: 2, requireRedis: true }), []);
  });

  test('redis and the replica count are checked', () => {
    assert.deepEqual(healthProblems({ ...healthy, redis: 'disabled', replicas: 1 }, { minReplicas: 2, requireRedis: true }), [
      'relay redis is disabled, expected ok',
      'relay reports 1 live replica(s), expected at least 2',
    ]);
    assert.deepEqual(healthProblems({ ...healthy, redis: 'disabled', replicas: 1 }, { minReplicas: 1, requireRedis: false }), []);
    assert.deepEqual(healthProblems({ ...healthy, knowledge_store: 'memory' }, { minReplicas: 1, requireRedis: true }), [
      'relay knowledge store is memory, expected postgres',
    ]);
    assert.deepEqual(healthProblems({ status: 'draining' }, { minReplicas: 1, requireRedis: false }), [
      'relay status is draining',
      'relay knowledge store is undefined, expected postgres',
      'relay reports 0 live replica(s), expected at least 1',
    ]);
  });

  test('settings come from the environment', () => {
    assert.deepEqual(settingsFromEnv({}), {
      origin: 'https://station.agora.build',
      minReplicas: 1,
      requireRedis: true,
    });
    assert.deepEqual(
      settingsFromEnv({ STATION_URL: 'https://x.test', STATION_MIN_REPLICAS: '2', STATION_REQUIRE_REDIS: '0' }),
      { origin: 'https://x.test', minReplicas: 2, requireRedis: false },
    );
    assert.throws(() => settingsFromEnv({ STATION_MIN_REPLICAS: 'two' }), /STATION_MIN_REPLICAS/);
  });

  test('waitForHealth polls until the cluster is healthy', async () => {
    const responses = [
      new Response('{}', { status: 502 }),
      new Response(JSON.stringify({ ...healthy, replicas: 1 })),
      new Response(JSON.stringify(healthy)),
    ];
    const logs = [];
    const health = await waitForHealth({
      origin: 'https://station.test',
      minReplicas: 2,
      requireRedis: true,
      fetchImpl: async () => responses.shift(),
      sleep: async () => {},
      log: line => logs.push(line),
      attempts: 5,
    });
    assert.equal(health.replicas, 2);
    assert.equal(logs.length, 3);
  });

  test('waitForHealth gives up', async () => {
    await assert.rejects(
      waitForHealth({
        origin: 'https://station.test',
        minReplicas: 1,
        requireRedis: true,
        fetchImpl: async () => new Response('{}', { status: 503 }),
        sleep: async () => {},
        log: () => {},
        attempts: 2,
      }),
      /did not become healthy: \/health returned HTTP 503/,
    );
  });
  ```

- [ ] **Step 2: run and watch it fail.** `node --test .github/scripts/verify-station.test.mjs`
  fails (no exports; the script also runs its network checks on import).

- [ ] **Step 3: implement.** Replace `.github/scripts/verify-station.mjs` with:

  ```js
  import { randomUUID } from 'node:crypto';
  import { pathToFileURL } from 'node:url';

  export function healthProblems(health, { minReplicas = 1, requireRedis = true } = {}) {
    const problems = [];
    if (health.status !== 'ok') problems.push(`relay status is ${health.status}`);
    // Atem Memory sync must be durable in production: an in-memory store
    // (DATABASE_URL missing) would silently lose every account's data on restart.
    if (health.knowledge_store !== 'postgres') {
      problems.push(`relay knowledge store is ${health.knowledge_store}, expected postgres`);
    }
    // Several replicas share rooms and sessions only through Redis.
    if (requireRedis && health.redis !== 'ok') {
      problems.push(`relay redis is ${health.redis ?? 'missing'}, expected ok`);
    }
    const replicas = Number(health.replicas ?? 0);
    if (replicas < minReplicas) {
      problems.push(`relay reports ${replicas} live replica(s), expected at least ${minReplicas}`);
    }
    return problems;
  }

  export function settingsFromEnv(env = process.env) {
    const raw = env.STATION_MIN_REPLICAS ?? '1';
    const minReplicas = Number(raw);
    if (!Number.isInteger(minReplicas) || minReplicas < 1) {
      throw new Error(`STATION_MIN_REPLICAS must be a positive integer, got ${raw}`);
    }
    return {
      origin: env.STATION_URL || 'https://station.agora.build',
      minReplicas,
      requireRedis: env.STATION_REQUIRE_REDIS !== '0',
    };
  }

  async function fetchHealth(origin, fetchImpl) {
    const response = await fetchImpl(new URL('/health', origin), { signal: AbortSignal.timeout(30_000) });
    const health = await response.json().catch(() => ({}));
    return { ok: response.ok, status: response.status, health };
  }

  /** Poll /health until the cluster is healthy (after a relay deploy). */
  export async function waitForHealth({
    origin,
    minReplicas,
    requireRedis,
    fetchImpl = fetch,
    sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
    log = console.log,
    attempts = 36,
  }) {
    let last = 'no response';
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        const { ok, status, health } = await fetchHealth(origin, fetchImpl);
        const problems = ok
          ? healthProblems(health, { minReplicas, requireRedis })
          : [`/health returned HTTP ${status}`];
        if (problems.length === 0) {
          log(`Relay healthy: redis ${health.redis}, ${health.replicas} live replica(s)`);
          return health;
        }
        last = problems.join('; ');
      } catch (error) {
        last = error.message;
      }
      log(`Waiting for relay health: ${last}`);
      await sleep(5_000);
    }
    throw new Error(`Relay did not become healthy: ${last}`);
  }

  export async function verifyStation({ origin, minReplicas, requireRedis }) {
    for (const path of ['/', '/health']) {
      const response = await fetch(new URL(path, origin), { signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`${path} returned HTTP ${response.status}`);
      if (path === '/health') {
        const health = await response.json();
        const problems = healthProblems(health, { minReplicas, requireRedis });
        if (problems.length) throw new Error(`Relay health: ${problems.join('; ')}`);
        console.log(
          `Relay health: ${health.status}; vault store: ${health.vault_store}; ` +
            `knowledge store: ${health.knowledge_store}; redis: ${health.redis}; replicas: ${health.replicas}`,
        );
      } else if (!(await response.text()).toLowerCase().includes('<!doctype html>')) {
        throw new Error('Station did not return the webapp HTML');
      }
      console.log(`${path}: HTTP ${response.status}`);
    }

    for (const path of ['/ws', '//ws']) {
      const url = new URL(origin);
      url.pathname = path;
      url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
      url.searchParams.set('role', 'astation');
      url.searchParams.set('code', `astation-${randomUUID()}`);
      await new Promise((resolve, reject) => {
        const socket = new WebSocket(url);
        const timer = setTimeout(() => {
          reject(new Error('Identity WebSocket connection timed out'));
          socket.close();
        }, 15_000);
        socket.addEventListener('open', () => {
          clearTimeout(timer);
          console.log(`Identity WebSocket ${path}: connected`);
          socket.close();
          resolve();
        }, { once: true });
        socket.addEventListener('error', () => {
          clearTimeout(timer);
          reject(new Error('Identity WebSocket connection failed'));
        }, { once: true });
      });
    }
  }

  if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const run = async () => {
      const settings = settingsFromEnv();
      if (process.argv.includes('--wait-health')) {
        await waitForHealth(settings);
      } else {
        await verifyStation(settings);
      }
    };
    run().catch(error => {
      console.error(error.message);
      process.exitCode = 1;
    });
  }
  ```

- [ ] **Step 4: run and watch it pass.** `node --test .github/scripts/*.test.mjs`
  (the CI webapp job already runs this glob).

- [ ] **Step 5: commit.**

  ```bash
  git add .github/scripts/verify-station.mjs .github/scripts/verify-station.test.mjs
  git commit -m "ci(station): verify Redis and the live replica count; --wait-health

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 29: deploy the relay apps one at a time

**Files:** modify `.github/workflows/deploy-station.yml`.

Secrets and variables (design; the human creates them in Task 30's
checklist): `COOLIFY_RELAY_SERVER_WEBHOOK_URL` (existing, now relay-a),
`COOLIFY_RELAY_B_WEBHOOK_URL` (new, optional: when empty relay-b is
skipped), repository variable `STATION_MIN_REPLICAS` (`1` until relay-b
exists, then `2`), optional variable `STATION_REQUIRE_REDIS` (`0` only after
a rollback to in-memory mode).

- [ ] **Step 1: edit the `deploy` job.** Replace its steps after
  `actions/setup-node@v4` (the four steps from `Deploy relay and wait for
  Coolify` to `Verify public HTTPS and identity WebSocket`) with:

  ```yaml
        - name: Deploy relay-a and wait for Coolify
          env:
            COOLIFY_WEBHOOK_URL: ${{ secrets.COOLIFY_RELAY_SERVER_WEBHOOK_URL }}
            COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
          run: node .github/scripts/deploy-coolify.mjs
        # relay-b keeps serving while relay-a restarts; wait until relay-a is
        # back (the live replica count recovers) before touching relay-b.
        - name: Wait for relay health after relay-a
          env:
            STATION_MIN_REPLICAS: ${{ vars.STATION_MIN_REPLICAS || '1' }}
            STATION_REQUIRE_REDIS: ${{ vars.STATION_REQUIRE_REDIS || '1' }}
          run: node .github/scripts/verify-station.mjs --wait-health
        - name: Deploy relay-b and wait for Coolify
          env:
            COOLIFY_WEBHOOK_URL: ${{ secrets.COOLIFY_RELAY_B_WEBHOOK_URL }}
            COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
          run: |
            if [ -z "$COOLIFY_WEBHOOK_URL" ]; then
              echo "COOLIFY_RELAY_B_WEBHOOK_URL is not set: single relay, skipping relay-b."
              exit 0
            fi
            node .github/scripts/deploy-coolify.mjs
        - name: Wait for relay health after relay-b
          env:
            STATION_MIN_REPLICAS: ${{ vars.STATION_MIN_REPLICAS || '1' }}
            STATION_REQUIRE_REDIS: ${{ vars.STATION_REQUIRE_REDIS || '1' }}
          run: node .github/scripts/verify-station.mjs --wait-health
        - name: Deploy webapp and wait for Coolify
          env:
            COOLIFY_WEBHOOK_URL: ${{ secrets.COOLIFY_WEBAPP_WEBHOOK_URL }}
            COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
          run: node .github/scripts/deploy-coolify.mjs
        - name: Verify public HTTPS, relay health and identity WebSocket
          env:
            STATION_MIN_REPLICAS: ${{ vars.STATION_MIN_REPLICAS || '1' }}
            STATION_REQUIRE_REDIS: ${{ vars.STATION_REQUIRE_REDIS || '1' }}
          run: node .github/scripts/verify-station.mjs
  ```

  Also change the comment above `concurrency:` to
  `# Keep image publication and the relay and webapp deployments in one serial run.`

- [ ] **Step 2: check it.** `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy-station.yml'))"`
  parses; `actionlint .github/workflows/deploy-station.yml` (if installed)
  reports nothing. The workflow runs only on `main`, so the real check is
  the first deploy after merge (Task 30 checklist, step 5).

- [ ] **Step 3: commit.**

  ```bash
  git add .github/workflows/deploy-station.yml
  git commit -m "ci(station): deploy relay-a, wait healthy, then optional relay-b

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 30: documentation (DEPLOY.md, README, SECURITY)

**Files:** modify `DEPLOY.md`, `relay-server/README.md`, `relay-server/SECURITY.md`.

- [ ] **Step 1: DEPLOY.md, "Station on Volumetric (Coolify)".**
  - Replace the paragraph that starts `Every push to \`main\` runs` with:

    ```markdown
    Every push to `main` runs `.github/workflows/deploy-station.yml`. It builds both
    Linux AMD64 images, publishes `:main` and `:sha-<commit>` tags to GHCR, then
    deploys the relay replicas one at a time (relay-a, wait until `/health`
    reports the expected replica count, then relay-b if configured, wait again)
    and finally the webapp. The final check requires public HTTPS, a healthy
    `/health` (Postgres knowledge store, Redis `ok`, at least
    `STATION_MIN_REPLICAS` live replicas), and an identity WebSocket connection
    to `wss://station.agora.build/ws`. The workflow can also be run manually on
    `main` from GitHub Actions.
    ```

  - Replace the applications table and the secrets list with:

    ```markdown
    The Coolify resources on Volumetric are:

    | Resource | Coolify UUID | Image | Host port |
    | --- | --- | --- | --- |
    | Relay A (`relay-a`) | `oss4444o8ss40ckgwc40og4c` | `ghcr.io/agora-build/station-relay-server:main` | `3000` |
    | Relay B (`relay-b`) | set when created | `ghcr.io/agora-build/station-relay-server:main` | none |
    | Valkey (relay live state) | set when created | `valkey/valkey:8` | none |
    | Webapp | `c0wwgk4c0owk0w4gsww4k0ss` | `ghcr.io/agora-build/station-webapp:main` | `3010` |

    Required GitHub Actions secrets:

    - `COOLIFY_API_TOKEN`: Coolify token with `deploy` and `read` permissions.
    - `COOLIFY_RELAY_SERVER_WEBHOOK_URL`: relay-a,
      `https://smt.agora.build/api/v1/deploy?uuid=oss4444o8ss40ckgwc40og4c&force=false`.
    - `COOLIFY_RELAY_B_WEBHOOK_URL`: relay-b,
      `https://smt.agora.build/api/v1/deploy?uuid=<relay-b uuid>&force=false`.
      Optional: while it is unset the workflow skips relay-b.
    - `COOLIFY_WEBAPP_WEBHOOK_URL`: `https://smt.agora.build/api/v1/deploy?uuid=c0wwgk4c0owk0w4gsww4k0ss&force=false`.

    GitHub Actions variables:

    - `STATION_MIN_REPLICAS`: live relay replicas the deploy waits for and
      verifies: `1` with relay-a only, `2` once relay-b exists.
    - `STATION_REQUIRE_REDIS`: leave unset (Redis required). Set `0` only
      after a rollback to in-memory mode.
    ```

  - Replace the `Runtime configuration:` bullet for the relay with:

    ```markdown
    - Relay (relay-a and relay-b, identical): `PUBLIC_BASE_URL=https://station.agora.build`,
      `CORS_ORIGIN=https://station.agora.build`, `PORT=3000`, the existing
      PostgreSQL `DATABASE_URL`, `REDIS_URL` (Valkey, a Coolify secret), and
      `RELAY_REPLICAS_EXPECTED` (`1` with relay-a only, `2` with relay-b; a value
      above 1 without `REDIS_URL` refuses to start). Both keep the
      `station-relay-server` network alias. Health check `GET /health` on port
      3000. Stop grace period at least 40 s (custom Docker option
      `--stop-timeout 40`): on SIGTERM a relay fails `/health`, closes its
      WebSockets with code 1012, leaves its rooms, then finishes in-flight
      requests (a voice request can wait up to 30 s).
    ```

  - After the `Verification:` code block, add:

    ```markdown
    #### Relay replicas and Valkey

    Each relay replica keeps only its own WebSockets. Rooms, pairing/OTP
    sessions, voice and RTC sessions, and rate-limit counters live in Valkey
    (`REDIS_URL`), and replicas deliver frames to each other through Valkey
    pub/sub. Postgres stays the only durable store. Design:
    `docs/specs/2026-09-30-relay-multi-replica.md`.

    Valkey resource: on the private `coolify` network only (no public port),
    password protected, `maxmemory-policy noeviction` (live state must never be
    dropped silently: if memory runs out, writes fail loudly), no persistence,
    no backups. **It is sensitive**: it holds pairing session ids, and a pending
    one can authorize a WebSocket. Restrict access like the database.

    If Valkey is unreachable: new WebSockets are refused, the pairing, voice
    and RTC endpoints return `503`, and `/health` fails. Vault and Atem Memory
    keep working (Postgres only). Nothing durable is lost; rooms rebuild as
    clients reconnect. A relay that can't reach Valkey at startup retries for
    about 30 s, then exits and Coolify restarts it.

    Sizing: each replica opens up to 5 Postgres connections, so replicas × 5
    must stay below Postgres `max_connections` (10 for two replicas). Before
    claiming 10k users or raising any limit, run the load test
    (`relay-server/loadtest/`).

    Rollout, each step reversible:

    1. Deploy Valkey (checklist below).
    2. Set `REDIS_URL` on the relay and deploy it, still one instance
       (`STATION_MIN_REPLICAS=1`); verify `/health` shows `"redis":"ok"`.
    3. Add relay-b, set `RELAY_REPLICAS_EXPECTED=2` on both and
       `STATION_MIN_REPLICAS=2`; verify `"replicas":2`.

    Rollback: remove relay-b (delete `COOLIFY_RELAY_B_WEBHOOK_URL`, set
    `STATION_MIN_REPLICAS=1`, `RELAY_REPLICAS_EXPECTED=1`), then, if needed,
    unset `REDIS_URL` and set `STATION_REQUIRE_REDIS=0` (back to in-memory mode).
    The Postgres schema doesn't change.

    Metrics: each relay serves Prometheus metrics at `GET /metrics` on port
    3000 (not proxied by nginx). Scrape each relay container on the `coolify`
    network.
    ```

  - Replace the "Admin reset" paragraph and SQL block (from `Admin reset, for a
    lost or replaced Mac` down to the paragraph ending `… or a restart.`) with:

    ~~~markdown
    Admin reset, for a lost or replaced Mac (its Astation reports "Relay rejected
    this Astation's key"). Relay logs show only the first 4 characters of an id, so
    look it up first:

    ```sql
    SELECT astation_id, registered_at, last_verified_at FROM astation_keys
     WHERE astation_id LIKE '<first chars>%';
    ```

    Then, in any relay container (Coolify → relay-a → Terminal):

    ```bash
    station-relay-server admin forget-key <astation_id>
    ```

    It deletes the key in Postgres and announces the change on Valkey, so every
    relay replica drops its cached key at once: the old key stops verifying
    immediately (a stolen Mac is revoked without a restart). Bindings are kept.
    The next connect with a new key for that id registers it. Deleting the row
    by hand in SQL still works, but then restart every relay replica to drop the
    cached key.
    ~~~

- [ ] **Step 2: DEPLOY.md, other sections.**
  - Kubernetes manifest: change the two lines
    `replicas: 1  # must stay 1: rooms and the Astation key cache are in memory (see Scaling)`
    and `type: Recreate  # never run two relay pods at once, even during a rollout` to
    `replicas: 1  # more than 1 needs REDIS_URL (see Scaling)` and
    `type: Recreate  # RollingUpdate is safe once REDIS_URL is set`.
  - Replace the whole `### The relay runs as exactly one instance` subsection
    (up to `### Scaling the webapp`) with:

    ```markdown
    ### Relay replicas

    With `REDIS_URL` set, the relay runs as any number of replicas behind the
    webapp: any replica serves any request, and an Astation and its Atems may
    be on different replicas. Without `REDIS_URL` it keeps rooms and sessions in
    memory and must run as exactly one instance (`RELAY_REPLICAS_EXPECTED` above
    1 without `REDIS_URL` refuses to start). See "Relay replicas and Valkey"
    above for Valkey, sizing, rollout and rollback.

    Replicas find each other only through Valkey; there is no leader. A
    crashed replica's sockets reconnect to the others within seconds, and its
    leftover room entries are ignored once its presence key expires (30 s).
    ```

  - In `### Load Balancing`, replace `the webapp proxies \`/api/*\` and \`/ws\` to the single relay.`
    with `the webapp proxies \`/api/*\` and \`/ws\` to the relay replicas.`
  - In `## Backup`, replace the sentence
    `Everything else (rooms, WebSockets, the key cache) is in memory and rebuilt on restart.`
    with
    `Everything else (rooms, sessions, WebSockets, the key cache) is live state in memory or Valkey and is rebuilt as clients reconnect; Valkey is not backed up.`
  - In `## Updating`, replace the comment
    `# Restart services. The relay restart drops every WebSocket for a few`
    `# seconds; Astations and Atems reconnect on their own. …` (the three
    comment lines) with:

    ```bash
    # Restart services. With one relay the restart drops every WebSocket for
    # a few seconds; with several (REDIS_URL) update them one at a time and
    # clients move to the others (close code 1012). Vault and Atem Memory
    # data is in Postgres and survives.
    ```

- [ ] **Step 3: relay-server/README.md.**
  - After the sentence starting `` `GET /health` returns `200` ``, add:
    ``It also reports `redis` (`disabled`, `ok`, `unavailable`) and `replicas` (live relay replicas), and returns `503` while Redis is unreachable or the relay is draining. `GET /metrics` serves Prometheus metrics (container network only).``
  - Add these rows to the environment variable table:

    ```markdown
    | `REDIS_URL` | _(unset)_ | Redis/Valkey for shared relay state: rooms, pairing/OTP, voice and RTC sessions, rate-limit counters, replica-to-replica delivery. Required to run more than one replica. Unset: in-memory, one replica only. |
    | `RELAY_REPLICAS_EXPECTED` | `1` | How many relay replicas the deployment runs. Above 1 without `REDIS_URL`, the relay refuses to start. |
    | `RELAY_WS_MAX_PER_IP` | `200` | Concurrent `/ws` connections per client IP per replica. Raise it for the load test. |
    ```

  - Replace the `## Testing` code block with:

    ```bash
    cargo test  # unit + in-memory integration suites
    # Postgres suites are #[ignore]d; run each against a throwaway local database:
    #   docker run --rm -d --name relay-test-pg -e POSTGRES_PASSWORD=pw -p 55433:5432 postgres:16
    #   IDENTITY_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test identity_store -- --ignored
    #   IDENTITY_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test relay:: -- --ignored
    #   KNOWLEDGE_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres cargo test knowledge_store -- --ignored
    #   docker rm -f relay-test-pg
    # Redis suites (every Redis unit + two relays in one process) are #[ignore]d
    # too; CI runs them against a Valkey service:
    #   docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
    #   TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
    #   docker rm -f relay-test-valkey
    # Load test (see loadtest/src/main.rs for flags and pass criteria):
    #   cargo run --release --manifest-path loadtest/Cargo.toml -- --url ws://127.0.0.1:3000/ws
    ```

  - Replace the `**Scaling:**` YAML snippet in `## Deployment` with:

    ```markdown
    **Scaling:** set `REDIS_URL` on every replica, then run as many replicas as
    needed behind the webapp (see `../DEPLOY.md`, "Relay replicas").
    ```

- [ ] **Step 4: relay-server/SECURITY.md.**
  - In "Astation relay identity", replace the `**Key cache.**` bullet's last
    two sentences (from `A presented key that differs from the cached one` to
    the end of the bullet) with:

    ```markdown
    A presented key that differs from the cached one makes the relay re-read
    the stored key before rejecting; if the database is unreachable it is
    rejected and the cached key stays. With several replicas, a registration,
    a re-read that finds a new key, or `admin forget-key` is announced on
    Valkey (`key-changed`) and every replica re-reads that key; if a re-read
    fails the key is marked stale and must be re-read before it verifies
    again (fail closed).
    ```

  - Replace the `**Admin reset.**` bullet with:

    ```markdown
    - **Admin reset.** A lost or replaced Mac cannot prove the old key; an
      operator runs `station-relay-server admin forget-key <astation_id>` (see
      `../DEPLOY.md`), which deletes the `astation_keys` row and makes every
      relay replica drop the cached key at once, so a compromised key is
      revoked immediately. The next connect with a new key registers it.
      Bindings are kept. Deleting the row by hand (or running the command
      without `REDIS_URL`) needs a relay restart to drop the cached key.
    ```

  - Under "Production blockers", item 5, append:
    `` Partly addressed: per-IP `/ws` connection cap, at most 4 pending Astation sockets per room, and bounded per-connection send queues (1,000 frames / 4 MB; a client stalled for 10 s is closed with 1013). Message size and rate limits are still open. ``
  - Under "Deployment baseline", add:

    ```markdown
    - With several relay replicas, set `REDIS_URL` as a secret, keep Valkey on
      the private network with a password and no public port. It holds
      pairing session ids (a pending one can authorize a WebSocket): restrict
      access like the database.
    ```

- [ ] **Step 5: check.** Read each edited section once in rendered form
  (e.g. `gh markdown-preview` or the GitHub PR view); make sure every
  command and name matches the code (`station-relay-server admin forget-key`,
  `REDIS_URL`, `RELAY_REPLICAS_EXPECTED`, `RELAY_WS_MAX_PER_IP`,
  `STATION_MIN_REPLICAS`, `STATION_REQUIRE_REDIS`,
  `COOLIFY_RELAY_B_WEBHOOK_URL`).

- [ ] **Step 6: commit.**

  ```bash
  git add DEPLOY.md relay-server/README.md relay-server/SECURITY.md
  git commit -m "docs(relay): multi-replica deploy, Valkey, forget-key runbook

  🤖 Built with SMT <smt@agora.build>"
  ```

### Manual Coolify checklist (human, not a code task)

Do these in order; each step is reversible. Record the new Coolify UUIDs in
DEPLOY.md's resource table in a follow-up commit.

1. **Valkey.** Coolify → Projects → Station → + New → Database → Redis.
   - Image: `valkey/valkey:8`.
   - Password: generate one; keep "Make it publicly available" **off** (no
     host port). Network: the default `coolify` network.
   - Custom configuration (`redis.conf` / command args):
     `maxmemory 512mb`, `maxmemory-policy noeviction`, `save ""`,
     `appendonly no`.
   - Backups: none. Start it and note its internal URL
     (`redis://default:<password>@<valkey-container-name>:6379`).
2. **relay-a (the existing relay app, `oss4444o8ss40ckgwc40og4c`).** Rename it
   `relay-a` (optional). Environment → add secret `REDIS_URL` = the internal
   URL above and `RELAY_REPLICAS_EXPECTED=1`. Health check: enabled, path
   `/health`, port 3000. Custom Docker options: keep the network alias
   `station-relay-server`, add `--stop-timeout 40`.
3. **Merge the branch** (after review). The deploy workflow deploys relay-a
   with `REDIS_URL`, waits for `/health` with `redis: "ok"` and 1 replica
   (repository variable `STATION_MIN_REPLICAS=1`), skips relay-b, deploys the
   webapp, and verifies. Check `https://station.agora.build/health` by hand.
4. **relay-b.** + New → Application → Docker Image
   `ghcr.io/agora-build/station-relay-server:main`, on the `coolify` network,
   **no host port**, custom Docker options
   `--network-alias station-relay-server --stop-timeout 40`, health check
   `/health` on 3000, and the same environment as relay-a (`DATABASE_URL`,
   `REDIS_URL`, `CORS_ORIGIN`, `PUBLIC_BASE_URL`, `PORT=3000`, `RUST_LOG=info`).
   Set `RELAY_REPLICAS_EXPECTED=2` on both relays. Deploy relay-b.
5. **GitHub.** Add secret `COOLIFY_RELAY_B_WEBHOOK_URL`
   (`https://smt.agora.build/api/v1/deploy?uuid=<relay-b uuid>&force=false`)
   and set repository variable `STATION_MIN_REPLICAS=2`. Re-run "Deploy
   Station" on `main`: both relays deploy one at a time and verification
   requires 2 replicas.
6. **Postgres.** Check `SHOW max_connections;` on the relay database is above
   10 (2 replicas × 5).
7. **Failover drill.** In Coolify, restart relay-a while an Astation and an
   Atem are connected: they reconnect within seconds and chat keeps working;
   `/health` stays green (served by relay-b). Repeat for relay-b.
8. **Metrics (optional).** Point Prometheus at
   `http://<relay-a container>:3000/metrics` and `http://<relay-b container>:3000/metrics`.

---

## Step 6 — 10k+ readiness

### Task 31: bounded send queues (1,000 frames or 4 MB; stalled 10 s → close)

**Files:** modify `src/cluster/local.rs`, `src/relay.rs` (`write_loop`),
`src/main.rs` (sweep task).

**Interfaces.**
Produces (`cluster/local.rs`):
- `pub const MAX_QUEUED_FRAMES: usize = 1000;` `pub const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;`
  `pub const SLOW_CLIENT_TIMEOUT: Duration = Duration::from_secs(10);` `pub const CLOSE_SLOW_CLIENT: u16 = 1013;`
- `#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub struct QueueLimits { pub frames: usize, pub bytes: usize, pub stall: Duration }` (Default = the constants)
- `LocalSockets::with_limits(QueueLimits) -> Self`; `LocalSockets::sweep_slow(&self) -> usize`;
  `LocalSockets::room_count(&self) -> usize`
- `SocketOutbox { frames: mpsc::Receiver<String>, close, queued_bytes: Arc<AtomicUsize> }` with
  `SocketOutbox::sent(&self, frame: &str)` (the writer took `frame`)

A frame that does not fit is dropped (frames stay best effort). A client
whose queue has stayed full for 10 s is closed with 1013; `send` checks on
every frame and `sweep_slow` (every second) catches a client that stays full
while no new frames arrive.

- [ ] **Step 1: write the tests** (append to `src/cluster/local.rs`'s tests):

  ```rust
  use std::time::Duration;

  #[tokio::test]
  async fn a_full_queue_drops_frames_and_a_stalled_client_is_closed() {
      let local = LocalSockets::with_limits(QueueLimits {
          frames: 2,
          bytes: 1024,
          stall: Duration::from_millis(100),
      });
      let mut outbox = local.register("slow", "room", SocketRole::Astation);
      assert!(local.send("slow", "1".into()));
      assert!(local.send("slow", "2".into()));
      assert!(!local.send("slow", "3".into()), "queue full: dropped");
      assert!(local.contains("slow"), "not yet stalled for long");
      tokio::time::sleep(Duration::from_millis(150)).await;
      assert!(!local.send("slow", "4".into()));
      assert!(!local.contains("slow"), "full for longer than the stall limit");
      assert!(outbox.close.changed().await.is_ok());
      assert_eq!(
          *outbox.close.borrow(),
          Some((CLOSE_SLOW_CLIENT, "client too slow".to_string()))
      );
  }

  #[tokio::test]
  async fn the_byte_cap_counts_bytes_until_the_writer_takes_them() {
      let local = LocalSockets::with_limits(QueueLimits {
          frames: 100,
          bytes: 10,
          stall: Duration::from_secs(60),
      });
      let mut outbox = local.register("c", "room", SocketRole::Astation);
      assert!(local.send("c", "12345678".into()));
      assert!(!local.send("c", "abc".into()), "8 + 3 bytes > 10");
      let frame = outbox.frames.recv().await.unwrap();
      outbox.sent(&frame);
      assert!(local.send("c", "abc".into()));
  }

  #[tokio::test]
  async fn sweep_closes_only_clients_that_stay_full() {
      let limits = QueueLimits { frames: 1, bytes: 1024, stall: Duration::from_millis(50) };
      let local = LocalSockets::with_limits(limits);
      let _stuck = local.register("stuck", "room", SocketRole::Astation);
      let mut caught_up = local.register("caught-up", "room", SocketRole::Astation);
      for id in ["stuck", "caught-up"] {
          assert!(local.send(id, "a".into()));
          assert!(!local.send(id, "b".into()), "full");
      }
      // One client drains its queue; the other doesn't.
      let frame = caught_up.frames.recv().await.unwrap();
      caught_up.sent(&frame);
      tokio::time::sleep(Duration::from_millis(80)).await;
      assert_eq!(local.sweep_slow(), 1);
      assert!(!local.contains("stuck"));
      assert!(local.contains("caught-up"));
  }

  #[test]
  fn default_limits_match_the_spec() {
      assert_eq!(
          QueueLimits::default(),
          QueueLimits { frames: 1000, bytes: 4 * 1024 * 1024, stall: Duration::from_secs(10) }
      );
  }
  ```

  Also add to `room_and_role_queries` the line
  `assert_eq!(local.room_count(), 2);`.

- [ ] **Step 2: run and watch it fail.** `cargo test cluster::local`.

- [ ] **Step 3: implement.** Replace everything above the test module in
  `src/cluster/local.rs` with:

  ```rust
  //! This replica's live WebSockets: connection id → sender. The only
  //! per-process relay state. The map holds each socket's only sender, so
  //! removing an entry ends that socket: its writer flushes what is queued,
  //! then closes (exactly how a replaced socket closes today).
  //!
  //! Each socket's queue is bounded (spec: "Bounded send queues"): at most
  //! 1,000 frames or 4 MB. A frame that doesn't fit is dropped, and a client
  //! whose queue stays full for 10 s is closed with 1013 (reconnect).

  use std::collections::{BTreeSet, HashMap};
  use std::sync::atomic::{AtomicUsize, Ordering};
  use std::sync::{Arc, Mutex, MutexGuard};
  use std::time::{Duration, Instant};

  use tokio::sync::{mpsc, watch};

  pub const MAX_QUEUED_FRAMES: usize = 1000;
  pub const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;
  pub const SLOW_CLIENT_TIMEOUT: Duration = Duration::from_secs(10);
  /// Close code for a client too slow to keep up (RFC 6455 "try again later").
  pub const CLOSE_SLOW_CLIENT: u16 = 1013;

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub struct QueueLimits {
      pub frames: usize,
      pub bytes: usize,
      /// A queue full this long closes the socket.
      pub stall: Duration,
  }

  impl Default for QueueLimits {
      fn default() -> Self {
          Self {
              frames: MAX_QUEUED_FRAMES,
              bytes: MAX_QUEUED_BYTES,
              stall: SLOW_CLIENT_TIMEOUT,
          }
      }
  }

  /// What a socket is, for room-wide operations (expiry, delete, drain).
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub enum SocketRole {
      Atem { atem_id: String },
      Astation,
  }

  /// A request to close with this code and reason, sent to the writer.
  pub type CloseRequest = Option<(u16, String)>;

  struct LocalConn {
      tx: mpsc::Sender<String>,
      queued_bytes: Arc<AtomicUsize>,
      /// Since when frames have not fit (None: the last frame fit).
      full_since: Option<Instant>,
      close: watch::Sender<CloseRequest>,
      code: String,
      role: SocketRole,
  }

  /// The receiving half, owned by the socket's writer task.
  pub struct SocketOutbox {
      pub frames: mpsc::Receiver<String>,
      pub close: watch::Receiver<CloseRequest>,
      pub queued_bytes: Arc<AtomicUsize>,
  }

  impl SocketOutbox {
      /// The writer took `frame` off the queue.
      pub fn sent(&self, frame: &str) {
          self.queued_bytes.fetch_sub(frame.len(), Ordering::Relaxed);
      }
  }

  #[derive(Clone, Default)]
  pub struct LocalSockets {
      conns: Arc<Mutex<HashMap<String, LocalConn>>>,
      limits: QueueLimits,
  }

  impl LocalSockets {
      pub fn new() -> Self {
          Self::default()
      }

      pub fn with_limits(limits: QueueLimits) -> Self {
          Self {
              conns: Arc::default(),
              limits,
          }
      }

      fn lock(&self) -> MutexGuard<'_, HashMap<String, LocalConn>> {
          self.conns.lock().unwrap_or_else(|e| e.into_inner())
      }

      pub fn register(&self, connection_id: &str, code: &str, role: SocketRole) -> SocketOutbox {
          let (tx, frames) = mpsc::channel(self.limits.frames);
          let (close, close_rx) = watch::channel(None);
          let queued_bytes = Arc::new(AtomicUsize::new(0));
          self.lock().insert(
              connection_id.to_string(),
              LocalConn {
                  tx,
                  queued_bytes: queued_bytes.clone(),
                  full_since: None,
                  close,
                  code: code.to_string(),
                  role,
              },
          );
          SocketOutbox {
              frames,
              close: close_rx,
              queued_bytes,
          }
      }

      /// Queue a frame. False when the connection is not here, or its queue
      /// is full (the frame is dropped; a queue full for `stall` closes it).
      pub fn send(&self, connection_id: &str, frame: String) -> bool {
          let mut conns = self.lock();
          let Some(conn) = conns.get_mut(connection_id) else {
              return false;
          };
          let len = frame.len();
          if conn.queued_bytes.load(Ordering::Relaxed) + len <= self.limits.bytes {
              conn.queued_bytes.fetch_add(len, Ordering::Relaxed);
              match conn.tx.try_send(frame) {
                  Ok(()) => {
                      conn.full_since = None;
                      return true;
                  }
                  Err(mpsc::error::TrySendError::Closed(_)) => {
                      conn.queued_bytes.fetch_sub(len, Ordering::Relaxed);
                      return false;
                  }
                  Err(mpsc::error::TrySendError::Full(_)) => {
                      conn.queued_bytes.fetch_sub(len, Ordering::Relaxed);
                  }
              }
          }
          let since = *conn.full_since.get_or_insert_with(Instant::now);
          if since.elapsed() >= self.limits.stall {
              if let Some(conn) = conns.remove(connection_id) {
                  Self::close_slow(conn, self.limits.stall);
              }
          }
          false
      }

      fn close_slow(conn: LocalConn, stall: Duration) {
          tracing::warn!("Closing a slow relay client (send queue full for {:?})", stall);
          let _ = conn
              .close
              .send(Some((CLOSE_SLOW_CLIENT, "client too slow".to_string())));
      }

      /// Close clients whose queue has stayed full for `stall` while no new
      /// frame arrived; forget the stall of clients that caught up. Returns
      /// how many were closed.
      pub fn sweep_slow(&self) -> usize {
          let mut conns = self.lock();
          let mut stalled = Vec::new();
          for (id, conn) in conns.iter_mut() {
              let Some(since) = conn.full_since else {
                  continue;
              };
              let still_full = conn.tx.capacity() == 0
                  || conn.queued_bytes.load(Ordering::Relaxed) >= self.limits.bytes;
              if !still_full {
                  conn.full_since = None;
              } else if since.elapsed() >= self.limits.stall {
                  stalled.push(id.clone());
              }
          }
          for id in &stalled {
              if let Some(conn) = conns.remove(id) {
                  Self::close_slow(conn, self.limits.stall);
              }
          }
          stalled.len()
      }

      pub fn contains(&self, connection_id: &str) -> bool {
          self.lock().contains_key(connection_id)
      }

      /// Drop the connection's sender: its writer flushes queued frames and
      /// closes without a close code (a replaced or evicted socket, as today).
      pub fn evict(&self, connection_id: &str) -> bool {
          self.lock().remove(connection_id).is_some()
      }

      /// Close with an explicit close code (1012 drain, 1013 try again later).
      pub fn close_with(&self, connection_id: &str, code: u16, reason: &str) -> bool {
          match self.lock().remove(connection_id) {
              Some(conn) => {
                  let _ = conn.close.send(Some((code, reason.to_string())));
                  true
              }
              None => false,
          }
      }

      pub fn connections_in_room(&self, code: &str) -> Vec<(String, SocketRole)> {
          self.lock()
              .iter()
              .filter(|(_, conn)| conn.code == code)
              .map(|(id, conn)| (id.clone(), conn.role.clone()))
              .collect()
      }

      fn codes_where(&self, astation: bool) -> Vec<String> {
          let codes: BTreeSet<String> = self
              .lock()
              .values()
              .filter(|conn| (conn.role == SocketRole::Astation) == astation)
              .map(|conn| conn.code.clone())
              .collect();
          codes.into_iter().collect()
      }

      /// Room codes where this replica holds an Astation socket (owner or pending).
      pub fn codes_with_astations(&self) -> Vec<String> {
          self.codes_where(true)
      }

      /// Room codes where this replica holds an Atem socket.
      pub fn codes_with_atems(&self) -> Vec<String> {
          self.codes_where(false)
      }

      /// Rooms with at least one socket on this replica.
      pub fn room_count(&self) -> usize {
          self.lock()
              .values()
              .map(|conn| conn.code.as_str())
              .collect::<std::collections::HashSet<_>>()
              .len()
      }

      pub fn connection_ids(&self) -> Vec<String> {
          self.lock().keys().cloned().collect()
      }

      /// (Atem sockets, Astation sockets) on this replica.
      pub fn count_by_role(&self) -> (usize, usize) {
          let conns = self.lock();
          let astations = conns
              .values()
              .filter(|conn| conn.role == SocketRole::Astation)
              .count();
          (conns.len() - astations, astations)
      }

      pub fn len(&self) -> usize {
          self.lock().len()
      }

      pub fn is_empty(&self) -> bool {
          self.lock().is_empty()
      }
  }
  ```

  In `src/relay.rs` `write_loop`, inside `msg = outbox.frames.recv() =>`,
  change the `Some(text) => {` arm's first line to account for the frame
  leaving the queue:

  ```rust
  Some(text) => {
      outbox.sent(&text);
      if ws_sink.send(Message::Text(text)).await.is_err() {
  ```

  In `src/main.rs`, after the four background cleanup `tokio::spawn`s, add:

  ```rust
  // Close clients whose send queue has stayed full for 10 s.
  let sweep_slow = relay.clone();
  tokio::spawn(async move {
      let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));
      loop {
          interval.tick().await;
          sweep_slow.local().sweep_slow();
      }
  });
  ```

  (`relay` is still in scope there: `AppState` is built after the sweeps.)

- [ ] **Step 4: run and watch it pass.** `cargo test` (the existing Task 1
  tests still pass: `frames.recv()` works the same on a bounded receiver)
  and the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): bounded per-socket send queues; close stalled clients with 1013

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 32: connection limits (per-IP `/ws`, pending Astations per room)

**Files:** create `src/cluster/limits.rs`; modify `src/cluster/mod.rs`,
`src/relay.rs`, `src/cluster/redis/mod.rs` (`connect_cluster`).

**Interfaces.**
Produces:
- `pub const DEFAULT_WS_MAX_PER_IP: usize = 200;`
- `#[derive(Clone)] pub struct WsConnLimiter` with `new(max_per_ip: usize)`,
  `from_env()` (`RELAY_WS_MAX_PER_IP`), `try_acquire(&self, ip: &str) -> Option<WsPermit>`,
  `open(&self, ip: &str) -> usize`; `pub struct WsPermit` (releases on drop)
- `pub fn client_ip(headers: &HeaderMap, peer: Option<SocketAddr>) -> String`
- `HubParts.ws_limiter: WsConnLimiter`; `RelayHub::ws_limiter(&self) -> &WsConnLimiter`;
  `#[cfg(test)] RelayHub::with_ws_limit(max_per_ip: usize, auth_timeout: Duration) -> Self`
- `MAX_PENDING_ASTATIONS_PER_ROOM` becomes 4.
- `ws_handler` answers 429 when the IP already has `max_per_ip` sockets on
  this replica; `handle_ws` holds the permit for the socket's lifetime.

The limit is per replica (no shared counter to leak when a replica
crashes). With N replicas behind round-robin a client can hold up to about
N × the limit.

- [ ] **Step 1: write the tests.** New `src/cluster/limits.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn permits_are_counted_per_ip_and_released_on_drop() {
          let limiter = WsConnLimiter::new(2);
          let a1 = limiter.try_acquire("203.0.113.1").expect("first");
          let _a2 = limiter.try_acquire("203.0.113.1").expect("second");
          assert!(limiter.try_acquire("203.0.113.1").is_none(), "third is over the cap");
          let _b1 = limiter.try_acquire("203.0.113.2").expect("another IP");
          assert_eq!(limiter.open("203.0.113.1"), 2);
          drop(a1);
          assert_eq!(limiter.open("203.0.113.1"), 1);
          assert!(limiter.try_acquire("203.0.113.1").is_some());
      }

      #[test]
      fn client_ip_prefers_cloudflare_then_forwarded_then_peer() {
          let mut headers = HeaderMap::new();
          let peer: SocketAddr = "10.0.0.5:4444".parse().unwrap();
          assert_eq!(client_ip(&headers, Some(peer)), "10.0.0.5");
          assert_eq!(client_ip(&headers, None), "unknown");
          headers.insert("x-real-ip", "10.0.0.9".parse().unwrap());
          assert_eq!(client_ip(&headers, Some(peer)), "10.0.0.9");
          headers.insert("x-forwarded-for", "198.51.100.7, 10.0.0.9".parse().unwrap());
          assert_eq!(client_ip(&headers, Some(peer)), "198.51.100.7");
          headers.insert("cf-connecting-ip", "203.0.113.50".parse().unwrap());
          assert_eq!(client_ip(&headers, Some(peer)), "203.0.113.50");
      }
  }
  ```

  In `src/relay.rs`'s test module:

  ```rust
  #[tokio::test]
  async fn websocket_connections_are_capped_per_client_ip() {
      let state = crate::AppState {
          relay: RelayHub::with_ws_limit(2, TEST_AUTH_TIMEOUT),
          ..memory_identity_state()
      };
      let (base_url, server) = spawn_relay(state.clone()).await;
      let first = connect_astation(&base_url, "astation-ip-1").await;
      let _second = connect_astation(&base_url, "astation-ip-2").await;
      match tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code=astation-ip-3")).await {
          Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
              assert_eq!(response.status().as_u16(), 429)
          }
          other => panic!("a third socket from one IP was accepted: {:?}", other.map(|_| ())),
      }
      drop(first);
      let mut admitted = false;
      for _ in 0..100 {
          if tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code=astation-ip-4"))
              .await
              .is_ok()
          {
              admitted = true;
              break;
          }
          tokio::time::sleep(std::time::Duration::from_millis(20)).await;
      }
      assert!(admitted, "a closed socket frees its slot");
      server.abort();
  }

  #[tokio::test]
  async fn a_room_takes_at_most_four_pending_astations() {
      let state = memory_identity_state();
      let (base_url, server) = spawn_relay(state.clone()).await;
      let code = "astation-crowd";
      let key = TestKey::generate();
      let _owner = verified_astation(&base_url, code, &key, "registered").await;
      let mut pending = Vec::new();
      for _ in 0..MAX_PENDING_ASTATIONS_PER_ROOM {
          pending.push(connect_astation(&base_url, code).await);
      }
      let (mut fifth, _) = tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code={code}"))
          .await
          .expect("upgrade");
      assert_eq!(close_code(&mut fifth).await, 1013);
      assert_eq!(MAX_PENDING_ASTATIONS_PER_ROOM, 4);
      server.abort();
  }
  ```

  Add `pub mod limits;` to `src/cluster/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test limits` and
  `cargo test relay::tests::websocket_connections`.

- [ ] **Step 3: implement.** Above the tests in `src/cluster/limits.rs`:

  ```rust
  //! Connection admission (spec: "Connection limits"): at most
  //! RELAY_WS_MAX_PER_IP concurrent `/ws` connections per client IP on each
  //! replica. (The pending-Astation cap per room lives in the directory.)

  use std::collections::HashMap;
  use std::net::SocketAddr;
  use std::sync::{Arc, Mutex};

  use axum::http::HeaderMap;

  pub const DEFAULT_WS_MAX_PER_IP: usize = 200;

  #[derive(Clone)]
  pub struct WsConnLimiter {
      max_per_ip: usize,
      open: Arc<Mutex<HashMap<String, usize>>>,
  }

  /// One admitted socket; its slot is released when dropped.
  pub struct WsPermit {
      limiter: WsConnLimiter,
      ip: String,
  }

  impl Drop for WsPermit {
      fn drop(&mut self) {
          let mut open = self.limiter.open.lock().unwrap_or_else(|e| e.into_inner());
          if let Some(count) = open.get_mut(&self.ip) {
              *count -= 1;
              if *count == 0 {
                  open.remove(&self.ip);
              }
          }
      }
  }

  impl WsConnLimiter {
      pub fn new(max_per_ip: usize) -> Self {
          Self {
              max_per_ip,
              open: Arc::default(),
          }
      }

      pub fn from_env() -> Self {
          let max = std::env::var("RELAY_WS_MAX_PER_IP")
              .ok()
              .and_then(|value| value.trim().parse().ok())
              .filter(|max: &usize| *max > 0)
              .unwrap_or(DEFAULT_WS_MAX_PER_IP);
          Self::new(max)
      }

      pub fn try_acquire(&self, ip: &str) -> Option<WsPermit> {
          let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
          let count = open.entry(ip.to_string()).or_insert(0);
          if *count >= self.max_per_ip {
              return None;
          }
          *count += 1;
          Some(WsPermit {
              limiter: self.clone(),
              ip: ip.to_string(),
          })
      }

      /// Open sockets from `ip` on this replica.
      pub fn open(&self, ip: &str) -> usize {
          self.open
              .lock()
              .unwrap_or_else(|e| e.into_inner())
              .get(ip)
              .copied()
              .unwrap_or(0)
      }
  }

  fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
      headers
          .get(name)
          .and_then(|value| value.to_str().ok())
          .map(str::trim)
          .filter(|value| !value.is_empty())
  }

  /// The client's IP: Cloudflare's header (it can't be forged through the
  /// tunnel), the first X-Forwarded-For entry, X-Real-IP, then the peer.
  pub fn client_ip(headers: &HeaderMap, peer: Option<SocketAddr>) -> String {
      header(headers, "cf-connecting-ip")
          .or_else(|| {
              header(headers, "x-forwarded-for")
                  .and_then(|value| value.split(',').next())
                  .map(str::trim)
                  .filter(|value| !value.is_empty())
          })
          .or_else(|| header(headers, "x-real-ip"))
          .map(str::to_string)
          .or_else(|| peer.map(|peer| peer.ip().to_string()))
          .unwrap_or_else(|| "unknown".to_string())
  }
  ```

  In `src/relay.rs`:
  - change `pub(crate) const MAX_PENDING_ASTATIONS_PER_ROOM: usize = 0;` to
    `pub(crate) const MAX_PENDING_ASTATIONS_PER_ROOM: usize = 4;` (and its
    comment to `/// Pending Astation sockets allowed per room.`);
  - add `use crate::cluster::limits::{client_ip, WsConnLimiter, WsPermit};`;
  - add `pub ws_limiter: WsConnLimiter,` to `HubParts`, `ws_limiter: WsConnLimiter,`
    to `HubInner`, `ws_limiter: parts.ws_limiter,` in `from_parts`, and
    `ws_limiter: WsConnLimiter::from_env(),` in `HubParts::single_instance`;
  - add to `impl RelayHub`:

    ```rust
    pub(crate) fn ws_limiter(&self) -> &WsConnLimiter {
        &self.inner.ws_limiter
    }

    #[cfg(test)]
    pub(crate) fn with_ws_limit(max_per_ip: usize, auth_timeout: Duration) -> Self {
        Self::from_parts(HubParts {
            ws_limiter: WsConnLimiter::new(max_per_ip),
            ..HubParts::single_instance(InMemoryRoomDirectory::new(), auth_timeout)
        })
    }
    ```

  - change `ws_handler`'s signature and add the admission check right after
    the draining check:

    ```rust
    pub async fn ws_handler(
        State(state): State<AppState>,
        Query(params): Query<WsQuery>,
        headers: axum::http::HeaderMap,
        peer: Option<axum::extract::ConnectInfo<std::net::SocketAddr>>,
        ws: WebSocketUpgrade,
    ) -> impl IntoResponse {
        if state.relay.is_draining() {
            return (StatusCode::SERVICE_UNAVAILABLE, "Relay is restarting, reconnect").into_response();
        }
        let ip = client_ip(&headers, peer.map(|axum::extract::ConnectInfo(address)| address));
        let Some(permit) = state.relay.ws_limiter().try_acquire(&ip) else {
            tracing::warn!("Refused a WebSocket: too many connections from one address");
            return (StatusCode::TOO_MANY_REQUESTS, "Too many WebSocket connections from this address")
                .into_response();
        };
    ```

    and pass the permit into both `on_upgrade` closures:
    `ws.on_upgrade(move |socket| handle_ws(hub, identity, code, role, atem_id, socket, permit))`;
  - give `handle_ws` a last parameter `_permit: WsPermit,` (held until it
    returns).

  In `src/cluster/redis/mod.rs` `connect_cluster`, add
  `ws_limiter: crate::cluster::limits::WsConnLimiter::from_env(),` to the
  `HubParts { … }`.

- [ ] **Step 4: run and watch it pass.** `cargo test`, the Redis suite.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): per-IP WebSocket cap and at most 4 pending Astations per room

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 33: Prometheus metrics at `/metrics`

**Files:** create `src/cluster/metrics.rs`; modify `src/cluster/mod.rs`,
`src/main.rs`, `src/cluster/redis/mod.rs`, `src/cluster/redis/bus.rs`,
`src/relay.rs`, `src/cluster/local.rs`, `src/cluster/ratelimit.rs`.

**Interfaces.**
Produces:
- `pub struct Metrics` (atomics): `bus_published`, `bus_received`,
  `slow_client_closes`, `rate_limited_http`, `rate_limited_ws`
  (all `pub AtomicU64`), plus `observe_redis(&self, elapsed: Duration, ok: bool)`
  and `render(&self, replica_id: &str, sockets: (usize, usize), rooms: usize) -> String`
- `pub fn metrics() -> &'static Metrics` (process-wide)
- `GET /metrics` (text format 0.0.4), outside rate limiting.

Per replica: sockets by role, rooms, bus publish/receive counts, Redis call
latency histogram and errors, slow-client closes, rate-limit rejections
(shared HTTP limiter and the `/ws` per-IP cap).

- [ ] **Step 1: write the tests.** New `src/cluster/metrics.rs`:

  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn renders_prometheus_text() {
          let metrics = Metrics::default();
          metrics.bus_published.fetch_add(3, Ordering::Relaxed);
          metrics.bus_received.fetch_add(2, Ordering::Relaxed);
          metrics.slow_client_closes.fetch_add(1, Ordering::Relaxed);
          metrics.rate_limited_ws.fetch_add(4, Ordering::Relaxed);
          metrics.observe_redis(Duration::from_micros(700), true);
          metrics.observe_redis(Duration::from_millis(30), false);
          let text = metrics.render("a1b2c3d4e5f6", (7, 3), 5);
          for line in [
              "relay_replica_info{replica=\"a1b2c3d4e5f6\"} 1",
              "relay_sockets{role=\"atem\"} 7",
              "relay_sockets{role=\"astation\"} 3",
              "relay_rooms 5",
              "relay_bus_published_total 3",
              "relay_bus_received_total 2",
              "relay_slow_client_closes_total 1",
              "relay_rate_limited_total{kind=\"http\"} 0",
              "relay_rate_limited_total{kind=\"ws\"} 4",
              "relay_redis_calls_total 2",
              "relay_redis_errors_total 1",
              "relay_redis_latency_seconds_bucket{le=\"0.001\"} 1",
              "relay_redis_latency_seconds_bucket{le=\"0.05\"} 2",
              "relay_redis_latency_seconds_bucket{le=\"+Inf\"} 2",
              "relay_redis_latency_seconds_count 2",
              "# TYPE relay_redis_latency_seconds histogram",
          ] {
              assert!(text.lines().any(|l| l == line), "missing {line:?} in\n{text}");
          }
          assert!(text.contains("relay_redis_latency_seconds_sum 0.0307"));
      }
  }
  ```

  In `src/main.rs` tests:

  ```rust
  #[tokio::test]
  async fn metrics_are_served() {
      let response = router(test_state())
          .oneshot(Request::builder().uri("/metrics").body(Body::empty()).unwrap())
          .await
          .unwrap();
      assert_eq!(response.status(), StatusCode::OK);
      assert_eq!(response.headers()["content-type"], "text/plain; version=0.0.4");
      let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
      let text = String::from_utf8(body.to_vec()).unwrap();
      assert!(text.contains("relay_sockets{role=\"atem\"} 0"), "{text}");
      assert!(text.contains("relay_replica_info{replica=\"local\"} 1"), "{text}");
  }
  ```

  Add `pub mod metrics;` to `src/cluster/mod.rs`.

- [ ] **Step 2: run and watch it fail.** `cargo test metrics`.

- [ ] **Step 3: implement.** Above the tests in `src/cluster/metrics.rs`:

  ```rust
  //! Per-replica metrics in the Prometheus text format (spec: "Metrics").
  //! Plain atomics, rendered by hand: no metrics crate needed.

  use std::fmt::Write as _;
  use std::sync::atomic::{AtomicU64, Ordering};
  use std::sync::OnceLock;
  use std::time::Duration;

  /// Histogram bucket upper bounds for Redis call latency, in seconds.
  const LATENCY_BUCKETS: [f64; 9] = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25];

  #[derive(Default)]
  pub struct Metrics {
      pub bus_published: AtomicU64,
      pub bus_received: AtomicU64,
      pub slow_client_closes: AtomicU64,
      pub rate_limited_http: AtomicU64,
      pub rate_limited_ws: AtomicU64,
      redis_calls: AtomicU64,
      redis_errors: AtomicU64,
      /// Cumulative counts per LATENCY_BUCKETS bound.
      redis_latency_buckets: [AtomicU64; 9],
      redis_latency_micros: AtomicU64,
  }

  pub fn metrics() -> &'static Metrics {
      static METRICS: OnceLock<Metrics> = OnceLock::new();
      METRICS.get_or_init(Metrics::default)
  }

  impl Metrics {
      pub fn observe_redis(&self, elapsed: Duration, ok: bool) {
          self.redis_calls.fetch_add(1, Ordering::Relaxed);
          if !ok {
              self.redis_errors.fetch_add(1, Ordering::Relaxed);
          }
          self.redis_latency_micros
              .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
          let seconds = elapsed.as_secs_f64();
          for (bound, count) in LATENCY_BUCKETS.iter().zip(&self.redis_latency_buckets) {
              if seconds <= *bound {
                  count.fetch_add(1, Ordering::Relaxed);
              }
          }
      }

      pub fn render(&self, replica_id: &str, sockets: (usize, usize), rooms: usize) -> String {
          let get = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
          let mut out = String::new();
          let _ = writeln!(out, "# HELP relay_replica_info This relay replica.");
          let _ = writeln!(out, "# TYPE relay_replica_info gauge");
          let _ = writeln!(out, "relay_replica_info{{replica=\"{replica_id}\"}} 1");
          let _ = writeln!(out, "# HELP relay_sockets Live WebSockets on this replica.");
          let _ = writeln!(out, "# TYPE relay_sockets gauge");
          let _ = writeln!(out, "relay_sockets{{role=\"atem\"}} {}", sockets.0);
          let _ = writeln!(out, "relay_sockets{{role=\"astation\"}} {}", sockets.1);
          let _ = writeln!(out, "# HELP relay_rooms Rooms with a socket on this replica.");
          let _ = writeln!(out, "# TYPE relay_rooms gauge");
          let _ = writeln!(out, "relay_rooms {rooms}");
          for (name, help, value) in [
              ("relay_bus_published_total", "Messages published to other replicas.", get(&self.bus_published)),
              ("relay_bus_received_total", "Messages received from the bus.", get(&self.bus_received)),
              ("relay_slow_client_closes_total", "Sockets closed for a full send queue.", get(&self.slow_client_closes)),
              ("relay_redis_calls_total", "Redis calls.", get(&self.redis_calls)),
              ("relay_redis_errors_total", "Failed or timed-out Redis calls.", get(&self.redis_errors)),
          ] {
              let _ = writeln!(out, "# HELP {name} {help}");
              let _ = writeln!(out, "# TYPE {name} counter");
              let _ = writeln!(out, "{name} {value}");
          }
          let _ = writeln!(out, "# HELP relay_rate_limited_total Requests refused by a rate or connection limit.");
          let _ = writeln!(out, "# TYPE relay_rate_limited_total counter");
          let _ = writeln!(out, "relay_rate_limited_total{{kind=\"http\"}} {}", get(&self.rate_limited_http));
          let _ = writeln!(out, "relay_rate_limited_total{{kind=\"ws\"}} {}", get(&self.rate_limited_ws));
          let _ = writeln!(out, "# HELP relay_redis_latency_seconds Redis call latency.");
          let _ = writeln!(out, "# TYPE relay_redis_latency_seconds histogram");
          for (bound, count) in LATENCY_BUCKETS.iter().zip(&self.redis_latency_buckets) {
              let _ = writeln!(out, "relay_redis_latency_seconds_bucket{{le=\"{bound}\"}} {}", get(count));
          }
          let calls = get(&self.redis_calls);
          let _ = writeln!(out, "relay_redis_latency_seconds_bucket{{le=\"+Inf\"}} {calls}");
          let _ = writeln!(
              out,
              "relay_redis_latency_seconds_sum {}",
              get(&self.redis_latency_micros) as f64 / 1_000_000.0
          );
          let _ = writeln!(out, "relay_redis_latency_seconds_count {calls}");
          out
      }
  }
  ```

  (`{bound}` prints `0.001`, `0.05`, … with Rust's shortest float form, as
  the test expects; `0.0307` is 700 µs + 30 ms.)

  Hook the counters in:
  - `src/cluster/redis/mod.rs` `RedisConn::run`: wrap the timeout:

    ```rust
    let started = std::time::Instant::now();
    let result = match tokio::time::timeout(REDIS_TIMEOUT, op(self.manager.clone())).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(redis_error(error)),
        Err(_) => Err(StoreError::Unavailable("redis call timed out".to_string())),
    };
    crate::cluster::metrics::metrics().observe_redis(started.elapsed(), result.is_ok());
    result
    ```

  - `src/cluster/redis/bus.rs`: replace `RedisBus::publish` with

    ```rust
    async fn publish(&self, channel: String, payload: String) -> Result<(), StoreError> {
        let result = self
            .conn
            .run(|mut c| async move {
                redis::cmd("PUBLISH")
                    .arg(&channel)
                    .arg(&payload)
                    .query_async::<i64>(&mut c)
                    .await
                    .map(|_| ())
            })
            .await;
        if result.is_ok() {
            crate::cluster::metrics::metrics()
                .bus_published
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
        result
    }
    ```

  - `src/relay.rs` `spawn_bus_dispatcher`: first line inside the `while let`
    body: `crate::cluster::metrics::metrics().bus_received.fetch_add(1, Ordering::Relaxed);`;
  - `src/cluster/local.rs` `close_slow`: add
    `crate::cluster::metrics::metrics().slow_client_closes.fetch_add(1, Ordering::Relaxed);`;
  - `src/cluster/ratelimit.rs` `shared_rate_limit`, in the `Limited` arm before
    returning: `crate::cluster::metrics::metrics().rate_limited_http.fetch_add(1, std::sync::atomic::Ordering::Relaxed);`;
  - `src/relay.rs` `ws_handler`, in the `else` branch of the permit check:
    `crate::cluster::metrics::metrics().rate_limited_ws.fetch_add(1, Ordering::Relaxed);`.

  In `src/main.rs`, add the handler and route it in `router` next to
  `/health` (outside the rate-limited groups):

  ```rust
  /// GET /metrics — Prometheus text format, per replica (not proxied by nginx).
  async fn metrics_handler(State(state): State<AppState>) -> impl IntoResponse {
      let local = state.relay.local();
      let body = cluster::metrics::metrics().render(
          state.relay.replica_id(),
          local.count_by_role(),
          local.room_count(),
      );
      ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], body)
  }
  ```

  ```rust
  .route("/metrics", get(metrics_handler))
  ```

- [ ] **Step 4: run and watch it pass.** `cargo test`, the Redis suite, and
  `curl -s localhost:3000/metrics` on a running relay.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/src
  git commit -m "feat(relay): per-replica Prometheus metrics at /metrics

  🤖 Built with SMT <smt@agora.build>"
  ```

### Task 34: load test client (`relay-server/loadtest/`)

**Files:** create `relay-server/loadtest/Cargo.toml`,
`relay-server/loadtest/src/main.rs`, `relay-server/loadtest/Cargo.lock`
(generated); modify `.github/workflows/ci.yml` (build it), `.gitignore`.

**What it does.** Opens `--astations` Astation sockets (legacy mode, one
room each) and `--atems-per-astation` Atem sockets per room, spread over
the `--url`s (round-robin, to hit each replica or one nginx), ramping at
`--ramp-per-sec` sockets per second. Once all are open, for `--duration-secs`
every Atem sends one frame per `--interval-ms` to its Astation and every
Astation broadcasts one frame per interval to its Atems. Frames carry a
send timestamp; receivers record the latency. Every 10 s it prints sockets,
frame counts and p50/p99 of that window. At the end it prints the totals and
**PASS** only if p99 < 100 ms, no frame was dropped, and no socket failed or
dropped. Memory stability over the 30 minutes is checked on the relays
(`docker stats`, `relay_sockets` / process RSS), not by this client.

Default run (the spec's target): `--astations 10000 --atems-per-astation 2`
(30k sockets), `--duration-secs 1800`, `--interval-ms 5000`.

- [ ] **Step 1: create the crate.** `relay-server/loadtest/Cargo.toml`:

  ```toml
  [package]
  name = "relay-loadtest"
  version = "0.1.0"
  edition = "2021"
  publish = false

  # Its own workspace: not part of the relay build or its Docker image.
  [workspace]

  [dependencies]
  tokio = { version = "1", features = ["full"] }
  tokio-tungstenite = "0.24"
  futures-util = "0.3"
  serde_json = "1"
  ```

  Add `relay-server/loadtest/target/` to the repo root `.gitignore` (next to
  `relay-server/target/`).

- [ ] **Step 2: write `relay-server/loadtest/src/main.rs`:**

  ```rust
  //! Relay load test (docs/specs/2026-09-30-relay-multi-replica.md,
  //! "Scaling to 10k+", step 4). Run it before claiming 10k users and before
  //! raising any limit.
  //!
  //!   cargo run --release -- --url ws://relay-a:3000/ws --url ws://relay-b:3000/ws
  //!
  //! One client host needs `ulimit -n 65535` and
  //! `sysctl -w net.ipv4.ip_local_port_range="1024 65535"` for 30k sockets,
  //! and the relays need RELAY_WS_MAX_PER_IP above the per-replica share.

  use std::sync::atomic::{AtomicU64, Ordering};
  use std::sync::{Arc, Mutex, OnceLock};
  use std::time::{Duration, Instant};

  use futures_util::{SinkExt, StreamExt};
  use tokio_tungstenite::{connect_async, tungstenite::Message};

  const USAGE: &str = "usage: relay-loadtest [--url ws://host:port/ws]... [--astations N] \
  [--atems-per-astation N] [--interval-ms N] [--duration-secs N] [--ramp-per-sec N] [--run-id ID]";

  /// Pass criteria (spec).
  const P99_LIMIT_MS: f64 = 100.0;

  struct Args {
      urls: Vec<String>,
      astations: usize,
      atems_per_astation: usize,
      interval: Duration,
      duration: Duration,
      ramp_per_sec: u64,
      run_id: String,
  }

  fn parse_args() -> Result<Args, String> {
      let mut args = Args {
          urls: Vec::new(),
          astations: 10_000,
          atems_per_astation: 2,
          interval: Duration::from_millis(5_000),
          duration: Duration::from_secs(1_800),
          ramp_per_sec: 500,
          run_id: format!("lt{}", std::process::id()),
      };
      let mut it = std::env::args().skip(1);
      while let Some(flag) = it.next() {
          let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
          let number = |text: String| text.parse::<u64>().map_err(|e| format!("{flag}: {e}"));
          match flag.as_str() {
              "--url" => args.urls.push(value()?),
              "--astations" => args.astations = number(value()?)? as usize,
              "--atems-per-astation" => args.atems_per_astation = number(value()?)? as usize,
              "--interval-ms" => args.interval = Duration::from_millis(number(value()?)?),
              "--duration-secs" => args.duration = Duration::from_secs(number(value()?)?),
              "--ramp-per-sec" => args.ramp_per_sec = number(value()?)?.max(1),
              "--run-id" => args.run_id = value()?,
              "-h" | "--help" => return Err(USAGE.to_string()),
              other => return Err(format!("unknown flag {other}\n{USAGE}")),
          }
      }
      if args.urls.is_empty() {
          args.urls.push("ws://127.0.0.1:3000/ws".to_string());
      }
      Ok(args)
  }

  fn now_us() -> u64 {
      static START: OnceLock<Instant> = OnceLock::new();
      START.get_or_init(Instant::now).elapsed().as_micros() as u64
  }

  #[derive(Default)]
  struct Stats {
      open: AtomicU64,
      connect_errors: AtomicU64,
      dropped_sockets: AtomicU64,
      up_sent: AtomicU64,
      up_received: AtomicU64,
      down_expected: AtomicU64,
      down_received: AtomicU64,
      window: Mutex<Vec<u32>>,
      all: Mutex<Vec<u32>>,
  }

  impl Stats {
      fn record(&self, sent_us: u64) {
          let micros = now_us().saturating_sub(sent_us).min(u32::MAX as u64) as u32;
          self.window.lock().unwrap().push(micros);
      }

      fn bump(counter: &AtomicU64, by: u64) {
          counter.fetch_add(by, Ordering::Relaxed);
      }
  }

  fn percentile_ms(sorted: &[u32], p: f64) -> f64 {
      if sorted.is_empty() {
          return 0.0;
      }
      let index = ((sorted.len() - 1) as f64 * p).round() as usize;
      sorted[index] as f64 / 1000.0
  }

  /// One Astation (legacy, keyless room `code`) broadcasting every interval
  /// until `stop`; records Atem → Astation latency.
  async fn astation(
      url: String,
      code: String,
      atems: usize,
      stats: Arc<Stats>,
      stop: Instant,
      interval: Duration,
      ready: tokio::sync::oneshot::Sender<bool>,
  ) {
      let socket = match connect_async(format!("{url}?role=astation&code={code}")).await {
          Ok((socket, _)) => socket,
          Err(_) => {
              Stats::bump(&stats.connect_errors, 1);
              let _ = ready.send(false);
              return;
          }
      };
      Stats::bump(&stats.open, 1);
      let _ = ready.send(true);
      let (mut sink, mut stream) = socket.split();
      let reader = tokio::spawn({
          let stats = stats.clone();
          async move {
              while let Some(Ok(message)) = stream.next().await {
                  if let Message::Text(text) = message {
                      if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
                          if let Some(sent) = value["payload"]["lt"]["sent_us"].as_u64() {
                              Stats::bump(&stats.up_received, 1);
                              stats.record(sent);
                          }
                      }
                  }
              }
              if Instant::now() < stop {
                  Stats::bump(&stats.dropped_sockets, 1);
              }
          }
      });
      let mut tick = tokio::time::interval(interval);
      tick.tick().await;
      while Instant::now() < stop {
          tick.tick().await;
          let frame = serde_json::json!({"lt_down": {"sent_us": now_us()}}).to_string();
          if sink.send(Message::Text(frame)).await.is_err() {
              break;
          }
          Stats::bump(&stats.down_expected, atems as u64);
      }
      // Let frames in flight arrive before closing.
      tokio::time::sleep(Duration::from_secs(3)).await;
      let _ = sink.close().await;
      reader.abort();
      stats.open.fetch_sub(1, Ordering::Relaxed);
  }

  /// One Atem in room `code` sending every interval until `stop`; records
  /// Astation → Atem (broadcast) latency.
  async fn atem(url: String, code: String, atem_id: String, stats: Arc<Stats>, stop: Instant, interval: Duration) {
      let socket = match connect_async(format!("{url}?role=atem&code={code}&atem_id={atem_id}")).await {
          Ok((socket, _)) => socket,
          Err(_) => {
              Stats::bump(&stats.connect_errors, 1);
              return;
          }
      };
      Stats::bump(&stats.open, 1);
      let (mut sink, mut stream) = socket.split();
      let reader = tokio::spawn({
          let stats = stats.clone();
          async move {
              while let Some(Ok(message)) = stream.next().await {
                  if let Message::Text(text) = message {
                      if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
                          if let Some(sent) = value["lt_down"]["sent_us"].as_u64() {
                              Stats::bump(&stats.down_received, 1);
                              stats.record(sent);
                          }
                      }
                  }
              }
              if Instant::now() < stop {
                  Stats::bump(&stats.dropped_sockets, 1);
              }
          }
      });
      let mut tick = tokio::time::interval(interval);
      tick.tick().await;
      let mut seq: u64 = 0;
      while Instant::now() < stop {
          tick.tick().await;
          seq += 1;
          let frame = serde_json::json!({"lt": {"seq": seq, "sent_us": now_us()}}).to_string();
          if sink.send(Message::Text(frame)).await.is_err() {
              break;
          }
          Stats::bump(&stats.up_sent, 1);
      }
      tokio::time::sleep(Duration::from_secs(3)).await;
      let _ = sink.close().await;
      reader.abort();
      stats.open.fetch_sub(1, Ordering::Relaxed);
  }

  #[tokio::main]
  async fn main() {
      let args = match parse_args() {
          Ok(args) => args,
          Err(message) => {
              eprintln!("{message}");
              std::process::exit(2);
          }
      };
      let stats = Arc::new(Stats::default());
      let sockets = args.astations * (1 + args.atems_per_astation);
      let ramp = Duration::from_secs_f64(sockets as f64 / args.ramp_per_sec as f64);
      // Traffic runs for `duration` after the ramp; every socket stops together.
      let stop = Instant::now() + ramp + Duration::from_secs(5) + args.duration;
      println!(
          "relay-loadtest: {} sockets ({} rooms × {} Atems + Astation) over {} URL(s), ramp {:.0} s, run {} s",
          sockets,
          args.astations,
          args.atems_per_astation,
          args.urls.len(),
          ramp.as_secs_f64(),
          args.duration.as_secs()
      );

      let reporter = tokio::spawn({
          let stats = stats.clone();
          async move {
              let mut tick = tokio::time::interval(Duration::from_secs(10));
              tick.tick().await;
              loop {
                  tick.tick().await;
                  let mut window = std::mem::take(&mut *stats.window.lock().unwrap());
                  window.sort_unstable();
                  println!(
                      "open {:>6}  up {}/{}  down {}/{}  p50 {:.1} ms  p99 {:.1} ms  errors {}  dropped {}",
                      stats.open.load(Ordering::Relaxed),
                      stats.up_received.load(Ordering::Relaxed),
                      stats.up_sent.load(Ordering::Relaxed),
                      stats.down_received.load(Ordering::Relaxed),
                      stats.down_expected.load(Ordering::Relaxed),
                      percentile_ms(&window, 0.50),
                      percentile_ms(&window, 0.99),
                      stats.connect_errors.load(Ordering::Relaxed),
                      stats.dropped_sockets.load(Ordering::Relaxed),
                  );
                  stats.all.lock().unwrap().extend(window);
              }
          }
      });

      let per_room = Duration::from_secs_f64((1 + args.atems_per_astation) as f64 / args.ramp_per_sec as f64);
      let mut tasks = Vec::with_capacity(sockets);
      for room in 0..args.astations {
          let url = args.urls[room % args.urls.len()].clone();
          let code = format!("loadtest-{}-{room}", args.run_id);
          let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
          tasks.push(tokio::spawn(astation(
              url,
              code.clone(),
              args.atems_per_astation,
              stats.clone(),
              stop,
              args.interval,
              ready_tx,
          )));
          // Atems need the room, which the Astation's connect creates.
          if ready_rx.await.unwrap_or(false) {
              for n in 0..args.atems_per_astation {
                  // Atems go to the other replicas when there are several URLs.
                  let url = args.urls[(room + n + 1) % args.urls.len()].clone();
                  tasks.push(tokio::spawn(atem(
                      url,
                      code.clone(),
                      format!("atem-{n}"),
                      stats.clone(),
                      stop,
                      args.interval,
                  )));
              }
          }
          tokio::time::sleep(per_room).await;
      }
      for task in tasks {
          let _ = task.await;
      }
      reporter.abort();

      let mut all = std::mem::take(&mut *stats.all.lock().unwrap());
      all.extend(std::mem::take(&mut *stats.window.lock().unwrap()));
      all.sort_unstable();
      let p50 = percentile_ms(&all, 0.50);
      let p99 = percentile_ms(&all, 0.99);
      let up_lost = stats.up_sent.load(Ordering::Relaxed) - stats.up_received.load(Ordering::Relaxed).min(stats.up_sent.load(Ordering::Relaxed));
      let down_lost = stats.down_expected.load(Ordering::Relaxed) - stats.down_received.load(Ordering::Relaxed).min(stats.down_expected.load(Ordering::Relaxed));
      let errors = stats.connect_errors.load(Ordering::Relaxed);
      let dropped = stats.dropped_sockets.load(Ordering::Relaxed);
      println!(
          "total: {} samples  p50 {:.1} ms  p99 {:.1} ms  lost frames up {} down {}  connect errors {}  dropped sockets {}",
          all.len(),
          p50,
          p99,
          up_lost,
          down_lost,
          errors,
          dropped
      );
      let pass = p99 < P99_LIMIT_MS && up_lost == 0 && down_lost == 0 && errors == 0 && dropped == 0 && !all.is_empty();
      println!("{}", if pass { "PASS" } else { "FAIL" });
      std::process::exit(if pass { 0 } else { 1 });
  }
  ```

- [ ] **Step 3: build and smoke-run it** against a local two-replica setup
  (Task 19, Step 4) with a small load:

  ```bash
  cd relay-server/loadtest
  cargo build --release          # creates Cargo.lock; commit it
  ./target/release/relay-loadtest --url ws://127.0.0.1:3001/ws --url ws://127.0.0.1:3002/ws \
    --astations 50 --atems-per-astation 2 --duration-secs 30 --interval-ms 1000 --ramp-per-sec 200
  ```

  Expected: `PASS`, p99 in single-digit milliseconds on a laptop.

- [ ] **Step 4: keep it compiling in CI.** In `.github/workflows/ci.yml`,
  `test-relay-server` job, add after the Redis suites step:

  ```yaml
        - name: Build relay load test client
          working-directory: relay-server/loadtest
          run: cargo build --locked
  ```

  and add `relay-server/loadtest/target` to that job's cache `path:` list.

- [ ] **Step 5: commit.**

  ```bash
  git add relay-server/loadtest/Cargo.toml relay-server/loadtest/Cargo.lock \
    relay-server/loadtest/src/main.rs .github/workflows/ci.yml .gitignore
  git commit -m "feat(relay): 30k-socket load test client with p99/drop pass criteria

  🤖 Built with SMT <smt@agora.build>"
  ```

- [ ] **Step 6: the real run (human, before claiming 10k).** Against
  production-like relays (two replicas, Valkey, `RELAY_WS_MAX_PER_IP=20000`
  on the relays for the run), from one or more load hosts prepared as the
  module doc says: `relay-loadtest --url wss://… --astations 10000
  --atems-per-astation 2 --duration-secs 1800`. Pass criteria: `PASS`
  (p99 < 100 ms, no lost frames, no failed or dropped sockets) **and** each
  relay's memory (`docker stats`) flat over the 30 minutes after the ramp.
  Record the result in DEPLOY.md's sizing paragraph.

---

## Self-review

- **Spec coverage.** Units and backings (table): `RoomDirectory` (Tasks 3,
  13), `ReplicaBus` (2, 12), `LocalSockets` (1, 31), `SessionStore` (6, 15),
  `VoiceSessionStore` (7, 16), `RtcSessionStore` (8, 17), `KeyCache` (4, 14,
  26), `RateLimiter` (9, 18). Mode selection and `RELAY_REPLICAS_EXPECTED`
  (19). Replica identity and presence (11). Every Redis key and channel from
  the spec's tables (10, with escaping per pre-flight note 6). Connect,
  frames, cache, ordering, disconnect, pair endpoints (5, 13, 14). Sessions
  with atomic grant/deny, voice with subscribe-before-check and the 64 KB
  cap, RTC atomic join, key-changed and `forget-key`, fixed-window limits
  with fail-open (6–9, 15–18, 26). Failure handling: replica crash, Redis
  unreachable, 3 s connect-path timeout (10, 23). Deploys: SIGTERM drain,
  Coolify apps, nginx, Valkey settings, rollout and rollback (25, 27–30,
  checklist). Scaling: bounded queues, connection limits, metrics, load
  test, sizing (31–34, 30). Testing: every item in the spec's two-relay
  list maps to a test in Tasks 21–23, 25 and 26; `/health` `redis` and
  `replicas` (11); `verify-station.mjs` (28).
- **Placeholders.** None: every code step has the full code; the only
  human-only steps are the Coolify checklist and the production load run,
  as required.
- **Type consistency.** `HubParts` grows by `rate_limiter` (9), `health`
  (11), `cache_rooms` (14) and `ws_limiter` (32), and each task updates both
  construction sites (`HubParts::single_instance` and `connect_cluster`);
  `connect_cluster` (19) already lists the first three, and Task 32 adds the
  fourth. Store handles keep their names and constructors, so the 25
  literal `AppState` constructions (including `knowledge_routes.rs`) compile
  unchanged.

