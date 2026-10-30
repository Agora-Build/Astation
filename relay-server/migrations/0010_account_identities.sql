-- Retain legacy principal strings and every existing product/cryptographic ID.
CREATE TABLE account_identities (
    issuer TEXT NOT NULL,
    subject TEXT NOT NULL,
    principal TEXT NOT NULL UNIQUE,
    PRIMARY KEY (issuer, subject)
);
INSERT INTO account_identities (issuer, subject, principal)
SELECT 'legacy:agora', value, value FROM (
    SELECT agora_user AS value FROM astation_accounts
    UNION SELECT agora_user FROM account_merge_requests
    UNION SELECT account_subject FROM remote_recovery_roots
) AS legacy;
