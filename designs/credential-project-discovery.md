# Credential Project Discovery

The Credentials project field is an editable list: reported Git projects from
verified Atem devices, existing saved credential scopes, or a manually entered
Git remote. Suggestions never grant a device access to a credential. Agora App
projects and local filesystem paths are not credential project identities.

An updated, unlocked Atem reports its current Git remote and project names it
has remembered for the account. It reports after authenticated connection and
in response to `credentialProjectListRequest`. `atem cred projects` explicitly
publishes suggestions with a bounded connection/delivery wait. Locked or unverified clients
send no inventory and never trigger an unlock prompt just to fill this list.
An ephemeral CLI can send its report and exit; no persistent connection or
unbounded acknowledgment wait is required.

`credentialProjectListResponse` carries a `report` with `signed`,
`encapped_key`, and `ciphertext`. The payload is a JSON array of canonical
project keys: lowercased `host/owner/repo`, with credentials and `.git` removed.
It contains at most 256 names and 64 KiB. Reports always use HPKE
X25519/HKDF-SHA256/ChaCha20-Poly1305, including when memory encryption is OFF.
The recipient is the Astation encryption key pinned during verification.

## Project spelling and compatibility

Project identity remains the lowercase canonical key. Display and saved scopes
retain the original spelling of a sanitized Git remote, such as
`github.com/Agora-Build/Atem`; protocols, credentials and `.git` are removed.
Case variants identify one scope and appear once in suggestions. A label never
changes authorization, memory project keys or keyed hashes. Previously stored
lowercase names remain readable; capitalization that was discarded cannot be
reconstructed.

An updated key agent adds an optional `labels` envelope to the existing report.
It has `signed`, `encapped_key` and `ciphertext`, like the original envelope.
Its encrypted JSON array contains `{key, label}` entries for exactly the
canonical keys in the original payload. Both arrays together are limited to
64 KiB and 256 projects. The label must be a sanitized spelling whose lowercase
canonical identity equals `key`. Neither spelling nor identity is plaintext
on the relay. Older Astation builds ignore the extension and read the original
array; older key agents omit it. No capability round trip or live connection
is required. Unlocked older agents are never restarted automatically.

The extension uses `atem-credential-project-labels-info-v1` for HPKE info and
`atem-credential-project-labels-v1` for its signed statement, followed by the
same account/device/generation/time fields and its own ciphertext digest.
Astation verifies both envelopes with the current pin and requires identical
identity, report time and canonical project sets before accepting labels. A
malformed extension rejects the report. Removing it can only remove display
spelling; it cannot change project identity or grant access. For reports at
the same time, a labeled report takes precedence over a legacy report.

Local credential format 1 retains its canonical `project` field and gains an
optional `projectLabel` field. Readers validate its canonical binding before
displaying it; records without the field use `project`. Saves and updates
retain spelling while duplicate checks continue to use the canonical key.

Using the existing length-prefixed field encoding and big-endian u64 fields:

- HPKE info: `atem-credential-projects-info-v1`, account, device ID, signing
  generation (1), report time (Unix seconds).
- Device-signed statement: `atem-credential-projects-v1`, account, device ID,
  signing generation (1), report time, SHA-256 of the encoded encapsulated key
  and ciphertext.

Astation captures the authenticated route before dispatch. It verifies the
device signature against its current local pin, account/device binding,
generation, payload bounds, ciphertext digest and report time (at most five
minutes old or one minute ahead), then decrypts using its protected identity.
Revoked or replaced pins cannot supply suggestions. Duplicate reports are
idempotent; older reports cannot replace newer suggestions. Accepted reports
can finish after the sending CLI disconnects. Account changes and revocation
remove cached suggestions when the picker is refreshed. The cache is in
process memory; saved credential scopes remain available after restart.

The relay transports ciphertext only. It supplies neither authoritative device
identity nor project permissions. Refresh requests contain no secret or
project name; responses can only be encrypted to the locally pinned Astation.
Manual input remains available with no connected Atem. This reporting feature
does not implement Atem credential retrieval or the future scope-grant service.
