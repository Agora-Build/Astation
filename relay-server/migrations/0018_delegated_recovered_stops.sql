-- Supplement a recovery checkpoint without rewriting its source or live feed.
-- Only the recovery operator imports these signed objects; they grant no effect.
CREATE TABLE station_delegated_recovered_stops (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    record JSONB NOT NULL,
    PRIMARY KEY (plan_id, record_id)
);
