# Astation r9 client

Astation requires revision 9 inside an authenticated `atem-ch1` channel.
The native shared library is pinned to Atem
`1493ca6a5d704484bff7b30b09222cf20658fdcd`; the relay consumes its reviewed
wire-compatible `eaaadc23477d12f1e2a0caa56ccafb1dd45be571` library.
The plaintext session handshake, old fixture runner and unused browser
protocol replica are removed. No r8 transport or fallback remains.

## Admission and trust

The shared core builds the encrypted revision 9 hello only after verifying
the host's signed accept with its independently pinned membership key.
`AstationR9Connection` admits only the shared core's verified welcome, checks
the expected account/host/native kind, and passes it to the presentation
service. Plaintext session, terminal and chat traffic cannot enter that service.
Only known advertised features are enabled.
An incompatible Atem is hidden from Connections, agent selection and the local
session API; Connections explains: "This Atem version is not supported.
Upgrade Atem." API status exposes `atem_upgrade_required`. Reconnection after
an upgrade performs a new handshake. Silence times out without an automatic
retry or a claim that the host is incompatible: a halted journal can also
withhold welcome.

Authority comes from proof of possession against the independently anchored
signed membership log. Account login and legacy pairing identify routing
context only. Durable membership advances commit before channel effects;
uncertain storage, unknown/removed members, frozen accounts or unpinned hosts
stop admission. Channel access needs active native view membership, not the
manage role. The relay cannot establish identity, permissions or encryption
state. Local port 8080 remains for same-machine transport and the opt-in API.

An authenticated newer membership head pauses operations. The coordinator
fetches and verifies the chain, commits it and opens a fresh channel. A head
already held on the same chain does not reconnect. Divergence, failed storage
or a removed member requires review and cannot silently resume.

Each live host socket has its own generation-bound router, with unique handles
even if a router is replaced on that socket. Writes are ordered and bounded to
64 frames/4 MiB. Failure closes the affected channel; ciphertext and uncertain
commands are never replayed. Peer close is not echoed. Disconnect, sleep and
late owner-auth replies cannot restore a lost attachment or lease. Repeated
verification notifications do not restart an in-progress signing prompt.

Native owner confirmation can be reused for less than five minutes while
foregrounded. Background, lock and sleep clear that reuse. Membership changes
always require their separate fresh, body-bound confirmation.

`RemoteRelayClient` also opens its own outbound WebSocket without this Mac's
identity-room connection. See the [independent API](../../docs/remote-api.md)
for routing, account authentication, bounds and current deployment limits.

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

The native adapter tests exercise the production shared library's handshake,
signature refusal and cancellation, raw envelope reader/router, unique
generations, deadlines and ordered bounded writes. The relay has a real
WebSocket test with P-256 native proof, independently signed host accept,
encrypted welcome/registry and replay refusal while no Mac is connected.
The shared core owns cryptographic/protocol conformance; the Swift app retains
tests for its presentation, durable requests, leases and local API.

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

The implemented API uses polling for chat, approvals and receipts. A native
full conversation UI, SSE replay/notifications and offline APNs delivery remain
separate work. Controlled transport tests do not establish production Auth,
mobile owner authentication, APNs/FCM or a live re-pairing ceremony.
