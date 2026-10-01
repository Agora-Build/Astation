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
