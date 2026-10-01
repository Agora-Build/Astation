//! ReplicaBus over Redis pub/sub. Each replica subscribes to its own inbox
//! (`relay:inbox:<replica_id>`), the broadcast channel and, as a pattern,
//! every voice-reply channel. Redis keeps order per publisher and channel,
//! so one Astation → Atem stream (one replica to one inbox) stays ordered.

use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures_util::StreamExt;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use super::{keys, redis_error, RedisConn, REDIS_TIMEOUT};
use crate::cluster::bus::{BroadcastMessage, BusEvent, InboxMessage, ReplicaBus};
use crate::cluster::StoreError;

/// Published to a replica's own inbox to prove its subscription is alive.
const HEARTBEAT_PAYLOAD: &str = r#"{"type":"heartbeat"}"#;
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
/// No message at all (heartbeats included) for this long: the subscription
/// is presumed half-open and is replaced.
pub const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(30);

/// Subscriber timings; injectable so tests can run them fast.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BusTiming {
    pub heartbeat_interval: Duration,
    pub heartbeat_timeout: Duration,
    pub backoff_initial: Duration,
    pub backoff_max: Duration,
    /// A subscription that stayed up this long restarts the backoff.
    pub stable_after: Duration,
}

impl Default for BusTiming {
    fn default() -> Self {
        Self {
            heartbeat_interval: HEARTBEAT_INTERVAL,
            heartbeat_timeout: HEARTBEAT_TIMEOUT,
            backoff_initial: Duration::from_millis(100),
            backoff_max: Duration::from_secs(5),
            stable_after: Duration::from_secs(30),
        }
    }
}

pub struct RedisBus {
    conn: RedisConn,
    replica_id: String,
}

impl RedisBus {
    /// Subscribe for `replica_id`; returns once the subscription is live.
    pub async fn start(
        conn: RedisConn,
        replica_id: &str,
    ) -> Result<(Self, mpsc::UnboundedReceiver<BusEvent>, JoinHandle<()>), StoreError> {
        Self::start_with(conn, replica_id, BusTiming::default()).await
    }

    pub(crate) async fn start_with(
        conn: RedisConn,
        replica_id: &str,
        timing: BusTiming,
    ) -> Result<(Self, mpsc::UnboundedReceiver<BusEvent>, JoinHandle<()>), StoreError> {
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        let (ready_tx, ready_rx) = oneshot::channel();
        let task = tokio::spawn(subscriber_loop(
            conn.client().clone(),
            Some(conn.clone()),
            replica_id.to_string(),
            events_tx,
            Some(ready_tx),
            timing,
        ));
        match tokio::time::timeout(REDIS_TIMEOUT * 2, ready_rx).await {
            Ok(Ok(())) => Ok((Self::publisher(conn, replica_id), events_rx, task)),
            _ => {
                task.abort();
                Err(StoreError::Unavailable("relay bus subscription failed".to_string()))
            }
        }
    }

    /// A bus that only publishes (no subscription).
    pub fn publisher(conn: RedisConn, replica_id: &str) -> Self {
        Self {
            conn,
            replica_id: replica_id.to_string(),
        }
    }

    async fn publish(&self, channel: String, payload: String) -> Result<(), StoreError> {
        self.conn
            .run(|mut c| async move {
                redis::cmd("PUBLISH")
                    .arg(&channel)
                    .arg(&payload)
                    .query_async::<i64>(&mut c)
                    .await
                    .map(|_| ())
            })
            .await
    }
}

#[async_trait]
impl ReplicaBus for RedisBus {
    fn backend_name(&self) -> &'static str {
        "redis"
    }

    async fn send_inbox(&self, replica_id: &str, message: InboxMessage) -> Result<(), StoreError> {
        let payload = serde_json::to_string(&message)
            .map_err(|error| StoreError::Unavailable(error.to_string()))?;
        self.publish(keys::inbox_channel(replica_id), payload).await
    }

    async fn broadcast(&self, message: BroadcastMessage) -> Result<(), StoreError> {
        let payload = serde_json::to_string(&message)
            .map_err(|error| StoreError::Unavailable(error.to_string()))?;
        tracing::trace!("Replica {} broadcasting {}", self.replica_id, payload);
        self.publish(keys::BROADCAST_CHANNEL.to_string(), payload).await
    }
}

