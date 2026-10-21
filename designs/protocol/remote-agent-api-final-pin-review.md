<!-- astation-handoff-monitor -->
# Final implementation/package review at 58fa1e9

Published review: https://github.com/Agora-Build/Atem/pull/80#issuecomment-6307612632

Coordination/blocker: https://github.com/Agora-Build/Atem/issues/81#issuecomment-6307616918

Reviewed immutable Atem PR #89 head
`58fa1e92bb99fed1ce81a42fb63ac1226782705b` against
`ade944fe62c2b349f620f3aa96ca79eb0127ad35`, responding to
[the final-pin handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6307433944).
The original quarantine rewrite/restart finding is fixed. A related
repeated-damage/clock-rollback finding remains below; this is not final host
or admission sign-off. No product/security decision is pending.

## High: a second damaged journal can discard the previous quarantine end

The handoff lists this as a low follow-up, but the consequence can be renewed
admission with an already revoked, otherwise valid grant. In
[`load_revoked`](https://github.com/Agora-Build/Atem/blob/58fa1e92bb99fed1ce81a42fb63ac1226782705b/src/session_protocol/r9/mod.rs#L2018),
an unreadable file creates a default quarantine. Its
[`anchor`](https://github.com/Agora-Build/Atem/blob/58fa1e92bb99fed1ce81a42fb63ac1226782705b/src/session_protocol/r9/revoked.rs#L64)
sets `until` from the current wall time, without recovering the previous end
from independent evidence. Keeping damaged files aside preserves bytes but
does not restore that end.

Concrete source trace (all times are the host's wall clock):

1. Grant A is issued at 12:00, expires at 13:00, and is revoked at 12:01.
2. Damage detected at 12:02 creates a durable quarantine ending at 13:07.
   The file now holds that record; A's lost revocation is covered by it.
3. The clock rolls back to 10:00, the rewritten file is damaged again, and
   the host restarts. The new unreadable-file path replaces the lost bound
   with 11:05.
4. After 66 minutes on both clocks (wall 11:06), the new quarantine ends
   and its record is dropped. This satisfies both implemented predicates.
5. The wall clock returns to 12:10. A is absent from the rewritten revoked
   map, its issuer remains authorized, and its signature/target remain
   valid. The unchanged
   [`BrowserGrant::verify`](https://github.com/Agora-Build/Atem/blob/58fa1e92bb99fed1ce81a42fb63ac1226782705b/crates/atem-client/src/principal.rs#L499)
   accepts its time predicates (`issued_at <= wall + 300000`, `wall < expires_at`).
   A fresh channel has no previous channel's monotonic deadline. The original
   13:07 bound would still have refused it.

Please preserve a prior conservative quarantine end independently of another
damaged journal, or keep browser admission blocked when that end cannot be
reconciled. Add the sequence above to the real-runtime regression and require
old A to remain refused when the clock returns, while retaining native
revocation and live fencing. This is a static trace of the pinned source,
supported by a predicate model, not a locally executed Atem reproduction.
The new backward-clock test preserves a readable quarantine record; it does
not damage that record a second time.

## Fix and evidence reviewed

The first corruption's quarantine now survives native revoke B and restarts:
every write carries `{started_at, until}`, and restoration requires both the
recorded wall end and a full 65-minute process monotonic window. The damaged
inode is hard-linked aside before replacement; directory sync, private temp
write, file sync, rename and directory sync preserve the original damaged file
or the new record through the reviewed crash points. Native revocations retain
live fencing and report a failed durable write as `busy`.

Inspected both new engine regressions (rewrite/restart and interrupted aside,
temp-write and rename) and the two real-runtime regressions (A/damage/B/restarts
and backward wall clock with an intact record). The runtime tests actually
start/restart a host on the same isolated journal and use shared-core clients;
the crash-point injections are engine tests. Upstream Test/core/bindings/harness
runs are green at this exact head. The downloaded release Test logs explicitly
show both new runtime tests **ignored: debug-only test hooks**; both engine
regressions ran and passed on Linux and both macOS targets. Green release CI
does not independently demonstrate the runtime sequences. Please provide an
exact-pin debug run of those tests with the repeated-damage regression. Local
Atem execution is not claimed.

The immutable tree delta contains eight paths: two documents, daemon/PTY
cleanup, r9 host wiring, the new revoked-journal module, engine regressions
and runtime regressions. Fourteen changed old/new blobs were downloaded and
Git-hash verified; the unchanged principal verifier and private-file reader
were also verified. All 75 r9 fixtures and all shared client/binding blobs are
unchanged from ade944f. PR #80 remains merged at c685aba, with no inline
comments or reviews.

## Packages and Astation consumption

All five final GitHub artifacts were independently downloaded. Archive digests,
all twelve listed payload checksums, clean `SOURCE.json` commits and feature
metadata verify against exactly 58fa1e9:

| Package | Artifact | Run |
| --- | --- | --- |
| Apple SwiftPM | 12317503957 | 39538413559 |
| WASM | 12317639271 | 39538413559 |
| Kotlin/JVM | 12317744140 | 39538413559 |
| Android | 12317768822 | 39538413559 |
| Non-production Linux harness | 12318825424 | 39538413509 |

Android has the expected three ELF classes/machines, twelve 16 KiB aligned
LOAD segments, the strict generation reader and no checked test/host exports.
WASM module headers and the harness's 23-event sample transcript parse. These
are static checks, not platform execution. ADB lists no connected devices and
the installed SDK has no emulator executable. Android loading and local Linux
harness execution remain NOT RUN.

Astation now pins/consumes the final Apple package independently of host
approval. Compared with accepted edeb8f0, production client source changes are
recovery-resume documentation and an r8 fixture-runner reporting string; the
generated Swift change includes the matching documentation-derived UniFFI
checksum. Use each archive's wrapper and native library together. The package
manifest and all supplied headers match the previous package; pairing vector
bytes remain pinned and unchanged. This dependency update does not wire the
existing app ceremony or enable remote admission.
The scheduled worker could not publish the seven-file final-package/review
follow-up: `git add` could not create the external worktree's `index.lock`
(Operation not permitted). It preserved the complete patch and commit message
under `/private/tmp/astation-r9-final-58fa1e9`. The interactive session can
publish the changes already present in the worktree; the patch must not be
reapplied. This publishes the reviewed dependency, not host approval.

Local final-package validation passes: 19 production FFI checks, 15 native
XCTest cases, five artifact-integrity/installer tests and the full macOS debug
app build/link. The earlier full-app test result (944 executed, 11 skipped,
one caption-scroll failure reproduced on main and tracked in Astation #61)
is historical; it was not rerun for this dependency-only change.
Direct `swiftc` compilation/linking of the supplied wrapper/static library and
the AstationRemote module also passes for arm64 and x86_64 iOS 17 simulator
targets using the installed simulator SDK. This is not simulator execution.
The attempted `xcodebuild` package invocation failed (CoreSimulator/Xcode
version mismatch and no recognized project/workspace/package); no machine
configuration was changed.

The original c685aba contract sign-off and settled recovery/push/authentication
choices stand. Actual ceremony, protected storage/signing, routers, durable push
ingress and platform/relay/provider conformance remain Astation work. Keep the
2 MiB channel and 262144-byte relay limits, cancellation exceptions and no r8
fallback. No Atem checkout was edited/built and no live trust, merge or deploy
action was performed.

Generated with SMT <smt@agora.build>
