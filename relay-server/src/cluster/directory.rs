//! Room membership and ownership (spec: "Rooms and message flow"). A room
//! is keyed by its code and records the owning Astation connection, the
//! pending (unproven) Astation connections, and one connection per Atem.
//! Connections are `ConnRef`s, so a room can span replicas.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

use async_trait::async_trait;

use super::{ConnRef, StoreError};

/// An unpaired room lives this long (today's ROOM_EXPIRY_SECS).
pub const ROOM_EXPIRY_SECS: i64 = 600;

/// Hostname of a room an Astation creates by connecting (identity room).
pub const IDENTITY_HOSTNAME: &str = "identity";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomInfo {
    pub hostname: String,
    /// Unix seconds.
    pub created_at: i64,
    pub owner: Option<ConnRef>,
    /// The owner proved the room's registered key.
    pub verified: bool,
    /// atem_id → its current connection.
    pub atems: BTreeMap<String, ConnRef>,
    /// Astation connections that must prove the key first. Sorted.
    pub pending: Vec<ConnRef>,
    /// Pending connection id → the client IP it connected from (the
    /// per-IP pending cap counts these).
    pub pending_ips: BTreeMap<String, String>,
}

/// Caps on a room's pending Astation sockets; 0 means no cap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PendingCaps {
    /// Pending sockets from one client IP.
    pub per_ip: usize,
    /// Pending sockets in total.
    pub per_room: usize,
}

impl PendingCaps {
    // Used by tests and the directory scenarios.
    #[allow(dead_code)]
    pub const NONE: Self = Self { per_ip: 0, per_room: 0 };
}

