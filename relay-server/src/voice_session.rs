use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{oneshot, RwLock};
use chrono::{DateTime, Utc};

/// Voice session state machine for LLM request accumulation
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum VoiceSessionState {
    /// Accumulating transcriptions, returning empty responses
    Accumulating,
    /// Trigger received, waiting for Atem to send LLM response
    Triggered,
    /// LLM response ready to be returned to Agora
    ResponseReady,
}

/// A voice coding session that accumulates transcriptions until triggered
#[derive(Debug, Clone)]
pub struct VoiceSession {
    pub session_id: String,
    pub atem_id: String,
    pub channel: String,
    pub state: VoiceSessionState,
    pub buffer: Vec<String>, // Accumulated transcriptions
    pub response: Option<String>, // LLM response from Atem
    pub created_at: DateTime<Utc>,
    pub last_activity: DateTime<Utc>,
    pub request_count: u32,
}

impl VoiceSession {
    pub fn new(session_id: String, atem_id: String, channel: String) -> Self {
        let now = Utc::now();
        Self {
            session_id,
            atem_id,
            channel,
            state: VoiceSessionState::Accumulating,
            buffer: Vec::new(),
            response: None,
            created_at: now,
            last_activity: now,
            request_count: 0,
        }
    }

    /// Add transcription chunk to buffer
    pub fn add_transcription(&mut self, text: String) {
        self.buffer.push(text);
        self.last_activity = Utc::now();
    }

    /// Get accumulated transcription as single string
    pub fn get_accumulated_text(&self) -> String {
        self.buffer.join(" ")
    }

    /// Mark session as triggered (user pressed hotkey or timeout)
    pub fn trigger(&mut self) {
        self.state = VoiceSessionState::Triggered;
        self.last_activity = Utc::now();
    }

    /// Set LLM response and mark as ready
    pub fn set_response(&mut self, response: String) {
        self.response = Some(response);
        self.state = VoiceSessionState::ResponseReady;
        self.last_activity = Utc::now();
    }

    /// Check if session is expired (60 seconds of inactivity)
    pub fn is_expired(&self) -> bool {
        let now = Utc::now();
        let elapsed = now.signed_duration_since(self.last_activity);
        elapsed.num_seconds() > 60
    }

    /// Increment request counter
    pub fn increment_requests(&mut self) {
        self.request_count += 1;
    }
}

/// Store for managing multiple voice sessions
#[derive(Clone)]
pub struct VoiceSessionStore {
    sessions: Arc<RwLock<HashMap<String, VoiceSession>>>,
    // Map session_id -> oneshot sender for blocking /api/llm/chat requests
    waiters: Arc<RwLock<HashMap<String, Vec<oneshot::Sender<String>>>>>,
}

impl VoiceSessionStore {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            waiters: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Create a new voice session
    pub async fn create(&self, session_id: String, atem_id: String, channel: String) -> VoiceSession {
        let session = VoiceSession::new(session_id.clone(), atem_id, channel);
        let mut sessions = self.sessions.write().await;
        sessions.insert(session_id.clone(), session.clone());
        tracing::info!("Created voice session: {}", session_id);
        session
    }

    /// Get session by ID
    pub async fn get(&self, session_id: &str) -> Option<VoiceSession> {
        let sessions = self.sessions.read().await;
        sessions.get(session_id).cloned()
    }

    /// Add transcription to session buffer
    pub async fn add_transcription(&self, session_id: &str, text: String) -> Option<()> {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(session_id) {
            session.add_transcription(text);
            Some(())
        } else {
            None
        }
    }

    /// Trigger session (user pressed hotkey or timeout)
    pub async fn trigger(&self, session_id: &str) -> Option<String> {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(session_id) {
            session.trigger();
            Some(session.get_accumulated_text())
        } else {
            None
        }
    }

    /// Set LLM response for session (called by Atem)
    pub async fn set_response(&self, session_id: &str, response: String) -> Option<()> {
        // Update session state
        {
            let mut sessions = self.sessions.write().await;
            if let Some(session) = sessions.get_mut(session_id) {
                session.set_response(response.clone());
            } else {
                tracing::warn!("Attempted to set response for nonexistent session: {}", session_id);
                return None;
            }
        }

        // Wake up any waiting /api/llm/chat requests
        let mut waiters = self.waiters.write().await;
        if let Some(senders) = waiters.remove(session_id) {
            tracing::info!("Waking {} waiting LLM requests for session {}", senders.len(), session_id);
            for sender in senders {
                let _ = sender.send(response.clone());
            }
        }

        Some(())
    }

    /// Register a waiter for LLM response (blocking /api/llm/chat request)
    pub async fn register_waiter(&self, session_id: String) -> oneshot::Receiver<String> {
        let (tx, rx) = oneshot::channel();
        let mut waiters = self.waiters.write().await;
        waiters.entry(session_id).or_insert_with(Vec::new).push(tx);
        rx
    }

