use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use async_trait::async_trait;

use crate::cluster::StoreError;

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use validator::Validate;

use crate::AppState;

const PUBLIC_BASE_URL_ENV_KEYS: [&str; 2] = ["PUBLIC_BASE_URL", "STATION_PUBLIC_BASE_URL"];
static PUBLIC_BASE_URL_CACHE: OnceLock<Option<String>> = OnceLock::new();

fn first_csv_header_value(headers: &HeaderMap, key: &str) -> Option<String> {
    headers
        .get(key)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_public_base_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    if !trimmed.starts_with("http://") && !trimmed.starts_with("https://") {
        return None;
    }
    if trimmed.contains('?') || trimmed.contains('#') {
        return None;
    }
    Some(trimmed.to_string())
}

fn configured_public_base_url() -> Option<String> {
    PUBLIC_BASE_URL_CACHE
        .get_or_init(|| {
            for key in PUBLIC_BASE_URL_ENV_KEYS {
                if let Ok(raw_value) = std::env::var(key) {
                    if raw_value.trim().is_empty() {
                        continue;
                    }
                    if let Some(normalized) = normalize_public_base_url(&raw_value) {
                        return Some(normalized);
                    }
                    tracing::warn!(
                        "Ignoring invalid {} value (must include http(s):// and no query/fragment): {}",
                        key,
                        raw_value
                    );
                }
            }
            None
        })
        .clone()
}

fn parse_forwarded_header(headers: &HeaderMap) -> (Option<String>, Option<String>) {
    let Some(forwarded) = first_csv_header_value(headers, "forwarded") else {
        return (None, None);
    };

    let mut proto: Option<String> = None;
    let mut host: Option<String> = None;
    for part in forwarded.split(';') {
        let mut kv = part.splitn(2, '=');
        let key = kv
            .next()
            .map(str::trim)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let value = kv
            .next()
            .map(str::trim)
            .unwrap_or_default()
            .trim_matches('"')
            .to_string();
        if value.is_empty() {
            continue;
        }
        match key.as_str() {
            "proto" => proto = Some(value),
            "host" => host = Some(value),
            _ => {}
        }
    }
    (proto, host)
}

fn host_has_port(host: &str) -> bool {
    if host.starts_with('[') {
        host.contains("]:")
    } else {
        host.matches(':').count() == 1
    }
}

fn local_hostname(host: &str) -> bool {
    let host_only = if host.starts_with('[') {
        host.trim_start_matches('[')
            .split(']')
            .next()
            .unwrap_or(host)
            .to_string()
    } else {
        host.split(':').next().unwrap_or(host).to_string()
    };

    host_only == "localhost"
        || host_only == "127.0.0.1"
        || host_only == "::1"
        || host_only.starts_with("10.")
        || host_only.starts_with("192.168.")
        || host_only
            .strip_prefix("172.")
            .and_then(|tail| tail.split('.').next())
            .and_then(|segment| segment.parse::<u8>().ok())
            .map(|second_octet| (16..=31).contains(&second_octet))
            .unwrap_or(false)
}

fn normalize_proto(proto: &str) -> Option<&'static str> {
    match proto.trim().to_ascii_lowercase().as_str() {
        "http" => Some("http"),
        "https" => Some("https"),
        _ => None,
    }
}

fn derive_session_base_url(headers: &HeaderMap, configured_base: Option<&str>) -> String {
    if let Some(base) = configured_base.and_then(normalize_public_base_url) {
        return base;
    }

    let (forwarded_proto, forwarded_host) = parse_forwarded_header(headers);

    let mut host = forwarded_host
        .or_else(|| first_csv_header_value(headers, "x-forwarded-host"))
        .or_else(|| first_csv_header_value(headers, "host"))
        .unwrap_or_else(|| "localhost:8080".to_string());

    if !host_has_port(&host) {
        if let Some(port) = first_csv_header_value(headers, "x-forwarded-port") {
            if !port.is_empty() {
                host = format!("{}:{}", host, port);
            }
        }
    }

    let inferred_proto = if local_hostname(&host) { "http" } else { "https" };
    let proto = forwarded_proto
        .or_else(|| first_csv_header_value(headers, "x-forwarded-proto"))
        .and_then(|value| normalize_proto(&value).map(str::to_string))
        .unwrap_or_else(|| inferred_proto.to_string());

    format!("{}://{}", proto, host)
}

