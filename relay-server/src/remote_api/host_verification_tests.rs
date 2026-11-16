use super::*;
use crate::{
    cluster::{
        bus::{BroadcastMessage, BusEvent, InboxMessage, ReplicaBus},
        directory::InMemoryRoomDirectory,
        StoreError,
    },
    relay::{
        tests::{assert_closed, assert_silent, verified_astation, TestKey},
        HubParts, RelayHub,
    },
};
use atem_client::{
    membership::{Entry, HostNow},
    KeyProvider, SignedObject,
};
use std::{collections::HashMap, sync::Mutex};
use tokio::{sync::mpsc, task::JoinHandle};

// Exercise the production dispatcher, including serialized cross-replica messages.
#[derive(Default)]
struct TestBus(Mutex<HashMap<String, mpsc::UnboundedSender<BusEvent>>>);

#[async_trait::async_trait]
impl ReplicaBus for TestBus {
    fn backend_name(&self) -> &'static str {
        "test"
    }
    async fn send_inbox(&self, replica: &str, message: InboxMessage) -> Result<(), StoreError> {
        let message = serde_json::from_str(&serde_json::to_string(&message).unwrap()).unwrap();
        self.0.lock().unwrap()[replica]
            .send(BusEvent::Inbox(message))
            .unwrap();
        Ok(())
    }
    async fn broadcast(&self, message: BroadcastMessage) -> Result<(), StoreError> {
        for inbox in self.0.lock().unwrap().values() {
            inbox.send(BusEvent::Broadcast(message.clone())).unwrap();
        }
        Ok(())
    }
}

struct Harness {
    fixture: Fixture,
    owner_state: crate::AppState,
    host_state: crate::AppState,
    owner_base: String,
    host_base: String,
    key: TestKey,
    owner: TestSocket,
    host: TestSocket,
    binding: HostBinding,
    bus: Arc<TestBus>,
    tasks: Vec<JoinHandle<()>>,
}

impl Drop for Harness {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl Harness {
    async fn new(cross_replica: bool) -> Self {
        Self::new_with_delegated(cross_replica, false).await
    }

    async fn new_with_delegated(cross_replica: bool, delegated: bool) -> Self {
        let fixture = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        let base = state(RecoveryStore::memory());
        if delegated {
            base.recovery
                .configure_delegated("https://station-dev.agora.build", 1).await
                .unwrap();
        }
        fixture.publish(&base.recovery).await;
        let bus = Arc::new(TestBus::default());
        let directory = InMemoryRoomDirectory::new();
        let mut states = Vec::new();
        let mut tasks = Vec::new();
        for id in ["owner", "host"] {
            let (tx, rx) = mpsc::unbounded_channel();
            bus.0.lock().unwrap().insert(id.into(), tx);
            let mut state = base.clone();
            state.relay = RelayHub::from_parts(HubParts {
                replica_id: id.into(),
                bus: bus.clone(),
                ..HubParts::single_instance(directory.clone(), Duration::from_secs(2))
            });
            state.relay.configure_recovery(base.recovery.clone());
            tasks.push(state.relay.spawn_bus_dispatcher(
                state.identity.clone(),
                Default::default(),
                rx,
            ));
            states.push(state);
        }
        let owner_state = states.remove(0);
        let host_state = if cross_replica {
            states.remove(0)
        } else {
            owner_state.clone()
        };
        Self::connect(fixture, owner_state, host_state, tasks, bus).await
    }

    async fn connect(
        fixture: Fixture,
        owner_state: crate::AppState,
        host_state: crate::AppState,
        mut tasks: Vec<JoinHandle<()>>,
        bus: Arc<TestBus>,
    ) -> Self {
        let (owner_base, server) = spawn_relay(owner_state.clone()).await;
        tasks.push(server);
        let (host_base, server) = spawn_relay(host_state.clone()).await;
        tasks.push(server);
        let key = TestKey::generate();
        let mut owner = verified_astation(&owner_base, "phone", &key, "registered").await;
        let mut host = connect_atem(&host_base, "phone", "host-a").await;
        prove(
            &mut host,
            &fixture.keys,
            &fixture.host_key,
            &fixture.log,
            "host-a",
        )
        .await;
        if host_state.recovery.delegated_enabled() {
            assert_eq!(next_client_json(&mut host).await["op"], "heads");
        }
        // Carrier A registration and proved admission each publish presence.
        loop {
            let event = next_client_json(&mut owner).await;
            if event["atem_id"] == "host-a" {
                break;
            }
        }
        let (_, _, Some(binding), _) = super::super::recovery::host_target(
            &host_state,
            &fixture.log.genesis_hash().to_hex(),
            "alice",
            "host-a",
        )
        .await
        .unwrap() else {
            panic!("host must have a proved binding");
        };
        Self {
            fixture,
            owner_state,
            host_state,
            owner_base,
            host_base,
            key,
            owner,
            host,
            binding,
            bus,
            tasks,
        }
    }

