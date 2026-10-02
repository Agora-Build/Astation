//! Routes for `/api/memory` and `/api/skills` (Atem Memory knowledge sync).
//!
//! Mirrors `vault_routes.rs`: session auth via `resolve_caller`, the account is
//! `Caller.work_session_id` (the paired astation_id). Batch ops are validated
//! (reserved tokens, credential scanning, NUL bytes) here — the store never
//! inspects memory content or skill file bytes.
//!
//! Batch handling, in order:
//! 1. Authenticate (`resolve_caller`) from the headers + query. The body is
//!    not read until the caller is known, so an unauthenticated client can't
//!    make the relay buffer a large body.
//! 2. Read the body with a hard byte cap (413 over it), then deserialize into
//!    typed ops. A malformed body or an unknown `op` fails the whole batch with
//!    400 — the atem client never sends an unknown op, so one means a broken
//!    client, not something to refuse per op (atem acks per-op refusals).
//! 3. Cap the op count (413 `{"error":"too many ops"}` over it).
//! 4. Apply each op. Input problems are per-op `{ok:false,error}` refusals
//!    (permanent: atem acks them). A backing-store failure stops the batch and
//!    returns 503 `{"error":"temporarily unavailable"}` for the whole request
//!    (transient: atem keeps every op queued and retries — add is idempotent
//!    by id, delete/invalidate/purge are idempotent, a retried skill push appends a
//!    harmless duplicate version). An invalidate's `superseded_by` is only a
//!    hint: the relay doesn't check that it exists or belongs to the account.

use std::collections::HashMap;

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::encryption::{valid_envelope, valid_hash, EncryptionState};
use crate::knowledge_secrets::{check_bytes, contains_reserved, find_secrets};
use crate::knowledge_store::{KnowledgeError, MemoryRow, SkillRow};
use crate::vault_routes::{err, resolve_caller};
use crate::AppState;

type ErrResp = (StatusCode, Json<Value>);

/// Byte limit on a `/api/memory/batch` body (also the route's `DefaultBodyLimit`).
pub(crate) const MEMORY_BATCH_BODY_LIMIT: usize = 2 * 1024 * 1024;
/// Byte limit on a `/api/skills/batch` body (also the route's `DefaultBodyLimit`).
pub(crate) const SKILLS_BATCH_BODY_LIMIT: usize = 16 * 1024 * 1024;
/// Most ops in one memory batch (atem sends at most 50).
pub(crate) const MEMORY_BATCH_MAX_OPS: usize = 64;
/// Most ops in one skills batch (atem sends at most 8).
pub(crate) const SKILLS_BATCH_MAX_OPS: usize = 16;

#[derive(Debug, Deserialize)]
pub(crate) struct AuthQuery {
    /// atem instance_id — the authorization principal (`?id=`).
    id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct PullQuery {
    id: Option<String>,
    since: Option<i64>,
    limit: Option<i64>,
}

fn op_err(msg: impl Into<String>) -> Value {
    json!({ "ok": false, "error": msg.into() })
}

/// The whole request fails with 503: the store is (probably transiently)
/// unavailable. The detail is logged, never sent to the client.
fn unavailable(e: KnowledgeError) -> ErrResp {
    tracing::error!("knowledge store error: {}", e);
    err(StatusCode::SERVICE_UNAVAILABLE, "temporarily unavailable")
}

/// A store call's result for one op: success → `ok(t)`; a domain refusal
/// (`IdConflict`) → a per-op refusal; a `Db` error → abort the batch (503).
fn store_result<T>(r: Result<T, KnowledgeError>, ok: impl FnOnce(T) -> Value) -> Result<Value, ErrResp> {
    match r {
        Ok(t) => Ok(ok(t)),
        Err(e @ (KnowledgeError::IdConflict | KnowledgeError::EncryptionConflict)) => {
            Ok(op_err(e.to_string()))
        }
        Err(e @ KnowledgeError::Db(_)) => Err(unavailable(e)),
    }
}

// ─────────────────────────── batch body ───────────────────────────

#[derive(Debug, Deserialize)]
struct Batch<T> {
    ops: Vec<T>,
}

/// True when the body-read error is the byte cap (http-body-util's
/// `LengthLimitError`, which axum wraps; matched by its message since that
/// crate isn't a direct dependency).
fn is_length_limit(e: &axum::Error) -> bool {
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(x) = cur {
        if x.to_string() == "length limit exceeded" {
            return true;
        }
        cur = x.source();
    }
    false
}

/// Read and parse a batch body (only ever called after `resolve_caller`).
/// Over `limit` bytes → 413; malformed JSON or an unknown op → 400; more
/// than `max_ops` ops → 413 `too many ops`.
async fn read_batch<T: DeserializeOwned>(body: Body, limit: usize, max_ops: usize) -> Result<Vec<T>, ErrResp> {
    let bytes = axum::body::to_bytes(body, limit).await.map_err(|e| {
        if is_length_limit(&e) {
            err(StatusCode::PAYLOAD_TOO_LARGE, "request body too large")
        } else {
            err(StatusCode::BAD_REQUEST, "could not read request body")
        }
    })?;
    let batch: Batch<T> = serde_json::from_slice(&bytes)
        .map_err(|_| err(StatusCode::BAD_REQUEST, "invalid batch"))?;
    if batch.ops.len() > max_ops {
        return Err(err(StatusCode::PAYLOAD_TOO_LARGE, "too many ops"));
    }
    Ok(batch.ops)
}

/// Postgres TEXT and JSONB can't hold `\u0000`; such input is refused per op
/// up front so a permanent input problem never surfaces as a (retried) 503.
fn has_nul(fields: &[&str]) -> bool {
    fields.iter().any(|f| f.contains('\0'))
}

fn memory_has_nul(m: &MemoryRow) -> bool {
    has_nul(&[
        &m.id,
        &m.scope,
        &m.project,
        &m.machine,
        &m.content,
        &m.content_hash,
        &m.confidence,
        &m.source_agent,
        &m.source_machine,
    ])
}

fn skill_has_nul(s: &SkillRow) -> bool {
    has_nul(&[
        &s.scope,
        &s.project,
        &s.name,
        &s.content_hash,
        &s.source_agent,
        &s.source_machine,
    ]) || s
        .files
        .as_object()
        .is_some_and(|o| o.keys().any(|k| k.contains('\0')))
}

// ─────────────────────────── base64 (standard alphabet, padded) ───────────────────────────

/// Decode standard-alphabet base64 (RFC 4648 §4, with `=` padding). Rejects
/// invalid characters, a length that isn't a multiple of 4, and padding that
/// isn't confined to the final group. No base64 crate exists in this
/// workspace; this is intentionally small and self-contained.
fn base64_decode(s: &str) -> Result<Vec<u8>, ()> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.len() % 4 != 0 {
        return Err(());
    }

    let n = bytes.len();
    let mut out = Vec::with_capacity(n / 4 * 3);
    for (i, chunk) in bytes.chunks_exact(4).enumerate() {
        let is_last = (i + 1) * 4 == n;
        let pad = chunk.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && !is_last) {
            return Err(());
        }
        let data = &chunk[..4 - pad];
        if data.iter().any(|&c| c == b'=') {
            return Err(());
        }
        let mut v = [0u8; 4];
        for (j, &c) in data.iter().enumerate() {
            v[j] = val(c).ok_or(())?;
        }
        let b0 = (v[0] << 2) | (v[1] >> 4);
        let b1 = (v[1] << 4) | (v[2] >> 2);
        let b2 = (v[2] << 6) | v[3];
        match pad {
            0 => out.extend_from_slice(&[b0, b1, b2]),
            // 3 significant chars; the low 2 bits of the 3rd char don't
            // contribute to any output byte and must be zero (canonical
            // encoding) — matches atem's base64 0.21 STANDARD decoder,
            // which rejects non-zero trailing bits as InvalidLastSymbol.
            1 => {
                if v[2] & 0x03 != 0 {
                    return Err(());
                }
                out.extend_from_slice(&[b0, b1]);
            }
            // 2 significant chars; the low 4 bits of the 2nd char don't
            // contribute to any output byte and must be zero.
            2 => {
                if v[1] & 0x0f != 0 {
                    return Err(());
                }
                out.push(b0);
            }
            _ => unreachable!(),
        }
    }
    Ok(out)
}

// ─────────────────────────── scope validation ───────────────────────────

/// atem's `Memory.scope` deserializes into an enum accepting only these
/// three values; anything else fails client-side and (worse) permanently
/// blocks pull sync for the account once such a row lands in the page. So
/// the relay refuses it up front instead of ever writing it.
fn is_valid_memory_scope(s: &str) -> bool {
    matches!(s, "global" | "project" | "machine")
}

/// atem's `Skill.scope` enum accepts only these two values (skills have no
/// per-machine scope).
fn is_valid_skill_scope(s: &str) -> bool {
    matches!(s, "global" | "project")
}

// ─────────────────────────── memory batch ───────────────────────────

/// One `/api/memory/batch` op. Unknown `op` values fail deserialization (400).
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub(crate) enum MemoryOp {
    Add { memory: MemoryRow },
    Delete { id: String },
    /// Final and idempotent; never changes content.
    Invalidate {
        id: String,
        invalid_at: i64,
        #[serde(default)]
        superseded_by: Option<String>,
    },
    Rewrite {
        id: String,
        #[serde(default)]
        project: String,
        content: String,
        content_hash: String,
    },
}

