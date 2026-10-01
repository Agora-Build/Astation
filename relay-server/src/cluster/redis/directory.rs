//! RoomDirectory in Redis (spec: "Redis keys"). Every mutation is one Lua
//! script over one room's keys only: KEYS[1] = relay:room:<code> (hash
//! {owner_conn, owner_replica, verified, hostname, created_at, paired}),
//! KEYS[2] = …:atems (atem_id → conn|replica), KEYS[3] = …:pending
//! (conn → replica). So "set owner = me, verified, remove me from pending,
//! return the previous owner" is atomic and two replicas can't both win.
//!
//! The room key expires ROOM_EXPIRY_SECS after creation, and again after an
//! Astation claims it, goes pending, is promoted, or `touch`es it (the
//! heartbeat of the replica holding its socket). The two hashes always carry
//! the room key's remaining TTL, so the three keys expire together.

use std::collections::HashMap;

use async_trait::async_trait;
use redis::Script;

use super::{keys, RedisConn};
use crate::cluster::directory::{
    AtemJoin, AtemLeave, OwnerClaim, Promotion, RoomDirectory, RoomInfo, IDENTITY_HOSTNAME,
    ROOM_EXPIRY_SECS,
};
use crate::cluster::{ConnRef, StoreError};

const PRELUDE: &str = r#"
local function sync_ttl()
  local ttl = redis.call('PTTL', KEYS[1])
  if ttl > 0 then
    if redis.call('EXISTS', KEYS[2]) == 1 then redis.call('PEXPIRE', KEYS[2], ttl) end
    if redis.call('EXISTS', KEYS[3]) == 1 then redis.call('PEXPIRE', KEYS[3], ttl) end
  end
end
local function is_empty()
  return redis.call('HLEN', KEYS[2]) == 0
    and redis.call('HLEN', KEYS[3]) == 0
    and (redis.call('HGET', KEYS[1], 'owner_conn') or '') == ''
end
local function new_room(hostname, created_at, ttl)
  redis.call('DEL', KEYS[2], KEYS[3])
  redis.call('HSET', KEYS[1], 'hostname', hostname, 'created_at', created_at,
    'owner_conn', '', 'owner_replica', '', 'verified', '0', 'paired', '0')
  redis.call('EXPIRE', KEYS[1], ttl)
end
local function keep_alive(ttl)
  redis.call('EXPIRE', KEYS[1], ttl)
  sync_ttl()
end
local function clear_owner()
  redis.call('HSET', KEYS[1], 'owner_conn', '', 'owner_replica', '', 'verified', '0', 'paired', '0')
end
-- Append the Atem pairs (Rust sorts them by atem id).
local function append_atems(out)
  local atems = redis.call('HGETALL', KEYS[2])
  for i = 1, #atems do out[#out + 1] = atems[i] end
  return out
end
"#;

// ARGV: hostname, created_at, ttl
const CREATE_ROOM: &str = r#"
redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
new_room(ARGV[1], ARGV[2], ARGV[3])
return '1'
"#;

// ARGV: hostname, created_at, ttl → '1' created | '0' existed
const ENSURE_ROOM: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 1 then return '0' end
new_room(ARGV[1], ARGV[2], ARGV[3])
return '1'
"#;

// ARGV: atem_id, conn|replica → {'1', replaced, owner_conn, owner_replica} | {'0'}
const JOIN_ATEM: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'0'} end
local replaced = redis.call('HGET', KEYS[2], ARGV[1]) or ''
redis.call('HSET', KEYS[2], ARGV[1], ARGV[2])
sync_ttl()
return {'1', replaced,
  redis.call('HGET', KEYS[1], 'owner_conn') or '',
  redis.call('HGET', KEYS[1], 'owner_replica') or ''}
"#;

