# Delegated Station database recovery

Implementation requirements for Astation #79. The deployment-generation fence,
operator inspection/fencing and operation/write-boundary checks are implemented.
Durable preparation now retains a recovery checkpoint and replacement feed
identity behind the closed fence. Complete snapshot recovery and reopening are not yet
implemented or approved as joint-test evidence. Delegated activation remains
disabled. Ordinary process or replica restarts keep the existing feed identity;
restoring a backup or losing history requires a new identity.

## Why a restored UUID is insufficient

The recovery root currently stores its feed UUID, records, signing high-water
marks and acknowledgment ledger in one Postgres transaction. This protects
against concurrent replicas and failed commits. Restoring the database also
restores all four values. The restored root cannot establish that no newer
hold, revoke, interrupt or signing reservation existed after the backup.

Minting a new UUID alone fixes the cursor identity but cannot reconstruct those
missing stops. Replaying the restored Portal active snapshot cannot establish
that a native manager never revoked the principal. Wall-clock time also cannot
recover a lost signing high-water mark.

The recovery implementation therefore needs a deployment-controlled recovery
generation outside the restored backup, a durable recovery fence, and a
verified complete snapshot. The generation is an operational rollback fence;
it grants no signing or host authority. The UUID alone supplies no such
protection.

## Implemented fence and operator commands

An opt-in delegated deployment must set
`STATION_DELEGATED_RECOVERY_GENERATION` to a canonical positive integer in its
external deployment configuration. It starts at `1` for a genuinely new Station.
All its replicas use the same normalized `PUBLIC_BASE_URL` and generation.
The generation must never be restored from the database backup, reset to `1`,
or decreased. Increase it before **every** restore or history-loss recovery,
including a backup taken before any delegated root existed. This is an explicit
operational input: the code cannot detect an unannounced restore that reuses
both the old configuration and the old database.

Migration `0015` stores the highest generation and a ready/fenced state per
Station origin. Initial generation `1` can bootstrap only when there is no
delegated feed history in the database. Existing history with no recovery row,
a missing row at any later generation, or an increased generation closes a
durable fence. A stale generation cannot lower it; the same generation cannot
reopen it. Changing the Station origin does not bypass the history check.
Initialize all genuinely new origins sharing a database before creating feeds.

The server refuses delegated startup if the generation is absent, malformed,
stale or fenced, or if fence initialization cannot commit. Running upgraded
replicas check the durable fence before feed/ACK operations, reservations,
service signing, host-route admission and socket writes. A frame queued before
the fence is discarded at the actual sink boundary. Reports hold a shared fence
lock through HTTP delivery and settlement. An operator fence commits only after
already admitted writes/deliveries finish; later operations cannot pass it.
Ledger settlement and the global delivery-marker clear commit together.

Using the deployment's database, origin and generation configuration:

```sh
station-relay-server admin delegated-recovery status
station-relay-server admin delegated-recovery fence
station-relay-server admin delegated-recovery inspect <genesis_hash>
```

`status` only reads the row and prints the configured generation, durable state
and `recovery_ready`. A missing row reports false and is not initialized by
inspection. `fence` closes the row durably without creating a new feed, editing
a signature, clearing a watermark or resuming a stopped report client. A stale
generation cannot fence a newer deployment. Exit codes are `0` for a successful
inspection/fence, `1` for a storage/fencing failure, and `2` for invalid arguments
or configuration. A successful status command is not activation evidence.
A failed fence write does not prove that other replicas stopped. Keep the fleet
drained and fix storage; never restart it with an older generation.

`inspect` reads one account root and the configured origin's fence in a single
read-only, repeatable-read Postgres transaction. It works while the fence is
closed and never advances the saved membership clock, ticks the ACK ledger,
initializes a missing feed or changes a signing reservation. The root is bounded
to 16 MiB and each query has a five-second statement timeout. A malformed root,
membership, ledger or record produces an error rather than a partial report.

The JSON report includes the saved membership head, feed ID/head, record verdict
counts from the shared verifier, watermark count/highest time, outstanding native
effect count, immediately ready/refused/dropped report counts, reporting stop
state and retained delivery retries. `ready_reports` is not the full unsettled
backlog: the shared ledger offers no reports while reporting is stopped and only
the next eligible report per principal otherwise. The command does not expose
signed bodies, recovery blobs, keys or report payloads. An absent root or an
absent feed for this origin is reported as null; it is not created or borrowed
from another Station.

