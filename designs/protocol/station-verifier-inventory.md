# Station verifier inventory

## Station-managed service evidence

`POST /agora-build/v1/logs/{genesis}/verifiers/services` uses the existing
native `astation.remote` bearer authorization for this exact Station. The body
contains exactly `member_ids` (1-64 sorted, distinct IDs) and `expected` (the
independently anchored device-list head). The request is limited to 16 KiB and
the operation to ten seconds. Responses are account-private and `no-store`.

The reply has the existing replica snapshot fields plus `services`, in the
exact requested ID order. Each row is `{id}` when unconfirmed, or
`{id, auth_key}` for a Station-managed P-256 key. In one repeatable-read
transaction, Station holds the recovery/fleet fences and membership row,
checks its exact issuer/origin/owner/provisioning/genesis binding, opens only
the existing sealed key, checks its approved fingerprint, and compares any
existing active service member's key. A removed/native member, foreign or
unmanaged ID supplies no service evidence. Missing or corrupt keys never
trigger generation, replacement, signing or provisioning. Cross-account roots
return the same metadata-free 404 as other account storage.

A pending enrollment may report its already durable provisioning key before
membership append. The native adapter accepts this only for the exact shared-
decoded unsigned enrollment request, reconstructed against the current manager
and device-list head, including the proposed public key. An arbitrary absent
member is refused. This report does not sign, append or authorize enrollment.

The gate retains the complete prospective signing request with this evidence,
not only the member ID or public key. A different key, scope, expiry, signing
time or other request field needs fresh matching evidence. Generic member
reports cannot authorize a new enrollment. Missing/invalid reports, reconnect
and retirement clear the binding; its finite lease still expires at signing.

The native source checks the protected accepted Station roster, exact account,
genesis and head, and every reported key. All accepted replicas must have live
evidence. Service capabilities are their common action set and lowest version;
the shortest replica lease bounds the service evidence from request start,
including token acquisition and response delay. Failed polls, key mismatch,
missing replicas, expiry and explicit retirement clear evidence. Delayed retired
polls cannot replace newer evidence; replayed response bytes cannot extend a
lease. Production signing still needs the complete participant owner.
Native/third-party SDK members require their own
authenticated source; a Station cannot use this endpoint to confirm them.

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

### Protected server-list review

The native Host Sending Access window offers **Review Station Servers...** even
while new-action signing is disabled. A current manager reviews the exact
origin, roster revision and complete slot list. Removed slots are listed
separately, with an explicit warning that they will no longer be checked.
The list is not accepted merely by opening the window or fetching a response.

Saving requires fresh Touch ID or Mac password confirmation. The coordinator
checks the anchored account/genesis/head and the manager's local public keys
before and after confirmation, fetches the same manifest again and writes the
reviewed roster to the existing protected account checkpoint. A changed head,
account, manager, selected Station or manifest requires another review. Reviews
expire after five minutes; the final refresh and commit must complete within
30 seconds of confirmation. A replaced or already consumed review cannot be
replayed. Roster revision rollback and changed contents at the same revision
are refused. An uncertain checkpoint write fences the coordinator until reload.

At most 64 accepted Station rosters are retained. Acceptance persists the
reviewed roster and genesis, not a live capability report, signature or reusable
owner confirmation. Restart must still collect fresh independently authenticated
evidence for every required participant before any new signing can be enabled.

## Remaining integration

### Local native evidence source

`AstationLocalVerifierEvidence` reads the loaded SDK's `verifierInventory()`
directly. It checks the existing protected signing and encryption public keys
against this active native member in the exact anchored account/genesis/head.
Missing or locked identity storage fails without creating or replacing keys.
Only this member can be confirmed; another native member, hosted service or SDK
consumer still needs its own authenticated evidence.

The caller must refresh this source synchronously at the signing boundary and
on identity/membership lifecycle changes. A failed check, changed account/head,
retirement or disposal clears its gate connection. A failed source cannot be
revived by replaying an older snapshot; reconstruct it only after establishing
the current anchor and identity. Both the local and Station adapters check their
log against the gate's exact anchor before confirming a consumer.

This source is implemented and tested, but the production participant provider
and new-action signer remain unset pending complete production sources.
It sends no network report, signs no capability claim and establishes no evidence
for another process. No ordinary signing or verification ceremony is changed.