fn encrypted_prefix(value: &str, hash: bool) -> bool {
    value.starts_with(if hash { "h1." } else { "e1." })
}

fn allowed_field(value: &str, encryption: &EncryptionState, hash: bool) -> bool {
    if value.is_empty() {
        return true;
    }
    let valid = encryption.kid.as_deref().is_some_and(|kid| {
        if hash {
            valid_hash(value, kid)
        } else {
            valid_envelope(value, kid)
        }
    });
    match encryption.mode.as_str() {
        "off" => !encrypted_prefix(value, hash),
        "enabling" | "on" => valid,
        "disabling" => valid || !encrypted_prefix(value, hash),
        _ => false,
    }
}

fn migration_field(value: &str, encryption: &EncryptionState, hash: bool) -> bool {
    match encryption.mode.as_str() {
        "enabling" => encryption.kid.as_deref().is_some_and(|kid| {
            if hash {
                value.is_empty() || valid_hash(value, kid)
            } else {
                value.is_empty() || valid_envelope(value, kid)
            }
        }),
        "disabling" => !encrypted_prefix(value, hash),
        _ => false,
    }
}

async fn encryption_state(state: &AppState, account: &str) -> Result<EncryptionState, ErrResp> {
    state.accounts.encryption_state(account).await.map_err(|error| {
        tracing::error!("account encryption state error: {}", error);
        err(StatusCode::SERVICE_UNAVAILABLE, "temporarily unavailable")
    })
}

/// `canon` maps an id the client sent to the canonical id an earlier `add`
/// in the same batch was deduplicated onto, so a later `delete`/`invalidate`
/// in the batch (as `id` or `superseded_by`) names a row that exists.
async fn apply_memory_op(
    state: &AppState,
    account: &str,
    encryption: &EncryptionState,
    op: MemoryOp,
    canon: &mut HashMap<String, String>,
) -> Result<Value, ErrResp> {
    let mapped = |canon: &HashMap<String, String>, id: &str| canon.get(id).cloned().unwrap_or_else(|| id.to_string());
    match op {
        MemoryOp::Add { memory } => {
            if !is_valid_memory_scope(&memory.scope)
                || memory_has_nul(&memory)
                || memory.valid_at.is_some_and(|v| v <= 0)
            {
                return Ok(op_err("invalid memory"));
            }
            if !allowed_field(&memory.project, encryption, true)
                || !allowed_field(&memory.content, encryption, false)
                || !allowed_field(&memory.content_hash, encryption, true)
            {
                return Ok(op_err("memory does not match the account encryption mode"));
            }
            let encrypted_content = encryption
                .kid
                .as_deref()
                .is_some_and(|kid| valid_envelope(&memory.content, kid));
            if !encrypted_content && contains_reserved(&memory.content) {
                return Ok(op_err("reserved token"));
            }
            if !encrypted_content {
                if let Some(f) = find_secrets(&memory.content).first() {
                    return Ok(op_err(format!("possible credential: {}", f.kind)));
                }
            }
            let r = state.knowledge.add_memory(account, memory).await;
            if let Ok(o) = &r {
                if let Some(cid) = &o.canonical_id {
                    canon.insert(o.id.clone(), cid.clone());
                }
            }
            store_result(r, |o| {
                let mut v = json!({ "ok": true, "id": o.id, "seq": o.seq });
                if let Some(cid) = o.canonical_id {
                    v["canonical_id"] = json!(cid);
                }
                v
            })
        }
        MemoryOp::Delete { id } => {
            if has_nul(&[&id]) {
                return Ok(op_err("invalid memory"));
            }
            let target = mapped(canon, &id);
            store_result(state.knowledge.delete_memory(account, &target).await, |seq| {
                json!({ "ok": true, "id": id, "seq": seq })
            })
        }
        MemoryOp::Invalidate { id, invalid_at, superseded_by } => {
            if invalid_at <= 0
                || has_nul(&[&id])
                || superseded_by.as_deref().is_some_and(|s| s.contains('\0'))
            {
                return Ok(op_err("invalid memory"));
            }
            let target = mapped(canon, &id);
            // `superseded_by` is a hint: not checked for existence or ownership.
            let successor = superseded_by.map(|s| mapped(canon, &s));
            store_result(
                state
                    .knowledge
                    .invalidate_memory(account, &target, invalid_at, successor.as_deref())
                    .await,
                |seq| json!({ "ok": true, "id": id, "seq": seq }),
            )
        }
        MemoryOp::Rewrite { id, project, content, content_hash } => {
            if has_nul(&[&id, &project, &content, &content_hash])
                || !migration_field(&project, encryption, true)
                || !migration_field(&content, encryption, false)
                || !migration_field(&content_hash, encryption, true)
            {
                return Ok(op_err("invalid encryption migration"));
            }
            let encrypted_content = encryption
                .kid
                .as_deref()
                .is_some_and(|kid| valid_envelope(&content, kid));
            if !encrypted_content && contains_reserved(&content) {
                return Ok(op_err("reserved token"));
            }
            if !encrypted_content {
                if let Some(finding) = find_secrets(&content).first() {
                    return Ok(op_err(format!("possible credential: {}", finding.kind)));
                }
            }
            store_result(
                state
                    .knowledge
                    .rewrite_memory_fields(account, &id, &project, &content, &content_hash)
                    .await,
                |seq| json!({ "ok": seq != 0, "id": id, "seq": seq }),
            )
        }
    }
}

/// POST /api/memory/batch {ops:[…]} -> {results:[…]}
pub async fn memory_batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuthQuery>,
    body: Body,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let ops: Vec<MemoryOp> = read_batch(body, MEMORY_BATCH_BODY_LIMIT, MEMORY_BATCH_MAX_OPS).await?;
    let encryption = encryption_state(&state, &caller.work_session_id).await?;
    let mut results = Vec::with_capacity(ops.len());
    let mut canon = HashMap::new();
    for op in ops {
        results.push(
            apply_memory_op(&state, &caller.work_session_id, &encryption, op, &mut canon).await?,
        );
    }
    Ok(Json(json!({ "results": results })))
}

/// GET /api/memory [?since&limit] -> {memories:[…]}
pub async fn memory_pull_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let since = query.since.unwrap_or(0);
    let limit = query.limit.unwrap_or(200);
    let rows = state
        .knowledge
        .pull_memories(&caller.work_session_id, since, limit)
        .await
        .map_err(unavailable)?;
    Ok(Json(json!({ "memories": rows })))
}

// ─────────────────────────── skills batch ───────────────────────────

/// Decode every file in a skill's `files` object; on success, run the secret
/// checks against the decoded bytes. Returns the first violation, if any.
fn check_skill_files(files: &Value) -> Result<(), Value> {
    let obj = match files.as_object() {
        Some(o) => o,
        None => return Err(op_err("invalid base64")),
    };
    let mut decoded: Vec<(String, Vec<u8>)> = Vec::with_capacity(obj.len());
    for (path, v) in obj {
        let s = match v.as_str() {
            Some(s) => s,
            None => return Err(op_err("invalid base64")),
        };
        match base64_decode(s) {
            Ok(bytes) => decoded.push((path.clone(), bytes)),
            Err(()) => return Err(op_err("invalid base64")),
        }
    }
    for (path, bytes) in &decoded {
        if let Some(f) = check_bytes(bytes).first() {
            return Err(op_err(format!("possible credential: {}: {}", path, f.kind)));
        }
        if let Ok(text) = std::str::from_utf8(bytes) {
            if contains_reserved(text) {
                return Err(op_err(format!(
                    "possible credential: {}: reserved token",
                    path
                )));
            }
        }
    }
    Ok(())
}

/// One `/api/skills/batch` op. Unknown `op` values fail deserialization (400).
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub(crate) enum SkillOp {
    Push {
        skill: SkillRow,
        base_version: i64,
    },
    Delete {
        scope: String,
        #[serde(default)]
        project: String,
        name: String,
    },
    Purge {
        scope: String,
        #[serde(default)]
        project: String,
        name: String,
        #[serde(default)]
        versions: Option<Vec<i64>>,
    },
    Rewrite {
        scope: String,
        #[serde(default)]
        old_project: String,
        name: String,
        version: i64,
        #[serde(default)]
        project: String,
        files: Value,
        content_hash: String,
    },
}

fn skill_files_match_mode(files: &Value, encryption: &EncryptionState, migration: bool) -> bool {
    let Some(files) = files.as_object() else {
        return false;
    };
    files.iter().all(|(path, encoded)| {
        let Some(encoded) = encoded.as_str() else {
            return false;
        };
        let Ok(bytes) = base64_decode(encoded) else {
            return false;
        };
        let Ok(content) = std::str::from_utf8(&bytes) else {
            return matches!(encryption.mode.as_str(), "off" | "disabling");
        };
        if migration {
            migration_field(path, encryption, false)
                && migration_field(content, encryption, false)
        } else {
            allowed_field(path, encryption, false)
                && allowed_field(content, encryption, false)
        }
    })
}

fn skill_files_have_valid_base64(files: &Value) -> bool {
    files.as_object().is_some_and(|files| {
        files.values().all(|encoded| {
            encoded
                .as_str()
                .is_some_and(|encoded| base64_decode(encoded).is_ok())
        })
    })
}

