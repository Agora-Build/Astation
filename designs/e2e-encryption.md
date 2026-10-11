# Encryption Migration Lifecycle

This documents Astation's authority and durable processing of
`encryptionMigrationComplete`. The shared protocol design, including key
grants, escrow and recovery, is maintained in Atem's
`designs/e2e-encryption.md`.

## Lifecycle

1. Owner approval persists `enabling` or `disabling`, its account, target,
   key ID and starting state epoch before publishing a signed pending state.
   Re-signing that state preserves the operation. Another owner change starts
   a new operation even with the same key ID. A legacy key without a signed
   state starts in `enabling`; it cannot create `on` without verification.
2. An unlocked, verified Atem migrates memory, skills and their history,
   vault summaries and every vault entry version. It reads the records back,
   checks field formats/key IDs, and authenticates ciphertext under the
   approved account key. A partial or interrupted scan sends no completion.
3. On receipt, Astation captures the authenticated device ID, connection
   generation and account before dispatching asynchronous work. It checks
   the pinned device signature, approved operation and key-possession proof,
   then durably saves the report with the exact pin, verification generation,
   Astation signing identity and captured route. A transport identity alone
   is insufficient authorization.
4. Processing uses the durable report and captured context, independently
   of Atem's process, socket or replacement connection. Under the identity
   lock, it rechecks the current pin and verification generation, signing
   identity, recovery confirmation, operation, account key and proof.
   Revocation or re-verification before commit invalidates the report. A
   fresh verified report can resume the pending operation.
5. Astation signs the final account state and atomically saves the state,
   epoch, report and final signature in the protected identity record.
   Publication occurs after this save. Duplicates reuse the saved final
   signature without another transition or epoch increment. A later revoke
   does not roll back an already committed account state.
6. Startup and relay reconnect resume accepted reports. Key access, signing
   or save failures preserve pending work for retries with bounded backoff.
   A crash before acceptance requires sender retry; after acceptance it
   requires no live client. A crash after commit can republish the saved
   result. Relay replication retries from local state without an Atem.
   If the relay missed the pending transition, Astation first replicates
   that pending mode, then the committed final mode after the next relay
   status. These replica updates never change the locally committed mode.
   If account routing changes after acceptance, finalization still commits
   the captured account. Publication waits until that account is selected;
   a queued result must not update another account's relay replica.

## Completion Statement

The wire message has `mode`, `kid` and `completion`, a `SignedWire` containing
base64 `statement` and `signature`. The Ed25519 signature uses the verified
device-signing key. The statement is a length-prefixed sequence; integers
are eight-byte unsigned big-endian values.

| Field | Required value |
| --- | --- |
| label | `atem-migration-complete-v1` |
| account | Locally approved data account |
| sign_gen | Astation signing generation, currently 1 |
| device_id | Authenticated, pinned device ID |
| target | `on` or `off`, matching the pending operation and outer mode |
| kid | Approved lowercase eight-character hex key ID, matching outer kid |
| state_epoch | Between operation start and current signed state, and at least the current device verification epoch |
| stores | 7: memory=1, skills/history=2, vault/history=4 |
| remaining | 0 |
| key_proof | 32-byte HMAC-SHA256 over the encoded first nine fields |

The HMAC key is HKDF-SHA256(account key K, empty salt,
`atem-migration-proof-v1`, 32 bytes). Atem's key agent creates the proof and
signs the report without exporting K. Re-verification with identical keys
cannot renew an old report's authorization. Reports from an earlier
operation cannot complete a new one. Unsigned legacy packets fail closed.

## Security Invariants

- Astation's protected local state and pins authorize transitions. The relay
  is transport and storage; its device labels, connection events, counters,
  modes and acknowledgments cannot authorize `on` or override device pins.
  Without an approved local state, the displayed mode defaults to `off`;
  a relay claim alone cannot display approved encryption.
- Only a validated completion may create a final encryption mode. The
  generic state setter starts pending operations. Existing approved states
  survive reconnects and relay disagreement.
- Revocation and completion serialize through the same identity lock. The
  final save determines their ordering; neither UI nor network publication
  can precede the durable commit.
- Atem is ephemeral. A bounded socket flush or acknowledgment improves
  delivery but is not required after durable acceptance.
- The report attests the records returned to the verified client's scan.
  An untrusted server may withhold records or retain old plaintext backups;
  completion does not prove their erasure.

Identity format 3 stores the migration journal and device verification
epochs alongside pins and escrow. Formats 1 and 2 load without replacing
keys and upgrade on write. Older readers refuse format 3 instead of erasing
its security metadata.

## Validation

Regressions cover immediate local and relay disconnects, delayed dispatch,
duplicates before and after commit, restart after acceptance and commit,
failed acceptance/final saves, unavailable keys, signing failure, reconnect
with a new connection generation, and revocation before/after acceptance
and commit. Re-verification tests reuse identical keys and reject old
reports. Forged signatures, accounts, devices, keys, partial scans and key
proofs fail closed. Relay `on` claims cannot change local state, and relay
reconnect replicates committed results without a connected Atem.

Swift and Rust share a migration-proof known-answer vector. Atem tests
exercise read-back rejection and a bounded flush before immediate shutdown.
Provisioned Swift tests exercise the protected Keychain and Secure Enclave;
live Touch ID and cross-machine migration need a matching updated client.
