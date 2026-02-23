use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use crate::AppState;
use crate::voice_session::VoiceSessionState;

/// OpenAI-compatible chat completion request format
#[derive(Debug, Deserialize)]
pub struct ChatCompletionRequest {
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    #[serde(skip)]
    pub session_id: Option<String>, // Will be extracted from headers or heuristics
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// OpenAI-compatible chat completion response format
#[derive(Debug, Serialize)]
pub struct ChatCompletionResponse {
    pub id: String,
    pub object: String,
    pub created: i64,
    pub model: String,
    pub choices: Vec<Choice>,
}

#[derive(Debug, Serialize)]
pub struct Choice {
    pub index: u32,
    pub message: ChatMessage,
    pub finish_reason: String,
}

/// POST /api/llm/chat
///
/// Smart buffering LLM proxy for Agora ConvoAI:
/// - Accumulating state: Return empty response immediately
/// - Triggered state: Block and wait for Atem to send response
/// - ResponseReady state: Return cached response
///
/// Session identification:
/// 1. Try X-Session-ID header (if Agora provides it)
/// 2. Try custom X-Voice-Session-ID header (if Astation sets it)
/// 3. Fallback: IP + time-window heuristic (last session from this IP within 5 minutes)
pub async fn llm_chat_handler(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(req): Json<ChatCompletionRequest>,
) -> Response {
    // Extract session ID from headers or heuristics
    let session_id = extract_session_id(&headers, &state).await;

    let session_id = match session_id {
        Some(id) => id,
        None => {
            tracing::warn!("No session ID found for /api/llm/chat request");
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({
                    "error": "Session ID not found. Ensure X-Voice-Session-ID header is set or session is active."
                }))
            ).into_response();
        }
    };

    tracing::debug!("Processing /api/llm/chat for session: {}", session_id);

    // Get last user message for logging
    let last_message = req.messages.last().map(|m| m.content.clone()).unwrap_or_default();
    tracing::info!("Session {}: User message: {}", session_id, last_message);

    // Increment request counter
    state.voice_sessions.increment_requests(&session_id).await;

    // Add transcription to buffer
    state.voice_sessions.add_transcription(&session_id, last_message).await;

    // Get session state
    let session_state = state.voice_sessions.get_state(&session_id).await;

    match session_state {
        Some(VoiceSessionState::Accumulating) => {
            // Return empty response immediately
            tracing::debug!("Session {} in Accumulating state - returning empty response", session_id);
            return create_empty_response().into_response();
        }
        Some(VoiceSessionState::Triggered) => {
            // Block and wait for Atem response
            tracing::info!("Session {} in Triggered state - blocking for Atem response", session_id);
            let waiter = state.voice_sessions.register_waiter(session_id.clone()).await;

            // Wait for response with timeout (30 seconds)
            match tokio::time::timeout(
                tokio::time::Duration::from_secs(30),
                waiter
            ).await {
                Ok(Ok(response_text)) => {
                    tracing::info!("Session {}: Received response from Atem", session_id);
                    return create_response(response_text).into_response();
                }
                Ok(Err(_)) => {
                    tracing::error!("Session {}: Waiter channel closed", session_id);
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({"error": "Response channel closed"}))
                    ).into_response();
                }
                Err(_) => {
                    tracing::error!("Session {}: Timeout waiting for Atem response", session_id);
                    return (
                        StatusCode::GATEWAY_TIMEOUT,
                        Json(serde_json::json!({"error": "Timeout waiting for Atem response"}))
                    ).into_response();
                }
            }
        }
        Some(VoiceSessionState::ResponseReady) => {
            // Return cached response
            if let Some(session) = state.voice_sessions.get(&session_id).await {
                if let Some(response_text) = session.response {
                    tracing::debug!("Session {} in ResponseReady state - returning cached response", session_id);
                    // Clean up session after delivering response
                    state.voice_sessions.delete(&session_id).await;
                    return create_response(response_text).into_response();
                }
            }
            tracing::error!("Session {} in ResponseReady but no cached response", session_id);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "Response ready but not found"}))
            ).into_response();
        }
        None => {
            tracing::warn!("Session {} not found", session_id);
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": "Session not found"}))
            ).into_response();
        }
    }
}

