//! Redis (Valkey) versions of the shared relay units, selected by
//! REDIS_URL. Redis holds only live state; losing it makes clients
//! reconnect but loses nothing durable.

pub mod bus;
pub mod directory;
pub mod keys;
pub mod presence;
pub mod ratelimit;
pub mod rtc;
pub mod sessions;
pub mod voice;

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use redis::aio::{ConnectionManager, ConnectionManagerConfig};
use tokio::task::JoinHandle;

use super::health::ClusterHealth;
use super::StoreError;
use crate::cluster::bus::ReplicaBus;
use crate::cluster::directory::RoomDirectory;
use crate::cluster::keys::KeyCache;
use crate::cluster::local::LocalSockets;
use crate::cluster::new_replica_id;
use crate::cluster::ratelimit::SharedRateLimiter;
use crate::identity_store::IdentityStore;
use crate::relay::{HubParts, RelayHub};
use crate::rtc_session::RtcSessionStore;
use crate::session_store::SessionStore;
use crate::voice_session::{ReplyWaiters, VoiceSessionStore};

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

/// Why a startup connect failed. Retrying can't fix a `Permanent` one (a
/// bad REDIS_URL or wrong credentials). Messages never contain the URL.
#[derive(Debug)]
pub enum ConnectError {
    Permanent(String),
    Retryable(StoreError),
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectError::Permanent(detail) => write!(f, "{detail}"),
            ConnectError::Retryable(error) => write!(f, "{error}"),
        }
    }
}

impl From<StoreError> for ConnectError {
    fn from(error: StoreError) -> Self {
        ConnectError::Retryable(error)
    }
}

impl From<ConnectError> for StoreError {
    fn from(error: ConnectError) -> Self {
        match error {
            ConnectError::Permanent(detail) => StoreError::Unavailable(detail),
            ConnectError::Retryable(error) => error,
        }
    }
}

/// An invalid client config (unparseable URL) or an authentication failure
/// (wrong password: AuthenticationFailed / WRONGPASS; none sent: NOAUTH).
/// Everything else (refused, timeouts, loading) may pass, so it is retried.
pub(crate) fn is_permanent_connect_error(error: &redis::RedisError) -> bool {
    matches!(
        error.kind(),
        redis::ErrorKind::InvalidClientConfig | redis::ErrorKind::AuthenticationFailed
    ) || matches!(error.code(), Some("NOAUTH") | Some("WRONGPASS"))
}

fn connect_error(error: redis::RedisError) -> ConnectError {
    if is_permanent_connect_error(&error) {
        // The kind and the server's reply only: never the URL (it may hold
        // the password).
        let detail = match (error.code(), error.detail()) {
            (Some(code), Some(detail)) => format!("{code} {detail}"),
            (None, Some(detail)) => format!("{}: {}", error.category(), detail),
            (_, None) => error.category().to_string(),
        };
        ConnectError::Permanent(detail)
    } else {
        ConnectError::Retryable(redis_error(error))
    }
}

impl RedisConn {
    /// `connect_checked` as a StoreError (the Redis test suites).
    #[cfg(test)]
    pub async fn connect(url: &str) -> Result<Self, StoreError> {
        Ok(Self::connect_checked(url).await?)
    }

    /// One connect attempt, bounded by REDIS_TIMEOUT, with no internal retry
    /// or backoff; startup-level retrying belongs to the caller (`main`).
    /// Tells permanent failures from ones worth retrying, and ends with a
    /// PING so a missing password shows up here (NOAUTH).
    pub async fn connect_checked(url: &str) -> Result<Self, ConnectError> {
        let client = redis::Client::open(url).map_err(connect_error)?;
        let config = ConnectionManagerConfig::new()
            .set_connection_timeout(REDIS_TIMEOUT)
            .set_response_timeout(REDIS_TIMEOUT)
            .set_number_of_retries(0);
        let connecting = async {
            let mut manager = client.get_connection_manager_with_config(config).await?;
            redis::cmd("PING").query_async::<String>(&mut manager).await?;
            Ok::<_, redis::RedisError>(manager)
        };
        let manager = tokio::time::timeout(REDIS_TIMEOUT, connecting)
            .await
            .map_err(|_| StoreError::Unavailable("redis connect timed out".to_string()))?
            .map_err(connect_error)?;
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
        let started = std::time::Instant::now();
        let result = match tokio::time::timeout(REDIS_TIMEOUT, op(self.manager.clone())).await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(redis_error(error)),
            Err(_) => Err(StoreError::Unavailable("redis call timed out".to_string())),
        };
        crate::cluster::metrics::metrics().observe_redis(started.elapsed(), result.is_ok());
        result
    }

    pub async fn ping(&self) -> Result<(), StoreError> {
        self.run(|mut c| async move {
            redis::cmd("PING").query_async::<String>(&mut c).await.map(|_| ())
        })
        .await
    }
}

