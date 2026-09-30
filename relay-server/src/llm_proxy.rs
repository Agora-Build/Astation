use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use crate::AppState;
use crate::voice_session::{VoiceSession, VoiceSessionState};
use crate::cluster::StoreError;
use crate::voice_session::WaitOutcome;

/// How long a Triggered request waits for the Atem's answer.
pub const LLM_WAIT_SECS: u64 = 30;

fn voice_unavailable(session_id: &str, error: StoreError) -> Response {
    tracing::error!("Voice store unavailable for session {}: {}", session_id, error);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({"error": "Temporarily unavailable"})),
    )
        .into_response()
}

/// OpenAI-compatible chat completion request format
#[derive(Debug, Deserialize)]
pub struct ChatCompletionRequest {
    pub messages: Vec<ChatMessage>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// Query parameters for /api/llm/chat (ConvoAI passes session_id via URL)
#[derive(Debug, Deserialize)]
pub struct LlmChatQuery {
    pub session_id: Option<String>,
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
    Query(query): Query<LlmChatQuery>,
    headers: axum::http::HeaderMap,
    Json(req): Json<ChatCompletionRequest>,
) -> Response {
    // Extract session ID: query param first, then headers
    let session_id = query.session_id
        .or_else(|| extract_session_id_from_headers(&headers));

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

    let voice = &state.voice_sessions;
    if let Err(error) = voice.increment_requests(&session_id).await {
        return voice_unavailable(&session_id, error);
    }
    if let Err(error) = voice.add_transcription(&session_id, last_message).await {
        return voice_unavailable(&session_id, error);
    }
    let session_state = match voice.get_state(&session_id).await {
        Ok(session_state) => session_state,
        Err(error) => return voice_unavailable(&session_id, error),
    };

    match session_state {
        Some(VoiceSessionState::Accumulating) => {
            tracing::debug!("Session {} in Accumulating state - returning empty response", session_id);
            create_empty_response().into_response()
        }
        Some(VoiceSessionState::Triggered) => {
            tracing::info!("Session {} in Triggered state - blocking for Atem response", session_id);
            match voice
                .wait_reply(&session_id, std::time::Duration::from_secs(LLM_WAIT_SECS))
                .await
            {
                Ok(WaitOutcome::Reply(response_text)) => {
                    tracing::info!("Session {}: Received response from Atem", session_id);
                    create_response(response_text).into_response()
                }
                Ok(WaitOutcome::Closed) => {
                    tracing::error!("Session {}: Waiter channel closed", session_id);
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(serde_json::json!({"error": "Response channel closed"})),
                    )
                        .into_response()
                }
                Ok(WaitOutcome::TimedOut) => {
                    tracing::error!("Session {}: Timeout waiting for Atem response", session_id);
                    (
                        StatusCode::GATEWAY_TIMEOUT,
                        Json(serde_json::json!({"error": "Timeout waiting for Atem response"})),
                    )
                        .into_response()
                }
                Err(error) => voice_unavailable(&session_id, error),
            }
        }
        Some(VoiceSessionState::ResponseReady) => match voice.get(&session_id).await {
            Err(error) => voice_unavailable(&session_id, error),
            Ok(Some(VoiceSession { response: Some(response_text), .. })) => {
                tracing::debug!("Session {} in ResponseReady state - returning cached response", session_id);
                // Clean up session after delivering response
                if let Err(error) = voice.delete(&session_id).await {
                    tracing::warn!("Could not delete voice session {}: {}", session_id, error);
                }
                create_response(response_text).into_response()
            }
            Ok(_) => {
                tracing::error!("Session {} in ResponseReady but no cached response", session_id);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"error": "Response ready but not found"})),
                )
                    .into_response()
            }
        },
        None => {
            tracing::warn!("Session {} not found", session_id);
            (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"error": "Session not found"})),
            )
                .into_response()
        }
    }
}

