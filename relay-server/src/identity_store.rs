//! Astation identity: registered P-256 keys (trust on first use) and durable
//! session bindings (`session_id` → `astation_id`) pushed by a verified Astation.
//!
//! See docs/knowledge-sync-plan.md, "Extension: Astation proof-of-possession +
//! durable pairing". This module only stores; the relay protocol that verifies
//! proofs and drives these calls lives in `relay.rs`.
//!
//! Mirrors `knowledge_store.rs`: one trait, an in-memory implementation for
//! tests and DB-less runs, and a Postgres implementation (migration
//! 0003_astation_identity). All times are unix seconds supplied by the caller.

use async_trait::async_trait;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::Mutex;

/// A binding is valid while `now - last_used_at < BINDING_TTL_SECS` (7 days).
pub const BINDING_TTL_SECS: i64 = 7 * 24 * 60 * 60;

/// `resolve` refreshes `last_used_at` only once it is at least this old.
pub const BINDING_TOUCH_INTERVAL_SECS: i64 = 60 * 60;

/// Result of `register_key_if_absent`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegisterOutcome {
    /// This call stored the key (first use).
    Registered,
    /// A key was already registered (possibly by a concurrent call). The caller
    /// must compare it with the key it tried to register.
    Existing(String),
}

/// Result of `bind`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindOutcome {
    /// Created, or refreshed because the caller already owns it.
    Bound,
    /// The session is bound to a different Astation; nothing changed.
    OwnedByOther,
}

/// Result of `replace_all`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplaceOutcome {
    /// Bindings of this Astation removed because they were not listed.
    pub removed: u64,
    /// Listed sessions now bound to this Astation (created or refreshed).
    pub bound: u64,
    /// Listed sessions skipped because another Astation owns them.
    pub skipped: u64,
}

#[derive(Debug)]
pub enum IdentityError {
    Db(String),
}

impl std::fmt::Display for IdentityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            IdentityError::Db(s) => write!(f, "database error: {}", s),
        }
    }
}

fn is_expired(last_used_at: i64, now: i64) -> bool {
    now - last_used_at >= BINDING_TTL_SECS
}

fn needs_touch(last_used_at: i64, now: i64) -> bool {
    now - last_used_at >= BINDING_TOUCH_INTERVAL_SECS
}

/// Listed sessions, deduplicated and sorted. `replace_all` upserts them in this
/// order so two Astations resyncing overlapping sets always lock the rows in
/// the same order (no Postgres deadlock between them).
fn dedup_sessions(sessions: &[String]) -> Vec<String> {
    let mut listed: Vec<String> = sessions
        .iter()
        .cloned()
        .collect::<HashSet<String>>()
        .into_iter()
        .collect();
    listed.sort();
    listed
}

/// Storage for Astation keys and session bindings.
#[async_trait]
pub trait IdentityStore: Send + Sync {
    fn backend_name(&self) -> &'static str;

    /// The registered public key (hex) of this Astation, if any.
    async fn get_key(&self, astation_id: &str) -> Result<Option<String>, IdentityError>;

    /// Trust on first use: store `pubkey_hex` only if no key exists for
    /// `astation_id`. Atomic — of concurrent callers exactly one gets
    /// `Registered`; every other one gets `Existing(<stored key>)`.
    async fn register_key_if_absent(
        &self,
        astation_id: &str,
        pubkey_hex: &str,
        now: i64,
    ) -> Result<RegisterOutcome, IdentityError>;

    /// Record a successful verification. No-op when no key is registered.
    async fn touch_key(&self, astation_id: &str, now: i64) -> Result<(), IdentityError>;

    /// Every registered `(astation_id, public_key)`. The relay loads these into
    /// its in-memory key cache at startup.
    async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError>;

    /// Bind `session_id` to `astation_id` (or refresh `last_used_at` if this
    /// Astation already owns it). A session owned by another Astation is left
    /// alone and `OwnedByOther` is returned — even if that binding has expired.
    async fn bind(
        &self,
        session_id: &str,
        astation_id: &str,
        now: i64,
    ) -> Result<BindOutcome, IdentityError>;

