//! Voice sessions in Redis (`relay:voice:<id>` hash). The Atem's answer is
//! stored in `relay:voice:<id>:reply` (30 s) and published on
//! `relay:voice-reply:<id>`, which every replica receives through its bus
//! (pattern subscription) and hands to its local waiters.

use std::collections::HashMap;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use redis::Script;

use super::{keys, RedisConn};
use crate::cluster::StoreError;
use crate::voice_session::{
    tail_within, ReplyWaiters, VoiceBackend, VoiceSession, VoiceSessionState, WaitOutcome,
    MAX_VOICE_BUFFER_BYTES,
};

pub const VOICE_IDLE_SECS: i64 = 60;
pub const REPLY_TTL_SECS: i64 = 30;

/// A wait also re-reads the stored answer this often, in case the
/// pub/sub message was missed during a reconnect.
const REPLY_POLL: Duration = Duration::from_secs(1);

// KEYS[1]; ARGV: text, now, cap_bytes, idle_ttl → 1 | 0
const ADD_TRANSCRIPTION: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
local buffer = cjson.decode(redis.call('HGET', KEYS[1], 'buffer') or '[]')
table.insert(buffer, ARGV[1])
local total = 0
for i = 1, #buffer do total = total + string.len(buffer[i]) end
while total > tonumber(ARGV[3]) and #buffer > 1 do
  total = total - string.len(buffer[1])
  table.remove(buffer, 1)
end
redis.call('HSET', KEYS[1], 'buffer', cjson.encode(buffer), 'last_activity', ARGV[2])
redis.call('EXPIRE', KEYS[1], ARGV[4])
return 1
"#;

// KEYS[1] session, KEYS[2] reply; ARGV: now, idle_ttl → buffer JSON | nil.
// A new turn drops the previous turn's stored answer, so it can't answer
// this turn's wait (in memory, the state check does the same).
const TRIGGER: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return false end
redis.call('HSET', KEYS[1], 'state', 'Triggered', 'last_activity', ARGV[1])
redis.call('DEL', KEYS[2])
redis.call('EXPIRE', KEYS[1], ARGV[2])
return redis.call('HGET', KEYS[1], 'buffer') or '[]'
"#;

// KEYS[1] session, KEYS[2] reply; ARGV: response, now, idle_ttl, reply_ttl, channel → 1 | 0
const SET_RESPONSE: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
redis.call('HSET', KEYS[1], 'state', 'ResponseReady', 'response', ARGV[1],
  'has_response', '1', 'last_activity', ARGV[2])
redis.call('EXPIRE', KEYS[1], ARGV[3])
redis.call('SET', KEYS[2], ARGV[1], 'EX', ARGV[4])
redis.call('PUBLISH', ARGV[5], ARGV[1])
return 1
"#;

// KEYS[1] → count | -1
const INCREMENT: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return -1 end
return redis.call('HINCRBY', KEYS[1], 'request_count', 1)
"#;

fn state_name(state: &VoiceSessionState) -> &'static str {
    match state {
        VoiceSessionState::Accumulating => "Accumulating",
        VoiceSessionState::Triggered => "Triggered",
        VoiceSessionState::ResponseReady => "ResponseReady",
    }
}

fn parse_state(name: &str) -> Option<VoiceSessionState> {
    match name {
        "Accumulating" => Some(VoiceSessionState::Accumulating),
        "Triggered" => Some(VoiceSessionState::Triggered),
        "ResponseReady" => Some(VoiceSessionState::ResponseReady),
        _ => None,
    }
}

fn parse_time(value: Option<&String>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?).ok().map(|time| time.with_timezone(&Utc))
}

fn parse_buffer(raw: &str) -> Vec<String> {
    if raw == "{}" {
        return Vec::new(); // cjson encodes an empty table as an object
    }
    serde_json::from_str(raw).unwrap_or_default()
}