/// Extract session ID from headers or heuristics
///
/// Priority:
/// 1. X-Voice-Session-ID header (set by Astation when creating session)
/// 2. X-Session-ID header (if Agora provides it)
/// 3. X-Forwarded-For IP + recent session lookup (last session from IP within 5 min)
async fn extract_session_id(headers: &axum::http::HeaderMap, _state: &AppState) -> Option<String> {
    // Try X-Voice-Session-ID (custom header)
    if let Some(session_id) = headers.get("x-voice-session-id") {
        if let Ok(id) = session_id.to_str() {
            return Some(id.to_string());
        }
    }

    // Try X-Session-ID (if Agora provides it)
    if let Some(session_id) = headers.get("x-session-id") {
        if let Ok(id) = session_id.to_str() {
            return Some(id.to_string());
        }
    }

    // Fallback: IP-based heuristic (last active session from this IP)
    if let Some(ip) = headers.get("x-forwarded-for").or_else(|| headers.get("x-real-ip")) {
        if let Ok(ip_str) = ip.to_str() {
            tracing::debug!("Using IP-based session lookup for: {}", ip_str);
            // TODO: Implement IP → session_id mapping with time window
            // For now, return None to force explicit session ID in headers
        }
    }

    None
}

/// Create empty response (Accumulating state)
fn create_empty_response() -> Json<ChatCompletionResponse> {
    Json(ChatCompletionResponse {
        id: format!("chatcmpl-{}", uuid::Uuid::new_v4()),
        object: "chat.completion".to_string(),
        created: chrono::Utc::now().timestamp(),
        model: "atem-voice-proxy".to_string(),
        choices: vec![Choice {
            index: 0,
            message: ChatMessage {
                role: "assistant".to_string(),
                content: "".to_string(),
            },
            finish_reason: "stop".to_string(),
        }],
    })
}

/// Create response with content (ResponseReady state)
fn create_response(content: String) -> Json<ChatCompletionResponse> {
    Json(ChatCompletionResponse {
        id: format!("chatcmpl-{}", uuid::Uuid::new_v4()),
        object: "chat.completion".to_string(),
        created: chrono::Utc::now().timestamp(),
        model: "atem-voice-proxy".to_string(),
        choices: vec![Choice {
            index: 0,
            message: ChatMessage {
                role: "assistant".to_string(),
                content,
            },
            finish_reason: "stop".to_string(),
        }],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voice_session::VoiceSessionStore;
    use crate::relay::RelayHub;
    use crate::session_store::SessionStore;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_verify::SessionVerifyCache;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn create_test_state() -> AppState {
        AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            session_verify_cache: SessionVerifyCache::new(),
            voice_sessions: VoiceSessionStore::new(),
        }
    }

    #[tokio::test]
    async fn test_accumulating_returns_empty() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Hello world".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-123".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            headers,
            Json(req),
        ).await;

        let status = response.status();
        assert_eq!(status, StatusCode::OK);

        // Verify session is still in Accumulating state
        let session = state.voice_sessions.get("test-123").await.unwrap();
        assert_eq!(session.state, VoiceSessionState::Accumulating);
    }

    #[tokio::test]
    async fn test_triggered_waits_for_response() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        // Trigger the session
        state.voice_sessions.trigger("test-123").await;

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Create a function".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-123".parse().unwrap());

        // Simulate Atem sending response after 100ms
        let state_clone = state.clone();
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            state_clone.voice_sessions.set_response(
                "test-123",
                "Here's the function implementation...".to_string(),
            ).await;
        });

        let response = llm_chat_handler(
            State(state.clone()),
            headers,
            Json(req),
        ).await;

        let status = response.status();
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn test_missing_session_id() {
        let state = create_test_state();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Hello".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let headers = axum::http::HeaderMap::new(); // No session ID header

        let response = llm_chat_handler(
            State(state),
            headers,
            Json(req),
        ).await;

        let status = response.status();
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn test_nonexistent_session() {
        let state = create_test_state();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Hello".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "nonexistent".parse().unwrap());

        let response = llm_chat_handler(
            State(state),
            headers,
            Json(req),
        ).await;

        let status = response.status();
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_response_ready_returns_cached() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-ready".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        // Set response directly (simulating Atem already replied)
        state.voice_sessions.set_response(
            "test-ready",
            "Here is the implementation".to_string(),
        ).await;

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Final request".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-ready".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Session should be cleaned up after delivering response
        let session = state.voice_sessions.get("test-ready").await;
        assert!(session.is_none());
    }

    #[tokio::test]
    async fn test_accumulating_buffers_transcription() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-buf".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "First chunk".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-buf".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Verify transcription was buffered
        let session = state.voice_sessions.get("test-buf").await.unwrap();
        assert_eq!(session.buffer.len(), 1);
        assert!(session.get_accumulated_text().contains("First chunk"));
    }

    #[tokio::test]
    async fn test_x_session_id_header_fallback() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-fallback".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Test".to_string(),
            }],
            stream: false,
            session_id: None,
        };

        // Use X-Session-ID instead of X-Voice-Session-ID
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-session-id", "test-fallback".parse().unwrap());

        let response = llm_chat_handler(
            State(state),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);
    }
}
