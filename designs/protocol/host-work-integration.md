# Native and Station host-work integration

Status: local implementation ready for draft review; no host-work rollout or new live grants.
This adds to the existing approved dev hosted API. Its separate `host-work-api`
Cargo feature is off in normal/default and existing `hosted-agent-api` builds.
Keep it off until the contract, verifier rollout and live acceptance below pass.

## Shared SDK

Native Apple and Station Rust consume immutable Atem source
`2b0c384e7213e5d4637cdba1f0a78ccbc53a2083`. The Apple archive is production
UniFFI, with no software-key/test/host exports. `Config/atem-client-apple.json`
pins the GitHub artifact, archive SHA-256, every payload hash and clean source
metadata. Both packaged station-route and host-work vectors are checked before
installation; Rust runs the host-work request vectors through the real SDK.
No Atem checkout is edited or built.

Atem PR #114 merged as `42866ac10e9f7ae62d068cebe6be3412503146b8`.
Its final head `2f86fe510163aaeaf8dbf5b566143fbc260811c2` differs from the
consumed SDK pin only in an unrelated daemon test; shared crates and contracts
are unchanged. Authoritative contracts at the consumed pin:

- `designs/protocol/atem-host-work-v1.md`
- `designs/protocol/atem-messages-v1.md`
- `designs/protocol/atem-task-attachments-v1.md`
- `docs/agent-coordination-handoff.md`

## Native behavior

Connections offers **New Agent** for a verified, connected Atem. The sheet asks
the admitted host for locally approved profile IDs, revisions, labels and
providers. It sends no command, directory, arguments or credential values.
Native control and local host consent remain authoritative. Hosts without
`host.launch` give an explanation rather than an older-protocol fallback.

Before launch, Astation persists the immutable request ID, host/trust identity,
profile revision and expiry to a restricted, fsynced local journal. A socket
failure or restart queries that same ID. It never turns an uncertain launch into
a new launch. A response timeout requires a fresh attachment before more
queries, preserving the SDK's bounded exchange registry. A failed journal write
disables new launches. Started, failed and outcome-unknown are distinct states.

**Attach** uses the existing terminal path only after the session registry
contains the returned session and process generation. Process creation alone
does not establish chat readiness. Message/task tracking is query-based because
the current extension has no unsolicited progress subscriptions. A stored
notice, a finished agent turn (`awaiting_result`) and explicit task completion
are separate labels. Tracking IDs can be supplied by the caller; this increment
does not create a durable native message composer/outbox.

Native integration approval has an explicit **Allow annotated mark tasks**
choice, off by default and reset when changing requests. It requires existing
`agent.view` and `agent.prompt` consent. The native review checks the exact
additional signed `message` and `notify` operations; Station cannot insert them
into an ordinary approval. Station also refuses this opt-in unless its separate
host-work build gate is enabled. Existing grants are unchanged.

## Station HTTP adapters

All routes are under
`/api/agent/v1/integrations/:id/hosts/:host`. Their normal authentication remains
Auth-issued integration JWTs bound to issuer, Station audience, owner,
integration, approved service-key fingerprint, expiry and current Portal policy.
The three new scopes are confirmed by Auth #14 and Portal #25 and deployed to
dev (Auth `ad12f8a`, Portal `26e97ed`). They are accepted by Station policy
readers only in a `host-work-api` build.

| Method / suffix | Body | Token scope |
| --- | --- | --- |
| GET `profiles` | none | `agent.launch` |
| POST `launches` | host, request_id, profile_id, profile_revision, expires_at | `agent.launch` |
| POST `launches/:request_id` | host | `agent.launch` |
| POST `messages` | host, immutable message envelope | `agent.message` |
| POST `messages/:message_id` | host | `agent.message` |
| POST `tasks/:task_id` | host | `agent.notify` + `agent.message` + `agent.prompt` |

`agent.view` is required on every integration. `agent.notify` requires both
`agent.message` and `agent.prompt`; launch and message remain independent.
New scopes require a new integration and fresh native consent. Auth issues
five-minute tokens using a fresh private-key JWT assertion, without a refresh
token. Audience/resource is the exact Station origin; owner, client ID and
`r9_svc` retain their existing bindings. The policy feed carries exact stored
scopes. Existing integrations gain no authority.

`host` is the exact account/device/trust-generation triple. It must match the
authenticated channel welcome and route. Requests reject unknown fields.
Remote shell commands, paths, args and environment are never accepted.
Profile IDs/revisions come from approved host configuration. Session-scoped
service grants cannot create a new session.

