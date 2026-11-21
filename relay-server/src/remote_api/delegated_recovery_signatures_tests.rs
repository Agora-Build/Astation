use super::super::super::delegated_recovery::{
    inspect,
    plan::{prepare, signatures::retain, stops},
    Binding,
};
use super::recovery_plan::retained;
use super::*;
use crate::test_database::TestDatabase;

async fn saved(pool: &sqlx::PgPool) -> Value {
    let mut result = json!({});
    for table in [
        "remote_recovery_roots",
        "station_delegated_recovery",
        "station_delegated_recovery_plans",
        "station_delegated_recovered_stops",
        "station_delegated_native_recovery",
        "station_delegated_recovery_signatures",
    ] {
        let rows: Vec<Value> = sqlx::query_scalar(&format!(
            "SELECT to_jsonb(t) FROM {table} t ORDER BY to_jsonb(t)::text"
        ))
        .fetch_all(pool)
        .await
        .unwrap();
        result[table] = json!(rows);
    }
    result
}

fn original(state: &Value) -> ControlRecord {
    ControlRecord::parse(
        &serde_json::to_vec(
            &state["remote_recovery_roots"][0]["state"]["delegated"][ORIGIN]["records"][1],
        )
        .unwrap(),
    )
    .unwrap()
}

fn fresh(f: &Fixture, plan: &Value, source: &ControlRecord, offset: u64) -> Value {
    let mut body = source.body().clone();
    body.feed = source.feed().map(|_| ControlFeed {
        origin: ORIGIN.into(),
        feed_id: plan["candidate_feed_id"].as_str().unwrap().into(),
    });
    body.record_id = uuid::Uuid::new_v4().to_string();
    body.issued_at = f.created + offset;
    build_control(&f.keys, &KeyId::new("manager"), &body)
        .unwrap()
        .to_json()
}

fn input(plan: &Value, source: &ControlRecord, copy: Value) -> Value {
    json!({"evidence_hash":plan["evidence_hash"],"replacements":[{"original_record_id":source.record_id(),"record":copy}]})
}

