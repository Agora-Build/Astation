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
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
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
/// `restore()` lets new connections through again.
struct CutProxy {
    port: u16,
    cut: Arc<AtomicBool>,
    /// Connections dropped because the proxy was cut.
    refused: Arc<AtomicUsize>,
    links: Arc<Mutex<Vec<JoinHandle<()>>>>,
    accept: JoinHandle<()>,
}

impl CutProxy {
    async fn start(target: SocketAddr) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let cut = Arc::new(AtomicBool::new(false));
        let refused = Arc::new(AtomicUsize::new(0));
        let links: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
        let accept = tokio::spawn({
            let (cut, refused, links) = (cut.clone(), refused.clone(), links.clone());
            async move {
                while let Ok((mut inbound, _)) = listener.accept().await {
                    if cut.load(Ordering::SeqCst) {
                        refused.fetch_add(1, Ordering::SeqCst);
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
        Self { port, cut, refused, links, accept }
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

    /// How many connections were dropped while cut.
    fn refused(&self) -> usize {
        self.refused.load(Ordering::SeqCst)
    }

    /// Redis is back: new connections pass again (cut links stay cut).
    fn restore(&self) {
        self.cut.store(false, Ordering::SeqCst);
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
    proxy: CutProxy,
    server: JoinHandle<()>,
    /// The 60 s sweeps `main` runs (sessions, rooms, RTC, voice).
    upkeep: Vec<(&'static str, JoinHandle<()>)>,
}

impl Replica {
    fn id(&self) -> &str {
        self.state.relay.replica_id()
    }

    fn stop_tasks(&self) {
        self.server.abort();
        self.cluster.abort();
        for (_, task) in &self.upkeep {
            task.abort();
        }
    }

    /// Crash: Redis goes first (so nothing is cleaned up), then every
    /// socket drops and the replica's tasks stop.
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_pairing_session_create_grant_poll_and_websocket_across_replicas() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let (status, created) = http(&one.state, "POST", "/api/sessions", r#"{"hostname":"mac"}"#, &[]).await;
    assert_eq!(status, StatusCode::CREATED);
    let id = created["id"].as_str().unwrap().to_string();
    let otp = created["otp"].as_str().unwrap().to_string();
    let grant_uri = format!("/api/sessions/{id}/grant");
    let grant_body = serde_json::json!({ "otp": otp }).to_string();

    // Two clicks on different replicas: exactly one applies.
    let (on_two, on_one) = tokio::join!(
        http(&two.state, "POST", &grant_uri, &grant_body, &[]),
        http(&one.state, "POST", &grant_uri, &grant_body, &[]),
    );
    let mut statuses = vec![on_two.0, on_one.0];
    statuses.sort();
    assert_eq!(statuses, vec![StatusCode::OK, StatusCode::CONFLICT]);

    let (status, polled) = http(&one.state, "GET", &format!("/api/sessions/{id}/status"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(polled["status"], "granted");
    assert_eq!(polled["token"].as_str().map(str::len), Some(64));

    let (_atem, _) = tokio_tungstenite::connect_async(format!("{}?session={id}&atem_id=atem-s", two.ws))
        .await
        .expect("session WebSocket on replica 2");
    let code = format!("session-{id}");
    let mut seen = false;
    for _ in 0..100 {
        if let Some(room) = one.state.relay.room(&code).await.unwrap() {
            if room.atems.contains_key("atem-s") {
                seen = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(seen, "replica 1 sees the Atem that connected to replica 2");
}

async fn voice_session(replica: &Replica) -> String {
    let (status, created) = http(
        &replica.state,
        "POST",
        "/api/voice-sessions",
        r#"{"atem_id":"atem-v","channel":"ch"}"#,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    created["session_id"].as_str().unwrap().to_string()
}

async fn llm_chat(state: &AppState, id: &str) -> (StatusCode, serde_json::Value) {
    http(
        state,
        "POST",
        &format!("/api/llm/chat?session_id={id}"),
        r#"{"messages":[{"role":"user","content":"go"}]}"#,
        &[],
    )
    .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_voice_wait_on_one_replica_is_answered_on_the_other() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;

    // Waiting on 1, answered on 2.
    let id = voice_session(&one).await;
    let (status, _) = http(&one.state, "POST", &format!("/api/voice-sessions/{id}/trigger"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    let waiting = tokio::spawn({
        let state = one.state.clone();
        let id = id.clone();
        async move { llm_chat(&state, &id).await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let answer = serde_json::json!({"session_id": id, "response": "done on two"}).to_string();
    let answered = std::time::Instant::now();
    let (status, _) = http(&two.state, "POST", "/api/voice-sessions/response", &answer, &[]).await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = waiting.await.unwrap();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["choices"][0]["message"]["content"], "done on two");
    // Woken by replica 2's publish, not by the 1 s re-read of :reply (which
    // would land at least 700 ms after the answer).
    assert!(answered.elapsed() < Duration::from_millis(500), "woken after {:?}", answered.elapsed());

    // The answer arrives before anyone waits.
    let early = voice_session(&one).await;
    let (status, _) = http(&one.state, "POST", &format!("/api/voice-sessions/{early}/trigger"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    let answer = serde_json::json!({"session_id": early, "response": "early"}).to_string();
    let (status, _) = http(&two.state, "POST", "/api/voice-sessions/response", &answer, &[]).await;
    assert_eq!(status, StatusCode::OK);
    // Let replica 2's publish reach replica 1 and find no waiter there, so
    // only the stored answer can satisfy the wait below.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let started = std::time::Instant::now();
    assert_eq!(
        one.state.voice_sessions.wait_reply(&early, Duration::from_secs(5)).await.unwrap(),
        crate::voice_session::WaitOutcome::Reply("early".to_string())
    );
    // Found by the read before waiting, not by the 1 s re-read.
    assert!(started.elapsed() < Duration::from_millis(500), "found after {:?}", started.elapsed());
    let (status, body) = llm_chat(&one.state, &early).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["choices"][0]["message"]["content"], "early");

    // Nobody answers: the wait times out (the handler's 30 s is the same
    // wait with LLM_WAIT_SECS; see llm_proxy::test_triggered_times_out_with_504).
    let silent = voice_session(&one).await;
    let (status, _) = http(&one.state, "POST", &format!("/api/voice-sessions/{silent}/trigger"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    let started = std::time::Instant::now();
    let outcome = tokio::time::timeout(
        Duration::from_secs(5),
        one.state.voice_sessions.wait_reply(&silent, Duration::from_secs(1)),
    )
    .await
    .expect("the wait ends at its deadline");
    assert_eq!(outcome.unwrap(), crate::voice_session::WaitOutcome::TimedOut);
    assert!(started.elapsed() >= Duration::from_millis(950), "gave up after {:?}", started.elapsed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_concurrent_rtc_joins_across_replicas_hold_the_cap() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let (status, created) = http(
        &one.state,
        "POST",
        "/api/rtc-sessions",
        r#"{"app_id":"app","channel":"ch","token":"tok","host_uid":1}"#,
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = created["id"].as_str().unwrap().to_string();
    let joins: Vec<_> = (0..20)
        .map(|i| {
            let state = if i % 2 == 0 { one.state.clone() } else { two.state.clone() };
            let id = id.clone();
            tokio::spawn(async move { state.rtc_sessions.join(&id, format!("user-{i}")).await })
        })
        .collect();
    let mut uids = Vec::new();
    let mut full = 0;
    for join in joins {
        match join.await.unwrap() {
            Ok(response) => uids.push(response.uid),
            Err(error) => {
                assert!(error.contains("full"), "{error}");
                full += 1;
            }
        }
    }
    uids.sort();
    assert_eq!(uids, (1000..1008).collect::<Vec<u32>>());
    assert_eq!(full, 12);
    let (status, _) = http(&two.state, "GET", &format!("/api/rtc-sessions/{id}"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    let stored = two.state.rtc_sessions.get(&id).await.unwrap().expect("session on replica 2");
    let mut stored_uids: Vec<u32> = stored.participants.iter().map(|p| p.uid).collect();
    stored_uids.sort();
    assert_eq!(stored_uids, uids, "replica 2 sees exactly the uids handed out");
}

#[tokio::test]
async fn cut_proxy_refuses_while_cut_and_passes_again_after_restore() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    // An echo server stands in for Valkey.
    let echo = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = echo.local_addr().unwrap();
    let server = tokio::spawn(async move {
        while let Ok((mut socket, _)) = echo.accept().await {
            tokio::spawn(async move {
                let (mut read, mut write) = socket.split();
                let _ = tokio::io::copy(&mut read, &mut write).await;
            });
        }
    });
    let proxy = CutProxy::start(target).await;
    // Ok(true): echoed; Ok(false): the proxy closed the connection.
    let round_trip = |port: u16| async move {
        let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        if socket.write_all(b"ping").await.is_err() {
            return false;
        }
        let mut buf = [0u8; 4];
        let read = tokio::time::timeout(Duration::from_secs(5), socket.read_exact(&mut buf))
            .await
            .expect("no answer and no close within 5 s");
        read.is_ok() && &buf == b"ping"
    };
    assert!(round_trip(proxy.port).await, "passes before the cut");
    let mut held = tokio::net::TcpStream::connect(("127.0.0.1", proxy.port)).await.unwrap();
    held.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    held.read_exact(&mut buf).await.unwrap();

    assert_eq!(proxy.refused(), 0);
    proxy.cut();
    assert!(!round_trip(proxy.port).await, "refused while cut");
    assert_eq!(proxy.refused(), 1);
    let mut rest = Vec::new();
    let dropped = tokio::time::timeout(Duration::from_secs(5), held.read_to_end(&mut rest)).await;
    assert!(dropped.is_ok(), "the open link is dropped by the cut");

    proxy.restore();
    assert!(round_trip(proxy.port).await, "passes again after restore");
    proxy.cut();
    assert_eq!(proxy.refused(), 1, "passing connections are not counted");
    assert!(!round_trip(proxy.port).await, "can be cut again");
    assert_eq!(proxy.refused(), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_a_crashed_replica_is_recovered_by_reconnecting_clients() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-crash";
    let key = TestKey::generate();
    let mut astation = verified_astation(&one.ws, code, &key, "registered").await;
    let mut atem = connect_atem(&two.ws, code, "atem-a").await;
    assert_eq!(next_client_json(&mut astation).await["relay_event"], "connected");
    eventually("replica 2 knows the key", || two.state.relay.keys().contains(code)).await;

    one.crash();
    wait_closed(&mut astation).await;

    // The Astation reconnects to the healthy replica; its promotion
    // replaces the owner entry the dead replica left behind.
    let mut astation = verified_astation(&two.ws, code, &key, "verified").await;
    let connected = next_client_json(&mut astation).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-a");
    send_json(&mut atem, serde_json::json!({"probe": "after-crash"})).await;
    assert_eq!(next_client_json(&mut astation).await["payload"]["probe"], "after-crash");
    send_json(&mut astation, serde_json::json!({"probe": "to-atem"})).await;
    assert_eq!(next_client_json(&mut atem).await["probe"], "to-atem");

    let (status, pair) = http(&two.state, "GET", &format!("/api/pair/{code}"), "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(pair["astation_connected"], true);
    assert_eq!(pair["paired"], true);
}

/// The next frame that is not a relay_event.
async fn next_frame(socket: &mut TestSocket) -> serde_json::Value {
    loop {
        let frame = next_client_json(socket).await;
        if frame.get("relay_event").is_none() {
            return frame;
        }
    }
}

/// An Atem on the crashed replica reconnects to the healthy one with the
/// same atem_id: its new connection replaces the entry the dead replica
/// left behind, and only the new connection is routed to.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_an_atem_from_a_crashed_replica_reconnects_and_replaces_its_entry() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-crash-atem";
    let key = TestKey::generate();
    let mut astation = verified_astation(&two.ws, code, &key, "registered").await;
    let mut atem = connect_atem(&one.ws, code, "atem-a").await;
    let connected = next_client_json(&mut astation).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-a");
    let old_id = connected["connection_id"].as_str().unwrap().to_string();

    one.crash();
    wait_closed(&mut atem).await;

    let mut atem = connect_atem(&two.ws, code, "atem-a").await;
    let new_id = loop {
        let event = next_client_json(&mut astation).await;
        if event["relay_event"] == "connected" {
            assert_eq!(event["atem_id"], "atem-a");
            let id = event["connection_id"].as_str().unwrap().to_string();
            assert_ne!(id, old_id, "a connected event for the dead connection");
            break id;
        }
    };

    send_json(&mut atem, serde_json::json!({"probe": "after-crash"})).await;
    let frame = next_frame(&mut astation).await;
    assert_eq!(frame["atem_id"], "atem-a");
    assert_eq!(frame["connection_id"], new_id.as_str());
    assert_eq!(frame["payload"]["probe"], "after-crash");

    // The dead connection's id is not routed to; the new one is.
    send_json(
        &mut astation,
        serde_json::json!({"atem_id": "atem-a", "connection_id": old_id, "payload": {"probe": "stale"}}),
    )
    .await;
    assert_silent(&mut atem, 150).await;
    send_json(
        &mut astation,
        serde_json::json!({"atem_id": "atem-a", "connection_id": new_id, "payload": {"probe": "to-atem"}}),
    )
    .await;
    assert_eq!(next_client_json(&mut atem).await["probe"], "to-atem");

    let room = two.state.relay.room(code).await.unwrap().expect("room");
    let entry = room.atems.get("atem-a").expect("atem-a's entry");
    assert_eq!(entry.conn, new_id, "the entry names the new connection");
    assert_eq!(entry.replica, two.id());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_down_means_503s_but_vault_and_memory_keep_working() {
    let _guard = REDIS_LOCK.lock().await;
    let (shared, one, two) = two_replicas().await;
    let now = chrono::Utc::now().timestamp();
    shared.identity.bind("sess-down", "astation-down", now).await.unwrap();

    one.proxy.cut();

    for (method, uri, body, error) in [
        ("POST", "/api/pair", r#"{"hostname":"h"}"#, serde_json::json!({"error": "relay state unavailable"})),
        ("POST", "/api/sessions", r#"{"hostname":"h"}"#, serde_json::json!({"error": "Temporarily unavailable"})),
        (
            "POST",
            "/api/rtc-sessions",
            r#"{"app_id":"a","channel":"c","token":"t","host_uid":1}"#,
            serde_json::json!({"error": "Temporarily unavailable"}),
        ),
        // The voice routes answer with a bare status, no body.
        ("POST", "/api/voice-sessions", r#"{"atem_id":"a","channel":"c"}"#, serde_json::Value::Null),
    ] {
        let (status, response) = http(&one.state, method, uri, body, &[]).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{method} {uri}");
        assert_eq!(response, error, "{method} {uri}");
    }
    let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(health["redis"], "unavailable");
    assert_eq!(
        refused_status(format!("{}?role=astation&code=astation-down", one.ws)).await,
        503
    );

    // Vault and Atem Memory only need Postgres.
    let auth = [("authorization", "session sess-down")];
    let (status, _) = http(&one.state, "POST", "/api/vault?id=atem-a", r#"{"summary":"x"}"#, &auth).await;
    assert_eq!(status, StatusCode::OK);
    let memory = serde_json::json!({
        "id": "mem-down",
        "scope": "global",
        "project": "",
        "machine": "",
        "content": "written while Redis was down",
        "content_hash": "h:down",
        "confidence": "high",
        "source_agent": "claude",
        "source_machine": "m1",
        "created_at": 1_700_000_000,
        "deleted": false,
        "seq": 0,
    });
    let batch = serde_json::json!({"ops": [{"op": "add", "memory": memory}]}).to_string();
    let (status, added) = http(&one.state, "POST", "/api/memory/batch?id=atem-a", &batch, &auth).await;
    assert_eq!(status, StatusCode::OK, "{added}");
    assert_eq!(added["results"][0]["ok"], true, "{added}");
    let (status, pulled) = http(&one.state, "GET", "/api/memory?id=atem-a", "", &auth).await;
    assert_eq!(status, StatusCode::OK);
    let memories = pulled["memories"].as_array().unwrap();
    assert_eq!(memories.len(), 1, "{pulled}");
    assert_eq!(memories[0]["id"], "mem-down");
    assert_eq!(memories[0]["content"], "written while Redis was down");

    // The other replica is unaffected.
    let (status, health) = http(&two.state, "GET", "/health", "", &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(health["redis"], "ok");
}

/// Poll an async check every 100 ms for up to 10 s.
async fn eventually_async<F, Fut>(what: &str, check: F)
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    for _ in 0..100 {
        if check().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("timed out waiting until {what}");
}

/// Subscribers on a replica's bus inbox, asked of Valkey directly.
async fn inbox_subscribers(replica: &Replica) -> i64 {
    let conn = crate::cluster::redis::RedisConn::connect(&crate::cluster::redis::test_support::test_url())
        .await
        .expect("connect TEST_REDIS_URL");
    let channel = crate::cluster::redis::keys::inbox_channel(replica.id());
    let counts: Vec<(String, i64)> = conn
        .run(|mut c| async move { redis::cmd("PUBSUB").arg("NUMSUB").arg(channel).query_async(&mut c).await })
        .await
        .unwrap();
    counts.first().map(|(_, count)| *count).unwrap_or(0)
}

/// An outage that starts after a WebSocket was upgraded closes it with 1013
/// (try again later); when Redis returns, the replica serves again and
/// rooms rebuild as clients reconnect, with nothing durable lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_outage_closes_with_1013_and_the_replica_recovers_when_redis_returns() {
    let _guard = REDIS_LOCK.lock().await;
    let (shared, one, two) = two_replicas().await;
    let code = "astation-outage";
    let key = TestKey::generate();
    let now = chrono::Utc::now().timestamp();
    shared.identity.bind("sess-outage", code, now).await.unwrap();
    let auth = [("authorization", "session sess-outage")];
    let (status, created) =
        http(&one.state, "POST", "/api/vault?id=atem-a", r#"{"summary":"before"}"#, &auth).await;
    assert_eq!(status, StatusCode::OK);
    let vault_id = created["vault_id"].as_str().unwrap().to_string();
    let mut owner = verified_astation(&one.ws, code, &key, "registered").await;

    // Upgraded before the outage, proving its key during it: the promotion
    // needs Redis, so the relay closes the socket with 1013.
    let (mut late, challenge) = connect_astation(&one.ws, code).await;
    // The challenge is queued before the pending entry is written, so wait
    // for that entry: otherwise the cut can land on the registration (also
    // a 1013, but before the key proof this step is about).
    eventually_async("the late Astation is pending", || async {
        let room = one.state.relay.room(code).await.unwrap().unwrap();
        room.pending.len() == 1
    })
    .await;
    one.proxy.cut();
    let result = authenticate(&mut late, &key, code, &challenge).await;
    assert_eq!(result["status"], "verified", "{result}");
    assert_eq!(expect_close_code(&mut late).await, 1013);
    assert_eq!(refused_status(format!("{}?role=atem&code={code}&atem_id=atem-a", one.ws)).await, 503);

    // Keep Redis away until replica one's bus has lost its subscription
    // and failed to resubscribe a few times (backoff 0.1 s, 0.2 s, 0.4 s):
    // four more refused connections, a margin for the heartbeat's reconnects.
    eventually_async("replica one's bus lost Redis", || async { inbox_subscribers(&one).await == 0 }).await;
    let base = one.proxy.refused();
    eventually_async("replica one retried Redis", || async { one.proxy.refused() >= base + 4 }).await;

    one.proxy.restore();
    eventually_async("/health recovers", || async {
        let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
        status == StatusCode::OK && health["redis"] == "ok"
    })
    .await;
    let (status, _) = http(&one.state, "POST", "/api/pair", r#"{"hostname":"h"}"#, &[]).await;
    assert_eq!(status, StatusCode::CREATED);
    // Frames to replica one need its bus back (the subscriber retries with backoff).
    eventually_async("replica one's bus resubscribes", || async { inbox_subscribers(&one).await == 1 }).await;

    // The room rebuilds: the key survived (verified, not registered again),
    // the new promotion evicts the owner from before the outage, and an
    // Atem on the other replica reaches the new owner both ways.
    let mut astation = verified_astation(&one.ws, code, &key, "verified").await;
    wait_closed(&mut owner).await;
    let mut atem = connect_atem(&two.ws, code, "atem-a").await;
    let connected = next_client_json(&mut astation).await;
    assert_eq!(connected["relay_event"], "connected");
    assert_eq!(connected["atem_id"], "atem-a");
    send_json(&mut atem, serde_json::json!({"probe": "after-outage"})).await;
    assert_eq!(next_client_json(&mut astation).await["payload"]["probe"], "after-outage");
    send_json(&mut astation, serde_json::json!({"probe": "to-atem"})).await;
    assert_eq!(next_client_json(&mut atem).await["probe"], "to-atem");

    // Nothing durable was lost.
    let (status, vaults) = http(&one.state, "GET", "/api/vault?id=atem-a", "", &auth).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        vaults.as_array().unwrap().iter().any(|v| v["vault_id"] == vault_id.as_str()),
        "{vaults}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_drain_closes_with_1012_and_removes_entries_and_presence() {
    let _guard = REDIS_LOCK.lock().await;
    let (_shared, one, two) = two_replicas().await;
    let code = "astation-drain";
    let (mut astation, _challenge) = connect_astation(&two.ws, code).await;
    let mut atem = connect_atem(&one.ws, code, "atem-a").await;
    let atem_id = next_client_json(&mut astation).await["connection_id"]
        .as_str()
        .unwrap()
        .to_string();

    one.state.relay.drain(Duration::from_secs(5)).await;

    assert_eq!(expect_close_code(&mut atem).await, 1012);
    let gone = next_client_json(&mut astation).await;
    assert_eq!(gone["relay_event"], "disconnected");
    assert_eq!(gone["connection_id"], atem_id.as_str());
    assert!(two.state.relay.room(code).await.unwrap().unwrap().atems.is_empty());
    assert_eq!(two.cluster.health.refresh().await.unwrap(), 1, "presence withdrawn");

    let (status, health) = http(&one.state, "GET", "/health", "", &[]).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(health["status"], "draining");
    assert_eq!(refused_status(format!("{}?role=astation&code=x", one.ws)).await, 503);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn redis_forget_key_and_registration_reach_both_replicas() {
    let _guard = REDIS_LOCK.lock().await;
    let (shared, one, two) = two_replicas().await;
    let code = "astation-forget";
    let old_key = TestKey::generate();
    let owner = verified_astation(&one.ws, code, &old_key, "registered").await;
    eventually("both replicas know the key", || {
        one.state.relay.keys().contains(code) && two.state.relay.keys().contains(code)
    })
    .await;

    let admin_conn = crate::cluster::redis::RedisConn::connect(&test_url()).await.unwrap();
    let publisher = crate::cluster::redis::bus::RedisBus::publisher(admin_conn, "admin");
    let outcome = crate::admin::forget_key(shared.identity.as_ref(), Some(&publisher), code)
        .await
        .unwrap();
    assert_eq!(outcome, crate::admin::ForgetOutcome { deleted: true, announced: true });
    eventually("both replicas dropped the key", || {
        !one.state.relay.keys().contains(code) && !two.state.relay.keys().contains(code)
    })
    .await;
    let mut owner = owner;
    wait_closed(&mut owner).await;

    // A new key registers on replica 2 and reaches replica 1.
    let new_key = TestKey::generate();
    let _new_owner = verified_astation(&two.ws, code, &new_key, "registered").await;
    let expected = new_key.public_hex();
    eventually("replica 1 learned the new key", || {
        one.state.relay.keys().get(code).map(|cached| cached.public_key) == Some(expected.clone())
    })
    .await;

    // The old key is refused on replica 1 at once, without a restart.
    let (mut old, challenge) = connect_astation(&one.ws, code).await;
    let result = authenticate(&mut old, &old_key, code, &challenge).await;
    assert_eq!(result["status"], "rejected", "{result}");
}