    /// Remove the binding only if `astation_id` owns it. Returns whether a
    /// binding was removed.
    async fn unbind(&self, session_id: &str, astation_id: &str) -> Result<bool, IdentityError>;

    /// Full resync, in one transaction: delete every binding of `astation_id`
    /// not in `sessions`, then bind each listed session (sessions owned by
    /// another Astation are skipped).
    async fn replace_all(
        &self,
        astation_id: &str,
        sessions: &[String],
        now: i64,
    ) -> Result<ReplaceOutcome, IdentityError>;

    /// The owning Astation of a live binding. `None` if missing or expired.
    /// Refreshes `last_used_at` when it is at least an hour old.
    async fn resolve(&self, session_id: &str, now: i64) -> Result<Option<String>, IdentityError>;
}

// ─────────────────────────── In-memory implementation ───────────────────────────

#[derive(Debug, Clone)]
struct KeyRec {
    public_key: String,
    #[allow(dead_code)]
    registered_at: i64,
    last_verified_at: i64,
}

#[derive(Debug, Clone)]
struct BindingRec {
    astation_id: String,
    #[allow(dead_code)]
    created_at: i64,
    last_used_at: i64,
}

#[derive(Default)]
struct IdentityState {
    keys: HashMap<String, KeyRec>,
    bindings: HashMap<String, BindingRec>,
}

impl IdentityState {
    fn bind(&mut self, session_id: &str, astation_id: &str, now: i64) -> BindOutcome {
        match self.bindings.get_mut(session_id) {
            Some(b) if b.astation_id != astation_id => BindOutcome::OwnedByOther,
            Some(b) => {
                b.last_used_at = now;
                BindOutcome::Bound
            }
            None => {
                self.bindings.insert(
                    session_id.to_string(),
                    BindingRec {
                        astation_id: astation_id.to_string(),
                        created_at: now,
                        last_used_at: now,
                    },
                );
                BindOutcome::Bound
            }
        }
    }
}

/// In-memory identity store for tests and DB-less runs (not durable). One
/// mutex guards all state, so every operation is atomic.
#[derive(Clone, Default)]
pub struct InMemoryIdentityStore {
    state: Arc<Mutex<IdentityState>>,
}

impl InMemoryIdentityStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Test stand-in for the admin reset (`DELETE FROM astation_keys …`).
    #[cfg(test)]
    pub(crate) async fn delete_key(&self, astation_id: &str) {
        self.state.lock().await.keys.remove(astation_id);
    }
}