Every report says `retained_history_only: true`. It can inventory what survived
the restore, but cannot establish missing later stops or unknown clock anchors.
`recovery_ready` describes only the existing deployment fence. Neither a report
nor a normal ready fence certifies snapshot completeness or authorizes reopening.

There is deliberately no reopen command yet. Removing the row, replaying a
configuration or retrying startup does not establish a complete snapshot.
The rest of the recovery sequence below is still required before reopening.

## Durable recovery preparation

After draining the fleet, increasing the external generation and committing its
closed fence, the operator can prepare each retained account's recovery:

```sh
station-relay-server admin delegated-recovery prepare <genesis_hash>
```

Migration `0017` retains the exact old membership, account storage binding and
selected origin's complete feed, including signatures, signing reservations,
ACK ledger, report IDs, retry state and reporting stop. It reserves a replacement
feed UUID in the same transaction. The old feed and root remain unchanged. This
is a recovery checkpoint, not a live replacement feed or an export of private
keys. The prepared UUID is never advertised in heads or accepted by live sync.

Preparation requires an existing closed fence at exactly the configured
generation, an owned retained root, an unfrozen shared-verified membership and
a structurally consistent feed. Missing clocks, duplicate record IDs or another
account/origin/feed are refused. It never initializes a missing root, feed or
fence. Concurrent operators/replicas and retry after restart return the same
durable plan and replacement UUID. A commit failure returns no successful plan.
Changes to the retained membership, ownership or feed require review; retry
never overwrites the earlier plan. A later external recovery generation gets
its own plan while retaining the old one. Backup blobs, routes and push state
do not establish control history and are excluded from this checkpoint.

The JSON output includes record IDs, principals, actions, the explicit
interruption choice, signer, shared-verifier verdicts and retained per-principal
clock anchors. Treat it as account-private operator information. It omits
signed bodies, signatures, membership contents, storage subjects, report
payloads, key material and backup blobs. Valid feed-bound native stops are
marked `fresh_manager_signature`: even a current manager's old signature cannot
be edited to name a new feed. Valid feed-independent host stops are retained;
other unverifiable authority remains a review obligation. Service records need
service-state reconciliation rather than copying their old feed signatures.
Every retained record remains listed; this command performs no compaction.

Every preparation reports `retained_history_only: true`,
`snapshot_complete: false` and `recovery_ready: false`. The operator's ability to
prepare is not evidence that all later stops or high-water anchors survived.
Preparation signs nothing, obtains no owner confirmation, changes no reporting
stop, settles no ACK and leaves serving/signing/reporting fenced. Complete later
history, manager re-sign orchestration, snapshot publication and reopening
remain required. Prepared plans have no automatic deletion or cancellation;
authenticated account deletion follows the separate account lifecycle.

## Retaining later native stops

A manager's protected native journal may have signed a revoke or interrupt
after the restored backup. An operator can retain those original signed objects
as additional obligations on the exact prepared plan:

```sh
station-relay-server admin delegated-recovery retain-stops <genesis_hash> stops.json
```

The regular input file is strict JSON with exactly `plan_id`, `source_hash`
(both from `prepare`) and `records` (1-64 original signed control objects).
The file is at most 256 KiB. The command requires the same closed generation,
ownership, membership and retained source as preparation; it never creates a
missing plan. Every record must name this account/genesis and a native signer.
Only revoke and interrupt records are accepted; a feed-bound service stop must
name this Station origin. The original feed ID, body and signature are retained.
A service's cover/hold/release or service-key signature is not a substitute for
authoritative service-state reconciliation.

Migration `0018` keeps these objects separately from the immutable checkpoint
and live feed. The entire batch commits or none does. Concurrent imports
serialize with preparation; identical retries are idempotent, while a record ID
with different contents conflicts with both the checkpoint and imported history.
Each origin/account history allows at most 4,096 distinct imported records and
16 MiB of persisted JSONB. A later recovery generation includes all earlier
imported stops; it cannot hide them by preparing another plan. Identical copies
are deduplicated, and conflicting contents under one ID refuse recovery review.
Malformed, oversized or inconsistent retained evidence refuses the report rather
than omitting a stop. Imported evidence has no pruning/cancellation command.

