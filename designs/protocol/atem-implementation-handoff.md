# Atem and Astation session integration handoff

Historical review/handoff: this records the earlier implementation and is not
the current remote-admission or approval contract. Use [r8-client.md](r8-client.md)
for shipped behavior and [remote-agent-api.md](remote-agent-api.md) for the
aligned r9 plan. Atem #81 owns handoffs; PR #80 owns the new shared contract.
Old freshness attestations, lease-taking approval answers and recovery/push
policies in this snapshot are superseded by those documents.

Updated 2026-10-16. The consolidated Astation work is in
[draft PR #50](https://github.com/Agora-Build/Astation/pull/50),
`feat/push-approvals`, against main. It includes the session client from the closed
PR #49 and the native approval inbox, now pinned to r7.1. All Atem implementation belongs to the
Atem owner; no Atem checkout was modified or built for this integration.

The session contract has no legacy fallback. The current runtime and
r7.1 contract are consolidated in
[Atem #72](https://github.com/Agora-Build/Atem/pull/72), `feat/session-runtime`.
The protocol, host handoff and all shared fixtures pin the published contract at
`6edda2490f4a4b7634edb446f64aa02748e29fa2`
([protocol](https://github.com/Agora-Build/Atem/blob/6edda2490f4a4b7634edb446f64aa02748e29fa2/designs/protocol/atem-session-v1.md),
[host handoff](https://github.com/Agora-Build/Atem/blob/6edda2490f4a4b7634edb446f64aa02748e29fa2/designs/protocol/atem-host-handoff.md)).

## Ready on Astation

- One authenticated session client per host connection serves Connections,
  terminal windows and the approval inbox. The registry supplies exact session,
  process, workspace, capability and activity data. Refresh sends session list,
  never agentListRequest or terminal list.
- The process-state dot is green for running sessions, including Codex with
  unknown activity. Idle / Working / Waiting / Unknown describe activity
  separately. Stopped processes remain unavailable; legacy activity alone
  never claims the process is running.
- Each new attachment resets sequence, registry, removals, terminal queues,
  pending replies and leases. Durable trust/runtime fences and submission
  recovery metadata survive. Reconnect queries receipts without replaying a
  command, approval answer or control acquisition.
- All requests bind the full target and attachment; mutations bind the lease.
  Terminal host events use verified connection, process, subscription and
  stream fencing. Removed operations have no outgoing fallback. Family errors,
  local takeover, deadline expiry and stale replies cannot restore authority.
- Claude structured prompts require chat-v1. Codex uses terminal input/paste.
  Browser access stays disabled, including before hello, pending the secure
  companion contract. No unbound chat is sent.
- Native r7 approval requests arrive independently of a lease. Allow once,
  Claude's exact offered Always allow rule and Deny use durable approval
  submissions with acquire:true. See the
  [approval lifecycle and remaining integration](push-approvals-handoff.md).
- Connections shows session handshake failures and allowlisted error codes.
  Pairing-code sockets transfer pairing credentials but never enter the online
  Atem list or become a session/control target.
- Retry Session Connection closes/reopens the transport, completes fresh relay
  key verification and saved-session authentication, then sends one hello.
  Sleep fences attachment/control state and closes the sockets; wake reconnects.
  A post-welcome unauthorized reply reconnects once. Initial refusals stop
  without a retry loop or misleading verification instruction. A local socket
  generation fences recovery even when Atem's connection_id stays unchanged.
  Retry does not repeat hello on the old socket. A recreated client on a
  surviving authenticated link can receive the r7.1 replacement welcome;
  old authority is fenced and durable receipts survive. The new shared host
  fixture is pinned and its request shapes decode with a UUID for ${gen2}.
  Host admission, dispatch and replacement-rate assertions need Atem's runner;
  see the [joint test matrix](session-validation.md).
- The optional [local API](../../docs/local-control-api.md) lists sessions,
  cards and receipts and submits controlled prompts/approval answers through
  the same native client. It is disabled by default, loopback-only and requires
  a protected same-user bearer key. UUID retries are idempotent.
- Astation has no VisualizeRequest/VisualizeResult types, senders or handlers;
  Atem may remove its remaining types/stub. See the
  [account trust review](account-trust-review.md) and
  [host push proof proposal](approval-push-proof.md) for the remaining joint gate.

## Local validation

The provisioned personal-team `Astation Local.app` runs from
`Astation/.build/Astation Local.app`, retaining bundle identifier
`build.agora.astation.local.xmgq79xmd5` and its protected Keychain access group.
Strict signature checks and bundled transcription/terminal resource checks
pass. The profile has no APNs entitlement; only offline push is disabled.

On 2026-10-16, the rebuilt provisioned Genie link completes
`hello -> welcome -> list -> sessions`. Connections shows exactly one online
Atem, `relay:Genie`, with:

- Claude `ses-vozq7s7qkbvr`, Idle.
- Codex `ses-m636w7gytzwx`, activity Unknown as reported by the host.

The user's Connections screenshot confirms both process dots are green while
the independent labels remain Claude Idle and Codex Unknown.

The earlier 19:42 hello received an error before safety-code verification
finished. Its old logger hid the error code, so that specific refusal cannot
be identified retrospectively. A fresh authenticated connection after
verification succeeds. The spurious `relay:TZAZ-Y9W6` row came from Astation
adding its own pairing transport as an online Atem, rather than evidence of a
second Atem runtime socket.

All ten actual WebKit renderer tests pass. The full Swift suite executes 907 tests,
11 environment-dependent skips, zero failures. The skips cover provisioned
XCTest/Keychain, live capture and optional local model integrations; they do
not represent a live APNs or agent-approval test. A harmless print-only prompt
was submitted to the existing `atem-jt-proj` Claude test session through the
local API and received a completed receipt. Control was released. An identical
UUID retry returned the same request; changed bytes were refused. No approval
card was emitted, so no approval decision was sent and the live allow/deny
matrix still needs an actual permission-triggering test prompt from Atem.

A second harmless delayed prompt, request
`afabc6fe-2496-4141-9702-581de0281a7d`, was executing when Astation quit. The
provisioned app relaunched, authenticated and recovered the original completed
receipt, with both agents still running and no inherited control. The first
observed host state was executing, so the exact accepted-before-executing
disconnect race remains a controlled joint test rather than a claimed result.
The live expiry test paused Mac renewals for 17.17 seconds without sending
agent input: the host controller cleared, Astation reported Control expired,
and control stayed released. A deliberately delayed renewal reply still needs
host timing control; deterministic client coverage already refuses it.

The clipboard update removes toolbar Copy/Paste in favor of Paste & Go.
Cmd+V now cancels WebKit's native default as well as xterm handling, preventing
duplicate paste requests. Native Edit/right-click paste follows focus and
does not submit; Paste & Go targets the selected terminal and appends Enter
in one bounded, ownership-fenced write. Empty, oversized, stale and read-only
pastes never send a stray Enter. Physical Claude clipboard retesting remains
a joint UI check; no agent input was sent to test this change.

Selecting another agent now automatically opens its terminal without requiring
View. Switching releases previous control and begins view-only; View remains
available for retry/reload. Three regressions cover switching from control,
late attachments/screens from the previous session and a pending list refresh.

[Astation issue #51](https://github.com/Agora-Build/Astation/issues/51) records
Brent's follow-up for image/audio/PDF/other-file attachments in the separate
composer. Coordinate file transport, provider support and remote cleanup with
the Atem owner; attachment implementation is outside the clipboard fix.

Relay push-related tests pass (16 tests; two database integration tests remain
ignored without their database fixture). Memory writes are currently refused
because they do not match the account encryption mode. The new attachment TODO
was not found after the CLI reported it added and then refused. Use issue #51
and these hosted docs for durable cross-machine coordination; do not assume
the memory reached Atem.

Production is unchanged: health reports main `9245603`, two replicas and Redis
OK. Relay account registration still refuses the Agora verifier configuration
(`AGORA_ACCOUNT_USERINFO_URL` / `AGORA_ACCOUNT_SUBJECT_FIELD` absent). That is a
separate account-discovery gate; the saved paired Genie connection works.

## Joint tests remaining

1. Use the same pinned r7.1 #72 runtime for pair/verify/launch, preserving
   existing sessions. Run second-hello-replaces-the-attachment.json in Atem's
   host runner. Confirm UUID capture, old binding stale_target, no inherited
   control, unchanged authorization deadline and busy within one second.
2. View each session, then explicitly take control to type/resize/paste and
   release. Host local input must revoke queued remote writes. Expiry and late
   renewal must not restore control. No legacy control op or lease_id is sent.
3. The live Claude prompt and disconnect-during-execution receipt recovery
   passed. Test interrupt and stop separately. Disconnect immediately after acceptance; reconnect queries
   the original receipt without another dispatch or a restored lease.
4. Trigger real Claude and Codex approval hooks with no lease holder. Check
   in-app alert/inbox, exact Claude rule confirmation, atomic answers, terminal
   answers, expiry, duplicate catch-up and delayed receipts. Disconnect or
   revoke while a request is pending; stale cards must be disabled.
5. Reauthenticate/reconnect to the same runtime, then restart the runtime.
   Registry sequence can restart, but runtime rollback and old process/stream
   frames remain refused. Exercise busy/stale-target/family error fixtures.
6. Unpair/revoke and pair/verify again. Old authority never returns. Local
   agents, memory, vaults and saved credentials remain intact.

The actual host currently supports one native Astation link; multi-attachment
core harness coverage does not establish simultaneous live controllers.

## Trust and offline delivery gates

Section 9 remains the gate for resume, browser/QR grants, account-wide native
access, signed membership/revocation ordering, freshness proofs and live
traffic E2EE. The relay is never identity, encryption-state or control
authority. Compatibility mode does not claim relay confidentiality.

Offline push needs an eligible push-enabled Apple profile and APNs provider
credentials, authenticated Atem-to-relay device proof, authorized recipients
and a durable, revocation-aware dispatch outbox. Current room ids and SSO/data
account grouping cannot supply that authority. The native inbox and transport
adapters do not imply live APNs delivery. See
[provider setup](../../docs/push-notifications.md).

Use this hosted handoff for cross-machine coordination. Shared Atem memory
sync is currently refused with `memory does not match the account encryption
mode`; do not assume this update reached the shared store unless sync succeeds.
No production merge or deployment is included.
