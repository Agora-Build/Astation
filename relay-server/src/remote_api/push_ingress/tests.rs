use super::*;
use crate::remote_api::recovery::{Operation, RecoveryStore};
use atem_client::{
    membership::{Entry, Head, HostNow},
    push::{self, ApprovalKey, DeviceClass, HintPlain, RecipientInfo},
    KeyId, KeyProvider, SoftwareKeys,
};
use axum::http::StatusCode;

pub(crate) struct Fixture {
    pub keys: SoftwareKeys,
    pub host_key: KeyId,
    pub enc_key: KeyId,
    pub log: Membership,
    pub created: u64,
    pub key: ApprovalKey,
}

impl Fixture {
    pub fn new(created: u64) -> Self {
        let mut keys = SoftwareKeys::new();
        let manager = KeyId::new("manager");
        let enc_key = KeyId::new("push-recipient");
        let host_key = KeyId::new("host");
        let recovery = KeyId::new("recovery");
        keys.insert_p256(manager.clone(), &[1; 32]).unwrap();
        keys.insert_x25519(enc_key.clone(), &[2; 32]);
        keys.insert_ed25519(host_key.clone(), &[3; 32]);
        keys.insert_ed25519(recovery.clone(), &[4; 32]);
        let sign = |body| {
            Entry::parse_bytes(
                &SignedObject::sign(&keys, &manager, body)
                    .unwrap()
                    .to_json()
                    .to_string()
                    .into_bytes(),
            )
            .unwrap()
        };
        let genesis = sign(
            json!({"type":"atem-membership-entry","v":1,"action":"genesis",
            "account_id":"account-test","seq":1,"prev_hash":"0".repeat(64),"signed_at":created,"signer":"phone",
            "member":{"device_id":"phone","kind":"native","roles":["control","manage","view"],
                "auth_key":keys.public_key(&manager).unwrap().to_json(),"enc_key":keys.public_key(&enc_key).unwrap().to_json()},
            "recovery_key":keys.public_key(&recovery).unwrap().to_json()}),
        );
        let hash = genesis.hash();
        let host = sign(
            json!({"type":"atem-membership-entry","v":1,"action":"add_host","account_id":"account-test",
            "genesis_hash":hash.to_hex(),"seq":2,"prev_hash":hash.to_hex(),"signed_at":created,"signer":"phone",
            "host":{"host_id":"host-a","host_trust_gen":1,"host_key":keys.public_key(&host_key).unwrap().to_json()}}),
        );
        let log = Membership::verify_chain(
            "account-test",
            &hash,
            &[genesis, host],
            &HostNow {
                wall_ms: created,
                mono_ms: 0,
                boot_id: "test".into(),
            },
        )
        .unwrap()
        .membership;
        let key = ApprovalKey::new(
            &log,
            "host-a",
            1,
            "session-a",
            "22222222-2222-4222-8222-222222222222",
            "11111111-1111-4111-8111-111111111111",
        );
        Self {
            keys,
            host_key,
            enc_key,
            log,
            created,
            key,
        }
    }

    pub fn open(&self) -> SignedObject {
        push::open_hint(
            &self.keys,
            &self.host_key,
            &self.key,
            self.created,
            self.created + 300_000,
            "phone",
            &self.keys.public_key(&self.enc_key).unwrap(),
            &HintPlain {
                tool: "Bash".into(),
                summary: "npm test".into(),
            },
        )
        .unwrap()
    }
    pub fn resolved(&self) -> SignedObject {
        push::resolved_hint(
            &self.keys,
            &self.host_key,
            &self.key,
            self.created,
            self.created + 300_000,
            "answered",
            self.created + 1000,
        )
        .unwrap()
    }
    pub fn seen(&self) -> SignedObject {
        push::seen(
            &self.keys,
            &self.host_key,
            &self.key,
            self.created,
            "phone",
            self.created + 1000,
        )
        .unwrap()
    }
    pub fn ingress(&self, object: SignedObject) -> Ingress {
        Ingress {
            context: self.context(),
            seen: object.body_type() == "atem-seen",
            object,
        }
    }
    pub fn context(&self) -> HostContext {
        HostContext {
            room: "phone".into(),
            host: "host-a".into(),
            connection: "accepted-socket".into(),
        }
    }
    pub fn verified(&self, resolved: bool) -> Hint {
        Hint::verify(
            &if resolved {
                self.resolved()
            } else {
                self.open()
            },
            &self.log,
            self.created,
            Verifier::Client,
        )
        .unwrap()
    }
    pub async fn publish(&self, store: &RecoveryStore) {
        for entry in self.log.entries() {
            assert_eq!(
                store
                    .perform(
                        &self.log.genesis_hash().to_hex(),
                        "alice",
                        Operation::Append {
                            entry: entry.clone(),
                            expected: Head {
                                seq: entry.seq - 1,
                                hash: entry.prev_hash
                            }
                        }
                    )
                    .await
                    .0,
                StatusCode::OK
            );
        }
    }