fn session_fields(session: &VoiceSession) -> Vec<(&'static str, String)> {
    vec![
        ("session_id", session.session_id.clone()),
        ("atem_id", session.atem_id.clone()),
        ("channel", session.channel.clone()),
        ("state", state_name(&session.state).to_string()),
        ("buffer", serde_json::to_string(&session.buffer).unwrap_or_else(|_| "[]".to_string())),
        ("has_response", if session.response.is_some() { "1" } else { "0" }.to_string()),
        ("response", session.response.clone().unwrap_or_default()),
        ("created_at", session.created_at.to_rfc3339()),
        ("last_activity", session.last_activity.to_rfc3339()),
        ("request_count", session.request_count.to_string()),
    ]
}

fn session_from_hash(map: &HashMap<String, String>) -> Option<VoiceSession> {
    Some(VoiceSession {
        session_id: map.get("session_id")?.clone(),
        atem_id: map.get("atem_id")?.clone(),
        channel: map.get("channel")?.clone(),
        state: parse_state(map.get("state")?)?,
        buffer: parse_buffer(map.get("buffer").map(String::as_str).unwrap_or("[]")),
        response: (map.get("has_response").map(String::as_str) == Some("1"))
            .then(|| map.get("response").cloned().unwrap_or_default()),
        created_at: parse_time(map.get("created_at"))?,
        last_activity: parse_time(map.get("last_activity"))?,
        request_count: map.get("request_count").and_then(|v| v.parse().ok()).unwrap_or(0),
    })
}

pub struct RedisVoiceBackend {
    conn: RedisConn,
    waiters: ReplyWaiters,
    add_transcription: Script,
    trigger: Script,
    set_response: Script,
    increment: Script,
}

impl RedisVoiceBackend {
    pub fn new(conn: RedisConn, waiters: ReplyWaiters) -> Self {
        Self {
            conn,
            waiters,
            add_transcription: Script::new(ADD_TRANSCRIPTION),
            trigger: Script::new(TRIGGER),
            set_response: Script::new(SET_RESPONSE),
            increment: Script::new(INCREMENT),
        }
    }

    async fn eval<T>(&self, script: &Script, keys: Vec<String>, args: Vec<String>) -> Result<T, StoreError>
    where
        T: redis::FromRedisValue + Send,
    {
        self.conn
            .run(|mut c| async move {
                let mut invocation = script.prepare_invoke();
                for key in &keys {
                    invocation.key(key);
                }
                for arg in &args {
                    invocation.arg(arg);
                }
                invocation.invoke_async(&mut c).await
            })
            .await
    }

    async fn stored_reply(&self, session_id: &str) -> Result<Option<String>, StoreError> {
        let key = keys::voice_reply(session_id);
        self.conn
            .run(|mut c| async move { redis::cmd("GET").arg(&key).query_async(&mut c).await })
            .await
    }

    /// Every voice session id (debug endpoints).
    async fn scan_ids(&self) -> Result<Vec<String>, StoreError> {
        self.conn
            .run(|mut c| async move {
                let mut cursor: u64 = 0;
                let mut ids = Vec::new();
                loop {
                    let (next, batch): (u64, Vec<String>) = redis::cmd("SCAN")
                        .arg(cursor)
                        .arg("MATCH")
                        .arg(keys::VOICE_PATTERN)
                        .arg("COUNT")
                        .arg(1000)
                        .query_async(&mut c)
                        .await?;
                    for key in batch {
                        if let Some(escaped) = key.strip_prefix(keys::VOICE_PREFIX) {
                            if !escaped.contains(':') {
                                ids.push(keys::unpart(escaped));
                            }
                        }
                    }
                    if next == 0 {
                        break;
                    }
                    cursor = next;
                }
                ids.sort();
                Ok(ids)
            })
            .await
    }
}

#[async_trait]
impl VoiceBackend for RedisVoiceBackend {
    async fn create(&self, session: VoiceSession) -> Result<(), StoreError> {
        let key = keys::voice(&session.session_id);
        let reply = keys::voice_reply(&session.session_id);
        let fields = session_fields(&session);
        self.conn
            .run(|mut c| async move {
                redis::pipe()
                    .atomic()
                    .del(&key)
                    .ignore()
                    .del(&reply)
                    .ignore()
                    .hset_multiple(&key, &fields)
                    .ignore()
                    .expire(&key, VOICE_IDLE_SECS)
                    .ignore()
                    .query_async::<()>(&mut c)
                    .await
            })
            .await
    }