Both `prepare` and successful imports report every recovered record's metadata,
its shared-verifier verdict and review requirement, plus a deterministic
`evidence_hash`. They expose no signed bodies/signatures or private key material.
An unknown, removed or invalid signer remains `authority_review`; importing its
object never establishes that the stop is in force. The report's
`observed_issued_at_lower_bounds` covers only currently valid imported records.
Those observed times do not establish the greatest time ever signed or reserved;
they cannot clear an unknown clock anchor or permit signing. Import changes no
live watermark, cursor, ACK, effect, reporting stop, signature or recovery fence.
The `snapshot_complete` and `recovery_ready` fields remain false. Authoritative
later service history, complete clocks, fresh manager signatures, snapshot
publication and reopening are still required.

## Complete recovery sequence

1. Drain and stop every replica before restoring. Keep delegated serving,
   signing and reporting closed while recovery is incomplete. A rolling restore
   that leaves old sockets or writers alive is unsupported.
2. Increase the recovery generation outside the backup. Startup compares it
   with durable recovery state before admitting delegated traffic; a mismatch
   never releases the fence. This guard is implemented; the remaining snapshot
   and completion steps below are not.
3. Inspect the restored account roots and reconcile them with authoritative
   later history. Retain every known stop and native interruption intent.
   Missing later history is an unresolved recovery obligation, never permission
   to infer an active state. Fresh Portal state alone cannot settle a missing
   native record. A recovery with no trustworthy later history stays fenced
   until the required owner confirmations establish a complete snapshot.
4. Stage a fresh UUID for each Station/account/genesis feed. `prepare` implements
   this durable checkpoint for a retained source. Retain the old
   signed records and evidence separately. A service record signed for the old
   feed cannot be edited or copied into the new feed as a valid new record.
5. Build the complete latest-state snapshot: coverage and each principal's
   revoke, hold/release and interruption state. Preserve host-principal
   interruption records, which are not feed-bound, and device-list authority.
   Native records requiring a new signature become explicit manager review
   items. Station never substitutes a service signature for a native intent.
6. Merge trustworthy signing high-water anchors and durably reserve strictly
   increasing timestamps before each signature. Unknown anchors keep signing
   fenced. A restored clock or an absent field never resets a watermark to zero.
   Changed native bodies require fresh owner confirmation.
7. Keep old acknowledgment evidence and report IDs/bodies immutable. An old
   feed's cursor or ACK never acknowledges the new snapshot. Reports with an
   uncertain prior delivery and report-client stops retain their existing
   fail-closed recovery rules; a feed reset does not resume reporting.
8. Validate all snapshot signatures with current membership and check every
   required state, timestamp reservation and retention obligation. Commit the
   new feed and its complete snapshot before making any new head visible.
   Partial writes, missing manager signatures or failed commits keep the fence.
9. Start replicas on the same completed generation and require fresh host
   proof. Hosts discover the new feed ID and sync from zero under the existing
   gate. Old feed requests are refused; delayed old responses cannot cross the
   new socket/trust association. Execution remains subject to the rollout gate.

## Retention

Keep feed records for at least 30 days, and each principal's latest state for
as long as that principal exists. Required stops, interruption intents,
signing watermarks, unresolved manager obligations and unsettled ACK/report
evidence cannot be discarded by record compaction. Account deletion remains
the separate authenticated deletion lifecycle. No compaction or pruning is
introduced by this document.

## Required practical tests

- Restore a backup taken before a native revoke and before a service hold.
  Neither a fresh active Portal snapshot nor restarting a second replica opens
  the fence without complete later state.
- Lose a signing reservation, move the wall clock backward and retry signing.
  No timestamp is reused, and missing anchors prevent signing.
- Crash at each recovery checkpoint and each publication commit. Restart must
  retain the fence or expose exactly the committed complete snapshot.
- Fail a native re-sign, race another membership entry and remove its manager.
  No stale confirmation or service key can complete that obligation.
- Replay old feed syncs, ACKs and queued responses after restart. They neither
  open the host gate nor settle a new snapshot/report.
- Lose a report reply or stop reporting with 403 before recovery. Resetting the
  feed never invents a delivery receipt or clears the report-client stop.
- Retain records across the 30-day boundary while preserving latest states and
  unresolved evidence; ordinary replica restart must not rotate the feed.

These tests require the actual Postgres implementation and replica/socket
boundaries. A serialized UUID round trip is not database-recovery evidence.

Current isolated coverage exercises lost service holds, native revocation and
signing reservations after a backup; stale and restarted replicas; missing
guard history; a backup predating all roots; failed fence commit; the actual
socket sink with a queued frame; fencing behind an in-flight HTTP report; and
preserving report IDs, account state and a stopped report client. No test yet
claims complete snapshot reconstruction, re-sign completion or live VII.A.
