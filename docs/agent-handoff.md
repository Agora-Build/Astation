# Astation Agent Handoff

Reviewed on 2026-10-08 against `main` at `b2db3cc`, merged PRs, the task
vault (`v-8ut37j7X`), and read-only production checks. This is the current
follow-up list; implementation and deployment history remain in Git and the
vault. Read local `AGENTS.md` instructions when present, then
[CLAUDE.md](../CLAUDE.md), [README.md](../README.md), and
[DEPLOY.md](../DEPLOY.md) for repository rules and runbooks.

## Current baseline

Production uses two relay replicas with Postgres and Valkey. On 2026-10-08,
the public `/health` returned `status: ok`, `redis: ok`, `replicas: 2`, and
Postgres knowledge/vault stores. A read-only `CONFIG GET` on the production
Valkey container confirmed `maxmemory: 536870912` (512 MiB) and
`maxmemory-policy: noeviction`. Relay-a's host port 3000 is closed; its removal
was recorded in vault entry e5 and direct access was rechecked during this
audit. GitHub's secret inventory no longer contains
`COOLIFY_RELAY_SERVER_WEBHOOK_URL`.

Relay identity, reconnect backoff, account recovery, account grouping/device
removal, and optional account-data encryption are implemented (PRs #19, #27,
#28, #30, #31). The task vault records successful real-Mac verification and
reconnection across a rolling deploy (e6/e7). The local two-relay
30,000-socket, 30-minute load test passed in PR #29; its measurements and
deployment limitations are recorded in [DEPLOY.md](../DEPLOY.md).

## Remaining identity work

### Keychain failures: still worth fixing

`preloadRelayIdentityKeyIfNeeded()` in
`Sources/Menubar/AstationHubManager.swift` retries `.failed` on each reconnect
and discards the error type. Network retries already have bounded backoff,
but a permanently undecodable key is retried too. The menu still describes
every load failure as "unreadable" and says relaying works even though a
registered identity without a valid proof is rejected and disconnected.

Preserve the underlying error, distinguish temporary access failures from
permanent key damage, and offer an explicit retry or repair action. A failed
read must never silently replace the stored signing key. This is a support
and failure-handling improvement; this audit did not reproduce a user-facing
failure.

### Signing-key repair: still missing

The Account Recovery Kit restores the Astation ID and relay URL. The
encryption recovery key restores account-data encryption. Neither restores
or repairs an unreadable relay signing key. A guided repair flow remains
useful, with device-owner authentication and coordination with the relay's
admin reset. Until then, use the [admin-reset runbook](../DEPLOY.md).
Do not automatically delete the Keychain item or reset a production identity.

### Targeted Mac checks: retain for identity changes

The initial build/release and reconnect checks are complete. There is still
no recorded end-to-end result for these specific cases:

- Reconnection and signing while the screen is locked, after first unlock.
- Denied Keychain access or an undecodable key: accurate UI, bounded retry,
  and no overwrite of persisted key material.
- Local and relay pairing bindings surviving a relay restart and becoming
  unusable after session removal or expiry.
- A complete different-ID recovery on an isolated Mac/account, and password
  fallback on a Mac without Touch ID (vault e6 explicitly left these unrun).

Use isolated identities and local relays for failure/recovery cases. These
are validation gaps, not evidence that the implemented flows are broken.
See [Relay identity](astation-relay-identity-handoff.md) for the protocol and
test entry points. Old-relay compatibility is relevant only if supporting
a deployment that predates relay identity; production already supports it.

## Conditional operations work

- **Capacity claim:** a 30,000-socket, 30-minute test through Cloudflare on
  production-like deployment hardware is still needed before claiming 10k
  users on that deployment. The local run excludes TLS and Cloudflare.
  Schedule a window, temporarily adjust per-IP limits, restore them, and
  clean up test identities as described in [DEPLOY.md](../DEPLOY.md).
  The local test does not need repeating merely to close the old checklist.
- **Version visibility:** `/health` still omits the build commit. Adding it
  would help confirm which version is serving during a rollout; readiness
  checks already work without it.

## Deferred ideas

These remain unimplemented, but the current evidence does not make them
required work:

- **TCP_NODELAY:** `serve_with_drain()` does not set it; Axum 0.7.9 exposes
  `.tcp_nodelay(true)`. Measure its effect on the observed approximately
  40 ms latency tail before changing defaults.
- **Per-room cache epochs:** the cache still has one global epoch. Optimize
  only if room churn measurably causes excess cache misses.
- **Key-cache placeholder/full-load interleaving:** `mark_stale()` does not
  bump the generation checked by `load()`, so a full load can drop a
  concurrently inserted placeholder. Retain as a focused concurrency
  investigation if changing this cache, including the effect on pending
  versus legacy room admission. Existing concurrent set/forget tests cover
  a different path; this audit did not reproduce the interleaving.
- **Postgres test isolation:** identity and knowledge test harnesses still
  reset shared tables under separate suite-local locks. Per-test schemas or
  databases would be useful before running these suites together in parallel.
  Keep the current suites on disposable test databases in the meantime.

## Product ideas requiring a separate decision

- **Agent-link:** cross-machine peer discovery and agent messaging remain
  absent from Atem's CLI and need an Astation permission model. Start only
  when requested.
- **Credentials vault:** optional encryption of memory, skills, and vault
  history is already implemented. A dedicated credential store and
  `atem vault get <name>` remain absent; current vault commands manage
  shared notes. Keep credential values out of memory, skills, and handoffs.