async fn submit(
    pool: &sqlx::PgPool,
    binding: &Binding,
    genesis: &str,
    plan: &Value,
    input: &Value,
) -> Result<Value, sqlx::Error> {
    retain(
        pool,
        binding,
        genesis,
        plan["plan_id"].as_str().unwrap(),
        &serde_json::to_vec(input).unwrap(),
    )
    .await
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_signatures_survive_replica_retry_without_publishing_or_opening(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = saved(&database.pool).await;
    let source = original(&before);
    let copy = fresh(&f, &plan, &source, 1000);
    let input = input(&plan, &source, copy.clone());
    let second = database.reconnect(2).await;
    let (first, retry) = tokio::join!(
        submit(&database.pool, &binding, &genesis, &plan, &input),
        submit(&second, &binding, &genesis, &plan, &input)
    );
    let first = first.unwrap();
    assert_eq!(retry.unwrap(), first);
    assert_eq!(
        first["evidence_hash"], plan["evidence_hash"],
        "acceptance does not invalidate its own source review"
    );
    assert_ne!(first["reconstruction_hash"], plan["reconstruction_hash"]);
    let signatures = &first["recovery_signatures"];
    assert_eq!(signatures["records"].as_array().unwrap().len(), 1);
    assert_eq!(signatures["records"][0]["current_review"], true);
    assert_eq!(signatures["records"][0]["verification"], "valid");
    assert_eq!(
        signatures["observed_signing_lower_bounds"]["service:svc-test"],
        f.created + 1000
    );
    assert_eq!(signatures["signing_clock_complete"], false);
    assert_eq!(first["snapshot_complete"], false);
    assert_eq!(first["recovery_ready"], false);
    let after = saved(&database.pool).await;
    for (table, value) in before.as_object().unwrap() {
        if table != "station_delegated_recovery_signatures" {
            assert_eq!(&after[table], value, "{table}");
        }
    }
    assert_eq!(
        after["station_delegated_recovery_signatures"][0]["record"],
        copy
    );
    assert_eq!(prepare(&second, &binding, &genesis).await.unwrap(), first);
    for secret in [
        "\"sig\"",
        "\"membership\"",
        "\"ledger\"",
        "old-report-client",
        "\"account_subject\"",
    ] {
        assert!(!first.to_string().contains(secret), "{secret}");
    }
    assert!(!inspect(&second, ORIGIN).await.unwrap().unwrap().ready);
    assert!(RecoveryStore::postgres(second.clone())
        .configure_delegated(ORIGIN, 1)
        .await
        .is_err());
    second.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_signatures_refuse_changed_intent_authority_and_context_atomically(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = saved(&database.pool).await;
    let source = original(&before);
    let copy = fresh(&f, &plan, &source, 1000);
    let valid = input(&plan, &source, copy.clone());
    for field in [
        "interrupt_running",
        "feed_id",
        "principal_key",
        "issued_at",
        "record_id",
        "signer",
        "by",
        "account_id",
    ] {
        let mut changed = ControlRecord::parse(&serde_json::to_vec(&copy).unwrap())
            .unwrap()
            .body()
            .clone();
        match field {
            "interrupt_running" => {
                changed.action = ControlAction::Revoke {
                    interrupt_running: false,
                }
            }
            "feed_id" => changed.feed.as_mut().unwrap().feed_id = uuid::Uuid::new_v4().to_string(),
            "principal_key" => changed.principal_key = Some(atem_client::Hash32::of(b"other")),
            "issued_at" => changed.issued_at = source.issued_at(),
            "record_id" => changed.record_id = source.record_id().into(),
            "signer" => changed.signer = ControlSigner::Principal,
            "by" => changed.about.by = "station".into(),
            "account_id" => changed.account_id = "other".into(),
            _ => unreachable!(),
        }
        let key = if field == "signer" {
            "service"
        } else {
            "manager"
        };
        let signed = build_control(&f.keys, &KeyId::new(key), &changed)
            .unwrap()
            .to_json();
        assert!(
            submit(
                &database.pool,
                &binding,
                &genesis,
                &plan,
                &input(&plan, &source, signed)
            )
            .await
            .is_err(),
            "{field}"
        );
        assert_eq!(saved(&database.pool).await, before, "{field}");
    }
    for (field, value) in [
        ("evidence_hash", json!("0".repeat(64))),
        ("extra", Value::Null),
    ] {
        let mut bad = valid.clone();
        bad[field] = value;
        assert!(
            submit(&database.pool, &binding, &genesis, &plan, &bad)
                .await
                .is_err(),
            "{field}"
        );
    }
    let mut bad = valid.clone();
    bad["replacements"][0]["original_record_id"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(submit(&database.pool, &binding, &genesis, &plan, &bad)
        .await
        .is_err());
    bad = valid.clone();
    bad["replacements"]
        .as_array_mut()
        .unwrap()
        .push(valid["replacements"][0].clone());
    assert!(submit(&database.pool, &binding, &genesis, &plan, &bad)
        .await
        .is_err());
    bad = valid.clone();
    bad["replacements"][0]["record"]["sig"] = json!("A".repeat(86));
    assert!(submit(&database.pool, &binding, &genesis, &plan, &bad)
        .await
        .is_err());
    let text = serde_json::to_string(&valid).unwrap();
    for key in ["evidence_hash", "original_record_id", "record_id"] {
        let bad = text.replacen(
            &format!("\"{key}\":"),
            &format!("\"{key}\":null,\"{key}\":"),
            1,
        );
        assert!(retain(
            &database.pool,
            &binding,
            &genesis,
            plan["plan_id"].as_str().unwrap(),
            bad.as_bytes()
        )
        .await
        .is_err());
    }
    assert!(retain(
        &database.pool,
        &binding,
        &genesis,
        plan["plan_id"].as_str().unwrap(),
        &vec![b' '; 262_145]
    )
    .await
    .is_err());
    assert!(submit(
        &database.pool,
        &Binding::new("https://other.example", 1).unwrap(),
        &genesis,
        &plan,
        &valid
    )
    .await
    .is_err());
    assert!(submit(
        &database.pool,
        &Binding::new(ORIGIN, 2).unwrap(),
        &genesis,
        &plan,
        &valid
    )
    .await
    .is_err());
    assert_eq!(saved(&database.pool).await, before);
    assert!(submit(&database.pool, &binding, &genesis, &plan, &valid)
        .await
        .is_ok());
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_signatures_keep_prior_clocks_and_require_review_after_new_evidence(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = saved(&database.pool).await;
    let source = original(&before);
    let first_copy = fresh(&f, &plan, &source, 1000);
    submit(
        &database.pool,
        &binding,
        &genesis,
        &plan,
        &input(&plan, &source, first_copy),
    )
    .await
    .unwrap();
    let mut later = source.body().clone();
    later.record_id = uuid::Uuid::new_v4().to_string();
    later.issued_at += 100;
    let later = build_control(&f.keys, &KeyId::new("manager"), &later)
        .unwrap()
        .to_json();
    let updated = stops::retain(
        &database.pool,
        &binding,
        &genesis,
        &serde_json::to_vec(&json!({
        "plan_id":plan["plan_id"],"source_hash":plan["source_hash"],"records":[later]}))
        .unwrap(),
    )
    .await
    .unwrap();
    assert_ne!(updated["evidence_hash"], plan["evidence_hash"]);
    assert_eq!(
        updated["recovery_signatures"]["records"][0]["current_review"],
        false
    );
    let before_failed = saved(&database.pool).await;
    let stale = input(&plan, &source, fresh(&f, &plan, &source, 1001));
    assert!(submit(&database.pool, &binding, &genesis, &plan, &stale)
        .await
        .is_err());
    let equal_time = input(&updated, &source, fresh(&f, &updated, &source, 1000));
    assert!(
        submit(&database.pool, &binding, &genesis, &updated, &equal_time)
            .await
            .is_err()
    );
    assert_eq!(saved(&database.pool).await, before_failed);
    let next = input(&updated, &source, fresh(&f, &updated, &source, 1001));
    let current = submit(&database.pool, &binding, &genesis, &updated, &next)
        .await
        .unwrap();
    assert_eq!(
        current["recovery_signatures"]["records"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        current["recovery_signatures"]["observed_signing_lower_bounds"]["service:svc-test"],
        f.created + 1001
    );
    let later_binding = Binding::new(ORIGIN, 2).unwrap();
    later_binding
        .initialize(&database.pool, true)
        .await
        .unwrap();
    let later_plan = prepare(&database.pool, &later_binding, &genesis)
        .await
        .unwrap();
    assert!(later_plan["recovery_signatures"]["records"]
        .as_array()
        .unwrap()
        .iter()
        .all(|row| row["current_review"] == false));
    let late_copy = fresh(&f, &later_plan, &source, 1002);
    let final_report = submit(
        &database.pool,
        &later_binding,
        &genesis,
        &later_plan,
        &input(&later_plan, &source, late_copy),
    )
    .await
    .unwrap();
    assert_eq!(
        final_report["recovery_signatures"]["records"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(final_report["recovery_ready"], false);
    assert_eq!(
        saved(&database.pool).await["remote_recovery_roots"],
        before["remote_recovery_roots"]
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_signatures_failed_commit_retains_no_signature_prefix() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = saved(&database.pool).await;
    let source = original(&before);
    let input = input(&plan, &source, fresh(&f, &plan, &source, 1000));
    sqlx::query("CREATE FUNCTION fail_signature_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected commit failure'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_signature_commit AFTER INSERT ON station_delegated_recovery_signatures \
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_signature_commit()")
        .execute(&database.pool).await.unwrap();
    assert!(submit(&database.pool, &binding, &genesis, &plan, &input)
        .await
        .is_err());
    assert_eq!(saved(&database.pool).await, before);
    sqlx::query("DROP TRIGGER fail_signature_commit ON station_delegated_recovery_signatures")
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(submit(&database.pool, &binding, &genesis, &plan, &input)
        .await
        .is_ok());
    let mut corrupt =
        saved(&database.pool).await["station_delegated_recovery_signatures"][0]["record"].clone();
    corrupt["sig"] = json!("A".repeat(86));
    sqlx::query("UPDATE station_delegated_recovery_signatures SET record=$1")
        .bind(corrupt)
        .execute(&database.pool)
        .await
        .unwrap();
    let broken = saved(&database.pool).await;
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert_eq!(saved(&database.pool).await, broken);
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
async fn postgres_delegated_recovery_signatures_refuse_partial_batches_and_keep_exact_host_interrupts(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, mut f, genesis, binding) = retained(&database).await;
    let revoke = atem_client::membership::host_sender_revoke("host-a", false, f.created).unwrap();
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft("phone", f.created, &revoke),
    )
    .unwrap();
    let next = f.log.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(next.appended, 1);
    f.log = next.next;
    let mut root = saved(&database.pool).await["remote_recovery_roots"][0]["state"].clone();
    root["membership"] = f.log.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(root)
        .bind(&genesis)
        .execute(&database.pool)
        .await
        .unwrap();
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let source = original(&saved(&database.pool).await);
    let mut host = source.body().clone();
    host.record_id = uuid::Uuid::new_v4().to_string();
    host.feed = None;
    host.principal_key = None;
    host.about.integration_id = None;
    host.principal = ControlPrincipal::Host("host-a".into());
    host.action = ControlAction::InterruptRunning {
        revoke_seq: Some(f.log.head().seq),
    };
    let host =
        ControlRecord::from_signed(build_control(&f.keys, &KeyId::new("manager"), &host).unwrap())
            .unwrap();
    let updated = stops::retain(&database.pool, &binding, &genesis, &serde_json::to_vec(&json!({
        "plan_id":plan["plan_id"],"source_hash":plan["source_hash"],"records":[host.object().to_json()]})).unwrap()).await.unwrap();
    let before = saved(&database.pool).await;
    let mut batch = input(&updated, &source, fresh(&f, &updated, &source, 1000));
    let mut invalid_host = host.body().clone();
    invalid_host.record_id = uuid::Uuid::new_v4().to_string();
    invalid_host.issued_at += 1000;
    invalid_host.action = ControlAction::InterruptRunning {
        revoke_seq: Some(2),
    };
    batch["replacements"].as_array_mut().unwrap().push(json!({"original_record_id":host.record_id(),
        "record":build_control(&f.keys, &KeyId::new("manager"), &invalid_host).unwrap().to_json()}));
    assert!(submit(&database.pool, &binding, &genesis, &updated, &batch)
        .await
        .is_err());
    assert_eq!(
        saved(&database.pool).await,
        before,
        "the valid service prefix must roll back"
    );
    batch["replacements"][1]["record"] = fresh(&f, &updated, &host, 1000);
    let accepted = submit(&database.pool, &binding, &genesis, &updated, &batch)
        .await
        .unwrap();
    assert_eq!(
        accepted["recovery_signatures"]["records"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(accepted["recovery_ready"], false);
    let host_copy = saved(&database.pool).await["station_delegated_recovery_signatures"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["original_record_id"] == host.record_id())
        .unwrap()["record"]
        .clone();
    assert!(host_copy["body"].get("feed_id").is_none());
    assert_eq!(host_copy["body"]["revoke_seq"], f.log.head().seq);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_signatures_recheck_current_manager_without_losing_old_anchors()
{
    use atem_client::membership::{Member, Role};
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let initial = saved(&database.pool).await;
    let source = original(&initial);
    let copy = fresh(&f, &plan, &source, 1000);
    submit(
        &database.pool,
        &binding,
        &genesis,
        &plan,
        &input(&plan, &source, copy),
    )
    .await
    .unwrap();
    let replacement_key = KeyId::new("replacement-manager");
    let replacement_enc = KeyId::new("replacement-encryption");
    f.keys
        .insert_p256(replacement_key.clone(), &[6; 32])
        .unwrap();
    f.keys.insert_x25519(replacement_enc.clone(), &[7; 32]);
    let add = Action::Add {
        member: Member {
            device_id: "replacement-manager".into(),
            auth_key: f.keys.public_key(&replacement_key).unwrap(),
            kind: MemberKind::Native {
                enc_key: f.keys.public_key(&replacement_enc).unwrap(),
                roles: [Role::View, Role::Control, Role::Manage].into(),
            },
        },
    };
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft("phone", f.created, &add),
    )
    .unwrap();
    let added = f.log.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(added.appended, 1);
    let demote = Action::SetRoles {
        device_id: "phone".into(),
        change: RolesChange::Native([Role::View].into()),
    };
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        added.next.draft("phone", f.created, &demote),
    )
    .unwrap();
    let demoted = added.next.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(demoted.appended, 1);
    let mut root = initial["remote_recovery_roots"][0]["state"].clone();
    root["membership"] = demoted.next.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1 WHERE genesis_hash=$2")
        .bind(root)
        .bind(&genesis)
        .execute(&database.pool)
        .await
        .unwrap();
    let changed = saved(&database.pool).await;
    assert!(
        prepare(&database.pool, &binding, &genesis).await.is_err(),
        "a changed source cannot reuse its old plan"
    );
    assert_eq!(saved(&database.pool).await, changed);
    let next_binding = Binding::new(ORIGIN, 2).unwrap();
    next_binding.initialize(&database.pool, true).await.unwrap();
    let next_plan = prepare(&database.pool, &next_binding, &genesis)
        .await
        .unwrap();
    assert_eq!(
        next_plan["recovery_signatures"]["records"][0]["verification"],
        "removed_manager"
    );
    assert_eq!(
        next_plan["recovery_signatures"]["observed_signing_lower_bounds"]["service:svc-test"],
        f.created + 1000
    );
    let removed_copy = fresh(&f, &next_plan, &source, 1001);
    let before_refusal = saved(&database.pool).await;
    assert!(submit(
        &database.pool,
        &next_binding,
        &genesis,
        &next_plan,
        &input(&next_plan, &source, removed_copy.clone())
    )
    .await
    .is_err());
    assert_eq!(saved(&database.pool).await, before_refusal);
    let mut body = ControlRecord::parse(&serde_json::to_vec(&removed_copy).unwrap())
        .unwrap()
        .body()
        .clone();
    body.signer = ControlSigner::Member("replacement-manager".into());
    let fresh_copy = build_control(&f.keys, &replacement_key, &body)
        .unwrap()
        .to_json();
    let result = submit(
        &database.pool,
        &next_binding,
        &genesis,
        &next_plan,
        &input(&next_plan, &source, fresh_copy),
    )
    .await
    .unwrap();
    assert_eq!(
        result["recovery_signatures"]["records"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|row| row["verification"] == "valid")
            .count(),
        1
    );
    assert_eq!(result["recovery_ready"], false);
    drop(store);
    database.cleanup().await;
}
