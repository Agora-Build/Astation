//! ReplicaBus over Redis pub/sub. Each replica subscribes to its own inbox
//! (`relay:inbox:<replica_id>`), the broadcast channel and, as a pattern,
//! every voice-reply channel. Redis keeps order per publisher and channel,
//! so one Astation → Atem stream (one replica to one inbox) stays ordered.

use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use super::{keys, redis_error, RedisConn, REDIS_TIMEOUT};
use crate::cluster::bus::{BroadcastMessage, BusEvent, InboxMessage, ReplicaBus};
use crate::cluster::StoreError;

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
        let (events_tx, events_rx) = mpsc::unbounded_channel();
        let (ready_tx, ready_rx) = oneshot::channel();
        let task = tokio::spawn(subscriber_loop(
            conn.client().clone(),
            replica_id.to_string(),
            events_tx,
            Some(ready_tx),
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

fn decode(message: &redis::Msg) -> Option<BusEvent> {
    let channel = message.get_channel_name();
    let payload: String = message.get_payload().ok()?;
    if let Some(escaped_id) = channel.strip_prefix(keys::VOICE_REPLY_CHANNEL_PREFIX) {
        return Some(BusEvent::VoiceReply {
            session_id: keys::unpart(escaped_id),
            reply: payload,
        });
    }
    if channel == keys::BROADCAST_CHANNEL {
        return serde_json::from_str(&payload).ok().map(BusEvent::Broadcast);
    }
    serde_json::from_str(&payload).ok().map(BusEvent::Inbox)
}

async fn subscriber_loop(
    client: redis::Client,
    replica_id: String,
    events: mpsc::UnboundedSender<BusEvent>,
    mut ready: Option<oneshot::Sender<()>>,
) {
    let mut backoff = Duration::from_millis(100);
    loop {
        match subscribe(&client, &replica_id).await {
            Ok(pubsub) => {
                backoff = Duration::from_millis(100);
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
                while let Some(message) = stream.next().await {
                    match decode(&message) {
                        Some(event) => {
                            if events.send(event).is_err() {
                                return;
                            }
                        }
                        None => tracing::warn!(
                            "Dropped an undecodable bus message on {}",
                            message.get_channel_name()
                        ),
                    }
                }
                tracing::warn!("Relay bus subscription lost; reconnecting");
            }
            Err(error) => tracing::warn!("Relay bus subscribe failed: {}", error),
        }
        if events.is_closed() {
            return;
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(5));
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
        let task = tokio::spawn(subscriber_loop(client, "x".into(), tx, Some(ready_tx)));
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert!(!task.is_finished(), "subscriber loop gave up");
        assert!(rx.try_recv().is_err());
        task.abort();
        drop(ready_rx);
    }
}
