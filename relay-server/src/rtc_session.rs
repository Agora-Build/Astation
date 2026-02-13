use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::AppState;

// --- Data Models ---

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Participant {
    pub uid: u32,
    pub display_name: Option<String>,
    pub joined_at: DateTime<Utc>,
}

/// Internal session data (uid_counter is atomic and not directly clonable).
pub struct RtcSessionInner {
    pub id: String,
    pub app_id: String,
    pub channel: String,
    pub token: String,
    pub uid_counter: AtomicU32,
    pub host_uid: u32,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub participants: Vec<Participant>,
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

impl RtcSessionInner {
    fn snapshot(&self) -> RtcSession {
        RtcSession {
            id: self.id.clone(),
            app_id: self.app_id.clone(),
            channel: self.channel.clone(),
            token: self.token.clone(),
            uid_counter_value: self.uid_counter.load(Ordering::SeqCst),
            host_uid: self.host_uid,
            created_at: self.created_at,
            expires_at: self.expires_at,
            participants: self.participants.clone(),
        }
    }
}

// --- Request / Response types ---

#[derive(Deserialize)]
pub struct CreateRtcSessionRequest {
    pub app_id: String,
    pub channel: String,
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

#[derive(Deserialize)]
pub struct JoinRtcSessionRequest {
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

#[derive(Serialize)]
pub struct RtcSessionError {
    pub error: String,
}

// --- Store ---

#[derive(Clone)]
pub struct RtcSessionStore {
    sessions: Arc<RwLock<HashMap<String, Arc<RwLock<RtcSessionInner>>>>>,
}

impl RtcSessionStore {
    pub fn new() -> Self {
        RtcSessionStore {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn create(&self, id: String, app_id: String, channel: String, token: String, host_uid: u32) -> RtcSession {
        let now = Utc::now();
        let inner = RtcSessionInner {
            id: id.clone(),
            app_id,
            channel,
            token,
            uid_counter: AtomicU32::new(1000),
            host_uid,
            created_at: now,
            expires_at: now + Duration::hours(4),
            participants: Vec::new(),
        };
        let snapshot = inner.snapshot();
        let arc_inner = Arc::new(RwLock::new(inner));
        let mut sessions = self.sessions.write().await;
        sessions.insert(id, arc_inner);
        snapshot
    }

    pub async fn get(&self, id: &str) -> Option<RtcSession> {
        let sessions = self.sessions.read().await;
        if let Some(inner) = sessions.get(id) {
            let inner = inner.read().await;
            Some(inner.snapshot())
        } else {
            None
        }
    }

    pub async fn join(&self, id: &str, name: String) -> Result<JoinRtcSessionResponse, String> {
        let sessions = self.sessions.read().await;
        if let Some(inner_arc) = sessions.get(id) {
            let mut inner = inner_arc.write().await;

            let current_count = inner.participants.len();
            tracing::info!("Join request for session {}: current participants = {}, name = {}", id, current_count, name);

            // Enforce 8-person limit (including host)
            if current_count >= 8 {
                tracing::warn!("Session {} is full ({} participants)", id, current_count);
                return Err("Session is full (maximum 8 participants)".to_string());
            }

            let uid = inner.uid_counter.fetch_add(1, Ordering::SeqCst);
            inner.participants.push(Participant {
                uid,
                display_name: Some(name.clone()),
                joined_at: Utc::now(),
            });

            tracing::info!("User {} joined session {} with UID {} (total participants: {})",
                name, id, uid, inner.participants.len());

            Ok(JoinRtcSessionResponse {
                app_id: inner.app_id.clone(),
                channel: inner.channel.clone(),
                token: inner.token.clone(),
                uid,
                name,
            })
        } else {
            Err("Session not found".to_string())
        }
    }

    pub async fn delete(&self, id: &str) -> bool {
        let mut sessions = self.sessions.write().await;
        sessions.remove(id).is_some()
    }

    pub async fn cleanup_expired(&self) {
        let now = Utc::now();
        let mut sessions = self.sessions.write().await;
        let mut expired_ids = Vec::new();
        for (id, inner_arc) in sessions.iter() {
            let inner = inner_arc.read().await;
            if now > inner.expires_at {
                expired_ids.push(id.clone());
            }
        }
        for id in expired_ids {
            sessions.remove(&id);
        }
    }
}

impl Default for RtcSessionStore {
    fn default() -> Self {
        Self::new()
    }
}

// --- Route Handlers ---

const SESSION_BASE_URL: &str = "https://station.agora.build/session";

/// POST /api/rtc-sessions
pub async fn create_rtc_session_handler(
    State(state): State<AppState>,
    Json(body): Json<CreateRtcSessionRequest>,
) -> impl IntoResponse {
    let id = Uuid::new_v4().to_string();
    let url = format!("{}/{}", SESSION_BASE_URL, id);

    state
        .rtc_sessions
        .create(id.clone(), body.app_id, body.channel, body.token, body.host_uid)
        .await;

    (
        StatusCode::CREATED,
        Json(CreateRtcSessionResponse { id, url }),
    )
}

/// GET /api/rtc-sessions/:id
pub async fn get_rtc_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.rtc_sessions.get(&id).await {
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
    match state.rtc_sessions.join(&id, body.name).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            let status = if error.contains("not found") {
                StatusCode::NOT_FOUND
            } else if error.contains("full") {
                StatusCode::CONFLICT
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            Err((status, Json(RtcSessionError { error })))
        }
    }
}

/// DELETE /api/rtc-sessions/:id
pub async fn delete_rtc_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if state.rtc_sessions.delete(&id).await {
        StatusCode::OK
    } else {
        StatusCode::NOT_FOUND
    }
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
        routing::{delete, get, post},
        Router,
    };
    use crate::relay::RelayHub;
    use crate::session_store::SessionStore;
    use tower::ServiceExt;

