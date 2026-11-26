-- The report client is shared by the Station's account feeds. Keep each
-- observed journal once, including when several accounts prepare for recovery.
CREATE TABLE station_delegated_reporting_history (
    origin TEXT NOT NULL REFERENCES station_delegated_recovery(origin),
    binding TEXT NOT NULL,
    first_generation BIGINT NOT NULL CHECK (first_generation > 0),
    evidence_hash TEXT NOT NULL,
    journal JSONB NOT NULL,
    PRIMARY KEY (origin, binding, evidence_hash)
);
