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
    let before_feed = inspect_root(&database.pool, &binding, &genesis, None)
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
    let report = inspect_root(&database.pool, &binding, &genesis, None)
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
    let unrelated = inspect_root(&database.pool, &other, &genesis, None)
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
    assert!(inspect_root(&database.pool, &binding, &genesis, None)
        .await
        .is_err());
    sqlx::query("UPDATE remote_recovery_roots SET state='{}'::jsonb WHERE genesis_hash=$1")
        .bind(&genesis)
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(inspect_root(&database.pool, &binding, &genesis, None)
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
    let report = inspect_root(&database.pool, &binding, &"0".repeat(64), None)
        .await
        .unwrap();
    assert!(report["root"].is_null());
    assert_eq!(report["genesis_hash"], "0".repeat(64));
    assert!(report["status"].is_null());
    assert_eq!(report["recovery_ready"], false);
    assert!(inspect(&database.pool, ORIGIN).await.unwrap().is_none());
    for invalid in ["0".repeat(63), "A".repeat(64), "g".repeat(64)] {
        assert!(inspect_root(&database.pool, &binding, &invalid, None)
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
    crate::station_integrations::tests::attach_test_room_owner(&old, ORIGIN).await;
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
async fn postgres_delegated_bootstrap_recognizes_independent_recovery_history() {
    // These three tables can be restored without either a feed or a fence row.
    for retained in [
        "INSERT INTO station_delegated_reporting(binding,events) VALUES ('report', '[]')",
        "INSERT INTO station_verifier_rosters(origin,generation,replicas)
         VALUES ('https://old-station.example', 1, '[\"a\"]')",
        "INSERT INTO station_integration_policy(binding,checkpoint,recovery_generation,recovery_revision)
         VALUES ('portal','{}',2,1)",
    ] {
        let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        sqlx::query(retained).execute(&db.pool).await.unwrap();
        let first = RecoveryStore::postgres(db.pool.clone());
        let replica = RecoveryStore::postgres(db.reconnect(2).await);
        let (a, b) = tokio::join!(
            first.configure_delegated(ORIGIN, 1),
            replica.configure_delegated(ORIGIN, 1),
        );
        assert!(a.is_err() && b.is_err(), "{retained}");
        let status = inspect(&db.pool, ORIGIN).await.unwrap().unwrap();
        assert_eq!(status.reason, "history_missing");
        assert!(!status.ready);
        drop((first, replica));
        db.cleanup().await;
    }
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_new_origin_recognizes_archived_recovery_evidence() {
    let old = "https://old-station.example";
    let genesis = fixture().log.genesis_hash().to_hex();
    for (evidence, expected_ready) in [
        ("INSERT INTO station_delegated_reporting_history(origin,binding,first_generation,evidence_hash,journal)
          VALUES ($1,'report',1,'saved','{}')", false),
        ("INSERT INTO station_delegated_recovery_plans(origin,generation,genesis_hash,plan_id,candidate_feed_id,source_hash,retained)
          SELECT $1,1,genesis_hash,'plan','candidate','source','{}' FROM remote_recovery_roots", false),
        ("INSERT INTO station_delegated_observed_reservations(origin,account_id,genesis_hash,service_id,key_hash,highest_ms)
          SELECT $1,'account',genesis_hash,'svc-a','key-a',42 FROM remote_recovery_roots", false),
        ("INSERT INTO station_delegated_observed_reservations(origin,account_id,genesis_hash,service_id,key_hash,highest_ms)
          SELECT $1,'account',genesis_hash,'svc-a','key-a',0 FROM remote_recovery_roots", true),
    ] {
        let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
        Binding::new(old, 1).unwrap().initialize(&db.pool, true).await.unwrap();
        sqlx::query("INSERT INTO remote_recovery_roots(genesis_hash,account_subject,state) VALUES ($1,'alice','{}')")
            .bind(&genesis).execute(&db.pool).await.unwrap();
        sqlx::query(evidence).bind(old).execute(&db.pool).await.unwrap();
        let replica = db.reconnect(2).await;
        let new = Binding::new(ORIGIN, 1).unwrap();
        for pool in [&db.pool, &replica] {
            let status = new.initialize(pool, false).await.unwrap();
            assert_eq!(status.ready, expected_ready, "{evidence}");
            assert_eq!(status.reason, if expected_ready { "initialized" } else { "history_missing" });
        }
        replica.close().await;
        db.cleanup().await;
    }
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_bootstrap_distinguishes_registration_from_a_signing_reservation() {
    use crate::service_signing_ceilings::SigningCeilings;
    let signing = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    let writer = SigningCeilings::fixture(signing.pool.clone()).await;
    let genesis = fixture().log.genesis_hash().to_hex();
    let key = "a".repeat(64);
    writer.register_new_key("account", &genesis, "svc-probe", &key).await.unwrap();

    for reserved in [false, true] {
        let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        // Normal Portal polling and service provisioning can predate first activation.
        sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ('portal','{}')")
            .execute(&db.pool).await.unwrap();
        if reserved {
            writer.reserve("account", &genesis, "svc-probe", &key, 0, 1..=2).await.unwrap();
        }
        let store = RecoveryStore::postgres(db.pool.clone());
        let ceilings = SigningCeilings::connect(&db.pool, (*signing.pool.connect_options()).clone())
            .await.unwrap();
        assert!(store.signing_ceilings.set(ceilings).is_ok());
        assert_eq!(store.configure_delegated(ORIGIN, 1).await.is_ok(), !reserved);
        let status = inspect(&db.pool, ORIGIN).await.unwrap().unwrap();
        assert_eq!(status.ready, !reserved);
        assert_eq!(status.reason, if reserved { "history_missing" } else { "initialized" });
        drop(store);
        db.cleanup().await;
    }
    drop(writer);
    signing.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_fence_waits_for_the_write_boundary_and_survives_restart() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 6).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    crate::station_integrations::tests::attach_test_room_owner(&store, ORIGIN).await;
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

fn inspection_portal() -> crate::integration_feed::FeedBinding {
    crate::integration_feed::FeedBinding {
        issuer: "https://auth.example".into(),
        portal_origin: "https://portal.example".into(),
        station_origin: ORIGIN.into(),
        report_client_id: "s-01234567890123456789012345".into(),
    }
}

async fn admit_proxy(store: &RecoveryStore, f: &Fixture, connection: &str) -> HostBinding {
    use crate::cluster::ConnRef;
    use crate::remote_api::recovery::ProxyBinding;
    use atem_client::host_route::{
        host_route_message, sign_host_route_as, HostRouteBody, RouteKind,
    };

    let challenge = HostChallenge::new("phone");
    let proof = host_route_message(
        &sign_host_route_as(
            RouteKind::Proxy,
            &f.keys,
            &f.host_key,
            &HostRouteBody::at(&f.log, "host-a", "host-a", &challenge),
        )
        .unwrap(),
    );
    store
        .admit_proxy(
            &proof.to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new(connection, "proxy-replica"),
            ProxyBinding {
                session: "session".into(),
                generation: "epoch".into(),
                native: ConnRef::new("native", "proxy-replica"),
            },
            "alice",
        )
        .await
        .unwrap().0
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_replacement_feed_requires_new_relay_and_proxy_proofs() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let legacy = admit(&store, &f, "before-delegated").await;
    assert!(saved(&database.pool, &genesis).await["routes"]["host-a"].get("delegated_feed").is_none());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    crate::station_integrations::tests::attach_test_room_owner(&store, ORIGIN).await;
    assert!(!store.prepare_delegated(&legacy).await);
    assert!(store.with_host_route(&legacy, || std::future::ready(())).await.is_some());

    let old_relay = admit(&store, &f, "old-relay").await;
    let old_proxy = admit_proxy(&store, &f, "old-proxy").await;
    let replica = RecoveryStore::postgres(database.reconnect(2).await);
    replica.configure_delegated(ORIGIN, 1).await.unwrap();
    crate::station_integrations::tests::attach_test_room_owner(&replica, ORIGIN).await;
    assert!(replica.prepare_delegated(&old_relay).await);
    assert!(replica.prepare_delegated(&old_proxy).await);

    // Model the committed replacement snapshot without exercising an operator reopen.
    let mut snapshot: Root = serde_json::from_value(saved(&database.pool, &genesis).await).unwrap();
    let previous_id = snapshot.delegated[ORIGIN].feed_id.clone();
    let replacement = Stored::new(ORIGIN, &f.log).unwrap();
    let current_ack = ack(&f, &replacement, 0, json!([]));
    snapshot.delegated.insert(ORIGIN.into(), replacement);
    let before = serde_json::to_value(snapshot).unwrap();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(&before).bind(&genesis).execute(&database.pool).await.unwrap();
    for socket in [&old_relay, &old_proxy] {
        assert!(replica.with_delegated_response(socket, None, |_| std::future::ready(())).await.is_none());
        assert!(!replica.prepare_delegated(socket).await);
        let refused = replica.acknowledge_delegated(socket, current_ack.clone()).await;
        assert_eq!(refused.0, StatusCode::FORBIDDEN);
        assert_eq!(refused.1.0, json!({"type":"relay","op":"control_ack_refused","code":"forbidden"}));
    }
    assert_eq!(saved(&database.pool, &genesis).await, before);

    let new_relay = admit(&store, &f, "new-relay").await;
    let new_proxy = admit_proxy(&store, &f, "new-proxy").await;
    let mut wrong_feed = current_ack.clone();
    wrong_feed.feed_id = previous_id;
    for socket in [&new_relay, &new_proxy] {
        assert!(replica.prepare_delegated(socket).await);
        assert_eq!(replica.acknowledge_delegated(socket, wrong_feed.clone()).await.0, StatusCode::FORBIDDEN);
        assert_eq!(replica.acknowledge_delegated(socket, current_ack.clone()).await.0, StatusCode::OK);
    }
    drop(replica);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_inspection_resolves_proved_route_owners_across_replicas() {
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::integration_feed::PolicyStore;

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let origin = Binding::new(ORIGIN, 1).unwrap();
    let portal = inspection_portal();
    let alice = "ab00000000000000000000000001";
    let bob = "ab00000000000000000000000002";
    sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,'alice'),($1,$3,'bob'),('https://other.example',$2,'legacy-user')")
        .bind(&portal.issuer).bind(alice).bind(bob).execute(&database.pool).await.unwrap();
    admit(&store, &f, "retained-relay").await;
    admit_proxy(&store, &f, "retained-proxy").await;
    // No relay directory, native app or host socket is available to the inspecting replica.
    drop(store);
    let replica = database.reconnect(2).await;
    let inspect = || inspect_root(&replica, &origin, &genesis, Some(&portal));
    let report = inspect().await.unwrap();
    assert_eq!(
        report["root"]["route_ownership"]["last_observed_binding"],
        "unobserved"
    );
    let policies = PolicyStore(database.pool.clone());
    let initial = policies.load(&portal).await.unwrap();
    let mut body = json!({"cursor":0,"changes":[],"checkpoint":{"at":"2026-11-24T10:00:00.000Z",
        "accounts":{"complete":true,"disabled":[]},"bindings":[],"integrations":[]}});
    let exact = |value: &Value| {
        PortalCheckpoint::parse(&serde_json::to_vec(value).unwrap(), &portal).unwrap()
    };
    let mut previous = initial.apply_checkpoint(exact(&body), 1).unwrap();
    policies.commit(&initial, &previous).await.unwrap();
    let snapshot = saved(&database.pool, &genesis).await;
    for (principal, relation, source) in [
        (None, "unregistered", "recovery_root"),
        (Some("alice"), "matches_root", "recovery_root"),
        (Some("legacy-user"), "unresolved", "unresolved"),
        (Some("bob"), "differs_from_root", "unresolved"),
    ] {
        if let Some(principal) = principal {
            sqlx::query(
                "INSERT INTO astation_accounts VALUES ('phone',$1,'test','group',0,0)
                ON CONFLICT(astation_id) DO UPDATE SET agora_user=EXCLUDED.agora_user",
            )
            .bind(principal)
            .execute(&database.pool)
            .await
            .unwrap();
        }
        let report = inspect().await.unwrap();
        let routes = report["root"]["route_ownership"]["retained_routes"]
            .as_array()
            .unwrap();
        assert_eq!(routes.len(), 2);
        for (row, carrier) in routes.iter().zip(["relay", "proxy"]) {
            assert_eq!(
                row,
                &json!({"host_id":"host-a","carrier":carrier,"proof":"verified",
                "registered_room_owner":relation,"owner_source":source})
            );
        }
    }
    for (version, state, account, source) in [
        (1, "bound", alice, "unresolved"),
        (2, "released", alice, "no_bound_owner"),
        (3, "bound", bob, "portal_binding"),
        (4, "unbound", bob, "no_bound_owner"),
    ] {
        body["checkpoint"]["bindings"] = json!([{"account":account,"accountId":f.log.account_id(),
            "genesisHash":genesis,"bindingId":"binding","version":version,"bindingState":state}]);
        let next = previous.apply_checkpoint(exact(&body), 1).unwrap();
        policies.commit(&previous, &next).await.unwrap();
        previous = next;
        let report = inspect().await.unwrap();
        let ownership = &report["root"]["route_ownership"];
        assert_eq!(ownership["last_observed_binding"], state);
        assert_eq!(ownership["binding_version"], version);
        assert_eq!(ownership["binding_matches_root_owner"], account == alice);
        assert_eq!(ownership["retained_routes"][0]["owner_source"], source);
        for private in [alice, bob, "phone", "retained-relay", "retained-proxy"] {
            assert!(!report.to_string().contains(private));
        }
    }
    // A replacement report credential may already know a later binding at
    // the same Portal cursor. The older credential cannot resolve a room.
    let mut rotated = portal.clone();
    rotated.report_client_id = "s-11234567890123456789012345".into();
    let mut prior = policies.load(&rotated).await.unwrap();
    body["checkpoint"]["bindings"][0]["bindingState"] = json!("bound");
    for version in [4, 5] {
        body["checkpoint"]["bindings"][0]["version"] = json!(version);
        let source = PortalCheckpoint::parse(&serde_json::to_vec(&body).unwrap(), &rotated).unwrap();
        let next = prior.apply_checkpoint(source, 1).unwrap();
        policies.commit(&prior, &next).await.unwrap();
        prior = next;
        let report = inspect().await.unwrap();
        let ownership = &report["root"]["route_ownership"];
        assert_eq!(ownership["last_observed_binding"], "superseded_or_conflicting");
        assert!(ownership["binding_matches_root_owner"].is_null());
        assert!(ownership["retained_routes"].as_array().unwrap().iter()
            .all(|row| row["owner_source"] == "unresolved"));
    }
    policies.deny(&rotated).await.unwrap();
    let report = inspect().await.unwrap();
    assert_eq!(report["root"]["route_ownership"]["last_observed_binding"], "superseded_or_conflicting");
    let caught_up = previous.apply_checkpoint(exact(&body), 1).unwrap();
    policies.commit(&previous, &caught_up).await.unwrap();
    let report = inspect().await.unwrap();
    assert_eq!(report["root"]["route_ownership"]["retained_routes"][0]["owner_source"], "portal_binding");
    assert_eq!(saved(&database.pool, &genesis).await, snapshot);
    assert!(
        super::super::super::delegated_recovery::inspect(&replica, ORIGIN)
            .await
            .unwrap()
            .is_none()
    );
    sqlx::query("UPDATE remote_recovery_roots SET state=jsonb_set(state,'{routes,host-a,host_trust_gen}','0') WHERE genesis_hash=$1")
        .bind(&genesis).execute(&database.pool).await.unwrap();
    let report = inspect().await.unwrap();
    assert_eq!(
        report["root"]["route_ownership"]["retained_routes"][0]["proof"],
        "stale"
    );
    assert_eq!(
        report["root"]["route_ownership"]["retained_routes"][1]["proof"],
        "verified"
    );

    // Both routes predate ownership capture. Only the proxy still proves its
    // route, and the migration can run on a different replica with no host online.
    use super::super::super::delegated_recovery::migrate_room_owners;
    let migrate = || migrate_room_owners(&replica, ORIGIN, &portal.issuer, &genesis);
    let source = saved(&database.pool, &genesis).await;
    sqlx::query("CREATE FUNCTION fail_migration() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'migration commit failed'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_migration AFTER INSERT ON station_proved_room_owners DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_migration()")
        .execute(&database.pool).await.unwrap();
    assert!(migrate().await.is_err());
    let count = || sqlx::query_scalar::<_, i64>("SELECT count(*) FROM station_proved_room_owners")
        .fetch_one(&database.pool);
    assert_eq!(count().await.unwrap(), 0);
    sqlx::query("DROP TRIGGER fail_migration ON station_proved_room_owners")
        .execute(&database.pool).await.unwrap();
    let migrated = json!({"proved_rooms":1,"with_registration_evidence":1,
        "disputed":0,"without_registration_evidence":0,"stale_routes":1});
    assert_eq!(migrate().await.unwrap(), migrated);
    assert_eq!(migrate().await.unwrap(), migrated);
    assert_eq!(count().await.unwrap(), 1);
    assert_eq!(saved(&database.pool, &genesis).await, source);
    assert!(migrate_room_owners(&replica, "https://custom.example", &portal.issuer, &genesis).await.is_err());
    sqlx::query("UPDATE astation_accounts SET agora_user='alice' WHERE astation_id='phone'")
        .execute(&database.pool).await.unwrap();
    assert_eq!(migrate().await.unwrap()["disputed"], 1);
    assert_eq!(migrate().await.unwrap()["with_registration_evidence"], 0);

    replica.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_inspection_resolves_session_rooms_without_extending_bindings() {
    use crate::cluster::ConnRef;
    use crate::identity_store::{
        IdentityStore, PgIdentityStore, BINDING_TOUCH_INTERVAL_SECS, BINDING_TTL_SECS,
    };
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::integration_feed::PolicyStore;

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let origin = Binding::new(ORIGIN, 1).unwrap();
    let portal = inspection_portal();
    let alice = "ab00000000000000000000000001";
    let bob = "ab00000000000000000000000002";
    sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,'alice'),($1,$3,'bob')")
        .bind(&portal.issuer).bind(alice).bind(bob).execute(&database.pool).await.unwrap();

    let session = crate::auth::create_session("bootstrap-host");
    let room = format!("session-{}", session.id);
    let challenge = HostChallenge::new(&room);
    let relay_proof = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a");
    store
        .admit_host(
            &relay_proof.to_string(),
            challenge.nonce,
            &room,
            "host-a",
            ConnRef::new("bootstrap-relay", "other-replica"),
        )
        .await
        .unwrap();
    drop(store);
    let replica = database.reconnect(2).await;
    let session_route = || async {
        inspect_root(&replica, &origin, &genesis, Some(&portal))
            .await
            .unwrap()["root"]["route_ownership"]["retained_routes"][0]
            .clone()
    };
    let policies = PolicyStore(database.pool.clone());
    let initial = policies.load(&portal).await.unwrap();
    let mut body = json!({"cursor":0,"changes":[],"checkpoint":{"at":"2026-11-24T10:00:00.000Z",
        "accounts":{"complete":true,"disabled":[]},"bindings":[],"integrations":[]}});
    let exact = |body: &Value| {
        PortalCheckpoint::parse(&serde_json::to_vec(body).unwrap(), &portal).unwrap()
    };
    let unbound = initial.apply_checkpoint(exact(&body), 1).unwrap();
    policies.commit(&initial, &unbound).await.unwrap();
    let missing = session_route().await;
    assert_eq!(missing["owner_source"], "unresolved");
    assert_eq!(missing["session_binding"], "missing");

    let identity = PgIdentityStore::new(database.pool.clone());
    let now = chrono::Utc::now().timestamp();
    let last_used = now - BINDING_TOUCH_INTERVAL_SECS - 30;
    identity
        .bind(&session.id, "phone", last_used)
        .await
        .unwrap();
    let unmapped = session_route().await;
    assert_eq!(unmapped["owner_source"], "unresolved");
    assert_eq!(unmapped["session_binding"], "unresolved");
    sqlx::query("INSERT INTO astation_accounts VALUES ('phone','alice','test','group',0,0)")
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(session_route().await["owner_source"], "recovery_root");

    body["checkpoint"]["bindings"] = json!([{"account":bob,"accountId":f.log.account_id(),
        "genesisHash":genesis,"bindingId":"binding","version":1,"bindingState":"bound"}]);
    let next = unbound.apply_checkpoint(exact(&body), 1).unwrap();
    policies.commit(&unbound, &next).await.unwrap();
    assert_eq!(session_route().await["owner_source"], "unresolved");

    sqlx::query("UPDATE astation_accounts SET agora_user='bob' WHERE astation_id='phone'")
        .execute(&database.pool)
        .await
        .unwrap();
    for (timestamp, binding_status, source) in [
        (now - BINDING_TTL_SECS, "expired", "unresolved"),
        (last_used, "current", "portal_binding"),
    ] {
        identity
            .bind(&session.id, "phone", timestamp)
            .await
            .unwrap();
        let row = session_route().await;
        assert_eq!(row["session_binding"], binding_status);
        assert_eq!(row["owner_source"], source);
        let retained: i64 =
            sqlx::query_scalar("SELECT last_used_at FROM session_bindings WHERE session_id=$1")
                .bind(&session.id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(retained, timestamp);
        assert!(!row.to_string().contains(&session.id));
    }
    // A literal room registration cannot supersede the bound session owner.
    sqlx::query("INSERT INTO astation_accounts VALUES ($1,'alice','test','group',0,0)")
        .bind(&room)
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(session_route().await["owner_source"], "unresolved");
    identity.unbind(&session.id, "phone").await.unwrap();
    let missing = session_route().await;
    assert_eq!(missing["session_binding"], "missing");
    assert_eq!(missing["owner_source"], "unresolved");
    replica.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_proved_session_owner_survives_expiry_and_refuses_reassignment() {
    use crate::cluster::ConnRef;
    use crate::identity_store::{IdentityStore, PgIdentityStore, BINDING_TTL_SECS};
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::integration_feed::PolicyStore;

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let portal = inspection_portal();
    let built_in = |pool| RecoveryStore::postgres_for_station(
        pool, Some(ORIGIN), Some(ORIGIN), Some(&portal.issuer),
    );
    let store = built_in(database.pool.clone());
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let account = "ab00000000000000000000000001";
    let other = "ab00000000000000000000000002";
    sqlx::query("INSERT INTO account_identities VALUES ($1,$2,'alice'),($1,$3,'bob')")
        .bind(&portal.issuer)
        .bind(account)
        .bind(other)
        .execute(&database.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO astation_accounts VALUES ('phone','alice','test','group',0,0)")
        .execute(&database.pool)
        .await
        .unwrap();
    let policies = PolicyStore(database.pool.clone());
    let initial = policies.load(&portal).await.unwrap();
    let body = json!({"cursor":0,"changes":[],"checkpoint":{"at":"2026-11-24T10:00:00.000Z",
        "accounts":{"complete":true,"disabled":[]},"bindings":[],"integrations":[]}});
    let cut = PortalCheckpoint::parse(&serde_json::to_vec(&body).unwrap(), &portal).unwrap();
    policies
        .commit(&initial, &initial.apply_checkpoint(cut, 1).unwrap())
        .await
        .unwrap();

    let session = crate::auth::create_session("local-test-host");
    let identity = PgIdentityStore::new(database.pool.clone());
    let now = chrono::Utc::now().timestamp();
    identity.bind(&session.id, "phone", now).await.unwrap();
    let room = format!("session-{}", session.id);
    let challenge = HostChallenge::new(&room);
    let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
    let replica = database.reconnect(3).await;
    let count = || {
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM station_proved_room_owners")
            .fetch_one(&replica)
    };
    assert!(store
        .admit_host(
            &message,
            [0; 32],
            &room,
            "host-a",
            ConnRef::new("bad", "local")
        )
        .await
        .is_err());
    assert_eq!(count().await.unwrap(), 0);

    for (origin, audience, issuer) in [
        ("https://custom.example", "https://custom.example", portal.issuer.as_str()),
        (ORIGIN, "https://station.agora.build", portal.issuer.as_str()),
        (ORIGIN, ORIGIN, "https://other-issuer.example"),
    ] {
        let independent = RecoveryStore::postgres_for_station(
            replica.clone(), Some(origin), Some(audience), Some(issuer),
        );
        independent.admit_host(&message, challenge.nonce, &room, "host-a",
            ConnRef::new("independent", "local")).await.unwrap();
        assert_eq!(count().await.unwrap(), 0);
    }

    // A failed route commit cannot leave behind ownership evidence.
    sqlx::query("CREATE FUNCTION fail_route() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'route commit failed'; END $$")
        .execute(&replica).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_route AFTER UPDATE ON remote_recovery_roots DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_route()")
        .execute(&replica).await.unwrap();
    assert!(store
        .admit_host(
            &message,
            challenge.nonce,
            &room,
            "host-a",
            ConnRef::new("failed", "local")
        )
        .await
        .is_err());
    assert_eq!(count().await.unwrap(), 0);
    sqlx::query("DROP TRIGGER fail_route ON remote_recovery_roots")
        .execute(&replica)
        .await
        .unwrap();

    store
        .admit_host(
            &message,
            challenge.nonce,
            &room,
            "host-a",
            ConnRef::new("accepted", "local"),
        )
        .await
        .unwrap();
    drop(store);
    assert_eq!(count().await.unwrap(), 1);
    let origin = Binding::new(ORIGIN, 1).unwrap();
    let route = || async {
        inspect_root(&replica, &origin, &genesis, Some(&portal))
            .await
            .unwrap()["root"]["route_ownership"]["retained_routes"][0]
            .clone()
    };
    identity
        .bind(&session.id, "phone", now - BINDING_TTL_SECS)
        .await
        .unwrap();
    let expired = route().await;
    assert_eq!(expired["session_binding"], "expired");
    assert_eq!(expired["owner_source"], "retained_session");
    identity.unbind(&session.id, "phone").await.unwrap();
    let missing = route().await;
    assert_eq!(missing["session_binding"], "missing");
    assert_eq!(missing["owner_source"], "retained_session");
    assert!(!missing.to_string().contains(account));

    // A new proof through a different account cannot silently transfer ownership.
    sqlx::query("UPDATE astation_accounts SET agora_user='bob' WHERE astation_id='phone'")
        .execute(&replica)
        .await
        .unwrap();
    identity.bind(&session.id, "phone", now).await.unwrap();
    assert_eq!(route().await["owner_source"], "unresolved");
    let restarted = built_in(replica.clone());
    let challenge = HostChallenge::new(&room);
    let fresh = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
    restarted
        .admit_host(
            &fresh,
            challenge.nonce,
            &room,
            "host-a",
            ConnRef::new("reconnect", "other"),
        )
        .await
        .unwrap();
    identity.unbind(&session.id, "phone").await.unwrap();
    assert_eq!(route().await["owner_source"], "unresolved");
    let first: (String, bool) =
        sqlx::query_as("SELECT account_subject,conflicted FROM station_proved_room_owners")
            .fetch_one(&replica)
            .await
            .unwrap();
    assert_eq!(first, (account.to_owned(), true));

    // An identity room has no session binding. Its registration at proof time
    // still prevents migration to the root's owner if that registration goes away.
    admit(&restarted, &f, "identity-room").await;
    sqlx::query("DELETE FROM astation_accounts WHERE astation_id='phone'")
        .execute(&replica).await.unwrap();
    let room = route().await;
    assert_eq!(room["registered_room_owner"], "unregistered");
    assert_eq!(room["owner_source"], "unresolved");
    assert!(room.get("session_binding").is_none());
    drop(restarted);
    replica.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_registration_preserves_previously_proved_session_room() {
    use crate::account_store::{AccountStore, PgAccountStore};
    use crate::cluster::ConnRef;
    use crate::identity_store::{IdentityStore, PgIdentityStore};

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let portal = inspection_portal();
    let store = RecoveryStore::postgres_for_station(
        database.pool.clone(),
        Some(ORIGIN),
        Some(ORIGIN),
        Some(&portal.issuer),
    );
    let f = fixture();
    f.publish(&store).await;
    let session = crate::auth::create_session("local-host");
    let room = format!("session-{}", session.id);
    let identity = PgIdentityStore::new(database.pool.clone());
    let now = chrono::Utc::now().timestamp();
    identity.bind(&session.id, "phone", now).await.unwrap();
    let challenge = HostChallenge::new(&room);
    let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
    store
        .admit_host(
            &message,
            challenge.nonce,
            &room,
            "host-a",
            ConnRef::new("host", "replica-a"),
        )
        .await
        .unwrap();
    drop(store);
    let replica = database.reconnect(2).await;
    // A pre-index deployment retains the same proof in its recovery root.
    sqlx::query("DELETE FROM station_room_proofs")
        .execute(&replica)
        .await
        .unwrap();
    let backfill = super::super::super::delegated_recovery::migrate_room_owners(
        &replica,
        ORIGIN,
        &portal.issuer,
        &f.log.genesis_hash().to_hex(),
    )
    .await
    .unwrap();
    assert_eq!(backfill["without_registration_evidence"], 1);
    let account = "ab00000000000000000000000001";
    sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,'alice')")
        .bind(&portal.issuer)
        .bind(account)
        .execute(&replica)
        .await
        .unwrap();
    let accounts = PgAccountStore::for_station(
        replica.clone(),
        Some((ORIGIN.into(), portal.issuer.clone())),
    );
    // Lose the transaction at commit, then retry on the same retained proof.
    sqlx::query("CREATE FUNCTION fail_observation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit failed'; END $$")
        .execute(&replica).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_observation AFTER INSERT ON station_proved_room_owners DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_observation()")
        .execute(&replica).await.unwrap();
    assert!(accounts
        .register("phone", "alice", "Phone", now)
        .await
        .is_err());
    assert_eq!(accounts.subject_for_astation("phone").await.unwrap(), None);
    sqlx::query("DROP TRIGGER fail_observation ON station_proved_room_owners")
        .execute(&replica)
        .await
        .unwrap();
    accounts
        .register("phone", "alice", "Phone", now)
        .await
        .unwrap();
    identity.unbind(&session.id, "phone").await.unwrap();

    let retained: Option<(String, bool)> = sqlx::query_as(
        "SELECT account_subject,conflicted FROM station_proved_room_owners
         WHERE station_origin=$1 AND issuer=$2 AND genesis_hash=$3 AND room=$4",
    )
    .bind(ORIGIN)
    .bind(&portal.issuer)
    .bind(f.log.genesis_hash().to_hex())
    .bind(&room)
    .fetch_optional(&database.pool)
    .await
    .unwrap();
    assert_eq!(retained, Some((account.to_string(), false)));
    replica.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_session_bind_and_resync_capture_only_current_scoped_proofs() {
    use crate::account_store::{AccountStore, PgAccountStore};
    use crate::cluster::ConnRef;
    use crate::identity_store::{IdentityStore, PgIdentityStore, BINDING_TTL_SECS};

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let portal = inspection_portal();
    let f = fixture();
    let store = RecoveryStore::postgres_for_station(
        database.pool.clone(),
        Some(ORIGIN),
        Some(ORIGIN),
        Some(&portal.issuer),
    );
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    let alice = "ab00000000000000000000000001";
    sqlx::query("INSERT INTO account_identities VALUES ($1,$2,'alice')")
        .bind(&portal.issuer)
        .bind(alice)
        .execute(&database.pool)
        .await
        .unwrap();
    let replica = database.reconnect(3).await;
    let scope = Some((ORIGIN.into(), portal.issuer.clone()));
    let accounts = PgAccountStore::for_station(replica.clone(), scope.clone());
    let identity = PgIdentityStore::for_station(replica.clone(), scope);
    let now = chrono::Utc::now().timestamp();
    accounts
        .register("phone", "alice", "Phone", now)
        .await
        .unwrap();
    let count = || {
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM station_proved_room_owners")
            .fetch_one(&replica)
    };

    for (index, session) in (0..2).map(|i| (i, crate::auth::create_session("local-host"))) {
        let room = format!("session-{}", session.id);
        let challenge = HostChallenge::new(&room);
        let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
        store
            .admit_host(
                &message,
                challenge.nonce,
                &room,
                "host-a",
                ConnRef::new("host", "replica-a"),
            )
            .await
            .unwrap();
        let saved = saved(&replica, &genesis).await;
        let current_count = count().await.unwrap();
        for scope in [
            None,
            Some((ORIGIN.into(), "https://other.example".into())),
            Some(("https://station.agora.build".into(), portal.issuer.clone())),
        ] {
            let other = PgIdentityStore::for_station(replica.clone(), scope);
            other.bind(&session.id, "phone", now).await.unwrap();
            assert_eq!(count().await.unwrap(), current_count);
            other.unbind(&session.id, "phone").await.unwrap();
        }

        identity
            .bind(&session.id, "phone", now - BINDING_TTL_SECS)
            .await
            .unwrap();
        assert_eq!(count().await.unwrap(), current_count);
        sqlx::query("UPDATE remote_recovery_roots SET state=jsonb_set(state,'{routes,host-a,host_trust_gen}','0') WHERE genesis_hash=$1")
            .bind(&genesis).execute(&replica).await.unwrap();
        identity.bind(&session.id, "phone", now).await.unwrap();
        assert_eq!(count().await.unwrap(), current_count);
        sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
            .bind(&saved)
            .bind(&genesis)
            .execute(&replica)
            .await
            .unwrap();

        if index == 0 {
            identity.bind(&session.id, "phone", now).await.unwrap();
        } else {
            identity
                .replace_all("phone", std::slice::from_ref(&session.id), now)
                .await
                .unwrap();
        }
        assert_eq!(count().await.unwrap(), current_count + 1);
        identity.unbind(&session.id, "phone").await.unwrap();
    }
    let indexed: i64 = sqlx::query_scalar("SELECT count(*) FROM station_room_proofs")
        .fetch_one(&replica)
        .await
        .unwrap();
    assert_eq!(indexed, 1, "a replacement route replaces its index entry");
    replica.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_concurrent_proof_and_registration_retain_identity_room_owner() {
    use crate::account_store::{AccountStore, PgAccountStore};
    use crate::cluster::ConnRef;
    use std::time::Duration;

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let portal = inspection_portal();
    let f = fixture();
    let store = RecoveryStore::postgres_for_station(
        database.pool.clone(),
        Some(ORIGIN),
        Some(ORIGIN),
        Some(&portal.issuer),
    );
    f.publish(&store).await;
    let subject = "ab00000000000000000000000001";
    sqlx::query("INSERT INTO account_identities VALUES ($1,$2,'alice')")
        .bind(&portal.issuer)
        .bind(subject)
        .execute(&database.pool)
        .await
        .unwrap();
    let replica = database.reconnect(2).await;
    let accounts =
        PgAccountStore::for_station(replica.clone(), Some((ORIGIN.into(), portal.issuer)));
    let room = "phone";
    let challenge = HostChallenge::new(room);
    let message = proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string();
    let mut gate = database.pool.begin().await.unwrap();
    let blocker: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *gate)
        .await
        .unwrap();
    super::super::super::delegated_recovery::route_ownership::lock_rooms(&mut gate, &[room])
        .await
        .unwrap();
    let host = tokio::spawn(async move {
        store
            .admit_host(
                &message,
                challenge.nonce,
                room,
                "host-a",
                ConnRef::new("host", "first"),
            )
            .await
            .unwrap();
    });
    let signin = tokio::spawn(async move {
        accounts
            .register(room, "alice", "Phone", chrono::Utc::now().timestamp())
            .await
            .unwrap();
    });
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let waiting: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM pg_locks waiter JOIN pg_locks owner USING (locktype,database,classid,objid,objsubid)
                 WHERE owner.pid=$1 AND owner.locktype='advisory' AND owner.granted AND NOT waiter.granted",
            ).bind(blocker).fetch_one(&database.pool).await.unwrap();
            if waiting == 2 { break; }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("both replicas must queue on the same room");
    gate.commit().await.unwrap();
    host.await.unwrap();
    signin.await.unwrap();
    let retained: (String, bool) =
        sqlx::query_as("SELECT account_subject,conflicted FROM station_proved_room_owners")
            .fetch_one(&replica)
            .await
            .unwrap();
    assert_eq!(retained, (subject.into(), false));
    replica.close().await;
    database.cleanup().await;
}