    async fn get(&self, session_id: &str) -> Result<Option<VoiceSession>, StoreError> {
        let key = keys::voice(session_id);
        let map: HashMap<String, String> = self
            .conn
            .run(|mut c| async move { redis::cmd("HGETALL").arg(&key).query_async(&mut c).await })
            .await?;
        Ok(if map.is_empty() { None } else { session_from_hash(&map) })
    }

    async fn add_transcription(&self, session_id: &str, text: String) -> Result<Option<()>, StoreError> {
        let added: i64 = self
            .eval(
                &self.add_transcription,
                vec![keys::voice(session_id)],
                vec![
                    tail_within(&text, MAX_VOICE_BUFFER_BYTES).to_string(),
                    Utc::now().to_rfc3339(),
                    MAX_VOICE_BUFFER_BYTES.to_string(),
                    VOICE_IDLE_SECS.to_string(),
                ],
            )
            .await?;
        Ok((added == 1).then_some(()))
    }

    async fn trigger(&self, session_id: &str) -> Result<Option<String>, StoreError> {
        let buffer: Option<String> = self
            .eval(
                &self.trigger,
                vec![keys::voice(session_id), keys::voice_reply(session_id)],
                vec![Utc::now().to_rfc3339(), VOICE_IDLE_SECS.to_string()],
            )
            .await?;
        Ok(buffer.map(|raw| parse_buffer(&raw).join(" ")))
    }

    async fn set_response(&self, session_id: &str, response: String) -> Result<Option<()>, StoreError> {
        let stored: i64 = self
            .eval(
                &self.set_response,
                vec![keys::voice(session_id), keys::voice_reply(session_id)],
                vec![
                    response,
                    Utc::now().to_rfc3339(),
                    VOICE_IDLE_SECS.to_string(),
                    REPLY_TTL_SECS.to_string(),
                    keys::voice_reply_channel(session_id),
                ],
            )
            .await?;
        if stored != 1 {
            tracing::warn!("Attempted to set response for nonexistent session: {}", session_id);
        }
        Ok((stored == 1).then_some(()))
    }

    async fn increment_requests(&self, session_id: &str) -> Result<Option<u32>, StoreError> {
        let count: i64 = self
            .eval(&self.increment, vec![keys::voice(session_id)], Vec::new())
            .await?;
        Ok(u32::try_from(count).ok())
    }

    async fn get_state(&self, session_id: &str) -> Result<Option<VoiceSessionState>, StoreError> {
        let key = keys::voice(session_id);
        let state: Option<String> = self
            .conn
            .run(|mut c| async move { redis::cmd("HGET").arg(&key).arg("state").query_async(&mut c).await })
            .await?;
        Ok(state.as_deref().and_then(parse_state))
    }

    async fn delete(&self, session_id: &str) -> Result<(), StoreError> {
        let (key, reply) = (keys::voice(session_id), keys::voice_reply(session_id));
        self.conn
            .run(|mut c| async move {
                redis::cmd("DEL").arg(&key).arg(&reply).query_async::<()>(&mut c).await
            })
            .await
    }

    async fn cleanup_expired(&self) -> Result<(), StoreError> {
        Ok(())
    }

    async fn get_by_atem(&self, atem_id: &str) -> Result<Vec<VoiceSession>, StoreError> {
        let mut sessions = Vec::new();
        for id in self.scan_ids().await? {
            if let Some(session) = self.get(&id).await? {
                if session.atem_id == atem_id {
                    sessions.push(session);
                }
            }
        }
        Ok(sessions)
    }

    async fn list_session_ids(&self) -> Result<Vec<String>, StoreError> {
        self.scan_ids().await
    }

