# Atem and Astation Session Integration Handoff

Date: 2026-10-15

All Atem implementation belongs to the Atem agent. Astation implements the
native client against [accepted r5](atem-session-v1.md), pinned at
`44987915fb24267960fd9d75221df4ed8c7838ec`. See the
[client implementation evidence](astation-session-v1-implementation.md) and
[product design](../session-multiplexing.md).

Review the Astation client in [draft PR #49](https://github.com/Agora-Build/Astation/pull/49),
stacked on #48. The implementation commit is `328c7d1`. Nothing is merged or
deployed. Use this hosted handoff for cross-machine coordination: a local Atem
memory record was created, but the relay refused its sync because the memory
did not match the account encryption mode. It is not confirmed shared memory.

## Published Atem lifecycle changes

The owner's `feat/status-pair-verify` is available on GitHub. Its current head
was checked through the GitHub API:

- [bf0df23](https://github.com/Agora-Build/Atem/commit/bf0df23daa87a3a0deff8460dd0527ef05e75853):
  durable monotonic host trust generation and random pairing binding; unpair
  advances trust before cleanup, and delayed authentication applies only while
  the captured pairing and saved session remain unchanged.
- [207b0e9](https://github.com/Agora-Build/Atem/commit/207b0e9a7852c1a8fa818465cb7fd9da76221053):
  interrupted unpair cannot use leftover sessions; token refresh reloads stores
  and cannot restore a removed pairing or credential entry.

The owner's unified status, idempotent `pair`, explicit `pair verify`, and
credential unlock/lock gates are the source of truth. No duplicate Atem command
implementation is needed. These commits were read, not built or tested locally.
Their publication alone is not evidence of an operational r5 host.

## Ready on Astation's side

The native remote terminal starts `session/hello` only on an authenticated,
safety-code-verified connection. It checks account, device, socket and pairing
context before dispatch and before sending. The registry, attachment, lease,
and full process target govern terminal access. Prompt, interrupt and stop
submissions have durable local request identities; reconnect only queries their
receipts. No prompt text or PTY bytes are saved in that recovery journal.

Swift and offline JavaScript run the shared digest/rejection vectors and both
client scenarios using their wire decoders. Native integration tests additionally
cover actual terminal binding, revocation, exact expiry, reconnects, receipt
recovery, durable-write failures, and disk reload. The browser module is
conformance code with live host access disabled.

[GitHub CI](https://github.com/Agora-Build/Astation/actions/runs/38832982893)
passed for Astation implementation commit `328c7d1`, including macOS build/tests,
relay tests and webapp tests. Joint live testing against the owner's r5 host
remains outstanding; passing client CI does not establish host conformance.

## Next work with the Atem owner

1. Implement/confirm the r5 host hello/welcome, complete registry values,
   revisions, target binding and runtime restart behavior. Welcome must use
   authenticated account/device identity and the durable `pairing.json` host
   trust generation. Astation refuses rollback, missing fields and unsafe counters.
2. Enforce the same 15-second lease across direct/relay terminal, chat, voice,
   interrupt, stop and every other mutation path. Local input wins at the PTY
   write boundary. Host replies and streams carry the exact target and attachment;
   terminal IDs/generations must agree with their binding. There is no legacy
   control fallback once the socket starts v1.
3. Run the host-side shared fixtures against the actual Rust decoder, receipt
   journal and PTY dispatcher: expiry/local input, legacy bypass, duplicate/reused
   requests, pre-effect failure versus partial writes, restart and receipt recovery.
   Add the remaining scenarios in upstream section 8, especially immediate
   disconnect after acceptance and unpair/trust changes before dispatch.
4. Test the two actual builds together: simultaneous viewers; explicit takeover;
   independent agents; exact-deadline expiry; reconnect with pending receipts;
   interrupted unpair/re-pair; old/new runtime ordering. Check zero duplicate
   dispatches and no restoration of control or keys after revocation.
5. Keep browser work gated. The old Astation browser bridge works only on an
   unupgraded socket. Starting native v1 disables existing browser links on that
   socket and refuses new ones, including when welcome is delayed/lost. It does
   not send unbound chat submissions to a managed host. Secure companion grants
   and a browser control UI require the section 9 contract first.

Host supervision, worker adoption, durable host receipts/history and recovery
remain Atem responsibilities. Astation's client journal is neither the host's
receipt authority nor proof that a command executed.

## Security release gate

Upstream section 9 is still open. Account-wide native enrollment, resume,
standalone/independent browser access, authenticated freshness and live traffic
E2EE must stay disabled until jointly specified, implemented and tested. Relay
labels, account claims and presence do not establish identity, encryption state,
trust generation, control authority or authorization freshness.

## Correction of the earlier local experiment

Earlier wording about "current Astation/Atem worktrees" referred to an
uncommitted experiment at `/Users/brent/Dev/Agora.Build/Atem-session-multiplexing`,
based on `10d3ea874ef25347dd4447fa27e7c64654785a13`, not a published Atem build.
That checkout is preserved and work on it has stopped. Its transitional lease
and chat policies are superseded by r5 and the owner's implementation. Do not
build on it or apply its old patch wholesale. No local Atem checkout was changed,
built or tested during this Astation client integration.