    pub(crate) fn remove_host(&self) -> Entry {
        let head = self.log.head();
        let object = SignedObject::sign(&self.keys, &KeyId::new("manager"), json!({
            "type":"atem-membership-entry", "v":1, "action":"remove_host", "account_id":"account-test",
            "genesis_hash":self.log.genesis_hash().to_hex(), "seq":head.seq+1, "prev_hash":head.hash.to_hex(),
            "signed_at":self.created, "signer":"phone", "host_id":"host-a"
        })).unwrap();
        Entry::parse_bytes(object.to_json().to_string().as_bytes()).unwrap()
    }
}

fn mobile(_: &str) -> RecipientInfo {
    RecipientInfo {
        class: DeviceClass::Mobile,
        connected: false,
        immediate_mobile: false,
    }
}

#[test]
fn durable_replay_preserves_the_signed_schedule_and_conflicting_bytes_cannot_replace_it() {
    let f = Fixture::new(900_000);
    let mut state = PushState::default();
    let open = f.open();
    assert_eq!(
        state
            .receive(&f.ingress(open.clone()), &f.log, f.created)
            .unwrap()["code"],
        "accepted"
    );
    let saved = serde_json::to_vec(&state).unwrap();
    assert!(!String::from_utf8_lossy(&saved).contains("npm test"));
    state = serde_json::from_slice(&saved).unwrap();
    assert_eq!(
        state
            .receive(&f.ingress(open.clone()), &f.log, f.created + 180_000)
            .unwrap()["code"],
        "idempotent"
    );
    assert!(state
        .ledger(&f.log)
        .due(f.created + 59_999, &mobile)
        .is_empty());
    assert_eq!(
        state.ledger(&f.log).due(f.created + 60_000, &mobile).len(),
        1
    );
    let other = f.open(); // HPKE resealing changes bytes for the same identity.
    assert_eq!(
        state
            .receive(&f.ingress(other), &f.log, f.created + 1000)
            .unwrap()["code"],
        "duplicate"
    );
    assert_eq!(state.events.len(), 1);
    assert_eq!(state.events[0].object, open.to_json());
}

#[test]
fn pending_seen_survives_restart_and_resolution_dominates_delayed_open() {
    let f = Fixture::new(900_000);
    let mut state = PushState::default();
    assert_eq!(
        state
            .receive(&f.ingress(f.seen()), &f.log, f.created)
            .unwrap()["code"],
        "pending"
    );
    state = serde_json::from_slice(&serde_json::to_vec(&state).unwrap()).unwrap();
    state
        .receive(&f.ingress(f.open()), &f.log, f.created + 1000)
        .unwrap();
    assert!(state
        .ledger(&f.log)
        .due(f.created + 60_000, &mobile)
        .is_empty());
    let mut resolved = PushState::default();
    resolved
        .receive(&f.ingress(f.resolved()), &f.log, f.created)
        .unwrap();
    assert_eq!(
        resolved
            .receive(&f.ingress(f.open()), &f.log, f.created + 1000)
            .unwrap()["code"],
        "ignored_after_resolved"
    );
    assert!(resolved
        .ledger(&f.log)
        .due(f.created + 60_000, &mobile)
        .is_empty());
}

