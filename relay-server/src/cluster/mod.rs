//! Building blocks for running the relay as several replicas
//! (docs/specs/2026-09-30-relay-multi-replica.md). Each shared unit is a
//! trait with an in-memory version (tests, single instance, local dev) and
//! a Redis version (production, `REDIS_URL`).


// Consumers land in later tasks of the multi-replica plan; remove then.
#![allow(dead_code)]
pub mod bus;
pub mod directory;
pub mod keys;
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
