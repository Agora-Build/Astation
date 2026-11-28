use super::super::super::delegated_recovery::{inspect, plan::prepare, Binding};
use super::*;
use crate::test_database::TestDatabase;

async fn saved(pool: &sqlx::PgPool, genesis: &str) -> Value {
    sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
        .bind(genesis)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn plans(pool: &sqlx::PgPool) -> Vec<Value> {
    sqlx::query_scalar(
        "SELECT to_jsonb(p) FROM station_delegated_recovery_plans p ORDER BY generation",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

pub(super) async fn retained(
    database: &TestDatabase,
) -> (std::sync::Arc<RecoveryStore>, Fixture, String, Binding) {
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&store).await;
    let genesis = f.log.genesis_hash().to_hex();
    assert_eq!(
        store
            .delegated_operation(&genesis, "alice", Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    let mut root: Root = serde_json::from_value(saved(&database.pool, &genesis).await).unwrap();
    let feed = root.delegated.get_mut(ORIGIN).unwrap();
    let held = record(
        &f,
        feed,
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Hold,
    );
    feed.publish(
        ORIGIN,
        &f.log,
        &held,
        f.created,
        &["host-a".into()],
        f.created,
    )
    .unwrap();
    let service = record(
        &f,
        feed,
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: true,
        },
    );
    let mut body = service.body().clone();
    body.signer = ControlSigner::Member("phone".into());
    let native =
        ControlRecord::from_signed(build_control(&f.keys, &KeyId::new("manager"), &body).unwrap())
            .unwrap();
    feed.publish(
        ORIGIN,
        &f.log,
        &native,
        f.created,
        &["host-a".into()],
        f.created,
    )
    .unwrap();
    feed.ledger = feed
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .stop_reporting("old-report-client")
        .unwrap()
        .next
        .to_json();
    // A reservation with no record is still an outstanding clock obligation.
    feed.signing_high_water
        .insert("service:reserved-only".into(), f.created + 123);
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(serde_json::to_value(root).unwrap())
        .execute(&database.pool)
        .await
        .unwrap();
    (store, f, genesis, Binding::new(ORIGIN, 1).unwrap())
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preparation_survives_replica_races_and_restart_without_serving(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (store, f, genesis, binding) = retained(&database).await;
    assert!(
        prepare(&database.pool, &binding, &genesis).await.is_err(),
        "an open deployment cannot prepare"
    );
    assert!(plans(&database.pool).await.is_empty());
    binding.initialize(&database.pool, true).await.unwrap();
    let before = saved(&database.pool, &genesis).await;
    let second = database.reconnect(2).await;
    let (first, other) = tokio::join!(
        prepare(&database.pool, &binding, &genesis),
        prepare(&second, &binding, &genesis)
    );
    let first = first.unwrap();
    assert_eq!(
        other.unwrap(),
        first,
        "concurrent replicas retain one exact plan"
    );
    assert_eq!(plans(&database.pool).await.len(), 1);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert_eq!(first["membership_head"], f.log.head().to_json());
    assert_eq!(first["snapshot_complete"], false);
    assert_eq!(first["recovery_ready"], false);
    assert_eq!(first["retained_history_only"], true);
    assert_ne!(
        first["candidate_feed_id"],
        before["delegated"][ORIGIN]["feed_id"]
    );
    assert_eq!(
        first["review"]["records"][0]["requirement"],
        "service_state_reconciliation"
    );
    assert_eq!(
        first["review"]["records"][1]["requirement"],
        "retain_service_stop"
    );
    assert_eq!(first["review"]["records"][1]["interrupt_running"], true);
    assert_eq!(
        first["review"]["retained_signing_watermarks"]["service:reserved-only"],
        f.created + 123
    );
    assert_eq!(first["review"]["inspection"]["reporting_stopped"], true);
    let saved_plans = plans(&database.pool).await;
    assert_eq!(
        saved_plans[0]["retained"]["feed"],
        before["delegated"][ORIGIN]
    );
    for secret in [
        "\"sig\"",
        "\"signature\"",
        "old-report-client",
        "\"ledger\"",
        "\"membership\"",
    ] {
        assert!(!first.to_string().contains(secret), "{secret}");
    }
    second.close().await;
    let restart = database.reconnect(2).await;
    assert_eq!(prepare(&restart, &binding, &genesis).await.unwrap(), first);
    let fresh_store = RecoveryStore::postgres(restart.clone());
    assert!(fresh_store.configure_delegated(ORIGIN, 1).await.is_err());
    assert!(!inspect(&restart, ORIGIN).await.unwrap().unwrap().ready);
    assert_ne!(
        store
            .delegated_operation(&genesis, "alice", Command::Ensure)
            .await
            .0,
        StatusCode::OK
    );
    drop(fresh_store);
    restart.close().await;
    drop(store);
    database.cleanup().await;
}

pub(super) fn demote_manager(f: &mut Fixture) -> Membership {
    use atem_client::membership::{Member, Role};
    let replacement_key = KeyId::new("replacement-manager");
    let replacement_enc = KeyId::new("replacement-encryption");
    f.keys.insert_p256(replacement_key.clone(), &[6; 32]).unwrap();
    f.keys.insert_x25519(replacement_enc.clone(), &[7; 32]);
    let add = Action::Add { member: Member {
        device_id: "replacement-manager".into(),
        auth_key: f.keys.public_key(&replacement_key).unwrap(),
        kind: MemberKind::Native {
            enc_key: f.keys.public_key(&replacement_enc).unwrap(),
            roles: [Role::View, Role::Control, Role::Manage].into(),
        },
    }};
    let entry = sign_entry(&f.keys, &KeyId::new("manager"), f.log.draft("phone", f.created, &add)).unwrap();
    let added = f.log.evaluate_objects(&[entry.object().clone()], &HostNow {
        wall_ms: f.created, mono_ms: 0, boot_id: "test".into(),
    });
    assert_eq!(added.appended, 1, "{:?}", added.stop);
    let demotion = Action::SetRoles {
        device_id: "phone".into(),
        change: RolesChange::Native([Role::View].into()),
    };
    let entry = sign_entry(&f.keys, &KeyId::new("manager"), added.next.draft("phone", f.created, &demotion)).unwrap();
    let next = added.next.evaluate_objects(&[entry.object().clone()], &HostNow {
        wall_ms: f.created, mono_ms: 0, boot_id: "test".into(),
    });
    assert_eq!(next.appended, 1);
    next.next
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_reviews_a_root_that_predates_its_first_feed() {
    use super::super::super::delegated_recovery::plan::{review_for_owner, stops};

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, first) = retained(&database).await;
    let original = saved(&database.pool, &genesis).await;
    let native = original["delegated"][ORIGIN]["records"][1].clone();
    let mut backup = original.clone();
    backup.as_object_mut().unwrap().remove("delegated");
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(&backup).bind(&genesis).execute(&database.pool).await.unwrap();
    first.initialize(&database.pool, true).await.unwrap();
    let review = prepare(&database.pool, &first, &genesis).await.unwrap();
    assert!(review["review"]["retained_feed_id"].is_null());
    assert!(review["review"]["inspection"].is_null());
    assert_eq!(review["review"]["status"], "missing_retained_feed");
    assert_eq!(plans(&database.pool).await[0]["retained"].get("feed"), Some(&Value::Null));
    assert!(review_for_owner(&database.pool, &first, &genesis, "other").await.is_err());
    let owner = review_for_owner(&database.pool, &first, &genesis, "alice").await.unwrap();
    assert_eq!(owner["source_hash"], review["source_hash"]);
    let input = serde_json::to_vec(&json!({
        "plan_id":review["plan_id"],"source_hash":review["source_hash"],"records":[native]
    })).unwrap();
    let retained = stops::retain(&database.pool, &first, &genesis, &input).await.unwrap();
    assert_eq!(retained["known_history"]["records"][0]["record_id"], native["body"]["record_id"]);
    assert_eq!(retained["known_history"]["observed_signing_lower_bounds"]["service:svc-test"], f.created);
    assert_eq!(retained["recovery_ready"], false);
    assert_eq!(saved(&database.pool, &genesis).await, backup);

    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&database.pool, true).await.unwrap();
    let replica = database.reconnect(2).await;
    let after = prepare(&replica, &next, &genesis).await.unwrap();
    assert_ne!(after["candidate_feed_id"], review["candidate_feed_id"]);
    assert_eq!(after["known_history"]["records"], retained["known_history"]["records"]);
    assert_eq!(after["known_history"]["complete_history"], false);
    assert!(!inspect(&replica, ORIGIN).await.unwrap().unwrap().ready);
    assert_eq!(saved(&replica, &genesis).await, backup);
    replica.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preserves_prior_checkpoint_stops_and_reserved_clocks() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let original = saved(&database.pool, &genesis).await;
    let first = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let original_plans = plans(&database.pool).await;

    // The next restored source predates both stops and a reservation that
    // never produced a record. The earlier checkpoint still knows them.
    let mut older_source = original.clone();
    older_source["delegated"].as_object_mut().unwrap().remove(ORIGIN);
    let replacement_seq = f.log.head().seq + 1;
    older_source["membership"] = demote_manager(&mut f).to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(&older_source).bind(&genesis).execute(&database.pool).await.unwrap();
    let later = Binding::new(ORIGIN, 2).unwrap();
    later.initialize(&database.pool, true).await.unwrap();
    let restart = database.reconnect(2).await;
    let second = prepare(&restart, &later, &genesis).await.unwrap();
    let authors = &second["known_authors"]["members"];
    assert_eq!(authors["member:phone"]["first_manage_seq"], 1);
    assert_eq!(authors["member:phone"]["member_status"], "demoted");
    assert_eq!(authors["member:replacement-manager"]["member_status"], "manager");
    assert_eq!(authors["member:replacement-manager"]["first_manage_seq"], replacement_seq);
    assert_eq!(authors["member:phone"]["reports"], json!([]));
    assert_eq!(second["known_authors"]["complete_history"], false);
    let history = &second["known_history"];
    assert_eq!(history["membership_gaps"], json!([]));
    let records = history["records"].as_array().expect("known obligations");
    assert_eq!(records.len(), 2);
    for record in original["delegated"][ORIGIN]["records"].as_array().unwrap() {
        assert!(records.iter().any(|review| review["record_id"] == record["body"]["record_id"]));
    }
    let native = records.iter().find(|record| record["signer"] == "member:phone").unwrap();
    assert_eq!(native["verification"], "removed_manager");
    assert_eq!(native["requirement"], "fresh_manager_signature");
    assert_eq!(history["observed_signing_lower_bounds"]["service:reserved-only"], f.created + 123);
    assert_eq!(history["checkpoints"].as_array().unwrap().len(), 2);
    assert!(history["checkpoints"].as_array().unwrap().iter().any(|checkpoint| {
        checkpoint["plan_id"] == first["plan_id"] && checkpoint["inspection"]["reporting_stopped"] == true
    }));
    assert_eq!(prepare(&restart, &later, &genesis).await.unwrap(), second);
    assert_eq!(saved(&restart, &genesis).await, older_source);
    assert_eq!(plans(&restart).await[0], original_plans[0]);
    assert_eq!(second["snapshot_complete"], false);
    assert_eq!(second["recovery_ready"], false);
    for private in ["\"sig\"", "\"membership\"", "\"ledger\"", "old-report-client", "\"account_subject\""] {
        assert!(!second.to_string().contains(private), "{private}");
    }
    restart.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_requires_restored_membership_to_cover_every_retained_head() {
    use super::super::super::delegated_recovery::plan::{review_for_owner, signer_challenges, snapshot_stops};

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, mut f, genesis, first) = retained(&database).await;
    let initial = saved(&database.pool, &genesis).await;
    let replace = async |state: &Value| {
        sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
            .bind(state).bind(&genesis).execute(&database.pool).await.unwrap();
    };
    let mut demoted = initial.clone();
    let later_log = demote_manager(&mut f);
    demoted["membership"] = later_log.to_stored();
    replace(&demoted).await;
    first.initialize(&database.pool, true).await.unwrap();
    let known = prepare(&database.pool, &first, &genesis).await.unwrap();

    let peer = database.reconnect(2).await;
    let removal = Action::Remove { device_id: "svc-test".into() };
    let entry = sign_entry(&f.keys, &KeyId::new("manager"), f.log.draft("phone", f.created, &removal)).unwrap();
    let fork = f.log.evaluate_objects(&[entry.object().clone()], &HostNow {
        wall_ms: f.created, mono_ms: 0, boot_id: "test".into(),
    });
    assert_eq!(fork.appended, 1, "{:?}", fork.stop);
    let mut diverged = initial.clone();
    diverged["membership"] = fork.next.to_stored();
    for (generation, restored, reason) in [(2, &initial, "restored_head_behind"), (4, &diverged, "divergent_history")] {
        replace(restored).await;
        let binding = Binding::new(ORIGIN, generation).unwrap();
        binding.initialize(&peer, true).await.unwrap();
        let review = prepare(&peer, &binding, &genesis).await.unwrap();
        let gaps = review["known_history"]["membership_gaps"].as_array().unwrap();
        assert_eq!(gaps.first(), Some(&json!({
            "generation":1, "plan_id":known["plan_id"], "membership_head":later_log.head().to_json(), "reason":reason
        })));
        assert!(review_for_owner(&peer, &binding, &genesis, "alice").await.is_err());
        let request = signer_challenges::Request::parse(&json!({
            "signer":"member:phone", "slot":"mac", "expected":review["membership_head"],
            "recovery":{"generation":generation.to_string(), "plan_id":review["plan_id"],
                "candidate_feed_id":review["candidate_feed_id"], "source_hash":review["source_hash"],
                "evidence_hash":review["evidence_hash"]}
        })).unwrap();
        assert!(matches!(signer_challenges::mint(&peer, &binding, &genesis, "alice", request).await,
            Err(signer_challenges::MintError::ContextChanged)));
        assert!(snapshot_stops::stage(&peer, &binding, &genesis, review["reconstruction_hash"].as_str().unwrap()).await.is_err());
        assert_eq!(saved(&peer, &genesis).await, *restored);
        if generation == 2 {
            // Deliver the signed extension through the ordinary membership append.
            // Keep the original checkpoint and open a fresh report round in this plan.
            let mut previous = f.log.head();
            for entry in later_log.entries().iter().filter(|e| e.seq > f.log.head().seq) {
                assert_eq!(store.append_test_entry(&genesis, "alice", entry.clone(), previous).await, StatusCode::OK);
                previous = Head { seq: entry.seq, hash: entry.hash() };
            }
            assert!(review_for_owner(&peer, &binding, &genesis, "alice").await.is_err());
            let advanced = prepare(&peer, &binding, &genesis).await.unwrap();
            assert_eq!(advanced["plan_id"], review["plan_id"]);
            assert_eq!(advanced["candidate_feed_id"], review["candidate_feed_id"]);
            assert_eq!(advanced["source_hash"], review["source_hash"]);
            assert_eq!(advanced["known_history"]["membership_gaps"], json!([]));
            assert_ne!(advanced["evidence_hash"], review["evidence_hash"]);
            assert_eq!(prepare(&database.pool, &binding, &genesis).await.unwrap(), advanced);
            for stale in [&initial, &diverged] {
                replace(stale).await;
                assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
            }
            replace(&demoted).await;
            assert_eq!(prepare(&peer, &binding, &genesis).await.unwrap(), advanced);
            let corrected = Binding::new(ORIGIN, 3).unwrap();
            corrected.initialize(&peer, true).await.unwrap();
            let current = prepare(&peer, &corrected, &genesis).await.unwrap();
            assert_eq!(current["known_history"]["membership_gaps"], json!([]));
            assert_eq!(review_for_owner(&peer, &corrected, &genesis, "alice").await.unwrap()["membership_head"],
                later_log.head().to_json());
        }
    }
    let effects: (i64, i64) = sqlx::query_as("SELECT (SELECT count(*) FROM station_delegated_signer_challenges),
        (SELECT count(*) FROM station_delegated_snapshot_stops)").fetch_one(&peer).await.unwrap();
    assert_eq!(effects, (0, 0));
    peer.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_refuses_corrupt_or_foreign_earlier_checkpoints_atomically() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    prepare(&database.pool, &binding, &genesis).await.unwrap();
    let original = plans(&database.pool).await.remove(0);
    let root = saved(&database.pool, &genesis).await;
    let later = Binding::new(ORIGIN, 2).unwrap();
    later.initialize(&database.pool, true).await.unwrap();
    for wrong in ["account_subject", "account_id", "source_hash", "candidate_feed_id"] {
        let mut checkpoint = original.clone();
        if wrong.starts_with("account_") {
            checkpoint["retained"][wrong] = json!("foreign");
            let canonical = atem_client::canonical::jcs(&checkpoint["retained"]).unwrap();
            checkpoint["source_hash"] = ring::digest::digest(&ring::digest::SHA256, canonical.as_bytes())
                .as_ref().iter().map(|byte| format!("{byte:02x}")).collect::<String>().into();
        } else {
            checkpoint[wrong] = json!("corrupt");
        }
        sqlx::query("UPDATE station_delegated_recovery_plans SET retained=$1,source_hash=$2,candidate_feed_id=$3 WHERE generation=1")
            .bind(&checkpoint["retained"]).bind(checkpoint["source_hash"].as_str().unwrap())
            .bind(checkpoint["candidate_feed_id"].as_str().unwrap()).execute(&database.pool).await.unwrap();
        let corrupt = plans(&database.pool).await;
        assert!(prepare(&database.pool, &later, &genesis).await.is_err(), "{wrong}");
        assert_eq!(plans(&database.pool).await, corrupt, "a failed reconciliation must not retain a partial plan");
        assert_eq!(saved(&database.pool, &genesis).await, root);
    }
    sqlx::query("UPDATE station_delegated_recovery_plans SET retained=$1,source_hash=$2,candidate_feed_id=$3 WHERE generation=1")
        .bind(&original["retained"]).bind(original["source_hash"].as_str().unwrap())
        .bind(original["candidate_feed_id"].as_str().unwrap()).execute(&database.pool).await.unwrap();
    assert!(prepare(&database.pool, &later, &genesis).await.is_ok());
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_refuses_excess_checkpoint_history_without_truncation() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    prepare(&database.pool, &binding, &genesis).await.unwrap();
    let original = plans(&database.pool).await.remove(0);
    for generation in 2..=129 {
        sqlx::query("INSERT INTO station_delegated_recovery_plans(origin,generation,genesis_hash,plan_id,candidate_feed_id,source_hash,retained) VALUES ($1,$2,$3,$4,$5,$6,$7)")
            .bind(ORIGIN).bind(generation as i64).bind(&genesis)
            .bind(uuid::Uuid::new_v4().to_string()).bind(uuid::Uuid::new_v4().to_string())
            .bind(original["source_hash"].as_str().unwrap()).bind(&original["retained"])
            .execute(&database.pool).await.unwrap();
    }
    let later = Binding::new(ORIGIN, 130).unwrap();
    later.initialize(&database.pool, true).await.unwrap();
    let before = plans(&database.pool).await;
    let root = saved(&database.pool, &genesis).await;
    assert!(prepare(&database.pool, &later, &genesis).await.is_err());
    assert_eq!(plans(&database.pool).await, before);
    assert_eq!(saved(&database.pool, &genesis).await, root);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_never_reuses_an_earlier_sources_feed_id() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    prepare(&database.pool, &binding, &genesis).await.unwrap();
    let mut root = saved(&database.pool, &genesis).await;
    let old_id = root["delegated"][ORIGIN]["feed_id"].as_str().unwrap().to_owned();
    root["delegated"][ORIGIN] = serde_json::to_value(Stored::new(ORIGIN, &f.log).unwrap()).unwrap();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(&root).bind(&genesis).execute(&database.pool).await.unwrap();
    let later = Binding::new(ORIGIN, 2).unwrap();
    later.initialize(&database.pool, true).await.unwrap();
    prepare(&database.pool, &later, &genesis).await.unwrap();
    // It differs from this plan's source and every earlier candidate, so the
    // old per-plan/SQL uniqueness checks cannot detect this history reuse.
    sqlx::query("UPDATE station_delegated_recovery_plans SET candidate_feed_id=$1 WHERE generation=2")
        .bind(old_id).execute(&database.pool).await.unwrap();
    let before = plans(&database.pool).await;
    assert!(prepare(&database.pool, &later, &genesis).await.is_err());
    assert_eq!(plans(&database.pool).await, before);
    assert_eq!(saved(&database.pool, &genesis).await, root);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preparation_commit_failure_retains_fence_and_all_source_evidence(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let before = saved(&database.pool, &genesis).await;
    sqlx::query("CREATE FUNCTION fail_plan_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test plan commit failure'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_plan_commit AFTER INSERT ON station_delegated_recovery_plans DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_plan_commit()")
        .execute(&database.pool).await.unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert!(
        plans(&database.pool).await.is_empty(),
        "an uncommitted UUID is never returned or retained"
    );
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    sqlx::query("DROP TRIGGER fail_plan_commit ON station_delegated_recovery_plans")
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_ok());
    assert_eq!(saved(&database.pool, &genesis).await, before);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preparation_never_overwrites_changed_history_or_an_old_generation(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let first = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before_plans = plans(&database.pool).await;
    let source = saved(&database.pool, &genesis).await;
    // Unrelated encrypted backup data does not substitute for control history
    // and must not make an otherwise identical preparation unusable.
    let mut changed = source.clone();
    changed["blobs"] = json!({"1":{"bytes":"opaque-test-backup", "uploaded_at":f.created}});
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&changed)
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(
        prepare(&database.pool, &binding, &genesis).await.unwrap(),
        first
    );
    changed["delegated"][ORIGIN]["signing_high_water"]["service:reserved-only"] =
        json!(f.created + 124);
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&changed)
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert_eq!(plans(&database.pool).await, before_plans);
    let newer = Binding::new(ORIGIN, 2).unwrap();
    newer.initialize(&database.pool, false).await.unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    let next = prepare(&database.pool, &newer, &genesis).await.unwrap();
    assert_ne!(next["plan_id"], first["plan_id"]);
    assert_ne!(next["candidate_feed_id"], first["candidate_feed_id"]);
    let after = plans(&database.pool).await;
    assert_eq!(after.len(), 2);
    assert_eq!(after[0], before_plans[0]);
    assert_eq!(saved(&database.pool, &genesis).await, changed);
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preparation_refuses_missing_foreign_and_corrupt_sources() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    for bad in ["invalid".into(), "A".repeat(64), "0".repeat(64)] {
        assert!(prepare(&database.pool, &binding, &bad).await.is_err());
    }
    let other = Binding::new("https://other.example", 1).unwrap();
    assert!(prepare(&database.pool, &other, &genesis).await.is_err());
    assert!(inspect(&database.pool, &other.origin)
        .await
        .unwrap()
        .is_none());
    let source = saved(&database.pool, &genesis).await;
    let mut cases = vec![json!({})];
    let mut malformed = source.clone();
    malformed["delegated"][ORIGIN] = Value::Null;
    cases.push(malformed);
    let mut missing_clock = source.clone();
    missing_clock["delegated"][ORIGIN]["signing_high_water"] = json!({});
    cases.push(missing_clock);
    let mut foreign = source.clone();
    foreign["delegated"][ORIGIN]["records"][0]["body"]["feed"]["origin"] =
        json!("https://other.example");
    cases.push(foreign);
    let mut duplicate = source.clone();
    let duplicate_record = duplicate["delegated"][ORIGIN]["records"][0].clone();
    duplicate["delegated"][ORIGIN]["records"]
        .as_array_mut()
        .unwrap()
        .push(duplicate_record);
    cases.push(duplicate);
    for changed in cases {
        sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
            .bind(&genesis)
            .bind(changed)
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
        assert!(plans(&database.pool).await.is_empty());
    }
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_preparation_refuses_changed_owner_and_corrupt_checkpoints() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let first = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let checkpoint = plans(&database.pool).await.remove(0);
    let before = saved(&database.pool, &genesis).await;
    sqlx::query(
        "UPDATE remote_recovery_roots SET account_subject='another-owner' WHERE genesis_hash=$1",
    )
    .bind(&genesis)
    .execute(&database.pool)
    .await
    .unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert_eq!(plans(&database.pool).await, vec![checkpoint.clone()]);
    sqlx::query("UPDATE remote_recovery_roots SET account_subject=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(checkpoint["retained"]["account_subject"].as_str().unwrap())
        .execute(&database.pool)
        .await
        .unwrap();
    for (column, value) in [
        ("plan_id", "not-a-uuid"),
        (
            "candidate_feed_id",
            first["review"]["retained_feed_id"].as_str().unwrap(),
        ),
        ("source_hash", "changed"),
    ] {
        sqlx::query(&format!(
            "UPDATE station_delegated_recovery_plans SET {column}=$1"
        ))
        .bind(value)
        .execute(&database.pool)
        .await
        .unwrap();
        assert!(
            prepare(&database.pool, &binding, &genesis).await.is_err(),
            "{column}"
        );
        sqlx::query(&format!(
            "UPDATE station_delegated_recovery_plans SET {column}=$1"
        ))
        .bind(checkpoint[column].as_str().unwrap())
        .execute(&database.pool)
        .await
        .unwrap();
    }
    sqlx::query("UPDATE station_delegated_recovery_plans SET retained=jsonb_set(retained,'{padding}',to_jsonb(repeat('x',16777216)))")
        .execute(&database.pool).await.unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    sqlx::query("UPDATE station_delegated_recovery_plans SET retained=$1")
        .bind(&checkpoint["retained"])
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(
        prepare(&database.pool, &binding, &genesis).await.unwrap(),
        first
    );
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    drop(store);
    database.cleanup().await;
}