/// Extract session ID from HTTP headers.
///
/// Priority:
/// 1. X-Voice-Session-ID header (set by Astation when creating session)
/// 2. X-Session-ID header (if Agora provides it)
/// 3. X-Forwarded-For IP + recent session lookup (last session from IP within 5 min)
fn extract_session_id_from_headers(headers: &axum::http::HeaderMap) -> Option<String> {
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
    use axum::http::StatusCode;

    fn create_test_state() -> AppState {
        AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: std::sync::Arc::new(crate::vault_store::InMemoryVaultStore::new()),
            knowledge: std::sync::Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            identity: std::sync::Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
        }
    }

    #[tokio::test]
    async fn test_accumulating_returns_empty() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Hello world".to_string(),
            }],
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-123".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: None }),
            headers,
            Json(req),
        ).await;

        let status = response.status();
        assert_eq!(status, StatusCode::OK);

        // Verify session is still in Accumulating state
        let session = state.voice_sessions.get("test-123").await.unwrap().unwrap();
        assert_eq!(session.state, VoiceSessionState::Accumulating);
    }

    #[tokio::test]
    async fn test_triggered_waits_for_response() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();

        // Trigger the session
        state.voice_sessions.trigger("test-123").await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Create a function".to_string(),
            }],
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
            ).await.unwrap();
        });

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: None }),
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
        };

        let headers = axum::http::HeaderMap::new(); // No session ID header

        let response = llm_chat_handler(
            State(state),
            Query(LlmChatQuery { session_id: None }),
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
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "nonexistent".parse().unwrap());

        let response = llm_chat_handler(
            State(state),
            Query(LlmChatQuery { session_id: None }),
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
        ).await.unwrap();

        // Set response directly (simulating Atem already replied)
        state.voice_sessions.set_response(
            "test-ready",
            "Here is the implementation".to_string(),
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Final request".to_string(),
            }],
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-ready".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: None }),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Session should be cleaned up after delivering response
        let session = state.voice_sessions.get("test-ready").await.unwrap();
        assert!(session.is_none());
    }

    #[tokio::test]
    async fn test_accumulating_buffers_transcription() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-buf".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "First chunk".to_string(),
            }],
        };

        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-buf".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: None }),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Verify transcription was buffered
        let session = state.voice_sessions.get("test-buf").await.unwrap().unwrap();
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
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Test".to_string(),
            }],
        };

        // Use X-Session-ID instead of X-Voice-Session-ID
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-session-id", "test-fallback".parse().unwrap());

        let response = llm_chat_handler(
            State(state),
            Query(LlmChatQuery { session_id: None }),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_session_id_from_query_param() {
        let state = create_test_state();
        state.voice_sessions.create(
            "query-sess".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Hello via query param".to_string(),
            }],
        };

        // No header — session ID comes from query param
        let headers = axum::http::HeaderMap::new();

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: Some("query-sess".to_string()) }),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Verify transcription was buffered in the correct session
        let session = state.voice_sessions.get("query-sess").await.unwrap().unwrap();
        assert!(session.get_accumulated_text().contains("Hello via query param"));
    }

    #[tokio::test]
    async fn test_query_param_overrides_header() {
        let state = create_test_state();
        // Create two sessions
        state.voice_sessions.create(
            "from-query".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();
        state.voice_sessions.create(
            "from-header".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();

        let req = ChatCompletionRequest {
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: "Which session?".to_string(),
            }],
        };

        // Both query param and header set — query param should win
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "from-header".parse().unwrap());

        let response = llm_chat_handler(
            State(state.clone()),
            Query(LlmChatQuery { session_id: Some("from-query".to_string()) }),
            headers,
            Json(req),
        ).await;

        assert_eq!(response.status(), StatusCode::OK);

        // Verify text went to the query param session, not the header session
        let query_session = state.voice_sessions.get("from-query").await.unwrap().unwrap();
        assert!(query_session.get_accumulated_text().contains("Which session?"));

        let header_session = state.voice_sessions.get("from-header").await.unwrap().unwrap();
        assert!(header_session.get_accumulated_text().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn test_triggered_times_out_with_504() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-timeout".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await.unwrap();
        state.voice_sessions.trigger("test-timeout").await.unwrap();
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("x-voice-session-id", "test-timeout".parse().unwrap());
        let response = llm_chat_handler(
            State(state),
            Query(LlmChatQuery { session_id: None }),
            headers,
            Json(ChatCompletionRequest {
                messages: vec![ChatMessage { role: "user".to_string(), content: "go".to_string() }],
            }),
        ).await;
        assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
    }
}