// --- Data Models ---

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Participant {
    pub uid: u32,
    pub display_name: Option<String>,
    pub joined_at: DateTime<Utc>,
}

/// Snapshot of an RTC session (returned by store operations).
#[derive(Clone, Debug)]
pub struct RtcSession {
    pub id: String,
    pub app_id: String,
    pub channel: String,
    pub token: String,
    pub uid_counter_value: u32,
    pub host_uid: u32,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub participants: Vec<Participant>,
}

// --- Request / Response types ---

#[derive(Deserialize, Validate)]
pub struct CreateRtcSessionRequest {
    #[validate(length(min = 1, max = 255))]
    pub app_id: String,
    #[validate(length(min = 1, max = 64))]
    pub channel: String,
    #[validate(length(min = 1, max = 4096))]
    pub token: String,
    pub host_uid: u32,
}

#[derive(Serialize, Deserialize)]
pub struct CreateRtcSessionResponse {
    pub id: String,
    pub url: String,
}

#[derive(Serialize, Deserialize)]
pub struct GetRtcSessionResponse {
    pub app_id: String,
    pub channel: String,
    pub host_uid: u32,
    pub created_at: DateTime<Utc>,
}

#[derive(Deserialize, Validate)]
pub struct JoinRtcSessionRequest {
    #[validate(length(min = 1, max = 100))]
    pub name: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JoinRtcSessionResponse {
    pub app_id: String,
    pub channel: String,
    pub token: String,
    pub uid: u32,
    pub name: String,
}

#[derive(Serialize, Deserialize)]
pub struct RtcSessionError {
    pub error: String,
}

// --- Store ---

pub const MAX_RTC_PARTICIPANTS: usize = 8;
pub const RTC_FIRST_UID: u32 = 1000;
pub const RTC_SESSION_TTL_HOURS: i64 = 4;

#[derive(Debug)]
pub enum JoinOutcome {
    NotFound,
    Full,
    Joined(JoinRtcSessionResponse),
}

#[async_trait]
pub trait RtcBackend: Send + Sync {
    async fn create(&self, session: RtcSession) -> Result<(), StoreError>;
    async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError>;
    /// Take the next uid and add a participant, atomically, unless the
    /// session already has MAX_RTC_PARTICIPANTS.
    async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError>;
    async fn delete(&self, id: &str) -> Result<bool, StoreError>;
    async fn cleanup_expired(&self, now: DateTime<Utc>) -> Result<(), StoreError>;
}

#[derive(Clone, Default)]
pub struct InMemoryRtcBackend {
    sessions: Arc<std::sync::Mutex<HashMap<String, RtcSession>>>,
}

impl InMemoryRtcBackend {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, RtcSession>> {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[async_trait]
impl RtcBackend for InMemoryRtcBackend {
    async fn create(&self, session: RtcSession) -> Result<(), StoreError> {
        self.lock().insert(session.id.clone(), session);
        Ok(())
    }

    async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
        Ok(self.lock().get(id).cloned())
    }