// ARGV: conn, replica, hostname, created_at, ttl
// → {prev_conn, prev_replica, atem_id, conn|replica, …}
const CLAIM_OWNER: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then new_room(ARGV[3], ARGV[4], ARGV[5]) end
local out = {redis.call('HGET', KEYS[1], 'owner_conn') or '',
             redis.call('HGET', KEYS[1], 'owner_replica') or ''}
redis.call('HSET', KEYS[1], 'owner_conn', ARGV[1], 'owner_replica', ARGV[2],
  'verified', '0', 'paired', '1')
keep_alive(ARGV[5])
return append_atems(out)
"#;

// ARGV: conn, replica, hostname, created_at, ttl, max_pending (0 = no cap) → '1' | '0'
// A connection id that is already pending is admitted unchanged (its stored
// replica is kept), before the cap check — as the in-memory directory does.
const ADD_PENDING: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then new_room(ARGV[3], ARGV[4], ARGV[5]) end
if redis.call('HEXISTS', KEYS[3], ARGV[1]) == 0 then
  local cap = tonumber(ARGV[6])
  if cap > 0 and redis.call('HLEN', KEYS[3]) >= cap then return '0' end
  redis.call('HSET', KEYS[3], ARGV[1], ARGV[2])
end
keep_alive(ARGV[5])
return '1'
"#;

// ARGV: conn, replica, was_pending ('1'/'0'), ttl
// → {'none'} | {'owner'} | {'not_pending', evicted_conn, evicted_replica}
//   | {'promoted', prev_conn, prev_replica, evicted_unverified, atem pairs…}
const PROMOTE: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'none'} end
local oc = redis.call('HGET', KEYS[1], 'owner_conn') or ''
local orp = redis.call('HGET', KEYS[1], 'owner_replica') or ''
if oc ~= '' and oc == ARGV[1] then
  redis.call('HSET', KEYS[1], 'verified', '1')
  keep_alive(ARGV[4])
  return {'owner'}
end
local ec, er, evicted = '', '', '0'
if oc ~= '' and (redis.call('HGET', KEYS[1], 'verified') or '0') ~= '1' then
  ec, er, evicted = oc, orp, '1'
  clear_owner()
end
if ARGV[3] ~= '1' or redis.call('HDEL', KEYS[3], ARGV[1]) == 0 then
  return {'not_pending', ec, er}
end
redis.call('HSET', KEYS[1], 'owner_conn', ARGV[1], 'owner_replica', ARGV[2],
  'verified', '1', 'paired', '1')
keep_alive(ARGV[4])
return append_atems({'promoted', oc, orp, evicted})
"#;

// ARGV: atem_id, connection_id → {removed, room_removed, owner_conn, owner_replica}
// The Atem is removed only when the connection id of its stored
// `conn|replica` (the part before the first '|', like ConnRef::decode)
// equals ARGV[2].
const LEAVE_ATEM: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {'0', '0', '', ''} end
local removed = '0'
local current = redis.call('HGET', KEYS[2], ARGV[1]) or ''
local bar = string.find(current, '|', 1, true)
if bar and string.sub(current, 1, bar - 1) == ARGV[2] then
  redis.call('HDEL', KEYS[2], ARGV[1])
  removed = '1'
end
local oc = redis.call('HGET', KEYS[1], 'owner_conn') or ''
local orp = redis.call('HGET', KEYS[1], 'owner_replica') or ''
local gone = '0'
if is_empty() then
  redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
  gone = '1'
end
return {removed, gone, oc, orp}
"#;

// ARGV: connection_id → room_removed '1' | '0'
const LEAVE_ASTATION: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return '0' end
redis.call('HDEL', KEYS[3], ARGV[1])
if (redis.call('HGET', KEYS[1], 'owner_conn') or '') == ARGV[1] then
  clear_owner()
end
if is_empty() then
  redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
  return '1'
end
return '0'
"#;