fn skill_files_are_encrypted(files: &Value, kid: &str) -> bool {
    let Some(files) = files.as_object() else {
        return false;
    };
    files.iter().all(|(path, encoded)| {
        let Some(encoded) = encoded.as_str() else {
            return false;
        };
        let Ok(bytes) = base64_decode(encoded) else {
            return false;
        };
        let Ok(content) = std::str::from_utf8(&bytes) else {
            return false;
        };
        valid_envelope(path, kid) && valid_envelope(content, kid)
    })
}

async fn apply_skill_op(
    state: &AppState,
    account: &str,
    encryption: &EncryptionState,
    op: SkillOp,
) -> Result<Value, ErrResp> {
    match op {
        SkillOp::Push { skill, base_version } => {
            if !is_valid_skill_scope(&skill.scope) || skill_has_nul(&skill) {
                return Ok(op_err("invalid skill"));
            }
            if !skill_files_have_valid_base64(&skill.files) {
                return Ok(op_err("invalid base64"));
            }
            if !allowed_field(&skill.project, encryption, true)
                || !allowed_field(&skill.content_hash, encryption, true)
                || !skill_files_match_mode(&skill.files, encryption, false)
            {
                return Ok(op_err("skill does not match the account encryption mode"));
            }
            let files_encrypted = encryption.kid.as_deref().is_some_and(|kid| {
                skill_files_are_encrypted(&skill.files, kid)
            });
            if !files_encrypted {
                if let Err(bad) = check_skill_files(&skill.files) {
                    return Ok(bad);
                }
            }
            store_result(state.knowledge.push_skill(account, skill, base_version).await, |o| {
                json!({
                    "ok": true,
                    "version": o.version,
                    "seq": o.seq,
                    "superseded_concurrent": o.superseded_concurrent,
                })
            })
        }
        SkillOp::Delete { scope, project, name } => {
            if !is_valid_skill_scope(&scope) || has_nul(&[&project, &name]) {
                return Ok(op_err("invalid skill"));
            }
            store_result(
                state.knowledge.delete_skill(account, &scope, &project, &name).await,
                |o| json!({ "ok": true, "version": o.version, "seq": o.seq }),
            )
        }
        SkillOp::Purge { scope, project, name, versions } => {
            if !is_valid_skill_scope(&scope) || has_nul(&[&project, &name]) {
                return Ok(op_err("invalid skill"));
            }
            store_result(
                state
                    .knowledge
                    .purge_skill(account, &scope, &project, &name, versions)
                    .await,
                |_| json!({ "ok": true }),
            )
        }
        SkillOp::Rewrite {
            scope,
            old_project,
            name,
            version,
            project,
            files,
            content_hash,
        } => {
            if !is_valid_skill_scope(&scope)
                || has_nul(&[&old_project, &name, &project, &content_hash])
                || !migration_field(&project, encryption, true)
                || !migration_field(&content_hash, encryption, true)
                || !skill_files_match_mode(&files, encryption, true)
            {
                return Ok(op_err("invalid encryption migration"));
            }
            let files_encrypted = encryption
                .kid
                .as_deref()
                .is_some_and(|kid| skill_files_are_encrypted(&files, kid));
            if !files_encrypted {
                if let Err(bad) = check_skill_files(&files) {
                    return Ok(bad);
                }
            }
            store_result(
                state
                    .knowledge
                    .rewrite_skill_fields(
                        account,
                        &scope,
                        &old_project,
                        &name,
                        version,
                        &project,
                        files,
                        &content_hash,
                    )
                    .await,
                |seq| json!({ "ok": seq != 0, "version": version, "seq": seq }),
            )
        }
    }
}

/// POST /api/skills/batch {ops:[…]} -> {results:[…]}
pub async fn skills_batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuthQuery>,
    body: Body,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let ops: Vec<SkillOp> = read_batch(body, SKILLS_BATCH_BODY_LIMIT, SKILLS_BATCH_MAX_OPS).await?;
    let encryption = encryption_state(&state, &caller.work_session_id).await?;
    let mut results = Vec::with_capacity(ops.len());
    for op in ops {
        results.push(apply_skill_op(&state, &caller.work_session_id, &encryption, op).await?);
    }
    Ok(Json(json!({ "results": results })))
}

/// GET /api/skills [?since&limit] -> {skills:[…]}
pub async fn skills_pull_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let since = query.since.unwrap_or(0);
    let limit = query.limit.unwrap_or(200);
    let rows = state
        .knowledge
        .pull_skills(&caller.work_session_id, since, limit)
        .await
        .map_err(unavailable)?;
    Ok(Json(json!({ "skills": rows })))
}

// ─────────────────────────── skill history ───────────────────────────

#[derive(Debug, Deserialize)]
pub(crate) struct SkillKeyQuery {
    id: Option<String>,
    scope: Option<String>,
    #[serde(default)]
    project: String,
    name: Option<String>,
    version: Option<i64>,
}

/// `(scope, project, name)` from the query, or 400 `invalid skill`.
fn skill_key(q: &SkillKeyQuery) -> Result<(String, String, String), ErrResp> {
    let scope = q.scope.clone().unwrap_or_default();
    let name = q.name.clone().unwrap_or_default();
    if !is_valid_skill_scope(&scope) || name.is_empty() || has_nul(&[&q.project, &name]) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid skill"));
    }
    Ok((scope, q.project.clone(), name))
}

/// GET /api/skills/versions ?scope&project&name -> {versions:[…]} (newest first, no files)
pub async fn skill_versions_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SkillKeyQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let (scope, project, name) = skill_key(&query)?;
    let versions = state
        .knowledge
        .skill_versions(&caller.work_session_id, &scope, &project, &name)
        .await
        .map_err(unavailable)?;
    Ok(Json(json!({ "versions": versions })))
}

