mod admin;
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

#[cfg(test)]
mod redis_multi_replica_tests;

use axum::extract::{DefaultBodyLimit, State};
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use cluster::ratelimit::{shared_rate_limit, SharedLimit, GENERAL_LIMIT_PER_MINUTE, GRANT_LIMIT_PER_MINUTE};
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

fn redis_url() -> Option<String> {
    std::env::var("REDIS_URL").ok().filter(|url| !url.trim().is_empty())
}

/// RELAY_REPLICAS_EXPECTED: unset or blank means 1; anything else must be
/// a positive integer.
fn parse_replicas_expected(value: Option<&str>) -> Result<usize, String> {
    match value.map(str::trim) {
        None | Some("") => Ok(1),
        Some(raw) => match raw.parse::<usize>() {
            Ok(count) if count > 0 => Ok(count),
            _ => Err(format!(
                "RELAY_REPLICAS_EXPECTED must be a positive integer (how many relay replicas run), got {raw:?}"
            )),
        },
    }
}

/// RELAY_REPLICAS_EXPECTED (default 1): how many replicas this deployment
/// runs. An invalid value stops the relay (exit 1).
fn replicas_expected() -> usize {
    let raw = match std::env::var("RELAY_REPLICAS_EXPECTED") {
        Ok(value) => Some(value),
        Err(std::env::VarError::NotPresent) => None,
        Err(std::env::VarError::NotUnicode(_)) => Some("<not UTF-8>".to_string()),
    };
    match parse_replicas_expected(raw.as_deref()) {
        Ok(count) => count,
        Err(message) => {
            tracing::error!("{}", message);
            std::process::exit(1);
        }
    }
}

/// Without Redis every replica would have its own rooms and sessions.
fn check_single_instance(expected_replicas: usize) -> Result<(), String> {
    if expected_replicas > 1 {
        return Err(format!(
            "RELAY_REPLICAS_EXPECTED={expected_replicas} but REDIS_URL is not set: \
             several relay replicas need Redis for shared state. Set REDIS_URL or run one replica."
        ));
    }
    Ok(())
}

const REDIS_CONNECT_ATTEMPTS: u32 = 10;
const REDIS_CONNECT_RETRY_SECS: u64 = 3;

/// Redis mode, one replica (shared by `main` and the two-relay test
/// harness): connect around the already loaded `keys`, retrying
/// unreachable/timeouts for about 30 s, then re-read the keys once the bus
/// is subscribed. A permanent failure (bad URL, wrong password) gives up at
/// once. `Err` carries the message to log before exiting (`main` exits 1 so
/// the orchestrator restarts the relay). Never logs the URL.
async fn start_redis_replica(
    url: &str,
    identity: Arc<dyn identity_store::IdentityStore>,
    keys: cluster::keys::KeyCache,
    auth_timeout: std::time::Duration,
) -> Result<cluster::redis::RedisCluster, String> {
    let cluster = connect_redis_cluster(url, identity.clone(), keys, auth_timeout).await?;
    // A key registered on another replica between the load and the bus
    // subscription was announced while we weren't listening: re-read once
    // now that key-changed messages reach us.
    match tokio::time::timeout(
        relay::KEY_RELOAD_TIMEOUT,
        cluster.relay.load_keys(identity.as_ref()),
    )
    .await
    {
        Ok(Ok(count)) => tracing::info!("Re-read {} Astation relay key(s) after subscribing", count),
        Ok(Err(error)) => tracing::warn!("Could not re-read relay keys after subscribing: {}", error),
        Err(_) => tracing::warn!(
            "Re-reading relay keys after subscribing timed out after {:?}",
            relay::KEY_RELOAD_TIMEOUT
        ),
    }
    tracing::info!(
        "Shared relay state ready (Redis); replica {}, {} live replica(s)",
        cluster.relay.replica_id(),
        cluster::health::ClusterHealth::replicas(&cluster.health)
    );
    Ok(cluster)
}

