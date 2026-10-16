# Astation atem-session v1 Implementation

Date: 2026-10-15

Branch: `feat/session-multiplexing`, targeting `main`. It retains both commits
from #48, which is closed as superseded by the combined #49.
Review: [draft PR #49](https://github.com/Agora-Build/Astation/pull/49), native
implementation commit `328c7d157f8048e35194b7c1a393c83c4b4fe7b2`.
Contract: [atem-session v1 r5](atem-session-v1.md), upstream
`44987915fb24267960fd9d75221df4ed8c7838ec`. This is native compatibility-mode
client implementation evidence, not a production or end-to-end host signoff.

## Lifecycle and invariants

1. The hub supplies account, verified host device, exact authenticated socket,
   and pairing session from local authentication/verification state. It captures
   that context before asynchronous dispatch and rechecks it on delivery. Message
   fields and relay presence cannot supply this identity.
2. Every replacement connection starts a fresh hello. Native welcome must match
   that context and have view permission. Its authorization deadline is bounded
   by monotonic request send time and at most 24 hours; this cap is not the open
   section 9 freshness proof. Resume and automatic control restoration are off.
3. Trust and runtime fences are saved durably before accepting state. Registry
   updates reject rollback, sequence gaps, incomplete descriptors, and removed
   process resurrection. Runtime restart clears the sequence domain and old
   attachment/leases, and requires a fresh welcome. Tombstones retain each
   removed process generation within the current runtime, up to 4096 total.
4. A selected process can be viewed only when present in the authorized registry.
   Terminal requests bind the full account/host/trust/session/process target and
   attachment. Mutations additionally bind the session lease epoch. Legacy
   terminal control is not a fallback in the native managed UI.
5. Control requires explicit acquisition. Renew every five seconds, expire at
   `now >= deadline`, correlate each grant/renewal reply once, and use request
   send time for the conservative deadline. Revocation fences late replies even
   before an initial grant arrived. A repeat acquire cannot extend control.
   Input handlers check current authority even before the next timer/UI update.
6. Persist a request ID, exact target, kind and JCS digest before submitting a
   prompt, interrupt or stop. A persistence failure sends nothing. Disconnect
   never replays a submission or PTY input. Reconnect queries unresolved receipts
   using their original full target, including targets no longer in the registry.
   Receipt final outcomes are immutable, and a write acknowledgement is not a
   semantic command completion.
7. The recovery journal contains metadata and receipt details, not prompts,
   terminal output, credentials or control authority. File writes use restricted
   0600 temporary files, fsync, rename and directory fsync. Corrupt load or an
   uncertain write failure disables further journal use until reload. Retain at
   most 4096 requests and 128 host fences; only a final request may be evicted to
   admit another. Unresolved requests are not silently discarded.
8. The strict parser sees original direct/relay bytes before Foundation can
   discard duplicate keys or change number spellings. It rejects unsafe known
   counters and invalid Unicode, keeps unknown fields ignorable, and preserves
   distinct Unicode key spellings for canonical digests. Network logging redacts
   session and terminal contents, including malformed/truncated packets.
9. Starting v1 disables the old browser bridge on that socket immediately.
   Browser host access in the new module is false and is not wired to transport.
   An unupgraded socket retains the existing companion bridge behavior.

## Validation

The native tests exercise the actual envelope decoder, session client, hub
authentication dispatch, terminal controller and WebKit renderer. The two
client fixtures cover late/duplicate renewals, exact expiry, runtime epochs,
sequence gaps and removals. Digest vectors and raw parser rejection vectors run
in both Swift and JavaScript. All eight bundled fixture copies match the pinned
upstream files; host scenarios are data for the Atem runner, not simulated host
conformance claims.

```sh
swift test --filter 'AtemSession|RemoteTerminal|AgentInputRouting|BrowserAgentChat'
node --test webapp/tests/*
python3 scripts/setup-terminal-assets.py --verify
```

Latest focused results: 96 native tests pass; webapp tests have 46 passes and
one skip; all eight pinned terminal assets verify.

[GitHub CI run 38832982893](https://github.com/Agora-Build/Astation/actions/runs/38832982893)
passed for implementation commit `328c7d1`: macOS build/tests, relay server
tests, webapp tests and dispatch context validation. Subsequent branch commits
update documentation only. The local failures below are retained as evidence
of the limits of this Mac's test environment.

The unfiltered Swift suite was also attempted: 847 tests, nine skipped, four
failures. Three existing protected-key tests could not create a Secure Enclave
key (`NSOSStatusErrorDomain -25308`, `AKSError -536870174`). The existing caption
scroll test failed its native scroll-position assertion, including in isolation.
Neither test file nor its production implementation is changed by this task.
These checks remain unresolved; do not report the unfiltered suite as passing.

After the final client fixes, a broader run explicitly excluded those four
tests: 844 tests, nine skipped, one failure in the existing
`TimeSyncTests.testMultipleCallsReturnConsistentTimestamps`. Its network clock
requests timed out and consecutive calls exceeded the two-second assertion.
All session tests passed in that run. No TimeSync code or tests were changed.

## Remaining integration and release work

Use the [Atem owner handoff](atem-implementation-handoff.md) for the published
trust-generation/unpair fixes and host requirements. No local Atem source was
modified, built or tested for this integration. Host-side shared fixtures,
crash-surviving workers/receipts, simultaneous real clients, and actual transport
interoperability still need the owner's r5 host build.

Upstream section 9 remains the security gate. This work does not enable
account-wide native access, resume, browser enrollment or live traffic E2EE.
No installed app was replaced or restarted, no PR was merged, and nothing was
deployed by this task.
