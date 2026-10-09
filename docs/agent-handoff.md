# Astation Agent Handoff

Reviewed on 2026-10-08 against `main` at `5460de4`, merged PRs, the task
vault (`v-8ut37j7X`), and read-only production checks. Relay hardening is now
in review in PR #37. This is the current
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

## Identity fixes merged

[PR #36](https://github.com/Agora-Build/Astation/pull/36) merged as `5460de4`.
Keychain and signing failures retain their types. Temporary access failures
have bounded, noninteractive retries; denied, cancelled, and permanent failures
require an explicit action. The UI accurately reports unavailable relay access.
Settings > Security provides authenticated repair of an unusable signing key
and recovery of relay trust without replacing a readable key. A saved recovery
pause survives relaunch and clears only after successful relay verification.
The administrator still performs the relay reset manually; no production
identity was reset. See [device key recovery](relay-device-key-recovery.md).

Validation recorded for #36: 517 Swift tests with six expected skips and no
failures, release/app-bundle checks, and hosted CI pass. Deploy Station run
`37845075840` completed for the merge, followed by successful public health
and identity WebSocket checks. Native app installation remains separate from
relay/webapp deployment.

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

## Relay hardening in review

[PR #37](https://github.com/Agora-Build/Astation/pull/37) implements these
follow-ups in branch `fix/relay-hardening`; they are not yet merged or deployed:

- **Version visibility:** every health response includes the package version
  and embedded build commit. Image workflows supply the commit, final deploy
  verification requires it, and intermediate rolling checks accept mixed builds.
  A public response identifies the answering replica; Coolify completion still
  checks each application deployment.
- **Key-cache concurrency:** a deterministic regression reproduces an older
  full load overwriting a later stale key or dropping its placeholder.
  Advancing the generation on stale marks preserves that fail-closed state.
- **Postgres test isolation:** each test owns a separate schema, including
  reconnects and migration tests. CI runs all database suites together with
  four threads. Previously unrun knowledge fixtures now use base64 file data.

Local validation passes: 445 relay tests, all 45 Postgres tests together,
59 Node tooling tests, a release build, and a live health metadata check.
A clean database run leaves no test schemas. Hosted CI checks the Linux
container metadata and Valkey suites. Use the PR's current checks for status.

## Deferred ideas

These remain unimplemented, but the current evidence does not make them
required work:

- **TCP_NODELAY:** `serve_with_drain()` does not set it; Axum 0.7.9 exposes
  `.tcp_nodelay(true)`. Measure its effect on the observed approximately
  40 ms latency tail before changing defaults.
- **Per-room cache epochs:** the cache still has one global epoch. Optimize
  only if room churn measurably causes excess cache misses.

## Product ideas requiring a separate decision

- **Agent-link:** cross-machine peer discovery and agent messaging remain
  absent from Atem's CLI and need an Astation permission model. Start only
  when requested.
- **Credentials vault:** optional encryption of memory, skills, and vault
  history is already implemented. A dedicated credential store and
  `atem vault get <name>` remain absent; current vault commands manage
  shared notes. Keep credential values out of memory, skills, and handoffs.
