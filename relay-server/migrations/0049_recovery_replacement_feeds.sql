-- One replaceable, unpublished feed image per recovery plan.
CREATE TABLE station_delegated_replacement_feeds (
    plan_id TEXT PRIMARY KEY REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    cut_hash TEXT NOT NULL,
    captured_ms BIGINT NOT NULL CHECK (captured_ms BETWEEN 0 AND 9007199254740991),
    feed_hash TEXT NOT NULL,
    feed JSONB NOT NULL CHECK (jsonb_typeof(feed) = 'object' AND octet_length(feed::text) <= 16777216)
);
