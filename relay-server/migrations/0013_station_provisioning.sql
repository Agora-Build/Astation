-- An integration cannot silently acquire a second service identity or root.
CREATE TABLE station_integration_provisioning (
    binding TEXT NOT NULL,
    integration_id TEXT NOT NULL,
    context TEXT NOT NULL,
    fingerprint TEXT,
    PRIMARY KEY (binding, integration_id)
);

CREATE TABLE station_integration_feed_poll (
    binding TEXT PRIMARY KEY,
    not_before TIMESTAMPTZ NOT NULL
);

CREATE TABLE station_integration_quota (
    binding TEXT NOT NULL,
    integration_id TEXT NOT NULL,
    second BIGINT NOT NULL,
    used BIGINT NOT NULL,
    PRIMARY KEY(binding, integration_id)
);
