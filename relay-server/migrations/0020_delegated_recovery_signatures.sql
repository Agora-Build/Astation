-- Fresh manager copies remain separate from the live feed and original evidence.
-- The input commitment binds a copy to the exact recovery review it addressed.
CREATE TABLE station_delegated_recovery_signatures (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    original_record_id TEXT NOT NULL,
    evidence_hash TEXT NOT NULL,
    record JSONB NOT NULL,
    PRIMARY KEY (plan_id, record_id),
    UNIQUE (plan_id, evidence_hash, original_record_id)
);
