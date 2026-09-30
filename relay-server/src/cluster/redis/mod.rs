//! Redis (Valkey) versions of the shared relay units, selected by
//! REDIS_URL. Redis holds only live state; losing it makes clients
//! reconnect but loses nothing durable.

// Consumers land in Tasks 11-19; drop the allow as they do.
#[allow(dead_code)]
pub mod keys;

use std::future::Future;
use std::time::Duration;

use redis::aio::{ConnectionManager, ConnectionManagerConfig};

use super::StoreError;

// Consumers land in Tasks 11-19; drop the allow as they do.
#[allow(dead_code)]
/// Bound on every Redis call, so a slow Redis can't stall a connect.
pub const REDIS_TIMEOUT: Duration = Duration::from_secs(3);

// Consumers land in Tasks 11-19; drop the allow as they do.
#[allow(dead_code)]
pub(crate) fn redis_error(error: redis::RedisError) -> StoreError {
    StoreError::Unavailable(error.to_string())
}

// Consumers land in Tasks 11-19; drop the allow as they do.
#[allow(dead_code)]
/// A reconnecting command connection plus the client (for pub/sub).
#[derive(Clone)]
pub struct RedisConn {
    client: redis::Client,
    manager: ConnectionManager,
}

// Consumers land in Tasks 11-19; drop the allow as they do.
#[allow(dead_code)]
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