#[async_trait]
impl IdentityStore for InMemoryIdentityStore {
    fn backend_name(&self) -> &'static str {
        "memory"
    }

    async fn get_key(&self, astation_id: &str) -> Result<Option<String>, IdentityError> {
        let st = self.state.lock().await;
        Ok(st.keys.get(astation_id).map(|k| k.public_key.clone()))
    }

    async fn register_key_if_absent(
        &self,
        astation_id: &str,
        pubkey_hex: &str,
        now: i64,
    ) -> Result<RegisterOutcome, IdentityError> {
        let mut st = self.state.lock().await;
        if let Some(k) = st.keys.get(astation_id) {
            return Ok(RegisterOutcome::Existing(k.public_key.clone()));
        }
        st.keys.insert(
            astation_id.to_string(),
            KeyRec {
                public_key: pubkey_hex.to_string(),
                registered_at: now,
                last_verified_at: now,
            },
        );
        Ok(RegisterOutcome::Registered)
    }

    async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
        let st = self.state.lock().await;
        Ok(st
            .keys
            .iter()
            .map(|(id, k)| (id.clone(), k.public_key.clone()))
            .collect())
    }

    async fn touch_key(&self, astation_id: &str, now: i64) -> Result<(), IdentityError> {
        let mut st = self.state.lock().await;
        if let Some(k) = st.keys.get_mut(astation_id) {
            k.last_verified_at = now;
        }
        Ok(())
    }

    async fn bind(
        &self,
        session_id: &str,
        astation_id: &str,
        now: i64,
    ) -> Result<BindOutcome, IdentityError> {
        Ok(self.state.lock().await.bind(session_id, astation_id, now))
    }

    async fn unbind(&self, session_id: &str, astation_id: &str) -> Result<bool, IdentityError> {
        let mut st = self.state.lock().await;
        match st.bindings.get(session_id) {
            Some(b) if b.astation_id == astation_id => {
                st.bindings.remove(session_id);
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    async fn replace_all(
        &self,
        astation_id: &str,
        sessions: &[String],
        now: i64,
    ) -> Result<ReplaceOutcome, IdentityError> {
        let listed = dedup_sessions(sessions);
        let keep: HashSet<&str> = listed.iter().map(|s| s.as_str()).collect();
        let mut st = self.state.lock().await;
        let before = st.bindings.len();
        st.bindings
            .retain(|sid, b| b.astation_id != astation_id || keep.contains(sid.as_str()));
        let mut out = ReplaceOutcome {
            removed: (before - st.bindings.len()) as u64,
            ..Default::default()
        };
        for sid in &listed {
            match st.bind(sid, astation_id, now) {
                BindOutcome::Bound => out.bound += 1,
                BindOutcome::OwnedByOther => out.skipped += 1,
            }
        }
        Ok(out)
    }

    async fn resolve(&self, session_id: &str, now: i64) -> Result<Option<String>, IdentityError> {
        let mut st = self.state.lock().await;
        let b = match st.bindings.get_mut(session_id) {
            None => return Ok(None),
            Some(b) => b,
        };
        if is_expired(b.last_used_at, now) {
            return Ok(None);
        }
        if needs_touch(b.last_used_at, now) {
            b.last_used_at = now;
        }
        Ok(Some(b.astation_id.clone()))
    }
}

// ─────────────────────────── Postgres implementation ───────────────────────────

/// Postgres-backed identity store (tables from `0003_astation_identity.sql`).
#[derive(Clone)]
pub struct PgIdentityStore {
    pool: sqlx::PgPool,
}

impl PgIdentityStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

fn db_err(e: sqlx::Error) -> IdentityError {
    IdentityError::Db(e.to_string())
}

/// Serialize binding writes of one Astation (transaction-scoped advisory lock,
/// released at commit/rollback), so a `replace_all` and a concurrent
/// `bind`/`unbind` from the same Astation apply in a single order. Writes that
/// race across Astations on the same session are settled by the
/// `ON CONFLICT … WHERE owner = caller` upsert instead.
async fn lock_astation(
    conn: &mut sqlx::PgConnection,
    astation_id: &str,
) -> Result<(), IdentityError> {
    let key = serde_json::to_string(&["astation-bindings", astation_id])
        .map_err(|e| IdentityError::Db(e.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(conn)
        .await
        .map_err(db_err)?;
    Ok(())
}

/// Insert the binding, or refresh it only when `astation_id` already owns it.
/// Returns whether a row was inserted or refreshed.
async fn upsert_owned_binding(
    conn: &mut sqlx::PgConnection,
    session_id: &str,
    astation_id: &str,
    now: i64,
) -> Result<bool, IdentityError> {
    let res = sqlx::query(
        "INSERT INTO session_bindings (session_id, astation_id, created_at, last_used_at) \
         VALUES ($1, $2, $3, $3) \
         ON CONFLICT (session_id) DO UPDATE SET last_used_at = EXCLUDED.last_used_at \
         WHERE session_bindings.astation_id = EXCLUDED.astation_id",
    )
    .bind(session_id)
    .bind(astation_id)
    .bind(now)
    .execute(conn)
    .await
    .map_err(db_err)?;
    Ok(res.rows_affected() == 1)
}

#[async_trait]
impl IdentityStore for PgIdentityStore {
    fn backend_name(&self) -> &'static str {
        "postgres"
    }

    async fn get_key(&self, astation_id: &str) -> Result<Option<String>, IdentityError> {
        sqlx::query_scalar("SELECT public_key FROM astation_keys WHERE astation_id = $1")
            .bind(astation_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(db_err)
    }

    async fn register_key_if_absent(
        &self,
        astation_id: &str,
        pubkey_hex: &str,
        now: i64,
    ) -> Result<RegisterOutcome, IdentityError> {
        let res = sqlx::query(
            "INSERT INTO astation_keys (astation_id, public_key, registered_at, last_verified_at) \
             VALUES ($1, $2, $3, $3) ON CONFLICT (astation_id) DO NOTHING",
        )
        .bind(astation_id)
        .bind(pubkey_hex)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(db_err)?;
        if res.rows_affected() == 1 {
            return Ok(RegisterOutcome::Registered);
        }
        // Lost to an existing (or concurrently committed) key: re-read it so the
        // caller can compare.
        match self.get_key(astation_id).await? {
            Some(k) => Ok(RegisterOutcome::Existing(k)),
            // Only possible if the row was deleted (admin reset) in between.
            None => Err(IdentityError::Db(
                "key insert conflicted but no key was found; retry".to_string(),
            )),
        }
    }

    async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
        sqlx::query_as("SELECT astation_id, public_key FROM astation_keys")
            .fetch_all(&self.pool)
            .await
            .map_err(db_err)
    }

    async fn touch_key(&self, astation_id: &str, now: i64) -> Result<(), IdentityError> {
        sqlx::query("UPDATE astation_keys SET last_verified_at = $2 WHERE astation_id = $1")
            .bind(astation_id)
            .bind(now)
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        Ok(())
    }

    async fn bind(
        &self,
        session_id: &str,
        astation_id: &str,
        now: i64,
    ) -> Result<BindOutcome, IdentityError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_astation(&mut tx, astation_id).await?;
        let ok = upsert_owned_binding(&mut tx, session_id, astation_id, now).await?;
        tx.commit().await.map_err(db_err)?;
        Ok(if ok {
            BindOutcome::Bound
        } else {
            BindOutcome::OwnedByOther
        })
    }

    async fn unbind(&self, session_id: &str, astation_id: &str) -> Result<bool, IdentityError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_astation(&mut tx, astation_id).await?;
        let res =
            sqlx::query("DELETE FROM session_bindings WHERE session_id = $1 AND astation_id = $2")
                .bind(session_id)
                .bind(astation_id)
                .execute(&mut *tx)
                .await
                .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(res.rows_affected() == 1)
    }

    async fn replace_all(
        &self,
        astation_id: &str,
        sessions: &[String],
        now: i64,
    ) -> Result<ReplaceOutcome, IdentityError> {
        let listed = dedup_sessions(sessions);
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_astation(&mut tx, astation_id).await?;
        let removed = sqlx::query(
            "DELETE FROM session_bindings \
             WHERE astation_id = $1 AND NOT (session_id = ANY($2))",
        )
        .bind(astation_id)
        .bind(&listed)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?
        .rows_affected();
        let mut out = ReplaceOutcome {
            removed,
            ..Default::default()
        };
        for sid in &listed {
            if upsert_owned_binding(&mut tx, sid, astation_id, now).await? {
                out.bound += 1;
            } else {
                out.skipped += 1;
            }
        }
        tx.commit().await.map_err(db_err)?;
        Ok(out)
    }

    async fn resolve(&self, session_id: &str, now: i64) -> Result<Option<String>, IdentityError> {
        let row: Option<(String, i64)> = sqlx::query_as(
            "SELECT astation_id, last_used_at FROM session_bindings WHERE session_id = $1",
        )
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_err)?;
        let (astation_id, last_used_at) = match row {
            None => return Ok(None),
            Some(r) => r,
        };
        if is_expired(last_used_at, now) {
            return Ok(None);
        }
        if needs_touch(last_used_at, now) {
            // Conditional on the owner and the old timestamp being unchanged, so
            // a concurrent unbind/rebind or a fresher touch is never overwritten.
            sqlx::query(
                "UPDATE session_bindings SET last_used_at = $3 \
                 WHERE session_id = $1 AND astation_id = $2 AND last_used_at < $3",
            )
            .bind(session_id)
            .bind(&astation_id)
            .bind(now)
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        }
        Ok(Some(astation_id))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    const A: &str = "astation-a";
    const B: &str = "astation-b";
    const KEY1: &str = "04aa";
    const KEY2: &str = "04bb";
    const T0: i64 = 1_700_000_000;
    const DAY: i64 = 24 * 60 * 60;

    fn v(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }

    /// Backend-independent scenarios, run against both implementations.
    mod scenarios {
        use super::*;

        pub async fn tofu_first_key_wins(s: &dyn IdentityStore) {
            assert_eq!(s.get_key(A).await.unwrap(), None);
            assert_eq!(
                s.register_key_if_absent(A, KEY1, T0).await.unwrap(),
                RegisterOutcome::Registered
            );
            assert_eq!(s.get_key(A).await.unwrap().as_deref(), Some(KEY1));
            // A different key never replaces the first.
            assert_eq!(
                s.register_key_if_absent(A, KEY2, T0 + 1).await.unwrap(),
                RegisterOutcome::Existing(KEY1.to_string())
            );
            // The same key again also reports Existing (caller compares).
            assert_eq!(
                s.register_key_if_absent(A, KEY1, T0 + 2).await.unwrap(),
                RegisterOutcome::Existing(KEY1.to_string())
            );
            assert_eq!(s.get_key(A).await.unwrap().as_deref(), Some(KEY1));
            // Keys are per Astation.
            assert_eq!(
                s.register_key_if_absent(B, KEY2, T0).await.unwrap(),
                RegisterOutcome::Registered
            );
            assert_eq!(s.get_key(B).await.unwrap().as_deref(), Some(KEY2));
        }

        pub async fn list_keys_returns_all(s: &dyn IdentityStore) {
            assert!(s.list_keys().await.unwrap().is_empty());
            s.register_key_if_absent(A, KEY1, T0).await.unwrap();
            s.register_key_if_absent(B, KEY2, T0).await.unwrap();
            s.register_key_if_absent(A, KEY2, T0).await.unwrap();
            let mut keys = s.list_keys().await.unwrap();
            keys.sort();
            assert_eq!(
                keys,
                vec![
                    (A.to_string(), KEY1.to_string()),
                    (B.to_string(), KEY2.to_string())
                ]
            );
        }

        pub async fn touch_key_never_registers(s: &dyn IdentityStore) {
            s.touch_key(A, T0).await.unwrap();
            assert_eq!(s.get_key(A).await.unwrap(), None);
            s.register_key_if_absent(A, KEY1, T0).await.unwrap();
            s.touch_key(A, T0 + 10).await.unwrap();
            assert_eq!(s.get_key(A).await.unwrap().as_deref(), Some(KEY1));
        }

        pub async fn concurrent_tofu_has_one_winner(s: Arc<dyn IdentityStore>) {
            let mut handles = Vec::new();
            for i in 0..16 {
                let s = s.clone();
                handles.push(tokio::spawn(async move {
                    let key = format!("04{:02x}", i);
                    let out = s.register_key_if_absent(A, &key, T0).await.unwrap();
                    (key, out)
                }));
            }
            let mut winners = Vec::new();
            let mut existing = Vec::new();
            for h in handles {
                match h.await.unwrap() {
                    (key, RegisterOutcome::Registered) => winners.push(key),
                    (_, RegisterOutcome::Existing(k)) => existing.push(k),
                }
            }
            assert_eq!(winners.len(), 1, "exactly one registration wins");
            assert_eq!(existing.len(), 15);
            assert!(existing.iter().all(|k| *k == winners[0]));
            assert_eq!(s.get_key(A).await.unwrap(), Some(winners[0].clone()));
        }

        pub async fn bind_and_resolve(s: &dyn IdentityStore) {
            assert_eq!(s.resolve("s1", T0).await.unwrap(), None);
            assert_eq!(s.bind("s1", A, T0).await.unwrap(), BindOutcome::Bound);
            assert_eq!(s.resolve("s1", T0 + 1).await.unwrap().as_deref(), Some(A));
            assert_eq!(s.resolve("unknown", T0).await.unwrap(), None);
        }

        pub async fn bind_owned_by_other_is_rejected(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            assert_eq!(
                s.bind("s1", B, T0 + 1).await.unwrap(),
                BindOutcome::OwnedByOther
            );
            assert_eq!(s.resolve("s1", T0 + 2).await.unwrap().as_deref(), Some(A));
            // Even an expired binding stays with its owner.
            assert_eq!(
                s.bind("s1", B, T0 + 8 * DAY).await.unwrap(),
                BindOutcome::OwnedByOther
            );
            assert_eq!(s.resolve("s1", T0 + 8 * DAY).await.unwrap(), None);
        }

        pub async fn rebind_by_owner_refreshes(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            assert_eq!(
                s.bind("s1", A, T0 + 6 * DAY).await.unwrap(),
                BindOutcome::Bound
            );
            // Would be expired from T0; alive from the refresh.
            assert_eq!(
                s.resolve("s1", T0 + 8 * DAY).await.unwrap().as_deref(),
                Some(A)
            );
            // An expired binding is revived by its owner re-binding.
            assert_eq!(s.resolve("s1", T0 + 20 * DAY).await.unwrap(), None);
            assert_eq!(
                s.bind("s1", A, T0 + 20 * DAY).await.unwrap(),
                BindOutcome::Bound
            );
            assert_eq!(
                s.resolve("s1", T0 + 20 * DAY + 1).await.unwrap().as_deref(),
                Some(A)
            );
        }

        pub async fn unbind_requires_ownership(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            assert!(!s.unbind("s1", B).await.unwrap());
            assert_eq!(s.resolve("s1", T0).await.unwrap().as_deref(), Some(A));
            assert!(s.unbind("s1", A).await.unwrap());
            assert_eq!(s.resolve("s1", T0).await.unwrap(), None);
            assert!(!s.unbind("s1", A).await.unwrap());
            assert!(!s.unbind("never", A).await.unwrap());
            // Once unbound, another Astation may bind it.
            assert_eq!(s.bind("s1", B, T0 + 1).await.unwrap(), BindOutcome::Bound);
            assert_eq!(s.resolve("s1", T0 + 1).await.unwrap().as_deref(), Some(B));
        }

        pub async fn replace_all_resyncs(s: &dyn IdentityStore) {
            for sid in ["s1", "s2", "s3"] {
                s.bind(sid, A, T0).await.unwrap();
            }
            s.bind("s4", B, T0).await.unwrap();
            s.bind("s6", B, T0).await.unwrap();
            let out = s
                .replace_all(A, &v(&["s2", "s4", "s5", "s5"]), T0 + 10)
                .await
                .unwrap();
            assert_eq!(
                out,
                ReplaceOutcome {
                    removed: 2,
                    bound: 2,
                    skipped: 1
                }
            );
            let t = T0 + 11;
            assert_eq!(s.resolve("s1", t).await.unwrap(), None);
            assert_eq!(s.resolve("s2", t).await.unwrap().as_deref(), Some(A));
            assert_eq!(s.resolve("s3", t).await.unwrap(), None);
            // Owned by B: skipped, untouched.
            assert_eq!(s.resolve("s4", t).await.unwrap().as_deref(), Some(B));
            assert_eq!(s.resolve("s5", t).await.unwrap().as_deref(), Some(A));
            // B's unlisted binding is not A's to remove.
            assert_eq!(s.resolve("s6", t).await.unwrap().as_deref(), Some(B));
        }

        pub async fn replace_all_refreshes_listed(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            s.replace_all(A, &v(&["s1"]), T0 + 6 * DAY).await.unwrap();
            assert_eq!(
                s.resolve("s1", T0 + 8 * DAY).await.unwrap().as_deref(),
                Some(A)
            );
        }

        pub async fn replace_all_empty_clears_own(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            s.bind("s2", A, T0).await.unwrap();
            s.bind("s3", B, T0).await.unwrap();
            let out = s.replace_all(A, &[], T0 + 1).await.unwrap();
            assert_eq!(
                out,
                ReplaceOutcome {
                    removed: 2,
                    bound: 0,
                    skipped: 0
                }
            );
            assert_eq!(s.resolve("s1", T0 + 1).await.unwrap(), None);
            assert_eq!(s.resolve("s2", T0 + 1).await.unwrap(), None);
            assert_eq!(s.resolve("s3", T0 + 1).await.unwrap().as_deref(), Some(B));
        }

        pub async fn sliding_expiry(s: &dyn IdentityStore) {
            s.bind("s1", A, T0).await.unwrap();
            s.bind("s2", A, T0).await.unwrap();
            assert_eq!(
                s.resolve("s1", T0 + 7 * DAY - 1).await.unwrap().as_deref(),
                Some(A)
            );
            assert_eq!(s.resolve("s2", T0 + 7 * DAY).await.unwrap(), None);
            // An expired lookup does not touch (revive) it.
            assert_eq!(s.resolve("s2", T0 + 7 * DAY + 1).await.unwrap(), None);
            assert_eq!(
                s.resolve("s2", T0 + 7 * DAY + 2 * BINDING_TOUCH_INTERVAL_SECS)
                    .await
                    .unwrap(),
                None
            );
        }

        pub async fn resolve_touch_is_throttled(s: &dyn IdentityStore) {
            // Under an hour since last use: no touch, so expiry still counts from T0.
            s.bind("s1", A, T0).await.unwrap();
            assert_eq!(
                s.resolve("s1", T0 + BINDING_TOUCH_INTERVAL_SECS - 1)
                    .await
                    .unwrap()
                    .as_deref(),
                Some(A)
            );
            assert_eq!(s.resolve("s1", T0 + 7 * DAY).await.unwrap(), None);

            // An hour or more: touched, so expiry slides from that use.
            s.bind("s2", A, T0).await.unwrap();
            let used = T0 + BINDING_TOUCH_INTERVAL_SECS;
            assert_eq!(s.resolve("s2", used).await.unwrap().as_deref(), Some(A));
            assert_eq!(
                s.resolve("s2", used + 7 * DAY - 1)
                    .await
                    .unwrap()
                    .as_deref(),
                Some(A)
            );
            assert_eq!(
                s.resolve("s2", used + 7 * DAY - 1 + 7 * DAY).await.unwrap(),
                None
            );
        }
    }

    macro_rules! mem_tests {
        ($($name:ident),* $(,)?) => {
            $(
                #[tokio::test]
                async fn $name() {
                    let s = InMemoryIdentityStore::new();
                    scenarios::$name(&s).await;
                }
            )*
        };
    }

    mem_tests!(
        tofu_first_key_wins,
        list_keys_returns_all,
        touch_key_never_registers,
        bind_and_resolve,
        bind_owned_by_other_is_rejected,
        rebind_by_owner_refreshes,
        unbind_requires_ownership,
        replace_all_resyncs,
        replace_all_refreshes_listed,
        replace_all_empty_clears_own,
        sliding_expiry,
        resolve_touch_is_throttled,
    );

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_tofu_has_one_winner() {
        scenarios::concurrent_tofu_has_one_winner(Arc::new(InMemoryIdentityStore::new())).await;
    }

    #[test]
    fn dedup_sessions_sorts_for_a_stable_lock_order() {
        assert_eq!(
            dedup_sessions(&v(&["s3", "s1", "s3", "s2", "s1"])),
            v(&["s1", "s2", "s3"])
        );
        assert!(dedup_sessions(&[]).is_empty());
    }

    #[tokio::test]
    async fn in_memory_backend_name() {
        assert_eq!(InMemoryIdentityStore::new().backend_name(), "memory");
    }

    #[test]
    fn local_url_guard() {
        assert!(is_local_db_url(
            "postgres://postgres:pw@localhost:55432/postgres"
        ));
        assert!(is_local_db_url("postgres://u:p@127.0.0.1:5432/db"));
        assert!(is_local_db_url("postgresql://u@[::1]:5432/db"));
        assert!(!is_local_db_url("postgres://u:p@db.example.com:5432/db"));
        assert!(!is_local_db_url("postgres://u:p@localhost.evil.com/db"));
        assert!(!is_local_db_url("postgres://localhost@prod.example.com/db"));
        assert!(!is_local_db_url("not a url"));
    }

    // ───────────── Postgres (ignored; needs IDENTITY_TEST_DATABASE_URL) ─────────────
    //
    // docker run --rm -d --name id-test-pg -e POSTGRES_PASSWORD=pw -p 55433:5432 postgres:16
    // IDENTITY_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55433/postgres \
    //   cargo test identity_store -- --ignored
    // docker rm -f id-test-pg

    /// True only for a URL whose host is the local machine. The Pg harness
    /// empties tables, so it refuses to touch anything else.
    fn is_local_db_url(url: &str) -> bool {
        let rest = match url.split_once("://") {
            Some((scheme, rest)) if scheme == "postgres" || scheme == "postgresql" => rest,
            _ => return false,
        };
        let authority = rest.split(['/', '?']).next().unwrap_or("");
        let hostport = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
        let host = if let Some(stripped) = hostport.strip_prefix('[') {
            stripped.split(']').next().unwrap_or("")
        } else {
            hostport.split(':').next().unwrap_or("")
        };
        matches!(host, "localhost" | "127.0.0.1" | "::1")
    }

    /// Pg tests share one database, so they run one at a time.
    pub(crate) static PG_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Run the migrations, then empty the identity tables (local DB only).
    pub(crate) async fn fresh_pg() -> PgIdentityStore {
        let url = std::env::var("IDENTITY_TEST_DATABASE_URL")
            .expect("set IDENTITY_TEST_DATABASE_URL to run the Postgres tests");
        assert!(
            is_local_db_url(&url),
            "IDENTITY_TEST_DATABASE_URL must point at localhost; the tests empty tables"
        );
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(20)
            .connect(&url)
            .await
            .expect("connect IDENTITY_TEST_DATABASE_URL");
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        sqlx::query("TRUNCATE astation_keys, session_bindings")
            .execute(&pool)
            .await
            .unwrap();
        PgIdentityStore::new(pool)
    }

    macro_rules! pg_tests {
        ($($name:ident),* $(,)?) => {
            mod pg {
                use super::*;
                $(
                    #[tokio::test]
                    #[ignore]
                    async fn $name() {
                        let _g = PG_LOCK.lock().await;
                        let s = fresh_pg().await;
                        scenarios::$name(&s).await;
                    }
                )*

                #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
                #[ignore]
                async fn concurrent_tofu_has_one_winner() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    scenarios::concurrent_tofu_has_one_winner(Arc::new(s)).await;
                }

                #[tokio::test]
                #[ignore]
                async fn pg_backend_name() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    assert_eq!(s.backend_name(), "postgres");
                }

                /// Bindings and keys outlive the store instance (a relay restart).
                #[tokio::test]
                #[ignore]
                async fn pg_state_survives_new_store() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    s.register_key_if_absent(A, KEY1, T0).await.unwrap();
                    s.bind("s1", A, T0).await.unwrap();
                    let url = std::env::var("IDENTITY_TEST_DATABASE_URL").unwrap();
                    let pool = sqlx::postgres::PgPoolOptions::new()
                        .max_connections(2)
                        .connect(&url)
                        .await
                        .unwrap();
                    let s2 = PgIdentityStore::new(pool);
                    assert_eq!(s2.get_key(A).await.unwrap().as_deref(), Some(KEY1));
                    assert_eq!(s2.resolve("s1", T0 + 1).await.unwrap().as_deref(), Some(A));
                }

                /// `touch_key` writes `last_verified_at` (not observable via the trait).
                #[tokio::test]
                #[ignore]
                async fn pg_touch_key_updates_last_verified() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    s.register_key_if_absent(A, KEY1, T0).await.unwrap();
                    s.touch_key(A, T0 + 99).await.unwrap();
                    let (reg, ver): (i64, i64) = sqlx::query_as(
                        "SELECT registered_at, last_verified_at FROM astation_keys WHERE astation_id = $1",
                    )
                    .bind(A)
                    .fetch_one(&s.pool)
                    .await
                    .unwrap();
                    assert_eq!((reg, ver), (T0, T0 + 99));
                }
            }
        };
    }

    pg_tests!(
        tofu_first_key_wins,
        list_keys_returns_all,
        touch_key_never_registers,
        bind_and_resolve,
        bind_owned_by_other_is_rejected,
        rebind_by_owner_refreshes,
        unbind_requires_ownership,
        replace_all_resyncs,
        replace_all_refreshes_listed,
        replace_all_empty_clears_own,
        sliding_expiry,
        resolve_touch_is_throttled,
    );
}
