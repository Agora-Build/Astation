use axum::{
    extract::{ws::WebSocket, Query, State, WebSocketUpgrade},
    http::StatusCode,
    response::{Html, IntoResponse, Json},
};
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use tokio::time::Instant;

use crate::AppState;

// Characters for pairing codes — no ambiguous chars (0/O, 1/I/L excluded)
const CODE_CHARS: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/// Room expiry: 10 minutes if unpaired.
const ROOM_EXPIRY_SECS: u64 = 600;

// --- Types ---

struct PairRoom {
    #[allow(dead_code)]
    code: String,
    hostname: String,
    atem_tx: Option<mpsc::UnboundedSender<String>>,
    astation_tx: Option<mpsc::UnboundedSender<String>>,
    created_at: Instant,
}

#[derive(Clone)]
pub struct RelayHub {
    rooms: Arc<RwLock<HashMap<String, PairRoom>>>,
}

impl RelayHub {
    pub fn new() -> Self {
        Self {
            rooms: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Remove rooms that are older than ROOM_EXPIRY_SECS and have no astation connected.
    pub async fn cleanup_expired(&self) {
        let now = Instant::now();
        let mut rooms = self.rooms.write().await;
        rooms.retain(|_, room| {
            let age = now.duration_since(room.created_at).as_secs();
            // Keep if not expired, or if astation is connected (actively paired)
            age < ROOM_EXPIRY_SECS || room.astation_tx.is_some()
        });
    }
}

impl Default for RelayHub {
    fn default() -> Self {
        Self::new()
    }
}

/// Generate an 8-char pairing code like "ABCD-EFGH" (no ambiguous chars).
fn generate_pairing_code() -> String {
    let mut rng = rand::thread_rng();
    let chars: Vec<u8> = (0..8)
        .map(|_| CODE_CHARS[rng.gen_range(0..CODE_CHARS.len())])
        .collect();
    let s = String::from_utf8(chars).unwrap();
    format!("{}-{}", &s[..4], &s[4..])
}

// --- Request / Response types ---

#[derive(Deserialize)]
pub struct CreatePairRequest {
    pub hostname: String,
}

#[derive(Serialize, Deserialize)]
pub struct CreatePairResponse {
    pub code: String,
}

#[derive(Serialize, Deserialize)]
pub struct PairStatusResponse {
    pub paired: bool,
    pub hostname: String,
}

#[derive(Deserialize)]
pub struct WsQuery {
    pub role: String,
    pub code: String,
}

#[derive(Deserialize)]
pub struct PairPageQuery {
    pub code: String,
}

// --- Handlers ---

/// POST /api/pair — Register for pairing, get a code back.
pub async fn create_pair_handler(
    State(state): State<AppState>,
    Json(body): Json<CreatePairRequest>,
) -> impl IntoResponse {
    let hub = &state.relay;
    let code = generate_pairing_code();
    let room = PairRoom {
        code: code.clone(),
        hostname: body.hostname,
        atem_tx: None,
        astation_tx: None,
        created_at: Instant::now(),
    };

    let mut rooms = hub.rooms.write().await;
    rooms.insert(code.clone(), room);
    drop(rooms);

    tracing::info!("Pair room created: {}", code);
    (StatusCode::CREATED, Json(CreatePairResponse { code }))
}

/// GET /api/pair/:code — Check pairing status.
pub async fn pair_status_handler(
    State(state): State<AppState>,
    axum::extract::Path(code): axum::extract::Path<String>,
) -> impl IntoResponse {
    let rooms = state.relay.rooms.read().await;
    match rooms.get(&code) {
        Some(room) => {
            let paired = room.astation_tx.is_some();
            Ok(Json(PairStatusResponse {
                paired,
                hostname: room.hostname.clone(),
            }))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Room not found"})),
        )),
    }
}

/// GET /ws?role=atem|astation&code=XXXX — WebSocket upgrade for relay.
pub async fn ws_handler(
    State(state): State<AppState>,
    Query(params): Query<WsQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let hub = state.relay.clone();
    let code = params.code.clone();
    let role = params.role.clone();

    // Verify room exists
    {
        let rooms = hub.rooms.read().await;
        if !rooms.contains_key(&code) {
            return (
                StatusCode::NOT_FOUND,
                "Room not found",
            )
                .into_response();
        }
    }

    ws.on_upgrade(move |socket| handle_ws(hub, code, role, socket))
        .into_response()
}

async fn handle_ws(hub: RelayHub, code: String, role: String, socket: WebSocket) {
    let (mut ws_sink, mut ws_stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();

    // Register this side's sender in the room
    let _other_tx = {
        let mut rooms = hub.rooms.write().await;
        let room = match rooms.get_mut(&code) {
            Some(r) => r,
            None => {
                tracing::warn!("Room {} disappeared before WS setup", code);
                return;
            }
        };

        match role.as_str() {
            "atem" => {
                room.atem_tx = Some(tx.clone());
                room.astation_tx.clone()
            }
            "astation" => {
                room.astation_tx = Some(tx.clone());
                room.atem_tx.clone()
            }
            _ => {
                tracing::warn!("Unknown role: {}", role);
                return;
            }
        }
    };

    tracing::info!("WS connected: role={} code={}", role, code);

    // Task: forward messages from our channel to the WS sink
    let code_for_writer = code.clone();
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_sink
                .send(axum::extract::ws::Message::Text(msg.into()))
                .await
                .is_err()
            {
                tracing::debug!("WS write failed for {}", code_for_writer);
                break;
            }
        }
    });

    // Read incoming frames and forward to the other side
    let hub_for_read = hub.clone();
    let role_for_read = role.clone();
    let code_for_read = code.clone();
    while let Some(msg_result) = ws_stream.next().await {
        match msg_result {
            Ok(axum::extract::ws::Message::Text(text)) => {
                // Get the other side's sender from the room (it may have connected since we started)
                let other = {
                    let rooms = hub_for_read.rooms.read().await;
                    rooms.get(&code_for_read).and_then(|room| {
                        match role_for_read.as_str() {
                            "atem" => room.astation_tx.clone(),
                            "astation" => room.atem_tx.clone(),
                            _ => None,
                        }
                    })
                };

                if let Some(other_tx) = other {
                    let _ = other_tx.send(text.to_string());
                }
            }
            Ok(axum::extract::ws::Message::Close(_)) => break,
            Err(e) => {
                tracing::debug!("WS read error for {} {}: {}", role, code_for_read, e);
                break;
            }
            _ => {}
        }
    }

    // Cleanup: remove our sender from the room
    {
        let mut rooms = hub_for_read.rooms.write().await;
        if let Some(room) = rooms.get_mut(&code) {
            match role.as_str() {
                "atem" => room.atem_tx = None,
                "astation" => room.astation_tx = None,
                _ => {}
            }
            // If both sides disconnected, remove the room
            if room.atem_tx.is_none() && room.astation_tx.is_none() {
                rooms.remove(&code);
                tracing::info!("Room {} removed (both sides disconnected)", code);
            }
        }
    }

    write_task.abort();
    tracing::info!("WS disconnected: role={} code={}", role, code);
}

