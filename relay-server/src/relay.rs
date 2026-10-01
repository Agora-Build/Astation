use axum::{
    extract::{
        ws::{CloseFrame, Message, WebSocket},
        Query, State, WebSocketUpgrade,
    },
    http::StatusCode,
    response::{Html, IntoResponse, Json, Response},
};
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use uuid::Uuid;
use validator::Validate;

use crate::cluster::bus::{
    apply_inbox, BroadcastMessage, BusEvent, InboxMessage, LoopbackBus, ReplicaBus,
};
use crate::cluster::directory::{
    AtemJoin, InMemoryRoomDirectory, Promotion, RoomDirectory, RoomInfo, IDENTITY_HOSTNAME,
};
use crate::cluster::health::{ClusterHealth, SingleInstance};
use crate::cluster::keys::KeyCache;
use crate::cluster::limits::{client_ip, WsConnLimiter, WsPermit, DEFAULT_WS_MAX_PER_IP};
use crate::cluster::local::{LocalSockets, SocketOutbox, SocketRole};
use crate::cluster::ratelimit::{NoopRateLimiter, SharedRateLimiter};
use crate::cluster::{ConnRef, StoreError, SINGLE_REPLICA_ID};
use crate::identity_store::{BindOutcome, IdentityError, IdentityStore, RegisterOutcome};
use crate::voice_session::ReplyWaiters;
use crate::AppState;

/// A room code as it may appear in logs: the first 4 characters plus "…".
/// Astation room codes are bearer-like identifiers (whoever presents one joins
/// that room), so logs never carry them in full.
pub(crate) fn mask_code(code: &str) -> String {
    format!("{}…", code.chars().take(4).collect::<String>())
}

// Characters for pairing codes — no ambiguous chars (0/O, 1/I/L excluded)
const CODE_CHARS: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/// WebSocket ping interval in seconds.
/// Keeps idle connections alive across NAT firewalls without high bandwidth overhead.
/// At 100k connections, 60s pings produce ~1700 tiny frames/sec (~10KB/s total) — negligible.
const WS_PING_INTERVAL_SECS: u64 = 60;

/// An Astation must answer the relay-auth challenge within this window.
pub(crate) const RELAY_AUTH_TIMEOUT_SECS: u64 = 10;

/// Most session ids one `relaySessions` resync may list.
const MAX_RELAY_SESSIONS: usize = 1000;

/// Longest session id accepted in a binding message (Astation sends UUIDs).
const MAX_SESSION_ID_LEN: usize = 128;

/// Bound on each identity-store call made while verifying a proof, so a slow
/// or unreachable database can't stall a connection past its challenge.
const IDENTITY_STORE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Close code: shared relay state unavailable, reconnect later (RFC 6455).
pub(crate) const CLOSE_TRY_AGAIN: u16 = 1013;
/// Bound on flushing a socket's queued frames before its close frame.
const CLOSE_FLUSH_TIMEOUT: Duration = Duration::from_millis(1500);

/// Fresh codes POST /api/pair tries before giving up (a collision never
/// overwrites a live room).
const MAX_PAIR_CODE_ATTEMPTS: usize = 10;

/// A key reload after a bus resubscribe gives up after this long.
pub(crate) const KEY_RELOAD_TIMEOUT: Duration = Duration::from_secs(10);

/// Pending Astation sockets allowed per room.
pub(crate) const MAX_PENDING_ASTATIONS_PER_ROOM: usize = 4;

/// Close code on drain (RFC 6455 "service restart"): reconnect elsewhere.
pub(crate) const CLOSE_SERVICE_RESTART: u16 = 1012;

/// How long a drain waits for its sockets to leave their rooms.
pub const DRAIN_GRACE: Duration = Duration::from_secs(5);

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

/// What a hub is built from: in-memory parts by default, Redis-backed
/// parts when REDIS_URL is set.
pub(crate) struct HubParts {
    pub replica_id: String,
    pub directory: Arc<dyn RoomDirectory>,
    pub bus: Arc<dyn ReplicaBus>,
    pub local: LocalSockets,
    pub keys: KeyCache,
    pub rate_limiter: Arc<dyn SharedRateLimiter>,
    pub health: Arc<dyn ClusterHealth>,
    pub auth_timeout: Duration,
    /// Cache routing lookups (Redis mode; one replica reads its own memory).
    pub cache_rooms: bool,
    pub ws_limiter: WsConnLimiter,
}

impl HubParts {
    /// Single-instance parts: in-memory directory, loopback bus, no
    /// shared limits, no Redis.
    pub(crate) fn single_instance(
        directory: InMemoryRoomDirectory,
        auth_timeout: Duration,
    ) -> Self {
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
            cache_rooms: false,
            ws_limiter: WsConnLimiter::new(DEFAULT_WS_MAX_PER_IP),
        }
    }
}

struct HubInner {
    replica_id: String,
    directory: Arc<dyn RoomDirectory>,
    bus: Arc<dyn ReplicaBus>,
    local: LocalSockets,
    keys: KeyCache,
    rate_limiter: Arc<dyn SharedRateLimiter>,
    health: Arc<dyn ClusterHealth>,
    auth_timeout: Duration,
    room_cache: Option<RoomCache>,
    draining: AtomicBool,
    active_sockets: AtomicUsize,
    ws_limiter: WsConnLimiter,
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

    /// Single-instance hub around an already-loaded key cache (startup).
    pub(crate) fn from_keys(keys: KeyCache, ws_max_per_ip: usize) -> Self {
        Self::from_parts(HubParts {
            keys,
            ws_limiter: WsConnLimiter::new(ws_max_per_ip),
            ..HubParts::single_instance(
                InMemoryRoomDirectory::new(),
                Duration::from_secs(RELAY_AUTH_TIMEOUT_SECS),
            )
        })
    }

    pub(crate) fn in_memory(directory: InMemoryRoomDirectory, auth_timeout: Duration) -> Self {
        Self::from_parts(HubParts::single_instance(directory, auth_timeout))
    }

    pub(crate) fn from_parts(parts: HubParts) -> Self {
        Self {
            inner: Arc::new(HubInner {
                replica_id: parts.replica_id,
                directory: parts.directory,
                bus: parts.bus,
                local: parts.local,
                keys: parts.keys,
                rate_limiter: parts.rate_limiter,
                health: parts.health,
                auth_timeout: parts.auth_timeout,
                room_cache: parts.cache_rooms.then(RoomCache::default),
                draining: AtomicBool::new(false),
                active_sockets: AtomicUsize::new(0),
                ws_limiter: parts.ws_limiter,
            }),
        }
    }

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

    #[cfg(test)]
    pub(crate) fn with_auth_timeout(auth_timeout: Duration) -> Self {
        Self::in_memory(InMemoryRoomDirectory::new(), auth_timeout)
    }

    pub(crate) fn rate_limiter(&self) -> Arc<dyn SharedRateLimiter> {
        self.inner.rate_limiter.clone()
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
        if room
            .owner
            .as_ref()
            .is_some_and(|owner| !health.is_live(&owner.replica))
        {
            room.owner = None;
            room.verified = false;
        }
        room.atems
            .retain(|_, connection| health.is_live(&connection.replica));
        room.pending
            .retain(|connection| health.is_live(&connection.replica));
        room
    }

    pub fn replica_id(&self) -> &str {
        &self.inner.replica_id
    }

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
        let left = self.inner.active_sockets.load(Ordering::SeqCst);
        if left > 0 {
            tracing::warn!(
                "Drain grace ({:?}) ended with {} socket(s) still open",
                grace,
                left
            );
        }
        if let Err(error) = self.inner.health.withdraw().await {
            tracing::warn!("Could not withdraw replica presence: {}", error);
        }
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
            by_replica
                .entry(target.replica)
                .or_default()
                .push(target.conn);
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
            reason: code
                .map(|(_, reason)| reason.to_string())
                .unwrap_or_default(),
        };
        if let Err(error) = self.inner.bus.send_inbox(&target.replica, message).await {
            if code.is_none() {
                // An eviction/replacement (or a DELETE /api/pair room close)
                // that did not arrive can leave a live socket behind until
                // the next heartbeat.
                tracing::warn!(
                    "Could not close an evicted or removed connection on replica {}: {}",
                    target.replica,
                    error
                );
            } else {
                tracing::debug!(
                    "Could not close a connection on replica {}: {}",
                    target.replica,
                    error
                );
            }
        }
    }

    /// A room's directory entry changed: other replicas drop cached copies.
    pub(crate) async fn room_changed(&self, code: &str) {
        self.invalidate_room(code);
        let message = BroadcastMessage::RoomChanged {
            code: code.to_string(),
        };
        if let Err(error) = self.inner.bus.broadcast(message).await {
            tracing::debug!(
                "Could not announce a change of room {}: {}",
                mask_code(code),
                error
            );
        }
    }

    /// An Astation key was registered, replaced or forgotten here.
    pub(crate) async fn announce_key_change(&self, astation_id: &str) {
        let message = BroadcastMessage::KeyChanged {
            astation_id: astation_id.to_string(),
        };
        if let Err(error) = self.inner.bus.broadcast(message).await {
            tracing::warn!(
                "Could not announce a key change for Astation {}: {}",
                mask_code(astation_id),
                error
            );
        }
    }

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
        // Without a cache the read above was already fresh.
        self.inner.room_cache.as_ref()?;
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

    /// Apply what other replicas publish to this one (Redis mode). Never
    /// waits on a client or the identity store: socket sends are queued,
    /// key re-reads run on their own tasks. Ends when `events` closes.
    pub(crate) fn spawn_bus_dispatcher(
        &self,
        identity: Arc<dyn IdentityStore>,
        waiters: ReplyWaiters,
        mut events: mpsc::UnboundedReceiver<BusEvent>,
    ) -> JoinHandle<()> {
        let hub = self.clone();
        let reload_busy = Arc::new(AtomicBool::new(false));
        let reload_again = Arc::new(AtomicBool::new(false));
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                crate::cluster::metrics::metrics()
                    .bus_received
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                match event {
                    BusEvent::Inbox(message) => apply_inbox(hub.local(), message),
                    BusEvent::Broadcast(BroadcastMessage::RoomChanged { code }) => {
                        hub.invalidate_room(&code)
                    }
                    BusEvent::Broadcast(BroadcastMessage::KeyChanged { astation_id }) => {
                        let (keys, identity) = (hub.keys().clone(), identity.clone());
                        let hub = hub.clone();
                        tokio::spawn(async move {
                            keys.reload_one(identity.as_ref(), &astation_id).await;
                            hub.drop_verified_owner_if_key_forgotten(&astation_id).await;
                        });
                    }
                    BusEvent::VoiceReply { session_id, reply } => {
                        waiters.wake(&session_id, &reply);
                    }
                    BusEvent::Resubscribed => {
                        // Anything published while we were away is lost:
                        // drop cached rooms and re-read every key.
                        hub.clear_room_cache();
                        // One reload at a time, each bounded; a resubscribe
                        // that lands mid-reload re-arms one more run.
                        reload_again.store(true, Ordering::SeqCst);
                        if !reload_busy.swap(true, Ordering::SeqCst) {
                            let (keys, identity) = (hub.keys().clone(), identity.clone());
                            let (busy, again) = (reload_busy.clone(), reload_again.clone());
                            tokio::spawn(async move {
                                loop {
                                    again.store(false, Ordering::SeqCst);
                                    match tokio::time::timeout(
                                        KEY_RELOAD_TIMEOUT,
                                        keys.load(identity.as_ref()),
                                    )
                                    .await
                                    {
                                        Ok(Ok(_)) => {}
                                        Ok(Err(error)) => tracing::warn!(
                                            "Could not reload relay keys after resubscribing: {}",
                                            error
                                        ),
                                        Err(_) => tracing::warn!(
                                            "Reloading relay keys after resubscribing timed out"
                                        ),
                                    }
                                    busy.store(false, Ordering::SeqCst);
                                    if !again.load(Ordering::SeqCst)
                                        || busy.swap(true, Ordering::SeqCst)
                                    {
                                        break;
                                    }
                                }
                            });
                        }
                    }
                }
            }
        })
    }

    #[cfg(test)]
    pub(crate) async fn create_room(
        &self,
        code: &str,
        hostname: &str,
        now: i64,
    ) -> Result<(), StoreError> {
        self.inner
            .directory
            .create_room(code, hostname, now)
            .await?;
        self.room_changed(code).await;
        Ok(())
    }

    /// A new pairing room under a fresh code from `next_code`; never
    /// overwrites a live room. `None` when every attempt collided.
    pub(crate) async fn create_pair_room(
        &self,
        hostname: &str,
        now: i64,
        mut next_code: impl FnMut() -> String,
    ) -> Result<Option<String>, StoreError> {
        for _ in 0..MAX_PAIR_CODE_ATTEMPTS {
            let code = next_code();
            if self.ensure_room(&code, hostname, now).await? {
                return Ok(Some(code));
            }
            tracing::warn!("Pairing code collision on {}, retrying", mask_code(&code));
        }
        Ok(None)
    }

    pub(crate) async fn ensure_room(
        &self,
        code: &str,
        hostname: &str,
        now: i64,
    ) -> Result<bool, StoreError> {
        let created = self
            .inner
            .directory
            .ensure_room(code, hostname, now)
            .await?;
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
            Promotion::Promoted {
                previous_owner,
                evicted_unverified,
                atems,
            } => {
                if evicted_unverified {
                    tracing::warn!(
                        "Evicting unverified Astation owner of keyed room {}",
                        mask_code(code)
                    );
                }
                // Queued after the promotion, so an Atem frame may precede its
                // `connected` event (as on the legacy-claim path; Astation copes).
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

    /// After a key re-read: when the key is now ABSENT (an admin forgot it,
    /// not a re-registration with a new key), a verified Astation owner on
    /// this replica no longer proves anything, so it is disconnected (the
    /// socket's own cleanup leaves the room through the guarded path).
    /// Idempotent: a repeat finds no local verified owner. A key that could
    /// not be re-read stays cached (stale), so nothing is evicted then.
    pub(crate) async fn drop_verified_owner_if_key_forgotten(&self, astation_id: &str) -> bool {
        if self.inner.keys.contains(astation_id) {
            return false;
        }
        let room = match self.inner.directory.get(astation_id).await {
            Ok(Some(room)) => room,
            Ok(None) => return false,
            Err(error) => {
                tracing::warn!(
                    "Could not check the room of a forgotten key {}: {}",
                    mask_code(astation_id),
                    error
                );
                return false;
            }
        };
        let Some(owner) = room.owner.filter(|owner| {
            room.verified
                && owner.replica == self.inner.replica_id
                && self.inner.local.contains(&owner.conn)
        }) else {
            return false;
        };
        tracing::warn!(
            "Key of Astation {} was forgotten: disconnecting its verified socket",
            mask_code(astation_id)
        );
        self.close_connection(&owner, None).await;
        true
    }

    /// Close every local socket of a room that no longer exists.
    fn evict_room_locally(&self, code: &str) {
        for (connection_id, role) in self.inner.local.connections_in_room(code) {
            // An Astation keeps (or recreates) its room: one that registered
            // just before the sweep must not be closed.
            if matches!(role, SocketRole::Atem { .. }) {
                self.inner.local.evict(&connection_id);
            }
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
        let astation_codes = self.inner.local.codes_with_astations();
        for (done, code) in astation_codes.iter().enumerate() {
            if let Err(error) = self.inner.directory.touch(code).await {
                // Shared state is down: each further touch would only wait
                // out its own timeout. The next sweep tries them all again.
                tracing::warn!(
                    "Room heartbeat failed; skipping {} of {} room(s) this sweep: {}",
                    astation_codes.len() - done,
                    astation_codes.len(),
                    error
                );
                break;
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

/// Generate an 8-char pairing code like "ABCD-EFGH" (no ambiguous chars).
fn generate_pairing_code() -> String {
    let mut rng = rand::thread_rng();
    let chars: Vec<u8> = (0..8)
        .map(|_| CODE_CHARS[rng.gen_range(0..CODE_CHARS.len())])
        .collect();
    let s = String::from_utf8(chars).unwrap();
    format!("{}-{}", &s[..4], &s[4..])
}

// --- Request / Response types ---

#[derive(Deserialize, Validate)]
pub struct CreatePairRequest {
    #[validate(length(min = 1, max = 255))]
    pub hostname: String,
}

#[derive(Serialize, Deserialize)]
pub struct CreatePairResponse {
    pub code: String,
}

#[derive(Serialize, Deserialize)]
pub struct PairStatusResponse {
    pub paired: bool,
    pub hostname: String,
    /// Number of Atems currently connected (0 = none). For backward compat,
    /// `atem_connected` is derived as `atem_count > 0`.
    pub atem_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub atem_ids: Option<Vec<String>>,
    pub atem_connected: bool,
    pub astation_connected: bool,
    pub expired: bool,
}

#[derive(Serialize)]
pub struct DeletePairResponse {
    pub closed: bool,
}

#[derive(Deserialize)]
pub struct WsQuery {
    // Pairing-based auth (traditional)
    pub role: Option<String>,
    pub code: Option<String>,
    // Session-based auth (after HTTP auth)
    pub session: Option<String>,
    // Atem identity — stable ID used to distinguish multiple Atems in the same room.
    // Typically the Atem's hostname. Auto-generated by the relay if not provided.
    pub atem_id: Option<String>,
}

#[derive(Deserialize)]
pub struct PairPageQuery {
    pub code: String,
}

// --- Handlers ---

fn relay_state_unavailable(error: &StoreError) -> (StatusCode, Json<serde_json::Value>) {
    tracing::error!("Relay state unavailable: {}", error);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({"error": "relay state unavailable"})),
    )
}

fn ws_unavailable(error: &StoreError) -> Response {
    tracing::error!("Refused a WebSocket, relay state unavailable: {}", error);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        "Relay state unavailable, retry shortly",
    )
        .into_response()
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

    let now = chrono::Utc::now().timestamp();
    let code = match state
        .relay
        .create_pair_room(&body.hostname, now, generate_pairing_code)
        .await
    {
        Ok(Some(code)) => code,
        Ok(None) => {
            tracing::error!(
                "No free pairing code after {} attempts",
                MAX_PAIR_CODE_ATTEMPTS
            );
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "could not allocate a pairing code"})),
            )
                .into_response();
        }
        Err(error) => return relay_state_unavailable(&error).into_response(),
    };

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
        Ok(false) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Room not found"})),
        )
            .into_response(),
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
    headers: axum::http::HeaderMap,
    peer: Option<axum::extract::ConnectInfo<std::net::SocketAddr>>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if state.relay.is_draining() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "Relay is restarting, reconnect",
        )
            .into_response();
    }
    let ip = client_ip(
        &headers,
        peer.map(|axum::extract::ConnectInfo(address)| address),
    );
    let Some(permit) = state.relay.ws_limiter().try_acquire(&ip) else {
        crate::cluster::metrics::metrics()
            .rate_limited_ws
            .fetch_add(1, Ordering::Relaxed);
        tracing::warn!(
            "Refused a WebSocket: {} connections already open from one address",
            state.relay.ws_limiter().open(&ip)
        );
        return (
            StatusCode::TOO_MANY_REQUESTS,
            "Too many WebSocket connections from this address",
        )
            .into_response();
    };
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
                    tracing::debug!(
                        "Could not refresh session {}: {}",
                        mask_code(&session_id),
                        error
                    );
                }
                let atem_id = params
                    .atem_id
                    .clone()
                    .unwrap_or_else(|| "session-atem".to_string());
                let identity = state.identity.clone();
                return ws
                    .on_upgrade(move |socket| {
                        handle_ws(hub, identity, code, role, atem_id, socket, permit)
                    })
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
        None => {
            return (StatusCode::BAD_REQUEST, "Missing code or session parameter").into_response()
        }
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
    ws.on_upgrade(move |socket| handle_ws(hub, identity, code, role, atem_id, socket, permit))
        .into_response()
}

