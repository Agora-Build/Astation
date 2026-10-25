-- Only public binding metadata and operator-key-encrypted service key envelopes.
-- Native identity keys, account K and operator wrapping keys never enter this table.
CREATE TABLE station_service_keys (
    context TEXT PRIMARY KEY CHECK (octet_length(context) <= 4096),
    sealed TEXT NOT NULL CHECK (octet_length(sealed) <= 8192)
);
