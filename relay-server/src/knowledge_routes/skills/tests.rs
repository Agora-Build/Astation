use super::*;
use crate::account_store::{AccountStore, InMemoryAccountStore};
use crate::knowledge_routes::tests::{sample_skill, test_state};
use crate::knowledge_store::PgKnowledgeStore;
use crate::vault_routes::tests::bind_session;
use axum::{http::Request, Router};
use std::sync::Arc;
use tower::ServiceExt;

const ACCOUNT: &str = "skill-wire-test";
const BATCH: &str = "/api/skills/batch?id=atem-test";
const KEY: &str = "scope=global&project=&name=demo";

fn envelope(kid: &str, marker: u8, bytes: usize) -> String {
    format!("e1.{kid}.{}", STANDARD.encode(vec![marker; bytes]))
}

fn compact_skill() -> Value {
    let mut skill = sample_skill(
        "demo",
        json!({envelope("0123abcd", 1, 40): envelope("0123abcd", 2, 40)}),
    );
    skill["content_hash"] = json!(format!("h1.0123abcd.{}", "a".repeat(64)));
    skill["files_encoding"] = json!("e1-text");
    skill
}

fn push(skill: Value, base_version: i64) -> Value {
    json!({"op": "push", "skill": skill, "base_version": base_version})
}

fn request(method: &str, uri: &str, session: Option<&str>, body: Body) -> Request<Body> {
    let mut req = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .header("x-forwarded-for", "203.0.113.51");
    if let Some(session) = session {
        req = req.header("authorization", format!("session {session}"));
    }
    req.body(body).unwrap()
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    session: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let req = request(
        method,
        uri,
        Some(session),
        Body::from(body.map(|v| v.to_string()).unwrap_or_default()),
    );
    let response = app.clone().oneshot(req).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn encrypted_state() -> (AppState, String, Arc<InMemoryAccountStore>) {
    let (mut state, session) = test_state(ACCOUNT).await;
    let accounts = Arc::new(InMemoryAccountStore::new(
        state.knowledge.clone(),
        state.vault.clone(),
    ));
    state.accounts = accounts.clone();
    accounts
        .set_encryption_state(ACCOUNT, "enabling", Some("0123abcd"), 1)
        .await
        .unwrap();
    accounts
        .set_encryption_state(ACCOUNT, "on", Some("0123abcd"), 1)
        .await
        .unwrap();
    (state, session, accounts)
}

fn skill_with_empty_file() -> Value {
    let mut row = compact_skill();
    row["files"][envelope("0123abcd", 3, 40)] = json!("");
    row
}

#[tokio::test]
async fn stored_ciphertext_including_empty_files_reads_without_mutation() {
    let (state, session, accounts) = encrypted_state().await;
    let knowledge = state.knowledge.clone();
    let compact = skill_with_empty_file();
    let mut stored = compact.clone();
    normalize_files(&mut stored).unwrap();
    // A row stored before this transport change uses the same persistent format.
    let original = knowledge
        .push_skill(ACCOUNT, serde_json::from_value(stored).unwrap(), 0)
        .await
        .unwrap();
    let before = knowledge.pull_skills(ACCOUNT, 0, 500).await.unwrap();
    let app = crate::router(state);
    let (_, page) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(page["skills"][0]["files"], compact["files"]);
    assert_eq!(page["skills"][0]["files_encoding"], "e1-text");
    assert_eq!(page["skills"][0]["seq"], original.seq);
    assert!(page.get("wire_version").is_none());
    assert_eq!(
        knowledge.pull_skills(ACCOUNT, 0, 500).await.unwrap(),
        before
    );
    let counts = accounts.encryption_state(ACCOUNT).await.unwrap();
    assert_eq!((counts.plaintext_fields, counts.obsolete_fields), (0, 0));
}

#[tokio::test]
async fn exact_version_retries_and_concurrent_writes_never_renumber_ciphertext() {
    let (state, session, _) = encrypted_state().await;
    let app = crate::router(state);
    let compact = skill_with_empty_file();
    let (_, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(compact.clone(), 0)]})),
    )
    .await;
    assert_eq!(result["results"][0]["ok"], true, "{result}");
    let seq = result["results"][0]["seq"].as_i64().unwrap();
    let mut resealed = compact.clone();
    resealed["files"] = json!({envelope("0123abcd", 4, 40): envelope("0123abcd", 5, 40)});
    for row in [compact.clone(), resealed] {
        let (_, refused) = call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(row, 0)]})),
        )
        .await;
        assert_eq!(
            refused["results"][0],
            json!({"ok": false, "error": "version_conflict", "current_version": 1})
        );
    }
    let mut next = compact.clone();
    next["version"] = json!(2);
    let (a, b) = tokio::join!(
        call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(next.clone(), 1)]}))
        ),
        call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(next, 1)]}))
        )
    );
    let outcomes = [a.1["results"][0].clone(), b.1["results"][0].clone()];
    assert_eq!(outcomes.iter().filter(|r| r["ok"] == true).count(), 1);
    assert_eq!(
        outcomes
            .iter()
            .filter(|r| r["error"] == "version_conflict" && r["current_version"] == 2)
            .count(),
        1
    );
    let (_, page) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(page["skills"].as_array().unwrap().len(), 2);
    assert_eq!(page["skills"][1]["seq"], seq + 1);
    assert_eq!(page["skills"][1]["files"], compact["files"]);
    let (_, cursor) = call(
        &app,
        "GET",
        &format!("/api/skills?id=atem-test&since={seq}&limit=1"),
        &session,
        None,
    )
    .await;
    assert_eq!(cursor["skills"].as_array().unwrap().len(), 1);
    assert_eq!(cursor["skills"][0]["version"], 2);
    for (version, base) in [
        (0, 0),
        (4, 2),
        (1, -1),
        (9_007_199_254_740_992i64, 9_007_199_254_740_991i64),
        (i64::MAX, i64::MAX),
    ] {
        let mut invalid = compact.clone();
        invalid["version"] = json!(version);
        let (_, refused) = call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(invalid, base)]})),
        )
        .await;
        assert_eq!(
            refused["results"][0],
            json!({"ok": false, "error": "invalid skill version"})
        );
    }
}

