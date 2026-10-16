# Atem and Astation session integration handoff

Date: 2026-10-16

Astations and Atems update together to **atem-session r6.2**, with no backward
compatibility. Review [draft Astation #49](https://github.com/Agora-Build/Astation/pull/49),
which targets `main` and contains superseded #48. All Atem implementation belongs
to the Atem owner; Astation has not changed, built or tested an Atem checkout.

Contract: [Atem #68](https://github.com/Agora-Build/Atem/pull/68), history tag
`atem-session-v1-r6.2`, pinned `22de096b1980ee3ae342c0352b4c1d5fa54e3b51`;
[exact snapshot](atem-session-v1.md), [fixtures](fixtures/schema.md).
Host: [Atem #69](https://github.com/Agora-Build/Atem/pull/69), `feat/runtime`,
read at `a09be62c4db344b9a0540cf68f2ae4b28852844a`;
[build/run instructions and real-runtime coverage](atem-host-handoff.md).

## Astation changes ready for joint testing

- One authenticated session client per host connection, shared by Connections
  and terminal windows. No second hello when opening or reopening a window.
  The session registry replaces both removed lists and supplies exact process
  ids, workspace labels, capabilities and activity to the UI.
- Every new attachment clears sequence, registry, removals, terminal queues,
  pending replies and leases, while retaining durable trust/runtime fences and
  submission recovery metadata. A first snapshot at sequence 1 after 100 works.
- Requests bind full target/attachment and mutation lease. Actual r6.2 terminal
  host events are unbound; Astation checks verified connection, exact process,
  outstanding subscription and stream instead. Old-stream errors are ignored.
- Removed operations have no outgoing fallback. Session unsupported_version
  errors can omit re. Terminal and chat preserve family error codes. Permission,
  session_closed and stale_lease refusals remove control without replay.
- Prompt/interrupt/stop requests persist their identities before sending.
  Reconnect queries the original receipts. Busy also keeps a request unresolved
  and never causes an automatic resubmit. Codex uses terminal input/paste;
  structured prompts require chat-v1. Leases retain exact-deadline fencing.
- Browser access is disabled on all host sockets, including before hello; no
  unbound chat is sent. Open in Browser is disabled pending secure companions.
- All 18 r6.2 fixture files are copied and pinned; Swift and offline JavaScript
  run all three client scenarios, plus digest/rejection vectors. Host scenarios
  remain the owner's responsibility. See [validation evidence](astation-session-v1-implementation.md).

## Joint live test sequence

1. Use the same #69 binary for pair/verify/launch on an isolated test profile;
   preserve existing sessions. Run instructions are in the host handoff. Build
   Astation #49, authenticate/verify the host, and check exactly one hello/welcome
   even when Connections refreshes and terminal windows reopen.
2. Launch Claude and Codex and another session of one provider. Confirm each
   session/workspace/process appears, can be selected and viewed independently,
   and updates activity/removal without agentListRequest or terminal list.
3. Take Control, type/resize/paste and release. Local host input must revoke
   remote input at the worker write boundary. Expiry and late renewal must not
   restore input; large durable epoch jumps must work. No legacy control op or
   lease_id is sent. Provider approvals still use the controlled terminal.
4. On Claude, submit a prompt and observe accepted/executing/completed; interrupt
   and stop use their own receipts. Codex's structured prompt field is disabled.
   Disconnect immediately after acceptance and restart/reconnect the runtime;
   query the original receipt without a second dispatch or restored lease.
5. Reauthenticate/reconnect to the same runtime. The registry sequence can
   restart at 1, removed-process caches clear, runtime rollback stays refused,
   and old terminal frames/errors cannot enter the new subscription. Verify
   session_closed is handled before stale_lease when both conditions apply.
6. Exercise terminal busy/stale_lease/stale_target errors and chat rejected or
   outcome_unknown in their own families. Removed forms return session
   unsupported_version, including without re; malformed messages never write.
   Browser open and unbound submit stay disabled.
7. Unpair/revoke with a pending request, then pair/verify again. Old authority
   never returns, pending work is not replayed under new trust, and local agents,
   memory, vaults and saved credentials remain intact.

Atem's real runtime currently supports **one Astation link/attachment**; do not
advertise simultaneous controllers or execute a multiple-link live test yet.
Its core harness covers the multi-attachment scenarios. New fixture steps
include reconnect, close_session, turn_complete, held/flushed PTY writes,
family-filtered expect, captures and end-of-scenario queue exhaustion. The host
handoff distinguishes actual binary coverage from core-only or unsupported
fault steps; client tests do not expand that claim.

## Contract clarifications for the Atem owner

The pinned host handoff says every terminal message carries a binding. Its wire
implementation and actual host events instead require bindings only on requests
and prohibit them on host events. Astation follows the implementation and
fixtures, with local connection/process/stream fencing for responses. Clarify
that sentence in the owner document for joint testing.

The #69 contract adds a double-I/O-failure exception to busy admission: a request
answered busy might still dispatch once under its original identity. The r6.2
tag/#68 text says busy records nothing. Astation conservatively retains the
request for queries and never auto-resends it; reconcile the wording upstream.
Neither clarification blocks the client changes or initial live tests.

## Security and approval gates

Update, 2026-10-16: the user approved push delivery independently of a lease and
atomic acquire:true answers. See the [push preparation and required joint
contract](push-approvals-handoff.md). Native token registration, provider
adapters and provisioning docs are on feat/push-approvals; host ingress and
decision UI await authenticated host/membership proofs and r7 wire fixtures.
The existing r6.2 client remains unchanged on #49, whose current-head CI is green
(854 Swift tests, ten skipped, zero failures; relay and webapp checks pass).

Section 9 remains open: resume, browser/QR grants, multiple native attachments,
account-wide trust/enrollment, signed membership/revocation ordering,
authenticated freshness proofs and live traffic E2EE stay disabled. The relay
is not identity, trust, encryption-state or control authority. Compatibility
mode does not claim relay confidentiality. r7 prompt-bound allow once / always
allow / deny is being built by Atem; Astation awaits the contract text before
implementing approval decisions.

## Coordination and provenance

Use this hosted handoff for cross-machine coordination. The r6.2 update is saved
locally as Atem memory `mem_ad576dc855114182ae1ef6d30ced6d3d` for project Astation,
but the relay rejected sync: `memory does not match the account encryption mode`.
The earlier r5 memory id was not present in this CLI store. Shared memory is not
confirmed; read the hosted handoff instead. Do not rely on a local Atem checkout.

Earlier worktree wording referred to an abandoned, uncommitted experiment at
`/Users/brent/Dev/Agora.Build/Atem-session-multiplexing`, based on `10d3ea8`.
It is preserved and is not an implementation source. The owner's published
pair/verify/status and trust-generation work (#67) is authoritative.

Nothing was merged or deployed, and no installed app or running agent was
replaced or restarted for this update. #49 remains draft for joint live testing.
