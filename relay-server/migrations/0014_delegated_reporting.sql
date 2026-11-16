-- Report-client stops apply to every account on the Station, across replicas.
-- The ordered journal also lets a dormant account apply intervening stops and
-- explicit resumes before its next delivery.
CREATE TABLE station_delegated_reporting (
    binding TEXT PRIMARY KEY,
    events JSONB NOT NULL,
    in_flight TEXT
);

-- A restart with the same operator configuration must not undo a later 403.
CREATE TABLE station_delegated_report_resumptions (
    binding TEXT NOT NULL REFERENCES station_delegated_reporting(binding),
    resume_id UUID NOT NULL,
    PRIMARY KEY (binding, resume_id)
);
