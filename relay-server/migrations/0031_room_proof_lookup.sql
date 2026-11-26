-- Locate the last verified room for each carrier at this Station. Registration
-- must still validate the proof against current membership before retaining an owner.
CREATE TABLE station_room_proofs (
    station_origin TEXT NOT NULL,
    issuer TEXT NOT NULL,
    genesis_hash TEXT NOT NULL REFERENCES remote_recovery_roots(genesis_hash) ON DELETE CASCADE,
    host_id TEXT NOT NULL,
    carrier TEXT NOT NULL CHECK (carrier IN ('relay', 'proxy')),
    room TEXT NOT NULL,
    nonce BYTEA NOT NULL CHECK (octet_length(nonce) = 32),
    PRIMARY KEY (station_origin, issuer, genesis_hash, host_id, carrier)
);
CREATE INDEX station_room_proofs_by_room ON station_room_proofs (station_origin, issuer, room);
