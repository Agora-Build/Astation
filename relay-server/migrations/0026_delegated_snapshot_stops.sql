-- One replaceable stop component per closed recovery plan. The signed source
-- history and original ACK ledger remain in their existing immutable checkpoints.
CREATE TABLE station_delegated_snapshot_stops (
    plan_id TEXT PRIMARY KEY REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    reconstruction_hash TEXT NOT NULL,
    records JSONB NOT NULL CHECK (jsonb_typeof(records) = 'array')
);
