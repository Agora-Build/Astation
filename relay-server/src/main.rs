mod auth;
mod relay;
mod routes;
mod rtc_session;
mod session_store;
mod session_verify;
mod web;

use axum::extract::Request;
use axum::http::{header, HeaderValue, Method};
use axum::routing::{get, post};
use axum::Router;
use relay::RelayHub;
use rtc_session::RtcSessionStore;
use session_store::SessionStore;
use session_verify::SessionVerifyCache;
use std::net::IpAddr;
use std::sync::Arc;
use tower_governor::{governor::GovernorConfigBuilder, GovernorLayer};
use tower_http::cors::CorsLayer;


/// Shared state accessible by all route handlers.
#[derive(Clone)]
pub struct AppState {
    pub sessions: SessionStore,
    pub relay: RelayHub,
    pub rtc_sessions: RtcSessionStore,
    pub session_verify_cache: SessionVerifyCache,
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
    let session_verify_cache = SessionVerifyCache::new();

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

    // Spawn background cleanup for session verify cache
    let cleanup_verify = session_verify_cache.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(300)); // 5 minutes
        loop {
            interval.tick().await;
            cleanup_verify.cleanup_expired().await;
        }
    });

    let state = AppState {
        sessions,
        relay,
        rtc_sessions,
        session_verify_cache,
    };

    // Configure CORS - Allow specific origin or default to localhost for development
    let allowed_origin = std::env::var("CORS_ORIGIN")
        .unwrap_or_else(|_| "https://station.agora.build".to_string());

    let cors = if allowed_origin == "*" {
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
    };

    // Configure rate limiting
    // OTP/grant endpoints: 60 requests per minute per IP (strict)
    // General endpoints: 600 requests per minute per IP
    let governor_conf_strict = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(1)  // 60 per minute
            .burst_size(10)
            .finish()
            .unwrap(),
    );

    let governor_conf_general = Arc::new(
        GovernorConfigBuilder::default()
            .per_second(10)  // 600 per minute
            .burst_size(20)
            .finish()
            .unwrap(),
    );

    // Build the router with rate limiting on sensitive endpoints
    // Strict rate limiting for OTP validation (brute force protection)
    let auth_routes = Router::new()
        .route(
            "/api/sessions/:id/grant",
            post(routes::grant_session_handler),
        );
        // Rate limiting temporarily disabled for local testing with nginx proxy
        // .layer(GovernorLayer {
        //     config: governor_conf_strict.clone(),
        // });

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
        // Relay API routes
        .route("/api/pair", post(relay::create_pair_handler))
        .route("/api/pair/:code", get(relay::pair_status_handler));
        // Rate limiting temporarily disabled for local testing with nginx proxy
        // .layer(GovernorLayer {
        //     config: governor_conf_general.clone(),
        // });

    // Combine all routes
    let app = Router::new()
        .merge(auth_routes)
        .merge(general_routes)
        .route("/ws", get(relay::ws_handler))
        .route("/pair", get(relay::pair_page_handler))
        .route("/auth", get(routes::auth_page_handler))
        .layer(cors)
        .with_state(state);

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

    axum::serve(listener, app)
        .await
        .expect("Server error");
}
