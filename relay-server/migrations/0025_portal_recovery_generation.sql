-- Only a checkpoint fetched for an already closed recovery generation receives
-- these fields. The revision prevents older writers from preserving a stale stamp.
ALTER TABLE station_integration_policy
    ADD COLUMN recovery_generation BIGINT CHECK (recovery_generation > 0),
    ADD COLUMN recovery_revision NUMERIC(20,0),
    ADD CHECK ((recovery_generation IS NULL) = (recovery_revision IS NULL));
