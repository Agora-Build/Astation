mod auth;
mod cluster;
mod identity_store;
mod knowledge_routes;
mod knowledge_secrets;
mod knowledge_store;
mod relay;
mod routes;
mod rtc_session;
mod session_store;
mod voice_session;
mod voice_routes;
mod llm_proxy;
mod vault_store;
mod vault_routes;
mod web;

use axum::extract::{DefaultBodyLimit, State};
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use relay::RelayHub;
use rtc_session::RtcSessionStore;
use session_store::SessionStore;
use voice_session::VoiceSessionStore;
use std::net::SocketAddr;
use std::sync::Arc;
use tower_governor::{
    governor::GovernorConfigBuilder,
    key_extractor::SmartIpKeyExtractor,
    GovernorLayer,
};
use tower_http::cors::CorsLayer;


/// Shared state accessible by all route handlers.
#[derive(Clone)]
pub struct AppState {
    pub sessions: SessionStore,
    pub relay: RelayHub,
    pub rtc_sessions: RtcSessionStore,
    pub voice_sessions: VoiceSessionStore,
    pub vault: Arc<dyn vault_store::VaultStore>,
    pub knowledge: Arc<dyn knowledge_store::KnowledgeStore>,
    /// Astation keys + durable session bindings (Postgres when DATABASE_URL is set).
    pub identity: Arc<dyn identity_store::IdentityStore>,
}

async fn health_handler(State(state): State<AppState>) -> impl IntoResponse {
    match state.vault.health_check().await {
        Ok(()) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "status": "ok",
                "vault_store": state.vault.backend_name(),
                "knowledge_store": state.knowledge.backend_name(),
            })),
        ),
        Err(error) => {
            tracing::error!("Health check failed: {}", error);
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "status": "unhealthy" })),
            )
        }
    }
}

/// CORS: `CORS_ORIGIN` (default the production webapp origin); `*` is dev-only.
fn cors_layer() -> CorsLayer {
    // Configure CORS - Allow specific origin or default to localhost for development
    let allowed_origin = std::env::var("CORS_ORIGIN")
        .unwrap_or_else(|_| "https://station.agora.build".to_string());

    if allowed_origin == "*" {
        // Development mode: allow all origins
        tracing::warn!("CORS configured to allow ALL origins - only use in development!");
        CorsLayer::permissive()
    } else {
        // Production mode: whitelist specific domain
        tracing::info!("CORS configured to allow origin: {}", allowed_origin);
        CorsLayer::new()
            .allow_origin(allowed_origin.parse::<HeaderValue>().expect("Invalid CORS_ORIGIN"))
            .allow_methods([Method::GET, Method::POST, Method::DELETE, Method::OPTIONS])
            .allow_headers([header::CONTENT_TYPE, header::AUTHORIZATION])
            .allow_credentials(true)
    }
}