    async fn wait_reply(&self, session_id: &str, timeout: Duration) -> Result<WaitOutcome, StoreError> {
        // The bus already listens on relay:voice-reply:* (pattern), so
        // registering the waiter is subscribing; it happens before the
        // stored answer is read, so an answer can't slip through between.
        let mut receiver = self.waiters.register(session_id);
        let deadline = tokio::time::Instant::now() + timeout;
        let mut first_check = true;
        let outcome = loop {
            match self.stored_reply(session_id).await {
                Ok(Some(reply)) => break Ok(WaitOutcome::Reply(reply)),
                Ok(None) => {}
                Err(error) if first_check => break Err(error),
                Err(error) => tracing::debug!("Voice reply poll failed for {}: {}", session_id, error),
            }
            first_check = false;
            let now = tokio::time::Instant::now();
            if now >= deadline {
                break Ok(WaitOutcome::TimedOut);
            }
            match tokio::time::timeout((deadline - now).min(REPLY_POLL), &mut receiver).await {
                Ok(Ok(reply)) => break Ok(WaitOutcome::Reply(reply)),
                // The waiter was dropped (never in practice): register again, keep polling.
                Ok(Err(_)) => receiver = self.waiters.register(session_id),
                Err(_) => {}
            }
        };
        // Close our receiver first, so prune sees it gone and no waiter is
        // left behind (a woken waiter was already removed by wake).
        drop(receiver);
        self.waiters.prune(session_id);
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::bus::BusEvent;
    use crate::cluster::redis::bus::RedisBus;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};
    use crate::voice_session::tests::scenarios;
    use crate::voice_session::VoiceSessionStore;
    use std::sync::Arc;

