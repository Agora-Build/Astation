-- A NULL digest on a pre-migration challenge cannot authorize a first binding.
ALTER TABLE station_binding_challenges ADD COLUMN room_digest bytea
    CHECK (octet_length(room_digest) = 32);

CREATE TABLE station_binding_room_consents (
    issuer text NOT NULL,
    station_origin text NOT NULL,
    nonce text NOT NULL,
    owner_subject text NOT NULL,
    auth_time bigint NOT NULL CHECK (auth_time >= 0),
    expires_at bigint NOT NULL CHECK (auth_time <= expires_at / 1000),
    PRIMARY KEY (issuer, station_origin, nonce, owner_subject),
    FOREIGN KEY (issuer, station_origin, nonce)
        REFERENCES station_binding_challenges (issuer, station_origin, nonce) ON DELETE CASCADE
);