/// Percent-decode an incoming atem_id and filter to a safe id, preserving
/// non-ASCII characters. Falls back to a random id when empty/missing.
fn sanitize_atem_id(raw: Option<&str>) -> String {
    let decoded = urlencoding::decode(raw.unwrap_or(""))
        .map(|c| c.into_owned())
        .unwrap_or_default();
    let filtered: String = decoded
        .chars()
        .filter(|c| !c.is_ascii() || c.is_ascii_alphanumeric() || *c == '-')
        .collect();
    if filtered.is_empty() {
        format!("atem-{:x}", rand::thread_rng().gen::<u32>())
    } else {
        filtered
    }
}

// --- Astation relay identity (proof of possession) ---
//
// Exact protocol: docs/knowledge-sync-plan.md, "Extension: Astation
// proof-of-possession + durable pairing". Summary:
//
//   relay → Astation (first frame on every role=astation socket; old Astations
//   ignore it because it has no atem_id/connection_id):
//     {"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"<64 hex>"}
//   Astation → relay (intercepted, never forwarded):
//     {"type":"relayAuth","astation_id","public_key","signature"}
//     signature = DER ECDSA P-256/SHA-256 over
//     "station-relay-auth-v1\n<challenge>\n<astation_id>"
//   relay → Astation: {"type":"relayAuthResult","status":"registered|verified|rejected","message"}
//   then, from a verified connection only: relaySessions / relayBind /
//   relayUnbind, each answered with a relayAck.
//
// No key registered for the room code: the socket owns the room at once
// (legacy mode — relays as before but can't bind sessions); a valid proof
// registers its key (trust on first use). Key registered: the socket is
// pending — no room ownership, no Atem traffic — until it proves that key;
// a wrong proof or none within the timeout is rejected and closed.

const RELAY_AUTH_PROTOCOL: &str = "relay-auth-1";
const RELAY_AUTH_CONTEXT: &str = "station-relay-auth-v1";

/// A DER-encoded ECDSA P-256 signature is at most 72 bytes.
const MAX_SIGNATURE_BYTES: usize = 72;

/// Lowercase hex.
pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Decode hex (either case). `None` on odd length or a non-hex character.
fn hex_decode(hex: &str) -> Option<Vec<u8>> {
    fn nibble(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    let bytes = hex.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    bytes
        .chunks(2)
        .map(|pair| Some((nibble(pair[0])? << 4) | nibble(pair[1])?))
        .collect()
}

/// A P-256 X9.63 uncompressed public key as lowercase hex (65 bytes = 130
/// chars, `04` prefix), or `None` if `hex` isn't one.
fn normalize_public_key(hex: &str) -> Option<String> {
    let lower = hex.to_ascii_lowercase();
    (lower.len() == 130 && lower.starts_with("04") && hex_decode(&lower).is_some()).then_some(lower)
}

/// The DER signature bytes, or `None` if `hex` isn't a plausible one.
fn decode_signature(hex: &str) -> Option<Vec<u8>> {
    hex_decode(hex).filter(|sig| !sig.is_empty() && sig.len() <= MAX_SIGNATURE_BYTES)
}

/// The exact UTF-8 string an Astation signs.
fn relay_auth_signing_message(challenge: &str, astation_id: &str) -> String {
    format!("{RELAY_AUTH_CONTEXT}\n{challenge}\n{astation_id}")
}

/// Verify `signature` (DER) by `public_key_hex` over the signing message.
fn verify_relay_signature(
    public_key_hex: &str,
    challenge: &str,
    astation_id: &str,
    signature: &[u8],
) -> bool {
    let Some(public_key) = hex_decode(public_key_hex) else {
        return false;
    };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_ASN1, public_key)
        .verify(
            relay_auth_signing_message(challenge, astation_id).as_bytes(),
            signature,
        )
        .is_ok()
}

/// 32 random bytes as 64 lowercase hex characters.
fn new_relay_challenge() -> String {
    hex_encode(&rand::thread_rng().gen::<[u8; 32]>())
}

fn relay_auth_challenge_frame(challenge: &str) -> String {
    serde_json::json!({
        "type": "relayAuthChallenge",
        "protocol": RELAY_AUTH_PROTOCOL,
        "challenge": challenge,
    })
    .to_string()
}

fn relay_auth_result_frame(status: &str, message: &str) -> String {
    serde_json::json!({
        "type": "relayAuthResult",
        "status": status,
        "message": message,
    })
    .to_string()
}

fn relay_ack_ok(for_type: &str) -> String {
    serde_json::json!({"type": "relayAck", "for": for_type, "ok": true}).to_string()
}

/// `relaySessions` success: also reports how many listed sessions were
/// skipped because another Astation owns them.
fn relay_sessions_ack(skipped: u64) -> String {
    serde_json::json!({
        "type": "relayAck",
        "for": "relaySessions",
        "ok": true,
        "skipped": skipped,
    })
    .to_string()
}

fn relay_ack_err(for_type: &str, message: &str) -> String {
    serde_json::json!({
        "type": "relayAck",
        "for": for_type,
        "ok": false,
        "message": message,
    })
    .to_string()
}

/// The relay-auth frame type of an Astation message, if it is one. These are
/// handled (or dropped) by the relay and never forwarded to Atems.
fn relay_control_type(message: &serde_json::Value) -> Option<&str> {
    let kind = message.get("type")?.as_str()?;
    matches!(
        kind,
        "relayAuth"
            | "relaySessions"
            | "relayBind"
            | "relayUnbind"
            | "relayAuthChallenge"
            | "relayAuthResult"
            | "relayAck"
    )
    .then_some(kind)
}

