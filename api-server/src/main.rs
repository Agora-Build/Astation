mod auth;
mod relay;
mod routes;
mod rtc_session;
mod session_store;
mod web;

use axum::routing::{get, post};
use axum::Router;
use relay::RelayHub;
use rtc_session::RtcSessionStore;
use session_store::SessionStore;
use tower_http::cors::{Any, CorsLayer};

/// Shared state accessible by all route handlers.
#[derive(Clone)]
pub struct AppState {
    pub sessions: SessionStore,
    pub relay: RelayHub,
    pub rtc_sessions: RtcSessionStore,
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

    // Spawn background cleanup for expired sessions
    let cleanup_sessions = sessions.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_sessions.cleanup_expired().await;
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

    let state = AppState {
        sessions,
        relay,
        rtc_sessions,
    };

    // Configure CORS
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Build the router
    let app = Router::new()
        // Auth API routes
        .route("/api/sessions", post(routes::create_session_handler))
        .route(
            "/api/sessions/:id/status",
            get(routes::get_session_status_handler),
        )
        .route(
            "/api/sessions/:id/grant",
            post(routes::grant_session_handler),
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
        // Relay API routes
        .route("/api/pair", post(relay::create_pair_handler))
        .route("/api/pair/:code", get(relay::pair_status_handler))
        .route("/ws", get(relay::ws_handler))
        .route("/pair", get(relay::pair_page_handler))
        // Web page routes
        .route("/auth", get(routes::auth_page_handler))
        .layer(cors)
        .with_state(state);

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

    axum::serve(listener, app)
        .await
        .expect("Server error");
}
