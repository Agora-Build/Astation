-- Apply once, as the signing-store owner, after schema.sql.
BEGIN;
CREATE TABLE station_signing_publication_guard (
    singleton BOOLEAN PRIMARY KEY CHECK (singleton),
    attempt UUID,
    origin TEXT,
    generation BIGINT,
    primary_store TEXT,
    CHECK ((attempt IS NULL AND origin IS NULL AND generation IS NULL AND primary_store IS NULL)
        OR (attempt IS NOT NULL AND origin IS NOT NULL AND generation IS NOT NULL AND generation > 0
            AND primary_store IS NOT NULL))
);
INSERT INTO station_signing_publication_guard (singleton) VALUES (true);

-- Signers keep their column grants on the ceilings table. Only the operator
-- changes the guard. Qualify its schema even for clients with a custom search path.
CREATE FUNCTION station_check_signing_publication() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE held BOOLEAN;
BEGIN
    EXECUTE format('SELECT attempt IS NOT NULL FROM %I.station_signing_publication_guard
                    WHERE singleton FOR SHARE', TG_TABLE_SCHEMA) INTO STRICT held;
    IF held THEN
        RAISE EXCEPTION 'service signing held for recovery publication' USING ERRCODE = '55000';
    END IF;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION station_check_signing_publication() FROM PUBLIC;
CREATE TRIGGER station_check_signing_publication
    BEFORE INSERT OR UPDATE ON station_service_signing_ceilings
    FOR EACH STATEMENT EXECUTE FUNCTION station_check_signing_publication();
ALTER TABLE station_service_signing_ceilings ENABLE ALWAYS TRIGGER station_check_signing_publication;
COMMIT;