/// One relay replica whose shared state lives in Redis.
pub struct RedisCluster {
    pub relay: RelayHub,
    pub sessions: SessionStore,
    pub voice_sessions: VoiceSessionStore,
    pub rtc_sessions: RtcSessionStore,
    pub health: presence::RedisHealth,
    /// Background tasks, named for the supervisor in `main`.
    tasks: Vec<(&'static str, JoinHandle<()>)>,
}

impl RedisCluster {
    /// Hand the background tasks to a supervisor (`main`). `abort` then
    /// has nothing left to stop.
    pub fn take_tasks(&mut self) -> Vec<(&'static str, JoinHandle<()>)> {
        std::mem::take(&mut self.tasks)
    }

    /// Stop this replica's background tasks (bus, dispatcher, presence).
    /// Dropping a `RedisCluster` without calling this leaves them running.
    // Tests and the two-relay harness; `main` supervises them instead.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn abort(&self) {
        for (_, task) in &self.tasks {
            task.abort();
        }
    }
}

/// Build a replica on Redis with an empty key cache (tests
/// load keys afterwards with `relay.load_keys`).
// Tests only; `main` and the two-relay harness pass loaded keys.
#[cfg_attr(not(test), allow(dead_code))]
pub async fn connect_cluster(
    url: &str,
    identity: Arc<dyn IdentityStore>,
    auth_timeout: Duration,
) -> Result<RedisCluster, StoreError> {
    Ok(connect_cluster_with_keys(
        url,
        identity,
        KeyCache::new(),
        auth_timeout,
        crate::cluster::limits::DEFAULT_WS_MAX_PER_IP,
    )
    .await?)
}

/// Build a replica on Redis around `keys` (already loaded by the caller):
/// presence (one awaited refresh, so peers are known before serving), bus
/// subscription with its self-heartbeat, the bus dispatcher, then the
/// directory, sessions, voice, RTC and the shared rate limiter. Everything
/// is running when this returns, so the caller may start serving.
pub async fn connect_cluster_with_keys(
    url: &str,
    identity: Arc<dyn IdentityStore>,
    keys: KeyCache,
    auth_timeout: Duration,
    ws_max_per_ip: usize,
) -> Result<RedisCluster, ConnectError> {
    let conn = RedisConn::connect_checked(url).await?;
    let replica_id = new_replica_id();
    let health = presence::RedisHealth::start(conn.clone(), &replica_id).await?;
    let (bus, events, bus_task) = match bus::RedisBus::start(conn.clone(), &replica_id).await {
        Ok(started) => started,
        Err(error) => {
            // Don't leave a presence key behind for a replica that never ran.
            if let Err(withdraw_error) = health.withdraw().await {
                tracing::debug!("Could not withdraw replica {}: {}", replica_id, withdraw_error);
            }
            return Err(error.into());
        }
    };
    let waiters = ReplyWaiters::default();
    let directory: Arc<dyn RoomDirectory> = Arc::new(directory::RedisRoomDirectory::new(conn.clone()));
    let bus: Arc<dyn ReplicaBus> = Arc::new(bus);
    let rate_limiter: Arc<dyn SharedRateLimiter> = Arc::new(ratelimit::RedisRateLimiter::new(conn.clone()));
    tracing::info!(
        "Relay replica {} backends: rooms={}, bus={}, rate limits={}",
        replica_id,
        directory.backend_name(),
        bus.backend_name(),
        rate_limiter.backend_name()
    );
    let relay = RelayHub::from_parts(HubParts {
        replica_id: replica_id.clone(),
        directory,
        bus,
        local: LocalSockets::new(),
        keys,
        rate_limiter,
        health: Arc::new(health.clone()),
        cache_rooms: true,
        auth_timeout,
        ws_limiter: crate::cluster::limits::WsConnLimiter::new(ws_max_per_ip),
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
        tasks: vec![
            ("bus subscriber", bus_task),
            ("bus dispatcher", dispatcher),
            ("presence refresh", presence_task),
        ],
    })
}