    /// A replica's voice store plus the bus wiring that wakes its waiters.
    async fn replica(conn: &RedisConn, id: &str) -> (VoiceSessionStore, ReplyWaiters, tokio::task::JoinHandle<()>) {
        let waiters = ReplyWaiters::default();
        let (_bus, mut events, bus_task) = RedisBus::start(conn.clone(), id).await.unwrap();
        let wake = waiters.clone();
        let forward = tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                if let BusEvent::VoiceReply { session_id, reply } = event {
                    wake.wake(&session_id, &reply);
                }
            }
        });
        let store = VoiceSessionStore::with_backend(Arc::new(RedisVoiceBackend::new(conn.clone(), waiters.clone())));
        (store, waiters, tokio::spawn(async move {
            let _ = forward.await;
            bus_task.abort();
        }))
    }

    #[tokio::test]
    #[ignore]
    async fn redis_voice_session_lifecycle() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-a").await;
        let created = store.create("v-1".into(), "atem-1".into(), "ch".into()).await.unwrap();
        let loaded = store.get("v-1").await.unwrap().unwrap();
        assert_eq!(loaded.session_id, created.session_id);
        assert_eq!(loaded.atem_id, "atem-1");
        assert_eq!(loaded.state, VoiceSessionState::Accumulating);
        assert_eq!(store.increment_requests("v-1").await.unwrap(), Some(1));
        assert_eq!(store.increment_requests("v-1").await.unwrap(), Some(2));
        assert_eq!(store.add_transcription("v-1", "Create".into()).await.unwrap(), Some(()));
        assert_eq!(store.add_transcription("v-1", "a function".into()).await.unwrap(), Some(()));
        assert_eq!(store.trigger("v-1").await.unwrap().as_deref(), Some("Create a function"));
        assert_eq!(store.get_state("v-1").await.unwrap(), Some(VoiceSessionState::Triggered));
        assert_eq!(store.set_response("v-1", "done".into()).await.unwrap(), Some(()));
        let ready = store.get("v-1").await.unwrap().unwrap();
        assert_eq!(ready.state, VoiceSessionState::ResponseReady);
        assert_eq!(ready.response.as_deref(), Some("done"));
        assert_eq!(ready.request_count, 2);
        assert_eq!(store.list_session_ids().await.unwrap(), vec!["v-1".to_string()]);
        assert_eq!(store.get_by_atem("atem-1").await.unwrap().len(), 1);
        assert!(store.get_by_atem("atem-2").await.unwrap().is_empty());
        store.delete("v-1").await.unwrap();
        assert!(store.get("v-1").await.unwrap().is_none());
        assert_eq!(store.trigger("missing").await.unwrap(), None);
        assert_eq!(store.set_response("missing", "x".into()).await.unwrap(), None);
        assert_eq!(store.increment_requests("missing").await.unwrap(), None);
    }

    #[tokio::test]
    #[ignore]
    async fn redis_voice_buffer_is_capped() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-a").await;
        store.create("v-cap".into(), "atem".into(), "ch".into()).await.unwrap();
        let chunk = "x".repeat(1024);
        for _ in 0..70 {
            store.add_transcription("v-cap", chunk.clone()).await.unwrap();
        }
        let session = store.get("v-cap").await.unwrap().unwrap();
        assert_eq!(session.buffer.len(), 64);
        assert!(session.buffer.iter().map(String::len).sum::<usize>() <= MAX_VOICE_BUFFER_BYTES);
    }

    #[tokio::test]
    #[ignore]
    async fn redis_voice_wait_is_answered_across_replicas() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (one, _w1, _t1) = replica(&conn, "voice-1").await;
        let (two, _w2, _t2) = replica(&conn, "voice-2").await;
        one.create("v-x".into(), "atem".into(), "ch".into()).await.unwrap();
        one.trigger("v-x").await.unwrap();

        // Answered on replica two while replica one waits.
        let waiting = tokio::spawn({
            let one = one.clone();
            async move { one.wait_reply("v-x", std::time::Duration::from_secs(5)).await.unwrap() }
        });
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        two.set_response("v-x", "from two".into()).await.unwrap();
        assert_eq!(waiting.await.unwrap(), WaitOutcome::Reply("from two".into()));

        // An answer that arrived before the wait is found at once.
        one.create("v-early".into(), "atem".into(), "ch".into()).await.unwrap();
        two.set_response("v-early", "early".into()).await.unwrap();
        let started = std::time::Instant::now();
        assert_eq!(
            one.wait_reply("v-early", std::time::Duration::from_secs(5)).await.unwrap(),
            WaitOutcome::Reply("early".into())
        );
        assert!(started.elapsed() < std::time::Duration::from_secs(1));

        // No answer: the wait times out.
        one.create("v-silent".into(), "atem".into(), "ch".into()).await.unwrap();
        let started = std::time::Instant::now();
        assert_eq!(
            one.wait_reply("v-silent", std::time::Duration::from_secs(1)).await.unwrap(),
            WaitOutcome::TimedOut
        );
        assert!(started.elapsed() >= std::time::Duration::from_secs(1));
    }

    /// The in-memory wait scenarios, against Redis.
    #[tokio::test]
    #[ignore]
    async fn redis_voice_passes_the_shared_wait_scenarios() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-s1").await;
        scenarios::reply_wakes_a_waiter(store).await;

        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-s2").await;
        scenarios::multiple_waiters_all_notified(store).await;

        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-s3").await;
        scenarios::answer_that_arrived_first_is_returned(store).await;

        let conn = fresh_conn().await;
        let (store, waiters, _task) = replica(&conn, "voice-s4").await;
        scenarios::early_reply_leaves_no_waiter_behind(store, &waiters).await;

        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-s5").await;
        scenarios::stale_reply_never_answers_a_new_turn(store).await;
    }

    /// The LLM proxy's 30 s wait, in real time: neither the 1 s re-read nor
    /// the 3 s Redis call bound cuts it short.
    #[tokio::test]
    #[ignore]
    async fn redis_voice_wait_times_out_after_30_s() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let (store, _waiters, _task) = replica(&conn, "voice-t").await;
        assert_eq!(crate::llm_proxy::LLM_WAIT_SECS, 30);
        scenarios::wait_times_out_after(store, Duration::from_secs(crate::llm_proxy::LLM_WAIT_SECS)).await;
    }
}
