-- Optional end-to-end encryption state belongs to the resolved data account.
-- A missing row is equivalent to mode=off.
CREATE TABLE IF NOT EXISTS data_account_encryption (
    data_account TEXT PRIMARY KEY,
    mode         TEXT NOT NULL CHECK (mode IN ('enabling', 'on', 'disabling')),
    kid          TEXT NOT NULL CHECK (kid ~ '^[0-9a-f]{8}$'),
    enabled_at   BIGINT,
    updated_at   BIGINT NOT NULL
);
