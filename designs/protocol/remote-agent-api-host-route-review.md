# R9.7b final host-route delivery review

Reviewed 2026-10-22 at immutable Atem #89 source
`83c0776d21fa35c656eefaee25edd03cbbd203ee`, tree
`08ec638aac7b71f60bf4f09c655a8c99b95eb007`.
[Final delivery](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6340237151),
[corrected source review](https://github.com/Agora-Build/Atem/pull/80#issuecomment-6340020747),
[prior findings](https://github.com/Agora-Build/Atem/pull/80#issuecomment-6339594928).

## Accepted shared implementation

The correction from bdc29e9 comprises three commits/eight changed blobs,
previously downloaded, read and checked against their immutable Git hashes.
The two findings are now closed in source and runtime execution:

- Carrier A retains the owner-present Astation-authenticated room for pairing,
  initial verification and manager reconciliation of a held host, without a
  route proof. Carrier B independently creates/holds the proved route, with
  isolated candidates, durable binding and replacement fencing. Existing
  membership, manager, freeze and r9-only device admission rules stand.
- A valid route verdict survives initial Astation authentication/denial in
  either order. The host preserves the independent carrier, saves granted
  sessions through the existing guarded path and waits at most ten additional
  seconds for a late verdict only if this link sent its proof.

All 216 current changed PR #89 paths agree with the complete immutable tree;
PR #80 still has its signed-off c685abab contract head. Fresh submitted/inline
reviews are empty on both PRs. The shared verifier, its consumer tests and the
host-route vector fixture are byte-for-byte unchanged from reviewed bdc29e9.
That earlier independent public-vector check verified four Ed25519 proofs,
three P-256 membership-entry signatures/hashes and four refused signatures.
This review does not reinterpret scenario files as executed tests.

## Completed upstream execution

[Host Test 39773150632](https://github.com/Agora-Build/Atem/actions/runs/39773150632)
passes on Linux and both macOS architectures. Its synthetic merge
`b25f0b0cc8bb3b4d7f4233b90cee265b8c228b3a` has exactly the complete source
tree above; the binding jobs check out 83c0776 directly.

Downloaded final Linux logs show 1,845 release unit tests passing without
failures/ignores; each Mac architecture runs 1,843. Linux runs all 18
host-route process cases plus three support cases (21 pass, zero failed or
ignored). The five added cases cover both overlapping-denial orders,
verdict-then-grant with session persistence, an unpinned carrier-A host and
actual held-host manager reconciliation. The process suite is Linux-only;
macOS executes zero of those cases. All 63 selected Linux debug-hook cases
also pass without failures/ignores. Other release integration suites retain
explicit environment/debug-hook ignores.

[Bindings 39773150714](https://github.com/Agora-Build/Atem/actions/runs/39773150714)
passes, including macOS Swift/Apple, Android, Linux Rust/Kotlin/WASM and e2e.
Previously downloaded exact-head logs execute the five shared host-route tests,
the host-route vector runner, 14 stored-log tests and 37 conformance assertions
per Swift/Kotlin/WASM binding. Core checks on three OSes and non-production
harness packaging also succeed. Upstream fake-relay runtime tests do not
establish Astation's database/directory/replica behavior or live agent operation.

## Final packages and Astation integration

All four delivered GitHub ZIP digests, nine SHA256SUMS payloads and clean
SOURCE.json metadata verify against precisely 83c0776. Production feature
metadata matches each package; no archive-supplied shell/build script is
executed. SwiftPM consumes the reviewed manifest, unchanged from 1493ca6.

| Package | Artifact ID | GitHub archive SHA-256 |
| --- | --- | --- |
| Apple | 12422844613 | `427330b2175fffeec595255b4ee9a25f5092991b639887d5fd86e58b09dfd6c4` |
| Kotlin/JVM Linux | 12423052979 | `6949911ed800bb7aaaca5c36491aa7c5399962890dbec5e5c286cc1c92e02c38` |
| Android | 12422554124 | `2202a3b3bdbda2bc67d39f32325e60ddc805e0aef161e9cc1ee329a0b8e5e86d` |
| WASM | 12423337294 | `f5fdbea66bccb29ef18546b7d110f30260aed89acdd5f682ceac6605ba927e1f` |

Astation's Apple package and relay Cargo dependency now use this pin. The
Apple manifest, generated Swift wrapper and C header equal accepted 1493ca6;
the Rust-only host-route verifier adds no binding API. The production Apple
static library passes 19 local Swift consumer assertions. The relay builds
only the shared library dependency; no Atem host or FFI source is built.

The relay now drops every owner-carried `type:"relay"` message before routing,
including the inner payload of generation-bound targeted messages. Host-carried
relay messages already terminate in the push ingress. This prevents a peer
from supplying host challenges/verdicts or receiving host proofs; ordinary
owner traffic and opaque channel bytes retain their existing routing.

The real WebSocket regression first reproduced owner-to-host challenge
forwarding before the fix; host-to-owner interception already passed. With
the fix, the complete relay suite passes 505 tests, with 115 explicit
environment-dependent ignores and no failures. Both broadcast and targeted
injection are exercised, along with ordinary traffic in both directions.

The macOS app builds against the new package. The native run executes 120
tests with zero failures and one optional loopback issuer skip, excluding the
existing external `sysctl` boot-ID check that this worker's sandbox denies.
The initial full 121-case run hit two assertions in that single environment
check; this is not a claim of a fresh 121-case/platform pass. No protected
owner ceremony, real agent, Android device load or provider execution is added
by these checks. The installed provisioned Local.app remains at 5aa3efd.

## Remaining gates

This accepts the delivered shared source/runtime and packages for integration.
The Astation relay still needs both carriers, absent-room challenge admission,
candidate isolation for B, durable `(genesis_hash, host_id)` binding,
cross-replica fencing before route exposure, verdicts, membership-change
revocation/replacement and proved-route presence retention. Run the
[no-Mac restart/rejoin/removal matrix](r9-host-routing-lifecycle.md) against the
real runtime after these are implemented. No live relay lifecycle pass is
claimed by this dependency/interception increment.

Joint provisioned owner/real-agent ceremony remains a release gate. Push
providers remain follow-up. The known low-severity host follow-up discards a
fresh `auth_required` during the bounded late-verdict wait; it retains the
routed link and recovers on the next challenge or link loss. No new user
product/security decision is pending. No live keys, pairings, trust floors,
credential-agent state, merge or deployment are changed.
