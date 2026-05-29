use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rand::Rng;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

/// One row in a vault. Field names/types must match the atem client
/// (`Atem/src/vault_client.rs::VaultEntry`) exactly.
#[derive(Debug, Clone, Serialize)]
pub struct VaultEntry {
    pub seq: i64,
    pub entry_no: i32,
    pub version: i32,
    pub kind: String,
    pub writer_id: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
}

/// `POST /api/vault` response.
#[derive(Debug, Clone, Serialize)]
pub struct CreatedVault {
    pub vault_id: String,
}

/// `GET /api/vault` list item.
#[derive(Debug, Clone, Serialize)]
pub struct VaultListItem {
    pub vault_id: String,
    pub summary: String,
}

/// Append/override write result.
#[derive(Debug, Clone, Serialize)]
pub struct WriteResult {
    pub entry_no: i32,
    pub version: i32,
    pub seq: i64,
}

/// Per-vault metadata used for authorization checks.
#[derive(Debug, Clone)]
pub struct VaultMeta {
    pub work_session_id: String,
    pub writer_list: Vec<String>,
}

#[derive(Debug)]
pub enum VaultError {
    NotFound,
    Db(String),
}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VaultError::NotFound => write!(f, "vault not found"),
            VaultError::Db(s) => write!(f, "database error: {}", s),
        }
    }
}

/// Generate a short, URL-safe, non-sequential vault id: `v-` + 8 base62 chars.
pub fn generate_vault_id() -> String {
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::thread_rng();
    let suffix: String = (0..8)
        .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
        .collect();
    format!("v-{}", suffix)
}

/// Storage abstraction for vaults. The handlers depend on this trait so tests
/// can use an in-memory implementation and production uses Postgres.
#[async_trait]
pub trait VaultStore: Send + Sync {
    async fn create_vault(
        &self,
        work_session_id: &str,
        created_by: &str,
        summary: &str,
    ) -> Result<String, VaultError>;

    async fn list_readable(
        &self,
        work_session_id: &str,
        client_id: &str,
    ) -> Result<Vec<VaultListItem>, VaultError>;

    async fn read(
        &self,
        vault_id: &str,
        since: Option<i64>,
        history: bool,
    ) -> Result<Vec<VaultEntry>, VaultError>;

