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

    // The two-relay harness (tests); Task 25 (SIGTERM drain) uses it in `main`.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn connection_ids(&self) -> Vec<String> {
        self.lock().keys().cloned().collect()
    }

    /// (Atem sockets, Astation sockets) on this replica.
    // Task 33 (metrics).
    #[allow(dead_code)]
    pub fn count_by_role(&self) -> (usize, usize) {
        let conns = self.lock();
        let astations = conns
            .values()
            .filter(|conn| conn.role == SocketRole::Astation)
            .count();
        (conns.len() - astations, astations)
    }

    // Only tests use it; kept as the clippy len_without_is_empty pair of is_empty.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    // Task 25 (drain test asserts it).
    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }
}

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