    async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError> {
        let mut sessions = self.lock();
        let Some(session) = sessions.get_mut(id) else {
            return Ok(JoinOutcome::NotFound);
        };
        let current_count = session.participants.len();
        tracing::info!(
            "Join request for session {}: current participants = {}, name = {}",
            id,
            current_count,
            name
        );
        // Enforce 8-person limit (including host)
        if current_count >= MAX_RTC_PARTICIPANTS {
            tracing::warn!("Session {} is full ({} participants)", id, current_count);
            return Ok(JoinOutcome::Full);
        }
        let uid = session.uid_counter_value;
        session.uid_counter_value += 1;
        session.participants.push(Participant {
            uid,
            display_name: Some(name.clone()),
            joined_at: now,
        });
        tracing::info!(
            "User {} joined session {} with UID {} (total participants: {})",
            name,
            id,
            uid,
            session.participants.len()
        );
        Ok(JoinOutcome::Joined(JoinRtcSessionResponse {
            app_id: session.app_id.clone(),
            channel: session.channel.clone(),
            token: session.token.clone(),
            uid,
            name,
        }))
    }

    async fn delete(&self, id: &str) -> Result<bool, StoreError> {
        Ok(self.lock().remove(id).is_some())
    }

    async fn cleanup_expired(&self, now: DateTime<Utc>) -> Result<(), StoreError> {
        self.lock().retain(|_, session| now <= session.expires_at);
        Ok(())
    }
}

#[derive(Clone)]
pub struct RtcSessionStore {
    backend: Arc<dyn RtcBackend>,
}

impl RtcSessionStore {
    pub fn new() -> Self {
        Self::with_backend(Arc::new(InMemoryRtcBackend::default()))
    }

    pub fn with_backend(backend: Arc<dyn RtcBackend>) -> Self {
        Self { backend }
    }

    pub async fn create(
        &self,
        id: String,
        app_id: String,
        channel: String,
        token: String,
        host_uid: u32,
    ) -> Result<RtcSession, StoreError> {
        let now = Utc::now();
        let session = RtcSession {
            id,
            app_id,
            channel,
            token,
            uid_counter_value: RTC_FIRST_UID,
            host_uid,
            created_at: now,
            expires_at: now + Duration::hours(RTC_SESSION_TTL_HOURS),
            participants: Vec::new(),
        };
        self.backend.create(session.clone()).await?;
        Ok(session)
    }

    pub async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
        self.backend.get(id).await
    }

    /// Join a session; the error text drives the HTTP status (see
    /// `join_error_status`).
    pub async fn join(&self, id: &str, name: String) -> Result<JoinRtcSessionResponse, String> {
        match self.backend.join(id, name, Utc::now()).await {
            Ok(JoinOutcome::Joined(response)) => Ok(response),
            Ok(JoinOutcome::NotFound) => Err("Session not found".to_string()),
            Ok(JoinOutcome::Full) => Err("Session is full (maximum 8 participants)".to_string()),
            Err(error) => {
                tracing::error!("RTC session store unavailable: {}", error);
                Err("Temporarily unavailable".to_string())
            }
        }
    }

    pub async fn delete(&self, id: &str) -> Result<bool, StoreError> {
        self.backend.delete(id).await
    }

    pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
        self.backend.cleanup_expired(Utc::now()).await
    }
}

impl Default for RtcSessionStore {
    fn default() -> Self {
        Self::new()
    }
}

/// HTTP status for a `join` error message.
fn join_error_status(error: &str) -> StatusCode {
    if error.contains("unavailable") {
        StatusCode::SERVICE_UNAVAILABLE
    } else if error.contains("not found") {
        StatusCode::NOT_FOUND
    } else if error.contains("full") {
        StatusCode::CONFLICT
    } else {
        StatusCode::INTERNAL_SERVER_ERROR
    }
}

fn rtc_unavailable(error: StoreError) -> (StatusCode, Json<RtcSessionError>) {
    tracing::error!("RTC session store unavailable: {}", error);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(RtcSessionError { error: "Temporarily unavailable".to_string() }),
    )
}

// --- Route Handlers ---

