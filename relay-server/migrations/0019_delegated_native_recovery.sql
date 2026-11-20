-- Preserve complete native exports separately from verified signed stops.
-- Unsigned intent and destinations confer no effects or signing authority.
CREATE TABLE station_delegated_native_recovery (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    evidence_hash TEXT NOT NULL,
    archive JSONB NOT NULL,
    PRIMARY KEY (plan_id, evidence_hash)
);
