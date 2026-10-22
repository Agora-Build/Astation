//! Independent r9 transport. Account login permits routing only; the host verifies every device.
use crate::{cluster::ConnRef, AppState};
use axum::{
    extract::{
        ws::{Message, WebSocket},
        ConnectInfo, Query, State, WebSocketUpgrade,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, value::RawValue};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore};

pub(crate) const MAX_BYTES: usize = 2_097_152;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Envelope<'a> {
    #[serde(rename = "type")]
    kind: String,
    event: String,
    pub(crate) channel: String,
    #[serde(borrow)]
    frame: Option<&'a RawValue>,
    transport: Option<String>,
    reason: Option<String>,
}

impl<'a> Envelope<'a> {
    pub(crate) fn parse(text: &'a str) -> Option<Self> {
        if text.len() > MAX_BYTES {
            return None;
        }
        let v: Self = serde_json::from_str(text).ok()?;
        if v.kind != "channel" || !valid_handle(&v.channel) {
            return None;
        }
        match v.event.as_str() {
            "open"
                if v.transport.as_deref() == Some("relay")
                    && v.frame.is_none()
                    && v.reason.is_none() => {}
            "frame"
                if v.transport.is_none()
                    && v.reason.is_none()
                    && v.frame.is_some_and(|f| f.get().starts_with('{')) => {}
            "close"
                if v.frame.is_none()
                    && v.transport.is_none()
                    && v.reason.as_ref().is_none_or(|s| {
                        s.len() <= 32 && s.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
                    }) => {}
            _ => return None,
        }
        Some(v)
    }

    fn with_handle(&self, handle: &str) -> String {
        match self.event.as_str() {
            "open" => json!({"type":"channel","event":"open","channel":handle,"transport":"relay"}).to_string(),
            "frame" => format!(r#"{{"type":"channel","event":"frame","channel":"{handle}","frame":{}}}"#, self.frame.unwrap().get()),
            _ => json!({"type":"channel","event":"close","channel":handle,"reason":self.reason.as_deref().unwrap_or("closed")}).to_string(),
        }
    }
}

fn valid_handle(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

struct Route {
    subject: String,
    target: ConnRef,
    client_handle: String,
    sender: mpsc::Sender<QueuedFrame>,
    bytes: Arc<Semaphore>,
    close: watch::Sender<bool>,
    binding: Option<super::recovery::HostBinding>,
    owner_route: Option<super::recovery::OwnerRoute>,
}

pub(crate) struct QueuedFrame {
    text: String,
    _bytes: OwnedSemaphorePermit,
}

#[derive(Default)]
struct Inner {
    routes: HashMap<String, Route>,
    deliveries: HashMap<String, oneshot::Sender<bool>>,
}

#[derive(Clone, Default)]
pub(crate) struct ChannelBroker(Arc<Mutex<Inner>>);

impl ChannelBroker {
    pub(crate) fn register(
        &self,
        replica: &str,
        subject: &str,
        target: ConnRef,
        client_handle: &str,
    ) -> Option<(String, mpsc::Receiver<QueuedFrame>, watch::Receiver<bool>)> {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if inner.routes.len() >= 1024
            || inner
                .routes
                .values()
                .filter(|r| r.subject == subject)
                .count()
                >= 16
        {
            return None;
        }
        let handle = format!("rc_{}_{}", replica, uuid::Uuid::new_v4().simple());
        if !valid_handle(&handle) {
            return None;
        }
        // Include the in-flight socket write in the byte bound.
        let (sender, frames) = mpsc::channel(64);
        let bytes = Arc::new(Semaphore::new(4 * 1024 * 1024));
        let (close, closed) = watch::channel(false);
        inner.routes.insert(
            handle.clone(),
            Route {
                subject: subject.into(),
                target,
                client_handle: client_handle.into(),
                sender,
                bytes,
                close,
                binding: None,
                owner_route: None,
            },
        );
        Some((handle, frames, closed))
    }

    pub(crate) fn bind_host(&self, handle: &str, binding: super::recovery::HostBinding) {
        if let Some(route) = self.0.lock().unwrap_or_else(|e| e.into_inner()).routes.get_mut(handle) {
            route.binding = Some(binding);
        }
    }

    pub(crate) fn host_binding(&self, handle: &str) -> Option<super::recovery::HostBinding> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).routes.get(handle)?.binding.clone()
    }

