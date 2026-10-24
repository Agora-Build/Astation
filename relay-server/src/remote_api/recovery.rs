//! Account login gates storage visibility; the signed log and native pins own trust.
use std::{
    collections::{BTreeMap, HashMap},
    sync::{Arc, OnceLock},
    time::Instant,
};

use atem_client::{
    backup::KBackupEnvelope,
    canonical::{jcs, StrictValue},
    membership::{Action, Check, Entry, Head, HostNow, MemberStatus, Membership},
    Hash32,
    host_route::{verify_host_route_message, HostRouteRefusal, RelayReply},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::PgPool;
use tokio::sync::Mutex;

use crate::{account_store::VerifyError, AppState};

const MAX_PAGE: usize = 262_144;
const MAX_STATE: usize = 16 * 1024 * 1024;
const MAX_INTEGER: u64 = 9_007_199_254_740_991;
type Reply = (StatusCode, Json<Value>);

fn error(status: StatusCode, code: &'static str) -> Reply {
    (status, Json(json!({"error":{"code":code}})))
}
fn invalid() -> Reply {
    error(StatusCode::BAD_REQUEST, "invalid_recovery_record")
}
fn unavailable() -> Reply {
    error(
        StatusCode::SERVICE_UNAVAILABLE,
        "recovery_storage_unavailable",
    )
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Blob {
    bytes: String,
    uploaded_at: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Root {
    account: String,
    membership: Value,
    blobs: BTreeMap<u64, Blob>,
    #[serde(default)]
    push: super::push_ingress::PushState,
    #[serde(default)]
    routes: BTreeMap<String, HostBinding>,
}

/// A fresh connection is the generation fence. Presence never substitutes for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HostBinding {
    pub genesis: String,
    pub host: String,
    pub connection: crate::cluster::ConnRef,
    pub room: String,
    pub atem_id: String,
    nonce: [u8; 32],
    proof: String,
}

#[derive(Debug)]
pub(crate) enum HostRouteError {
    Refused(Value),
    Unavailable,
}

/// Carrier A has no route proof; it is usable only while this exact room owner
/// and host connection remain present. A proved replacement still fences it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct OwnerRoute {
    pub genesis: String,
    pub host: String,
    pub room: String,
    pub connection: crate::cluster::ConnRef,
    pub host_trust_gen: u64,
}

impl HostBinding {
    fn valid(&self, log: &Membership) -> bool {
        verify_host_route_message(
            log,
            self.proof.as_bytes(),
            &self.nonce,
            &self.room,
            &self.atem_id,
        )
        .is_ok_and(|route| {
            route.host_id == self.host && log.genesis_hash().to_hex() == self.genesis
        })
    }
}

/// One root is the transaction/lock unit, including envelope retention and CAS.
pub struct RecoveryStore {
    pool: Option<PgPool>,
    memory: Option<Mutex<HashMap<String, (String, Root)>>>,
}

impl RecoveryStore {
    pub(crate) async fn admit_host(
        &self,
        text: &str,
        nonce: [u8; 32],
        room: &str,
        atem_id: &str,
        connection: crate::cluster::ConnRef,
    ) -> Result<(HostBinding, Value), HostRouteError> {
        // This untrusted selector only locates the anchored log. The shared verifier
        // validates the exact message and its account, head, key and challenge.
        let malformed = || {
            HostRouteError::Refused(
                RelayReply::refused(&HostRouteRefusal::Malformed("message")).to_json(),
            )
        };
        let value = StrictValue::parse(text.as_bytes(), 16_384).map_err(|_| malformed())?;
        let genesis = value.value()["proof"]["body"]["genesis_hash"]
            .as_str()
            .ok_or_else(malformed)?;
        let reply = self
            .perform_scoped(
                genesis,
                None,
                Operation::HostRoute {
                    text: text.into(),
                    nonce,
                    room: room.into(),
                    atem_id: atem_id.into(),
                    connection,
                },
            )
            .await;
        if reply.0 != StatusCode::OK {
            return Err(if reply.0 == StatusCode::SERVICE_UNAVAILABLE {
                HostRouteError::Unavailable
            } else {
                HostRouteError::Refused(if reply.1 .0["type"] == "relay" {
                    reply.1 .0
                } else {
                    RelayReply::refused(&HostRouteRefusal::UnknownHost).to_json()
                })
            });
        }
        Ok((
            serde_json::from_value(reply.1 .0["binding"].clone()).map_err(|_| malformed())?,
            reply.1 .0,
        ))
    }

    /// Keep the membership/binding lock until queue admission or presence publication.
    /// The action must not recursively enter this store or wait for a peer's ACK.
    pub(crate) async fn with_host_route<T, F, Fut>(
        &self,
        binding: &HostBinding,
        action: F,
    ) -> Option<T>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        self.with_root(
            &binding.genesis,
            |root, log| root.routes.get(&binding.host) == Some(binding) && binding.valid(log),
            action,
        )
        .await
    }

    pub(crate) async fn with_owner_route<T, F, Fut>(
        &self,
        route: &OwnerRoute,
        action: F,
    ) -> Option<T>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        self.with_root(
            &route.genesis,
            |root, log| {
                log.host(&route.host)
                    .is_some_and(|host| host.host_trust_gen == route.host_trust_gen)
                    && root
                        .routes
                        .get(&route.host)
                        .filter(|binding| binding.valid(log))
                        .is_none_or(|binding| binding.connection == route.connection)
            },
            action,
        )
        .await
    }

    async fn with_root<T, P, F, Fut>(&self, genesis: &str, predicate: P, action: F) -> Option<T>
    where
        P: FnOnce(&Root, &Membership) -> bool,
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        tokio::time::timeout(
            std::time::Duration::from_secs(3),
            self.with_root_inner(genesis, predicate, action),
        )
        .await
        .ok()
        .flatten()
    }

    async fn with_root_inner<T, P, F, Fut>(
        &self,
        genesis: &str,
        predicate: P,
        action: F,
    ) -> Option<T>
    where
        P: FnOnce(&Root, &Membership) -> bool,
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        let valid = |root: &Root| {
            let Ok(hash) = Hash32::from_hex(genesis) else {
                return false;
            };
            let Ok(mut log) = Membership::from_stored(&root.account, &hash, &root.membership)
            else {
                return false;
            };
            log.advance(&now());
            predicate(root, &log)
        };
        if let Some(memory) = &self.memory {
            let roots = memory.lock().await;
            let (_, root) = roots.get(genesis)?;
            if !valid(root) {
                return None;
            }
            return Some(action().await);
        }
        let pool = self.pool.as_ref()?;
        let mut tx = pool.begin().await.ok()?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(genesis)
            .execute(&mut *tx)
            .await
            .ok()?;
        let saved: Option<(Value,)> = sqlx::query_as(
            "SELECT state FROM remote_recovery_roots WHERE genesis_hash = $1 FOR UPDATE",
        )
        .bind(genesis)
        .fetch_optional(&mut *tx)
        .await
        .ok()?;
        let root: Root = serde_json::from_value(saved?.0).ok()?;
        if !valid(&root) {
            return None;
        }
        // No state changes: dropping the read transaction releases its locks.
        Some(action().await)
    }

    pub fn disabled() -> Arc<Self> {
        Arc::new(Self {
            pool: None,
            memory: None,
        })
    }
    pub fn postgres(pool: PgPool) -> Arc<Self> {
        Arc::new(Self {
            pool: Some(pool),
            memory: None,
        })
    }
    pub fn is_durable(&self) -> bool {
        self.pool.is_some()
    }

    pub(crate) fn route_storage_enabled(&self) -> bool {
        self.pool.is_some() || self.memory.is_some()
    }

    pub async fn collect_expired(&self) -> Result<(), sqlx::Error> {
        let Some(pool) = &self.pool else {
            return Ok(());
        };
        let mut cursor = String::new();
        loop {
            let roots: Vec<(String, String)> = sqlx::query_as(
                "SELECT genesis_hash, account_subject FROM remote_recovery_roots WHERE genesis_hash > $1 ORDER BY genesis_hash LIMIT 64")
                .bind(&cursor).fetch_all(pool).await?;
            if roots.is_empty() {
                break;
            }
            for (genesis, owner) in &roots {
                let hash = Hash32::from_hex(genesis)
                    .map_err(|_| sqlx::Error::Protocol("invalid recovery root".into()))?;
                let _ = self
                    .database(pool, genesis, Some(owner), hash, Operation::Collect)
                    .await?;
            }
            cursor = roots.last().unwrap().0.clone();
        }
        Ok(())
    }
    #[cfg(test)]
    pub fn memory() -> Arc<Self> {
        Arc::new(Self {
            pool: None,
            memory: Some(Mutex::new(HashMap::new())),
        })
    }

    pub(super) async fn perform(&self, genesis: &str, subject: &str, operation: Operation) -> Reply {
        self.perform_scoped(genesis, Some(subject), operation).await
    }

    pub(super) async fn push(&self, ingress: super::push_ingress::Ingress) -> Option<Value> {
        let genesis = ingress.object.body()["genesis_hash"].as_str()?.to_owned();
        let reply = self.perform_scoped(&genesis, None, Operation::Push(ingress)).await;
        (reply.0 == StatusCode::OK).then_some(reply.1.0)
    }

    async fn perform_scoped(&self, genesis: &str, subject: Option<&str>, operation: Operation) -> Reply {
        let hash = match Hash32::from_hex(genesis) {
            Ok(h) => h,
            Err(_) => return invalid(),
        };
        if let Some(memory) = &self.memory {
            let mut roots = memory.lock().await;
            if roots
                .get(genesis)
                .is_some_and(|(owner, _)| subject.is_some_and(|subject| owner != subject))
            {
                return error(StatusCode::NOT_FOUND, "recovery_record_not_found");
            }
            let owner = roots.get(genesis).map(|(owner, _)| owner.as_str()).or(subject).map(str::to_owned);
            let Some(owner) = owner else { return error(StatusCode::NOT_FOUND, "recovery_record_not_found") };
            match apply(
                roots.get(genesis).map(|(_, root)| root.clone()),
                hash,
                operation,
                now(),
            ) {
                Ok((root, reply)) => {
                    roots.insert(genesis.to_owned(), (owner, root));
                    reply
                }
                Err(reply) => reply,
            }
        } else if let Some(pool) = &self.pool {
            match self.database(pool, genesis, subject, hash, operation).await {
                Ok(reply) => reply,
                Err(e) => {
                    tracing::error!("recovery store transaction failed: {}", e);
                    unavailable()
                }
            }
        } else {
            unavailable()
        }
    }

    async fn database(
        &self,
        pool: &PgPool,
        genesis: &str,
        subject: Option<&str>,
        hash: Hash32,
        operation: Operation,
    ) -> Result<Reply, sqlx::Error> {
        let mut tx = pool.begin().await?;
        // Lock absent roots too. A hash collision only serializes unrelated roots.
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(genesis)
            .execute(&mut *tx)
            .await?;
        let saved: Option<(String, Value)> = sqlx::query_as(
            "SELECT account_subject, state FROM remote_recovery_roots WHERE genesis_hash = $1 FOR UPDATE")
            .bind(genesis).fetch_optional(&mut *tx).await?;
        if saved.as_ref().is_some_and(|(owner, _)| subject.is_some_and(|subject| owner != subject)) {
            return Ok(error(StatusCode::NOT_FOUND, "recovery_record_not_found"));
        }
        let owner = saved.as_ref().map(|(owner, _)| owner.as_str()).or(subject).map(str::to_owned);
        let Some(owner) = owner else { return Ok(error(StatusCode::NOT_FOUND, "recovery_record_not_found")) };
        let root = match saved {
            Some((_, value)) => match serde_json::from_value(value) {
                Ok(r) => Some(r),
                Err(_) => return Ok(unavailable()),
            },
            None => None,
        };
        let (root, reply) = match apply(root, hash, operation, now()) {
            Ok(r) => r,
            Err(reply) => return Ok(reply),
        };
        let value = serde_json::to_value(root).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
        sqlx::query("INSERT INTO remote_recovery_roots (genesis_hash, account_subject, state) VALUES ($1,$2,$3) \
            ON CONFLICT (genesis_hash) DO UPDATE SET state = EXCLUDED.state, updated_at = now()")
            .bind(genesis).bind(owner).bind(value).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(reply)
    }
}