// → {} | {room pairs, atem pairs, pending pairs}
const DELETE_ROOM: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return {} end
local out = {redis.call('HGETALL', KEYS[1]), redis.call('HGETALL', KEYS[2]),
             redis.call('HGETALL', KEYS[3])}
redis.call('DEL', KEYS[1], KEYS[2], KEYS[3])
return out
"#;

// ARGV: ttl → '1' | '0'
const TOUCH: &str = r#"
if redis.call('EXISTS', KEYS[1]) == 0 then return '0' end
keep_alive(ARGV[1])
return '1'
"#;

fn script(body: &str) -> Script {
    Script::new(&format!("{PRELUDE}\n{body}"))
}

fn at(values: &[String], index: usize) -> &str {
    values.get(index).map(String::as_str).unwrap_or("")
}

fn conn_ref(conn: &str, replica: &str) -> Option<ConnRef> {
    (!conn.is_empty()).then(|| ConnRef::new(conn, replica))
}

/// `[id, "conn|replica", id, …]` → pairs sorted by atem id (the in-memory
/// directory's BTreeMap order); malformed entries are skipped.
fn atem_pairs(flat: &[String]) -> Vec<(String, ConnRef)> {
    let mut pairs: Vec<(String, ConnRef)> = flat
        .chunks(2)
        .filter_map(|pair| match pair {
            [atem_id, value] => ConnRef::decode(value).map(|conn| (atem_id.clone(), conn)),
            _ => None,
        })
        .collect();
    pairs.sort();
    pairs
}

fn flat_to_map(flat: &[String]) -> HashMap<String, String> {
    flat.chunks(2)
        .filter_map(|pair| match pair {
            [field, value] => Some((field.clone(), value.clone())),
            _ => None,
        })
        .collect()
}

fn room_info(
    room: &HashMap<String, String>,
    atems: &HashMap<String, String>,
    pending: &HashMap<String, String>,
) -> RoomInfo {
    let field = |name: &str| room.get(name).map(String::as_str).unwrap_or("");
    let mut pending: Vec<ConnRef> = pending
        .iter()
        .map(|(conn, replica)| ConnRef::new(conn, replica))
        .collect();
    pending.sort();
    RoomInfo {
        hostname: field("hostname").to_string(),
        created_at: field("created_at").parse().unwrap_or(0),
        owner: conn_ref(field("owner_conn"), field("owner_replica")),
        verified: field("verified") == "1",
        atems: atems
            .iter()
            .filter_map(|(atem_id, value)| {
                ConnRef::decode(value).map(|conn| (atem_id.clone(), conn))
            })
            .collect(),
        pending,
    }
}

pub struct RedisRoomDirectory {
    conn: RedisConn,
    create_room: Script,
    ensure_room: Script,
    join_atem: Script,
    claim_owner: Script,
    add_pending: Script,
    promote: Script,
    leave_atem: Script,
    leave_astation: Script,
    delete_room: Script,
    touch: Script,
}

impl RedisRoomDirectory {
    pub fn new(conn: RedisConn) -> Self {
        Self {
            conn,
            create_room: script(CREATE_ROOM),
            ensure_room: script(ENSURE_ROOM),
            join_atem: script(JOIN_ATEM),
            claim_owner: script(CLAIM_OWNER),
            add_pending: script(ADD_PENDING),
            promote: script(PROMOTE),
            leave_atem: script(LEAVE_ATEM),
            leave_astation: script(LEAVE_ASTATION),
            delete_room: script(DELETE_ROOM),
            touch: script(TOUCH),
        }
    }

    /// Run a room script with that room's three keys and `args`.
    async fn eval<T>(&self, script: &Script, code: &str, args: Vec<String>) -> Result<T, StoreError>
    where
        T: redis::FromRedisValue + Send,
    {
        let (room, atems, pending) = (
            keys::room(code),
            keys::room_atems(code),
            keys::room_pending(code),
        );
        self.conn
            .run(|mut c| async move {
                let mut invocation = script.prepare_invoke();
                invocation.key(&room).key(&atems).key(&pending);
                for arg in &args {
                    invocation.arg(arg);
                }
                invocation.invoke_async(&mut c).await
            })
            .await
    }
}

