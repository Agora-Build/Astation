//! Account-scoped storage for Atem Memory: memories + versioned skills.
//!
//! The account is the paired astation_id (`Caller.work_session_id`). Every read
//! and write is limited to it. Callers run the secret checks before calling in;
//! the store never inspects `content` or skill `files` (files are an opaque JSON
//! object of base64 strings, passed through untouched).
//!
//! Mirrors `vault_store.rs`: one trait, an in-memory implementation for tests
//! and DB-less runs, and a Postgres implementation (migration 0002_knowledge).

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;

/// Max rows returned by one pull, regardless of the requested limit.
pub const PULL_LIMIT_CAP: i64 = 500;

/// One memory. Also the wire `Memory`. The client's `seq`, `deleted`,
/// `deleted_at`, `invalid_at` and `superseded_by` are ignored on input
/// (`valid_at` is kept). `deleted` is derived from `deleted_at` (Postgres
/// computes it in `MEMORY_COLS`) and stays on the wire for older atems.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, sqlx::FromRow)]
pub struct MemoryRow {
    pub id: String,
    pub scope: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub machine: String,
    pub content: String,
    pub content_hash: String,
    pub confidence: String,
    pub source_agent: String,
    pub source_machine: String,
    pub created_at: i64,
    #[serde(default)]
    pub deleted: bool,
    /// When it was deleted (unix seconds); `None` = not deleted.
    #[serde(default)]
    pub deleted_at: Option<i64>,
    /// When the fact became true; `None` = `created_at`.
    #[serde(default)]
    pub valid_at: Option<i64>,
    /// When it stopped being true; `None` = still valid. Final once set.
    #[serde(default)]
    pub invalid_at: Option<i64>,
    /// The memory that replaced it, if any.
    #[serde(default)]
    pub superseded_by: Option<String>,
    #[serde(default)]
    pub seq: i64,
}

/// One skill version. Also the wire `Skill`. `files` is `{relpath: base64}`,
/// kept as raw JSON. The client's `version`, `seq` and `deleted` are ignored
/// on input (the store assigns them).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SkillRow {
    pub scope: String,
    #[serde(default)]
    pub project: String,
    pub name: String,
    pub version: i64,
    pub files: serde_json::Value,
    pub content_hash: String,
    pub source_agent: String,
    pub source_machine: String,
    pub created_at: i64,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub seq: i64,
}

/// Result of `add_memory`. `id` is the id that was submitted; `canonical_id`
/// is set when the memory was deduplicated onto an existing live row (and then
/// `seq` is that row's seq).
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryAddOutcome {
    pub id: String,
    pub canonical_id: Option<String>,
    pub seq: i64,
}

/// Result of `push_skill` / `delete_skill`.
#[derive(Debug, Clone, PartialEq)]
pub struct SkillPushOutcome {
    pub version: i64,
    pub seq: i64,
    pub superseded_concurrent: bool,
}

#[derive(Debug)]
pub enum KnowledgeError {
    /// The memory id exists under a different account.
    IdConflict,
    Db(String),
}

impl std::fmt::Display for KnowledgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KnowledgeError::IdConflict => write!(f, "id conflict"),
            KnowledgeError::Db(s) => write!(f, "database error: {}", s),
        }
    }
}

fn clamp_limit(limit: i64) -> i64 {
    limit.clamp(0, PULL_LIMIT_CAP)
}

fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Storage abstraction for memories and skills.
#[async_trait]
pub trait KnowledgeStore: Send + Sync {
    fn backend_name(&self) -> &'static str;

    /// Verify that the backing store can serve requests.
    async fn health_check(&self) -> Result<(), KnowledgeError>;

    /// Idempotent by id; dedups onto a valid, undeleted row with the same
    /// `(account, scope, project, machine, content_hash)`; else inserts
    /// (keeping the client's `valid_at`).
    async fn add_memory(
        &self,
        account: &str,
        m: MemoryRow,
    ) -> Result<MemoryAddOutcome, KnowledgeError>;

    /// Blank + tombstone the memory (`deleted_at`, first deletion time kept),
    /// returning its new seq. Unknown id, or an id owned by another account →
    /// `Ok(0)` (no change, no existence oracle).
    async fn delete_memory(&self, account: &str, id: &str) -> Result<i64, KnowledgeError>;

    /// Mark a valid memory invalid (never touches `content`), returning its
    /// new seq. Final: an id that is already invalid, deleted, unknown, or
    /// owned by another account → `Ok(0)`, no change.
    async fn invalidate_memory(
        &self,
        account: &str,
        id: &str,
        invalid_at: i64,
        superseded_by: Option<&str>,
    ) -> Result<i64, KnowledgeError>;

    /// Rows with `seq > since`, ascending, at most `min(limit, 500)`. Includes tombstones.
    async fn pull_memories(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<MemoryRow>, KnowledgeError>;

    /// Append `max(version) + 1`; `superseded_concurrent = base_version < max live version`.
    async fn push_skill(
        &self,
        account: &str,
        s: SkillRow,
        base_version: i64,
    ) -> Result<SkillPushOutcome, KnowledgeError>;

    /// Append a tombstone version. Unknown skill → `version: 0, seq: 0`, nothing appended.
    async fn delete_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
    ) -> Result<SkillPushOutcome, KnowledgeError>;

    /// Blank the chosen versions (all when `None`), each with a new seq.
    /// Returns the number of rows purged.
    async fn purge_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
        versions: Option<Vec<i64>>,
    ) -> Result<u64, KnowledgeError>;

    /// Rows with `seq > since`, ascending, at most `min(limit, 500)`. Includes tombstones.
    async fn pull_skills(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<SkillRow>, KnowledgeError>;
}

// ─────────────────────────── In-memory implementation ───────────────────────────

#[derive(Default)]
struct KnowledgeState {
    seq: i64,
    /// (account, row)
    memories: Vec<(String, MemoryRow)>,
    /// (account, row)
    skills: Vec<(String, SkillRow)>,
}

impl KnowledgeState {
    fn next_seq(&mut self) -> i64 {
        self.seq += 1;
        self.seq
    }
}

/// In-memory knowledge store for tests and DB-less runs. A single mutex guards
/// all state so seq allocation and each write are atomic together.
#[derive(Clone, Default)]
pub struct InMemoryKnowledgeStore {
    state: Arc<Mutex<KnowledgeState>>,
}

impl InMemoryKnowledgeStore {
    pub fn new() -> Self {
        Self::default()
    }
}

fn skill_key_matches(
    acct: &str,
    s: &SkillRow,
    account: &str,
    scope: &str,
    project: &str,
    name: &str,
) -> bool {
    acct == account && s.scope == scope && s.project == project && s.name == name
}