The production native constructor still supplies no all-participant provider.
The shared `required_version` classifier and verifier-report primitives are
available in the current Apple, Android and Station pin `atem-client-sdk-1952ec8ad03f`.
Complete protected participant enumeration and production polling remain required.
A Station replica
report proves only that replica's own core;
it cannot confirm a host, member or unrelated SDK. OAuth login alone cannot prove
that a reporter owns a signed-list member key. Shared host welcomes and local
protected-key evidence retain their separate authority boundaries.

This implementation can be reviewed/tested independently of those remaining
requirements. It is not VII.A evidence and leaves all new signing/delegated
execution/proxy opt-ins off. The current provisioned app and shared test host
are preserved.

### Native and external SDK process proofs

`RemoteMemberVerifierEvidence` uses the actual shared report builder/verifier,
not an app protocol parser or a release-derived inventory. It consumes an
explicitly reviewed list of `(member, slot, process)` tuples. The process is the
loaded SDK's `verifierReportProcess()` value; a key alone does not identify every
process using that key. A process replacement needs a protected roster review.
Missing or expired slots stay required, and this collector cannot discover or
silently remove them. Hosts and Station replicas retain their separate sources.

Call `begin` before token acquisition or passing a challenge to any carrier.
The shared helper mints a fresh nonce for the exact member/service, configured
slot, normalized Station origin and increasing connection generation. The
consumer retains that expectation and a local ContinuousClock deadline, at most
30 seconds including token work, network delay, verification, persistence and
sleep. A service's signed membership expiry also caps that deadline.

`receive` verifies the signed bytes against the independently anchored current
membership and the stored expectation. The report must be at the exact current
head and name the reviewed process. Wrong signer/slot/signature input cannot
consume another slot's expectation. A matching report is single-use; replay
cannot renew evidence. A second authenticated process for the same challenge
conflicts even after the first response was consumed. A conflict keeps the
member unconfirmed; it does not select the latest process.

All reviewed slots for one member must be confirmed. The gate receives only
their common actions, lowest version and earliest deadline. Call `refresh` with
the fresh membership and wall time synchronously at the protected signing
boundary. The gate itself also enforces the monotonic deadline without needing
timer delivery. An account/key/head/roster/recovery/association change retires
the collector through its current-context fence. Old failures and retired
responses cannot overwrite a newer request.

`RemoteMemberVerifierJournal` retains per-member/slot inventory high-water marks
and conflicts across consumer restarts. Its production backend uses the existing
no-interaction protected Keychain store and exclusive cross-process file lock.
The initial protected roster review may explicitly create an empty journal;
ordinary reload refuses a missing journal. The complete account/genesis/origin
binding, duplicate-free bounded checkpoint and monotonic inventory rules are
checked on load/update. Save and read-back complete before any proof is exposed
to the gate. An uncertain write retires the collector. Stored history never
restores a live report, challenge, deadline or owner confirmation. There is no
automatic conflict-clear or history-pruning operation.

Apple's `RemoteAppleDeviceIdentity.loadExisting` and Android's
`MobileDeviceIdentity.open(existingOnly = true)` load existing protected keys
without creating an identity. Their typed `verifierReport` methods and the Mac's
`AtemE2EIdentity.verifierReport` let the shared SDK construct the complete signing
body and bind it to the current member's keys. Apple explicitly disables
LocalAuthentication interaction for key validation and signing; Android uses
its existing unlocked-device Keystore path without opening a biometric flow.
No routine-channel owner confirmation is reused or requested. Missing, locked,
foreign or changed keys/storage produce no report and never trigger replacement.
The reporters also require a protocol account/genesis anchor captured from
independently trusted native membership. They check it before and after signing;
the caller's current-context fence binds the active login and selected Station.
An Agora.Build OAuth subject scopes identity storage but is not the protocol
account ID. Reporting never equates those two identifiers.

These adapters and their crash/lifecycle tests are implemented. The production
participant provider, protected process-roster review and polling lifecycle
remain explicit #79 work, along with the separate durable author barrier and
recovery assembly/publication/reopening. Delegated activation stays off until
the whole provider and VII.A are verified; existing hosted execution is unchanged.

### Account-private challenge carriage

The following endpoints reuse this exact Station's existing native account
bearer and recovery-root ownership. They require the separate delegated
build/runtime opt-in. A bearer allows carriage only; it does not sign a report
or establish membership, process identity, freshness or compatibility.