    fn create_test_app() -> Router {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
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
            .await;

        assert_eq!(session.id, "test-id");
        assert_eq!(session.app_id, "app123");
        assert_eq!(session.channel, "my-channel");
        assert_eq!(session.host_uid, 5678);

        let retrieved = store.get("test-id").await;
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
        assert!(store.get("does-not-exist").await.is_none());
    }

    #[tokio::test]
    async fn test_delete_session() {
        let store = RtcSessionStore::new();
        store
            .create("del-me".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await;
        assert!(store.get("del-me").await.is_some());
        assert!(store.delete("del-me").await);
        assert!(store.get("del-me").await.is_none());
    }

    #[tokio::test]
    async fn test_join_assigns_unique_uids() {
        let store = RtcSessionStore::new();
        store
            .create("join-test".into(), "app".into(), "ch".into(), "tok".into(), 1)
            .await;

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
            .await;

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
            .await;

        store.join("part-test", "Alice".into()).await;

        let session = store.get("part-test").await.unwrap();
        assert_eq!(session.participants.len(), 1);
        assert_eq!(
            session.participants[0].display_name,
            Some("Alice".to_string())
        );
        assert_eq!(session.participants[0].uid, 1000);
    }

    #[tokio::test]
    async fn test_cleanup_expired() {
        let store = RtcSessionStore::new();

        // Create an expired session by manipulating internally
        {
            let inner = RtcSessionInner {
                id: "expired".into(),
                app_id: "a".into(),
                channel: "c".into(),
                token: "t".into(),
                uid_counter: AtomicU32::new(1000),
                host_uid: 1,
                created_at: Utc::now() - Duration::hours(5),
                expires_at: Utc::now() - Duration::hours(1),
                participants: Vec::new(),
            };
            let mut sessions = store.sessions.write().await;
            sessions.insert("expired".into(), Arc::new(RwLock::new(inner)));
        }

        // Create an active session
        store
            .create("active".into(), "a".into(), "c".into(), "t".into(), 1)
            .await;

        store.cleanup_expired().await;

        assert!(store.get("expired").await.is_none());
        assert!(store.get("active").await.is_some());
    }

    #[tokio::test]
    async fn test_cleanup_preserves_active() {
        let store = RtcSessionStore::new();
        store
            .create("keep-me".into(), "a".into(), "c".into(), "t".into(), 1)
            .await;

        store.cleanup_expired().await;

        assert!(store.get("keep-me").await.is_some());
    }

    #[tokio::test]
    async fn test_uid_counter_starts_at_1000() {
        let store = RtcSessionStore::new();
        store
            .create("uid-test".into(), "a".into(), "c".into(), "t".into(), 1)
            .await;

        let resp = store.join("uid-test", "First".into()).await.unwrap();
        assert_eq!(resp.uid, 1000);
    }

    #[tokio::test]
    async fn test_concurrent_joins() {
        let store = RtcSessionStore::new();
        store
            .create("concurrent".into(), "a".into(), "c".into(), "t".into(), 1)
            .await;

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
            .await;

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
        assert!(resp.url.starts_with("https://station.agora.build/session/"));
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
        };
        state
            .rtc_sessions
            .create("get-test".into(), "app1".into(), "room1".into(), "tok".into(), 99)
            .await;

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
        };
        state
            .rtc_sessions
            .create("join-h".into(), "app1".into(), "room1".into(), "tok1".into(), 42)
            .await;

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
        };
        state
            .rtc_sessions
            .create("del-h".into(), "a".into(), "c".into(), "t".into(), 1)
            .await;

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
}