async fn subscribe(client: &redis::Client, replica_id: &str) -> Result<redis::aio::PubSub, StoreError> {
    let subscribing = async {
        let mut pubsub = client.get_async_pubsub().await?;
        pubsub.subscribe(keys::inbox_channel(replica_id)).await?;
        pubsub.subscribe(keys::BROADCAST_CHANNEL).await?;
        pubsub.psubscribe(keys::VOICE_REPLY_PATTERN).await?;
        Ok::<_, redis::RedisError>(pubsub)
    };
    match tokio::time::timeout(REDIS_TIMEOUT, subscribing).await {
        Ok(Ok(pubsub)) => Ok(pubsub),
        Ok(Err(error)) => Err(redis_error(error)),
        Err(_) => Err(StoreError::Unavailable("redis subscribe timed out".to_string())),
    }
}

/// What one pub/sub message means to the subscriber.
#[derive(Debug, PartialEq, Eq)]
enum Decoded {
    Event(BusEvent),
    /// This replica's own liveness probe: proves the subscription works.
    Heartbeat,
    Undecodable,
}

fn is_heartbeat(payload: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(payload)
        .ok()
        .and_then(|value| value.get("type").and_then(|kind| kind.as_str()).map(|kind| kind == "heartbeat"))
        .unwrap_or(false)
}

fn decode(message: &redis::Msg) -> Decoded {
    let channel = message.get_channel_name();
    let payload: String = match message.get_payload() {
        Ok(payload) => payload,
        Err(_) => return Decoded::Undecodable,
    };
    if let Some(escaped_id) = channel.strip_prefix(keys::VOICE_REPLY_CHANNEL_PREFIX) {
        return Decoded::Event(BusEvent::VoiceReply {
            session_id: keys::unpart(escaped_id),
            reply: payload,
        });
    }
    let event = if channel == keys::BROADCAST_CHANNEL {
        serde_json::from_str(&payload).ok().map(BusEvent::Broadcast)
    } else {
        if is_heartbeat(&payload) {
            return Decoded::Heartbeat;
        }
        serde_json::from_str(&payload).ok().map(BusEvent::Inbox)
    };
    match event {
        Some(event) => Decoded::Event(event),
        None => Decoded::Undecodable,
    }
}

/// Delay before the next subscribe attempt, given the previous delay and how
/// long the last subscription stayed up (`None`: subscribing failed). Only a
/// subscription that lasted `stable_after` restarts the backoff, so a
/// subscribe-then-kicked loop can't spin at the initial delay.
fn next_backoff(previous: Duration, uptime: Option<Duration>, timing: &BusTiming) -> Duration {
    match uptime {
        Some(uptime) if uptime >= timing.stable_after => timing.backoff_initial,
        _ => (previous * 2).min(timing.backoff_max),
    }
}

/// Aborts the wrapped task when dropped (including when the owning future
/// is itself aborted).
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Publish a heartbeat to this replica's own inbox every interval. Redis
/// 0.27's pub/sub connection can't PING and TCP keepalive uses OS defaults
/// (hours), so this is how a half-open subscription is noticed.
async fn heartbeat_loop(conn: RedisConn, replica_id: String, interval: Duration) {
    let bus = RedisBus::publisher(conn, &replica_id);
    let channel = keys::inbox_channel(&replica_id);
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        if let Err(error) = bus.publish(channel.clone(), HEARTBEAT_PAYLOAD.to_string()).await {
            tracing::warn!("Relay bus heartbeat publish failed: {}", error);
        }
    }
}

