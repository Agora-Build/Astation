-- Optional Agora account registration and explicit Astation data grouping.
-- Unregistered Astations keep using astation_id directly, preserving the
-- existing authorization and storage behavior.
CREATE TABLE IF NOT EXISTS astation_accounts (
    astation_id   TEXT PRIMARY KEY,
    agora_user    TEXT NOT NULL,
    label         TEXT NOT NULL,
    data_account  TEXT NOT NULL,
    registered_at BIGINT NOT NULL,
    last_seen_at  BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS astation_accounts_by_user
    ON astation_accounts (agora_user, registered_at, astation_id);
CREATE INDEX IF NOT EXISTS astation_accounts_by_data
    ON astation_accounts (data_account);

CREATE TABLE IF NOT EXISTS account_merge_requests (
    request_id            TEXT PRIMARY KEY,
    agora_user            TEXT NOT NULL,
    requester_astation_id TEXT NOT NULL,
    target_astation_id    TEXT NOT NULL,
    mode                  TEXT NOT NULL CHECK (mode IN ('online', 'delayed')),
    status                TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'cancelled', 'expired')),
    created_at            BIGINT NOT NULL,
    ready_at              BIGINT,
    expires_at            BIGINT NOT NULL,
    completed_at          BIGINT
);
CREATE INDEX IF NOT EXISTS account_merge_requests_pending
    ON account_merge_requests (status, ready_at, expires_at);
