-- The transition itself owns its report body. Keep retry and terminal state
-- beside it so a lost reply or a new report credential cannot reorder reports.
ALTER TABLE station_native_binding_transitions
    ADD COLUMN report_outcome text CHECK (report_outcome IN ('confirmed','refused')),
    ADD COLUMN report_attempts integer NOT NULL DEFAULT 0,
    ADD COLUMN report_due timestamptz NOT NULL DEFAULT now();

ALTER TABLE station_applied_binding_releases
    ADD COLUMN report_outcome text CHECK (report_outcome IN ('confirmed','refused')),
    ADD COLUMN report_attempts integer NOT NULL DEFAULT 0,
    ADD COLUMN report_due timestamptz NOT NULL DEFAULT now();

CREATE INDEX station_native_binding_reports_pending ON station_native_binding_transitions
    (issuer,portal_origin,station_origin,account_id,genesis,version) WHERE report_outcome IS NULL;
CREATE INDEX station_release_reports_pending ON station_applied_binding_releases
    (issuer,portal_origin,station_origin,account_id,genesis,version)
    WHERE report_outcome IS NULL AND portal_version IS NULL;

CREATE VIEW station_pending_binding_reports AS
    SELECT issuer,portal_origin,station_origin,account_id,genesis,version,report,report_due
    FROM station_native_binding_transitions WHERE report_outcome IS NULL
    UNION ALL
    SELECT issuer,portal_origin,station_origin,account_id,genesis,version,report,report_due
    FROM station_applied_binding_releases WHERE report_outcome IS NULL AND portal_version IS NULL;
