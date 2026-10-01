//! Two relays in one process sharing Valkey, with the Astation and its
//! Atems deliberately on different replicas (spec: "Testing"). An
//! in-process identity store, vault and knowledge store stand in for the
//! shared Postgres (same traits). Each replica is built by the same
//! functions `main` uses in Redis mode (`start_redis_replica`,
//! `spawn_upkeep`, `router`). Every test is #[ignore]d:
//!
//!   docker run --rm -d --name relay-test-valkey -p 56379:6379 valkey/valkey:8
//!   TEST_REDIS_URL=redis://127.0.0.1:56379/ cargo test redis -- --ignored --test-threads=1
//!   docker rm -f relay-test-valkey

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::StreamExt;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message as ClientMessage;
use tower::ServiceExt;

use crate::cluster::keys::KeyCache;
use crate::cluster::redis::test_support::{flush, test_url, REDIS_LOCK};
use crate::cluster::redis::RedisCluster;
use crate::identity_store::{IdentityStore, InMemoryIdentityStore};
use crate::knowledge_store::{InMemoryKnowledgeStore, KnowledgeStore};
use crate::relay::tests::{
    assert_closed, assert_silent, authenticate, connect_astation, connect_atem, next_client_json,
    send_json, spawn_relay, verified_astation, TestKey, TestSocket, TEST_AUTH_TIMEOUT,
};
use crate::vault_store::{InMemoryVaultStore, VaultStore};
use crate::AppState;

/// A TCP forwarder in front of Valkey. `cut()` drops every link and
/// refuses new ones: that replica loses Redis, the other doesn't.
struct CutProxy {
    port: u16,
    cut: Arc<AtomicBool>,
    links: Arc<Mutex<Vec<JoinHandle<()>>>>,
    accept: JoinHandle<()>,
}

impl CutProxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let cut = Arc::new(AtomicBool::new(false));
        let links: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
        let accept = tokio::spawn({
            let (cut, links) = (cut.clone(), links.clone());
            async move {
                while let Ok((mut inbound, _)) = listener.accept().await {
                    if cut.load(Ordering::SeqCst) {
                        continue; // dropped: the connection is refused
                    }
                    let link = tokio::spawn(async move {
                        if let Ok(mut outbound) = tokio::net::TcpStream::connect(target).await {
                            let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
                        }
                    });
                    links.lock().unwrap().push(link);
                }
            }
        });
        Self { port, cut, links, accept }
    }

    fn url(&self) -> String {
        format!("redis://127.0.0.1:{}/", self.port)
    }

    fn cut(&self) {
        self.cut.store(true, Ordering::SeqCst);
        for link in self.links.lock().unwrap().drain(..) {
            link.abort();
        }
    }
}

impl Drop for CutProxy {
    fn drop(&mut self) {
        self.accept.abort();
        self.cut();
    }
}

/// TEST_REDIS_URL as a socket address (it must carry no credentials).
fn valkey_addr() -> SocketAddr {
    let url = test_url();
    assert!(!url.contains('@'), "the two-relay tests need TEST_REDIS_URL without credentials");
    let hostport = url
        .trim_start_matches("redis://")
        .split(['/', '?'])
        .next()
        .unwrap_or("")
        .replacen("localhost", "127.0.0.1", 1);
    hostport.parse().expect("TEST_REDIS_URL must look like redis://127.0.0.1:56379/")
}

/// The durable stores both replicas share (Postgres in production).
#[derive(Clone)]
struct Shared {
    identity: Arc<dyn IdentityStore>,
    vault: Arc<dyn VaultStore>,
    knowledge: Arc<dyn KnowledgeStore>,
}

impl Shared {
    fn new() -> Self {
        Self {
            identity: Arc::new(InMemoryIdentityStore::new()),
            vault: Arc::new(InMemoryVaultStore::new()),
            knowledge: Arc::new(InMemoryKnowledgeStore::new()),
        }
    }
}

