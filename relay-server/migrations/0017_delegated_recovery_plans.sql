-- A prepared replacement is never a live feed or proof of complete history.
-- Keep each generation's original membership, records, watermarks and ledger
-- intact while later history and fresh manager signatures are reconciled.
CREATE TABLE station_delegated_recovery_plans (
    origin TEXT NOT NULL REFERENCES station_delegated_recovery(origin),
    generation BIGINT NOT NULL CHECK (generation > 0),
    genesis_hash TEXT NOT NULL REFERENCES remote_recovery_roots(genesis_hash) ON DELETE CASCADE,
    plan_id TEXT NOT NULL UNIQUE,
    candidate_feed_id TEXT NOT NULL UNIQUE,
    source_hash TEXT NOT NULL,
    retained JSONB NOT NULL,
    PRIMARY KEY (origin, generation, genesis_hash)
);