#[async_trait]
impl KnowledgeStore for InMemoryKnowledgeStore {
    fn backend_name(&self) -> &'static str {
        "memory"
    }

    async fn health_check(&self) -> Result<(), KnowledgeError> {
        Ok(())
    }

    async fn add_memory(
        &self,
        account: &str,
        m: MemoryRow,
    ) -> Result<MemoryAddOutcome, KnowledgeError> {
        let mut st = self.state.lock().await;
        if let Some((acct, row)) = st.memories.iter().find(|(_, r)| r.id == m.id) {
            if acct != account {
                return Err(KnowledgeError::IdConflict);
            }
            return Ok(MemoryAddOutcome {
                id: row.id.clone(),
                canonical_id: None,
                seq: row.seq,
            });
        }
        if let Some((_, row)) = st.memories.iter().find(|(acct, r)| {
            acct == account
                && r.deleted_at.is_none()
                && r.invalid_at.is_none()
                && r.scope == m.scope
                && r.project == m.project
                && r.machine == m.machine
                && r.content_hash == m.content_hash
        }) {
            return Ok(MemoryAddOutcome {
                id: m.id,
                canonical_id: Some(row.id.clone()),
                seq: row.seq,
            });
        }
        let seq = st.next_seq();
        let id = m.id.clone();
        st.memories.push((
            account.to_string(),
            MemoryRow {
                deleted: false,
                deleted_at: None,
                invalid_at: None,
                superseded_by: None,
                seq,
                ..m
            },
        ));
        Ok(MemoryAddOutcome {
            id,
            canonical_id: None,
            seq,
        })
    }

    async fn delete_memory(&self, account: &str, id: &str) -> Result<i64, KnowledgeError> {
        let mut st = self.state.lock().await;
        // An id owned by another account is treated exactly like an unknown id.
        let idx = match st
            .memories
            .iter()
            .position(|(acct, r)| acct == account && r.id == id)
        {
            None => return Ok(0),
            Some(i) => i,
        };
        let now = now_secs();
        let seq = st.next_seq();
        let row = &mut st.memories[idx].1;
        row.content.clear();
        row.content_hash.clear();
        row.deleted = true;
        row.deleted_at.get_or_insert(now);
        row.seq = seq;
        Ok(seq)
    }

    async fn invalidate_memory(
        &self,
        account: &str,
        id: &str,
        invalid_at: i64,
        superseded_by: Option<&str>,
    ) -> Result<i64, KnowledgeError> {
        let mut st = self.state.lock().await;
        let idx = match st.memories.iter().position(|(acct, r)| {
            acct == account && r.id == id && r.deleted_at.is_none() && r.invalid_at.is_none()
        }) {
            None => return Ok(0),
            Some(i) => i,
        };
        let seq = st.next_seq();
        let row = &mut st.memories[idx].1;
        row.invalid_at = Some(invalid_at);
        row.superseded_by = superseded_by.map(str::to_string);
        row.seq = seq;
        Ok(seq)
    }

    async fn pull_memories(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<MemoryRow>, KnowledgeError> {
        let st = self.state.lock().await;
        let mut rows: Vec<MemoryRow> = st
            .memories
            .iter()
            .filter(|(acct, r)| acct == account && r.seq > since)
            .map(|(_, r)| r.clone())
            .collect();
        rows.sort_by_key(|r| r.seq);
        rows.truncate(clamp_limit(limit) as usize);
        Ok(rows)
    }

    async fn push_skill(
        &self,
        account: &str,
        s: SkillRow,
        base_version: i64,
    ) -> Result<SkillPushOutcome, KnowledgeError> {
        let mut st = self.state.lock().await;
        let (mut cur, mut cur_live) = (0i64, 0i64);
        for (acct, r) in &st.skills {
            if skill_key_matches(acct, r, account, &s.scope, &s.project, &s.name) {
                cur = cur.max(r.version);
                if !r.deleted {
                    cur_live = cur_live.max(r.version);
                }
            }
        }
        let version = cur + 1;
        let seq = st.next_seq();
        st.skills.push((
            account.to_string(),
            SkillRow {
                version,
                deleted: false,
                seq,
                ..s
            },
        ));
        Ok(SkillPushOutcome {
            version,
            seq,
            superseded_concurrent: base_version < cur_live,
        })
    }

    async fn delete_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
    ) -> Result<SkillPushOutcome, KnowledgeError> {
        let mut st = self.state.lock().await;
        let latest = st
            .skills
            .iter()
            .filter(|(acct, r)| skill_key_matches(acct, r, account, scope, project, name))
            .map(|(_, r)| r)
            .max_by_key(|r| r.version)
            .cloned();
        let latest = match latest {
            None => {
                return Ok(SkillPushOutcome {
                    version: 0,
                    seq: 0,
                    superseded_concurrent: false,
                })
            }
            Some(r) => r,
        };
        let version = latest.version + 1;
        let seq = st.next_seq();
        st.skills.push((
            account.to_string(),
            SkillRow {
                scope: scope.to_string(),
                project: project.to_string(),
                name: name.to_string(),
                version,
                files: serde_json::json!({}),
                content_hash: String::new(),
                source_agent: latest.source_agent,
                source_machine: latest.source_machine,
                created_at: now_secs(),
                deleted: true,
                seq,
            },
        ));
        Ok(SkillPushOutcome {
            version,
            seq,
            superseded_concurrent: false,
        })
    }

    async fn purge_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
        versions: Option<Vec<i64>>,
    ) -> Result<u64, KnowledgeError> {
        let mut st = self.state.lock().await;
        let mut idxs: Vec<usize> = st
            .skills
            .iter()
            .enumerate()
            .filter(|(_, (acct, r))| {
                skill_key_matches(acct, r, account, scope, project, name)
                    && versions.as_ref().is_none_or(|v| v.contains(&r.version))
            })
            .map(|(i, _)| i)
            .collect();
        idxs.sort_by_key(|&i| st.skills[i].1.version);
        for &i in &idxs {
            let seq = st.next_seq();
            let row = &mut st.skills[i].1;
            row.files = serde_json::json!({});
            row.content_hash.clear();
            row.deleted = true;
            row.seq = seq;
        }
        Ok(idxs.len() as u64)
    }

    async fn pull_skills(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<SkillRow>, KnowledgeError> {
        let st = self.state.lock().await;
        let mut rows: Vec<SkillRow> = st
            .skills
            .iter()
            .filter(|(acct, r)| acct == account && r.seq > since)
            .map(|(_, r)| r.clone())
            .collect();
        rows.sort_by_key(|r| r.seq);
        rows.truncate(clamp_limit(limit) as usize);
        Ok(rows)
    }
}

// ─────────────────────────── Postgres implementation ───────────────────────────

/// Postgres-backed knowledge store (tables from `0002_knowledge.sql`).
/// Runtime-checked queries; one transaction per write. `files` is JSONB,
/// written as text cast to `::jsonb` and read back as `::text` (the sqlx
/// `json` feature is not enabled).
#[derive(Clone)]
pub struct PgKnowledgeStore {
    pool: sqlx::PgPool,
}

impl PgKnowledgeStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

fn db_err(e: sqlx::Error) -> KnowledgeError {
    KnowledgeError::Db(e.to_string())
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    match e {
        sqlx::Error::Database(d) => d.is_unique_violation(),
        _ => false,
    }
}

const MEMORY_COLS: &str = "id, scope, project, machine, content, content_hash, confidence, \
     source_agent, source_machine, created_at, (deleted_at IS NOT NULL) AS deleted, deleted_at, \
     valid_at, invalid_at, superseded_by, seq";
const SKILL_COLS: &str = "scope, project, name, version, files::text AS files, content_hash, \
     source_agent, source_machine, created_at, deleted, seq";
const SKILL_KEY: &str = "account_id = $1 AND scope = $2 AND project = $3 AND name = $4";