/// The production router: every route, its body limits, rate limiting and
/// CORS. Shared by `main` and the tests so they exercise the real stack.
fn router(state: AppState) -> Router {
    // Configure rate limiting
    // OTP/grant endpoints: 60 requests per minute per IP (strict)
    // General endpoints: 600 requests per minute per IP
    let governor_conf_strict = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(1) // 60 per minute
            .burst_size(10)
            .key_extractor(SmartIpKeyExtractor)
            .use_headers()
            .finish()
            .unwrap(),
    );

    let governor_conf_general = Arc::new(
        GovernorConfigBuilder::default()
            .per_millisecond(100) // 10 per second / 600 per minute
            .burst_size(20)
            .key_extractor(SmartIpKeyExtractor)
            .use_headers()
            .finish()
            .unwrap(),
    );

    // Build the router with rate limiting on sensitive endpoints
    // Strict rate limiting for OTP validation (brute force protection)
    let auth_routes = Router::new()
        .route(
            "/api/sessions/:id/grant",
            post(routes::grant_session_handler),
        )
        .layer(GovernorLayer {
            config: governor_conf_strict,
        });

    // General rate limiting for other API endpoints
    let general_routes = Router::new()
        // Auth API routes
        .route("/api/sessions", post(routes::create_session_handler))
        .route(
            "/api/sessions/:id/status",
            get(routes::get_session_status_handler),
        )
        .route(
            "/api/sessions/:id/deny",
            post(routes::deny_session_handler),
        )
        // RTC Session API routes
        .route(
            "/api/rtc-sessions",
            post(rtc_session::create_rtc_session_handler),
        )
        .route(
            "/api/rtc-sessions/:id",
            get(rtc_session::get_rtc_session_handler)
                .delete(rtc_session::delete_rtc_session_handler),
        )
        .route(
            "/api/rtc-sessions/:id/join",
            post(rtc_session::join_rtc_session_handler),
        )
        // Voice Session API routes
        .route(
            "/api/voice-sessions",
            post(voice_routes::create_voice_session_handler)
                .get(voice_routes::list_voice_sessions_handler),
        )
        .route(
            "/api/voice-sessions/:id",
            get(voice_routes::get_voice_session_handler)
                .delete(voice_routes::delete_voice_session_handler),
        )
        .route(
            "/api/voice-sessions/:id/trigger",
            post(voice_routes::trigger_voice_session_handler),
        )
        .route(
            "/api/voice-sessions/response",
            post(voice_routes::atem_response_handler),
        )
        // LLM Proxy (for Agora ConvoAI)
        .route(
            "/api/llm/chat",
            post(llm_proxy::llm_chat_handler),
        )
        // Vault API routes
        .route(
            "/api/vault",
            post(vault_routes::create_vault_handler).get(vault_routes::list_vaults_handler),
        )
        .route(
            "/api/vault/:id",
            get(vault_routes::read_vault_handler).post(vault_routes::write_vault_handler),
        )
        .route(
            "/api/vault/:id/summary",
            post(vault_routes::set_summary_handler),
        )
        // Atem Memory API routes (knowledge sync)
        .route(
            "/api/memory/batch",
            post(knowledge_routes::memory_batch_handler)
                .layer(DefaultBodyLimit::max(knowledge_routes::MEMORY_BATCH_BODY_LIMIT)),
        )
        .route("/api/memory", get(knowledge_routes::memory_pull_handler))
        .route(
            "/api/skills/batch",
            post(knowledge_routes::skills_batch_handler)
                .layer(DefaultBodyLimit::max(knowledge_routes::SKILLS_BATCH_BODY_LIMIT)),
        )
        .route("/api/skills", get(knowledge_routes::skills_pull_handler))
        // Relay API routes
        .route("/api/pair", post(relay::create_pair_handler))
        .route("/api/pair/:code", get(relay::pair_status_handler).delete(relay::delete_pair_handler))
        .layer(GovernorLayer {
            config: governor_conf_general,
        });

    // Combine all routes
    Router::new()
        .merge(auth_routes)
        .merge(general_routes)
        .route("/health", get(health_handler))
        .route("/ws", get(relay::ws_handler))
        .route("/pair", get(relay::pair_page_handler))
        .route("/auth", get(routes::auth_page_handler))
        .layer(cors_layer())
        .with_state(state)
}

