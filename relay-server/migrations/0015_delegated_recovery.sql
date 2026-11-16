-- Deployment generation is supplied outside the database backup. A mismatch
-- fences all delegated activity until complete snapshot recovery is implemented.
CREATE TABLE station_delegated_recovery (
    origin TEXT PRIMARY KEY,
    generation BIGINT NOT NULL CHECK (generation > 0),
    ready BOOLEAN NOT NULL,
    reason TEXT NOT NULL CHECK (reason IN ('initialized', 'history_missing', 'generation_changed', 'operator_fenced'))
);
