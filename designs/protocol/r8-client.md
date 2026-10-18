# Astation r8 client

Astation requires atem-session revision 8. The contract, handoff and fixtures
are pinned to Atem main `4f87bab1289848cb6a0da5707d2e7830eb5c057d` (PR #78).
The merged contract matches the reviewed source byte for byte (SHA-256
`61c02f789fdaf2c72710f975150f196e8c6b6979a6a6a3cc51e921ecbf1680c9`).
All four [implementation contract edits](agent-control-api-atem-r6-review.md)
are confirmed. There is no older-protocol fallback.

## Admission and trust

Every hello sends `revision: 8`. A welcome must name revision 8, advertise
features, match the verified account/device, and grant view permission before
Astation requests the registry. Only known advertised features are enabled.
An incompatible Atem is hidden from Connections, agent selection and the local
session API; Connections explains: "This Atem version is not supported.
Upgrade Atem." API status exposes `atem_upgrade_required`. Reconnection after
an upgrade performs a new handshake. Silence times out without an automatic
retry or a claim that the host is incompatible: a halted journal can also
withhold welcome.

Authority still comes from the native app's authenticated, safety-code-verified
pairing. The relay transports messages; it does not establish identity,
permissions, encryption mode or control. Account-wide membership, standalone
browser authority and other section 9 features remain gated. Local port 8080
remains available for same-machine connections and the opt-in local API.

## Prompt and terminal lifecycle

Native UI and API submit through `AtemSessionClient` and its durable request
journal. Prompt text and transcripts are never written into that journal.

- With an existing owned lease, Send uses its epoch.
- Without one, Send carries root `acquire: true`, without `lease_epoch`.
- A `lease_held` refusal records the authenticated controller and epoch.
  Native UI offers a confirmation; API callers supply `takeover: true` and
  that exact `expected_controller`. Only this definitive refusal permits an
  explicit retry with the same UUID and canonical content.
- An uncertain request is queried, never replayed. Receipt queries and
  duplicate submissions cannot acquire control. A definitive `busy` requires
  a new request UUID for a deliberate new attempt.
- An admitting receipt can grant control only for a still-outstanding Send on
  the current attachment, before the conservative deadline, without a newer
  or revoked epoch. Release, backgrounding, window closure and target changes
  fence late adoption while retaining receipt recovery.
- Native UI renews every five seconds while foregrounded and releases on app
  background, window closure, session switch and sleep. API callers use an
  explicit `operator_id` (default `local-api`) and must renew every five seconds.
  Native UI cannot consume an API caller's lease, or vice versa. An abandoned
  API lease expires within 15 seconds; Astation never renews it automatically.
- Raw terminal input, resize, paste, interrupt and stop retain explicit held
  lease checks. Reading chat, approving and revoking a rule do not acquire it.

Permission, full target, attachment and process identity are checked at every
operation. A fresh registry snapshot that reports a different/no controller
cannot revive an old local lease.

## Approvals and results

Approval answers omit both `acquire` and `lease_epoch`. They require current
control permission and the exact pending request, independently of the lease.
A closed-request refusal disables the card without disrupting unrelated
terminal control. Always allow echoes an exact host-offered rule for Claude
or Codex; matching remains on Atem. Rule revocation is also lease-free.
Final cards expose the host's close reason when `approval.card_reason` is
advertised. Auto-allowed cards are informational, never new pending alerts.

Completed prompt receipts expose `result` when advertised: turn/user IDs,
outcome, up to 32 reply IDs, `more` and retained-reply coverage. Reply coverage
can change without changing the final request's outcome. Missing results or
partial/unavailable replies do not authorize resubmission. Use a bounded
history lookup to obtain retained content; the request journal stores only
metadata. It retains at most 4096 records/4 MiB, evicting old final records.

## One ordered chat service

`AtemSessionChat` replaces the approval-only observer. Native approval activity
and the API share one conversation per full target and attachment. It starts
with read-only `open`, then `opened` sequence 0, whole messages and an explicit
`history_end`. No `open.before`, `open.generation`, `status.page` or delta path
is used. API reads of additional targets prioritize those subscriptions within
the same bounded pool; they do not create independent host authorities.

History requests have exactly one selector: `before`, `next`, `turn_id` or
`request_id`. Each page has a local pending result until its ordered boundary
arrives. At most four pages are retained per view, eight valid requests/sec,
50 messages, 256 KiB content and 1 MiB serialized data per page, including the
boundary. The retained timeline is bounded to 500 messages/8 MiB per view,
with at most eight views. API snapshots return at most 50 messages/900 KiB of
message data and explicitly report local truncation.

Whole messages replace prior versions at the shared stream sequence; delayed
pages never regress newer content. Recovered messages use the presence of
`after_message_id`, including explicit null, to insert into the timeline.
Coverage, retention truncation and holes remain visible and never cause a
reopen. A sequence gap or host close fence triggers bounded resynchronization;
a changed process generation refreshes the authoritative registry first.
Page errors affect that page, not the whole conversation. A missing boundary
is unconfirmed, never an empty completed history. Polling cannot reopen a
failed subscription indefinitely.

## Validation and rollout

`Tests/AstationTests/Fixtures/atem-session-v1/source.json` pins the complete
published fixture set with SHA-256. All seven client scenarios run through
the actual Swift wire decoder and client, including revision rejection,
feature negotiation, delayed Send replies, truncation and sequence recovery.
Host-only fixtures are retained with their upstream ownership; importing them
is not a claim that Swift executes the host journal or agent runtime.

Focused integration tests also exercise API Send/takeover/renew/release,
lease-free approvals, native/API ownership races, release before a delayed
receipt, receipt projection changes, ordered history pages, late whole-message
updates, recovered null predecessors, page errors, missing boundaries and
unsupported-host filtering. API transport tests cover loopback/bearer admission,
Origin rejection, strict JSON and request-size limits.

Provisioned local verification and read-only Genie handshake results are
recorded in the PR. Live mutation tests against disposable Claude/Codex
sessions remain distinct from deterministic conformance tests: do not send
prompts, interrupts, stop requests or approval decisions to a user's working
sessions merely to verify discovery.

On 2026-10-18, the personally provisioned build passed 941 Swift tests
(six environment-dependent skips, no failures), including all seven shared
client scenarios. Release compilation, 65 automation tests and 18 packaging
tests also passed. The provisioned app was relaunched from its canonical
local bundle and connected to Genie's r8 runtime. Both Claude and Codex were
discovered with all nine negotiated features; each read-only chat view reached
an explicit complete `history_end` with no error. Their histories were empty
at that point. Neither discovery nor chat reads acquired control. This live
check establishes handshake, registry and empty-history boundaries, not prompt
execution, nonempty pagination or provider approval behavior.

The implemented API uses polling for chat, approvals and receipts. A native
full conversation UI, SSE replay/notifications and offline APNs delivery remain
separate work; r8 support does not claim those interfaces are complete.
