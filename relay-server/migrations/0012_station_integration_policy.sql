-- Authenticated Portal snapshots; cursor and policy commit as one CAS record.
-- No native account keys, R9 service private keys or Portal refresh tokens.
CREATE TABLE station_integration_policy (
    binding TEXT PRIMARY KEY CHECK (octet_length(binding) <= 4096),
    checkpoint TEXT NOT NULL CHECK (octet_length(checkpoint) <= 4194304)
);