#[tokio::test]
async fn removed_versioned_routes_are_not_available() {
    let (state, session) = test_state(ACCOUNT).await;
    let app = crate::router(state);
    let fallback = call(&app, "GET", "/missing-api-route", &session, None).await;
    for uri in [
        "/api/skills/v2",
        "/api/skills/v2/batch",
        "/api/skills/v2/versions",
        "/api/skills/v2/version",
    ] {
        let result = call(&app, "GET", uri, &session, None).await;
        assert_eq!(
            result, fallback,
            "{uri} must use the missing-route fallback"
        );
    }
}

#[tokio::test]
async fn unknown_missing_malformed_and_mixed_encodings_refuse_the_entire_batch() {
    let (state, session, _) = encrypted_state().await;
    let knowledge = state.knowledge.clone();
    let app = crate::router(state);
    let valid = compact_skill();
    let mut missing = valid.clone();
    missing.as_object_mut().unwrap().remove("files_encoding");
    let mut unknown = valid.clone();
    unknown["files_encoding"] = json!("guess");
    let mut wrong_type = valid.clone();
    wrong_type["files_encoding"] = json!(true);
    let mut mixed = valid.clone();
    mixed["files"]["SKILL.md"] = json!("plaintext");
    let mut invalid = valid.clone();
    invalid["files"] = json!({envelope("0123abcd", 1, 40): "e1.0123abcd.bad"});
    let mut short = valid.clone();
    short["files"] = json!({envelope("0123abcd", 1, 40): envelope("0123abcd", 2, 39)});
    let mut path = valid.clone();
    path["files"] = json!({"SKILL.md": envelope("0123abcd", 2, 40)});
    let mut invalid_base64 = valid.clone();
    invalid_base64["files_encoding"] = json!("base64");
    for invalid in [
        missing,
        unknown,
        wrong_type,
        mixed,
        invalid,
        short,
        path,
        invalid_base64,
    ] {
        let expected = match invalid.get("files_encoding").and_then(Value::as_str) {
            Some("e1-text" | "base64") => "invalid skill files encoding",
            _ => "unsupported skill files encoding; update Atem",
        };
        let (status, body) = call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(valid.clone(), 0), push(invalid, 0)]})),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(body, json!({"error": expected}));
        assert!(knowledge
            .pull_skills(ACCOUNT, 0, 500)
            .await
            .unwrap()
            .is_empty());
    }
    let (status, _) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(valid, 0), {"op": "unknown"}]})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(knowledge
        .pull_skills(ACCOUNT, 0, 500)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn compact_and_base64_never_bypass_account_mode_or_key_checks() {
    let (state, session, _) = encrypted_state().await;
    let app = crate::router(state);
    let mut obsolete = compact_skill();
    obsolete["files"] = json!({envelope("89abcdef", 1, 40): envelope("89abcdef", 2, 40)});
    let mut plain = sample_skill(
        "plain",
        json!({"SKILL.md": STANDARD.encode(b"plain instructions")}),
    );
    plain["files_encoding"] = json!("base64");
    let (status, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(obsolete, 0), push(plain, 0)]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(result["results"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["ok"] == false));

    let (state, session) = test_state(ACCOUNT).await;
    let app = crate::router(state);
    let (_, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(compact_skill(), 0)]})),
    )
    .await;
    assert_eq!(result["results"][0]["ok"], false);
}