#[tokio::main]
async fn main() {
    // Initialize tracing/logging
    tracing_subscriber::fmt()
        .with_target(false)
        .with_level(true)
        .init();

    tracing::info!("Starting Astation server...");

    // Initialize stores
    let sessions = SessionStore::new();
    let relay = RelayHub::new();
    let rtc_sessions = RtcSessionStore::new();
    let voice_sessions = VoiceSessionStore::new();

    // Vault + knowledge (Atem Memory) + identity stores: Postgres, sharing one
    // pool, when DATABASE_URL is set (the durable path), else in-memory
    // fallbacks so the rest of the server still runs without a DB.
    let (vault, knowledge, identity): (
        Arc<dyn vault_store::VaultStore>,
        Arc<dyn knowledge_store::KnowledgeStore>,
        Arc<dyn identity_store::IdentityStore>,
    ) = match std::env::var("DATABASE_URL") {
        Ok(url) if !url.is_empty() => {
            tracing::info!("Connecting to Postgres for vault + knowledge storage...");
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(5)
                .connect(&url)
                .await
                .expect("Failed to connect to DATABASE_URL for vault storage");
            sqlx::migrate!("./migrations")
                .run(&pool)
                .await
                .expect("Failed to run vault migrations");
            tracing::info!("Vault + knowledge + identity storage ready (Postgres)");
            (
                Arc::new(vault_store::PgVaultStore::new(pool.clone())),
                Arc::new(knowledge_store::PgKnowledgeStore::new(pool.clone())),
                Arc::new(identity_store::PgIdentityStore::new(pool)),
            )
        }
        _ => {
            tracing::warn!(
                "DATABASE_URL not set — vault + knowledge + identity storage is IN-MEMORY \
                 (not durable). Set DATABASE_URL to enable persistent storage."
            );
            (
                Arc::new(vault_store::InMemoryVaultStore::new()),
                Arc::new(knowledge_store::InMemoryKnowledgeStore::new()),
                Arc::new(identity_store::InMemoryIdentityStore::new()),
            )
        }
    };

    // The relay decides Pending vs legacy Astation connections and verifies
    // registered keys from an in-memory cache, so it is loaded once here.
    let key_count = relay
        .load_keys(identity.as_ref())
        .await
        .expect("Failed to load Astation relay keys");
    tracing::info!("Loaded {} Astation relay key(s)", key_count);

    // Spawn background cleanup for expired sessions
    let cleanup_sessions = sessions.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = cleanup_sessions.cleanup_expired().await {
                tracing::debug!("Session sweep failed: {}", error);
            }
            tracing::debug!("Cleaned up expired sessions");
        }
    });

    // Spawn background cleanup for expired pair rooms
    let cleanup_relay = relay.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_relay.cleanup_expired().await;
            tracing::debug!("Cleaned up expired pair rooms");
        }
    });

    // Spawn background cleanup for expired RTC sessions
    let cleanup_rtc = rtc_sessions.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_rtc.cleanup_expired().await;
            tracing::debug!("Cleaned up expired RTC sessions");
        }
    });

    // Spawn background cleanup for expired voice sessions
    let cleanup_voice = voice_sessions.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = cleanup_voice.cleanup_expired().await {
                tracing::debug!("Voice session sweep failed: {}", error);
            }
            tracing::debug!("Cleaned up expired voice sessions");
        }
    });

    let state = AppState {
        sessions,
        relay,
        rtc_sessions,
        voice_sessions,
        vault,
        knowledge,
        identity,
    };

    let app = router(state);

    tracing::info!("Rate limiting configured:");
    tracing::info!("  - OTP validation: 60 requests/min per IP (burst: 10)");
    tracing::info!("  - General API: 600 requests/min per IP (burst: 20)");

    // Read port from PORT env var (default 3000)
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);

    let addr = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|_| panic!("Failed to bind to {}", addr));

    tracing::info!("Astation server listening on http://{}", addr);

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
        .await
        .expect("Server error");
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use tower::ServiceExt;

    fn test_state() -> AppState {
        AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: Arc::new(vault_store::InMemoryVaultStore::new()),
            knowledge: Arc::new(knowledge_store::InMemoryKnowledgeStore::new()),
            identity: Arc::new(identity_store::InMemoryIdentityStore::new()),
        }
    }

    #[tokio::test]
    async fn health_reports_ready_store() {
        let app = Router::new()
            .route("/health", get(health_handler))
            .with_state(test_state());
        let response = app
            .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(
            body.as_ref(),
            br#"{"knowledge_store":"memory","status":"ok","vault_store":"memory"}"#
        );
    }

    #[tokio::test]
    async fn rate_limit_uses_forwarded_client_ip() {
        let config = Arc::new(
            GovernorConfigBuilder::default()
                .per_second(60)
                .burst_size(2)
                .key_extractor(SmartIpKeyExtractor)
                .finish()
                .unwrap(),
        );
        let app = Router::new()
            .route("/limited", get(|| async { "ok" }))
            .layer(GovernorLayer { config });

        for expected in [StatusCode::OK, StatusCode::OK, StatusCode::TOO_MANY_REQUESTS] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri("/limited")
                        .header("x-forwarded-for", "203.0.113.10")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), expected);
        }

        let other_client = app
            .oneshot(
                Request::builder()
                    .uri("/limited")
                    .header("x-forwarded-for", "203.0.113.11")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(other_client.status(), StatusCode::OK);
    }
}
