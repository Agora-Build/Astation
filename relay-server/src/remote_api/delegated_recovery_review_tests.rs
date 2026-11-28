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
    get_recovery(app, &format!("/api/remote/v1/logs/{genesis}/control/recovery"), owner).await
}

async fn get_recovery(app: &crate::AppState, path: &str, owner: Option<&str>) -> (StatusCode, Value) {
    get_recovery_bounded(app, path, owner, 8192).await
}

async fn get_recovery_bounded(app: &crate::AppState, path: &str, owner: Option<&str>, max_bytes: usize) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .uri(path)
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
    let bytes = to_bytes(response.into_body(), max_bytes).await.unwrap();
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
    post_recovery(app, &format!("/api/remote/v1/logs/{genesis}/control/recovery/{plan}/signatures"), owner, bytes).await
}

async fn post_recovery(app: &crate::AppState, path: &str, owner: Option<&str>, bytes: Vec<u8>) -> (StatusCode, Value) {
    let mut request = Request::builder().method("POST").uri(path)
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
async fn postgres_delegated_copy_reservation_rechecks_the_original_manager_and_clock_across_replicas() {
    let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, mut f, genesis, binding) = retained(&db).await;
    binding.initialize(&db.pool, true).await.unwrap();
    plan::prepare(&db.pool, &binding, &genesis).await.unwrap();
    let mut root = saved(&db.pool, &genesis).await;
    let original = root["delegated"][ORIGIN]["records"][1].clone();
    f.log = super::recovery_plan::demote_manager(&mut f);
    root["membership"] = f.log.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis).bind(&root).execute(&db.pool).await.unwrap();
    let cut = plan::prepare(&db.pool, &binding, &genesis).await.unwrap();
    let app_on = async |pool| {
        let store = RecoveryStore::postgres(pool);
        store.configure_recovery_review(ORIGIN, 1).await.unwrap();
        make_app(store)
    };
    let a = app_on(db.pool.clone()).await;
    let b = app_on(db.reconnect(2).await).await;
    let url = format!("/api/remote/v1/logs/{genesis}/control/recovery/copy-reservations");
    let send = async |app: &crate::AppState, owner: Option<&str>, value: &Value| {
        post_recovery(app, &url, owner, value.to_string().into_bytes()).await
    };
    use ring::digest::{digest, SHA256};
    let hash: String = digest(&SHA256, atem_client::canonical::jcs(&original).unwrap().as_bytes())
        .as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    let request = json!({"manager":"replacement-manager","original_record_id":original["body"]["record_id"],
        "original_hash":hash,"expected":f.log.head().to_json(),"recovery":{"generation":"1","plan_id":cut["plan_id"],
        "candidate_feed_id":cut["candidate_feed_id"],"source_hash":cut["source_hash"],"evidence_hash":cut["evidence_hash"]}});
    assert_eq!(send(&a, None, &request).await.0, StatusCode::UNAUTHORIZED);
    let foreign = send(&a, Some("bob"), &request).await;
    assert_eq!(foreign.0, StatusCode::NOT_FOUND);
    assert_eq!(post_recovery(&a, &url.replace(&genesis, &"a".repeat(64)), Some("alice"), request.to_string().into_bytes()).await, foreign);
    for (key, value) in [("manager", json!("phone")), ("original_hash", json!("a".repeat(64))), ("issued_at", json!(42))] {
        let mut stale = request.clone(); stale[key] = value;
        assert_eq!(send(&a, Some("alice"), &stale).await.0, StatusCode::CONFLICT);
    }
    sqlx::raw_sql("CREATE FUNCTION reject_copy_reservation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'failed'; END $$;
        CREATE CONSTRAINT TRIGGER reject_copy AFTER INSERT ON station_delegated_copy_reservations DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION reject_copy_reservation()").execute(&db.pool).await.unwrap();
    assert_eq!(send(&a, Some("alice"), &request).await.0, StatusCode::SERVICE_UNAVAILABLE);
    sqlx::query("DROP TRIGGER reject_copy ON station_delegated_copy_reservations").execute(&db.pool).await.unwrap();
    let (one, two) = tokio::join!(send(&a, Some("alice"), &request), send(&b, Some("alice"), &request));
    assert_eq!(one, two);
    assert_eq!(one.0, StatusCode::OK);
    let time = one.1["issued_at"].as_u64().unwrap();
    assert!(time > original["body"]["issued_at"].as_u64().unwrap());
    let mut exact = request.clone(); exact["issued_at"] = json!(time);
    let mut receipt = exact.clone();
    receipt["account_id"] = json!(f.log.account_id()); receipt["origin"] = json!(ORIGIN);
    receipt["genesis_hash"] = json!(genesis);
    assert_eq!(one.1, receipt);
    assert_eq!(send(&b, Some("alice"), &exact).await, one);
    let mut wrong_time = exact.clone(); wrong_time["issued_at"] = json!(time - 1);
    assert_eq!(send(&a, Some("alice"), &wrong_time).await.0, StatusCode::CONFLICT);
    // The response was lost before this draft reached the Mac's journal. Another
    // draft for the same principal has since raised the Mac's local floor.
    let mut newer = request.clone();
    newer["after_issued_at"] = json!(time);
    let advanced = send(&b, Some("alice"), &newer).await;
    assert_eq!(advanced.0, StatusCode::OK);
    let next = advanced.1["issued_at"].as_u64().unwrap();
    assert!(next > time);
    assert_eq!(send(&a, Some("alice"), &newer).await, advanced);
    assert_eq!(send(&a, Some("alice"), &exact).await.0, StatusCode::CONFLICT);
    exact["issued_at"] = json!(next);
    assert_eq!(send(&a, Some("alice"), &exact).await, advanced);
    let mut future = newer.clone();
    future["after_issued_at"] = json!(9_007_199_254_740_991u64);
    assert_eq!(send(&b, Some("alice"), &future).await.0, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(send(&b, Some("alice"), &exact).await, advanced);
    let mut mixed = exact.clone();
    mixed["after_issued_at"] = json!(time);
    assert_eq!(send(&a, Some("alice"), &mixed).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(plan::prepare(&db.pool, &binding, &genesis).await.unwrap(), cut);
    let mut body = ControlRecord::parse(original.to_string().as_bytes()).unwrap().body().clone();
    body.signer = ControlSigner::Member("replacement-manager".into());
    body.record_id = uuid::Uuid::new_v4().to_string(); body.issued_at = next;
    let copy = build_control(&f.keys, &KeyId::new("replacement-manager"), &body).unwrap();
    let input = json!({"evidence_hash":cut["evidence_hash"], "replacements":[{"original_record_id":request["original_record_id"],
        "record":copy.to_json()}]});
    assert_eq!(retain_http(&b, &genesis, cut["plan_id"].as_str().unwrap(), Some("alice"), input.to_string().into_bytes()).await.0, StatusCode::OK);
    assert_eq!(send(&a, Some("alice"), &exact).await.0, StatusCode::CONFLICT);
    assert!(!inspect(&db.pool, ORIGIN).await.unwrap().unwrap().ready);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_recovery_pages_only_outstanding_former_manager_originals_at_one_review() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let initial = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let mut root = saved(&database.pool, &genesis).await;
    let first = root["delegated"][ORIGIN]["records"][1].clone();
    let original = ControlRecord::parse(first.to_string().as_bytes()).unwrap();
    let mut expected = vec![first];
    for _ in 0..64 {
        let mut body = original.body().clone();
        body.record_id = uuid::Uuid::new_v4().to_string();
        expected.push(build_control(&f.keys, &KeyId::new("manager"), &body).unwrap().to_json());
    }
    let replica = database.reconnect(2).await;
    let reader = RecoveryStore::postgres(replica.clone());
    reader.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(reader);
    let path = |state: &Value, offset: usize| format!("/api/remote/v1/logs/{genesis}/control/recovery/{}/originals?review={}&offset={offset}",
        state["plan_id"].as_str().unwrap(), state["reconstruction_hash"].as_str().unwrap());
    let empty = get_recovery(&app, &path(&initial, 0), Some("alice")).await;
    assert_eq!(empty.0, StatusCode::OK);
    assert_eq!(empty.1["records"], json!([]));
    assert_eq!(empty.1["more"], false);
    f.log = super::recovery_plan::demote_manager(&mut f);
    root["membership"] = f.log.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis).bind(&root).execute(&database.pool).await.unwrap();
    let changed = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let import = |records: Value| json!({"plan_id":changed["plan_id"],"source_hash":changed["source_hash"],"records":records});
    plan::stops::retain(&database.pool, &binding, &genesis, import(json!(&expected[1..])).to_string().as_bytes()).await.unwrap();
    let mut forged = expected[0].clone();
    forged["body"]["record_id"] = json!(uuid::Uuid::new_v4().to_string());
    let cut = plan::stops::retain(&database.pool, &binding, &genesis, import(json!([forged])).to_string().as_bytes()).await.unwrap();
    assert_eq!(get_recovery(&app, &path(&cut,0), None).await.0, StatusCode::UNAUTHORIZED);
    let foreign = get_recovery(&app, &path(&cut,0), Some("bob")).await;
    assert_eq!(foreign.0, StatusCode::NOT_FOUND);
    assert_eq!(foreign, get_recovery(&app, &path(&cut,0).replace(&genesis, &"a".repeat(64)), Some("alice")).await);
    assert_eq!(get_recovery(&app, &path(&initial, 64), Some("alice")).await.0, StatusCode::CONFLICT);
    expected.sort_by(|a, b| a["body"]["record_id"].as_str().cmp(&b["body"]["record_id"].as_str()));
    for (offset, end) in [(0,64), (64,65)] {
        let (status, page) = get_recovery_bounded(&app, &path(&cut, offset), Some("alice"), 262_144).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(page, json!({"plan_id":cut["plan_id"],"reconstruction_hash":cut["reconstruction_hash"],
            "offset":offset,"records":&expected[offset..end],"more":end < 65}));
    }
    // Another replica stores an approved copy. A page of the old review must no longer be served.
    let mut body = original.body().clone();
    body.signer = ControlSigner::Member("replacement-manager".into());
    body.record_id = uuid::Uuid::new_v4().to_string();
    body.issued_at = f.created + 1000;
    let copy = build_control(&f.keys, &KeyId::new("replacement-manager"), &body).unwrap().to_json();
    let batch = json!({"evidence_hash":cut["evidence_hash"],"replacements":[{"original_record_id":original.record_id(),"record":copy}]});
    let current = plan::signatures::retain(&database.pool, &binding, &genesis, cut["plan_id"].as_str().unwrap(), batch.to_string().as_bytes()).await.unwrap();
    assert_eq!(get_recovery(&app, &path(&cut,64), Some("alice")).await.0, StatusCode::CONFLICT);
    let (status, page) = get_recovery_bounded(&app, &path(&current,0), Some("alice"), 262_144).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["more"], false);
    let records = page["records"].as_array().unwrap();
    assert_eq!(records.len(), 64);
    assert!(records.iter().all(|r| r != &original.object().to_json()));
    assert_eq!(saved(&replica, &genesis).await, root);
    replica.close().await;
    database.cleanup().await;
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


#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_signer_challenge_is_private_committed_and_reused_by_other_replicas() {
    use atem_client::member_report::SignerReportChallenge;

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (_, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let endpoint = |root: &str| format!("/api/remote/v1/logs/{root}/control/recovery/signer-challenges");
    let path = endpoint(&genesis);
    let request = json!({"signer":"member:phone","slot":"astation-macos","expected":f.log.head().to_json(),
        "recovery":{"generation":"1","plan_id":plan["plan_id"],"candidate_feed_id":plan["candidate_feed_id"],
            "source_hash":plan["source_hash"],"evidence_hash":plan["evidence_hash"]}});
    let bytes = serde_json::to_vec(&request).unwrap();
    let before = saved(&database.pool, &genesis).await;
    let a = RecoveryStore::postgres(database.reconnect(2).await);
    let b = RecoveryStore::postgres(database.reconnect(2).await);
    a.configure_recovery_review(ORIGIN, 1).await.unwrap();
    b.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let a = make_app(a);
    let b = make_app(b);
    assert_eq!(post_recovery(&a, &path, None, bytes.clone()).await.0, StatusCode::UNAUTHORIZED);
    let missing = post_recovery(&a, &endpoint(&"a".repeat(64)), Some("alice"), bytes.clone()).await;
    assert_eq!(missing.0, StatusCode::NOT_FOUND);
    assert_eq!(post_recovery(&a, &path, Some("bob"), bytes.clone()).await, missing);

    let (first, second) = tokio::join!(post_recovery(&a, &path, Some("alice"), bytes.clone()),
        post_recovery(&b, &path, Some("alice"), bytes.clone()));
    assert_eq!(first.0, StatusCode::OK, "{}", first.1);
    assert_eq!(first, second);
    let challenge = SignerReportChallenge::parse(first.1.to_string().as_bytes()).unwrap();
    assert_eq!(challenge.connection(), 1);
    assert_eq!(challenge.expires_at() - challenge.issued_at(), 30_000);
    assert_eq!(challenge.origin(), ORIGIN);
    assert_eq!(challenge.recovery().to_json(), request["recovery"]);

    for bad in ["evidence","head","signer","extra"] {
        let mut changed = request.clone();
        match bad {
            "evidence" => changed["recovery"]["evidence_hash"] = json!("0".repeat(64)),
            "head" => changed["expected"]["seq"] = json!(999),
            "signer" => changed["signer"] = json!("service:bot"),
            _ => changed["nonce"] = json!("caller-chosen"),
        }
        assert!(!post_recovery(&a, &path, Some("alice"), changed.to_string().into_bytes()).await.0.is_success());
    }
    // Expiry alone never alters the external generation, plan, fence or live root.
    sqlx::query("UPDATE station_delegated_signer_challenges SET expires_at=0")
        .execute(&database.pool).await.unwrap();
    let renewed = post_recovery(&b, &path, Some("alice"), bytes.clone()).await;
    assert_eq!(renewed.0, StatusCode::OK);
    let next = SignerReportChallenge::parse(renewed.1.to_string().as_bytes()).unwrap();
    assert_ne!(challenge.nonce(), next.nonce());
    assert_eq!(next.connection(), 2);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);

    // Simulate a lost database commit while another slot is being created.
    sqlx::raw_sql("CREATE FUNCTION reject_mint() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit fault'; END $$; \
        CREATE CONSTRAINT TRIGGER reject_mint AFTER INSERT ON station_delegated_signer_challenges \
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_mint();")
        .execute(&database.pool).await.unwrap();
    let mut another = request;
    another["slot"] = json!("astation-ios");
    assert_eq!(post_recovery(&a, &path, Some("alice"), another.to_string().into_bytes()).await.0, StatusCode::SERVICE_UNAVAILABLE);
    let counts: (i64, i64) = sqlx::query_as("SELECT signer_connection,(SELECT count(*) FROM station_delegated_signer_challenges) FROM station_delegated_recovery_plans")
        .fetch_one(&database.pool).await.unwrap();
    assert_eq!(counts, (2, 1));
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_signer_report_is_verified_once_and_receipted_across_replicas() {
    use atem_client::member_report::{sign_signer_report, signer_report_body, JournalView, SignerReportChallenge};
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (store, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let a = RecoveryStore::postgres(database.reconnect(2).await);
    let b = RecoveryStore::postgres(database.reconnect(2).await);
    a.configure_recovery_review(ORIGIN, 1).await.unwrap();
    b.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let (a, b) = (make_app(a), make_app(b));
    let base = format!("/api/remote/v1/logs/{genesis}/control/recovery");
    let path = format!("{base}/signer-reports");
    let signer = "member:phone";
    let mint = |slot: &str| json!({"signer":signer,"slot":slot,"expected":f.log.head().to_json(),
        "recovery":{"generation":"1","plan_id":plan["plan_id"],"candidate_feed_id":plan["candidate_feed_id"],
            "source_hash":plan["source_hash"],"evidence_hash":plan["evidence_hash"]}}).to_string().into_bytes();
    let before = saved(&database.pool, &genesis).await;
    let original = &before["delegated"][ORIGIN]["records"][1];
    let mut inputs = Vec::new();
    let displaced = atem_client::encoding::b64u(&[2; 16]);
    for slot in ["astation-macos", "other"] {
        let (status, challenge) = post_recovery(&a, &format!("{base}/signer-challenges"), Some("alice"), mint(slot)).await;
        assert_eq!(status, StatusCode::OK);
        let challenge = SignerReportChallenge::parse(challenge.to_string().as_bytes()).unwrap();
        let journal = JournalView {
            id: [1; 16], since: 2, revision: 2,
            records: vec![original["body"].to_string()], drafts: vec![],
            processes: vec![atem_client::encoding::b64u(&atem_client::member_report::process_generation()), displaced.clone()],
        };
        let body = signer_report_body(&f.log, &challenge, signer, slot, ORIGIN, &journal, challenge.issued_at()).unwrap();
        let report = sign_signer_report(&f.keys, &KeyId::new("manager"), &body).unwrap();
        inputs.push(json!({"report":report.to_json(),"records":[original],"processes":journal.processes}));
    }
    let input = &inputs[0];
    let bytes = input.to_string().into_bytes();
    assert_eq!(post_recovery(&a, &path, None, bytes.clone()).await.0, StatusCode::UNAUTHORIZED);
    let missing = path.replace(&genesis, &"0".repeat(64));
    assert_eq!(post_recovery(&a, &path, Some("bob"), bytes.clone()).await,
        post_recovery(&a, &missing, Some("alice"), bytes.clone()).await);
    for field in ["signature", "records", "processes", "missing_processes", "extra"] {
        let mut bad = input.clone();
        match field {
            "signature" => bad["report"]["sig"] = json!("forged"),
            "records" => bad["records"] = json!([{}]),
            "processes" => bad["processes"] = json!([]),
            "missing_processes" => { bad.as_object_mut().unwrap().remove("processes"); }
            _ => bad["extra"] = json!(true),
        }
        assert_eq!(post_recovery(&a, &path, Some("alice"), bad.to_string().into_bytes()).await.0, StatusCode::BAD_REQUEST);
    }
    sqlx::raw_sql("CREATE FUNCTION reject_report() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit fault'; END $$;
        CREATE CONSTRAINT TRIGGER reject_report AFTER INSERT ON station_delegated_signer_reports
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_report();")
        .execute(&database.pool).await.unwrap();
    assert_eq!(post_recovery(&a, &path, Some("alice"), bytes.clone()).await.0, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(http(&b, &genesis, Some("alice")).await.1["evidence_hash"], plan["evidence_hash"]);
    sqlx::query("DROP TRIGGER reject_report ON station_delegated_signer_reports").execute(&database.pool).await.unwrap();
    let (one, two) = tokio::join!(post_recovery(&a, &path, Some("alice"), bytes.clone()),
        post_recovery(&b, &path, Some("alice"), bytes.clone()));
    assert_eq!(one.0, StatusCode::OK, "{}", one.1);
    assert_eq!(one, two);
    assert_eq!(one.1["retained_only"], true);
    assert_eq!(one.1["plan_id"], plan["plan_id"]);
    assert_eq!(one.1["submission_hash"].as_str().unwrap().len(), 64);
    let mut conflict = input.clone();
    conflict["records"] = json!([]);
    assert_eq!(post_recovery(&b, &path, Some("alice"), conflict.to_string().into_bytes()).await.0, StatusCode::CONFLICT);
    // This signed record was already in the checkpoint when both slots got their challenges.
    assert_eq!(http(&b, &genesis, Some("alice")).await.1["evidence_hash"], plan["evidence_hash"]);
    sqlx::query("DELETE FROM station_delegated_signer_challenges WHERE slot='astation-macos'").execute(&database.pool).await.unwrap();
    assert_eq!(post_recovery(&a, &path, Some("alice"), bytes.clone()).await, one);
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_signer_reports").fetch_one(&database.pool).await.unwrap();
    assert_eq!(count, 1);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    let review = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let author = &review["known_authors"]["members"]["member:phone"];
    assert_eq!(author["member_status"], "manager");
    assert_eq!(author["reports"][0]["process"], input["report"]["body"]["process"]);
    assert!(author["reports"][0]["process"].as_str().is_some_and(|p| p.len() == 22));
    assert_eq!(author["reports"][0]["missing_early_range"], true);
    assert_eq!(author["reports"][0]["journal"]["records"], 1);
    assert_eq!(author["reports"][0]["submission_hash"], one.1["submission_hash"]);
    assert_eq!(review["known_authors"]["complete_history"], false);
    // Use the same prepared-plan fields the Mac exporter reads, plus one offline
    // slot that the Station has never had a connection or a report for.
    let mut roster = http(&b, &genesis, Some("alice")).await.1;
    for flag in ["retained_history_only", "complete_history", "signing_clock_complete", "snapshot_complete", "recovery_ready"] {
        roster.as_object_mut().unwrap().remove(flag);
    }
    let slot = json!({"member":"phone","slot":"astation-macos","process":author["reports"][0]["process"],
        "review_head":f.log.head().to_json(),"selected":true});
    let offline = json!({"member":"phone","slot":"offline","process":"AQEBAQEBAQEBAQEBAQEBAQ",
        "review_head":f.log.head().to_json(),"selected":false});
    roster["slots"] = json!([slot, offline]);
    let comparison = |value: Value| {
        let bytes = value.to_string().into_bytes();
        let pool = database.pool.clone();
        let binding = binding.clone();
        let genesis = genesis.clone();
        let id = review["plan_id"].as_str().unwrap().to_owned();
        async move { plan::author_roster::compare(&pool, &binding, &genesis, &id, &[bytes]).await }
    };
    let result = comparison(roster.clone()).await.unwrap();
    assert_eq!(result["matching_current_reports"][0]["slot"], "astation-macos");
    assert_eq!(result["reviewed_without_current_report"][0]["slot"], "offline");
    assert_eq!(result["reviewed_without_signed_attachment"], json!([{
        "member": "phone", "slot": "offline", "process": offline["process"]
    }]));
    assert_eq!(result["reports_missing_early_range"][0]["submission_hash"], one.1["submission_hash"]);
    assert_eq!(result["reported_outside_review"], json!([]));
    assert_eq!(result["recovery_ready"], false);
    let mut attached = roster.clone();
    attached["slots"][1]["process"] = json!(displaced);
    let transferred = comparison(attached).await.unwrap();
    assert_eq!(transferred["reviewed_without_signed_attachment"], json!([]));
    assert_eq!(transferred["reviewed_without_current_report"][0]["slot"], "offline");
    assert_eq!(transferred["reports_missing_early_range"].as_array().unwrap().len(), 1);
    let mut replaced = roster.clone();
    replaced["slots"][0]["process"] = offline["process"].clone();
    let mismatch = comparison(replaced).await.unwrap();
    assert_eq!(mismatch["matching_current_reports"], json!([]));
    assert_eq!(mismatch["reported_outside_review"][0]["slot"], "astation-macos");
    let mut empty = roster.clone();
    empty["slots"] = json!([]);
    assert_eq!(comparison(empty).await.unwrap()["missing_current_roster"], json!(["phone"]));
    for field in ["account_id","genesis_hash","origin","generation","plan_id","candidate_feed_id",
        "source_hash","evidence_hash","reconstruction_hash","membership_head","version","unknown"] {
        let mut changed = roster.clone();
        changed[field] = json!("changed");
        assert!(comparison(changed).await.is_err(), "{field}");
    }
    let mut fork = roster.clone();
    fork["slots"][1]["review_head"]["hash"] = json!("0".repeat(64));
    assert!(comparison(fork).await.is_err());
    let mut duplicate = roster.clone();
    duplicate["slots"] = json!([slot, slot]);
    assert!(comparison(duplicate).await.is_err());
    assert_eq!(plan::prepare(&database.pool, &binding, &genesis).await.unwrap(), review);
    // A second slot can finish the same round using its outstanding challenge on another replica.
    assert_eq!(post_recovery(&b, &path, Some("alice"), inputs[1].to_string().into_bytes()).await.0, StatusCode::OK);
    let other = http(&a, &genesis, Some("alice")).await.1;
    assert_eq!(other["evidence_hash"], plan["evidence_hash"]);
    assert_ne!(other["reconstruction_hash"], review["reconstruction_hash"]);
    let staged = plan::snapshot_stops::stage(&database.pool, &binding, &genesis,
        other["reconstruction_hash"].as_str().unwrap()).await.unwrap();
    assert_eq!(staged["stop_count"], 1);
    let (status, pending) = post_recovery(&a, &format!("{base}/signer-challenges"), Some("alice"), mint("pending")).await;
    assert_eq!(status, StatusCode::OK);
    let challenge = SignerReportChallenge::parse(pending.to_string().as_bytes()).unwrap();
    let journal = JournalView {id:[3;16], since:1, revision:0, records:vec![], drafts:vec![], processes:vec![atem_client::encoding::b64u(&atem_client::member_report::process_generation())]};
    let body = signer_report_body(&f.log, &challenge, signer, "pending", ORIGIN, &journal, challenge.issued_at()).unwrap();
    let pending = sign_signer_report(&f.keys, &KeyId::new("manager"), &body).unwrap();

    let extended = super::recovery_plan::demote_manager(&mut f);
    let remove = Action::Remove { device_id: "phone".into() };
    let entry = sign_entry(&f.keys, &KeyId::new("replacement-manager"),
        extended.draft("replacement-manager", f.created, &remove)).unwrap();
    let mut previous = f.log.head();
    for next in extended.entries().iter().filter(|e| e.seq > f.log.head().seq).chain(std::iter::once(&entry)) {
        assert_eq!(store.append_test_entry(&genesis, "alice", next.clone(), previous).await, StatusCode::OK);
        previous = Head { seq:next.seq, hash:next.hash() };
    }
    let restart = database.reconnect(2).await;
    let moved = plan::prepare(&restart, &binding, &genesis).await.unwrap();
    assert_eq!(moved["plan_id"], plan["plan_id"]);
    assert_ne!(moved["evidence_hash"], other["evidence_hash"]);
    assert_eq!(moved["known_authors"]["members"][signer]["reports"].as_array().unwrap().len(), 2);
    let obligation = moved["known_history"]["records"].as_array().unwrap().iter()
        .find(|row| row["record_id"] == original["body"]["record_id"]).unwrap();
    assert_eq!(obligation["verification"], "removed_manager");
    assert!(plan::snapshot_stops::stage(&restart, &binding, &genesis, other["reconstruction_hash"].as_str().unwrap()).await.is_err());
    assert!(comparison(roster.clone()).await.is_err());
    assert_eq!(post_recovery(&a, &path, Some("alice"),
        json!({"report":pending.to_json(),"records":[],"processes":journal.processes}).to_string().into_bytes()).await.0, StatusCode::CONFLICT);
    assert_eq!(post_recovery(&b, &path, Some("alice"), bytes).await, one);
    restart.close().await;
    // A corrupted retained report cannot appear in a subsequent operator review.
    sqlx::query("UPDATE station_delegated_signer_reports SET accepted_at=0").execute(&database.pool).await.unwrap();
    assert!(comparison(roster).await.is_err());
    assert!(plan::prepare(&database.pool, &binding, &genesis).await.is_err());
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_authors_confirm_one_evidence_hash_across_replicas() {
    use atem_client::member_report::{sign_signer_report, signer_report_body, JournalView, SignerReportChallenge};

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (_, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let before = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    f.log = super::recovery_plan::demote_manager(&mut f);
    let mut root = saved(&database.pool, &genesis).await;
    root["membership"] = f.log.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis).bind(&root).execute(&database.pool).await.unwrap();
    let initial = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    assert_eq!(initial["plan_id"], before["plan_id"]);
    assert_ne!(initial["evidence_hash"], before["evidence_hash"]);
    let replica = database.reconnect(2).await;
    let store = RecoveryStore::postgres(replica.clone());
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    let other_store = RecoveryStore::postgres(database.pool.clone());
    other_store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let other_app = make_app(other_store);
    let base = format!("/api/remote/v1/logs/{genesis}/control/recovery");
    let report_path = format!("{base}/signer-reports");
    let former = "member:phone";
    let active = "member:replacement-manager";
    let original = ControlRecord::parse(root["delegated"][ORIGIN]["records"][1].to_string().as_bytes()).unwrap();
    let mut replacement = original.body().clone();
    replacement.signer = ControlSigner::Member("replacement-manager".into());
    replacement.record_id = uuid::Uuid::new_v4().to_string();
    replacement.issued_at = f.created + 1000;
    let copy = build_control(&f.keys, &KeyId::new("replacement-manager"), &replacement).unwrap().to_json();
    let copies = json!({"evidence_hash":initial["evidence_hash"],
        "replacements":[{"original_record_id":original.record_id(),"record":copy}]});
    let plan_id = initial["plan_id"].as_str().unwrap();
    assert_eq!(retain_http(&app, &genesis, plan_id, Some("alice"), copies.to_string().into_bytes()).await.0, StatusCode::OK);
    let retained_copy = plan::prepare(&replica, &binding, &genesis).await.unwrap();
    assert_eq!(retained_copy["recovery_signatures"]["pending_copy_exports"], json!([{
        "original_record_id": original.record_id(), "copy_record_id": replacement.record_id
    }]));
    let mut newly_discovered = replacement.clone();
    newly_discovered.record_id = uuid::Uuid::new_v4().to_string();
    newly_discovered.issued_at += 1;
    let new_stop = build_control(&f.keys, &KeyId::new("replacement-manager"), &newly_discovered).unwrap().to_json();
    let make_submission = async |signer: &str, key: &str, revision: u64, drafts: Vec<String>, source: &Value| {
        let slot = "native";
        let mint = json!({"signer":signer,"slot":slot,"expected":f.log.head().to_json(),
            "recovery":{"generation":"1","plan_id":initial["plan_id"],"candidate_feed_id":initial["candidate_feed_id"],
                "source_hash":initial["source_hash"],"evidence_hash":source}});
        let (status, challenge) = post_recovery(&app, &format!("{base}/signer-challenges"), Some("alice"),
            mint.to_string().into_bytes()).await;
        assert_eq!(status, StatusCode::OK, "{challenge}");
        let challenge = SignerReportChallenge::parse(challenge.to_string().as_bytes()).unwrap();
        let mut records = Vec::new();
        if signer == active {
            records.push(&copy);
            if revision >= 3 { records.push(&new_stop); }
        }
        let journal = JournalView { id: [1; 16], since: 1, revision,
            records: records.iter().map(|record| record["body"].to_string()).collect(), drafts, processes: vec![atem_client::encoding::b64u(&atem_client::member_report::process_generation())] };
        let body = signer_report_body(&f.log, &challenge, signer, slot, ORIGIN, &journal, challenge.issued_at()).unwrap();
        let report = sign_signer_report(&f.keys, &KeyId::new(key), &body).unwrap();
        json!({"report":report.to_json(),"records":records,"processes":journal.processes}).to_string().into_bytes()
    };
    let initial_submission = make_submission(former, "manager", 1, vec![], &initial["evidence_hash"]).await;
    let second = make_submission(active, "replacement-manager", 1, vec![], &initial["evidence_hash"]).await;
    assert_eq!(post_recovery(&app, &report_path, Some("alice"), second).await.0, StatusCode::OK);
    let first = plan::prepare(&replica, &binding, &genesis).await.unwrap();
    assert_ne!(first["evidence_hash"], initial["evidence_hash"]);
    let journal_id = atem_client::encoding::b64u(&[1;16]);
    assert_eq!(first["known_authors"]["pending_final_reports"], json!([
        {"signer":former,"journal_id":null,"reason":"no_report"},
        {"signer":active,"journal_id":journal_id,"reason":"evidence_changed"}
    ]));
    // The other author already approved the prior round. It can finish that
    // outstanding request after discovery, then confirm the enlarged base.
    let original_receipt = post_recovery(&other_app, &report_path, Some("alice"), initial_submission.clone()).await;
    assert_eq!(original_receipt.0, StatusCode::OK);
    let cut = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    assert_eq!(cut["evidence_hash"], first["evidence_hash"]);
    assert_ne!(cut["reconstruction_hash"], first["reconstruction_hash"]);
    assert_eq!(cut["known_authors"]["pending_final_reports"], json!([
        {"signer":former,"journal_id":journal_id,"reason":"evidence_changed"},
        {"signer":active,"journal_id":journal_id,"reason":"evidence_changed"}
    ]));
    assert_eq!(cut["recovery_signatures"]["records"][0]["exported_at_cut"], false);
    assert!(plan::snapshot_stops::stage(&replica, &binding, &genesis,
        cut["reconstruction_hash"].as_str().unwrap()).await.is_err());
    let hash = &cut["evidence_hash"];
    let a = make_submission(former, "manager", 1, vec![], hash).await;
    let b = make_submission(active, "replacement-manager", 1, vec![], hash).await;
    let (a, b) = tokio::join!(post_recovery(&app, &report_path, Some("alice"), a),
        post_recovery(&other_app, &report_path, Some("alice"), b));
    assert_eq!((a.0, b.0), (StatusCode::OK, StatusCode::OK));
    let resumed = database.reconnect(2).await;
    let confirmed = plan::prepare(&resumed, &binding, &genesis).await.unwrap();
    assert_eq!(&confirmed["evidence_hash"], hash);
    assert_eq!(confirmed["known_authors"]["pending_final_reports"], json!([]));
    assert_ne!(confirmed["reconstruction_hash"], cut["reconstruction_hash"]);
    let mapped = &confirmed["recovery_signatures"]["records"][0];
    assert_eq!(mapped["current_review"], false);
    assert_eq!(mapped["exported_at_cut"], true);
    assert_eq!(confirmed["recovery_signatures"]["pending_copy_exports"], json!([]));
    let staged = plan::snapshot_stops::stage(&resumed, &binding, &genesis,
        confirmed["reconstruction_hash"].as_str().unwrap()).await.unwrap();
    assert_eq!(staged["stop_count"], 1);
    let bytes: Value = sqlx::query_scalar("SELECT records FROM station_delegated_snapshot_stops WHERE plan_id=$1")
        .bind(plan_id).fetch_one(&replica).await.unwrap();
    assert_eq!(bytes, json!([copy]));
    let mut roster = http(&app, &genesis, Some("alice")).await.1;
    for flag in ["retained_history_only", "complete_history", "signing_clock_complete", "snapshot_complete", "recovery_ready"] {
        roster.as_object_mut().unwrap().remove(flag);
    }
    roster["slots"] = json!(["phone", "replacement-manager"].map(|member| json!({
        "member":member,"slot":"native","process":atem_client::encoding::b64u(&atem_client::member_report::process_generation()),
        "selected":true,"review_head":f.log.head().to_json()})));
    let compare = async |roster: &Value| {
        plan::author_roster::compare(&resumed, &binding, &genesis, initial["plan_id"].as_str().unwrap(),
            &[roster.to_string().into_bytes()]).await
    };
    let result = compare(&roster).await.unwrap();
    assert_eq!(result["matching_evidence_confirmations"].as_array().unwrap().len(), 2);
    assert_eq!(result["reviewed_without_current_confirmation"], json!([]));
    assert_eq!(result["complete_history"], false);

    // Two managers can supply their lists separately for one locked review.
    let mut phone = roster.clone();
    phone["slots"] = json!([roster["slots"][0]]);
    let mut manager = roster.clone();
    manager["slots"] = json!([roster["slots"][1]]);
    let compare_files = async |files: &[Value]| {
        let inputs: Vec<_> = files.iter().map(|v| v.to_string().into_bytes()).collect();
        plan::author_roster::compare(&resumed, &binding, &genesis, initial["plan_id"].as_str().unwrap(), &inputs).await
    };
    assert_eq!(compare_files(&[manager.clone(), phone.clone(), phone.clone()]).await.unwrap(), result);
    assert_eq!(result["conflicted_author_slots"], json!([]));
    let mut observed = phone.clone();
    let conflicts = json!([{"member":"phone","slot":"native"},{"member":"phone","slot":"old-slot"}]);
    observed["conflicted_slots"] = conflicts.clone();
    for files in [
        vec![phone.clone(), observed.clone(), manager.clone()],
        vec![manager.clone(), observed.clone(), phone.clone(), observed.clone()],
    ] {
        let combined = compare_files(&files).await.unwrap();
        assert_eq!(combined["conflicted_author_slots"], conflicts);
        assert_eq!(combined["matching_evidence_confirmations"], result["matching_evidence_confirmations"]);
        assert_eq!(combined["recovery_ready"], false);
    }
    for invalid in [json!(null), json!([conflicts[0], conflicts[0]]),
        json!([{"member":"unknown","slot":"native"}]), json!([{"member":"phone","slot":"/"}])] {
        observed["conflicted_slots"] = invalid;
        assert!(compare_files(&[observed.clone()]).await.is_err());
    }
    let mut conflict = phone.clone();
    conflict["slots"][0]["selected"] = json!(false);
    assert!(compare_files(&[phone.clone(), conflict]).await.is_err());
    let mut stale = manager.clone();
    stale["evidence_hash"] = json!("0".repeat(64));
    assert!(compare_files(&[phone.clone(), stale]).await.is_err());

    // Changing only the journal revision changes the review, not its record set.
    sqlx::query("DELETE FROM station_delegated_signer_challenges").execute(&resumed).await.unwrap();
    let changed = make_submission(active, "replacement-manager", 2, vec![], hash).await;
    assert_eq!(post_recovery(&app, &report_path, Some("alice"), changed).await.0, StatusCode::OK);
    let revised = plan::prepare(&resumed, &binding, &genesis).await.unwrap();
    assert_eq!(&revised["evidence_hash"], hash);
    assert_ne!(revised["reconstruction_hash"], confirmed["reconstruction_hash"]);
    assert_eq!(revised["recovery_signatures"]["records"][0]["exported_at_cut"], true);
    // A newly exported signed stop opens another round for both authors.
    sqlx::query("UPDATE station_delegated_signer_challenges SET expires_at=0").execute(&resumed).await.unwrap();
    let changed = make_submission(active, "replacement-manager", 3, vec![], hash).await;
    assert_eq!(post_recovery(&app, &report_path, Some("alice"), changed).await.0, StatusCode::OK);
    assert_eq!(post_recovery(&app, &report_path, Some("alice"), initial_submission).await, original_receipt);
    assert!(compare(&roster).await.is_err());
    assert!(compare_files(&[phone, manager]).await.is_err());
    let latest = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    assert_ne!(&latest["evidence_hash"], hash);
    assert_eq!(latest["recovery_signatures"]["records"][0]["exported_at_cut"], false);
    assert_eq!(latest["recovery_signatures"]["pending_copy_exports"][0]["original_record_id"], original.record_id());
    assert!(plan::snapshot_stops::stage(&resumed, &binding, &genesis,
        latest["reconstruction_hash"].as_str().unwrap()).await.is_err());
    roster["evidence_hash"] = latest["evidence_hash"].clone();
    roster["reconstruction_hash"] = latest["reconstruction_hash"].clone();
    let result = compare(&roster).await.unwrap();
    assert_eq!(result["matching_evidence_confirmations"], json!([]));
    assert_eq!(result["reviewed_without_current_confirmation"].as_array().unwrap().len(), 2);
    // A contradictory inventory is retained as evidence even if the process
    // re-attests it at the latest evidence hash. A replica reconstructs the conflict.
    let mut draft = root["delegated"][ORIGIN]["records"][1]["body"].clone();
    draft["signer"] = json!(active);
    let divergent = make_submission(active, "replacement-manager", 3, vec![draft.to_string()],
        &latest["evidence_hash"]).await;
    assert_eq!(post_recovery(&other_app, &report_path, Some("alice"), divergent).await.0, StatusCode::OK);
    let fork = plan::prepare(&resumed, &binding, &genesis).await.unwrap();
    let gaps = fork["known_authors"]["journal_gaps"].as_array().unwrap();
    assert_eq!(gaps.len(), 1);
    assert_eq!(gaps[0]["signer"], active);
    assert_eq!(gaps[0]["reasons"], json!(["conflicting_revision_contents","held_inventory_changed"]));
    assert_eq!(fork["evidence_hash"], latest["evidence_hash"]);
    sqlx::query("UPDATE station_delegated_signer_challenges SET expires_at=0").execute(&resumed).await.unwrap();
    let confirm_fork = make_submission(active, "replacement-manager", 3, vec![draft.to_string()],
        &fork["evidence_hash"]).await;
    assert_eq!(post_recovery(&app, &report_path, Some("alice"), confirm_fork).await.0, StatusCode::OK);
    let after = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    assert_eq!(after["evidence_hash"], fork["evidence_hash"]);
    assert_eq!(after["known_authors"]["journal_gaps"], fork["known_authors"]["journal_gaps"]);
    sqlx::query("UPDATE station_delegated_signer_challenges SET expires_at=0").execute(&resumed).await.unwrap();
    let outstanding = make_submission(former, "manager", 1, vec![], &after["evidence_hash"]).await;
    let mut imported = replacement.clone();
    imported.record_id = uuid::Uuid::new_v4().to_string();
    let imported = build_control(&f.keys, &KeyId::new("replacement-manager"), &imported).unwrap();
    let input = json!({"plan_id":plan_id,"source_hash":initial["source_hash"],"records":[imported.to_json()]});
    plan::stops::retain(&resumed, &binding, &genesis, input.to_string().as_bytes()).await.unwrap();
    assert_eq!(post_recovery(&other_app, &report_path, Some("alice"), outstanding).await.0, StatusCode::CONFLICT);
    assert_eq!(saved(&resumed, &genesis).await, root);
    assert!(!inspect(&resumed, ORIGIN).await.unwrap().unwrap().ready);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_history_retains_signer_exports_after_abandonment() {
    use atem_client::member_report::{
        sign_signer_report, signer_report_body, JournalView, SignerReportChallenge,
    };

    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let (_, mut f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let first = plan::prepare(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    let mut root = saved(&database.pool, &genesis).await;
    let retained_stop = &root["delegated"][ORIGIN]["records"][1];
    let mut body = ControlRecord::parse(retained_stop.to_string().as_bytes())
        .unwrap()
        .body()
        .clone();
    body.record_id = uuid::Uuid::new_v4().to_string();
    body.issued_at += 1000;
    let exported = build_control(&f.keys, &KeyId::new("manager"), &body)
        .unwrap()
        .to_json();
    let mut wrong_target = body.clone();
    wrong_target.record_id = uuid::Uuid::new_v4().to_string();
    wrong_target.issued_at += 1000;
    wrong_target.principal_key = Some(atem_client::Hash32::of(b"unknown-service-key"));
    let unresolved = build_control(&f.keys, &KeyId::new("manager"), &wrong_target).unwrap().to_json();
    let store = RecoveryStore::postgres(database.reconnect(2).await);
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    let base = format!("/api/remote/v1/logs/{genesis}/control/recovery");
    let signer = "member:phone";
    let slot = "astation-macos";
    let mint = json!({"signer":signer,"slot":slot,"expected":f.log.head().to_json(),
        "recovery":{"generation":"1","plan_id":first["plan_id"],"candidate_feed_id":first["candidate_feed_id"],
            "source_hash":first["source_hash"],"evidence_hash":first["evidence_hash"]}});
    let (status, challenge) = post_recovery(
        &app,
        &format!("{base}/signer-challenges"),
        Some("alice"),
        mint.to_string().into_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let challenge = SignerReportChallenge::parse(challenge.to_string().as_bytes()).unwrap();
    let submission = |stops: &[&Value]| {
        let journal = JournalView {
            id: [1; 16],
            since: 1,
            revision: 2,
            records: stops.iter().map(|r| r["body"].to_string()).collect(),
            drafts: vec![],
            processes: vec![atem_client::encoding::b64u(&atem_client::member_report::process_generation())],
        };
        let report = signer_report_body(
            &f.log,
            &challenge,
            signer,
            slot,
            ORIGIN,
            &journal,
            challenge.issued_at(),
        )
        .unwrap();
        let signed = sign_signer_report(&f.keys, &KeyId::new("manager"), &report).unwrap();
        json!({"report":signed.to_json(),"records":stops,"processes":journal.processes})
            .to_string()
            .into_bytes()
    };
    let mut conflicting_body = body.clone();
    conflicting_body.record_id = retained_stop["body"]["record_id"].as_str().unwrap().into();
    let conflict = build_control(&f.keys, &KeyId::new("manager"), &conflicting_body)
        .unwrap()
        .to_json();
    let path = format!("{base}/signer-reports");
    assert_eq!(
        post_recovery(&app, &path, Some("alice"), submission(&[&conflict]))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        plan::prepare(&database.pool, &binding, &genesis)
            .await
            .unwrap(),
        first
    );
    assert_eq!(
        post_recovery(
            &app,
            &path,
            Some("alice"),
            submission(&[retained_stop, &exported, &unresolved])
        )
        .await
        .0,
        StatusCode::OK
    );

    let current = plan::prepare(&database.pool, &binding, &genesis)
        .await
        .unwrap();
    assert!(current["recovery_signatures"]["known_native_obligations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["original"]["record_id"] == body.record_id
            && r["requirement"] == "retain_service_stop"));
    plan::outcome::abandon(
        &database.pool,
        &binding,
        &genesis,
        first["plan_id"].as_str().unwrap(),
    )
    .await
    .unwrap();
    let demoted = super::recovery_plan::demote_manager(&mut f);
    root["membership"] = demoted.to_stored();
    sqlx::query("UPDATE remote_recovery_roots SET state=$2 WHERE genesis_hash=$1")
        .bind(&genesis)
        .bind(&root)
        .execute(&database.pool)
        .await
        .unwrap();
    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&database.pool, true).await.unwrap();
    let replica = database.reconnect(2).await;
    let later = plan::prepare(&replica, &next, &genesis).await.unwrap();
    let history = &later["known_history"];
    assert_eq!(
        history["records"].as_array().unwrap().len(),
        4,
        "two report-only records and two feed records"
    );
    assert_eq!(
        history["observed_signing_lower_bounds"][body.principal.name()],
        body.issued_at
    );
    let obligations = later["recovery_signatures"]["known_native_obligations"]
        .as_array()
        .unwrap();
    assert!(obligations
        .iter()
        .any(|r| r["original"]["record_id"] == body.record_id
            && r["requirement"] == "fresh_manager_signature"
            && r["original"]["verification"] == "removed_manager"));
    assert_eq!(
        later["known_authors"]["members"][signer]["reports"],
        json!([])
    );
    let gaps = later["known_authors"]["journal_gaps"].as_array().unwrap();
    assert_eq!(gaps.len(), 1);
    assert_eq!(gaps[0]["signer"], signer);
    assert_eq!(gaps[0]["reasons"], json!(["missing_current_report"]));
    let previous = &later["known_authors"]["prior_plans"][0];
    assert_eq!(previous["plan_id"], first["plan_id"]);
    assert_eq!(previous["members"][signer]["member_status"], "manager");
    assert_eq!(previous["members"][signer]["reports"][0]["process"],
        atem_client::encoding::b64u(&atem_client::member_report::process_generation()));
    assert_eq!(previous["members"][signer]["reports"][0]["journal"]["records"], 3);
    assert_eq!(later["known_authors"]["members"][signer]["member_status"], "demoted");
    assert_eq!(later["recovery_ready"], false);
    assert_eq!(
        later,
        plan::prepare(&database.pool, &next, &genesis)
            .await
            .unwrap()
    );
    // The new report is correctly signed, has a larger revision and still
    // exports three stops. One of the original three has nevertheless vanished.
    let store = RecoveryStore::postgres(replica.clone());
    store.configure_recovery_review(ORIGIN, 2).await.unwrap();
    let peer = make_app(store);
    let mint = json!({"signer":signer,"slot":slot,"expected":demoted.head().to_json(),
        "recovery":{"generation":"2","plan_id":later["plan_id"],"candidate_feed_id":later["candidate_feed_id"],
            "source_hash":later["source_hash"],"evidence_hash":later["evidence_hash"]}});
    let (status, raw) = post_recovery(&peer, &format!("{base}/signer-challenges"), Some("alice"),
        mint.to_string().into_bytes()).await;
    assert_eq!(status, StatusCode::OK);
    let challenge = SignerReportChallenge::parse(raw.to_string().as_bytes()).unwrap();
    let mut other = body.clone();
    other.record_id = uuid::Uuid::new_v4().to_string();
    let other = build_control(&f.keys, &KeyId::new("manager"), &other).unwrap().to_json();
    let records = [&root["delegated"][ORIGIN]["records"][1], &unresolved, &other];
    let journal = JournalView {id:[1;16], since:1, revision:3,
        records:records.iter().map(|r| r["body"].to_string()).collect(), drafts:vec![], processes:vec![atem_client::encoding::b64u(&atem_client::member_report::process_generation())]};
    let author_report = signer_report_body(&demoted, &challenge, signer, slot, ORIGIN,
        &journal, challenge.issued_at()).unwrap();
    let signed = sign_signer_report(&f.keys, &KeyId::new("manager"), &author_report).unwrap();
    let payload = json!({"report":signed.to_json(),"records":records,"processes":journal.processes});
    assert_eq!(post_recovery(&peer, &path, Some("alice"), payload.to_string().into_bytes()).await.0,
        StatusCode::OK);
    let checked = plan::prepare(&database.pool, &next, &genesis).await.unwrap();
    let gap = &checked["known_authors"]["journal_gaps"][0];
    assert_eq!(gap["reasons"], json!(["previous_export_missing"]));
    assert_eq!(gap["missing_record_ids"], json!([body.record_id]));
    assert!(checked["known_history"]["records"].as_array().unwrap().iter()
        .any(|row| row["record_id"] == body.record_id));
    // A second authentic report from this generation goes below generation one's
    // revision 2. The already retained revision 3 cannot reconcile that rollback.
    let mut mint = mint;
    mint["recovery"]["evidence_hash"] = checked["evidence_hash"].clone();
    let (status, raw) = post_recovery(&peer, &format!("{base}/signer-challenges"), Some("alice"),
        mint.to_string().into_bytes()).await;
    assert_eq!(status, StatusCode::OK);
    let challenge = SignerReportChallenge::parse(raw.to_string().as_bytes()).unwrap();
    let rolled_back = JournalView { revision: 1, ..journal };
    let request = signer_report_body(&demoted, &challenge, signer, slot, ORIGIN,
        &rolled_back, challenge.issued_at()).unwrap();
    let signed = sign_signer_report(&f.keys, &KeyId::new("manager"), &request).unwrap();
    let payload = json!({"report":signed.to_json(),"records":records,"processes":rolled_back.processes});
    assert_eq!(post_recovery(&peer, &path, Some("alice"), payload.to_string().into_bytes()).await.0,
        StatusCode::OK);
    let inspected = plan::prepare(&database.pool, &next, &genesis).await.unwrap();
    let gap = &inspected["known_authors"]["journal_gaps"][0];
    assert_eq!(gap["reasons"], json!(["previous_export_missing","revision_below_prior_plan"]));
    assert_eq!(gap["revision_regression"], json!({
        "generation":2, "lowest_revision":1, "highest_earlier_revision":2
    }));
    assert_eq!(plan::prepare(&replica, &next, &genesis).await.unwrap(), inspected);
    sqlx::query("UPDATE station_delegated_signer_reports SET accepted_at=0")
        .execute(&database.pool)
        .await
        .unwrap();
    assert!(plan::prepare(&replica, &next, &genesis).await.is_err());
    assert_eq!(saved(&replica, &genesis).await, root);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_plan_abandonment_is_terminal_private_atomic_and_independent_of_live_state() {
    let database = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let (_, f, genesis, binding) = retained(&database).await;
    binding.initialize(&database.pool, true).await.unwrap();
    let plan = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let id = plan["plan_id"].as_str().unwrap();
    let replica = database.reconnect(2).await;
    let store = RecoveryStore::postgres(replica.clone());
    store.configure_recovery_review(ORIGIN, 1).await.unwrap();
    let app = make_app(store);
    let path = format!("/api/remote/v1/logs/{genesis}/control/recovery/{id}/outcome");
    let before = saved(&database.pool, &genesis).await;
    let pending = get_recovery(&app, &path, Some("alice")).await;
    assert_eq!(pending.0, StatusCode::OK);
    assert_eq!(pending.1["outcome"], "pending");
    assert_eq!(get_recovery(&app, &path, None).await.0, StatusCode::UNAUTHORIZED);
    let missing = get_recovery(&app, &path.replace(id, &uuid::Uuid::new_v4().to_string()), Some("alice")).await;
    assert_eq!(missing.0, StatusCode::NOT_FOUND);
    assert_eq!(get_recovery(&app, &path, Some("bob")).await, missing);
    sqlx::raw_sql("CREATE FUNCTION reject_end() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'commit fault'; END $$;
        CREATE CONSTRAINT TRIGGER reject_end AFTER UPDATE ON station_delegated_recovery_plans
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_end();")
        .execute(&database.pool).await.unwrap();
    assert!(plan::outcome::abandon(&database.pool, &binding, &genesis, id).await.is_err());
    assert_eq!(get_recovery(&app, &path, Some("alice")).await, pending);
    assert!(plan::prepare(&replica, &binding, &genesis).await.is_ok());
    sqlx::query("DROP TRIGGER reject_end ON station_delegated_recovery_plans").execute(&database.pool).await.unwrap();
    let (a, b) = tokio::join!(plan::outcome::abandon(&database.pool, &binding, &genesis, id),
        plan::outcome::abandon(&replica, &binding, &genesis, id));
    let receipt = a.unwrap();
    assert_eq!(b.unwrap(), receipt);
    assert_eq!(receipt["outcome"], "abandoned");
    assert_eq!(receipt["generation"], "1");
    assert_eq!(receipt["account_id"], f.log.account_id());
    assert_eq!(receipt["candidate_feed_id"], plan["candidate_feed_id"]);
    assert_eq!(receipt["source_hash"], plan["source_hash"]);
    assert_eq!(receipt.as_object().unwrap().len(), 8);
    assert_eq!(get_recovery(&app, &path, Some("alice")).await, (StatusCode::OK, receipt));
    assert!(plan::prepare(&replica, &binding, &genesis).await.is_err());
    assert_eq!(http(&app, &genesis, Some("alice")).await.0, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    let next = Binding::new(ORIGIN, 2).unwrap();
    next.initialize(&database.pool, true).await.unwrap();
    let new_plan = plan::prepare(&replica, &next, &genesis).await.unwrap();
    assert_ne!(new_plan["plan_id"], id);
    assert!(plan::outcome::abandon(&database.pool, &next, &genesis, id).await.is_err());
    assert_eq!(get_recovery(&app, &path, Some("alice")).await.0, StatusCode::NOT_FOUND);
    database.cleanup().await;
}