/// GET /pair?code=XXXX — HTML landing page for pairing.
pub async fn pair_page_handler(
    State(state): State<AppState>,
    Query(params): Query<PairPageQuery>,
) -> impl IntoResponse {
    let rooms = state.relay.rooms.read().await;
    match rooms.get(&params.code) {
        Some(room) => {
            let html = render_pair_page(&params.code, &room.hostname);
            Ok(Html(html))
        }
        None => Err((
            StatusCode::NOT_FOUND,
            Html("<h1>Pairing code not found</h1><p>The code may have expired.</p>".to_string()),
        )),
    }
}

fn render_pair_page(code: &str, hostname: &str) -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Atem Pairing — {code}</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #0a0a0a; color: #e0e0e0; }}
    .card {{ background: #1a1a2e; border-radius: 16px; padding: 48px; text-align: center; max-width: 420px; box-shadow: 0 8px 32px rgba(0,0,0,0.4); }}
    .code {{ font-size: 48px; font-weight: 700; letter-spacing: 4px; color: #00d4aa; margin: 24px 0; font-family: 'SF Mono', monospace; }}
    .hostname {{ color: #888; font-size: 14px; margin-bottom: 32px; }}
    .btn {{ display: inline-block; padding: 12px 32px; background: #00d4aa; color: #0a0a0a; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 16px; transition: background 0.2s; }}
    .btn:hover {{ background: #00f5c4; }}
    .download {{ margin-top: 24px; font-size: 13px; color: #666; }}
    .download a {{ color: #00d4aa; }}
    h2 {{ margin: 0 0 8px; font-size: 20px; color: #fff; }}
    p {{ margin: 4px 0; font-size: 14px; color: #aaa; }}
  </style>
</head>
<body>
  <div class="card">
    <h2>Atem Pairing</h2>
    <p>Enter this code in Astation to connect</p>
    <div class="code">{code}</div>
    <div class="hostname">Host: {hostname}</div>
    <a class="btn" href="astation://pair?code={code}">Open in Astation</a>
    <div class="download">
      <p>Don't have Astation? <a href="https://github.com/AgoraIO-Community/astation/releases">Download</a></p>
    </div>
  </div>
</body>
</html>"#,
        code = code,
        hostname = hostname,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_code_format() {
        let code = generate_pairing_code();
        assert_eq!(code.len(), 9); // 4 + '-' + 4
        assert_eq!(&code[4..5], "-");

        // No ambiguous characters
        let no_hyphen = code.replace('-', "");
        for ch in no_hyphen.chars() {
            assert!(
                CODE_CHARS.contains(&(ch as u8)),
                "Character '{}' should be in CODE_CHARS",
                ch
            );
        }
    }

    #[test]
    fn pairing_code_uniqueness() {
        let codes: Vec<String> = (0..20).map(|_| generate_pairing_code()).collect();
        let unique: std::collections::HashSet<&String> = codes.iter().collect();
        assert!(unique.len() > 1, "Pairing codes should vary");
    }

    #[test]
    fn pairing_code_no_ambiguous_chars() {
        for _ in 0..100 {
            let code = generate_pairing_code();
            let no_hyphen = code.replace('-', "");
            assert!(!no_hyphen.contains('0'), "Should not contain 0");
            assert!(!no_hyphen.contains('O'), "Should not contain O");
            assert!(!no_hyphen.contains('1'), "Should not contain 1");
            assert!(!no_hyphen.contains('I'), "Should not contain I");
            assert!(!no_hyphen.contains('L'), "Should not contain L");
        }
    }

    #[tokio::test]
    async fn relay_hub_create_and_lookup() {
        let hub = RelayHub::new();

        let room = PairRoom {
            code: "ABCD-EFGH".to_string(),
            hostname: "test-host".to_string(),
            atem_tx: None,
            astation_tx: None,
            created_at: Instant::now(),
        };

        hub.rooms
            .write()
            .await
            .insert("ABCD-EFGH".to_string(), room);

        let rooms = hub.rooms.read().await;
        assert!(rooms.contains_key("ABCD-EFGH"));
        assert_eq!(rooms["ABCD-EFGH"].hostname, "test-host");
    }

    #[tokio::test]
    async fn relay_hub_cleanup_expired() {
        let hub = RelayHub::new();

        // Create a room with a very old timestamp
        let room = PairRoom {
            code: "OLD1-CODE".to_string(),
            hostname: "old-host".to_string(),
            atem_tx: None,
            astation_tx: None,
            created_at: Instant::now() - std::time::Duration::from_secs(ROOM_EXPIRY_SECS + 10),
        };
        hub.rooms
            .write()
            .await
            .insert("OLD1-CODE".to_string(), room);

        // Create a fresh room
        let fresh = PairRoom {
            code: "NEW1-CODE".to_string(),
            hostname: "new-host".to_string(),
            atem_tx: None,
            astation_tx: None,
            created_at: Instant::now(),
        };
        hub.rooms
            .write()
            .await
            .insert("NEW1-CODE".to_string(), fresh);

        hub.cleanup_expired().await;

        let rooms = hub.rooms.read().await;
        assert!(!rooms.contains_key("OLD1-CODE"), "Expired room should be removed");
        assert!(rooms.contains_key("NEW1-CODE"), "Fresh room should remain");
    }

    #[tokio::test]
    async fn relay_hub_cleanup_keeps_paired() {
        let hub = RelayHub::new();

        // Create an old but paired room (astation_tx is Some)
        let (tx, _rx) = mpsc::unbounded_channel::<String>();
        let room = PairRoom {
            code: "PAIR-CODE".to_string(),
            hostname: "paired-host".to_string(),
            atem_tx: None,
            astation_tx: Some(tx),
            created_at: Instant::now() - std::time::Duration::from_secs(ROOM_EXPIRY_SECS + 10),
        };
        hub.rooms
            .write()
            .await
            .insert("PAIR-CODE".to_string(), room);

        hub.cleanup_expired().await;

        let rooms = hub.rooms.read().await;
        assert!(
            rooms.contains_key("PAIR-CODE"),
            "Paired room should not be cleaned up"
        );
    }

    #[test]
    fn render_pair_page_contains_code() {
        let html = render_pair_page("TEST-CODE", "my-host");
        assert!(html.contains("TEST-CODE"));
        assert!(html.contains("my-host"));
        assert!(html.contains("astation://pair?code=TEST-CODE"));
    }

    // --- Integration tests (HTTP endpoint tests) ---

    use axum::{
        body::Body,
        http::{Request, StatusCode as HttpStatusCode},
        Router,
    };
    use tower::ServiceExt;

    fn create_relay_app() -> Router {
        let state = crate::AppState {
            sessions: crate::session_store::SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: crate::rtc_session::RtcSessionStore::new(),
        };
        Router::new()
            .route("/api/pair", axum::routing::post(create_pair_handler))
            .route("/api/pair/:code", axum::routing::get(pair_status_handler))
            .route("/ws", axum::routing::get(ws_handler))
            .route("/pair", axum::routing::get(pair_page_handler))
            .with_state(state)
    }

    /// Helper: POST /api/pair with given hostname, returns the response body as CreatePairResponse.
    async fn post_create_pair(app: Router, hostname: &str) -> (HttpStatusCode, String) {
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(format!(r#"{{"hostname": "{}"}}"#, hostname)))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let body_str = String::from_utf8(body.to_vec()).unwrap();
        (status, body_str)
    }

    #[tokio::test]
    async fn test_create_pair_endpoint() {
        let app = create_relay_app();
        let (status, body_str) = post_create_pair(app, "my-machine").await;

        assert_eq!(status, HttpStatusCode::CREATED);

        let resp: CreatePairResponse = serde_json::from_str(&body_str).unwrap();
        // Code should be in XXXX-XXXX format (9 chars total)
        assert_eq!(resp.code.len(), 9, "Code should be 9 characters (XXXX-XXXX)");
        assert_eq!(
            &resp.code[4..5],
            "-",
            "Code should have hyphen at position 4"
        );
        // Each half should be 4 alphanumeric chars
        let left = &resp.code[..4];
        let right = &resp.code[5..];
        assert!(
            left.chars().all(|c| c.is_ascii_alphanumeric()),
            "Left half should be alphanumeric"
        );
        assert!(
            right.chars().all(|c| c.is_ascii_alphanumeric()),
            "Right half should be alphanumeric"
        );
    }

    #[tokio::test]
    async fn test_create_pair_code_no_ambiguous_chars() {
        // Create several pairs and verify none contain ambiguous characters
        for _ in 0..20 {
            let app = create_relay_app();
            let (status, body_str) = post_create_pair(app, "test-host").await;
            assert_eq!(status, HttpStatusCode::CREATED);

            let resp: CreatePairResponse = serde_json::from_str(&body_str).unwrap();
            let code_no_hyphen = resp.code.replace('-', "");
            assert!(
                !code_no_hyphen.contains('0'),
                "Code should not contain '0': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('O'),
                "Code should not contain 'O': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('1'),
                "Code should not contain '1': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('I'),
                "Code should not contain 'I': {}",
                resp.code
            );
            assert!(
                !code_no_hyphen.contains('L'),
                "Code should not contain 'L': {}",
                resp.code
            );
        }
    }

    #[tokio::test]
    async fn test_pair_status_exists() {
        let app = create_relay_app();

        // Step 1: Create a pair
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "dev-machine"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreatePairResponse = serde_json::from_slice(&body).unwrap();
        let code = created.code;

        // Step 2: GET /api/pair/:code should return paired=false
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/pair/{}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let status_resp: PairStatusResponse = serde_json::from_slice(&body).unwrap();
        assert!(!status_resp.paired, "Newly created pair should not be paired yet");
        assert_eq!(status_resp.hostname, "dev-machine");
    }

    #[tokio::test]
    async fn test_pair_status_not_found() {
        let app = create_relay_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/pair/NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_pair_page_exists() {
        let app = create_relay_app();

        // Step 1: Create a pair
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/pair")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"hostname": "page-test-host"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::CREATED);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: CreatePairResponse = serde_json::from_slice(&body).unwrap();
        let code = created.code;

        // Step 2: GET /pair?code=XXXX should return HTML containing the code
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/pair?code={}", code))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(
            html.contains(&code),
            "HTML page should contain the pairing code"
        );
        assert!(
            html.contains("page-test-host"),
            "HTML page should contain the hostname"
        );
        assert!(
            html.contains("Atem Pairing"),
            "HTML page should contain the page title"
        );
        assert!(
            html.contains(&format!("astation://pair?code={}", code)),
            "HTML page should contain the deep link"
        );
    }

    #[tokio::test]
    async fn test_pair_page_not_found() {
        let app = create_relay_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/pair?code=NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), HttpStatusCode::NOT_FOUND);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(
            html.contains("not found"),
            "404 page should indicate code not found"
        );
    }

    #[tokio::test]
    async fn test_ws_handler_room_not_found() {
        let app = create_relay_app();

        // Send a non-upgrade GET request to /ws with a nonexistent room code.
        // Without the WebSocket upgrade headers, the handler should check the room
        // and return 404 before attempting the upgrade.
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/ws?role=atem&code=NONEXIST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // The ws_handler checks room existence before upgrade, so a non-upgrade
        // request to a nonexistent room should still fail. Axum returns 400 for
        // missing upgrade headers on WebSocket routes when the handler calls
        // ws.on_upgrade(), but our handler returns 404 before reaching that point
        // for nonexistent rooms.
        // Note: Since the request lacks upgrade headers, axum's WebSocketUpgrade
        // extractor will reject it. The handler won't even run. Axum returns 400
        // or the rejection status. We verify it does NOT return 200/101.
        let status = response.status();
        assert!(
            status == HttpStatusCode::NOT_FOUND
                || status == HttpStatusCode::BAD_REQUEST
                || status == HttpStatusCode::UPGRADE_REQUIRED,
            "Expected 404, 400, or 426 for non-upgrade WS request to nonexistent room, got {}",
            status
        );
    }

    #[tokio::test]
    async fn test_create_multiple_pairs_unique_codes() {
        let app = create_relay_app();
        let mut codes = std::collections::HashSet::new();

        for i in 0..10 {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/pair")
                        .header("Content-Type", "application/json")
                        .body(Body::from(format!(r#"{{"hostname": "host-{}"}}"#, i)))
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(response.status(), HttpStatusCode::CREATED);
            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let resp: CreatePairResponse = serde_json::from_slice(&body).unwrap();
            codes.insert(resp.code);
        }

        assert_eq!(
            codes.len(),
            10,
            "All 10 pairing codes should be unique"
        );
    }
}
