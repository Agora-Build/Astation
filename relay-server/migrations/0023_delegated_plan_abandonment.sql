-- Preserve abandoned plans and their evidence. The primary key still reserves
-- the account/Station generation so this candidate cannot be prepared again.
ALTER TABLE station_delegated_recovery_plans
    ADD COLUMN abandoned BOOLEAN NOT NULL DEFAULT FALSE;
