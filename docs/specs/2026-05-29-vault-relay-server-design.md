# Vault — relay-server side (Postgres + `/api/vault`)

Status: spec — 2026-05-29
Scope: **Astation relay-server only.** This is the server half of the "vault"
feature. The atem-side CLI (`atem vault …`) is already merged (Atem repo PR #10)
and calls the endpoints defined here.

> This spec is self-contained — you do not need the Atem repo to start. The
> atem-side counterpart is `Atem/designs/vault.md` (data model + auth model) and
> `Atem/designs/vault-implementation-plan.md` (the client). This doc restates
> everything the relay-server needs and is the authoritative server contract.

## What we're building

A **vault** is a small, durable, append-only, shared context store. Multiple
atems (each driving its own coding agent) read/write a common vault so agents
working toward one goal hand off notes/decisions without a human copy-pasting
between terminals.

The relay-server (this repo) hosts vaults over HTTP, backed by **Postgres**, and
enforces access control. atems are the only clients — agents never talk to the
vault directly.

The atem CLI already shipped and issues exactly these calls (so the contract is
fixed):

```
Auth header (all requests):  Authorization: session <session_id>
Query (all requests):        ?id=<client_id>            (atem instance_id)

POST /api/vault                 {summary}                       -> {vault_id}
GET  /api/vault                                                 -> [{vault_id, summary}]
GET  /api/vault/<id>            [?since=<seq>&history=true]      -> [VaultEntry]
POST /api/vault/<id>           {text, entry_id?}                -> {entry_no, version, seq}
POST /api/vault/<id>/summary   {text}                           -> {} (200 OK)

VaultEntry = {seq, entry_no, version, kind, writer_id, content, created_at}
```

(The atem client types live in `Atem/src/vault_client.rs` — `VaultEntry`,
`CreatedVault {vault_id}`, `VaultListItem {vault_id, summary}`,
`WriteResult {entry_no, version, seq}`. Match these field names exactly or the
client's deserialization breaks.)

## Why this is non-trivial here

The relay-server today is **fully in-memory** — every store is
`RwLock<HashMap<…>>` (`SessionStore`, `RelayHub`, `RtcSessionStore`,
`SessionVerifyCache`, `VoiceSessionStore`; see `src/main.rs:25-33`). `Cargo.toml`
has **no database crate**. Vault content must survive restarts and be readable by
an atem that was offline when it was written, so the vault is the **first
persistent store** in this service. That is the bulk of the new work: add
Postgres, a migration, a connection pool in `AppState`, and a `vault_routes.rs`
module following the existing route conventions.

## Data model (Postgres)

Two tables. `vaults` holds mutable per-vault metadata plus a denormalized
`writer_list` for fast authz. `vault_entries` is append-only and versioned.

```sql
CREATE TABLE vaults (
    vault_id        TEXT PRIMARY KEY,         -- short, URL-safe, e.g. "v-7Kf3qD"
    summary         TEXT NOT NULL DEFAULT '', -- mutable description
    work_session_id TEXT NOT NULL,            -- the work session this vault belongs to (see Auth)
    created_by      TEXT NOT NULL,            -- client_id of creator
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    writer_list     TEXT[] NOT NULL DEFAULT '{}',  -- denormalized content-writer client_ids
    next_entry_no   INT    NOT NULL DEFAULT 1      -- per-vault entry-number allocator
);

CREATE TABLE vault_entries (
    seq        BIGSERIAL PRIMARY KEY,         -- global write order (also the --since cursor)
    vault_id   TEXT NOT NULL REFERENCES vaults(vault_id),
    entry_no   INT  NOT NULL,                 -- per-vault: 1,2,3 -> shown as e1, e2, e3
    version    INT  NOT NULL,                 -- per-entry: 1,2,3 -> shown as v1, v2, v3
    kind       TEXT NOT NULL,                 -- 'content' | 'summary'
    writer_id  TEXT NOT NULL,                 -- client_id that wrote this row
    content    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (vault_id, entry_no, version)
);

CREATE INDEX vault_entries_by_vault_seq ON vault_entries (vault_id, seq);
```

### Append vs. override (no separate "override" kind)

- **Append** (`POST /api/vault/<id>` with `{text}`, no `entry_id`): allocate
  `entry_no = vaults.next_entry_no` then `next_entry_no += 1`; insert with
  `version = 1`.
- **Override / edit** (`POST /api/vault/<id>` with `{text, entry_id: N}`): keep
  `entry_no = N`; insert with `version = max(version where entry_no = N) + 1`.

Append-vs-override is fully derivable from `version` (v1 = first write, v2+ =
edit), so there is **no** `override` kind. `kind ∈ {content, summary}` only.
Both operations must be transactional (allocate `entry_no`/compute `version` and
insert inside one transaction) so concurrent writers can't collide on
`(vault_id, entry_no, version)`.

### Render semantics (drives the read queries)

- **Current view** (`GET /api/vault/<id>` with no `history`): for each
  `entry_no`, return only the row with the **highest `version`**, ordered by
  `entry_no` ascending. SQL: `DISTINCT ON (entry_no) … ORDER BY entry_no,
  version DESC` (or a window function).
- **History** (`?history=true`): return **every** row ordered by `seq` ascending.
- **Incremental** (`?since=<seq>`): only rows with `seq > <since>`. Combine with
  the above (history-since, or current-view filtered — for v1, `since` applies to
  the history query; the client uses it for the `watch` cursor).

The atem client renders these; the server just returns the rows as JSON arrays
of `VaultEntry`.

## Auth & work-session resolution

This is the **one real design decision** for the server. Everything above is
fixed by the client contract; this part depends on how relay sessions bind to a
"work session."

Two tokens arrive on every request:

| Token | Source | Role |
|-------|--------|------|
| `session_id` (in `Authorization: session <id>`) | the atem↔Astation session | **authenticates** — proves the caller is a real, granted atem, and resolves its `work_session_id` |
| `client_id` (in `?id=<id>`) | the atem's persistent `instance_id` (UUID) | **authorizes** — checked against the vault's `writer_list` |

Authorization predicates (enforce server-side):

```
can_read(vault, caller):
    caller.work_session_id == vault.work_session_id    -- in the same work session
    OR caller.client_id = ANY(vault.writer_list)       -- past content-writer

can_write(vault, caller):                              -- append / override content
    caller.work_session_id == vault.work_session_id    -- in-session only
```

- In-session atems get full read + write.
- Out-of-session atems get **read-only**, and only if their `client_id` is in
  `writer_list` (they contributed earlier, in a prior session).
- `set-summary` uses the **read** predicate (summary is mutable + low-stakes; any
  atem that can see the vault may update it).
- `writer_list` is appended (`client_id`, dedup) only on **content writes**
  (append/override), not on reads or set-summary.

### Resolving `work_session_id` — pick one (recommended: A)

The "work session" is the set of atems collaborating with one Astation. In the
relay's room model that is the room keyed by the astation_id (`code`), where
multiple atems share one room (`PairRoom.atem_txs` is keyed by atem_id;
`src/relay.rs:30-39`). So **`work_session_id` should resolve to the astation_id
the session is bound to**, NOT to `session-{session_id}` (that would isolate each
atem in its own room and break sharing).

- **Option A (recommended): bind sessions to an astation_id, use that.**
  Persist the astation_id on the relay `Session` when it's granted (today
  `Session` stores `hostname` but not astation_id; `src/auth.rs:15-24`). Vault
  auth looks up the session, reads its astation_id, and uses it as
  `work_session_id`. Clean, no extra params, matches the room model. Requires a
  small change to session creation/grant to capture astation_id.

- **Option B: caller passes the work session explicitly + server verifies.**
  Add `?work_session=<astation_id>` to vault requests and verify the session is
  authorized for it (via `SessionVerifyCache`, `src/session_verify.rs`, which
  already verifies sessions against Astation). No `Session` schema change, but it
  adds a param the atem client does **not** send today — so it needs an atem-side
  change too. Avoid unless A is infeasible.

- **Option C (interim/testing only): `work_session_id = session_id`.**
  Trivial, but each atem is its own work session → no cross-atem sharing. Only
  acceptable as a first vertical slice to exercise the CRUD before wiring real
  session→astation binding. Do not ship as the final behavior.

**Session validation itself** reuses the existing machinery: validate the
`session_id` the same way the WS `?session=` path does (`src/relay.rs:227-261` —
session must exist and be `Granted`), and/or `SessionVerifyCache`
(`src/session_verify.rs`) for cross-service verification. Return **401** for a
missing/invalid session, **403** when the session is valid but `can_read`/
`can_write` fails.

## `atem_id` sanitizer change (required for non-ASCII ids)

atem now generates ids that may contain non-ASCII (Chinese/Japanese/Korean
hostnames) and percent-encodes them into the relay URL. The current sanitizer
**strips non-ASCII and does not percent-decode** (`src/relay.rs:303-308`):

```rust
let atem_id = params.atem_id
    .as_deref()
    .map(|s| s.chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_' || *c == '.').collect::<String>())
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| format!("atem-{:x}", rand::thread_rng().gen::<u32>()));
```

Update it to **percent-decode first**, then keep non-ASCII while restricting
ASCII to `[A-Za-z0-9-]` (matching atem's own rule in
`Atem/designs/atem-identity.md`):

```rust
let decoded = urlencoding::decode(params.atem_id.as_deref().unwrap_or(""))
    .map(|c| c.into_owned())
    .unwrap_or_default();
let atem_id: String = decoded
    .chars()
    .filter(|c| !c.is_ascii() || c.is_ascii_alphanumeric() || *c == '-')
    .collect();
let atem_id = if atem_id.is_empty() {
    format!("atem-{:x}", rand::thread_rng().gen::<u32>())
} else {
    atem_id
};
```

(`urlencoding` is already a dependency. `is_alphanumeric()` previously also
allowed non-ASCII alphanumerics; the new filter is explicit about the rule.)

This is independent of the vault tables and can land as its own small commit.

## Implementation tasks

Follow the existing relay-server conventions: a `vault_routes.rs` module with
handlers returning `Result<Json<T>, (StatusCode, Json<ErrorResponse>)>` (see
`src/rtc_session.rs:432-449`), errors as `(StatusCode, Json(json!({"error": …})))`,
request types deriving `Deserialize, Validate`, inline `#[cfg(test)] mod tests`
with `#[tokio::test]` + `tower::ServiceExt::oneshot`.

### Task 1 — Add Postgres + a `VaultStore`
- `Cargo.toml`: add `sqlx = { version = "0.7", features = ["runtime-tokio", "postgres", "macros", "chrono", "uuid"] }` (sqlx fits the existing tokio/async style; alternatives `tokio-postgres` or `deadpool-postgres` are acceptable).
- Add a migration (`migrations/0001_vault.sql` with the two `CREATE TABLE`s above) and run it at startup (sqlx `migrate!`), or document `sqlx migrate run`.
- `src/vault_store.rs`: a `VaultStore { pool: sqlx::PgPool }` with methods:
  - `create_vault(work_session_id, created_by, summary) -> vault_id`
  - `list_readable(work_session_id, client_id) -> Vec<VaultListItem>`
  - `read(vault_id, since: Option<i64>, history: bool) -> Vec<VaultEntry>`
  - `append(vault_id, writer_id, text) -> WriteResult` (txn: allocate entry_no, version=1)
  - `override_entry(vault_id, entry_no, writer_id, text) -> WriteResult` (txn: version=max+1)
  - `set_summary(vault_id, text)`
  - `get_meta(vault_id) -> {work_session_id, writer_list}` (for authz)
  - `add_writer(vault_id, client_id)` (dedup; on content writes)
- Connection string from env (`DATABASE_URL`); document in README + `docker-compose`.

### Task 2 — Wire `VaultStore` into `AppState`
- `src/main.rs:25-33`: add `pub vault: VaultStore` to `AppState`.
- Build the pool in `main()` before constructing `AppState`; fail fast if
  `DATABASE_URL` is unset/unreachable.

### Task 3 — Session→work_session resolution (Option A)
- Extend the relay `Session` (`src/auth.rs:15-24`) + session create/grant to
  capture the astation_id the session is bound to.
- Add a helper `resolve_caller(headers, query) -> Result<Caller{work_session_id, client_id}, (StatusCode, …)>`
  that parses `Authorization: session <id>` + `?id=<client_id>`, validates the
  session (Granted), and returns the bound astation_id as `work_session_id`.
  401 on bad session.

### Task 4 — `vault_routes.rs` handlers + route wiring
- Implement the 5 endpoints exactly per the contract above, each calling
  `resolve_caller` then the `VaultStore`, enforcing `can_read`/`can_write`
  (403 on failure), and returning the documented JSON.
- `POST /api/vault/<id>`: branch on `entry_id` present → `override_entry` else
  `append`; then `add_writer`.
- Register routes in `main.rs` alongside the others (`main.rs:153-229`).

### Task 5 — `atem_id` sanitizer
- Apply the `src/relay.rs:303-308` change above. Add a unit test with a
  percent-encoded CJK `atem_id` asserting it round-trips (decoded, non-ASCII
  preserved).

### Task 6 — Tests
- Handler tests with `oneshot` for: create→read roundtrip, append then
  override (current view shows v2, history shows v1+v2), `--since` filtering,
  authz (in-session read+write; out-of-session past-writer read-only → 403 on
  write; stranger → 403 on read), set-summary.
- Store tests against a test Postgres. Options: `sqlx::test` fixtures, a
  testcontainers Postgres, or abstract `VaultStore` behind a trait with an
  in-memory impl for handler tests + a thin live-DB integration test. Pick one
  and note it; don't block all tests on a live DB.

### Task 7 — Notification (v1.5, optional in this pass)
- After a committed content write, broadcast `vault-updated {vault_id, seq}` to
  the relay room for that `work_session_id` (the room keyed by astation_id), so
  watching atems re-read. The relay already broadcasts Astation→all
  (`src/relay.rs:314-318`); reuse that path. The atem `watch` subscriber is a
  separate atem-side v1.5 task — server can land the broadcast now or defer.

## Acceptance test

1. `DATABASE_URL` set; migrations applied; relay-server running.
2. Two atems paired to the same Astation (same room/work session).
3. atem A: `atem vault new --summary "auth refactor"` → prints `v-XXXX`.
4. atem A: `atem vault write --vault-id v-XXXX --text "decided: JWT in cookie"`.
5. atem B: `atem vault read --vault-id v-XXXX` → sees the entry.
6. atem A: `atem vault write --vault-id v-XXXX --entry-id 1 --text "JWT, 15m exp"`.
7. atem B: `atem vault read --vault-id v-XXXX --history` → shows `e1 v1` + `e1 v2`.
8. An atem **not** in the work session and **not** in `writer_list` → `read`
   returns 403. An out-of-session past-writer → `read` OK, `write` → 403.

## Build / deploy

```bash
# relay-server dir
cargo build
cargo test          # see Task 6 re: DB-backed tests
DATABASE_URL=postgres://… cargo run
```

- Add a `postgres` service to `docker-compose.yml` / `docker-compose.dev.yml`
  and pass `DATABASE_URL` to the relay-server container.
- Document `DATABASE_URL` alongside the existing env vars (`CORS_ORIGIN`,
  `PORT`, `PUBLIC_BASE_URL`, …).

## Open questions

1. **Session→astation binding (Task 3).** Confirm the relay `Session` can carry
   the astation_id (Option A). If sessions are minted without knowing the bound
   astation_id, fall back to Option B (explicit `?work_session=` + verify) — but
   that needs a matching atem-side change.
2. **vault_id generation.** Short, URL-safe, not trivially enumerable (authz is
   server-enforced so secrecy isn't load-bearing, but don't use sequential ids).
   Suggest `v-` + 8–12 base62 random chars.
3. **Summary history.** v1 keeps `summary` as a mutable column only. The schema
   supports logging `kind='summary'` rows later if history is wanted.
4. **`writer_list` growth.** Append-only; fine for small teams. Revisit GC if a
   vault accrues many one-off writers.
5. **DB-backed test strategy (Task 6).** Decide: `sqlx::test` vs testcontainers
   vs store-trait + in-memory. Affects CI.