    pub(crate) fn bind_owner(&self, handle: &str, route: super::recovery::OwnerRoute) {
        if let Some(bound) = self.0.lock().unwrap_or_else(|e| e.into_inner()).routes.get_mut(handle) {
            bound.owner_route = Some(route);
        }
    }

    pub(crate) fn owner_route(&self, handle: &str) -> Option<super::recovery::OwnerRoute> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).routes.get(handle)?.owner_route.clone()
    }

    pub(crate) fn reply(&self, handle: &str, source: &ConnRef, text: &str) -> bool {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let Some(route) = inner.routes.get(handle) else {
            return false;
        };
        if &route.target != source {
            return false;
        }
        let Some(envelope) = Envelope::parse(text) else {
            let _ = route.close.send(true);
            return false;
        };
        let text = envelope.with_handle(&route.client_handle);
        let permit = route
            .bytes
            .clone()
            .try_acquire_many_owned(text.len() as u32);
        let queued = permit.ok().map(|bytes| QueuedFrame {
            text,
            _bytes: bytes,
        });
        if envelope.event == "open"
            || envelope.channel != handle
            || queued.is_none_or(|frame| route.sender.try_send(frame).is_err())
        {
            let _ = route.close.send(true);
            inner.routes.remove(handle);
            return false;
        }
        true
    }

    pub(crate) fn remove(&self, handle: &str) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .routes
            .remove(handle);
    }

    pub(crate) fn delivery(&self) -> Option<(String, oneshot::Receiver<bool>)> {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        inner.deliveries.retain(|_, sender| !sender.is_closed());
        if inner.deliveries.len() >= 1024 {
            return None;
        }
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        inner.deliveries.insert(id.clone(), tx);
        Some((id, rx))
    }
    pub(crate) fn delivered(&self, id: &str, accepted: bool) {
        if let Some(tx) = self
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .deliveries
            .remove(id)
        {
            let _ = tx.send(accepted);
        }
    }
    pub(crate) fn reset(&self) {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        for (_, route) in inner.routes.drain() {
            let _ = route.close.send(true);
        }
        inner.deliveries.clear();
    }
}

pub(crate) fn origin(handle: &str) -> Option<&str> {
    let rest = handle.strip_prefix("rc_")?;
    let (replica, id) = rest.split_once('_')?;
    (valid_handle(handle)
        && !replica.is_empty()
        && id.len() == 32
        && id.bytes().all(|b| b.is_ascii_hexdigit()))
    .then_some(replica)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ChannelQuery {
    genesis: String,
    host: String,
}

pub(super) async fn connect(
    State(state): State<AppState>,
    Query(query): Query<ChannelQuery>,
    headers: HeaderMap,
    peer: Option<ConnectInfo<std::net::SocketAddr>>,
    ws: WebSocketUpgrade,
) -> Response {
    if state.relay.is_draining() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    let ip = crate::cluster::limits::client_ip(&headers, peer.map(|ConnectInfo(addr)| addr));
    let Some(permit) = state.relay.ws_limiter().try_acquire(&ip) else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    let subject = match super::recovery::subject(&state, &headers).await {
        Ok(s) => s,
        Err(e) => return e.into_response(),
    };
    let (room, target, binding, host_trust_gen) = match super::recovery::host_target(&state, &query.genesis, &subject, &query.host).await {
        Ok(route) => route,
        Err(error) => return error.into_response(),
    };
    let owner_route = binding.is_none().then(|| super::recovery::OwnerRoute {
        genesis:query.genesis, host:query.host.clone(), room:room.clone(), connection:target.clone(), host_trust_gen,
    });
    // The account subject is only a privacy/rate-limit boundary. No device ID or role is accepted here.
    ws.max_message_size(MAX_BYTES)
        .max_frame_size(MAX_BYTES)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            serve(socket, state.relay, state.recovery, room, query.host, target, subject, binding, owner_route).await;
        })
}

struct RouteGuard {
    hub: crate::relay::RelayHub,
    target: ConnRef,
    handle: String,
    notify_host: bool,
    owner_route: Option<super::recovery::OwnerRoute>,
}
impl Drop for RouteGuard {
    fn drop(&mut self) {
        self.hub.channels().remove(&self.handle);
        if !self.notify_host {
            return;
        }
        let (hub, target, handle, owner_route) = (self.hub.clone(), self.target.clone(), self.handle.clone(), self.owner_route.clone());
        tokio::spawn(async move {
            let _ = hub
                .deliver_scoped_channel(
                    &target,
                    json!({"type":"channel","event":"close","channel":handle,"reason":"closed"})
                        .to_string(), owner_route,
                )
                .await;
        });
    }
}