#[cfg(test)]
pub(crate) mod test_support {
    //! Redis suites are #[ignore]d and need TEST_REDIS_URL (localhost only:
    //! the harness empties the database). See the plan's global constraints.
    use super::RedisConn;

    /// Redis tests share one database, so they run one at a time.
    pub(crate) static REDIS_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// True only for a `redis://` URL whose host is this machine.
    pub(crate) fn is_local_redis_url(url: &str) -> bool {
        let parsed = match url::Url::parse(url) {
            Ok(parsed) => parsed,
            Err(_) => return false,
        };
        parsed.scheme() == "redis"
            && matches!(
                parsed.host(),
                // `redis` is not a "special" scheme, so the url crate leaves a
                // dotted-quad host as a string instead of parsing it to Ipv4.
                Some(url::Host::Domain("localhost"))
                    | Some(url::Host::Domain("127.0.0.1"))
                    | Some(url::Host::Ipv4(std::net::Ipv4Addr::LOCALHOST))
                    | Some(url::Host::Ipv6(std::net::Ipv6Addr::LOCALHOST))
            )
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
        assert!(!is_local_redis_url("redis://evil.com#@localhost"));
        assert!(!is_local_redis_url("redis://127.0.0.1.evil.com"));
        assert!(!is_local_redis_url("redis://localhost@evil"));
        assert!(!is_local_redis_url("redis://user:pw@evil.com/"));
        assert!(!is_local_redis_url("rediss://localhost"));
        assert!(is_local_redis_url("redis://[::1]:6379/"));
    }

    #[tokio::test]
    async fn unreachable_redis_is_a_store_error() {
        let started = std::time::Instant::now();
        let error = RedisConn::connect("redis://127.0.0.1:1/").await.err().expect("no server on port 1");
        assert!(matches!(error, StoreError::Unavailable(_)));
        assert!(started.elapsed() < REDIS_TIMEOUT, "took {:?}", started.elapsed());
    }

    #[test]
    fn only_config_and_auth_errors_are_permanent() {
        use redis::{ErrorKind, RedisError};
        let refused = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        let timed_out = RedisError::from(std::io::Error::from(std::io::ErrorKind::TimedOut));
        assert!(!is_permanent_connect_error(&refused));
        assert!(!is_permanent_connect_error(&timed_out));
        assert!(!is_permanent_connect_error(&RedisError::from((ErrorKind::BusyLoadingError, "loading"))));
        assert!(!is_permanent_connect_error(&RedisError::from((ErrorKind::TryAgain, "try again"))));
        assert!(is_permanent_connect_error(&RedisError::from((ErrorKind::InvalidClientConfig, "bad url"))));
        assert!(is_permanent_connect_error(&RedisError::from((ErrorKind::AuthenticationFailed, "wrong password"))));
        for code in ["NOAUTH", "WRONGPASS"] {
            // A server error reply with a code redis-rs has no kind for.
            let reply = format!("-{code} authentication problem\r\n");
            let error = match redis::parse_redis_value(reply.as_bytes()) {
                Ok(redis::Value::ServerError(error)) => RedisError::from(error),
                Ok(other) => panic!("{code}: parsed as {other:?}"),
                Err(error) => error,
            };
            assert_eq!(error.code(), Some(code));
            assert!(is_permanent_connect_error(&error), "{code}");
        }
    }

    #[tokio::test]
    async fn bad_redis_url_is_permanent_and_never_echoed() {
        for url in ["not a url", "redis://:hunter2@127.0.0.1:notaport/", "http://:hunter2@127.0.0.1/"] {
            match RedisConn::connect_checked(url).await {
                Err(ConnectError::Permanent(message)) => {
                    assert!(!message.contains("hunter2"), "{message}");
                    assert!(!message.contains(url), "{message}");
                }
                Err(other) => panic!("{url}: expected a permanent error, got {other}"),
                Ok(_) => panic!("{url}: connected"),
            }
        }
    }

    #[tokio::test]
    async fn refused_redis_is_retryable() {
        let error = RedisConn::connect_checked("redis://127.0.0.1:1/").await.err().expect("no server on port 1");
        assert!(matches!(error, ConnectError::Retryable(_)), "{error}");
    }

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
