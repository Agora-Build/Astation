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

## Native author signing barrier

The [November 23 review](https://github.com/Agora-Build/Astation/issues/114#issuecomment-7089435073)
agrees Atem's exact-plan durable barrier B1-B6 and typed signer-report proposal.
The Apple journal implements a local hold for this interval. Its internal
collector validates the SDK challenge and a plan at the pinned membership head,
then commits both sets of bodies, the exact signed records and the hold in one
protected revision. A signed body can also appear in a surviving unsigned
outbox. The SDK commits that body once in each applicable set. The owner-signing
adapter can return signed bytes only after their exposure is saved and read
back. An exact retry uses the retained signature.

Ordinary stops, re-signs and recovery copies check the hold before owner
confirmation, at draft persistence and at key use. An already signed outbox
can still deliver its retained bytes. Loading a fresh authenticated Station
review reconciles a different plan in a higher generation for that origin. The
Mac retains the original signatures and the successor generation in the same
commit. A file import, another origin or an unknown outcome keeps the hold.

Recovery Copies can request a Station challenge and submit a signed report
when the delegated signing gate permits it. A retry can deliver a previously
exposed signature. The Mac checks the authenticated terminal receipt for abandonment or publication.
Station still needs atomic publication, complete historical author coverage and joint verification.

Recovery Copies can review this Mac's retained evidence offline. The coordinator
holds the account checkpoint and the member key's journal lock while reading
ordinary and recovery outboxes across saved Station origins. Service stops belong
to their named Station. Host interrupts apply at every origin. Matching bodies
with the same ID count once. A retained signature resolves an older outbox
draft. An attempted or legacy draft without a known signature stays unresolved.
The review neither establishes historical coverage nor commits a report barrier.

One journal lock must cover every process using the member's key. Before any
stop signature, append the exact body durably as possibly signed, then save the
signature. The report and barrier commit together, bound to the account,
genesis, exact Station origin, external recovery generation, plan, candidate
feed, membership head, journal identity/range/revision and source/evidence
commitments. No report can escape before that commit. The report's exposure
must itself be durable before export/return/transmission.

The Apple journal records the shared SDK's 16-byte process identifier under
the member key's existing lock. It records the creating process at revision
zero and each subsequent process at the revision of its first attachment.
The first draft or signing attempt persists a new journal. Opening an
existing journal persists any new attachment before returning it to the
caller. An older journal keeps its identity, signed entries and barriers
on migration. Its first tracked process has a positive revision, leaving
earlier processes unknown. Station still requires signed roster evidence
from the shared SDK to account for a displaced process.

While held, the barrier refuses the plan's new drafts and signatures before
any prompt and at the key boundary: service stops at that origin, plus
originless host-principal interrupts. Any active barrier for this account and
genesis holds host interrupts; completing one origin's recovery cannot release
another's barrier. Other-origin service stops are outside this plan.

A possibly-signed body without its saved signature remains an unresolved
obligation. Missing exported signatures cannot be reclassified as drafts or
erased to make report hashes match. Unknown/old processes, missing journal
ranges, a changed journal identity and possible protected-store rollback remain
unresolved too. Owner approval and a signed report do not repair these gaps.

Only authenticated durable evidence from the exact origin that the plan
published, or can never publish, releases its barrier. A higher caller-supplied
generation, timeout, report-lease expiry, sleep, restart or cancelled prompt
cannot release it. A failed/uncertain release write retains the hold. Replacing
a report for the same plan is atomic; a different plan requires proof the old
one cannot publish. Changed evidence/head invalidates the prepared collection.

The owner review must explain the temporary stop-signing restriction and the
available device-list/channel emergency actions. The fenced Station must not
serve usable delegated heads. All recovery publication gates stay closed until
these adapter obligations and independent history/clock completeness are met.

The adopted SDK's `check_control_snapshot_consistency` is deliberately weaker:
it checks consistency only with supplied retained records/marks/covered set.
A retained, still-valid Station-own or current-manager revoke/interrupt may be
carried with the exact original body and signature, including its old feed,
without a mark. Covers, holds and releases are signed anew. New service-key
records bind the candidate feed and exceed its mark. Removed-manager copies
require a fresh manager; an invalid/forged retained record never induces a
signature. ACK and settlement evidence is new for the replacement feed.

## Requesting a signer challenge

A native account client with a current Station review calls
`POST /api/remote/v1/logs/{genesis}/control/recovery/signer-challenges`.
Its native bearer identifies the owner of the recovery root. The body contains
`signer` (a native `member:<device_id>`), `slot`, the exact `expected` membership
head and the five SDK `recovery` fields from the review. The Station checks
them against the stored plan and signed membership under the closed recovery
fence. The named device must be active and must have held the manager role.

The response is the SDK signer challenge. A retry for the same member, slot,
plan, evidence and head returns the same unexpired challenge across replicas.
The Station allocates a new connection number and random nonce on renewal.
It retains at most 128 unexpired slots per plan. Its 30-second lease starts
at the database clock. The Apple client checks the response against the
selected HTTPS origin, target, every recovery field and the current time
before passing it to the approval flow. Issuance grants no signing authority.
Owner confirmation, report submission and snapshot publication are separate.

## Submitting an author report

Recovery Copies shows the selected Station, plan, generation, signed record
count and draft count. The owner consents to the signing hold before the Mac
takes it. The journal checks the reviewed inventory again under the key lock.
Fresh owner authentication approves use of the member key for that SDK request.
If authentication is cancelled after consent, the hold continues. A delivery
retry reads only the already exposed report and records from protected storage.

The account client posts `{"report": <signed report>, "records": [<signed records>]}`
to `POST /api/remote/v1/logs/{genesis}/control/recovery/signer-reports`.
Under the closed fence and locked owner root, Station verifies the SDK report
and exports against the saved challenge, exact head, plan, current evidence
and database time. The round's evidence hash includes the distinct signed records
discovered through current author reports. A first report with an empty journal,
a record already in the base, or a journal revision with the same signed records
can confirm that round. Each accepted report commits its full submission hash to
the reconstruction review, including drafts and journal metadata. Conflicting
journal observations remain visible to the operator.

A newly exported signed record changes the evidence hash. All authors then
confirm the new round. A still-valid outstanding report for the previous round
can arrive after another author exports a new record. Station retains the late
response under its original challenge. A change to the checkpoint, imports or
native archives requires a new challenge even for retention. The Mac keeps the
record and draft sets frozen. A renewed report keeps its revision until another
SDK process attaches. The next signature covers that attachment and requires
fresh review if the owner was already confirming an older revision. An exact
retry sends the saved signed bytes. Each request is bounded to 256 KiB
and the Station retains up to 256 submissions per plan.

A successful response contains `plan_id`, `retained_only: true` and
`submission_hash` (lowercase hex SHA-256 of the canonical request). Exact
retries recover this receipt across replicas and after challenge expiry. A new
submission needs a current challenge. A conflicting reuse of a connection is
refused. Retention leaves the signing hold and recovery fence in place.
Historical coverage and snapshot publication require separate evidence.

The operator's preparation output includes `known_authors.members`. It walks the
signed membership history to find each native member's earliest effective manager
grant, including members who have since been removed or demoted. Pending and
cancelled recovery additions confer no authority. For this plan it rechecks the
saved challenge, signature and exported records at the recorded acceptance time.
A journal created after the first grant shows `missing_early_range: true`.
Each reviewed report includes the slot and base64url process ID from the verified
SDK report. The Mac uses its unique matching slot from the protected process
list for this Station and membership head. With no current, unambiguous match
it can still submit journal evidence under its platform slot. The slot alone
never matches a process or establishes complete participant coverage.
An empty reports list identifies a known author with no accepted report in this
plan. `known_authors.prior_plans` lists the authors and reports from each earlier
retained membership head. An old report describes only its original plan.

The operator review lists `known_authors.journal_gaps` when a previously
observed member journal has no current report, a signed revision falls below
one observed in an earlier generation, or its signed creation sequence changes.
`revision_regression` identifies the first affected generation, its lowest
reported revision and the highest revision in earlier generations. Reports
within one generation can arrive in any order. The discrepancy stays visible
after the journal catches up. The review also flags different signed record
or draft sets at the same journal revision, and changes to either frozen set
within one plan. These conflicts survive later confirmations, process
replacement and plan abandonment.
A later plan's report from the same journal must still export every previously
reported signed stop for this origin. If any are missing, `previous_export_missing`
lists their IDs in `missing_record_ids`, even when the newer report has a higher
revision and the same record count. The Station retains the earlier signed
stops. Unsigned drafts may be cancelled after their plan ends.
A new process can report the same durable journal. A new journal
cannot account for the missing old one. An empty list describes only the
journals observed at this Station. Participant coverage still requires the
independent roster.

In **Recovery Copies**, load the Station review and choose **Save Reviewed
Processes**. Give the file to the recovery operator for comparison:

```sh
station-relay-server admin delegated-recovery compare-authors <genesis_hash> <plan_id> <file> [file ...]
```

The Mac reads its protected native process lists for the selected Station,
including offline slots and previously reviewed processes displaced by a list
edit. Each row includes its reviewed membership head. Existing lists migrate
on their next protected edit. Processes discarded by older versions still
require independent investigation.

Station compares the file against the locked plan, source, evidence, reconstruction
and membership head. A change requires a fresh export. The output names historical
managers without a current roster, reviewed processes without a report in this
plan, and reported processes absent from the supplied list. A match requires
the same member, slot and SDK process ID. Early journal gaps and ambiguous
process identities remain visible even when a tuple matches. The comparison
also lists which reviewed tuples' latest reports sign the current evidence hash
and which still need confirmation. Several managers can supply separate exports
for the same review. If two exports describe the same member, their slot lists
must agree, including prior processes and reviewed heads. A disagreement or a
stale file refuses the combined comparison. A retried receipt retains its original
scope. Comparing exported files cannot attest their provenance, establish complete history,
release a signing hold or reopen a feed.

When the Mac has a pinned verifier journal, the export also reads its saved
process conflicts for this Station and device list. A missing pinned journal
requires recovery before the Mac can export. Station lists reported conflicts
for current and former managers in `conflicted_author_slots`, including slots
the manager has since removed from the roster. A matching signed report can
still describe one process's records. The conflict remains visible alongside it.
Station combines conflicts from all supplied exports. An older export or an
export from another Mac can add observations but cannot clear one.

Recovery rechecks each retained report with the membership and challenge from
the plan that accepted it. A signed revoke or interrupt exported only in that
report appears among the replacement plan's obligations, including after
abandonment. Identical records from different sources appear once. Conflicting
contents under one record ID refuse reconciliation. The recorded signing time
remains a lower bound even if the manager later loses authority. Current
membership determines whether to carry the stop unchanged, obtain a fresh
signature or review its authority. Independent evidence of complete history and participant coverage is
still required before publication.

`known_history.membership_gaps` identifies earlier verified membership heads
missing from the restored list. `restored_head_behind` means the retained
checkpoint has a signed extension of the restored list. `divergent_history`
means their entries disagree at an overlapping sequence. The operator can
inspect both heads and retain evidence while the fence is closed. Station
withholds native signing reviews, fresh signer challenges, new replacement
signatures, service drafts and stop staging until the restored list covers
every retained head. A later generation alone cannot resolve a fork.

## Ending a prepared plan

To permanently abandon a candidate, a Station operator runs
`station-relay-server admin delegated-recovery abandon <genesis_hash> <plan_id>`
with the exact closed deployment generation and origin. The transaction takes the
deployment and account locks, checks the current subject against the retained owner,
and marks the plan abandoned. The original plan, records, historical commitments
and reserved generation stay in storage. All preparation and new evidence writes
for that candidate stop. Recovery can prepare another candidate in a later
external generation. The deployment fence stays closed.

**Check Signing Hold** in Recovery Copies reads
`GET /api/remote/v1/logs/{genesis}/control/recovery/{plan}/outcome` from the
selected Station with the native owner's bearer. An `abandoned` or `published` receipt
matching the account, genesis, origin, generation, plan, candidate and source
can end this hold. Missing, pending and unrecognized outcomes keep it held.
The Mac retains the frozen signatures and end marker in one protected write.
A late challenge cannot reinstall that plan. Holds at other origins still apply.
Station may issue `published` only after it atomically commits the recovered
feed, generation and plan outcome. The current server returns `pending` or
`abandoned` while that publication path is under development.

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
Station origin. At initial generation `1`, Station checks for retained feeds,
live or archived reporting journals, recovery plans, verifier rosters,
recovery-stamped Portal checkpoints and positive signing reservations.
An earlier origin's recorded positive reservation still counts if the
independent signing store has since lost that row.
A regular Portal checkpoint or unused service-key registration can precede
first activation. Existing delegated history with no recovery row,
a missing row at any later generation, or an increased generation closes a
durable fence. A stale generation cannot lower it; the same generation cannot
reopen it. Changing the Station origin does not bypass the history check.
Initialize all genuinely new origins sharing a database before starting delegated
reporting, registering verifier replicas or creating feeds.

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
station-relay-server admin delegated-recovery list-roots
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

While the replicas are drained and the configured generation is fenced,
`list-roots` compares retained device lists with registrations in the
independent signing store. With reporting configured on a built-in Station,
it also checks native binding transitions, administrative release requests
and authenticated Portal checkpoints retained under any report credential
for the configured issuer, Portal and Station. This finds native-only lists
with zero registered service keys. A historical unbind or release still
identifies a list whose history needs recovery.

Each page returns up to 64 distinct hashes in order. Pass `next_after` on the
next call until it is null. `binding_discovery` is `retained` when the command
checked the built-in binding sources, `reporting_unconfigured` when it could
only check roots and registrations on a built-in Station, and `not_applicable`
for custom Stations. Each page requires both databases. A malformed retained
checkpoint in the selected scope fails the read.

If `root_present` is false, recover the signed list and reconcile its history
before reopening. `registered_keys` includes unused registrations left by
interrupted provisioning. A positive `keys_with_reservations` means the
independent store committed signing time for at least one key. Discovery uses
historical evidence only. A list missing from every available source still
requires independent evidence. Each page is a fresh observation. Restart
from the first page after restoring rows.

On custom and built-in Stations, `checked_service_contexts` is true when
reporting is configured and the command also read retained service-key
metadata. An interrupted enrollment can leave a provisioning request before
a key is registered. Its issuer, Portal and Station identify the scope across
report credential rotation. A surviving key envelope independently names its
issuer and Station in its public context. The inventory reads that label
without opening the envelope. Its presence says nothing about key usability
or the current owner, and leaves the independent registration count unchanged.

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

With built-in Station reporting configured, the same transaction includes
`root.route_ownership` for the room migration. It checks each retained relay
and native proxy proof against the stored list head and trust generation.
The result identifies the carrier and host, whether the registered room owner
matches the root's issuer-scoped identity, and the ownership source from the
last observed Portal binding. If another credential for the same Station has a
newer binding, or disagrees at the same version, room ownership stays unresolved
until the selected credential has a consistent checkpoint. An unbound or
released list has no bound owner.
For a never-bound list, a missing root identity or conflicting or unresolvable
registration requires review. For a Station-issued session room, inspection
also resolves its seven-day binding to a registered Astation under the same
issuer. The bound Astation and any registration under the literal room name
must agree with the candidate owner. A missing, expired or unmapped session
binding leaves the owner unresolved. Inspection never refreshes its expiry.
A stale proof supplies no ownership evidence.
The report omits account subjects, room codes and connection identifiers.
It can run offline from a database replica. Live room admission still needs
current availability and binding invalidation.

Every report says `retained_history_only: true`. It can inventory what survived
the restore, but cannot establish missing later stops or unknown clock anchors.
`recovery_ready` describes only the existing deployment fence. Neither a report
nor a normal ready fence certifies snapshot completeness or authorizes reopening.

There is deliberately no reopen command yet. Removing the row, replaying a
configuration or retrying startup does not establish a complete snapshot.
The rest of the recovery sequence below is still required before reopening.

### Authenticated acquisition of an existing preparation

After the operator has fenced and prepared the retained account, a drained
Station can start in explicit review mode with
`STATION_DELEGATED_RECOVERY_REVIEW=true`, `STATION_DELEGATED_HOST_WORK` disabled,
and the exact external `PUBLIC_BASE_URL` and
`STATION_DELEGATED_RECOVERY_GENERATION`. This requires the opt-in delegated
build, durable Postgres storage and an already closed fence at that generation.
It never initializes a missing fence, increases a generation, creates a plan or
enables delegated serving/signing/reporting. Invalid configuration refuses
startup. Ordinary deployments retain their existing configuration and behavior.
This mode is for a drained recovery deployment, not an availability workaround.

`GET /api/remote/v1/logs/<genesis>/control/recovery` uses the existing native
Station bearer and recovery account-ownership checks. Under the same fence/root
locks used by preparation/import, it reads the existing exact checkpoint and
reconciles all retained evidence. It returns at most 8 KiB of version-1 metadata:
account, genesis, normalized origin, generation, plan/candidate-feed IDs,
source/evidence/reconstruction hashes and the membership head. The generation is
a canonical positive decimal **string**, preserving the deployment integer
without JSON numeric conversion. No bodies, signatures, subjects, keys or
backups are included. Missing/foreign roots return the same metadata-free404;
missing/stale plans, open/stale fences, corrupt evidence, storage failures and
the ten-second operation deadline return503 with no partial review. Every
response is `no-store`.

The reply explicitly retains `retained_history_only: true` and false
`complete_history`, `signing_clock_complete`, `snapshot_complete` and
`recovery_ready`. This is an authenticated view of current retained evidence,
not a completeness attestation or signing reservation. Imports can change its
evidence/reconstruction hashes; changed ownership, membership, source or
deployment generation retires the earlier review. A fetch does not create any
durable recovery state, tick clocks/ACKs or reopen a fence.

In Recovery Copies, **Load Station Review** explicitly fetches this metadata
from the selected Station. The native reader rejects another account, origin,
genesis or membership head, noncanonical IDs/numbers, unknown/duplicate/null
fields, oversize replies and any assertion of completion/readiness. The
coordinator checks its protected checkpoint before and after the fetch and
discards replies after account/Station/window changes. Opening the window and
exporting saved signatures remain local operations. A manager uses **Prepare
Copy** to reserve a timestamp for one verified original.

The screen lists signed stops saved on this Mac. Loading the review also reads
`GET /api/remote/v1/logs/<genesis>/control/recovery/<plan>/originals` from the
selected Station with the native account bearer. Each request names the exact
`reconstruction_hash` in the `review` query parameter and the number of rows
already read in `offset`. Station checks account ownership and the closed plan
under the recovery lock. It returns up to 64 outstanding former-manager stops
in record-ID order, within 256 KiB. A changed plan or reconstruction returns
409. A foreign or missing account root returns the same 404. The Mac verifies
each signed record against the pinned membership head before displaying the
list. A failed page discards the entire Station list.

**Prepare Copy** rechecks the Station review for a selected remote original,
compares any local record with the same ID, and invokes the trusted recovery
authority for that exact signed object. It requires both the delegated gate and recovery
provider, rechecks the protected checkpoint before reservation and draft storage,
and revalidates current account, Station and membership across async work.
Membership refresh rechecks protected state before writing and after each network
page, so a reply cannot recreate a missing or changed journal from memory.
Signing also rechecks it before and after owner confirmation and at the key boundary.
An account/Station change or closed window retires pending preparation. A spent
reservation does not authorize a late draft.

Successful preparation saves an unsigned draft and selects it for review; it
does not sign or show an owner prompt. **Confirm Copy** is the separate existing
protected confirmation/signing step. Exact preparation retries reuse the saved
draft and reservation, and exact signed retries reuse their signature. Original
delivery/Portal receipts and feed state remain separate. Saved-copy export stays
available offline even if current membership no longer permits reviewing an
original for a new preparation; protected checkpoint failures still refuse it.

### Native storage of signed recovery copies

**Send to Station** sends an already signed, protected copy using the existing
native Station bearer. It needs no new owner confirmation, clock reservation or
signing authority. The coordinator checks the exact protected copy and current
membership, fetches the existing plan, and requires its complete context to match
before sending. Account/Station/window changes, cancellation, or a changed/missing
protected checkpoint retire the operation and any late receipt. Originals and
signed copies stay saved; a lost reply retries the exact stored signature after
restart. No ordinary control-feed receipt is created or cleared.

`POST /api/remote/v1/logs/<genesis>/control/recovery/<plan>/signatures` accepts the
existing `retain-resigned` input: `evidence_hash` and at most 64 replacements,
each naming its exact `original_record_id` and signed `record`. Authentication
precedes body reading; strict decoding and the 256 KiB bound apply. The shared
retention transaction checks account ownership under the root/fence locks, the
current closed generation, plan, exact source evidence, original intent and
current manager signature. It reuses the operator path's clock lower bounds,
atomic batch and exact retry rules. Cross-account and missing roots produce the
same metadata-free 404. A stale review or failed commit returns no successful
receipt. Only the signed-copy table changes.

After commit, the bounded version-1 receipt names account, genesis, origin,
canonical decimal generation string, plan, evidence hash, exact ordered record
IDs and reconstruction hash. `retained_only` is true and `recovery_ready` is
false. The native strict reader checks every binding, the submitted IDs and
those flags. Storage success establishes neither complete history/clocks nor
stop effects, snapshot publication or reopening. These still require the
production authority and joint checks.

The explicit recovery-review startup mode also permits this signed-copy
retention endpoint and the native copy reservation described below. Its GET
remains read-only. The mode still requires the
opt-in delegated build, durable store and already closed exact-generation
fence. The manager's Mac prepares and confirms its own signatures. Station
keeps live feed writes, reporting and reopening behind their separate gates.

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
generation, an owned retained root and an unfrozen shared-verified membership.
If the backup predates this origin's first feed, the checkpoint stores an explicit
null feed. The review reports `missing_retained_feed` with no feed ID or ledger
inspection. Operators can collect later signed stops and earlier checkpoints
against that membership. The missing feed supplies no evidence of prior signing
times or report delivery. For a present feed, missing clocks, duplicate record IDs or another
account/origin/feed are refused. It never initializes a missing root, feed or
fence. Concurrent operators/replicas and retry after restart return the same
durable plan and replacement UUID. A commit failure returns no successful plan.
When signed membership advances, run `prepare` again. Station checks the
extension against the last head observed by any replica. The original source,
plan and replacement feed keep their identities. The new head starts a fresh
author report round and invalidates staging against the previous review.
Earlier reports and copies remain verifiable at their acceptance heads. The
latest membership determines each stop's current authority. A rollback, fork,
change of owner or change to the retained feed refuses preparation.
A later external recovery generation gets
its own plan while retaining the old one. Backup blobs, routes and push state
do not establish control history and are excluded from this checkpoint.

The JSON output includes record IDs, principals, actions, the explicit
interruption choice, signer, shared-verifier verdicts and retained per-principal
clock anchors. Treat it as account-private operator information. It omits
signed bodies, signatures, membership contents, storage subjects, report
payloads, key material and backup blobs. Valid revokes and interrupts can be carried unchanged. Feed-bound stops are
marked `retain_service_stop`, including those signed by the service itself.
Feed-independent host stops are marked `retain_host_record`. An authenticated
former manager's stop requires a fresh manager signature. Unknown or invalid
authority remains under review. Service covers, holds and releases require
authoritative state reconciliation, a new signature for the candidate feed and
a complete signing ceiling. Preparation keeps the original records for review.

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
The file is at most 256 KiB. Its opened descriptor must be a regular file;
on Unix the open is nonblocking so a replacement FIFO cannot stall the command.
The command requires the same closed generation,
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
An import equal to a checkpoint record is still retained independently so that
a later restored source cannot erase that accepted obligation.
Malformed, oversized or inconsistent retained evidence refuses the report rather
than omitting a stop. Imported evidence has no pruning/cancellation command.

Both `prepare` and successful imports report every recovered record's metadata,
its shared-verifier verdict and review requirement, plus a deterministic
`evidence_hash`. They expose no signed bodies/signatures or private key material.
The SDK identifies a genuine stop from a former manager as `removed_manager`.
Its recovery requirement is `fresh_manager_signature`. Other invalid or unknown
authority stays under `authority_review`. Recovery refuses a signed replacement
if it cannot authenticate the original at the head where the copy was retained.
The report's
`observed_issued_at_lower_bounds` covers only currently valid imported records.
Those observed times do not establish the greatest time ever signed or reserved;
they cannot clear an unknown clock anchor or permit signing. Import changes no
live watermark, cursor, ACK, effect, reporting stop, signature or recovery fence.
The `snapshot_complete` and `recovery_ready` fields remain false. Authoritative
later service history, complete clocks, fresh manager signatures, snapshot
publication and reopening are still required.

### Reconciling retained checkpoints

Every preparation/import also reconciles all known earlier checkpoints for this
exact Station, account and genesis. `known_history.records` deduplicates identical
objects across checkpoints and imports; the same record ID with different
contents refuses the entire transaction. A later restored root cannot omit an
earlier known hold, revoke or interrupt from the recovery review. Every signature
is classified against current membership, so a former manager's original stays
an authority-review obligation. No former signature is promoted to current
authority.

`known_history.checkpoints` identifies each original immutable checkpoint and
summarizes its retained ACK/reporting state. Old ledgers, report IDs, delivery
retries and reporting stops remain separate; reconciliation never merges or
settles them. `observed_signing_lower_bounds` includes every retained reservation,
including reservations with no published record, and valid imported signatures.
These are lower bounds, not proof that later clocks/history survived.

The combined `evidence_hash` binds the exact prepared plan/source, all known
checkpoint commitments and imported evidence. It changes when later evidence is
retained; it authorizes no signature or reopening. Reconciliation is bounded to
128 checkpoints and membership observations combined, 16 MiB of their
retained JSONB and 4,096 distinct combined
record IDs, in addition to the import limits. Exceeding a bound or finding a
corrupt/foreign checkpoint refuses recovery without truncation or a partial
plan/import. Known historical feed IDs cannot become the new candidate ID.

Both `complete_history` and `signing_clock_complete` remain false. This is the
inventory required before snapshot construction; it cannot establish missing
history or replace authoritative service reconciliation and fresh manager
confirmation.

## Complete recovery sequence

### Native evidence export

In Astation, open Control Activity for the source Station and choose
**Export Recovery Evidence**. The export reads the protected local journal;
it needs no network request, signing key operation or new owner confirmation,
and remains available while delegated signing is disabled. Changing account or
Station access, or closing the review window, cancels an outstanding save.
An expired network token does not authorize any remote call or prevent this
local read for the remembered account; explicit sign-out disables export.
The destination file is atomically saved with mode `0600`.

The JSON archive identifies its account, genesis and original Station. `records`
contains every retained original signed object, including completed deliveries,
removed-manager stops and superseded originals. `unsigned_reviews` is separate:
these drafts are unresolved intent, not signed stops. `destinations` preserves
each record's original Station routes, including host-interrupt fanout. No
private key, Recovery Kit, encryption secret, Portal credential or mirror
credential is exported. The archive does contain public account/control metadata
and signatures; share it only with the recovery operator.

For `retain-stops`, the operator must match the archive's genesis and Station to
the exact `prepare` report, then package `records` into batches with that report's
`plan_id` and `source_hash`. Each batch must fit 64 records and 256 KiB; an export
can exceed a single batch and is never silently truncated. Never submit
`unsigned_reviews` as signed records or infer that their intent was applied.
The archive itself is not a `retain-stops` input file or a recovery approval.

### Importing the complete native export

The preferred handoff accepts the original export directly, without manually
extracting records or splitting at a wire-page boundary:

```sh
station-relay-server admin delegated-recovery retain-native <genesis_hash> <plan_id> native-evidence.json
```

The plan ID must identify the exact existing `prepare` checkpoint. The command
rechecks the closed generation, retained source, ownership and membership under
the same transaction locks as preparation. It accepts only a bounded regular
file (8 MiB) with the exact native version-1 export shape. The shared strict
readers validate every original signed record and unsigned control body;
account, genesis and original Station must match. The archive must preserve
exactly one destination list per record or unsigned review, beginning with its
original Station. Only feed-independent host interruptions can name additional
destinations (at most 64 total). Duplicate IDs, substituted routes, extra fields,
duplicate JSON keys and claims of complete history or clocks are refused.

One transaction retains the complete archive, its deterministic canonical hash
and all original signed stops. It accepts up to the native journal's 256 entries,
including exports larger than the 64-record wire limit. Unsigned reviews and
destinations are retained separately from verified stops: they establish no
effect, delivery, signing timestamp or authority. They are explicit owner-review
obligations for later reconstruction, not objects to sign automatically. Original
signatures, unsigned bodies and routes remain in storage; public operator output
contains only review metadata, destinations and commitments.

Identical retries and concurrent replicas retain one archive for a plan. A later
recovery generation includes earlier archives; changing the current source
cannot discard known unsigned intent or its destinations. Conflicting bodies
under one record ID, including a conflict between an unsigned review and any
known signed checkpoint/import, refuse the entire transaction. A failed commit
retains neither an archive nor a signed prefix. Inspection refuses corrupt,
foreign or excessive history rather than returning a partial review. Retained
archives are bounded to 128 rows, 16 MiB of persisted JSONB and 4,096 distinct
review IDs per Station/account history, alongside existing signed-history limits.

The combined preparation `evidence_hash` commits to this archive history as well
as checkpoints and signed imports. All completeness/readiness fields stay false;
the new command does not publish a snapshot, sign, clear a reporting stop, advance
a clock or open a fence.

This is a snapshot of one local journal, not proof that every manager, Station
or later event has been found. `complete_history`, `signing_clock_complete`
and `snapshot_complete` remain false. A locked, changed or uncertain protected
checkpoint refuses export; no older fallback, signing, retry, receipt change or
reopening is performed. Complete history and clock reconciliation, fresh
manager confirmation and publication remain separate obligations.

### Retaining fresh manager copies

The operator can retain already-signed fresh manager copies against an exact
prepared source review:

```sh
station-relay-server admin delegated-recovery retain-resigned <genesis_hash> <plan_id> replacements.json
```

The bounded regular file (256 KiB) has exactly `evidence_hash`, taken from the
current preparation, and `replacements`, a nonempty array of at most 64 objects
with exactly `original_record_id` and `record`. Each original must be a retained
signed native revoke or interruption. Unsigned intent and service-signed state
cannot be substituted. The current shared verifier must accept each new native
manager signature. The replacement preserves the exact principal, key, action,
interruption choice, host revoke sequence and audit fields. Only its signer,
record ID, timestamp and service feed ID can change. A service copy names the
original feed or the prepared replacement feed at the same Station. A host
interruption remains feed-independent.
The operator associates the source commitment; the control signature authenticates
the exact stop body only. It is not an attestation of complete recovery history.

New IDs must not collide with retained originals, unsigned reviews or earlier
copies. Each new signature's time must exceed every observed retained reservation
and earlier accepted copy for its principal; exact retries reuse their signature.
These are necessary lower-bound checks, never proof that all clock anchors are
known. This command performs no signing or timestamp reservation and cannot
authorize a native application to sign while its recovery clock is unknown.
Native recovery review, complete clock reconciliation and its protected signing
path remain required.

Migration `0020` retains copies separately from originals and the live feed.
The deployment fence, exact generation, owned root and immutable source stay
locked through the whole batch and commit. Any mismatch, failed signature,
conflicting ID, excess history or failed commit refuses the whole batch. Retry
and concurrent replicas retain one exact copy for a source/evidence review.
All generations' copies and signing lower bounds remain retained; current
membership reclassifies a removed manager without erasing their old signature
or clock obligation. Corrupt signatures are refused under the original plan's
verified membership, including after a restart.

Every accepted copy also enters the replacement snapshot as a retained stop in
its own right. When its signer still has authority, the snapshot carries its
exact bytes once, even if the copy also satisfies an earlier stop. If its
signer has lost authority, it appears in the new review under its own record
ID and needs a verified replacement. The Station recalculates the reconstruction
hash for plans with copies so that an older staged snapshot can be rebuilt.

The source `evidence_hash` remains the commitment to checkpoints/imports. A new
`reconstruction_hash` additionally commits to the retained manager copies.
Later source evidence marks earlier copies as belonging to an earlier review.
The latest verified report for a signer, slot and process can confirm the exact
signed copy against the new evidence hash within the same plan. Station can
then stage that copy without another stop signature. A later cut requires
another report. Outputs contain only metadata, verification
and commitments, not signatures or keys. `snapshot_complete`,
`signing_clock_complete` and `recovery_ready` remain false. This is retention for
reconstruction, not snapshot publication, a completed native recovery ceremony
or permission to reopen the Station.

The same locked inspection assembles `recovery_signatures.known_native_obligations`
from every retained original signed native stop. Each item preserves the original
review and identifies a matching current copy by record ID, or explicitly says
`retain_service_stop`, `retain_host_record`, `fresh_manager_signature` or
`authority_review`. A copy is
`signed_copy_retained` when it matches that exact original and plan, passes
the shared verifier under current membership and either belongs to the current
review or was exported by its author against the current evidence hash.
Another stop for the same principal cannot replace it. Changing evidence or the
recovery generation makes earlier copies require review again; removing a manager
preserves their original verdict and all earlier copies and clock obligations.
An unchanged valid host interruption can instead retain its original signature
and exact revoke sequence. Unsigned owner intent remains separately listed in
`native_archives`; it never becomes an original signed stop through this mapping.

This mapping avoids manual matching while assembling the known native portion
of a future snapshot. It exposes no signed bodies and changes no stored state.
Even a copy for every known original does not establish missing history, complete
clocks, service state or a complete snapshot. All existing completeness/readiness
fields remain false, and no signing, publication or reopening is authorized.

### Protected native recovery copies

`RemoteControlRecoveryPublication` now keeps recovery copies in a separate,
bounded protected journal. `AstationRecoveryCoordinator` persists it alongside
the account checkpoint, independently of ordinary control deliveries. A recovery
copy can use the same current manager or a replacement manager for an original
whose signer lost manage. The shared builders/readers verify every original,
draft and signature. Service copies preserve the original origin and may name
the original or candidate feed. The Mac keeps the original feed on new copies
and can retry an existing signed candidate-feed copy byte for byte;
host interruptions keep their original revoke sequence and no feed binding.
All other intent and audit fields remain identical. Originals, their delivery
destinations and independently approved Portal mirrors stay intact.

Preparation is scoped to the exact account/genesis, Station, external generation,
plan, source/evidence commitments, replacement feed and membership head. A saved
draft records the exact signing request. The recovery adapter must establish the
current closed plan, authenticated original and current manager, and check its
reservation again at confirmation and signing. The local journal keeps increasing
copy timestamps for a principal. The protocol uses native stop timestamps for
display. A current manager signs needed copies before submitting the final
signer report and entering its signing hold. Complete participant history and
the service signing clock are required for snapshot publication. Requiring either
to sign a native copy would make recovery wait for its own result.

With delegated signing authorized, the Mac obtains a timestamp from
`POST /api/remote/v1/logs/<genesis>/control/recovery/copy-reservations`.
The native bearer identifies the owner. The request names the closed plan,
membership head, current manager, original record ID and SHA-256 of the
canonical signed original. Station checks that the original still needs a
new manager signature. It stores one elapsed timestamp for this review in
shared PostgreSQL, above the retained principal's observed times and its
previous native copy reservations. Concurrent replicas return the same
reservation for the same request. When the Mac has already saved a draft for
the same principal, it sends that journal's most recent timestamp as
`after_issued_at` on a new reservation. If an earlier reply was lost, Station
can replace its unseen reservation with an elapsed timestamp above this floor.
An exact `issued_at` recheck and a new reservation are distinct requests.
The independent service signing clock is used only for service signatures.

The Mac rechecks the exact saved `issued_at` before showing owner confirmation
and after the owner responds. This request can only verify an existing
reservation. A changed plan, original, membership or elapsed signing floor
requires a new review. If a later retained stop passes the draft's time,
choosing **Prepare Copy** again can reserve a newer timestamp. The protected
journal retains the earlier draft and any signature, with a separate record
ID for the new confirmation. The Station records a copy only when it receives
and verifies its signature. A reservation alone leaves the fence closed.

Control Activity's **Review Recovery Copies** opens a separate protected local
review. It lists only drafts already prepared through that trusted adapter and
signed copies retained on this Mac; it never accepts a caller-supplied plan as
authorization. Each review shows the original stop and interruption choice,
original/new record IDs, manager, Station, generation, candidate feed, exact
membership head and source/evidence commitments. **Confirm Copy** first reviews
that exact intent, then uses the coordinator's fresh owner confirmation and
authority rechecks. The button remains disabled without the production adapter,
current sign-in and selected source Station. Confirmation does not submit the
record to a live feed or clear the recovery fence.

**Save Signed Copy** exports the existing `retain-resigned` JSON for the selected
saved signature without network access or a new signing prompt. Before writing
the file it rereads the protected checkpoint and requires the exact same export;
changed or unreadable storage refuses the save. Files are atomic and mode `0600`.
Account/Station changes or closing the window invalidate pending confirmation
and save callbacks. A delayed callback cannot sign or write an earlier account's
copy. The original evidence-export action stays separate.

With an authenticated adapter and fresh owner approval, the exact signature is
saved before it can be exported. An uncertain protected save fences the process;
restart reads the committed draft or exact signature without silently choosing
an older checkpoint. Saving the first recovery draft raises the account checkpoint
to version 4. Older readers refuse it instead of rewriting away recovery copies;
later operations cannot lower the checkpoint version. Membership or account
changes invalidate the pending review.
This version fence prevents older supported readers from erasing a new journal;
it is not a claim of rollback resistance against replacing the entire protected
checkpoint with an earlier legacy value. Legacy checkpoints must remain readable,
and neither a missing journal nor its local lower bounds establish complete clocks.
The independent trusted recovery authority remains mandatory before any new
signature, including after a legacy checkpoint is loaded.
Retrying an already signed copy never signs it again, including with P-256.
Earlier review copies and their clock obligations remain saved across new plans.

Export uses the existing `retain-resigned` JSON shape, limited to 64 signed copies
and 256 KiB, preserving preparation order for increasing per-principal times.
Mixed contexts, duplicate/missing IDs, unsigned copies and oversized batches are
refused rather than partially exported. Recovery copies never enter the original
native-evidence archive or normal Station delivery queue. Exporting already-signed
evidence reads the protected checkpoint and needs no new network/signing authority.
Exports load only an already retained origin journal. Unknown-origin failures do
not create journals or consume capacity. Retained other-Station copies remain
exportable without changing the selected Station or obtaining network authority.
This component does not publish a replacement snapshot or reopen recovery.

### Portal service observations during recovery

With report-client configuration, `prepare` archives the Station-wide reporting
journal under its issuer, Portal and Station origins. It saves the ordered
events, outstanding delivery claim and consumed resume IDs together while the
recovery fence is locked. Accounts and replicas share one copy of each distinct
observation. The operator sees the current evidence hash, the number of retained
observations, and whether any ended with a stopped client or outstanding delivery.
A missing live journal has a null current hash. Earlier observations remain
available to reconcile before reopening. Preparation sends no report or resume.

At reporter startup, Station checks that the live event sequence extends every
archived sequence for the same issuer, Portal and Station. It restores consumed
resume IDs in the journal transaction before considering the configured resume.
A missing stop or a conflicting prefix keeps the reporter closed. An archived
delivery claim that disappeared requires a fresh explicit resume unless the
live journal already records a subsequent resume. The initial client uses no
resume ID. Each later resume requires one distinct consumed ID. If the live
and archived evidence together cannot account for those IDs, the reporter
stays closed, including when the operator repeats an earlier ID.

If the restored journal lost a stop or an outstanding delivery, run
`station-relay-server admin delegated-recovery restore-report-stop <evidence_hash>`
with the same Portal reporting configuration, while the recovery generation is
closed. The preparation report includes `reporting_history.retained_stop_or_claim_hash`
when an archived observation ended with either condition. An earlier preparation's
saved hash can also identify the source. Station verifies the selected archive
against the live row and all other observations. Incompatible histories require
reconciliation. On success it restores the exact stopped event sequence or
outstanding claim and the consumed resume IDs in one transaction. Repeating the
command returns the same receipt. The reporting worker stays held until its
normal explicit resume, and the deployment recovery fence stays closed.

A Station in recovery review mode fetches the existing authenticated Portal checkpoint
after observing its configured closed generation. At commit it takes a shared lock
on the same fence and compares the policy revision. A late response from a previous
generation cannot stamp a restored checkpoint. Ordinary policy updates and denials
invalidate the observation, including writes made by a replica running the earlier
schema. An operator restores under a new external generation.

With its report-client configuration present, `admin delegated-recovery prepare`
projects the checkpoint onto the retained R9 membership. An observed row matches
the configured issuer's account owner, integration ID and signed service key.
The projection carries the lifecycle state, interruption choice, expiry and any
known revocation time. Missing or mismatched rows stay unresolved. The recovery
plan commits to this observation separately from its native signer reports.
For a built-in Station, the observation includes account availability and the
binding ID, version and state for this owner's exact R9 account and genesis.
A change to that binding changes the evidence hash even at the same feed cursor.
An absent binding or a binding owned by another account is reported as unresolved.
The review holds the policy row through its transaction and can be retried after a
concurrent writer commits. This observation describes the checkpoint. Live room
admission and closure require the separate ownership check.
When the independent signing database is configured, the same account and genesis
reservation rows also drive the Portal comparison. Keys missing from the restored
list appear in `registrations_without_membership`. Each row carries the highest
reserved time and the Portal lifecycle observation for its exact owner, integration
and public key. Zero can identify an unused registration from an interrupted
enrollment. A key in this list requires membership reconciliation. A missing
signing database leaves this field null. A retained service signature requires a
ceiling for its exact key, even if another key registered for the same integration
has reserved a higher time. The comparison includes keys recorded in earlier
recovery checkpoints. A service signature verified under its earlier membership
still sets a lower bound for that key if the current restore predates enrollment.
A missing historical registration appears even when its signatures were never
published. A missing checkpoint is reported as pending.
Publication must recheck current authority.

The built-in Station journals an authenticated D27 release from either the
ordinary feed or the checkpoint's `pendingReleases`. It commits the release
identity and the feed cursor or checkpoint in one PostgreSQL transaction.
All report credentials for the same issuer, Portal and Station share that
journal. Receiving the same release ID with a different target rejects the
transaction. Delegated service signing and ownership review consult the
journal until the binding advances beyond the released version. D27 settlement
requires the binding transition, its durable outbound report and route
closures in addition to this observation.

During `prepare`, the primary recovery database retains the highest reservation
it has seen for each Station, account, genesis, service and key. This includes
ranges burned by a failed publication and registrations still at zero. A later
review lists any missing or lower signing-store row in
`service_clock_evidence.reservation_shortfalls` with its previously observed
value. Changing plans or replicas preserves these observations. If the signing
store is unconfigured, the review lists the retained observations separately.
The Portal comparison also uses those observations to identify services that
belong to this device list. `prior_signing_registrations` lists the exact
service and key, highest observed time, and current checkpoint policy when the
live registration is absent, lower, or unavailable. A historical observation
alone cannot establish current coverage or authorize a signature.
Before signing any new service control records, Station requires the independent
database to cover the observed floor for that key. A positive observation for
another key of the same service also blocks signing. Only the independent
signing database can reserve timestamps. If both databases
lose a reservation, this comparison cannot recover it.

The operator review derives `service_clock_evidence.snapshot_signing_marks` for service keys identified
by signed membership history. Each entry names the exact fingerprint, the
independent reservation ceiling and the minimum time a new signature must
exceed. The latter includes retained principal watermarks and native recovery
copies. A missing registration, a reservation shortfall, conflicting signed
keys or an own-key signature above its ceiling withholds the mark for that
principal. An unused registration by itself establishes no membership.

For each service, `snapshot_review` lists the fresh lifecycle actions required
by the observed checkpoint. Station matches the signed active member and key
to the stored provisioning context for this issuer, Station, owner, and genesis.
A paused service needs a new cover followed by a hold. An active service needs
a new cover followed by a release so a host that kept the old hold can resume.
Portal's authenticated `held` flag preserves this distinction after grant
expiry. An explicit `true` carries the hold and an explicit `false` allows
release subject to the ordinary owner and binding checks. Both leave expired
API access denied. An older expired row without the flag leaves recovery at
`pre_expiry_state_unresolved`.
A release requires an ordinary Portal policy read less than 120 seconds old
on both custom and built-in Stations. A recovery checkpoint preserves that
read time. A future timestamp or an expired lease withholds the release.
For a bound list on the built-in Station, the review also requires a completed
change-feed read within the same 60-second window used by the live signer.
If the read ages out, the review withholds the release even when the retained
checkpoint still shows the owner as enabled.
A known manager revoke survives a Portal resume. A matching reviewed copy
preserves the effect of a former manager's revoke. Portal revocation separately
requires the service's own revoke for reporting, and a later interrupt request
requires an interrupt if the own-key stop did not already include one. After
a Portal or native revoke, `fresh_stop_actions` lists only the missing stops,
even when membership already removed the service.

The ordinary integration feed, cursor-zero snapshot and recovery checkpoint
can provide the original `revokedAt` for the first signed revoke. A later
interrupt preserves that time. A legacy row may have no recorded time.
For an explicitly undated legacy revocation, Station can use the first
`integration_revoked` change's `at` if it observed the feed from cursor zero.
It retains that event across restarts. An interrupt, a repeated revoke or the
current state attached to an older event cannot supply a missing first event.

When the original time is unknown at intake, Station starts the reporting
deadline at the signed revoke's issue time. When Portal later supplies the
original time for the same service and key, Station can lower the stored start
and emit an overdue final. An existing final keeps its report ID, host set and
delivery history. The correction uses the signed membership's public key and
survives removal of the private service key. A pending interrupt goes through
the normal signing path after the bookkeeping transaction commits.

A signed membership removal ends the cover requirement. A verified revoke for
the service and its key also ends it once Station stages that revoke in the
replacement snapshot. The review reports the reason in `coverage_end` and
includes the selected record ID for a revoke. Every replica checks the staged
records against the current reconstruction, including required interrupts.
A Portal revoke alone leaves coverage unresolved. A missing key, signing
reservation, expired grant or stale staged component cannot end coverage.
These observations contribute to the review while publication remains fenced.

Missing ownership, an unresolved stop, or expiry that hides the previous hold
keeps the corresponding state unresolved. Earlier membership keys appear in
`prior_membership_keys` with their matching Portal observations even after both
the restored membership and the signing database lose the enrollment.
Station also reads provisioning for the exact report binding, issuer, owner and
genesis. A provisioned key can predate both native enrollment and Portal's
receipt of its fingerprint. It appears in `provisioned_without_membership`
even if neither source mentions it. An interrupted provisioning operation
without a saved fingerprint appears in `provisioning_without_fingerprint`.
When the operator configures the Station service wrapping key, `protected_service_keys`
reports the public fingerprint derived from each authenticated envelope. A key saved
before the provisioning fingerprint is `pending`. An established fingerprint can
be `matched` or `mismatch`. An absent envelope is `missing`, and one the Station
cannot authenticate is `unreadable`. With the independent signing database configured,
each authenticated key carries its exact reservation or a missing-registration
observation. A registered ceiling of zero records an unused key. Preparing a review leaves the provisioning
record and enrollment as they were. The protected-key observation is omitted when
the wrapping key is unconfigured. If an envelope survives the loss of its
provisioning row, `envelopes_without_provisioning` lists its service ID for
the exact issuer, Station, owner and device list. With the wrapping key,
Station authenticates the envelope in that context and reports its fingerprint,
Portal observation and available signing reservation. An unreadable envelope
remains unresolved. Only a matching provisioning row can designate a managed
key for snapshot signing. These entries require reconciliation before
publication. If the Portal alone identifies a
key for this Agora.Build owner, `portal_keys_without_attribution` preserves its
lifecycle observation. The owner can have several R9 lists, so this evidence
requires reconciliation before the Station can attribute the key to this list.
For an owner with multiple lists, `portal_keys_at_other_lists` records a
matching integration enrolled on another list. Station checks the provisioning
record for this reporting binding, authenticates the protected key in its
original context, and verifies the service fingerprint against that owner's
signed membership at the other genesis. The evidence names that genesis and
membership head. Its recovery handles the service's controls. If any of those
checks fails, the integration stays in `portal_keys_without_attribution`.
Rows owned by other Agora.Build accounts are excluded.
These are obligations for review. Signing and publication still require a
current coverage decision, protected key access, complete participants and
clock validation.

### Candidate service records

With the service vault, Portal binding and independent signing store configured,
`prepare` also builds `service_drafts.unsigned_bodies`. Each body names the
candidate feed and the service key matched across the verified list, protected
provisioning and independent reservation. The cover precedes the hold or
release. A required service revoke or follow-up interrupt gets its own body.
A future signing floor makes the batch wait until its entire timestamp range
has elapsed.

Station retains the bodies with the review commitments. Retrying the same
review on another replica returns the same record IDs and times. A changed
review prepares new drafts, and a failed commit preserves the preceding ones.
If Station can draft only some of the reviewed services, `service_drafts.status`
is `partial`. The response keeps the available bodies and lists each affected
service, key fingerprint and reason in `unresolved_services`. A service with
a carried revoke and no outstanding action needs no new signing key. A
`prepared` batch accounts for the actions of the membership services in this
review. Unattributed Portal keys and evidence outside that membership still
need reconciliation. Preparation produces no signatures or reservations.
Final signing must recheck participant coverage,
policy, membership and signing floors before publishing the snapshot.

The service signer takes the reviewed membership, exact feed ID and signing
mark with the batch. It checks every body before reserving time. The separate
signing database advances the exact key's ceiling only if it still equals
the reviewed value. Even an intervening reservation below the proposed
timestamps requires a new review. A native stop can raise the principal's
minimum timestamp above the service key's own ceiling.

If policy or wall time changes while the signing store commits, the signer
withholds the batch and the reservation stays consumed. The signer checks the
completed records with the shared membership verifier. Recovery preparation
continues to return unsigned bodies. The final publisher must supply its
verified participant cut and retain the records atomically.

Recovery keeps each committed service batch under its plan and original draft
source hash. Its receipt identifies the reviewed bodies, exact signed records,
and membership head at acceptance. An operator can recover that receipt from
`known_history.checkpoints[].service_components` after a lost response,
including after the independent clock advances and a replica prepares a new
draft. The original records also remain available when a plan is abandoned.
The current plan's service signatures change its reconstruction hash. The
native author round stays bound to the evidence the managers reviewed before
Station signed. When a later plan starts, these service signatures are part
of its historical inputs.
Station verifies each signature at its acceptance head, carries signed
revocations and interrupts into the next review, and accounts for each key's
highest observed signature. A retained receipt alone grants no publication
authority.

When service review is available, the operator's `prepare` returns
`candidate_snapshot`. An `assembled` result contains the record count and
SHA-256 of the ordered signed records. Station checks the current required
actions, membership, author evidence and independent signing reservations before
reusing signatures from a previous attempt. A new batch retains the clock
evidence from before it signed. An older batch without that evidence can still
supply historical stops. A list can have an empty candidate or one containing
only revokes and interrupts. The assembled result is a preview. Publication
requires the final participant check and a separate commit.

With an assembled snapshot, `prepare` also stages the ordered records, fresh
acknowledgment ledger and signing watermarks together in PostgreSQL. The
`replacement_feed` receipt identifies the reviewed inputs and the exact stored
feed. Retrying that review on another replica uses the original capture time,
including for revocation deadlines. The watermarks include unused service and
recovery-copy reservations. The old feed remains in the original checkpoint.

The replacement ledger starts with an empty set of host acknowledgments.
It applies the existing reporting journal before recording the snapshot's
revokes and interrupts. A lost journal prefix, stop or delivery claim can
produce `awaiting_reporting_history`. The operator can still inspect the other
recovery evidence. The live reporter retains its outstanding delivery claim.
A staged receipt grants no authority to serve the feed or release a manager's
signing hold.

### Staging revocations and interrupts

After reviewing `prepare`, run

```sh
station-relay-server admin delegated-recovery stage-stops <genesis_hash> <reconstruction_hash>
```

Station locks the closed generation and account, rebuilds that exact review and
assembles its known signed stops. It preserves each authorized original,
including an old-feed service revoke and a feed-independent host interrupt.
For a former manager it requires the reviewed replacement signature for that
particular original. It checks the resulting stop effects with the shared Atem
SDK at current membership. Stops are ordered by original record ID so replicas
assemble the same component. A stale review, missing copy or unresolved
authority prevents staging.

If a later backup already contains a carried stop, recovery verifies its original
signature again at the restored membership. Its signed feed ID is also reserved
against reuse. A cover, hold or release must name the feed that contains it.

The transaction saves the signed component under the plan ID. Its receipt gives
the candidate feed ID, reconstruction hash, record count and records hash.
If the response is lost, repeat the command with the same hash on either
replica. It verifies the saved records and returns the original receipt
without rewriting them. A mismatch refuses the receipt.
After new evidence, repeat preparation and stage against the new hash. The live
feed and its ACK ledger continue to refer to the old feed. The complete snapshot
still requires participant and service evidence, current covers and holds,
clock verification and atomic publication.

### Operator Steps

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

When a relay or local proxy proves a host, Station binds that connection to
the active Station origin and feed ID in the same transaction. A replacement
feed requires a fresh proof before the host can fetch control data or acknowledge
effects. Station checks the feed again when writing queued control frames.
The ACK names the feed the host just read, even when the acknowledged stop
retains its original signature from an earlier feed.

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
