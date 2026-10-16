# Astation atem-session v1 implementation

Date: 2026-10-16

Branch: `feat/session-multiplexing`, [draft PR #49](https://github.com/Agora-Build/Astation/pull/49),
targeting `main` and retaining both commits from superseded #48.
Contract: [atem-session r6.2](atem-session-v1.md), Atem PR #68, history tag
`atem-session-v1-r6.2` at `22de096b1980ee3ae342c0352b4c1d5fa54e3b51`.
Host: [Atem PR #69](https://github.com/Agora-Build/Atem/pull/69), run instructions
and coverage in the [pinned host handoff](atem-host-handoff.md), read at
`a09be62c4db344b9a0540cf68f2ae4b28852844a`.

## Lifecycle and invariants

1. The hub captures account, verified host device, exact authenticated socket
   and pairing session before asynchronous dispatch, then rechecks that context.
   Message fields and relay presence cannot supply identity or authority.
2. One client per authenticated host connection owns hello/welcome, the registry
   and leases. Connections and terminal windows share it. Opening or reopening a
   window never sends another hello on a welcomed attachment. Failed attachments
   wait for a replacement authenticated connection. No resume or auto-control.
3. Every welcome clears sessions, sequence, removals, pending operations,
   terminal subscriptions and leases; retain durable host trust/runtime floors
   and request recovery metadata only. The first snapshot can use any sequence.
   Reject runtime rollback, gaps, incomplete descriptors and removed-process
   resurrection within the current attachment. Runtime floors commit durably.
4. Session-v1 list is the only registry. Removed agent lists, terminal lists,
   control/lease_id, unbound voice/prompts and console commands have no production
   fallback. Browser host access is disabled even before hello. The old browser
   UI and its isolated tests remain for future companion work, without transport
   authority. Native UI disables Open in Browser.
5. Terminal requests carry the exact account/host/trust/session/process target
   and attachment; mutations additionally carry the current lease epoch. Actual
   r6.2 host events carry no binding. Accept them only from the captured verified
   connection and correlate subscribe/process/stream locally. An error for a
   replaced stream cannot close its successor. Per-attachment resets drop old
   terminal queues and subscriptions.
6. Session errors accept absent `re` for removed/undecodable requests. Terminal
   errors preserve terminal id, optional stream id, code and message; chat errors
   preserve code and request id. There is no cross-family receipt interpretation.
   Permission, closed-session and stale-lease refusals remove local control;
   stale targets refresh the registry, without replaying a submission.
7. Acquire control explicitly; renew every five seconds and expire at
   `now >= deadline`. Correlate each grant once, estimate deadlines from request
   send time and fence late grants. Repeated acquire never extends control;
   lease epochs can skip. Read-only or terminal-only capabilities never grant
   control or imply structured prompt support. Codex uses terminal typing/paste.
8. Persist request id, full target, kind and JCS digest before submitting prompt,
   interrupt or stop. A failed local save sends nothing. Disconnect never replays
   submissions or PTY input; reconnect queries original receipts, including old
   process targets. Host admission is permission, accepting session, then lease.
   Busy leaves the recovery identity unresolved for receipt queries: the host
   branch documents that a double I/O failure can make delivery uncertain.
9. The shared journal contains recovery metadata, not prompts, terminal output,
   keys or control authority. Use one journal for every host client to avoid
   overwriting another host's records. Restricted temporary files, fsync, rename
   and directory fsync commit writes; corrupt load/uncertain save fails closed.
   Retain at most 4096 requests and 128 host fences; only final receipts can be
   evicted to admit work. Final outcomes are immutable.
10. Parse original direct/relay bytes before Foundation loses duplicate keys or
    number spellings. Enforce safe counters, Unicode identity and payload bounds.
    Debug logging redacts session and terminal contents, including bad packets.
    Section 9 trust, secure grants, freshness and traffic E2EE remain disabled;
    r7 prompt-bound approvals await their separate contract.

## Validation

All 18 upstream fixture blobs are verified against their Git object hashes on
import, copied byte-for-byte to design/test resources, and pinned by SHA-256 in
`Tests/AstationTests/Fixtures/atem-session-v1/source.json`. This includes the
schema, digest vectors and 16 scenarios. The obsolete r5 legacy-bypass fixture
is replaced by removed-ops-have-no-effect.

Swift and offline JavaScript run all three client scenarios through their real
wire decoders: late/duplicate renewals, runtime/sequence ordering and new
attachment reset. Harnesses recognize the documented steps and assert the
reported state rather than skipping unsupported assertions. A fixture welcome
represents a new authenticated test transport and is correlated with its hello.
Native tests also cover actual terminal binding, unbound host events, family
errors, admission refusals, busy receipt recovery, no second hello, disabled
browser fallback, revocation, persistence failure and journal reload.
Host-side fixtures are data for Atem's runners; these client results do not
claim to execute a Rust host or the real runtime/worker harness.

```sh
swift test --filter 'AtemSession|RemoteTerminal|AgentInputRouting|BrowserAgentChat'
node --test webapp/tests/*
python3 scripts/setup-terminal-assets.py --verify
```

Final focused run: 102 native tests pass; webapp: 49 pass, one skip;
eight pinned terminal assets verify, including the final permission/capability
regression and the refusal-during-resync check.

The broader local run passed: 849 tests, eight skipped, zero failures, explicitly
excluding the five previously documented local failures:

- `AtemE2EIdentityTests.testRealProtectedIdentityReloadsRecoveryPinsAndEpochs`
- `AtemE2EIdentityTests.testRealProtectedMigrationJournalRecoversAndCommitsOnceAfterIdentityReload`
- `AtemE2EIdentityTests.testRealProtectedStorageKeyEscrowRestartUnlockAndReplayRejection`
- `FloatingSpeechControlsTests.testManualCaptionScrollHoldsSnapshotFor15SecondsAndResumesWithoutNewSpeech`
- `TimeSyncTests.testMultipleCallsReturnConsistentTimestamps`

The previous unfiltered run failed protected-key creation (-25308), the caption
scroll assertion, and a subsequent broader run failed TimeSync after network
timeouts. The production files for those tests are unchanged; do not report an unfiltered full local
suite as green. Previous CI passed r5 implementation `328c7d1`; r6.2 needs its
own PR checks after this push.

## Joint integration and release gates

See the [Atem owner handoff](atem-implementation-handoff.md) for the concrete
live checks. The host currently has one Astation link/attachment at a time.
Multiple independent agent sessions can share that link; multiple simultaneous
native controllers and QR companions still require section 9.

No local Atem checkout was changed, built or tested. No active agent process or
installed app was replaced/restarted, no PR was merged, and nothing was deployed.
