-- Replicas look up exact, never-reused live connection references. An
-- unchanged connection count must not require scanning the transition history.
CREATE INDEX station_native_retired_connections ON station_native_binding_transitions
    USING gin (retired_routes jsonb_path_ops);
