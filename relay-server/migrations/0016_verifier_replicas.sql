-- Capability evidence is separate from relay presence. An expired report never
-- removes a required slot from the deployment's explicit verifier roster.
CREATE TABLE station_verifier_rosters (
    origin TEXT PRIMARY KEY,
    generation BIGINT NOT NULL CHECK (generation > 0),
    replicas JSONB NOT NULL CHECK (jsonb_typeof(replicas) = 'array')
);

CREATE TABLE station_verifier_replicas (
    origin TEXT NOT NULL REFERENCES station_verifier_rosters(origin),
    replica_id TEXT NOT NULL,
    roster_generation BIGINT NOT NULL CHECK (roster_generation > 0),
    recovery_generation BIGINT NOT NULL CHECK (recovery_generation > 0),
    connection TEXT NOT NULL,
    connection_generation BIGINT NOT NULL CHECK (connection_generation > 0),
    inventory JSONB,
    highest_inventory JSONB NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (origin, replica_id)
);
