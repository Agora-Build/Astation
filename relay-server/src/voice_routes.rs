use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use crate::AppState;
use crate::voice_session::{
    CreateVoiceSessionRequest, CreateVoiceSessionResponse,
    TriggerResponse, AtemResponseRequest, AtemResponseResponse,
};

/// POST /api/voice-sessions
///
/// Create a new voice coding session (called by Astation)
pub async fn create_voice_session_handler(
    State(state): State<AppState>,
    Json(req): Json<CreateVoiceSessionRequest>,
) -> Result<Json<CreateVoiceSessionResponse>, StatusCode> {
    let session_id = uuid::Uuid::new_v4().to_string();

    let session = state.voice_sessions.create(
        session_id.clone(),
        req.atem_id.clone(),
        req.channel.clone(),
    ).await;

    tracing::info!(
        "Created voice session {} for Atem {} in channel {}",
        session_id,
        req.atem_id,
        req.channel
    );

    Ok(Json(CreateVoiceSessionResponse {
        session_id: session.session_id,
        atem_id: session.atem_id,
        channel: session.channel,
        created_at: session.created_at,
    }))
}

/// POST /api/voice-sessions/:id/trigger
///
/// Trigger session to send accumulated transcriptions to Atem (called by Astation)
/// This happens when:
/// - User releases Ctrl+V (PTT mode)
/// - Timeout expires (Hands-Free mode)
/// - User says trigger keyword (Hands-Free mode)
pub async fn trigger_voice_session_handler(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<TriggerResponse>, StatusCode> {
    let accumulated_text = state.voice_sessions.trigger(&session_id).await
        .ok_or(StatusCode::NOT_FOUND)?;

    let session = state.voice_sessions.get(&session_id).await
        .ok_or(StatusCode::NOT_FOUND)?;

    tracing::info!(
        "Triggered session {}: accumulated_text = \"{}\"",
        session_id,
        accumulated_text
    );

    Ok(Json(TriggerResponse {
        session_id: session.session_id,
        accumulated_text,
        atem_id: session.atem_id,
    }))
}

/// POST /api/voice-sessions/response
///
/// Receive LLM response from Atem and wake up waiting /api/llm/chat requests
/// (called by Atem directly via WebSocket or HTTP)
pub async fn atem_response_handler(
    State(state): State<AppState>,
    Json(req): Json<AtemResponseRequest>,
) -> Result<Json<AtemResponseResponse>, StatusCode> {
    state.voice_sessions.set_response(&req.session_id, req.response.clone()).await
        .ok_or(StatusCode::NOT_FOUND)?;

    tracing::info!(
        "Received response for session {}: {} chars",
        req.session_id,
        req.response.len()
    );

    Ok(Json(AtemResponseResponse {
        success: true,
        message: format!("Response received for session {}", req.session_id),
    }))
}

/// GET /api/voice-sessions/:id
///
/// Get session info (for debugging)
pub async fn get_voice_session_handler(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let session = state.voice_sessions.get(&session_id).await
        .ok_or(StatusCode::NOT_FOUND)?;

    Ok(Json(serde_json::json!({
        "session_id": session.session_id,
        "atem_id": session.atem_id,
        "channel": session.channel,
        "state": session.state,
        "buffer_size": session.buffer.len(),
        "accumulated_text": session.get_accumulated_text(),
        "has_response": session.response.is_some(),
        "created_at": session.created_at,
        "last_activity": session.last_activity,
        "request_count": session.request_count,
    })))
}

/// DELETE /api/voice-sessions/:id
///
/// Delete session (cleanup)
pub async fn delete_voice_session_handler(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    state.voice_sessions.delete(&session_id).await;
    tracing::info!("Deleted voice session {}", session_id);
    Ok(StatusCode::OK)
}

/// GET /api/voice-sessions
///
/// List all active sessions (for debugging)
pub async fn list_voice_sessions_handler(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let session_ids = state.voice_sessions.list_session_ids().await;

    Ok(Json(serde_json::json!({
        "sessions": session_ids,
        "count": session_ids.len(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voice_session::VoiceSessionStore;
    use crate::relay::RelayHub;
    use crate::session_store::SessionStore;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_verify::SessionVerifyCache;

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
    async fn test_create_voice_session() {
        let state = create_test_state();
        let req = CreateVoiceSessionRequest {
            atem_id: "atem-123".to_string(),
            channel: "test-channel".to_string(),
        };

        let result = create_voice_session_handler(State(state), Json(req)).await;
        assert!(result.is_ok());

        let response = result.unwrap().0;
        assert_eq!(response.atem_id, "atem-123");
        assert_eq!(response.channel, "test-channel");
    }

    #[tokio::test]
    async fn test_trigger_voice_session() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        ).await;

        state.voice_sessions.add_transcription("test-123", "Hello world".to_string()).await;

        let result = trigger_voice_session_handler(
            State(state),
            Path("test-123".to_string()),
        ).await;

        assert!(result.is_ok());
        let response = result.unwrap().0;
        assert_eq!(response.accumulated_text, "Hello world");
    }

    #[tokio::test]
    async fn test_atem_response() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        ).await;

        let req = AtemResponseRequest {
            session_id: "test-123".to_string(),
            response: "Here's the implementation...".to_string(),
        };

        let result = atem_response_handler(State(state.clone()), Json(req)).await;
        assert!(result.is_ok());

        let session = state.voice_sessions.get("test-123").await.unwrap();
        assert_eq!(session.response, Some("Here's the implementation...".to_string()));
    }

    #[tokio::test]
    async fn test_get_voice_session() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        ).await;

        let result = get_voice_session_handler(
            State(state),
            Path("test-123".to_string()),
        ).await;

        assert!(result.is_ok());
        let response = result.unwrap().0;
        assert_eq!(response["session_id"], "test-123");
        assert_eq!(response["atem_id"], "atem-456");
    }

    #[tokio::test]
    async fn test_delete_voice_session() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        ).await;

        let result = delete_voice_session_handler(
            State(state.clone()),
            Path("test-123".to_string()),
        ).await;

        assert!(result.is_ok());

        // Verify session is deleted
        let session = state.voice_sessions.get("test-123").await;
        assert!(session.is_none());
    }

    #[tokio::test]
    async fn test_list_voice_sessions() {
        let state = create_test_state();
        state.voice_sessions.create("test-1".to_string(), "atem".to_string(), "ch".to_string()).await;
        state.voice_sessions.create("test-2".to_string(), "atem".to_string(), "ch".to_string()).await;

        let result = list_voice_sessions_handler(State(state)).await;
        assert!(result.is_ok());

        let response = result.unwrap().0;
        assert_eq!(response["count"], 2);
    }

    #[tokio::test]
    async fn test_trigger_nonexistent_session() {
        let state = create_test_state();

        let result = trigger_voice_session_handler(
            State(state),
            Path("nonexistent".to_string()),
        ).await;

        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_response_nonexistent_session() {
        let state = create_test_state();

        let req = AtemResponseRequest {
            session_id: "nonexistent".to_string(),
            response: "Some response".to_string(),
        };

        let result = atem_response_handler(State(state), Json(req)).await;

        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_get_nonexistent_session() {
        let state = create_test_state();

        let result = get_voice_session_handler(
            State(state),
            Path("nonexistent".to_string()),
        ).await;

        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_trigger_empty_buffer() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-empty".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        // Trigger with no transcriptions added
        let result = trigger_voice_session_handler(
            State(state),
            Path("test-empty".to_string()),
        ).await;

        assert!(result.is_ok());
        let response = result.unwrap().0;
        assert_eq!(response.accumulated_text, "");
    }

    #[tokio::test]
    async fn test_trigger_sets_state() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-state".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        state.voice_sessions.add_transcription("test-state", "Hello".to_string()).await;
        trigger_voice_session_handler(
            State(state.clone()),
            Path("test-state".to_string()),
        ).await.unwrap();

        let session = state.voice_sessions.get("test-state").await.unwrap();
        assert_eq!(session.state, crate::voice_session::VoiceSessionState::Triggered);
    }

    #[tokio::test]
    async fn test_response_sets_state() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-resp".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        let req = AtemResponseRequest {
            session_id: "test-resp".to_string(),
            response: "Done!".to_string(),
        };
        atem_response_handler(State(state.clone()), Json(req)).await.unwrap();

        let session = state.voice_sessions.get("test-resp").await.unwrap();
        assert_eq!(session.state, crate::voice_session::VoiceSessionState::ResponseReady);
        assert_eq!(session.response, Some("Done!".to_string()));
    }

    #[tokio::test]
    async fn test_multiple_transcriptions_accumulated() {
        let state = create_test_state();
        state.voice_sessions.create(
            "test-multi".to_string(),
            "atem-1".to_string(),
            "channel-1".to_string(),
        ).await;

        state.voice_sessions.add_transcription("test-multi", "Please".to_string()).await;
        state.voice_sessions.add_transcription("test-multi", "create".to_string()).await;
        state.voice_sessions.add_transcription("test-multi", "a function".to_string()).await;

        let result = trigger_voice_session_handler(
            State(state),
            Path("test-multi".to_string()),
        ).await;

        assert!(result.is_ok());
        let response = result.unwrap().0;
        assert_eq!(response.accumulated_text, "Please create a function");
    }
}
