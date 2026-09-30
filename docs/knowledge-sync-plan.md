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
- Per-request body limits: `/api/memory/batch` 2 MB; `/api/skills/batch` 16 MB (production nginx matches these per location). Op caps: 64 memory ops, 16 skill ops (413 `too many ops`). The atem client sends at most 50 memory ops and 8 skill ops per request.
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
  - **Unknown `op`:** ~~`{ok:false, error:"unknown op"}`~~ — superseded by the final-review fix wave: a malformed body or unknown op is 400 for the whole batch (ops are typed), see `relay-server/README.md`.
  - ~~A store error on one op gives `{ok:false, error}` for that op, and processing continues.~~ Superseded: a store (DB) error stops the batch with 503 `{"error":"temporarily unavailable"}`; atem keeps the ops queued.
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

---

### Task 5: atem — explicit capability tiers (centralized gates)

Repo: `/home/guohai/Dev/Agora.Build/Atem`, same branch `feat/memory-pairing-auth`.

Product rule (user, 2026-09-29):
- **Tier 1 — `atem login`:** a limited set of functions.
- **Tier 2 — paired with Astation:** the full set. Astation is the control plane.

**Files:**
- Modify: `src/auth.rs`
- Modify: `src/memory/cmd.rs`
- Modify: `src/cli.rs` (the vault handler and the project commands)
- Modify: `AGENTS.md`

**Interfaces (produce in `src/auth.rs`):**
- `pub enum PairingProblem { NotConfigured, NotPaired }`
- `pub struct PairedSession { pub relay_base: String, pub astation_id: String, pub session_id: String }`
- `pub fn pairing_from(relay_base: &str, astation_id: Option<&str>, session_id: Option<String>) -> Result<PairedSession, PairingProblem>`: pure and unit-tested.
- `pub fn pairing_session() -> Result<PairedSession, PairingProblem>`: loads `AtemConfig` and `SessionManager` the way `handle_vault_command` does. A config or session load failure maps to `NotConfigured` or `NotPaired` respectively.
- `pub fn pairing_gate_message(feature: &str) -> String` = `format!("{feature} works only on machines paired with your Astation. Run `atem pair` (Astation approves this machine), then retry.")`
- `pub fn require_pairing(feature: &str) -> anyhow::Result<PairedSession>`: the tier-2 gate. It's a local check with no network.
- `pub fn login_gate_message(feature: &str) -> String` = `format!("{feature} requires `atem login` (your Agora account).")`
- `pub fn require_login(feature: &str) -> anyhow::Result<()>`: the tier-1 gate. It's local and passes when `CredentialStore::load().entries` is non-empty.

**Changes:**
- **`src/memory/cmd.rs`:**
  - Delete the local `relay_session`, `SessionProblem`, `require_pairing`, and `PAIRING_GATE_MSG`. Use `crate::auth::require_pairing("Atem Memory")` and `pairing_session()` instead.
  - The memory gate text must stay byte-identical to today's: "Atem Memory works only on machines paired with your Astation. Run `atem pair` (Astation approves this machine), then retry."
  - Status lines keep their current texts, mapped from `PairingProblem`.
- **`src/cli.rs` vault handler:** replace its ad-hoc session resolution with `crate::auth::require_pairing("Atem Vault")`, and use the returned `relay_base` and `session_id`. The old "No Astation session found…" error goes away; behavior is otherwise identical.
- **`src/cli.rs` project commands** (the `atem project …` handlers that call `valid_token`): call `crate::auth::require_login("atem project")` first so the message is consistent. Leave `atem token` and `atem serv …` ungated; they work with environment variables or a cached project.
- **`AGENTS.md`:** add a "Capability tiers" subsection with this table:

  | Tier | Needs | Commands |
  |---|---|---|
  | 0 | — | serv files, config, token with AGORA_APP_ID/CERT env |
  | 1 | `atem login` | project, token (active project), serv rtc/convo/webhooks |
  | 2 | paired with Astation | vault, sync, memory, skill, and Astation-driven remote agent control, voice coding, mark tasks, visualize |

  Add one line: "New cross-machine or cross-agent features are tier 2 and must gate with `auth::require_pairing`."

**Tests:**
- `pairing_from`: all three outcomes.
- The exact texts of `pairing_gate_message("Atem Memory")` and `login_gate_message("atem project")`.
- Existing memory tests pass unchanged.
- Run `cargo test` (the `agent_visualize` flake passes with `--test-threads=1`) and `cargo build`.

**Commit:** `refactor(auth): explicit capability tiers — shared pairing/login gates`

---

## Extension: Astation proof-of-possession + durable pairing (Tasks 6–9)