/// The bounded connect retries of `start_redis_replica`.
async fn connect_redis_cluster(
    url: &str,
    identity: Arc<dyn identity_store::IdentityStore>,
    keys: cluster::keys::KeyCache,
    auth_timeout: std::time::Duration,
) -> Result<cluster::redis::RedisCluster, String> {
    for attempt in 1..=REDIS_CONNECT_ATTEMPTS {
        match cluster::redis::connect_cluster_with_keys(url, identity.clone(), keys.clone(), auth_timeout).await {
            Ok(cluster) => return Ok(cluster),
            // A bad URL or wrong credentials won't fix themselves.
            Err(cluster::redis::ConnectError::Permanent(detail)) => {
                return Err(format!(
                    "Redis connect failed and retrying won't help (check REDIS_URL and its password): {}",
                    detail
                ));
            }
            Err(cluster::redis::ConnectError::Retryable(error)) => {
                tracing::error!(
                    "Redis connect attempt {}/{} failed: {}",
                    attempt,
                    REDIS_CONNECT_ATTEMPTS,
                    error
                );
                if attempt < REDIS_CONNECT_ATTEMPTS {
                    tokio::time::sleep(std::time::Duration::from_secs(REDIS_CONNECT_RETRY_SECS)).await;
                }
            }
        }
    }
    Err(format!(
        "Could not reach REDIS_URL after {} attempts; exiting so the relay is restarted",
        REDIS_CONNECT_ATTEMPTS
    ))
}

/// A background task that must run for the life of the process, named
/// for the log line if it stops.
type NamedTask = (&'static str, tokio::task::JoinHandle<()>);

/// Wait until the first task ends. Unless the relay is draining (then
/// tasks ending is expected), that is a failure: log it and return the
/// task's name.
async fn supervise(tasks: Vec<NamedTask>, hub: &RelayHub) -> Option<&'static str> {
    if tasks.is_empty() {
        return None;
    }
    let (names, handles): (Vec<&'static str>, Vec<_>) = tasks.into_iter().unzip();
    let (result, index, _rest) = futures_util::future::select_all(handles).await;
    let name = names[index];
    if hub.is_draining() {
        tracing::debug!("Background task '{}' ended during drain", name);
        return None;
    }
    match result {
        Ok(()) => tracing::error!("Background task '{}' stopped unexpectedly; draining, then exiting", name),
        Err(error) if error.is_panic() => {
            tracing::error!("Background task '{}' panicked; draining, then exiting", name)
        }
        Err(error) => tracing::error!(
            "Background task '{}' ended ({}); draining, then exiting",
            name,
            error
        ),
    }
    Some(name)
}

/// A replica that silently stopped processing the bus or refreshing its
/// presence must not keep looking healthy. When a supervised task fails,
/// drain (fail /health, close sockets with 1012, leave rooms, withdraw
/// presence) and then call `exit` (`main`: exit 1, and the orchestrator
/// restarts the relay). A drain already under way (SIGTERM) is left to
/// finish on its own.
async fn run_supervisor(
    tasks: Vec<NamedTask>,
    hub: RelayHub,
    grace: std::time::Duration,
    exit: impl FnOnce(&'static str),
) {
    let Some(name) = supervise(tasks, &hub).await else {
        return;
    };
    if hub.is_draining() {
        return;
    }
    hub.drain(grace).await;
    // By design the supervisor-failure exit skips the in-flight HTTP grace.
    exit(name);
}

/// The background sweeps every replica runs every 60 s: expired pairing
/// sessions, room upkeep, expired RTC and voice sessions. Shared by `main`
/// (which supervises them for the life of the process) and the two-relay
/// test harness (which aborts them).
fn spawn_upkeep(
    relay: &RelayHub,
    sessions: &SessionStore,
    rtc_sessions: &RtcSessionStore,
    voice_sessions: &VoiceSessionStore,
) -> Vec<NamedTask> {
    // Spawn background cleanup for expired sessions
    let cleanup_sessions = sessions.clone();
    let sessions_sweep = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = cleanup_sessions.cleanup_expired().await {
                tracing::debug!("Session sweep failed: {}", error);
            }
            tracing::debug!("Cleaned up expired sessions");
        }
    });

    // Room upkeep every 60 s (pre-flight 7). In-memory: sweep expired rooms.
    // Redis: rooms expire on their own (EXPIRE 600), so each replica
    // refreshes every room where it holds an Astation socket (owner or
    // pending) and closes its Atem sockets whose room no longer exists.
    // A Redis outage longer than ~9 minutes (600 s TTL minus one interval)
    // lets live rooms expire: their sockets are then closed and clients
    // reconnect, recreating them.
    let cleanup_relay = relay.clone();
    let rooms_sweep = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        // A sweep slowed by a Redis outage must not be followed by a burst.
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            cleanup_relay.cleanup_expired().await;
            tracing::debug!("Cleaned up expired pair rooms");
        }
    });

    // Spawn background cleanup for expired RTC sessions
    let cleanup_rtc = rtc_sessions.clone();
    let rtc_sweep = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = cleanup_rtc.cleanup_expired().await {
                tracing::debug!("RTC session sweep failed: {}", error);
            }
            tracing::debug!("Cleaned up expired RTC sessions");
        }
    });

    // Spawn background cleanup for expired voice sessions
    let cleanup_voice = voice_sessions.clone();
    let voice_sweep = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = cleanup_voice.cleanup_expired().await {
                tracing::debug!("Voice session sweep failed: {}", error);
            }
            tracing::debug!("Cleaned up expired voice sessions");
        }
    });
    // Close clients whose send queue has stayed full for 10 s while no new
    // frame arrived (a new frame checks on its own).
    let sweep_slow = relay.clone();
    let slow_sweep = tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(1));
        loop {
            interval.tick().await;
            sweep_slow.local().sweep_slow();
        }
    });
    vec![
        ("session sweep", sessions_sweep),
        ("room keep-alive", rooms_sweep),
        ("RTC session sweep", rtc_sweep),
        ("voice session sweep", voice_sweep),
        ("slow-client sweep", slow_sweep),
    ]
}