/// Serialize every write transaction of one account; call it FIRST in each
/// Pg write, before anything takes a `nextval('knowledge_seq')`.
///
/// Why: a seq is allocated inside the transaction but becomes visible only at
/// commit. Without this lock, T1 (seq 10) could commit after T2 (seq 11); a
/// pull in between returns 11, the client's `since` cursor moves past 10, and
/// T1's row is never pulled. Holding a per-account lock from before `nextval`
/// until commit makes per-account commit order equal seq order, and pulls are
/// account-scoped, so a cursor never skips a row.
///
/// The same lock also serializes skill version computation (`max(version)+1`)
/// for every key of the account, including the first push of a key, which
/// `SELECT … FOR UPDATE` could not cover (no rows to lock yet). So no separate
/// per-skill-key lock is taken, and there is no lock ordering to get wrong.
/// It is a transaction-scoped advisory lock (released at commit/rollback);
/// hash collisions only serialize unrelated accounts.
async fn lock_account(conn: &mut sqlx::PgConnection, account: &str) -> Result<(), KnowledgeError> {
    let key =
        serde_json::to_string(&["acct", account]).map_err(|e| KnowledgeError::Db(e.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(conn)
        .await
        .map_err(db_err)?;
    Ok(())
}

/// The no-insert outcomes of `add_memory`: the id already exists (own account
/// → its seq; other account → IdConflict), or a live row has the dedup key.
async fn existing_memory_outcome(
    conn: &mut sqlx::PgConnection,
    account: &str,
    m: &MemoryRow,
) -> Result<Option<MemoryAddOutcome>, KnowledgeError> {
    let by_id: Option<(String, i64)> =
        sqlx::query_as("SELECT account_id, seq FROM memories WHERE id = $1")
            .bind(&m.id)
            .fetch_optional(&mut *conn)
            .await
            .map_err(db_err)?;
    if let Some((owner, seq)) = by_id {
        if owner != account {
            return Err(KnowledgeError::IdConflict);
        }
        return Ok(Some(MemoryAddOutcome {
            id: m.id.clone(),
            canonical_id: None,
            seq,
        }));
    }
    let dup: Option<(String, i64)> = sqlx::query_as(
        "SELECT id, seq FROM memories WHERE account_id = $1 AND scope = $2 AND project = $3 \
         AND machine = $4 AND content_hash = $5 AND deleted_at IS NULL AND invalid_at IS NULL",
    )
    .bind(account)
    .bind(&m.scope)
    .bind(&m.project)
    .bind(&m.machine)
    .bind(&m.content_hash)
    .fetch_optional(&mut *conn)
    .await
    .map_err(db_err)?;
    Ok(dup.map(|(cid, seq)| MemoryAddOutcome {
        id: m.id.clone(),
        canonical_id: Some(cid),
        seq,
    }))
}

/// sqlx row for `skill_versions` with `files` read as text.
#[derive(sqlx::FromRow)]
struct PgSkillRow {
    scope: String,
    project: String,
    name: String,
    version: i64,
    files: String,
    content_hash: String,
    source_agent: String,
    source_machine: String,
    created_at: i64,
    deleted: bool,
    seq: i64,
}

impl TryFrom<PgSkillRow> for SkillRow {
    type Error = KnowledgeError;
    fn try_from(r: PgSkillRow) -> Result<Self, KnowledgeError> {
        Ok(SkillRow {
            scope: r.scope,
            project: r.project,
            name: r.name,
            version: r.version,
            files: serde_json::from_str(&r.files)
                .map_err(|e| KnowledgeError::Db(format!("bad files json: {e}")))?,
            content_hash: r.content_hash,
            source_agent: r.source_agent,
            source_machine: r.source_machine,
            created_at: r.created_at,
            deleted: r.deleted,
            seq: r.seq,
        })
    }
}

#[async_trait]
impl KnowledgeStore for PgKnowledgeStore {
    fn backend_name(&self) -> &'static str {
        "postgres"
    }

    async fn health_check(&self) -> Result<(), KnowledgeError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        Ok(())
    }

    async fn add_memory(
        &self,
        account: &str,
        m: MemoryRow,
    ) -> Result<MemoryAddOutcome, KnowledgeError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        if let Some(o) = existing_memory_outcome(&mut tx, account, &m).await? {
            tx.commit().await.map_err(db_err)?;
            return Ok(o);
        }
        let inserted: Result<i64, sqlx::Error> = sqlx::query_scalar(
            "INSERT INTO memories (id, account_id, scope, project, machine, content, content_hash, \
             confidence, source_agent, source_machine, created_at, valid_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING seq",
        )
        .bind(&m.id)
        .bind(account)
        .bind(&m.scope)
        .bind(&m.project)
        .bind(&m.machine)
        .bind(&m.content)
        .bind(&m.content_hash)
        .bind(&m.confidence)
        .bind(&m.source_agent)
        .bind(&m.source_machine)
        .bind(m.created_at)
        .bind(m.valid_at)
        .fetch_one(&mut *tx)
        .await;
        match inserted {
            Ok(seq) => {
                tx.commit().await.map_err(db_err)?;
                Ok(MemoryAddOutcome {
                    id: m.id,
                    canonical_id: None,
                    seq,
                })
            }
            // Lost a race: a concurrent insert of the same id (primary key,
            // possibly from another account, which the account lock does not
            // serialize) or of the same dedup key (`memories_dedup`) committed
            // first. The transaction is aborted; re-read outside it.
            Err(e) if is_unique_violation(&e) => {
                tx.rollback().await.map_err(db_err)?;
                let mut conn = self.pool.acquire().await.map_err(db_err)?;
                match existing_memory_outcome(&mut conn, account, &m).await? {
                    Some(o) => Ok(o),
                    None => Err(KnowledgeError::Db(format!(
                        "memory insert conflicted but no existing row was found: {e}"
                    ))),
                }
            }
            Err(e) => Err(db_err(e)),
        }
    }

    async fn delete_memory(&self, account: &str, id: &str) -> Result<i64, KnowledgeError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        // Scoped to the account: an id owned by another account matches no row
        // and is indistinguishable from an unknown id (Ok(0), no existence oracle).
        let seq: Option<i64> = sqlx::query_scalar(
            "UPDATE memories SET content = '', content_hash = '', \
             deleted_at = COALESCE(deleted_at, $3), seq = nextval('knowledge_seq') \
             WHERE id = $1 AND account_id = $2 RETURNING seq",
        )
        .bind(id)
        .bind(account)
        .bind(now_secs())
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(seq.unwrap_or(0))
    }

    async fn invalidate_memory(
        &self,
        account: &str,
        id: &str,
        invalid_at: i64,
        superseded_by: Option<&str>,
    ) -> Result<i64, KnowledgeError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        // Final and account-scoped: an invalid, deleted, unknown or foreign id
        // matches no row → Ok(0).
        let seq: Option<i64> = sqlx::query_scalar(
            "UPDATE memories SET invalid_at = $3, superseded_by = $4, \
             seq = nextval('knowledge_seq') \
             WHERE id = $1 AND account_id = $2 AND deleted_at IS NULL AND invalid_at IS NULL \
             RETURNING seq",
        )
        .bind(id)
        .bind(account)
        .bind(invalid_at)
        .bind(superseded_by)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(seq.unwrap_or(0))
    }

    async fn pull_memories(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<MemoryRow>, KnowledgeError> {
        let sql = format!(
            "SELECT {MEMORY_COLS} FROM memories WHERE account_id = $1 AND seq > $2 \
             ORDER BY seq ASC LIMIT $3"
        );
        sqlx::query_as::<_, MemoryRow>(&sql)
            .bind(account)
            .bind(since)
            .bind(clamp_limit(limit))
            .fetch_all(&self.pool)
            .await
            .map_err(db_err)
    }

    async fn push_skill(
        &self,
        account: &str,
        s: SkillRow,
        base_version: i64,
    ) -> Result<SkillPushOutcome, KnowledgeError> {
        let files =
            serde_json::to_string(&s.files).map_err(|e| KnowledgeError::Db(e.to_string()))?;
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        let (cur, cur_live): (i64, i64) = sqlx::query_as(&format!(
            "SELECT COALESCE(MAX(version), 0)::bigint, \
             COALESCE(MAX(version) FILTER (WHERE NOT deleted), 0)::bigint \
             FROM skill_versions WHERE {SKILL_KEY}"
        ))
        .bind(account)
        .bind(&s.scope)
        .bind(&s.project)
        .bind(&s.name)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;
        let version = cur + 1;
        let seq: i64 = sqlx::query_scalar(
            "INSERT INTO skill_versions (account_id, scope, project, name, version, files, \
             content_hash, source_agent, source_machine, created_at, deleted) \
             VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10, false) RETURNING seq",
        )
        .bind(account)
        .bind(&s.scope)
        .bind(&s.project)
        .bind(&s.name)
        .bind(version)
        .bind(files)
        .bind(&s.content_hash)
        .bind(&s.source_agent)
        .bind(&s.source_machine)
        .bind(s.created_at)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(SkillPushOutcome {
            version,
            seq,
            superseded_concurrent: base_version < cur_live,
        })
    }

    async fn delete_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
    ) -> Result<SkillPushOutcome, KnowledgeError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        let latest: Option<(i64, String, String)> = sqlx::query_as(&format!(
            "SELECT version, source_agent, source_machine FROM skill_versions \
             WHERE {SKILL_KEY} ORDER BY version DESC LIMIT 1"
        ))
        .bind(account)
        .bind(scope)
        .bind(project)
        .bind(name)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?;
        let (cur, source_agent, source_machine) = match latest {
            None => {
                return Ok(SkillPushOutcome {
                    version: 0,
                    seq: 0,
                    superseded_concurrent: false,
                })
            }
            Some(r) => r,
        };
        let version = cur + 1;
        let seq: i64 = sqlx::query_scalar(
            "INSERT INTO skill_versions (account_id, scope, project, name, version, files, \
             content_hash, source_agent, source_machine, created_at, deleted) \
             VALUES ($1, $2, $3, $4, $5, '{}'::jsonb, '', $6, $7, $8, true) RETURNING seq",
        )
        .bind(account)
        .bind(scope)
        .bind(project)
        .bind(name)
        .bind(version)
        .bind(source_agent)
        .bind(source_machine)
        .bind(now_secs())
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(SkillPushOutcome {
            version,
            seq,
            superseded_concurrent: false,
        })
    }

    async fn purge_skill(
        &self,
        account: &str,
        scope: &str,
        project: &str,
        name: &str,
        versions: Option<Vec<i64>>,
    ) -> Result<u64, KnowledgeError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account(&mut tx, account).await?;
        // Assign new seqs in version order (matches in-memory). Postgres evaluates a
        // volatile target-list function (nextval) after ORDER BY at the same level.
        let res = sqlx::query(&format!(
            "WITH renum AS ( \
               SELECT version, nextval('knowledge_seq') AS new_seq FROM skill_versions \
               WHERE {SKILL_KEY} AND ($5::bigint[] IS NULL OR version = ANY($5)) \
               ORDER BY version \
             ) \
             UPDATE skill_versions sv SET files = '{{}}'::jsonb, content_hash = '', \
               deleted = true, seq = renum.new_seq \
             FROM renum WHERE sv.account_id = $1 AND sv.scope = $2 AND sv.project = $3 \
               AND sv.name = $4 AND sv.version = renum.version"
        ))
        .bind(account)
        .bind(scope)
        .bind(project)
        .bind(name)
        .bind(versions)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(res.rows_affected())
    }

    async fn pull_skills(
        &self,
        account: &str,
        since: i64,
        limit: i64,
    ) -> Result<Vec<SkillRow>, KnowledgeError> {
        let sql = format!(
            "SELECT {SKILL_COLS} FROM skill_versions WHERE account_id = $1 AND seq > $2 \
             ORDER BY seq ASC LIMIT $3"
        );
        let rows: Vec<PgSkillRow> = sqlx::query_as(&sql)
            .bind(account)
            .bind(since)
            .bind(clamp_limit(limit))
            .fetch_all(&self.pool)
            .await
            .map_err(db_err)?;
        rows.into_iter().map(SkillRow::try_from).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const A: &str = "astation-a";
    const B: &str = "astation-b";

    fn mem(id: &str, content: &str) -> MemoryRow {
        MemoryRow {
            id: id.to_string(),
            scope: "global".to_string(),
            project: String::new(),
            machine: String::new(),
            content: content.to_string(),
            content_hash: format!("h:{}", content),
            confidence: "medium".to_string(),
            source_agent: "claude".to_string(),
            source_machine: "m1".to_string(),
            created_at: 1_700_000_000,
            deleted: false,
            deleted_at: None,
            valid_at: None,
            invalid_at: None,
            superseded_by: None,
            seq: 0,
        }
    }

    fn skill(name: &str, body: &str) -> SkillRow {
        SkillRow {
            scope: "global".to_string(),
            project: String::new(),
            name: name.to_string(),
            version: 0,
            files: json!({ "SKILL.md": body }),
            content_hash: format!("h:{}", body),
            source_agent: "claude".to_string(),
            source_machine: "m1".to_string(),
            created_at: 1_700_000_000,
            deleted: false,
            seq: 0,
        }
    }

    /// Scenarios shared by the in-memory and Postgres tests. Each assumes an
    /// empty store.
    pub(super) mod scenarios {
        use super::*;

        pub async fn add_is_idempotent_by_id(s: &dyn KnowledgeStore) {
            let o1 = s.add_memory(A, mem("mem_1", "use pnpm")).await.unwrap();
            assert_eq!(o1.id, "mem_1");
            assert_eq!(o1.canonical_id, None);
            assert!(o1.seq > 0);
            // Same id again (even with different content) → unchanged.
            let o2 = s
                .add_memory(A, mem("mem_1", "something else"))
                .await
                .unwrap();
            assert_eq!(o2, o1);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].content, "use pnpm");
            // Also idempotent against a deleted row: returns the tombstone's seq.
            let d = s.delete_memory(A, "mem_1").await.unwrap();
            let o3 = s.add_memory(A, mem("mem_1", "use pnpm")).await.unwrap();
            assert_eq!(
                o3,
                MemoryAddOutcome {
                    id: "mem_1".into(),
                    canonical_id: None,
                    seq: d
                }
            );
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            assert!(rows[0].deleted);
        }

        pub async fn add_dedups_to_canonical_id(s: &dyn KnowledgeStore) {
            let o1 = s.add_memory(A, mem("mem_1", "use pnpm")).await.unwrap();
            let o2 = s.add_memory(A, mem("mem_2", "use pnpm")).await.unwrap();
            assert_eq!(o2.id, "mem_2");
            assert_eq!(o2.canonical_id.as_deref(), Some("mem_1"));
            assert_eq!(o2.seq, o1.seq);
            assert_eq!(s.pull_memories(A, 0, 100).await.unwrap().len(), 1);
            // A different part of the dedup key → a new row.
            let mut p = mem("mem_3", "use pnpm");
            p.scope = "project".into();
            p.project = "github.com/x/y".into();
            let o3 = s.add_memory(A, p).await.unwrap();
            assert_eq!(o3.canonical_id, None);
            let mut m = mem("mem_4", "use pnpm");
            m.scope = "machine".into();
            m.machine = "m1".into();
            assert_eq!(s.add_memory(A, m).await.unwrap().canonical_id, None);
            // The same content in another account is not a dedup hit.
            assert_eq!(
                s.add_memory(B, mem("mem_5", "use pnpm"))
                    .await
                    .unwrap()
                    .canonical_id,
                None
            );
            assert_eq!(s.pull_memories(A, 0, 100).await.unwrap().len(), 3);
        }

        pub async fn add_after_delete_of_same_content_inserts(s: &dyn KnowledgeStore) {
            s.add_memory(A, mem("mem_1", "use pnpm")).await.unwrap();
            let d = s.delete_memory(A, "mem_1").await.unwrap();
            let o = s.add_memory(A, mem("mem_2", "use pnpm")).await.unwrap();
            assert_eq!(o.canonical_id, None);
            assert!(o.seq > d);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 2);
            assert_eq!(rows[1].id, "mem_2");
            assert!(!rows[1].deleted);
        }

        pub async fn id_owned_by_other_account_is_rejected(s: &dyn KnowledgeStore) {
            let o = s.add_memory(A, mem("mem_1", "secretly A's")).await.unwrap();
            assert!(matches!(
                s.add_memory(B, mem("mem_1", "x")).await,
                Err(KnowledgeError::IdConflict)
            ));
            // Deleting another account's id is indistinguishable from an
            // unknown id: Ok(0), and A's row is untouched.
            assert_eq!(s.delete_memory(B, "mem_1").await.unwrap(), 0);
            assert_eq!(s.delete_memory(B, "mem_unknown").await.unwrap(), 0);
            assert!(s.pull_memories(B, 0, 100).await.unwrap().is_empty());
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].content, "secretly A's");
            assert_eq!(rows[0].seq, o.seq);
            assert!(!rows[0].deleted);
        }

        pub async fn delete_blanks_and_is_idempotent(s: &dyn KnowledgeStore) {
            let o = s.add_memory(A, mem("mem_1", "use pnpm")).await.unwrap();
            let d = s.delete_memory(A, "mem_1").await.unwrap();
            assert!(d > o.seq);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            let r = &rows[0];
            assert_eq!((r.content.as_str(), r.content_hash.as_str()), ("", ""));
            assert!(r.deleted);
            assert_eq!(r.seq, d);
            // Unknown id → Ok(0), nothing changes.
            assert_eq!(s.delete_memory(A, "mem_nope").await.unwrap(), 0);
            // Deleting again is ok and leaves a blank tombstone.
            let d2 = s.delete_memory(A, "mem_1").await.unwrap();
            assert!(d2 > 0);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            assert!(rows[0].deleted && rows[0].content.is_empty());
        }

        pub async fn pull_is_account_scoped_and_ordered(s: &dyn KnowledgeStore) {
            s.add_memory(A, mem("a1", "one")).await.unwrap();
            s.add_memory(B, mem("b1", "one")).await.unwrap();
            s.add_memory(A, mem("a2", "two")).await.unwrap();
            s.add_memory(B, mem("b2", "two")).await.unwrap();
            s.add_memory(A, mem("a3", "three")).await.unwrap();
            s.delete_memory(A, "a1").await.unwrap(); // a1 moves to the end
            let a = s.pull_memories(A, 0, 100).await.unwrap();
            let ids: Vec<&str> = a.iter().map(|r| r.id.as_str()).collect();
            assert_eq!(ids, vec!["a2", "a3", "a1"]);
            assert!(a.windows(2).all(|w| w[0].seq < w[1].seq));
            let b = s.pull_memories(B, 0, 100).await.unwrap();
            let ids: Vec<&str> = b.iter().map(|r| r.id.as_str()).collect();
            assert_eq!(ids, vec!["b1", "b2"]);

            s.push_skill(A, skill("x", "a"), 0).await.unwrap();
            s.push_skill(B, skill("x", "b"), 0).await.unwrap();
            s.push_skill(A, skill("y", "a"), 0).await.unwrap();
            let sk = s.pull_skills(A, 0, 100).await.unwrap();
            let names: Vec<&str> = sk.iter().map(|r| r.name.as_str()).collect();
            assert_eq!(names, vec!["x", "y"]);
            assert!(sk.iter().all(|r| r.files == json!({"SKILL.md": "a"})));
            let sk = s.pull_skills(B, 0, 100).await.unwrap();
            assert_eq!(sk.len(), 1);
            assert_eq!(sk[0].files, json!({"SKILL.md": "b"}));
        }

        pub async fn pull_respects_since_and_limit_cap(s: &dyn KnowledgeStore) {
            let mut seqs = Vec::new();
            for i in 0..505 {
                let o = s
                    .add_memory(A, mem(&format!("mem_{i}"), &format!("c{i}")))
                    .await
                    .unwrap();
                seqs.push(o.seq);
            }
            assert_eq!(s.pull_memories(A, 0, 10_000).await.unwrap().len(), 500);
            assert_eq!(s.pull_memories(A, 0, 2).await.unwrap().len(), 2);
            assert_eq!(s.pull_memories(A, 0, 0).await.unwrap().len(), 0);
            let rest = s.pull_memories(A, seqs[499], 10_000).await.unwrap();
            assert_eq!(rest.len(), 5);
            assert_eq!(rest[0].id, "mem_500");
            assert!(rest.iter().all(|r| r.seq > seqs[499]));
            assert!(s.pull_memories(A, seqs[504], 10).await.unwrap().is_empty());

            for i in 0..3 {
                s.push_skill(A, skill(&format!("s{i}"), "x"), 0)
                    .await
                    .unwrap();
            }
            let all = s.pull_skills(A, 0, 10).await.unwrap();
            assert_eq!(all.len(), 3);
            let after = s.pull_skills(A, all[0].seq, 1).await.unwrap();
            assert_eq!(after.len(), 1);
            assert_eq!(after[0].name, "s1");
        }

        pub async fn push_skill_appends_versions_and_flags_supersede(s: &dyn KnowledgeStore) {
            let p1 = s.push_skill(A, skill("x", "v1"), 0).await.unwrap();
            assert_eq!((p1.version, p1.superseded_concurrent), (1, false));
            let p2 = s.push_skill(A, skill("x", "v2"), 1).await.unwrap();
            assert_eq!((p2.version, p2.superseded_concurrent), (2, false));
            assert!(p2.seq > p1.seq);
            // Pushed from a stale base → still appended, flagged.
            let p3 = s.push_skill(A, skill("x", "v3"), 1).await.unwrap();
            assert_eq!((p3.version, p3.superseded_concurrent), (3, true));
            // The client's version/seq/deleted are ignored.
            let mut forged = skill("x", "v4");
            forged.version = 99;
            forged.seq = 99_999;
            forged.deleted = true;
            let p4 = s.push_skill(A, forged, 3).await.unwrap();
            assert_eq!((p4.version, p4.superseded_concurrent), (4, false));
            // A tombstone doesn't count as live: cur_live stays 4.
            let d = s.delete_skill(A, "global", "", "x").await.unwrap();
            assert_eq!(d.version, 5);
            let p6 = s.push_skill(A, skill("x", "v6"), 4).await.unwrap();
            assert_eq!((p6.version, p6.superseded_concurrent), (6, false));
            // Base 5 (the tombstone) is older than live v6 → flagged.
            let p7 = s.push_skill(A, skill("x", "v7"), 5).await.unwrap();
            assert_eq!((p7.version, p7.superseded_concurrent), (7, true));
            let p8 = s.push_skill(A, skill("x", "v8"), 0).await.unwrap();
            assert_eq!((p8.version, p8.superseded_concurrent), (8, true));
            // Keys are independent (name, project, account).
            assert_eq!(
                s.push_skill(A, skill("y", "v1"), 0).await.unwrap().version,
                1
            );
            let mut proj = skill("x", "p");
            proj.scope = "project".into();
            proj.project = "github.com/x/y".into();
            assert_eq!(s.push_skill(A, proj, 0).await.unwrap().version, 1);
            assert_eq!(
                s.push_skill(B, skill("x", "b"), 0).await.unwrap().version,
                1
            );
            // After purging every version, nothing is live and versions keep growing.
            s.purge_skill(A, "global", "", "x", None).await.unwrap();
            let p9 = s.push_skill(A, skill("x", "v9"), 0).await.unwrap();
            assert_eq!((p9.version, p9.superseded_concurrent), (9, false));
            let rows: Vec<SkillRow> = s
                .pull_skills(A, 0, 500)
                .await
                .unwrap()
                .into_iter()
                .filter(|r| r.name == "x" && r.scope == "global")
                .collect();
            let mut versions: Vec<i64> = rows.iter().map(|r| r.version).collect();
            versions.sort();
            assert_eq!(versions, (1..=9).collect::<Vec<_>>());
            let v9 = rows.iter().find(|r| r.version == 9).unwrap();
            assert!(!v9.deleted);
            assert_eq!(v9.files, json!({"SKILL.md": "v9"}));
            assert_eq!(v9.content_hash, "h:v9");
        }

        pub async fn delete_skill_appends_tombstone(s: &dyn KnowledgeStore) {
            let p = s.push_skill(A, skill("x", "v1"), 0).await.unwrap();
            let d = s.delete_skill(A, "global", "", "x").await.unwrap();
            assert_eq!(d.version, 2);
            assert!(d.seq > p.seq);
            assert!(!d.superseded_concurrent);
            let rows = s.pull_skills(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 2);
            let t = &rows[1];
            assert_eq!((t.version, t.deleted, t.seq), (2, true, d.seq));
            assert_eq!(t.files, json!({}));
            assert_eq!(t.content_hash, "");
            assert_eq!(t.source_agent, "claude");
            // v1 is untouched.
            assert_eq!(rows[0].files, json!({"SKILL.md": "v1"}));
            assert!(!rows[0].deleted);
            // Unknown skill (or another account's) → 0/0, nothing appended.
            let u = s.delete_skill(A, "global", "", "nope").await.unwrap();
            assert_eq!((u.version, u.seq), (0, 0));
            let u = s.delete_skill(B, "global", "", "x").await.unwrap();
            assert_eq!((u.version, u.seq), (0, 0));
            assert_eq!(s.pull_skills(A, 0, 100).await.unwrap().len(), 2);
            assert!(s.pull_skills(B, 0, 100).await.unwrap().is_empty());
        }

        pub async fn purge_selected_and_all_versions(s: &dyn KnowledgeStore) {
            for v in 1..=3 {
                s.push_skill(A, skill("x", &format!("v{v}")), v - 1)
                    .await
                    .unwrap();
            }
            s.push_skill(B, skill("x", "b"), 0).await.unwrap();
            let before = s.pull_skills(A, 0, 100).await.unwrap();
            let max_before = before.iter().map(|r| r.seq).max().unwrap();

            let n = s
                .purge_skill(A, "global", "", "x", Some(vec![1, 3, 42]))
                .await
                .unwrap();
            assert_eq!(n, 2);
            let rows = s.pull_skills(A, max_before, 100).await.unwrap();
            let vs: Vec<i64> = rows.iter().map(|r| r.version).collect();
            assert_eq!(vs, vec![1, 3], "purged rows get new seqs, v2 does not");
            assert_ne!(rows[0].seq, rows[1].seq);
            for r in &rows {
                assert!(r.deleted);
                assert_eq!(r.files, json!({}));
                assert_eq!(r.content_hash, "");
            }
            let all = s.pull_skills(A, 0, 100).await.unwrap();
            let v2 = all.iter().find(|r| r.version == 2).unwrap();
            assert!(!v2.deleted);
            assert_eq!(v2.files, json!({"SKILL.md": "v2"}));

            let n = s.purge_skill(A, "global", "", "x", None).await.unwrap();
            assert_eq!(n, 3);
            let all = s.pull_skills(A, 0, 100).await.unwrap();
            assert_eq!(all.len(), 3);
            assert!(all
                .iter()
                .all(|r| r.deleted && r.files == json!({}) && r.content_hash.is_empty()));
            // Unknown skill → 0; the other account is untouched.
            assert_eq!(
                s.purge_skill(A, "global", "", "nope", None).await.unwrap(),
                0
            );
            let b = s.pull_skills(B, 0, 100).await.unwrap();
            assert_eq!(b.len(), 1);
            assert!(!b[0].deleted);
            assert_eq!(b[0].files, json!({"SKILL.md": "b"}));
        }

        pub async fn seq_is_global_and_monotonic(s: &dyn KnowledgeStore) {
            let mut seqs = vec![
                s.add_memory(A, mem("m1", "one")).await.unwrap().seq,
                s.push_skill(A, skill("x", "v1"), 0).await.unwrap().seq,
                s.add_memory(B, mem("m2", "two")).await.unwrap().seq,
                s.delete_memory(A, "m1").await.unwrap(),
                s.push_skill(B, skill("x", "v1"), 0).await.unwrap().seq,
                s.delete_skill(A, "global", "", "x").await.unwrap().seq,
            ];
            s.purge_skill(A, "global", "", "x", Some(vec![1]))
                .await
                .unwrap();
            let purged = s.pull_skills(A, 0, 100).await.unwrap();
            seqs.push(purged.iter().find(|r| r.version == 1).unwrap().seq);
            seqs.push(s.add_memory(A, mem("m3", "three")).await.unwrap().seq);
            seqs.push(s.invalidate_memory(A, "m3", 5, None).await.unwrap());
            assert!(seqs.windows(2).all(|w| w[0] < w[1]), "{seqs:?}");
        }

        pub async fn concurrent_skill_pushes_get_distinct_versions(s: Arc<dyn KnowledgeStore>) {
            let mut handles = Vec::new();
            for i in 0..10 {
                let s = s.clone();
                handles.push(tokio::spawn(async move {
                    s.push_skill(A, skill("race", &format!("v{i}")), 0)
                        .await
                        .unwrap()
                }));
            }
            let mut versions = Vec::new();
            let mut seqs = Vec::new();
            for h in handles {
                let o = h.await.unwrap();
                versions.push(o.version);
                seqs.push(o.seq);
            }
            versions.sort();
            assert_eq!(versions, (1..=10).collect::<Vec<_>>());
            seqs.sort();
            seqs.dedup();
            assert_eq!(seqs.len(), 10);
            assert_eq!(s.pull_skills(A, 0, 100).await.unwrap().len(), 10);
        }

        /// Concurrent writers on one account while a reader pulls with a
        /// cursor (`since = max seq seen`). Every write must eventually be
        /// observed: a row that becomes visible with a seq below the cursor
        /// would be skipped forever.
        pub async fn cursor_pull_never_skips_rows(s: Arc<dyn KnowledgeStore>) {
            use std::collections::HashSet;
            use std::sync::atomic::{AtomicBool, Ordering};
            const WRITERS: usize = 8;
            const OPS: usize = 30;
            let done = Arc::new(AtomicBool::new(false));

            let reader = {
                let (s, done) = (s.clone(), done.clone());
                tokio::spawn(async move {
                    let (mut mcur, mut scur) = (0i64, 0i64);
                    let mut mem_seen: HashSet<(String, bool)> = HashSet::new();
                    let mut skill_seen: HashSet<(String, i64)> = HashSet::new();
                    loop {
                        // Read the flag BEFORE pulling: once it is set, every
                        // write has committed, so this pass drains the rest.
                        let finished = done.load(Ordering::SeqCst);
                        loop {
                            let rows = s.pull_memories(A, mcur, 500).await.unwrap();
                            let skills = s.pull_skills(A, scur, 500).await.unwrap();
                            if rows.is_empty() && skills.is_empty() {
                                break;
                            }
                            for r in rows {
                                assert!(r.seq > mcur, "pull must be ascending past the cursor");
                                mcur = r.seq;
                                mem_seen.insert((r.id, r.deleted));
                            }
                            for r in skills {
                                assert!(r.seq > scur, "pull must be ascending past the cursor");
                                scur = r.seq;
                                skill_seen.insert((r.name, r.version));
                            }
                        }
                        if finished {
                            return (mem_seen, skill_seen);
                        }
                        tokio::task::yield_now().await;
                    }
                })
            };

            let mut writers = Vec::new();
            for w in 0..WRITERS {
                let s = s.clone();
                writers.push(tokio::spawn(async move {
                    let mut added = Vec::new();
                    let mut deleted = Vec::new();
                    let mut pushed = Vec::new();
                    for i in 0..OPS {
                        let id = format!("mem_{w}_{i}");
                        s.add_memory(A, mem(&id, &id)).await.unwrap();
                        added.push(id.clone());
                        if i % 3 == 0 {
                            assert!(s.delete_memory(A, &id).await.unwrap() > 0);
                            deleted.push(id);
                        }
                        if i % 2 == 0 {
                            let name = format!("skill_{w}");
                            let o = s
                                .push_skill(A, skill(&name, &format!("{i}")), 0)
                                .await
                                .unwrap();
                            pushed.push((name, o.version));
                        }
                    }
                    (added, deleted, pushed)
                }));
            }
            let mut want_mem: HashSet<(String, bool)> = HashSet::new();
            let mut want_skill: HashSet<(String, i64)> = HashSet::new();
            for h in writers {
                let (added, deleted, pushed) = h.await.unwrap();
                // Each add was visible live at some point unless it was
                // deleted before the reader could see it; the tombstone of a
                // deleted id must always be seen.
                for id in added {
                    if !deleted.contains(&id) {
                        want_mem.insert((id, false));
                    }
                }
                for id in deleted {
                    want_mem.insert((id, true));
                }
                want_skill.extend(pushed);
            }
            done.store(true, Ordering::SeqCst);
            let (mem_seen, skill_seen) = reader.await.unwrap();
            let missing_mem: Vec<_> = want_mem.difference(&mem_seen).collect();
            let missing_skill: Vec<_> = want_skill.difference(&skill_seen).collect();
            assert!(
                missing_mem.is_empty() && missing_skill.is_empty(),
                "cursor skipped rows: {} memories {:?}, {} skills {:?}",
                missing_mem.len(),
                missing_mem.iter().take(5).collect::<Vec<_>>(),
                missing_skill.len(),
                missing_skill.iter().take(5).collect::<Vec<_>>()
            );
        }

        pub async fn invalidate_is_final_and_keeps_content(s: &dyn KnowledgeStore) {
            let a = s.add_memory(A, mem("mem_1", "port 8765")).await.unwrap();
            let b = s.add_memory(A, mem("mem_2", "port 9000")).await.unwrap();
            let i = s
                .invalidate_memory(A, "mem_1", 1_790_000_000, Some("mem_2"))
                .await
                .unwrap();
            assert!(i > a.seq && i > b.seq);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            let r1 = rows.iter().find(|r| r.id == "mem_1").unwrap().clone();
            assert_eq!(r1.content, "port 8765");
            assert_eq!(r1.content_hash, "h:port 8765");
            assert_eq!(
                (r1.invalid_at, r1.superseded_by.as_deref(), r1.seq),
                (Some(1_790_000_000), Some("mem_2"), i)
            );
            assert!(!r1.deleted && r1.deleted_at.is_none());
            // Final: a repeat (with any values) changes nothing and takes no seq.
            assert_eq!(
                s.invalidate_memory(A, "mem_1", 1_800_000_000, Some("mem_3")).await.unwrap(),
                0
            );
            assert_eq!(s.invalidate_memory(A, "mem_1", 1_800_000_000, None).await.unwrap(), 0);
            let again = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(again.iter().find(|r| r.id == "mem_1").unwrap(), &r1);
            // A cursor past mem_2's add sees exactly the invalidation.
            let after = s.pull_memories(A, b.seq, 100).await.unwrap();
            assert_eq!(after.len(), 1);
            assert_eq!(after[0].id, "mem_1");
            // Without a successor.
            let j = s.invalidate_memory(A, "mem_2", 1_790_000_100, None).await.unwrap();
            assert!(j > i);
            let r2 = s.pull_memories(A, i, 100).await.unwrap();
            assert_eq!((r2[0].invalid_at, r2[0].superseded_by.clone()), (Some(1_790_000_100), None));
        }

        pub async fn invalidate_unknown_deleted_or_foreign_is_a_noop(s: &dyn KnowledgeStore) {
            s.add_memory(A, mem("mem_1", "a")).await.unwrap();
            s.add_memory(A, mem("mem_2", "b")).await.unwrap();
            let d = s.delete_memory(A, "mem_2").await.unwrap();
            assert_eq!(s.invalidate_memory(A, "mem_nope", 5, None).await.unwrap(), 0);
            assert_eq!(s.invalidate_memory(A, "mem_2", 5, None).await.unwrap(), 0);
            assert_eq!(s.invalidate_memory(B, "mem_1", 5, None).await.unwrap(), 0);
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert!(rows.iter().all(|r| r.invalid_at.is_none()));
            assert_eq!(rows.iter().map(|r| r.seq).max().unwrap(), d);
            assert!(s.pull_memories(B, 0, 100).await.unwrap().is_empty());
        }

        pub async fn dedup_ignores_invalid_rows(s: &dyn KnowledgeStore) {
            let o1 = s.add_memory(A, mem("mem_1", "port 8765")).await.unwrap();
            s.invalidate_memory(A, "mem_1", 10, None).await.unwrap();
            // The fact became true again: a new memory, not a dedup onto the invalid one.
            let o2 = s.add_memory(A, mem("mem_2", "port 8765")).await.unwrap();
            assert_eq!(o2.canonical_id, None);
            assert!(o2.seq > o1.seq);
            // Now the valid mem_2 is the dedup target.
            let o3 = s.add_memory(A, mem("mem_3", "port 8765")).await.unwrap();
            assert_eq!(o3.canonical_id.as_deref(), Some("mem_2"));
            // Idempotent by id still holds for an invalid row.
            let again = s.add_memory(A, mem("mem_1", "port 8765")).await.unwrap();
            assert_eq!((again.id.as_str(), again.canonical_id), ("mem_1", None));
        }

        pub async fn add_keeps_valid_at_and_ignores_client_state(s: &dyn KnowledgeStore) {
            let mut m = mem("mem_1", "port 8765");
            m.valid_at = Some(1_700_000_500);
            m.deleted = true;
            m.deleted_at = Some(9);
            m.invalid_at = Some(9);
            m.superseded_by = Some("mem_x".into());
            s.add_memory(A, m).await.unwrap();
            let r = s.pull_memories(A, 0, 100).await.unwrap().remove(0);
            assert_eq!(r.valid_at, Some(1_700_000_500));
            assert!(!r.deleted);
            assert_eq!((r.deleted_at, r.invalid_at, r.superseded_by), (None, None, None));
        }

        pub async fn delete_records_deleted_at(s: &dyn KnowledgeStore) {
            s.add_memory(A, mem("mem_1", "x")).await.unwrap();
            let before = chrono::Utc::now().timestamp();
            s.delete_memory(A, "mem_1").await.unwrap();
            let r = s.pull_memories(A, 0, 100).await.unwrap().remove(0);
            let at = r.deleted_at.expect("deleted_at set");
            assert!(r.deleted && at >= before && at <= before + 5);
            // A repeat delete keeps the first deletion time.
            s.delete_memory(A, "mem_1").await.unwrap();
            assert_eq!(s.pull_memories(A, 0, 100).await.unwrap()[0].deleted_at, Some(at));
            // Deleting an invalidated fact clears its text too.
            s.add_memory(A, mem("mem_2", "y")).await.unwrap();
            s.invalidate_memory(A, "mem_2", 7, None).await.unwrap();
            s.delete_memory(A, "mem_2").await.unwrap();
            let r2 = s
                .pull_memories(A, 0, 100)
                .await
                .unwrap()
                .into_iter()
                .find(|r| r.id == "mem_2")
                .unwrap();
            assert!(r2.deleted && r2.content.is_empty() && r2.deleted_at.is_some());
        }

        pub async fn concurrent_dedup_adds_converge(s: Arc<dyn KnowledgeStore>) {
            let mut handles = Vec::new();
            for i in 0..10 {
                let s = s.clone();
                handles.push(tokio::spawn(async move {
                    s.add_memory(A, mem(&format!("mem_{i}"), "same content"))
                        .await
                        .unwrap()
                }));
            }
            let mut outs = Vec::new();
            for h in handles {
                outs.push(h.await.unwrap());
            }
            let winners: Vec<&MemoryAddOutcome> =
                outs.iter().filter(|o| o.canonical_id.is_none()).collect();
            assert_eq!(winners.len(), 1, "{outs:?}");
            let winner = winners[0].id.clone();
            for o in &outs {
                if o.canonical_id.is_some() {
                    assert_eq!(o.canonical_id.as_deref(), Some(winner.as_str()));
                    assert_eq!(o.seq, winners[0].seq);
                }
            }
            let rows = s.pull_memories(A, 0, 100).await.unwrap();
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].id, winner);

            // Concurrent adds of the same id all see one row.
            let mut handles = Vec::new();
            for _ in 0..10 {
                let s = s.clone();
                handles.push(tokio::spawn(async move {
                    s.add_memory(A, mem("mem_same", "other content"))
                        .await
                        .unwrap()
                }));
            }
            let mut outs = Vec::new();
            for h in handles {
                outs.push(h.await.unwrap());
            }
            assert!(
                outs.iter()
                    .all(|o| o == &outs[0] && o.canonical_id.is_none()),
                "{outs:?}"
            );
            assert_eq!(s.pull_memories(A, 0, 100).await.unwrap().len(), 2);
        }
    }

    // ───────────── in-memory ─────────────

    macro_rules! in_memory_tests {
        ($($name:ident),* $(,)?) => {
            $(
                #[tokio::test]
                async fn $name() {
                    let s = InMemoryKnowledgeStore::new();
                    scenarios::$name(&s).await;
                }
            )*
        };
    }

    in_memory_tests!(
        add_is_idempotent_by_id,
        add_dedups_to_canonical_id,
        add_after_delete_of_same_content_inserts,
        id_owned_by_other_account_is_rejected,
        delete_blanks_and_is_idempotent,
        pull_is_account_scoped_and_ordered,
        pull_respects_since_and_limit_cap,
        push_skill_appends_versions_and_flags_supersede,
        delete_skill_appends_tombstone,
        purge_selected_and_all_versions,
        seq_is_global_and_monotonic,
        invalidate_is_final_and_keeps_content,
        invalidate_unknown_deleted_or_foreign_is_a_noop,
        dedup_ignores_invalid_rows,
        add_keeps_valid_at_and_ignores_client_state,
        delete_records_deleted_at,
    );

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_skill_pushes_get_distinct_versions() {
        scenarios::concurrent_skill_pushes_get_distinct_versions(Arc::new(
            InMemoryKnowledgeStore::new(),
        ))
        .await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn cursor_pull_never_skips_rows() {
        scenarios::cursor_pull_never_skips_rows(Arc::new(InMemoryKnowledgeStore::new())).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_dedup_adds_converge() {
        scenarios::concurrent_dedup_adds_converge(Arc::new(InMemoryKnowledgeStore::new())).await;
    }

    // ───────────── Postgres (ignored; needs KNOWLEDGE_TEST_DATABASE_URL) ─────────────
    //
    // docker run --rm -d --name ks-test-pg -e POSTGRES_PASSWORD=pw -p 55432:5432 postgres:16
    // KNOWLEDGE_TEST_DATABASE_URL=postgres://postgres:pw@localhost:55432/postgres \
    //   cargo test knowledge_store -- --ignored

    /// Pg tests share one database, so they run one at a time.
    static PG_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Drop and recreate the knowledge tables, then run the migrations.
    async fn fresh_pg() -> PgKnowledgeStore {
        let url = std::env::var("KNOWLEDGE_TEST_DATABASE_URL")
            .expect("set KNOWLEDGE_TEST_DATABASE_URL to run the Postgres tests");
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(12)
            .connect(&url)
            .await
            .expect("connect KNOWLEDGE_TEST_DATABASE_URL");
        for stmt in [
            "DROP TABLE IF EXISTS memories",
            "DROP TABLE IF EXISTS skill_versions",
            "DROP SEQUENCE IF EXISTS knowledge_seq",
            // Forget applied migrations so 0002 runs again (0001 is IF NOT EXISTS).
            "DROP TABLE IF EXISTS _sqlx_migrations",
        ] {
            sqlx::query(stmt).execute(&pool).await.unwrap();
        }
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        PgKnowledgeStore::new(pool)
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
                async fn concurrent_skill_pushes_get_distinct_versions() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    scenarios::concurrent_skill_pushes_get_distinct_versions(Arc::new(s)).await;
                }

                #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
                #[ignore]
                async fn cursor_pull_never_skips_rows() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    scenarios::cursor_pull_never_skips_rows(Arc::new(s)).await;
                }

                #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
                #[ignore]
                async fn concurrent_dedup_adds_converge() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    scenarios::concurrent_dedup_adds_converge(Arc::new(s)).await;
                }

                #[tokio::test]
                #[ignore]
                async fn pg_backend_name_and_health() {
                    let _g = PG_LOCK.lock().await;
                    let s = fresh_pg().await;
                    assert_eq!(s.backend_name(), "postgres");
                    assert!(s.health_check().await.is_ok());
                }
            }
        };
    }

    pg_tests!(
        add_is_idempotent_by_id,
        add_dedups_to_canonical_id,
        add_after_delete_of_same_content_inserts,
        id_owned_by_other_account_is_rejected,
        delete_blanks_and_is_idempotent,
        pull_is_account_scoped_and_ordered,
        pull_respects_since_and_limit_cap,
        push_skill_appends_versions_and_flags_supersede,
        delete_skill_appends_tombstone,
        purge_selected_and_all_versions,
        seq_is_global_and_monotonic,
        invalidate_is_final_and_keeps_content,
        invalidate_unknown_deleted_or_foreign_is_a_noop,
        dedup_ignores_invalid_rows,
        add_keeps_valid_at_and_ignores_client_state,
        delete_records_deleted_at,
    );

    /// 0004 on pre-1.1 data: deleted rows get `deleted_at` (the migration
    /// time), live rows stay NULL, `deleted` is gone, and the dedup index
    /// only covers valid, undeleted rows.
    #[tokio::test]
    #[ignore]
    async fn pg_migration_0004_backfills_deleted_at_and_drops_deleted() {
        use sqlx::Executor;
        let _g = PG_LOCK.lock().await;
        let url = std::env::var("KNOWLEDGE_TEST_DATABASE_URL")
            .expect("set KNOWLEDGE_TEST_DATABASE_URL to run the Postgres tests");
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(2)
            .connect(&url)
            .await
            .unwrap();
        for stmt in [
            "DROP TABLE IF EXISTS memories",
            "DROP TABLE IF EXISTS skill_versions",
            "DROP SEQUENCE IF EXISTS knowledge_seq",
        ] {
            sqlx::query(stmt).execute(&pool).await.unwrap();
        }
        pool.execute(include_str!("../migrations/0002_knowledge.sql")).await.unwrap();
        pool.execute(
            "INSERT INTO memories (id, account_id, scope, content, content_hash, source_agent, \
             source_machine, created_at, deleted) VALUES \
             ('m_live', 'acct', 'global', 'x', 'hx', 'cli', 'm', 1, false), \
             ('m_gone', 'acct', 'global', '', '', 'cli', 'm', 1, true)",
        )
        .await
        .unwrap();
        let before = chrono::Utc::now().timestamp();
        pool.execute(include_str!("../migrations/0004_memory_validity.sql")).await.unwrap();
        let rows: Vec<(String, Option<i64>, Option<i64>, Option<i64>, Option<String>)> =
            sqlx::query_as(
                "SELECT id, deleted_at, valid_at, invalid_at, superseded_by FROM memories ORDER BY id",
            )
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(rows[0].0, "m_gone");
        assert!(rows[0].1.unwrap() >= before - 5, "{:?}", rows[0]);
        assert_eq!(rows[1], ("m_live".to_string(), None, None, None, None));
        let has_deleted: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.columns \
             WHERE table_name = 'memories' AND column_name = 'deleted')",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(!has_deleted);
        let pred: String = sqlx::query_scalar(
            "SELECT pg_get_expr(indpred, indrelid) FROM pg_index \
             WHERE indexrelid = 'memories_dedup'::regclass",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(
            pred.contains("deleted_at IS NULL") && pred.contains("invalid_at IS NULL"),
            "{pred}"
        );
        drop(pool);
        // Leave the shared database fully migrated for the other suites.
        fresh_pg().await;
    }

    #[tokio::test]
    async fn in_memory_backend_name_and_health() {
        let s = InMemoryKnowledgeStore::new();
        assert_eq!(s.backend_name(), "memory");
        assert!(s.health_check().await.is_ok());
    }

    #[test]
    fn wire_rows_match_client_json() {
        // Client-shaped JSON with the optional fields omitted.
        let m: MemoryRow = serde_json::from_value(json!({
            "id": "mem_1", "scope": "global", "content": "use pnpm",
            "content_hash": "abc", "confidence": "high", "source_agent": "claude",
            "source_machine": "m1", "created_at": 1700000000
        }))
        .unwrap();
        assert_eq!(
            (m.project.as_str(), m.machine.as_str(), m.deleted, m.seq),
            ("", "", false, 0)
        );
        assert_eq!(
            (m.deleted_at, m.valid_at, m.invalid_at, m.superseded_by.clone()),
            (None, None, None, None)
        );
        let v = serde_json::to_value(&m).unwrap();
        let mut keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                "confidence",
                "content",
                "content_hash",
                "created_at",
                "deleted",
                "deleted_at",
                "id",
                "invalid_at",
                "machine",
                "project",
                "scope",
                "seq",
                "source_agent",
                "source_machine",
                "superseded_by",
                "valid_at"
            ]
        );

        let s: SkillRow = serde_json::from_value(json!({
            "scope": "global", "name": "x", "version": 3,
            "files": {"SKILL.md": "aGk=", "a/b.sh": ""}, "content_hash": "h",
            "source_agent": "claude", "source_machine": "m1", "created_at": 1700000000
        }))
        .unwrap();
        assert_eq!(
            (s.project.as_str(), s.deleted, s.seq, s.version),
            ("", false, 0, 3)
        );
        assert_eq!(s.files, json!({"SKILL.md": "aGk=", "a/b.sh": ""}));
        let v = serde_json::to_value(&s).unwrap();
        let mut keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                "content_hash",
                "created_at",
                "deleted",
                "files",
                "name",
                "project",
                "scope",
                "seq",
                "source_agent",
                "source_machine",
                "version"
            ]
        );
    }
}
