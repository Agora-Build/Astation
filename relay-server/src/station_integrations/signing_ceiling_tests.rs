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
    replica.close().await;
    drop(runtime);
    primary.cleanup().await;
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
    let stopped = prior.iter().find(|row| row["service_id"] == id).unwrap();
    assert_eq!(stopped["key_fingerprint"], fingerprint);
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
    assert_ne!(saved["portal_service_evidence_hash"], unassigned["portal_service_evidence_hash"]);
    assert_eq!(unassigned["recovery_ready"], false);
    drop(runtime);
    primary.cleanup().await;
    external.cleanup().await;
}