fn valid_session_id(session_id: &str) -> bool {
    !session_id.is_empty()
        && session_id.len() <= MAX_SESSION_ID_LEN
        && session_id.chars().all(|c| c.is_ascii_graphic())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AuthState {
    /// No key was registered at connect: owns the room like an old Astation,
    /// but can't bind sessions unless it proves a key.
    Legacy,
    /// A key is registered: must prove it before it owns the room.
    Pending,
    /// Proved (or registered) the room's key.
    Verified,
}

struct AstationAuth {
    challenge: String,
    deadline: Instant,
    state: AuthState,
}

/// Record a successful verification without blocking or failing it.
fn touch_key_in_background(identity: &Arc<dyn IdentityStore>, astation_id: &str, now: i64) {
    let identity = identity.clone();
    let astation_id = astation_id.to_string();
    tokio::spawn(async move {
        if let Err(error) = identity.touch_key(&astation_id, now).await {
            tracing::warn!(
                "Could not record verification for Astation {}: {}",
                mask_code(&astation_id),
                error
            );
        }
    });
}

const KEY_MISMATCH: &str = "public_key does not match the key registered for this astation_id";

/// Check a `relayAuth` message. On success returns the status to report
/// (`registered` or `verified`); on failure the rejection message.
///
/// A key in the relay's cache verifies with no I/O (the store is only touched
/// in the background), so registered Astations keep relaying through a
/// database outage. A presented key that differs from the cached one triggers
/// a re-read (to pick up an admin reset); if the store is unreachable it is
/// rejected. Registration needs the store: `INSERT … ON CONFLICT DO NOTHING`
/// first, then the cache.
async fn verify_relay_auth(
    hub: &RelayHub,
    identity: &Arc<dyn IdentityStore>,
    code: &str,
    challenge: &str,
    message: &serde_json::Value,
    now: i64,
) -> Result<&'static str, &'static str> {
    let field = |name: &str| message.get(name).and_then(|value| value.as_str());
    let astation_id = field("astation_id").ok_or("invalid relayAuth message")?;
    if astation_id != code {
        return Err("astation_id does not match this connection");
    }
    let public_key = field("public_key")
        .and_then(normalize_public_key)
        .ok_or("invalid public_key")?;
    let signature = field("signature")
        .and_then(decode_signature)
        .ok_or("invalid signature")?;
    if !verify_relay_signature(&public_key, challenge, astation_id, &signature) {
        return Err("signature verification failed");
    }

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

/// Apply a `relaySessions` / `relayBind` / `relayUnbind` from a verified
/// Astation; returns the `relayAck` frame.
async fn apply_binding_message(
    identity: &dyn IdentityStore,
    code: &str,
    kind: &str,
    message: &serde_json::Value,
    now: i64,
) -> String {
    let store_error = |error: crate::identity_store::IdentityError| {
        tracing::error!(
            "Identity store error on {} from Astation {}: {}",
            kind,
            mask_code(code),
            error
        );
        relay_ack_err(kind, "identity store unavailable")
    };
    match kind {
        "relaySessions" => {
            let Some(listed) = message.get("sessions").and_then(|value| value.as_array()) else {
                return relay_ack_err(kind, "invalid relaySessions message");
            };
            if listed.len() > MAX_RELAY_SESSIONS {
                tracing::warn!(
                    "Refused relaySessions from Astation {}: {} ids (max {})",
                    mask_code(code),
                    listed.len(),
                    MAX_RELAY_SESSIONS
                );
                return relay_ack_err(kind, "too many sessions (max 1000)");
            }
            let mut sessions = Vec::with_capacity(listed.len());
            for value in listed {
                match value.as_str().filter(|id| valid_session_id(id)) {
                    Some(id) => sessions.push(id.to_string()),
                    None => return relay_ack_err(kind, "invalid session_id"),
                }
            }
            match identity.replace_all(code, &sessions, now).await {
                Ok(outcome) => {
                    if outcome.skipped > 0 {
                        tracing::warn!(
                            "Astation {} resync skipped {} session(s) bound to another Astation",
                            mask_code(code),
                            outcome.skipped
                        );
                    }
                    tracing::info!(
                        "Astation {} resynced sessions: {} bound, {} removed",
                        mask_code(code),
                        outcome.bound,
                        outcome.removed
                    );
                    relay_sessions_ack(outcome.skipped)
                }
                Err(error) => store_error(error),
            }
        }
        "relayBind" | "relayUnbind" => {
            let Some(session_id) = message
                .get("session_id")
                .and_then(|value| value.as_str())
                .filter(|id| valid_session_id(id))
            else {
                return relay_ack_err(kind, "invalid session_id");
            };
            if kind == "relayBind" {
                match identity.bind(session_id, code, now).await {
                    Ok(BindOutcome::Bound) => {
                        tracing::info!(
                            "Astation {} bound session {}",
                            mask_code(code),
                            mask_code(session_id)
                        );
                        relay_ack_ok(kind)
                    }
                    Ok(BindOutcome::OwnedByOther) => {
                        tracing::warn!(
                            "Astation {} tried to bind session {} owned by another Astation",
                            mask_code(code),
                            mask_code(session_id)
                        );
                        relay_ack_err(kind, "session is bound to another Astation")
                    }
                    Err(error) => store_error(error),
                }
            } else {
                match identity.unbind(session_id, code).await {
                    Ok(removed) => {
                        tracing::info!(
                            "Astation {} unbound session {} (removed: {})",
                            mask_code(code),
                            mask_code(session_id),
                            removed
                        );
                        relay_ack_ok(kind)
                    }
                    Err(error) => store_error(error),
                }
            }
        }
        _ => relay_ack_err(kind, "unsupported message"),
    }
}

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
                tracing::debug!(
                    "Ignoring repeated relayAuth from Astation {}",
                    mask_code(code)
                );
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
                    hub.local()
                        .send(connection_id, relay_auth_result_frame(status, message));
                    let was_pending = auth.state == AuthState::Pending;
                    auth.state = AuthState::Verified;
                    if let Err(error) = hub.promote_verified(code, connection_id, was_pending).await
                    {
                        tracing::error!(
                            "Relay state unavailable promoting Astation {}: {}",
                            mask_code(code),
                            error
                        );
                        hub.local().close_with(
                            connection_id,
                            CLOSE_TRY_AGAIN,
                            "relay state unavailable",
                        );
                        return false;
                    }
                    tracing::info!("Astation {} relay identity {}", mask_code(code), status);
                    true
                }
                Err(reason) => {
                    tracing::warn!(
                        "Rejected relayAuth for Astation {}: {}",
                        mask_code(code),
                        reason
                    );
                    hub.local()
                        .send(connection_id, relay_auth_result_frame("rejected", reason));
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
                    hub.deliver(
                        &owner,
                        relay_connection_event(atem_id, connection_id, "connected"),
                    )
                    .await;
                }
                Ok(Registration::Registered)
            }
        };
    };
    // The challenge is always the first frame.
    hub.local()
        .send(connection_id, relay_auth_challenge_frame(&auth.challenge));
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
/// close) or on a close request (flush what was queued, then that close
/// frame).
async fn write_loop<S>(mut ws_sink: S, mut outbox: SocketOutbox, code: String)
where
    S: futures_util::Sink<Message> + Unpin,
{
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
                    // Frames queued before the close request go first (a
                    // relayAuthResult before its 1013, as `evict` flushes).
                    // `close_with` dropped the sender, so the queue is finite;
                    // the flush is bounded so a stalled client can't hold it.
                    let flush = async {
                        while let Ok(text) = outbox.frames.try_recv() {
                            outbox.sent(&text);
                            if ws_sink.send(Message::Text(text)).await.is_err() {
                                return false;
                            }
                        }
                        true
                    };
                    let flushed = tokio::time::timeout(CLOSE_FLUSH_TIMEOUT, flush).await;
                    if !matches!(flushed, Ok(true)) {
                        tracing::debug!("WS flush before close failed for {}", mask_code(&code));
                    }
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
                        // Off the queue: its bytes no longer count toward the cap.
                        outbox.sent(&text);
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
    _permit: WsPermit,
) {
    let _active = ActiveSocket::new(&hub);
    let socket_role = match role.as_str() {
        "atem" => SocketRole::Atem {
            atem_id: atem_id.clone(),
        },
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
    let mut reader_close = outbox.close.clone();

    // An Astation gets a challenge; it must prove the key first when one is
    // registered for this room code (decided from the key cache, no I/O).
    let mut astation_auth = (role == "astation").then(|| AstationAuth {
        challenge: new_relay_challenge(),
        deadline: Instant::now() + hub.auth_timeout(),
        state: AuthState::Legacy,
    });

    // The writer runs from the start, so a refusal below still reaches the client.
    let mut write_task = tokio::spawn(write_loop(ws_sink, outbox, code.clone()));

    // Upgraded after the drain listed the sockets (SeqCst: a socket is
    // either listed or sees the flag here): close it with 1012 before it
    // joins its room, so nobody is told it connected.
    if hub.is_draining() {
        local.close_with(&connection_id, CLOSE_SERVICE_RESTART, "relay restarting");
        let _ = tokio::time::timeout(Duration::from_secs(2), &mut write_task).await;
        write_task.abort();
        return;
    }

    let registration = register_connection(
        &hub,
        &code,
        &atem_id,
        &connection_id,
        astation_auth.as_mut(),
    )
    .await;
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
            local.close_with(
                &connection_id,
                CLOSE_TRY_AGAIN,
                "too many pending connections",
            );
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
    let mut watch_close = true;
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
            .map(|deadline| {
                deadline
                    .saturating_duration_since(Instant::now())
                    .min(read_timeout)
            })
            .unwrap_or(read_timeout);
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
                        Ok(Some(RoomInfo {
                            owner: Some(owner), ..
                        })) => {
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
                        tracing::debug!(
                            "Dropping stale Astation connection: code={}",
                            mask_code(&code)
                        );
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
        "atem" => match hub
            .directory()
            .leave_atem(&code, &atem_id, &connection_id)
            .await
        {
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

fn status_update<'a>(payload: &'a serde_json::Value) -> Option<(&'a str, &'a serde_json::Value)> {
    if payload.get("type")?.as_str()? != "statusUpdate" {
        return None;
    }
    let data = payload.get("data")?;
    Some((data.get("status")?.as_str()?, data.get("data")?))
}

/// Log an Atem's auth request (masked). Observation only: bindings come
/// exclusively from a verified Astation's relayBind/relaySessions.
fn log_atem_auth_attempt(code: &str, atem_id: &str, text: &str) {
    if !tracing::enabled!(tracing::Level::DEBUG) {
        return;
    }
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(text) else {
        return;
    };
    let Some(("auth", auth_data)) = status_update(&payload) else {
        return;
    };
    let session = auth_data
        .get("session_id")
        .and_then(|value| value.as_str())
        .filter(|session_id| !session_id.is_empty())
        .map(mask_code)
        .unwrap_or_else(|| "-".to_string());
    tracing::debug!(
        "Atem auth attempt: code={} atem_id={} session={}",
        mask_code(code),
        atem_id,
        session
    );
}

/// GET /pair?code=XXXX — HTML landing page for pairing.
pub async fn pair_page_handler(
    State(state): State<AppState>,
    Query(params): Query<PairPageQuery>,
) -> impl IntoResponse {
    let room = match state.relay.room(&params.code).await {
        Ok(room) => room,
        Err(error) => {
            tracing::error!("Relay state unavailable for the pair page: {}", error);
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Html(
                    "<h1>Temporarily unavailable</h1><p>Please retry in a moment.</p>".to_string(),
                ),
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
    Html(render_pair_page(
        &params.code,
        &room.hostname,
        &initial_status,
    ))
    .into_response()
}

struct InitialPageStatus {
    atem_connected: bool,
    astation_connected: bool,
    expired: bool,
}

/// HTML-escape a string to prevent XSS attacks
fn html_escape(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '&' => "&amp;".to_string(),
            '<' => "&lt;".to_string(),
            '>' => "&gt;".to_string(),
            '"' => "&quot;".to_string(),
            '\'' => "&#x27;".to_string(),
            '/' => "&#x2F;".to_string(),
            _ => c.to_string(),
        })
        .collect()
}

fn render_pair_page(code: &str, hostname: &str, status: &InitialPageStatus) -> String {
    let code_esc = html_escape(code);
    let hostname_esc = html_escape(hostname);
    let code_url = urlencoding::encode(code);
    // Initial state classes for JS
    let atem_dot = if status.atem_connected {
        "dot connected"
    } else {
        "dot"
    };
    let astation_dot = if status.astation_connected {
        "dot connected"
    } else {
        "dot"
    };
    let expired_class = if status.expired { " expired" } else { "" };

    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Atem Pairing — {code}</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#0a0a0a;color:#e0e0e0}}
    .card{{background:#1a1a2e;border-radius:16px;padding:40px 48px;text-align:center;width:100%;max-width:440px;box-shadow:0 8px 32px rgba(0,0,0,.4);transition:opacity .4s}}
    .card.expired{{opacity:.45;pointer-events:none}}
    h2{{font-size:20px;color:#fff;margin-bottom:6px}}
    .sub{{font-size:14px;color:#888;margin-bottom:4px}}
    .code{{font-size:46px;font-weight:700;letter-spacing:5px;color:#00d4aa;margin:20px 0;font-family:'SF Mono',monospace}}
    .hostname{{font-size:13px;color:#555;margin-bottom:28px}}
    .btn{{display:inline-block;padding:11px 30px;background:#00d4aa;color:#0a0a0a;border-radius:8px;text-decoration:none;font-weight:600;font-size:15px;transition:background .2s}}
    .btn:hover{{background:#00f5c4}}
    .btn-close{{display:inline-block;padding:11px 30px;background:#2a1a1a;color:#ff6b6b;border:1px solid #ff6b6b44;border-radius:8px;font-weight:600;font-size:15px;cursor:pointer;transition:all .2s}}
    .btn-close:hover{{background:#ff6b6b22}}
    .status-row{{display:flex;justify-content:center;gap:24px;margin-top:28px;font-size:13px;color:#666}}
    .dot{{width:8px;height:8px;border-radius:50%;background:#333;display:inline-block;margin-right:6px;transition:background .3s}}
    .dot.connected{{background:#00d4aa;box-shadow:0 0 6px #00d4aa88}}
    .info-box{{background:#0f1a14;border:1px solid #00d4aa33;border-radius:10px;padding:16px;margin:20px 0;font-size:13px;text-align:left}}
    .info-row{{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #ffffff08}}
    .atem-tag{{background:#0f1a14;border:1px solid #00d4aa44;border-radius:4px;padding:2px 8px;margin:2px;display:inline-block;font-size:12px;color:#00d4aa}}
    .info-row:last-child{{border-bottom:none}}
    .info-label{{color:#666}}
    .info-value{{color:#ccc;font-family:'SF Mono',monospace;font-size:12px}}
    .success-icon{{font-size:36px;margin-bottom:12px}}
    .download{{margin-top:20px;font-size:13px;color:#444}}
    .download a{{color:#00d4aa;text-decoration:none}}
    #expired-msg{{color:#ff6b6b;font-size:14px;margin-top:12px;display:none}}
    #closed-msg{{color:#888;font-size:14px;margin-top:12px;display:none}}
    #view-waiting,#view-paired{{display:none}}
  </style>
</head>
<body>
  <div class="card{expired_class}" id="card">
    <div id="view-waiting">
      <h2>Atem Pairing</h2>
      <p class="sub">Open in Astation to connect</p>
      <div class="code">{code}</div>
      <div class="hostname">Host: {hostname}</div>
      <a class="btn" href="astation://pair?code={code_url}">Open in Astation</a>
      <div id="expired-msg">⏱ This pairing code has expired.</div>
      <div class="download"><p>No Astation? <a href="https://github.com/AgoraIO-Community/astation/releases">Download</a></p></div>
    </div>

    <div id="view-paired">
      <div class="success-icon">🔗</div>
      <h2>Connected!</h2>
      <p class="sub" style="margin-bottom:16px">Atem and Astation are paired via relay</p>
      <div class="info-box">
        <div class="info-row"><span class="info-label">Atem(s)</span><span class="info-value" id="atem-list">—</span></div>
        <div class="info-row"><span class="info-label">Code</span><span class="info-value">{code}</span></div>
      </div>
      <button class="btn-close" onclick="window.close()">Close Page</button>
    </div>

    <div class="status-row">
      <span><span class="{atem_dot}" id="atem-dot"></span>Atem</span>
      <span><span class="{astation_dot}" id="astation-dot"></span>Astation</span>
    </div>
  </div>

  <script>
    var CODE = {code_json};
    var pollTimer = null;

    function setDot(id, on) {{
      var el = document.getElementById(id);
      if (on) el.classList.add('connected'); else el.classList.remove('connected');
    }}

    function showExpired() {{
      document.getElementById('card').classList.add('expired');
      document.getElementById('expired-msg').style.display = 'block';
      document.getElementById('view-waiting').style.display = 'block';
      clearTimeout(pollTimer);
    }}

    function renderAtemList(atemIds) {{
      var list = document.getElementById('atem-list');
      if (!atemIds || atemIds.length === 0) {{
        list.innerHTML = '—';
        return;
      }}
      list.innerHTML = atemIds.map(function(id) {{
        return '<span class="atem-tag">' + id.replace(/</g,'&lt;') + '</span>';
      }}).join('');
    }}

    function showPaired(data) {{
      document.getElementById('view-waiting').style.display = 'none';
      document.getElementById('view-paired').style.display = 'block';
      renderAtemList(data.atem_ids);
      // Keep polling — new Atems may connect after the first one
      pollTimer = setTimeout(poll, 2000);
    }}

    function showWaiting() {{
      document.getElementById('view-waiting').style.display = 'block';
      document.getElementById('view-paired').style.display = 'none';
    }}

    async function poll() {{
      try {{
        var resp = await fetch('/api/pair/' + CODE);
        if (resp.status === 404) {{ showExpired(); return; }}
        var data = await resp.json();
        setDot('atem-dot', data.atem_connected);
        setDot('astation-dot', data.astation_connected);
        if (data.expired) {{ showExpired(); return; }}
        if (data.paired) {{ showPaired(data); return; }}
        showWaiting();
        pollTimer = setTimeout(poll, 2000);
      }} catch(e) {{
        pollTimer = setTimeout(poll, 5000);
      }}
    }}

    poll();
  </script>
</body>
</html>"#,
        code = code_esc,
        hostname = hostname_esc,
        code_url = code_url,
        code_json = serde_json::to_string(code).unwrap_or_else(|_| format!("\"{}\"", code_esc)),
        expired_class = expired_class,
        atem_dot = atem_dot,
        astation_dot = astation_dot,
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::voice_session::VoiceSessionStore;
    use tokio::net::TcpStream;
    use tokio_tungstenite::{
        tungstenite::Message as ClientMessage, MaybeTlsStream, WebSocketStream,
    };

    pub(crate) type TestSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

    /// A frame queued before `close_with` reaches the client before the
    /// close frame, even when the writer first runs after both (a slow host:
    /// the relayAuthResult that precedes a 1013 was being dropped).
    #[tokio::test]
    async fn write_loop_flushes_queued_frames_before_a_close_code() {
        let local = LocalSockets::new();
        let outbox = local.register("c1", "ROOM", SocketRole::Astation);
        assert!(local.send("c1", "first".to_string()));
        assert!(local.send("c1", "second".to_string()));
        assert!(local.close_with("c1", CLOSE_TRY_AGAIN, "relay state unavailable"));
        let mut written: Vec<Message> = Vec::new();
        tokio::time::timeout(
            Duration::from_secs(2),
            write_loop(&mut written, outbox, "ROOM".to_string()),
        )
        .await
        .expect("the writer stops after the close frame");
        let texts: Vec<String> = written
            .iter()
            .filter_map(|message| match message {
                Message::Text(text) => Some(text.to_string()),
                _ => None,
            })
            .collect();
        assert_eq!(texts, ["first", "second"], "{written:?}");
        match written.last() {
            Some(Message::Close(Some(frame))) => {
                assert_eq!(frame.code, CLOSE_TRY_AGAIN);
                assert_eq!(frame.reason, "relay state unavailable");
            }
            other => panic!("expected a 1013 close last, got {other:?}"),
        }
    }

    /// The writer releases each frame's bytes from the queue's byte cap as
    /// it sends it, on the normal path and on the flush before a close.
    #[tokio::test]
    async fn write_loop_releases_the_bytes_of_frames_it_sends() {
        use crate::cluster::local::QueueLimits;
        let local = LocalSockets::with_limits(QueueLimits {
            frames: 100,
            bytes: 10,
            stall: Duration::from_secs(60),
        });
        for close_code in [None, Some(CLOSE_TRY_AGAIN)] {
            let outbox = local.register("c1", "ROOM", SocketRole::Astation);
            let queued = outbox.queued_bytes.clone();
            assert!(local.send("c1", "12345".to_string()));
            assert!(local.send("c1", "678".to_string()));
            assert_eq!(queued.load(std::sync::atomic::Ordering::Relaxed), 8);
            match close_code {
                None => assert!(local.evict("c1")),
                Some(code) => assert!(local.close_with("c1", code, "bye")),
            }
            let mut written: Vec<Message> = Vec::new();
            tokio::time::timeout(
                Duration::from_secs(2),
                write_loop(&mut written, outbox, "ROOM".to_string()),
            )
            .await
            .expect("the writer ends");
            assert_eq!(
                queued.load(std::sync::atomic::Ordering::Relaxed),
                0,
                "{close_code:?}"
            );
        }

        // A live socket keeps taking frames past the byte cap's worth in total.
        let outbox = local.register("c2", "ROOM", SocketRole::Astation);
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let sink = Box::pin(futures_util::sink::unfold(
            tx,
            |tx, message: Message| async move {
                tx.send(message).map_err(|_| ())?;
                Ok::<_, ()>(tx)
            },
        ));
        let writer = tokio::spawn(write_loop(sink, outbox, "ROOM".to_string()));
        for n in 0..20 {
            assert!(
                local.send("c2", format!("{n:05}")),
                "frame {n} fits: earlier ones were sent"
            );
            let message = tokio::time::timeout(Duration::from_secs(2), rx.recv())
                .await
                .unwrap();
            assert!(matches!(message, Some(Message::Text(_))));
        }
        writer.abort();
    }

    #[test]
    fn mask_code_shows_only_a_prefix() {
        assert_eq!(mask_code("astation-0123456789abcdef"), "asta…");
        assert_eq!(mask_code("ABCDEFGH"), "ABCD…");
        assert_eq!(mask_code("ab"), "ab…");
        assert_eq!(mask_code(""), "…");
        // Char-based: never splits a multi-byte character (no panic).
        assert_eq!(mask_code("日本語テキスト"), "日本語テ…");
    }

    pub(crate) async fn next_client_json(socket: &mut TestSocket) -> serde_json::Value {
        loop {
            let frame = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
                .await
                .expect("timed out waiting for WebSocket message")
                .expect("WebSocket closed before receiving message")
                .expect("failed to read WebSocket message");
            match frame {
                ClientMessage::Text(text) => {
                    return serde_json::from_str(&text).expect("WebSocket text was not JSON");
                }
                ClientMessage::Close(frame) => {
                    panic!("WebSocket closed unexpectedly: {frame:?}");
                }
                _ => {}
            }
        }
    }

    #[test]
    fn pairing_code_format() {
        let code = generate_pairing_code();
        assert_eq!(code.len(), 9); // 4 + '-' + 4
        assert_eq!(&code[4..5], "-");

        // No ambiguous characters
        let no_hyphen = code.replace('-', "");
        for ch in no_hyphen.chars() {
            assert!(
                CODE_CHARS.contains(&(ch as u8)),
                "Character '{}' should be in CODE_CHARS",
                ch
            );
        }
    }

    #[test]
    fn pairing_code_uniqueness() {
        let codes: Vec<String> = (0..20).map(|_| generate_pairing_code()).collect();
        let unique: std::collections::HashSet<&String> = codes.iter().collect();
        assert!(unique.len() > 1, "Pairing codes should vary");
    }

    #[test]
    fn sanitize_atem_id_preserves_decoded_cjk() {
        // "团队-mac" percent-encoded; non-ASCII preserved, ASCII restricted to [A-Za-z0-9-].
        let encoded = "%E5%9B%A2%E9%98%9F-mac";
        assert_eq!(sanitize_atem_id(Some(encoded)), "团队-mac");
    }

    #[test]
    fn sanitize_atem_id_strips_unsafe_ascii() {
        assert_eq!(sanitize_atem_id(Some("a_b.c d!e")), "abcde");
        assert_eq!(sanitize_atem_id(Some("keep-this-123")), "keep-this-123");
    }

    #[test]
    fn sanitize_atem_id_falls_back_when_empty() {
        let id = sanitize_atem_id(None);
        assert!(id.starts_with("atem-"));
        let id2 = sanitize_atem_id(Some(""));
        assert!(id2.starts_with("atem-"));
    }

    #[test]
    fn relay_connection_event_carries_generation() {
        let event = relay_connection_event(
            "atem-office",
            "43c8a181-6567-49ae-9191-8e103a66cc55",
            "connected",
        );
        let value: serde_json::Value = serde_json::from_str(&event).unwrap();

        assert_eq!(value["atem_id"], "atem-office");
        assert_eq!(
            value["connection_id"],
            "43c8a181-6567-49ae-9191-8e103a66cc55"
        );
        assert_eq!(value["relay_event"], "connected");
    }

    #[test]
    fn pairing_code_no_ambiguous_chars() {
        for _ in 0..100 {
            let code = generate_pairing_code();
            let no_hyphen = code.replace('-', "");
            assert!(!no_hyphen.contains('0'), "Should not contain 0");
            assert!(!no_hyphen.contains('O'), "Should not contain O");
            assert!(!no_hyphen.contains('1'), "Should not contain 1");
            assert!(!no_hyphen.contains('I'), "Should not contain I");
            assert!(!no_hyphen.contains('L'), "Should not contain L");
        }
    }

    #[tokio::test]
    async fn relay_hub_create_and_lookup() {
        let hub = RelayHub::new();
        hub.create_room("ABCD-EFGH", "test-host", now())
            .await
            .unwrap();
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
        directory.insert_for_test(
            "OLD1-CODE",
            RoomInfo::new("old-host", now() - ROOM_EXPIRY_SECS - 10),
        );
        directory.insert_for_test("NEW1-CODE", RoomInfo::new("new-host", now()));
        hub.cleanup_expired().await;
        assert!(
            hub.room("OLD1-CODE").await.unwrap().is_none(),
            "Expired room should be removed"
        );
        assert!(
            hub.room("NEW1-CODE").await.unwrap().is_some(),
            "Fresh room should remain"
        );
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
            RoomInfo {
                atems,
                ..RoomInfo::new("old-host", now() - ROOM_EXPIRY_SECS - 10)
            },
        );
        let mut atem = hub.local().register(
            "connection-old",
            "OLD-ATEM",
            SocketRole::Atem {
                atem_id: "test-atem".into(),
            },
        );
        hub.cleanup_expired().await;
        // Removed (only an Astation keeps a room), and its Atem socket is closed.
        assert!(
            hub.room("OLD-ATEM").await.unwrap().is_none(),
            "Room with only atem connected should be cleaned up"
        );
        assert!(
            atem.frames.recv().await.is_none(),
            "the Atem's socket was closed"
        );
    }

    fn default_status() -> InitialPageStatus {
        InitialPageStatus {
            atem_connected: false,
            astation_connected: false,
            expired: false,
        }
    }

    #[test]
    fn render_pair_page_contains_code() {
        let html = render_pair_page("TEST-CODE", "my-host", &default_status());
        assert!(html.contains("TEST-CODE"));
        assert!(html.contains("my-host"));
        assert!(html.contains("astation://pair?code=TEST-CODE"));
    }

    use crate::cluster::bus::{
        BroadcastMessage as BusBroadcast, InboxMessage, ReplicaBus as BusTrait,
    };
    use crate::cluster::directory::{InMemoryRoomDirectory, RoomInfo, ROOM_EXPIRY_SECS};
    use crate::cluster::local::SocketRole;
    use crate::cluster::{ConnRef, StoreError as ClusterError, SINGLE_REPLICA_ID};

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
        hub.directory()
            .join_atem(code, "atem-live", &ConnRef::new("t1", "r1"))
            .await
            .unwrap();
        hub.directory()
            .join_atem(code, "atem-dead", &ConnRef::new("t2", "dead"))
            .await
            .unwrap();
        hub.directory()
            .add_pending(code, &ConnRef::new("p1", "dead"), now(), 0)
            .await
            .unwrap();
        let room = hub.room(code).await.unwrap().unwrap();
        assert_eq!(room.owner, None);
        assert!(!room.verified);
        assert_eq!(room.atems.keys().collect::<Vec<_>>(), vec!["atem-live"]);
        assert!(room.pending.is_empty());
    }

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
        async fn send_inbox(
            &self,
            replica_id: &str,
            message: InboxMessage,
        ) -> Result<(), ClusterError> {
            self.inbox
                .lock()
                .unwrap()
                .push((replica_id.to_string(), message));
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
            bus: bus.clone(),
            local: local.clone(),
            ..HubParts::single_instance(InMemoryRoomDirectory::new(), TEST_AUTH_TIMEOUT)
        });
        let mut here = local.register("a", "room", SocketRole::Astation);
        hub.deliver_many(
            vec![
                ConnRef::new("a", "r1"),
                ConnRef::new("b", "r2"),
                ConnRef::new("c", "r2"),
            ],
            "frame".to_string(),
        )
        .await;
        assert_eq!(here.frames.recv().await.as_deref(), Some("frame"));
        hub.deliver(&ConnRef::new("x", "r3"), "one".to_string())
            .await;
        hub.close_connection(&ConnRef::new("y", "r2"), None).await;
        hub.close_connection(&ConnRef::new("a", "r1"), Some((1012, "restart")))
            .await;
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
                    InboxMessage::Deliver {
                        connection_ids: vec!["x".into()],
                        frame: "one".into()
                    }
                ),
                (
                    "r2".to_string(),
                    InboxMessage::Close {
                        connection_id: "y".into(),
                        code: None,
                        reason: String::new()
                    }
                ),
            ]
        );
    }

    #[tokio::test]
    async fn cached_routing_follows_room_changed() {
        let directory = InMemoryRoomDirectory::new();
        let hub = RelayHub::from_parts(HubParts {
            cache_rooms: true,
            ..HubParts::single_instance(directory.clone(), TEST_AUTH_TIMEOUT)
        });
        let code = "astation-cache";
        directory
            .claim_owner(code, &test_conn("owner-1"), now())
            .await
            .unwrap();
        assert_eq!(
            hub.route_view(code).await.unwrap().unwrap().owner,
            Some(test_conn("owner-1"))
        );
        // Changed behind the hub's back (another replica): still cached …
        directory
            .claim_owner(code, &test_conn("owner-2"), now())
            .await
            .unwrap();
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
        directory
            .join_atem(code, "atem-a", &test_conn("t-new"))
            .await
            .unwrap();
        assert_eq!(
            hub.find_atem(code, "atem-a", "t-new").await,
            Some(test_conn("t-new"))
        );
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
        identity
            .register_key_if_absent("astation-k", "04AB", 1)
            .await
            .unwrap();
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
            .send(BusEvent::VoiceReply {
                session_id: "voice-1".into(),
                reply: "answer".into(),
            })
            .unwrap();
        assert_eq!(reply.await.unwrap(), "answer");

        events_tx
            .send(BusEvent::Broadcast(BusBroadcast::KeyChanged {
                astation_id: "astation-k".into(),
            }))
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

    /// Poll until `check` holds (dispatcher work runs on spawned tasks).
    async fn eventually(mut check: impl FnMut() -> bool) -> bool {
        for _ in 0..100 {
            if check() {
                return true;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        false
    }

    #[tokio::test]
    async fn bus_dispatcher_room_changed_resubscribe_and_key_reset() {
        use crate::cluster::bus::BusEvent;
        let directory = InMemoryRoomDirectory::new();
        let hub = RelayHub::from_parts(HubParts {
            cache_rooms: true,
            ..HubParts::single_instance(directory.clone(), TEST_AUTH_TIMEOUT)
        });
        let identity = std::sync::Arc::new(InMemoryIdentityStore::new());
        let waiters = crate::voice_session::ReplyWaiters::default();
        let (events_tx, events_rx) = tokio::sync::mpsc::unbounded_channel();
        let task = hub.spawn_bus_dispatcher(identity.clone(), waiters, events_rx);
        let owner = |hub: RelayHub, code: &'static str| async move {
            hub.route_view(code).await.unwrap().unwrap().owner
        };

        // room-changed from another replica drops the cached entry; a
        // second copy (or our own echo) is harmless.
        directory
            .claim_owner("room-a", &test_conn("o1"), now())
            .await
            .unwrap();
        assert_eq!(owner(hub.clone(), "room-a").await, Some(test_conn("o1")));
        directory
            .claim_owner("room-a", &test_conn("o2"), now())
            .await
            .unwrap();
        for _ in 0..2 {
            events_tx
                .send(BusEvent::Broadcast(BusBroadcast::RoomChanged {
                    code: "room-a".into(),
                }))
                .unwrap();
        }
        let mut fresh = false;
        for _ in 0..100 {
            if owner(hub.clone(), "room-a").await == Some(test_conn("o2")) {
                fresh = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(fresh, "room-changed invalidated the cached room");

        // Our own room_changed invalidates locally before announcing.
        directory
            .claim_owner("room-a", &test_conn("o3"), now())
            .await
            .unwrap();
        hub.room_changed("room-a").await;
        assert_eq!(owner(hub.clone(), "room-a").await, Some(test_conn("o3")));

        // Resubscribed: every cached room is dropped and every key re-read.
        directory
            .claim_owner("room-b", &test_conn("b1"), now())
            .await
            .unwrap();
        assert_eq!(owner(hub.clone(), "room-b").await, Some(test_conn("b1")));
        directory
            .claim_owner("room-a", &test_conn("o4"), now())
            .await
            .unwrap();
        directory
            .claim_owner("room-b", &test_conn("b2"), now())
            .await
            .unwrap();
        identity
            .register_key_if_absent("astation-r", "04CD", 1)
            .await
            .unwrap();
        hub.keys().set("astation-gone", "04ef");
        events_tx.send(BusEvent::Resubscribed).unwrap();
        let keys = hub.keys().clone();
        assert!(
            eventually(|| keys.contains("astation-r") && !keys.contains("astation-gone")).await,
            "resubscribe reloaded the keys"
        );
        assert_eq!(owner(hub.clone(), "room-a").await, Some(test_conn("o4")));
        assert_eq!(owner(hub.clone(), "room-b").await, Some(test_conn("b2")));

        // key-changed for a key deleted elsewhere forgets it.
        identity.delete_key("astation-r").await.unwrap();
        events_tx
            .send(BusEvent::Broadcast(BusBroadcast::KeyChanged {
                astation_id: "astation-r".into(),
            }))
            .unwrap();
        assert!(
            eventually(|| !keys.contains("astation-r")).await,
            "key-changed forgot the key"
        );

        drop(events_tx);
        task.await.unwrap();
    }

    /// `list_keys` counts its calls and never returns (until the timeout drops it).
    struct HangingList(std::sync::Arc<std::sync::atomic::AtomicUsize>);

    #[async_trait::async_trait]
    impl IdentityStore for HangingList {
        fn backend_name(&self) -> &'static str {
            "hanging-list"
        }
        async fn get_key(&self, _: &str) -> Result<Option<String>, StoreError> {
            unreachable!()
        }
        async fn register_key_if_absent(
            &self,
            _: &str,
            _: &str,
            _: i64,
        ) -> Result<StoreRegisterOutcome, StoreError> {
            unreachable!()
        }
        async fn touch_key(&self, _: &str, _: i64) -> Result<(), StoreError> {
            unreachable!()
        }
        async fn list_keys(&self) -> Result<Vec<(String, String)>, StoreError> {
            self.0.fetch_add(1, Ordering::SeqCst);
            std::future::pending().await
        }
        async fn bind(&self, _: &str, _: &str, _: i64) -> Result<StoreBindOutcome, StoreError> {
            unreachable!()
        }
        async fn unbind(&self, _: &str, _: &str) -> Result<bool, StoreError> {
            unreachable!()
        }
        async fn replace_all(
            &self,
            _: &str,
            _: &[String],
            _: i64,
        ) -> Result<ReplaceOutcome, StoreError> {
            unreachable!()
        }
        async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, StoreError> {
            unreachable!()
        }
    }

    #[tokio::test(start_paused = true)]
    async fn key_reload_after_resubscribe_is_bounded_and_single_flight() {
        use crate::cluster::bus::BusEvent;
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hub = RelayHub::in_memory(InMemoryRoomDirectory::new(), TEST_AUTH_TIMEOUT);
        let (events_tx, events_rx) = tokio::sync::mpsc::unbounded_channel();
        let task = hub.spawn_bus_dispatcher(
            std::sync::Arc::new(HangingList(calls.clone())),
            crate::voice_session::ReplyWaiters::default(),
            events_rx,
        );
        let settle = || tokio::time::sleep(Duration::from_millis(100));
        events_tx.send(BusEvent::Resubscribed).unwrap();
        settle().await;
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        // Two more mid-reload: no concurrent reload yet.
        events_tx.send(BusEvent::Resubscribed).unwrap();
        events_tx.send(BusEvent::Resubscribed).unwrap();
        settle().await;
        assert_eq!(calls.load(Ordering::SeqCst), 1, "single flight");
        // The first reload times out; the re-armed one runs exactly once.
        tokio::time::sleep(KEY_RELOAD_TIMEOUT).await;
        settle().await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "re-armed once");
        tokio::time::sleep(KEY_RELOAD_TIMEOUT * 2).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "no more runs");
        // Free again afterwards.
        events_tx.send(BusEvent::Resubscribed).unwrap();
        settle().await;
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        drop(events_tx);
        task.await.unwrap();
    }

    #[tokio::test]
    async fn without_cache_routing_reads_the_directory() {
        let directory = InMemoryRoomDirectory::new();
        let hub = RelayHub::in_memory(directory.clone(), TEST_AUTH_TIMEOUT);
        directory
            .claim_owner("room-n", &test_conn("o1"), now())
            .await
            .unwrap();
        assert_eq!(
            hub.route_view("room-n").await.unwrap().unwrap().owner,
            Some(test_conn("o1"))
        );
        directory
            .claim_owner("room-n", &test_conn("o2"), now())
            .await
            .unwrap();
        assert_eq!(
            hub.route_view("room-n").await.unwrap().unwrap().owner,
            Some(test_conn("o2"))
        );
    }

    // --- Integration tests (HTTP endpoint tests) ---

    use axum::{
        body::Body,
        http::{Request, StatusCode as HttpStatusCode},
        Router,
    };
    use tower::ServiceExt;

    fn create_relay_app() -> Router {
        let state = crate::AppState {
            sessions: crate::session_store::SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: crate::rtc_session::RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
        };
        Router::new()
            .route("/api/pair", axum::routing::post(create_pair_handler))
            .route(
                "/api/pair/:code",
                axum::routing::get(pair_status_handler).delete(delete_pair_handler),
            )
            .route("/ws", axum::routing::get(ws_handler))
            .route("/pair", axum::routing::get(pair_page_handler))
            .with_state(state)
    }

    /// Helper: POST /api/pair with given hostname, returns the response body as CreatePairResponse.
    async fn post_create_pair(app: Router, hostname: &str) -> (HttpStatusCode, String) {
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"hostname": "{}"}}"#, hostname)))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let body_str = String::from_utf8(body.to_vec()).unwrap();
        (status, body_str)
    }

    #[tokio::test]
    async fn test_create_pair_endpoint() {
        let app = create_relay_app();
        let (status, body_str) = post_create_pair(app, "my-machine").await;

        assert_eq!(status, HttpStatusCode::CREATED);

        let resp: CreatePairResponse = serde_json::from_str(&body_str).unwrap();
        // Code should be in XXXX-XXXX format (9 chars total)
        assert_eq!(
            resp.code.len(),
            9,
            "Code should be 9 characters (XXXX-XXXX)"
        );
        assert_eq!(
            &resp.code[4..5],
            "-",
            "Code should have hyphen at position 4"
        );
        // Each half should be 4 alphanumeric chars
        let left = &resp.code[..4];
        let right = &resp.code[5..];
        assert!(
            left.chars().all(|c| c.is_ascii_alphanumeric()),
            "Left half should be alphanumeric"
        );
        assert!(
            right.chars().all(|c| c.is_ascii_alphanumeric()),
            "Right half should be alphanumeric"
        );
    }

    #[tokio::test]
    async fn test_create_pair_code_no_ambiguous_chars() {
        // Create several pairs and verify none contain ambiguous characters
        for _ in 0..20 {
            let app = create_relay_app();
            let (status, body_str) = post_create_pair(app, "test-host").await;
            assert_eq!(status, HttpStatusCode::CREATED);

            let resp: CreatePairResponse = serde_json::from_str(&body_str).unwrap();
            let code_no_hyphen = resp.code.replace('-', "");
            assert!(
                !code_no_hyphen.contains('0'),
                "Code should not contain '0': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('O'),
                "Code should not contain 'O': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('1'),
                "Code should not contain '1': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('I'),
                "Code should not contain 'I': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('L'),
                "Code should not contain 'L': {}",
                resp.code
            );
        }
    }

    #[tokio::test]
    async fn test_pair_status_exists() {
        let app = create_relay_app();

        // Step 1: Create a pair
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "dev-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreatePairResponse = serde_json::from_slice(&body).unwrap();
        let code = created.code;

        // Step 2: GET /api/pair/:code should return paired=false
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/pair/{}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: PairStatusResponse = serde_json::from_slice(&body).unwrap();
        assert!(
            !status_resp.paired,
            "Newly created pair should not be paired yet"
        );
        assert_eq!(status_resp.hostname, "dev-machine");
    }

    #[tokio::test]
    async fn test_pair_status_not_found() {
        let app = create_relay_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/pair/NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_pair_page_exists() {
        let app = create_relay_app();

        // Step 1: Create a pair
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "page-test-host"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreatePairResponse = serde_json::from_slice(&body).unwrap();
        let code = created.code;

        // Step 2: GET /pair?code=XXXX should return HTML containing the code
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/pair?code={}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(
            html.contains(&code),
            "HTML page should contain the pairing code"
        );
        assert!(
            html.contains("page-test-host"),
            "HTML page should contain the hostname"
        );
        assert!(
            html.contains("Atem Pairing"),
            "HTML page should contain the page title"
        );
        assert!(
            html.contains(&format!("astation://pair?code={}", code)),
            "HTML page should contain the deep link"
        );
    }

    #[tokio::test]
    async fn test_pair_page_not_found() {
        let app = create_relay_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/pair?code=NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::NOT_FOUND);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(
            html.contains("not found"),
            "404 page should indicate code not found"
        );
    }

    #[tokio::test]
    async fn test_ws_handler_room_not_found() {
        let app = create_relay_app();

        // Send a non-upgrade GET request to /ws with a nonexistent room code.
        // Without the WebSocket upgrade headers, the handler should check the room
        // and return 404 before attempting the upgrade.
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/ws?role=atem&code=NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // The ws_handler checks room existence before upgrade, so a non-upgrade
        // request to a nonexistent room should still fail. Axum returns 400 for
        // missing upgrade headers on WebSocket routes when the handler calls
        // ws.on_upgrade(), but our handler returns 404 before reaching that point
        // for nonexistent rooms.
        // Note: Since the request lacks upgrade headers, axum's WebSocketUpgrade
        // extractor will reject it. The handler won't even run. Axum returns 400
        // or the rejection status. We verify it does NOT return 200/101.
        let status = response.status();
        assert!(
            status == HttpStatusCode::NOT_FOUND
                || status == HttpStatusCode::BAD_REQUEST
                || status == HttpStatusCode::UPGRADE_REQUIRED,
            "Expected 404, 400, or 426 for non-upgrade WS request to nonexistent room, got {}",
            status
        );
    }

    #[tokio::test]
    async fn practical_websocket_replacement_rejects_stale_generation() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("failed to bind test relay");
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, create_relay_app())
                .await
                .expect("test relay failed");
        });
        let base_url = format!("ws://{address}/ws");
        let code = "practical-replacement";
        let atem_id = "atem-office";

        let (mut astation, _) =
            tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code={code}"))
                .await
                .expect("failed to connect Astation");
        // A legacy Astation (no registered key) ignores the challenge and
        // relays as before.
        assert_eq!(
            next_client_json(&mut astation).await["type"],
            "relayAuthChallenge"
        );
        let (mut original, _) = tokio_tungstenite::connect_async(format!(
            "{base_url}?role=atem&code={code}&atem_id={atem_id}"
        ))
        .await
        .expect("failed to connect original Atem");
        let original_event = next_client_json(&mut astation).await;
        assert_eq!(original_event["atem_id"], atem_id);
        assert_eq!(original_event["relay_event"], "connected");
        let original_connection_id = original_event["connection_id"]
            .as_str()
            .expect("connected event lacked connection_id")
            .to_string();

        let (mut replacement, _) = tokio_tungstenite::connect_async(format!(
            "{base_url}?role=atem&code={code}&atem_id={atem_id}"
        ))
        .await
        .expect("failed to connect replacement Atem");
        let replacement_event = next_client_json(&mut astation).await;
        assert_eq!(replacement_event["atem_id"], atem_id);
        assert_eq!(replacement_event["relay_event"], "connected");
        let replacement_connection_id = replacement_event["connection_id"]
            .as_str()
            .expect("replacement event lacked connection_id")
            .to_string();
        assert_ne!(original_connection_id, replacement_connection_id);

        let original_closed = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while let Some(frame) = original.next().await {
                match frame {
                    Ok(ClientMessage::Close(_)) | Err(_) => return true,
                    _ => {}
                }
            }
            true
        })
        .await
        .unwrap_or(false);
        assert!(original_closed, "replaced Atem socket remained open");

        astation
            .send(ClientMessage::Text(
                serde_json::json!({
                    "atem_id": atem_id,
                    "connection_id": original_connection_id,
                    "payload": {"probe": "stale"},
                })
                .to_string(),
            ))
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), replacement.next(),)
                .await
                .is_err(),
            "stale targeted response reached replacement Atem"
        );

        astation
            .send(ClientMessage::Text(
                serde_json::json!({
                    "atem_id": atem_id,
                    "connection_id": replacement_connection_id,
                    "payload": {"probe": "current"},
                })
                .to_string(),
            ))
            .await
            .unwrap();
        assert_eq!(next_client_json(&mut replacement).await["probe"], "current");

        replacement
            .send(ClientMessage::Text(
                serde_json::json!({"probe": "from-atem"}).to_string(),
            ))
            .await
            .unwrap();
        let forwarded = next_client_json(&mut astation).await;
        assert_eq!(forwarded["atem_id"], atem_id);
        assert_eq!(forwarded["connection_id"], replacement_connection_id);
        assert_eq!(forwarded["payload"]["probe"], "from-atem");

        replacement.close(None).await.unwrap();
        let disconnect_event = next_client_json(&mut astation).await;
        assert_eq!(disconnect_event["atem_id"], atem_id);
        assert_eq!(disconnect_event["connection_id"], replacement_connection_id);
        assert_eq!(disconnect_event["relay_event"], "disconnected");

        server.abort();
    }

    #[tokio::test]
    async fn test_create_multiple_pairs_unique_codes() {
        let app = create_relay_app();
        let mut codes = std::collections::HashSet::new();

        for i in 0..10 {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/pair")
                        .header("Content-Type", "application/json")
                        .body(Body::from(format!(r#"{{"hostname": "host-{}"}}"#, i)))
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(response.status(), HttpStatusCode::CREATED);
            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let resp: CreatePairResponse = serde_json::from_slice(&body).unwrap();
            codes.insert(resp.code);
        }

        assert_eq!(codes.len(), 10, "All 10 pairing codes should be unique");
    }

    #[tokio::test]
    async fn test_pairing_code_entropy() {
        // Generate many codes to verify randomness distribution
        let mut first_chars = std::collections::HashMap::new();
        for _ in 0..100 {
            let code = generate_pairing_code();
            let first_char = code.chars().next().unwrap();
            *first_chars.entry(first_char).or_insert(0) += 1;
        }

        // Should have reasonable distribution (at least 5 different first characters out of 100 samples)
        assert!(
            first_chars.len() >= 5,
            "Pairing codes should have good entropy, got {} unique first chars",
            first_chars.len()
        );
    }

    #[tokio::test]
    async fn test_pair_page_xss_protection() {
        // Test that hostname with HTML/JS is safely escaped
        let html = render_pair_page(
            "TEST-CODE",
            "<script>alert('xss')</script>",
            &default_status(),
        );
        // If properly escaped, the literal string should appear, not executed
        assert!(
            !html.contains("<script>alert"),
            "Script tags should be escaped or removed"
        );

        // Test with other XSS vectors
        let html2 = render_pair_page("CODE-123", "' onload='alert(1)'", &default_status());
        assert!(
            !html2.contains("onload='alert"),
            "Event handlers should be escaped"
        );
    }

    #[tokio::test]
    async fn test_pair_status_shows_unpaired_then_paired() {
        let state = crate::AppState {
            sessions: crate::session_store::SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: crate::rtc_session::RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
        };

        // Create pair
        let code = generate_pairing_code();
        state
            .relay
            .create_room(&code, "test-host", now())
            .await
            .unwrap();

        let app = Router::new()
            .route("/api/pair/:code", axum::routing::get(pair_status_handler))
            .with_state(state.clone());

        // Check status before pairing
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/pair/{}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status: PairStatusResponse = serde_json::from_slice(&body).unwrap();
        assert!(!status.paired, "Should not be paired initially");

        // Simulate both sides connecting
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

        // Check status after both connected
        let app2 = Router::new()
            .route("/api/pair/:code", axum::routing::get(pair_status_handler))
            .with_state(state);

        let response = app2
            .oneshot(
                Request::builder()
                    .uri(format!("/api/pair/{}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status: PairStatusResponse = serde_json::from_slice(&body).unwrap();
        assert!(status.paired, "Should be paired after both sides connect");
        assert!(status.astation_connected);
        assert!(status.atem_connected);
    }

    #[tokio::test]
    async fn test_concurrent_pair_creation() {
        use std::sync::Arc;
        use tokio::sync::Mutex;

        let app = Arc::new(Mutex::new(create_relay_app()));
        let mut handles = Vec::new();

        for i in 0..10 {
            let app_clone = app.clone();
            handles.push(tokio::spawn(async move {
                let app = app_clone.lock().await;
                let response = app
                    .clone()
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri("/api/pair")
                            .header("Content-Type", "application/json")
                            .body(Body::from(format!(r#"{{"hostname": "host-{}"}}"#, i)))
                            .unwrap(),
                    )
                    .await
                    .unwrap();

                let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                    .await
                    .unwrap();
                serde_json::from_slice::<CreatePairResponse>(&body)
                    .ok()
                    .map(|r| r.code)
            }));
        }

        let mut codes = std::collections::HashSet::new();
        for handle in handles {
            if let Some(code) = handle.await.unwrap() {
                codes.insert(code);
            }
        }

        assert_eq!(
            codes.len(),
            10,
            "All concurrent pairs should have unique codes"
        );
    }

    #[test]
    fn test_code_chars_does_not_contain_ambiguous() {
        let chars_str = String::from_utf8_lossy(CODE_CHARS);
        assert!(!chars_str.contains('0'), "CODE_CHARS should not contain 0");
        assert!(!chars_str.contains('O'), "CODE_CHARS should not contain O");
        assert!(!chars_str.contains('1'), "CODE_CHARS should not contain 1");
        assert!(!chars_str.contains('I'), "CODE_CHARS should not contain I");
        assert!(!chars_str.contains('L'), "CODE_CHARS should not contain L");
    }

    // ─────────────── Astation proof-of-possession + durable bindings ───────────────

    use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};

    /// A software P-256 key acting as a real Astation's relay identity.
    pub(crate) struct TestKey {
        pair: EcdsaKeyPair,
        rng: ring::rand::SystemRandom,
    }

    impl TestKey {
        pub(crate) fn generate() -> Self {
            let rng = ring::rand::SystemRandom::new();
            let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
                .expect("generate P-256 key");
            let pair =
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng)
                    .expect("load P-256 key");
            Self { pair, rng }
        }

        /// X9.63 uncompressed public key, lowercase hex (what Astation sends).
        pub(crate) fn public_hex(&self) -> String {
            hex_encode(self.pair.public_key().as_ref())
        }

        /// DER signature over the protocol's signed message, lowercase hex.
        pub(crate) fn sign_hex(&self, challenge: &str, astation_id: &str) -> String {
            let message = relay_auth_signing_message(challenge, astation_id);
            let sig = self
                .pair
                .sign(&self.rng, message.as_bytes())
                .expect("sign challenge");
            hex_encode(sig.as_ref())
        }

        pub(crate) fn relay_auth(&self, challenge: &str, astation_id: &str) -> serde_json::Value {
            serde_json::json!({
                "type": "relayAuth",
                "astation_id": astation_id,
                "public_key": self.public_hex(),
                "signature": self.sign_hex(challenge, astation_id),
            })
        }
    }

    pub(crate) const TEST_AUTH_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(400);

    fn identity_state(
        identity: std::sync::Arc<dyn crate::identity_store::IdentityStore>,
    ) -> crate::AppState {
        crate::AppState {
            sessions: crate::session_store::SessionStore::new(),
            relay: RelayHub::with_auth_timeout(TEST_AUTH_TIMEOUT),
            rtc_sessions: crate::rtc_session::RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity,
        }
    }

    fn memory_identity_state() -> crate::AppState {
        identity_state(std::sync::Arc::new(
            crate::identity_store::InMemoryIdentityStore::new(),
        ))
    }

    /// Serve the production router on an ephemeral port; returns the ws base URL.
    pub(crate) async fn spawn_relay(
        state: crate::AppState,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("failed to bind test relay");
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(
                listener,
                crate::router(state).into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .expect("test relay failed");
        });
        (format!("ws://{address}/ws"), server)
    }

    /// Open `role=astation` and read the challenge that must arrive first.
    pub(crate) async fn connect_astation(base_url: &str, code: &str) -> (TestSocket, String) {
        let (mut socket, _) =
            tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code={code}"))
                .await
                .expect("failed to connect Astation");
        let challenge = next_client_json(&mut socket).await;
        assert_eq!(challenge["type"], "relayAuthChallenge");
        assert_eq!(challenge["protocol"], "relay-auth-1");
        let value = challenge["challenge"].as_str().unwrap().to_string();
        assert_eq!(value.len(), 64);
        assert!(value
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)));
        (socket, value)
    }

    pub(crate) async fn connect_atem(base_url: &str, code: &str, atem_id: &str) -> TestSocket {
        tokio_tungstenite::connect_async(format!(
            "{base_url}?role=atem&code={code}&atem_id={atem_id}"
        ))
        .await
        .expect("failed to connect Atem")
        .0
    }

    pub(crate) async fn send_json(socket: &mut TestSocket, value: serde_json::Value) {
        socket
            .send(ClientMessage::Text(value.to_string()))
            .await
            .expect("send failed");
    }

    /// Answer the challenge with `key`; returns the relayAuthResult.
    pub(crate) async fn authenticate(
        socket: &mut TestSocket,
        key: &TestKey,
        code: &str,
        challenge: &str,
    ) -> serde_json::Value {
        send_json(socket, key.relay_auth(challenge, code)).await;
        let result = next_client_json(socket).await;
        assert_eq!(result["type"], "relayAuthResult");
        result
    }

    /// Connect, prove `key`, and assert the expected status.
    pub(crate) async fn verified_astation(
        base_url: &str,
        code: &str,
        key: &TestKey,
        expected_status: &str,
    ) -> TestSocket {
        let (mut socket, challenge) = connect_astation(base_url, code).await;
        let result = authenticate(&mut socket, key, code, &challenge).await;
        assert_eq!(result["status"], expected_status, "{result}");
        socket
    }

    /// Send a control message and return the relay's ack.
    pub(crate) async fn control(
        socket: &mut TestSocket,
        value: serde_json::Value,
    ) -> serde_json::Value {
        let kind = value["type"].as_str().unwrap().to_string();
        send_json(socket, value).await;
        let ack = next_client_json(socket).await;
        assert_eq!(ack["type"], "relayAck");
        assert_eq!(ack["for"], kind.as_str());
        ack
    }

    pub(crate) async fn assert_closed(socket: &mut TestSocket) {
        let closed = tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                match socket.next().await {
                    None | Some(Err(_)) | Some(Ok(ClientMessage::Close(_))) => return true,
                    Some(Ok(ClientMessage::Text(text))) => {
                        panic!("unexpected frame before close: {text}")
                    }
                    Some(Ok(_)) => {}
                }
            }
        })
        .await
        .unwrap_or(false);
        assert!(closed, "socket was not closed");
    }

    pub(crate) async fn assert_silent(socket: &mut TestSocket, millis: u64) {
        match tokio::time::timeout(std::time::Duration::from_millis(millis), socket.next()).await {
            Err(_) => {}
            Ok(Some(Ok(ClientMessage::Text(text)))) => panic!("unexpected frame: {text}"),
            Ok(other) => panic!("unexpected socket event: {other:?}"),
        }
    }

    async fn resolve(state: &crate::AppState, session_id: &str) -> Option<String> {
        state
            .identity
            .resolve(session_id, chrono::Utc::now().timestamp())
            .await
            .unwrap()
    }

    #[test]
    fn signing_message_matches_protocol() {
        assert_eq!(
            relay_auth_signing_message("ab12", "astation-x"),
            "station-relay-auth-v1\nab12\nastation-x"
        );
    }

    #[test]
    fn hex_round_trips_and_rejects_bad_input() {
        assert_eq!(
            hex_decode("00ff10Ab").unwrap(),
            vec![0x00, 0xff, 0x10, 0xab]
        );
        assert_eq!(hex_encode(&[0x00, 0xff, 0x10, 0xab]), "00ff10ab");
        assert_eq!(hex_decode("").unwrap(), Vec::<u8>::new());
        assert!(hex_decode("abc").is_none(), "odd length");
        assert!(hex_decode("zz").is_none(), "non-hex");
        assert!(hex_decode("é1").is_none(), "non-ASCII");
    }

    #[test]
    fn public_key_is_validated_and_lowercased() {
        let key = TestKey::generate();
        let upper = key.public_hex().to_uppercase();
        assert_eq!(normalize_public_key(&upper), Some(key.public_hex()));
        assert!(
            normalize_public_key(&key.public_hex()[..128]).is_none(),
            "too short"
        );
        assert!(
            normalize_public_key(&format!("{}00", key.public_hex())).is_none(),
            "too long"
        );
        let compressed_prefix = format!("02{}", &key.public_hex()[2..]);
        assert!(
            normalize_public_key(&compressed_prefix).is_none(),
            "not 04-prefixed"
        );
        let non_hex = format!("04{}", "g".repeat(128));
        assert!(normalize_public_key(&non_hex).is_none(), "non-hex");
    }

    #[test]
    fn signature_verifies_only_for_the_signed_challenge_and_id() {
        let key = TestKey::generate();
        let other = TestKey::generate();
        let challenge = "11".repeat(32);
        let sig = hex_decode(&key.sign_hex(&challenge, "astation-a")).unwrap();
        assert!(verify_relay_signature(
            &key.public_hex(),
            &challenge,
            "astation-a",
            &sig
        ));
        assert!(!verify_relay_signature(
            &other.public_hex(),
            &challenge,
            "astation-a",
            &sig
        ));
        assert!(!verify_relay_signature(
            &key.public_hex(),
            &"22".repeat(32),
            "astation-a",
            &sig
        ));
        assert!(!verify_relay_signature(
            &key.public_hex(),
            &challenge,
            "astation-b",
            &sig
        ));
        assert!(decode_signature("zz").is_none());
        assert!(decode_signature("").is_none());
        assert!(
            decode_signature(&"ab".repeat(200)).is_none(),
            "longer than a DER P-256 signature"
        );
    }

    #[test]
    fn protocol_frames_have_the_exact_shape() {
        let challenge: serde_json::Value =
            serde_json::from_str(&relay_auth_challenge_frame("ab")).unwrap();
        assert_eq!(
            challenge,
            serde_json::json!({"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"ab"})
        );
        let result: serde_json::Value =
            serde_json::from_str(&relay_auth_result_frame("verified", "ok")).unwrap();
        assert_eq!(
            result,
            serde_json::json!({"type":"relayAuthResult","status":"verified","message":"ok"})
        );
        let ack: serde_json::Value = serde_json::from_str(&relay_ack_ok("relayBind")).unwrap();
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relayBind","ok":true})
        );
        let ack: serde_json::Value = serde_json::from_str(&relay_sessions_ack(3)).unwrap();
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relaySessions","ok":true,"skipped":3})
        );
        let ack: serde_json::Value =
            serde_json::from_str(&relay_ack_err("relayUnbind", "nope")).unwrap();
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relayUnbind","ok":false,"message":"nope"})
        );
    }

    /// An old Astation ignores the challenge: it still relays both ways (also
    /// after the challenge window), but it can never create a binding — not by
    /// control messages and not by the auth traffic the relay passes along.
    #[tokio::test]
    async fn legacy_astation_relays_but_creates_no_bindings() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-legacy";

        let (mut astation, _challenge) = connect_astation(&base_url, code).await;
        tokio::time::sleep(TEST_AUTH_TIMEOUT * 2).await;

        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        let connected = next_client_json(&mut astation).await;
        assert_eq!(connected["relay_event"], "connected");
        let connection_id = connected["connection_id"].as_str().unwrap().to_string();

        // Atem asks to authenticate with a session; Astation grants it.
        send_json(
            &mut atem,
            serde_json::json!({"type":"statusUpdate","data":{"status":"auth","data":{"session_id":"session-legacy"}}}),
        )
        .await;
        let forwarded = next_client_json(&mut astation).await;
        assert_eq!(
            forwarded["payload"]["data"]["data"]["session_id"],
            "session-legacy"
        );
        send_json(
            &mut astation,
            serde_json::json!({
                "atem_id": "atem-a",
                "connection_id": connection_id,
                "payload": {"type":"statusUpdate","data":{"status":"authenticated","data":{}}},
            }),
        )
        .await;
        assert_eq!(
            next_client_json(&mut atem).await["data"]["status"],
            "authenticated"
        );
        send_json(
            &mut astation,
            serde_json::json!({
                "atem_id": "atem-a",
                "connection_id": connection_id,
                "payload": {"type":"statusUpdate","data":{"status":"auth","data":{"status":"granted","session_id":"session-granted"}}},
            }),
        )
        .await;
        assert_eq!(
            next_client_json(&mut atem).await["data"]["data"]["status"],
            "granted"
        );

        // Binding control messages are refused without a verified key.
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":"session-legacy"}),
        )
        .await;
        assert_eq!(ack["ok"], false);
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":["session-legacy"]}),
        )
        .await;
        assert_eq!(ack["ok"], false);

        // Broadcast still reaches the Atem.
        send_json(&mut astation, serde_json::json!({"probe":"broadcast"})).await;
        assert_eq!(next_client_json(&mut atem).await["probe"], "broadcast");

        assert_eq!(resolve(&state, "session-legacy").await, None);
        assert_eq!(resolve(&state, "session-granted").await, None);
        assert_eq!(state.identity.get_key(code).await.unwrap(), None);
        server.abort();
    }

    #[tokio::test]
    async fn valid_proof_registers_key_and_later_connections_verify() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-tofu";
        let key = TestKey::generate();

        let mut first = verified_astation(&base_url, code, &key, "registered").await;
        assert_eq!(
            state.identity.get_key(code).await.unwrap(),
            Some(key.public_hex())
        );

        // Reconnect (e.g. after a network change): pending until verified, then
        // it owns the room and the old socket is closed.
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut first).await["relay_event"],
            "connected"
        );
        let (mut second, challenge) = connect_astation(&base_url, code).await;
        // Uppercase key hex is accepted (compared lowercase).
        let mut auth = key.relay_auth(&challenge, code);
        auth["public_key"] = serde_json::Value::String(key.public_hex().to_uppercase());
        send_json(&mut second, auth).await;
        let result = next_client_json(&mut second).await;
        assert_eq!(result["status"], "verified", "{result}");
        let connected = next_client_json(&mut second).await;
        assert_eq!(connected["relay_event"], "connected");
        assert_eq!(connected["atem_id"], "atem-a");
        assert_closed(&mut first).await;

        send_json(&mut atem, serde_json::json!({"probe":"to-new-owner"})).await;
        assert_eq!(
            next_client_json(&mut second).await["payload"]["probe"],
            "to-new-owner"
        );
        server.abort();
    }

    /// A second key for a registered id is rejected and closed, and while it
    /// was pending it neither owned the room nor saw Atem traffic.
    #[tokio::test]
    async fn wrong_key_is_rejected_and_does_not_take_over_the_room() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-owned";
        let owner_key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &owner_key, "registered").await;
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut owner).await["relay_event"],
            "connected"
        );

        let (mut intruder, challenge) = connect_astation(&base_url, code).await;
        // Pending: no connected events, no Atem traffic, room still the owner's.
        send_json(&mut atem, serde_json::json!({"probe":"while-pending"})).await;
        assert_eq!(
            next_client_json(&mut owner).await["payload"]["probe"],
            "while-pending"
        );
        assert_silent(&mut intruder, 150).await;
        // Its non-control messages go nowhere.
        send_json(&mut intruder, serde_json::json!({"probe":"from-intruder"})).await;
        assert_silent(&mut atem, 150).await;

        let result = authenticate(&mut intruder, &TestKey::generate(), code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut intruder).await;

        // A valid signature by the right key over the wrong challenge fails too.
        let (mut replay, _challenge) = connect_astation(&base_url, code).await;
        let result = authenticate(&mut replay, &owner_key, code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut replay).await;

        assert_eq!(
            state.identity.get_key(code).await.unwrap(),
            Some(owner_key.public_hex())
        );
        send_json(&mut owner, serde_json::json!({"probe":"owner-still-here"})).await;
        assert_eq!(
            next_client_json(&mut atem).await["probe"],
            "owner-still-here"
        );
        send_json(&mut atem, serde_json::json!({"probe":"to-owner"})).await;
        assert_eq!(
            next_client_json(&mut owner).await["payload"]["probe"],
            "to-owner"
        );
        server.abort();
    }

    #[tokio::test]
    async fn pending_connection_times_out() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-timeout";
        let key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &key, "registered").await;

        let (mut silent, _challenge) = connect_astation(&base_url, code).await;
        let result = tokio::time::timeout(TEST_AUTH_TIMEOUT * 5, next_client_json(&mut silent))
            .await
            .expect("no timeout result");
        assert_eq!(result["type"], "relayAuthResult");
        assert_eq!(result["status"], "rejected");
        assert_closed(&mut silent).await;

        // The owner is unaffected.
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut owner).await["relay_event"],
            "connected"
        );
        send_json(&mut atem, serde_json::json!({"probe":"x"})).await;
        assert_eq!(next_client_json(&mut owner).await["payload"]["probe"], "x");
        server.abort();
    }

    #[tokio::test]
    async fn late_answer_from_legacy_connection_is_rejected() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-late";
        let key = TestKey::generate();
        let (mut astation, challenge) = connect_astation(&base_url, code).await;
        tokio::time::sleep(TEST_AUTH_TIMEOUT * 2).await;
        let result = authenticate(&mut astation, &key, code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut astation).await;
        assert_eq!(state.identity.get_key(code).await.unwrap(), None);
        server.abort();
    }

    #[tokio::test]
    async fn proof_for_another_astation_id_is_rejected() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let key = TestKey::generate();
        let (mut astation, challenge) = connect_astation(&base_url, "astation-mine").await;
        let result = authenticate(&mut astation, &key, "astation-theirs", &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut astation).await;
        assert_eq!(state.identity.get_key("astation-mine").await.unwrap(), None);
        assert_eq!(
            state.identity.get_key("astation-theirs").await.unwrap(),
            None
        );
        server.abort();
    }

    #[tokio::test]
    async fn control_messages_are_never_forwarded_to_atems() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-control";
        let key = TestKey::generate();
        let mut astation = verified_astation(&base_url, code, &key, "registered").await;
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut astation).await["relay_event"],
            "connected"
        );

        control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":["s1"]}),
        )
        .await;
        control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":"s2"}),
        )
        .await;
        control(
            &mut astation,
            serde_json::json!({"type":"relayUnbind","session_id":"s2"}),
        )
        .await;
        // A repeated relayAuth and relay→Astation frame types are dropped silently.
        send_json(&mut astation, key.relay_auth(&"00".repeat(32), code)).await;
        send_json(
            &mut astation,
            serde_json::json!({"type":"relayAck","for":"relayBind","ok":true}),
        )
        .await;
        send_json(
            &mut astation,
            serde_json::json!({"type":"relayAuthResult","status":"verified","message":""}),
        )
        .await;
        send_json(&mut astation, serde_json::json!({"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"00"})).await;

        // The first thing the Atem receives is the ordinary broadcast.
        send_json(&mut astation, serde_json::json!({"probe":"after-control"})).await;
        assert_eq!(next_client_json(&mut atem).await["probe"], "after-control");
        assert_silent(&mut astation, 100).await;
        server.abort();
    }

    #[tokio::test]
    async fn binding_messages_drive_resolve_caller() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-binder";
        let key = TestKey::generate();
        let mut astation = verified_astation(&base_url, code, &key, "registered").await;

        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":["s1","s2"]}),
        )
        .await;
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relaySessions","ok":true,"skipped":0})
        );
        assert_eq!(resolve(&state, "s1").await.as_deref(), Some(code));
        assert_eq!(resolve(&state, "s2").await.as_deref(), Some(code));

        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":"s3"}),
        )
        .await;
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relayBind","ok":true})
        );
        assert_eq!(resolve(&state, "s3").await.as_deref(), Some(code));

        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayUnbind","session_id":"s1"}),
        )
        .await;
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relayUnbind","ok":true})
        );
        assert_eq!(resolve(&state, "s1").await, None);

        // Full resync: exactly the listed set.
        control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":["s2"]}),
        )
        .await;
        assert_eq!(resolve(&state, "s2").await.as_deref(), Some(code));
        assert_eq!(resolve(&state, "s3").await, None);

        // Another Astation's session: bind refused, resync skips it.
        let now = chrono::Utc::now().timestamp();
        state
            .identity
            .bind("s-other", "astation-other", now)
            .await
            .unwrap();
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":"s-other"}),
        )
        .await;
        assert_eq!(ack["ok"], false);
        assert!(ack["message"].is_string());
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":["s2","s-other"]}),
        )
        .await;
        assert_eq!(
            ack,
            serde_json::json!({"type":"relayAck","for":"relaySessions","ok":true,"skipped":1})
        );
        assert_eq!(
            resolve(&state, "s-other").await.as_deref(),
            Some("astation-other")
        );

        // Too many ids: refused, nothing changes.
        let many: Vec<String> = (0..1001).map(|i| format!("s-many-{i}")).collect();
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":many}),
        )
        .await;
        assert_eq!(ack["ok"], false);
        assert_eq!(resolve(&state, "s2").await.as_deref(), Some(code));
        assert_eq!(resolve(&state, "s-many-0").await, None);
        // Exactly the cap is fine.
        let cap: Vec<String> = (0..1000).map(|i| format!("s-cap-{i}")).collect();
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relaySessions","sessions":cap}),
        )
        .await;
        assert_eq!(ack["ok"], true);
        assert_eq!(resolve(&state, "s-cap-999").await.as_deref(), Some(code));

        // Malformed messages: refused.
        for bad in [
            serde_json::json!({"type":"relayBind"}),
            serde_json::json!({"type":"relayBind","session_id":""}),
            serde_json::json!({"type":"relayBind","session_id":"x".repeat(200)}),
            serde_json::json!({"type":"relaySessions","sessions":"s1"}),
            serde_json::json!({"type":"relaySessions","sessions":[1]}),
            serde_json::json!({"type":"relayUnbind","session_id":7}),
        ] {
            assert_eq!(
                control(&mut astation, bad.clone()).await["ok"],
                false,
                "{bad}"
            );
        }

        // The cap-sized resync replaced the set; s2 is gone.
        assert_eq!(resolve(&state, "s2").await, None);

        // resolve_caller authorizes exactly the bound sessions.
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("authorization", "session s-cap-0".parse().unwrap());
        let caller = crate::vault_routes::resolve_caller(&state, &headers, Some("atem-a"))
            .await
            .unwrap_or_else(|e| panic!("bound session did not resolve: {}", e.0));
        assert_eq!(caller.work_session_id, code);
        headers.insert("authorization", "session s2".parse().unwrap());
        let denied = crate::vault_routes::resolve_caller(&state, &headers, Some("atem-a")).await;
        assert_eq!(
            denied.err().map(|e| e.0),
            Some(HttpStatusCode::UNAUTHORIZED)
        );
        server.abort();
    }

    async fn http_status(
        state: &crate::AppState,
        method: &str,
        uri: &str,
        session: &str,
        body: &str,
    ) -> HttpStatusCode {
        crate::router(state.clone())
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("authorization", format!("session {session}"))
                    .header("content-type", "application/json")
                    .header("x-forwarded-for", "203.0.113.77")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
    }

    async fn assert_routes(state: &crate::AppState, session: &str, expected: HttpStatusCode) {
        for (method, uri, body) in [
            ("POST", "/api/vault?id=atem-a", r#"{"summary":"x"}"#),
            ("GET", "/api/vault?id=atem-a", ""),
            ("GET", "/api/memory?id=atem-a", ""),
            ("GET", "/api/skills?id=atem-a", ""),
            ("POST", "/api/memory/batch?id=atem-a", r#"{"ops":[]}"#),
        ] {
            assert_eq!(
                http_status(state, method, uri, session, body).await,
                expected,
                "{method} {uri}"
            );
        }
    }

    /// Vault and knowledge routes: 401 until the verified Astation binds the
    /// session, 200 after, 401 again once it is unbound. A granted
    /// SessionStore session alone authorizes nothing.
    #[tokio::test]
    async fn vault_and_knowledge_routes_need_a_binding() {
        let state = memory_identity_state();
        let mut granted = crate::auth::create_session("host");
        granted.status = crate::auth::SessionStatus::Granted;
        let session_id = granted.id.clone();
        state.sessions.create(granted).await.unwrap();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-routes";
        let key = TestKey::generate();

        assert_routes(&state, &session_id, HttpStatusCode::UNAUTHORIZED).await;

        let mut astation = verified_astation(&base_url, code, &key, "registered").await;
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":session_id}),
        )
        .await;
        assert_eq!(ack["ok"], true);
        assert_routes(&state, &session_id, HttpStatusCode::OK).await;

        control(
            &mut astation,
            serde_json::json!({"type":"relayUnbind","session_id":session_id}),
        )
        .await;
        assert_routes(&state, &session_id, HttpStatusCode::UNAUTHORIZED).await;
        server.abort();
    }

    /// Bindings live in Postgres: a relay restart (new AppState, new pool) keeps
    /// authorizing them. Run with IDENTITY_TEST_DATABASE_URL (see identity_store).
    #[tokio::test]
    #[ignore]
    async fn pg_bindings_survive_a_new_app_state() {
        let _guard = crate::identity_store::tests::PG_LOCK.lock().await;
        let store = crate::identity_store::tests::fresh_pg().await;
        let state = identity_state(std::sync::Arc::new(store));
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-pg-restart";
        let key = TestKey::generate();
        let mut astation = verified_astation(&base_url, code, &key, "registered").await;
        let ack = control(
            &mut astation,
            serde_json::json!({"type":"relayBind","session_id":"pg-session"}),
        )
        .await;
        assert_eq!(ack["ok"], true);
        server.abort();

        let url = std::env::var("IDENTITY_TEST_DATABASE_URL").unwrap();
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(2)
            .connect(&url)
            .await
            .unwrap();
        let restarted = identity_state(std::sync::Arc::new(
            crate::identity_store::PgIdentityStore::new(pool),
        ));
        // As main() does at startup.
        assert_eq!(
            restarted
                .relay
                .load_keys(restarted.identity.as_ref())
                .await
                .unwrap(),
            1
        );
        assert_routes(&restarted, "pg-session", HttpStatusCode::OK).await;
        assert_routes(&restarted, "pg-unbound", HttpStatusCode::UNAUTHORIZED).await;

        // The registered key survived too: the same key now verifies.
        let (base_url, server) = spawn_relay(restarted).await;
        verified_astation(&base_url, code, &key, "verified").await;
        server.abort();
    }

    // ─────────────── Key cache, DB outages, admin reset, DELETE ───────────────

    use crate::identity_store::{
        BindOutcome as StoreBindOutcome, IdentityError as StoreError, InMemoryIdentityStore,
        RegisterOutcome as StoreRegisterOutcome, ReplaceOutcome,
    };
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// An in-memory identity store that counts calls and can be taken "down".
    #[derive(Clone, Default)]
    struct FlakyIdentity {
        inner: InMemoryIdentityStore,
        down: std::sync::Arc<AtomicBool>,
        calls: std::sync::Arc<AtomicUsize>,
    }

    impl FlakyIdentity {
        fn check(&self) -> Result<(), StoreError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.down.load(Ordering::SeqCst) {
                Err(StoreError::Db("database is down".into()))
            } else {
                Ok(())
            }
        }
        fn set_down(&self, down: bool) {
            self.down.store(down, Ordering::SeqCst);
        }
        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl IdentityStore for FlakyIdentity {
        fn backend_name(&self) -> &'static str {
            "flaky"
        }
        async fn get_key(&self, id: &str) -> Result<Option<String>, StoreError> {
            self.check()?;
            self.inner.get_key(id).await
        }
        async fn register_key_if_absent(
            &self,
            id: &str,
            key: &str,
            now: i64,
        ) -> Result<StoreRegisterOutcome, StoreError> {
            self.check()?;
            self.inner.register_key_if_absent(id, key, now).await
        }
        async fn touch_key(&self, id: &str, now: i64) -> Result<(), StoreError> {
            self.check()?;
            self.inner.touch_key(id, now).await
        }
        async fn list_keys(&self) -> Result<Vec<(String, String)>, StoreError> {
            self.check()?;
            self.inner.list_keys().await
        }
        async fn bind(&self, s: &str, id: &str, now: i64) -> Result<StoreBindOutcome, StoreError> {
            self.check()?;
            self.inner.bind(s, id, now).await
        }
        async fn unbind(&self, s: &str, id: &str) -> Result<bool, StoreError> {
            self.check()?;
            self.inner.unbind(s, id).await
        }
        async fn replace_all(
            &self,
            id: &str,
            sessions: &[String],
            now: i64,
        ) -> Result<ReplaceOutcome, StoreError> {
            self.check()?;
            self.inner.replace_all(id, sessions, now).await
        }
        async fn resolve(&self, s: &str, now: i64) -> Result<Option<String>, StoreError> {
            self.check()?;
            self.inner.resolve(s, now).await
        }
    }

    fn flaky_state() -> (crate::AppState, FlakyIdentity) {
        let flaky = FlakyIdentity::default();
        (identity_state(std::sync::Arc::new(flaky.clone())), flaky)
    }

    #[tokio::test]
    async fn connecting_does_no_identity_store_io() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let key = TestKey::generate();
        let _owner = verified_astation(&base_url, "astation-io", &key, "registered").await;
        let before = flaky.calls();
        let (_pending, _) = connect_astation(&base_url, "astation-io").await;
        let (_legacy, _) = connect_astation(&base_url, "astation-io-keyless").await;
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert_eq!(
            flaky.calls(),
            before,
            "a connect touched the identity store"
        );
        server.abort();
    }

    /// With the database down a registered Astation still verifies from the
    /// key cache and keeps relaying; binding changes fail softly.
    #[tokio::test]
    async fn registered_astation_verifies_while_db_is_down() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-db-down";
        let key = TestKey::generate();
        let mut old = verified_astation(&base_url, code, &key, "registered").await;
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(next_client_json(&mut old).await["relay_event"], "connected");

        flaky.set_down(true);
        let mut new = verified_astation(&base_url, code, &key, "verified").await;
        assert_eq!(next_client_json(&mut new).await["relay_event"], "connected");
        assert_closed(&mut old).await;
        send_json(&mut atem, serde_json::json!({"probe":"db-down"})).await;
        assert_eq!(
            next_client_json(&mut new).await["payload"]["probe"],
            "db-down"
        );

        let ack = control(
            &mut new,
            serde_json::json!({"type":"relayBind","session_id":"s1"}),
        )
        .await;
        assert_eq!(ack["ok"], false);
        assert_eq!(ack["message"], "identity store unavailable");
        // Still the owner.
        send_json(&mut new, serde_json::json!({"probe":"still-owner"})).await;
        assert_eq!(next_client_json(&mut atem).await["probe"], "still-owner");
        server.abort();
    }

    #[tokio::test]
    async fn wrong_key_while_db_is_down_is_rejected_and_owner_untouched() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-db-down-wrong";
        let key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &key, "registered").await;
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut owner).await["relay_event"],
            "connected"
        );

        flaky.set_down(true);
        let (mut intruder, challenge) = connect_astation(&base_url, code).await;
        let result = authenticate(&mut intruder, &TestKey::generate(), code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut intruder).await;

        send_json(&mut atem, serde_json::json!({"probe":"to-owner"})).await;
        assert_eq!(
            next_client_json(&mut owner).await["payload"]["probe"],
            "to-owner"
        );
        assert!(
            state.relay.keys().contains(code),
            "a DB error must not forget the key"
        );
        server.abort();
    }

    /// A key that a failed re-read left stale is re-read before it verifies
    /// anything: while the database is still down even the right key is
    /// refused (fail closed).
    #[tokio::test]
    async fn stale_key_is_reread_before_it_verifies() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-stale";
        let key = TestKey::generate();
        verified_astation(&base_url, code, &key, "registered").await;

        flaky.set_down(true);
        state.relay.keys().reload_one(&flaky, code).await;
        assert!(state.relay.keys().get(code).unwrap().stale);
        let (mut refused, challenge) = connect_astation(&base_url, code).await;
        let result = authenticate(&mut refused, &key, code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        assert_closed(&mut refused).await;

        flaky.set_down(false);
        verified_astation(&base_url, code, &key, "verified").await;
        assert!(!state.relay.keys().get(code).unwrap().stale);
        server.abort();
    }

    #[tokio::test]
    async fn registration_while_db_is_down_is_rejected_and_retry_works() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-db-down-new";
        let key = TestKey::generate();
        flaky.set_down(true);
        let (mut astation, challenge) = connect_astation(&base_url, code).await;
        let result = authenticate(&mut astation, &key, code, &challenge).await;
        assert_eq!(result["status"], "rejected");
        assert_eq!(result["message"], "identity store unavailable");
        assert_closed(&mut astation).await;
        assert!(!state.relay.keys().contains(code));

        // Still keyless, so the retry is a legacy socket that registers.
        flaky.set_down(false);
        verified_astation(&base_url, code, &key, "registered").await;
        assert!(state.relay.keys().contains(code));
        server.abort();
    }

    /// An admin reset (row deleted) is picked up when a different key
    /// connects: the mismatch re-reads the store. Until then the cached old
    /// key still verifies (documented; restart the relay to revoke at once).
    #[tokio::test]
    async fn admin_reset_is_picked_up_on_key_mismatch() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-reset";
        let old_key = TestKey::generate();
        let new_key = TestKey::generate();
        verified_astation(&base_url, code, &old_key, "registered").await;

        flaky.inner.delete_key(code).await.unwrap();
        verified_astation(&base_url, code, &old_key, "verified").await;

        verified_astation(&base_url, code, &new_key, "registered").await;
        assert_eq!(
            state.identity.get_key(code).await.unwrap(),
            Some(new_key.public_hex())
        );
        let (mut old, challenge) = connect_astation(&base_url, code).await;
        let result = authenticate(&mut old, &old_key, code, &challenge).await;
        assert_eq!(result["status"], "rejected", "{result}");
        server.abort();
    }

    /// A forgotten key (absent after the re-read) disconnects the verified
    /// owner; a changed key (re-registration) and repeats do nothing.
    #[tokio::test]
    async fn forgotten_key_disconnects_the_verified_owner_but_a_changed_key_does_not() {
        let (state, flaky) = flaky_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-forgotten";
        let key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &key, "registered").await;
        let hub = state.relay.clone();

        // Changed: another key is stored; the cache holds it; nobody is dropped.
        flaky.inner.delete_key(code).await.unwrap();
        flaky
            .inner
            .register_key_if_absent(code, &TestKey::generate().public_hex(), 2)
            .await
            .unwrap();
        hub.keys().reload_one(&flaky, code).await;
        assert!(!hub.drop_verified_owner_if_key_forgotten(code).await);
        assert!(hub
            .local()
            .contains(&hub.room(code).await.unwrap().unwrap().owner.unwrap().conn));

        // Absent: forgotten. The owner goes, and a repeat is a no-op.
        flaky.inner.delete_key(code).await.unwrap();
        hub.keys().reload_one(&flaky, code).await;
        assert!(hub.drop_verified_owner_if_key_forgotten(code).await);
        let closed = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match owner.next().await {
                    None | Some(Err(_)) | Some(Ok(ClientMessage::Close(_))) => return,
                    Some(Ok(_)) => {}
                }
            }
        })
        .await;
        assert!(closed.is_ok(), "the verified owner stayed connected");
        assert!(!hub.drop_verified_owner_if_key_forgotten(code).await);
        server.abort();
    }

    /// Keys registered before a restart make those ids pending from the first
    /// connect (main() loads the cache at startup).
    #[tokio::test]
    async fn loaded_keys_make_known_ids_pending() {
        let (state, flaky) = flaky_state();
        let code = "astation-preloaded";
        let key = TestKey::generate();
        flaky
            .inner
            .register_key_if_absent(code, &key.public_hex(), 1)
            .await
            .unwrap();
        assert_eq!(
            state
                .relay
                .load_keys(state.identity.as_ref())
                .await
                .unwrap(),
            1
        );
        let (base_url, server) = spawn_relay(state.clone()).await;

        let (mut astation, challenge) = connect_astation(&base_url, code).await;
        let _atem = connect_atem(&base_url, code, "atem-a").await;
        assert_silent(&mut astation, 150).await;
        let result = authenticate(&mut astation, &key, code, &challenge).await;
        assert_eq!(result["status"], "verified");
        assert_eq!(
            next_client_json(&mut astation).await["relay_event"],
            "connected"
        );
        server.abort();
    }

    #[tokio::test]
    async fn atem_joining_while_an_astation_is_pending_is_not_announced_to_it() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-pending-join";
        let key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &key, "registered").await;
        let (mut pending, _challenge) = connect_astation(&base_url, code).await;

        let mut atem = connect_atem(&base_url, code, "atem-late").await;
        assert_eq!(next_client_json(&mut owner).await["atem_id"], "atem-late");
        send_json(&mut atem, serde_json::json!({"probe":"x"})).await;
        assert_eq!(next_client_json(&mut owner).await["payload"]["probe"], "x");
        assert_silent(&mut pending, 150).await;
        server.abort();
    }

    async fn delete_room(
        state: &crate::AppState,
        code: &str,
    ) -> (HttpStatusCode, serde_json::Value) {
        let response = crate::router(state.clone())
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/pair/{code}"))
                    .header("x-forwarded-for", "203.0.113.78")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null),
        )
    }

    #[tokio::test]
    async fn delete_is_refused_for_a_keyed_room() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-undeletable";
        let key = TestKey::generate();
        let mut owner = verified_astation(&base_url, code, &key, "registered").await;
        let mut atem = connect_atem(&base_url, code, "atem-a").await;
        assert_eq!(
            next_client_json(&mut owner).await["relay_event"],
            "connected"
        );

        let (status, body) = delete_room(&state, code).await;
        assert_eq!(status, HttpStatusCode::CONFLICT);
        assert_eq!(
            body,
            serde_json::json!({"error":"room is owned by a registered Astation"})
        );

        send_json(&mut owner, serde_json::json!({"probe":"survived"})).await;
        assert_eq!(next_client_json(&mut atem).await["probe"], "survived");
        server.abort();
    }

    #[tokio::test]
    async fn delete_still_closes_keyless_rooms() {
        let state = memory_identity_state();
        let (base_url, server) = spawn_relay(state.clone()).await;
        let code = "astation-keyless-delete";
        let (_legacy, _challenge) = connect_astation(&base_url, code).await;
        let (status, body) = delete_room(&state, code).await;
        assert_eq!(status, HttpStatusCode::OK);
        assert_eq!(body["closed"], true);
        assert!(state.relay.room(code).await.unwrap().is_none());
        server.abort();
    }

    /// First-registration race: an unverified socket that became owner is
    /// evicted when the registering (or a pending) connection verifies.
    #[tokio::test]
    async fn verification_evicts_an_unverified_owner() {
        let hub = RelayHub::new();
        let code = "astation-race";
        let mut squatter = hub.local().register("squatter", code, SocketRole::Astation);
        let _pending = hub.local().register("pending", code, SocketRole::Astation);
        hub.directory()
            .claim_owner(code, &test_conn("squatter"), now())
            .await
            .unwrap();
        assert!(hub
            .directory()
            .add_pending(code, &test_conn("pending"), now(), 0)
            .await
            .unwrap());

        // The registering socket was replaced, so it is not the owner.
        hub.promote_verified(code, "registrar", false)
            .await
            .unwrap();
        assert!(hub.room(code).await.unwrap().unwrap().owner.is_none());
        assert!(
            squatter.frames.recv().await.is_none(),
            "squatter's sender was dropped"
        );

        hub.promote_verified(code, "pending", true).await.unwrap();
        let room = hub.room(code).await.unwrap().unwrap();
        assert_eq!(
            room.owner.map(|owner| owner.conn).as_deref(),
            Some("pending")
        );
        assert!(room.verified);
        assert!(room.pending.is_empty());
    }

    #[tokio::test]
    async fn pair_code_collision_never_overwrites_a_live_room() {
        let hub = RelayHub::new();
        hub.create_room("TAKN-CODE", "live-host", now())
            .await
            .unwrap();
        hub.directory()
            .claim_owner("TAKN-CODE", &test_conn("owner"), now())
            .await
            .unwrap();
        let mut codes = vec!["FREE-CODE", "TAKN-CODE"];
        let code = hub
            .create_pair_room("new-host", now(), || codes.pop().unwrap().to_string())
            .await
            .unwrap();
        assert_eq!(code.as_deref(), Some("FREE-CODE"));
        let live = hub.room("TAKN-CODE").await.unwrap().unwrap();
        assert_eq!(live.hostname, "live-host");
        assert_eq!(live.owner.map(|owner| owner.conn).as_deref(), Some("owner"));
        assert_eq!(
            hub.room("FREE-CODE").await.unwrap().unwrap().hostname,
            "new-host"
        );

        // Every attempt collides: no room is overwritten.
        let none = hub
            .create_pair_room("x", now(), || "TAKN-CODE".to_string())
            .await
            .unwrap();
        assert_eq!(none, None);
        assert_eq!(
            hub.room("TAKN-CODE").await.unwrap().unwrap().hostname,
            "live-host"
        );
    }

    /// The sweep closes the Atem sockets of a removed room, never an
    /// Astation socket that registered just before it claims the room.
    #[tokio::test]
    async fn sweep_closes_only_atem_sockets() {
        let directory = InMemoryRoomDirectory::new();
        let hub = hub_over(&directory);
        let mut atems = std::collections::BTreeMap::new();
        atems.insert("atem-a".to_string(), test_conn("atem-conn"));
        directory.insert_for_test(
            "OLD-ROOM",
            RoomInfo {
                atems,
                ..RoomInfo::new("h", now() - ROOM_EXPIRY_SECS - 10)
            },
        );
        let mut atem = hub.local().register(
            "atem-conn",
            "OLD-ROOM",
            SocketRole::Atem {
                atem_id: "atem-a".into(),
            },
        );
        let _astation = hub
            .local()
            .register("astation-conn", "OLD-ROOM", SocketRole::Astation);
        hub.cleanup_expired().await;
        assert!(hub.room("OLD-ROOM").await.unwrap().is_none());
        assert!(
            atem.frames.recv().await.is_none(),
            "the Atem's socket was closed"
        );
        assert!(
            hub.local().contains("astation-conn"),
            "the Astation socket stays"
        );
    }

    /// Every call delegates to an in-memory directory except `touch`,
    /// which fails (shared state down) and counts its calls.
    struct TouchFails {
        inner: InMemoryRoomDirectory,
        touches: Arc<std::sync::atomic::AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl RoomDirectory for TouchFails {
        fn backend_name(&self) -> &'static str {
            "touch-fails"
        }
        async fn create_room(
            &self,
            code: &str,
            hostname: &str,
            now: i64,
        ) -> Result<(), ClusterError> {
            self.inner.create_room(code, hostname, now).await
        }
        async fn ensure_room(
            &self,
            code: &str,
            hostname: &str,
            now: i64,
        ) -> Result<bool, ClusterError> {
            self.inner.ensure_room(code, hostname, now).await
        }
        async fn get(&self, code: &str) -> Result<Option<RoomInfo>, ClusterError> {
            self.inner.get(code).await
        }
        async fn join_atem(
            &self,
            code: &str,
            atem_id: &str,
            conn: &ConnRef,
        ) -> Result<AtemJoin, ClusterError> {
            self.inner.join_atem(code, atem_id, conn).await
        }
        async fn claim_owner(
            &self,
            code: &str,
            conn: &ConnRef,
            now: i64,
        ) -> Result<crate::cluster::directory::OwnerClaim, ClusterError> {
            self.inner.claim_owner(code, conn, now).await
        }
        async fn add_pending(
            &self,
            code: &str,
            conn: &ConnRef,
            now: i64,
            max_pending: usize,
        ) -> Result<bool, ClusterError> {
            self.inner.add_pending(code, conn, now, max_pending).await
        }
        async fn promote(
            &self,
            code: &str,
            conn: &ConnRef,
            was_pending: bool,
        ) -> Result<Promotion, ClusterError> {
            self.inner.promote(code, conn, was_pending).await
        }
        async fn leave_atem(
            &self,
            code: &str,
            atem_id: &str,
            connection_id: &str,
        ) -> Result<crate::cluster::directory::AtemLeave, ClusterError> {
            self.inner.leave_atem(code, atem_id, connection_id).await
        }
        async fn leave_astation(
            &self,
            code: &str,
            connection_id: &str,
        ) -> Result<bool, ClusterError> {
            self.inner.leave_astation(code, connection_id).await
        }
        async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, ClusterError> {
            self.inner.delete_room(code).await
        }
        async fn touch(&self, _code: &str) -> Result<bool, ClusterError> {
            self.touches
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Err(ClusterError::Unavailable("redis call timed out".into()))
        }
        async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, ClusterError> {
            self.inner.exists(codes).await
        }
        async fn remove_expired(&self, now: i64) -> Result<Vec<String>, ClusterError> {
            self.inner.remove_expired(now).await
        }
    }

    #[tokio::test]
    async fn sweep_stops_touching_rooms_after_the_first_error() {
        let touches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let directory = TouchFails {
            inner: InMemoryRoomDirectory::new(),
            touches: touches.clone(),
        };
        let hub = RelayHub::from_parts(HubParts {
            directory: Arc::new(directory),
            ..HubParts::single_instance(InMemoryRoomDirectory::new(), TEST_AUTH_TIMEOUT)
        });
        let _sockets: Vec<_> = ["ROOM-A", "ROOM-B", "ROOM-C"]
            .iter()
            .enumerate()
            .map(|(i, code)| {
                hub.local()
                    .register(&format!("astation-{i}"), code, SocketRole::Astation)
            })
            .collect();
        hub.cleanup_expired().await;
        assert_eq!(
            touches.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "one failed touch ends this sweep's touches"
        );
        hub.cleanup_expired().await;
        assert_eq!(
            touches.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "the next sweep tries again"
        );
    }

    #[tokio::test]
    async fn verification_keeps_a_verified_owner_until_a_pending_one_takes_over() {
        let hub = RelayHub::new();
        let code = "astation-verified";
        let _owner = hub.local().register("owner", code, SocketRole::Astation);
        hub.directory()
            .claim_owner(code, &test_conn("owner"), now())
            .await
            .unwrap();
        hub.promote_verified(code, "owner", false).await.unwrap();

        // A stale, non-pending verified socket doesn't disturb the owner.
        hub.promote_verified(code, "stale", false).await.unwrap();
        let room = hub.room(code).await.unwrap().unwrap();
        assert_eq!(room.owner.map(|owner| owner.conn).as_deref(), Some("owner"));
        assert!(room.verified);
        assert!(hub.local().contains("owner"));
    }

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
        assert_eq!(
            next_client_json(&mut astation).await["relay_event"],
            "connected"
        );

        state.relay.drain(std::time::Duration::from_secs(5)).await;

        assert_eq!(close_code(&mut atem).await, 1012);
        assert_eq!(close_code(&mut astation).await, 1012);
        assert!(
            state.relay.room(code).await.unwrap().is_none(),
            "entries removed"
        );
        assert!(state.relay.local().is_empty());

        let response = crate::router(state.clone())
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), HttpStatusCode::SERVICE_UNAVAILABLE);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(body.as_ref(), br#"{"status":"draining"}"#);

        match tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code=late")).await
        {
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
                assert_eq!(response.status().as_u16(), 503)
            }
            other => panic!(
                "a draining relay accepted a socket: {:?}",
                other.map(|_| ())
            ),
        }
        server.abort();
    }

    /// A socket upgraded just before the drain flag was set (it passed the
    /// ws_handler check) is closed with 1012 before it joins its room.
    #[tokio::test]
    async fn a_socket_upgraded_during_a_drain_never_joins_its_room() {
        let hub = RelayHub::new();
        let code = "astation-late";
        hub.ensure_room(code, "host", chrono::Utc::now().timestamp())
            .await
            .unwrap();
        hub.drain(std::time::Duration::from_millis(10)).await;

        let late_hub = hub.clone();
        let app = Router::new().route(
            "/late",
            axum::routing::get(move |ws: WebSocketUpgrade| async move {
                let identity: Arc<dyn IdentityStore> =
                    Arc::new(crate::identity_store::InMemoryIdentityStore::new());
                let permit = late_hub
                    .ws_limiter()
                    .try_acquire("127.0.0.1")
                    .expect("permit");
                ws.on_upgrade(move |socket| {
                    handle_ws(
                        late_hub,
                        identity,
                        code.to_string(),
                        "atem".into(),
                        "atem-late".into(),
                        socket,
                        permit,
                    )
                })
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        let (mut atem, _) = tokio_tungstenite::connect_async(format!("ws://{address}/late"))
            .await
            .expect("upgrade");
        assert_eq!(close_code(&mut atem).await, 1012);
        let room = hub.room(code).await.unwrap().expect("room kept");
        assert!(
            room.atems.is_empty(),
            "a late socket must not join: {:?}",
            room.atems
        );
        assert!(hub.local().is_empty());
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
        let (mut fifth, _) =
            tokio_tungstenite::connect_async(format!("{base_url}?role=astation&code={code}"))
                .await
                .expect("upgrade");
        assert_eq!(close_code(&mut fifth).await, 1013);
        assert_eq!(MAX_PENDING_ASTATIONS_PER_ROOM, 4);
        server.abort();
    }

    #[tokio::test]
    async fn websocket_connections_are_capped_per_client_ip() {
        let state = crate::AppState {
            relay: RelayHub::with_ws_limit(2, TEST_AUTH_TIMEOUT),
            ..memory_identity_state()
        };
        let (base_url, server) = spawn_relay(state.clone()).await;
        let first = connect_astation(&base_url, "astation-ip-1").await;
        let _second = connect_astation(&base_url, "astation-ip-2").await;
        match tokio_tungstenite::connect_async(format!(
            "{base_url}?role=astation&code=astation-ip-3"
        ))
        .await
        {
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
                assert_eq!(response.status().as_u16(), 429)
            }
            other => panic!(
                "a third socket from one IP was accepted: {:?}",
                other.map(|_| ())
            ),
        }
        drop(first);
        let mut admitted = false;
        for _ in 0..100 {
            if tokio_tungstenite::connect_async(format!(
                "{base_url}?role=astation&code=astation-ip-4"
            ))
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

    /// Open a `/ws` socket as if Cloudflare had forwarded it from `ip`.
    async fn connect_from(
        base_url: &str,
        query: &str,
        ip: &str,
        forwarded_for: Option<&str>,
    ) -> Result<TestSocket, tokio_tungstenite::tungstenite::Error> {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let mut request = format!("{base_url}?{query}").into_client_request().unwrap();
        request
            .headers_mut()
            .insert("cf-connecting-ip", ip.parse().unwrap());
        if let Some(forwarded) = forwarded_for {
            request
                .headers_mut()
                .insert("x-forwarded-for", forwarded.parse().unwrap());
        }
        tokio_tungstenite::connect_async(request)
            .await
            .map(|(socket, _)| socket)
    }

    #[tokio::test]
    async fn the_per_ip_cap_keys_on_cloudflares_address_and_leaves_other_ips_alone() {
        let state = crate::AppState {
            relay: RelayHub::with_ws_limit(1, TEST_AUTH_TIMEOUT),
            ..memory_identity_state()
        };
        let (base_url, server) = spawn_relay(state.clone()).await;
        let refused_before = crate::cluster::metrics::metrics()
            .rate_limited_ws
            .load(Ordering::Relaxed);
        let _held = connect_from(
            &base_url,
            "role=astation&code=astation-cf-1",
            "203.0.113.1",
            None,
        )
        .await
        .expect("first socket");
        // A forged X-Forwarded-For does not move the socket to another bucket.
        match connect_from(
            &base_url,
            "role=astation&code=astation-cf-2",
            "203.0.113.1",
            Some("198.51.100.99"),
        )
        .await
        {
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
                assert_eq!(response.status().as_u16(), 429);
                assert_eq!(
                    response.body().as_deref(),
                    Some(&b"Too many WebSocket connections from this address"[..])
                );
            }
            other => panic!(
                "a second socket from one IP was accepted: {:?}",
                other.map(|_| ())
            ),
        }
        let _other = connect_from(
            &base_url,
            "role=astation&code=astation-cf-3",
            "203.0.113.2",
            None,
        )
        .await
        .expect("another IP is unaffected");
        assert_eq!(state.relay.ws_limiter().open("203.0.113.1"), 1);
        assert_eq!(state.relay.ws_limiter().open("203.0.113.2"), 1);
        // Process-wide counter: other tests may refuse sockets too.
        assert!(
            crate::cluster::metrics::metrics()
                .rate_limited_ws
                .load(Ordering::Relaxed)
                > refused_before
        );
        server.abort();
    }

    /// A socket refused before or after the upgrade gives its slot back.
    #[tokio::test]
    async fn refused_and_closed_sockets_release_their_slot() {
        let state = crate::AppState {
            relay: RelayHub::with_ws_limit(1, TEST_AUTH_TIMEOUT),
            ..memory_identity_state()
        };
        let (base_url, server) = spawn_relay(state.clone()).await;
        let ip = "203.0.113.9";
        // Refused before the upgrade: an Atem for a room that does not exist.
        match connect_from(&base_url, "role=atem&code=NOPE42&atem_id=a", ip, None).await {
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
                assert_eq!(response.status().as_u16(), 404)
            }
            other => panic!("expected 404: {:?}", other.map(|_| ())),
        }
        assert_eq!(state.relay.ws_limiter().open(ip), 0);
        // Upgraded, then closed by the relay: an unknown role ends handle_ws.
        state
            .relay
            .ensure_room("astation-odd", "host", chrono::Utc::now().timestamp())
            .await
            .unwrap();
        let _odd = connect_from(&base_url, "role=bogus&code=astation-odd", ip, None)
            .await
            .expect("upgrade");
        let mut freed = false;
        for _ in 0..100 {
            if state.relay.ws_limiter().open(ip) == 0 {
                freed = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(freed, "a socket the relay ended gives its slot back");
        // Closed by the auth timeout: a pending socket (the room's key is
        // registered, from another address) that never answers.
        let key = TestKey::generate();
        let _owner = verified_astation(&base_url, "astation-silent", &key, "registered").await;
        let mut silent = connect_from(&base_url, "role=astation&code=astation-silent", ip, None)
            .await
            .expect("slot is free again");
        let _ = close_code(&mut silent).await;
        let mut freed = false;
        for _ in 0..100 {
            if state.relay.ws_limiter().open(ip) == 0 {
                freed = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(freed, "a timed-out socket gives its slot back");
        server.abort();
    }
}