async fn health_handler(State(state): State<AppState>) -> impl IntoResponse {
    if state.relay.is_draining() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({ "status": "draining" })),
        );
    }
    let redis = state.relay.redis_status().await;
    match state.vault.health_check().await {
        Ok(()) if redis != "unavailable" => (
            StatusCode::OK,
            Json(serde_json::json!({
                "status": "ok",
                "vault_store": state.vault.backend_name(),
                "knowledge_store": state.knowledge.backend_name(),
                "redis": redis,
                "replicas": state.relay.replica_count(),
            })),
        ),
        Ok(()) => {
            tracing::error!("Health check failed: Redis unavailable");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "status": "unhealthy", "redis": redis })),
            )
        }
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
        })
        .layer(axum::middleware::from_fn_with_state(
            SharedLimit {
                hub: state.relay.clone(),
                bucket: "grant",
                limit: GRANT_LIMIT_PER_MINUTE,
                burst: 10,
            },
            shared_rate_limit,
        ));

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
        })
        .layer(axum::middleware::from_fn_with_state(
            SharedLimit {
                hub: state.relay.clone(),
                bucket: "general",
                limit: GENERAL_LIMIT_PER_MINUTE,
            burst: 20,
            },
            shared_rate_limit,
        ));

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

/// SIGTERM (docker stop, Coolify redeploy) or Ctrl-C. Returns the
/// conventional exit code of the signal received (143 / 130).
async fn shutdown_signal() -> i32 {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(error) => {
                tracing::error!("Could not listen for SIGTERM: {}", error);
                std::future::pending::<()>().await;
            }
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => 130,
        _ = terminate => 143,
    }
}

