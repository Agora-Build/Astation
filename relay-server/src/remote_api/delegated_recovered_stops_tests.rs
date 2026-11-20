use super::super::super::delegated_recovery::{
    plan::{prepare, stops::retain},
    Binding,
};
use super::recovery_plan::retained;
use super::*;
use crate::test_database::TestDatabase;

fn later_stop(f: &Fixture, feed: &Stored, offset: u64) -> ControlRecord {
    let old = record(
        f,
        feed,
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: true,
        },
    );
    let mut body = old.body().clone();
    body.signer = ControlSigner::Member("phone".into());
    body.issued_at = f.created + offset;
    ControlRecord::from_signed(build_control(&f.keys, &KeyId::new("manager"), &body).unwrap())
        .unwrap()
}

fn input(plan: &Value, records: Vec<Value>) -> Vec<u8> {
    serde_json::to_vec(
        &json!({"plan_id":plan["plan_id"], "source_hash":plan["source_hash"], "records":records}),
    )
    .unwrap()
}

async fn state(pool: &sqlx::PgPool) -> Value {
    let root: Value = sqlx::query_scalar("SELECT state FROM remote_recovery_roots")
        .fetch_one(pool)
        .await
        .unwrap();
    let plans: Vec<Value> = sqlx::query_scalar(
        "SELECT to_jsonb(p) FROM station_delegated_recovery_plans p ORDER BY generation",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    let rows: Vec<Value> = sqlx::query_scalar(
        "SELECT to_jsonb(r) FROM station_delegated_recovered_stops r ORDER BY record_id",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    let fences: Vec<Value> =
        sqlx::query_scalar("SELECT to_jsonb(f) FROM station_delegated_recovery f ORDER BY origin")
            .fetch_all(pool)
            .await
            .unwrap();
    json!({"root":root,"plans":plans,"stops":rows,"fences":fences})
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_checkpoint_duplicate_survives_changed_source_generation() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let record = before["root"]["delegated"][ORIGIN]["records"][1].clone();
    let bytes = input(&plan, vec![record.clone(), record.clone()]);
    let first = retain(&database.pool, &binding, &genesis, &bytes)
        .await
        .unwrap();
    assert_eq!(first["recovered_stops"]["records"].as_array().unwrap().len(), 1);
    assert_eq!(state(&database.pool).await["stops"].as_array().unwrap().len(), 1);
    assert_eq!(retain(&database.pool, &binding, &genesis, &bytes).await.unwrap(), first);
    for key in ["root", "plans", "fences"] {
        assert_eq!(state(&database.pool).await[key], before[key], "{key}");
    }

    // A later restored source can lack this stop. Its accepted import must
    // remain an obligation independently of the older immutable checkpoint.
    let mut changed_source = before["root"].clone();
    changed_source["delegated"][ORIGIN]["records"].as_array_mut().unwrap().pop();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1")
        .bind(&changed_source)
        .execute(&database.pool)
        .await
        .unwrap();
    let next_binding = Binding::new(ORIGIN, 2).unwrap();
    next_binding.initialize(&database.pool, true).await.unwrap();
    let restart = database.reconnect(2).await;
    let next = prepare(&restart, &next_binding, &genesis).await.unwrap();
    assert_ne!(next["source_hash"], first["source_hash"]);
    assert_eq!(next["recovered_stops"], first["recovered_stops"]);
    assert_eq!(next["snapshot_complete"], false);
    assert_eq!(next["recovery_ready"], false);
    let after = state(&restart).await;
    assert_eq!(after["stops"][0]["record"], record);
    assert_eq!(after["root"], changed_source);
    assert_eq!(after["plans"][0], before["plans"][0]);
    restart.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_refuse_conflicts_with_an_earlier_checkpoint() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let old = ControlRecord::parse(&serde_json::to_vec(&before["root"]["delegated"][ORIGIN]["records"][1]).unwrap()).unwrap();
    let mut older_source = before["root"].clone();
    let mut empty = Stored::new(ORIGIN, &f.log).unwrap();
    empty.feed_id = before["root"]["delegated"][ORIGIN]["feed_id"].as_str().unwrap().into();
    older_source["delegated"][ORIGIN] = serde_json::to_value(empty).unwrap();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1")
        .bind(&older_source).execute(&database.pool).await.unwrap();
    let later = Binding::new(ORIGIN, 2).unwrap();
    later.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &later, &genesis).await.unwrap();
    let retained_source: Root = serde_json::from_value(older_source).unwrap();
    let genuine = later_stop(&f, &retained_source.delegated[ORIGIN], 100);
    let mut conflict = old.body().clone();
    conflict.issued_at += 200;
    let conflicting = build_control(&f.keys, &KeyId::new("manager"), &conflict).unwrap().to_json();
    let unchanged = state(&database.pool).await;
    assert!(retain(&database.pool, &later, &genesis,
        &input(&plan, vec![genuine.object().to_json(), conflicting])).await.is_err());
    assert_eq!(state(&database.pool).await, unchanged, "the entire batch must roll back");
    let accepted = retain(&database.pool, &later, &genesis,
        &input(&plan, vec![genuine.object().to_json()])).await.unwrap();
    assert_ne!(accepted["evidence_hash"], plan["evidence_hash"]);
    assert_eq!(accepted["plan_id"], plan["plan_id"]);
    assert_eq!(accepted["source_hash"], plan["source_hash"]);
    assert_eq!(accepted["known_history"]["records"].as_array().unwrap().len(), 3);
    assert_eq!(accepted["known_history"]["observed_signing_lower_bounds"]["service:svc-test"], f.created + 100);
    assert_eq!(accepted["known_history"]["complete_history"], false);
    assert_eq!(accepted["known_history"]["signing_clock_complete"], false);
    assert_eq!(accepted["snapshot_complete"], false);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_preserve_later_native_intent_across_replicas_and_restart(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let root: Root = serde_json::from_value(before["root"].clone()).unwrap();
    let first = later_stop(&f, &root.delegated[ORIGIN], 100);
    let second = later_stop(&f, &root.delegated[ORIGIN], 200);
    let first_input = input(&plan, vec![first.object().to_json()]);
    let second_input = input(&plan, vec![second.object().to_json()]);
    let replica = database.reconnect(2).await;
    let (a, b) = tokio::join!(
        retain(&database.pool, &binding, &genesis, &first_input),
        retain(&replica, &binding, &genesis, &second_input)
    );
    a.unwrap();
    b.unwrap();
    let final_report = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let rows = final_report["recovered_stops"]["records"]
        .as_array()
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert!(rows
        .iter()
        .all(|row| row["requirement"] == "fresh_manager_signature"
            && row["interrupt_running"] == true));
    assert_eq!(
        final_report["recovered_stops"]["observed_issued_at_lower_bounds"]["service:svc-test"],
        f.created + 200
    );
    for key in [
        "candidate_feed_id",
        "source_hash",
        "membership_head",
        "review",
    ] {
        assert_eq!(final_report[key], plan[key], "{key}");
    }
    for key in ["root", "plans", "fences"] {
        assert_eq!(state(&database.pool).await[key], before[key], "{key}");
    }
    assert_eq!(
        retain(&replica, &binding, &genesis, &first_input)
            .await
            .unwrap(),
        final_report
    );
    replica.close().await;
    let restart = database.reconnect(2).await;
    assert_eq!(
        prepare(&restart, &binding, &genesis).await.unwrap(),
        final_report
    );
    assert_eq!(state(&restart).await["stops"].as_array().unwrap().len(), 2);
    for row in state(&restart).await["stops"].as_array().unwrap() {
        let record = &row["record"];
        assert!(record == &first.object().to_json() || record == &second.object().to_json());
    }
    let public = final_report.to_string();
    for private in [
        "\"sig\"",
        "\"membership\"",
        "\"ledger\"",
        "old-report-client",
        "\"account_subject\"",
    ] {
        assert!(!public.contains(private), "{private}");
    }
    assert_eq!(final_report["snapshot_complete"], false);
    assert_eq!(final_report["recovery_ready"], false);
    assert_eq!(final_report["retained_history_only"], true);
    restart.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_refuse_wrong_context_active_records_and_conflicting_ids_atomically(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let root: Root = serde_json::from_value(before["root"].clone()).unwrap();
    let valid = later_stop(&f, &root.delegated[ORIGIN], 100);
    let mut cases = Vec::new();
    let original = valid.object().to_json();
    for (field, value) in [
        ("account_id", json!("another-account")),
        ("genesis_hash", json!("f".repeat(64))),
        ("origin", json!("https://other.example")),
        ("signer", json!("service:svc-test")),
    ] {
        let mut wrong = original.clone();
        wrong["body"][field] = value;
        cases.push(wrong);
    }
    cases.push(
        record(
            &f,
            &root.delegated[ORIGIN],
            &uuid::Uuid::new_v4().to_string(),
            ControlAction::Release,
        )
        .object()
        .to_json(),
    );
    let mut conflicting = original.clone();
    conflicting["body"]["interrupt_running"] = json!(false);
    cases.push(conflicting);
    let mut retained_collision = original.clone();
    retained_collision["body"]["record_id"] =
        root.delegated[ORIGIN].records[1]["body"]["record_id"].clone();
    cases.push(retained_collision);
    for wrong in cases {
        assert!(retain(
            &database.pool,
            &binding,
            &genesis,
            &input(&plan, vec![original.clone(), wrong])
        )
        .await
        .is_err());
        assert_eq!(state(&database.pool).await, before);
    }
    for key in ["plan_id", "source_hash"] {
        let mut wrong_plan = plan.clone();
        wrong_plan[key] = json!("wrong");
        assert!(retain(
            &database.pool,
            &binding,
            &genesis,
            &input(&wrong_plan, vec![original.clone()])
        )
        .await
        .is_err());
    }
    let too_many = input(&plan, vec![original.clone(); 65]);
    assert!(retain(&database.pool, &binding, &genesis, &too_many)
        .await
        .is_err());
    let admitted = retain(
        &database.pool,
        &binding,
        &genesis,
        &input(&plan, vec![original]),
    )
    .await
    .unwrap();
    let saved = state(&database.pool).await;
    let mut conflict = valid.body().clone();
    conflict.issued_at += 1;
    let signed = build_control(&f.keys, &KeyId::new("manager"), &conflict)
        .unwrap()
        .to_json();
    assert!(retain(
        &database.pool,
        &binding,
        &genesis,
        &input(&plan, vec![signed])
    )
    .await
    .is_err());
    assert_eq!(state(&database.pool).await, saved);
    assert_eq!(
        prepare(&database.pool, &binding, &genesis).await.unwrap(),
        admitted
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_keep_unknown_authority_unresolved_and_commit_failures_invisible(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let root: Root = serde_json::from_value(before["root"].clone()).unwrap();
    let mut candidate = later_stop(&f, &root.delegated[ORIGIN], 100)
        .object()
        .to_json();
    candidate["body"]["signer"] = json!("member:unknown-manager");
    let bytes = input(&plan, vec![candidate]);
    sqlx::query("CREATE FUNCTION fail_stop_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test recovery stop commit failure'; END $$").execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_stop_commit AFTER INSERT ON station_delegated_recovered_stops DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_stop_commit()").execute(&database.pool).await.unwrap();
    assert!(retain(&database.pool, &binding, &genesis, &bytes)
        .await
        .is_err());
    assert_eq!(state(&database.pool).await, before);
    sqlx::query("DROP TRIGGER fail_stop_commit ON station_delegated_recovered_stops")
        .execute(&database.pool)
        .await
        .unwrap();
    let result = retain(&database.pool, &binding, &genesis, &bytes)
        .await
        .unwrap();
    assert_eq!(
        result["recovered_stops"]["records"][0]["verification"],
        "pending:signer_unknown"
    );
    assert_eq!(
        result["recovered_stops"]["records"][0]["requirement"],
        "authority_review"
    );
    assert_eq!(
        result["recovered_stops"]["observed_issued_at_lower_bounds"],
        json!({})
    );
    assert_eq!(result["snapshot_complete"], false);
    assert_eq!(state(&database.pool).await["fences"], before["fences"]);
    assert_eq!(state(&database.pool).await["root"], before["root"]);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_require_original_source_and_closed_current_fence() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    let before = state(&database.pool).await;
    let root: Root = serde_json::from_value(before["root"].clone()).unwrap();
    let object = later_stop(&f, &root.delegated[ORIGIN], 100)
        .object()
        .to_json();
    let missing = input(
        &json!({"plan_id":"missing","source_hash":"missing"}),
        vec![object.clone()],
    );
    assert!(retain(&database.pool, &binding, &genesis, &missing)
        .await
        .is_err());
    assert_eq!(state(&database.pool).await, before);
    binding.initialize(&database.pool, true).await.unwrap();
    assert!(retain(&database.pool, &binding, &genesis, &missing)
        .await
        .is_err());
    assert!(state(&database.pool).await["plans"]
        .as_array()
        .unwrap()
        .is_empty());
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let input = input(&plan, vec![object]);
    for mutation in ["UPDATE remote_recovery_roots SET account_subject='other-owner'", "UPDATE remote_recovery_roots SET state=jsonb_set(state, ARRAY['delegated','https://station-dev.agora.build','signing_high_water','service:reserved-only'], '9999999999999')"] {
        let mut tx = database.pool.begin().await.unwrap();
        // Commit the fault so the operation on another connection must see it.
        sqlx::query(mutation).execute(&mut *tx).await.unwrap(); tx.commit().await.unwrap();
        let changed = state(&database.pool).await;
        assert!(retain(&database.pool, &binding, &genesis, &input).await.is_err());
        assert_eq!(state(&database.pool).await, changed);
        sqlx::query("UPDATE remote_recovery_roots SET account_subject='alice',state=$1").bind(&before["root"]).execute(&database.pool).await.unwrap();
    }
    let stale = Binding::new(ORIGIN, 2).unwrap();
    assert!(retain(&database.pool, &stale, &genesis, &input)
        .await
        .is_err());
    sqlx::query("UPDATE station_delegated_recovery SET ready=true")
        .execute(&database.pool)
        .await
        .unwrap();
    let changed = state(&database.pool).await;
    assert!(retain(&database.pool, &binding, &genesis, &input)
        .await
        .is_err());
    assert_eq!(state(&database.pool).await, changed);
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_refuse_corrupt_or_oversize_saved_evidence_without_partial_reports(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let before = state(&database.pool).await;
    let root: Root = serde_json::from_value(before["root"].clone()).unwrap();
    let record = later_stop(&f, &root.delegated[ORIGIN], 100)
        .object()
        .to_json();
    let input = input(&plan, vec![record.clone()]);
    retain(&database.pool, &binding, &genesis, &input)
        .await
        .unwrap();
    for mutation in ["UPDATE station_delegated_recovered_stops SET record_id='wrong'", "UPDATE station_delegated_recovered_stops SET record=jsonb_set(record,'{body,account_id}', '\"foreign\"')", "UPDATE station_delegated_recovered_stops SET record=jsonb_set(record,'{padding}',to_jsonb(repeat('x',16777216)))"] {
        sqlx::query(mutation).execute(&database.pool).await.unwrap();
        let corrupt = state(&database.pool).await;
        assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
        assert!(retain(&database.pool, &binding, &genesis, &input).await.is_err());
        assert_eq!(state(&database.pool).await, corrupt);
        sqlx::query("UPDATE station_delegated_recovered_stops SET record_id=$1,record=$2").bind(record["body"]["record_id"].as_str().unwrap()).bind(&record).execute(&database.pool).await.unwrap();
    }
    sqlx::query("INSERT INTO station_delegated_recovered_stops(plan_id,record_id,record) SELECT $1,'over-limit-'||i::text,$2 FROM generate_series(1,4096) i")
        .bind(plan["plan_id"].as_str().unwrap()).bind(&record).execute(&database.pool).await.unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert!(retain(&database.pool, &binding, &genesis, &input)
        .await
        .is_err());
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovered_stops_survive_later_generations_and_keep_host_intents_feed_independent(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (store, mut f, genesis, binding) = retained(&database).await;
    let action = atem_client::membership::host_sender_revoke("host-a", false, f.created).unwrap();
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft("phone", f.created, &action),
    )
    .unwrap();
    let appended = f.log.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(appended.appended, 1);
    f.log = appended.next;
    let mut root: Root =
        serde_json::from_value(state(&database.pool).await["root"].clone()).unwrap();
    root.membership = f.log.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$1")
        .bind(serde_json::to_value(root).unwrap())
        .execute(&database.pool)
        .await
        .unwrap();
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let body = ControlBody {
        account_id: f.log.account_id().into(),
        genesis_hash: f.log.genesis_hash(),
        feed: None,
        principal: ControlPrincipal::Host("host-a".into()),
        principal_key: None,
        signer: ControlSigner::Member("phone".into()),
        action: ControlAction::InterruptRunning {
            revoke_seq: Some(f.log.head().seq),
        },
        record_id: uuid::Uuid::new_v4().to_string(),
        issued_at: f.created + 100,
        about: ControlAbout {
            integration_id: None,
            by: "owner".into(),
        },
    };
    let record = build_control(&f.keys, &KeyId::new("manager"), &body)
        .unwrap()
        .to_json();
    let first = retain(
        &database.pool,
        &binding,
        &genesis,
        &input(&plan, vec![record.clone()]),
    )
    .await
    .unwrap();
    assert_eq!(
        first["recovered_stops"]["records"][0]["requirement"],
        "retain_host_record"
    );
    assert_eq!(
        first["recovered_stops"]["records"][0]["revoke_seq"],
        f.log.head().seq
    );
    let before = state(&database.pool).await;
    let second_binding = Binding::new(ORIGIN, 2).unwrap();
    second_binding
        .initialize(&database.pool, true)
        .await
        .unwrap();
    let next = prepare(&database.pool, &second_binding, &genesis)
        .await
        .unwrap();
    assert_ne!(next["plan_id"], first["plan_id"]);
    assert_eq!(next["recovered_stops"], first["recovered_stops"]);
    assert_eq!(state(&database.pool).await["stops"], before["stops"]);
    assert_eq!(state(&database.pool).await["root"], before["root"]);
    assert_eq!(
        retain(
            &database.pool,
            &second_binding,
            &genesis,
            &input(&next, vec![record])
        )
        .await
        .unwrap(),
        next
    );
    assert_eq!(
        state(&database.pool).await["stops"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    sqlx::query("INSERT INTO station_delegated_recovered_stops(plan_id,record_id,record) SELECT $1,record_id,jsonb_set(record,'{body,about,by}','\"reconciled\"') FROM station_delegated_recovered_stops")
        .bind(next["plan_id"].as_str().unwrap()).execute(&database.pool).await.unwrap();
    let conflicting = state(&database.pool).await;
    assert!(prepare(&database.pool, &second_binding, &genesis)
        .await
        .is_err());
    assert_eq!(state(&database.pool).await, conflicting);
    sqlx::query("DELETE FROM station_delegated_recovered_stops WHERE plan_id=$1")
        .bind(next["plan_id"].as_str().unwrap())
        .execute(&database.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE station_delegated_recovered_stops SET record=jsonb_set(record,'{body,account_id}','\"foreign\"')").execute(&database.pool).await.unwrap();
    assert!(prepare(&database.pool, &second_binding, &genesis)
        .await
        .is_err());
    drop(store);
    database.cleanup().await;
}
