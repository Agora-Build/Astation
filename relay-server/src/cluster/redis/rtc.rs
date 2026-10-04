//! RTC sessions in Redis (`relay:rtc:<id>` hash, 4 h). `join` checks the
//! participant cap and takes the next uid in one script, so concurrent
//! joins on different replicas can't exceed the cap or share a uid.

use std::collections::HashMap;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use redis::Script;

use super::{keys, RedisConn};
use crate::cluster::StoreError;
use crate::rtc_session::{
    JoinOutcome, JoinRtcSessionResponse, Participant, RtcBackend, RtcSession, MAX_RTC_PARTICIPANTS,
};

// KEYS[1]; ARGV: name, joined_at, max
// → {'not_found'} | {'full', count} | {'joined', uid, app_id, channel, token, count}
const JOIN: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'not_found'} end
local raw = redis.call('HGET', KEYS[1], 'participants') or '[]'
local participants = cjson.decode(raw)
if #participants >= tonumber(ARGV[3]) then return {'full', tostring(#participants)} end
local uid = redis.call('HINCRBY', KEYS[1], 'next_uid', 1) - 1
if uid == tonumber(redis.call('HGET', KEYS[1], 'host_uid')) then
  uid = redis.call('HINCRBY', KEYS[1], 'next_uid', 1) - 1