/// Serve until `signal`, then drain (fail /health, close sockets with
/// 1012, leave rooms, withdraw presence) and let in-flight HTTP requests
/// finish, for at most `grace` after the drain: a long poll (LLM proxy, up
/// to 30 s) must not hold up a redeploy.
async fn serve_with_drain<S>(
    listener: tokio::net::TcpListener,
    app: Router,
    hub: RelayHub,
    signal: S,
    grace: std::time::Duration,
) -> std::io::Result<()>
where
    S: std::future::Future<Output = ()> + Send + 'static,
{
    let (drained_tx, drained_rx) = tokio::sync::oneshot::channel::<()>();
    let server = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        signal.await;
        tracing::info!("Shutdown signal received: draining relay sockets");
        hub.drain(grace).await;
        let _ = drained_tx.send(());
    });
    // The bound starts once the drain is done (sockets gone, presence
    // withdrawn); before the signal the server runs for as long as it likes.
    let deadline = async move {
        match drained_rx.await {
            Ok(()) => tokio::time::sleep(grace).await,
            Err(_) => std::future::pending::<()>().await,
        }
    };
    tokio::select! {
        result = server => result,
        _ = deadline => {
            tracing::warn!(
                "In-flight HTTP requests still running {:?} after the drain; abandoning them",
                grace
            );
            Ok(())
        }
    }
}

#[tokio::main]
async fn main() {
    // Initialize tracing/logging
    tracing_subscriber::fmt()
        .with_target(false)
        .with_level(true)
        .init();

    // `station-relay-server admin …`: an operator command, not the server.
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("admin") {
        std::process::exit(admin::main(&args[1..]).await);
    }
    serve().await;
}

