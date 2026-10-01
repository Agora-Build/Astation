//! Pairing/OTP sessions in Redis (`relay:session:<id>` hash). Grant and
//! deny are Lua scripts that apply only while the session is pending, so
//! two concurrent clicks on different replicas can't both apply.

use std::collections::HashMap;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use redis::Script;

use super::{keys, RedisConn};
use crate::auth::{Session, SessionStatus};
use crate::cluster::StoreError;
use crate::session_store::{DenyOutcome, GrantOutcome, SessionBackend};

/// A pending session stays this long after it expires, so polls still see
/// `expired` (and grants `410`) as they did before the 60 s sweep.
pub const PENDING_GRACE_SECS: i64 = 60;

/// Granted and denied sessions: a week, refreshed on each `?session=` use.
pub const DECIDED_SESSION_TTL_SECS: i64 = 7 * 24 * 60 * 60;

// KEYS[1]; ARGV: otp, now_ms, token, decided_ttl
const GRANT: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
local status = redis.call('HGET', KEYS[1], 'status')
if status ~= 'pending' then return {'not_pending', status} end
if tonumber(ARGV[2]) > tonumber(redis.call('HGET', KEYS[1], 'expires_at_ms')) then
  return {'expired'}
end
if redis.call('HGET', KEYS[1], 'otp') ~= ARGV[1] then return {'invalid_otp'} end
redis.call('HSET', KEYS[1], 'status', 'granted', 'token', ARGV[3])
redis.call('EXPIRE', KEYS[1], ARGV[4])
return {'granted'}
"#;

// KEYS[1]; ARGV: decided_ttl
const DENY: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
local status = redis.call('HGET', KEYS[1], 'status')
if status ~= 'pending' then return {'not_pending', status} end
redis.call('HSET', KEYS[1], 'status', 'denied')
redis.call('EXPIRE', KEYS[1], ARGV[1])
return {'denied'}
"#;

// KEYS[1]; ARGV: decided_ttl
const TOUCH: &str = r#"
if redis.call('HGET', KEYS[1], 'status') == 'granted' then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return {'1'}
"#;

fn status_name(status: &SessionStatus) -> String {
    serde_json::to_value(status)
        .ok()
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_default()
}

fn parse_status(name: &str) -> Option<SessionStatus> {
    serde_json::from_value(serde_json::Value::String(name.to_string())).ok()
}

fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
}

fn non_empty(value: Option<&String>) -> Option<String> {
    value.filter(|value| !value.is_empty()).cloned()
}

/// How long a session stays in Redis (pre-flight note 2).
pub fn session_ttl_secs(session: &Session, now: DateTime<Utc>) -> i64 {
    match session.status {
        SessionStatus::Pending => ((session.expires_at - now).num_seconds() + PENDING_GRACE_SECS).max(1),
        _ => DECIDED_SESSION_TTL_SECS,
    }
}

fn session_fields(session: &Session) -> Vec<(&'static str, String)> {
    vec![
        ("id", session.id.clone()),
        ("otp", session.otp.clone()),
        ("hostname", session.hostname.clone()),
        ("status", status_name(&session.status)),
        ("token", session.token.clone().unwrap_or_default()),
        ("created_at", session.created_at.to_rfc3339()),
        ("expires_at", session.expires_at.to_rfc3339()),
        ("expires_at_ms", session.expires_at.timestamp_millis().to_string()),
        ("astation_id", session.astation_id.clone().unwrap_or_default()),
    ]
}

fn session_from_hash(map: &HashMap<String, String>) -> Option<Session> {
    Some(Session {
        id: map.get("id")?.clone(),
        otp: map.get("otp")?.clone(),
        hostname: map.get("hostname")?.clone(),
        status: parse_status(map.get("status")?)?,
        token: non_empty(map.get("token")),
        created_at: parse_time(map.get("created_at"))?,
        expires_at: parse_time(map.get("expires_at"))?,
        astation_id: non_empty(map.get("astation_id")),
    })
}

pub struct RedisSessionBackend {
    conn: RedisConn,
    grant: Script,
    deny: Script,
    touch: Script,
}

impl RedisSessionBackend {
    pub fn new(conn: RedisConn) -> Self {
        Self {
            conn,
            grant: Script::new(GRANT),
            deny: Script::new(DENY),
            touch: Script::new(TOUCH),
        }
    }

