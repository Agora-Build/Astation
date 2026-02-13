use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{Html, IntoResponse, Json},
};
use serde::{Deserialize, Serialize};
use validator::Validate;

use crate::auth::{self, SessionStatus};
use crate::web::auth_page;
use crate::AppState;

// --- Request / Response types ---

#[derive(Deserialize, Validate)]
pub struct CreateSessionRequest {
    #[validate(length(min = 1, max = 255))]
    pub hostname: String,
}

#[derive(Serialize, Deserialize)]
pub struct CreateSessionResponse {
    pub id: String,
    pub otp: String,
    pub hostname: String,
    pub status: SessionStatus,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize, Deserialize)]
pub struct SessionStatusResponse {
    pub id: String,
    pub status: SessionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Deserialize)]
pub struct GrantRequest {
    pub otp: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

#[derive(Deserialize)]
pub struct AuthPageQuery {
    pub id: String,
    pub tag: String,
}

// --- Route Handlers ---

/// POST /api/sessions
/// Creates a new auth session for the given hostname.
pub async fn create_session_handler(
    State(state): State<AppState>,
    Json(body): Json<CreateSessionRequest>,
) -> impl IntoResponse {
    // Validate input
    if let Err(e) = body.validate() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: format!("Validation error: {}", e),
            }),
        )
            .into_response();
    }

    let session = auth::create_session(&body.hostname);
    let response = CreateSessionResponse {
        id: session.id.clone(),
        otp: session.otp.clone(),
        hostname: session.hostname.clone(),
        status: session.status.clone(),
        created_at: session.created_at,
        expires_at: session.expires_at,
    };
    state.sessions.create(session).await;
    (StatusCode::CREATED, Json(response)).into_response()
}

/// GET /api/sessions/:id/status
/// Returns the current status of a session. Includes token if granted.
pub async fn get_session_status_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.sessions.get(&id).await {
        Some(session) => {
            // Check if session has expired
            let status = if session.status == SessionStatus::Pending
                && chrono::Utc::now() > session.expires_at
            {
                SessionStatus::Expired
            } else {
                session.status.clone()
            };

            let token = if status == SessionStatus::Granted {
                session.token.clone()
            } else {
                None
            };

            Ok(Json(SessionStatusResponse {
                id: session.id,
                status,
                token,
            }))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: "Session not found".to_string(),
            }),
        )),
    }
}

/// POST /api/sessions/:id/grant
/// Validates the OTP, sets status to Granted, and generates a session token.
pub async fn grant_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<GrantRequest>,
) -> impl IntoResponse {
    match state.sessions.get(&id).await {
        Some(mut session) => {
            // Check if already processed
            if session.status != SessionStatus::Pending {
                return Err((
                    StatusCode::CONFLICT,
                    Json(ErrorResponse {
                        error: format!(
                            "Session is already {}",
                            serde_json::to_string(&session.status)
                                .unwrap_or_default()
                                .trim_matches('"')
                        ),
                    }),
                ));
            }

            // Validate OTP
            if !auth::validate_otp(&session, &body.otp) {
                // Check if expired
                if chrono::Utc::now() > session.expires_at {
                    return Err((
                        StatusCode::GONE,
                        Json(ErrorResponse {
                            error: "Session has expired".to_string(),
                        }),
                    ));
                }
                return Err((
                    StatusCode::UNAUTHORIZED,
                    Json(ErrorResponse {
                        error: "Invalid OTP".to_string(),
                    }),
                ));
            }

            session.status = SessionStatus::Granted;
            session.token = Some(auth::generate_session_token());
            let response = SessionStatusResponse {
                id: session.id.clone(),
                status: session.status.clone(),
                token: session.token.clone(),
            };
            state.sessions.update(&id, session).await;

            Ok(Json(response))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: "Session not found".to_string(),
            }),
        )),
    }
}