    /// Append a new content entry (version = 1, fresh entry_no).
    async fn append(
        &self,
        vault_id: &str,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError>;

    /// Override an existing entry_no with a new version (max version + 1).
    async fn override_entry(
        &self,
        vault_id: &str,
        entry_no: i32,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError>;

    async fn set_summary(&self, vault_id: &str, text: &str) -> Result<(), VaultError>;

    async fn get_meta(&self, vault_id: &str) -> Result<Option<VaultMeta>, VaultError>;

    async fn add_writer(&self, vault_id: &str, client_id: &str) -> Result<(), VaultError>;
}

// ─────────────────────────── In-memory implementation ───────────────────────────

#[derive(Default)]
struct VaultRow {
    summary: String,
    work_session_id: String,
    #[allow(dead_code)]
    created_by: String,
    writer_list: Vec<String>,
    next_entry_no: i32,
    entries: Vec<VaultEntry>,
}

/// In-memory vault store for tests and DB-less runs. Mirrors the existing
/// `RwLock<HashMap<…>>` style used by the other relay stores.
#[derive(Clone)]
pub struct InMemoryVaultStore {
    vaults: Arc<RwLock<HashMap<String, VaultRow>>>,
    seq: Arc<AtomicI64>,
}

impl InMemoryVaultStore {
    pub fn new() -> Self {
        Self {
            vaults: Arc::new(RwLock::new(HashMap::new())),
            seq: Arc::new(AtomicI64::new(0)),
        }
    }

    fn next_seq(&self) -> i64 {
        self.seq.fetch_add(1, Ordering::SeqCst) + 1
    }
}

impl Default for InMemoryVaultStore {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl VaultStore for InMemoryVaultStore {
    async fn create_vault(
        &self,
        work_session_id: &str,
        created_by: &str,
        summary: &str,
    ) -> Result<String, VaultError> {
        let vault_id = generate_vault_id();
        let mut vaults = self.vaults.write().await;
        vaults.insert(
            vault_id.clone(),
            VaultRow {
                summary: summary.to_string(),
                work_session_id: work_session_id.to_string(),
                created_by: created_by.to_string(),
                writer_list: Vec::new(),
                next_entry_no: 1,
                entries: Vec::new(),
            },
        );
        Ok(vault_id)
    }

    async fn list_readable(
        &self,
        work_session_id: &str,
        client_id: &str,
    ) -> Result<Vec<VaultListItem>, VaultError> {
        let vaults = self.vaults.read().await;
        let mut out: Vec<(i64, VaultListItem)> = vaults
            .iter()
            .filter(|(_, v)| {
                v.work_session_id == work_session_id
                    || v.writer_list.iter().any(|w| w == client_id)
            })
            .map(|(id, v)| {
                let first_seq = v.entries.first().map(|e| e.seq).unwrap_or(i64::MAX);
                (
                    first_seq,
                    VaultListItem {
                        vault_id: id.clone(),
                        summary: v.summary.clone(),
                    },
                )
            })
            .collect();
        out.sort_by_key(|(s, _)| *s);
        Ok(out.into_iter().map(|(_, item)| item).collect())
    }

    async fn read(
        &self,
        vault_id: &str,
        since: Option<i64>,
        history: bool,
    ) -> Result<Vec<VaultEntry>, VaultError> {
        let vaults = self.vaults.read().await;
        let row = vaults.get(vault_id).ok_or(VaultError::NotFound)?;
        let since = since.unwrap_or(0);

        if history {
            // Every row, ordered by seq, filtered by since.
            let mut entries: Vec<VaultEntry> = row
                .entries
                .iter()
                .filter(|e| e.seq > since)
                .cloned()
                .collect();
            entries.sort_by_key(|e| e.seq);
            Ok(entries)
        } else {
            // Current view: highest version per entry_no, ordered by entry_no.
            let mut latest: HashMap<i32, VaultEntry> = HashMap::new();
            for e in row.entries.iter().filter(|e| e.seq > since) {
                match latest.get(&e.entry_no) {
                    Some(existing) if existing.version >= e.version => {}
                    _ => {
                        latest.insert(e.entry_no, e.clone());
                    }
                }
            }
            let mut entries: Vec<VaultEntry> = latest.into_values().collect();
            entries.sort_by_key(|e| e.entry_no);
            Ok(entries)
        }
    }

    async fn append(
        &self,
        vault_id: &str,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError> {
        let seq = self.next_seq();
        let mut vaults = self.vaults.write().await;
        let row = vaults.get_mut(vault_id).ok_or(VaultError::NotFound)?;
        let entry_no = row.next_entry_no;
        row.next_entry_no += 1;
        let entry = VaultEntry {
            seq,
            entry_no,
            version: 1,
            kind: "content".to_string(),
            writer_id: writer_id.to_string(),
            content: text.to_string(),
            created_at: Utc::now(),
        };
        row.entries.push(entry);
        Ok(WriteResult {
            entry_no,
            version: 1,
            seq,
        })
    }

    async fn override_entry(
        &self,
        vault_id: &str,
        entry_no: i32,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError> {
        let seq = self.next_seq();
        let mut vaults = self.vaults.write().await;
        let row = vaults.get_mut(vault_id).ok_or(VaultError::NotFound)?;
        let max_version = row
            .entries
            .iter()
            .filter(|e| e.entry_no == entry_no)
            .map(|e| e.version)
            .max()
            .unwrap_or(0);
        let version = max_version + 1;
        let entry = VaultEntry {
            seq,
            entry_no,
            version,
            kind: "content".to_string(),
            writer_id: writer_id.to_string(),
            content: text.to_string(),
            created_at: Utc::now(),
        };
        row.entries.push(entry);
        Ok(WriteResult {
            entry_no,
            version,
            seq,
        })
    }

    async fn set_summary(&self, vault_id: &str, text: &str) -> Result<(), VaultError> {
        let mut vaults = self.vaults.write().await;
        let row = vaults.get_mut(vault_id).ok_or(VaultError::NotFound)?;
        row.summary = text.to_string();
        Ok(())
    }

    async fn get_meta(&self, vault_id: &str) -> Result<Option<VaultMeta>, VaultError> {
        let vaults = self.vaults.read().await;
        Ok(vaults.get(vault_id).map(|v| VaultMeta {
            work_session_id: v.work_session_id.clone(),
            writer_list: v.writer_list.clone(),
        }))
    }

    async fn add_writer(&self, vault_id: &str, client_id: &str) -> Result<(), VaultError> {
        let mut vaults = self.vaults.write().await;
        let row = vaults.get_mut(vault_id).ok_or(VaultError::NotFound)?;
        if !row.writer_list.iter().any(|w| w == client_id) {
            row.writer_list.push(client_id.to_string());
        }
        Ok(())
    }
}

// ─────────────────────────── Postgres implementation ───────────────────────────

/// Postgres-backed vault store. Uses runtime-checked queries (no compile-time
/// DB needed). Append/override run inside a transaction so concurrent writers
/// can't collide on (vault_id, entry_no, version).
#[derive(Clone)]
pub struct PgVaultStore {
    pool: sqlx::PgPool,
}

impl PgVaultStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

fn db_err(e: sqlx::Error) -> VaultError {
    VaultError::Db(e.to_string())
}

#[async_trait]
impl VaultStore for PgVaultStore {
    async fn create_vault(
        &self,
        work_session_id: &str,
        created_by: &str,
        summary: &str,
    ) -> Result<String, VaultError> {
        let vault_id = generate_vault_id();
        sqlx::query(
            "INSERT INTO vaults (vault_id, summary, work_session_id, created_by) \
             VALUES ($1, $2, $3, $4)",
        )
        .bind(&vault_id)
        .bind(summary)
        .bind(work_session_id)
        .bind(created_by)
        .execute(&self.pool)
        .await
        .map_err(db_err)?;
        Ok(vault_id)
    }

    async fn list_readable(
        &self,
        work_session_id: &str,
        client_id: &str,
    ) -> Result<Vec<VaultListItem>, VaultError> {
        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT vault_id, summary FROM vaults \
             WHERE work_session_id = $1 OR $2 = ANY(writer_list) \
             ORDER BY created_at ASC",
        )
        .bind(work_session_id)
        .bind(client_id)
        .fetch_all(&self.pool)
        .await
        .map_err(db_err)?;
        Ok(rows
            .into_iter()
            .map(|(vault_id, summary)| VaultListItem { vault_id, summary })
            .collect())
    }

    async fn read(
        &self,
        vault_id: &str,
        since: Option<i64>,
        history: bool,
    ) -> Result<Vec<VaultEntry>, VaultError> {
        let since = since.unwrap_or(0);
        let sql = if history {
            "SELECT seq, entry_no, version, kind, writer_id, content, created_at \
             FROM vault_entries WHERE vault_id = $1 AND seq > $2 ORDER BY seq ASC"
        } else {
            "SELECT DISTINCT ON (entry_no) seq, entry_no, version, kind, writer_id, content, created_at \
             FROM vault_entries WHERE vault_id = $1 AND seq > $2 \
             ORDER BY entry_no ASC, version DESC"
        };
        let rows: Vec<VaultEntryRow> = sqlx::query_as(sql)
            .bind(vault_id)
            .bind(since)
            .fetch_all(&self.pool)
            .await
            .map_err(db_err)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn append(
        &self,
        vault_id: &str,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        // Allocate entry_no atomically.
        let entry_no: i32 = sqlx::query_scalar(
            "UPDATE vaults SET next_entry_no = next_entry_no + 1 \
             WHERE vault_id = $1 RETURNING next_entry_no - 1",
        )
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?
        .ok_or(VaultError::NotFound)?;

        let seq: i64 = sqlx::query_scalar(
            "INSERT INTO vault_entries (vault_id, entry_no, version, kind, writer_id, content) \
             VALUES ($1, $2, 1, 'content', $3, $4) RETURNING seq",
        )
        .bind(vault_id)
        .bind(entry_no)
        .bind(writer_id)
        .bind(text)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;

        tx.commit().await.map_err(db_err)?;
        Ok(WriteResult {
            entry_no,
            version: 1,
            seq,
        })
    }

    async fn override_entry(
        &self,
        vault_id: &str,
        entry_no: i32,
        writer_id: &str,
        text: &str,
    ) -> Result<WriteResult, VaultError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let max_version: Option<i32> = sqlx::query_scalar(
            "SELECT MAX(version) FROM vault_entries WHERE vault_id = $1 AND entry_no = $2",
        )
        .bind(vault_id)
        .bind(entry_no)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;
        let version = max_version.unwrap_or(0) + 1;

        let seq: i64 = sqlx::query_scalar(
            "INSERT INTO vault_entries (vault_id, entry_no, version, kind, writer_id, content) \
             VALUES ($1, $2, $3, 'content', $4, $5) RETURNING seq",
        )
        .bind(vault_id)
        .bind(entry_no)
        .bind(version)
        .bind(writer_id)
        .bind(text)
        .fetch_one(&mut *tx)
        .await
        .map_err(db_err)?;

        tx.commit().await.map_err(db_err)?;
        Ok(WriteResult {
            entry_no,
            version,
            seq,
        })
    }

    async fn set_summary(&self, vault_id: &str, text: &str) -> Result<(), VaultError> {
        let res = sqlx::query("UPDATE vaults SET summary = $1 WHERE vault_id = $2")
            .bind(text)
            .bind(vault_id)
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        if res.rows_affected() == 0 {
            return Err(VaultError::NotFound);
        }
        Ok(())
    }

    async fn get_meta(&self, vault_id: &str) -> Result<Option<VaultMeta>, VaultError> {
        let row: Option<(String, Vec<String>)> = sqlx::query_as(
            "SELECT work_session_id, writer_list FROM vaults WHERE vault_id = $1",
        )
        .bind(vault_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_err)?;
        Ok(row.map(|(work_session_id, writer_list)| VaultMeta {
            work_session_id,
            writer_list,
        }))
    }

    async fn add_writer(&self, vault_id: &str, client_id: &str) -> Result<(), VaultError> {
        // array_append only if not already present (dedup).
        sqlx::query(
            "UPDATE vaults SET writer_list = array_append(writer_list, $2) \
             WHERE vault_id = $1 AND NOT ($2 = ANY(writer_list))",
        )
        .bind(vault_id)
        .bind(client_id)
        .execute(&self.pool)
        .await
        .map_err(db_err)?;
        Ok(())
    }
}

/// Row shape for sqlx FromRow mapping of vault_entries.
#[derive(sqlx::FromRow)]
struct VaultEntryRow {
    seq: i64,
    entry_no: i32,
    version: i32,
    kind: String,
    writer_id: String,
    content: String,
    created_at: DateTime<Utc>,
}

impl From<VaultEntryRow> for VaultEntry {
    fn from(r: VaultEntryRow) -> Self {
        VaultEntry {
            seq: r.seq,
            entry_no: r.entry_no,
            version: r.version,
            kind: r.kind,
            writer_id: r.writer_id,
            content: r.content,
            created_at: r.created_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn append_then_read_current_and_history() {
        let store = InMemoryVaultStore::new();
        let id = store.create_vault("ws-1", "client-a", "auth refactor").await.unwrap();

        let w1 = store.append(&id, "client-a", "decided: JWT in cookie").await.unwrap();
        assert_eq!(w1.entry_no, 1);
        assert_eq!(w1.version, 1);

        // Override entry 1 → version 2.
        let w2 = store.override_entry(&id, 1, "client-a", "JWT, 15m exp").await.unwrap();
        assert_eq!(w2.entry_no, 1);
        assert_eq!(w2.version, 2);

        // Current view: only v2.
        let current = store.read(&id, None, false).await.unwrap();
        assert_eq!(current.len(), 1);
        assert_eq!(current[0].version, 2);
        assert_eq!(current[0].content, "JWT, 15m exp");

        // History: both v1 and v2.
        let history = store.read(&id, None, true).await.unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].version, 1);
        assert_eq!(history[1].version, 2);
    }

    #[tokio::test]
    async fn since_filters_by_seq() {
        let store = InMemoryVaultStore::new();
        let id = store.create_vault("ws-1", "a", "").await.unwrap();
        let w1 = store.append(&id, "a", "first").await.unwrap();
        let _w2 = store.append(&id, "a", "second").await.unwrap();

        let after_first = store.read(&id, Some(w1.seq), true).await.unwrap();
        assert_eq!(after_first.len(), 1);
        assert_eq!(after_first[0].content, "second");
    }

    #[tokio::test]
    async fn writer_list_dedups() {
        let store = InMemoryVaultStore::new();
        let id = store.create_vault("ws-1", "a", "").await.unwrap();
        store.add_writer(&id, "client-x").await.unwrap();
        store.add_writer(&id, "client-x").await.unwrap();
        let meta = store.get_meta(&id).await.unwrap().unwrap();
        assert_eq!(meta.writer_list, vec!["client-x".to_string()]);
        assert_eq!(meta.work_session_id, "ws-1");
    }

    #[tokio::test]
    async fn list_readable_in_session_and_past_writer() {
        let store = InMemoryVaultStore::new();
        let id = store.create_vault("ws-1", "a", "vault one").await.unwrap();
        store.add_writer(&id, "past-writer").await.unwrap();

        // In-session caller sees it.
        let in_session = store.list_readable("ws-1", "anyone").await.unwrap();
        assert_eq!(in_session.len(), 1);

        // Out-of-session past writer sees it.
        let past = store.list_readable("ws-other", "past-writer").await.unwrap();
        assert_eq!(past.len(), 1);

        // Out-of-session stranger does not.
        let stranger = store.list_readable("ws-other", "stranger").await.unwrap();
        assert_eq!(stranger.len(), 0);
    }
}
