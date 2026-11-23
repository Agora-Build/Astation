ALTER TABLE station_delegated_recovery_plans
    ADD COLUMN signer_connection BIGINT NOT NULL DEFAULT 0
    CHECK (signer_connection BETWEEN 0 AND 9007199254740991);

CREATE TABLE station_delegated_signer_challenges (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    signer TEXT NOT NULL,
    slot TEXT NOT NULL,
    membership_head JSONB NOT NULL,
    challenge JSONB NOT NULL,
    expires_at BIGINT NOT NULL,
    PRIMARY KEY (plan_id, signer, slot)
);
