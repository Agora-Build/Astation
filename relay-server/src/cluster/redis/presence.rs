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
    /// Starts with only this replica live. Callers must use `start` (or
    /// `refresh` first), or peers look dead and their entries are stripped.
    pub fn new(conn: RedisConn, replica_id: &str) -> Self {
        let live = HashSet::from([replica_id.to_string()]);
        Self {
            conn,
            replica_id: replica_id.to_string(),
            started_at: chrono::Utc::now().timestamp(),
            live: Arc::new(RwLock::new(live)),
        }
    }

    /// `new` plus one awaited refresh, so peers are known before serving.
    pub async fn start(conn: RedisConn, replica_id: &str) -> Result<Self, StoreError> {
        let health = Self::new(conn, replica_id);
        health.refresh().await?;
        Ok(health)
    }

    /// Renew this replica's presence and re-list the live replicas.
    /// On failure the last known live set is kept (fails open, by design).
    pub async fn refresh(&self) -> Result<usize, StoreError> {
        self.refresh_at(chrono::Utc::now().timestamp()).await
    }

    /// `refresh` with an injectable clock (unix seconds).
    pub(crate) async fn refresh_at(&self, now: i64) -> Result<usize, StoreError> {
        let presence = keys::replica(&self.replica_id);
        let id = self.replica_id.clone();
        let started_at = self.started_at;
        let expires = now + PRESENCE_TTL_SECS as i64;
        let (_, _, _, found): ((), i64, i64, Vec<String>) = self
            .conn
            .run(|mut c| async move {
                redis::pipe()
                    .atomic()
                    .cmd("SET").arg(&presence).arg(started_at).arg("EX").arg(PRESENCE_TTL_SECS)
                    .cmd("ZADD").arg(keys::REPLICAS_INDEX).arg(expires).arg(&id)
                    .cmd("ZREMRANGEBYSCORE").arg(keys::REPLICAS_INDEX).arg("-inf").arg(format!("({now}"))
                    .cmd("ZRANGEBYSCORE").arg(keys::REPLICAS_INDEX).arg(now).arg("+inf")
                    .query_async(&mut c)
                    .await
            })
            .await?;
        let mut live: HashSet<String> = found.into_iter().collect();
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
        let id = self.replica_id.clone();
        self.conn
            .run(|mut c| async move {
                redis::pipe()
                    .cmd("DEL").arg(&presence)
                    .cmd("ZREM").arg(keys::REPLICAS_INDEX).arg(&id)
                    .query_async::<()>(&mut c)
                    .await
            })
            .await
    }
}

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

    #[tokio::test]
    #[ignore]
    async fn redis_presence_expires_replicas_that_stop_refreshing() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let a = RedisHealth::new(conn.clone(), "replica-a");
        let b = RedisHealth::new(conn.clone(), "replica-b");
        let t = 1_000_000;
        b.refresh_at(t).await.unwrap();
        assert_eq!(a.refresh_at(t).await.unwrap(), 2);
        assert_eq!(a.refresh_at(t + 20).await.unwrap(), 2);
        assert_eq!(a.refresh_at(t + 31).await.unwrap(), 1);
        assert!(!a.is_live("replica-b"));
    }

    #[tokio::test]
    #[ignore]
    async fn redis_presence_start_sees_live_peers_at_once() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let a = RedisHealth::start(conn.clone(), "replica-a").await.unwrap();
        let b = RedisHealth::start(conn.clone(), "replica-b").await.unwrap();
        assert!(b.is_live("replica-a"));
        assert_eq!(b.replicas(), 2);
        assert_eq!(a.replicas(), 1);
    }
}
