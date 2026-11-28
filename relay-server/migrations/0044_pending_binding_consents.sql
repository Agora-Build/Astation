-- Discovery starts only after a manager signs the exact outstanding challenge.
ALTER TABLE station_binding_challenges
    ADD COLUMN consent_proof text CHECK (octet_length(consent_proof) BETWEEN 1 AND 16384),
    ADD COLUMN consent_owners text[] NOT NULL DEFAULT '{}';
CREATE INDEX station_binding_consent_owners ON station_binding_challenges
    USING gin (consent_owners) WHERE consent_proof IS NOT NULL;
