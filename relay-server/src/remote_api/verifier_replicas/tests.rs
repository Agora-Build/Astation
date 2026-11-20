use super::*;
use crate::test_database::TestDatabase;

const ORIGIN: &str = "https://station.example";

fn config(replica: &str) -> Configuration {
    Configuration {
        generation: 1,
        replica: replica.into(),
        replicas: vec!["a".into(), "b".into()],
    }
}

async fn setup() -> (TestDatabase, Binding) {
    let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let binding = Binding::new(ORIGIN, 1).unwrap();
    assert!(binding.initialize(&db.pool, false).await.unwrap().ready);
    (db, binding)
}

#[test]
fn configuration_requires_an_explicit_bounded_sorted_roster() {
    let good = r#"{"generation":1,"replica":"a","replicas":["a","b"]}"#;
    assert_eq!(Configuration::parse(good), Ok(config("a")));
    for bad in [
        good.replace("\"generation\":1", "\"generation\":0"),
        good.replace("\"generation\":1", "\"generation\":9007199254740992"),
        good.replace("\"generation\":1", "\"generation\":1.0"),
        good.replace("\"generation\":1", "\"generation\":1,\"generation\":1"),
        good.replace("\"replica\":\"a\"", "\"replica\":\"c\""),
        good.replace("[\"a\",\"b\"]", "[\"b\",\"a\"]"),
        good.replace("[\"a\",\"b\"]", "[\"a\",\"a\"]"),
        good.replace("[\"a\",\"b\"]", "[]"),
        good.replace("[\"a\",\"b\"]", "[\"a\",\"bad id\"]"),
        good.replace("{", "{\"extra\":null,"),
        " ".repeat(16_385),
    ] {
        assert!(Configuration::parse(&bad).is_err(), "{bad}");
    }
    let mut oversized = config("a");
    oversized.replicas = (0..65).map(|i| format!("a{i:02}")).collect();
    oversized.replica = "a00".into();
    assert!(oversized.validate().is_err());
    assert!(!valid_id(&"a".repeat(129)));
}

