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
        .reserve(account, &genesis, service, key, burned, burned + 1)
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
        first.reserve(account, &genesis, service, key, last + 1, future),
        replica.reserve(account, &genesis, service, key, last + 1, future)
    );
    assert_ne!(a.is_ok(), b.is_ok());
    assert!(runtime.reconcile_delegated_service(ID).await.is_err());
    assert!(feed(&runtime, &genesis).await.is_empty());
    let fence = Binding::new(origin, 2).unwrap();
    fence.initialize(&primary.pool, true).await.unwrap();
    let review = plan::prepare_with_ceilings(&primary.pool, &fence, &genesis, Some(&replica))
        .await
        .unwrap();
    assert_eq!(
        review["service_clock_evidence"]["reservations"][0]["highest_ms"],
        future
    );
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
            future + 1,
            future + 1
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
        .reserve(account, &genesis, service, "orphan", future + 1, future + 1)
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
    let missing = plan::prepare_with_ceilings(&primary.pool, &fence, &genesis, Some(&replica))
        .await
        .unwrap();
    assert_eq!(
        missing["service_clock_evidence"]["unregistered_membership_keys"],
        json!([[service, key]])
    );
    assert_ne!(
        missing["service_clock_evidence_hash"],
        review["service_clock_evidence_hash"]
    );
    assert!(replica
        .reserve(account, &genesis, service, key, future + 1, future + 1)
        .await
        .is_err());
    sqlx::query("DROP TABLE station_service_signing_ceilings")
        .execute(&external.pool)
        .await
        .unwrap();
    assert!(replica
        .reserve(account, &genesis, service, key, future + 1, future + 1)
        .await
        .is_err());
    assert!(
        plan::prepare_with_ceilings(&primary.pool, &fence, &genesis, Some(&replica))
            .await
            .is_err()
    );
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}
