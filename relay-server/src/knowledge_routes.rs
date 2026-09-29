//! Routes for `/api/memory` and `/api/skills` (Atem Memory knowledge sync).
//!
//! Mirrors `vault_routes.rs`: session auth via `resolve_caller`, the account is
//! `Caller.work_session_id` (the paired astation_id). Batch ops are validated
//! (reserved tokens, credential scanning) here — the store never inspects
//! memory content or skill file bytes.

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::knowledge_secrets::{check_bytes, contains_reserved, find_secrets};
use crate::knowledge_store::{KnowledgeError, MemoryRow, SkillRow};
use crate::vault_routes::{err, resolve_caller};
use crate::AppState;

type ErrResp = (StatusCode, Json<Value>);

#[derive(Debug, Deserialize)]
pub(crate) struct AuthQuery {
    /// atem instance_id — the authorization principal (`?id=`).
    id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct PullQuery {
    id: Option<String>,
    since: Option<i64>,
    limit: Option<i64>,
}

fn op_err(msg: impl Into<String>) -> Value {
    json!({ "ok": false, "error": msg.into() })
}

/// Maps a store error to a per-op result. `Db` (and any other non-domain
/// error) never reaches the client as raw text — only a generic message,
/// with the detail logged server-side.
fn store_err(e: KnowledgeError) -> Value {
    match &e {
        KnowledgeError::IdConflict => op_err(e.to_string()),
        KnowledgeError::Db(detail) => {
            tracing::error!("knowledge store error: {}", detail);
            op_err("internal error")
        }
    }
}

fn internal_err(e: KnowledgeError) -> ErrResp {
    match &e {
        KnowledgeError::Db(detail) => tracing::error!("knowledge store error: {}", detail),
        KnowledgeError::IdConflict => tracing::error!("knowledge store error: {}", e),
    }
    err(StatusCode::INTERNAL_SERVER_ERROR, "internal error")
}

// ─────────────────────────── base64 (standard alphabet, padded) ───────────────────────────

/// Decode standard-alphabet base64 (RFC 4648 §4, with `=` padding). Rejects
/// invalid characters, a length that isn't a multiple of 4, and padding that
/// isn't confined to the final group. No base64 crate exists in this
/// workspace; this is intentionally small and self-contained.
fn base64_decode(s: &str) -> Result<Vec<u8>, ()> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.len() % 4 != 0 {
        return Err(());
    }

    let n = bytes.len();
    let mut out = Vec::with_capacity(n / 4 * 3);
    for (i, chunk) in bytes.chunks_exact(4).enumerate() {
        let is_last = (i + 1) * 4 == n;
        let pad = chunk.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && !is_last) {
            return Err(());
        }
        let data = &chunk[..4 - pad];
        if data.iter().any(|&c| c == b'=') {
            return Err(());
        }
        let mut v = [0u8; 4];
        for (j, &c) in data.iter().enumerate() {
            v[j] = val(c).ok_or(())?;
        }
        let b0 = (v[0] << 2) | (v[1] >> 4);
        let b1 = (v[1] << 4) | (v[2] >> 2);
        let b2 = (v[2] << 6) | v[3];
        match pad {
            0 => out.extend_from_slice(&[b0, b1, b2]),
            1 => out.extend_from_slice(&[b0, b1]),
            2 => out.push(b0),
            _ => unreachable!(),
        }
    }
    Ok(out)
}

// ─────────────────────────── memory batch ───────────────────────────

