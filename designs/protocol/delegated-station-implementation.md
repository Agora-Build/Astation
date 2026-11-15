# Delegated Station implementation (#79)

This is implementation status against the agreed Atem Step 4 contract, pinned
to `c7b0054fe1208cad1bac98162d9d3ea99b5307cc` (#166's merged tree).
The feature is **not ready for activation**. This change does not enable
delegated execution or new native membership/control signing.

## Implemented

- Apple, Android and relay shared-core pins; published artifact hashes checked.
- One durable own feed per Station/account/genesis, including an empty feed.
  Membership, record append, signing high-water and shared ACK ledger use the
  same recovery-root transaction and lock. Failed commits expose no record or
  ACK evidence; a reused record ID with a different body is refused.
- Strict `heads`, correlated `control_sync`, `membership_fetch`, and whole-ACK
  validation on current proved host associations. Periodic heads every 30 s,
  durable-change wakeups and replica nudges re-read authority from storage.
  Bounded responses use the shared builders, 64-item/262144-byte limits and
  30-second handler deadlines.
- Queued control responses carry their original host association, checked
  again under the membership lock at the socket write. Trust generation is
  captured at admission, including when a generation changes without a key
  change. Old stored routes without a generation require a fresh proof.
  Obsolete control frames are discarded during close flushing too; they cannot
  prevent an independently authorized #80 verification completion from flushing.
- Durable shared-ledger report outbox with stable IDs/bodies, per-host effect
  evidence, retry pacing, explicit refusal and report-client stop/resume.
  Committed reporting may settle during a membership freeze; new authority and
  host ACKs stay blocked.
- Protected service-key reconciliation from authenticated Portal state:
  cover, hold, release, revoke and a later explicit interrupt. Expiry emits
  nothing. Covered hosts come from verified grant history, so narrowing a scope
  cannot remove a previously covered host from revocation accounting. A native
  revoke cannot be undone by a later active Portal snapshot. A separate own-key
  revoke is still issued for Portal reporting. Keys remain until signed R9
  membership removal, rather than being deleted on Portal revocation alone.

## Native client HTTP carriage

All endpoints are under `/api/remote/v1/logs/{genesis}/control`, require the
existing account access token, return `Cache-Control: no-store`, and check the
account's ownership of the root. Login permits storage access, never signing
or host authority. All are unavailable while the delegated runtime gate is off.

| Method/path | Request | Response |
| --- | --- | --- |
| GET base | none | Shared `heads` envelope for this Station |
| POST `/sync` | Exact shared `control_sync` envelope | Correlated shared result or metadata-free refusal |
| POST `/reservations` | `{principal, manager, expected:{seq,hash}}` | `{issued_at}`; monotonically reserved before signing |
| POST `/records` | `{record:<signed object>, expected:{seq,hash}}` | `{record_id, appended}` after durable publication |

Requests are strict JSON: duplicate/unknown fields are refused. Reservations
check the exact current head, known principal and active manager. Publication
also requires the shared verifier to accept a current native manager's
signature; only `revoke` and `interrupt_running` are allowed. Covered hosts are
derived inside the transaction. These endpoints accept no host ACKs. After a
membership change a caller must refresh and revalidate; it cannot replay an old
confirmation under a new head. An unchanged retry at the same head is idempotent.

`RemoteRecoveryHTTP` consumes these endpoints using its existing account-token,
HTTPS, redirect refusal and bounded-response path. Shared readers validate own
heads and exact sync correlation, and an anchored local log verifies a manager
record before publication. The adapter accepts only a matching record ID and a
Boolean receipt. It does not sign a record or treat a receipt as host application.

## Native stop delivery

The Mac integration screen now has gated Revoke and later Interrupt workflows.
Revoke's interruption checkbox starts off. A review shows the integration,
principal, Station, action, interruption choice and exact record ID before a
separate fresh owner authentication. The ordinary membership key provider still
refuses control signatures; the authorized stop path uses the same protected
identity with a one-use `RemoteConfirmedSigner` for the SDK's exact request.
Managers cannot use this path to sign service cover, hold or release.

`RemoteControlPublication` stores the draft before confirmation and the exact
signature before either delivery leg. Its protected checkpoint is bound to the
account, genesis and Station and retains the Portal issuer/owner and explicit
interruption choice. A changed membership head invalidates an unsigned review.
A retry revalidates a signed record against the current independently anchored
membership; a removed manager needs a new review/signature. Its already confirmed
Portal revoke intent remains available. Checkpoints also verify retained
signatures with the public key pinned at preparation.

Station storage and Portal mirroring settle independently. A failed or lost
reply, app restart, or write that committed before throwing never creates a new
record or signature. An uncertain protected write stops the instance until a
reload. The account coordinator schedules retries at startup/resumption and
every 30 seconds, independent of the Settings window; account, Station and
coordinator generation changes retire its work. It uses the same cached native
integration authorization as the approval screen, without opening a sign-in
prompt in the background. These receipts never imply host application.

The production constructor supplies no delegated signing authorization, so
these controls and retries remain off. This is not the separate all-verifier
gate for the five new membership actions; that gate also stays off, and
host-sender Readmit is not implemented by the service-stop UI.

Portal integration follow-up: [Portal #38](https://github.com/Agora-Build/Portal/issues/38).
At Portal `fd11f8bc7c1dbfe9c89b2a23bd7572b00ac6e440`, an earlier non-interrupting
revoke wins over a later native mirror with `interruptRunning: true`. Native
keeps its exact signed stop and pending mirror rather than accepting a false
choice as confirmation. The normal first revoke and false-intent retries work;
the conflicting true-intent mirror needs Portal convergence before activation.

## Reporting recovery

Before any HTTP delivery, Station durably commits an in-flight marker for the
report-client binding shared by all accounts and replicas. It then locks that
marker through the request and settlement. A 403 persists a Station-wide stop.
If the stop commit fails or the process dies during delivery, the earlier
marker remains and **all further reports stay blocked**, including after restart.
An uncertain response might have been a 403, so an elapsed timeout alone never
authorizes a resend.

After investigating/fixing the report-client configuration, an operator may
resume with both `STATION_DELEGATED_REPORT_RESUME_CLIENT` equal to the configured
client and a fresh UUID `STATION_DELEGATED_REPORT_RESUME_ID`. Each resume ID is
consumed durably once across replicas; leaving it configured or replaying it
after another 403 cannot resume again. Remove it after use. A same-client resume
retains pending report IDs/bodies; a replacement client uses the shared ledger's
explicit drop policy. This is operator recovery, not a native owner action.

The ordinary retry path persists its backoff and clears the marker only after
settlement commits. No redirect is followed. Refused report IDs are retained
for operator diagnostics rather than retried under a new ID.

## Gates and remaining work

The `delegated-host-work` Cargo feature and exact
`STATION_DELEGATED_HOST_WORK=true` runtime setting are both required, with a
normalized `PUBLIC_BASE_URL`. Deployment configuration enables neither.
New native signing/device-list compatibility gates remain off.

Still required before activation:

- Native :8080 proxy with fresh host proof and socket/identity generation
  retirement. Atem main currently ignores a local-link `host_challenge`; the
  focused host request is [Atem #120 comment 6892158273](https://github.com/Agora-Build/Atem/issues/120#issuecomment-6892158273).
  A native login token cannot replace the proof. A proxy must not take over a
  normal host route without supporting its encrypted channel routing too.
- Native host-sender Revoke/Readmit/Interrupt UI and its all-verifier signing
  authorization. The service Revoke/Interrupt UI and protected delivery journal
  are implemented but remain gated. Record-specific re-sign/application alerts
  and unknown-outcome resolution/listing/reminders/push remain required.
- Restore/reset/incarnation tooling: a restored database must never reuse a
  `feed_id`. A reset must reissue a complete latest-state snapshot, including
  native records needing a manager. The present storage UUID is restart-stable;
  it is not a completed database-restore procedure. Retention/compaction must
  preserve required stops, high-water and at least 30 days of records.
- Account ownership/mailbox integration, the remaining Kotlin delegated
  fixture runner, and all real Station/native/Atem/Portal joint checks listed
  in #79. Passing fake-host/isolated tests is not activation evidence.

## Validation

Tests exercise strict shared fixtures through actual Rust and Swift bindings,
real sockets without a Mac, isolated Postgres and Redis, two replicas/restart,
generation changes behind a queued response, ACK commit failure, service-key
binding, lifecycle concurrency and expiry, historical coverage, HTTP retries,
failed stop/marker commits and explicit one-shot resumption. Native approval
pushes use the SDK's typed approval/unknown-outcome targets; until the unknown
outcome UI exists, the approval inbox does not consume their deduplication state.

The working branch's exact commands/results are recorded in its PR. Real
protected owner ceremonies and native local transport remain joint checks.
