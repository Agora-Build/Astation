# Delegated Station database recovery

Implementation requirements for Astation #79. This procedure is not yet
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
incarnation outside the restored backup, a durable recovery fence, and a
verified complete snapshot. The incarnation is an operational rollback fence;
it grants no signing or host authority. No such protection is claimed by the
current UUID implementation.

## Recovery sequence to implement

1. Drain and stop every replica before restoring. Keep delegated serving,
   signing and reporting closed while recovery is incomplete. A rolling restore
   that leaves old sockets or writers alive is unsupported.
2. Allocate a fresh recovery incarnation outside the backup. Reusing an old
   incarnation is refused. Startup must compare its configured incarnation to
   durable recovery state before admitting delegated traffic; a mismatch never
   auto-initializes or releases the fence.
3. Inspect the restored account roots and reconcile them with authoritative
   later history. Retain every known stop and native interruption intent.
   Missing later history is an unresolved recovery obligation, never permission
   to infer an active state. Fresh Portal state alone cannot settle a missing
   native record. A recovery with no trustworthy later history stays fenced
   until the required owner confirmations establish a complete snapshot.
4. Stage a fresh UUID for each Station/account/genesis feed. Retain the old
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
9. Start replicas on the same completed incarnation and require fresh host
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