async fn serve(
    mut socket: WebSocket,
    hub: crate::relay::RelayHub,
    recovery: Arc<super::recovery::RecoveryStore>,
    room: String,
    host: String,
    target: ConnRef,
    subject: String,
    binding: Option<super::recovery::HostBinding>,
    owner_route: Option<super::recovery::OwnerRoute>,
) {
    let initial = tokio::time::timeout(Duration::from_secs(10), socket.next()).await;
    let Ok(Some(Ok(Message::Text(text)))) = initial else {
        return;
    };
    let Some(open) = Envelope::parse(&text).filter(|e| e.event == "open") else {
        return;
    };
    let Some((handle, mut replies, mut closed)) =
        hub.channels()
            .register(hub.replica_id(), &subject, target.clone(), &open.channel)
    else {
        return;
    };
    if let Some(binding) = &binding { hub.channels().bind_host(&handle, binding.clone()); }
    if let Some(route) = &owner_route { hub.channels().bind_owner(&handle, route.clone()); }
    let mut guard = RouteGuard {
        hub: hub.clone(),
        target: target.clone(),
        handle: handle.clone(),
        notify_host: true,
        owner_route: owner_route.clone(),
    };
    if !hub
        .deliver_scoped_channel(&target, open.with_handle(&handle), owner_route.clone())
        .await
    {
        return;
    }
    let lifetime = tokio::time::sleep(Duration::from_secs(3600));
    tokio::pin!(lifetime);
    let mut health = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            biased;
            _ = closed.changed() => break,
            _ = &mut lifetime => break,
            _ = health.tick() => {
                let current = if let Some(binding) = &binding {
                    recovery.with_host_route(binding, || async { () }).await.is_some()
                } else { matches!(hub.room(&room).await, Ok(Some(r)) if r.owner.is_some() && r.atems.get(&host) == Some(&target)) };
                if !current { break; }
                if !matches!(tokio::time::timeout(Duration::from_secs(5), socket.send(Message::Ping(vec![]))).await, Ok(Ok(()))) { break; }
            }
            reply = replies.recv() => {
                let Some(reply) = reply else { break };
                let is_close = Envelope::parse(&reply.text).is_some_and(|e| e.event == "close");
                if is_close { guard.notify_host = false; }
                let result = tokio::time::timeout(Duration::from_secs(5), socket.send(Message::Text(reply.text))).await;
                drop(reply._bytes);
                if !matches!(result, Ok(Ok(()))) || is_close { break; }
            }
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        let Some(message) = Envelope::parse(&text).filter(|e| e.channel == open.channel && e.event != "open") else { break };
                        let current = if let Some(binding) = &binding {
                            recovery.with_host_route(binding, || async { () }).await.is_some()
                        } else { matches!(hub.room(&room).await, Ok(Some(r)) if r.owner.is_some() && r.atems.get(&host) == Some(&target)) };
                        if !current { break; }
                        let sent = hub.deliver_scoped_channel(&target, message.with_handle(&handle), owner_route.clone()).await;
                        if sent && message.event == "close" { guard.notify_host = false; }
                        if !sent || message.event == "close" { break; }
                    },
                    Some(Ok(Message::Pong(_))) => {},
                    Some(Ok(Message::Ping(payload))) => { if socket.send(Message::Pong(payload)).await.is_err() { break; } },
                    _ => break,
                }
            }
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(1), socket.close()).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct TestBus {
        replicas: Mutex<HashMap<String, mpsc::UnboundedSender<crate::cluster::bus::BusEvent>>>,
        lose_acks: std::sync::atomic::AtomicBool,
    }
    #[async_trait::async_trait]
    impl crate::cluster::bus::ReplicaBus for TestBus {
        fn backend_name(&self) -> &'static str {
            "test"
        }
        async fn send_inbox(
            &self,
            replica: &str,
            message: crate::cluster::bus::InboxMessage,
        ) -> Result<(), crate::cluster::StoreError> {
            if self.lose_acks.load(std::sync::atomic::Ordering::Relaxed)
                && matches!(
                    message,
                    crate::cluster::bus::InboxMessage::ChannelDelivered { .. }
                )
            {
                return Ok(());
            }
            self.replicas
                .lock()
                .unwrap()
                .get(replica)
                .unwrap()
                .send(crate::cluster::bus::BusEvent::Inbox(message))
                .map_err(|_| crate::cluster::StoreError::Unavailable("test bus closed".into()))
        }
        async fn broadcast(
            &self,
            _: crate::cluster::bus::BroadcastMessage,
        ) -> Result<(), crate::cluster::StoreError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn two_replica_dispatchers_acknowledge_both_directions_and_never_replay_after_ack_loss() {
        use crate::relay::{HubParts, RelayHub};
        let bus = Arc::new(TestBus::default());
        let identity = Arc::new(crate::identity_store::InMemoryIdentityStore::new());
        let mut hubs = Vec::new();
        let mut tasks = Vec::new();
        for replica in ["r1", "r2"] {
            let hub = RelayHub::from_parts(HubParts {
                replica_id: replica.into(),
                bus: bus.clone(),
                ..HubParts::single_instance(
                    crate::cluster::directory::InMemoryRoomDirectory::new(),
                    Duration::from_secs(10),
                )
            });
            let (tx, rx) = mpsc::unbounded_channel();
            bus.replicas.lock().unwrap().insert(replica.into(), tx);
            tasks.push(hub.spawn_bus_dispatcher(
                identity.clone(),
                crate::voice_session::ReplyWaiters::default(),
                rx,
            ));
            hubs.push(hub);
        }
        let target = ConnRef::new("host", "r2");
        let mut socket = hubs[1].local().register(
            "host",
            "room",
            crate::cluster::local::SocketRole::Atem {
                atem_id: "host-a".into(),
            },
        );
        let (handle, mut replies, _closed) = hubs[0]
            .channels()
            .register("r1", "alice", target.clone(), "phone_1")
            .unwrap();
        let open = json!({"type":"channel","event":"open","channel":handle,"transport":"relay"})
            .to_string();
        assert!(hubs[0].deliver_channel(&target, open.clone()).await);
        assert_eq!(socket.frames.recv().await.unwrap(), open);
        let reply =
            json!({"type":"channel","event":"frame","channel":handle,"frame":{"ct":"ciphertext"}})
                .to_string();
        assert!(hubs[1].remote_channel_reply(&target, &reply).await);
        assert!(replies.recv().await.unwrap().text.contains("ciphertext"));
        bus.lose_acks
            .store(true, std::sync::atomic::Ordering::Relaxed);
        assert!(!hubs[0].deliver_channel(&target, open.clone()).await);
        assert_eq!(socket.frames.recv().await.unwrap(), open);
        assert!(
            socket.frames.try_recv().is_err(),
            "No ciphertext retries after uncertain delivery"
        );
        for task in tasks {
            task.abort();
        }
    }

    async fn proved_route_fences_at_both_replica_queues(
        stores: [Arc<super::super::recovery::RecoveryStore>; 2],
    ) {
        use crate::relay::{HubParts, RelayHub};
        use crate::remote_api::{
            host_route_tests::proof, push_ingress::tests::Fixture, recovery::Operation,
        };
        use atem_client::host_route::HostChallenge;
        let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        f.publish(&stores[0]).await;
        let bus = Arc::new(TestBus::default());
        let mut hubs = Vec::new();
        let mut tasks = Vec::new();
        for (replica, store) in ["r1", "r2"].into_iter().zip(&stores) {
            let hub = RelayHub::from_parts(HubParts {
                replica_id: replica.into(),
                bus: bus.clone(),
                ..HubParts::single_instance(
                    crate::cluster::directory::InMemoryRoomDirectory::new(),
                    Duration::from_secs(10),
                )
            });
            hub.configure_recovery(store.clone());
            let (tx, rx) = mpsc::unbounded_channel();
            bus.replicas.lock().unwrap().insert(replica.into(), tx);
            tasks.push(hub.spawn_bus_dispatcher(
                Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
                crate::voice_session::ReplyWaiters::default(),
                rx,
            ));
            hubs.push(hub);
        }
        let old_target = ConnRef::new("old-host", "r2");
        let new_target = ConnRef::new("new-host", "r2");
        let mut old_socket = hubs[1].local().register(
            &old_target.conn,
            "phone",
            crate::cluster::local::SocketRole::Atem {
                atem_id: "host-a".into(),
            },
        );
        let mut new_socket = hubs[1].local().register(
            &new_target.conn,
            "phone",
            crate::cluster::local::SocketRole::Atem {
                atem_id: "host-a".into(),
            },
        );
        hubs[1]
            .directory()
            .claim_owner(
                "phone",
                &ConnRef::new("owner", "r2"),
                "127.0.0.1",
                chrono::Utc::now().timestamp(),
                crate::cluster::directory::PendingCaps::NONE,
            )
            .await
            .unwrap();
        hubs[1]
            .directory()
            .join_atem("phone", "host-a", &old_target)
            .await
            .unwrap();
        let owner_route = super::super::recovery::OwnerRoute {
            genesis: f.log.genesis_hash().to_hex(),
            host: "host-a".into(),
            room: "phone".into(),
            connection: old_target.clone(),
            host_trust_gen: 1,
        };
        let (owner_handle, mut owner_replies, _) = hubs[0]
            .channels()
            .register("r1", "alice", old_target.clone(), "owner_1")
            .unwrap();
        hubs[0]
            .channels()
            .bind_owner(&owner_handle, owner_route.clone());
        let owner_open =
            json!({"type":"channel","event":"open","channel":owner_handle,"transport":"relay"})
                .to_string();
        assert!(
            hubs[0]
                .deliver_scoped_channel(&old_target, owner_open.clone(), Some(owner_route.clone()))
                .await
        );
        assert_eq!(old_socket.frames.recv().await.unwrap(), owner_open);
        let challenge = HostChallenge::new("phone");
        let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
        let (old, _) = stores[0]
            .admit_host(
                &message,
                challenge.nonce,
                "phone",
                "host-a",
                old_target.clone(),
            )
            .await
            .unwrap();
        hubs[1].track_host_route(old.clone());
        let (handle, mut replies, _) = hubs[0]
            .channels()
            .register("r1", "alice", old_target.clone(), "phone_1")
            .unwrap();
        hubs[0].channels().bind_host(&handle, old);
        let open = json!({"type":"channel","event":"open","channel":handle,"transport":"relay"})
            .to_string();
        assert!(hubs[0].deliver_channel(&old_target, open.clone()).await);
        assert_eq!(old_socket.frames.recv().await.unwrap(), open);
        let challenge = HostChallenge::new("phone");
        let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
        let (new, _) = stores[1]
            .admit_host(
                &message,
                challenge.nonce,
                "phone",
                "host-a",
                new_target.clone(),
            )
            .await
            .unwrap();
        hubs[1].track_host_route(new);
        // Deliberately deliver no old-connection close or room invalidation. The
        // destination and reply broker must consult the durable generation anyway.
        assert!(!hubs[0].deliver_channel(&old_target, open.clone()).await);
        assert!(
            !hubs[0]
                .deliver_scoped_channel(&old_target, owner_open, Some(owner_route))
                .await
        );
        assert!(old_socket.frames.try_recv().is_err());
        let late = json!({"type":"channel","event":"frame","channel":handle,"frame":{"ct":"late"}})
            .to_string();
        assert!(hubs[1].remote_channel_reply(&old_target, &late).await);
        assert!(replies.try_recv().is_err());
        let late_owner = json!({"type":"channel","event":"frame","channel":owner_handle,"frame":{"ct":"late_a"}}).to_string();
        assert!(hubs[1].remote_channel_reply(&old_target, &late_owner).await);
        assert!(owner_replies.try_recv().is_err());
        assert!(hubs[0].deliver_channel(&new_target, open.clone()).await);
        assert_eq!(new_socket.frames.recv().await.unwrap(), open);
        assert_eq!(
            stores[0]
                .perform(
                    &f.log.genesis_hash().to_hex(),
                    "alice",
                    Operation::Append {
                        entry: f.remove_host(),
                        expected: f.log.head().clone(),
                    }
                )
                .await
                .0,
            StatusCode::OK
        );
        assert!(!hubs[0].deliver_channel(&new_target, open).await);
        assert!(new_socket.frames.try_recv().is_err());
        for task in tasks {
            task.abort();
        }
    }

    #[tokio::test]
    async fn replacement_and_removal_fence_two_replicas_even_when_close_is_lost() {
        let store = super::super::recovery::RecoveryStore::memory();
        proved_route_fences_at_both_replica_queues([store.clone(), store]).await;
    }

    #[tokio::test]
    #[ignore = "requires a local isolated Postgres test database"]
    async fn postgres_replica_queues_use_the_same_durable_generation() {
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let second = db.reconnect(4).await;
        proved_route_fences_at_both_replica_queues([
            super::super::recovery::RecoveryStore::postgres(db.pool.clone()),
            super::super::recovery::RecoveryStore::postgres(second.clone()),
        ])
        .await;
        second.close().await;
        db.cleanup().await;
    }

    #[tokio::test]
    async fn replies_are_bound_to_the_host_generation_and_never_change_inner_bytes() {
        let broker = ChannelBroker::default();
        let host = ConnRef::new("socket-a", "host-replica");
        let (h, mut rx, _) = broker
            .register("client-replica", "account-a", host.clone(), "native_1")
            .unwrap();
        let bytes = format!(
            r#"{{"type":"channel","event":"frame","channel":"{h}","frame":{{"n":1e3,"value":"\u0061"}}}}"#
        );
        broker.reply(&h, &ConnRef::new("socket-b", "host-replica"), &bytes);
        assert!(rx.try_recv().is_err());
        broker.reply(&h, &host, &bytes);
        let reply = rx.recv().await.unwrap();
        assert!(reply.text.contains(r#""frame":{"n":1e3,"value":"\u0061"}"#));
        assert!(reply.text.contains(r#""channel":"native_1""#));
    }
    #[tokio::test]
    async fn backpressure_and_bus_loss_close_routes_instead_of_dropping_records() {
        let broker = ChannelBroker::default();
        let host = ConnRef::new("host", "local");
        let (h, _rx, mut close) = broker.register("local", "a", host.clone(), "one").unwrap();
        let frame = format!(r#"{{"type":"channel","event":"frame","channel":"{h}","frame":{{}}}}"#);
        for _ in 0..65 {
            broker.reply(&h, &host, &frame);
        }
        close.changed().await.unwrap();
        assert!(*close.borrow());
        let (_, _rx, mut close) = broker.register("local", "a", host, "two").unwrap();
        broker.reset();
        close.changed().await.unwrap();
        assert!(*close.borrow());
    }
    #[tokio::test]
    async fn byte_limit_includes_frames_already_taken_by_the_socket_writer() {
        let broker = ChannelBroker::default();
        let host = ConnRef::new("host", "local");
        let (handle, mut rx, mut close) =
            broker.register("local", "a", host.clone(), "one").unwrap();
        let frame = json!({"type":"channel","event":"frame","channel":handle,
            "frame":{"ct":"a".repeat(1_500_000)}})
        .to_string();
        assert!(broker.reply(&handle, &host, &frame));
        let inflight = rx.recv().await.unwrap();
        assert!(broker.reply(&handle, &host, &frame));
        assert!(!broker.reply(&handle, &host, &frame));
        close.changed().await.unwrap();
        assert!(*close.borrow());
        drop(inflight);
    }

    #[tokio::test]
    async fn malformed_reply_closes_only_its_bound_route_and_revoked_sources_cannot_close_it() {
        let broker = ChannelBroker::default();
        let host = ConnRef::new("host", "local");
        let (one, _rx, mut close_one) = broker.register("local", "a", host.clone(), "one").unwrap();
        let (_, _rx, close_two) = broker.register("local", "a", host.clone(), "two").unwrap();
        let malformed = format!(
            r#"{{"type":"channel","event":"frame","channel":"{one}","frame":{{}},"unexpected":true}}"#
        );
        assert!(!broker.reply(&one, &ConnRef::new("old-host", "local"), &malformed));
        assert!(!*close_one.borrow());
        assert!(!broker.reply(&one, &host, &malformed));
        close_one.changed().await.unwrap();
        assert!(*close_one.borrow());
        assert!(!*close_two.borrow());
    }
    #[test]
    fn malformed_or_plaintext_messages_have_no_transport_path() {
        for s in [
            r#"{"type":"session","data":{"op":"hello","revision":8}}"#,
            r#"{"type":"channel","event":"open","channel":"a","transport":"direct"}"#,
            r#"{"type":"channel","event":"frame","channel":"a","channel":"b","frame":{}}"#,
        ] {
            assert!(Envelope::parse(s).is_none());
        }
        assert_eq!(
            origin("rc_local_0123456789abcdef0123456789abcdef"),
            Some("local")
        );
    }
}