#[tokio::test]
async fn migration_history_tombstones_and_purge_keep_legacy_semantics() {
    let (mut state, session) = test_state(ACCOUNT).await;
    let accounts = Arc::new(InMemoryAccountStore::new(
        state.knowledge.clone(),
        state.vault.clone(),
    ));
    state.accounts = accounts.clone();
    let app = crate::router(state);
    let mut old = sample_skill(
        "demo",
        json!({"SKILL.md": STANDARD.encode(b"original instructions")}),
    );
    old["files_encoding"] = json!("base64");
    let (_, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(old.clone(), 0)]})),
    )
    .await;
    assert_eq!(result["results"][0]["ok"], true);
    let (_, plain) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=1"),
        &session,
        None,
    )
    .await;
    assert_eq!(plain["skill"]["files_encoding"], "base64");
    assert_eq!(plain["skill"]["files"], old["files"]);

    accounts
        .set_encryption_state(ACCOUNT, "enabling", Some("0123abcd"), 1)
        .await
        .unwrap();
    let compact = skill_with_empty_file();
    let (_, result) = call(&app, "POST", BATCH, &session, Some(json!({"ops": [{
        "op": "rewrite", "scope": "global", "old_project": "", "name": "demo", "version": 1,
        "project": "", "files": compact["files"], "files_encoding": "e1-text", "content_hash": compact["content_hash"]
    }]}))).await;
    assert_eq!(result["results"][0]["ok"], true, "{result}");
    let rewrite_seq = result["results"][0]["seq"].clone();
    accounts
        .set_encryption_state(ACCOUNT, "on", Some("0123abcd"), 1)
        .await
        .unwrap();
    let (_, history) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=1"),
        &session,
        None,
    )
    .await;
    assert_eq!(history["skill"]["version"], 1);
    assert_eq!(history["skill"]["seq"], rewrite_seq);
    assert_eq!(history["skill"]["files"], compact["files"]);
    let (_, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [
            {"op": "delete", "scope": "global", "name": "demo"},
            {"op": "purge", "scope": "global", "name": "demo", "versions": [1]}
        ]})),
    )
    .await;
    assert!(result["results"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["ok"] == true));
    let (_, versions) = call(
        &app,
        "GET",
        &format!("/api/skills/versions?id=atem-test&{KEY}"),
        &session,
        None,
    )
    .await;
    assert_eq!(versions["versions"].as_array().unwrap().len(), 2);
    assert!(versions["versions"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r.get("files").is_none()));
    let (_, tombstone) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=2"),
        &session,
        None,
    )
    .await;
    assert_eq!(tombstone["skill"]["deleted"], true);
    assert_eq!(tombstone["skill"]["files"], json!({}));
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=1"),
        &session,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::GONE);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=99"),
        &session,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn legacy_binary_history_and_obsolete_ciphertext_are_preserved() {
    let (state, session) = test_state(ACCOUNT).await;
    let binary_files = json!({"asset.bin": STANDARD.encode([0xff, 0xfe, 0x00])});
    let row: SkillRow =
        serde_json::from_value(sample_skill("binary", binary_files.clone())).unwrap();
    state.knowledge.push_skill(ACCOUNT, row, 0).await.unwrap();
    let mut row = compact_skill();
    normalize_files(&mut row).unwrap();
    state
        .knowledge
        .push_skill(ACCOUNT, serde_json::from_value(row).unwrap(), 0)
        .await
        .unwrap();
    let app = crate::router(state);
    let (_, result) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(result["skills"][0]["files_encoding"], "base64");
    assert_eq!(result["skills"][0]["files"], binary_files);
    assert_eq!(result["skills"][1]["files_encoding"], "e1-text");
    assert_eq!(result["skills"][1]["files"], compact_skill()["files"]);
}

