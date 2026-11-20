use super::super::super::delegated_recovery::{inspect, inspect_root, Binding};
use super::*;
use crate::test_database::TestDatabase;

async fn saved(pool: &sqlx::PgPool, genesis: &str) -> Value {
    sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
        .bind(genesis)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_inspection_reads_fenced_history_without_changing_it() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let binding = Binding::new(ORIGIN, 1).unwrap();
    let before_feed = inspect_root(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    assert!(before_feed["root"]["feed"].is_null());
    assert_eq!(
        store
            .delegated_operation(&genesis, "alice", Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    let root: Root = serde_json::from_value(saved(&database.pool, &genesis).await).unwrap();
    let held = record(
        &f,
        &root.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Hold,
    );
    assert_eq!(
        store
            .delegated_operation(
                &genesis,
                "alice",
                Command::Publish {
                    record: held,
                    revoked_at: f.created,
                    covered: vec!["host-a".into()],
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        store
            .delegated_operation(
                &genesis,
                "alice",
                Command::Reserve {
                    principal: "service:svc-test".into(),
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    binding.initialize(&database.pool, true).await.unwrap();
    let before = saved(&database.pool, &genesis).await;
    let report = inspect_root(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    assert_eq!(report["retained_history_only"], true);
    assert_eq!(report["recovery_ready"], false);
    assert_eq!(report["status"]["reason"], "operator_fenced");
    assert_eq!(report["root"]["membership_head"], f.log.head().to_json());
    assert_eq!(report["root"]["feed"]["head"], 1);
    assert!(
        report["root"]["feed"]["signing_watermarks"]["highest_issued_at"]
            .as_u64()
            .unwrap()
            > f.created
    );
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    let other = Binding::new("https://other.example", 1).unwrap();
    let unrelated = inspect_root(&database.pool, &other, &genesis)
        .await
        .unwrap();
    assert!(unrelated["root"]["feed"].is_null());
    assert!(unrelated["status"].is_null());
    assert!(inspect(&database.pool, &other.origin)
        .await
        .unwrap()
        .is_none());
    sqlx::query("UPDATE remote_recovery_roots SET state=jsonb_set(state,'{inspection_padding}',to_jsonb(repeat('x',16777216))) WHERE genesis_hash=$1")
        .bind(&genesis).execute(&database.pool).await.unwrap();
    assert!(inspect_root(&database.pool, &binding, &genesis)
        .await
        .is_err());
    sqlx::query("UPDATE remote_recovery_roots SET state='{}'::jsonb WHERE genesis_hash=$1")
        .bind(&genesis)
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(inspect_root(&database.pool, &binding, &genesis)
        .await
        .is_err());
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_inspection_does_not_initialize_absent_history() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 2).await;
    let binding = Binding::new(ORIGIN, 2).unwrap();
    let report = inspect_root(&database.pool, &binding, &"0".repeat(64))
        .await
        .unwrap();
    assert!(report["root"].is_null());
    assert_eq!(report["genesis_hash"], "0".repeat(64));
    assert!(report["status"].is_null());
    assert_eq!(report["recovery_ready"], false);
    assert!(inspect(&database.pool, ORIGIN).await.unwrap().is_none());
    for invalid in ["0".repeat(63), "A".repeat(64), "g".repeat(64)] {
        assert!(inspect_root(&database.pool, &binding, &invalid)
            .await
            .is_err());
    }
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_rejects_lost_stops_reservations_and_stale_replicas() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 8).await;
    let old = RecoveryStore::postgres(database.pool.clone());
    old.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&old).await;
    let genesis = f.log.genesis_hash().to_hex();
    let binding = admit(&old, &f, "before-backup").await;
    assert!(old.prepare_delegated(&binding).await);
    let backup = saved(&database.pool, &genesis).await;
    let initial: Root = serde_json::from_value(backup.clone()).unwrap();
    let feed = &initial.delegated[ORIGIN];
    let held = record(
        &f,
        feed,
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Hold,
    );
    assert_eq!(
        old.delegated_operation(
            &genesis,
            "alice",
            Command::Publish {
                record: held,
                revoked_at: f.created,
                covered: vec![],
            }
        )
        .await
        .0,
        StatusCode::OK
    );
    let revoked = build_control(
        &f.keys,
        &KeyId::new("manager"),
        &ControlBody {
            account_id: f.log.account_id().into(),
            genesis_hash: f.log.genesis_hash(),
            feed: Some(ControlFeed {
                origin: ORIGIN.into(),
                feed_id: feed.feed_id.clone(),
            }),
            principal: ControlPrincipal::Service("svc-test".into()),
            principal_key: Some(
                principal_key_of(&f.keys.public_key(&KeyId::new("service")).unwrap()).unwrap(),
            ),
            signer: ControlSigner::Member("phone".into()),
            action: ControlAction::Revoke {
                interrupt_running: true,
            },
            record_id: uuid::Uuid::new_v4().to_string(),
            issued_at: f.created + 1,
            about: ControlAbout {
                integration_id: Some("i-01234567890123456789012345".into()),
                by: "owner".into(),
            },
        },
    )
    .unwrap();
    assert_eq!(
        old.delegated_operation(
            &genesis,
            "alice",
            Command::Owner(OwnerCommand::Publish {
                record: ControlRecord::from_signed(revoked).unwrap(),
                expected: f.log.head(),
            })
        )
        .await
        .0,
        StatusCode::OK
    );
    let (status, reserved) = old
        .delegated_operation(
            &genesis,
            "alice",
            Command::Reserve {
                principal: "service:svc-test".into(),
            },
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(reserved.0["issued_at"].as_u64().unwrap() > f.created + 1);
    let latest = saved(&database.pool, &genesis).await;
    assert_eq!(
        latest["delegated"][ORIGIN]["records"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    // Restore the old root AND old ready recovery row. The deployment's new
    // generation is external to that backup and must not release its lost stops.
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(&backup)
        .bind(&genesis)
        .execute(&database.pool)
        .await
        .unwrap();
    let restored = RecoveryStore::postgres(database.reconnect(3).await);
    assert!(restored.configure_delegated(ORIGIN, 2).await.is_err());
    let fence = inspect(&database.pool, ORIGIN).await.unwrap().unwrap();
    assert_eq!(fence.generation, 2);
    assert!(!fence.ready);
    assert_eq!(fence.reason, "generation_changed");
    assert!(Binding::new(ORIGIN, 1)
        .unwrap()
        .initialize(&database.pool, true)
        .await
        .is_err());
    for command in [
        Command::Ensure,
        Command::Reserve {
            principal: "service:svc-test".into(),
        },
        Command::Owner(OwnerCommand::Heads),
        Command::Ledger(LedgerUpdate::Tick),
    ] {
        assert_eq!(
            old.delegated_operation(&genesis, "alice", command).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
    }
    let mut wrote = false;
    assert!(old
        .with_delegated_response(&binding, None, |_| {
            wrote = true;
            std::future::ready(())
        })
        .await
        .is_none());
    assert!(!wrote);
    assert!(!old.prepare_delegated(&binding).await);
    assert!(old
        .with_host_route(&binding, || std::future::ready(()))
        .await
        .is_none());
    assert!(RecoveryStore::postgres(database.reconnect(2).await)
        .configure_delegated(ORIGIN, 1)
        .await
        .is_err());
    assert!(RecoveryStore::postgres(database.reconnect(2).await)
        .configure_delegated(ORIGIN, 2)
        .await
        .is_err());
    assert_eq!(
        saved(&database.pool, &genesis).await,
        backup,
        "no active snapshot, watermark reset or report settlement"
    );
    assert_eq!(
        inspect(&database.pool, ORIGIN).await.unwrap().unwrap(),
        fence
    );
    drop(old);
    drop(restored);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_never_bootstraps_missing_history_or_reopens_a_fence() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&store).await;
    assert_eq!(
        store
            .delegated_operation(&f.log.genesis_hash().to_hex(), "alice", Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    sqlx::query("DELETE FROM station_delegated_recovery")
        .execute(&database.pool)
        .await
        .unwrap();
    let restarted = RecoveryStore::postgres(database.reconnect(2).await);
    assert!(restarted.configure_delegated(ORIGIN, 1).await.is_err());
    let status = inspect(&database.pool, ORIGIN).await.unwrap().unwrap();
    assert_eq!(status.reason, "history_missing");
    assert!(!status.ready);
    assert!(restarted.configure_delegated(ORIGIN, 1).await.is_err());

    let new_origin = "https://new-station.example";
    assert!(RecoveryStore::postgres(database.pool.clone())
        .configure_delegated(new_origin, 1)
        .await
        .is_err());
    assert_eq!(
        inspect(&database.pool, new_origin)
            .await
            .unwrap()
            .unwrap()
            .reason,
        "history_missing"
    );
    // Even a backup predating every root/feed cannot initialize generation 2.
    sqlx::query("DELETE FROM remote_recovery_roots")
        .execute(&database.pool)
        .await
        .unwrap();
    let fresh = Binding::new("https://empty-station.example", 2).unwrap();
    assert!(!fresh.initialize(&database.pool, false).await.unwrap().ready);
    assert!(
        !Binding::new(&fresh.origin, 1)
            .unwrap()
            .initialize(&database.pool, false)
            .await
            .unwrap()
            .ready
    );
    drop(store);
    drop(restarted);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_fence_waits_for_the_write_boundary_and_survives_restart() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 6).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&store).await;
    let binding = admit(&store, &f, "write-boundary").await;
    assert!(store.prepare_delegated(&binding).await);
    let (entered, waiting) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    let writer = {
        let store = store.clone();
        let binding = binding.clone();
        tokio::spawn(async move {
            store
                .with_delegated_response(&binding, None, |response| async move {
                    response.unwrap().unwrap();
                    entered.send(()).unwrap();
                    released.await.unwrap();
                })
                .await
        })
    };
    waiting.await.unwrap();
    let mut fence = {
        let pool = database.pool.clone();
        tokio::spawn(async move {
            Binding::new(ORIGIN, 1)
                .unwrap()
                .initialize(&pool, true)
                .await
                .unwrap()
        })
    };
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(100), &mut fence)
            .await
            .is_err()
    );
    release.send(()).unwrap();
    assert_eq!(writer.await.unwrap(), Some(()));
    let fenced = fence.await.unwrap();
    assert!(!fenced.ready);
    assert_eq!(fenced.reason, "operator_fenced");
    assert!(store
        .with_delegated_response(&binding, None, |_| std::future::ready(()))
        .await
        .is_none());
    assert!(store.configure_delegated(ORIGIN, 1).await.is_err());
    assert!(RecoveryStore::postgres(database.reconnect(2).await)
        .configure_delegated(ORIGIN, 1)
        .await
        .is_err());
    assert_eq!(
        inspect(&database.pool, ORIGIN).await.unwrap().unwrap(),
        fenced
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_failed_fence_commit_cannot_start_the_new_generation() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    sqlx::query("CREATE FUNCTION fail_recovery_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test recovery commit failure'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_recovery_commit AFTER UPDATE ON station_delegated_recovery DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_recovery_commit()")
        .execute(&database.pool).await.unwrap();
    let new = RecoveryStore::postgres(database.reconnect(2).await);
    assert!(new.configure_delegated(ORIGIN, 2).await.is_err());
    assert!(!new.delegated_enabled());
    assert!(new.delegated_accounts("").await.is_none());
    let mut tx = database.pool.begin().await.unwrap();
    assert!(new.lock_delegated_recovery(&mut tx).await.is_err());
    tx.rollback().await.unwrap();
    let before = inspect(&database.pool, ORIGIN).await.unwrap().unwrap();
    assert_eq!(before.generation, 1);
    sqlx::query("DROP TRIGGER fail_recovery_commit ON station_delegated_recovery")
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(new.configure_delegated(ORIGIN, 2).await.is_err());
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    drop(new);
    drop(store);
    database.cleanup().await;
}
