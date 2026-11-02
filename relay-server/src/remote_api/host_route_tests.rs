use super::{
    push_ingress::tests::Fixture,
    recovery::{HostBinding, Operation, RecoveryStore},
};
use crate::{
    cluster::ConnRef,
    relay::tests::{connect_atem, next_client_json, send_json, spawn_relay, TestSocket},
};
use atem_client::{
    host_route::{host_route_message, sign_host_route, HostChallenge, HostRouteBody},
    membership::Membership,
    KeyId, SoftwareKeys,
};
use axum::http::StatusCode;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

pub(crate) fn proof(
    keys: &SoftwareKeys,
    key: &KeyId,
    log: &Membership,
    challenge: &HostChallenge,
    atem: &str,
) -> Value {
    host_route_message(
        &sign_host_route(
            keys,
            key,
            &HostRouteBody::at(log, "host-a", atem, challenge),
        )
        .unwrap(),
    )
}

pub(crate) async fn prove(
    socket: &mut TestSocket,
    keys: &SoftwareKeys,
    key: &KeyId,
    log: &Membership,
    atem: &str,
) -> Value {
    let challenge =
        HostChallenge::parse(next_client_json(socket).await.to_string().as_bytes()).unwrap();
    let message = proof(keys, key, log, &challenge, atem);
    send_json(socket, message.clone()).await;
    let verdict = next_client_json(socket).await;
    assert_eq!(verdict["op"], "host_route_ok", "{verdict}");
    message
}

fn state(store: Arc<RecoveryStore>) -> crate::AppState {
    let mut state = crate::tests::test_state();
    state.recovery = store;
    state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        state.knowledge.clone(),
        state.vault.clone(),
        Arc::new(super::recovery::tests::TestAccountVerifier),
    ));
    state
}

async fn admit(store: &RecoveryStore, f: &Fixture, connection: &str) -> (HostBinding, Value) {
    let challenge = HostChallenge::new("phone");
    store
        .admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new(connection, "local"),
        )
        .await
        .unwrap()
}

#[tokio::test]
async fn isolated_candidate_cannot_displace_host_and_fresh_challenge_refuses_replay() {
    let store = RecoveryStore::memory();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let app = state(store.clone());
    let (base, server) = spawn_relay(app.clone()).await;
    // No room creation by a fixture or native client.
    let mut first = connect_atem(&base, "phone", "host-a").await;
    let old_proof = prove(&mut first, &f.keys, &f.host_key, &f.log, "host-a").await;
    let original = app.relay.room("phone").await.unwrap().unwrap().atems["host-a"].clone();
    let mut candidate = connect_atem(&base, "phone", "host-a").await;
    let challenge = next_client_json(&mut candidate).await;
    assert_eq!(challenge["op"], "host_challenge");
    send_json(
        &mut candidate,
        json!({"type":"channel","event":"open","channel":"fake","transport":"relay"}),
    )
    .await;
    assert_eq!(
        app.relay.room("phone").await.unwrap().unwrap().atems["host-a"],
        original
    );
    send_json(&mut candidate, old_proof).await;
    assert_eq!(
        next_client_json(&mut candidate).await["code"],
        "nonce_mismatch"
    );
    assert_eq!(
        app.relay.room("phone").await.unwrap().unwrap().atems["host-a"],
        original
    );
    let mut replacement = connect_atem(&base, "phone", "host-a").await;
    let repeated = prove(&mut replacement, &f.keys, &f.host_key, &f.log, "host-a").await;
    let current = app.relay.room("phone").await.unwrap().unwrap().atems["host-a"].clone();
    assert_ne!(current, original);
    // Replaying on the same connection never commits a second acquisition.
    send_json(&mut replacement, repeated).await;
    assert_eq!(
        app.relay.room("phone").await.unwrap().unwrap().atems["host-a"],
        current
    );
    server.abort();
}

async fn reconnect_after_directory_restart(store: Arc<RecoveryStore>) {
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let app = state(store.clone());
    let (base, server) = spawn_relay(app.clone()).await;
    let mut first = connect_atem(&base, "phone", "host-a").await;
    prove(&mut first, &f.keys, &f.host_key, &f.log, "host-a").await;
    first.close(None).await.unwrap();
    server.abort();
    // Every ephemeral directory is new; only recovery storage is retained.
    let app = state(store.clone());
    let (base, server) = spawn_relay(app.clone()).await;
    assert!(app.relay.room("phone").await.unwrap().is_none());
    let mut host = connect_atem(&base, "phone", "host-a").await;
    prove(&mut host, &f.keys, &f.host_key, &f.log, "host-a").await;
    app.relay.cleanup_expired().await;
    send_json(&mut host, atem_client::push::push_hint_message(&[f.open()])).await;
    assert_eq!(next_client_json(&mut host).await["op"], "push_ack");
    // An owner arriving later sees the proved host and can authenticate normally.
    let (mut owner, _) = crate::relay::tests::connect_astation(&base, "phone").await;
    let connected = next_client_json(&mut owner).await;
    assert_eq!(connected["atem_id"], "host-a");
    server.abort();
}

