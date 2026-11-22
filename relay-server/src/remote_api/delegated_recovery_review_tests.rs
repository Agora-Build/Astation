use super::recovery_plan::retained;
use super::*;
use crate::remote_api::recovery::delegated_recovery::{inspect, plan, Binding};
use crate::test_database::TestDatabase;
use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use std::sync::Arc;
use tower::ServiceExt;

fn make_app(store: Arc<RecoveryStore>) -> crate::AppState {
    let mut app = crate::tests::test_state();
    app.recovery = store;
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    app
}

async fn http(app: &crate::AppState, genesis: &str, owner: Option<&str>) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .uri(format!("/api/remote/v1/logs/{genesis}/control/recovery"))
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
    assert_eq!(response.headers()["cache-control"], "no-store");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 8192).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

async fn saved(pool: &sqlx::PgPool, genesis: &str) -> Value {
    sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
        .bind(genesis)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn retain_http(app: &crate::AppState, genesis: &str, plan: &str, owner: Option<&str>, bytes: Vec<u8>) -> (StatusCode, Value) {
    let mut request = Request::builder().method("POST")
        .uri(format!("/api/remote/v1/logs/{genesis}/control/recovery/{plan}/signatures"))
        .extension(axum::extract::ConnectInfo("127.0.0.1:40001".parse::<std::net::SocketAddr>().unwrap()));
    if let Some(owner) = owner { request = request.header("authorization", format!("Bearer {owner}")); }
    let response = crate::router(app.clone()).oneshot(request.body(Body::from(bytes)).unwrap()).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 8192).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

fn copy_input(f: &Fixture, plan: &Value, root: &Value) -> Value {
    let original = ControlRecord::parse(&serde_json::to_vec(&root["delegated"][ORIGIN]["records"][1]).unwrap()).unwrap();
    let mut body = original.body().clone();
    body.feed = Some(ControlFeed { origin: ORIGIN.into(), feed_id: plan["candidate_feed_id"].as_str().unwrap().into() });
    body.record_id = uuid::Uuid::new_v4().to_string();
    body.issued_at = f.created + 1000;
    let copy = build_control(&f.keys, &KeyId::new("manager"), &body).unwrap();
    json!({"evidence_hash":plan["evidence_hash"],"replacements":[{"original_record_id":original.record_id(),"record":copy.to_json()}]})
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_recovery_retention_is_private_durable_and_retries_without_publishing() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (_, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let id = plan["plan_id"].as_str().unwrap();
    let before = saved(&database.pool, &genesis).await;
    let input = copy_input(&f, &plan, &before);
    let bytes = serde_json::to_vec(&input).unwrap();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    assert_eq!(retain_http(&app, &genesis, id, None, bytes.clone()).await.0, StatusCode::UNAUTHORIZED);
    let missing = retain_http(&app, &"a".repeat(64), id, Some("alice"), bytes.clone()).await;
    assert_eq!(missing.0, StatusCode::NOT_FOUND);
    assert_eq!(retain_http(&app, &genesis, id, Some("bob"), bytes.clone()).await, missing);
    let (status, receipt) = retain_http(&app, &genesis, id, Some("alice"), bytes.clone()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(receipt["record_ids"], json!([input["replacements"][0]["record"]["body"]["record_id"]]));
    assert_eq!(receipt["account_id"], f.log.account_id());
    assert_eq!(receipt["genesis_hash"], genesis);
    assert_eq!(receipt["origin"], ORIGIN);
    assert_eq!(receipt["generation"], "1");
    assert_eq!(receipt["plan_id"], id);
    assert_eq!(receipt["evidence_hash"], plan["evidence_hash"]);
    assert_ne!(receipt["reconstruction_hash"], plan["reconstruction_hash"]);
    assert_eq!(receipt["retained_only"], true);
    assert_eq!(receipt["recovery_ready"], false);
    assert_eq!(receipt.as_object().unwrap().len(), 11);
    let restarted = RecoveryStore::postgres(database.reconnect(2).await);
    restarted.configure_recovery_review(ORIGIN, 1).await.unwrap();
    assert_eq!(retain_http(&make_app(restarted), &genesis, id, Some("alice"), bytes.clone()).await, (status, receipt));
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_recovery_signatures").fetch_one(&database.pool).await.unwrap();
    assert_eq!(count, 1);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&database.pool, true).await.unwrap();
    assert_eq!(retain_http(&app, &genesis, id, Some("alice"), bytes).await.0, StatusCode::SERVICE_UNAVAILABLE);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_native_recovery_retention_refuses_invalid_inputs_and_failed_commits() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (_, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let id = plan["plan_id"].as_str().unwrap();
    let before = saved(&database.pool, &genesis).await;
    let input = copy_input(&f, &plan, &before);
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    assert_eq!(retain_http(&app, &genesis, id, Some("alice"), vec![b' '; 262_145]).await.0, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(retain_http(&app, &genesis, id, Some("alice"), br#"{"replacements":[],"replacements":[]}"#.to_vec()).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(retain_http(&app, &genesis, "invalid", Some("alice"), vec![]).await.0, StatusCode::BAD_REQUEST);
    for mutation in ["signature", "evidence", "intent"] {
        let mut bad = input.clone();
        match mutation {
            "signature" => bad["replacements"][0]["record"]["sig"] = json!("a".repeat(86)),
            "evidence" => bad["evidence_hash"] = json!("0".repeat(64)),
            _ => bad["replacements"][0]["record"]["body"]["action"] = json!("release"),
        }
        assert_eq!(retain_http(&app, &genesis, id, Some("alice"), serde_json::to_vec(&bad).unwrap()).await.0, StatusCode::SERVICE_UNAVAILABLE);
    }
    sqlx::raw_sql("CREATE FUNCTION reject_native_retention() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected commit failure'; END $$; \
        CREATE CONSTRAINT TRIGGER reject_native_retention AFTER INSERT ON station_delegated_recovery_signatures \
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_native_retention();")
        .execute(&database.pool).await.unwrap();
    assert_eq!(retain_http(&app, &genesis, id, Some("alice"), serde_json::to_vec(&input).unwrap()).await.0, StatusCode::SERVICE_UNAVAILABLE);
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_recovery_signatures").fetch_one(&database.pool).await.unwrap();
    assert_eq!(count, 0);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_review_is_account_private_read_only_and_survives_restart() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let prepared = plan::prepare(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    assert!(!store.delegated_enabled());
    assert!(store.configure_delegated(ORIGIN, 1).await.is_err());
    let app = make_app(store.clone());
    let before = saved(&database.pool, &genesis).await;
    assert_eq!(http(&app, &genesis, None).await.0, StatusCode::UNAUTHORIZED);
    let missing = http(&app, &"a".repeat(64), Some("alice")).await;
    assert_eq!(missing.0, StatusCode::NOT_FOUND);
    assert_eq!(http(&app, &genesis, Some("bob")).await, missing);
    let (status, review) = http(&app, &genesis, Some("alice")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(review["account_id"], f.log.account_id());
    assert_eq!(review["membership_head"], f.log.head().to_json());
    for key in [
        "plan_id",
        "candidate_feed_id",
        "source_hash",
        "evidence_hash",
        "reconstruction_hash",
    ] {
        assert_eq!(review[key], prepared[key]);
    }
    assert_eq!(review["generation"], "1");
    assert_eq!(review["retained_history_only"], true);
    for key in [
        "complete_history",
        "signing_clock_complete",
        "snapshot_complete",
        "recovery_ready",
    ] {
        assert_eq!(review[key], false);
    }
    assert_eq!(review.as_object().unwrap().len(), 16);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert_eq!(
        plan::prepare(&database.pool, &binding, &genesis)
            .await
            .unwrap(),
        prepared
    );
    assert_eq!(
        store
            .delegated_operation(&genesis, "alice", Command::Ensure)
            .await
            .0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert!(
        !inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    let restarted = RecoveryStore::postgres(database.reconnect(2).await);
    restarted
        .configure_recovery_review(ORIGIN, 1)
        .await
        .unwrap();
    assert_eq!(
        http(&make_app(restarted), &genesis, Some("alice")).await,
        (status, review)
    );
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_review_never_creates_missing_plans_or_initializes_a_fence() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, _, genesis, binding) = retained(&database).await;
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    assert!(store.configure_recovery_review(ORIGIN, 1).await.is_err());
    assert!(
        inspect(&database.pool, ORIGIN)
            .await
            .unwrap()
            .unwrap()
            .ready
    );
    binding.initialize(&database.pool, true).await.unwrap();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    assert_eq!(
        http(&make_app(store), &genesis, Some("alice")).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_recovery_plans")
        .fetch_one(&database.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
    let unknown = "https://other.example";
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    assert!(store.configure_recovery_review(unknown, 2).await.is_err());
    assert!(inspect(&database.pool, unknown).await.unwrap().is_none());
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_review_refuses_changed_source_and_stale_generation() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, _, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    plan::prepare(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    assert_eq!(http(&app, &genesis, Some("alice")).await.0, StatusCode::OK);
    let before = saved(&database.pool, &genesis).await;
    let mut changed = before.clone();
    changed["delegated"][ORIGIN]["signing_high_water"]["service:reserved-only"] =
        json!(now().wall_ms + 1000);
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&changed)
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(
        http(&app, &genesis, Some("alice")).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(saved(&database.pool, &genesis).await, changed);
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&before)
        .execute(&database.pool)
        .await
        .unwrap();
    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&database.pool, true).await.unwrap();
    assert_eq!(
        http(&app, &genesis, Some("alice")).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(saved(&database.pool, &genesis).await, before);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_review_updates_evidence_and_preserves_large_generations() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, f, genesis, _) = retained(&database).await;
    let generation = 9_007_199_254_740_991;
    let binding = Binding::new(ORIGIN, generation).unwrap();
    binding.initialize(&database.pool, true).await.unwrap();
    let before = plan::prepare(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store
        .configure_recovery_review(ORIGIN, generation)
        .await
        .unwrap();
    let app = make_app(store);
    assert_eq!(
        http(&app, &genesis, Some("alice")).await.1["generation"],
        generation.to_string()
    );
    let root: Root = serde_json::from_value(saved(&database.pool, &genesis).await).unwrap();
    let mut body = record(
        &f,
        &root.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: true,
        },
    )
    .body()
    .clone();
    body.signer = ControlSigner::Member("phone".into());
    let original = build_control(&f.keys, &KeyId::new("manager"), &body).unwrap();
    let input = serde_json::to_vec(
        &json!({ "plan_id": before["plan_id"], "source_hash": before["source_hash"],
        "records": [original.to_json()] }),
    )
    .unwrap();
    let after = plan::stops::retain(&database.pool, &binding, &genesis, &input)
        .await
        .unwrap();
    let (_, review) = http(&app, &genesis, Some("alice")).await;
    assert_eq!(review["source_hash"], before["source_hash"]);
    assert_ne!(review["evidence_hash"], before["evidence_hash"]);
    assert_eq!(review["evidence_hash"], after["evidence_hash"]);
    assert_eq!(review["reconstruction_hash"], after["reconstruction_hash"]);
    database.cleanup().await;
}
