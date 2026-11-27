-- An applied admin release is both the new local binding version and its
-- durable outbound report. An HTTP retry must use the identical record.
CREATE TABLE station_applied_binding_releases (
    issuer TEXT NOT NULL,
    portal_origin TEXT NOT NULL,
    station_origin TEXT NOT NULL,
    release_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    genesis TEXT NOT NULL,
    version BIGINT NOT NULL CHECK (version BETWEEN 2 AND 9007199254740991),
    report JSONB NOT NULL,
    PRIMARY KEY (issuer,portal_origin,station_origin,account_id,genesis,version),
    UNIQUE (issuer,portal_origin,station_origin,release_id),
    FOREIGN KEY (issuer,portal_origin,station_origin,release_id)
        REFERENCES station_binding_release_requests (issuer,portal_origin,station_origin,release_id),
    CHECK (report->>'state' IS NOT DISTINCT FROM 'binding_changed'
       AND report->>'bindingState' IS NOT DISTINCT FROM 'released'
       AND report->>'accountId' IS NOT DISTINCT FROM account_id
       AND report->>'genesisHash' IS NOT DISTINCT FROM genesis
       AND report->'version' IS NOT DISTINCT FROM to_jsonb(version))
);