Decided with the user on 2026-09-29:
- **Astation proves its identity to the relay with a P-256 key.**
- **First key registration is trust-on-first-use.** A lost or replaced Mac needs an admin reset.
- **Only verified Astations can grant vault and memory access.** Old Astation versions keep relaying chat and remote control, but they must update to use vault or memory.
- **Pairing bindings are durable** and pushed by the verified Astation.

This fixes `relay-server/SECURITY.md` blocker #1, relay restarts losing bindings, local-only pairings never getting bound, and revocation.

### Protocol (exact; relay, Astation, and docs must match)

**Relay → Astation.** Sent raw, right after an `role=astation` socket opens. Old Astation versions ignore it, because they drop frames without `atem_id`/`connection_id`:
```json
{"type":"relayAuthChallenge","protocol":"relay-auth-1","challenge":"<64 lowercase hex>"}
```

**Astation → relay** (the relay intercepts these; they are never forwarded to Atems):
```json
{"type":"relayAuth","astation_id":"<room code>","public_key":"<hex, P-256 X9.63 uncompressed, 65 bytes>","signature":"<hex, DER ECDSA over SHA-256>"}
```
The signed message is the UTF-8 string `station-relay-auth-v1\n<challenge>\n<astation_id>`.

**Relay → Astation:**
```json
{"type":"relayAuthResult","status":"registered|verified|rejected","message":"<text>"}
```

**Only after `registered` or `verified`,** Astation → relay (also intercepted):
```json
{"type":"relaySessions","sessions":["<session_id>", …]}
{"type":"relayBind","session_id":"<id>"}
{"type":"relayUnbind","session_id":"<id>"}
```
- `relaySessions` is a full resync, sent after every successful verification. The relay sets this Astation's bindings to exactly the listed set.
- `relayBind` is sent when a session is granted.
- `relayUnbind` is sent when a session is deleted or expires.
- The relay replies with `{"type":"relayAck","for":"relaySessions|relayBind|relayUnbind","ok":true}`, or `ok:false` with a `message`.

**Relay rules:**
- The challenge must be answered within 10 s. A wrong or missing proof gets `rejected`, and the socket closes.
- Verification uses `ring` ECDSA_P256_SHA256_ASN1 with `UnparsedPublicKey`. Add `ring` as a direct dependency; it is already in `Cargo.lock` via rustls.
- **No key registered** for the `astation_id`:
  - A valid proof registers the key (TOFU, via an atomic `INSERT … ON CONFLICT DO NOTHING` followed by re-reading and comparing), and the result is `registered`.
  - An Astation that never answers stays in **legacy mode**. It can relay as it does today, but it can never create bindings.
- **Key registered:**
  - A proof must use that exact key.
  - A new `role=astation` connection is **pending** and must not replace the room's current `astation_tx` until it verifies. A pending connection that doesn't verify within 10 s is closed. Legacy takeover is impossible once a key exists.
- **Bindings** are stored in Postgres and are the **only** authorization source for `resolve_caller`:
  - Passive observation of auth traffic no longer creates bindings.
  - The `SessionVerifyCache` is no longer consulted for authorization.
- **Sliding expiry:** a binding is valid while `now - last_used_at < 7 days`. `resolve_caller` touches `last_used_at` at most once per hour per session.
- An `unbind`, or a resync that omits a session, removes the binding immediately.
- **Admin reset** (document it in `DEPLOY.md`): `DELETE FROM astation_keys WHERE astation_id = '<id>';` (bindings stay). The next verified connect registers the new key.
- Every log line masks room codes and session IDs.

### Task 6: Relay identity store + migration

**Files:**
- Create: `relay-server/migrations/0003_astation_identity.sql`
- Create: `relay-server/src/identity_store.rs`
- Modify: `relay-server/src/main.rs` (`AppState.identity`, built from the same `DATABASE_URL` pool; in-memory otherwise)

**Migration:**
```sql
CREATE TABLE IF NOT EXISTS astation_keys (
    astation_id      TEXT PRIMARY KEY,
    public_key       TEXT NOT NULL,           -- hex, P-256 X9.63 uncompressed
    registered_at    BIGINT NOT NULL,
    last_verified_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS session_bindings (
    session_id   TEXT PRIMARY KEY,
    astation_id  TEXT NOT NULL,
    created_at   BIGINT NOT NULL,
    last_used_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS session_bindings_by_astation ON session_bindings (astation_id);
```

