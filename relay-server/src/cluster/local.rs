//! This replica's live WebSockets: connection id → sender. The only
//! per-process relay state. The map holds each socket's only sender, so
//! removing an entry ends that socket: its writer flushes what is queued,
//! then closes (exactly how a replaced socket closes today).
//!
//! Each socket's queue is bounded (spec: "Bounded send queues"): at most
//! 1,000 frames or 4 MB. A frame that doesn't fit is dropped (frames are
//! best effort), and a client whose queue stays full for 10 s is closed with
//! 1013 (reconnect). `send` never waits, so a slow client can't hold up the
//! bus dispatcher or anyone else.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use tokio::sync::{mpsc, watch};
// Tokio's clock, so paused-time tests drive the stall timer.
use tokio::time::Instant;

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
    /// Clients closed for being too slow, since start (Task 33's metrics).
    slow_closed: Arc<AtomicU64>,
}

impl LocalSockets {
    pub fn new() -> Self {
        Self::default()
    }

    // Production uses the defaults; tests shrink the limits.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn with_limits(limits: QueueLimits) -> Self {
        Self {
            limits,
            ..Self::default()
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

    /// Queue a frame without waiting. False when the connection is not (or
    /// no longer) here, or its queue is full: the frame is dropped, and a
    /// queue full for `stall` closes the socket with 1013.
    pub fn send(&self, connection_id: &str, frame: String) -> bool {
        let mut conns = self.lock();
        let Some(conn) = conns.get_mut(connection_id) else {
            return false;
        };
        let len = frame.len();
        let queued = conn.queued_bytes.load(Ordering::Relaxed);
        // An empty queue takes any one frame, so a frame larger than the
        // byte cap is still delivered (alone) rather than never.
        if queued == 0 || queued + len <= self.limits.bytes {
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
                self.close_slow(conn);
            }
        }
        false
    }

    fn close_slow(&self, conn: LocalConn) {
        self.slow_closed.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(
            "Closing a slow relay client (send queue full for {:?})",
            self.limits.stall
        );
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
                self.close_slow(conn);
            }
        }
        stalled.len()
    }

    /// Clients closed for being too slow since start.
    // Task 33 (metrics).
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn slow_client_closes(&self) -> u64 {
        self.slow_closed.load(Ordering::Relaxed)
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
    // Task 33 (metrics).
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn room_count(&self) -> usize {
        self.lock()
            .values()
            .map(|conn| conn.code.as_str())
            .collect::<HashSet<_>>()
            .len()
    }

    /// Every socket on this replica (drain closes them all).
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

    // Only tests use it (the drain test asserts it).
    #[cfg_attr(not(test), allow(dead_code))]
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
        assert_eq!(local.room_count(), 2);
        let mut ids = local.connection_ids();
        ids.sort();
        assert_eq!(ids, vec!["a1".to_string(), "t1".to_string(), "t2".to_string()]);
    }

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
        assert_eq!(local.slow_client_closes(), 1);
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
    async fn one_oversized_frame_still_goes_to_an_empty_queue() {
        let local = LocalSockets::with_limits(QueueLimits {
            frames: 100,
            bytes: 10,
            stall: Duration::from_secs(60),
        });
        let mut outbox = local.register("c", "room", SocketRole::Astation);
        assert!(local.send("c", "x".repeat(20)), "an empty queue takes any one frame");
        assert!(!local.send("c", "y".into()), "but nothing after it until it is sent");
        let frame = outbox.frames.recv().await.unwrap();
        outbox.sent(&frame);
        assert_eq!(outbox.queued_bytes.load(Ordering::Relaxed), 0);
        assert!(local.send("c", "y".into()));
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
        assert_eq!(local.slow_client_closes(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn the_stall_timer_restarts_when_the_queue_drains() {
        let local = LocalSockets::with_limits(QueueLimits {
            frames: 1,
            bytes: 1024,
            stall: Duration::from_millis(100),
        });
        let mut outbox = local.register("c", "room", SocketRole::Astation);
        assert!(local.send("c", "a".into()));
        assert!(!local.send("c", "b".into()), "full: the stall timer starts");
        tokio::time::sleep(Duration::from_millis(80)).await;
        let frame = outbox.frames.recv().await.unwrap();
        outbox.sent(&frame);
        assert!(local.send("c", "c".into()), "drained below the cap: fits again");
        assert!(!local.send("c", "d".into()), "full again: a new stall timer");
        tokio::time::sleep(Duration::from_millis(40)).await;
        // 120 ms since the queue first filled, 40 ms since it last did.
        assert!(!local.send("c", "e".into()));
        assert_eq!(local.sweep_slow(), 0);
        assert!(local.contains("c"), "the stall restarted when the queue drained");
        tokio::time::sleep(Duration::from_millis(70)).await;
        assert!(!local.send("c", "f".into()));
        assert!(!local.contains("c"), "full for 110 ms on the new timer");
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_client_never_blocks_delivery_to_others() {
        // The bus dispatcher's path: one deliver fanned out to every socket.
        let local = LocalSockets::new();
        let _stuck = local.register("stuck", "room", SocketRole::Astation);
        let mut healthy = local.register("healthy", "room", SocketRole::Astation);
        let deliver = |local: &LocalSockets, n: usize| {
            crate::cluster::bus::apply_inbox(
                local,
                crate::cluster::bus::InboxMessage::Deliver {
                    connection_ids: vec!["stuck".into(), "healthy".into()],
                    frame: format!("frame-{n}"),
                },
            )
        };
        let mut received = 0;
        // Bounded in (paused) time: a blocking send would never finish and
        // the timeout would fire.
        tokio::time::timeout(Duration::from_secs(1), async {
            for n in 0..5 * MAX_QUEUED_FRAMES {
                deliver(&local, n);
                while let Ok(frame) = healthy.frames.try_recv() {
                    healthy.sent(&frame);
                    received += 1;
                }
            }
        })
        .await
        .expect("delivery never waits on a full queue");
        assert_eq!(received, 5 * MAX_QUEUED_FRAMES, "the healthy client got every frame");
        assert!(local.contains("stuck"), "full, but not yet for 10 s");

        tokio::time::sleep(SLOW_CLIENT_TIMEOUT).await;
        deliver(&local, 0);
        assert!(!local.contains("stuck"), "full for 10 s: closed");
        assert!(local.contains("healthy"));
        assert_eq!(healthy.frames.try_recv().as_deref(), Ok("frame-0"));
        assert_eq!(local.slow_client_closes(), 1);
    }

    #[tokio::test]
    async fn the_byte_cap_stalls_a_client_too() {
        let local = LocalSockets::with_limits(QueueLimits {
            frames: 100,
            bytes: 4,
            stall: Duration::from_millis(30),
        });
        let _outbox = local.register("c", "room", SocketRole::Astation);
        assert!(local.send("c", "1234".into()));
        assert!(!local.send("c", "5".into()));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(local.sweep_slow(), 1, "full by bytes for longer than the stall");
        assert!(!local.contains("c"));
    }

    #[test]
    fn default_limits_match_the_spec() {
        assert_eq!(
            QueueLimits::default(),
            QueueLimits { frames: 1000, bytes: 4 * 1024 * 1024, stall: Duration::from_secs(10) }
        );
        assert_eq!(CLOSE_SLOW_CLIENT, 1013);
    }
}
