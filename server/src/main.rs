mod auth;
mod routes;
mod session_store;
mod web;

use axum::routing::{get, post};
use axum::Router;
use session_store::SessionStore;
use tower_http::cors::{Any, CorsLayer};

#[tokio::main]
async fn main() {
    // Initialize tracing/logging
    tracing_subscriber::fmt()
        .with_target(false)
        .with_level(true)
        .init();

    tracing::info!("Starting Astation server...");

    // Initialize the session store
    let store = SessionStore::new();

    // Spawn a background task to periodically clean up expired sessions
    let cleanup_store = store.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            cleanup_store.cleanup_expired().await;
            tracing::debug!("Cleaned up expired sessions");
        }
    });

    // Configure CORS
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Build the router
    let app = Router::new()
        // API routes
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
        // Web page route
        .route("/auth", get(routes::auth_page_handler))
        .layer(cors)
        .with_state(store);

    // Start the server
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000")
        .await
        .expect("Failed to bind to port 3000");

    tracing::info!("Astation server listening on http://0.0.0.0:3000");

    axum::serve(listener, app)
        .await
        .expect("Server error");
}
