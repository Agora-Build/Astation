//! Pairing/OTP sessions. In-memory by default; Redis-backed
//! (`relay:session:<id>`) when REDIS_URL is set, so create, grant, poll and
//! the `?session=` WebSocket can each reach a different replica.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use tokio::sync::RwLock;

use crate::auth::{Session, SessionStatus};
use crate::cluster::StoreError;

/// Result of an OTP grant, applied atomically by the backend.
#[derive(Debug, Clone)]
pub enum GrantOutcome {
    NotFound,
    NotPending(SessionStatus),
    Expired,
    InvalidOtp,
    Granted(Session),
}

#[derive(Debug, Clone)]
pub enum DenyOutcome {
    NotFound,
    NotPending(SessionStatus),
    Denied(Session),
}

#[async_trait]
pub trait SessionBackend: Send + Sync {
    async fn create(&self, session: Session) -> Result<(), StoreError>;
    async fn get(&self, id: &str) -> Result<Option<Session>, StoreError>;
    async fn update(&self, id: &str, session: Session) -> Result<(), StoreError>;
    async fn delete(&self, id: &str) -> Result<(), StoreError>;
    /// Pending, unexpired and the OTP matches → granted with `token`.
    async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError>;
    /// Pending → denied.
    async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError>;
    /// A granted session was used (`?session=` WebSocket): keep it alive.
    async fn touch(&self, id: &str) -> Result<(), StoreError>;
    /// Remove expired pending sessions (in-memory; Redis expires keys).
    async fn cleanup_expired(&self) -> Result<(), StoreError>;
}

#[derive(Clone, Default)]
pub struct InMemorySessionBackend {
    sessions: Arc<RwLock<HashMap<String, Session>>>,
}

#[async_trait]
impl SessionBackend for InMemorySessionBackend {
    async fn create(&self, session: Session) -> Result<(), StoreError> {
        self.sessions.write().await.insert(session.id.clone(), session);
        Ok(())
    }

    async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
        Ok(self.sessions.read().await.get(id).cloned())
    }

    async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
        self.sessions.write().await.insert(id.to_string(), session);
        Ok(())
    }

    async fn delete(&self, id: &str) -> Result<(), StoreError> {
        self.sessions.write().await.remove(id);
        Ok(())
    }

    async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError> {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(id) else {
            return Ok(GrantOutcome::NotFound);
        };
        if session.status != SessionStatus::Pending {
            return Ok(GrantOutcome::NotPending(session.status.clone()));
        }
        if now > session.expires_at {
            return Ok(GrantOutcome::Expired);
        }
        if session.otp != otp {
            return Ok(GrantOutcome::InvalidOtp);
        }
        session.status = SessionStatus::Granted;
        session.token = Some(token.to_string());
        Ok(GrantOutcome::Granted(session.clone()))
    }

    async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(id) else {
            return Ok(DenyOutcome::NotFound);
        };
        if session.status != SessionStatus::Pending {
            return Ok(DenyOutcome::NotPending(session.status.clone()));
        }
        session.status = SessionStatus::Denied;
        Ok(DenyOutcome::Denied(session.clone()))
    }

    async fn touch(&self, _id: &str) -> Result<(), StoreError> {
        Ok(())
    }

    /// Remove all sessions that have expired and are still pending.
    async fn cleanup_expired(&self) -> Result<(), StoreError> {
        let now = Utc::now();
        self.sessions
            .write()
            .await
            .retain(|_, session| !(now > session.expires_at && session.status == SessionStatus::Pending));
        Ok(())
    }
}