pub(super) enum Operation {
    HostRoute { text: String, nonce: [u8; 32], room: String, atem_id: String, connection: crate::cluster::ConnRef },
    Append {
        entry: Entry,
        expected: Head,
    },
    Entries {
        after: u64,
    },
    Put {
        version: u64,
        bytes: String,
        intent: Entry,
    },
    Get {
        version: u64,
    },
    ProbeRoute {
        host: String,
    },
    Collect,
    Push(super::push_ingress::Ingress),
}

fn now() -> HostNow {
    static CLOCK: OnceLock<(Instant, String)> = OnceLock::new();
    let (start, boot_id) = CLOCK.get_or_init(|| (Instant::now(), uuid::Uuid::new_v4().to_string()));
    let wall_ms = chrono::Utc::now().timestamp_millis().max(0) as u64;
    // This clock is only a relay convenience check, never a host's recovery wait.
    // Hosts and native clients independently evaluate pending entries on their own clocks.
    HostNow {
        wall_ms,
        mono_ms: start.elapsed().as_millis().min(u64::MAX as u128) as u64,
        boot_id: boot_id.clone(),
    }
}

fn apply(
    saved: Option<Root>,
    hash: Hash32,
    operation: Operation,
    clock: HostNow,
) -> Result<(Root, Reply), Reply> {
    let mut root = match saved {
        Some(r) => r,
        None => {
            let Operation::Append { entry, expected } = &operation else {
                return Err(error(StatusCode::NOT_FOUND, "recovery_record_not_found"));
            };
            if expected.seq != 0 || expected.hash != Hash32([0; 32]) || entry.seq != 1 {
                return Err(invalid());
            }
            let log = Membership::from_genesis(&entry.account_id, &hash, entry.clone())
                .map_err(|_| invalid())?;
            Root {
                account: entry.account_id.clone(),
                membership: log.to_stored(),
                blobs: BTreeMap::new(),
                push: Default::default(),
                routes: Default::default(),
            }
        }
    };
    let mut log = Membership::from_stored(&root.account, &hash, &root.membership)
        .map_err(|_| unavailable())?;
    log.advance(&clock);
    let reply = match operation {
        Operation::HostRoute { text, nonce, room, atem_id, connection } => {
            let route = verify_host_route_message(&log, text.as_bytes(), &nonce, &room, &atem_id)
                .map_err(|refusal| (StatusCode::BAD_REQUEST, Json(RelayReply::refused(&refusal).to_json())))?;
            let binding = HostBinding { genesis: hash.to_hex(), host: route.host_id.clone(),
                connection, room, atem_id, nonce, proof: text };
            let replaced = root.routes.insert(route.host_id.clone(), binding.clone());
            (StatusCode::OK, Json(json!({"binding":binding,"replaced":replaced,"verdict":RelayReply::ok(&route).to_json()})))
        }
        Operation::Collect => {
            root.push.collect(clock.wall_ms);
            (StatusCode::OK, Json(json!({})))
        }
        Operation::Push(ingress) => {
            if root.routes.get(&ingress.context.host).is_some_and(|binding|
                binding.connection.conn != ingress.context.connection || !binding.valid(&log)) {
                return Err(error(StatusCode::BAD_REQUEST, "invalid_push_record"));
            }
            let disposition = root.push.receive(&ingress, &log, clock.wall_ms)
                .map_err(|_| error(StatusCode::BAD_REQUEST, "invalid_push_record"))?;
            (StatusCode::OK, Json(disposition))
        }
        Operation::ProbeRoute { host } => {
            let current = log
                .host(&host)
                .ok_or_else(|| error(StatusCode::NOT_FOUND, "recovery_record_not_found"))?;
            let signer = log
                .entries()
                .iter()
                .rev()
                .find_map(|e| match &e.action {
                    Action::AddHost { host: record }
                        if record.host_id == host
                            && record.host_trust_gen == current.host_trust_gen =>
                    {
                        Some(e.signer.clone())
                    }
                    _ => None,
                })
                .ok_or_else(unavailable)?;
            let binding = root.routes.get(&host).filter(|binding| binding.valid(&log));
            (StatusCode::OK, Json(json!({"room":signer,"binding":binding,"host_trust_gen":current.host_trust_gen})))
        }
        Operation::Append { entry, expected } => {
            if let Some(existing) = log.entry(entry.seq).filter(|e| e.hash() == entry.hash()) {
                (
                    StatusCode::OK,
                    Json(json!({"entry":existing.object().to_json()})),
                )
            } else if expected != log.head() {
                let same = expected.seq == 0
                    || log
                        .entry(expected.seq)
                        .is_some_and(|e| e.hash() == expected.hash);
                page(
                    &log,
                    if same {
                        expected.seq.min(log.head().seq)
                    } else {
                        0
                    },
                    StatusCode::CONFLICT,
                )?
            } else {
                if log.check_next(&entry) != Check::Valid {
                    return Err(invalid());
                }
                let evaluation = log.evaluate_objects(&[entry.object().clone()], &clock);
                if evaluation.appended != 1 || evaluation.stop.is_some() {
                    return Err(invalid());
                }
                log = evaluation.next;
                (
                    StatusCode::OK,
                    Json(json!({"entry":entry.object().to_json()})),
                )
            }
        }
        Operation::Entries { after } => page(&log, after, StatusCode::OK)?,
        Operation::Put {
            version,
            bytes,
            intent,
        } => {
            let blob = KBackupEnvelope::parse(bytes.as_bytes()).map_err(|_| invalid())?;
            let Action::KBackup(record) = &intent.action else {
                return Err(invalid());
            };
            let predecessor = intent.seq.checked_sub(1).ok_or_else(invalid)?;
            let prefix = &log.entries()[..usize::try_from(predecessor)
                .ok()
                .filter(|n| *n <= log.entries().len())
                .ok_or_else(invalid)?];
            let historical = Membership::verify_chain(&root.account, &hash, prefix, &clock)
                .map_err(|_| invalid())?;
            let manager = log
                .member(&intent.signer)
                .filter(|m| m.status == MemberStatus::Active && m.member.is_manager())
                .ok_or_else(invalid)?;
            // Even an intent based on an older head must still have a current manager's signature.
            intent
                .object()
                .verify(&manager.member.auth_key)
                .map_err(|_| invalid())?;
            if historical.membership.check_next(&intent) != Check::Valid
                || blob.jcs() != bytes
                || blob.account_id != root.account
                || blob.genesis_hash != hash
                || blob.blob_version != version
                || record.blob_version != version
                || record.kids != blob.kids
                || record.recovery_key != blob.recovery_key
                || record.backup_hash != blob.backup_hash()
            {
                return Err(invalid());
            }
            if let Some(existing) = root.blobs.get(&version) {
                if existing.bytes == bytes {
                    (StatusCode::OK, Json(json!({"stored":true})))
                } else {
                    (
                        StatusCode::CONFLICT,
                        Json(json!({"max_occupied":root.blobs.keys().next_back()})),
                    )
                }
            } else {
                root.blobs.insert(
                    version,
                    Blob {
                        bytes,
                        uploaded_at: clock.wall_ms,
                    },
                );
                (StatusCode::OK, Json(json!({"stored":true})))
            }
        }
        Operation::Get { version } => {
            let record = log
                .entries()
                .iter()
                .find_map(|e| match &e.action {
                    Action::KBackup(b) if b.blob_version == version => Some(b),
                    _ => None,
                })
                .ok_or_else(|| error(StatusCode::NOT_FOUND, "recovery_record_not_found"))?;
            let blob = root
                .blobs
                .get(&version)
                .ok_or_else(|| error(StatusCode::NOT_FOUND, "recovery_record_not_found"))?;
            let envelope =
                KBackupEnvelope::parse(blob.bytes.as_bytes()).map_err(|_| unavailable())?;
            if envelope.account_id != root.account
                || envelope.genesis_hash != hash
                || envelope.blob_version != version
                || envelope.kids != record.kids
                || envelope.recovery_key != record.recovery_key
                || envelope.backup_hash() != record.backup_hash
            {
                return Err(unavailable());
            }
            (
                StatusCode::OK,
                Json(serde_json::from_str(&blob.bytes).map_err(|_| unavailable())?),
            )
        }
    };
    root.routes.retain(|_, binding| binding.valid(&log));
    retain(&mut root, &log, clock.wall_ms);
    root.membership = log.to_stored();
    if serde_json::to_vec(&root).map_err(|_| unavailable())?.len() > MAX_STATE {
        return Err(unavailable());
    }
    Ok((root, reply))
}

