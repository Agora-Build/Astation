# Knowledge Sync (relay side) + atem pairing auth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve Atem Memory's `/api/memory` and `/api/skills` sync endpoints from
the Station relay-server, authenticated by Astation pairing sessions, and switch
atem's client from SSO bearer tokens to the pairing session. That makes
cross-machine sync work.

**Architecture:** This mirrors the vault. There's a `KnowledgeStore` trait with an
in-memory implementation (tests and dev) and a Postgres implementation (used when
`DATABASE_URL` is set, with sqlx migrations). A new `knowledge_routes.rs` handles the
four endpoints. The vault's `resolve_caller` (`Authorization: session <id>` plus
`?id=<instance_id>`) is reused, and the **account key is the caller's
`work_session_id`** (the paired astation_id). The relay runs the same secret and
reserved-token checks as atem before storing anything.

**Tech Stack:** relay-server: Rust, axum 0.7, sqlx 0.7 (postgres), serde,
async-trait, tokio. atem: existing `src/memory/` modules.

**Spec:** `Atem/designs/atem-memory.md` (the §Relay API, §Data model, and §Security
sections), and the "Prerequisite" and "Wire contract" sections of
`Atem/designs/atem-memory-implementation-plan.md`. **Auth amendment (decided
2026-09-29):** use Astation pairing sessions, not SSO bearer tokens. The account
is the paired Astation.

## Global Constraints

- **Astation is the control plane.** Atem Memory works only on machines your Astation has approved through pairing. The relay accepts only granted sessions bound to an Astation. atem refuses every memory, skill, and sync command (local ones included) unless the machine has an active pairing session for the configured Astation.
- The account is `Caller.work_session_id` (the astation_id bound to the session). Every read and write is limited to it. `?id=<instance_id>` is `client_id` and is only used for logging and `source_machine` checks.
- Wire JSON must match the atem client exactly (see "Wire contract"). If anything differs, the relay changes, not atem.
- **A credential value never reaches the database.** Every memory `content` and every skill file is checked with the ported atem secret rules plus the reserved token `atem:memory:`. A match is refused per op: `{"ok": false, "error": "possible credential: <kind>"}` or `"reserved token"`. No partial writes.
- Deleting a memory: blanks `content` and `content_hash`, sets deleted, takes a new `seq`. **It is idempotent**: an unknown or already-deleted id returns `ok: true`.
- Skill push always appends `max(version)+1`. `superseded_concurrent = base_version < current max live version`. Delete appends a tombstone version (`deleted: true`, `files: {}`). Purge sets `files={}`, `content_hash=''`, `deleted=true` on the chosen versions (all versions when `versions` is null), each with a new `seq`.
- Per-request body limits: `/api/memory/batch` 2 MB; `/api/skills/batch` 16 MB. The atem client sends at most 8 skill ops per request.
- **No new crates** in either repo. Commit messages end with `🤖 Built with SMT <smt@agora.build>`.

## Wire contract

```
Auth (all):   Authorization: session <session_id>
Query (all):  ?id=<instance_id>

POST /api/memory/batch        {"ops":[Op…]}  → 200 {"results":[OpResult…]}   (one per op, same order)
GET  /api/memory?since=S&limit=L             → 200 {"memories":[Memory…]}    (seq > S, ascending, ≤ min(L,500))
POST /api/skills/batch        {"ops":[Op…]}  → 200 {"results":[OpResult…]}
GET  /api/skills?since=S&limit=L             → 200 {"skills":[Skill…]}

Memory = {id, scope:"global|project|machine", project, machine, content, content_hash,
          confidence, source_agent, source_machine, created_at:<unix secs>, deleted:bool, seq}
Skill  = {scope:"global|project", project, name, version, files:{relpath: base64},
          content_hash, source_agent, source_machine, created_at:<unix secs>, deleted:bool, seq}

Memory ops: {"op":"add","memory":Memory} | {"op":"delete","id":"mem_…"}
Skill ops:  {"op":"push","skill":Skill,"base_version":N}
          | {"op":"delete","scope","project","name"}
          | {"op":"purge","scope","project","name","versions":[N…]|null}

OpResult = {ok, id?, canonical_id?, seq?, version?, superseded_concurrent?, error?}
Errors: 401 {"error":...} bad/missing session; 400 missing ?id or malformed body.
```

Memory `add` rules:
- Idempotent by `id`: if that id already exists (live or deleted), return that row's id and seq and don't change anything.
- Otherwise, if a live row has the same `(account, scope, project, machine, content_hash)`, return `canonical_id` equal to that row's id and don't insert.
- Otherwise insert with a new seq.

