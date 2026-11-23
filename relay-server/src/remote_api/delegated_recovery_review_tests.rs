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
    let (_, f, genesis, binding) = retained(&database).await;
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
    for slot in ["astation-macos", "other"] {
        let (status, challenge) = post_recovery(&a, &format!("{base}/signer-challenges"), Some("alice"), mint(slot)).await;
        assert_eq!(status, StatusCode::OK);
        let challenge = SignerReportChallenge::parse(challenge.to_string().as_bytes()).unwrap();
        let journal = JournalView {id:[1;16], since:2, revision:2, records:vec![original["body"].to_string()], drafts:vec![]};
        let body = signer_report_body(&f.log, &challenge, signer, slot, ORIGIN, &journal, challenge.issued_at()).unwrap();
        let report = sign_signer_report(&f.keys, &KeyId::new("manager"), &body).unwrap();
        inputs.push(json!({"report":report.to_json(),"records":[original]}));
    }
    let input = &inputs[0];
    let bytes = input.to_string().into_bytes();
    assert_eq!(post_recovery(&a, &path, None, bytes.clone()).await.0, StatusCode::UNAUTHORIZED);
    let missing = path.replace(&genesis, &"0".repeat(64));
    assert_eq!(post_recovery(&a, &path, Some("bob"), bytes.clone()).await,
        post_recovery(&a, &missing, Some("alice"), bytes.clone()).await);
    for field in ["signature", "records", "extra"] {
        let mut bad = input.clone();
        match field {
            "signature" => bad["report"]["sig"] = json!("forged"),
            "records" => bad["records"] = json!([{}]),
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
    assert_eq!(post_recovery(&b, &path, Some("alice"), inputs[1].to_string().into_bytes()).await.0, StatusCode::CONFLICT);
    assert_ne!(http(&b, &genesis, Some("alice")).await.1["evidence_hash"], plan["evidence_hash"]);
    sqlx::query("DELETE FROM station_delegated_signer_challenges").execute(&database.pool).await.unwrap();
    assert_eq!(post_recovery(&a, &path, Some("alice"), bytes).await, one);
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_signer_reports").fetch_one(&database.pool).await.unwrap();
    assert_eq!(count, 1);
    assert_eq!(saved(&database.pool, &genesis).await, before);
    assert!(!inspect(&database.pool, ORIGIN).await.unwrap().unwrap().ready);
    let review = plan::prepare(&database.pool, &binding, &genesis).await.unwrap();
    let author = &review["known_authors"]["members"]["member:phone"];
    assert_eq!(author["member_status"], "manager");
    assert_eq!(author["reports"][0]["missing_early_range"], true);
    assert_eq!(author["reports"][0]["journal"]["records"], 1);
    assert_eq!(author["reports"][0]["submission_hash"], one.1["submission_hash"]);
    assert_eq!(review["known_authors"]["complete_history"], false);
    // A corrupted retained report cannot appear in a subsequent operator review.
    sqlx::query("UPDATE station_delegated_signer_reports SET accepted_at=0").execute(&database.pool).await.unwrap();
    assert!(plan::prepare(&database.pool, &binding, &genesis).await.is_err());
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