    async fn write(&self, id: &str, session: &Session) -> Result<(), StoreError> {
        let key = keys::session(id);
        let fields = session_fields(session);
        let ttl = session_ttl_secs(session, Utc::now());
        self.conn
            .run(|mut c| async move {
                redis::pipe()
                    .atomic()
                    .del(&key)
                    .ignore()
                    .hset_multiple(&key, &fields)
                    .ignore()
                    .expire(&key, ttl)
                    .ignore()
                    .query_async::<()>(&mut c)
                    .await
            })
            .await
    }

    async fn script(&self, script: &Script, id: &str, args: Vec<String>) -> Result<Vec<String>, StoreError> {
        let key = keys::session(id);
        self.conn
            .run(|mut c| async move {
                let mut invocation = script.prepare_invoke();
                invocation.key(&key);
                for arg in &args {
                    invocation.arg(arg);
                }
                invocation.invoke_async(&mut c).await
            })
            .await
    }

    async fn load(&self, id: &str) -> Result<Option<Session>, StoreError> {
        let key = keys::session(id);
        let map: HashMap<String, String> = self
            .conn
            .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
            .await?;
        if map.is_empty() {
            return Ok(None);
        }
        session_from_hash(&map)
            .map(Some)
            .ok_or_else(|| StoreError::Unavailable(format!("malformed session {}", crate::relay::mask_code(id))))
    }
}

#[async_trait]
impl SessionBackend for RedisSessionBackend {
    async fn create(&self, session: Session) -> Result<(), StoreError> {
        self.write(&session.id.clone(), &session).await
    }

    async fn get(&self, id: &str) -> Result<Option<Session>, StoreError> {
        self.load(id).await
    }

    async fn update(&self, id: &str, session: Session) -> Result<(), StoreError> {
        self.write(id, &session).await
    }

    async fn delete(&self, id: &str) -> Result<(), StoreError> {
        let key = keys::session(id);
        self.conn
            .run(|mut c| async move { redis::cmd("DEL").arg(&key).query_async::<()>(&mut c).await })
            .await
    }

    async fn grant(&self, id: &str, otp: &str, token: &str, now: DateTime<Utc>) -> Result<GrantOutcome, StoreError> {
        let out = self
            .script(
                &self.grant,
                id,
                vec![
                    otp.to_string(),
                    now.timestamp_millis().to_string(),
                    token.to_string(),
                    DECIDED_SESSION_TTL_SECS.to_string(),
                ],
            )
            .await?;
        Ok(match out.first().map(String::as_str) {
            Some("granted") => match self.load(id).await? {
                Some(session) => GrantOutcome::Granted(session),
                None => GrantOutcome::NotFound,
            },
            Some("not_pending") => GrantOutcome::NotPending(
                out.get(1).and_then(|name| parse_status(name)).unwrap_or(SessionStatus::Expired),
            ),
            Some("expired") => GrantOutcome::Expired,
            Some("invalid_otp") => GrantOutcome::InvalidOtp,
            _ => GrantOutcome::NotFound,
        })
    }

    async fn deny(&self, id: &str) -> Result<DenyOutcome, StoreError> {
        let out = self
            .script(&self.deny, id, vec![DECIDED_SESSION_TTL_SECS.to_string()])
            .await?;
        Ok(match out.first().map(String::as_str) {
            Some("denied") => match self.load(id).await? {
                Some(session) => DenyOutcome::Denied(session),
                None => DenyOutcome::NotFound,
            },
            Some("not_pending") => DenyOutcome::NotPending(
                out.get(1).and_then(|name| parse_status(name)).unwrap_or(SessionStatus::Expired),
            ),
            _ => DenyOutcome::NotFound,
        })
    }

    async fn touch(&self, id: &str) -> Result<(), StoreError> {
        let _ = self
            .script(&self.touch, id, vec![DECIDED_SESSION_TTL_SECS.to_string()])
            .await;
        Ok(())
    }

    async fn cleanup_expired(&self) -> Result<(), StoreError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::create_session;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
    use crate::session_store::{tests::scenarios, SessionStore};
    use std::sync::Arc;

    async fn store() -> (SessionStore, RedisConn) {
        let conn = fresh_conn().await;
        (
            SessionStore::with_backend(Arc::new(RedisSessionBackend::new(conn.clone()))),
            conn,
        )
    }

