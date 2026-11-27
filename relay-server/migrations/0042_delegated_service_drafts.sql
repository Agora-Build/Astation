-- Only the closed plan can use these unsigned, replaceable service bodies.
CREATE TABLE station_delegated_service_drafts (
    plan_id TEXT PRIMARY KEY REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    source_hash TEXT NOT NULL,
    bodies JSONB NOT NULL CHECK (jsonb_typeof(bodies) = 'array' AND octet_length(bodies::text) <= 16777216),
    bodies_hash TEXT NOT NULL
);
