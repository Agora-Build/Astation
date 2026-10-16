CREATE TABLE device_push_tokens (
    device_id TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('apns_sandbox', 'apns_production', 'fcm')),
    token TEXT NOT NULL,
    generation TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, platform),
    UNIQUE (platform, token)
);