impl RoomInfo {
    pub fn new(hostname: &str, created_at: i64) -> Self {
        Self {
            hostname: hostname.to_string(),
            created_at,
            owner: None,
            verified: false,
            atems: BTreeMap::new(),
            pending: Vec::new(),
            pending_ips: BTreeMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.atems.is_empty() && self.owner.is_none() && self.pending.is_empty()
    }

    /// No Astation owns it and it is older than ROOM_EXPIRY_SECS.
    pub fn is_expired(&self, now: i64) -> bool {
        self.owner.is_none() && now - self.created_at >= ROOM_EXPIRY_SECS
    }

    fn keep_on_sweep(&self, now: i64) -> bool {
        now - self.created_at < ROOM_EXPIRY_SECS || self.owner.is_some() || !self.pending.is_empty()
    }

    /// Whether one more pending socket from `ip` fits under `caps`.
    fn admits_pending(&self, ip: &str, caps: PendingCaps) -> bool {
        if caps.per_room > 0 && self.pending.len() >= caps.per_room {
            return false;
        }
        let from_ip = self
            .pending
            .iter()
            .filter(|pending| self.pending_ips.get(&pending.conn).map(String::as_str) == Some(ip))
            .count();
        caps.per_ip == 0 || from_ip < caps.per_ip
    }

    /// Add `conn` to pending (a connection id already pending is admitted
    /// unchanged). False when `caps` are full.
    fn try_pending(&mut self, conn: &ConnRef, ip: &str, caps: PendingCaps) -> bool {
        if self.pending.iter().any(|p| p.conn == conn.conn) {
            return true;
        }
        if !self.admits_pending(ip, caps) {
            return false;
        }
        self.pending.push(conn.clone());
        self.pending.sort();
        self.pending_ips.insert(conn.conn.clone(), ip.to_string());
        true
    }

    fn remove_pending(&mut self, connection_id: &str) {
        self.pending.retain(|pending| pending.conn != connection_id);
        self.pending_ips.remove(connection_id);
    }

    fn atem_list(&self) -> Vec<(String, ConnRef)> {
        self.atems
            .iter()
            .map(|(id, conn)| (id.clone(), conn.clone()))
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AtemJoin {
    NoRoom,
    Joined {
        /// The Atem's previous connection (to be closed).
        replaced: Option<ConnRef>,
        /// The room owner (to be told `relay_event: connected`).
        owner: Option<ConnRef>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OwnerClaim {
    /// The caller owns the room now (unverified).
    Claimed {
        /// The previous, unverified owner (to be closed).
        replaced: Option<ConnRef>,
        /// The room's Atems (the new owner is told about each).
        atems: Vec<(String, ConnRef)>,
    },
    /// A verified owner holds the room, so the caller was added to pending
    /// instead: it must prove the key like any keyed Astation. (The
    /// directory is authoritative; the caller's key cache may lack a key
    /// registered on another replica.)
    Pending,
    /// As `Pending`, but the pending caps are full: the caller is refused.
    TooManyPending,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Promotion {
    NoRoom,
    /// The connection already owned the room; it is now verified.
    AlreadyOwner,
    /// Not pending (or no longer): at most an unverified owner was evicted.
    NotPending { evicted: Option<ConnRef> },
    /// The pending connection now owns the room.
    Promoted {
        /// The replaced owner (to be closed).
        previous_owner: Option<ConnRef>,
        /// `previous_owner` had not proved the key (evicted, not replaced).
        evicted_unverified: bool,
        atems: Vec<(String, ConnRef)>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AtemLeave {
    /// The leaving connection was the Atem's current one.
    pub removed: bool,
    pub owner: Option<ConnRef>,
    pub room_removed: bool,
}

#[async_trait]
pub trait RoomDirectory: Send + Sync {
    fn backend_name(&self) -> &'static str;
    /// POST /api/pair: a fresh room (replaces any room with this code).
    // Task 13 (RedisRoomDirectory) and the Task 21 tests.
    #[allow(dead_code)]
    async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError>;
    /// Create the room if missing. True when it was created.
    async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError>;
    async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError>;
    async fn join_atem(&self, code: &str, atem_id: &str, conn: &ConnRef) -> Result<AtemJoin, StoreError>;
    /// A legacy (keyless) Astation takes the room, creating it if missing,
    /// and replaces an unverified owner. A verified owner is never replaced
    /// here: the caller joins pending instead (under `caps`, as
    /// `add_pending`).
    async fn claim_owner(
        &self,
        code: &str,
        conn: &ConnRef,
        ip: &str,
        now: i64,
        caps: PendingCaps,
    ) -> Result<OwnerClaim, StoreError>;
    /// A keyed Astation (connected from client `ip`) waits to prove its
    /// key. False when `caps` are full: too many pending sockets from that
    /// IP, or in the room.
    async fn add_pending(
        &self,
        code: &str,
        conn: &ConnRef,
        ip: &str,
        now: i64,
        caps: PendingCaps,
    ) -> Result<bool, StoreError>;
    /// Room bookkeeping after `conn` proved the room's key, atomically.
    async fn promote(&self, code: &str, conn: &ConnRef, was_pending: bool) -> Result<Promotion, StoreError>;
    /// Remove the Atem only if `connection_id` is its current connection.
    async fn leave_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Result<AtemLeave, StoreError>;
    /// Remove a pending or owning Astation connection. True if the room was removed.
    async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError>;
    /// Remove the room; returns its members so their sockets can be closed.
    async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError>;
    /// Heartbeat from a replica holding an Astation socket: keep the room alive.
    async fn touch(&self, code: &str) -> Result<bool, StoreError>;
    async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError>;
    /// Sweep expired rooms (in-memory only; Redis expires keys itself).
    async fn remove_expired(&self, now: i64) -> Result<Vec<String>, StoreError>;
}

/// In-memory directory: one mutex over all rooms, so every call is atomic.
#[derive(Clone, Default)]
pub struct InMemoryRoomDirectory {
    rooms: Arc<Mutex<HashMap<String, RoomInfo>>>,
}

impl InMemoryRoomDirectory {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, RoomInfo>> {
        self.rooms.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    pub(crate) fn insert_for_test(&self, code: &str, room: RoomInfo) {
        self.lock().insert(code.to_string(), room);
    }
}

#[async_trait]
impl RoomDirectory for InMemoryRoomDirectory {
    fn backend_name(&self) -> &'static str {
        "memory"
    }

    async fn create_room(&self, code: &str, hostname: &str, now: i64) -> Result<(), StoreError> {
        self.lock().insert(code.to_string(), RoomInfo::new(hostname, now));
        Ok(())
    }

    async fn ensure_room(&self, code: &str, hostname: &str, now: i64) -> Result<bool, StoreError> {
        let mut rooms = self.lock();
        if rooms.contains_key(code) {
            return Ok(false);
        }
        rooms.insert(code.to_string(), RoomInfo::new(hostname, now));
        Ok(true)
    }

    async fn get(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        Ok(self.lock().get(code).cloned())
    }

    async fn join_atem(&self, code: &str, atem_id: &str, conn: &ConnRef) -> Result<AtemJoin, StoreError> {
        let mut rooms = self.lock();
        let Some(room) = rooms.get_mut(code) else {
            return Ok(AtemJoin::NoRoom);
        };
        let replaced = room.atems.insert(atem_id.to_string(), conn.clone());
        Ok(AtemJoin::Joined {
            replaced,
            owner: room.owner.clone(),
        })
    }

    async fn claim_owner(
        &self,
        code: &str,
        conn: &ConnRef,
        ip: &str,
        now: i64,
        caps: PendingCaps,
    ) -> Result<OwnerClaim, StoreError> {
        let mut rooms = self.lock();
        let room = rooms
            .entry(code.to_string())
            .or_insert_with(|| RoomInfo::new(IDENTITY_HOSTNAME, now));
        if room.owner.is_some() && room.verified {
            return Ok(if room.try_pending(conn, ip, caps) {
                OwnerClaim::Pending
            } else {
                OwnerClaim::TooManyPending
            });
        }
        let replaced = room.owner.replace(conn.clone());
        room.verified = false;
        Ok(OwnerClaim::Claimed {
            replaced,
            atems: room.atem_list(),
        })
    }

    async fn add_pending(
        &self,
        code: &str,
        conn: &ConnRef,
        ip: &str,
        now: i64,
        caps: PendingCaps,
    ) -> Result<bool, StoreError> {
        let mut rooms = self.lock();
        let room = rooms
            .entry(code.to_string())
            .or_insert_with(|| RoomInfo::new(IDENTITY_HOSTNAME, now));
        Ok(room.try_pending(conn, ip, caps))
    }

    async fn promote(&self, code: &str, conn: &ConnRef, was_pending: bool) -> Result<Promotion, StoreError> {
        let mut rooms = self.lock();
        let Some(room) = rooms.get_mut(code) else {
            return Ok(Promotion::NoRoom);
        };
        if room.owner.as_ref().map(|owner| owner.conn == conn.conn).unwrap_or(false) {
            room.verified = true;
            return Ok(Promotion::AlreadyOwner);
        }
        let previous_owner = room.owner.clone();
        let mut evicted = None;
        if room.owner.is_some() && !room.verified {
            evicted = room.owner.take();
        }
        let position = room.pending.iter().position(|pending| pending.conn == conn.conn);
        let Some(position) = position.filter(|_| was_pending) else {
            return Ok(Promotion::NotPending { evicted });
        };
        room.pending.remove(position);
        room.pending_ips.remove(&conn.conn);
        room.owner = Some(conn.clone());
        room.verified = true;
        Ok(Promotion::Promoted {
            previous_owner,
            evicted_unverified: evicted.is_some(),
            atems: room.atem_list(),
        })
    }

    async fn leave_atem(&self, code: &str, atem_id: &str, connection_id: &str) -> Result<AtemLeave, StoreError> {
        let mut rooms = self.lock();
        let Some(room) = rooms.get_mut(code) else {
            return Ok(AtemLeave { removed: false, owner: None, room_removed: false });
        };
        let removed = room
            .atems
            .get(atem_id)
            .map(|current| current.conn == connection_id)
            .unwrap_or(false);
        if removed {
            room.atems.remove(atem_id);
        }
        let owner = room.owner.clone();
        let room_removed = room.is_empty();
        if room_removed {
            rooms.remove(code);
        }
        Ok(AtemLeave { removed, owner, room_removed })
    }

    async fn leave_astation(&self, code: &str, connection_id: &str) -> Result<bool, StoreError> {
        let mut rooms = self.lock();
        let Some(room) = rooms.get_mut(code) else {
            return Ok(false);
        };
        room.remove_pending(connection_id);
        if room.owner.as_ref().map(|owner| owner.conn == connection_id).unwrap_or(false) {
            room.owner = None;
            room.verified = false;
        }
        let room_removed = room.is_empty();
        if room_removed {
            rooms.remove(code);
        }
        Ok(room_removed)
    }

    async fn delete_room(&self, code: &str) -> Result<Option<RoomInfo>, StoreError> {
        Ok(self.lock().remove(code))
    }

    async fn touch(&self, code: &str) -> Result<bool, StoreError> {
        Ok(self.lock().contains_key(code))
    }

    async fn exists(&self, codes: &[String]) -> Result<Vec<bool>, StoreError> {
        let rooms = self.lock();
        Ok(codes.iter().map(|code| rooms.contains_key(code)).collect())
    }

    async fn remove_expired(&self, now: i64) -> Result<Vec<String>, StoreError> {
        let mut rooms = self.lock();
        let expired: Vec<String> = rooms
            .iter()
            .filter(|(_, room)| !room.keep_on_sweep(now))
            .map(|(code, _)| code.clone())
            .collect();
        for code in &expired {
            rooms.remove(code);
        }
        Ok(expired)
    }
}

#[cfg(test)]
pub(crate) mod scenarios {
    //! Backend-independent directory behavior, run against the in-memory
    //! directory here and against Redis in `cluster::redis::directory`.
    use super::*;
    use std::sync::Arc;

    const T0: i64 = 1_700_000_000;
    /// The client address of pending sockets unless a scenario varies it.
    const IP: &str = "192.0.2.1";

    fn c(conn: &str, replica: &str) -> ConnRef {
        ConnRef::new(conn, replica)
    }

    pub async fn create_get_and_expiry(d: &dyn RoomDirectory) {
        assert_eq!(d.get("ROOM-1").await.unwrap(), None);
        d.create_room("ROOM-1", "host-1", T0).await.unwrap();
        let room = d.get("ROOM-1").await.unwrap().expect("created");
        assert_eq!(room, RoomInfo::new("host-1", T0));
        assert!(!room.is_expired(T0 + ROOM_EXPIRY_SECS - 1));
        assert!(room.is_expired(T0 + ROOM_EXPIRY_SECS));
    }

    pub async fn ensure_room_is_idempotent(d: &dyn RoomDirectory) {
        assert!(d.ensure_room("astation-1", IDENTITY_HOSTNAME, T0).await.unwrap());
        assert!(!d.ensure_room("astation-1", "other", T0 + 5).await.unwrap());
        let room = d.get("astation-1").await.unwrap().unwrap();
        assert_eq!((room.hostname.as_str(), room.created_at), (IDENTITY_HOSTNAME, T0));
    }

    pub async fn atem_join_requires_a_room_and_replaces(d: &dyn RoomDirectory) {
        assert_eq!(
            d.join_atem("NOPE", "atem-a", &c("t1", "r1")).await.unwrap(),
            AtemJoin::NoRoom
        );
        d.create_room("ROOM", "h", T0).await.unwrap();
        assert_eq!(
            d.join_atem("ROOM", "atem-a", &c("t1", "r1")).await.unwrap(),
            AtemJoin::Joined { replaced: None, owner: None }
        );
        d.claim_owner("ROOM", &c("s1", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(
            d.join_atem("ROOM", "atem-a", &c("t2", "r2")).await.unwrap(),
            AtemJoin::Joined {
                replaced: Some(c("t1", "r1")),
                owner: Some(c("s1", "r2")),
            }
        );
        let room = d.get("ROOM").await.unwrap().unwrap();
        assert_eq!(room.atems.get("atem-a"), Some(&c("t2", "r2")));
    }

    pub async fn claim_owner_creates_the_room_and_replaces_the_owner(d: &dyn RoomDirectory) {
        let first = d.claim_owner("astation-x", &c("s1", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(first, OwnerClaim::Claimed { replaced: None, atems: vec![] });
        let room = d.get("astation-x").await.unwrap().unwrap();
        assert_eq!(room.hostname, IDENTITY_HOSTNAME);
        assert_eq!(room.owner, Some(c("s1", "r1")));
        assert!(!room.verified);
        d.join_atem("astation-x", "atem-a", &c("t1", "r2")).await.unwrap();
        let second = d.claim_owner("astation-x", &c("s2", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(
            second,
            OwnerClaim::Claimed {
                replaced: Some(c("s1", "r1")),
                atems: vec![("atem-a".to_string(), c("t1", "r2"))],
            }
        );
    }

    /// A verified owner is never displaced by a claim: the claimant goes
    /// pending (under the caps) and the owner stays verified.
    pub async fn claim_owner_waits_behind_a_verified_owner(d: &dyn RoomDirectory) {
        let caps = PendingCaps { per_ip: 1, per_room: 0 };
        d.claim_owner("astation-v", &c("s1", "r1"), IP, T0, caps).await.unwrap();
        d.join_atem("astation-v", "atem-a", &c("t1", "r2")).await.unwrap();
        assert_eq!(
            d.promote("astation-v", &c("s1", "r1"), false).await.unwrap(),
            Promotion::AlreadyOwner
        );
        assert_eq!(
            d.claim_owner("astation-v", &c("squatter", "r2"), IP, T0, caps).await.unwrap(),
            OwnerClaim::Pending
        );
        assert_eq!(
            d.claim_owner("astation-v", &c("another", "r2"), IP, T0, caps).await.unwrap(),
            OwnerClaim::TooManyPending
        );
        let room = d.get("astation-v").await.unwrap().unwrap();
        assert_eq!(room.owner, Some(c("s1", "r1")));
        assert!(room.verified);
        assert_eq!(room.pending, vec![c("squatter", "r2")]);
        assert_eq!(room.pending_ips.get("squatter").map(String::as_str), Some(IP));
        // Proving the key promotes the waiting claimant (an ordinary reconnect).
        assert_eq!(
            d.promote("astation-v", &c("squatter", "r2"), true).await.unwrap(),
            Promotion::Promoted {
                previous_owner: Some(c("s1", "r1")),
                evicted_unverified: false,
                atems: vec![("atem-a".to_string(), c("t1", "r2"))],
            }
        );
        // Once the verified owner leaves, a claim takes the room again.
        d.leave_astation("astation-v", "squatter").await.unwrap();
        assert!(matches!(
            d.claim_owner("astation-v", &c("legacy", "r1"), IP, T0, caps).await.unwrap(),
            OwnerClaim::Claimed { replaced: None, .. }
        ));
    }

    pub async fn pending_respects_the_caps(d: &dyn RoomDirectory) {
        let caps = PendingCaps { per_ip: 2, per_room: 4 };
        let (ip_a, ip_b, ip_c) = ("203.0.113.1", "203.0.113.2", "2001:db8::3");
        assert!(d.add_pending("astation-p", &c("p1", "r1"), ip_a, T0, caps).await.unwrap());
        assert!(d.add_pending("astation-p", &c("p2", "r2"), ip_a, T0, caps).await.unwrap());
        // A third from one address is refused; another address still fits.
        assert!(!d.add_pending("astation-p", &c("p3", "r1"), ip_a, T0, caps).await.unwrap());
        assert!(d.add_pending("astation-p", &c("p4", "r1"), ip_b, T0, caps).await.unwrap());
        assert!(d.add_pending("astation-p", &c("p5", "r2"), ip_c, T0, caps).await.unwrap());
        // The room as a whole is full.
        assert!(!d.add_pending("astation-p", &c("p6", "r2"), "198.51.100.9", T0, caps).await.unwrap());
        assert!(
            d.add_pending("astation-p", &c("p3", "r1"), ip_a, T0, PendingCaps::NONE).await.unwrap(),
            "0 means no cap"
        );
        let room = d.get("astation-p").await.unwrap().unwrap();
        assert_eq!(
            room.pending,
            vec![c("p1", "r1"), c("p2", "r2"), c("p3", "r1"), c("p4", "r1"), c("p5", "r2")]
        );
        assert_eq!(room.pending_ips.get("p4").map(String::as_str), Some(ip_b));
        assert_eq!(room.pending_ips.get("p5").map(String::as_str), Some(ip_c));
        assert_eq!(room.owner, None);
        assert_eq!(room.hostname, IDENTITY_HOSTNAME);
        // Slots freed by leaving or by promotion count no more.
        let per_ip_3 = PendingCaps { per_ip: 3, per_room: 0 };
        assert!(!d.leave_astation("astation-p", "p1").await.unwrap());
        assert!(!d.add_pending("astation-p", &c("p7", "r1"), ip_a, T0, PendingCaps { per_ip: 2, per_room: 0 }).await.unwrap());
        assert!(d.add_pending("astation-p", &c("p7", "r1"), ip_a, T0, per_ip_3).await.unwrap());
        assert!(matches!(
            d.promote("astation-p", &c("p7", "r1"), true).await.unwrap(),
            Promotion::Promoted { .. }
        ));
        let room = d.get("astation-p").await.unwrap().unwrap();
        assert!(!room.pending_ips.contains_key("p1"));
        assert!(!room.pending_ips.contains_key("p7"));
        assert!(d.add_pending("astation-p", &c("p8", "r1"), ip_a, T0, per_ip_3).await.unwrap());
    }

    pub async fn promotion_rules(d: &dyn RoomDirectory) {
        assert_eq!(
            d.promote("none", &c("x", "r1"), true).await.unwrap(),
            Promotion::NoRoom
        );
        // An unverified owner (squatter) plus a pending socket.
        d.claim_owner("astation-race", &c("squatter", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.add_pending("astation-race", &c("pending", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.join_atem("astation-race", "atem-a", &c("t1", "r1")).await.unwrap();

        // A verifier that is not pending (its socket was replaced) only evicts the squatter.
        assert_eq!(
            d.promote("astation-race", &c("registrar", "r1"), false).await.unwrap(),
            Promotion::NotPending { evicted: Some(c("squatter", "r1")) }
        );
        assert_eq!(d.get("astation-race").await.unwrap().unwrap().owner, None);

        // The pending socket takes over and learns the Atems.
        assert_eq!(
            d.promote("astation-race", &c("pending", "r2"), true).await.unwrap(),
            Promotion::Promoted {
                previous_owner: None,
                evicted_unverified: false,
                atems: vec![("atem-a".to_string(), c("t1", "r1"))],
            }
        );
        let room = d.get("astation-race").await.unwrap().unwrap();
        assert_eq!(room.owner, Some(c("pending", "r2")));
        assert!(room.verified);
        assert!(room.pending.is_empty());

        // The owner proving again is only marked verified.
        assert_eq!(
            d.promote("astation-race", &c("pending", "r2"), false).await.unwrap(),
            Promotion::AlreadyOwner
        );
        // A stale non-pending verifier leaves a verified owner alone.
        assert_eq!(
            d.promote("astation-race", &c("stale", "r1"), false).await.unwrap(),
            Promotion::NotPending { evicted: None }
        );
        // A pending reconnect replaces the verified owner (an ordinary reconnect).
        d.add_pending("astation-race", &c("again", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(
            d.promote("astation-race", &c("again", "r1"), true).await.unwrap(),
            Promotion::Promoted {
                previous_owner: Some(c("pending", "r2")),
                evicted_unverified: false,
                atems: vec![("atem-a".to_string(), c("t1", "r1"))],
            }
        );
    }

    pub async fn promotion_with_a_squatter_and_a_pending_socket(d: &dyn RoomDirectory) {
        d.claim_owner("astation-sq", &c("squatter", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.add_pending("astation-sq", &c("pending", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(
            d.promote("astation-sq", &c("pending", "r2"), true).await.unwrap(),
            Promotion::Promoted {
                previous_owner: Some(c("squatter", "r1")),
                evicted_unverified: true,
                atems: vec![],
            }
        );
        let room = d.get("astation-sq").await.unwrap().unwrap();
        assert_eq!(room.owner, Some(c("pending", "r2")));
        assert!(room.verified);
        assert!(room.pending.is_empty());
    }

    pub async fn add_pending_dedupes_by_connection_id(d: &dyn RoomDirectory) {
        let one = PendingCaps { per_ip: 1, per_room: 1 };
        assert!(d.add_pending("astation-dd", &c("p1", "r1"), IP, T0, one).await.unwrap());
        // Same connection id (even with another replica label): already pending, cap not hit.
        assert!(d.add_pending("astation-dd", &c("p1", "r2"), IP, T0, one).await.unwrap());
        assert_eq!(
            d.get("astation-dd").await.unwrap().unwrap().pending,
            vec![c("p1", "r1")]
        );
    }

    pub async fn legacy_owner_becomes_verified_when_it_proves(d: &dyn RoomDirectory) {
        d.claim_owner("astation-l", &c("s1", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        assert_eq!(
            d.promote("astation-l", &c("s1", "r1"), false).await.unwrap(),
            Promotion::AlreadyOwner
        );
        assert!(d.get("astation-l").await.unwrap().unwrap().verified);
    }

    pub async fn leave_atem_ignores_a_stale_connection(d: &dyn RoomDirectory) {
        d.claim_owner("astation-s", &c("s1", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.join_atem("astation-s", "atem-office", &c("replacement", "r2")).await.unwrap();
        assert_eq!(
            d.leave_atem("astation-s", "atem-office", "stale").await.unwrap(),
            AtemLeave { removed: false, owner: Some(c("s1", "r1")), room_removed: false }
        );
        assert_eq!(
            d.leave_atem("astation-s", "atem-office", "replacement").await.unwrap(),
            AtemLeave { removed: true, owner: Some(c("s1", "r1")), room_removed: false }
        );
        assert!(d.get("astation-s").await.unwrap().unwrap().atems.is_empty());
        assert_eq!(
            d.leave_atem("missing", "a", "c").await.unwrap(),
            AtemLeave { removed: false, owner: None, room_removed: false }
        );
    }

    pub async fn leaving_last_member_removes_the_room(d: &dyn RoomDirectory) {
        d.claim_owner("astation-e", &c("s1", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.add_pending("astation-e", &c("p1", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.join_atem("astation-e", "atem-a", &c("t1", "r2")).await.unwrap();
        assert!(!d.leave_astation("astation-e", "p1").await.unwrap());
        assert!(!d.leave_astation("astation-e", "someone-else").await.unwrap());
        assert!(!d.leave_astation("astation-e", "s1").await.unwrap());
        let room = d.get("astation-e").await.unwrap().unwrap();
        assert_eq!(room.owner, None);
        assert!(!room.verified);
        assert!(room.pending.is_empty());
        assert_eq!(
            d.leave_atem("astation-e", "atem-a", "t1").await.unwrap(),
            AtemLeave { removed: true, owner: None, room_removed: true }
        );
        assert_eq!(d.get("astation-e").await.unwrap(), None);
        assert!(!d.leave_astation("astation-e", "s1").await.unwrap());
    }

    pub async fn delete_room_returns_its_members(d: &dyn RoomDirectory) {
        assert_eq!(d.delete_room("nope").await.unwrap(), None);
        d.claim_owner("ROOM-D", &c("s1", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.add_pending("ROOM-D", &c("p1", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.join_atem("ROOM-D", "atem-a", &c("t1", "r2")).await.unwrap();
        let room = d.delete_room("ROOM-D").await.unwrap().expect("members");
        assert_eq!(room.owner, Some(c("s1", "r1")));
        assert_eq!(room.pending, vec![c("p1", "r2")]);
        assert_eq!(room.atems.get("atem-a"), Some(&c("t1", "r2")));
        assert_eq!(d.get("ROOM-D").await.unwrap(), None);
    }

    pub async fn touch_and_exists(d: &dyn RoomDirectory) {
        d.create_room("ROOM-T", "h", T0).await.unwrap();
        assert!(d.touch("ROOM-T").await.unwrap());
        assert!(!d.touch("ROOM-GONE").await.unwrap());
        assert_eq!(
            d.exists(&["ROOM-T".to_string(), "ROOM-GONE".to_string()]).await.unwrap(),
            vec![true, false]
        );
        assert_eq!(d.exists(&[]).await.unwrap(), Vec::<bool>::new());
    }

    /// Two sockets proving at once: one ends as owner, and its promotion
    /// names the other as the previous owner (so the other gets closed).
    pub async fn concurrent_promotions_leave_one_owner(d: Arc<dyn RoomDirectory>) {
        d.claim_owner("astation-c", &c("old", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.promote("astation-c", &c("old", "r1"), false).await.unwrap();
        d.add_pending("astation-c", &c("a", "r1"), IP, T0, PendingCaps::NONE).await.unwrap();
        d.add_pending("astation-c", &c("b", "r2"), IP, T0, PendingCaps::NONE).await.unwrap();
        let (da, db) = (d.clone(), d.clone());
        let (ra, rb) = tokio::join!(
            tokio::spawn(async move { da.promote("astation-c", &c("a", "r1"), true).await.unwrap() }),
            tokio::spawn(async move { db.promote("astation-c", &c("b", "r2"), true).await.unwrap() }),
        );
        let (ra, rb) = (ra.unwrap(), rb.unwrap());
        let owner = d
            .get("astation-c")
            .await
            .unwrap()
            .unwrap()
            .owner
            .expect("an owner");
        let (winner, loser) = if owner.conn == "a" { (ra, "b") } else { (rb, "a") };
        match winner {
            Promotion::Promoted { previous_owner: Some(previous), .. } => {
                assert_eq!(previous.conn, loser)
            }
            other => panic!("the winner's promotion was {other:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    macro_rules! memory_directory_tests {
        ($($name:ident),* $(,)?) => {
            $(
                #[tokio::test]
                async fn $name() {
                    let d = InMemoryRoomDirectory::new();
                    scenarios::$name(&d).await;
                }
            )*
        };
    }

    memory_directory_tests!(
        create_get_and_expiry,
        ensure_room_is_idempotent,
        atem_join_requires_a_room_and_replaces,
        claim_owner_creates_the_room_and_replaces_the_owner,
        claim_owner_waits_behind_a_verified_owner,
        pending_respects_the_caps,
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
    async fn concurrent_promotions_leave_one_owner() {
        scenarios::concurrent_promotions_leave_one_owner(std::sync::Arc::new(
            InMemoryRoomDirectory::new(),
        ))
        .await;
    }

    #[tokio::test]
    async fn remove_expired_keeps_rooms_with_an_astation() {
        let d = InMemoryRoomDirectory::new();
        let now = 1_700_000_000;
        let old = now - ROOM_EXPIRY_SECS - 10;
        d.insert_for_test("OLD", RoomInfo::new("h", old));
        d.insert_for_test("NEW", RoomInfo::new("h", now));
        d.insert_for_test(
            "OWNED",
            RoomInfo { owner: Some(ConnRef::new("s", "r")), ..RoomInfo::new("h", old) },
        );
        d.insert_for_test(
            "PENDING",
            RoomInfo { pending: vec![ConnRef::new("p", "r")], ..RoomInfo::new("h", old) },
        );
        let mut atems = BTreeMap::new();
        atems.insert("atem".to_string(), ConnRef::new("t", "r"));
        d.insert_for_test("ATEM-ONLY", RoomInfo { atems, ..RoomInfo::new("h", old) });
        let mut removed = d.remove_expired(now).await.unwrap();
        removed.sort();
        assert_eq!(removed, vec!["ATEM-ONLY".to_string(), "OLD".to_string()]);
        assert!(d.get("NEW").await.unwrap().is_some());
        assert!(d.get("OWNED").await.unwrap().is_some());
        assert!(d.get("PENDING").await.unwrap().is_some());
    }
}