/// POST /api/rtc-sessions
pub async fn create_rtc_session_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateRtcSessionRequest>,
) -> impl IntoResponse {
    // Validate input
    if let Err(e) = body.validate() {
        return (
            StatusCode::BAD_REQUEST,
            Json(CreateRtcSessionResponse {
                id: String::new(),
                url: format!("Validation error: {}", e),
            }),
        )
            .into_response();
    }

    let id = Uuid::new_v4().to_string();

    // Log all relevant headers for debugging
    let host_header = headers.get("host").and_then(|h| h.to_str().ok()).unwrap_or("(none)");
    let x_fwd_host = headers.get("x-forwarded-host").and_then(|h| h.to_str().ok()).unwrap_or("(none)");
    let x_fwd_port = headers.get("x-forwarded-port").and_then(|h| h.to_str().ok()).unwrap_or("(none)");
    let x_fwd_proto = headers.get("x-forwarded-proto").and_then(|h| h.to_str().ok()).unwrap_or("(none)");

    tracing::info!(
        "Creating RTC session - Headers: Host={}, X-Forwarded-Host={}, X-Forwarded-Port={}, X-Forwarded-Proto={}",
        host_header, x_fwd_host, x_fwd_port, x_fwd_proto
    );

    let configured_public_base = configured_public_base_url();
    if let Some(base) = configured_public_base.as_deref() {
        tracing::info!("Using configured public base URL for sessions: {}", base);
    }
    let base_url = derive_session_base_url(&headers, configured_public_base.as_deref());
    let url = format!("{}/session/{}", base_url, id);

    tracing::info!("Generated session URL: {}", url);

    if let Err(error) = state
        .rtc_sessions
        .create(id.clone(), body.app_id, body.channel, body.token, body.host_uid)
        .await
    {
        return rtc_unavailable(error).into_response();
    }

    (
        StatusCode::CREATED,
        Json(CreateRtcSessionResponse { id, url }),
    )
        .into_response()
}

/// GET /api/rtc-sessions/:id
pub async fn get_rtc_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<GetRtcSessionResponse>, (StatusCode, Json<RtcSessionError>)> {
    match state.rtc_sessions.get(&id).await.map_err(rtc_unavailable)? {
        Some(session) => Ok(Json(GetRtcSessionResponse {
            app_id: session.app_id,
            channel: session.channel,
            host_uid: session.host_uid,
            created_at: session.created_at,
        })),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(RtcSessionError {
                error: "Session not found".to_string(),
            }),
        )),
    }
}

/// POST /api/rtc-sessions/:id/join
pub async fn join_rtc_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<JoinRtcSessionRequest>,
) -> impl IntoResponse {
    // Validate input
    if let Err(e) = body.validate() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(RtcSessionError {
                error: format!("Validation error: {}", e),
            }),
        ));
    }

    match state.rtc_sessions.join(&id, body.name).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            let status = join_error_status(&error);
            Err((status, Json(RtcSessionError { error })))
        }
    }
}

