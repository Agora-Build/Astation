ALTER TABLE station_applied_binding_releases
    ADD COLUMN retired_routes jsonb NOT NULL DEFAULT '[]';
CREATE INDEX station_release_retired_connections ON station_applied_binding_releases
    USING gin (retired_routes jsonb_path_ops);