#[tokio::test]
async fn no_mac_reconnect_restores_route_after_entire_directory_restart() {
    reconnect_after_directory_restart(RecoveryStore::memory()).await;
}

#[tokio::test]
async fn owner_present_bootstrap_without_a_membership_pin_keeps_carrier_a() {
    let app = state(RecoveryStore::memory());
    let (base, server) = spawn_relay(app).await;
    let (mut owner, _) = crate::relay::tests::connect_astation(&base, "new-account").await;
    let mut host = connect_atem(&base, "new-account", "new-host").await;
    assert_eq!(next_client_json(&mut host).await["op"], "host_challenge");
    assert_eq!(
        next_client_json(&mut owner).await["relay_event"],
        "connected"
    );
    send_json(
        &mut host,
        json!({"type":"auth_request","nonce":"bootstrap"}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut owner).await["payload"]["nonce"],
        "bootstrap"
    );
    send_json(&mut owner, json!({"type":"auth_required","nonce":"owner"})).await;
    assert_eq!(next_client_json(&mut host).await["nonce"], "owner");
    server.abort();
}

#[tokio::test]
async fn pairing_host_waits_without_route_proof_for_later_owner() {
    let mut app = state(RecoveryStore::memory());
    app.relay = crate::relay::RelayHub::with_auth_timeout(Duration::from_millis(50));
    let (base, server) = spawn_relay(app.clone()).await;
    let http_base = base.replace("ws://", "http://").trim_end_matches("/ws").to_string();
    let client = reqwest::Client::new();
    let created: Value = client.post(format!("{http_base}/api/pair"))
        .json(&json!({"hostname":"disposable-pairing-host"}))
        .send().await.unwrap().error_for_status().unwrap().json().await.unwrap();
    let code = created["code"].as_str().unwrap();
    let mut host = connect_atem(&base, code, "new-host").await;

    // A human can take longer than the independent route-proof deadline.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let status: Value = client.get(format!("{http_base}/api/pair/{code}"))
        .send().await.unwrap().error_for_status().unwrap().json().await.unwrap();
    assert_eq!(status["atem_connected"], true, "{status}");
    assert_eq!(status["astation_connected"], false);

    let (mut owner, _) = crate::relay::tests::connect_astation(&base, code).await;
    let connected = next_client_json(&mut owner).await;
    assert_eq!(connected["atem_id"], "new-host");
    assert!(!app.relay.room(code).await.unwrap().unwrap().verified);
    send_json(&mut owner, json!({"type":"auth_required","nonce":"owner"})).await;
    // A pairing link must receive the ceremony, not a host-route challenge.
    assert_eq!(next_client_json(&mut host).await["nonce"], "owner");
    send_json(&mut host, json!({"type":"auth_request","nonce":"pairing"})).await;
    assert_eq!(next_client_json(&mut owner).await["payload"]["nonce"], "pairing");
    server.abort();
}

#[tokio::test]
async fn ownerless_identity_requires_proof_and_expired_pairing_cannot_rejoin() {
    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::{Error, Message};

    let mut app = state(RecoveryStore::memory());
    app.relay = crate::relay::RelayHub::with_auth_timeout(Duration::from_millis(50));
    let now = chrono::Utc::now().timestamp();
    app.relay.ensure_room("identity", "identity", now).await.unwrap();
    let expired = app.relay.create_pair_room("old-host", now - 601, || "OLD-PAIR".into())
        .await.unwrap().unwrap();
    let (base, server) = spawn_relay(app.clone()).await;
    let mut host = connect_atem(&base, "identity", "unproved-host").await;
    assert_eq!(next_client_json(&mut host).await["op"], "host_challenge");
    let closed = tokio::time::timeout(Duration::from_secs(2), host.next()).await.unwrap();
    assert!(matches!(closed, None | Some(Ok(Message::Close(_))) | Some(Err(_))));
    assert!(app.relay.room("identity").await.unwrap().is_none_or(|room| room.atems.is_empty()));

    let result = tokio_tungstenite::connect_async(
        format!("{base}?role=atem&code={expired}&atem_id=old-host")
    ).await;
    assert!(matches!(result, Err(Error::Http(response)) if response.status() == StatusCode::GONE));
    server.abort();
}

