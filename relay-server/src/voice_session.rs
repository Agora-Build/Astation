use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{oneshot, RwLock};

use crate::cluster::StoreError;

/// Cap on a voice session's transcript buffer (it was unbounded).
pub const MAX_VOICE_BUFFER_BYTES: usize = 64 * 1024;

/// The last `max` bytes of `text`, cut at a character boundary.
pub fn tail_within(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

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
    pub buffer: Vec<String>,      // Accumulated transcriptions
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

    /// Add transcription chunk to buffer. The buffer keeps its newest chunks
    /// within MAX_VOICE_BUFFER_BYTES.
    pub fn add_transcription(&mut self, text: String) {
        self.buffer
            .push(tail_within(&text, MAX_VOICE_BUFFER_BYTES).to_string());
        let mut total: usize = self.buffer.iter().map(String::len).sum();
        while total > MAX_VOICE_BUFFER_BYTES && self.buffer.len() > 1 {
            total -= self.buffer.remove(0).len();
        }
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

/// How a wait for the Atem's answer ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaitOutcome {
    Reply(String),
    TimedOut,
    /// The waiter was dropped without an answer.
    Closed,
}

/// Local `/api/llm/chat` requests waiting for an answer, by session id.
/// In-memory mode wakes them directly; Redis mode wakes them from the
/// `relay:voice-reply:<id>` channel.
#[derive(Clone, Default)]
pub struct ReplyWaiters {
    waiters: Arc<std::sync::Mutex<HashMap<String, Vec<oneshot::Sender<String>>>>>,
}

impl ReplyWaiters {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Vec<oneshot::Sender<String>>>> {
        self.waiters.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn register(&self, session_id: &str) -> oneshot::Receiver<String> {
        let (tx, rx) = oneshot::channel();
        self.lock()
            .entry(session_id.to_string())
            .or_default()
            .push(tx);
        rx
    }

    /// Hand `reply` to every waiter of `session_id`; returns how many.
    pub fn wake(&self, session_id: &str, reply: &str) -> usize {
        let senders = self.lock().remove(session_id).unwrap_or_default();
        let count = senders.len();
        for sender in senders {
            let _ = sender.send(reply.to_string());
        }
        count
    }

    /// Whether any request still waits on `session_id`.
    #[cfg(test)]
    pub(crate) fn is_waiting(&self, session_id: &str) -> bool {
        self.lock().contains_key(session_id)
    }

    /// Drop waiters whose request is gone (timed out).
    pub fn prune(&self, session_id: &str) {
        let mut waiters = self.lock();
        if let Some(senders) = waiters.get_mut(session_id) {
            senders.retain(|sender| !sender.is_closed());
            if senders.is_empty() {
                waiters.remove(session_id);
            }
        }
    }
}

#[async_trait]
pub trait VoiceBackend: Send + Sync {
    async fn create(&self, session: VoiceSession) -> Result<(), StoreError>;
    async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError>;
    async fn add_transcription(
        &self,
        session_id: &str,
        text: String,
    ) -> Result<Option<()>, StoreError>;
    async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError>;
    async fn set_response(
        &self,
        session_id: &str,
        response: String,
    ) -> Result<Option<()>, StoreError>;
    async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError>;
    async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError>;
    async fn delete(&self, session_id: &str) -> Result<(), StoreError>;
    async fn cleanup_expired(&self) -> Result<(), StoreError>;
    async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError>;
    async fn list_session_ids(&self) -> Result<Vec<String>, StoreError>;
    /// Wait up to `timeout` for the Atem's answer. The waiter is registered
    /// before an already-arrived answer is checked, so none slips through.
    async fn wait_reply(
        &self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<WaitOutcome, StoreError>;
}

#[derive(Clone, Default)]
pub struct InMemoryVoiceBackend {
    sessions: Arc<RwLock<HashMap<String, VoiceSession>>>,
    waiters: ReplyWaiters,
}

impl InMemoryVoiceBackend {
    #[cfg(test)]
    pub(crate) async fn age_for_test(&self, session_id: &str, seconds: i64) {
        if let Some(session) = self.sessions.write().await.get_mut(session_id) {
            session.last_activity = Utc::now() - chrono::Duration::seconds(seconds);
        }
    }
}

#[async_trait]
impl VoiceBackend for InMemoryVoiceBackend {
    async fn create(&self, session: VoiceSession) -> Result<(), StoreError> {
        self.sessions
            .write()
            .await
            .insert(session.session_id.clone(), session);
        Ok(())
    }

    async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
        Ok(self.sessions.read().await.get(session_id).cloned())
    }

    async fn add_transcription(
        &self,
        session_id: &str,
        text: String,
    ) -> Result<Option<()>, StoreError> {
        Ok(self
            .sessions
            .write()
            .await
            .get_mut(session_id)
            .map(|session| session.add_transcription(text)))
    }

    async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
        Ok(self
            .sessions
            .write()
            .await
            .get_mut(session_id)
            .map(|session| {
                session.trigger();
                session.get_accumulated_text()
            }))
    }

    async fn set_response(
        &self,
        session_id: &str,
        response: String,
    ) -> Result<Option<()>, StoreError> {
        {
            let mut sessions = self.sessions.write().await;
            let Some(session) = sessions.get_mut(session_id) else {
                tracing::warn!(
                    "Attempted to set response for nonexistent session: {}",
                    session_id
                );
                return Ok(None);
            };
            session.set_response(response.clone());
        }
        let woken = self.waiters.wake(session_id, &response);
        if woken > 0 {
            tracing::info!(
                "Woke {} waiting LLM requests for session {}",
                woken,
                session_id
            );
        }
        Ok(Some(()))
    }

    async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
        Ok(self
            .sessions
            .write()
            .await
            .get_mut(session_id)
            .map(|session| {
                session.increment_requests();
                session.request_count
            }))
    }

    async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError> {
        Ok(self
            .sessions
            .read()
            .await
            .get(session_id)
            .map(|session| session.state.clone()))
    }

    async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
        self.sessions.write().await.remove(session_id);
        Ok(())
    }

    async fn cleanup_expired(&self) -> Result<(), StoreError> {
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
        Ok(())
    }

    async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
        Ok(self
            .sessions
            .read()
            .await
            .values()
            .filter(|session| session.atem_id == atem_id)
            .cloned()
            .collect())
    }

    async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
        Ok(self.sessions.read().await.keys().cloned().collect())
    }

    async fn wait_reply(
        &self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<WaitOutcome, StoreError> {
        let receiver = self.waiters.register(session_id);
        let arrived = self
            .sessions
            .read()
            .await
            .get(session_id)
            .filter(|session| session.state == VoiceSessionState::ResponseReady)
            .and_then(|session| session.response.clone());
        if let Some(reply) = arrived {
            drop(receiver);
            self.waiters.prune(session_id);
            return Ok(WaitOutcome::Reply(reply));
        }
        let outcome = match tokio::time::timeout(timeout, receiver).await {
            Ok(Ok(reply)) => WaitOutcome::Reply(reply),
            Ok(Err(_)) => WaitOutcome::Closed,
            Err(_) => WaitOutcome::TimedOut,
        };
        self.waiters.prune(session_id);
        Ok(outcome)
    }
}

