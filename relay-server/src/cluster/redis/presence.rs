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