| Method | Suffix under `/api/remote/v1/logs/{genesis}` | Body |
| --- | --- | --- |
| POST | `/verifier-reports` | `{challenge, expected}` |
| GET | `/verifier-reports/{nonce}` | none |
| POST | `/verifier-reports/{nonce}` | `{report}` |
| DELETE | `/verifier-reports/{nonce}` | none |
| POST | `/verifier-requests` | `{signer, slot, expected}` |

`challenge` is the unchanged shared-library challenge object; `expected` is the
consumer's independently anchored device-list head. `{nonce}` is its canonical
32-byte base64url nonce. The mailbox reply is exactly
`{challenge, expected, reports:[<signed report objects>]}`. Inbox replies are
exactly `{challenges:[<challenge objects>]}` for the requested signer/slot/head.
Closing returns `{closed:true}`. Roots owned by another account return the same
metadata-free 404 as an unknown root. Every response is `no-store`.

Station uses the shared challenge reader and report verifier, checks the exact
configured origin, active signer, unexpired challenge and current expected head,
and rejects frozen membership. It verifies each report before retaining it.
The client repeats authentication against its own pinned membership. Station
may carry an authenticated ancestor report so its process conflict is not lost;
the native consumer continues to refuse ancestors as live signing evidence.

The mailbox retains up to four distinct authenticated processes per challenge.
Each process's report body is immutable. Retrying the same signed body, including
a different valid signature over it, returns the retained report without
extending expiry. Distinct processes are returned together, never overwritten
by the latest response. A changed body for the same process is refused. Excess
reports or pending challenges return 429 and cannot confirm a verifier.

All root updates use the existing transactional recovery store, account lock
and configured recovery/replica fences. A failed or uncertain write acknowledges
no new report. Replica and restart reads retain committed bytes, not live trust.
The operation has a ten-second deadline and five-second SQL statement bound.
Request bodies are limited to 16,640 bytes; shared challenges to 4,096 bytes and
reports to 16 KiB. At most 128 challenge slots exist per account root, including
expiry/closure tombstones retained for a further 30 seconds. At most sixteen
unexpired challenges target one signer/slot, bounding inbox replies. HTTP
responses remain within the native 256 KiB bound. Re-creation cannot change an
existing nonce's challenge, head or expiry or reopen a closed challenge.

`RemoteRecoveryHTTP` implements these native carrier calls, refuses redirects
and foreign-origin challenges before acquiring a token, and strictly checks
the reply's challenge/head/shape/limits. `RemoteMemberVerifierPoller.poll` is a
scheduling primitive for an explicitly reviewed slot. It mints a challenge
before token acquisition, checks later mailbox reads for additional process
responses, and starts a new round after ten seconds. A repeated signed body
cannot consume or renew evidence. It authenticates the entire batch before
exposing any new proof, rechecks the trusted context after each await, and
withdraws evidence on a current poll failure. Overlapping requests for one slot
are refused. Retirement invalidates in-flight responses and the evidence owner.
The complete native provider must schedule these calls and retire the owner on
account, identity, selection, recovery, roster and membership lifecycle changes.

This slice does not schedule production jobs, grant service tokens access to
native endpoints, or add a protected roster editor. An external SDK service
still needs its separately authorized carrier; its report cannot be inferred
from a native process or a Station-managed service. No report secret or private
key is uploaded, and no new signing/execution gate is enabled by these routes.

### Manager review of a member's verifier processes

In the Mac app, open **Manage Host Senders** and choose **Review Member
Processes**. Select an active native or service member from the signed device
list. Enter every SDK process that uses its key, including offline processes.
Each row contains the configured slot name and the process's SDK identifier.
The editor shows this Mac's identifier when reviewing its member. For a remote
process, the operator supplies the identifier obtained from that process.

The final review shows the Station, member, device-list revision, proposed
rows and removed entries. A manager confirms with Touch ID or their Mac
password. The coordinator rereads the signed list, checks the existing
manager keys and saves the exact rows in the protected account checkpoint.
Changing the selected Station or device-list head invalidates the review.
On a later head the previous rows are available for editing, including offline
slots. A successful save cannot clear the conflict journal or supply live
evidence. Older app versions refuse a checkpoint containing process rosters.

The review covers one member at one Station. The production provider must
establish coverage for every active member, host and Station replica, and
obtain independent evidence from every required process. Third-party service
carriage, production polling and VII.A are still open.