#[test]
fn same_version_requires_the_same_actions_and_later_versions_only_widen() {
    let ours = VerifierInventory::ours();
    assert!(widens(&ours, &ours));
    let mut actions = ours.actions().to_vec();
    actions.push("zz_future".into());
    let changed_same_version = VerifierInventory::new(ours.version(), actions.clone()).unwrap();
    assert!(!widens(&changed_same_version, &ours));
    let wider = VerifierInventory::new(ours.version() + 1, actions).unwrap();
    assert!(widens(&wider, &ours));
    assert!(!widens(&ours, &wider));
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_missing_expired_and_withdrawn_replicas_remain_required() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let one = a.snapshot().await.unwrap();
    assert_eq!(one["replicas"].as_array().unwrap().len(), 2);
    assert_eq!(
        one["replicas"][0]["verifier"],
        VerifierInventory::ours().to_json()
    );
    assert_eq!(one["replicas"][1], json!({"id":"b"}));
    let b = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("b"))
        .await
        .unwrap();
    assert!(a.snapshot().await.unwrap()["replicas"][1]["verifier"].is_object());
    sqlx::query("UPDATE station_verifier_replicas SET expires_at=clock_timestamp()-interval '1 second' WHERE replica_id='b'")
        .execute(&db.pool).await.unwrap();
    assert!(b.refresh().await.is_err());
    assert!(b.snapshot().await.is_err());
    let expired = a.snapshot().await.unwrap();
    assert_eq!(
        expired["replicas"][1],
        json!({"id":"b","connection_generation":1})
    );
    let replacement = ReplicaRegistry::register(db.pool.clone(), binding, config("b"))
        .await
        .unwrap();
    assert_eq!(replacement.connection_generation, 2);
    assert!(b.refresh().await.is_err());
    b.withdraw().await.unwrap();
    assert!(replacement.refresh().await.is_ok());
    replacement.withdraw().await.unwrap();
    assert!(replacement.refresh().await.is_err());
    assert_eq!(
        a.snapshot().await.unwrap()["replicas"][1],
        json!({"id":"b","connection_generation":2})
    );
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_replacement_cannot_hide_a_live_replica_or_downgrade_it() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let b = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("b"))
        .await
        .unwrap();
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("b"))
            .await
            .is_err()
    );
    b.withdraw().await.unwrap();
    let ours = VerifierInventory::ours();
    let higher = VerifierInventory::new(ours.version() + 1, ours.actions().to_vec()).unwrap();
    sqlx::query("UPDATE station_verifier_replicas SET highest_inventory=$1 WHERE replica_id='b'")
        .bind(higher.to_json())
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding, config("b"))
            .await
            .is_err()
    );
    let report = a.snapshot().await.unwrap();
    assert_eq!(
        report["replicas"][1],
        json!({"id":"b","connection_generation":2})
    );
    let saved: Value = sqlx::query_scalar(
        "SELECT highest_inventory FROM station_verifier_replicas WHERE replica_id='b'",
    )
    .fetch_one(&db.pool)
    .await
    .unwrap();
    assert_eq!(saved, higher.to_json());
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_roster_changes_retire_old_connections_and_cannot_roll_back() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let mut changed = config("b");
    changed.replicas.push("c".into());
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding.clone(), changed.clone())
            .await
            .is_err()
    );
    changed.generation = 2;
    let b = ReplicaRegistry::register(db.pool.clone(), binding.clone(), changed)
        .await
        .unwrap();
    assert!(a.refresh().await.is_err());
    assert!(a.snapshot().await.is_err());
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding, config("a"))
            .await
            .is_err()
    );
    let reports = b.snapshot().await.unwrap();
    assert_eq!(reports["roster_generation"], 2);
    assert!(reports["replicas"][0]["verifier"].is_null());
    assert_eq!(reports["replicas"][2], json!({"id":"c"}));
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_recovery_fence_closes_reports_renewals_and_registration() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    binding.initialize(&db.pool, true).await.unwrap();
    assert!(a.snapshot().await.is_err());
    assert!(a.refresh().await.is_err());
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding, config("b"))
            .await
            .is_err()
    );
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_stale_restore_reports_cannot_cross_a_recovery_generation() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let _b = ReplicaRegistry::register(db.pool.clone(), binding, config("b"))
        .await
        .unwrap();
    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&db.pool, false).await.unwrap();
    // Simulates a separately verified future restore workflow reopening its fence.
    sqlx::query("UPDATE station_delegated_recovery SET ready=true")
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(a.snapshot().await.is_err());
    assert!(a.refresh().await.is_err());
    let current = ReplicaRegistry::register(db.pool.clone(), next, config("a"))
        .await
        .unwrap();
    let report = current.snapshot().await.unwrap();
    assert!(report["replicas"][0]["verifier"].is_object());
    assert_eq!(
        report["replicas"][1],
        json!({"id":"b","connection_generation":1})
    );
    a.withdraw().await.unwrap();
    assert!(current.refresh().await.is_ok());
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_monotonic_expiry_and_clock_rollback_do_not_revive_evidence() {
    let (db, binding) = setup().await;
    let a = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let b = ReplicaRegistry::register(db.pool.clone(), binding, config("b"))
        .await
        .unwrap();
    *b.valid_before.lock().await = Instant::now();
    assert!(b.refresh().await.is_err());
    assert!(b.snapshot().await.is_err());
    sqlx::query("UPDATE station_verifier_replicas SET expires_at=clock_timestamp()+interval '5 minutes' WHERE replica_id='b'")
        .execute(&db.pool).await.unwrap();
    assert!(b.refresh().await.is_err());
    assert_eq!(
        a.snapshot().await.unwrap()["replicas"][1],
        json!({"id":"b","connection_generation":1})
    );
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_invalid_configuration_and_failed_commit_publish_no_roster() {
    let (db, binding) = setup().await;
    let mut invalid = config("a");
    invalid.replicas.clear();
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding.clone(), invalid)
            .await
            .is_err()
    );
    sqlx::query("CREATE FUNCTION reject_verifier_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected commit failure'; END $$")
        .execute(&db.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER reject_verifier_commit AFTER INSERT OR UPDATE ON station_verifier_replicas DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_verifier_commit()")
        .execute(&db.pool).await.unwrap();
    assert!(
        ReplicaRegistry::register(db.pool.clone(), binding, config("a"))
            .await
            .is_err()
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_verifier_rosters")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
#[cfg(feature = "delegated-host-work")]
async fn postgres_account_private_http_reports_exact_head_without_cross_account_disclosure() {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;
    let (db, _) = setup().await;
    let mut app = crate::tests::test_state();
    app.recovery = super::super::RecoveryStore::postgres(db.pool.clone());
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(super::super::tests::TestAccountVerifier),
    ));
    app.recovery.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = super::super::delegated::tests::fixture();
    f.publish(&app.recovery).await;
    let genesis = f.log.genesis_hash().to_hex();
    app.recovery
        .configure_verifier_replicas(r#"{"generation":1,"replica":"a","replicas":["a","b"]}"#)
        .await
        .unwrap();
    let registry = app.recovery.verifier_replicas().unwrap();
    for (owner, selected, expected) in [
        (Some("alice"), genesis.as_str(), StatusCode::OK),
        (None, genesis.as_str(), StatusCode::UNAUTHORIZED),
        (Some("bob"), genesis.as_str(), StatusCode::NOT_FOUND),
        (
            Some("alice"),
            "0000000000000000000000000000000000000000000000000000000000000000",
            StatusCode::NOT_FOUND,
        ),
        (Some("alice"), "invalid", StatusCode::BAD_REQUEST),
    ] {
        let mut request = Request::builder()
            .uri(format!("/api/remote/v1/logs/{selected}/verifiers"))
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40001".parse::<std::net::SocketAddr>().unwrap(),
            ));
        if let Some(owner) = owner {
            request = request.header("authorization", format!("Bearer {owner}"));
        }
        let response = crate::router(app.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        assert_eq!(response.headers()["cache-control"], "no-store");
        let value: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 262_144).await.unwrap())
                .unwrap();
        if expected == StatusCode::OK {
            assert_eq!(value["account_id"], f.log.account_id());
            assert_eq!(value["genesis_hash"], genesis);
            assert_eq!(value["head"], f.log.head().to_json());
            assert_eq!(value["replicas"][1], json!({"id":"b"}));
        } else {
            assert_eq!(value.as_object().unwrap().len(), 1);
            assert!(value.get("replicas").is_none());
        }
    }
    registry.withdraw().await.unwrap();
    assert!(app
        .recovery
        .integration_log(&genesis, "alice")
        .await
        .is_none());
    let response = crate::router(app.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/api/remote/v1/logs/{genesis}/verifiers"))
                .header("authorization", "Bearer alice")
                .extension(axum::extract::ConnectInfo(
                    "127.0.0.1:40001".parse::<std::net::SocketAddr>().unwrap(),
                ))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    drop(app);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_replacement_waits_for_the_old_verifier_write_boundary() {
    let (db, binding) = setup().await;
    let old = ReplicaRegistry::register(db.pool.clone(), binding.clone(), config("a"))
        .await
        .unwrap();
    let mut tx = db.pool.begin().await.unwrap();
    old.lock_live(&mut tx).await.unwrap();
    let draining = old.clone();
    let mut withdrawal = tokio::spawn(async move { draining.withdraw().await });
    assert!(
        tokio::time::timeout(Duration::from_millis(20), &mut withdrawal)
            .await
            .is_err()
    );
    tx.commit().await.unwrap();
    withdrawal.await.unwrap().unwrap();
    let replacement = ReplicaRegistry::register(db.pool.clone(), binding, config("a"))
        .await
        .unwrap();
    let mut tx = db.pool.begin().await.unwrap();
    assert!(old.lock_live(&mut tx).await.is_err());
    replacement.lock_live(&mut tx).await.unwrap();
    tx.rollback().await.unwrap();
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_lost_verifier_lease_uses_the_existing_relay_drain_supervisor() {
    use std::sync::atomic::{AtomicBool, Ordering};
    let (db, binding) = setup().await;
    let replica = ReplicaRegistry::register(db.pool.clone(), binding, config("a"))
        .await
        .unwrap();
    *replica.valid_before.lock().await = Instant::now();
    let relay = crate::tests::test_state().relay;
    let stopped = Arc::new(AtomicBool::new(false));
    let observed = stopped.clone();
    tokio::time::timeout(
        Duration::from_secs(2),
        crate::run_supervisor(
            vec![("Station verifier inventory", replica.spawn_refresh())],
            relay.clone(),
            Duration::ZERO,
            move |_| {
                observed.store(true, Ordering::SeqCst);
            },
        ),
    )
    .await
    .unwrap();
    assert!(stopped.load(Ordering::SeqCst));
    assert!(relay.is_draining());
    db.cleanup().await;
}