/// Voice sessions, shared by the voice routes and the LLM proxy.
#[derive(Clone)]
pub struct VoiceSessionStore {
    backend: Arc<dyn VoiceBackend>,
}

impl VoiceSessionStore {
    pub fn new() -> Self {
        Self::with_backend(Arc::new(InMemoryVoiceBackend::default()))
    }

    pub fn with_backend(backend: Arc<dyn VoiceBackend>) -> Self {
        Self { backend }
    }

    /// Create a new voice session
    pub async fn create(
        &self,
        session_id: String,
        atem_id: String,
        channel: String,
    ) -> Result<VoiceSession, StoreError> {
        let session = VoiceSession::new(session_id.clone(), atem_id, channel);
        self.backend.create(session.clone()).await?;
        tracing::info!("Created voice session: {}", session_id);
        Ok(session)
    }

    pub async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
        self.backend.get(session_id).await
    }

    pub async fn add_transcription(
        &self,
        session_id: &str,
        text: String,
    ) -> Result<Option<()>, StoreError> {
        self.backend.add_transcription(session_id, text).await
    }

    pub async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
        self.backend.trigger(session_id).await
    }

    pub async fn set_response(
        &self,
        session_id: &str,
        response: String,
    ) -> Result<Option<()>, StoreError> {
        self.backend.set_response(session_id, response).await
    }

    pub async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
        self.backend.increment_requests(session_id).await
    }

    pub async fn get_state(
        &self,
        session_id: &str,
    ) -> Result<Option<VoiceSessionState>, StoreError> {
        self.backend.get_state(session_id).await
    }

    pub async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
        self.backend.delete(session_id).await?;
        tracing::info!("Deleted voice session: {}", session_id);
        Ok(())
    }

    pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
        self.backend.cleanup_expired().await
    }

    pub async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
        self.backend.get_by_atem(atem_id).await
    }

    pub async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
        self.backend.list_session_ids().await
    }

    pub async fn wait_reply(
        &self,
        session_id: &str,
        timeout: Duration,
    ) -> Result<WaitOutcome, StoreError> {
        self.backend.wait_reply(session_id, timeout).await
    }
}

