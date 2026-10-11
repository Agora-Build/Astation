# Astation Agent Handoff

Updated on 2026-10-11 for merged encryption and credential UI work against
`main` at `91d5a23`. The prior operational audit on 2026-10-10 checked `b426292`,
open PRs, worktree state, and production verification. The original 2026-10-08
audit also checked the task vault (`v-8ut37j7X`). This is the current follow-up
list; implementation and deployment history remain in Git and the vault. Read local `AGENTS.md`
instructions when present, then
[CLAUDE.md](../CLAUDE.md), [README.md](../README.md), and
[DEPLOY.md](../DEPLOY.md) for repository rules and runbooks.

## Current baseline

PRs #39-#42 are merged. Production deployment of `91d5a23` passed in
[Deploy Station run 38125486057](https://github.com/Agora-Build/Astation/actions/runs/38125486057);
public health and both identity WebSocket paths passed, with two relay replicas
and healthy Redis/Postgres stores. Native app installation is separate from
relay/webapp deployment. See the user-facing [credentials guide](credentials.md)
for current pairing, key-agent upgrade, project-picker and migration steps.

Production uses two relay replicas with Postgres and Valkey. After PR #38
deployed on 2026-10-10 as `28c6320` (Deploy Station run `38104654861`),
HTTPS and both identity WebSocket paths passed verification, and
the public `/health` returned `status: ok`, `redis: ok`, `replicas: 2`, and
Postgres knowledge/vault stores. On 2026-10-08, a read-only `CONFIG GET` on
the production Valkey container confirmed `maxmemory: 536870912` (512 MiB) and
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

## Relay hardening merged

[PR #37](https://github.com/Agora-Build/Astation/pull/37) was squash-merged
as `d09f854` after review found no critical issues and CI passed on the final
head `f999a1c`. These follow-ups are implemented and no longer pending tasks:

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
A clean database run leaves no test schemas. CI run `38105747186` passed
macOS builds/tests/app packaging, web/tooling tests, all relay/Postgres/Valkey
suites, and the Linux container metadata check. The resulting production
rollout is recorded in Deploy Station run `38106294228`; use its completion
and public health/build-commit checks to confirm deployment.

## Encryption implementation merged

[PR #39](https://github.com/Agora-Build/Astation/pull/39) merged as `f9c52dd`
and implements device verification, storage-key escrow/unlock and durable encryption migration.
Retain the app worktree while the running Local.app resides there.
See [device verification](atem-device-verification.md) for the protocol,
personal-team signing and the live test checklist.

The local migration implementation captures authenticated device and connection
context before dispatch, journals accepted reports, and commits completion
durably and idempotently after migration and cryptographic validation. Its
lifecycle and security invariants are documented in [designs/e2e-encryption.md](../designs/e2e-encryption.md).
The relay must never establish device identity or authorize
encryption state. Retain the design and regressions with the implementation.

Final local verification passes the provisioned 638-test Swift run with six
expected skips, including 28 migration regressions and real Keychain/Secure
Enclave recovery. The release build, 446 relay tests, three core suites,
59 Node tooling tests and web checks pass. All 48 protocol fixtures match
Atem `main` at `b73add8` byte for byte.
Immediate disconnection, delayed execution, duplicates, reconnects, interrupted
recovery, and revocation races have regression coverage. Live lock/unlock,
approval, denial, revocation, storage-key rotation, re-pairing, and migration
to ON were subsequently confirmed with Genie. Atem PRs #40 and #41 are merged.
Those completed checks are not pending build tasks.

Review fixes remove a direct-socket/main-thread deadlock: immutable authenticated
route/account snapshots are captured under a short lock and accepted reports
are journaled on the calling thread. Connection generations use socket UUIDs.
An account without locally approved encryption state displays Unavailable and
disables changes. Only owner-approved device verification establishes the
initial signed Off state; a relay report cannot create it.

Remaining live verification includes OFF and OFF-then-ON; these checks have not
been recorded and must not be claimed complete. Currently an updated, unlocked
`atem cred unlock` or `atem pair` finishes a pending migration; `atem sync`
talks only to the relay. Making sync connect to Astation to finish migration
is a proposed behavior change, not an approved requirement.

A separate observed relay issue also remains unresolved: an Atem connection
received HTTP 404 "Room not found" while Astation was running. Relaunching
Astation recreated the room and restored access. The reason the room vanished
has not been established; reproduce it and inspect room ownership/heartbeat
refresh before declaring it fixed. The optional account verifier warnings do
not establish the cause of this 404.

## Unified agora.build SSO: approved direction

PR #38 records the product requirements in the
[unified identity specification](specs/2026-10-10-unified-agora-build-identity.md).
The agora.build/portal project is to implement shared accounts for Astation,
Atem, Vox, and future products, with GitHub, Google, Apple, and Agora as linked
sign-in providers. The proposed SSO service and hostname are not deployed.

Keep `AGORA_ACCOUNT_USERINFO_URL`, `AGORA_ACCOUNT_SUBJECT_FIELD`, and
`AGORA_ACCOUNT_AUTH_TIME_FIELD` unset in the current deployment. They are an
optional legacy Agora account verifier, not prerequisites for pairing, sync,
E2EE, or the future SSO. Retain the compatibility code until the replacement
integration and migration are tested. Permanent account IDs, validated token
issuer/audience, provider linking, separate Agora resource credentials, and
Astation's independent E2EE approval boundary remain requirements.

## Deferred ideas

These remain unimplemented, but the current evidence does not make them
required work:

- **TCP_NODELAY:** `serve_with_drain()` does not set it; Axum 0.7.9 exposes
  `.tcp_nodelay(true)`. Measure its effect on the observed approximately
  40 ms latency tail before changing defaults.
- **Per-room cache epochs:** the cache still has one global epoch. Optimize
  only if room churn measurably causes excess cache misses.

## Product ideas requiring a separate decision

- **Agent-link:** cross-machine peer discovery and agent messaging need an
  Astation permission model and a separately agreed product scope. Check the
  current Atem implementation before treating the original feature list as
  missing work.
- **Credential service:** the local Settings > Credentials editor now stores
  named secrets in the protected Mac Keychain, with project/global scopes and
  Touch ID for save/update/delete/copy. See [credentials](credentials.md).
  Its project picker includes encrypted reports from updated, unlocked Atem
  devices and saved scopes; manual Git-remote entry remains available.
  Companion Atem reporting and original-case labels are merged in Atem PRs
  #44 and #46; Astation PRs #40-#42 provide the editor, embedded Touch ID and
  case-insensitive scope identity. Update both the CLI and its key agent.
  The designed Atem get/list integration, signed manifests and scope grants
  remain separate work; current Atem does not implement those commands. Local
  credentials are not published to the relay. Keep values out of memory,
  skills and handoffs; the shared-notes vault is separate.