struct Replica {
    state: AppState,
    cluster: RedisCluster,
    /// ws://127.0.0.1:<port>/ws
    ws: String,
    #[allow(dead_code)] // used from Task 23 (Redis outage) and Task 25 (drain)
    proxy: CutProxy,
    server: JoinHandle<()>,
    /// The 60 s sweeps `main` runs (sessions, rooms, RTC, voice).
    upkeep: Vec<JoinHandle<()>>,
}

impl Replica {
    fn id(&self) -> &str {
        self.state.relay.replica_id()
    }

    fn stop_tasks(&self) {
        self.server.abort();
        self.cluster.abort();
        for task in &self.upkeep {
            task.abort();
        }
    }

    /// Crash: Redis goes first (so nothing is cleaned up), then every
    /// socket drops and the replica's tasks stop.
    #[allow(dead_code)] // used from Task 23 (Redis outage) and Task 25 (drain)
    fn crash(&self) {
        self.proxy.cut();
        self.stop_tasks();
        for connection_id in self.state.relay.local().connection_ids() {
            self.state.relay.local().evict(&connection_id);
        }
    }
}

impl Drop for Replica {
    fn drop(&mut self) {
        self.stop_tasks();
    }
}

/// One replica, started the way `main` starts it in Redis mode: keys
/// loaded, then `start_redis_replica`, then the upkeep sweeps, then the
/// production router on a socket.
async fn start_replica(shared: &Shared) -> Replica {
    let proxy = CutProxy::start(valkey_addr()).await;
    let keys = KeyCache::new();
    keys.load(shared.identity.as_ref()).await.expect("load keys");
    let cluster = crate::start_redis_replica(&proxy.url(), shared.identity.clone(), keys, TEST_AUTH_TIMEOUT)
        .await
        .expect("start replica");
    let upkeep = crate::spawn_upkeep(
        &cluster.relay,
        &cluster.sessions,
        &cluster.rtc_sessions,
        &cluster.voice_sessions,
    );
    let state = AppState {
        sessions: cluster.sessions.clone(),
        relay: cluster.relay.clone(),
        rtc_sessions: cluster.rtc_sessions.clone(),
        voice_sessions: cluster.voice_sessions.clone(),
        vault: shared.vault.clone(),
        knowledge: shared.knowledge.clone(),
        identity: shared.identity.clone(),
    };
    let (ws, server) = spawn_relay(state.clone()).await;
    Replica { state, cluster, ws, proxy, server, upkeep }
}

/// A fresh database and two replicas that know each other.
async fn two_replicas() -> (Shared, Replica, Replica) {
    flush().await;
    let shared = Shared::new();
    let one = start_replica(&shared).await;
    let two = start_replica(&shared).await;
    one.cluster.health.refresh().await.unwrap();
    (shared, one, two)
}

static NEXT_IP: AtomicU8 = AtomicU8::new(1);

/// One HTTP request through a replica's full router.
async fn http(
    state: &AppState,
    method: &str,
    uri: &str,
    body: &str,
    headers: &[(&str, &str)],
) -> (StatusCode, serde_json::Value) {
    let ip = format!("198.51.100.{}", NEXT_IP.fetch_add(1, Ordering::Relaxed));
    let mut request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-for", ip);
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = crate::router(state.clone())
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
}

async fn eventually(what: &str, check: impl Fn() -> bool) {
    for _ in 0..150 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting until {what}");
}

/// Wait for the socket to close, ignoring any frames before that.
async fn wait_closed(socket: &mut TestSocket) {
    let closed = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match socket.next().await {
                None | Some(Err(_)) | Some(Ok(ClientMessage::Close(_))) => return,
                Some(Ok(_)) => {}
            }
        }
    })
    .await;
    assert!(closed.is_ok(), "socket was not closed");
}

