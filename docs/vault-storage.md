# Vault Storage Design

Vaults hold versioned shared context for collaborating Atem instances. The relay
hosts the HTTP API and storage; Atem is the client. This document records the
implemented model and its boundaries. Endpoint and deployment details are in the
[relay README](../relay-server/README.md#vault).

## Components and persistence

```text
Atem client
    |
    v
vault_routes.rs -- resolve caller and access rules
    |
    v
VaultStore trait
    +-- PgVaultStore ------> Postgres
    +-- InMemoryVaultStore -> process-local state
```

`AppState` holds an `Arc<dyn VaultStore>`, separating HTTP authorization from
storage operations. When `DATABASE_URL` is configured, startup connects to
Postgres and runs migrations. Without it, the relay uses the in-memory store and
logs that data is not durable. A configured database failure does not silently
switch the server to temporary storage.

`GET /health` checks the configured store and identifies its backend. The schema
is defined in [0001_vault.sql](../relay-server/migrations/0001_vault.sql).

## Data model and read semantics

| Record | Purpose |
| --- | --- |
| `vaults` | Vault ID, mutable summary, owning work session, creator, past content writers, and next entry number |
| `vault_entries` | Versioned content with sequence, entry number, version, kind, writer, content, and timestamp |

A vault's `work_session_id` is the Astation identity to which the caller's session
is bound. The content model uses three distinct numbers:

- `entry_no` identifies a logical entry within a vault.
- `version` identifies a revision of that entry.
- `seq` is the global storage sequence used for incremental reads.

Appending allocates a new entry number and writes version 1. Overriding an entry
writes another row with the same entry number and an incremented version. It does
not replace the old content. The schema enforces uniqueness of
`(vault_id, entry_no, version)`.

Normal reads return the latest version of each entry, ordered by entry number.
`history=true` returns revisions ordered by sequence. `since=<seq>` filters rows
to those with a greater sequence before the current/history projection is applied.
Clients that need revision events should use history with their cursor.

The current summary endpoint updates `vaults.summary` directly. It does not append
a summary-history row, despite the schema's provision for a summary entry kind.

## Writes and concurrency

Postgres append operations increment `next_entry_no` and insert the new row within
a transaction. The update serializes allocation for the same vault.

Override operations read the maximum version and insert the next revision in a
transaction. The unique constraint prevents duplicate versions, but the current
implementation does not lock that allocation or retry conflicts. Concurrent
overrides can therefore fail rather than both succeeding with distinct versions.
Content-writer registration happens after the content write as a separate store
operation. These details matter when adding stronger write atomicity or retries.

## Caller resolution and access rules

Requests currently carry `Authorization: session <session_id>` and
`?id=<client_id>`. The relay resolves a granted session's bound Astation identity,
or falls back to the cross-service session verification cache. Invalid or unbound
sessions are rejected. The client ID remains a request-supplied identifier in this
API; do not describe it as cryptographically bound to the requester.

| Caller relationship | Read | Write content | Update summary |
| --- | --- | --- | --- |
| Same work session as the vault | Yes | Yes | Yes |
| Recorded past content writer from another work session | Yes | No | Yes |
| Neither | No | No | No |

The summary endpoint uses the read predicate. Thus, describing past writers as
strictly read-only would miss their current summary-update permission.

Vault HTTP authentication still needs the authenticated-device-session work
listed in [Device Authentication v2](specs/2026-07-21-device-authentication-v2.md#remaining-production-blockers).
WebSocket HMAC authentication does not automatically secure these HTTP endpoints.

## Source and verification

Storage behavior is implemented in `relay-server/src/vault_store.rs`; HTTP
resolution and permissions are in `relay-server/src/vault_routes.rs`. Tests cover
store behavior and HTTP access decisions using the in-memory backend. Postgres
durability, migrations, and write contention need database-backed validation when
those paths change. Keep field names compatible with Atem's Vault client.
