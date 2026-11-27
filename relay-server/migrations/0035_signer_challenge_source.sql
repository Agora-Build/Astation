-- Allows outstanding reports in one round to arrive in either order.
ALTER TABLE station_delegated_signer_challenges ADD COLUMN external_source_hash TEXT
    CHECK (external_source_hash ~ '^[0-9a-f]{64}$');
