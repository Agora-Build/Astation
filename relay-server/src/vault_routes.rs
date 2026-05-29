use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::auth::SessionStatus;
use crate::vault_store::VaultMeta;
use crate::AppState;

type ErrResp = (StatusCode, Json<serde_json::Value>);

fn err(status: StatusCode, msg: &str) -> ErrResp {
    (status, Json(json!({ "error": msg })))
}

/// The authenticated caller of a vault request.
struct Caller {
    work_session_id: String,
    client_id: String,
}

#[derive(Debug, Deserialize)]
pub struct VaultQuery {
    /// atem instance_id — the authorization principal.
    pub id: Option<String>,
    /// Incremental read cursor (read endpoint only).
    pub since: Option<i64>,
    /// Whether to return full history (read endpoint only).
    pub history: Option<bool>,
}

/// Validate the session + extract the client_id. Resolves work_session_id to
/// the astation_id the session is bound to (Option A). 401 on bad session,
/// 400 on missing client id.
async fn resolve_caller(
    state: &AppState,
    headers: &HeaderMap,
    query: &VaultQuery,
) -> Result<Caller, ErrResp> {
    // Authorization: session <session_id>
    let auth = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let session_id = auth
        .strip_prefix("session ")
        .or_else(|| auth.strip_prefix("Session "))
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| err(StatusCode::UNAUTHORIZED, "missing session authorization"))?;

    let client_id = query
        .id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| err(StatusCode::BAD_REQUEST, "missing ?id=<client_id>"))?
        .to_string();

    // Resolve the bound astation_id (work_session_id). Primary source: a granted
    // session in the SessionStore carrying astation_id (Option A). Fallback: the
    // cross-service verify cache (which maps session -> astation_id).
    let work_session_id = match state.sessions.get(session_id).await {
        Some(s) if s.status == SessionStatus::Granted => {
            if let Some(aid) = s.astation_id {
                Some(aid)
            } else {
                state.session_verify_cache.get_astation_id(session_id).await
            }
        }
        Some(_) => None, // exists but not granted
        None => state.session_verify_cache.get_astation_id(session_id).await,
    }
    .ok_or_else(|| err(StatusCode::UNAUTHORIZED, "invalid or unbound session"))?;

    Ok(Caller {
        work_session_id,
        client_id,
    })
}

fn can_read(meta: &VaultMeta, caller: &Caller) -> bool {
    caller.work_session_id == meta.work_session_id
        || meta.writer_list.iter().any(|w| w == &caller.client_id)
}

fn can_write(meta: &VaultMeta, caller: &Caller) -> bool {
    caller.work_session_id == meta.work_session_id
}

async fn load_meta(state: &AppState, vault_id: &str) -> Result<VaultMeta, ErrResp> {
    state
        .vault
        .get_meta(vault_id)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?
        .ok_or_else(|| err(StatusCode::NOT_FOUND, "vault not found"))
}

// ─────────────────────────── Handlers ───────────────────────────

#[derive(Debug, Deserialize)]
pub struct CreateVaultRequest {
    #[serde(default)]
    pub summary: String,
}

/// POST /api/vault  {summary} -> {vault_id}
pub async fn create_vault_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<VaultQuery>,
    Json(body): Json<CreateVaultRequest>,
) -> Result<Json<serde_json::Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, &query).await?;
    let vault_id = state
        .vault
        .create_vault(&caller.work_session_id, &caller.client_id, &body.summary)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;
    Ok(Json(json!({ "vault_id": vault_id })))
}

/// GET /api/vault -> [{vault_id, summary}]
pub async fn list_vaults_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<VaultQuery>,
) -> Result<Json<serde_json::Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, &query).await?;
    let items = state
        .vault
        .list_readable(&caller.work_session_id, &caller.client_id)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;
    Ok(Json(serde_json::to_value(items).unwrap()))
}

/// GET /api/vault/:id [?since&history] -> [VaultEntry]
pub async fn read_vault_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Query(query): Query<VaultQuery>,
) -> Result<Json<serde_json::Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, &query).await?;
    let meta = load_meta(&state, &vault_id).await?;
    if !can_read(&meta, &caller) {
        return Err(err(StatusCode::FORBIDDEN, "not authorized to read this vault"));
    }
    let entries = state
        .vault
        .read(&vault_id, query.since, query.history.unwrap_or(false))
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;
    Ok(Json(serde_json::to_value(entries).unwrap()))
}

