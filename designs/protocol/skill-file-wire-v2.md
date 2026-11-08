# Skill file transport v2

Status: Astation technical agreement for Atem #130 Task 6 / F8, 2026-11-08.
The Station adapter is implemented on its own branch; no deployment or forced
encryption migration is implied. Atem owns its client implementation and the
joint compatibility run.

Agreement: <https://github.com/Agora-Build/Atem/issues/130#issuecomment-6724888980>.

## Purpose

A sealed skill file is already an ASCII `e1.<kid>.<payload>` envelope. The
legacy `Skill.files` serializer base64-encodes those bytes again. For large
files the two encodings expand ciphertext to about 1.78 times the original
size. V2 carries the envelope directly as a JSON string, about 1.33 times the
original size plus fixed envelope and JSON overhead.

This changes only the HTTP representation. It does not decrypt or re-encrypt
files, change their authenticated data, add author verification, or change R9.

## Routes and schemas

| Method | Route | Response |
| --- | --- | --- |
| GET | `/api/skills/v2?id=...&since=...&limit=...` | `{wire_version:2, skills:[...]}` |
| POST | `/api/skills/v2/batch?id=...` | `{wire_version:2, results:[...]}` |
| GET | `/api/skills/v2/versions?id=...&scope=...&project=...&name=...` | `{wire_version:2, versions:[...]}` |
| GET | `/api/skills/v2/version?id=...&scope=...&project=...&name=...&version=...` | `{wire_version:2, skill:...}` |

Authentication, query semantics and results reuse the corresponding legacy
route. Errors retain its HTTP status and `{error:...}` shape; error responses
do not advertise V2 capability. The history index contains metadata, not files.

The batch request remains `{ops:[...]}`. `push`, `rewrite`, `delete` and `purge`
keep their existing semantics. A `push.skill` and a `rewrite` each require a
`files_encoding` field next to `files`. Each returned skill row also carries it:

- `"e1-text"`: every filename and value is a structurally valid sealed
  `e1.<kid>.<payload>` string. Values are not base64-encoded a second time.
  Empty maps are valid, including tombstones.
- `"base64"`: values are the existing standard, padded, canonical base64 of
  file bytes. This supports historical plaintext/binary content and the existing
  migration. It does not bypass the account's encryption policy. In an encrypted
  account, those decoded bytes must still be valid envelopes for the current key.

For example, V2 carries the following structure; the ellipses here are only
illustrative and are not valid envelopes:

```json
{
  "op": "push",
  "base_version": 0,
  "skill": {
    "scope": "global",
    "project": "",
    "name": "example",
    "version": 0,
    "files_encoding": "e1-text",
    "files": {"e1.0123abcd.<sealed-path>": "e1.0123abcd.<sealed-file>"},
    "content_hash": "h1.0123abcd.<keyed-hash>",
    "source_agent": "cli",
    "source_machine": "example-device",
    "created_at": 1700000000,
    "seq": 0,
    "deleted": false
  }
}
```

`fixtures/skill-file-wire-v2.json` is an exact machine-readable public encoding
vector. Its payloads are synthetic structural envelopes, not valid AEAD
ciphertext and not real account material.

Missing/unknown encodings, invalid base64, malformed sealed fields, and an
`e1-text` row mixing plaintext and ciphertext fail the whole batch with HTTP
400 `invalid skill files encoding`, before any operation is applied. Unknown
operations or malformed operation fields fail the whole batch with HTTP 400
`invalid batch`. Once transport validation succeeds, the existing per-operation
policy/refusal results and transient storage errors apply unchanged.

Authentication precedes reading the body. Both the received body and its
normalized legacy JSON representation are bounded to 16 MiB. The batch retains
the existing limit of 16 operations. The normalized bound prevents compact
transport from bypassing the storage budget. Oversized bodies/normalizations
return 413; the latter uses `normalized request body too large`.

## Shared storage and preservation

V2 normalizes file strings to the existing base64 storage format, then calls the
same skill operations. Store-side transactional encryption checks still apply,
including when the account mode changes during the request. No database migration
or separate version/cursor is introduced.

On reads, a row whose paths and decoded file bytes are all structurally sealed
uses `e1-text`. Historical binary/plaintext or partially migrated rows remain
explicitly `base64`. Obsolete envelopes remain readable in their original form;
serialization never substitutes or rotates their keys. Shape checks do not
authenticate ciphertext: clients retain their existing decryption checks.

Across representations preserve the exact filename/envelope bytes, metadata,
content hash, assigned version, sequence and ordering. A V2 reader can see a
legacy writer's new row, and a legacy reader can see a V2 writer's new row.
History, rewrite, deletion and purge use the same records. A read does not
rewrite stored rows or advance their sequence.

Any later signed-write contract must bind the underlying ciphertext and
metadata independently of this outer transport encoding; F8 grants no
permission to change signed content.

## Client negotiation and rollout

1. Probe the authenticated V2 collection on the exact selected Station and
   require HTTP 200, `wire_version:2` and a valid page before choosing V2 writes.
2. A missing collection route on an older Station permits legacy ciphertext
   transport. This is transport compatibility, never plaintext fallback.
3. Do not downgrade for 401/403, malformed/unsupported successful responses,
   timeouts or 5xx. A per-version 404 means a missing skill version, not a
   capability result. Do not carry capability state to another Station.
4. Never retry an uncertain POST in a different format. Keep the existing
   outcome/retry behavior rather than inventing an extra write for negotiation.

Deploy the adapter only after review and joint compatibility checks. Clients
must still work with older Stations, and existing clients must continue working
with the upgraded Station. This does not authorize the broader E2EE-only forced
migration, plaintext purge, new onboarding policy, or hosted/mobile activation.

## Validation

Station tests exercise real production routes for mixed legacy/V2 writes and
reads, byte/hash/version/sequence preservation, explicit encoding errors,
encryption mode/current key enforcement, owner isolation, authentication before
body reads, history and migration read-back, tombstones/purge, obsolete and binary
history, body/operation/normalized limits, and a 1 MiB file's wire expansion.
An optional local-Postgres test covers cross-connection and reopened-pool reads
and writes using the unchanged durable store.

The Atem client must additionally test new-client/old-Station negotiation,
refusals that must not downgrade, selected-Station changes and uncertain-write
handling. A live old/new compatibility run remains required before deployment.