The client's `seq` and `deleted` fields are ignored on input.

## File Structure

| File | Responsibility |
|---|---|
| Create `relay-server/migrations/0002_knowledge.sql` | `knowledge_seq`, `memories`, `skill_versions`, indexes |
| Create `relay-server/src/knowledge_secrets.rs` | Port of atem `src/memory/secrets.rs` (verbatim) + `contains_reserved` |
| Create `relay-server/src/knowledge_store.rs` | `KnowledgeStore` trait, `InMemoryKnowledgeStore`, `PgKnowledgeStore` |
| Create `relay-server/src/knowledge_routes.rs` | The four handlers + route tests |
| Modify `relay-server/src/vault_routes.rs` | Make `Caller`, `resolve_caller`, `err` `pub(crate)` so both route modules share them (move no logic) |
| Modify `relay-server/src/main.rs` | `mod`s, `AppState.knowledge`, store selection (Pg when `DATABASE_URL`), routes with body limits, `/health` reports `knowledge_store` |
| Modify `docs/README.md` or relay README | One section describing the endpoints |
| Modify (atem) `src/memory/api.rs`, `src/memory/cmd.rs`, `src/memory/sync.rs`, `designs/atem-memory.md`, `AGENTS.md` | Session auth, skill chunk 8, messages, docs |

---

### Task 1: Migration + ported secret rules

**Files:**
- Create: `relay-server/migrations/0002_knowledge.sql`
- Create: `relay-server/src/knowledge_secrets.rs`
- Modify: `relay-server/src/main.rs` (add `mod knowledge_secrets;`)

**Interfaces:**
- Produces: `knowledge_secrets::{find_secrets(&str) -> Vec<SecretFinding>, check_bytes(&[u8]) -> Vec<SecretFinding>, mask(&str) -> String, contains_reserved(&str) -> bool, SecretFinding{kind, masked, line}}`.

- [ ] **Step 1: Migration**

