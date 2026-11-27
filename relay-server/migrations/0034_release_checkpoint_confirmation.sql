-- Authenticated Portal evidence survives a lost HTTP reply and credential rotation.
ALTER TABLE station_applied_binding_releases ADD COLUMN portal_version BIGINT
    CHECK (portal_version BETWEEN version AND 9007199254740991);

CREATE INDEX station_unconfirmed_binding_releases
    ON station_applied_binding_releases (issuer,portal_origin,station_origin,account_id,genesis)
    WHERE portal_version IS NULL;