fn retain(root: &mut Root, log: &Membership, now: u64) {
    let mut per_key: HashMap<String, Vec<u64>> = HashMap::new();
    for entry in log.entries().iter().rev() {
        if let Action::KBackup(record) = &entry.action {
            let kept = per_key
                .entry(record.recovery_key.to_json().to_string())
                .or_default();
            if kept.len() < 2 {
                kept.push(record.blob_version);
            }
        }
    }
    let named: Vec<u64> = log
        .entries()
        .iter()
        .filter_map(|e| {
            if let Action::KBackup(b) = &e.action {
                Some(b.blob_version)
            } else {
                None
            }
        })
        .collect();
    root.blobs.retain(|version, blob| {
        per_key.values().any(|keep| keep.contains(version))
            || (!named.contains(version) && now.saturating_sub(blob.uploaded_at) < 3_600_000)
    });
}

fn page(log: &Membership, after: u64, status: StatusCode) -> Result<Reply, Reply> {
    if after > log.head().seq {
        return Err(invalid());
    }
    let mut entries = Vec::new();
    let available = &log.entries()[after as usize..];
    for entry in available.iter().take(64) {
        entries.push(entry.object().to_json());
        let value = json!({"head":log.head().to_json(),"entries":entries,"more":true});
        if serde_json::to_vec(&value).map_err(|_| unavailable())?.len() > MAX_PAGE {
            entries.pop();
            break;
        }
    }
    if entries.is_empty() && !available.is_empty() {
        return Err(unavailable());
    }
    Ok((
        status,
        Json(
            json!({"head":log.head().to_json(),"more":entries.len()<available.len(),"entries":entries}),
        ),
    ))
}

