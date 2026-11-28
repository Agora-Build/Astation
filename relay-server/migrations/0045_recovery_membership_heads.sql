-- Keep the plan's original source immutable. Reports and copies accepted after
-- an append must remain verifiable at their own head after restore or demotion.
CREATE TABLE station_delegated_recovery_memberships (
    plan_id TEXT NOT NULL REFERENCES station_delegated_recovery_plans(plan_id) ON DELETE CASCADE,
    seq BIGINT NOT NULL CHECK (seq > 0),
    membership JSONB NOT NULL,
    PRIMARY KEY (plan_id, seq)
);

ALTER TABLE station_delegated_recovery_signatures ADD COLUMN membership_seq BIGINT,
    ADD FOREIGN KEY (plan_id, membership_seq) REFERENCES station_delegated_recovery_memberships(plan_id, seq);