Executable message recipients additionally require token `agent.notify` and
`agent.prompt`. Every additional scope is rechecked against current policy,
including after channel establishment and before returning a result. Atem
independently enforces signed `message`/`notify`/`prompt`, local route consent,
scope and principal control generation. Sender must equal the authenticated
`service:<id>`; forwarding claims for another principal are refused.

Responses contain `{host, result}` from the SDK-verified, correlated
`host_work_result`. Each HTTP call has a fresh exchange ID; the caller retains
the original launch/message/recipient IDs for retries and queries. Station does
not silently replay a mutation after transport loss. Callers recover with the
query routes. Scope, host, channel, attachment and original identity checks
prevent results from being routed to another request or principal.

This first generic message adapter accepts inline text only. It refuses typed
marks and context snapshots rather than treating a digest as proof of committed
publication or access. PNG marks use their separate authenticated publisher.
Atomic memory/vault write-and-notify and durable cross-host delivery remain
separate work. Task queries return an explicit result already recorded by an
authorized coordinator; these adapters do not publish context or call
`work_complete` on the coordinator's behalf.

These are online adapters, not an offline delivery service. An accepted message
is a durable host receipt, not a promise that an agent ran. Executable work needs
the original principal to retain a live authorized channel. Clients should keep
the existing authenticated host `events` WebSocket open while queued work runs,
and use message/task queries for extension progress. Closing all of that
principal's channels leaves queued work blocked until it reconnects. No stored
encrypted record is replayed on a different channel.

## Ownership and gates

| Owner | Remaining acceptance |
| --- | --- |
| Atem | Supply the immutable `Astation-online-mark` sender commit/patch mentioned in its handoff; isolated runtime/profile/route setup for native live acceptance |
| Astation / Station | Integrate that publisher and publish the local marks endpoint; complete actual-host native launch/attach and hosted result-routing acceptance |
| Auth #14 | Contract confirmed and issuance deployed to dev; joint live acceptance remains |
| Portal #25 | Scope consent/validation and exact change feed deployed to dev; joint live acceptance remains |
| Portal Admin | Optional capability/diagnostic visibility; no required protocol change |

Native integration parsing and review accept all eight exact token scopes and
enforce notify prerequisites. Before signing new operations, native approval
checks live authenticated capabilities and host trust generations for every
selected host, both before and after owner authentication. Disconnection or
replacement cancels unsigned consent; saved signatures retain exact retry
behavior. The review also requires upgrading other strict account verifiers.
Native member launch does not depend on service-token scopes.

Atem v0.8.2 (`953afb7`) contains PR #114 and clears the release gate. Running
host upgrades and locally approved launch profiles/routes still require live
verification; a published release does not upgrade the disposable Genie host.

Before enrolling `launch`, `message` or `notify`, upgrade **every participating
strict membership verifier**: Atem hosts, Station replicas, native controllers
and other SDK consumers of the account log. Feature negotiation alone cannot
make an old strict log reader accept new signed operation names. Do not use a
live account grant as a rollout probe.

The marks publisher is requested at
https://github.com/Agora-Build/Atem/pull/114#issuecomment-6592805957.
Coordination continues on Atem #81. Auth/Portal contract requests:
https://github.com/Agora-Build/Auth/issues/14 and
https://github.com/Agora-Build/Portal/issues/25.

Local sender tests use isolated Postgres, real HTTP/JWT validation and signed
encrypted host fixtures. They do not establish live Claude/Codex launch,
actual provider readiness, deployed mark delivery or a completed native release.
No retained Genie agent, approved integration, production flag or running
provisioned app is changed by these tests.

## Local validation

- Native app: 1,167 tests, 20 environment skips, no failures. Includes journal
  restart, private file permissions, stale-view merges, corrupt records and
  fail-closed persistence checks.
- Portable native adapter: 178 tests, one platform skip, no failures. Covers
  launch loss/restart, feature/control gates, pending-exchange bounds, task
  versus turn completion, and exact opt-in mark scope review.
- Relay: 560 unit tests pass in the host-work build. Eight isolated Postgres
  hosted API tests and the mark enrollment test pass. The new real-HTTP case
  verifies JWT scope separation, original launch identity recovery, authenticated
  message senders, per-recipient task result routing, stale hosts and revocation.
- The pinned production Apple library passes 36 consumer checks; artifact,
  source metadata and packaged fixture integrity are verified. Release/artifact
  tooling has 23 passing tests; workflow tooling has 67.

These are local results, not deployed/native-provider acceptance. CI results
and actual-host release evidence are recorded separately on the draft PR.