    async fn start(&mut self) {
        let commit = json!({"type":"verifyCommit","data":{"device_id":"host-a",
            "commitment":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=","host_trust_gen":2}});
        send_json(&mut self.host, commit.clone()).await;
        loop {
            let frame = next_client_json(&mut self.owner).await;
            if frame["payload"]["type"] == "verifyCommit" {
                assert_eq!(frame["payload"], commit);
                break;
            }
        }
        self.send_owner(json!({"type":"verifyKeys","data":{"nonce":"opaque"}}))
            .await;
        assert_eq!(next_client_json(&mut self.host).await["type"], "verifyKeys");
        send_json(
            &mut self.host,
            json!({"type":"verifyReveal","data":{"host_channel_pub":"opaque"}}),
        )
        .await;
        assert_eq!(
            next_client_json(&mut self.owner).await["payload"]["type"],
            "verifyReveal"
        );
    }

    async fn send_owner(&mut self, payload: Value) {
        send_json(
            &mut self.owner,
            json!({"atem_id":"host-a",
            "connection_id":self.binding.connection.conn,"payload":payload}),
        )
        .await;
    }

    async fn publish_rekey(&self) -> (SoftwareKeys, KeyId, Membership) {
        let mut keys = SoftwareKeys::new();
        let key = KeyId::new("new-host-key");
        keys.insert_ed25519(key.clone(), &[12; 32]);
        let f = &self.fixture;
        let entry = Entry::parse_bytes(SignedObject::sign(&f.keys, &KeyId::new("manager"), json!({
            "type":"atem-membership-entry","v":1,"action":"add_host","account_id":f.log.account_id(),
            "genesis_hash":f.log.genesis_hash().to_hex(),"seq":3,"prev_hash":f.log.head().hash.to_hex(),
            "signed_at":f.created,"signer":"phone","host":{"host_id":"host-a","host_trust_gen":2,
            "host_key":keys.public_key(&key).unwrap().to_json()}
        })).unwrap().to_json().to_string().as_bytes()).unwrap();
        let mut entries = f.log.entries().to_vec();
        entries.push(entry.clone());
        let log = Membership::verify_chain(
            f.log.account_id(),
            &f.log.genesis_hash(),
            &entries,
            &HostNow {
                wall_ms: f.created,
                mono_ms: 0,
                boot_id: "test".into(),
            },
        )
        .unwrap()
        .membership;
        let reply = self
            .host_state
            .recovery
            .perform(
                &f.log.genesis_hash().to_hex(),
                "alice",
                Operation::Append {
                    entry,
                    expected: f.log.head().clone(),
                },
            )
            .await;
        assert_eq!(reply.0, StatusCode::OK, "{reply:?}");
        (keys, key, log)
    }
}

async fn completion_after_rekey(h: &mut Harness) {
    h.start().await;
    let (keys, key, log) = h.publish_rekey().await;
    assert!(h
        .host_state
        .recovery
        .with_host_route(&h.binding, || async { () })
        .await
        .is_none());
    h.host_state.relay.cleanup_expired().await;
    let owner_route = super::super::recovery::OwnerRoute {
        genesis: h.binding.genesis.clone(),
        host: h.binding.host.clone(),
        room: h.binding.room.clone(),
        connection: h.binding.connection.clone(),
        host_trust_gen: 2,
    };
    assert!(
        !h.owner_state
            .relay
            .deliver_scoped_channel(
                &h.binding.connection,
                json!({"type":"channel","event":"open","channel":"stale-api","transport":"relay"})
                    .to_string(),
                Some(owner_route)
            )
            .await
    );
    // All ordinary stale traffic remains fenced, without cutting the completion path.
    send_json(&mut h.host, json!({"type":"auth_request","nonce":"stale"})).await;
    send_json(
        &mut h.host,
        json!({"type":"channel","event":"open","channel":"stale","transport":"relay"}),
    )
    .await;
    if h.host_state.recovery.delegated_enabled() {
        send_json(&mut h.host, json!({"type":"relay","op":"control_sync",
            "request_id":uuid::Uuid::new_v4().to_string(),
            "origin":"https://station-dev.agora.build", "after":0})).await;
        send_json(&mut h.host, json!({"type":"relay","op":"membership_fetch","after":0})).await;
    }
    h.send_owner(json!({"type":"auth_required","nonce":"stale"}))
        .await;
    h.host_state
        .relay
        .deliver(
            &h.binding.connection,
            json!({"type":"deviceVerified","data":{}}).to_string(),
        )
        .await;
    assert_silent(&mut h.host, 100).await;
    assert_silent(&mut h.owner, 100).await;
    let completion = json!({"type":"deviceVerified","data":{"membership":{"entries":
        log.entries().iter().map(|e| e.object().to_json()).collect::<Vec<_>>()},"device_verified":{"opaque":"signed"}}});
    h.send_owner(completion.clone()).await;
    assert_eq!(next_client_json(&mut h.host).await, completion);
    assert_closed(&mut h.host).await;

    let mut reconnect = connect_atem(&h.host_base, "phone", "host-a").await;
    let challenge = HostChallenge::parse(
        next_client_json(&mut reconnect)
            .await
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    let old_proof = proof(
        &h.fixture.keys,
        &h.fixture.host_key,
        &h.fixture.log,
        &challenge,
        "host-a",
    );
    let super::super::recovery::HostRouteError::Refused(refused) = h
        .host_state
        .recovery
        .admit_host(
            &old_proof.to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            h.binding.connection.clone(),
        )
        .await
        .unwrap_err()
    else {
        panic!("old key must be refused");
    };
    assert_eq!(refused["code"], "bad_signature");
    send_json(
        &mut reconnect,
        proof(&keys, &key, &log, &challenge, "host-a"),
    )
    .await;
    assert_eq!(
        next_client_json(&mut reconnect).await["op"],
        "host_route_ok"
    );
    if h.host_state.recovery.delegated_enabled() {
        let heads = next_client_json(&mut reconnect).await;
        assert_eq!(heads["op"], "heads");
        assert_eq!(heads["membership"], log.head().to_json());
    }
    // The completion is bound to the original connection, never replayed.
    h.send_owner(completion).await;
    assert_silent(&mut reconnect, 100).await;
}

#[tokio::test]
async fn proved_reverification_completion_survives_rekey_and_cleanup() {
    completion_after_rekey(&mut Harness::new(false).await).await;
}

#[tokio::test]
async fn proved_reverification_completion_crosses_replicas_after_rekey() {
    completion_after_rekey(&mut Harness::new(true).await).await;
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
async fn delegated_calls_do_not_cut_reverification_completion_after_rekey() {
    completion_after_rekey(&mut Harness::new_with_delegated(false, true).await).await;
    completion_after_rekey(&mut Harness::new_with_delegated(true, true).await).await;
}

#[tokio::test]
#[ignore = "requires isolated local Redis and Postgres"]
async fn postgres_proved_reverification_completion_crosses_real_replicas() {
    postgres_completion(false).await;
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
#[ignore = "requires isolated local Redis and Postgres"]
async fn postgres_delegated_calls_preserve_verification_across_real_replicas() {
    postgres_completion(true).await;
}

async fn postgres_completion(delegated: bool) {
    use crate::cluster::{
        keys::KeyCache,
        redis::{test_support, RedisCluster},
    };
    let _lock = test_support::REDIS_LOCK.lock().await;
    test_support::flush().await;
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let second_pool = db.reconnect(4).await;
    let base = state(RecoveryStore::postgres(db.pool.clone()));
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&base.recovery).await;
    struct Clusters(Vec<RedisCluster>);
    impl Drop for Clusters {
        fn drop(&mut self) {
            for cluster in &self.0 {
                cluster.abort();
            }
        }
    }
    let mut clusters = Clusters(Vec::new());
    let mut states = Vec::new();
    for store in [
        base.recovery.clone(),
        RecoveryStore::postgres(second_pool.clone()),
    ] {
        if delegated {
            store.configure_delegated("https://station-dev.agora.build", 1).await.unwrap();
        }
        let cluster = crate::start_redis_replica(
            &test_support::test_url(),
            base.identity.clone(),
            KeyCache::new(),
            Duration::from_secs(2),
            crate::cluster::limits::DEFAULT_WS_MAX_PER_IP,
        )
        .await
        .unwrap();
        let mut state = base.clone();
        state.relay = cluster.relay.clone();
        state.recovery = store;
        state.relay.configure_recovery(state.recovery.clone());
        states.push(state);
        clusters.0.push(cluster);
    }
    for cluster in &clusters.0 {
        cluster.health.refresh().await.unwrap();
    }
    let mut h = Harness::connect(
        f,
        states.remove(0),
        states.remove(0),
        Vec::new(),
        Arc::default(),
    )
    .await;
    completion_after_rekey(&mut h).await;
    drop(h);
    drop(clusters);
    second_pool.close().await;
    db.cleanup().await;
}

#[tokio::test]
async fn proved_reverification_requires_a_commit_before_the_membership_changes() {
    let mut h = Harness::new(false).await;
    h.publish_rekey().await;
    h.send_owner(json!({"type":"deviceVerified","data":{}}))
        .await;
    assert_closed(&mut h.host).await;
}

#[tokio::test]
async fn proved_reverification_cannot_complete_before_durable_publication() {
    let mut h = Harness::new(false).await;
    h.start().await;
    h.send_owner(json!({"type":"deviceVerified","data":{}}))
        .await;
    assert_closed(&mut h.host).await;
    assert_eq!(
        h.host_state
            .recovery
            .integration_log(&h.binding.genesis, "alice")
            .await
            .unwrap()
            .head(),
        h.fixture.log.head()
    );
}

#[tokio::test]
async fn proved_reverification_host_replacement_never_receives_old_completion() {
    let mut h = Harness::new(true).await;
    h.start().await;
    let (keys, key, log) = h.publish_rekey().await;
    let mut replacement = connect_atem(&h.host_base, "phone", "host-a").await;
    prove(&mut replacement, &keys, &key, &log, "host-a").await;
    h.host_state.relay.cleanup_expired().await;
    assert_closed(&mut h.host).await;
    h.send_owner(json!({"type":"deviceVerified","data":{}}))
        .await;
    assert_silent(&mut replacement, 100).await;
}

#[tokio::test]
async fn proved_reverification_owner_replacement_fences_a_delayed_replica_delivery() {
    let mut h = Harness::new(true).await;
    h.start().await;
    h.publish_rekey().await;
    let owner = h
        .owner_state
        .relay
        .room("phone")
        .await
        .unwrap()
        .unwrap()
        .owner
        .unwrap();
    let _replacement = verified_astation(&h.owner_base, "phone", &h.key, "verified").await;
    // Model a completion already in transit when the owner was replaced.
    h.bus
        .send_inbox(
            h.host_state.relay.replica_id(),
            InboxMessage::VerificationDeliver {
                room: "phone".into(),
                connection_id: h.binding.connection.conn.clone(),
                owner,
                frame: json!({"type":"deviceVerified","data":{}}).to_string(),
            },
        )
        .await
        .unwrap();
    h.host_state.relay.cleanup_expired().await;
    assert_closed(&mut h.host).await;
}

#[tokio::test]
async fn proved_reverification_removal_revokes_the_completion_window() {
    let mut h = Harness::new(true).await;
    h.start().await;
    let reply = h
        .host_state
        .recovery
        .perform(
            &h.binding.genesis,
            "alice",
            Operation::Append {
                entry: h.fixture.remove_host(),
                expected: h.fixture.log.head().clone(),
            },
        )
        .await;
    assert_eq!(reply.0, StatusCode::OK);
    h.send_owner(json!({"type":"deviceVerified","data":{}}))
        .await;
    assert_closed(&mut h.host).await;
}

#[tokio::test]
async fn proved_reverification_abort_can_retry_on_a_fresh_proved_connection() {
    let mut h = Harness::new(true).await;
    h.start().await;
    let abort = json!({"type":"verifyAbort","data":{"reason":"publication failed"}});
    h.send_owner(abort.clone()).await;
    assert_eq!(next_client_json(&mut h.host).await, abort);
    assert_closed(&mut h.host).await;
    assert_eq!(
        h.host_state
            .recovery
            .integration_log(&h.binding.genesis, "alice")
            .await
            .unwrap()
            .head(),
        h.fixture.log.head()
    );
    let mut reconnect = connect_atem(&h.host_base, "phone", "host-a").await;
    prove(
        &mut reconnect,
        &h.fixture.keys,
        &h.fixture.host_key,
        &h.fixture.log,
        "host-a",
    )
    .await;
    let new_connection = h
        .host_state
        .relay
        .room("phone")
        .await
        .unwrap()
        .unwrap()
        .atems["host-a"]
        .clone();
    assert_ne!(new_connection, h.binding.connection);
    send_json(
        &mut reconnect,
        json!({"type":"verifyCommit","data":{"device_id":"host-a",
        "host_trust_gen":2,"commitment":"fresh commitment"}}),
    )
    .await;
    loop {
        let frame = next_client_json(&mut h.owner).await;
        if frame["payload"]["type"] == "verifyCommit" {
            assert_eq!(frame["connection_id"], new_connection.conn);
            break;
        }
    }
    send_json(
        &mut h.owner,
        json!({"atem_id":"host-a","connection_id":new_connection.conn,
        "payload":{"type":"verifyKeys","data":{"nonce":"fresh keys"}}}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut reconnect).await["data"]["nonce"],
        "fresh keys"
    );
}

#[tokio::test]
async fn proved_reverification_host_abort_closes_the_window() {
    let mut h = Harness::new(true).await;
    h.start().await;
    let abort = json!({"type":"verifyAbort","data":{"reason":"code declined"}});
    send_json(&mut h.host, abort.clone()).await;
    assert_eq!(next_client_json(&mut h.owner).await["payload"], abort);
    assert_closed(&mut h.host).await;
    assert_eq!(
        h.host_state
            .recovery
            .integration_log(&h.binding.genesis, "alice")
            .await
            .unwrap()
            .head(),
        h.fixture.log.head()
    );
}