    /// Increment request counter for session
    pub async fn increment_requests(&self, session_id: &str) -> Option<u32> {
        let mut sessions = self.sessions.write().await;
        if let Some(session) = sessions.get_mut(session_id) {
            session.increment_requests();
            Some(session.request_count)
        } else {
            None
        }
    }

    /// Get session state
    pub async fn get_state(&self, session_id: &str) -> Option<VoiceSessionState> {
        let sessions = self.sessions.read().await;
        sessions.get(session_id).map(|s| s.state.clone())
    }

    /// Delete session
    pub async fn delete(&self, session_id: &str) {
        let mut sessions = self.sessions.write().await;
        sessions.remove(session_id);
        tracing::info!("Deleted voice session: {}", session_id);
    }

    /// Cleanup expired sessions (called by background task)
    pub async fn cleanup_expired(&self) {
        let mut sessions = self.sessions.write().await;
        let expired: Vec<String> = sessions
            .iter()
            .filter(|(_, session)| session.is_expired())
            .map(|(id, _)| id.clone())
            .collect();

        for session_id in expired {
            sessions.remove(&session_id);
            tracing::info!("Cleaned up expired voice session: {}", session_id);
        }
    }

    /// Get all active sessions for an Atem client
    pub async fn get_by_atem(&self, atem_id: &str) -> Vec<VoiceSession> {
        let sessions = self.sessions.read().await;
        sessions
            .values()
            .filter(|s| s.atem_id == atem_id)
            .cloned()
            .collect()
    }

    /// List all session IDs (for debugging)
    pub async fn list_session_ids(&self) -> Vec<String> {
        let sessions = self.sessions.read().await;
        sessions.keys().cloned().collect()
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateVoiceSessionRequest {
    pub atem_id: String,
    pub channel: String,
}

#[derive(Debug, Serialize)]
pub struct CreateVoiceSessionResponse {
    pub session_id: String,
    pub atem_id: String,
    pub channel: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct TriggerRequest {
    // No body needed - session_id is in URL path
}

#[derive(Debug, Serialize)]
pub struct TriggerResponse {
    pub session_id: String,
    pub accumulated_text: String,
    pub atem_id: String,
}

#[derive(Debug, Deserialize)]
pub struct AtemResponseRequest {
    pub session_id: String,
    pub response: String,
}

#[derive(Debug, Serialize)]
pub struct AtemResponseResponse {
    pub success: bool,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voice_session_new() {
        let session = VoiceSession::new(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        );
        assert_eq!(session.session_id, "test-123");
        assert_eq!(session.atem_id, "atem-456");
        assert_eq!(session.channel, "channel-789");
        assert_eq!(session.state, VoiceSessionState::Accumulating);
        assert!(session.buffer.is_empty());
        assert!(session.response.is_none());
    }

    #[test]
    fn voice_session_add_transcription() {
        let mut session = VoiceSession::new(
            "test".to_string(),
            "atem".to_string(),
            "channel".to_string(),
        );
        session.add_transcription("Hello".to_string());
        session.add_transcription("world".to_string());
        assert_eq!(session.buffer.len(), 2);
        assert_eq!(session.get_accumulated_text(), "Hello world");
    }

    #[test]
    fn voice_session_trigger() {
        let mut session = VoiceSession::new(
            "test".to_string(),
            "atem".to_string(),
            "channel".to_string(),
        );
        session.add_transcription("Create a function".to_string());
        session.trigger();
        assert_eq!(session.state, VoiceSessionState::Triggered);
    }

    #[test]
    fn voice_session_set_response() {
        let mut session = VoiceSession::new(
            "test".to_string(),
            "atem".to_string(),
            "channel".to_string(),
        );
        session.set_response("Here's the function...".to_string());
        assert_eq!(session.state, VoiceSessionState::ResponseReady);
        assert_eq!(session.response, Some("Here's the function...".to_string()));
    }

    #[tokio::test]
    async fn store_create_and_get() {
        let store = VoiceSessionStore::new();
        let session = store.create(
            "test-123".to_string(),
            "atem-456".to_string(),
            "channel-789".to_string(),
        ).await;

        let retrieved = store.get("test-123").await.unwrap();
        assert_eq!(retrieved.session_id, session.session_id);
        assert_eq!(retrieved.atem_id, session.atem_id);
    }

    #[tokio::test]
    async fn store_add_transcription() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await;

        store.add_transcription("test", "Hello".to_string()).await;
        store.add_transcription("test", "world".to_string()).await;

        let session = store.get("test").await.unwrap();
        assert_eq!(session.get_accumulated_text(), "Hello world");
    }

    #[tokio::test]
    async fn store_trigger() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await;

        store.add_transcription("test", "Create a function".to_string()).await;
        let text = store.trigger("test").await.unwrap();

        assert_eq!(text, "Create a function");
        let session = store.get("test").await.unwrap();
        assert_eq!(session.state, VoiceSessionState::Triggered);
    }

    #[tokio::test]
    async fn store_set_response() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await;

        store.set_response("test", "Here's the response".to_string()).await;

        let session = store.get("test").await.unwrap();
        assert_eq!(session.state, VoiceSessionState::ResponseReady);
        assert_eq!(session.response, Some("Here's the response".to_string()));
    }

