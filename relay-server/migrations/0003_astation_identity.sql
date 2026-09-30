-- Astation proof-of-possession: one P-256 key per Astation (trust on first
-- use) + durable session bindings pushed by the verified Astation.
-- Admin reset of a lost/replaced Mac: DELETE FROM astation_keys WHERE astation_id = '<id>';
CREATE TABLE IF NOT EXISTS astation_keys (
    astation_id      TEXT PRIMARY KEY,
    public_key       TEXT NOT NULL,           -- hex, P-256 X9.63 uncompressed
    registered_at    BIGINT NOT NULL,
    last_verified_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_bindings (
    session_id   TEXT PRIMARY KEY,
    astation_id  TEXT NOT NULL,
    created_at   BIGINT NOT NULL,
    last_used_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS session_bindings_by_astation ON session_bindings (astation_id);