end
table.insert(participants, {uid = uid, display_name = ARGV[1], joined_at = ARGV[2]})
redis.call('HSET', KEYS[1], 'participants', cjson.encode(participants))
return {'joined', tostring(uid), redis.call('HGET', KEYS[1], 'app_id'),
  redis.call('HGET', KEYS[1], 'channel'), redis.call('HGET', KEYS[1], 'token'),
  tostring(#participants)}
"#;

fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
}

fn parse_participants(raw: &str) -> Vec<Participant> {
    if raw == "{}" {
        return Vec::new(); // cjson encodes an empty table as an object
    }
    serde_json::from_str(raw).unwrap_or_default()
}

fn session_from_hash(map: &HashMap<String, String>) -> Option<RtcSession> {
    Some(RtcSession {
        id: map.get("id")?.clone(),
        app_id: map.get("app_id")?.clone(),
        channel: map.get("channel")?.clone(),
        token: map.get("token")?.clone(),
        uid_counter_value: map.get("next_uid")?.parse().ok()?,
        host_uid: map.get("host_uid")?.parse().ok()?,
        created_at: parse_time(map.get("created_at"))?,
        expires_at: parse_time(map.get("expires_at"))?,
        participants: parse_participants(map.get("participants").map(String::as_str).unwrap_or("[]")),
    })
}

pub struct RedisRtcBackend {
    conn: RedisConn,
    join: Script,
}

impl RedisRtcBackend {
    pub fn new(conn: RedisConn) -> Self {
        Self {
            conn,
            join: Script::new(JOIN),
        }
    }
}

#[async_trait]
impl RtcBackend for RedisRtcBackend {
    async fn create(&self, session: RtcSession) -> Result<(), StoreError> {
        let key = keys::rtc(&session.id);
        let ttl = (session.expires_at - Utc::now()).num_seconds().max(1);
        let fields: Vec<(&str, String)> = vec![
            ("id", session.id.clone()),
            ("app_id", session.app_id.clone()),
            ("channel", session.channel.clone()),
            ("token", session.token.clone()),
            ("host_uid", session.host_uid.to_string()),
            ("created_at", session.created_at.to_rfc3339()),
            ("expires_at", session.expires_at.to_rfc3339()),
            (
                "participants",
                serde_json::to_string(&session.participants).unwrap_or_else(|_| "[]".to_string()),
            ),
            ("next_uid", session.uid_counter_value.to_string()),
        ];
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

    async fn get(&self, id: &str) -> Result<Option<RtcSession>, StoreError> {
        let key = keys::rtc(id);
        let map: HashMap<String, String> = self
            .conn
            .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
            .await?;
        Ok(if map.is_empty() { None } else { session_from_hash(&map) })
    }

    async fn join(&self, id: &str, name: String, now: DateTime<Utc>) -> Result<JoinOutcome, StoreError> {
        let key = keys::rtc(id);
        let script = &self.join;
        let args = vec![name.clone(), now.to_rfc3339(), MAX_RTC_PARTICIPANTS.to_string()];
        let out: Vec<String> = self
            .conn
            .run(|mut c| async move {
                let mut invocation = script.prepare_invoke();
                invocation.key(&key);
                for arg in &args {
                    invocation.arg(arg);
                }
                invocation.invoke_async(&mut c).await
            })
            .await?;
        let field = |index: usize| out.get(index).cloned().unwrap_or_default();
        Ok(match out.first().map(String::as_str) {
            Some("joined") => {
                let uid: u32 = field(1)
                    .parse()
                    .map_err(|_| StoreError::Unavailable("malformed RTC uid".to_string()))?;
                tracing::info!(
                    "User {} joined session {} with UID {} (total participants: {})",
                    name,
                    id,
                    uid,
                    field(5)
                );
                JoinOutcome::Joined(JoinRtcSessionResponse {
                    app_id: field(2),
                    channel: field(3),
                    token: field(4),
                    uid,
                    name,
                })
            }
            Some("full") => {
                tracing::warn!("Session {} is full ({} participants)", id, field(1));
                JoinOutcome::Full
            }
            _ => JoinOutcome::NotFound,
        })
    }

    async fn delete(&self, id: &str) -> Result<bool, StoreError> {
        let key = keys::rtc(id);
        let removed: i64 = self
            .conn
            .run(|mut c| async move { redis::cmd("DEL").arg(&key).query_async(&mut c).await })
            .await?;
        Ok(removed > 0)
    }

    async fn cleanup_expired(&self, _now: DateTime<Utc>) -> Result<(), StoreError> {
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
    use crate::rtc_session::{RtcBackend, RtcSession, RtcSessionStore, RTC_FIRST_UID};
    use std::sync::Arc;

    #[tokio::test]
    #[ignore]
    async fn redis_browser_and_screen_uids_skip_the_host() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn)));
        store.create("screen-uids".into(), "app".into(), "room".into(), "token".into(), RTC_FIRST_UID + 1)
            .await.unwrap();
        let browser = store.join("screen-uids", "Browser".into()).await.unwrap();
        let screen = store.join("screen-uids", "Browser (screen)".into()).await.unwrap();
        assert_eq!(browser.uid, RTC_FIRST_UID);
        assert_eq!(screen.uid, RTC_FIRST_UID + 2);
    }

    #[tokio::test]
    #[ignore]
    async fn redis_rtc_create_get_delete() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn.clone())));
        let created = store
            .create("rtc-1".into(), "app".into(), "ch".into(), "tok".into(), 42)
            .await
            .unwrap();
        let loaded = store.get("rtc-1").await.unwrap().unwrap();
        assert_eq!((loaded.app_id.as_str(), loaded.channel.as_str(), loaded.token.as_str()), ("app", "ch", "tok"));
        assert_eq!(loaded.host_uid, 42);
        assert_eq!(loaded.created_at, created.created_at);
        assert_eq!(loaded.uid_counter_value, RTC_FIRST_UID);
        assert!(loaded.participants.is_empty());
        let ttl: i64 = conn
            .run(|mut c| async move { redis::cmd("TTL").arg("relay:rtc:rtc-1").query_async(&mut c).await })
            .await
            .unwrap();
        assert!((4 * 3600 - 10..=4 * 3600).contains(&ttl), "ttl {ttl}");
        let joined = store.join("rtc-1", "Alice".into()).await.unwrap();
        assert_eq!(joined.uid, 1000);
        let ttl: i64 = conn
            .run(|mut c| async move { redis::cmd("TTL").arg("relay:rtc:rtc-1").query_async(&mut c).await })
            .await
            .unwrap();
        assert!((4 * 3600 - 10..=4 * 3600).contains(&ttl), "ttl after join {ttl}");
        assert_eq!((joined.app_id.as_str(), joined.token.as_str()), ("app", "tok"));
        let loaded = store.get("rtc-1").await.unwrap().unwrap();
        assert_eq!(loaded.participants.len(), 1);
        assert_eq!(loaded.participants[0].display_name.as_deref(), Some("Alice"));
        assert_eq!(loaded.uid_counter_value, 1001);
        assert!(store.join("missing", "Bob".into()).await.unwrap_err().contains("not found"));
        assert!(store.delete("rtc-1").await.unwrap());
        assert!(!store.delete("rtc-1").await.unwrap());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn redis_rtc_concurrent_joins_hold_the_cap() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn)));
        store.create("rtc-c".into(), "a".into(), "c".into(), "t".into(), 1).await.unwrap();
        let handles: Vec<_> = (0..12)
            .map(|i| {
                let store = store.clone();
                tokio::spawn(async move { store.join("rtc-c", format!("User{i}")).await })
            })
            .collect();
        let mut uids = Vec::new();
        let mut full = 0;
        for handle in handles {
            match handle.await.unwrap() {
                Ok(response) => uids.push(response.uid),
                Err(error) => {
                    assert!(error.contains("full"), "{error}");
                    full += 1;
                }
            }
        }
        uids.sort();
        assert_eq!(uids, (1000..1008).collect::<Vec<u32>>());
        assert_eq!(full, 4);
    }

    /// The in-memory scenarios (uid sequence, cap of exactly 8, no uid reuse,
    /// not found, expiry), against Redis.
    #[tokio::test]
    #[ignore]
    async fn redis_rtc_passes_the_in_memory_scenarios() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let store = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn.clone())));
        store.create("seq".into(), "app".into(), "ch".into(), "tok".into(), 1).await.unwrap();
        for expected in RTC_FIRST_UID..RTC_FIRST_UID + 8 {
            let joined = store.join("seq", format!("U{expected}")).await.unwrap();
            assert_eq!(joined.uid, expected);
            assert_eq!(joined.name, format!("U{expected}"));
        }
        let error = store.join("seq", "Ninth".into()).await.unwrap_err();
        assert_eq!(error, "Session is full (maximum 8 participants)");
        let loaded = store.get("seq").await.unwrap().unwrap();
        assert_eq!(loaded.participants.len(), 8);
        assert_eq!(loaded.uid_counter_value, RTC_FIRST_UID + 8, "a refused join takes no uid");
        assert_eq!(store.join("nope", "A".into()).await.unwrap_err(), "Session not found");

        // Non-ASCII display names round-trip (cjson passes bytes through).
        store.create("names".into(), "app".into(), "ch".into(), "tok".into(), 1).await.unwrap();
        store.join("names", "张伟".into()).await.unwrap();
        store.join("names", "Ünï".into()).await.unwrap();
        let loaded = store.get("names").await.unwrap().unwrap();
        let names: Vec<_> = loaded.participants.iter().map(|p| p.display_name.clone().unwrap()).collect();
        assert_eq!(names, vec!["张伟".to_string(), "Ünï".to_string()]);
        let ttl: i64 = conn
            .run(|mut c| async move { redis::cmd("TTL").arg("relay:rtc:names").query_async(&mut c).await })
            .await
            .unwrap();
        assert!((4 * 3600 - 10..=4 * 3600).contains(&ttl), "ttl after joins {ttl}");

        // Sessions are independent, each starting at the first uid.
        store.create("other".into(), "app".into(), "ch".into(), "tok".into(), 1).await.unwrap();
        assert_eq!(store.join("other", "A".into()).await.unwrap().uid, RTC_FIRST_UID);

        // Expiry: a session past its expiry is gone.
        let backend = RedisRtcBackend::new(conn.clone());
        let now = chrono::Utc::now();
        backend
            .create(RtcSession {
                id: "short".into(),
                app_id: "a".into(),
                channel: "c".into(),
                token: "t".into(),
                uid_counter_value: RTC_FIRST_UID,
                host_uid: 1,
                created_at: now,
                expires_at: now + chrono::Duration::seconds(1),
                participants: Vec::new(),
            })
            .await
            .unwrap();
        assert!(store.get("short").await.unwrap().is_some());
        tokio::time::sleep(std::time::Duration::from_millis(2200)).await;
        assert!(store.get("short").await.unwrap().is_none());
        assert_eq!(store.join("short", "Late".into()).await.unwrap_err(), "Session not found");
    }

    /// Two replicas (separate connections, separate stores) racing for one session.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn redis_rtc_joins_from_two_replicas_never_share_a_uid() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let one = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn.clone())));
        let two = RtcSessionStore::with_backend(Arc::new(RedisRtcBackend::new(conn.clone())));
        one.create("rtc-two".into(), "a".into(), "c".into(), "t".into(), 1).await.unwrap();
        let handles: Vec<_> = (0..16)
            .map(|i| {
                let store = if i % 2 == 0 { one.clone() } else { two.clone() };
                tokio::spawn(async move { store.join("rtc-two", format!("U{i}")).await })
            })
            .collect();
        let mut uids = Vec::new();
        for handle in handles {
            if let Ok(response) = handle.await.unwrap() {
                uids.push(response.uid);
            }
        }
        uids.sort();
        assert_eq!(uids, (1000..1008).collect::<Vec<u32>>());
        assert_eq!(one.get("rtc-two").await.unwrap().unwrap().participants.len(), 8);
    }
}
