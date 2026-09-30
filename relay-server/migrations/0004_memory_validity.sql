-- Atem Memory 1.1: fact validity. `deleted` becomes `deleted_at`; facts can
-- be invalidated (kept, not injected) and point at the memory that replaced them.
ALTER TABLE memories ADD COLUMN deleted_at    BIGINT;
UPDATE memories SET deleted_at = extract(epoch FROM now())::bigint
    WHERE deleted;                                              -- real time unknown
ALTER TABLE memories ADD COLUMN valid_at      BIGINT;          -- NULL means created_at
ALTER TABLE memories ADD COLUMN invalid_at    BIGINT;
ALTER TABLE memories ADD COLUMN superseded_by TEXT;
DROP INDEX memories_dedup;
CREATE UNIQUE INDEX memories_dedup ON memories
    (account_id, scope, project, machine, content_hash)
    WHERE deleted_at IS NULL AND invalid_at IS NULL;
ALTER TABLE memories DROP COLUMN deleted;