    #[tokio::test]
    async fn store_get_by_atem() {
        let store = VoiceSessionStore::new();
        store.create("test1".to_string(), "atem-1".to_string(), "channel-1".to_string()).await;
        store.create("test2".to_string(), "atem-1".to_string(), "channel-2".to_string()).await;
        store.create("test3".to_string(), "atem-2".to_string(), "channel-3".to_string()).await;

        let atem1_sessions = store.get_by_atem("atem-1").await;
        assert_eq!(atem1_sessions.len(), 2);

        let atem2_sessions = store.get_by_atem("atem-2").await;
        assert_eq!(atem2_sessions.len(), 1);
    }

    #[tokio::test]
    async fn store_increment_requests() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await;

        let count1 = store.increment_requests("test").await.unwrap();
        assert_eq!(count1, 1);

        let count2 = store.increment_requests("test").await.unwrap();
        assert_eq!(count2, 2);
    }

    #[tokio::test]
    async fn waiter_mechanism() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "channel".to_string()).await;

        // Register waiter (simulates blocking /api/llm/chat request)
        let rx = store.register_waiter("test".to_string()).await;

        // Set response (simulates Atem sending response)
        tokio::spawn({
            let store = store.clone();
            async move {
                tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
                store.set_response("test", "Response!".to_string()).await;
            }
        });

        // Wait for response
        let result = rx.await.unwrap();
        assert_eq!(result, "Response!");
    }

    #[tokio::test]
    async fn store_delete_removes_session() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "ch".to_string()).await;
        assert!(store.get("test").await.is_some());

        store.delete("test").await;
        assert!(store.get("test").await.is_none());
    }

    #[tokio::test]
    async fn store_delete_nonexistent_is_silent() {
        let store = VoiceSessionStore::new();
        // Should not panic
        store.delete("nonexistent").await;
    }

    #[tokio::test]
    async fn store_trigger_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.trigger("nonexistent").await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_set_response_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.set_response("nonexistent", "resp".to_string()).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_add_transcription_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.add_transcription("nonexistent", "text".to_string()).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_increment_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.increment_requests("nonexistent").await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_get_state_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.get_state("nonexistent").await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_cleanup_expired_removes_old_sessions() {
        let store = VoiceSessionStore::new();
        store.create("fresh".to_string(), "atem".to_string(), "ch".to_string()).await;

        // Manually age a session by manipulating its last_activity
        {
            let mut sessions = store.sessions.write().await;
            if let Some(session) = sessions.get_mut("fresh") {
                session.last_activity = Utc::now() - chrono::Duration::seconds(120);
            }
        }

        store.cleanup_expired().await;
        assert!(store.get("fresh").await.is_none());
    }

    #[tokio::test]
    async fn store_cleanup_preserves_active_sessions() {
        let store = VoiceSessionStore::new();
        store.create("active".to_string(), "atem".to_string(), "ch".to_string()).await;

        store.cleanup_expired().await;
        assert!(store.get("active").await.is_some());
    }

    #[test]
    fn voice_session_is_expired_after_60s() {
        let mut session = VoiceSession::new(
            "test".to_string(),
            "atem".to_string(),
            "channel".to_string(),
        );
        // Not expired when fresh
        assert!(!session.is_expired());

        // Manually age it
        session.last_activity = Utc::now() - chrono::Duration::seconds(120);
        assert!(session.is_expired());
    }

    #[test]
    fn voice_session_empty_buffer_text() {
        let session = VoiceSession::new(
            "test".to_string(),
            "atem".to_string(),
            "channel".to_string(),
        );
        assert_eq!(session.get_accumulated_text(), "");
    }

    #[tokio::test]
    async fn waiter_multiple_waiters_all_notified() {
        let store = VoiceSessionStore::new();
        store.create("test".to_string(), "atem".to_string(), "ch".to_string()).await;

        let rx1 = store.register_waiter("test".to_string()).await;
        let rx2 = store.register_waiter("test".to_string()).await;

        store.set_response("test", "Response!".to_string()).await;

        assert_eq!(rx1.await.unwrap(), "Response!");
        assert_eq!(rx2.await.unwrap(), "Response!");
    }
}