/// `heartbeat`: the connection to publish heartbeats with. Always `Some` in
/// production; without it an idle subscription is recycled every
/// `heartbeat_timeout`.
async fn subscriber_loop(
    client: redis::Client,
    heartbeat: Option<RedisConn>,
    replica_id: String,
    events: mpsc::UnboundedSender<BusEvent>,
    mut ready: Option<oneshot::Sender<()>>,
    timing: BusTiming,
) {
    // Dropped (aborting the heartbeat task) when this loop returns or is aborted.
    let _heartbeat = heartbeat.map(|conn| {
        AbortOnDrop(tokio::spawn(heartbeat_loop(
            conn,
            replica_id.clone(),
            timing.heartbeat_interval,
        )))
    });
    let mut previous_delay: Option<Duration> = None;
    loop {
        let mut uptime = None;
        match subscribe(&client, &replica_id).await {
            Ok(pubsub) => {
                let subscribed_at = Instant::now();
                match ready.take() {
                    Some(ready) => {
                        let _ = ready.send(());
                    }
                    None => {
                        if events.send(BusEvent::Resubscribed).is_err() {
                            return;
                        }
                    }
                }
                let mut stream = Box::pin(pubsub.into_on_message());
                loop {
                    let message = match tokio::time::timeout(timing.heartbeat_timeout, stream.next()).await {
                        Ok(Some(message)) => message,
                        Ok(None) => {
                            tracing::warn!("Relay bus subscription lost; reconnecting");
                            break;
                        }
                        Err(_) => {
                            tracing::warn!(
                                "Relay bus heard nothing for {:?} (not even its heartbeat); reconnecting",
                                timing.heartbeat_timeout
                            );
                            break;
                        }
                    };
                    match decode(&message) {
                        Decoded::Event(event) => {
                            if events.send(event).is_err() {
                                return;
                            }
                        }
                        Decoded::Heartbeat => {}
                        Decoded::Undecodable => tracing::warn!(
                            "Dropped an undecodable bus message on {}",
                            message.get_channel_name()
                        ),
                    }
                }
                uptime = Some(subscribed_at.elapsed());
            }
            Err(error) => tracing::warn!("Relay bus subscribe failed: {}", error),
        }
        if events.is_closed() {
            return;
        }
        let delay = match previous_delay {
            None => timing.backoff_initial,
            Some(previous) => next_backoff(previous, uptime, &timing),
        };
        previous_delay = Some(delay);
        tokio::time::sleep(delay).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

    async fn next_event(events: &mut mpsc::UnboundedReceiver<BusEvent>) -> BusEvent {
        tokio::time::timeout(std::time::Duration::from_secs(3), events.recv())
            .await
            .expect("no bus event within 3 s")
            .expect("bus closed")
    }

    #[tokio::test]
    #[ignore]
    async fn redis_bus_delivers_inbox_broadcast_and_voice_replies() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (bus_a, mut events_a, task_a) = RedisBus::start(conn.clone(), "replica-a").await.unwrap();
        let (bus_b, mut events_b, task_b) = RedisBus::start(conn.clone(), "replica-b").await.unwrap();
        assert_eq!(bus_a.backend_name(), "redis");

        // Inbox: only the addressed replica gets it, in publish order.
        for n in 0..20 {
            bus_a
                .send_inbox(
                    "replica-b",
                    InboxMessage::Deliver { connection_ids: vec!["c1".into()], frame: format!("{n}") },
                )
                .await
                .unwrap();
        }
        for n in 0..20 {
            assert_eq!(
                next_event(&mut events_b).await,
                BusEvent::Inbox(InboxMessage::Deliver {
                    connection_ids: vec!["c1".into()],
                    frame: format!("{n}"),
                })
            );
        }

        // Broadcast: everyone, including the sender.
        let message = BroadcastMessage::KeyChanged { astation_id: "astation-x".into() };
        bus_b.broadcast(message.clone()).await.unwrap();
        assert_eq!(next_event(&mut events_a).await, BusEvent::Broadcast(message.clone()));
        assert_eq!(next_event(&mut events_b).await, BusEvent::Broadcast(message));

        // Voice replies arrive on every replica, id unescaped.
        conn.run(|mut c| async move {
            redis::cmd("PUBLISH")
                .arg(keys::voice_reply_channel("v:1"))
                .arg("the answer")
                .query_async::<i64>(&mut c)
                .await
        })
        .await
        .unwrap();
        let expected = BusEvent::VoiceReply { session_id: "v:1".into(), reply: "the answer".into() };
        assert_eq!(next_event(&mut events_a).await, expected);
        assert_eq!(next_event(&mut events_b).await, expected);

        // A publisher-only bus (admin) reaches subscribers too.
        let admin = RedisBus::publisher(conn.clone(), "admin");
        admin
            .broadcast(BroadcastMessage::RoomChanged { code: "ROOM".into() })
            .await
            .unwrap();
        assert_eq!(
            next_event(&mut events_a).await,
            BusEvent::Broadcast(BroadcastMessage::RoomChanged { code: "ROOM".into() })
        );
        task_a.abort();
        task_b.abort();
    }

    #[tokio::test]
    #[ignore]
    async fn redis_bus_resubscribes_after_a_dropped_connection() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (bus, mut events, task) = RedisBus::start(conn.clone(), "replica-r").await.unwrap();

        // Drop every pub/sub connection server-side, twice in a row.
        for _ in 0..2 {
            conn.run(|mut c| async move {
                redis::cmd("CLIENT")
                    .arg("KILL")
                    .arg("TYPE")
                    .arg("pubsub")
                    .query_async::<i64>(&mut c)
                    .await
            })
            .await
            .unwrap();
            assert_eq!(next_event(&mut events).await, BusEvent::Resubscribed);
        }
        assert!(!task.is_finished());

        // The renewed subscription delivers again.
        let message = BroadcastMessage::RoomChanged { code: "R".into() };
        bus.broadcast(message.clone()).await.unwrap();
        assert_eq!(next_event(&mut events).await, BusEvent::Broadcast(message));
        bus.send_inbox("replica-r", InboxMessage::Close { connection_id: "c".into(), code: None, reason: String::new() })
            .await
            .unwrap();
        assert!(matches!(next_event(&mut events).await, BusEvent::Inbox(_)));
        task.abort();
    }

    #[tokio::test]
    async fn subscriber_loop_keeps_retrying_without_redis() {
        // No server, so no RedisConn either: exercise the subscriber loop's
        // error path directly and check it keeps retrying instead of exiting.
        let client = redis::Client::open("redis://127.0.0.1:1/").unwrap();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (ready_tx, ready_rx) = oneshot::channel();
        let task = tokio::spawn(subscriber_loop(client, None, "x".into(), tx, Some(ready_tx), fast_timing()));
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert!(!task.is_finished(), "subscriber loop gave up");
        assert!(rx.try_recv().is_err());
        task.abort();
        drop(ready_rx);
    }

    fn pubsub_message(channel: &str, payload: &str) -> redis::Msg {
        redis::Msg::from_value(&redis::Value::Array(vec![
            redis::Value::BulkString(b"message".to_vec()),
            redis::Value::BulkString(channel.as_bytes().to_vec()),
            redis::Value::BulkString(payload.as_bytes().to_vec()),
        ]))
        .expect("a pub/sub message")
    }

    #[test]
    fn heartbeat_decodes_to_no_event() {
        let heartbeat = pubsub_message(&keys::inbox_channel("r"), HEARTBEAT_PAYLOAD);
        assert_eq!(decode(&heartbeat), Decoded::Heartbeat);
        let garbage = pubsub_message(&keys::inbox_channel("r"), "{\"type\":\"nope\"}");
        assert_eq!(decode(&garbage), Decoded::Undecodable);
        let deliver = pubsub_message(
            &keys::inbox_channel("r"),
            "{\"type\":\"deliver\",\"connection_ids\":[\"c\"],\"frame\":\"f\"}",
        );
        assert_eq!(
            decode(&deliver),
            Decoded::Event(BusEvent::Inbox(InboxMessage::Deliver {
                connection_ids: vec!["c".into()],
                frame: "f".into(),
            }))
        );
    }

    fn fast_timing() -> BusTiming {
        BusTiming {
            heartbeat_interval: Duration::from_millis(200),
            heartbeat_timeout: Duration::from_millis(1000),
            backoff_initial: Duration::from_millis(100),
            backoff_max: Duration::from_secs(5),
            stable_after: Duration::from_secs(30),
        }
    }

    #[test]
    fn backoff_resets_only_after_a_stable_subscription() {
        let timing = fast_timing();
        let ms = Duration::from_millis;
        // `next_backoff(previous delay, uptime)` is the delay before the next
        // attempt. Kicked right after subscribing: keep doubling up to the cap.
        assert_eq!(next_backoff(ms(100), Some(ms(10)), &timing), ms(200));
        assert_eq!(next_backoff(ms(3000), Some(ms(10)), &timing), ms(5000));
        assert_eq!(next_backoff(ms(5000), Some(ms(10)), &timing), ms(5000));
        // Subscribe failed: keep doubling.
        assert_eq!(next_backoff(ms(400), None, &timing), ms(800));
        // Up long enough: start again from the initial delay.
        assert_eq!(next_backoff(ms(5000), Some(Duration::from_secs(30)), &timing), ms(100));
    }

    async fn kill_pubsub_clients(conn: &RedisConn) {
        conn.run(|mut c| async move {
            redis::cmd("CLIENT")
                .arg("KILL")
                .arg("TYPE")
                .arg("pubsub")
                .query_async::<i64>(&mut c)
                .await
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    #[ignore]
    async fn redis_bus_backs_off_when_kicked_repeatedly() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (_bus, mut events, task) =
            RedisBus::start_with(conn.clone(), "replica-k", fast_timing()).await.unwrap();
        let mut delays = Vec::new();
        for _ in 0..3 {
            let kicked = std::time::Instant::now();
            kill_pubsub_clients(&conn).await;
            assert_eq!(next_event(&mut events).await, BusEvent::Resubscribed);
            delays.push(kicked.elapsed());
        }
        // 100 ms, 200 ms, 400 ms: no reset to 100 ms between short-lived subscriptions.
        assert!(delays[2] >= Duration::from_millis(350), "delays {delays:?}");
        assert!(delays[2] > delays[0], "delays {delays:?}");
        task.abort();
    }

    #[tokio::test]
    #[ignore]
    async fn redis_bus_heartbeat_detects_a_silent_subscription() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (_bus, mut events, task) =
            RedisBus::start_with(conn.clone(), "replica-h", fast_timing()).await.unwrap();

        // Healthy and idle: heartbeats keep the subscription alive well past
        // the timeout, and none of them surface as events.
        let quiet = tokio::time::timeout(Duration::from_millis(2500), events.recv()).await;
        assert!(quiet.is_err(), "unexpected event {quiet:?}");

        // Freeze publishing (PUBLISH is paused by CLIENT PAUSE WRITE,
        // SUBSCRIBE is not): no heartbeat arrives, so the subscriber gives up
        // on the stream after heartbeat_timeout and resubscribes.
        let paused = std::time::Instant::now();
        conn.run(|mut c| async move {
            redis::cmd("CLIENT").arg("PAUSE").arg(3000).arg("WRITE").query_async::<()>(&mut c).await
        })
        .await
        .unwrap();
        let event = next_event(&mut events).await;
        let elapsed = paused.elapsed();
        conn.run(|mut c| async move { redis::cmd("CLIENT").arg("UNPAUSE").query_async::<()>(&mut c).await })
            .await
            .unwrap();
        assert_eq!(event, BusEvent::Resubscribed);
        assert!(elapsed >= Duration::from_millis(700), "resubscribed after {elapsed:?}");
        assert!(!task.is_finished());
        task.abort();
    }

    #[tokio::test]
    async fn heartbeat_task_stops_with_the_subscriber_loop() {
        let flag = std::sync::Arc::new(());
        let held = flag.clone();
        let guard = AbortOnDrop(tokio::spawn(async move {
            let _held = held;
            std::future::pending::<()>().await
        }));
        tokio::task::yield_now().await;
        assert_eq!(std::sync::Arc::strong_count(&flag), 2);
        drop(guard);
        for _ in 0..50 {
            if std::sync::Arc::strong_count(&flag) == 1 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("heartbeat task still running");
    }
}