/// GET /api/skills/version ?scope&project&name&version -> {skill} | 404 | 410 (purged)
pub async fn skill_version_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SkillKeyQuery>,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let (scope, project, name) = skill_key(&query)?;
    let version = query
        .version
        .ok_or_else(|| err(StatusCode::BAD_REQUEST, "missing version"))?;
    match state
        .knowledge
        .skill_version(&caller.work_session_id, &scope, &project, &name, version)
        .await
        .map_err(unavailable)?
    {
        None => Err(err(StatusCode::NOT_FOUND, "no such skill version")),
        Some(row) if row.purged => Err(err(StatusCode::GONE, "skill version purged")),
        Some(row) => Ok(Json(json!({ "skill": row }))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_store::{AccountStore, InMemoryAccountStore};
    use crate::vault_routes::tests::bind_session;
    use crate::knowledge_store::{
        InMemoryKnowledgeStore, KnowledgeStore, MemoryAddOutcome, SkillPushOutcome,
        SkillVersionInfo,
    };
    use crate::relay::RelayHub;
    use crate::rtc_session::RtcSessionStore;
    use crate::session_store::SessionStore;
    use crate::vault_store::{InMemoryVaultStore, VaultStore};
    use crate::voice_session::VoiceSessionStore;
    use axum::body::Body;
    use axum::http::Request;
    use axum::routing::{get, post};
    use axum::Router;
    use std::sync::Arc;
    use tower::ServiceExt;

    /// Build an AppState with in-memory stores and a session bound to
    /// `astation_id`. Returns (state, session_id).
    async fn test_state(astation_id: &str) -> (AppState, String) {
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: Arc::new(InMemoryVaultStore::new()),
            knowledge: Arc::new(InMemoryKnowledgeStore::new()),
            identity: Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: Arc::new(crate::account_store::InMemoryAccountStore::default()),
        };
        let session_id = bind_session(&state, astation_id).await;
        (state, session_id)
    }

    fn app(state: AppState) -> Router {
        Router::new()
            .route("/api/memory/batch", post(memory_batch_handler))
            .route("/api/memory", get(memory_pull_handler))
            .route("/api/skills/batch", post(skills_batch_handler))
            .route("/api/skills", get(skills_pull_handler))
            .route("/api/skills/versions", get(skill_versions_handler))
            .route("/api/skills/version", get(skill_version_handler))
            .with_state(state)
    }

    async fn body_json(resp: axum::response::Response) -> Value {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    }

    fn req(method: &str, uri: &str, session: &str, body: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("session {}", session))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn req_no_auth(method: &str, uri: &str, body: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn sample_memory(id: &str, content: &str) -> Value {
        json!({
            "id": id,
            "scope": "global",
            "project": "",
            "machine": "",
            "content": content,
            "content_hash": format!("h:{}", content),
            "confidence": "high",
            "source_agent": "claude",
            "source_machine": "m1",
            "created_at": 1_700_000_000,
            "deleted": false,
            "seq": 0,
        })
    }

    fn sample_skill(name: &str, files: Value) -> Value {
        json!({
            "scope": "global",
            "project": "",
            "name": name,
            "version": 0,
            "files": files,
            "content_hash": "h",
            "source_agent": "claude",
            "source_machine": "m1",
            "created_at": 1_700_000_000,
            "deleted": false,
            "seq": 0,
        })
    }

    fn b64(s: &str) -> String {
        // Local, dependency-free encoder for building test fixtures.
        const ALPHA: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let bytes = s.as_bytes();
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0];
            let b1 = *chunk.get(1).unwrap_or(&0);
            let b2 = *chunk.get(2).unwrap_or(&0);
            out.push(ALPHA[(b0 >> 2) as usize] as char);
            out.push(ALPHA[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            out.push(if chunk.len() > 1 {
                ALPHA[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                ALPHA[(b2 & 0x3f) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    // ─────────────────────────── base64 decoder unit tests ───────────────────────────

    #[test]
    fn base64_roundtrips() {
        for s in ["", "a", "ab", "abc", "hello world", "AKIAIOSFODNN7EXAMPLE"] {
            assert_eq!(base64_decode(&b64(s)).unwrap(), s.as_bytes(), "{}", s);
        }
    }

    #[test]
    fn base64_rejects_bad_input() {
        assert!(base64_decode("a").is_err(), "not a multiple of 4");
        assert!(base64_decode("AAA=AAAA").is_err(), "padding not in last group");
        assert!(base64_decode("A=BC").is_err(), "padding mid-group");
        assert!(base64_decode("!!!!").is_err(), "invalid chars");
        assert!(base64_decode("AAAAA===").is_err(), "3 pad chars");
        assert_eq!(base64_decode("").unwrap(), Vec::<u8>::new());
    }

    /// Non-canonical trailing bits: atem's base64 0.21 STANDARD decoder
    /// rejects these (InvalidLastSymbol); the relay must too, or a row it
    /// accepted but the client can't decode permanently blocks pull sync.
    #[test]
    fn base64_rejects_non_canonical_trailing_bits() {
        assert!(base64_decode("QR==").is_err(), "2-pad group with nonzero trailing bits");
        assert_eq!(base64_decode("QQ==").unwrap(), vec![0x41]);
        assert_eq!(base64_decode("QUI=").unwrap(), vec![0x41, 0x42]);
        assert!(base64_decode("QUJ=").is_err(), "1-pad group with nonzero trailing bits");
    }

    // ─────────────────────────── memory batch ───────────────────────────

    #[tokio::test]
    async fn memory_batch_requires_session() {
        let (state, _sess) = test_state("ws-1").await;
        let app = app(state);
        let resp = app
            .oneshot(req_no_auth(
                "POST",
                "/api/memory/batch?id=a",
                r#"{"ops":[]}"#,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn memory_batch_requires_client_id() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let resp = app
            .oneshot(req("POST", "/api/memory/batch", &sess, r#"{"ops":[]}"#))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn add_then_pull_round_trips_wire_shape() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mem = sample_memory("mem_1", "use pnpm");
        let batch = json!({ "ops": [{"op": "add", "memory": mem}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], true);
        assert!(results["results"][0]["seq"].as_i64().unwrap() > 0);

        let resp = app
            .clone()
            .oneshot(req("GET", "/api/memory?id=a", &sess, ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let pulled = body_json(resp).await;
        let rows = pulled["memories"].as_array().unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        for (k, v) in mem.as_object().unwrap() {
            if k == "seq" {
                assert!(row["seq"].as_i64().unwrap() > 0);
            } else {
                assert_eq!(&row[k], v, "field {}", k);
            }
        }
    }

    #[tokio::test]
    async fn add_with_credential_is_refused_per_op() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "good content")},
            {"op": "add", "memory": sample_memory("mem_2", "key is sk-proj-abcdef1234567890ABCDEF")},
            {"op": "add", "memory": sample_memory("mem_3", "also good")},
        ]});
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r.len(), 3);
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[1]["ok"], false);
        assert!(r[1]["error"].as_str().unwrap().starts_with("possible credential:"));
        assert_eq!(r[2]["ok"], true);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["memories"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| !r["content"].as_str().unwrap().contains("sk-proj")));
    }

    #[tokio::test]
    async fn add_with_reserved_token_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "see atem:memory:foo for details")},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "reserved token");
    }

    #[tokio::test]
    async fn dedup_returns_canonical_id() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "use pnpm")},
            {"op": "add", "memory": sample_memory("mem_2", "use pnpm")},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = &results["results"];
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[0]["id"], "mem_1");
        assert!(r[0].get("canonical_id").is_none());
        assert_eq!(r[1]["ok"], true);
        assert_eq!(r[1]["id"], "mem_2");
        assert_eq!(r[1]["canonical_id"], "mem_1");
        assert_eq!(r[1]["seq"], r[0]["seq"]);
    }

    #[tokio::test]
    async fn delete_is_idempotent() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let add = json!({ "ops": [{"op": "add", "memory": sample_memory("mem_1", "x")}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &add.to_string(),
            ))
            .await
            .unwrap();

        let del = json!({ "ops": [
            {"op": "delete", "id": "mem_1"},
            {"op": "delete", "id": "mem_1"},
            {"op": "delete", "id": "mem_unknown"},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &del.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r.len(), 3);
        assert!(r.iter().all(|x| x["ok"] == true));
        assert!(r[0]["seq"].as_i64().unwrap() > 0);
        assert_eq!(r[2]["seq"], 0);
    }

    /// The whole batch is refused: atem never sends an unknown op, so one
    /// means a broken client, not a per-op refusal to ack.
    #[tokio::test]
    async fn unknown_memory_op_fails_the_whole_batch() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let batch = json!({ "ops": [
            {"op": "add", "memory": sample_memory("mem_1", "fine")},
            {"op": "frobnicate"},
        ]});
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        // Nothing from the batch was applied.
        let pulled = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(pulled["memories"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn unknown_skill_op_and_malformed_bodies_are_400() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        for (uri, body) in [
            ("/api/skills/batch?id=a", json!({"ops": [{"op": "frobnicate"}]}).to_string()),
            ("/api/skills/batch?id=a", "not json".to_string()),
            ("/api/memory/batch?id=a", "{\"ops\": 5}".to_string()),
            // A memory missing required fields is a malformed body too.
            ("/api/memory/batch?id=a", json!({"ops": [{"op": "add", "memory": {"id": "x"}}]}).to_string()),
        ] {
            let resp = app.clone().oneshot(req("POST", uri, &sess, &body)).await.unwrap();
            assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{} {}", uri, body);
        }
    }

    // ─────────────────────────── op caps ───────────────────────────

    #[tokio::test]
    async fn memory_batch_over_op_cap_is_413() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let ops = |n: usize| {
            json!({ "ops": (0..n).map(|i| json!({"op": "delete", "id": format!("m{}", i)})).collect::<Vec<_>>() })
                .to_string()
        };
        let at_cap = app
            .clone()
            .oneshot(req("POST", "/api/memory/batch?id=a", &sess, &ops(MEMORY_BATCH_MAX_OPS)))
            .await
            .unwrap();
        assert_eq!(at_cap.status(), StatusCode::OK);
        let over = app
            .oneshot(req("POST", "/api/memory/batch?id=a", &sess, &ops(MEMORY_BATCH_MAX_OPS + 1)))
            .await
            .unwrap();
        assert_eq!(over.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(body_json(over).await, json!({"error": "too many ops"}));
    }

    #[tokio::test]
    async fn skills_batch_over_op_cap_is_413() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let ops = |n: usize| {
            json!({ "ops": (0..n).map(|i| json!({"op": "delete", "scope": "global", "project": "", "name": format!("s{}", i)})).collect::<Vec<_>>() })
                .to_string()
        };
        let at_cap = app
            .clone()
            .oneshot(req("POST", "/api/skills/batch?id=a", &sess, &ops(SKILLS_BATCH_MAX_OPS)))
            .await
            .unwrap();
        assert_eq!(at_cap.status(), StatusCode::OK);
        let over = app
            .oneshot(req("POST", "/api/skills/batch?id=a", &sess, &ops(SKILLS_BATCH_MAX_OPS + 1)))
            .await
            .unwrap();
        assert_eq!(over.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(body_json(over).await, json!({"error": "too many ops"}));
    }

    #[test]
    fn op_caps_leave_room_for_atems_chunks() {
        // atem sends at most 50 memory ops and 8 skill ops per request.
        assert_eq!(MEMORY_BATCH_MAX_OPS, 64);
        assert_eq!(SKILLS_BATCH_MAX_OPS, 16);
    }

    // ─────────────────────────── NUL bytes ───────────────────────────

    /// Postgres TEXT/JSONB can't hold NUL; it must be a per-op refusal, never
    /// a store error (which would now be a retried 503 forever).
    #[tokio::test]
    async fn nul_in_memory_fields_is_refused_per_op() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mut ops = vec![json!({"op": "add", "memory": sample_memory("mem_ok", "fine")})];
        for field in ["id", "content", "project", "machine", "source_agent", "source_machine", "confidence", "content_hash"] {
            let mut m = sample_memory(&format!("mem_{}", field), &format!("c {}", field));
            m[field] = json!(format!("bad\u{0}{}", field));
            ops.push(json!({"op": "add", "memory": m}));
        }
        ops.push(json!({"op": "delete", "id": "mem\u{0}x"}));
        let resp = app
            .clone()
            .oneshot(req("POST", "/api/memory/batch?id=a", &sess, &json!({"ops": ops}).to_string()))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r[0]["ok"], true);
        for x in &r[1..] {
            assert_eq!(x["ok"], false, "{}", x);
            assert_eq!(x["error"], "invalid memory", "{}", x);
        }
        let pulled = body_json(app.oneshot(req("GET", "/api/memory?id=a", &sess, "")).await.unwrap()).await;
        assert_eq!(pulled["memories"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn nul_in_skill_fields_is_refused_per_op() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let good = sample_skill("ok", json!({"SKILL.md": b64("# hi")}));
        let mut ops = vec![json!({"op": "push", "skill": good, "base_version": 0})];
        for field in ["name", "project", "source_agent", "source_machine", "content_hash"] {
            let mut sk = sample_skill("x", json!({"SKILL.md": b64("# hi")}));
            sk[field] = json!("bad\u{0}");
            ops.push(json!({"op": "push", "skill": sk, "base_version": 0}));
        }
        let bad_path = sample_skill("y", json!({"a\u{0}.md": b64("# hi")}));
        ops.push(json!({"op": "push", "skill": bad_path, "base_version": 0}));
        ops.push(json!({"op": "delete", "scope": "global", "project": "", "name": "n\u{0}"}));
        ops.push(json!({"op": "purge", "scope": "global", "project": "p\u{0}", "name": "n", "versions": null}));
        let resp = app
            .clone()
            .oneshot(req("POST", "/api/skills/batch?id=a", &sess, &json!({"ops": ops}).to_string()))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r[0]["ok"], true);
        for x in &r[1..] {
            assert_eq!(x["ok"], false, "{}", x);
            assert_eq!(x["error"], "invalid skill", "{}", x);
        }
        let pulled = body_json(app.oneshot(req("GET", "/api/skills?id=a", &sess, "")).await.unwrap()).await;
        assert_eq!(pulled["skills"].as_array().unwrap().len(), 1);
    }

    // ─────────────────────────── store failures → 503 ───────────────────────────

    /// A store whose backend is down: every call fails with `Db`.
    struct FailingStore;

    #[async_trait::async_trait]
    impl KnowledgeStore for FailingStore {
        fn backend_name(&self) -> &'static str {
            "failing"
        }
        async fn health_check(&self) -> Result<(), KnowledgeError> {
            Err(KnowledgeError::Db("down".into()))
        }
        async fn add_memory(&self, _: &str, _: MemoryRow) -> Result<MemoryAddOutcome, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn invalidate_memory(&self, _: &str, _: &str, _: i64, _: Option<&str>) -> Result<i64, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn delete_memory(&self, _: &str, _: &str) -> Result<i64, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn pull_memories(&self, _: &str, _: i64, _: i64) -> Result<Vec<MemoryRow>, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn push_skill(&self, _: &str, _: SkillRow, _: i64) -> Result<SkillPushOutcome, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn delete_skill(&self, _: &str, _: &str, _: &str, _: &str) -> Result<SkillPushOutcome, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn purge_skill(&self, _: &str, _: &str, _: &str, _: &str, _: Option<Vec<i64>>) -> Result<u64, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn pull_skills(&self, _: &str, _: i64, _: i64) -> Result<Vec<SkillRow>, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn skill_versions(&self, _: &str, _: &str, _: &str, _: &str) -> Result<Vec<SkillVersionInfo>, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn skill_version(&self, _: &str, _: &str, _: &str, _: &str, _: i64) -> Result<Option<SkillRow>, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn encryption_counts(&self, _: &str, _: Option<&str>) -> Result<crate::encryption::EncryptionCounts, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn rewrite_memory_fields(
            &self,
            _: &str,
            _: &str,
            _: &str,
            _: &str,
            _: &str,
        ) -> Result<i64, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
        async fn rewrite_skill_fields(
            &self,
            _: &str,
            _: &str,
            _: &str,
            _: &str,
            _: i64,
            _: &str,
            _: Value,
            _: &str,
        ) -> Result<i64, KnowledgeError> {
            Err(KnowledgeError::Db("connection reset".into()))
        }
    }

    #[tokio::test]
    async fn store_failure_fails_the_whole_batch_with_503() {
        let (mut state, sess) = test_state("ws-1").await;
        state.knowledge = Arc::new(FailingStore);
        let app = app(state);
        let cases = [
            ("/api/memory/batch?id=a", json!({"ops": [{"op": "add", "memory": sample_memory("mem_1", "x")}]})),
            ("/api/memory/batch?id=a", json!({"ops": [{"op": "delete", "id": "mem_1"}]})),
            ("/api/memory/batch?id=a", json!({"ops": [{"op": "invalidate", "id": "mem_1", "invalid_at": 5}]})),
            ("/api/skills/batch?id=a", json!({"ops": [{"op": "push", "skill": sample_skill("x", json!({"SKILL.md": b64("# hi")})), "base_version": 0}]})),
            ("/api/skills/batch?id=a", json!({"ops": [{"op": "delete", "scope": "global", "project": "", "name": "x"}]})),
            ("/api/skills/batch?id=a", json!({"ops": [{"op": "purge", "scope": "global", "project": "", "name": "x", "versions": null}]})),
        ];
        for (uri, body) in cases {
            let resp = app.clone().oneshot(req("POST", uri, &sess, &body.to_string())).await.unwrap();
            assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE, "{} {}", uri, body);
            let v = body_json(resp).await;
            assert_eq!(v, json!({"error": "temporarily unavailable"}));
            assert!(!v.to_string().contains("connection reset"));
        }
        for uri in [
            "/api/memory?id=a",
            "/api/skills?id=a",
            "/api/skills/versions?id=a&scope=global&name=x",
            "/api/skills/version?id=a&scope=global&name=x&version=1",
        ] {
            let resp = app.clone().oneshot(req("GET", uri, &sess, "")).await.unwrap();
            assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE, "{}", uri);
        }
    }

    // ─────────────────────────── production router ───────────────────────────

    fn prod_req(uri: &str, session: Option<&str>, body: Body) -> Request<Body> {
        let mut b = Request::builder()
            .method("POST")
            .uri(uri)
            .header("content-type", "application/json")
            // The rate limiter keys on the client IP.
            .header("x-forwarded-for", "203.0.113.50");
        if let Some(s) = session {
            b = b.header("authorization", format!("session {}", s));
        }
        b.body(body).unwrap()
    }

    async fn prod_post_json(
        app: &Router,
        uri: &str,
        session: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let response = app
            .clone()
            .oneshot(prod_req(uri, Some(session), Body::from(body.to_string())))
            .await
            .unwrap();
        let status = response.status();
        (status, body_json(response).await)
    }

    /// An unauthenticated caller can't make the relay buffer a large body:
    /// auth runs first and the body is never polled.
    #[tokio::test]
    async fn unauthenticated_oversized_body_is_401_without_reading_it() {
        use std::sync::atomic::{AtomicBool, Ordering};
        for uri in ["/api/skills/batch?id=a", "/api/memory/batch?id=a"] {
            let (state, _sess) = test_state("ws-1").await;
            let app = crate::router(state);
            let polled = Arc::new(AtomicBool::new(false));
            let flag = polled.clone();
            let stream = futures_util::stream::once(async move {
                flag.store(true, Ordering::SeqCst);
                Ok::<_, std::io::Error>(axum::body::Bytes::from(vec![b'x'; 17 * 1024 * 1024]))
            });
            let resp = app
                .oneshot(prod_req(uri, None, Body::from_stream(stream)))
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "{}", uri);
            assert!(!polled.load(Ordering::SeqCst), "{}: body was read before auth", uri);
        }
    }

    #[tokio::test]
    async fn multi_megabyte_skill_push_succeeds_through_production_router() {
        let (state, sess) = test_state("ws-1").await;
        let app = crate::router(state);
        // ~6 MB of text → ~8 MB of base64: above nginx's and axum's 1-2 MB
        // defaults, below the 16 MB skills limit.
        let text = "step: run the build and read the output carefully\n".repeat(120_000);
        let files = json!({"SKILL.md": b64(&text)});
        let body = json!({ "ops": [{"op": "push", "skill": sample_skill("big", files), "base_version": 0}] }).to_string();
        assert!(body.len() > 2 * 1024 * 1024 && body.len() < 16 * 1024 * 1024, "{}", body.len());
        let resp = app
            .oneshot(prod_req("/api/skills/batch?id=a", Some(&sess), Body::from(body)))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let v = body_json(resp).await;
        assert_eq!(v["results"][0]["ok"], true, "{}", v);
    }

    #[tokio::test]
    async fn over_limit_bodies_are_413_through_production_router() {
        for (uri, limit) in [
            ("/api/memory/batch?id=a", MEMORY_BATCH_BODY_LIMIT),
            ("/api/skills/batch?id=a", SKILLS_BATCH_BODY_LIMIT),
        ] {
            let (state, sess) = test_state("ws-1").await;
            let app = crate::router(state);
            let big = "x".repeat(limit + 1);
            let resp = app
                .oneshot(prod_req(uri, Some(&sess), Body::from(big)))
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE, "{}", uri);
        }
    }

    #[tokio::test]
    async fn add_with_invalid_scope_is_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mut mem = sample_memory("mem_1", "x");
        mem["scope"] = json!("bogus");
        let batch = json!({ "ops": [{"op": "add", "memory": mem}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess,
                &batch.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid memory");

        let pulled = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(pulled["memories"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn encrypted_account_accepts_only_structurally_valid_current_key_fields() {
        use base64::Engine;

        let accounts = Arc::new(InMemoryAccountStore::default());
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: Arc::new(InMemoryVaultStore::new()),
            knowledge: Arc::new(InMemoryKnowledgeStore::new()),
            identity: Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: accounts.clone(),
        };
        let session = bind_session(&state, "ws-1").await;
        accounts
            .set_encryption_state("ws-1", "enabling", Some("0123abcd"), 1)
            .await
            .unwrap();
        let app = app(state);
        let payload = base64::engine::general_purpose::STANDARD.encode([0_u8; 40]);
        let mut valid = sample_memory("mem-valid", &format!("e1.0123abcd.{payload}"));
        valid["content_hash"] = json!(format!("h1.0123abcd.{}", "a".repeat(64)));
        let response = body_json(
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/memory/batch?id=a",
                    &session,
                    &json!({"ops": [{"op": "add", "memory": valid}]}).to_string(),
                ))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], true, "{response}");

        for (id, content) in [
            ("mem-plain", "AKIAIOSFODNN7EXAMPLE".to_string()),
            ("mem-malformed", "e1.0123abcd.not-base64".to_string()),
            ("mem-obsolete", format!("e1.89abcdef.{payload}")),
        ] {
            let mut memory = sample_memory(id, &content);
            memory["content_hash"] = json!(format!("h1.0123abcd.{}", "b".repeat(64)));
            let response = body_json(
                app.clone()
                    .oneshot(req(
                        "POST",
                        "/api/memory/batch?id=a",
                        &session,
                        &json!({"ops": [{"op": "add", "memory": memory}]}).to_string(),
                    ))
                    .await
                    .unwrap(),
            )
            .await;
            assert_eq!(response["results"][0]["ok"], false, "{id}: {response}");
        }
    }

    #[tokio::test]
    async fn production_routes_complete_encryption_and_decryption_migrations() {
        let knowledge = Arc::new(InMemoryKnowledgeStore::new());
        let vault = Arc::new(InMemoryVaultStore::new());
        let accounts = Arc::new(InMemoryAccountStore::new(knowledge.clone(), vault.clone()));
        let state = AppState {
            sessions: SessionStore::new(),
            relay: RelayHub::new(),
            rtc_sessions: RtcSessionStore::new(),
            voice_sessions: VoiceSessionStore::new(),
            vault: vault.clone(),
            knowledge: knowledge.clone(),
            identity: Arc::new(crate::identity_store::InMemoryIdentityStore::new()),
            accounts: accounts.clone(),
        };
        let session = bind_session(&state, "ws-1").await;
        let app = crate::router(state);

        let mut memory = sample_memory("mem-migrate", "plain memory");
        memory["scope"] = json!("project");
        memory["project"] = json!("project-x");
        let (status, response) = prod_post_json(
            &app,
            "/api/memory/batch?id=atem-a",
            &session,
            json!({"ops": [{"op": "add", "memory": memory}]}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response["results"][0]["ok"], true, "{response}");

        for (base_version, body) in [(0, "skill v1"), (1, "skill v2")] {
            let mut skill = sample_skill("migrate", json!({"SKILL.md": b64(body)}));
            skill["scope"] = json!("project");
            skill["project"] = json!("project-x");
            skill["content_hash"] = json!(format!("hash-{body}"));
            let (status, response) = prod_post_json(
                &app,
                "/api/skills/batch?id=atem-a",
                &session,
                json!({"ops": [{"op": "push", "skill": skill, "base_version": base_version}]}),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response["results"][0]["ok"], true, "{response}");
            assert_eq!(response["results"][0]["version"], base_version + 1);
        }

        let (status, created) = prod_post_json(
            &app,
            "/api/vault?id=atem-a",
            &session,
            json!({"summary": "plain summary"}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let vault_id = created["vault_id"].as_str().unwrap().to_string();
        for body in [json!({"text": "vault v1"}), json!({"text": "vault v2", "entry_id": 1})] {
            let (status, response) = prod_post_json(
                &app,
                &format!("/api/vault/{vault_id}?id=atem-a"),
                &session,
                body,
            )
            .await;
            assert_eq!(status, StatusCode::OK, "{response}");
        }

        let kid = "0123abcd";
        accounts
            .set_encryption_state("ws-1", "enabling", Some(kid), 1)
            .await
            .unwrap();
        assert!(accounts
            .set_encryption_state("ws-1", "on", Some(kid), 2)
            .await
            .is_err());
        let envelope = |marker: char| format!("e1.{kid}.{}", b64(&marker.to_string().repeat(40)));
        let hash = |marker: char| format!("h1.{kid}.{}", marker.to_string().repeat(64));
        let encrypted_project = hash('a');
        let encrypted_path = envelope('p');
        let encrypted_files = |marker: char| {
            Value::Object(
                [(
                    encrypted_path.clone(),
                    Value::String(b64(&envelope(marker))),
                )]
                .into_iter()
                .collect(),
            )
        };

        let encrypted_memory = envelope('m');
        let (status, response) = prod_post_json(
            &app,
            "/api/memory/batch?id=atem-a",
            &session,
            json!({"ops": [{
                "op": "rewrite",
                "id": "mem-migrate",
                "project": encrypted_project,
                "content": encrypted_memory,
                "content_hash": hash('b')
            }]}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response["results"][0]["ok"], true, "{response}");

        let (status, response) = prod_post_json(
            &app,
            "/api/skills/batch?id=atem-a",
            &session,
            json!({"ops": [
                {
                    "op": "rewrite", "scope": "project", "old_project": "project-x",
                    "name": "migrate", "version": 1, "project": encrypted_project,
                    "files": encrypted_files('1'), "content_hash": hash('c')
                },
                {
                    "op": "rewrite", "scope": "project", "old_project": "project-x",
                    "name": "migrate", "version": 2, "project": encrypted_project,
                    "files": encrypted_files('2'), "content_hash": hash('d')
                }
            ]}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(response["results"].as_array().unwrap().iter().all(|item| item["ok"] == true));

        let encrypted_summary = envelope('s');
        let encrypted_vault_v1 = envelope('v');
        let encrypted_vault_v2 = envelope('w');
        let (status, response) = prod_post_json(
            &app,
            &format!("/api/vault/{vault_id}/encryption?id=atem-a"),
            &session,
            json!({
                "summary": encrypted_summary,
                "entries": [
                    {"entry_no": 1, "version": 1, "content": encrypted_vault_v1},
                    {"entry_no": 1, "version": 2, "content": encrypted_vault_v2}
                ]
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{response}");

        let enabled = accounts
            .set_encryption_state("ws-1", "on", Some(kid), 3)
            .await
            .unwrap();
        assert_eq!((enabled.plaintext_fields, enabled.ciphertext_fields, enabled.obsolete_fields), (0, 14, 0));

        let memories = knowledge.pull_memories("ws-1", 0, 10).await.unwrap();
        assert_eq!(memories.len(), 1);
        assert_eq!(memories[0].content, encrypted_memory);
        for version in 1..=2 {
            let skill = knowledge
                .skill_version("ws-1", "project", &encrypted_project, "migrate", version)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(skill.files, encrypted_files(char::from_digit(version as u32, 10).unwrap()));
        }
        assert_eq!(vault.list_readable("ws-1").await.unwrap()[0].summary, encrypted_summary);
        let encrypted_history = vault.read(&vault_id, None, true).await.unwrap();
        assert_eq!(encrypted_history.len(), 2);
        assert!(encrypted_history.iter().all(|entry| entry.content.starts_with("e1.0123abcd.")));

        let mut plain_memory = sample_memory("plain-rejected", "plaintext after enable");
        plain_memory["scope"] = json!("project");
        plain_memory["project"] = json!("project-x");
        let (_, response) = prod_post_json(
            &app,
            "/api/memory/batch?id=atem-a",
            &session,
            json!({"ops": [{"op": "add", "memory": plain_memory}]}),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], false, "{response}");
        let (_, response) = prod_post_json(
            &app,
            "/api/skills/batch?id=atem-a",
            &session,
            json!({"ops": [{"op": "push", "skill": sample_skill(
                "plain-rejected", json!({"SKILL.md": b64("plaintext after enable")})
            ), "base_version": 0}]}),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], false, "{response}");
        let (status, _) = prod_post_json(
            &app,
            &format!("/api/vault/{vault_id}?id=atem-a"),
            &session,
            json!({"text": "plaintext after enable"}),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);

        accounts
            .set_encryption_state("ws-1", "disabling", Some(kid), 4)
            .await
            .unwrap();
        let (_, response) = prod_post_json(
            &app,
            "/api/memory/batch?id=atem-a",
            &session,
            json!({"ops": [{
                "op": "rewrite", "id": "mem-migrate", "project": "project-x",
                "content": "plain memory", "content_hash": "h:plain memory"
            }]}),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], true, "{response}");
        let (_, response) = prod_post_json(
            &app,
            "/api/skills/batch?id=atem-a",
            &session,
            json!({"ops": [
                {
                    "op": "rewrite", "scope": "project", "old_project": encrypted_project,
                    "name": "migrate", "version": 1, "project": "project-x",
                    "files": {"SKILL.md": b64("skill v1")}, "content_hash": "hash-skill v1"
                },
                {
                    "op": "rewrite", "scope": "project", "old_project": encrypted_project,
                    "name": "migrate", "version": 2, "project": "project-x",
                    "files": {"SKILL.md": b64("skill v2")}, "content_hash": "hash-skill v2"
                }
            ]}),
        )
        .await;
        assert!(response["results"].as_array().unwrap().iter().all(|item| item["ok"] == true));
        let (status, response) = prod_post_json(
            &app,
            &format!("/api/vault/{vault_id}/encryption?id=atem-a"),
            &session,
            json!({
                "summary": "plain summary",
                "entries": [
                    {"entry_no": 1, "version": 1, "content": "vault v1"},
                    {"entry_no": 1, "version": 2, "content": "vault v2"}
                ]
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{response}");

        let disabled = accounts
            .set_encryption_state("ws-1", "off", Some(kid), 5)
            .await
            .unwrap();
        assert_eq!((disabled.plaintext_fields, disabled.ciphertext_fields, disabled.obsolete_fields), (14, 0, 0));
        assert_eq!(
            knowledge
                .skill_version("ws-1", "project", "project-x", "migrate", 1)
                .await
                .unwrap()
                .unwrap()
                .files,
            json!({"SKILL.md": b64("skill v1")})
        );
        assert_eq!(vault.read(&vault_id, None, true).await.unwrap()[0].content, "vault v1");

        let mut stale_memory = sample_memory("stale-ciphertext", &envelope('z'));
        stale_memory["content_hash"] = json!(hash('z'));
        let (_, response) = prod_post_json(
            &app,
            "/api/memory/batch?id=atem-a",
            &session,
            json!({"ops": [{"op": "add", "memory": stale_memory}]}),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], false, "{response}");
        let mut stale_skill = sample_skill("stale-ciphertext", encrypted_files('z'));
        stale_skill["content_hash"] = json!(hash('z'));
        let (_, response) = prod_post_json(
            &app,
            "/api/skills/batch?id=atem-a",
            &session,
            json!({"ops": [{"op": "push", "skill": stale_skill, "base_version": 0}]}),
        )
        .await;
        assert_eq!(response["results"][0]["ok"], false, "{response}");
        let (status, _) = prod_post_json(
            &app,
            &format!("/api/vault/{vault_id}?id=atem-a"),
            &session,
            json!({"text": envelope('z')}),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
    }

    #[tokio::test]
    async fn accounts_are_isolated() {
        let (state, sess1) = test_state("ws-1").await;
        let sess2 = bind_session(&state, "ws-2").await;
        let app = app(state);

        let add_mem = json!({ "ops": [{"op": "add", "memory": sample_memory("mem_1", "secret-to-ws1")}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/memory/batch?id=a",
                &sess1,
                &add_mem.to_string(),
            ))
            .await
            .unwrap();
        let push_skill = json!({ "ops": [{"op": "push", "skill": sample_skill("x", json!({"SKILL.md": b64("body")})), "base_version": 0}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess1,
                &push_skill.to_string(),
            ))
            .await
            .unwrap();

        let mem2 = body_json(
            app.clone()
                .oneshot(req("GET", "/api/memory?id=a", &sess2, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(mem2["memories"].as_array().unwrap().len(), 0);
        let sk2 = body_json(
            app.clone()
                .oneshot(req("GET", "/api/skills?id=a", &sess2, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(sk2["skills"].as_array().unwrap().len(), 0);

        let mem1 = body_json(
            app.oneshot(req("GET", "/api/memory?id=a", &sess1, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(mem1["memories"].as_array().unwrap().len(), 1);
    }

    // ─────────────────────────── skills batch ───────────────────────────

    #[tokio::test]
    async fn skill_push_pull_and_supersede() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": b64("# hi")});
        let push1 = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files.clone()), "base_version": 0}] });
        let r1 = body_json(
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push1.to_string(),
                ))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(r1["results"][0]["ok"], true);
        assert_eq!(r1["results"][0]["version"], 1);
        assert_eq!(r1["results"][0]["superseded_concurrent"], false);

        // Stale base_version → still applied, flagged.
        let push2 = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files.clone()), "base_version": 0}] });
        let r2 = body_json(
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push2.to_string(),
                ))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(r2["results"][0]["version"], 2);
        assert_eq!(r2["results"][0]["superseded_concurrent"], true);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["skills"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["files"], files);
    }

    #[tokio::test]
    async fn skill_with_secret_file_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"creds.txt": b64("AKIAIOSFODNN7EXAMPLE")});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        let e = results["results"][0]["error"].as_str().unwrap();
        assert!(e.starts_with("possible credential: creds.txt:"), "{}", e);

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(pulled["skills"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn skill_push_with_invalid_base64_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": "not-valid-base64!!"});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid base64");
    }

    #[tokio::test]
    async fn skill_push_with_invalid_scope_is_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mut skill = sample_skill("x", json!({"SKILL.md": b64("# hi")}));
        skill["scope"] = json!("machine"); // valid for memories, not skills
        let push = json!({ "ops": [{"op": "push", "skill": skill, "base_version": 0}] });
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid skill");

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(pulled["skills"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn skill_delete_with_invalid_scope_is_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let del = json!({ "ops": [
            {"op": "delete", "scope": "bogus", "project": "", "name": "x"},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &del.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid skill");
    }

    #[tokio::test]
    async fn skill_purge_with_invalid_scope_is_refused() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let purge = json!({ "ops": [
            {"op": "purge", "scope": "bogus", "project": "", "name": "x", "versions": null},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &purge.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0]["ok"], false);
        assert_eq!(results["results"][0]["error"], "invalid skill");
    }

    #[tokio::test]
    async fn skill_delete_appends_tombstone_and_is_idempotent_on_unknown() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let files = json!({"SKILL.md": b64("v1")});
        let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
        app.clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &push.to_string(),
            ))
            .await
            .unwrap();

        let del = json!({ "ops": [
            {"op": "delete", "scope": "global", "project": "", "name": "x"},
            {"op": "delete", "scope": "global", "project": "", "name": "does-not-exist"},
        ]});
        let resp = app
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &del.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        let r = results["results"].as_array().unwrap();
        assert_eq!(r[0]["ok"], true);
        assert_eq!(r[0]["version"], 2);
        assert_eq!(r[1]["ok"], true);
        assert_eq!(r[1]["version"], 0);
        assert_eq!(r[1]["seq"], 0);
    }

    #[tokio::test]
    async fn skill_purge_all() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        for body in ["v1", "v2"] {
            let files = json!({"SKILL.md": b64(body)});
            let push = json!({ "ops": [{"op": "push", "skill": sample_skill("x", files), "base_version": 0}] });
            app.clone()
                .oneshot(req(
                    "POST",
                    "/api/skills/batch?id=a",
                    &sess,
                    &push.to_string(),
                ))
                .await
                .unwrap();
        }

        let purge = json!({ "ops": [
            {"op": "purge", "scope": "global", "project": "", "name": "x", "versions": null},
        ]});
        let resp = app
            .clone()
            .oneshot(req(
                "POST",
                "/api/skills/batch?id=a",
                &sess,
                &purge.to_string(),
            ))
            .await
            .unwrap();
        let results = body_json(resp).await;
        assert_eq!(results["results"][0], json!({"ok": true}));

        let pulled = body_json(
            app.oneshot(req("GET", "/api/skills?id=a", &sess, ""))
                .await
                .unwrap(),
        )
        .await;
        let rows = pulled["skills"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r["deleted"] == true));
    }

    // ─────────────────────────── invalidate + validity ───────────────────────────

    async fn call(app: &Router, method: &str, uri: &str, session: &str, body: Option<Value>) -> (StatusCode, Value) {
        let b = body.map(|v| v.to_string()).unwrap_or_default();
        let resp = app.clone().oneshot(req(method, uri, session, &b)).await.unwrap();
        let status = resp.status();
        (status, body_json(resp).await)
    }

    fn add_op(id: &str, content: &str) -> Value {
        json!({"op": "add", "memory": sample_memory(id, content)})
    }

    async fn pull_row(app: &Router, sess: &str, id: &str) -> Value {
        let (_, v) = call(app, "GET", "/api/memory?id=a", sess, None).await;
        v["memories"].as_array().unwrap().iter().find(|r| r["id"] == id).cloned().unwrap_or(Value::Null)
    }

    const MEM_BATCH: &str = "/api/memory/batch?id=a";

    #[tokio::test]
    async fn invalidate_marks_fact_invalid_and_keeps_content() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [add_op("mem_old", "port 8765"), add_op("mem_new", "port 9000")]}))).await;
        let (st, v) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [
            {"op": "invalidate", "id": "mem_old", "invalid_at": 1_790_000_000, "superseded_by": "mem_new"},
        ]}))).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(v["results"][0]["ok"], true, "{v}");
        assert!(v["results"][0]["seq"].as_i64().unwrap() > 0);
        let row = pull_row(&app, &sess, "mem_old").await;
        assert_eq!(row["content"], "port 8765");
        assert_eq!(row["invalid_at"], 1_790_000_000);
        assert_eq!(row["superseded_by"], "mem_new");
        assert_eq!(row["deleted"], false);
        assert_eq!(row["deleted_at"], Value::Null);
        assert_eq!(pull_row(&app, &sess, "mem_new").await["invalid_at"], Value::Null);
    }

    #[tokio::test]
    async fn invalidate_is_final_and_unknown_or_foreign_ids_are_ok() {
        let (state, sess) = test_state("ws-1").await;
        let sess2 = bind_session(&state, "ws-2").await;
        let app = app(state);
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [add_op("mem_1", "x")]}))).await;
        let inv = |id: &str, at: i64| json!({"op": "invalidate", "id": id, "invalid_at": at});
        let (_, v) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [inv("mem_1", 100), inv("mem_1", 200), inv("mem_unknown", 100)]}))).await;
        let r = v["results"].as_array().unwrap();
        assert!(r.iter().all(|x| x["ok"] == true), "{v}");
        assert!(r[0]["seq"].as_i64().unwrap() > 0);
        assert_eq!((r[1]["seq"].clone(), r[2]["seq"].clone()), (json!(0), json!(0)));
        // Another account can't touch it, and can't tell that it exists.
        let (_, v2) = call(&app, "POST", MEM_BATCH, &sess2, Some(json!({"ops": [inv("mem_1", 300)]}))).await;
        assert_eq!(v2["results"][0], json!({"ok": true, "id": "mem_1", "seq": 0}));
        assert_eq!(pull_row(&app, &sess, "mem_1").await["invalid_at"], 100);
    }

    #[tokio::test]
    async fn invalidate_input_problems_are_refused_per_op() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [add_op("mem_1", "x")]}))).await;
        let (st, v) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [
            {"op": "invalidate", "id": "mem_1", "invalid_at": 0},
            {"op": "invalidate", "id": "mem_1", "invalid_at": -5},
            {"op": "invalidate", "id": "mem\u{0}1", "invalid_at": 5},
            {"op": "invalidate", "id": "mem_1", "invalid_at": 5, "superseded_by": "mem\u{0}2"},
        ]}))).await;
        assert_eq!(st, StatusCode::OK);
        for x in v["results"].as_array().unwrap() {
            assert_eq!(x, &json!({"ok": false, "error": "invalid memory"}));
        }
        assert_eq!(pull_row(&app, &sess, "mem_1").await["invalid_at"], Value::Null);
        // A missing invalid_at is a malformed op: the whole batch is 400.
        let (st, _) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [{"op": "invalidate", "id": "mem_1"}]}))).await;
        assert_eq!(st, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn invalidate_follows_a_canonical_id_from_the_same_batch() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [add_op("mem_old", "port 8765"), add_op("mem_canon", "port 9000")]}))).await;
        // Another machine replaced mem_old with the same text mem_canon already has.
        let (_, v) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [
            add_op("mem_new", "port 9000"),
            {"op": "invalidate", "id": "mem_old", "invalid_at": 5, "superseded_by": "mem_new"},
        ]}))).await;
        assert_eq!(v["results"][0]["canonical_id"], "mem_canon");
        assert_eq!(v["results"][1]["ok"], true);
        assert_eq!(pull_row(&app, &sess, "mem_old").await["superseded_by"], "mem_canon");
    }

    #[tokio::test]
    async fn add_carries_valid_at_and_refuses_non_positive() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        let mut m = sample_memory("mem_1", "x");
        m["valid_at"] = json!(1_690_000_000);
        let mut bad = sample_memory("mem_2", "y");
        bad["valid_at"] = json!(0);
        let (_, v) = call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [
            {"op": "add", "memory": m}, {"op": "add", "memory": bad},
        ]}))).await;
        assert_eq!(v["results"][0]["ok"], true);
        assert_eq!(v["results"][1], json!({"ok": false, "error": "invalid memory"}));
        assert_eq!(pull_row(&app, &sess, "mem_1").await["valid_at"], 1_690_000_000);
        assert_eq!(pull_row(&app, &sess, "mem_2").await, Value::Null);
    }

    #[tokio::test]
    async fn deleted_rows_carry_deleted_at_and_the_legacy_flag() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [add_op("mem_1", "x")]}))).await;
        call(&app, "POST", MEM_BATCH, &sess, Some(json!({"ops": [{"op": "delete", "id": "mem_1"}]}))).await;
        let row = pull_row(&app, &sess, "mem_1").await;
        assert_eq!(row["deleted"], true);
        assert!(row["deleted_at"].as_i64().unwrap() > 1_700_000_000);
        assert_eq!(row["content"], "");
    }

    // ─────────────────────────── skill history ───────────────────────────

    async fn skill_op(app: &Router, sess: &str, op: Value) {
        let (st, v) = call(app, "POST", "/api/skills/batch?id=a", sess, Some(json!({"ops": [op]}))).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(v["results"][0]["ok"], true, "{v}");
    }

    fn push_op(name: &str, body: &str) -> Value {
        json!({"op": "push", "skill": sample_skill(name, json!({"SKILL.md": b64(body)})), "base_version": 0})
    }

    const X_KEY: &str = "scope=global&project=&name=x";

    #[tokio::test]
    async fn skill_versions_lists_history_without_files() {
        let (state, sess) = test_state("ws-1").await;
        let sess2 = bind_session(&state, "ws-2").await;
        let app = app(state);
        skill_op(&app, &sess, push_op("x", "v1")).await;
        skill_op(&app, &sess, push_op("x", "v2")).await;
        skill_op(&app, &sess, json!({"op": "delete", "scope": "global", "project": "", "name": "x"})).await;
        skill_op(&app, &sess, json!({"op": "purge", "scope": "global", "project": "", "name": "x", "versions": [1]})).await;
        let (st, v) = call(&app, "GET", &format!("/api/skills/versions?id=a&{X_KEY}"), &sess, None).await;
        assert_eq!(st, StatusCode::OK);
        let vs = v["versions"].as_array().unwrap();
        let got: Vec<(i64, bool, bool, i64)> = vs.iter().map(|r| (
            r["version"].as_i64().unwrap(), r["deleted"].as_bool().unwrap(),
            r["purged"].as_bool().unwrap(), r["file_count"].as_i64().unwrap(),
        )).collect();
        assert_eq!(got, vec![(3, true, false, 0), (2, false, false, 1), (1, true, true, 0)]);
        assert!(vs.iter().all(|r| r.get("files").is_none()));
        assert_eq!(vs[1]["source_agent"], "claude");
        assert_eq!(vs[1]["source_machine"], "m1");
        assert_eq!(vs[1]["created_at"], 1_700_000_000);
        // Another account sees an empty history.
        let (st2, v2) = call(&app, "GET", &format!("/api/skills/versions?id=a&{X_KEY}"), &sess2, None).await;
        assert_eq!((st2, v2), (StatusCode::OK, json!({"versions": []})));
    }

    #[tokio::test]
    async fn skill_version_returns_files_404_and_410() {
        let (state, sess) = test_state("ws-1").await;
        let sess2 = bind_session(&state, "ws-2").await;
        let app = app(state);
        skill_op(&app, &sess, push_op("x", "v1")).await;
        skill_op(&app, &sess, push_op("x", "v2")).await;
        skill_op(&app, &sess, json!({"op": "delete", "scope": "global", "project": "", "name": "x"})).await;
        skill_op(&app, &sess, json!({"op": "purge", "scope": "global", "project": "", "name": "x", "versions": [1]})).await;
        let get = |v: i64| format!("/api/skills/version?id=a&{X_KEY}&version={v}");
        let (st, v) = call(&app, "GET", &get(2), &sess, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(v["skill"]["version"], 2);
        assert_eq!(v["skill"]["files"], json!({"SKILL.md": b64("v2")}));
        assert!(v["skill"].get("purged").is_none());
        let (st, v) = call(&app, "GET", &get(3), &sess, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!((v["skill"]["deleted"].clone(), v["skill"]["files"].clone()), (json!(true), json!({})));
        let (st, v) = call(&app, "GET", &get(1), &sess, None).await;
        assert_eq!((st, v), (StatusCode::GONE, json!({"error": "skill version purged"})));
        let (st, v) = call(&app, "GET", &get(9), &sess, None).await;
        assert_eq!((st, v), (StatusCode::NOT_FOUND, json!({"error": "no such skill version"})));
        let (st, _) = call(&app, "GET", &get(2), &sess2, None).await;
        assert_eq!(st, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn skill_history_bad_queries_are_400_and_auth_is_required() {
        let (state, sess) = test_state("ws-1").await;
        let app = app(state);
        for uri in [
            "/api/skills/versions?id=a&scope=machine&name=x",
            "/api/skills/versions?id=a&scope=global",
            "/api/skills/versions?id=a&scope=global&name=x%00y",
            "/api/skills/version?id=a&scope=global&name=x",
            "/api/skills/version?id=a&scope=global&name=x&version=abc",
        ] {
            let (st, _) = call(&app, "GET", uri, &sess, None).await;
            assert_eq!(st, StatusCode::BAD_REQUEST, "{uri}");
        }
        let resp = app
            .oneshot(req_no_auth("GET", "/api/skills/versions?id=a&scope=global&name=x", ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn skill_history_routes_are_mounted_in_the_production_router() {
        let (state, sess) = test_state("ws-1").await;
        let app = crate::router(state);
        let get = |uri: &str| {
            Request::builder()
                .method("GET")
                .uri(uri)
                .header("authorization", format!("session {}", sess))
                .header("x-forwarded-for", "203.0.113.50")
                .body(Body::empty())
                .unwrap()
        };
        let resp = app.clone().oneshot(get("/api/skills/versions?id=a&scope=global&name=x")).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app.oneshot(get("/api/skills/version?id=a&scope=global&name=x&version=1")).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        assert_eq!(body_json(resp).await, json!({"error": "no such skill version"}));
    }
}