#[async_trait]
impl RoomDirectory for RedisRoomDirectory {
    fn backend_name(&self) -> &'static str {
        "redis"
    }

    async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError> {
        let _: String = self
            .eval(
                &self.create_room,
                code,
                vec![
                    hostname.to_string(),
                    now.to_string(),
                    ROOM_EXPIRY_SECS.to_string(),
                ],
            )
            .await?;
        Ok(())
    }

    async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError> {
        let created: String = self
            .eval(
                &self.ensure_room,
                code,
                vec![
                    hostname.to_string(),
                    now.to_string(),
                    ROOM_EXPIRY_SECS.to_string(),
                ],
            )
            .await?;
        Ok(created == "1")
    }

    async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        let (room_key, atems_key, pending_key) = (
            keys::room(code),
            keys::room_atems(code),
            keys::room_pending(code),
        );
        let (room, atems, pending): (
            HashMap<String, String>,
            HashMap<String, String>,
            HashMap<String, String>,
        ) = self
            .conn
            .run(|mut c| async move {
                redis::pipe()
                    .atomic()
                    .hgetall(&room_key)
                    .hgetall(&atems_key)
                    .hgetall(&pending_key)
                    .query_async(&mut c)
                    .await
            })
            .await?;
        if room.is_empty() {
            return Ok(None);
        }
        Ok(Some(room_info(&room, &atems, &pending)))
    }

    async fn join_atem(
        &self,
        code: &str,
        atem_id: &str,
        conn: &ConnRef,
    ) -> Result<AtemJoin, StoreError> {
        let out: Vec<String> = self
            .eval(
                &self.join_atem,
                code,
                vec![atem_id.to_string(), conn.encode()],
            )
            .await?;
        if at(&out, 0) != "1" {
            return Ok(AtemJoin::NoRoom);
        }
        Ok(AtemJoin::Joined {
            replaced: ConnRef::decode(at(&out, 1)),
            owner: conn_ref(at(&out, 2), at(&out, 3)),
        })
    }

    async fn claim_owner(
        &self,
        code: &str,
        conn: &ConnRef,
        now: i64,
    ) -> Result<OwnerClaim, StoreError> {
        let out: Vec<String> = self
            .eval(
                &self.claim_owner,
                code,
                vec![
                    conn.conn.clone(),
                    conn.replica.clone(),
                    IDENTITY_HOSTNAME.to_string(),
                    now.to_string(),
                    ROOM_EXPIRY_SECS.to_string(),
                ],
            )
            .await?;
        Ok(OwnerClaim {
            replaced: conn_ref(at(&out, 0), at(&out, 1)),
            atems: atem_pairs(out.get(2..).unwrap_or(&[])),
        })
    }

    async fn add_pending(
        &self,
        code: &str,
        conn: &ConnRef,
        now: i64,
        max_pending: usize,
    ) -> Result<bool, StoreError> {
        let admitted: String = self
            .eval(
                &self.add_pending,
                code,
                vec![
                    conn.conn.clone(),
                    conn.replica.clone(),
                    IDENTITY_HOSTNAME.to_string(),
                    now.to_string(),
                    ROOM_EXPIRY_SECS.to_string(),
                    max_pending.to_string(),
                ],
            )
            .await?;
        Ok(admitted == "1")
    }

    async fn promote(
        &self,
        code: &str,
        conn: &ConnRef,
        was_pending: bool,
    ) -> Result<Promotion, StoreError> {
        let out: Vec<String> = self
            .eval(
                &self.promote,
                code,
                vec![
                    conn.conn.clone(),
                    conn.replica.clone(),
                    if was_pending { "1" } else { "0" }.to_string(),
                    ROOM_EXPIRY_SECS.to_string(),
                ],
            )
            .await?;
        Ok(match at(&out, 0) {
            "owner" => Promotion::AlreadyOwner,
            "not_pending" => Promotion::NotPending {
                evicted: conn_ref(at(&out, 1), at(&out, 2)),
            },
            "promoted" => Promotion::Promoted {
                previous_owner: conn_ref(at(&out, 1), at(&out, 2)),
                evicted_unverified: at(&out, 3) == "1",
                atems: atem_pairs(out.get(4..).unwrap_or(&[])),
            },
            _ => Promotion::NoRoom,
        })
    }

    async fn leave_atem(
        &self,
        code: &str,
        atem_id: &str,
        connection_id: &str,
    ) -> Result<AtemLeave, StoreError> {
        let out: Vec<String> = self
            .eval(
                &self.leave_atem,
                code,
                vec![atem_id.to_string(), connection_id.to_string()],
            )
            .await?;
        Ok(AtemLeave {
            removed: at(&out, 0) == "1",
            room_removed: at(&out, 1) == "1",
            owner: conn_ref(at(&out, 2), at(&out, 3)),
        })
    }

    async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError> {
        let removed: String = self
            .eval(&self.leave_astation, code, vec![connection_id.to_string()])
            .await?;
        Ok(removed == "1")
    }

    async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        let out: Vec<Vec<String>> = self.eval(&self.delete_room, code, Vec::new()).await?;
        let (room, atems, pending) = match out.as_slice() {
            [room, atems, pending] => (room, atems, pending),
            _ => return Ok(None),
        };
        Ok(Some(room_info(
            &flat_to_map(room),
            &flat_to_map(atems),
            &flat_to_map(pending),
        )))
    }

    async fn touch(&self, code: &str) -> Result<bool, StoreError> {
        let exists: String = self
            .eval(&self.touch, code, vec![ROOM_EXPIRY_SECS.to_string()])
            .await?;
        Ok(exists == "1")
    }

    async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError> {
        if codes.is_empty() {
            return Ok(Vec::new());
        }
        let room_keys: Vec<String> = codes.iter().map(|code| keys::room(code)).collect();
        self.conn
            .run(|mut c| async move {
                let mut pipe = redis::pipe();
                for key in &room_keys {
                    pipe.exists(key);
                }
                pipe.query_async(&mut c).await
            })
            .await
    }

    /// Redis expires room keys itself.
    async fn remove_expired(&self, _now: i64) -> Result<Vec<String>, StoreError> {
        Ok(Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::directory::scenarios;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

    macro_rules! redis_directory_tests {
        ($($name:ident),* $(,)?) => {
            $(
                #[tokio::test]
                #[ignore]
                async fn $name() {
                    let _guard = REDIS_LOCK.lock().await;
                    let d = RedisRoomDirectory::new(fresh_conn().await);
                    scenarios::$name(&d).await;
                }
            )*
        };
    }

    async fn ttl(conn: &RedisConn, key: &str) -> i64 {
        let key = key.to_string();
        conn.run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
            .await
            .unwrap()
    }

    mod redis_directory {
        use super::*;

        redis_directory_tests!(
            create_get_and_expiry,
            ensure_room_is_idempotent,
            atem_join_requires_a_room_and_replaces,
            claim_owner_creates_the_room_and_replaces_the_owner,
            pending_respects_the_cap,
            add_pending_dedupes_by_connection_id,
            promotion_rules,
            promotion_with_a_squatter_and_a_pending_socket,
            legacy_owner_becomes_verified_when_it_proves,
            leave_atem_ignores_a_stale_connection,
            leaving_last_member_removes_the_room,
            delete_room_returns_its_members,
            touch_and_exists,
        );

        #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
        #[ignore]
        async fn concurrent_promotions_leave_one_owner() {
            let _guard = REDIS_LOCK.lock().await;
            let d = RedisRoomDirectory::new(fresh_conn().await);
            scenarios::concurrent_promotions_leave_one_owner(std::sync::Arc::new(d)).await;
        }

        #[tokio::test]
        #[ignore]
        async fn room_keys_follow_the_spec_and_expire() {
            let _guard = REDIS_LOCK.lock().await;
            let conn = fresh_conn().await;
            let d = RedisRoomDirectory::new(conn.clone());
            d.create_room("ROOM-K", "host", 1_700_000_000)
                .await
                .unwrap();
            d.join_atem("ROOM-K", "atem-a", &ConnRef::new("t1", "r1"))
                .await
                .unwrap();
            d.add_pending("ROOM-K", &ConnRef::new("p1", "r2"), 1_700_000_000, 0)
                .await
                .unwrap();
            let (room, atems, pending): (
                HashMap<String, String>,
                HashMap<String, String>,
                HashMap<String, String>,
            ) = conn
                .run(|mut c| async move {
                    redis::pipe()
                        .hgetall("relay:room:ROOM-K")
                        .hgetall("relay:room:ROOM-K:atems")
                        .hgetall("relay:room:ROOM-K:pending")
                        .query_async(&mut c)
                        .await
                })
                .await
                .unwrap();
            assert_eq!(room["hostname"], "host");
            assert_eq!(room["created_at"], "1700000000");
            assert_eq!(room["owner_conn"], "");
            assert_eq!(room["verified"], "0");
            assert_eq!(room["paired"], "0");
            assert_eq!(atems["atem-a"], "t1|r1");
            assert_eq!(pending["p1"], "r2");
            for key in [
                "relay:room:ROOM-K",
                "relay:room:ROOM-K:atems",
                "relay:room:ROOM-K:pending",
            ] {
                let left = ttl(&conn, key).await;
                assert!((590..=600).contains(&left), "{key} ttl {left}");
            }
            assert!(d.remove_expired(i64::MAX).await.unwrap().is_empty());
        }

        #[tokio::test]
        #[ignore]
        async fn touch_and_claims_refresh_the_room_ttl_redis() {
            let _guard = REDIS_LOCK.lock().await;
            let conn = fresh_conn().await;
            let d = RedisRoomDirectory::new(conn.clone());
            let shorten = |conn: RedisConn| async move {
                conn.run(|mut c| async move {
                    redis::pipe()
                        .cmd("EXPIRE")
                        .arg("relay:room:ROOM-R")
                        .arg(5)
                        .ignore()
                        .cmd("EXPIRE")
                        .arg("relay:room:ROOM-R:atems")
                        .arg(5)
                        .ignore()
                        .cmd("EXPIRE")
                        .arg("relay:room:ROOM-R:pending")
                        .arg(5)
                        .ignore()
                        .query_async::<()>(&mut c)
                        .await
                })
                .await
                .unwrap();
            };
            let all_fresh = |conn: RedisConn| async move {
                for key in [
                    "relay:room:ROOM-R",
                    "relay:room:ROOM-R:atems",
                    "relay:room:ROOM-R:pending",
                ] {
                    let left = ttl(&conn, key).await;
                    assert!((590..=600).contains(&left), "{key} ttl {left}");
                }
            };
            d.create_room("ROOM-R", "h", 1).await.unwrap();
            d.join_atem("ROOM-R", "atem-a", &ConnRef::new("t1", "r1"))
                .await
                .unwrap();
            d.add_pending("ROOM-R", &ConnRef::new("p1", "r1"), 1, 0)
                .await
                .unwrap();

            shorten(conn.clone()).await;
            assert!(d.touch("ROOM-R").await.unwrap());
            all_fresh(conn.clone()).await;

            shorten(conn.clone()).await;
            d.add_pending("ROOM-R", &ConnRef::new("p2", "r1"), 1, 0)
                .await
                .unwrap();
            all_fresh(conn.clone()).await;

            shorten(conn.clone()).await;
            d.claim_owner("ROOM-R", &ConnRef::new("s1", "r1"), 1)
                .await
                .unwrap();
            all_fresh(conn.clone()).await;

            // The owner proving its key (already the owner) keeps the room alive too.
            shorten(conn.clone()).await;
            assert_eq!(
                d.promote("ROOM-R", &ConnRef::new("s1", "r1"), false)
                    .await
                    .unwrap(),
                Promotion::AlreadyOwner
            );
            all_fresh(conn.clone()).await;

            // An Atem joining doesn't extend the room, but its hash follows the room's TTL.
            shorten(conn.clone()).await;
            d.join_atem("ROOM-R", "atem-b", &ConnRef::new("t2", "r1"))
                .await
                .unwrap();
            let left = ttl(&conn, "relay:room:ROOM-R:atems").await;
            assert!((1..=5).contains(&left), "atems ttl {left}");
        }

        #[tokio::test]
        #[ignore]
        async fn a_recreated_room_drops_leftover_members_redis() {
            let _guard = REDIS_LOCK.lock().await;
            let conn = fresh_conn().await;
            let d = RedisRoomDirectory::new(conn.clone());
            // Member hashes left behind without their room (e.g. the room key
            // expired first): a new room must not inherit them.
            let plant = |conn: RedisConn| async move {
                conn.run(|mut c| async move {
                    redis::pipe()
                        .hset("relay:room:ROOM-L:atems", "atem-old", "t0|r0")
                        .ignore()
                        .hset("relay:room:ROOM-L:pending", "p-old", "r0")
                        .ignore()
                        .query_async::<()>(&mut c)
                        .await
                })
                .await
                .unwrap();
            };
            plant(conn.clone()).await;
            assert!(d.ensure_room("ROOM-L", "h", 1).await.unwrap());
            let room = d.get("ROOM-L").await.unwrap().unwrap();
            assert!(
                room.atems.is_empty(),
                "ensure_room inherited {:?}",
                room.atems
            );
            assert!(room.pending.is_empty());

            assert!(d.delete_room("ROOM-L").await.unwrap().is_some());
            plant(conn.clone()).await;
            let claim = d
                .claim_owner("ROOM-L", &ConnRef::new("s1", "r1"), 1)
                .await
                .unwrap();
            assert!(
                claim.atems.is_empty(),
                "claim_owner inherited {:?}",
                claim.atems
            );
            assert!(d.get("ROOM-L").await.unwrap().unwrap().pending.is_empty());

            assert!(d.delete_room("ROOM-L").await.unwrap().is_some());
            plant(conn.clone()).await;
            assert!(d
                .add_pending("ROOM-L", &ConnRef::new("p1", "r1"), 1, 0)
                .await
                .unwrap());
            let room = d.get("ROOM-L").await.unwrap().unwrap();
            assert!(room.atems.is_empty());
            assert_eq!(room.pending.len(), 1);
        }

        #[tokio::test]
        #[ignore]
        async fn room_codes_are_escaped_redis() {
            let _guard = REDIS_LOCK.lock().await;
            let d = RedisRoomDirectory::new(fresh_conn().await);
            d.create_room("X", "h", 1).await.unwrap();
            // "X:atems" must not be room X's Atem hash.
            assert_eq!(
                d.join_atem("X:atems", "atem-a", &ConnRef::new("t1", "r1"))
                    .await
                    .unwrap(),
                AtemJoin::NoRoom
            );
            d.create_room("X:atems", "h2", 2).await.unwrap();
            assert_eq!(d.get("X").await.unwrap().unwrap().hostname, "h");
            assert_eq!(d.get("X:atems").await.unwrap().unwrap().hostname, "h2");
            assert!(d.delete_room("X:atems").await.unwrap().is_some());
            assert!(d.get("X").await.unwrap().is_some());
        }
    }
}
