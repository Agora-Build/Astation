-- A manager can resume the same native copy after restart or on another replica.
CREATE TABLE station_delegated_copy_reservations (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    original_id TEXT NOT NULL,
    manager TEXT NOT NULL,
    principal TEXT NOT NULL,
    review_hash TEXT NOT NULL,
    issued_at BIGINT NOT NULL CHECK (issued_at BETWEEN 1 AND 9007199254740991),
    PRIMARY KEY (plan_id, original_id, manager)
);

CREATE INDEX station_copy_principal_time ON station_delegated_copy_reservations
    (plan_id, principal, issued_at DESC);
