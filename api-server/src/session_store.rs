use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::auth::{Session, SessionStatus};
use chrono::Utc;

#[derive(Clone)]
pub struct SessionStore {
    sessions: Arc<RwLock<HashMap<String, Session>>>,
}

impl SessionStore {
    pub fn new() -> Self {
        SessionStore {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn create(&self, session: Session) {
        let id = session.id.clone();
        let mut sessions = self.sessions.write().await;
        sessions.insert(id, session);
    }

    pub async fn get(&self, id: &str) -> Option<Session> {
        let sessions = self.sessions.read().await;
        sessions.get(id).cloned()
    }

    pub async fn update(&self, id: &str, session: Session) {
        let mut sessions = self.sessions.write().await;
        sessions.insert(id.to_string(), session);
    }

    pub async fn delete(&self, id: &str) {
        let mut sessions = self.sessions.write().await;
        sessions.remove(id);
    }

    /// Remove all sessions that have expired and are still pending.
    pub async fn cleanup_expired(&self) {
        let now = Utc::now();
        let mut sessions = self.sessions.write().await;
        sessions.retain(|_, session| {
            if now > session.expires_at && session.status == SessionStatus::Pending {
                false
            } else {
                true
            }
        });
    }
}

impl Default for SessionStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{create_session, SessionStatus};
    use chrono::{Duration, Utc};
    use uuid::Uuid;

    #[tokio::test]
    async fn test_create_and_get_session() {
        let store = SessionStore::new();
        let session = create_session("test-host");
        let id = session.id.clone();

        store.create(session.clone()).await;
        let retrieved = store.get(&id).await;

        assert!(retrieved.is_some());
        let retrieved = retrieved.unwrap();
        assert_eq!(retrieved.id, id);
        assert_eq!(retrieved.hostname, "test-host");
        assert_eq!(retrieved.status, SessionStatus::Pending);
    }

    #[tokio::test]
    async fn test_get_nonexistent_session() {
        let store = SessionStore::new();
        let result = store.get("nonexistent-id").await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_update_session() {
        let store = SessionStore::new();
        let mut session = create_session("test-host");
        let id = session.id.clone();

        store.create(session.clone()).await;

        session.status = SessionStatus::Granted;
        session.token = Some("test-token".to_string());
        store.update(&id, session).await;

        let retrieved = store.get(&id).await.unwrap();
        assert_eq!(retrieved.status, SessionStatus::Granted);
        assert_eq!(retrieved.token, Some("test-token".to_string()));
    }

    #[tokio::test]
    async fn test_delete_session() {
        let store = SessionStore::new();
        let session = create_session("test-host");
        let id = session.id.clone();

        store.create(session).await;
        assert!(store.get(&id).await.is_some());

        store.delete(&id).await;
        assert!(store.get(&id).await.is_none());
    }

    #[tokio::test]
    async fn test_cleanup_expired_sessions() {
        let store = SessionStore::new();
        let now = Utc::now();

        // Create an expired pending session
        let expired_session = Session {
            id: Uuid::new_v4().to_string(),
            otp: "12345678".to_string(),
            hostname: "expired-host".to_string(),
            status: SessionStatus::Pending,
            token: None,
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5),
        };
        let expired_id = expired_session.id.clone();
        store.create(expired_session).await;

        // Create an active session
        let active_session = create_session("active-host");
        let active_id = active_session.id.clone();
        store.create(active_session).await;

        // Create a granted but expired session (should NOT be cleaned up)
        let granted_session = Session {
            id: Uuid::new_v4().to_string(),
            otp: "87654321".to_string(),
            hostname: "granted-host".to_string(),
            status: SessionStatus::Granted,
            token: Some("some-token".to_string()),
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5),
        };
        let granted_id = granted_session.id.clone();
        store.create(granted_session).await;

        store.cleanup_expired().await;

        // Expired pending session should be removed
        assert!(store.get(&expired_id).await.is_none());
        // Active session should remain
        assert!(store.get(&active_id).await.is_some());
        // Granted session should remain (even though expired)
        assert!(store.get(&granted_id).await.is_some());
    }

    #[tokio::test]
    async fn test_session_lifecycle_grant() {
        let store = SessionStore::new();
        let session = create_session("my-machine");
        let id = session.id.clone();
        let otp = session.otp.clone();

        // Create session
        store.create(session).await;

        // Verify pending
        let s = store.get(&id).await.unwrap();
        assert_eq!(s.status, SessionStatus::Pending);
        assert!(s.token.is_none());

        // Grant session
        let mut s = store.get(&id).await.unwrap();
        if crate::auth::validate_otp(&s, &otp) {
            s.status = SessionStatus::Granted;
            s.token = Some(crate::auth::generate_session_token());
            store.update(&id, s).await;
        }

        // Verify granted
        let s = store.get(&id).await.unwrap();
        assert_eq!(s.status, SessionStatus::Granted);
        assert!(s.token.is_some());
        assert_eq!(s.token.as_ref().unwrap().len(), 64);
    }

    #[tokio::test]
    async fn test_session_lifecycle_deny() {
        let store = SessionStore::new();
        let session = create_session("my-machine");
        let id = session.id.clone();

        // Create session
        store.create(session).await;

        // Deny session
        let mut s = store.get(&id).await.unwrap();
        s.status = SessionStatus::Denied;
        store.update(&id, s).await;

        // Verify denied
        let s = store.get(&id).await.unwrap();
        assert_eq!(s.status, SessionStatus::Denied);
        assert!(s.token.is_none());
    }
}