async fn serve() {
    tracing::info!("Starting Astation server...");

    // Configuration errors stop the relay before anything connects.
    let redis_url = redis_url();
    let expected_replicas = replicas_expected();

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
    // registered keys from an in-memory cache, so it is loaded once here,
    // before the relay's shared state is set up.
    let keys = cluster::keys::KeyCache::new();
    let key_count = keys
        .load(identity.as_ref())
        .await
        .expect("Failed to load Astation relay keys");
    tracing::info!("Loaded {} Astation relay key(s)", key_count);

    // Rooms, pairing/voice/RTC sessions and rate limits: Redis when
    // REDIS_URL is set (several replicas), else in memory (one replica).
    // Startup order in Redis mode: keys above → Redis connect (bounded
    // retries, then exit 1) → presence (one refresh, so peers are known) →
    // bus subscription + dispatcher → background sweeps below → listener.
    let (relay, sessions, rtc_sessions, voice_sessions, cluster_tasks) = match redis_url {
        Some(url) => {
            tracing::info!("Connecting to Redis for shared relay state...");
            let auth_timeout = std::time::Duration::from_secs(relay::RELAY_AUTH_TIMEOUT_SECS);
            let mut cluster = match start_redis_replica(&url, identity.clone(), keys, auth_timeout).await {
                Ok(cluster) => cluster,
                Err(message) => {
                    tracing::error!("{}", message);
                    std::process::exit(1);
                }
            };
            // The cluster's background tasks (bus, dispatcher, presence)
            // run for the life of the process, supervised below.
            let tasks = cluster.take_tasks();
            (
                cluster.relay,
                cluster.sessions,
                cluster.rtc_sessions,
                cluster.voice_sessions,
                tasks,
            )
        }
        None => {
            if let Err(message) = check_single_instance(expected_replicas) {
                tracing::error!("{}", message);
                std::process::exit(1);
            }
            tracing::warn!(
                "REDIS_URL not set — rooms, pairing/voice/RTC sessions and rate limits are \
                 IN-MEMORY: run exactly ONE relay replica. Set REDIS_URL to run several."
            );
            let relay = RelayHub::from_keys(keys);
            (
                relay,
                SessionStore::new(),
                RtcSessionStore::new(),
                VoiceSessionStore::new(),
                Vec::new(),
            )
        }
    };

    // Background tasks run for the life of the process; one that stops
    // outside a drain stops the relay (exit 1) so it is restarted.
    let mut background = cluster_tasks;
    background.extend(spawn_upkeep(&relay, &sessions, &rtc_sessions, &voice_sessions));
    tokio::spawn(run_supervisor(background, relay.clone(), relay::DRAIN_GRACE, |_| {
        std::process::exit(1)
    }));

    let state = AppState {
        sessions,
        relay,
        rtc_sessions,
        voice_sessions,
        vault,
        knowledge,
        identity,
    };

    let shutdown_hub = state.relay.clone();
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

    let signal = async {
        shutdown_signal().await;
        // Our handlers replaced the default action, so without this a
        // second signal would do nothing until the drain ends.
        tokio::spawn(async {
            let code = shutdown_signal().await;
            tracing::warn!("Second shutdown signal during the drain: exiting now");
            std::process::exit(code);
        });
    };
    serve_with_drain(listener, app, shutdown_hub, signal, relay::DRAIN_GRACE)
        .await
        .expect("Server error");
    tracing::info!("Relay stopped");
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

    #[test]
    fn several_replicas_need_redis() {
        assert!(check_single_instance(1).is_ok());
        let message = check_single_instance(2).unwrap_err();
        assert!(message.contains("RELAY_REPLICAS_EXPECTED=2"), "{message}");
        assert!(message.contains("REDIS_URL"), "{message}");
    }

    #[test]
    fn replicas_expected_must_be_a_positive_integer() {
        assert_eq!(parse_replicas_expected(None), Ok(1));
        assert_eq!(parse_replicas_expected(Some("  ")), Ok(1));
        assert_eq!(parse_replicas_expected(Some("1")), Ok(1));
        assert_eq!(parse_replicas_expected(Some(" 3 ")), Ok(3));
        for bad in ["0", "-1", "two", "2.5", "1e3"] {
            let message = parse_replicas_expected(Some(bad)).unwrap_err();
            assert!(message.contains("RELAY_REPLICAS_EXPECTED"), "{message}");
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
            br#"{"knowledge_store":"memory","redis":"disabled","replicas":1,"status":"ok","vault_store":"memory"}"#
        );
    }

    #[tokio::test]
    async fn health_fails_when_redis_is_unavailable() {
        struct Down;
        #[async_trait::async_trait]
        impl cluster::health::ClusterHealth for Down {
            async fn redis_status(&self) -> &'static str {
                "unavailable"
            }
            fn replicas(&self) -> usize {
                1
            }
            fn is_live(&self, _: &str) -> bool {
                true
            }
            async fn withdraw(&self) -> Result<(), cluster::StoreError> {
                Ok(())
            }
        }
        let state = AppState {
            relay: RelayHub::with_health(Arc::new(Down)),
            ..test_state()
        };
        let response = Router::new()
            .route("/health", get(health_handler))
            .with_state(state)
            .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(body.as_ref(), br#"{"redis":"unavailable","status":"unhealthy"}"#);
    }

    /// Runs `run_supervisor` with an injected exit; returns the task it
    /// exited for (None: it didn't exit).
    async fn supervised(tasks: Vec<NamedTask>, hub: RelayHub) -> Option<&'static str> {
        let reported = Arc::new(std::sync::Mutex::new(None));
        let sink = reported.clone();
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_supervisor(tasks, hub, std::time::Duration::from_millis(100), move |name| {
                *sink.lock().unwrap() = Some(name)
            }),
        )
        .await
        .expect("the supervisor did not return");
        let name = *reported.lock().unwrap();
        name
    }

    #[tokio::test]
    async fn supervisor_reports_a_task_that_ends_early() {
        let tasks: Vec<NamedTask> = vec![
            ("presence refresh", tokio::spawn(std::future::pending::<()>())),
            ("bus dispatcher", tokio::spawn(async {})),
        ];
        assert_eq!(supervised(tasks, RelayHub::new()).await, Some("bus dispatcher"));
    }

    #[tokio::test]
    async fn supervisor_reports_a_task_that_panics() {
        let tasks: Vec<NamedTask> = vec![
            ("room keep-alive", tokio::spawn(async { panic!("boom") })),
            ("bus subscriber", tokio::spawn(std::future::pending::<()>())),
        ];
        assert_eq!(supervised(tasks, RelayHub::new()).await, Some("room keep-alive"));
    }

    #[tokio::test]
    async fn a_failed_task_drains_the_relay_before_the_exit() {
        let hub = RelayHub::new();
        let mut outbox = hub.local().register("c1", "room", cluster::local::SocketRole::Astation);
        let seen = Arc::new(std::sync::Mutex::new(None));
        let sink = seen.clone();
        let observed = hub.clone();
        let tasks: Vec<NamedTask> = vec![("bus dispatcher", tokio::spawn(async {}))];
        run_supervisor(tasks, hub, std::time::Duration::from_millis(100), move |name| {
            *sink.lock().unwrap() = Some((name, observed.is_draining(), observed.local().is_empty()))
        })
        .await;
        assert_eq!(*seen.lock().unwrap(), Some(("bus dispatcher", true, true)));
        assert!(outbox.close.changed().await.is_ok());
        assert_eq!(outbox.close.borrow().as_ref().map(|close| close.0), Some(1012));
    }

    /// The upkeep closes a client whose queue stays full with no new frames
    /// arriving (`send` alone would only notice on the next frame).
    #[tokio::test(start_paused = true)]
    async fn upkeep_closes_a_client_that_stays_full() {
        use cluster::local::{SocketRole, CLOSE_SLOW_CLIENT, MAX_QUEUED_FRAMES, SLOW_CLIENT_TIMEOUT};
        let hub = RelayHub::new();
        let mut outbox = hub.local().register("stuck", "room", SocketRole::Astation);
        for n in 0..=MAX_QUEUED_FRAMES {
            hub.local().send("stuck", format!("{n}"));
        }
        let tasks = spawn_upkeep(&hub, &SessionStore::new(), &RtcSessionStore::new(), &VoiceSessionStore::new());
        tokio::time::sleep(SLOW_CLIENT_TIMEOUT + std::time::Duration::from_secs(2)).await;
        assert!(!hub.local().contains("stuck"));
        assert!(outbox.close.changed().await.is_ok());
        assert_eq!(outbox.close.borrow().as_ref().map(|close| close.0), Some(CLOSE_SLOW_CLIENT));
        for (_, task) in tasks {
            task.abort();
        }
    }

    #[tokio::test]
    async fn supervisor_expects_tasks_to_end_while_draining() {
        let hub = RelayHub::new();
        hub.drain(std::time::Duration::from_millis(10)).await;
        let tasks: Vec<NamedTask> = vec![("bus dispatcher", tokio::spawn(async {}))];
        assert_eq!(supervised(tasks, hub).await, None);
    }

    #[tokio::test]
    async fn shutdown_abandons_in_flight_requests_after_the_grace() {
        use tokio::io::AsyncWriteExt;
        let app = Router::new().route(
            "/slow",
            get(|| async {
                tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                "late"
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let hub = RelayHub::new();
        let (signal_tx, signal_rx) = tokio::sync::oneshot::channel::<()>();
        let grace = std::time::Duration::from_millis(200);
        let server = tokio::spawn(serve_with_drain(
            listener,
            app,
            hub.clone(),
            async move {
                let _ = signal_rx.await;
            },
            grace,
        ));
        let mut client = tokio::net::TcpStream::connect(address).await.unwrap();
        client
            .write_all(b"GET /slow HTTP/1.1\r\nHost: relay\r\n\r\n")
            .await
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        signal_tx.send(()).unwrap();
        let finished = tokio::time::timeout(std::time::Duration::from_secs(3), server).await;
        assert!(finished.is_ok(), "shutdown waited for the in-flight request");
        assert!(hub.is_draining());
    }

    #[tokio::test]
    async fn health_fails_while_draining() {
        let state = test_state();
        state.relay.drain(std::time::Duration::from_millis(10)).await;
        let response = router(state)
            .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(body.as_ref(), br#"{"status":"draining"}"#);
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