```sql
-- Atem Memory: account-scoped memories + versioned skills (account = paired astation_id).
CREATE SEQUENCE IF NOT EXISTS knowledge_seq;

CREATE TABLE IF NOT EXISTS memories (
    id             TEXT PRIMARY KEY,
    account_id     TEXT NOT NULL,
    scope          TEXT NOT NULL,
    project        TEXT NOT NULL DEFAULT '',
    machine        TEXT NOT NULL DEFAULT '',
    content        TEXT NOT NULL,
    content_hash   TEXT NOT NULL,
    confidence     TEXT NOT NULL DEFAULT 'medium',
    source_agent   TEXT NOT NULL,
    source_machine TEXT NOT NULL,
    created_at     BIGINT NOT NULL,
    deleted        BOOLEAN NOT NULL DEFAULT false,
    seq            BIGINT NOT NULL DEFAULT nextval('knowledge_seq')
);
CREATE INDEX IF NOT EXISTS memories_account_seq ON memories (account_id, seq);
CREATE UNIQUE INDEX IF NOT EXISTS memories_dedup ON memories
    (account_id, scope, project, machine, content_hash) WHERE NOT deleted;

CREATE TABLE IF NOT EXISTS skill_versions (
    account_id     TEXT NOT NULL,
    scope          TEXT NOT NULL,
    project        TEXT NOT NULL DEFAULT '',
    name           TEXT NOT NULL,
    version        BIGINT NOT NULL,
    files          JSONB NOT NULL,
    content_hash   TEXT NOT NULL,
    source_agent   TEXT NOT NULL,
    source_machine TEXT NOT NULL,
    created_at     BIGINT NOT NULL,
    deleted        BOOLEAN NOT NULL DEFAULT false,
    seq            BIGINT NOT NULL DEFAULT nextval('knowledge_seq'),
    PRIMARY KEY (account_id, scope, project, name, version)
);
CREATE INDEX IF NOT EXISTS skill_versions_account_seq ON skill_versions (account_id, seq);
```
(`created_at` is stored as unix seconds `BIGINT` so it round-trips the wire value exactly; `deleted` is a boolean — simpler than the spec's `deleted_at` and equivalent on the wire.)

- [ ] **Step 2: Port the secret rules**

Copy `/home/guohai/Dev/Agora.Build/Atem/src/memory/secrets.rs` into `relay-server/src/knowledge_secrets.rs` **verbatim, including its tests**. Change only import paths if needed. Add `pub const RESERVED: &str = "atem:memory:";` and `pub fn contains_reserved(s: &str) -> bool { s.contains(RESERVED) }` with a test.

- [ ] **Step 3: Verify and commit**

Run `cd relay-server && cargo test knowledge_secrets`; every ported test must pass. Then `cargo build`.
Commit: `feat(relay): knowledge migration + ported secret rules`.

---

### Task 2: `KnowledgeStore` (in-memory + Postgres)

**Files:**
- Create: `relay-server/src/knowledge_store.rs`
- Modify: `relay-server/src/main.rs` (`mod knowledge_store;`)

**Interfaces:**
- Consumes: nothing from Task 1 (the store assumes callers already ran the secret checks).
- Produces:
  - `MemoryRow` and `SkillRow`: serde structs matching the wire `Memory`/`Skill` (`files` is `serde_json::Value`, an object of base64 strings, and is passed through untouched).
  - `KnowledgeError`.
  - `#[async_trait] pub trait KnowledgeStore: Send + Sync` with:
    - `backend_name(&self) -> &'static str`
    - `health_check`
    - `add_memory(&self, account: &str, m: MemoryRow) -> Result<MemoryAddOutcome, KnowledgeError>`, where `MemoryAddOutcome { id, canonical_id: Option<String>, seq }`
    - `delete_memory(account, id) -> Result<i64 /*seq, 0 if unknown*/>`
    - `pull_memories(account, since, limit) -> Result<Vec<MemoryRow>>`
    - `push_skill(account, s: SkillRow, base_version) -> Result<SkillPushOutcome { version, seq, superseded_concurrent }>`
    - `delete_skill(account, scope, project, name) -> Result<SkillPushOutcome>`
    - `purge_skill(account, scope, project, name, versions: Option<Vec<i64>>) -> Result<u64 /*rows*/>`
    - `pull_skills(account, since, limit) -> Result<Vec<SkillRow>>`
  - `InMemoryKnowledgeStore`, and `PgKnowledgeStore::new(PgPool)`.

Semantics, which both implementations must follow exactly:
- **`add_memory`:**
  - If the `id` exists for this account, return its id and seq with no change.
  - Otherwise, if a live row matches the dedup key, return `canonical_id = that id` and its seq, with no insert.
  - Otherwise, insert with `deleted=false` and a fresh seq.
  - An `id` that exists under a **different** account is an error ("id conflict"), never a cross-account read.
- **`delete_memory`:** if the row exists for this account, set `content=''`, `content_hash=''`, `deleted=true`, a new seq, and return that seq. If it's unknown, return `Ok(0)`, which is idempotent.
- **`push_skill`:**
  - `cur = max(version)` for the key (0 if none), and `cur_live = max(version) where not deleted`.
  - Insert `version = cur + 1` with the given files and hash, `deleted=false`, and a fresh seq.
  - `superseded_concurrent = base_version < cur_live`.
- **`delete_skill`:** append `version = cur + 1` with `files={}`, `content_hash=''`, `deleted=true`. Deleting an unknown skill is ok and appends nothing: return `version: 0, seq: 0`.
- **`purge_skill`:** for the matching versions (all when `None`), set `files={}`, `content_hash=''`, `deleted=true`, and a new seq on each row.
- **Pulls:** rows with `seq > since`, ascending by seq, `LIMIT min(limit, 500)`. Pulls include tombstones.
- **Postgres:** use one transaction per write, and `SELECT … FOR UPDATE` on the skill key when computing `cur`, so concurrent pushes can't produce the same version. On insert, dedup races surface as a unique violation on `memories_dedup`; handle one by re-reading and returning `canonical_id`.

- [ ] **Step 1: Write the failing tests (in-memory)**

`add_is_idempotent_by_id`, `add_dedups_to_canonical_id`, `add_after_delete_of_same_content_inserts`, `id_owned_by_other_account_is_rejected`, `delete_blanks_and_is_idempotent`, `pull_is_account_scoped_and_ordered`, `pull_respects_since_and_limit_cap`, `push_skill_appends_versions_and_flags_supersede`, `delete_skill_appends_tombstone`, `purge_selected_and_all_versions`, `seq_is_global_and_monotonic`.

- [ ] **Step 2: Implement `InMemoryKnowledgeStore`** until they pass.

- [ ] **Step 3: Implement `PgKnowledgeStore`**, and add Postgres tests marked `#[ignore]`: the same scenarios against a real DB, reading `KNOWLEDGE_TEST_DATABASE_URL` and dropping and recreating the tables at start. If `docker` is available, run them against a throwaway `postgres:16` container (`docker run --rm -d -e POSTGRES_PASSWORD=pw -p 55432:5432 postgres:16`, then run the migrations with `sqlx::migrate!`). Record the result either way. If docker isn't available, report that the Postgres path was build-checked only.

- [ ] **Step 4: Commit** `feat(relay): KnowledgeStore (in-memory + Postgres)`.

---

### Task 3: Routes, wiring, body limits

**Files:**
- Create: `relay-server/src/knowledge_routes.rs`
- Modify: `relay-server/src/vault_routes.rs` (make `err`, `Caller`, `resolve_caller`, and the query struct `pub(crate)`. If needed, add a small `pub(crate) struct AuthQuery { id: Option<String> }` so knowledge routes don't depend on the vault's query shape)
- Modify: `relay-server/src/main.rs` (`mod knowledge_routes;`, `AppState.knowledge: Arc<dyn KnowledgeStore>` built next to `vault` from the same `DATABASE_URL` pool, routes, `/health` JSON adds `"knowledge_store"`, and every `AppState { … }` literal in tests gains `knowledge`)

**Interfaces:**
- Consumes: `knowledge_store::*`, `knowledge_secrets::{find_secrets, check_bytes, contains_reserved}`, and the vault's `resolve_caller`.

Handler behavior:
- Every handler calls `resolve_caller` first (401 on a missing or invalid session, 400 on missing `?id`). The account is `caller.work_session_id`.
- **`POST /api/memory/batch`** — `{"ops":[…]}`. For each op in order:
  - **`add`:** if `contains_reserved(content)`, the result is `{ok:false, error:"reserved token"}`. If `find_secrets(content)` is non-empty, the result is `{ok:false, error:"possible credential: <kind>"}`. Otherwise call `store.add_memory` and return `{ok:true, id, canonical_id?, seq}`.
  - **`delete`:** call `delete_memory` and return `{ok:true, id, seq}`.
  - **Unknown `op`:** `{ok:false, error:"unknown op"}`.
  - A store error on one op gives `{ok:false, error}` for that op, and processing continues.
  - Returns 200 `{"results":[…]}`.
- **`POST /api/skills/batch`** —
  - **`push`:** base64-decode every file value. A decode failure gives `{ok:false, error:"invalid base64"}`. Run `check_bytes` on every decoded file and `contains_reserved` on UTF-8 files. Any finding gives `{ok:false, error:"possible credential: <path>: <kind>"}` and nothing is stored. Otherwise call `push_skill` and return `{ok:true, version, seq, superseded_concurrent}`.
  - **`delete`:** call `delete_skill` and return `{ok:true, version, seq}`.
  - **`purge`:** call `purge_skill` and return `{ok:true}`.
- **`GET /api/memory` and `GET /api/skills`:** query `since` (default 0) and `limit` (default 200, capped at 500). Returns `{"memories":[…]}` or `{"skills":[…]}`.
- **Body limits:** `DefaultBodyLimit::max(2 * 1024 * 1024)` on the memory batch route and `max(16 * 1024 * 1024)` on the skills batch route. Apply them per route with `.layer(...)` on the method router.
- Routes go under the same rate-limit layer group as `/api/vault`.

- [ ] **Step 1: Write the failing route tests.** Reuse the vault test helper pattern (a granted session bound to an astation_id, and in-memory stores):
  - `memory_batch_requires_session` (401)
  - `memory_batch_requires_client_id` (400)
  - `add_then_pull_round_trips_wire_shape`: POST the exact JSON atem sends (a full Memory object), then GET, and assert that every field is echoed and `seq > 0`.
  - `add_with_credential_is_refused_per_op`: batch of [good, `sk-…` secret, good] gives [ok, not ok, ok], and the secret isn't in a later pull.
  - `add_with_reserved_token_refused`
  - `dedup_returns_canonical_id`
  - `delete_is_idempotent`
  - `accounts_are_isolated`: two sessions bound to different astation_ids can't see each other's memories or skills.
  - `skill_push_pull_and_supersede`
  - `skill_with_secret_file_refused`: base64 of a file containing `AKIAIOSFODNN7EXAMPLE`.
  - `skill_purge_all`
  - `oversized_skills_body_is_rejected` (413 when the body is over 16 MB)
- [ ] **Step 2: Implement** until all pass. Then run `cargo test` for the whole relay-server crate and `cargo build --release`.
- [ ] **Step 3: Docs.** Add a short "Knowledge sync (Atem Memory)" section to `relay-server/README.md` covering the endpoints, session auth, the account = astation_id rule, the secret checks, and body limits.
- [ ] **Step 4: Commit** `feat(relay): /api/memory + /api/skills (session auth, account = astation)`.

---

### Task 4: atem — authenticate with the pairing session

Repo: `/home/guohai/Dev/Agora.Build/Atem` (a new branch `feat/memory-pairing-auth` off `main`).

**Files:**
- Modify: `src/memory/api.rs`
- Modify: `src/memory/cmd.rs`
- Modify: `src/memory/sync.rs`
- Modify: `designs/atem-memory.md` (§Identity & auth)
- Modify: `AGENTS.md` (the Atem Memory paragraph)

Changes:
- **`api.rs`:**
  - `KnowledgeClient::new(base, client_id, session_id)` sends `Authorization: session <session_id>` in place of the Bearer header.
  - Keep a `#[cfg(test)]`-free doc comment explaining that the pairing session is the account key.
  - Update the header test if one exists, or add `sends_session_authorization` by extracting a pure `fn auth_header(session_id: &str) -> String`.
- **`cmd.rs`:**
  - `client()` resolves the relay base and session exactly as `handle_vault_command` does in `src/cli.rs`: `AtemConfig::load()?.astation_relay_url()`, `config.astation_relay_code` (the Astation id), and `crate::auth::SessionManager::load()?.get(&astation_id).map(|s| s.session_id)`. Put this in one helper, `fn relay_session(config) -> Result<(String /*base*/, String /*session_id*/), SessionProblem>`.
  - `SessionProblem` has two variants: `NotConfigured` (no `astation_relay_code`) and `NotPaired` (no session).
  - The sync status line gives specific guidance:
    - NotConfigured: "No Astation configured — set astation_relay_code (or ASTATION_RELAY_CODE); changes stay queued."
    - NotPaired: "Not paired with your Astation — run `atem pair`; changes stay queued."
    - Offline stays as it is today.
  - Remove the SSO-token dependency from `client()`.
  - **Pairing gate:** replace `require_login()` with `require_pairing()`. It runs first in `handle_sync`, `handle_memory`, and `handle_skill`, and it's a local check with no network: `relay_session()` must return a session. On `NotConfigured` or `NotPaired`, fail with "Atem Memory works only on machines paired with your Astation. Run `atem pair` (Astation approves this machine), then retry." Local commands (`add`, `list`, `search`, `rm`, `apply`, `status`) are gated too.
  - Once a session exists, `client()` uses it. The gate and the client share `relay_session()`.
  - Update the existing `sync_status_line` tests, and add a test for the gate message on the pure helper.
- **`sync.rs`:** push skill ops in chunks of **8**. Memory ops keep chunks of 50. Use two constants, `MEMORY_PUSH_CHUNK` and `SKILL_PUSH_CHUNK`.
- **Docs:**
  - Spec §Identity & auth now reads:
    - **Astation is the control plane.** Atem Memory works only on machines paired with, and approved by, your Astation.
    - The account is the paired Astation. Every machine paired with the same Astation shares memory and skills.
    - Pair once per machine with `atem pair`. Sessions renew on use and expire after 7 days idle. An unpaired or expired machine can't read, write, or sync.
    - Login-based accounts are a possible future follow-up.
    - Also update the spec's CLI section: "Every command refuses to run without `atem login`" becomes "…without an active Astation pairing".
  - AGENTS.md: change "SSO bearer auth" to "Astation pairing-session auth".

- [ ] Steps: TDD the pure helpers (`auth_header`, the status-line variants, the chunk constants). Run `cargo test memory::` and the full `cargo test` (the known `agent_visualize` flake passes with `--test-threads=1`), then `cargo build`. Commit `feat(memory): sync with the Astation pairing session`.

---

## Deployment (controller, after review)

1. Astation: open a PR from `feat/knowledge-sync` and squash-merge it to `main`. `.github/workflows/deploy-station.yml` builds GHCR images and deploys the relay and webapp to Coolify. Watch the run to completion.
2. Verify production:
   - `GET https://station.agora.build/health` returns `knowledge_store: "postgres"`.
   - `POST /api/memory/batch` with no session returns 401.
3. Atem: open a PR from `feat/memory-pairing-auth` and squash-merge it.
4. End-to-end, if a paired session exists on this machine:
   - `atem memory add` a test fact, then `atem sync`.
   - A second isolated HOME using the same pairing session pulls it, which proves cross-machine sync through production.
   - Purge the test memory afterwards.
