use super::super::super::delegated_recovery::{
    plan::{native::retain, prepare},
    Binding,
};
use super::recovery_plan::retained;
use super::*;
use crate::test_database::TestDatabase;

fn archive(f: &Fixture, records: Vec<Value>, unsigned: Vec<Value>) -> Value {
    let destinations: serde_json::Map<String, Value> = records
        .iter()
        .map(|record| &record["body"])
        .chain(unsigned.iter())
        .map(|body| (body["record_id"].as_str().unwrap().into(), json!([ORIGIN])))
        .collect();
    json!({"type":"astation-native-control-recovery-evidence", "version":1,
        "account_id":f.log.account_id(), "genesis_hash":f.log.genesis_hash().to_hex(), "station_origin":ORIGIN,
        "destinations":destinations, "retained_history_only":true, "complete_history":false,
        "signing_clock_complete":false, "snapshot_complete":false, "records":records, "unsigned_reviews":unsigned})
}

async fn state(pool: &sqlx::PgPool) -> Value {
    let mut result = json!({});
    for table in [
        "remote_recovery_roots",
        "station_delegated_recovery",
        "station_delegated_recovery_plans",
        "station_delegated_recovered_stops",
        "station_delegated_native_recovery",
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

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_archive_retains_all_pages_intents_and_destinations_across_restarts(
) {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let plan_id = plan["plan_id"].as_str().unwrap();
    let before = state(&database.pool).await;
    let original = &before["remote_recovery_roots"][0]["state"]["delegated"][ORIGIN]["records"][1];
    let body = ControlRecord::parse(&serde_json::to_vec(original).unwrap())
        .unwrap()
        .body()
        .clone();
    let mut records = Vec::new();
    for offset in 1..=65 {
        let mut next = body.clone();
        next.record_id = uuid::Uuid::new_v4().to_string();
        next.issued_at += offset;
        records.push(
            build_control(&f.keys, &KeyId::new("manager"), &next)
                .unwrap()
                .to_json(),
        );
    }
    let mut pending = body;
    pending.principal = ControlPrincipal::Host("host-a".into());
    pending.principal_key = None;
    pending.feed = None;
    pending.about.integration_id = None;
    pending.action = ControlAction::InterruptRunning {
        revoke_seq: Some(1),
    };
    pending.record_id = uuid::Uuid::new_v4().to_string();
    pending.issued_at += 100_000;
    let mut input = archive(&f, records, vec![pending.to_json()]);
    input["destinations"][&pending.record_id] = json!([ORIGIN, "https://other.example"]);
    let bytes = serde_json::to_vec(&input).unwrap();
    let other = database.reconnect(2).await;
    let (first, second) = tokio::join!(
        retain(&database.pool, &binding, &genesis, plan_id, &bytes),
        retain(&other, &binding, &genesis, plan_id, &bytes)
    );
    let first = first.unwrap();
    assert_eq!(second.unwrap(), first);
    assert_eq!(
        first["recovered_stops"]["records"]
            .as_array()
            .unwrap()
            .len(),
        65
    );
    let summary = &first["native_archives"]["archives"][0];
    assert_eq!(
        summary["unsigned_reviews"][0]["record_id"],
        pending.record_id
    );
    assert_eq!(
        summary["unsigned_reviews"][0]["requirement"],
        "unsigned_owner_intent"
    );
    assert_eq!(summary["destinations"], input["destinations"]);
    assert_eq!(
        first["native_archives"]["unsigned_intent_is_authority"],
        false
    );
    assert!(
        first["known_history"]["observed_signing_lower_bounds"]
            .get("host:host-a")
            .is_none(),
        "unsigned future-dated intent must never advance a signing-clock anchor"
    );
    assert_ne!(first["evidence_hash"], plan["evidence_hash"]);
    assert_eq!(first["snapshot_complete"], false);
    assert_eq!(first["recovery_ready"], false);
    let after = state(&database.pool).await;
    assert_eq!(
        after["station_delegated_native_recovery"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        after["station_delegated_native_recovery"][0]["archive"],
        input
    );
    for table in [
        "remote_recovery_roots",
        "station_delegated_recovery",
        "station_delegated_recovery_plans",
    ] {
        assert_eq!(after[table], before[table], "{table}");
    }
    other.close().await;
    let restart = database.reconnect(2).await;
    assert_eq!(prepare(&restart, &binding, &genesis).await.unwrap(), first);
    let later = Binding::new(ORIGIN, 2).unwrap();
    later.initialize(&restart, true).await.unwrap();
    let next = prepare(&restart, &later, &genesis).await.unwrap();
    assert_eq!(next["native_archives"], first["native_archives"]);
    assert_eq!(next["recovered_stops"], first["recovered_stops"]);
    restart.close().await;
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_archive_refuses_corrupt_foreign_and_excess_retained_history() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let plan_id = plan["plan_id"].as_str().unwrap();
    let original = state(&database.pool).await["remote_recovery_roots"][0]["state"]["delegated"]
        [ORIGIN]["records"][1]
        .clone();
    let mut body = ControlBody::from_json(&original["body"]).unwrap();
    body.record_id = uuid::Uuid::new_v4().to_string();
    let original = build_control(&f.keys, &KeyId::new("manager"), &body)
        .unwrap()
        .to_json();
    let input = archive(&f, vec![original.clone()], vec![]);
    let bytes = serde_json::to_vec(&input).unwrap();
    retain(&database.pool, &binding, &genesis, plan_id, &bytes)
        .await
        .unwrap();
    let stored: (String, Value) =
        sqlx::query_as("SELECT evidence_hash,archive FROM station_delegated_native_recovery")
            .fetch_one(&database.pool)
            .await
            .unwrap();
    for (field, value) in [
        ("complete_history", json!(true)),
        ("account_id", json!("foreign")),
        ("station_origin", json!("https://foreign.example")),
    ] {
        let mut corrupt = input.clone();
        corrupt[field] = value;
        sqlx::query("UPDATE station_delegated_native_recovery SET archive=$1")
            .bind(corrupt)
            .execute(&database.pool)
            .await
            .unwrap();
        let before = state(&database.pool).await;
        assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
        assert_eq!(state(&database.pool).await, before);
    }
    sqlx::query("UPDATE station_delegated_native_recovery SET archive=$1")
        .bind(&stored.1)
        .execute(&database.pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM station_delegated_recovered_stops")
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(
        prepare(&database.pool, &binding, &genesis).await.is_err(),
        "an archive's signed stop cannot disappear from reconciled history"
    );
    sqlx::query(
        "INSERT INTO station_delegated_recovered_stops(plan_id,record_id,record) VALUES ($1,$2,$3)",
    )
    .bind(plan_id)
    .bind(original["body"]["record_id"].as_str().unwrap())
    .bind(&original)
    .execute(&database.pool)
    .await
    .unwrap();
    // Aggregate bounds are checked before fetching/parsing any archive body.
    sqlx::query("INSERT INTO station_delegated_native_recovery(plan_id,evidence_hash,archive) SELECT $1,n::text,$2 FROM generate_series(1,128) n")
        .bind(plan_id).bind(&input).execute(&database.pool).await.unwrap();
    let before = state(&database.pool).await;
    assert!(prepare(&database.pool, &binding, &genesis).await.is_err());
    assert!(retain(&database.pool, &binding, &genesis, plan_id, &bytes)
        .await
        .is_err());
    assert_eq!(state(&database.pool).await, before);
    sqlx::query("DELETE FROM station_delegated_native_recovery WHERE evidence_hash<>$1")
        .bind(stored.0)
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(prepare(&database.pool, &binding, &genesis).await.is_ok());
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_unsigned_history_cannot_be_rewritten_by_later_archives() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let plan_id = plan["plan_id"].as_str().unwrap();
    let original = state(&database.pool).await["remote_recovery_roots"][0]["state"]["delegated"]
        [ORIGIN]["records"][1]
        .clone();
    let mut body = ControlBody::from_json(&original["body"]).unwrap();
    body.record_id = uuid::Uuid::new_v4().to_string();
    let input = archive(&f, vec![], vec![body.to_json()]);
    let first = retain(
        &database.pool,
        &binding,
        &genesis,
        plan_id,
        &serde_json::to_vec(&input).unwrap(),
    )
    .await
    .unwrap();
    assert!(first["recovered_stops"]["records"]
        .as_array()
        .unwrap()
        .is_empty());
    let before = state(&database.pool).await;
    let mut changed = body.clone();
    changed.issued_at += 1;
    let signed_change = build_control(&f.keys, &KeyId::new("manager"), &changed)
        .unwrap()
        .to_json();
    for conflict in [
        archive(&f, vec![], vec![changed.to_json()]),
        archive(&f, vec![signed_change], vec![]),
    ] {
        assert!(retain(
            &database.pool,
            &binding,
            &genesis,
            plan_id,
            &serde_json::to_vec(&conflict).unwrap()
        )
        .await
        .is_err());
        assert_eq!(
            state(&database.pool).await,
            before,
            "later evidence cannot rewrite an earlier review body"
        );
    }
    let signed = build_control(&f.keys, &KeyId::new("manager"), &body)
        .unwrap()
        .to_json();
    let signed_archive = archive(&f, vec![signed], vec![]);
    let next = retain(
        &database.pool,
        &binding,
        &genesis,
        plan_id,
        &serde_json::to_vec(&signed_archive).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(
        next["recovered_stops"]["records"].as_array().unwrap().len(),
        1
    );
    assert_eq!(
        next["native_archives"]["archives"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        next["recovery_ready"], false,
        "a later actual signature still grants no readiness"
    );
    assert_eq!(
        state(&database.pool).await["station_delegated_native_recovery"][0]["archive"]
            ["unsigned_reviews"],
        input["unsigned_reviews"]
    );
    drop(store);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_archive_refuses_conflicts_atomically_and_never_opens_a_fence() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
    let (store, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = prepare(&database.pool, &binding, &genesis).await.unwrap();
    let plan_id = plan["plan_id"].as_str().unwrap();
    let before = state(&database.pool).await;
    let original =
        before["remote_recovery_roots"][0]["state"]["delegated"][ORIGIN]["records"][1].clone();
    let mut unsigned = original["body"].clone();
    unsigned["issued_at"] = json!(f.created + 1);
    let mut fresh = ControlBody::from_json(&original["body"]).unwrap();
    fresh.record_id = uuid::Uuid::new_v4().to_string();
    let fresh = build_control(&f.keys, &KeyId::new("manager"), &fresh)
        .unwrap()
        .to_json();
    let conflict = archive(&f, vec![fresh], vec![unsigned]);
    assert!(retain(
        &database.pool,
        &binding,
        &genesis,
        plan_id,
        &serde_json::to_vec(&conflict).unwrap()
    )
    .await
    .is_err());
    assert_eq!(
        state(&database.pool).await,
        before,
        "archive and valid signed prefix both roll back"
    );
    let valid = archive(&f, vec![original], vec![]);
    let mut invalids = Vec::new();
    for (field, value) in [
        ("account_id", json!("foreign")),
        ("genesis_hash", json!("0".repeat(64))),
        ("station_origin", json!("https://other.example")),
        ("complete_history", json!(true)),
    ] {
        let mut input = valid.clone();
        input[field] = value;
        invalids.push(input);
    }
    for input in invalids {
        assert!(retain(
            &database.pool,
            &binding,
            &genesis,
            plan_id,
            &serde_json::to_vec(&input).unwrap()
        )
        .await
        .is_err());
        assert_eq!(state(&database.pool).await, before);
    }
    assert!(retain(
        &database.pool,
        &binding,
        &genesis,
        &uuid::Uuid::new_v4().to_string(),
        &serde_json::to_vec(&valid).unwrap()
    )
    .await
    .is_err());
    assert_eq!(state(&database.pool).await, before);
    // Fail the final commit after insertion, exercising both tables' atomicity.
    sqlx::query("CREATE FUNCTION reject_native_archive() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit fault'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER reject_native_archive AFTER INSERT ON station_delegated_native_recovery DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_native_archive()")
        .execute(&database.pool).await.unwrap();
    assert!(retain(
        &database.pool,
        &binding,
        &genesis,
        plan_id,
        &serde_json::to_vec(&valid).unwrap()
    )
    .await
    .is_err());
    assert_eq!(state(&database.pool).await, before);
    drop(store);
    database.cleanup().await;
}