/// POST /api/sessions/:id/deny
/// Sets the session status to Denied.
pub async fn deny_session_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    match state.sessions.get(&id).await {
        Some(mut session) => {
            if session.status != SessionStatus::Pending {
                return Err((
                    StatusCode::CONFLICT,
                    Json(ErrorResponse {
                        error: format!(
                            "Session is already {}",
                            serde_json::to_string(&session.status)
                                .unwrap_or_default()
                                .trim_matches('"')
                        ),
                    }),
                ));
            }

            session.status = SessionStatus::Denied;
            let response = SessionStatusResponse {
                id: session.id.clone(),
                status: session.status.clone(),
                token: None,
            };
            state.sessions.update(&id, session).await;

            Ok(Json(response))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: "Session not found".to_string(),
            }),
        )),
    }
}

/// GET /auth?id=...&tag=...
/// Returns the HTML fallback auth page.
pub async fn auth_page_handler(
    State(state): State<AppState>,
    Query(params): Query<AuthPageQuery>,
) -> impl IntoResponse {
    match state.sessions.get(&params.id).await {
        Some(session) => Ok(Html(auth_page::render_auth_page(
            &session.id,
            &params.tag,
            &session.otp,
        ))),
        None => Err((
            StatusCode::NOT_FOUND,
            Html(
                "<h1>Session not found</h1><p>The requested session does not exist or has been removed.</p>"
                    .to_string(),
            ),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::create_session;
    use crate::relay::RelayHub;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_store::SessionStore;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
        routing::{get, post},
        Router,
    };
    use tower::ServiceExt;

    fn create_app() -> Router {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/status", get(get_session_status_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .route("/api/sessions/:id/deny", post(deny_session_handler))
            .route("/auth", get(auth_page_handler))
            .with_state(state)
    }

    #[tokio::test]
    async fn test_create_session_endpoint() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let resp: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(resp.hostname, "test-machine");
        assert_eq!(resp.status, SessionStatus::Pending);
        assert_eq!(resp.otp.len(), 8);
    }

    #[tokio::test]
    async fn test_session_status_not_found() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/sessions/nonexistent/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_full_grant_lifecycle() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/status", get(get_session_status_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .with_state(state);

        // Step 1: Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;
        let otp = created.otp;

        // Step 2: Check status (should be pending)
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/sessions/{}/status", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(status_resp.status, SessionStatus::Pending);
        assert!(status_resp.token.is_none());

        // Step 3: Grant with correct OTP
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/grant", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"otp": "{}"}}"#, otp)))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let grant_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(grant_resp.status, SessionStatus::Granted);
        assert!(grant_resp.token.is_some());
        assert_eq!(grant_resp.token.unwrap().len(), 64);

        // Step 4: Check status (should be granted with token)
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/sessions/{}/status", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(status_resp.status, SessionStatus::Granted);
        assert!(status_resp.token.is_some());
    }

    #[tokio::test]
    async fn test_full_deny_lifecycle() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/status", get(get_session_status_handler))
            .route("/api/sessions/:id/deny", post(deny_session_handler))
            .with_state(state);

        // Step 1: Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;

        // Step 2: Deny
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/deny", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        // Step 3: Check status (should be denied)
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/sessions/{}/status", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(status_resp.status, SessionStatus::Denied);
        assert!(status_resp.token.is_none());
    }

    #[tokio::test]
    async fn test_grant_with_wrong_otp() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .with_state(state);

        // Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;

        // Grant with wrong OTP
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/grant", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"otp": "00000000"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_grant_nonexistent_session() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions/nonexistent/grant")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"otp": "12345678"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_deny_nonexistent_session() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions/nonexistent/deny")
                    .header("Content-Type", "application/json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_auth_page_handler() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let session = create_session("my-machine");
        let session_id = session.id.clone();
        state.sessions.create(session).await;

        let app = Router::new()
            .route("/auth", get(auth_page_handler))
            .with_state(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/auth?id={}&tag=my-machine", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(html.contains("Astation Auth"));
        assert!(html.contains("my-machine"));
    }

    #[tokio::test]
    async fn test_auth_page_session_not_found() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/auth?id=nonexistent&tag=test")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_double_grant_returns_conflict() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .with_state(state);

        // Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;
        let otp = created.otp;

        // First grant
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/grant", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"otp": "{}"}}"#, otp)))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // Second grant should return conflict
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/grant", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"otp": "{}"}}"#, otp)))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
    }

    #[tokio::test]
    async fn test_double_deny_returns_conflict() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/deny", post(deny_session_handler))
            .with_state(state);

        // Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;

        // First deny
        app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/deny", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Second deny should return conflict
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/deny", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CONFLICT);
    }

    #[tokio::test]
    async fn test_grant_after_deny_returns_conflict() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .route("/api/sessions/:id/deny", post(deny_session_handler))
            .with_state(state);

        // Create session
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "test-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
        let session_id = created.id;
        let otp = created.otp;

        // Deny first
        app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/deny", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Try to grant after deny should return conflict
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{}/grant", session_id))
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"otp": "{}"}}"#, otp)))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CONFLICT);
    }

    #[tokio::test]
    async fn test_create_session_invalid_json() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"invalid": json}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Should reject invalid JSON
        assert!(
            response.status() == StatusCode::BAD_REQUEST ||
            response.status() == StatusCode::UNPROCESSABLE_ENTITY
        );
    }

    #[tokio::test]
    async fn test_create_session_missing_hostname() {
        let app = create_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[tokio::test]
    async fn test_session_token_uniqueness() {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };
        let app = Router::new()
            .route("/api/sessions", post(create_session_handler))
            .route("/api/sessions/:id/grant", post(grant_session_handler))
            .with_state(state);

        let mut tokens = std::collections::HashSet::new();

        for i in 0..10 {
            // Create session
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/sessions")
                        .header("Content-Type", "application/json")
                        .body(Body::from(format!(r#"{{"hostname": "host-{}"}}"#, i)))
                        .unwrap(),
                )
                .await
                .unwrap();

            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let created: CreateSessionResponse = serde_json::from_slice(&body).unwrap();

            // Grant session
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(format!("/api/sessions/{}/grant", created.id))
                        .header("Content-Type", "application/json")
                        .body(Body::from(format!(r#"{{"otp": "{}"}}"#, created.otp)))
                        .unwrap(),
                )
                .await
                .unwrap();

            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let grant_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();

            if let Some(token) = grant_resp.token {
                tokens.insert(token);
            }
        }

        assert_eq!(tokens.len(), 10, "All session tokens should be unique");
    }

    #[tokio::test]
    async fn test_status_returns_expired_for_old_pending_session() {
        use chrono::{Duration, Utc};

        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
        };

        // Create an expired session manually
        let now = Utc::now();
        let expired_session = crate::auth::Session {
            id: uuid::Uuid::new_v4().to_string(),
            otp: "12345678".to_string(),
            hostname: "expired-host".to_string(),
            status: crate::auth::SessionStatus::Pending,
            token: None,
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5),
        };
        let session_id = expired_session.id.clone();
        state.sessions.create(expired_session).await;

        let app = Router::new()
            .route("/api/sessions/:id/status", get(get_session_status_handler))
            .with_state(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/sessions/{}/status", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: SessionStatusResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(status_resp.status, crate::auth::SessionStatus::Expired);
    }

    #[tokio::test]
    async fn test_hostname_with_special_characters() {
        let app = create_app();

        let test_hostnames = vec![
            "host-with-dashes",
            "host_with_underscores",
            "host.with.dots",
            "192.168.1.1",
            "host123",
            "UPPERCASE-HOST",
        ];

        for hostname in test_hostnames {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/sessions")
                        .header("Content-Type", "application/json")
                        .body(Body::from(format!(r#"{{"hostname": "{}"}}"#, hostname)))
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(
                response.status(),
                StatusCode::CREATED,
                "Should accept hostname: {}",
                hostname
            );

            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let resp: CreateSessionResponse = serde_json::from_slice(&body).unwrap();
            assert_eq!(resp.hostname, hostname);
        }
    }
}
