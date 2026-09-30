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
