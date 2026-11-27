-- A challenge carries no ownership authority. Keep its exact bytes for proof verification.
CREATE TABLE station_binding_challenges (
    issuer TEXT NOT NULL,
    station_origin TEXT NOT NULL,
    subject TEXT NOT NULL,
    nonce TEXT NOT NULL,
    challenge TEXT NOT NULL CHECK (octet_length(challenge) <= 4096),
    expires_at BIGINT NOT NULL,
    PRIMARY KEY (issuer, station_origin, nonce)
);
CREATE INDEX station_binding_challenges_expiry ON station_binding_challenges (issuer, station_origin, expires_at);
CREATE INDEX station_binding_challenges_subject ON station_binding_challenges (issuer, station_origin, subject);