/// DELETE /api/rtc-sessions/:id
pub async fn delete_rtc_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.rtc_sessions.delete(&id).await {
        Ok(true) => StatusCode::OK,
        Ok(false) => StatusCode::NOT_FOUND,
        Err(error) => rtc_unavailable(error).0,
    }
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{HeaderMap, HeaderValue, Request, StatusCode},
        routing::{delete, get, post},
        Router,
    };
    use crate::relay::RelayHub;
    use crate::session_store::SessionStore;
    use crate::voice_session::VoiceSessionStore;
    use tower::ServiceExt;

    fn create_test_app() -> Router {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        Router::new()
            .route("/api/rtc-sessions", post(create_rtc_session_handler))
            .route("/api/rtc-sessions/:id", get(get_rtc_session_handler))
            .route(
                "/api/rtc-sessions/:id/join",
                post(join_rtc_session_handler),
            )
            .route(
                "/api/rtc-sessions/:id",
                delete(delete_rtc_session_handler),
            )
            .with_state(state)
    }

    // --- Store Tests ---

    #[tokio::test]
    async fn test_create_and_get_session() {
        let store = RtcSessionStore::new();
        let session = store
            .create(
                "test-id".into(),
                "app123".into(),
                "my-channel".into(),
                "token-abc".into(),
                5678,
            )
            .await.unwrap();

        assert_eq!(session.id, "test-id");
        assert_eq!(session.app_id, "app123");
        assert_eq!(session.channel, "my-channel");
        assert_eq!(session.host_uid, 5678);

        let retrieved = store.get("test-id").await.unwrap();
        assert!(retrieved.is_some());
        let retrieved = retrieved.unwrap();
        assert_eq!(retrieved.app_id, "app123");
        assert_eq!(retrieved.channel, "my-channel");
        assert_eq!(retrieved.token, "token-abc");
        assert_eq!(retrieved.host_uid, 5678);
    }

    #[tokio::test]
    async fn test_get_nonexistent() {
        let store = RtcSessionStore::new();
        assert!(store.get("does-not-exist").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn test_delete_session() {
        let store = RtcSessionStore::new();
        store
            .create("del-me".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await.unwrap();
        assert!(store.get("del-me").await.unwrap().is_some());
        assert!(store.delete("del-me").await.unwrap());
        assert!(store.get("del-me").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn test_join_assigns_unique_uids() {
        let store = RtcSessionStore::new();
        store
            .create("join-test".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await.unwrap();

        let r1 = store.join("join-test", "Alice".into()).await.unwrap();
        let r2 = store.join("join-test", "Bob".into()).await.unwrap();
        let r3 = store.join("join-test", "Charlie".into()).await.unwrap();

        assert_eq!(r1.uid, 1000);
        assert_eq!(r2.uid, 1001);
        assert_eq!(r3.uid, 1002);
    }

    #[tokio::test]
    async fn test_join_nonexistent() {
        let store = RtcSessionStore::new();
        assert!(store.join("nope", "Alice".into()).await.is_err());
    }

    #[tokio::test]
    async fn test_join_returns_correct_session_info() {
        let store = RtcSessionStore::new();
        store
            .create("info-test".into(), "my-app".into(), "room1".into(), "secret-token".into(), 42)
            .await.unwrap();

        let resp = store.join("info-test", "Dave".into()).await.unwrap();
        assert_eq!(resp.app_id, "my-app");
        assert_eq!(resp.channel, "room1");
        assert_eq!(resp.token, "secret-token");
        assert_eq!(resp.name, "Dave");
    }

    #[tokio::test]
    async fn test_join_records_participant_name() {
        let store = RtcSessionStore::new();
        store
            .create("part-test".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await.unwrap();

        let _ = store.join("part-test", "Alice".into()).await;

        let session = store.get("part-test").await.unwrap().unwrap();
        assert_eq!(session.participants.len(), 1);
        assert_eq!(
            session.participants[0].display_name,
            Some("Alice".to_string())
        );
        assert_eq!(session.participants[0].uid, 1000);
    }

    #[tokio::test]
    async fn test_cleanup_expired() {
        let backend = InMemoryRtcBackend::default();
        let store = RtcSessionStore::with_backend(Arc::new(backend.clone()));
        backend
            .create(RtcSession {
                id: "expired".into(),
                app_id: "a".into(),
                channel: "c".into(),
                token: "t".into(),
                uid_counter_value: RTC_FIRST_UID,
                host_uid: 1,
                created_at: Utc::now() - Duration::hours(5),
                expires_at: Utc::now() - Duration::hours(1),
                participants: Vec::new(),
            })
            .await
            .unwrap();
        store
            .create("active".into(), "a".into(), "c".into(), "t".into(), 1)
            .await
            .unwrap();

        store.cleanup_expired().await.unwrap();

        assert!(store.get("expired").await.unwrap().is_none());
        assert!(store.get("active").await.unwrap().is_some());
    }

    struct BrokenBackend;

    #[async_trait]
    impl RtcBackend for BrokenBackend {
        async fn create(&self, _: RtcSession) -> Result<(), StoreError> {
            Err(StoreError::Unavailable("secret-host:6379".into()))
        }
        async fn get(&self, _: &str) -> Result<Option<RtcSession>, StoreError> {
            Err(StoreError::Unavailable("secret-host:6379".into()))
        }
        async fn join(&self, _: &str, _: String, _: DateTime<Utc>) -> Result<JoinOutcome, StoreError> {
            Err(StoreError::Unavailable("secret-host:6379".into()))
        }
        async fn delete(&self, _: &str) -> Result<bool, StoreError> {
            Err(StoreError::Unavailable("secret-host:6379".into()))
        }
        async fn cleanup_expired(&self, _: DateTime<Utc>) -> Result<(), StoreError> {
            Err(StoreError::Unavailable("secret-host:6379".into()))
        }
    }

    #[tokio::test]
    async fn join_error_body_does_not_leak_backend_text() {
        let store = RtcSessionStore::with_backend(Arc::new(BrokenBackend));
        let error = store.join("x", "n".into()).await.unwrap_err();
        assert_eq!(error, "Temporarily unavailable");
        assert_eq!(join_error_status(&error), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn join_handler_maps_an_unavailable_store_to_503() {
        assert_eq!(join_error_status("Temporarily unavailable"), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(join_error_status("Session not found"), StatusCode::NOT_FOUND);
        assert_eq!(join_error_status("Session is full (maximum 8 participants)"), StatusCode::CONFLICT);
        assert_eq!(join_error_status("anything else"), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn test_cleanup_preserves_active() {
        let store = RtcSessionStore::new();
        store
            .create("keep-me".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        store.cleanup_expired().await.unwrap();

        assert!(store.get("keep-me").await.unwrap().is_some());
    }

    #[tokio::test]
    async fn test_uid_counter_starts_at_1000() {
        let store = RtcSessionStore::new();
        store
            .create("uid-test".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        let resp = store.join("uid-test", "First".into()).await.unwrap();
        assert_eq!(resp.uid, 1000);
    }

    #[tokio::test]
    async fn test_concurrent_joins() {
        let store = RtcSessionStore::new();
        store
            .create("concurrent".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        let mut handles = Vec::new();
        for i in 0..10 {
            let store = store.clone();
            handles.push(tokio::spawn(async move {
                store
                    .join("concurrent", format!("User{}", i))
                    .await
                    .ok()
                    .map(|r| r.uid)
            }));
        }

        let mut uids = Vec::new();
        for handle in handles {
            if let Some(uid) = handle.await.unwrap() {
                uids.push(uid);
            }
        }

        uids.sort();
        uids.dedup();
        assert_eq!(uids.len(), 8, "Should allow maximum 8 participants");
        assert_eq!(*uids.first().unwrap(), 1000);
        assert_eq!(*uids.last().unwrap(), 1007);
    }

    #[tokio::test]
    async fn test_max_participants_enforced() {
        let store = RtcSessionStore::new();
        store
            .create("full-test".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        // Join 8 people successfully
        for i in 0..8 {
            let result = store.join("full-test", format!("User{}", i)).await;
            assert!(result.is_ok(), "User {} should join successfully", i);
        }

        // 9th person should fail
        let result = store.join("full-test", "User9".into()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("full"));
    }

    #[test]
    fn test_derive_session_base_url_prefers_configured_public_base() {
        let mut headers = HeaderMap::new();
        headers.insert("host", HeaderValue::from_static("internal:3000"));
        headers.insert(
            "x-forwarded-host",
            HeaderValue::from_static("station-staging.agora.build"),
        );
        headers.insert("x-forwarded-proto", HeaderValue::from_static("http"));

        let base = derive_session_base_url(&headers, Some("https://station-staging.agora.build/"));
        assert_eq!(base, "https://station-staging.agora.build");
    }

    #[test]
    fn test_derive_session_base_url_uses_forwarded_headers() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "forwarded",
            HeaderValue::from_static("for=1.1.1.1;proto=https;host=station-staging.agora.build"),
        );
        headers.insert("host", HeaderValue::from_static("internal:3000"));

        let base = derive_session_base_url(&headers, None);
        assert_eq!(base, "https://station-staging.agora.build");
    }

    #[test]
    fn test_derive_session_base_url_infers_http_for_localhost() {
        let mut headers = HeaderMap::new();
        headers.insert("host", HeaderValue::from_static("127.0.0.1:3000"));

        let base = derive_session_base_url(&headers, None);
        assert_eq!(base, "http://127.0.0.1:3000");
    }

    // --- Handler Tests ---

    #[tokio::test]
    async fn test_create_session_handler() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions")
                    .header("Content-Type", "application/json")
                    .header("Host", "station.agora.build")
                    .body(Body::from(
                        r#"{"app_id":"app1","channel":"room","token":"tok","host_uid":5678}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let resp: CreateRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        assert!(!resp.id.is_empty());
        assert!(resp.url.contains("/session/"));
        assert!(resp.url.contains(&resp.id));
    }

    #[tokio::test]
    async fn test_create_session_missing_fields() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"app_id":"app1"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[tokio::test]
    async fn test_get_session_handler() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        state
            .rtc_sessions
            .create("get-test".into(), "app1".into(), "room1".into(), "tok".into(), 99)
            .await
            .unwrap();

        let app = Router::new()
            .route("/api/rtc-sessions/:id", get(get_rtc_session_handler))
            .with_state(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/rtc-sessions/get-test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let resp: GetRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(resp.app_id, "app1");
        assert_eq!(resp.channel, "room1");
        assert_eq!(resp.host_uid, 99);
    }

    #[tokio::test]
    async fn test_get_session_not_found() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/rtc-sessions/nonexistent")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_join_session_handler() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        state
            .rtc_sessions
            .create("join-h".into(), "app1".into(), "room1".into(), "tok1".into(), 42)
            .await
            .unwrap();

        let app = Router::new()
            .route(
                "/api/rtc-sessions/:id/join",
                post(join_rtc_session_handler),
            )
            .with_state(state);

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions/join-h/join")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"Alice"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let resp: JoinRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(resp.app_id, "app1");
        assert_eq!(resp.channel, "room1");
        assert_eq!(resp.token, "tok1");
        assert_eq!(resp.uid, 1000);
        assert_eq!(resp.name, "Alice");
    }

    #[tokio::test]
    async fn test_join_session_not_found() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions/nope/join")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"Alice"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_delete_session_handler() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        state
            .rtc_sessions
            .create("del-h".into(), "a".into(), "c".into(), "t".into(), 1)
            .await
            .unwrap();

        let app = Router::new()
            .route(
                "/api/rtc-sessions/:id",
                delete(delete_rtc_session_handler),
            )
            .with_state(state);

        let response = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/rtc-sessions/del-h")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_delete_session_not_found() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/rtc-sessions/nope")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_full_lifecycle() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        let app = Router::new()
            .route("/api/rtc-sessions", post(create_rtc_session_handler))
            .route("/api/rtc-sessions/:id", get(get_rtc_session_handler))
            .route(
                "/api/rtc-sessions/:id/join",
                post(join_rtc_session_handler),
            )
            .route(
                "/api/rtc-sessions/:id",
                delete(delete_rtc_session_handler),
            )
            .with_state(state);

        // Step 1: Create
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(
                        r#"{"app_id":"app1","channel":"room","token":"tok","host_uid":5678}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;

        // Step 2: Get
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/rtc-sessions/{}", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // Step 3: Join (uid 1000)
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/rtc-sessions/{}/join", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"Alice"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let join1: JoinRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(join1.uid, 1000);

        // Step 4: Join again (uid 1001)
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/rtc-sessions/{}/join", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"Bob"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let join2: JoinRtcSessionResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(join2.uid, 1001);

        // Step 5: Delete
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/rtc-sessions/{}", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // Step 6: Get after delete → 404
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/rtc-sessions/{}", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_join_session_full_handler() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: std::sync::Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        state
            .rtc_sessions
            .create("full-h".into(), "app1".into(), "room1".into(), "tok1".into(), 42)
            .await
            .unwrap();

        // Fill session to capacity (8 participants)
        for i in 0..8 {
            state.rtc_sessions.join("full-h", format!("User{}", i)).await.unwrap();
        }

        let app = Router::new()
            .route(
                "/api/rtc-sessions/:id/join",
                post(join_rtc_session_handler),
            )
            .with_state(state);

        // 9th person should get 409 Conflict
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions/full-h/join")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"User9"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let error: RtcSessionError = serde_json::from_slice(&body).unwrap();
        assert!(error.error.contains("full"));
    }

    #[tokio::test]
    async fn test_concurrent_cleanup_and_join() {
        let store = RtcSessionStore::new();
        store
            .create("race-test".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        // Spawn concurrent operations: cleanup and join
        let store1 = store.clone();
        let cleanup_task = tokio::spawn(async move {
            store1.cleanup_expired().await.unwrap();
        });

        let store2 = store.clone();
        let join_task = tokio::spawn(async move {
            store2.join("race-test", "RaceUser".into()).await
        });

        let _ = tokio::join!(cleanup_task, join_task);

        // Session should still exist and have at least one participant
        let session = store.get("race-test").await.unwrap();
        assert!(session.is_some(), "Session should not be cleaned up while active");
    }

    #[tokio::test]
    async fn test_session_url_format() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rtc-sessions")
                    .header("Content-Type", "application/json")
                    .header("Host", "station.agora.build")
                    .body(Body::from(
                        r#"{"app_id":"app1","channel":"room","token":"tok","host_uid":5678}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let resp: CreateRtcSessionResponse = serde_json::from_slice(&body).unwrap();

        assert!(resp.url.contains("/session/"));
        assert!(resp.url.contains(&resp.id));
        assert!(uuid::Uuid::parse_str(&resp.id).is_ok(), "Session ID should be valid UUID");
    }

    #[tokio::test]
    async fn test_participant_names_persistence() {
        let store = RtcSessionStore::new();
        store
            .create("name-test".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await.unwrap();

        // Join multiple users
        store.join("name-test", "Alice".into()).await.unwrap();
        store.join("name-test", "Bob".into()).await.unwrap();
        store.join("name-test", "Charlie".into()).await.unwrap();

        let session = store.get("name-test").await.unwrap().unwrap();
        assert_eq!(session.participants.len(), 3);

        let names: Vec<String> = session.participants.iter()
            .filter_map(|p| p.display_name.clone())
            .collect();
        assert_eq!(names, vec!["Alice", "Bob", "Charlie"]);
    }

    #[tokio::test]
    async fn test_delete_session_with_participants() {
        let store = RtcSessionStore::new();
        store
            .create("del-part".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await.unwrap();

        // Add participants
        store.join("del-part", "User1".into()).await.unwrap();
        store.join("del-part", "User2".into()).await.unwrap();

        // Delete should succeed even with participants
        assert!(store.delete("del-part").await.unwrap());
        assert!(store.get("del-part").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn test_cleanup_does_not_remove_active_sessions_with_participants() {
        let store = RtcSessionStore::new();

        // Create session (not expired)
        store
            .create("active-with-parts".into(), "a".into(), "c".into(), "t".into(), 1)
            .await.unwrap();

        // Add participants
        store.join("active-with-parts", "User1".into()).await.unwrap();
        store.join("active-with-parts", "User2".into()).await.unwrap();

        store.cleanup_expired().await.unwrap();

        // Should still exist
        let session = store.get("active-with-parts").await.unwrap();
        assert!(session.is_some());
        assert_eq!(session.unwrap().participants.len(), 2);
    }
}