pub(super) async fn subject(state: &AppState, headers: &HeaderMap) -> Result<String, Reply> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or_else(|| error(StatusCode::UNAUTHORIZED, "account_login_required"))?;
    state
        .accounts
        .verify_access_token(token)
        .await
        .map(|a| a.subject)
        .map_err(|e| match e {
            VerifyError::Rejected => error(StatusCode::UNAUTHORIZED, "account_login_required"),
            _ => unavailable(),
        })
}

pub(super) async fn host_target(
    state: &AppState,
    genesis: &str,
    subject: &str,
    host: &str,
) -> Result<(String, crate::cluster::ConnRef, Option<HostBinding>, u64), Reply> {
    state.relay.configure_recovery(state.recovery.clone());
    let reply = state
        .recovery
        .perform(
            genesis,
            subject,
            Operation::ProbeRoute { host: host.into() },
        )
        .await;
    if reply.0 != StatusCode::OK {
        return Err(reply);
    }
    let room = reply.1 .0["room"]
        .as_str()
        .ok_or_else(unavailable)?
        .to_owned();
    let binding: Option<HostBinding> = serde_json::from_value(reply.1 .0["binding"].clone()).ok();
    let target = if let Some(binding) = &binding {
        Some(binding.connection.clone())
    } else {
        match state.relay.room(&room).await {
            Ok(Some(room)) if room.owner.is_some() => room.atems.get(host).cloned(),
            _ => None,
        }
    };
    Ok((
        room,
        target.ok_or_else(|| error(StatusCode::SERVICE_UNAVAILABLE, "host_unreachable"))?,
        binding,
        reply.1.0["host_trust_gen"].as_u64().ok_or_else(unavailable)?,
    ))
}