/// Pairing/OTP sessions, shared by every route that uses them.
#[derive(Clone)]
pub struct SessionStore {
    backend: Arc<dyn SessionBackend>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self::with_backend(Arc::new(InMemorySessionBackend::default()))
    }

    pub fn with_backend(backend: Arc<dyn SessionBackend>) -> Self {
        Self { backend }
    }

    pub async fn create(&self, session: Session) -> Result<(), StoreError> {
        self.backend.create(session).await
    }

    pub async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
        self.backend.get(id).await
    }

    pub async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
        self.backend.update(id, session).await
    }

    pub async fn delete(&self, id: &str) -> Result<(), StoreError> {
        self.backend.delete(id).await
    }

    /// Validate the OTP and grant with a fresh session token, atomically.
    pub async fn grant(&self, id: &str, otp: &str) -> Result<GrantOutcome, StoreError> {
        let token = crate::auth::generate_session_token();
        self.backend.grant(id, otp, &token, Utc::now()).await
    }

    pub async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
        self.backend.deny(id).await
    }

    pub async fn touch(&self, id: &str) -> Result<(), StoreError> {
        self.backend.touch(id).await
    }

    pub async fn cleanup_expired(&self) -> Result<(), StoreError> {
        self.backend.cleanup_expired().await
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

        store.create(session.clone()).await.unwrap();
        let retrieved = store.get(&id).await.unwrap();

        assert!(retrieved.is_some());
        let retrieved = retrieved.unwrap();
        assert_eq!(retrieved.id, id);
        assert_eq!(retrieved.hostname, "test-host");
        assert_eq!(retrieved.status, SessionStatus::Pending);
    }

    #[tokio::test]
    async fn test_get_nonexistent_session() {
        let store = SessionStore::new();
        let result = store.get("nonexistent-id").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_update_session() {
        let store = SessionStore::new();
        let mut session = create_session("test-host");
        let id = session.id.clone();

        store.create(session.clone()).await.unwrap();

        session.status = SessionStatus::Granted;
        session.token = Some("test-token".to_string());
        store.update(&id, session).await.unwrap();

        let retrieved = store.get(&id).await.unwrap().unwrap();
        assert_eq!(retrieved.status, SessionStatus::Granted);
        assert_eq!(retrieved.token, Some("test-token".to_string()));
    }

    #[tokio::test]
    async fn test_delete_session() {
        let store = SessionStore::new();
        let session = create_session("test-host");
        let id = session.id.clone();

        store.create(session).await.unwrap();
        assert!(store.get(&id).await.unwrap().is_some());

        store.delete(&id).await.unwrap();
        assert!(store.get(&id).await.unwrap().is_none());
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
            astation_id: None,
        };
        let expired_id = expired_session.id.clone();
        store.create(expired_session).await.unwrap();

        // Create an active session
        let active_session = create_session("active-host");
        let active_id = active_session.id.clone();
        store.create(active_session).await.unwrap();

        // Create a granted but expired session (should NOT be cleaned up)
        let granted_session = Session {
            id: Uuid::new_v4().to_string(),
            otp: "87654321".to_string(),
            hostname: "granted-host".to_string(),
            status: SessionStatus::Granted,
            token: Some("some-token".to_string()),
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5),
            astation_id: None,
        };
        let granted_id = granted_session.id.clone();
        store.create(granted_session).await.unwrap();

        store.cleanup_expired().await.unwrap();

        // Expired pending session should be removed
        assert!(store.get(&expired_id).await.unwrap().is_none());
        // Active session should remain
        assert!(store.get(&active_id).await.unwrap().is_some());
        // Granted session should remain (even though expired)
        assert!(store.get(&granted_id).await.unwrap().is_some());
    }

    #[tokio::test]
    async fn test_session_lifecycle_grant() {
        let store = SessionStore::new();
        let session = create_session("my-machine");
        let id = session.id.clone();
        let otp = session.otp.clone();

        // Create session
        store.create(session).await.unwrap();

        // Verify pending
        let s = store.get(&id).await.unwrap().unwrap();
        assert_eq!(s.status, SessionStatus::Pending);
        assert!(s.token.is_none());

        // Grant session
        let mut s = store.get(&id).await.unwrap().unwrap();
        if crate::auth::validate_otp(&s, &otp) {
            s.status = SessionStatus::Granted;
            s.token = Some(crate::auth::generate_session_token());
            store.update(&id, s).await.unwrap();
        }

        // Verify granted
        let s = store.get(&id).await.unwrap().unwrap();
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
        store.create(session).await.unwrap();

        // Deny session
        let mut s = store.get(&id).await.unwrap().unwrap();
        s.status = SessionStatus::Denied;
        store.update(&id, s).await.unwrap();

        // Verify denied
        let s = store.get(&id).await.unwrap().unwrap();
        assert_eq!(s.status, SessionStatus::Denied);
        assert!(s.token.is_none());
    }

    #[tokio::test]
    async fn grant_is_atomic_and_checks_in_order() {
        let store = SessionStore::new();
        let session = create_session("grant-host");
        let id = session.id.clone();
        let otp = session.otp.clone();
        store.create(session).await.unwrap();

        assert!(matches!(store.grant("missing", &otp).await.unwrap(), GrantOutcome::NotFound));
        assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::InvalidOtp));
        let granted = match store.grant(&id, &otp).await.unwrap() {
            GrantOutcome::Granted(session) => session,
            other => panic!("expected Granted, got {other:?}"),
        };
        assert_eq!(granted.status, SessionStatus::Granted);
        assert_eq!(granted.token.as_ref().map(String::len), Some(64));
        assert!(matches!(
            store.grant(&id, &otp).await.unwrap(),
            GrantOutcome::NotPending(SessionStatus::Granted)
        ));
        assert!(matches!(
            store.deny(&id).await.unwrap(),
            DenyOutcome::NotPending(SessionStatus::Granted)
        ));
    }

    #[tokio::test]
    async fn grant_of_an_expired_session_is_expired_even_with_the_right_otp() {
        let store = SessionStore::new();
        let now = Utc::now();
        let expired = Session {
            id: Uuid::new_v4().to_string(),
            otp: "12345678".to_string(),
            hostname: "late".to_string(),
            status: SessionStatus::Pending,
            token: None,
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5),
            astation_id: None,
        };
        let id = expired.id.clone();
        store.create(expired).await.unwrap();
        assert!(matches!(store.grant(&id, "12345678").await.unwrap(), GrantOutcome::Expired));
        assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::Expired));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_grants_apply_once() {
        let store = SessionStore::new();
        let session = create_session("race-host");
        let (id, otp) = (session.id.clone(), session.otp.clone());
        store.create(session).await.unwrap();
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let (store, id, otp) = (store.clone(), id.clone(), otp.clone());
                tokio::spawn(async move { store.grant(&id, &otp).await.unwrap() })
            })
            .collect();
        let mut granted = 0;
        for handle in handles {
            if matches!(handle.await.unwrap(), GrantOutcome::Granted(_)) {
                granted += 1;
            }
        }
        assert_eq!(granted, 1);
    }

    #[tokio::test]
    async fn deny_applies_only_while_pending() {
        let store = SessionStore::new();
        let session = create_session("deny-host");
        let id = session.id.clone();
        store.create(session).await.unwrap();
        assert!(matches!(store.deny("missing").await.unwrap(), DenyOutcome::NotFound));
        match store.deny(&id).await.unwrap() {
            DenyOutcome::Denied(session) => assert_eq!(session.status, SessionStatus::Denied),
            other => panic!("expected Denied, got {other:?}"),
        }
        assert!(matches!(
            store.deny(&id).await.unwrap(),
            DenyOutcome::NotPending(SessionStatus::Denied)
        ));
    }
}