#[test]
fn forged_carriers_generations_and_payloads_cannot_create_acknowledged_work() {
    let f = Fixture::new(900_000);
    let mut state = PushState::default();
    for field in ["host", "room"] {
        let mut ingress = f.ingress(f.open());
        if field == "host" {
            ingress.context.host = "other".into()
        } else {
            ingress.context.room = "other".into()
        }
        assert!(state.receive(&ingress, &f.log, f.created).is_err());
    }
    let mut altered = f.open().to_json();
    altered["body"]["session_id"] = json!("other");
    let object = SignedObject::parse(altered.to_string().as_bytes()).unwrap();
    assert!(state
        .receive(&f.ingress(object), &f.log, f.created)
        .is_err());
    assert!(state.events.is_empty());
    let mut key = f.key.clone();
    key.host_trust_gen = 2;
    let old = push::resolved_hint(
        &f.keys,
        &f.host_key,
        &key,
        f.created,
        f.created + 300_000,
        "answered",
        f.created + 1000,
    )
    .unwrap();
    assert_eq!(
        state.receive(&f.ingress(old), &f.log, f.created).unwrap()["code"],
        "binding"
    );
    assert!(state.events.iter().all(|e| !e.accepted));
}

#[tokio::test]
async fn disabled_storage_and_malformed_or_plaintext_push_never_acknowledge() {
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    let message = push::push_hint_message(&[f.open()]).to_string();
    assert!(handle(&RecoveryStore::disabled(), f.context(), &message)
        .await
        .unwrap()
        .is_empty());
    for text in [
        r#"{"type":"push_approval","tool":"Bash","summary":"secret"}"#,
        r#"{"type":"relay","op":"push_seen","seen":{},"extra":true}"#,
        r#"{"type":"relay","type":"relay","op":"push_hint","hints":[]}"#,
    ] {
        assert!(handle(&RecoveryStore::memory(), f.context(), text)
            .await
            .unwrap()
            .is_empty());
    }
}

#[tokio::test]
async fn two_ingress_workers_ack_one_durable_event_after_the_carrier_disappears() {
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    let store = RecoveryStore::memory();
    f.publish(&store).await;
    let message = push::push_hint_message(&[f.open()]).to_string();
    let (a, b) = tokio::join!(
        handle(&store, f.context(), &message),
        handle(&store, f.context(), &message)
    );
    assert_eq!(a, b);
    let a = a.unwrap();
    assert_eq!(a.len(), 1);
    let ack: Value = serde_json::from_str(&a[0]).unwrap();
    assert_eq!(ack["acks"][0]["process_gen"], f.key.process_gen);
    assert_eq!(ack["acks"][0]["device_id"], "phone");
    // Processing uses the captured context and never looks up a live socket.
    let mut disconnected = f.context();
    disconnected.connection = "already-closed".into();
    assert_eq!(handle(&store, disconnected, &message).await.unwrap(), a);
}

#[tokio::test]
async fn membership_removal_fences_delayed_ingress_and_previously_accepted_retries() {
    for accepted_first in [false, true] {
        let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        let store = RecoveryStore::memory();
        f.publish(&store).await;
        let message = push::push_hint_message(&[f.open()]).to_string();
        let context = f.context(); // Captured while this host was still enrolled.
        if accepted_first {
            assert_eq!(
                handle(&store, context.clone(), &message)
                    .await
                    .unwrap()
                    .len(),
                1
            )
        }
        assert_eq!(
            store
                .perform(
                    &f.log.genesis_hash().to_hex(),
                    "alice",
                    Operation::Append {
                        entry: f.remove_host(),
                        expected: f.log.head().clone()
                    }
                )
                .await
                .0,
            StatusCode::OK
        );
        assert!(handle(&store, context, &message).await.unwrap().is_empty());
        let mut entries = f.log.entries().to_vec();
        entries.push(f.remove_host());
        let removed = Membership::verify_chain(
            "account-test",
            &f.log.genesis_hash(),
            &entries,
            &HostNow {
                wall_ms: f.created,
                mono_ms: 1,
                boot_id: "test".into(),
            },
        )
        .unwrap()
        .membership;
        let mut state = PushState::default();
        state
            .receive(&f.ingress(f.open()), &f.log, f.created)
            .unwrap();
        assert!(state
            .ledger(&removed)
            .due(f.created + 60_000, &mobile)
            .is_empty());
    }
}