async fn apply_memory_op(state: &AppState, account: &str, op: Value) -> Value {
    let op_name = op.get("op").and_then(Value::as_str).unwrap_or("");
    match op_name {
        "add" => {
            let memory: MemoryRow = match op.get("memory").cloned() {
                Some(v) => match serde_json::from_value(v) {
                    Ok(m) => m,
                    Err(_) => return op_err("invalid memory"),
                },
                None => return op_err("invalid memory"),
            };
            if contains_reserved(&memory.content) {
                return op_err("reserved token");
            }
            let findings = find_secrets(&memory.content);
            if let Some(f) = findings.first() {
                return op_err(format!("possible credential: {}", f.kind));
            }
            match state.knowledge.add_memory(account, memory).await {
                Ok(o) => {
                    let mut v = json!({ "ok": true, "id": o.id, "seq": o.seq });
                    if let Some(cid) = o.canonical_id {
                        v["canonical_id"] = json!(cid);
                    }
                    v
                }
                Err(e) => store_err(e),
            }
        }
        "delete" => {
            let id = match op.get("id").and_then(Value::as_str) {
                Some(id) => id.to_string(),
                None => return op_err("invalid delete"),
            };
            match state.knowledge.delete_memory(account, &id).await {
                Ok(seq) => json!({ "ok": true, "id": id, "seq": seq }),
                Err(e) => store_err(e),
            }
        }
        _ => op_err("unknown op"),
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct BatchRequest {
    ops: Vec<Value>,
}

/// POST /api/memory/batch {ops:[…]} -> {results:[…]}
pub async fn memory_batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuthQuery>,
    Json(body): Json<BatchRequest>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let mut results = Vec::with_capacity(body.ops.len());
    for op in body.ops {
        results.push(apply_memory_op(&state, &caller.work_session_id, op).await);
    }
    Ok(Json(json!({ "results": results })))
}

/// GET /api/memory [?since&limit] -> {memories:[…]}
pub async fn memory_pull_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let since = query.since.unwrap_or(0);
    let limit = query.limit.unwrap_or(200);
    let rows = state
        .knowledge
        .pull_memories(&caller.work_session_id, since, limit)
        .await
        .map_err(internal_err)?;
    Ok(Json(json!({ "memories": rows })))
}

// ─────────────────────────── skills batch ───────────────────────────

/// Decode every file in a skill's `files` object; on success, run the secret
/// checks against the decoded bytes. Returns the first violation, if any.
fn check_skill_files(files: &Value) -> Result<(), Value> {
    let obj = match files.as_object() {
        Some(o) => o,
        None => return Err(op_err("invalid base64")),
    };
    let mut decoded: Vec<(String, Vec<u8>)> = Vec::with_capacity(obj.len());
    for (path, v) in obj {
        let s = match v.as_str() {
            Some(s) => s,
            None => return Err(op_err("invalid base64")),
        };
        match base64_decode(s) {
            Ok(bytes) => decoded.push((path.clone(), bytes)),
            Err(()) => return Err(op_err("invalid base64")),
        }
    }
    for (path, bytes) in &decoded {
        if let Some(f) = check_bytes(bytes).first() {
            return Err(op_err(format!("possible credential: {}: {}", path, f.kind)));
        }
        if let Ok(text) = std::str::from_utf8(bytes) {
            if contains_reserved(text) {
                return Err(op_err(format!(
                    "possible credential: {}: reserved token",
                    path
                )));
            }
        }
    }
    Ok(())
}

async fn apply_skill_op(state: &AppState, account: &str, op: Value) -> Value {
    let op_name = op.get("op").and_then(Value::as_str).unwrap_or("");
    match op_name {
        "push" => {
            let skill: SkillRow = match op.get("skill").cloned() {
                Some(v) => match serde_json::from_value(v) {
                    Ok(s) => s,
                    Err(_) => return op_err("invalid skill"),
                },
                None => return op_err("invalid skill"),
            };
            let base_version = op.get("base_version").and_then(Value::as_i64).unwrap_or(0);
            if let Err(bad) = check_skill_files(&skill.files) {
                return bad;
            }
            match state.knowledge.push_skill(account, skill, base_version).await {
                Ok(o) => json!({
                    "ok": true,
                    "version": o.version,
                    "seq": o.seq,
                    "superseded_concurrent": o.superseded_concurrent,
                }),
                Err(e) => store_err(e),
            }
        }
        "delete" => {
            let scope = op.get("scope").and_then(Value::as_str).unwrap_or("").to_string();
            let project = op.get("project").and_then(Value::as_str).unwrap_or("").to_string();
            let name = match op.get("name").and_then(Value::as_str) {
                Some(n) => n.to_string(),
                None => return op_err("invalid delete"),
            };
            match state.knowledge.delete_skill(account, &scope, &project, &name).await {
                Ok(o) => json!({ "ok": true, "version": o.version, "seq": o.seq }),
                Err(e) => store_err(e),
            }
        }
        "purge" => {
            let scope = op.get("scope").and_then(Value::as_str).unwrap_or("").to_string();
            let project = op.get("project").and_then(Value::as_str).unwrap_or("").to_string();
            let name = match op.get("name").and_then(Value::as_str) {
                Some(n) => n.to_string(),
                None => return op_err("invalid purge"),
            };
            let versions: Option<Vec<i64>> = match op.get("versions") {
                None | Some(Value::Null) => None,
                Some(v) => match serde_json::from_value(v.clone()) {
                    Ok(vs) => Some(vs),
                    Err(_) => return op_err("invalid purge"),
                },
            };
            match state
                .knowledge
                .purge_skill(account, &scope, &project, &name, versions)
                .await
            {
                Ok(_) => json!({ "ok": true }),
                Err(e) => store_err(e),
            }
        }
        _ => op_err("unknown op"),
    }
}