#[derive(Debug, Deserialize)]
pub struct WriteVaultRequest {
    pub text: String,
    #[serde(default)]
    pub entry_id: Option<i32>,
}

/// POST /api/vault/:id  {text, entry_id?} -> {entry_no, version, seq}
pub async fn write_vault_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Query(query): Query<VaultQuery>,
    Json(body): Json<WriteVaultRequest>,
) -> Result<Json<serde_json::Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, &query).await?;
    let meta = load_meta(&state, &vault_id).await?;
    if !can_write(&meta, &caller) {
        return Err(err(StatusCode::FORBIDDEN, "not authorized to write this vault"));
    }

    let result = if let Some(entry_no) = body.entry_id {
        state
            .vault
            .override_entry(&vault_id, entry_no, &caller.client_id, &body.text)
            .await
    } else {
        state
            .vault
            .append(&vault_id, &caller.client_id, &body.text)
            .await
    }
    .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;

    // Record the content writer (dedup).
    state
        .vault
        .add_writer(&vault_id, &caller.client_id)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;

    Ok(Json(json!({
        "entry_no": result.entry_no,
        "version": result.version,
        "seq": result.seq,
    })))
}

#[derive(Debug, Deserialize)]
pub struct SetSummaryRequest {
    pub text: String,
}

/// POST /api/vault/:id/summary  {text} -> {}
pub async fn set_summary_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Query(query): Query<VaultQuery>,
    Json(body): Json<SetSummaryRequest>,
) -> Result<Json<serde_json::Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, &query).await?;
    let meta = load_meta(&state, &vault_id).await?;
    // set-summary uses the read predicate (mutable, low-stakes).
    if !can_read(&meta, &caller) {
        return Err(err(StatusCode::FORBIDDEN, "not authorized for this vault"));
    }
    state
        .vault
        .set_summary(&vault_id, &body.text)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;
    Ok(Json(json!({})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{create_session, SessionStatus};
    use crate::relay::RelayHub;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_store::SessionStore;
    use crate::session_verify::SessionVerifyCache;
    use crate::vault_store::InMemoryVaultStore;
    use crate::voice_session::VoiceSessionStore;
    use axum::body::Body;
    use axum::http::Request;
    use axum::routing::{get, post};
    use axum::Router;
    use std::sync::Arc;
    use tower::ServiceExt;

    /// Build an AppState with an in-memory vault and a granted session bound to
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
        };
        (state, session_id)
    }

    fn app(state: AppState) -> Router {
        Router::new()
            .route("/api/vault", post(create_vault_handler).get(list_vaults_handler))
            .route("/api/vault/:id", get(read_vault_handler).post(write_vault_handler))
            .route("/api/vault/:id/summary", post(set_summary_handler))
            .with_state(state)
    }

    async fn body_json(resp: axum::response::Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
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

    #[tokio::test]
    async fn create_then_read_roundtrip() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);

        let resp = app.clone()
            .oneshot(req("POST", "/api/vault?id=client-a", &sess, r#"{"summary":"auth refactor"}"#))
            .await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let vault_id = body_json(resp).await["vault_id"].as_str().unwrap().to_string();

        // Write an entry.
        let resp = app.clone()
            .oneshot(req("POST", &format!("/api/vault/{}?id=client-a", vault_id), &sess, r#"{"text":"decided: JWT in cookie"}"#))
            .await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let w = body_json(resp).await;
        assert_eq!(w["entry_no"], 1);
        assert_eq!(w["version"], 1);

        // Read current view.
        let resp = app.clone()
            .oneshot(req("GET", &format!("/api/vault/{}?id=client-a", vault_id), &sess, ""))
            .await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let entries = body_json(resp).await;
        assert_eq!(entries.as_array().unwrap().len(), 1);
        assert_eq!(entries[0]["content"], "decided: JWT in cookie");
    }

    #[tokio::test]
    async fn append_then_override_history() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let vault_id = {
            let resp = app.clone()
                .oneshot(req("POST", "/api/vault?id=a", &sess, r#"{}"#)).await.unwrap();
            body_json(resp).await["vault_id"].as_str().unwrap().to_string()
        };

        app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=a", vault_id), &sess, r#"{"text":"v1"}"#)).await.unwrap();
        app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=a", vault_id), &sess, r#"{"text":"v2","entry_id":1}"#)).await.unwrap();

        // Current view: only v2.
        let current = body_json(app.clone().oneshot(req("GET", &format!("/api/vault/{}?id=a", vault_id), &sess, "")).await.unwrap()).await;
        assert_eq!(current.as_array().unwrap().len(), 1);
        assert_eq!(current[0]["version"], 2);

        // History: v1 + v2.
        let history = body_json(app.clone().oneshot(req("GET", &format!("/api/vault/{}?id=a&history=true", vault_id), &sess, "")).await.unwrap()).await;
        assert_eq!(history.as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn since_filters() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let vault_id = body_json(app.clone().oneshot(req("POST", "/api/vault?id=a", &sess, r#"{}"#)).await.unwrap()).await["vault_id"].as_str().unwrap().to_string();
        let w1 = body_json(app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=a", vault_id), &sess, r#"{"text":"first"}"#)).await.unwrap()).await;
        app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=a", vault_id), &sess, r#"{"text":"second"}"#)).await.unwrap();
        let seq1 = w1["seq"].as_i64().unwrap();

        let after = body_json(app.clone().oneshot(req("GET", &format!("/api/vault/{}?id=a&history=true&since={}", vault_id, seq1), &sess, "")).await.unwrap()).await;
        assert_eq!(after.as_array().unwrap().len(), 1);
        assert_eq!(after[0]["content"], "second");
    }

    #[tokio::test]
    async fn authz_out_of_session_past_writer_read_only() {
        // Vault created in ws-1 by client-a, who becomes a writer.
        let (state, sess1) = test_state("ws-1").await;
        // Add a second granted session bound to a different work session ws-2.
        let mut s2 = create_session("host2");
        s2.status = SessionStatus::Granted;
        s2.astation_id = Some("ws-2".to_string());
        let sess2 = s2.id.clone();
        state.sessions.create(s2).await;

        let app = app(state);
        let vault_id = body_json(app.clone().oneshot(req("POST", "/api/vault?id=client-a", &sess1, r#"{}"#)).await.unwrap()).await["vault_id"].as_str().unwrap().to_string();
        // client-a writes → becomes a past writer.
        app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=client-a", vault_id), &sess1, r#"{"text":"x"}"#)).await.unwrap();

        // Out-of-session (ws-2) but past-writer client-a: read OK.
        let read = app.clone().oneshot(req("GET", &format!("/api/vault/{}?id=client-a", vault_id), &sess2, "")).await.unwrap();
        assert_eq!(read.status(), StatusCode::OK);

        // Out-of-session past-writer: write FORBIDDEN.
        let write = app.clone().oneshot(req("POST", &format!("/api/vault/{}?id=client-a", vault_id), &sess2, r#"{"text":"y"}"#)).await.unwrap();
        assert_eq!(write.status(), StatusCode::FORBIDDEN);

        // Stranger (ws-2, not a writer): read FORBIDDEN.
        let stranger = app.clone().oneshot(req("GET", &format!("/api/vault/{}?id=stranger", vault_id), &sess2, "")).await.unwrap();
        assert_eq!(stranger.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn missing_session_is_401() {
        let (state, _sess) = test_state("ws-1").await;
        let app = app(state);
        let resp = app.oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/vault?id=a")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        ).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn set_summary_ok() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let vault_id = body_json(app.clone().oneshot(req("POST", "/api/vault?id=a", &sess, r#"{"summary":"old"}"#)).await.unwrap()).await["vault_id"].as_str().unwrap().to_string();
        let resp = app.clone().oneshot(req("POST", &format!("/api/vault/{}/summary?id=a", vault_id), &sess, r#"{"text":"new summary"}"#)).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let list = body_json(app.clone().oneshot(req("GET", "/api/vault?id=a", &sess, "")).await.unwrap()).await;
        assert_eq!(list[0]["summary"], "new summary");
    }
}
