CREATE TABLE station_delegated_signer_reports (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    connection BIGINT NOT NULL CHECK (connection BETWEEN 1 AND 9007199254740991),
    challenge JSONB NOT NULL,
    submission JSONB NOT NULL,
    submission_hash TEXT NOT NULL,
    accepted_at BIGINT NOT NULL,
    PRIMARY KEY (plan_id, connection)
);
