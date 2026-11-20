# Station verifier inventory

Part of Astation #79 and the agreed R9.2 all-verifier signing gate. This is
Station-private HTTP carriage for deployment evidence, not an R9 wire change.
It does not activate delegated work or supply the complete native participant
provider. Hosts still report through their encrypted, authenticated welcome.

## Deployment roster and process evidence

A participating Station configures all its replica slots explicitly. Redis
presence, a successful health response and a live-socket count cannot establish
which unavailable verifiers still need checking. The roster is independent of
those sources and never shrinks when a lease expires.

Reporting is opt-in, only after the existing delegated build/runtime gate and
durable recovery generation are initialized. For a two-replica deployment:

```text
RELAY_REPLICAS_EXPECTED=2
STATION_VERIFIER_CONFIGURATION={"generation":1,"replica":"station-1","replicas":["station-1","station-2"]}
```

Each process has its own `replica` value. Every process uses the same sorted
complete `replicas` array and positive roster generation. The number of slots
must match `RELAY_REPLICAS_EXPECTED`. IDs contain 1-128 ASCII letters, digits,
periods, underscores, colons or hyphens; at most 64 slots are allowed. JSON is
strict, including duplicate-key and unknown-field rejection. Neither this
configuration nor its generation is signing authority.

The operator must enumerate every verifier process serving the origin. This
initial implementation supports an explicitly enumerated deployment; it is
not dynamic discovery or proof that an operator omitted no separate process.
Every replica must run the reporting code before a manager accepts the roster.
An unconfigured/unknown replica cannot be inferred compatible from its release.

Migration 0016 separates the durable roster from process reports. Each process
records the shared core's own `VerifierInventory::ours()`, a new random session,
an increasing slot connection generation and its recovery generation in one
transaction. A deferred commit failure publishes none of them. The previous
highest inventory survives process replacement; lower versions, narrower
actions or changed same-version rules invalidate evidence rather than replacing
that high-water mark.

Reports expire after 30 seconds and renew every 10 seconds. Renewal checks the
same roster, process, connection generation and recovery generation, plus both
the database lease and a process-local monotonic deadline. Expiration cannot
revive the same session. Clock rollback outside the allowed lease interval
produces no evidence. Read/renew/register operations also hold the durable
recovery fence. Reports restored from an earlier recovery generation do not
become live after a separately completed recovery reopens the fence.

An opted-in process checks its current roster/slot at recovery operations,
signing/reporting and existing socket write boundaries. Shared row locks remain
held through those operations, so replacing the slot waits for admitted work.
An expired or replaced process cannot serve merely because its supervision tick
has not run yet. A failed renewal triggers the existing relay drain supervisor.
Orderly shutdown withdraws its report after draining; a failed withdrawal leaves
the slot required and its finite report expires.

### Replacing a process

Drain and stop the old process for a slot before starting its replacement.
A concurrent process cannot acquire the same live slot. If withdrawal failed,
wait for the 30-second lease to expire. Configure this opt-in deployment to
replace each slot after its old process stops; a start-before-stop blue/green
deployment with the same slot is intentionally refused. This configuration is
not enabled in the current dev deployment and changes no ordinary relay rollout.

Changing the slot set requires a higher roster generation on all processes.
That retires the previous configuration. The native signer does not silently
accept the new manifest or remove missing participants: a fresh protected
manager review is required. Preserve inventory high-water rows for removed
slots; this increment introduces no pruning or reset command.

## Account-private HTTP

`GET /api/remote/v1/logs/{genesis}/verifiers` uses the existing per-origin account
access token and returns `Cache-Control: no-store`. It reads account ownership,
the shared-verified membership and all configured report slots in a single
repeatable-read transaction, protected by the recovery/replica fence. The
response contains the exact account, genesis and membership head; those values
are correlation context, never a substitute for the client's anchored log.

```json
{
  "origin": "https://station-dev.agora.build",
  "roster_generation": 1,
  "account_id": "account",
  "genesis_hash": "<64 lowercase hex characters>",
  "head": {"seq": 4, "hash": "<64 lowercase hex characters>"},
  "replicas": [
    {
      "id": "station-1",
      "connection_generation": 2,
      "verifier": {"version": 2, "actions": ["<shared action set>"]},
      "authorization_ms_left": 29700
    },
    {"id": "station-2", "connection_generation": 1},
    {"id": "station-3"}
  ]
}
```

The illustrative rows show the three exact shapes: live, previously connected
but unconfirmed, and never connected. They do not imply a two-slot configured
roster may return a third slot. An absent/null/expired inventory is never a
confirmed report; the server omits the field for an unconfirmed slot. It sends
neither null inventories nor a release-derived capability guess. An unknown
or other-account root has the same metadata-free 404. Missing reporting
configuration, a stale process or a recovery fence returns 503. No endpoint
allows an account bearer to write another member's capability claim.

Requests have a 10-second server deadline, SQL statements a five-second bound,
and reports have at most 64 slots. Native HTTP retains its 256 KiB bound, token
scoping and redirect refusal. Unauthenticated requests receive no roster.

## Native consumption

`RemoteRecoveryHTTP.stationVerifiers` captures a ContinuousClock timestamp
before account-token acquisition and the network request. Its strict reader
checks the response shape, exact origin/genesis, bounded integer fields, ordered
unique slot IDs and verifier inventory shape. Missing slots remain required.

`RemoteStationVerifierEvidence` requires an independently accepted roster and
the anchored account/genesis/head. Each poll has a fresh local token; a retired
response or failure cannot affect a newer one. A changed roster/head/account,
lower process generation or refused/narrower inventory clears evidence. Slot
identities include an origin digest so identical slot names on different
Stations cannot share a gate entry. Poll failure/disposal clears its connections.

The gate consumes each report's remaining lifetime from **request start**,
including token refresh, response delay and system sleep. It rechecks expiry
at the protected signing boundary even if no close callback or timer ran. A
fresh authenticated poll can renew evidence, but reusing an old snapshot cannot
move its original deadline. No live report survives constructing a new provider.

## Remaining integration

The production native constructor still supplies no all-participant provider.
Protected manager roster acceptance, authenticated reports for other native/SDK
members, complete Station discovery and the shared `required_version` helper
remain required. A Station replica report proves only that replica's own core;
it cannot confirm a host, member or unrelated SDK. OAuth login alone cannot prove
that a reporter owns a signed-list member key. Shared host welcomes and local
protected-key evidence retain their separate authority boundaries.

This implementation can be reviewed/tested independently of those remaining
requirements. It is not VII.A evidence and leaves all new signing/delegated
execution/proxy opt-ins off. The current provisioned app and shared test host
are preserved.
