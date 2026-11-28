-- Keep exact candidate signatures through a lost response, supersession and abandonment.
CREATE TABLE station_delegated_service_components (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    source_hash TEXT NOT NULL,
    bodies_hash TEXT NOT NULL,
    membership_seq BIGINT NOT NULL CHECK (membership_seq > 0),
    membership_hash TEXT NOT NULL,
    records_hash TEXT NOT NULL,
    records JSONB NOT NULL CHECK (jsonb_typeof(records) = 'array' AND jsonb_array_length(records) BETWEEN 1 AND 4096 AND octet_length(records::text) <= 16777216),
    PRIMARY KEY (plan_id, source_hash)
);
