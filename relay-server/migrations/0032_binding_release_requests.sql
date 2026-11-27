-- A release stays evidence against the old binding version across credential rotation.
CREATE TABLE station_binding_release_requests (
    issuer TEXT NOT NULL,
    portal_origin TEXT NOT NULL,
    station_origin TEXT NOT NULL,
    release_id TEXT NOT NULL,
    account TEXT NOT NULL,
    account_id TEXT NOT NULL,
    genesis TEXT NOT NULL,
    binding_id TEXT NOT NULL,
    version BIGINT NOT NULL CHECK (version > 0),
    PRIMARY KEY (issuer, portal_origin, station_origin, release_id)
);

CREATE INDEX station_binding_release_versions ON station_binding_release_requests
    (issuer, portal_origin, station_origin, account_id, genesis, version);