#[test]
fn envelope_shaped_content_keeps_plain_paths_and_mixed_history_lossless() {
    let sealed_text = envelope("0123abcd", 2, 40);
    let files = json!({"notes.txt": STANDARD.encode(sealed_text.as_bytes()), ".keep": ""});
    let mut plain = sample_skill("plain", files.clone());
    encode_row(&mut plain);
    assert_eq!(plain["files_encoding"], "base64");
    assert_eq!(plain["files"], files);

    let mut stored = skill_with_empty_file();
    normalize_files(&mut stored).unwrap();
    let mut mixed = stored.clone();
    mixed["files"]["notes.txt"] = json!(STANDARD.encode(b"plain history"));
    let mixed_files = mixed["files"].clone();
    encode_row(&mut mixed);
    assert_eq!(mixed["files_encoding"], "base64");
    assert_eq!(mixed["files"], mixed_files);

    // The submitted encoding is not persisted; sealed paths/bytes determine read encoding.
    stored["files_encoding"] = json!("base64");
    encode_row(&mut stored);
    assert_eq!(stored["files_encoding"], "e1-text");
    assert_eq!(stored["files"], skill_with_empty_file()["files"]);
}

#[tokio::test]
async fn authentication_precedes_body_read_and_accounts_cannot_cross_read() {
    use std::sync::atomic::{AtomicBool, Ordering};
    let (state, session, _) = encrypted_state().await;
    let other = bind_session(&state, "other-account").await;
    let app = crate::router(state);
    let read = Arc::new(AtomicBool::new(false));
    let observed = read.clone();
    let stream = futures_util::stream::once(async move {
        observed.store(true, Ordering::SeqCst);
        Ok::<_, std::io::Error>(axum::body::Bytes::from_static(b"not json"))
    });
    let response = app
        .clone()
        .oneshot(request("POST", BATCH, None, Body::from_stream(stream)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(!read.load(Ordering::SeqCst));
    call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(compact_skill(), 0)]})),
    )
    .await;
    let (_, result) = call(&app, "GET", "/api/skills?id=atem-test", &other, None).await;
    assert_eq!(result, json!({"skills": []}));
    let (_, result) = call(
        &app,
        "GET",
        &format!("/api/skills/versions?id=atem-test&{KEY}"),
        &other,
        None,
    )
    .await;
    assert_eq!(result, json!({"versions": []}));
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/skills/version?id=atem-test&{KEY}&version=1"),
        &other,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    for uri in [
        "/api/skills",
        "/api/skills/versions?scope=global&name=demo",
        "/api/skills/version?scope=global&name=demo&version=1",
    ] {
        let response = app
            .clone()
            .oneshot(request("GET", uri, None, Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn production_limits_cover_wire_size_op_count_and_normalized_size() {
    let (state, session, _) = encrypted_state().await;
    let app = crate::router(state);
    let too_many = vec![push(compact_skill(), 0); SKILLS_BATCH_MAX_OPS + 1];
    let (status, _) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": too_many})),
    )
    .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            BATCH,
            Some(&session),
            Body::from(vec![b' '; SKILLS_BATCH_BODY_LIMIT + 1]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    let mut large = compact_skill();
    large["files"] = json!({envelope("0123abcd", 1, 40): envelope("0123abcd", 2, 9_800_000)});
    let payload = json!({"ops": [push(large, 0)]});
    assert!(payload.to_string().len() < SKILLS_BATCH_BODY_LIMIT);
    let (status, result) = call(&app, "POST", BATCH, &session, Some(payload)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "{result}");
    assert_eq!(result["error"], "normalized request body too large");
    let (_, empty) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(empty["skills"], json!([]));
}

#[tokio::test]
async fn large_encrypted_files_travel_once_and_round_trip_without_byte_changes() {
    let (state, session, _) = encrypted_state().await;
    let app = crate::router(state);
    let raw_bytes = 1024 * 1024 + 40;
    let mut compact = compact_skill();
    compact["files"] = json!({envelope("0123abcd", 1, 40): envelope("0123abcd", 2, raw_bytes)});
    let body = json!({"ops": [push(compact.clone(), 0)]});
    let compact_len = body.to_string().len();
    let mut legacy = compact.clone();
    normalize_files(&mut legacy).unwrap();
    let legacy_len = json!({"ops": [push(legacy, 0)]}).to_string().len();
    assert!(compact_len < raw_bytes * 134 / 100);
    assert!(compact_len * 100 < legacy_len * 76);
    let (status, result) = call(&app, "POST", BATCH, &session, Some(body)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(result["results"][0]["ok"], true);
    let (_, page) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(page["skills"][0]["files"], compact["files"]);
}

#[test]
fn public_encoding_fixture_matches_storage_and_wire_including_empty_files() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../designs/protocol/fixtures/skill-file-wire.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let mut row = case["wire_skill"].clone();
        normalize_files(&mut row).unwrap();
        assert_eq!(row, case["stored_skill"]);
        encode_row(&mut row);
        assert_eq!(row, case["wire_skill"]);
    }
}

#[tokio::test]
#[ignore = "requires KNOWLEDGE_TEST_DATABASE_URL pointing to local Postgres"]
async fn postgres_replicas_and_restart_preserve_ciphertext_and_cas() {
    let database =
        crate::test_database::TestDatabase::migrated("KNOWLEDGE_TEST_DATABASE_URL", 4).await;
    let (mut state, session) = test_state(ACCOUNT).await;
    state.knowledge = Arc::new(PgKnowledgeStore::new(database.pool.clone()));
    let accounts = Arc::new(InMemoryAccountStore::new(
        state.knowledge.clone(),
        state.vault.clone(),
    ));
    state.accounts = accounts.clone();
    // The Postgres store repeats mode validation within its write transaction.
    sqlx::query("INSERT INTO data_account_encryption (data_account, mode, kid, updated_at) VALUES ($1, 'on', '0123abcd', 1)")
        .bind(ACCOUNT).execute(&database.pool).await.unwrap();
    accounts
        .set_encryption_state(ACCOUNT, "enabling", Some("0123abcd"), 1)
        .await
        .unwrap();
    accounts
        .set_encryption_state(ACCOUNT, "on", Some("0123abcd"), 1)
        .await
        .unwrap();
    let app = crate::router(state.clone());
    let (_, result) = call(
        &app,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(skill_with_empty_file(), 0)]})),
    )
    .await;
    assert_eq!(result["results"][0]["ok"], true, "{result}");
    let committed_seq = result["results"][0]["seq"].clone();
    state.knowledge = Arc::new(PgKnowledgeStore::new(database.reconnect(2).await));
    let replica = crate::router(state.clone());
    let (_, compact) = call(&replica, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(
        compact["skills"][0]["files"],
        skill_with_empty_file()["files"]
    );
    assert_eq!(compact["skills"][0]["seq"], committed_seq);
    let mut next = skill_with_empty_file();
    next["version"] = json!(2);
    let (a, b) = tokio::join!(
        call(
            &app,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(next.clone(), 1)]}))
        ),
        call(
            &replica,
            "POST",
            BATCH,
            &session,
            Some(json!({"ops": [push(next, 1)]}))
        )
    );
    let results = [a.1["results"][0].clone(), b.1["results"][0].clone()];
    assert_eq!(
        results.iter().filter(|r| r["ok"] == true).count(),
        1,
        "{results:?}"
    );
    assert_eq!(
        results
            .iter()
            .filter(|r| r["error"] == "version_conflict" && r["current_version"] == 2)
            .count(),
        1,
        "{results:?}"
    );
    let (_, updated) = call(&app, "GET", "/api/skills?id=atem-test", &session, None).await;
    assert_eq!(updated["skills"].as_array().unwrap().len(), 2);
    assert_eq!(
        updated["skills"][1]["files"],
        skill_with_empty_file()["files"]
    );
    assert_eq!(
        updated["skills"][1]["seq"].as_i64().unwrap(),
        committed_seq.as_i64().unwrap() + 1
    );
    let restarted_pool = database.reconnect(1).await;
    state.knowledge = Arc::new(PgKnowledgeStore::new(restarted_pool.clone()));
    let restarted = crate::router(state);
    let (_, replayed) = call(
        &restarted,
        "GET",
        "/api/skills?id=atem-test",
        &session,
        None,
    )
    .await;
    assert_eq!(replayed, updated);
    // Simulate the durable mode moving after the HTTP layer read its snapshot.
    sqlx::query("UPDATE data_account_encryption SET mode = 'enabling', kid = '89abcdef' WHERE data_account = $1")
        .bind(ACCOUNT).execute(&database.pool).await.unwrap();
    let mut next = compact_skill();
    next["version"] = json!(3);
    let (_, refused) = call(
        &restarted,
        "POST",
        BATCH,
        &session,
        Some(json!({"ops": [push(next.clone(), 2)]})),
    )
    .await;
    assert_eq!(
        refused["results"][0],
        json!({
            "ok": false, "error": "content does not match the account encryption mode"
        }),
        "{refused}"
    );
    let (_, unchanged) = call(
        &restarted,
        "GET",
        "/api/skills?id=atem-test",
        &session,
        None,
    )
    .await;
    assert_eq!(unchanged, updated);
    restarted_pool.close().await;
    for (method, uri, body) in [
        ("GET", "/api/skills?id=atem-test", None),
        (
            "GET",
            "/api/skills/versions?id=atem-test&scope=global&name=demo",
            None,
        ),
        (
            "GET",
            "/api/skills/version?id=atem-test&scope=global&name=demo&version=1",
            None,
        ),
        ("POST", BATCH, Some(json!({"ops": [push(next, 2)]}))),
    ] {
        let (status, error) = call(&restarted, method, uri, &session, body).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{uri}: {error}");
        assert_eq!(error, json!({"error": "temporarily unavailable"}));
    }
    database.cleanup().await;
}