async fn websocket_retry_after_disconnect(store: std::sync::Arc<RecoveryStore>) {
    use crate::relay::tests::{connect_atem, next_client_json, send_json, spawn_relay};
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let state = crate::AppState {
        recovery: store.clone(),
        ..crate::tests::test_state()
    };
    let (url, server) = spawn_relay(state.clone()).await;
    let message = push::push_hint_message(&[f.open()]);
    // No Mac is connected. Delivery is accepted independently of its sender's lifetime.
    let mut first = connect_atem(&url, "phone", "host-a").await;
    crate::remote_api::host_route_tests::prove(&mut first, &f.keys, &f.host_key, &f.log, "host-a").await;
    send_json(&mut first, message.clone()).await;
    first.close(None).await.unwrap();
    drop(first);
    // A fresh proof restores the route without fixture-side room creation.
    let mut next = connect_atem(&url, "phone", "host-a").await;
    crate::remote_api::host_route_tests::prove(&mut next, &f.keys, &f.host_key, &f.log, "host-a").await;
    send_json(&mut next, message.clone()).await;
    let ack = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        next_client_json(&mut next),
    )
    .await
    .unwrap();
    assert_eq!(ack["type"], "relay");
    assert_eq!(ack["op"], "push_ack");
    assert_eq!(ack["acks"].as_array().unwrap().len(), 1);
    assert_eq!(ack["acks"][0]["process_gen"], f.key.process_gen);
    send_json(&mut next, message.clone()).await;
    assert_eq!(next_client_json(&mut next).await, ack);
    // A forged signature never gets an ACK, nor is it forwarded as host content.
    let mut forged = message.clone();
    forged["hints"][0]["body"]["session_id"] = json!("forged");
    send_json(&mut next, forged).await;
    send_json(
        &mut next,
        json!({"type":"push_approval","tool":"secret","summary":"secret"}),
    )
    .await;
    send_json(&mut next, message.clone()).await;
    assert_eq!(next_client_json(&mut next).await, ack);
    // A room join alone cannot report another host's signed hint.
    let mut imposter = connect_atem(&url, "phone", "imposter").await;
    assert_eq!(next_client_json(&mut imposter).await["op"], "host_challenge");
    send_json(&mut imposter, message.clone()).await;
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(150),
        next_client_json(&mut imposter)
    )
    .await
    .is_err());
    let mut context = f.context();
    context.connection = state.relay.room("phone").await.unwrap().unwrap().atems["host-a"].conn.clone();
    let saved = handle(&store, context, &message.to_string())
        .await
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&saved[0]).unwrap(), ack);
    server.abort();
}

#[tokio::test]
async fn real_websocket_push_works_without_a_mac_and_survives_immediate_disconnect() {
    websocket_retry_after_disconnect(RecoveryStore::memory()).await;
}

#[tokio::test]
#[ignore = "requires a local isolated Postgres test database"]
async fn postgres_real_websocket_push_disconnect_and_retry_commit_one_record() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    websocket_retry_after_disconnect(RecoveryStore::postgres(db.pool.clone())).await;
    let root: Value = sqlx::query_scalar("SELECT state FROM remote_recovery_roots")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(root["push"]["events"].as_array().unwrap().len(), 1);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires a local isolated Postgres test database"]
async fn postgres_ack_follows_commit_and_survives_replica_restart_and_failed_write() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    let store = RecoveryStore::postgres(db.pool.clone());
    f.publish(&store).await;
    let second_pool = db.reconnect(4).await;
    let replica = RecoveryStore::postgres(second_pool.clone());
    let message = push::push_hint_message(&[f.open()]).to_string();
    sqlx::query(
        "ALTER TABLE remote_recovery_roots ADD CONSTRAINT push_fail CHECK (false) NOT VALID",
    )
    .execute(&db.pool)
    .await
    .unwrap();
    assert!(handle(&store, f.context(), &message)
        .await
        .unwrap()
        .is_empty());
    sqlx::query("ALTER TABLE remote_recovery_roots DROP CONSTRAINT push_fail")
        .execute(&db.pool)
        .await
        .unwrap();
    let (left, right) = tokio::join!(
        handle(&store, f.context(), &message),
        handle(&replica, f.context(), &message)
    );
    assert_eq!(left, right);
    assert_eq!(left.as_ref().unwrap().len(), 1);
    let root: Value = sqlx::query_scalar("SELECT state FROM remote_recovery_roots")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(root["push"]["events"].as_array().unwrap().len(), 1);
    assert!(!root.to_string().contains("npm test"));
    drop(store);
    drop(replica);
    let restarted = RecoveryStore::postgres(db.reconnect(2).await);
    assert_eq!(handle(&restarted, f.context(), &message).await, left);
    drop(restarted);
    second_pool.close().await;
    db.cleanup().await;
}