/// The close code the relay sent (0: closed without one).
#[allow(dead_code)] // used from Task 23 (Redis outage) and Task 25 (drain)
async fn expect_close_code(socket: &mut TestSocket) -> u16 {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match socket.next().await {
                Some(Ok(ClientMessage::Close(Some(frame)))) => return u16::from(frame.code),
                Some(Ok(ClientMessage::Close(None))) | None | Some(Err(_)) => return 0,
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .expect("no close within 5 s")
}

/// The HTTP status a refused WebSocket upgrade got.
#[allow(dead_code)] // used from Task 23 (Redis outage) and Task 25 (drain)
async fn refused_status(url: String) -> u16 {
    match tokio_tungstenite::connect_async(url).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => response.status().as_u16(),
        Err(other) => panic!("unexpected connect error: {other}"),
        Ok(_) => panic!("the WebSocket was accepted"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_two_replicas_share_rooms() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    assert_ne!(one.id(), two.id());
    let (status, created) = http(&one.state, "POST", "/api/pair", r#"{"hostname":"h"}"#, &[]).await;
    assert_eq!(status, StatusCode::CREATED);
    let code = created["code"].as_str().unwrap().to_string();
    let (status, room) = http(&two.state, "GET", &format!("/api/pair/{code}"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(room["hostname"], "h");
    for replica in [&one, &two] {
        let (status, health) = http(&replica.state, "GET", "/health", "", &[]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(health["redis"], "ok");
        assert_eq!(health["replicas"], 2);
    }
}

/// Astation on replica one, its Atem on replica two: frames cross the bus
/// both ways.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_two_replicas_carry_frames_across() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-harness";
    let key = TestKey::generate();
    let mut astation = verified_astation(&one.ws, code, &key, "registered").await;
    let mut atem = connect_atem(&two.ws, code, "atem-h").await;
    let connected = next_client_json(&mut astation).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-h");

    send_json(&mut astation, serde_json::json!({"probe": "to-atem"})).await;
    assert_eq!(next_client_json(&mut atem).await["probe"], "to-atem");

    send_json(&mut atem, serde_json::json!({"probe": "from-atem"})).await;
    let forwarded = next_client_json(&mut astation).await;
    assert_eq!(forwarded["atem_id"], "atem-h");
    assert_eq!(forwarded["payload"]["probe"], "from-atem");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_chat_crosses_replicas_both_ways_in_order() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-cross";
    let key = TestKey::generate();
    let mut astation = verified_astation(&one.ws, code, &key, "registered").await;
    let mut remote_atem = connect_atem(&two.ws, code, "atem-remote").await;
    let connected = next_client_json(&mut astation).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-remote");
    let remote_id = connected["connection_id"].as_str().unwrap().to_string();
    let mut local_atem = connect_atem(&one.ws, code, "atem-local").await;
    assert_eq!(next_client_json(&mut astation).await["atem_id"], "atem-local");

    // Atem (replica 2) → Astation (replica 1), order kept.
    for seq in 0..50 {
        send_json(&mut remote_atem, serde_json::json!({ "seq": seq })).await;
    }
    for seq in 0..50 {
        let frame = next_client_json(&mut astation).await;
        assert_eq!(frame["atem_id"], "atem-remote");
        assert_eq!(frame["connection_id"], remote_id.as_str());
        assert_eq!(frame["payload"]["seq"], seq);
    }

    // Astation → one Atem on the other replica, order kept.
    for seq in 0..50 {
        send_json(
            &mut astation,
            serde_json::json!({"atem_id": "atem-remote", "connection_id": remote_id, "payload": {"seq": seq}}),
        )
        .await;
    }
    for seq in 0..50 {
        assert_eq!(next_client_json(&mut remote_atem).await["seq"], seq);
    }
    assert_silent(&mut local_atem, 150).await;

    // Astation → all Atems (one local, one remote).
    send_json(&mut astation, serde_json::json!({"probe": "all"})).await;
    assert_eq!(next_client_json(&mut local_atem).await["probe"], "all");
    assert_eq!(next_client_json(&mut remote_atem).await["probe"], "all");

    // Disconnect notices cross replicas too.
    remote_atem.close(None).await.unwrap();
    let gone = next_client_json(&mut astation).await;
    assert_eq!(gone["relay_event"], "disconnected");
    assert_eq!(gone["connection_id"], remote_id.as_str());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_stale_connection_ids_are_dropped_across_replicas() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-stale";
    let (mut astation, _challenge) = connect_astation(&one.ws, code).await; // legacy owner
    let mut original = connect_atem(&two.ws, code, "atem-office").await;
    let original_id = next_client_json(&mut astation).await["connection_id"]
        .as_str()
        .unwrap()
        .to_string();
    let mut replacement = connect_atem(&one.ws, code, "atem-office").await;
    let replacement_id = next_client_json(&mut astation).await["connection_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_ne!(original_id, replacement_id);
    // The original (replica 2) is closed through the bus.
    wait_closed(&mut original).await;

    send_json(
        &mut astation,
        serde_json::json!({"atem_id": "atem-office", "connection_id": original_id, "payload": {"probe": "stale"}}),
    )
    .await;
    assert_silent(&mut replacement, 150).await;
    send_json(
        &mut astation,
        serde_json::json!({"atem_id": "atem-office", "connection_id": replacement_id, "payload": {"probe": "current"}}),
    )
    .await;
    assert_eq!(next_client_json(&mut replacement).await["probe"], "current");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_pending_on_one_replica_evicts_the_verified_owner_on_the_other() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-move";
    let key = TestKey::generate();
    let mut old = verified_astation(&two.ws, code, &key, "registered").await;
    let mut atem = connect_atem(&one.ws, code, "atem-a").await;
    assert_eq!(next_client_json(&mut old).await["relay_event"], "connected");
    eventually("replica 1 knows the key", || one.state.relay.keys().contains(code)).await;

    let (mut new, challenge) = connect_astation(&one.ws, code).await;
    // Pending: no ownership, no Atem traffic.
    send_json(&mut atem, serde_json::json!({"probe": "while-pending"})).await;
    assert_eq!(next_client_json(&mut old).await["payload"]["probe"], "while-pending");
    assert_silent(&mut new, 150).await;

    let result = authenticate(&mut new, &key, code, &challenge).await;
    assert_eq!(result["status"], "verified", "{result}");
    let connected = next_client_json(&mut new).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-a");
    assert_closed(&mut old).await;

    send_json(&mut atem, serde_json::json!({"probe": "to-new-owner"})).await;
    assert_eq!(next_client_json(&mut new).await["payload"]["probe"], "to-new-owner");
    let room = two.state.relay.room(code).await.unwrap().unwrap();
    assert_eq!(room.owner.map(|owner| owner.replica), Some(one.id().to_string()));
    assert!(room.verified);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_racing_astations_leave_exactly_one_owner() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-race";
    let key = TestKey::generate();
    let mut first_owner = verified_astation(&one.ws, code, &key, "registered").await;
    eventually("replica 2 knows the key", || two.state.relay.keys().contains(code)).await;

    let (mut on_one, challenge_one) = connect_astation(&one.ws, code).await;
    let (mut on_two, challenge_two) = connect_astation(&two.ws, code).await;
    let (result_one, result_two) = tokio::join!(
        authenticate(&mut on_one, &key, code, &challenge_one),
        authenticate(&mut on_two, &key, code, &challenge_two),
    );
    assert_eq!(result_one["status"], "verified");
    assert_eq!(result_two["status"], "verified");

    let owner = one.state.relay.room(code).await.unwrap().unwrap().owner.expect("an owner");
    let (winner, loser) = if owner.replica == one.id() {
        (&mut on_one, &mut on_two)
    } else {
        (&mut on_two, &mut on_one)
    };
    wait_closed(loser).await;
    wait_closed(&mut first_owner).await;

    // The winner owns the room: an Atem on either replica reaches it.
    let mut atem = connect_atem(&two.ws, code, "atem-after-race").await;
    assert_eq!(next_client_json(winner).await["relay_event"], "connected");
    send_json(&mut atem, serde_json::json!({"probe": "winner"})).await;
    assert_eq!(next_client_json(winner).await["payload"]["probe"], "winner");
}
