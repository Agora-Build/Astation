-- Vault: durable, append-only, versioned shared context store.
CREATE TABLE IF NOT EXISTS vaults (
    vault_id        TEXT PRIMARY KEY,             -- short, URL-safe, e.g. "v-7Kf3qD"
    summary         TEXT NOT NULL DEFAULT '',     -- mutable description
    work_session_id TEXT NOT NULL,                -- the work session (astation_id) this vault belongs to
    created_by      TEXT NOT NULL,                -- client_id of creator
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    writer_list     TEXT[] NOT NULL DEFAULT '{}', -- denormalized content-writer client_ids
    next_entry_no   INT    NOT NULL DEFAULT 1     -- per-vault entry-number allocator
);

CREATE TABLE IF NOT EXISTS vault_entries (
    seq        BIGSERIAL PRIMARY KEY,             -- global write order (also the --since cursor)
    vault_id   TEXT NOT NULL REFERENCES vaults(vault_id),
    entry_no   INT  NOT NULL,                     -- per-vault: 1,2,3 -> shown as e1, e2, e3
    version    INT  NOT NULL,                     -- per-entry: 1,2,3 -> shown as v1, v2, v3
    kind       TEXT NOT NULL,                     -- 'content' | 'summary'
    writer_id  TEXT NOT NULL,                     -- client_id that wrote this row
    content    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (vault_id, entry_no, version)
);

CREATE INDEX IF NOT EXISTS vault_entries_by_vault_seq ON vault_entries (vault_id, seq);