    async fn ttl(conn: &RedisConn, id: &str) -> i64 {
        let key = keys::session(id);
        conn.run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
            .await
            .unwrap()
    }

    #[tokio::test]
    #[ignore]
    async fn redis_sessions_round_trip_and_expire_as_designed() {
        let _guard = REDIS_LOCK.lock().await;
        let (store, conn) = store().await;
        let mut session = create_session("mac");
        session.astation_id = Some("astation-1".into());
        let id = session.id.clone();
        store.create(session.clone()).await.unwrap();
        let loaded = store.get(&id).await.unwrap().expect("stored");
        assert_eq!(loaded.id, session.id);
        assert_eq!(loaded.otp, session.otp);
        assert_eq!(loaded.hostname, "mac");
        assert_eq!(loaded.status, SessionStatus::Pending);
        assert_eq!(loaded.token, None);
        assert_eq!(loaded.created_at, session.created_at);
        assert_eq!(loaded.expires_at, session.expires_at);
        assert_eq!(loaded.astation_id.as_deref(), Some("astation-1"));
        // Pending: until 60 s after the 5-minute expiry.
        let pending_ttl = ttl(&conn, &id).await;
        assert!((300..=360).contains(&pending_ttl), "pending ttl {pending_ttl}");

        let otp = session.otp.clone();
        assert!(matches!(store.grant(&id, "00000000").await.unwrap(), GrantOutcome::InvalidOtp));
        let granted = match store.grant(&id, &otp).await.unwrap() {
            GrantOutcome::Granted(granted) => granted,
            other => panic!("expected Granted, got {other:?}"),
        };
        assert_eq!(granted.token.as_ref().map(String::len), Some(64));
        assert_eq!(store.get(&id).await.unwrap().unwrap().token, granted.token);
        let granted_ttl = ttl(&conn, &id).await;
        assert!(granted_ttl > DECIDED_SESSION_TTL_SECS - 10, "granted ttl {granted_ttl}");
        assert!(matches!(
            store.grant(&id, &otp).await.unwrap(),
            GrantOutcome::NotPending(SessionStatus::Granted)
        ));
        store.touch(&id).await.unwrap();

        assert!(matches!(store.grant("missing", &otp).await.unwrap(), GrantOutcome::NotFound));
        store.delete(&id).await.unwrap();
        assert!(store.get(&id).await.unwrap().is_none());
    }

    #[tokio::test]
    #[ignore]
    async fn redis_sessions_expired_and_denied() {
        let _guard = REDIS_LOCK.lock().await;
        let (store, _conn) = store().await;
        let now = Utc::now();
        let mut expired = create_session("late");
        expired.created_at = now - chrono::Duration::minutes(5) - chrono::Duration::seconds(30);
        expired.expires_at = now - chrono::Duration::seconds(30);
        let expired_id = expired.id.clone();
        let otp = expired.otp.clone();
        store.create(expired).await.unwrap();
        assert!(store.get(&expired_id).await.unwrap().is_some(), "kept for the grace period");
        assert!(matches!(store.grant(&expired_id, &otp).await.unwrap(), GrantOutcome::Expired));

        let pending = create_session("deny-me");
        let pending_id = pending.id.clone();
        store.create(pending).await.unwrap();
        assert!(matches!(store.deny(&pending_id).await.unwrap(), DenyOutcome::Denied(_)));
        assert!(matches!(
            store.deny(&pending_id).await.unwrap(),
            DenyOutcome::NotPending(SessionStatus::Denied)
        ));
        assert!(matches!(store.deny("missing").await.unwrap(), DenyOutcome::NotFound));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn redis_sessions_concurrent_grants_apply_once() {
        let _guard = REDIS_LOCK.lock().await;
        let (store, _conn) = store().await;
        let session = create_session("race");
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

    /// The same scenarios the in-memory backend passes, including the
    /// NotPending-before-Expired-before-OTP precedence.
    #[tokio::test]
    #[ignore]
    async fn redis_sessions_pass_the_shared_scenarios() {
        let _guard = REDIS_LOCK.lock().await;
        scenarios::grant_is_atomic_and_checks_in_order(store().await.0).await;
        scenarios::grant_of_an_expired_session_is_expired_even_with_the_right_otp(store().await.0).await;
        scenarios::deny_applies_only_while_pending(store().await.0).await;
        scenarios::grant_of_a_finished_expired_session_is_not_pending(store().await.0).await;
    }
}
