use super::{
    tests::{feed, policy},
    *,
};
use crate::{
    remote_api::recovery::delegated_recovery::{plan, Binding},
    service_signing_ceilings::SigningCeilings,
    station_integrations::tests::{
        append_body, fixture_with_ceiling_cluster, request, ID, OWNER, PRINCIPAL,
    },
    test_database::TestDatabase,
};

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_list_roots_finds_entire_missing_lists_across_pages() {
    use crate::remote_api::recovery::delegated_recovery::list_roots;

    let primary = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    let signing = SigningCeilings::fixture(external.pool.clone()).await;
    let fence = Binding::new("https://station.example", 1).unwrap();
    fence.initialize(&primary.pool, false).await.unwrap();
    assert!(list_roots(&primary.pool, &fence, &signing, None, None).await.is_err());
    fence.initialize(&primary.pool, true).await.unwrap();
    let empty = list_roots(&primary.pool, &fence, &signing, None, None).await.unwrap();
    assert_eq!(empty["roots"], json!([]));
    assert!(empty["next_after"].is_null());

    // Retained only, signing store only, and shared. Unused registrations are evidence too.
    sqlx::query("INSERT INTO remote_recovery_roots(genesis_hash,account_subject,state)
                 SELECT lpad(to_hex(i),64,'0'),'owner','{}'::jsonb
                 FROM generate_series(1,96) i WHERE i % 3 <> 1")
        .execute(&primary.pool).await.unwrap();
    sqlx::query("INSERT INTO station_service_signing_ceilings(account_id,genesis_hash,service_id,key_hash)
                 SELECT 'account',lpad(to_hex(i),64,'0'),'service','key'
                 FROM generate_series(1,96) i WHERE i % 3 <> 0")
        .execute(&external.pool).await.unwrap();
    let hash = |i: u32| format!("{i:064x}");
    signing.register_new_key("account", &hash(64), "other", "key").await.unwrap();
    signing.reserve("account", &hash(64), "other", "key", 0, 1..=2).await.unwrap();
    let replica = primary.reconnect(2).await;
    let first = list_roots(&primary.pool, &fence, &signing, None, None).await.unwrap();
    assert_eq!(first["next_after"], hash(64));
    assert_eq!(first["roots"].as_array().unwrap().len(), 64);
    assert_eq!(first["roots"][63], json!({"genesis_hash":hash(64),"root_present":false,
        "registered_keys":2,"keys_with_reservations":1}));
    assert_eq!(list_roots(&replica, &fence, &signing, None, None).await.unwrap(), first);
    let second = list_roots(&replica, &fence, &signing, None, first["next_after"].as_str()).await.unwrap();
    assert!(second["next_after"].is_null());
    let rows: Vec<_> = [&first, &second].into_iter()
        .flat_map(|page| page["roots"].as_array().unwrap()).collect();
    assert_eq!(rows.len(), 96);
    for (i, row) in (1..=96).zip(rows) {
        assert_eq!(row["genesis_hash"], hash(i));
        assert_eq!(row["root_present"], i % 3 != 1);
        assert_eq!(row["registered_keys"].as_i64(), Some(if i == 64 { 2 } else { i64::from(i % 3 != 0) }));
        assert_eq!(row["keys_with_reservations"].as_i64(), Some(i64::from(i == 64)));
    }
    // Exactly one full remaining page must have no continuation.
    let exact = list_roots(&replica, &fence, &signing, None, Some(&hash(32))).await.unwrap();
    assert_eq!(exact["roots"].as_array().unwrap().len(), 64);
    assert!(exact["next_after"].is_null());
    let newer = Binding::new(&fence.origin, 2).unwrap();
    newer.initialize(&primary.pool, true).await.unwrap();
    assert!(list_roots(&replica, &fence, &signing, None, Some(&hash(64))).await.is_err());
    sqlx::query("DROP TABLE station_service_signing_ceilings").execute(&external.pool).await.unwrap();
    assert!(list_roots(&replica, &newer, &signing, None, None).await.is_err());
    replica.close().await;
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_inventory_finds_interrupted_and_orphaned_service_keys() {
    use crate::remote_api::recovery::delegated_recovery::list_roots;
    use crate::station_integrations::tests::fixture_at_station;

    for origin in ["https://custom.example", "https://station-dev.agora.build"] {
        let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
        sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
            .execute(&external.pool)
            .await
            .unwrap();
        let (primary, runtime, fixture) =
            fixture_at_station("https://auth.example", Some(&external.pool), origin).await;
        let genesis = fixture.log.genesis_hash().to_hex();
        let store = runtime.app.recovery.signing_ceilings.get().unwrap();
        sqlx::raw_sql(
            "CREATE FUNCTION refuse_registration() RETURNS trigger LANGUAGE plpgsql AS $$
               BEGIN RAISE EXCEPTION 'test failure'; END $$;
            CREATE TRIGGER fail_registration BEFORE INSERT ON station_service_signing_ceilings
            FOR EACH ROW EXECUTE FUNCTION refuse_registration()",
        )
        .execute(&external.pool)
        .await
        .unwrap();
        assert!(runtime.prepare(ID, OWNER, request(&fixture)).await.is_err());
        let pending: (i64, i64) = sqlx::query_as(
            "SELECT
            (SELECT count(*) FROM station_integration_provisioning WHERE fingerprint IS NULL),
            (SELECT count(*) FROM station_service_keys)",
        )
        .fetch_one(&primary.pool)
        .await
        .unwrap();
        assert_eq!(pending, (1, 0));
        let fence = Binding::new(origin, 2).unwrap();
        fence.initialize(&primary.pool, true).await.unwrap();
        let replica = primary.reconnect(1).await;
        // Simulate a restore that retained the provisioning intent and lost the signed list.
        let state: (String, Value) = sqlx::query_as(
            "DELETE FROM remote_recovery_roots
            WHERE genesis_hash=$1 RETURNING account_subject,state",
        )
        .bind(&genesis)
        .fetch_one(&primary.pool)
        .await
        .unwrap();
        let rotated = crate::integration_feed::FeedBinding {
            report_client_id: format!("s-{}", "3".repeat(26)),
            ..runtime.binding.clone()
        };
        let missing = json!([{"genesis_hash":genesis,"root_present":false,
            "registered_keys":0,"keys_with_reservations":0}]);
        assert_eq!(
            list_roots(&replica, &fence, store, Some(&rotated), None)
                .await
                .unwrap()["roots"],
            missing
        );
        let foreign = crate::integration_feed::FeedBinding {
            portal_origin: "https://different-portal.example".into(),
            ..rotated.clone()
        };
        assert_eq!(
            list_roots(&replica, &fence, store, Some(&foreign), None)
                .await
                .unwrap()["roots"],
            json!([])
        );
        sqlx::query("INSERT INTO remote_recovery_roots(genesis_hash,account_subject,state) VALUES ($1,$2,$3)")
            .bind(&genesis).bind(&state.0).bind(&state.1).execute(&primary.pool).await.unwrap();
        sqlx::query("DROP TRIGGER fail_registration ON station_service_signing_ceilings")
            .execute(&external.pool)
            .await
            .unwrap();
        runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
        sqlx::raw_sql(
            "DELETE FROM remote_recovery_roots; DELETE FROM station_integration_provisioning",
        )
        .execute(&primary.pool)
        .await
        .unwrap();
        sqlx::query("DELETE FROM station_service_signing_ceilings")
            .execute(&external.pool)
            .await
            .unwrap();
        assert_eq!(
            list_roots(&replica, &fence, store, Some(&rotated), None)
                .await
                .unwrap()["roots"],
            missing
        );
        let other_issuer = crate::integration_feed::FeedBinding {
            issuer: "https://different-auth.example".into(),
            ..rotated
        };
        assert_eq!(
            list_roots(&replica, &fence, store, Some(&other_issuer), None)
                .await
                .unwrap()["roots"],
            json!([])
        );
        drop(runtime);
        replica.close().await;
        primary.cleanup().await;
        external.cleanup().await;
    }
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_signing_checks_recovery_observations_before_reserving() {
    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql")).execute(&external.pool).await.unwrap();
    let (primary, runtime, fixture) =
        fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let account = fixture.log.account_id();
    let origin = &runtime.binding.station_origin;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    let key = draft["fingerprint"].as_str().unwrap();
    let service = format!("svc-{ID}");
    append_body(&runtime, &fixture, serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap()).await;
    policy(&runtime, "paused", key, None).await;
    assert_eq!(
        recovery.delegated_operation(&genesis, PRINCIPAL, Command::Ensure).await.0,
        StatusCode::OK
    );
    let store = recovery.signing_ceilings.get().unwrap();
    store.reserve(account, &genesis, &service, key, 0, 1..=2).await.unwrap();

    let fence = Binding::new(origin, 1).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();
    plan::prepare_with_sources(&primary.pool, &fence, &genesis, Some(store), None, None).await.unwrap();
    // Exercise the normal signer with a reopened test fence and an older or
    // replaced independent cluster. There is no production reopen operation yet.
    sqlx::query("UPDATE station_delegated_recovery SET ready=true WHERE origin=$1")
        .bind(origin).execute(&primary.pool).await.unwrap();
    sqlx::query("TRUNCATE station_service_signing_ceilings").execute(&external.pool).await.unwrap();
    store.register_new_key(account, &genesis, &service, key).await.unwrap();
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert_eq!(store.reservations(account, &genesis).await.unwrap()[0].highest_ms, 0);
    assert!(feed(&runtime, &genesis).await.is_empty());
    store.reserve(account, &genesis, &service, key, 0, 1..=2).await.unwrap();
    sqlx::query("UPDATE station_delegated_observed_reservations SET key_hash=$1 WHERE genesis_hash=$2")
        .bind("f".repeat(64)).bind(&genesis).execute(&primary.pool).await.unwrap();
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert_eq!(store.reservations(account, &genesis).await.unwrap()[0].highest_ms, 2);
    assert!(feed(&runtime, &genesis).await.is_empty());
    sqlx::query("UPDATE station_delegated_observed_reservations SET key_hash=$1 WHERE genesis_hash=$2")
        .bind(key).bind(&genesis).execute(&primary.pool).await.unwrap();
    runtime.reconcile_delegated_service(ID).await.unwrap();
    assert_eq!(feed(&runtime, &genesis).await.len(), 2);
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_external_reservation_survives_failed_commit_and_primary_restore() {
    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 4).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
        .execute(&external.pool)
        .await
        .unwrap();
    let (primary, runtime, fixture) =
        fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let account = fixture.log.account_id();
    let genesis = fixture.log.genesis_hash().to_hex();
    let origin = &runtime.binding.station_origin;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    append_body(
        &runtime,
        &fixture,
        serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
    )
    .await;
    policy(
        &runtime,
        "paused",
        draft["fingerprint"].as_str().unwrap(),
        None,
    )
    .await;
    assert_eq!(
        recovery
            .delegated_operation(&genesis, PRINCIPAL, Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    let before: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&genesis)
            .fetch_one(&primary.pool)
            .await
            .unwrap();
    let replica =
        SigningCeilings::connect(&primary.pool, (*external.pool.connect_options()).clone())
            .await
            .unwrap();
    replica.check_access().await.unwrap();
    let initial = replica.reservations(account, &genesis).await.unwrap();
    assert_eq!(initial.len(), 1);
    let registration = &initial[0];
    assert_eq!(registration.highest_ms, 0);
    let service = &registration.service_id;
    let key = &registration.key_hash;
    let mut changes = recovery.delegated_changes();
    sqlx::query("CREATE FUNCTION fail_publish() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fail commit'; END $$")
        .execute(&primary.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_publish AFTER UPDATE ON remote_recovery_roots DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_publish()")
        .execute(&primary.pool).await.unwrap();
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert!(!changes.has_changed().unwrap());
    assert!(feed(&runtime, &genesis).await.is_empty());
    let burned = replica.reservations(account, &genesis).await.unwrap()[0].highest_ms as u64;
    assert!(burned > 0);
    assert!(replica
        .reserve(account, &genesis, service, key, 0, burned..=burned + 1)
        .await
        .is_err());
    sqlx::query("DROP TRIGGER fail_publish ON remote_recovery_roots")
        .execute(&primary.pool)
        .await
        .unwrap();
    runtime.reconcile_delegated_service(ID).await.unwrap();
    assert!(changes.has_changed().unwrap());
    changes.borrow_and_update();
    let records = feed(&runtime, &genesis).await;
    assert_eq!(records.len(), 2);
    let last = replica.reservations(account, &genesis).await.unwrap()[0].highest_ms as u64;
    assert!(last >= burned + 2);
    runtime.reconcile_delegated_service(ID).await.unwrap();
    assert!(!changes.has_changed().unwrap());
    assert_eq!(
        replica.reservations(account, &genesis).await.unwrap()[0].highest_ms as u64,
        last
    );

    // Restore the exact root from before either publication. Independent pools race
    // for one range; a simulated clock rollback then reaches the real signer.
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&before)
        .execute(&primary.pool)
        .await
        .unwrap();
    let future = chrono::Utc::now().timestamp_millis() as u64 + 60_000;
    let first = recovery.signing_ceilings.get().unwrap();
    let (a, b) = tokio::join!(
        first.reserve(account, &genesis, service, key, last, last + 1..=future),
        replica.reserve(account, &genesis, service, key, last, last + 1..=future)
    );
    assert_ne!(a.is_ok(), b.is_ok());
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert!(feed(&runtime, &genesis).await.is_empty());
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();
    let review = plan::prepare_with_sources(&primary.pool, &fence, &genesis, Some(&replica), None, None)
        .await
        .unwrap();
    assert_eq!(
        review["service_clock_evidence"]["reservations"][0]["highest_ms"],
        future
    );
    let principal = format!("service:{service}");
    let mark = &review["service_clock_evidence"]["snapshot_signing_marks"][&principal];
    assert_eq!(mark, &json!({"key_fingerprint":key,"highest_reserved_ms":future,"sign_above_ms":future}));
    // An authenticated native stop can raise the host floor above the service
    // key's external ceiling. A replacement cover must clear both.
    let mut higher_anchor = review.clone();
    higher_anchor["recovery_signatures"]["observed_signing_lower_bounds"][&principal] = (future + 10).into();
    higher_anchor["known_history"]["observed_signing_lower_bounds"][&principal] = (future + 1).into();
    let registrations = replica.reservations(account, &genesis).await.unwrap();
    let adjusted = SigningCeilings::recovery_evidence(&registrations, &[], &higher_anchor).unwrap();
    assert_eq!(adjusted["snapshot_signing_marks"][&principal]["sign_above_ms"], future + 10);
    assert_eq!(review["recovery_ready"], false);
    assert!(replica
        .reservations("other-account", &genesis)
        .await
        .unwrap()
        .is_empty());
    assert!(replica
        .reserve(
            account,
            &genesis,
            service,
            "legacy-key",
            last,
            future + 1..=future + 1
        )
        .await
        .is_err());
    // A failed provisioning transaction can leave an unused registration. It
    // cannot become a second signed history for this service.
    replica
        .register_new_key(account, &genesis, service, "orphan")
        .await
        .unwrap();
    assert!(replica
        .reserve(
            account,
            &genesis,
            service,
            "orphan",
            last,
            future + 1..=future + 1
        )
        .await
        .is_err());
    // Install the same schema at the primary alias: rejecting this read must
    // depend on the cluster identity, not a missing table or wrong password.
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
        .execute(&primary.pool)
        .await
        .unwrap();
    let alias = SigningCeilings::connect(&primary.pool, (*primary.pool.connect_options()).clone())
        .await
        .unwrap();
    assert!(alias.reservations(account, &genesis).await.is_err());
    // Loss of a registration cannot turn a retained membership key into an
    // unused one. A recovery inspection explicitly lists the missing key.
    sqlx::query("DELETE FROM station_service_signing_ceilings WHERE key_hash=$1")
        .bind(key)
        .execute(&external.pool)
        .await
        .unwrap();
    let missing = plan::prepare_with_sources(&primary.pool, &fence, &genesis, Some(&replica), None, None)
        .await
        .unwrap();
    assert_eq!(
        missing["service_clock_evidence"]["unregistered_membership_keys"],
        json!([[service, key]])
    );
    let observed_floor = json!({"service_id":service,"key_hash":key,"highest_ms":future});
    assert_eq!(
        missing["service_clock_evidence"]["reservation_shortfalls"],
        json!([observed_floor])
    );
    // Simulate restoring the signing database to its original registration.
    // The observed reservation never appeared in the restored feed.
    replica.register_new_key(account, &genesis, service, key).await.unwrap();
    let next = Binding::new(origin, 3).unwrap();
    next.initialize(&primary.pool, true).await.unwrap();
    let restarted = primary.reconnect(2).await;
    let lower = plan::prepare_with_sources(&restarted, &next, &genesis, Some(&replica), None, None)
        .await.unwrap();
    assert_eq!(lower["service_clock_evidence"]["reservation_shortfalls"], json!([observed_floor]));
    assert_eq!(lower["service_clock_evidence"]["snapshot_signing_marks"], json!({}));
    let offline = plan::prepare_with_sources(&restarted, &next, &genesis, None, None, None)
        .await.unwrap();
    assert_eq!(offline["service_clock_evidence"]["status"], "signing_store_unconfigured");
    assert!(offline["service_clock_evidence"]["observed_reservations"].as_array().unwrap().contains(&observed_floor));
    assert_eq!(offline["recovery_ready"], false);
    restarted.close().await;
    assert_ne!(
        missing["service_clock_evidence_hash"],
        review["service_clock_evidence_hash"]
    );
    assert!(replica
        .reserve(
            account,
            &genesis,
            service,
            key,
            last,
            future + 1..=future + 1
        )
        .await
        .is_err());
    sqlx::query("DROP TABLE station_service_signing_ceilings")
        .execute(&external.pool)
        .await
        .unwrap();
    assert!(replica
        .reserve(
            account,
            &genesis,
            service,
            key,
            last,
            future + 1..=future + 1
        )
        .await
        .is_err());
    assert!(
        plan::prepare_with_sources(&primary.pool, &next, &genesis, Some(&replica), None, None)
            .await
            .is_err()
    );
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_regressed_signing_store_cannot_hide_retained_service_signatures() {
    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
        .execute(&external.pool)
        .await
        .unwrap();
    let (primary, runtime, fixture) =
        fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let origin = &runtime.binding.station_origin;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    assert_eq!(
        recovery
            .delegated_operation(&genesis, PRINCIPAL, Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    let before_enrollment: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&genesis)
            .fetch_one(&primary.pool)
            .await
            .unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    append_body(
        &runtime,
        &fixture,
        serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
    )
    .await;
    policy(
        &runtime,
        "paused",
        draft["fingerprint"].as_str().unwrap(),
        None,
    )
    .await;
    runtime.reconcile_delegated_service(ID).await.unwrap();
    let records = feed(&runtime, &genesis).await;
    let last = records[1]["body"]["issued_at"].as_u64().unwrap();
    // The independent store was itself restored to the moment of registration.
    sqlx::raw_sql("CREATE TEMP TABLE old_rows AS SELECT account_id,genesis_hash,service_id,key_hash FROM station_service_signing_ceilings;
        TRUNCATE station_service_signing_ceilings;
        INSERT INTO station_service_signing_ceilings(account_id,genesis_hash,service_id,key_hash) SELECT * FROM old_rows;")
        .execute(&external.pool).await.unwrap();
    policy(
        &runtime,
        "ready",
        draft["fingerprint"].as_str().unwrap(),
        None,
    )
    .await;
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert_eq!(feed(&runtime, &genesis).await, records);
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();
    let review = plan::prepare_with_sources(
        &primary.pool,
        &fence,
        &genesis,
        recovery.signing_ceilings.get(),
        None, None,
    )
    .await
    .unwrap();
    assert_eq!(
        review["service_clock_evidence"]["uncovered_service_signatures"][format!("svc-{ID}")],
        last
    );
    assert_eq!(
        review["service_clock_evidence"]["reservations"][0]["highest_ms"],
        0
    );
    // A different registered key's reservation cannot cover this signature.
    let store = recovery.signing_ceilings.get().unwrap();
    let other_key = "f".repeat(64);
    let service = format!("svc-{ID}");
    store
        .register_new_key(fixture.log.account_id(), &genesis, &service, &other_key)
        .await
        .unwrap();
    store
        .reserve(
            fixture.log.account_id(),
            &genesis,
            &service,
            &other_key,
            0,
            last..=last,
        )
        .await
        .unwrap();
    let wrong_key = plan::prepare_with_sources(&primary.pool, &fence, &genesis, Some(store), None, None)
        .await
        .unwrap();
    assert_eq!(wrong_key["service_clock_evidence"]["snapshot_signing_marks"], json!({}));
    assert_eq!(
        wrong_key["service_clock_evidence"]["uncovered_service_signatures"][&service],
        last
    );
    // Restore the membership from before enrollment. Earlier authenticated
    // signatures still belong to this key even after the verifier loses it.
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(before_enrollment)
        .execute(&primary.pool)
        .await
        .unwrap();
    let later = Binding::new(origin, 3).unwrap();
    later.initialize(&primary.pool, true).await.unwrap();
    let replica = primary.reconnect(2).await;
    let historical = plan::prepare_with_sources(&replica, &later, &genesis, Some(store), None, None)
        .await
        .unwrap();
    assert_eq!(
        historical["service_clock_evidence"]["uncovered_service_signatures"][&service],
        last
    );
    let fingerprint = draft["fingerprint"].as_str().unwrap();
    sqlx::query("DELETE FROM station_service_signing_ceilings WHERE key_hash=$1")
        .bind(fingerprint)
        .execute(&external.pool)
        .await
        .unwrap();
    let missing = plan::prepare_with_sources(&replica, &later, &genesis, Some(store), None, None)
        .await
        .unwrap();
    assert_eq!(
        missing["service_clock_evidence"]["unregistered_membership_keys"],
        json!([[service, fingerprint]])
    );
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let source = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{"at":"2026-11-23T10:00:00.000Z","integrations":[{
        "id":ID,"ownerAccount":OWNER,"state":"revoked","scopes":["agent.view"],"r9Svc":fingerprint,
        "interruptRunning":true,"revokedAt":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
    }]}});
    let snapshot = crate::integration_checkpoint::PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(),&runtime.binding).unwrap();
    let next = previous.apply_checkpoint(snapshot, previous.received_at).unwrap();
    runtime.policies.commit_for_recovery(&previous,&next,Some(&later)).await.unwrap();
    let portal = plan::prepare_with_sources(&replica,&later,&genesis,Some(store),Some(&runtime.binding), Some(&runtime.vault)).await.unwrap();
    let observed = &portal["portal_service_evidence"]["prior_membership_keys"][0];
    assert_eq!(observed["service_id"], service);
    assert_eq!(observed["key_fingerprint"], fingerprint);
    assert_eq!(observed["highest_signed_ms"], last);
    assert_eq!(observed["portal_observation"]["interrupt_running"], true);
    assert_eq!(portal["portal_service_evidence"]["services"],json!([]));
    assert_eq!(portal["service_drafts"], json!({"status":"membership_history_unresolved"}));
    assert_eq!(portal["known_history"]["membership_gaps"][0]["reason"], "restored_head_behind");
    replica.close().await;
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_restore_attributes_a_portal_service_to_its_owners_other_list() {
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::remote_api::push_ingress::tests::Fixture;
    use atem_client::membership::Head;

    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
        .execute(&external.pool)
        .await
        .unwrap();
    let (db, runtime, enrolled) =
        fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let other = Fixture::new(enrolled.created - 5000);
    let genesis = other.log.genesis_hash().to_hex();
    let enrolled_genesis = enrolled.log.genesis_hash().to_hex();
    let recovery = &runtime.app.recovery;
    for entry in other.log.entries() {
        assert_eq!(
            recovery
                .append_test_entry(
                    &genesis,
                    PRINCIPAL,
                    entry.clone(),
                    Head {
                        seq: entry.seq - 1,
                        hash: entry.prev_hash
                    }
                )
                .await,
            StatusCode::OK
        );
    }
    let draft = runtime
        .prepare(ID, OWNER, request(&enrolled))
        .await
        .unwrap();
    let fingerprint = draft["fingerprint"].as_str().unwrap();
    let before_enrollment: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&enrolled_genesis)
            .fetch_one(&db.pool)
            .await
            .unwrap();
    append_body(
        &runtime,
        &enrolled,
        serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
    )
    .await;
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let source = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{"at":"2026-11-27T10:00:00.000Z","integrations":[{
        "id":ID,"ownerAccount":OWNER,"state":"revoked","scopes":["agent.view"],"r9Svc":fingerprint,
        "interruptRunning":true,"revokedAt":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
    }]}});
    let cut =
        PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
    let next = previous
        .apply_checkpoint(cut, previous.received_at)
        .unwrap();
    let fence = Binding::new(&runtime.binding.station_origin, 2).unwrap();
    fence.initialize(&db.pool, true).await.unwrap();
    runtime
        .policies
        .commit_for_recovery(&previous, &next, Some(&fence))
        .await
        .unwrap();
    let replica = db.reconnect(2).await;
    let prepare = |pool| {
        plan::prepare_with_sources(
            pool,
            &fence,
            &genesis,
            recovery.signing_ceilings.get(),
            Some(&runtime.binding),
            Some(&runtime.vault),
        )
    };
    let first = prepare(&db.pool).await.unwrap();
    let evidence = &first["portal_service_evidence"];
    assert_eq!(evidence["portal_keys_without_attribution"], json!([]));
    assert_eq!(
        evidence["portal_keys_at_other_lists"][0]["genesis_hash"],
        enrolled_genesis
    );
    assert_eq!(
        evidence["portal_keys_at_other_lists"][0]["key_fingerprint"],
        fingerprint
    );
    assert_eq!(evidence["services"], json!([]));
    assert_eq!(first["candidate_snapshot"]["record_count"], 0);
    assert_eq!(first["snapshot_complete"], false);
    assert_eq!(
        prepare(&replica).await.unwrap()["portal_service_evidence_hash"],
        first["portal_service_evidence_hash"]
    );
    let owning_review = plan::prepare_with_sources(
        &replica,
        &fence,
        &enrolled_genesis,
        recovery.signing_ceilings.get(),
        Some(&runtime.binding),
        Some(&runtime.vault),
    )
    .await
    .unwrap();
    let owning_service = &owning_review["portal_service_evidence"]["services"][0];
    assert_eq!(owning_service["key_fingerprint"], fingerprint);
    assert_eq!(
        owning_service["snapshot_review"]["fresh_stop_actions"],
        json!([{"action":"revoke","interrupt_running":true}])
    );

    let unresolved = |review: &Value| {
        assert_eq!(
            review["portal_service_evidence"]["portal_keys_without_attribution"][0]
                ["key_fingerprint"],
            fingerprint
        );
        assert_eq!(
            review["candidate_snapshot"]["status"],
            "provisioning_unresolved"
        );
        assert!(review["portal_service_evidence"]
            .get("portal_keys_at_other_lists")
            .is_none());
    };
    sqlx::query(
        "UPDATE remote_recovery_roots SET account_subject='another-owner' WHERE genesis_hash=$1",
    )
    .bind(&enrolled_genesis)
    .execute(&db.pool)
    .await
    .unwrap();
    unresolved(&prepare(&replica).await.unwrap());
    sqlx::query("UPDATE remote_recovery_roots SET account_subject=$2 WHERE genesis_hash=$1")
        .bind(&enrolled_genesis)
        .bind(PRINCIPAL)
        .execute(&db.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&enrolled_genesis)
        .bind(&before_enrollment)
        .execute(&db.pool)
        .await
        .unwrap();
    unresolved(&prepare(&replica).await.unwrap());
    append_body(
        &runtime,
        &enrolled,
        serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
    )
    .await;
    sqlx::query("UPDATE station_service_keys SET sealed='{}'")
        .execute(&db.pool)
        .await
        .unwrap();
    unresolved(&prepare(&replica).await.unwrap());
    replica.close().await;
    drop(runtime);
    db.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_restore_finds_revoked_service_missing_from_membership() {
    use crate::integration_checkpoint::PortalCheckpoint;

    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
        .execute(&external.pool)
        .await
        .unwrap();
    let (primary, runtime, fixture) =
        fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let account = fixture.log.account_id();
    let origin = &runtime.binding.station_origin;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    assert_eq!(
        recovery
            .delegated_operation(&genesis, PRINCIPAL, Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    let backup: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&genesis)
            .fetch_one(&primary.pool)
            .await
            .unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    append_body(
        &runtime,
        &fixture,
        serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
    )
    .await;
    let fingerprint = draft["fingerprint"].as_str().unwrap();
    policy(&runtime, "paused", fingerprint, None).await;
    runtime.reconcile_delegated_service(ID).await.unwrap();
    let ceiling = feed(&runtime, &genesis).await.last().unwrap()["body"]["issued_at"]
        .as_u64()
        .unwrap();
    let store = recovery.signing_ceilings.get().unwrap();
    let id = format!("svc-{ID}");
    let orphan = "f".repeat(64);
    store
        .register_new_key(account, &genesis, &id, &orphan)
        .await
        .unwrap();
    store
        .register_new_key(account, &"0".repeat(64), "other-root", fingerprint)
        .await
        .unwrap();
    store
        .register_new_key("other-account", &genesis, "foreign", fingerprint)
        .await
        .unwrap();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&backup)
        .execute(&primary.pool)
        .await
        .unwrap();
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();

    let prev = runtime.policies.load(&runtime.binding).await.unwrap();
    let other = "i-99999999999999999999999999";
    store
        .register_new_key(account, &genesis, &format!("svc-{other}"), fingerprint)
        .await
        .unwrap();
    let unrelated = "i-88888888888888888888888888";
    let source = json!({"changes":[],"cursor":prev.cursor,"checkpoint":{"at":"2026-11-23T10:00:00.000Z","integrations":[{
        "id":ID,"ownerAccount":OWNER,"state":"revoked","scopes":["agent.view"],"r9Svc":fingerprint,
        "interruptRunning":true,"revokedAt":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
    },{
        "id":unrelated,"ownerAccount":OWNER,"state":"ready","scopes":["agent.view"],
        "r9Svc":fingerprint,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
    },{
        "id":other,"ownerAccount":"ab00000000000000000000000001","state":"ready","scopes":["agent.view"],
        "r9Svc":fingerprint,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
    }]}});
    let snapshot =
        PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
    let bound = prev.apply_checkpoint(snapshot, prev.received_at).unwrap();
    runtime
        .policies
        .commit_for_recovery(&prev, &bound, Some(&fence))
        .await
        .unwrap();
    let replica = primary.reconnect(2).await;
    let review = || {
        plan::prepare_with_sources(
            &replica,
            &fence,
            &genesis,
            Some(store),
            Some(&runtime.binding), Some(&runtime.vault),
        )
    };
    let prepared = review().await.unwrap();
    let portal = &prepared["portal_service_evidence"];
    let provisioned = portal["provisioned_without_membership"].as_array().unwrap();
    assert_eq!(prepared["candidate_snapshot"]["status"], "provisioning_unresolved");
    assert_eq!(provisioned.len(), 1);
    assert_eq!(provisioned[0]["key_fingerprint"], fingerprint);
    assert_eq!(provisioned[0]["portal_observation"]["interrupt_running"], true);
    let unattributed = &portal["portal_keys_without_attribution"];
    assert_eq!(unattributed.as_array().unwrap().len(), 1);
    assert_eq!(unattributed[0]["service_id"], format!("svc-{unrelated}"));
    assert_eq!(portal["services"], json!([]));
    assert_eq!(portal["protected_service_keys"][0]["signing_reservation"],
        json!({"highest_reserved_ms":ceiling}));
    let keys = portal["registrations_without_membership"]
        .as_array()
        .unwrap();
    assert_eq!(keys.len(), 3);
    let lost = keys
        .iter()
        .find(|k| k["service_id"] == id && k["key_fingerprint"] == fingerprint)
        .unwrap();
    assert_eq!(lost["service_id"], id);
    assert_eq!(lost["highest_reserved_ms"], ceiling);
    assert_eq!(lost["portal_observation"]["state"], "revoked");
    assert_eq!(lost["portal_observation"]["interrupt_running"], true);
    assert!(lost["portal_observation"]["revoked_at"].is_null());
    let unused = keys
        .iter()
        .find(|k| k["key_fingerprint"] == orphan)
        .unwrap();
    assert_eq!(unused["highest_reserved_ms"], 0);
    assert_eq!(unused["portal_observation"], json!({"status":"unresolved"}));
    let foreign = keys
        .iter()
        .find(|k| k["service_id"] == format!("svc-{other}"))
        .unwrap();
    assert_eq!(
        foreign["portal_observation"],
        json!({"status":"unresolved"})
    );
    assert_eq!(prepared["recovery_ready"], false);

    // The Portal may be the only surviving source after both restores. Its
    // owner has multiple R9 lists; the row establishes no signing authority.
    sqlx::query("DELETE FROM station_service_signing_ceilings WHERE account_id=$1 AND genesis_hash=$2 AND key_hash=$3")
        .bind(account).bind(&genesis).bind(fingerprint).execute(&external.pool).await.unwrap();
    let saved = review().await.unwrap();
    assert_eq!(saved["portal_service_evidence"]["protected_service_keys"][0]["signing_reservation"],
        json!({"status":"missing"}), "the same service's other key cannot supply its reservation");
    assert_eq!(saved["portal_service_evidence"]["provisioned_without_membership"].as_array().unwrap(), provisioned);
    let stored: String = sqlx::query_scalar("SELECT context FROM station_integration_provisioning WHERE integration_id=$1")
        .bind(ID).fetch_one(&primary.pool).await.unwrap();
    let context: crate::service_keys::ServiceKeyContext = serde_json::from_str(&stored).unwrap();
    for foreign in [
        crate::service_keys::ServiceKeyContext { owner: "ab00000000000000000000000001".into(), ..context.clone() },
        crate::service_keys::ServiceKeyContext { genesis: "a".repeat(64), ..context.clone() },
        crate::service_keys::ServiceKeyContext { issuer: "https://other-auth.example".into(), ..context.clone() },
        crate::service_keys::ServiceKeyContext { station_origin: "https://other-station.example".into(), ..context.clone() },
    ] {
        crate::service_keys::load_or_create_pending(&primary.pool, &runtime.vault, &foreign, None).await.unwrap();
    }
    sqlx::query("DELETE FROM station_integration_provisioning WHERE integration_id=$1")
        .bind(ID).execute(&primary.pool).await.unwrap();
    // Even without a provisioning row, membership, or a matching external
    // reservation, the surviving protected key still identifies this list.
    let restored = review().await.unwrap();
    let evidence = &restored["portal_service_evidence"];
    assert_eq!(evidence["envelopes_without_provisioning"], json!([id]));
    assert_eq!(evidence["protected_service_keys"].as_array().unwrap().len(), 1);
    let row = &evidence["protected_service_keys"][0];
    assert_eq!(row["status"], "missing_provisioning");
    assert_eq!(row["key_fingerprint"], fingerprint);
    assert_eq!(row["signing_reservation"], json!({"status":"missing"}));
    assert_eq!(row["portal_observation"]["state"], "revoked");
    assert_eq!(&evidence["portal_keys_without_attribution"], unattributed);
    assert_eq!(evidence["provisioned_without_membership"], json!([]));
    assert_eq!(evidence["provisioning_without_fingerprint"], json!([]));
    assert_eq!(restored["recovery_ready"], false);
    assert_eq!(review().await.unwrap()["portal_service_evidence_hash"],
        restored["portal_service_evidence_hash"]);

    let without_key = plan::prepare_with_sources(&replica, &fence, &genesis, Some(store),
        Some(&runtime.binding), None).await.unwrap();
    let metadata = &without_key["portal_service_evidence"];
    assert_eq!(metadata["envelopes_without_provisioning"], json!([id]));
    assert!(metadata.get("protected_service_keys").is_none());
    assert_eq!(&metadata["portal_keys_without_attribution"], unattributed);
    let wrapping = crate::service_keys::ServiceKeyVault::new(&[83; 32], "other-operator").unwrap();
    let unreadable = plan::prepare_with_sources(&replica, &fence, &genesis, Some(store),
        Some(&runtime.binding), Some(&wrapping)).await.unwrap();
    assert_eq!(unreadable["portal_service_evidence"]["protected_service_keys"],
        json!([{"service_id":id,"provisioning_fingerprint":null,"status":"unreadable"}]));
    assert_eq!(unreadable["portal_service_evidence"]["portal_keys_without_attribution"],
        metadata["portal_keys_without_attribution"]);

    crate::service_keys::forget(&primary.pool, &context).await.unwrap();
    let unassigned = review().await.unwrap();
    let source = &unassigned["portal_service_evidence"];
    assert_eq!(source["services"], json!([]));
    assert_eq!(source["provisioned_without_membership"], json!([]));
    assert_eq!(&source["portal_keys_without_attribution"], unattributed);
    let prior = source["prior_signing_registrations"].as_array().unwrap();
    let stopped = prior.iter().find(|row| row["service_id"] == id && row["key_fingerprint"] == fingerprint).unwrap();
    assert_eq!(stopped["highest_observed_ms"], ceiling);
    assert_eq!(stopped["portal_observation"]["state"], "revoked");
    assert_eq!(stopped["portal_observation"]["interrupt_running"], true);
    assert!(stopped.get("snapshot_review").is_none());
    let disconnected = plan::prepare_with_sources(&replica, &fence, &genesis, None,
        Some(&runtime.binding), None).await.unwrap();
    let evidence = &disconnected["portal_service_evidence"];
    assert!(evidence["registrations_without_membership"].is_null());
    assert_eq!(&evidence["portal_keys_without_attribution"], unattributed);
    assert!(evidence["prior_signing_registrations"].as_array().unwrap().contains(stopped));
    assert_eq!(disconnected["recovery_ready"], false);
    store.register_new_key(account, &genesis, &id, fingerprint).await.unwrap();
    let lower = review().await.unwrap();
    let evidence = &lower["portal_service_evidence"];
    let live = evidence["registrations_without_membership"].as_array().unwrap().iter()
        .find(|row| row["service_id"] == id && row["key_fingerprint"] == fingerprint).unwrap();
    assert_eq!(live["highest_reserved_ms"], 0);
    assert!(evidence["prior_signing_registrations"].as_array().unwrap().contains(stopped));
    assert_eq!(&evidence["portal_keys_without_attribution"], unattributed);
    assert_ne!(saved["portal_service_evidence_hash"], unassigned["portal_service_evidence_hash"]);
    assert_eq!(unassigned["recovery_ready"], false);
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_service_drafts_retry_without_signing_or_reopening() {
    use crate::integration_checkpoint::PortalCheckpoint;
    use atem_client::control::{ControlAction, ControlBody};

    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql")).execute(&external.pool).await.unwrap();
    let (primary, runtime, fixture) = fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let origin = &runtime.binding.station_origin;
    let service = format!("svc-{ID}");
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    let enrollment = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    append_body(&runtime, &fixture, serde_json::from_str(enrollment["bodyJSON"].as_str().unwrap()).unwrap()).await;
    let key = enrollment["fingerprint"].as_str().unwrap();
    let store = recovery.signing_ceilings.get().unwrap();
    assert_eq!(recovery.delegated_operation(&genesis, PRINCIPAL, Command::Ensure).await.0, StatusCode::OK);
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();
    let replica = primary.reconnect(2).await;
    let policy = async |state: &str| {
        let previous = runtime.policies.load(&runtime.binding).await.unwrap();
        let source = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{"at":"2026-11-27T10:00:00.000Z",
            "integrations":[{"id":ID,"ownerAccount":OWNER,"state":state,"scopes":["agent.view"],"r9Svc":key,
            "expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10}]}});
        let snapshot = PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
        let next = previous.apply_checkpoint(snapshot, previous.received_at).unwrap();
        runtime.policies.commit_for_recovery(&previous, &next, Some(&fence)).await.unwrap();
    };
    let prepare = async |pool: &sqlx::PgPool| {
        plan::prepare_with_sources(pool, &fence, &genesis, Some(store), Some(&runtime.binding), Some(&runtime.vault)).await
    };
    policy("paused").await;
    let (a, b) = tokio::join!(prepare(&primary.pool), prepare(&replica));
    let review = a.unwrap();
    let draft = &review["service_drafts"];
    assert_eq!(draft, &b.unwrap()["service_drafts"]);
    assert_eq!(draft["status"], "prepared");
    assert_eq!(draft["unresolved_services"], json!([]));
    let bodies: Vec<_> = draft["unsigned_bodies"].as_array().unwrap().iter()
        .map(|body| ControlBody::from_json(body).unwrap()).collect();
    assert_eq!(bodies.len(), 2);
    assert_eq!(bodies[0].action, ControlAction::Cover);
    assert_eq!(bodies[1].action, ControlAction::Hold);
    assert_eq!(bodies[0].issued_at + 1, bodies[1].issued_at);
    assert_ne!(bodies[0].record_id, bodies[1].record_id);
    assert_eq!(bodies[0].principal.id(), service);
    assert_eq!(bodies[0].principal_key.unwrap().to_hex(), key);
    assert_eq!(bodies[0].feed.as_ref().unwrap().feed_id, review["candidate_feed_id"]);
    assert_eq!(store.reservations(fixture.log.account_id(), &genesis).await.unwrap()[0].highest_ms, 0);
    let read = "SELECT bodies FROM station_delegated_service_drafts WHERE plan_id=$1";
    let plan_id = review["plan_id"].as_str().unwrap();
    // The membership still requires a hold, even when a restarted replica
    // cannot open the signing key. It must not report an empty batch as prepared.
    let wrong_vault = crate::service_keys::ServiceKeyVault::new(&[83; 32], "other-operator").unwrap();
    let partial = plan::prepare_with_sources(&replica, &fence, &genesis, Some(store),
        Some(&runtime.binding), Some(&wrong_vault)).await.unwrap();
    let missing = &partial["service_drafts"];
    assert_eq!(missing["status"], "partial");
    assert_eq!(missing["unresolved_services"], json!([{
        "service_id":service,"key_fingerprint":key,"reason":"protected_key_unavailable"
    }]));
    assert_eq!(missing["unsigned_bodies"], json!([]));
    assert_eq!(partial["recovery_ready"], false);
    let restored = prepare(&primary.pool).await.unwrap();
    let draft = &restored["service_drafts"];
    assert_eq!(draft["status"], "prepared");
    assert_eq!(draft["unsigned_bodies"][1]["action"], "hold");
    assert_eq!(store.reservations(fixture.log.account_id(), &genesis).await.unwrap()[0].highest_ms, 0);
    policy("ready").await;
    sqlx::raw_sql("CREATE FUNCTION reject_draft() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'injected failure'; END $$;
        CREATE CONSTRAINT TRIGGER reject_draft AFTER UPDATE ON station_delegated_service_drafts
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_draft()")
        .execute(&primary.pool).await.unwrap();
    assert!(prepare(&replica).await.is_err());
    assert_eq!(sqlx::query_scalar::<_,Value>(read).bind(plan_id).fetch_one(&replica).await.unwrap(), draft["unsigned_bodies"]);
    sqlx::query("DROP TRIGGER reject_draft ON station_delegated_service_drafts").execute(&primary.pool).await.unwrap();
    let resumed = prepare(&replica).await.unwrap();
    let active = &resumed["service_drafts"];
    assert_ne!(active["source_hash"], draft["source_hash"]);
    assert_eq!(active["unsigned_bodies"][1]["action"], "release");
    assert_ne!(active["unsigned_bodies"][0]["record_id"], draft["unsigned_bodies"][0]["record_id"]);
    // Change both the stored object and its digest: retry checks the exact action too.
    let mut wrong = active["unsigned_bodies"].clone();
    wrong[1]["action"] = json!("hold");
    let digest = atem_client::canonical::jcs(&wrong).unwrap();
    let hash = ring::digest::digest(&ring::digest::SHA256, digest.as_bytes()).as_ref()
        .iter().map(|b| format!("{b:02x}")).collect::<String>();
    sqlx::query("UPDATE station_delegated_service_drafts SET bodies=$1,bodies_hash=$2")
        .bind(&wrong).bind(hash).execute(&primary.pool).await.unwrap();
    assert!(prepare(&replica).await.is_err());
    let future = chrono::Utc::now().timestamp_millis() as u64 + 60_000;
    store.reserve(fixture.log.account_id(), &genesis, &service, key, 0, future..=future).await.unwrap();
    let waiting = prepare(&replica).await.unwrap();
    assert_eq!(waiting["service_drafts"]["status"], "waiting_for_clock");
    assert_eq!(waiting["recovery_ready"], false);
    assert!(feed(&runtime, &genesis).await.is_empty());
    assert!(fence.lock(&mut *replica.acquire().await.unwrap()).await.is_err());
    replica.close().await;
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_empty_candidate_is_identical_across_replicas() {
    use crate::integration_checkpoint::PortalCheckpoint;

    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql")).execute(&external.pool).await.unwrap();
    let (primary, runtime, fixture) = fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let fence = Binding::new(&runtime.binding.station_origin, 2).unwrap();
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(&fence.origin, 1).await.unwrap();
    assert_eq!(recovery.delegated_operation(&genesis, PRINCIPAL, Command::Ensure).await.0, StatusCode::OK);
    let old_events = vec![ReportControlEvent::Resume(runtime.binding.report_client_id.clone()),
        ReportControlEvent::Stop(runtime.binding.report_client_id.clone())];
    assert_eq!(recovery.delegated_operation(&genesis, PRINCIPAL, Command::ReportingControl(old_events.clone())).await.0, StatusCode::OK);
    fence.initialize(&primary.pool, true).await.unwrap();
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let source = json!({"changes":[],"cursor":previous.cursor,
        "checkpoint":{"at":"2026-11-27T10:00:00.000Z","integrations":[]}});
    let policy = PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
    let next = previous.apply_checkpoint(policy, previous.received_at).unwrap();
    runtime.policies.commit_for_recovery(&previous, &next, Some(&fence)).await.unwrap();
    let clock = runtime.app.recovery.signing_ceilings.get().unwrap();
    let replica = primary.reconnect(2).await;
    let report_binding = runtime.binding.report_control_binding();
    let events = json!(old_events);
    let prepare = |pool| plan::prepare_with_sources(pool, &fence, &genesis,
        Some(clock), Some(&runtime.binding), Some(&runtime.vault));
    let missing_journal = prepare(&replica).await.unwrap();
    assert_eq!(missing_journal["replacement_feed"]["status"], "awaiting_reporting_history");
    // Model a restored reservation whose owner never returned a signed copy.
    sqlx::query("INSERT INTO station_delegated_copy_reservations(plan_id,original_id,manager,principal,review_hash,issued_at)
        VALUES($1,$2,'phone','host:host-a',$3,4500)")
        .bind(missing_journal["plan_id"].as_str().unwrap()).bind(uuid::Uuid::new_v4().to_string())
        .bind(missing_journal["evidence_hash"].as_str().unwrap()).execute(&primary.pool).await.unwrap();
    sqlx::query("INSERT INTO station_delegated_reporting(binding,events,in_flight) VALUES ($1,$2,'lost-response')")
        .bind(&report_binding).bind(&events).execute(&primary.pool).await.unwrap();
    sqlx::raw_sql("CREATE FUNCTION refuse_image() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'commit failed'; END; $$ LANGUAGE plpgsql;
        CREATE CONSTRAINT TRIGGER refuse_image AFTER INSERT ON station_delegated_replacement_feeds
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION refuse_image()").execute(&primary.pool).await.unwrap();
    assert!(prepare(&replica).await.is_err());
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_replacement_feeds")
        .fetch_one(&primary.pool).await.unwrap();
    assert_eq!(count,0);
    sqlx::query("DROP TRIGGER refuse_image ON station_delegated_replacement_feeds").execute(&primary.pool).await.unwrap();
    let mut exact = None;
    for pool in [&primary.pool, &replica] {
        let review = prepare(pool).await.unwrap();
        assert_eq!(review["candidate_snapshot"], json!({"status":"assembled","record_count":0,
            "records_hash":"4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"}));
        assert_eq!(review["snapshot_complete"], false);
        assert_eq!(review["recovery_ready"], false);
        let staged = &review["replacement_feed"];
        assert_eq!(staged["status"], "staged");
        let image: Value = sqlx::query_scalar("SELECT feed FROM station_delegated_replacement_feeds WHERE plan_id=$1")
            .bind(review["plan_id"].as_str().unwrap()).fetch_one(pool).await.unwrap();
        assert_eq!(image["feed_id"], review["candidate_feed_id"]);
        assert_eq!(image["records"], json!([]));
        assert_eq!(image["signing_high_water"]["host:host-a"], 4500);
        assert_eq!(image["ledger"]["stopped"], runtime.binding.report_client_id);
        assert_eq!(image["report_control_seq"], 2);
        assert_eq!(image["ledger"]["done"], json!([]));
        if let Some(previous) = &exact { assert_eq!(previous, staged); }
        exact = Some(staged.clone());
    }
    sqlx::query("DELETE FROM station_delegated_reporting WHERE binding=$1")
        .bind(&report_binding).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"]["status"], "awaiting_reporting_history");
    sqlx::query("INSERT INTO station_delegated_reporting(binding,events,in_flight) VALUES ($1,$2,'lost-response')")
        .bind(&report_binding).bind(&events).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"], exact.unwrap());
    sqlx::query("UPDATE station_delegated_replacement_feeds SET feed=jsonb_set(feed,'{records}', '[{}]')")
        .execute(&replica).await.unwrap();
    assert!(prepare(&primary.pool).await.is_err());
    let claim: String = sqlx::query_scalar("SELECT in_flight FROM station_delegated_reporting WHERE binding=$1")
        .bind(&report_binding).fetch_one(&primary.pool).await.unwrap();
    assert_eq!(claim, "lost-response");

    // A restored Resume event must have its operator ID. Replacing the outstanding
    // claim while the client is enabled also requires another explicit resume.
    let resume = json!([ReportControlEvent::Resume(runtime.binding.report_client_id.clone())]);
    sqlx::query("UPDATE station_delegated_reporting SET events=events || $2, in_flight='delivery-a' WHERE binding=$1")
        .bind(&report_binding).bind(resume).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"]["status"], "awaiting_reporting_history");
    let record_resume = "INSERT INTO station_delegated_report_resumptions(binding,resume_id) VALUES ($1,$2::uuid)";
    sqlx::query(record_resume).bind(&report_binding).bind(uuid::Uuid::new_v4().to_string()).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"]["status"], "staged");
    sqlx::query("UPDATE station_delegated_reporting SET in_flight='delivery-b' WHERE binding=$1")
        .bind(&report_binding).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"]["status"], "awaiting_reporting_history");
    let restart = json!([ReportControlEvent::Stop(runtime.binding.report_client_id.clone()),
        ReportControlEvent::Resume(runtime.binding.report_client_id.clone())]);
    sqlx::query("UPDATE station_delegated_reporting SET events=events || $2, in_flight=NULL WHERE binding=$1")
        .bind(&report_binding).bind(restart).execute(&primary.pool).await.unwrap();
    sqlx::query(record_resume).bind(&report_binding).bind(uuid::Uuid::new_v4().to_string()).execute(&primary.pool).await.unwrap();
    assert_eq!(prepare(&replica).await.unwrap()["replacement_feed"]["status"], "staged");
    replica.close().await;
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}

#[tokio::test]
#[ignore = "requires two independent local PostgreSQL clusters"]
async fn postgres_delegated_candidate_service_signatures_bind_the_reviewed_clock_and_feed() {
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::service_keys::load_approved;
    use crate::service_signing_ceilings::SigningMark;
    use atem_client::control::{
        check_snapshot_consistency, ControlBody, SnapshotConsistency, SnapshotInput,
    };

    let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../signing-store/schema.sql")).execute(&external.pool).await.unwrap();
    let (primary, runtime, fixture) = fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
    let genesis = fixture.log.genesis_hash().to_hex();
    let origin = &runtime.binding.station_origin;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    let enrollment = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
    append_body(&runtime, &fixture, serde_json::from_str(enrollment["bodyJSON"].as_str().unwrap()).unwrap()).await;
    let key = enrollment["fingerprint"].as_str().unwrap();
    let context = runtime.context(ID).await.unwrap();
    let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
    let signer = load_approved(&primary.pool, &runtime.vault, &context, key).await.unwrap();
    let clock = recovery.signing_ceilings.get().unwrap();
    let replica = SigningCeilings::connect(&primary.pool, (*external.pool.connect_options()).clone()).await.unwrap();
    assert_eq!(recovery.delegated_operation(&genesis, PRINCIPAL, Command::Ensure).await.0, StatusCode::OK);
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();

    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let source = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{"at":"2026-11-27T10:00:00.000Z",
        "integrations":[{"id":ID,"ownerAccount":OWNER,"state":"paused","scopes":["agent.view"],"r9Svc":key,
        "expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10}]}});
    let policy = PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
    let next = previous.apply_checkpoint(policy, previous.received_at).unwrap();
    runtime.policies.commit_for_recovery(&previous, &next, Some(&fence)).await.unwrap();

    let principal = format!("service:{}", context.service_id);
    let prepare = async || {
        let review = plan::prepare_with_sources(&primary.pool, &fence, &genesis, Some(clock),
            Some(&runtime.binding), Some(&runtime.vault)).await.unwrap();
        assert_eq!(review["service_drafts"]["status"], "prepared");
        let bodies: Vec<_> = review["service_drafts"]["unsigned_bodies"].as_array().unwrap().iter()
            .map(|body| ControlBody::from_json(body).unwrap()).collect();
        assert_eq!(bodies.len(), 2);
        let mark: SigningMark = serde_json::from_value(review["service_clock_evidence"]["snapshot_signing_marks"][&principal].clone()).unwrap();
        (review, bodies, mark)
    };
    let (initial, bodies, mark) = prepare().await;
    let candidate = initial["candidate_feed_id"].as_str().unwrap().to_owned();
    let old_feed = uuid::Uuid::new_v4().to_string();
    let mut mixed = bodies.clone();
    mixed[1].feed.as_mut().unwrap().feed_id = old_feed.clone();
    assert!(signer.sign_control_batch(clock, &log, &candidate, &mixed, &mark, || true).await.is_err());
    assert!(signer.sign_control_batch(clock, &log, &old_feed, &bodies, &mark, || true).await.is_err());
    let mut wrong_key = mark.clone();
    wrong_key.key_fingerprint = "a".repeat(64);
    assert!(signer.sign_control_batch(clock, &log, &candidate, &bodies, &wrong_key, || true).await.is_err());
    let mut higher_native_stop = mark.clone();
    higher_native_stop.sign_above_ms = bodies[0].issued_at;
    assert!(signer.sign_control_batch(clock, &log, &candidate, &bodies, &higher_native_stop, || true).await.is_err());
    assert_eq!(replica.reservations(log.account_id(), &genesis).await.unwrap()[0].highest_ms, 0);

    // An intervening reservation below both draft timestamps still invalidates the review.
    replica.reserve(log.account_id(), &genesis, &context.service_id, key, 0, 1..=1).await.unwrap();
    assert!(signer.sign_control_batch(clock, &log, &candidate, &bodies, &mark, || true).await.is_err());
    assert_eq!(replica.reservations(log.account_id(), &genesis).await.unwrap()[0].highest_ms, 1);
    let (_, fresh, updated) = prepare().await;
    let allowed = std::cell::Cell::new(true);
    assert!(signer.sign_control_batch(clock, &log, &candidate, &fresh, &updated,
        || allowed.replace(false)).await.is_err());
    let burned = fresh.last().unwrap().issued_at;
    assert_eq!(replica.reservations(log.account_id(), &genesis).await.unwrap()[0].highest_ms as u64, burned);

    let (review, fresh, updated) = prepare().await;
    let records = signer.sign_control_batch(&replica, &log, &candidate, &fresh, &updated, || true).await.unwrap();
    assert!(records[0].issued_at() > burned);
    assert!(signer.sign_control_batch(clock, &log, &candidate, &fresh, &updated, || true).await.is_err());
    let input = SnapshotInput {
        list: &log, origin, candidate_feed_id: &candidate, retained: &[], snapshot: &records,
        marks: &[(principal.clone(), updated.sign_above_ms)].into(), covered: &[principal.clone()].into(),
        provisioned: &[principal.clone()].into(),
    };
    assert_eq!(check_snapshot_consistency(&input).unwrap(), SnapshotConsistency::Consistent);
    let other = primary.reconnect(3).await;
    let persist = async |pool: &sqlx::PgPool, review: &Value, batch: &[atem_client::control::ControlRecord], commit: bool| {
        let mut tx = pool.begin().await?;
        let receipt = plan::service_components::retain(&mut tx, &fence, &genesis, review, batch).await?;
        if commit { tx.commit().await?; } else { tx.rollback().await?; }
        Ok::<_,sqlx::Error>(receipt)
    };
    assert!(persist(&other, &initial, &records, true).await.is_err());
    let mut changed_clock = review.clone();
    changed_clock["service_clock_evidence"]["snapshot_signing_marks"][&principal]["sign_above_ms"] = json!(0);
    assert!(persist(&other, &changed_clock, &records, true).await.is_err());
    let receipt = persist(&primary.pool, &review, &records, false).await.unwrap();
    let known = plan::prepare(&other, &fence, &genesis).await.unwrap();
    assert!(known["known_history"]["checkpoints"][0].get("service_components").is_none());
    // Commit and lose the response. The independent clock now forces a different draft.
    assert_eq!(persist(&other, &review, &records, true).await.unwrap(), receipt);
    let (superseding, _, _) = prepare().await;
    assert_ne!(superseding["service_drafts"]["source_hash"], receipt["source_hash"]);
    assert_eq!(initial["candidate_snapshot"]["status"], "awaiting_service_signatures");
    assert_eq!(superseding["candidate_snapshot"], json!({"status":"assembled","record_count":2,
        "records_hash":receipt["records_hash"]}));
    let retried = plan::prepare_with_sources(&other, &fence, &genesis, Some(clock),
        Some(&runtime.binding), Some(&runtime.vault)).await.unwrap();
    assert_eq!(retried["candidate_snapshot"], superseding["candidate_snapshot"]);
    assert_eq!(retried["replacement_feed"], superseding["replacement_feed"]);
    let read_feed = "SELECT feed FROM station_delegated_replacement_feeds WHERE plan_id=$1 AND cut_hash=$2";
    let image: Value = sqlx::query_scalar(read_feed).bind(review["plan_id"].as_str().unwrap())
        .bind(retried["replacement_feed"]["cut_hash"].as_str().unwrap()).fetch_one(&other).await.unwrap();
    assert_eq!(image["records"], json!(records.iter().map(|r| r.object().to_json()).collect::<Vec<_>>()));
    assert_eq!(image["signing_high_water"][&principal], records.last().unwrap().issued_at());
    assert_eq!(image["ledger"]["done"],json!([]));
    assert_eq!(superseding["evidence_hash"], review["evidence_hash"],
        "Station's own service signatures must preserve the native author round that authorized them");
    assert_ne!(superseding["reconstruction_hash"], review["reconstruction_hash"]);
    assert_eq!(superseding["known_history"]["checkpoints"][0]["service_components"], json!([receipt]));
    assert_eq!(receipt["membership_head"], log.head().to_json());
    assert_eq!(persist(&primary.pool, &review, &records, true).await.unwrap(), receipt);
    let original_cut: Value = sqlx::query_scalar("SELECT signing_cut FROM station_delegated_service_components WHERE source_hash=$1")
        .bind(receipt["source_hash"].as_str().unwrap()).fetch_one(&other).await.unwrap();
    assert_eq!(original_cut["service_clock_evidence"], review["service_clock_evidence"]);
    let mut altered_cut = original_cut.clone();
    altered_cut["service_clock_evidence"]["snapshot_signing_marks"][&principal]["highest_reserved_ms"] =
        json!(records.last().unwrap().issued_at());
    let change_cut = "UPDATE station_delegated_service_components SET signing_cut=$2 WHERE source_hash=$1";
    // A receipt from before signing cuts were stored still proves what was retained.
    // It cannot supply a fresh cover or hold.
    sqlx::query(change_cut).bind(receipt["source_hash"].as_str().unwrap())
        .bind(Option::<Value>::None).execute(&other).await.unwrap();
    assert_eq!(persist(&other, &review, &records, true).await.unwrap(), receipt);
    let (legacy, _, _) = prepare().await;
    assert_eq!(legacy["candidate_snapshot"]["status"], "awaiting_service_signatures");
    sqlx::query(change_cut).bind(receipt["source_hash"].as_str().unwrap()).bind(&altered_cut).execute(&other).await.unwrap();
    assert!(plan::prepare(&primary.pool, &fence, &genesis).await.is_err());
    sqlx::query(change_cut).bind(receipt["source_hash"].as_str().unwrap()).bind(&original_cut).execute(&other).await.unwrap();
    assert_eq!(persist(&other, &review, &records, true).await.unwrap(), receipt);
    assert!(persist(&other, &superseding, &records, true).await.is_err());
    assert!(persist(&other, &review, &records[..1], true).await.is_err());

    // A new Portal checkpoint can have the same cursor and the same required actions.
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let refreshed = previous.apply_checkpoint(previous.portal_snapshot.clone().unwrap(), previous.received_at).unwrap();
    runtime.policies.commit_for_recovery(&previous, &refreshed, Some(&fence)).await.unwrap();
    let (refreshed, _, _) = prepare().await;
    assert_eq!(refreshed["candidate_snapshot"]["status"], "awaiting_service_signatures");
    assert_eq!(persist(&other, &review, &records, true).await.unwrap(), receipt);

    // A revoke signed under this plan survives abandonment and becomes a required stop of the next plan.
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut revoked = source.clone();
    let integration = &mut revoked["checkpoint"]["integrations"][0];
    integration["state"] = json!("revoked");
    integration["interruptRunning"] = json!(true);
    integration["revokedAt"] = Value::Null;
    revoked["checkpoint"]["at"] = json!("2026-11-27T10:01:00.000Z");
    let policy = PortalCheckpoint::parse(&serde_json::to_vec(&revoked).unwrap(), &runtime.binding).unwrap();
    let next = previous.apply_checkpoint(policy, previous.received_at).unwrap();
    runtime.policies.commit_for_recovery(&previous, &next, Some(&fence)).await.unwrap();
    let sign_revoke = async || {
        let review = plan::prepare_with_sources(&other, &fence, &genesis, Some(clock),
            Some(&runtime.binding), Some(&runtime.vault)).await.unwrap();
        let bodies: Vec<_> = review["service_drafts"]["unsigned_bodies"].as_array().unwrap().iter()
            .map(|body| ControlBody::from_json(body).unwrap()).collect();
        let mark: SigningMark = serde_json::from_value(review["service_clock_evidence"]["snapshot_signing_marks"][&principal].clone()).unwrap();
        let signed = signer.sign_control_batch(clock, &log, &candidate, &bodies, &mark, || true).await.unwrap();
        (review, signed)
    };
    let (stale_review, stale_records) = sign_revoke().await;
    // A manager's late interrupt changes the author evidence, even while the stored unsigned draft is unchanged.
    let mut intent = stale_records[0].body().clone();
    intent.action = atem_client::control::ControlAction::InterruptRunning { revoke_seq: None };
    intent.signer = atem_client::control::ControlSigner::Member("phone".into());
    intent.about.by = "owner".into();
    intent.record_id = uuid::Uuid::new_v4().to_string();
    let interrupt = atem_client::control::build_control(&fixture.keys,
        &atem_client::KeyId::new("manager"), &intent).unwrap().to_json();
    let imported = plan::stops::retain(&other, &fence, &genesis, &serde_json::to_vec(&json!({
        "plan_id":stale_review["plan_id"], "source_hash":stale_review["source_hash"], "records":[interrupt]
    })).unwrap()).await.unwrap();
    assert_ne!(imported["evidence_hash"], stale_review["evidence_hash"]);
    assert!(persist(&primary.pool, &stale_review, &stale_records, true).await.is_err());
    assert_eq!(persist(&primary.pool, &review, &records, true).await.unwrap(), receipt);
    let (rev, stops) = sign_revoke().await;
    assert!(stops.iter().any(|r| matches!(r.action(), atem_client::control::ControlAction::Revoke { interrupt_running:true })));
    let final_receipt = persist(&other, &rev, &stops, true).await.unwrap();
    let current = plan::prepare(&other, &fence, &genesis).await.unwrap();
    let stop_only = plan::snapshot_stops::stage(&other, &fence, &genesis,
        current["reconstruction_hash"].as_str().unwrap()).await.unwrap();
    let after_revoke = plan::prepare_with_sources(&other, &fence, &genesis, Some(clock),
        Some(&runtime.binding), Some(&runtime.vault)).await.unwrap();
    assert_eq!(after_revoke["service_drafts"]["unsigned_bodies"], json!([]));
    assert_eq!(after_revoke["candidate_snapshot"], json!({"status":"assembled",
        "record_count":stop_only["stop_count"],"records_hash":stop_only["records_hash"]}));
    assert_eq!(after_revoke["snapshot_complete"], false);
    let replaced: Value = sqlx::query_scalar(read_feed).bind(rev["plan_id"].as_str().unwrap())
        .bind(after_revoke["replacement_feed"]["cut_hash"].as_str().unwrap()).fetch_one(&other).await.unwrap();
    assert_ne!(retried["replacement_feed"]["cut_hash"], after_revoke["replacement_feed"]["cut_hash"]);
    assert!(replaced["records"].as_array().unwrap().contains(&interrupt));
    for stop in &stops { assert!(replaced["records"].as_array().unwrap().contains(&stop.object().to_json())); }
    assert!(replaced["ledger"]["records"].as_object().unwrap().contains_key(interrupt["body"]["record_id"].as_str().unwrap()));
    assert_eq!(replaced["ledger"]["done"], json!([]));
    plan::outcome::abandon(&other, &fence, &genesis, receipt["plan_id"].as_str().unwrap()).await.unwrap();
    let next_fence = Binding::new(origin, 3).unwrap();
    next_fence.initialize(&primary.pool, true).await.unwrap();
    let historical = plan::prepare(&other, &next_fence, &genesis).await.unwrap();
    let prior = historical["known_history"]["checkpoints"][0]["service_components"].as_array().unwrap();
    assert!(prior.contains(&receipt) && prior.contains(&final_receipt));
    let staged = plan::snapshot_stops::stage(&other, &next_fence, &genesis,
        historical["reconstruction_hash"].as_str().unwrap()).await.unwrap();
    assert_eq!(staged["stop_count"], stops.len() + 1);
    let stored: Value = sqlx::query_scalar("SELECT records FROM station_delegated_snapshot_stops WHERE plan_id=$1")
        .bind(historical["plan_id"].as_str().unwrap()).fetch_one(&other).await.unwrap();
    for stop in &stops { assert!(stored.as_array().unwrap().contains(&stop.object().to_json())); }
    assert!(stored.as_array().unwrap().contains(&interrupt));
    sqlx::query("UPDATE station_delegated_service_components SET membership_hash=$1 WHERE source_hash=$2")
        .bind("0".repeat(64)).bind(receipt["source_hash"].as_str().unwrap()).execute(&other).await.unwrap();
    assert!(plan::prepare(&primary.pool, &next_fence, &genesis).await.is_err());
    other.close().await;
    assert!(feed(&runtime, &genesis).await.is_empty());
    assert!(fence.lock(&mut *primary.pool.acquire().await.unwrap()).await.is_err());
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}
