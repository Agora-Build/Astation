-- Signed logs and sealed backups only. Recovery secrets and K never reach the relay.
CREATE TABLE remote_recovery_roots (
    genesis_hash TEXT PRIMARY KEY CHECK (genesis_hash ~ '^[0-9a-f]{64}$'),
    account_subject TEXT NOT NULL,
    state JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
