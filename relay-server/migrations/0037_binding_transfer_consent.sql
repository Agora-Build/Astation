-- Current-owner consent belongs to this exact transfer and expires with it.
ALTER TABLE station_binding_challenges
    ADD COLUMN consent_auth_time BIGINT,
    ADD COLUMN consent_expires_at BIGINT,
    ADD CONSTRAINT binding_consent_lifetime CHECK (
        (consent_auth_time IS NULL AND consent_expires_at IS NULL)
        OR (consent_auth_time IS NOT NULL AND consent_expires_at IS NOT NULL
            AND challenge::jsonb->>'action' = 'transfer'
            AND consent_auth_time >= 0 AND consent_expires_at <= expires_at
            AND consent_auth_time <= consent_expires_at / 1000)
    );