**`IdentityStore` trait** (in-memory and Postgres, same semantics):
- `get_key(astation_id) -> Option<String>`
- `register_key_if_absent(astation_id, pubkey_hex, now) -> RegisterOutcome { Registered, Existing(String) }`
- `touch_key(astation_id, now)`
- `bind(session_id, astation_id, now)`: upsert. A session already bound to a different Astation is **re-bound** only when the caller is that session's current owner; otherwise it's rejected.
- `unbind(session_id, astation_id)`: only removes it if owned by `astation_id`.
- `replace_all(astation_id, sessions, now)`: in one transaction, delete every binding of this Astation not in `sessions`, then upsert the listed ones. A listed session owned by another Astation is skipped.
- `resolve(session_id, now) -> Option<String>`: `None` if missing or expired; touches `last_used_at` if it's more than an hour old.

**Tests:** in-memory and Postgres (ignored, docker) covering TOFU (first wins, second with a different key sees `Existing`), bind/unbind ownership, resync removal, sliding expiry, and the touch throttle.

### Task 7: Relay protocol in `relay.rs` + `resolve_caller`

**Files:**
- Modify: `relay-server/src/relay.rs`
- Modify: `relay-server/src/vault_routes.rs` (`resolve_caller` resolves only via `state.identity.resolve`)
- Modify: `relay-server/src/main.rs`
- Modify: `relay-server/SECURITY.md` (mark blocker #1 addressed and describe TOFU and legacy mode)
- Modify: `DEPLOY.md` (admin reset; rollout: deploy the relay, then ship the Astation update; vault and memory need the updated Astation)
- Modify: `relay-server/README.md`

Implement the protocol above: challenge on open, intercept the Astation control messages (never broadcast them), pending-connection handling for registered ids, the 10 s timeout, and binding messages that are accepted only from a verified connection.

- Remove bindings from passive observation. Logging of auth attempts can stay, masked.
- Keep the deploy check working. `.github/scripts/verify-station.mjs` opens `role=astation` with a random code and closes; that must still open, so the challenge is in-band.

**Tests** (tokio-tungstenite, as the existing relay tests do):
- an old-style Astation that never answers still relays but creates no bindings;
- a valid proof registers the key;
- a wrong key for a registered id is rejected and closed, and doesn't take over the room;
- a pending connection times out;
- control messages aren't forwarded to Atems;
- `relaySessions`, `relayBind`, and `relayUnbind` drive `resolve_caller`;
- vault and knowledge routes return 401 without a binding and 200 with one;
- bindings survive a new `AppState` backed by the same Postgres (ignored Postgres test).

### Task 8: Astation (Swift) — identity key + relay protocol

**Files:**
- Create: `Sources/Menubar/RelayIdentityKey.swift`
- Modify: `Sources/Menubar/AstationHubManager.swift`
- Create: tests in `Tests/AstationTests/RelayIdentityTests.swift`
- Modify: `.github/workflows/ci.yml` (add `swift test --filter RelayIdentityTests` after the Swift build)

**`RelayIdentityKey`:**
- Load or create the key.
- Prefer `SecureEnclave.P256.Signing.PrivateKey` when `SecureEnclave.isAvailable`. Persist its `dataRepresentation` in the Keychain as a generic password, service `build.agora.astation.relay-identity`, account `astation-relay-key-v1`.
- Otherwise use `P256.Signing.PrivateKey`, persisting its `rawRepresentation` the same way.
- `publicKeyHex` returns `x963Representation` as lowercase hex.
- `sign(challenge:astationId:)` returns the DER signature hex over `station-relay-auth-v1\n<challenge>\n<astationId>`.
- A pure `static func signingMessage(challenge:astationId:) -> String` for tests.

**Hub manager, on the relay identity socket:**
- Handle raw frames whose `type` is `relayAuthChallenge` by sending `relayAuth`.
- On `relayAuthResult` `registered` or `verified`, send `relaySessions` with the IDs from `SessionStore.getAllActive()`.
- When a session is granted (any path, including local and LAN), send `relayBind` if the relay socket is verified.
- When a session is deleted or expires in `SessionStore`, send `relayUnbind`.
- On `rejected`, log it and surface it in the menu status: "Relay rejected this Astation's key".

**Tests:** the signing-message format; a sign → verify round trip with a software key; the JSON builders for the four outbound messages; hex encoding.

**Can't compile here:** this machine has no Swift toolchain. Verify through the PR's macOS CI (`swift build` plus the new `swift test` step), and do a final manual check on the user's Mac.

### Task 9: atem — messages + docs

**Repo:** Atem, branch `feat/memory-pairing-auth`.

- Update the 401 note: "The relay doesn't recognize this machine's Astation session. Make sure your Astation (latest version) is running and connected to the relay, then sync again. Changes stay queued."
- Update `designs/atem-memory.md` §Identity & auth:
  - pairing bindings are durable and survive relay restarts;
  - they are pushed by the verified Astation (including local-only pairings) and revoked when Astation removes the session;
  - they need an Astation version with relay identity.
- Remove the "reconnect after restart" caveat.
- Test the note text.