impl Default for VoiceSessionStore {
    fn default() -> Self {
        Self::new()
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
pub(crate) mod tests {
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
        let session = store
            .create(
                "test-123".to_string(),
                "atem-456".to_string(),
                "channel-789".to_string(),
            )
            .await
            .unwrap();

        let retrieved = store.get("test-123").await.unwrap().unwrap();
        assert_eq!(retrieved.session_id, session.session_id);
        assert_eq!(retrieved.atem_id, session.atem_id);
    }

    #[tokio::test]
    async fn store_add_transcription() {
        let store = VoiceSessionStore::new();
        store
            .create(
                "test".to_string(),
                "atem".to_string(),
                "channel".to_string(),
            )
            .await
            .unwrap();

        store
            .add_transcription("test", "Hello".to_string())
            .await
            .unwrap();
        store
            .add_transcription("test", "world".to_string())
            .await
            .unwrap();

        let session = store.get("test").await.unwrap().unwrap();
        assert_eq!(session.get_accumulated_text(), "Hello world");
    }

    #[tokio::test]
    async fn store_trigger() {
        let store = VoiceSessionStore::new();
        store
            .create(
                "test".to_string(),
                "atem".to_string(),
                "channel".to_string(),
            )
            .await
            .unwrap();

        store
            .add_transcription("test", "Create a function".to_string())
            .await
            .unwrap();
        let text = store.trigger("test").await.unwrap().unwrap();

        assert_eq!(text, "Create a function");
        let session = store.get("test").await.unwrap().unwrap();
        assert_eq!(session.state, VoiceSessionState::Triggered);
    }

    #[tokio::test]
    async fn store_set_response() {
        let store = VoiceSessionStore::new();
        store
            .create(
                "test".to_string(),
                "atem".to_string(),
                "channel".to_string(),
            )
            .await
            .unwrap();

        store
            .set_response("test", "Here's the response".to_string())
            .await
            .unwrap();

        let session = store.get("test").await.unwrap().unwrap();
        assert_eq!(session.state, VoiceSessionState::ResponseReady);
        assert_eq!(session.response, Some("Here's the response".to_string()));
    }

    #[tokio::test]
    async fn store_get_by_atem() {
        let store = VoiceSessionStore::new();
        store
            .create(
                "test1".to_string(),
                "atem-1".to_string(),
                "channel-1".to_string(),
            )
            .await
            .unwrap();
        store
            .create(
                "test2".to_string(),
                "atem-1".to_string(),
                "channel-2".to_string(),
            )
            .await
            .unwrap();
        store
            .create(
                "test3".to_string(),
                "atem-2".to_string(),
                "channel-3".to_string(),
            )
            .await
            .unwrap();

        let atem1_sessions = store.get_by_atem("atem-1").await.unwrap();
        assert_eq!(atem1_sessions.len(), 2);

        let atem2_sessions = store.get_by_atem("atem-2").await.unwrap();
        assert_eq!(atem2_sessions.len(), 1);
    }

    #[tokio::test]
    async fn store_increment_requests() {
        let store = VoiceSessionStore::new();
        store
            .create(
                "test".to_string(),
                "atem".to_string(),
                "channel".to_string(),
            )
            .await
            .unwrap();

        let count1 = store.increment_requests("test").await.unwrap().unwrap();
        assert_eq!(count1, 1);

        let count2 = store.increment_requests("test").await.unwrap().unwrap();
        assert_eq!(count2, 2);
    }

    #[tokio::test]
    async fn waiter_mechanism() {
        scenarios::reply_wakes_a_waiter(VoiceSessionStore::new()).await;
    }

    #[tokio::test]
    async fn store_delete_removes_session() {
        let store = VoiceSessionStore::new();
        store
            .create("test".to_string(), "atem".to_string(), "ch".to_string())
            .await
            .unwrap();
        assert!(store.get("test").await.unwrap().is_some());

        store.delete("test").await.unwrap();
        assert!(store.get("test").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn store_delete_nonexistent_is_silent() {
        let store = VoiceSessionStore::new();
        // Should not panic
        store.delete("nonexistent").await.unwrap();
    }

    #[tokio::test]
    async fn store_trigger_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.trigger("nonexistent").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_set_response_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store
            .set_response("nonexistent", "resp".to_string())
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_add_transcription_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store
            .add_transcription("nonexistent", "text".to_string())
            .await
            .unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_increment_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.increment_requests("nonexistent").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_get_state_nonexistent_returns_none() {
        let store = VoiceSessionStore::new();
        let result = store.get_state("nonexistent").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn store_cleanup_expired_removes_old_sessions() {
        let backend = InMemoryVoiceBackend::default();
        let store = VoiceSessionStore::with_backend(std::sync::Arc::new(backend.clone()));
        store
            .create("fresh".to_string(), "atem".to_string(), "ch".to_string())
            .await
            .unwrap();
        backend.age_for_test("fresh", 120).await;
        store.cleanup_expired().await.unwrap();
        assert!(store.get("fresh").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn store_cleanup_preserves_active_sessions() {
        let store = VoiceSessionStore::new();
        store
            .create("active".to_string(), "atem".to_string(), "ch".to_string())
            .await
            .unwrap();

        store.cleanup_expired().await.unwrap();
        assert!(store.get("active").await.unwrap().is_some());
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
        scenarios::multiple_waiters_all_notified(VoiceSessionStore::new()).await;
    }

    #[tokio::test]
    async fn wait_reply_returns_an_answer_that_arrived_first() {
        scenarios::answer_that_arrived_first_is_returned(VoiceSessionStore::new()).await;
    }

    #[tokio::test(start_paused = true)]
    async fn wait_reply_times_out() {
        assert_eq!(crate::llm_proxy::LLM_WAIT_SECS, 30);
        scenarios::wait_times_out_after(
            VoiceSessionStore::new(),
            std::time::Duration::from_secs(crate::llm_proxy::LLM_WAIT_SECS),
        )
        .await;
    }

    #[tokio::test]
    async fn early_wait_reply_leaves_no_waiter_behind() {
        let backend = InMemoryVoiceBackend::default();
        let store = VoiceSessionStore::with_backend(std::sync::Arc::new(backend.clone()));
        scenarios::early_reply_leaves_no_waiter_behind(store, &backend.waiters).await;
    }

    #[tokio::test]
    async fn stale_reply_never_answers_a_new_turn() {
        scenarios::stale_reply_never_answers_a_new_turn(VoiceSessionStore::new()).await;
    }

    #[test]
    fn transcript_buffer_is_capped_at_64_kb() {
        let mut session = VoiceSession::new("cap".into(), "atem".into(), "ch".into());
        let chunk = "x".repeat(1024);
        for _ in 0..70 {
            session.add_transcription(chunk.clone());
        }
        let total: usize = session.buffer.iter().map(String::len).sum();
        assert!(total <= MAX_VOICE_BUFFER_BYTES);
        assert_eq!(session.buffer.len(), 64);
        session.add_transcription("the latest words".to_string());
        assert_eq!(
            session.buffer.last().map(String::as_str),
            Some("the latest words")
        );

        let mut big = VoiceSession::new("big".into(), "atem".into(), "ch".into());
        big.add_transcription(format!("{}é{}", "a".repeat(70_000), "tail"));
        assert_eq!(big.buffer.len(), 1);
        assert!(big.buffer[0].len() <= MAX_VOICE_BUFFER_BYTES);
        assert!(big.buffer[0].ends_with("étail"));
    }

    #[test]
    fn tail_within_cuts_at_a_character_boundary() {
        assert_eq!(tail_within("hello", 10), "hello");
        assert_eq!(tail_within("hello", 3), "llo");
        assert_eq!(tail_within("日本語", 4), "語");
    }

    /// Shared wait scenarios: the in-memory tests and the Redis suite both
    /// run these, so the two backends stay interchangeable.
    pub(crate) mod scenarios {
        use super::*;

        pub(crate) async fn reply_wakes_a_waiter(store: VoiceSessionStore) {
            store
                .create(
                    "test".to_string(),
                    "atem".to_string(),
                    "channel".to_string(),
                )
                .await
                .unwrap();
            tokio::spawn({
                let store = store.clone();
                async move {
                    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
                    store
                        .set_response("test", "Response!".to_string())
                        .await
                        .unwrap();
                }
            });
            let result = store
                .wait_reply("test", std::time::Duration::from_secs(5))
                .await
                .unwrap();
            assert_eq!(result, WaitOutcome::Reply("Response!".to_string()));
        }

        pub(crate) async fn multiple_waiters_all_notified(store: VoiceSessionStore) {
            store
                .create("test".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            let wait = std::time::Duration::from_secs(5);
            let (a, b, _) = tokio::join!(
                store.wait_reply("test", wait),
                store.wait_reply("test", wait),
                async {
                    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
                    store
                        .set_response("test", "Response!".to_string())
                        .await
                        .unwrap();
                }
            );
            assert_eq!(a.unwrap(), WaitOutcome::Reply("Response!".to_string()));
            assert_eq!(b.unwrap(), WaitOutcome::Reply("Response!".to_string()));
        }

        pub(crate) async fn answer_that_arrived_first_is_returned(store: VoiceSessionStore) {
            store
                .create("early".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            store
                .set_response("early", "already here".to_string())
                .await
                .unwrap();
            let result = store
                .wait_reply("early", std::time::Duration::from_millis(50))
                .await
                .unwrap();
            assert_eq!(result, WaitOutcome::Reply("already here".to_string()));
        }

        pub(crate) async fn wait_times_out_after(
            store: VoiceSessionStore,
            timeout: std::time::Duration,
        ) {
            store
                .create("slow".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            let started = tokio::time::Instant::now();
            let result = store.wait_reply("slow", timeout).await.unwrap();
            assert_eq!(result, WaitOutcome::TimedOut);
            let elapsed = started.elapsed();
            assert!(elapsed >= timeout, "timed out early: {elapsed:?}");
            assert!(
                elapsed < timeout + std::time::Duration::from_secs(2),
                "timed out late: {elapsed:?}"
            );
        }

        pub(crate) async fn early_reply_leaves_no_waiter_behind(
            store: VoiceSessionStore,
            waiters: &ReplyWaiters,
        ) {
            store
                .create("early2".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            store
                .set_response("early2", "here".to_string())
                .await
                .unwrap();
            let result = store
                .wait_reply("early2", std::time::Duration::from_millis(50))
                .await
                .unwrap();
            assert_eq!(result, WaitOutcome::Reply("here".to_string()));
            assert!(!waiters.is_waiting("early2"));
            // A wait that times out leaves none behind either.
            store
                .create("quiet".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            let result = store
                .wait_reply("quiet", std::time::Duration::from_millis(50))
                .await
                .unwrap();
            assert_eq!(result, WaitOutcome::TimedOut);
            assert!(!waiters.is_waiting("quiet"));
        }

        /// The answer to turn one must not answer turn two: the new trigger
        /// waits for a new answer.
        pub(crate) async fn stale_reply_never_answers_a_new_turn(store: VoiceSessionStore) {
            store
                .create("turns".to_string(), "atem".to_string(), "ch".to_string())
                .await
                .unwrap();
            store.trigger("turns").await.unwrap();
            store
                .set_response("turns", "first".to_string())
                .await
                .unwrap();
            assert_eq!(
                store
                    .wait_reply("turns", std::time::Duration::from_millis(50))
                    .await
                    .unwrap(),
                WaitOutcome::Reply("first".to_string())
            );

            store
                .add_transcription("turns", "next".to_string())
                .await
                .unwrap();
            store.trigger("turns").await.unwrap();
            // Longer than one Redis re-read interval, so the poll runs too.
            assert_eq!(
                store
                    .wait_reply("turns", std::time::Duration::from_millis(1500))
                    .await
                    .unwrap(),
                WaitOutcome::TimedOut
            );

            let (second, _) = tokio::join!(
                store.wait_reply("turns", std::time::Duration::from_secs(5)),
                async {
                    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
                    store
                        .set_response("turns", "second".to_string())
                        .await
                        .unwrap();
                }
            );
            assert_eq!(second.unwrap(), WaitOutcome::Reply("second".to_string()));
        }
    }
}