#[tokio::test]
async fn unproved_pairing_presence_does_not_supply_an_independent_route() {
    let store = RecoveryStore::memory();
    let now = chrono::Utc::now();
    let f = Fixture::new(now.timestamp_millis() as u64);
    f.publish(&store).await;
    let app = state(store);
    app.relay.create_pair_room("new-host", now.timestamp(), || "phone".into())
        .await.unwrap().unwrap();
    let (base, server) = spawn_relay(app.clone()).await;
    let _host = connect_atem(&base, "phone", "host-a").await;
    tokio::time::timeout(Duration::from_secs(2), async {
        while !app.relay.room("phone").await.unwrap().unwrap().atems.contains_key("host-a") {
            tokio::task::yield_now().await;
        }
    }).await.unwrap();
    let reply = super::recovery::host_target(&app, &f.log.genesis_hash().to_hex(), "alice", "host-a")
        .await.unwrap_err();
    assert_eq!(reply.0, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(reply.1.0["error"]["code"], "host_unreachable");
    server.abort();
}

#[tokio::test]
async fn proved_host_survives_auth_deadline_and_ownerless_room_expiry() {
    let store = RecoveryStore::memory();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let app = state(store);
    app.relay
        .ensure_room("phone", "expired", chrono::Utc::now().timestamp() - 700)
        .await
        .unwrap();
    let (base, server) = spawn_relay(app.clone()).await;
    let mut host = connect_atem(&base, "phone", "host-a").await;
    prove(&mut host, &f.keys, &f.host_key, &f.log, "host-a").await;
    app.relay.cleanup_expired().await;
    assert!(app
        .relay
        .room("phone")
        .await
        .unwrap()
        .unwrap()
        .atems
        .contains_key("host-a"));
    tokio::time::sleep(Duration::from_secs(11)).await;
    send_json(&mut host, atem_client::push::push_hint_message(&[f.open()])).await;
    assert_eq!(next_client_json(&mut host).await["op"], "push_ack");
    server.abort();
}

#[tokio::test]
async fn new_host_key_fences_an_ancestor_proof_and_current_connection() {
    use atem_client::{membership::Entry, KeyProvider, SignedObject};
    let store = RecoveryStore::memory();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let (binding, _) = admit(&store, &f, "old-key").await;
    let owner_route = super::recovery::OwnerRoute {
        genesis: binding.genesis.clone(),
        host: "host-a".into(),
        room: "phone".into(),
        connection: binding.connection.clone(),
        host_trust_gen: 1,
    };
    assert!(store
        .with_owner_route(&owner_route, || async { () })
        .await
        .is_some());
    let removed = f.remove_host();
    assert_eq!(
        store
            .perform(
                &binding.genesis,
                "alice",
                Operation::Append {
                    entry: removed.clone(),
                    expected: f.log.head().clone(),
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    let mut keys = SoftwareKeys::new();
    let key = KeyId::new("replacement");
    keys.insert_ed25519(key.clone(), &[12; 32]);
    let added = SignedObject::sign(
        &f.keys,
        &KeyId::new("manager"),
        json!({
            "type":"atem-membership-entry","v":1,"action":"add_host","account_id":"account-test",
            "genesis_hash":binding.genesis,"seq":4,"prev_hash":removed.hash().to_hex(),
            "signed_at":f.created,"signer":"phone","host":{"host_id":"host-a","host_trust_gen":2,
            "host_key":keys.public_key(&key).unwrap().to_json()}
        }),
    )
    .unwrap();
    let entry = Entry::parse_bytes(added.to_json().to_string().as_bytes()).unwrap();
    assert_eq!(
        store
            .perform(
                &binding.genesis,
                "alice",
                Operation::Append {
                    entry: entry.clone(),
                    expected: atem_client::membership::Head {
                        seq: 3,
                        hash: removed.hash()
                    },
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    assert!(store
        .with_host_route(&binding, || async { panic!("rekeyed route") })
        .await
        .is_none());
    assert!(store
        .with_owner_route(&owner_route, || async { panic!("rekeyed owner route") })
        .await
        .is_none());
    let challenge = HostChallenge::new("phone");
    let super::recovery::HostRouteError::Refused(refusal) = store
        .admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("replayed-key", "local"),
        )
        .await
        .unwrap_err()
    else {
        panic!("expected key refusal")
    };
    assert_eq!(refusal["code"], "bad_signature");
    let mut entries = f.log.entries().to_vec();
    entries.extend([removed, entry]);
    let current = Membership::verify_chain(
        "account-test",
        &f.log.genesis_hash(),
        &entries,
        &atem_client::membership::HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    )
    .unwrap()
    .membership;
    assert!(store
        .admit_host(
            &proof(&keys, &key, &current, &challenge, "host-a").to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("new-key", "local")
        )
        .await
        .is_ok());
}

async fn replacement_and_removal_fence_delayed_effects(store: Arc<RecoveryStore>) {
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let (first, _) = admit(&store, &f, "first").await;
    let (second, _) = admit(&store, &f, "second").await;
    assert!(store
        .with_host_route(&first, || async { panic!("stale effect") })
        .await
        .is_none());
    assert_eq!(
        store.with_host_route(&second, || async { "current" }).await,
        Some("current")
    );
    assert_eq!(
        store
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
    assert!(store
        .with_host_route(&second, || async { panic!("revoked effect") })
        .await
        .is_none());
    let challenge = HostChallenge::new("phone");
    let super::recovery::HostRouteError::Refused(refused) = store
        .admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("old-key-reconnect", "local"),
        )
        .await
        .unwrap_err()
    else {
        panic!("expected membership refusal")
    };
    assert_eq!(refused["code"], "unknown_host");
}

#[tokio::test]
async fn replacement_and_removal_fence_delayed_effects_in_memory() {
    replacement_and_removal_fence_delayed_effects(RecoveryStore::memory()).await;
}

async fn membership_commit_waits_for_admitted_effect(stores: [Arc<RecoveryStore>; 2]) {
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&stores[0]).await;
    let (binding, _) = admit(&stores[0], &f, "current").await;
    let (entered, entered_rx) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    let guarded = stores[0].clone();
    let current = binding.clone();
    let effect = tokio::spawn(async move {
        guarded
            .with_host_route(&current, || async {
                entered.send(()).unwrap();
                release_rx.await.unwrap();
                "admitted"
            })
            .await
    });
    entered_rx.await.unwrap();
    let revocation = stores[1].perform(
        &binding.genesis,
        "alice",
        Operation::Append {
            entry: f.remove_host(),
            expected: f.log.head().clone(),
        },
    );
    tokio::pin!(revocation);
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut revocation)
            .await
            .is_err()
    );
    release.send(()).unwrap();
    assert_eq!(effect.await.unwrap(), Some("admitted"));
    assert_eq!(revocation.await.0, StatusCode::OK);
    assert!(stores[0]
        .with_host_route(&binding, || async { panic!("effect after revocation") })
        .await
        .is_none());
}

#[tokio::test]
async fn membership_changes_serialize_with_queue_admission() {
    let store = RecoveryStore::memory();
    membership_commit_waits_for_admitted_effect([store.clone(), store]).await;
}

#[tokio::test]
#[ignore = "requires a local isolated Postgres test database"]
async fn postgres_membership_changes_serialize_with_queue_admission_across_pools() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let second = db.reconnect(4).await;
    membership_commit_waits_for_admitted_effect([
        RecoveryStore::postgres(db.pool.clone()),
        RecoveryStore::postgres(second.clone()),
    ])
    .await;
    second.close().await;
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires a local isolated Postgres test database"]
async fn postgres_durable_binding_survives_directory_restart_and_revocation() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    reconnect_after_directory_restart(RecoveryStore::postgres(db.pool.clone())).await;
    let stored: Value = sqlx::query_scalar("SELECT state FROM remote_recovery_roots")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(stored["routes"]["host-a"]["host"], "host-a");
    replacement_and_removal_fence_delayed_effects(RecoveryStore::postgres(db.reconnect(4).await))
        .await;
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires a local isolated Postgres test database"]
async fn postgres_failed_write_never_exposes_or_acknowledges_a_host() {
    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::Message;
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(db.pool.clone());
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    sqlx::query(
        "ALTER TABLE remote_recovery_roots ADD CONSTRAINT route_fail CHECK (false) NOT VALID",
    )
    .execute(&db.pool)
    .await
    .unwrap();
    let app = state(store);
    let (base, server) = spawn_relay(app.clone()).await;
    let mut host = connect_atem(&base, "phone", "host-a").await;
    let challenge =
        HostChallenge::parse(next_client_json(&mut host).await.to_string().as_bytes()).unwrap();
    send_json(
        &mut host,
        proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a"),
    )
    .await;
    let reply = tokio::time::timeout(Duration::from_secs(5), host.next())
        .await
        .unwrap();
    assert!(
        matches!(reply, Some(Ok(Message::Close(Some(frame)))) if u16::from(frame.code) == 1013)
    );
    assert!(app.relay.room("phone").await.unwrap().is_none());
    server.abort();
    db.cleanup().await;
}
