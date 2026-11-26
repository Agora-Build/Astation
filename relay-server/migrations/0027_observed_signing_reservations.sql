-- Recovery observations in the primary database. Only the independent signing
-- database can register a key or reserve a timestamp.
CREATE TABLE station_delegated_observed_reservations (
    origin TEXT NOT NULL REFERENCES station_delegated_recovery(origin),
    account_id TEXT NOT NULL,
    genesis_hash TEXT NOT NULL REFERENCES remote_recovery_roots(genesis_hash) ON DELETE CASCADE,
    service_id TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    highest_ms BIGINT NOT NULL CHECK (highest_ms BETWEEN 0 AND 9007199254740991),
    PRIMARY KEY (origin, account_id, genesis_hash, service_id, key_hash)
);
