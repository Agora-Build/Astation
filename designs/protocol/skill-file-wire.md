# Skill file transport

Status: Station implementation for Atem #130 Task 6 / F8, 2026-11-08.
The owner requires a coordinated Station/Atem update without compatibility routes,
format negotiation, probing or fallback. This supersedes the earlier V2 proposal.

## Purpose

A sealed skill file is already an ASCII `e1.<kid>.<payload>` envelope. Encoding
those bytes as base64 again expands large ciphertext to about 1.78 times its
original size. Sending the envelope directly uses about 1.33 times the original
size plus fixed envelope and JSON overhead. Station neither decrypts nor reseals
files. R9 and the account encryption policy are unchanged.

## Routes and schemas

| Method | Route | Response |
| --- | --- | --- |
| GET | `/api/skills?id=...&since=...&limit=...` | `{skills:[...]}` |
| POST | `/api/skills/batch?id=...` | `{results:[...]}` |
| GET | `/api/skills/versions?id=...&scope=...&project=...&name=...` | `{versions:[...]}` |
| GET | `/api/skills/version?id=...&scope=...&project=...&name=...&version=...` | `{skill:...}` |

Authentication, query semantics, metadata and error shapes stay the same. There
are no `/v2` routes or `wire_version`. The history index contains metadata only.

The request remains `{ops:[...]}`. Each `push.skill`, each `rewrite`, and each
returned row containing files has a required `files_encoding` beside `files`:

- `"e1-text"`: every filename is a structurally valid sealed envelope. Each
  value is a valid envelope or exactly `""`, meaning an empty file. That empty
  string is the only unsealed value permitted. Empty maps, including tombstones,
  are valid. Values do not have another base64 layer.
- `"base64"`: file values are canonical padded standard base64 of the file bytes.
  This represents binary/plaintext content during existing account mode changes
  and history. It never bypasses the account encryption policy or current key
  checks and is not a client fallback.

Missing, unknown or non-string encodings refuse the entire batch with HTTP 400
`unsupported skill files encoding; update Atem`. Malformed files or encodings,
including mixed plaintext in an `e1-text` row, refuse it with HTTP 400
`invalid skill files encoding`. Unknown operations or malformed operation fields
use HTTP 400 `invalid batch`. Transport validation finishes before any operation
is applied. Policy and store refusals remain per operation; transient failures
remain HTTP 503. Authentication precedes reading the body.

The wire body and its normalized storage JSON are each bounded to 16 MiB, with
at most 16 operations. Oversized requests return 413; the normalized bound uses
`normalized request body too large`. Compact wire encoding cannot increase the
amount of data admitted to storage.

## Preserve the sealed version

Atem binds encrypted skill files to `scope:name:version` in their authenticated
data. Station must never renumber the version after sealing.

A push requires `skill.version = base_version + 1`, with `base_version >= 0`
and both numbers within JavaScript's safe integer range. Invalid pairs receive
per-operation `{ok:false, error:"invalid skill version"}`. Station atomically
compares the base with the maximum stored version for that account and skill,
including tombstones and purged records. If they differ, it returns:

```json
{"ok": false, "error": "version_conflict", "current_version": 3}
```

No row is inserted and no sequence is allocated. This covers exact retries,
fresh random ciphertext for the same attempted version and concurrent writers.
Station does not compare contents. Successful pushes preserve the supplied
version and ciphertext, allocate a sequence, and return the existing result
shape with `superseded_concurrent:false`. The in-memory mutex or PostgreSQL
account lock and transaction covers comparison and insertion across replicas.

Atem resolves a conflict by fetching its attempted version and comparing its
deterministic keyed content hash and metadata. A match acknowledges an earlier
accepted push. Otherwise it pulls, rebases and reseals under the next version
in a later round. It never reuses ciphertext under another version. Deletes
append tombstones and purges clear existing versions with their existing semantics.
Migration rewrites update the exact selected version without renumbering it.

## Storage and read conversion

The HTTP boundary normalizes file strings to the existing base64 storage format.
No database migration or separate cursor is introduced. The durable store repeats
encryption mode/key checks inside its write transaction.

Reads use `e1-text` when all paths and decoded values are envelopes, allowing
empty values. Binary/plaintext or partly migrated historical rows use `base64`.
Obsolete envelopes retain their original keys and bytes. Reads never rewrite
rows, change hashes, versions or sequences. Structural checks do not authenticate
ciphertext; clients retain their decryption checks. Any future signed-write
contract must bind the underlying ciphertext and metadata independently of this
outer encoding.

The submitted `files_encoding` is not stored. Read classification depends on
the paths and underlying bytes, rather than the encoding originally submitted.
Envelope-shaped text under a plain filename remains `base64`; a mixed row also
remains `base64` without changing any file. When every path and nonempty value
has the reserved envelope grammar, the row reads as `e1-text`, including rows
originally submitted as `base64`. This is a representation choice, not proof
that the ciphertext is authentic. Account mode checks and client decryption
remain the authority for those bytes.

`fixtures/skill-file-wire.json` contains exact public storage/wire vectors,
including a sealed row with an empty file. Its synthetic payloads are structural
envelopes, not valid AEAD ciphertext or account material.

## Validation and rollout

Production route tests cover empty-file push and migration readback, stored-row
conversion, exact and newly sealed retries, competing writers, invalid/safe-integer
versions, encryption policy, owner isolation, authentication before body reads,
history, tombstones, purge, binary/obsolete history, body/operation/storage limits,
and large-file expansion. Shared store tests run the same CAS scenarios against
memory and PostgreSQL. A real PostgreSQL route test races separate pools, reopens
the store, and checks durable encryption refusal and storage failures.

Station and Atem ship together after the joint dev test. Older clients receive
the update-Atem refusal; there is no compatibility path. This change does not
authorize a forced account migration, hosted execution or mobile setup activation.
