-- A native transition, its replay receipt, the routes it retires and the
-- report to Portal become visible together, under the list's new version.
CREATE TABLE station_native_binding_transitions (
    issuer TEXT NOT NULL,
    portal_origin TEXT NOT NULL,
    station_origin TEXT NOT NULL,
    account_id TEXT NOT NULL,
    genesis TEXT NOT NULL,
    version BIGINT NOT NULL CHECK (version BETWEEN 1 AND 9007199254740991),
    nonce TEXT NOT NULL,
    proof_hash BYTEA NOT NULL CHECK (octet_length(proof_hash) = 32),
    report JSONB NOT NULL,
    retired_routes JSONB NOT NULL,
    PRIMARY KEY (issuer,portal_origin,station_origin,account_id,genesis,version),
    UNIQUE (issuer,station_origin,nonce),
    CHECK (report->>'state' IS NOT DISTINCT FROM 'binding_changed'
        AND report->>'accountId' IS NOT DISTINCT FROM account_id
        AND report->>'genesisHash' IS NOT DISTINCT FROM genesis
        AND report->'version' IS NOT DISTINCT FROM to_jsonb(version)
        AND report->>'bindingState' IN ('bound','unbound'))
);
