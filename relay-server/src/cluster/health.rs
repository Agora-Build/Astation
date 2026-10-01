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
    // Consumer lands with drain (later task); drop the allow then.
    #[allow(dead_code)]
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
