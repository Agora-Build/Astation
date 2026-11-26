-- Ownership evidence outlives the pairing session. Only an explicit ownership
-- transition may resolve a conflict. A reconnect cannot transfer a room.
CREATE TABLE station_proved_room_owners (
    station_origin TEXT NOT NULL,
    issuer TEXT NOT NULL,
    genesis_hash TEXT NOT NULL REFERENCES remote_recovery_roots(genesis_hash) ON DELETE CASCADE,
    room TEXT NOT NULL CHECK (octet_length(room) BETWEEN 1 AND 256),
    account_subject TEXT NOT NULL CHECK (account_subject ~ '^ab[0-9A-HJKMNP-TV-Z]{26}$'),
    conflicted BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (station_origin, issuer, genesis_hash, room)
);