async fn read(body: Body) -> Result<StrictValue, Reply> {
    let bytes = to_bytes(body, MAX_PAGE)
        .await
        .map_err(|_| error(StatusCode::PAYLOAD_TOO_LARGE, "recovery_record_too_large"))?;
    StrictValue::parse(&bytes, MAX_PAGE).map_err(|_| invalid())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PageQuery {
    #[serde(default)]
    after: u64,
}

pub async fn entries(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    Query(query): Query<PageQuery>,
) -> Reply {
    let subject = match subject(&state, &headers).await {
        Ok(s) => s,
        Err(e) => return e,
    };
    if query.after > MAX_INTEGER {
        return invalid();
    }
    state
        .recovery
        .perform(
            &genesis,
            &subject,
            Operation::Entries { after: query.after },
        )
        .await
}

pub async fn append(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let subject = match subject(&state, &headers).await {
        Ok(s) => s,
        Err(e) => return e,
    };
    let value = match read(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let parsed = (|| {
        if value.value().as_object()?.len() != 2 {
            return None;
        }
        let entry = Entry::from_strict(&value.get("entry")?).ok()?;
        let expected_value = value.get("expected")?;
        // Shared Head intentionally describes existing entries (seq >= 1).
        // Genesis CAS alone uses the empty-chain sentinel.
        let expected = if expected_value.value() == &json!({"seq":0,"hash":"0".repeat(64)})
            && entry.seq == 1
        {
            Head {
                seq: 0,
                hash: Hash32([0; 32]),
            }
        } else {
            Head::from_json(expected_value.value())?
        };
        if expected.seq > MAX_INTEGER {
            return None;
        }
        Some(Operation::Append { entry, expected })
    })();
    match parsed {
        Some(op) => {
            if let Operation::Append { entry, .. } = &op {
                if entry.seq == 1 {
                    // Bind storage ownership to the already registered creator.
                    // This metadata grants no membership or host authorization.
                    let owner = state.accounts.subject_for_astation(&entry.signer).await;
                    let account = state.accounts.resolve_data_account(&entry.signer).await;
                    if !matches!(owner, Ok(Some(ref owner)) if owner == &subject)
                        || !matches!(account, Ok(ref account) if account == &entry.account_id)
                    {
                        return error(StatusCode::FORBIDDEN, "recovery_creator_not_registered");
                    }
                }
            }
            state.recovery.perform(&genesis, &subject, op).await
        }
        None => invalid(),
    }
}

pub async fn upload(
    State(state): State<AppState>,
    Path((genesis, version)): Path<(String, u64)>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let subject = match subject(&state, &headers).await {
        Ok(s) => s,
        Err(e) => return e,
    };
    let parsed = (|| {
        if version == 0 || version > MAX_INTEGER {
            return None;
        }
        let text = headers.get("x-astation-backup-entry")?.to_str().ok()?;
        if text.len() > 16_384 {
            return None;
        }
        let bytes = URL_SAFE_NO_PAD.decode(text).ok()?;
        if URL_SAFE_NO_PAD.encode(&bytes) != text {
            return None;
        }
        Entry::parse_bytes(&bytes).ok()
    })();
    let Some(intent) = parsed else {
        return invalid();
    };
    let raw = match to_bytes(body, MAX_PAGE).await {
        Ok(v) => v,
        Err(_) => return error(StatusCode::PAYLOAD_TOO_LARGE, "recovery_record_too_large"),
    };
    let bytes = match StrictValue::parse(&raw, MAX_PAGE)
        .ok()
        .and_then(|v| jcs(v.value()).ok())
    {
        Some(v) if v.as_bytes() == raw.as_ref() => v,
        _ => return invalid(),
    };
    state
        .recovery
        .perform(
            &genesis,
            &subject,
            Operation::Put {
                version,
                bytes,
                intent,
            },
        )
        .await
}

pub async fn backup(
    State(state): State<AppState>,
    Path((genesis, version)): Path<(String, u64)>,
    headers: HeaderMap,
) -> Reply {
    let subject = match subject(&state, &headers).await {
        Ok(s) => s,
        Err(e) => return e,
    };
    if version == 0 || version > MAX_INTEGER {
        return invalid();
    }
    state
        .recovery
        .perform(&genesis, &subject, Operation::Get { version })
        .await
}

#[cfg(test)]
#[path = "channel_crypto_tests.rs"]
mod channel_crypto_tests;

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("fixtures/recovery-public-vectors.json")).unwrap()
    }
    fn entry(label: &str) -> Entry {
        Entry::parse_bytes(&serde_json::to_vec(&fixture()["entries"][label]).unwrap()).unwrap()
    }
    fn hash() -> Hash32 {
        Hash32::from_hex(fixture()["genesis"].as_str().unwrap()).unwrap()
    }
    fn append(label: &str) -> Operation {
        let entry = entry(label);
        let expected = Head {
            seq: entry.seq - 1,
            hash: entry.prev_hash,
        };
        Operation::Append { entry, expected }
    }
    fn initial() -> Root {
        let mut root = None;
        for label in ["E1", "E2", "E3", "E4", "E5", "E6"] {
            let (next, reply) = apply(root, hash(), append(label), now()).unwrap();
            assert_eq!(reply.0, StatusCode::OK);
            root = Some(next);
        }
        root.unwrap()
    }
    fn put() -> Operation {
        Operation::Put {
            version: 3,
            bytes: jcs(&fixture()["backup"]).unwrap(),
            intent: entry("KB7"),
        }
    }

    pub(crate) struct TestAccountVerifier;
    #[async_trait::async_trait]
    impl crate::account_store::AccountIdentityVerifier for TestAccountVerifier {
        async fn verify(
            &self,
            token: &str,
        ) -> Result<crate::account_identity::VerifiedIdentity, VerifyError> {
            Ok(crate::account_identity::VerifiedIdentity {
                issuer: crate::account_identity::LEGACY_ISSUER.into(),
                subject: token.to_owned(),
                authenticated_at: None,
            })
        }
    }

    #[tokio::test]
    async fn independent_clients_share_one_outbound_host_without_any_mac_and_keep_routes_isolated() {
        use crate::relay::tests::{connect_atem, next_client_json, send_json, spawn_relay};
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};
        let mut state = crate::tests::test_state();
        state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
            state.knowledge.clone(), state.vault.clone(), Arc::new(TestAccountVerifier)));
        state.recovery = RecoveryStore::memory();
        let f = super::super::push_ingress::tests::Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        f.publish(&state.recovery).await;
        let genesis = f.log.genesis_hash().to_hex();
        let (base, server) = spawn_relay(state).await;
        let mut host = connect_atem(&base, "phone", "host-a").await;
        crate::remote_api::host_route_tests::prove(&mut host, &f.keys, &f.host_key, &f.log, "host-a").await;
        let url = base.replace("/ws", &format!("/api/remote/v1/channels?genesis={genesis}&host=host-a"));
        let mut unauthorized = url.clone().into_client_request().unwrap();
        unauthorized.headers_mut().insert("authorization", "Bearer mallory".parse().unwrap());
        let Err(tokio_tungstenite::tungstenite::Error::Http(response)) = tokio_tungstenite::connect_async(unauthorized).await else { panic!("foreign account routed"); };
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let mut request = url.into_client_request().unwrap();
        request.headers_mut().insert("authorization", "Bearer alice".parse().unwrap());
        let mut a = tokio_tungstenite::connect_async(request.clone()).await.unwrap().0;
        let mut b = tokio_tungstenite::connect_async(request).await.unwrap().0;
        send_json(&mut a, json!({"type":"channel","event":"open","channel":"native_1","transport":"relay"})).await;
        let one = next_client_json(&mut host).await;
        send_json(&mut b, json!({"type":"channel","event":"open","channel":"native_1","transport":"relay"})).await;
        let two = next_client_json(&mut host).await;
        let h1 = one["channel"].as_str().unwrap(); let h2 = two["channel"].as_str().unwrap();
        assert_ne!(h1, h2); assert_eq!(one["transport"], "relay");
        // Noncanonical number/escape spellings survive every routing hop intact.
        let raw = format!(r#"{{"type":"channel","event":"frame","channel":"{h2}","frame":{{"ch":"atem-ch1","op":"record","n":1e3,"ct":"\u0061"}}}}"#);
        host.send(Message::Text(raw)).await.unwrap();
        let text = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop { if let Some(Ok(Message::Text(t))) = b.next().await { break t; } }
        }).await.unwrap();
        assert!(text.contains(r#""n":1e3,"ct":"\u0061""#));
        assert!(text.contains(r#""channel":"native_1""#));
        a.close(None).await.unwrap();
        let close = next_client_json(&mut host).await;
        assert_eq!(close["channel"], h1); assert_eq!(close["event"], "close");
        send_json(&mut b, json!({"type":"channel","event":"frame","channel":"native_1","frame":{"ch":"atem-ch1","op":"finish","ct":"opaque"}})).await;
        let frame = next_client_json(&mut host).await;
        assert_eq!(frame["channel"], h2); assert_eq!(frame["frame"]["ct"], "opaque");
        // The independent endpoint has no plaintext session path or protocol downgrade.
        send_json(&mut b, json!({"type":"session","data":{"op":"hello","revision":8}})).await;
        let close = next_client_json(&mut host).await;
        assert_eq!(close["channel"], h2); assert_eq!(close["event"], "close");
        server.abort();
    }

    #[tokio::test]
    async fn registered_creator_can_publish_and_retry_genesis_over_http() {
        use crate::account_store::{AccountStore, InMemoryAccountStore};
        use crate::relay::tests::spawn_relay;
        use ring::signature::KeyPair;
        let key = ring::signature::Ed25519KeyPair::from_seed_unchecked(&[0x27; 32]).unwrap();
        let mut genesis = fixture()["entries"]["E1"].clone();
        genesis["body"]["account_id"] = json!("dev-mac");
        genesis["body"]["member"]["auth_key"] =
            json!({"alg":"ed25519","pub":URL_SAFE_NO_PAD.encode(key.public_key().as_ref())});
        let unsigned = Entry::parse_bytes(&serde_json::to_vec(&genesis).unwrap()).unwrap();
        genesis["sig"] = json!(URL_SAFE_NO_PAD.encode(
            key.sign(unsigned.object().signing_input().as_bytes())
                .as_ref()
        ));
        let signed = Entry::parse_bytes(&serde_json::to_vec(&genesis).unwrap()).unwrap();
        let hash = signed.hash().to_hex();
        let mut state = crate::tests::test_state();
        let accounts = Arc::new(InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            Arc::new(TestAccountVerifier),
        ));
        accounts
            .register("dev-mac", "alice", "Mac", 1)
            .await
            .unwrap();
        state.accounts = accounts;
        state.recovery = RecoveryStore::memory();
        let (base, server) = spawn_relay(state).await;
        let url = base
            .replace("ws://", "http://")
            .replace("/ws", &format!("/api/remote/v1/logs/{hash}/entries"));
        let client = reqwest::Client::new();
        let body = json!({"entry":genesis,"expected":{"seq":0,"hash":"0".repeat(64)}});
        for _ in 0..2 {
            let response = client
                .post(&url)
                .bearer_auth("alice")
                .json(&body)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.json::<Value>().await.unwrap()["entry"], genesis);
        }
        let page = client
            .get(&url)
            .bearer_auth("alice")
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert_eq!(page["head"]["seq"], 1);
        let response = client
            .post(&url)
            .bearer_auth("mallory")
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        server.abort();
    }

    #[tokio::test]
    async fn public_genesis_cannot_be_claimed_by_another_logged_in_account() {
        use crate::account_store::{AccountStore, InMemoryAccountStore};
        use tower::ServiceExt;
        let mut state = crate::tests::test_state();
        let accounts = Arc::new(InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            Arc::new(TestAccountVerifier),
        ));
        accounts
            .register("dev-mac", "alice", "Mac", 1)
            .await
            .unwrap();
        state.accounts = accounts;
        state.recovery = RecoveryStore::memory();
        let response = crate::router(state).oneshot(axum::http::Request::builder().method("POST")
            .extension(axum::extract::ConnectInfo("127.0.0.1:43001".parse::<std::net::SocketAddr>().unwrap()))
            .uri(format!("/api/remote/v1/logs/{}/entries", fixture()["genesis"].as_str().unwrap()))
            .header("authorization", "Bearer mallory").header("content-type", "application/json")
            .body(Body::from(json!({"entry":fixture()["entries"]["E1"],"expected":{"seq":0,"hash":"0".repeat(64)}}).to_string())).unwrap()).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn recovery_probe_reaches_the_host_while_its_mac_is_offline_and_cannot_send_records() {
        use crate::relay::tests::{connect_atem, next_client_json, send_json, spawn_relay};
        let vectors: Value = serde_json::from_str(include_str!(
            "fixtures/recovery-channel-public-vectors.json"
        ))
        .unwrap();
        let mut state = crate::tests::test_state();
        state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            Arc::new(TestAccountVerifier),
        ));
        state.recovery = RecoveryStore::memory();
        let f = super::super::push_ingress::tests::Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        f.publish(&state.recovery).await;
        let genesis = f.log.genesis_hash().to_hex();
        let mut vectors = vectors;
        vectors["init"]["genesis_hash"] = json!(genesis);
        let (base, server) = spawn_relay(state).await;
        let mut host = connect_atem(&base, "phone", "host-a").await;
        crate::remote_api::host_route_tests::prove(&mut host, &f.keys, &f.host_key, &f.log, "host-a").await;
        let url = base.replace("ws://", "http://").replace(
            "/ws",
            &format!("/api/remote/v1/logs/{genesis}/probes/host-a"),
        );
        let http = reqwest::Client::new();
        let bad = http
            .post(&url)
            .bearer_auth("alice")
            .json(&json!({"ch":"atem-ch1","op":"finish","ct":"no"}))
            .send()
            .await
            .unwrap();
        assert_eq!(bad.status(), StatusCode::BAD_REQUEST);
        let request = http
            .post(&url)
            .bearer_auth("alice")
            .json(&vectors["init"])
            .send();
        let answer = async {
            let open = next_client_json(&mut host).await;
            assert_eq!(open["event"], "open");
            let handle = open["channel"].clone();
            assert!(handle.as_str().unwrap().starts_with("rp_"));
            let frame = next_client_json(&mut host).await;
            assert_eq!(frame["channel"], handle);
            assert_eq!(frame["frame"], vectors["init"]);
            send_json(&mut host, json!({"type":"channel","event":"frame","channel":handle,"frame":vectors["accept"]})).await;
        };
        let (response, ()) = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::join!(request, answer)
        })
        .await
        .unwrap();
        let response = response.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.json::<Value>().await.unwrap(), vectors["accept"]);
        assert_eq!(next_client_json(&mut host).await["event"], "close");
        server.abort();
    }

    #[test]
    fn signed_cas_retries_and_conflicts_preserve_the_committed_chain() {
        let root = initial();
        let before = root.membership.clone();
        let (root, retry) = apply(Some(root), hash(), append("E2"), now()).unwrap();
        assert_eq!(retry.0, StatusCode::OK);
        let (root, conflict) = apply(Some(root), hash(), append("C6_mac"), now()).unwrap();
        assert_eq!(conflict.0, StatusCode::CONFLICT);
        assert_eq!(conflict.1 .0["head"]["seq"], 6);
        assert_eq!(root.membership, before);
        assert!(apply(Some(root), hash(), append("X7_ipad"), now()).is_err());
    }

    #[test]
    fn backup_requires_exact_signed_intent_and_a_committed_reference() {
        let (root, reply) = apply(Some(initial()), hash(), put(), now()).unwrap();
        assert_eq!(reply.0, StatusCode::OK);
        assert!(apply(
            Some(root.clone()),
            hash(),
            Operation::Get { version: 3 },
            now()
        )
        .is_err());
        let (root, retry) = apply(Some(root), hash(), put(), now()).unwrap();
        assert_eq!(retry.0, StatusCode::OK);
        let (root, _) = apply(Some(root), hash(), append("KB7"), now()).unwrap();
        let (mut root, read) =
            apply(Some(root), hash(), Operation::Get { version: 3 }, now()).unwrap();
        assert_eq!(read.1 .0, fixture()["backup"]);
        root.blobs.get_mut(&3).unwrap().bytes =
            root.blobs[&3].bytes.replace("acct-test-1", "acct-corrupt");
        assert_eq!(
            apply(Some(root), hash(), Operation::Get { version: 3 }, now())
                .unwrap_err()
                .0,
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    #[test]
    fn altered_backup_or_intent_is_refused_without_changing_storage() {
        let mut blob = fixture()["backup"].clone();
        blob["kids"] = json!(["00000000"]);
        let op = Operation::Put {
            version: 3,
            bytes: jcs(&blob).unwrap(),
            intent: entry("KB7"),
        };
        assert!(apply(Some(initial()), hash(), op, now()).is_err());
        let mut intent = fixture()["entries"]["KB7"].clone();
        intent["body"]["signer"] = json!("dev-ipad");
        let op = Operation::Put {
            version: 3,
            bytes: jcs(&fixture()["backup"]).unwrap(),
            intent: Entry::parse_bytes(&serde_json::to_vec(&intent).unwrap()).unwrap(),
        };
        assert!(apply(Some(initial()), hash(), op, now()).is_err());
    }

    #[test]
    fn uncommitted_backup_collection_survives_store_roundtrip() {
        let clock = now();
        let (root, _) = apply(Some(initial()), hash(), put(), clock.clone()).unwrap();
        let root = serde_json::from_value(serde_json::to_value(root).unwrap()).unwrap();
        let later = HostNow {
            wall_ms: clock.wall_ms + 3_600_000,
            mono_ms: clock.mono_ms + 3_600_000,
            boot_id: clock.boot_id,
        };
        let (root, _) = apply(Some(root), hash(), Operation::Collect, later).unwrap();
        assert!(root.blobs.is_empty());
    }

    #[tokio::test]
    async fn account_isolation_and_concurrent_cas() {
        let store = RecoveryStore::memory();
        let genesis = fixture()["genesis"].as_str().unwrap().to_owned();
        assert_eq!(
            store.perform(&genesis, "alice", append("E1")).await.0,
            StatusCode::OK
        );
        assert_eq!(
            store
                .perform(&genesis, "mallory", Operation::Entries { after: 0 })
                .await
                .0,
            StatusCode::NOT_FOUND
        );
        let (a, b) = tokio::join!(
            store.perform(&genesis, "alice", append("E2")),
            store.perform(&genesis, "alice", append("E2"))
        );
        assert_eq!((a.0, b.0), (StatusCode::OK, StatusCode::OK));
        assert_eq!(
            store
                .perform(&genesis, "alice", Operation::Entries { after: 0 })
                .await
                .1
                 .0["head"]["seq"],
            2
        );
    }

    #[tokio::test]
    #[ignore = "requires a local isolated Postgres test database"]
    async fn postgres_cas_backup_restart_and_failed_transaction() {
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let store = RecoveryStore::postgres(db.pool.clone());
        let other_pool = db.reconnect(4).await;
        let replica = RecoveryStore::postgres(other_pool.clone());
        let genesis = fixture()["genesis"].as_str().unwrap().to_owned();
        assert_eq!(
            store.perform(&genesis, "alice", append("E1")).await.0,
            StatusCode::OK
        );
        let (a, b) = tokio::join!(
            store.perform(&genesis, "alice", append("E2")),
            replica.perform(&genesis, "alice", append("E2"))
        );
        assert_eq!((a.0, b.0), (StatusCode::OK, StatusCode::OK));
        for label in ["E3", "E4", "E5", "E6"] {
            assert_eq!(
                replica.perform(&genesis, "alice", append(label)).await.0,
                StatusCode::OK
            );
        }
        assert_eq!(
            replica.perform(&genesis, "alice", put()).await.0,
            StatusCode::OK
        );
        // Reject every write inside this isolated schema. No success may escape a rolled-back CAS.
        sqlx::query("ALTER TABLE remote_recovery_roots ADD CONSTRAINT inject_failure CHECK (false) NOT VALID").execute(&db.pool).await.unwrap();
        assert_eq!(
            store.perform(&genesis, "alice", append("KB7")).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        sqlx::query("ALTER TABLE remote_recovery_roots DROP CONSTRAINT inject_failure")
            .execute(&db.pool)
            .await
            .unwrap();
        assert_eq!(
            replica
                .perform(&genesis, "alice", Operation::Entries { after: 6 })
                .await
                .1
                 .0["head"]["seq"],
            6
        );
        assert_eq!(
            store.perform(&genesis, "alice", append("KB7")).await.0,
            StatusCode::OK
        );
        drop(store);
        drop(replica);
        other_pool.close().await;
        let restarted = RecoveryStore::postgres(db.reconnect(2).await);
        assert_eq!(
            restarted
                .perform(&genesis, "alice", Operation::Get { version: 3 })
                .await
                .1
                 .0,
            fixture()["backup"]
        );
        assert_eq!(
            restarted
                .perform(&genesis, "mallory", Operation::Get { version: 3 })
                .await
                .0,
            StatusCode::NOT_FOUND
        );
        restarted.pool.as_ref().unwrap().close().await;
        db.cleanup().await;
    }
}