/// POST /api/skills/batch {ops:[…]} -> {results:[…]}
pub async fn skills_batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuthQuery>,
    Json(body): Json<BatchRequest>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let mut results = Vec::with_capacity(body.ops.len());
    for op in body.ops {
        results.push(apply_skill_op(&state, &caller.work_session_id, op).await);
    }
    Ok(Json(json!({ "results": results })))
}

/// GET /api/skills [?since&limit] -> {skills:[…]}
pub async fn skills_pull_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let since = query.since.unwrap_or(0);
    let limit = query.limit.unwrap_or(200);
    let rows = state
        .knowledge
        .pull_skills(&caller.work_session_id, since, limit)
        .await
        .map_err(internal_err)?;
    Ok(Json(json!({ "skills": rows })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{create_session, SessionStatus};
    use crate::knowledge_store::InMemoryKnowledgeStore;
    use crate::relay::RelayHub;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_store::SessionStore;
    use crate::session_verify::SessionVerifyCache;
    use crate::vault_store::InMemoryVaultStore;
    use crate::voice_session::VoiceSessionStore;
    use axum::body::Body;
    use axum::extract::DefaultBodyLimit;
    use axum::http::Request;
    use axum::routing::{get, post};
    use axum::Router;
    use std::sync::Arc;
    use tower::ServiceExt;

    /// Build an AppState with in-memory stores and a granted session bound to
    /// `astation_id`. Returns (state, session_id).
    async fn test_state(astation_id: &str) -> (AppState, String) {
        let sessions = SessionStore::new();
        let mut session = create_session("test-host");
        session.status = SessionStatus::Granted;
        session.astation_id = Some(astation_id.to_string());
        let session_id = session.id.clone();
        sessions.create(session).await;

        let state = AppState {
            sessions,
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            session_verify_cache: SessionVerifyCache::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: Arc::new(InMemoryVaultStore::new()),
            knowledge: Arc::new(InMemoryKnowledgeStore::new()),
        };
        (state, session_id)
    }

    fn app(state: AppState) -> Router {
        Router::new()
            .route("/api/memory/batch", post(memory_batch_handler))
            .route("/api/memory", get(memory_pull_handler))
            .route("/api/skills/batch", post(skills_batch_handler))
            .route("/api/skills", get(skills_pull_handler))
            .with_state(state)
    }

    async fn body_json(resp: axum::response::Response) -> Value {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    }

    fn req(method: &str, uri: &str, session: &str, body: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("session {}", session))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn req_no_auth(method: &str, uri: &str, body: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn sample_memory(id: &str, content: &str) -> Value {
        json!({
            "id": id,
            "scope": "global",
            "project": "",
            "machine": "",
            "content": content,
            "content_hash": format!("h:{}", content),
            "confidence": "high",
            "source_agent": "claude",
            "source_machine": "m1",
            "created_at": 1_700_000_000,
            "deleted": false,
            "seq": 0,
        })
    }

    fn sample_skill(name: &str, files: Value) -> Value {
        json!({
            "scope": "global",
            "project": "",
            "name": name,
            "version": 0,
            "files": files,
            "content_hash": "h",
            "source_agent": "claude",
            "source_machine": "m1",
            "created_at": 1_700_000_000,
            "deleted": false,
            "seq": 0,
        })
    }

    fn b64(s: &str) -> String {
        // Local, dependency-free encoder for building test fixtures.
        const ALPHA: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let bytes = s.as_bytes();
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0];
            let b1 = *chunk.get(1).unwrap_or(&0);
            let b2 = *chunk.get(2).unwrap_or(&0);
            out.push(ALPHA[(b0 >> 2) as usize] as char);
            out.push(ALPHA[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            out.push(if chunk.len() > 1 {
                ALPHA[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                ALPHA[(b2 & 0x3f) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    // ─────────────────────────── base64 decoder unit tests ───────────────────────────

    #[test]
    fn base64_roundtrips() {
        for s in ["", "a", "ab", "abc", "hello world", "AKIAIOSFODNN7EXAMPLE"] {
            assert_eq!(base64_decode(&b64(s)).unwrap(), s.as_bytes(), "{}", s);
        }
    }

    #[test]
    fn base64_rejects_bad_input() {
        assert!(base64_decode("a").is_err(), "not a multiple of 4");
        assert!(base64_decode("AAA=AAAA").is_err(), "padding not in last group");
        assert!(base64_decode("A=BC").is_err(), "padding mid-group");
        assert!(base64_decode("!!!!").is_err(), "invalid chars");
        assert!(base64_decode("AAAAA===").is_err(), "3 pad chars");
        assert_eq!(base64_decode("").unwrap(), Vec::<u8>::new());
    }

    // ─────────────────────────── memory batch ───────────────────────────

    #[tokio::test]
    async fn memory_batch_requires_session() {
        let (state, _sess) = test_state("ws-1").await;
        let app = app(state);
        let resp = app
            .oneshot(req_no_auth(
                "POST",
                "/api/memory/batch?id=a",
                r#"{"ops":[]}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn memory_batch_requires_client_id() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let resp = app
            .oneshot(req("POST", "/api/memory/batch", &sess, r#"{"ops":[]}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn add_then_pull_round_trips_wire_shape() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mem = sample_memory("mem_1", "use pnpm");
        let batch = json!({ "ops": [{"op": "add", "memory": mem}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], true);
        assert!(results["results"][0]["seq"].as_i64().unwrap() > 0);

        let resp = app
            .clone()
            .oneshot(req("GET", "/api/memory?id=a", &sess, ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let pulled = body_json(resp).await;
        let rows = pulled["memories"].as_array().unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        for (k, v) in mem.as_object().unwrap() {
            if k == "seq" {
                assert!(row["seq"].as_i64().unwrap() > 0);
            } else {
                assert_eq!(&row[k], v, "field {}", k);
            }
        }
    }

    #[tokio::test]
    async fn add_with_credential_is_refused_per_op() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "good content")},
            {"op": "add", "memory": sample_memory("mem_2", "key is sk-proj-abcdef1234567890ABCDEF")},
            {"op": "add", "memory": sample_memory("mem_3", "also good")},
        ]});
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r.len(), 3);
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[1]["ok"], false);
        assert!(r[1]["error"].as_str().unwrap().starts_with("possible credential:"));
        assert_eq!(r[2]["ok"], true);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["memories"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| !r["content"].as_str().unwrap().contains("sk-proj")));
    }

    #[tokio::test]
    async fn add_with_reserved_token_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "see atem:memory:foo for details")},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "reserved token");
    }

    #[tokio::test]
    async fn dedup_returns_canonical_id() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "use pnpm")},
            {"op": "add", "memory": sample_memory("mem_2", "use pnpm")},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = &results["results"];
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[0]["id"], "mem_1");
        assert!(r[0].get("canonical_id").is_none());
        assert_eq!(r[1]["ok"], true);
        assert_eq!(r[1]["id"], "mem_2");
        assert_eq!(r[1]["canonical_id"], "mem_1");
        assert_eq!(r[1]["seq"], r[0]["seq"]);
    }

    #[tokio::test]
    async fn delete_is_idempotent() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let add = json!({ "ops": [{"op": "add", "memory": sample_memory("mem_1", "x")}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &add.to_string(),
            ))
            .await
            .unwrap();

        let del = json!({ "ops": [
            {"op": "delete", "id": "mem_1"},
            {"op": "delete", "id": "mem_1"},
            {"op": "delete", "id": "mem_unknown"},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &del.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r.len(), 3);
        assert!(r.iter().all(|x| x["ok"] == true));
        assert!(r[0]["seq"].as_i64().unwrap() > 0);
        assert_eq!(r[2]["seq"], 0);
    }

    #[tokio::test]
    async fn unknown_memory_op_is_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [{"op": "frobnicate"}] });
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "unknown op");
    }

    #[tokio::test]
    async fn accounts_are_isolated() {
        let (state, sess1) = test_state("ws-1").await;
        let mut s2 = create_session("h2");
        s2.status = SessionStatus::Granted;
        s2.astation_id = Some("ws-2".to_string());
        let sess2 = s2.id.clone();
        state.sessions.create(s2).await;
        let app = app(state);

        let add_mem = json!({ "ops": [{"op": "add", "memory": sample_memory("mem_1", "secret-to-ws1")}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess1,
                &add_mem.to_string(),
            ))
            .await
            .unwrap();
        let push_skill = json!({ "ops": [{"op": "push", "skill": sample_skill("x", json!({"SKILL.md": b64("body")})), "base_version": 0}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess1,
                &push_skill.to_string(),
            ))
            .await
            .unwrap();

        let mem2 = body_json(
            app.clone()
                .oneshot(req("GET", "/api/memory?id=a", &sess2, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(mem2["memories"].as_array().unwrap().len(), 0);
        let sk2 = body_json(
            app.clone()
                .oneshot(req("GET", "/api/skills?id=a", &sess2, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(sk2["skills"].as_array().unwrap().len(), 0);

        let mem1 = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess1, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(mem1["memories"].as_array().unwrap().len(), 1);
    }

    // ─────────────────────────── skills batch ───────────────────────────

    #[tokio::test]
    async fn skill_push_pull_and_supersede() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": b64("# hi")});
        let push1 = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files.clone()), "base_version": 0}] });
        let r1 = body_json(
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push1.to_string(),
                ))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(r1["results"][0]["ok"], true);
        assert_eq!(r1["results"][0]["version"], 1);
        assert_eq!(r1["results"][0]["superseded_concurrent"], false);

        // Stale base_version → still applied, flagged.
        let push2 = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files.clone()), "base_version": 0}] });
        let r2 = body_json(
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push2.to_string(),
                ))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(r2["results"][0]["version"], 2);
        assert_eq!(r2["results"][0]["superseded_concurrent"], true);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["skills"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["files"], files);
    }

    #[tokio::test]
    async fn skill_with_secret_file_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"creds.txt": b64("AKIAIOSFODNN7EXAMPLE")});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        let e = results["results"][0]["error"].as_str().unwrap();
        assert!(e.starts_with("possible credential: creds.txt:"), "{}", e);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(pulled["skills"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn skill_push_with_invalid_base64_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": "not-valid-base64!!"});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid base64");
    }

    #[tokio::test]
    async fn skill_delete_appends_tombstone_and_is_idempotent_on_unknown() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": b64("v1")});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();

        let del = json!({ "ops": [
            {"op": "delete", "scope": "global", "project": "", "name": "x"},
            {"op": "delete", "scope": "global", "project": "", "name": "does-not-exist"},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &del.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[0]["version"], 2);
        assert_eq!(r[1]["ok"], true);
        assert_eq!(r[1]["version"], 0);
        assert_eq!(r[1]["seq"], 0);
    }

    #[tokio::test]
    async fn skill_purge_all() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        for body in ["v1", "v2"] {
            let files = json!({"SKILL.md": b64(body)});
            let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push.to_string(),
                ))
                .await
                .unwrap();
        }

        let purge = json!({ "ops": [
            {"op": "purge", "scope": "global", "project": "", "name": "x", "versions": null},
        ]});
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &purge.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0], json!({"ok": true}));

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["skills"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r["deleted"] == true));
    }

    #[tokio::test]
    async fn oversized_skills_body_is_rejected() {
        let (state, sess) = test_state("ws-1").await;
        let app = Router::new()
            .route(
                "/api/skills/batch",
                post(skills_batch_handler)
                    .layer(DefaultBodyLimit::max(16 * 1024 * 1024)),
            )
            .with_state(state);

        // Over 16 MiB of raw body bytes.
        let big = "x".repeat(16 * 1024 * 1024 + 1);
        let resp = app
            .oneshot(req("POST", "/api/skills/batch?id=a", &sess, &big))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }
}
