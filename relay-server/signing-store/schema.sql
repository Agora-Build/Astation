-- Install in the independent signing database. Never include this table in a Station restore.
CREATE TABLE station_service_signing_ceilings (
    account_id TEXT NOT NULL,
    genesis_hash TEXT NOT NULL,
    service_id TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    highest_ms BIGINT NOT NULL DEFAULT 0 CHECK (highest_ms BETWEEN 0 AND 9007199254740991),
    PRIMARY KEY (account_id, genesis_hash, service_id, key_hash)
);

-- A failed key-provisioning commit can leave an unused registration. Only one
-- key can ever sign for the protocol principal, including after a restore.
CREATE UNIQUE INDEX station_signed_principal ON station_service_signing_ceilings
    (account_id, genesis_hash, service_id) WHERE highest_ms > 0;

-- The runtime role gets UPDATE on highest_ms only. Enforce monotonicity for
-- every client of this database, including an older or misconfigured replica.
CREATE FUNCTION station_require_higher_ceiling() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.highest_ms <= OLD.highest_ms THEN
        RAISE EXCEPTION 'signing ceiling must increase';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER station_require_higher_ceiling BEFORE UPDATE ON station_service_signing_ceilings
    FOR EACH ROW EXECUTE FUNCTION station_require_higher_ceiling();
