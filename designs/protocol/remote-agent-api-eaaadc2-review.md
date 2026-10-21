<!-- astation-handoff-monitor -->
# Corrected final implementation and package pin, eaaadc2

Atem's [final handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6311804983)
supersedes 58fa1e9 with `eaaadc23477d12f1e2a0caa56ccafb1dd45be571`.
The [pinned review](https://github.com/Agora-Build/Atem/pull/80#issuecomment-6311428840)
and [coordination reply](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6311432816)
record the source and execution evidence. Accept this pin and its matching
artifacts for Astation integration. The host journal corruption/clock-rollback
findings are closed; admission and merge/deployment remain gated.

## Source and runtime evidence

The reviews at 59c4610, ae07dec and eaaadc2 cover the host-only delta since
58fa1e9. All four changed blobs in the latest delta match their Git hashes.
The running engine merges the current on-disk pairing bound, and re-pin raises
an intact sidecar with that copy. The shared client (58 blobs), binding
(28 blobs) and fixture directory (149 blobs) are identical to 58fa1e9.
There are no new vectors to approve or substitute.

Test run [39568023669, attempt 2](https://github.com/Agora-Build/Atem/actions/runs/39568023669/attempts/2)
succeeds on all three targets. Its synthetic merge checkout
`cd76bcd72ef1aa0c9b9cc4e048075b6b4baa2c44` has the same complete tree as
the reviewed head: `f231f30cfe8c75b6b331337435556d7909a55343`.
Downloaded Linux logs explicitly pass 1,826 release unit tests and all 63
tests in seven debug-hook suites, with zero debug failures/ignores. The 14
revoked-grants tests include missing main/sidecar, repeated damage and clock
rollback, revocation while behind, runtime/two-file loss after stop/crash,
and retained native revocation/fencing. Both new engine regressions pass.
The two host-bridge tests that failed attempt 1 pass in the rerun; their
original failure cause is unconfirmed. Core/bindings/harness CI is green.
Linux raw-log SHA-256:
`1c0a4abf98876a7c70416b55c6dc2cb31bfe56cf251b663b54554683c8cbf774`.

## Artifact and local consumer checks

All five GitHub ZIP digests match the final handoff and API metadata. All
12 listed payload checksums and clean SOURCE.json commits/features verify.

| Package | Artifact ID | Run |
| --- | --- | --- |
| Apple SwiftPM | 12330892581 | 39568023465 |
| WASM | 12329949348 | 39568023465 |
| Kotlin/JVM | 12329874535 | 39568023465 |
| Android | 12330248442 | 39568023465 |
| Non-production Linux harness | 12330852861 | 39568023464 |

Compared with 58fa1e9, the Apple wrapper, manifest, headers and all static
libraries are byte-identical. Only the xcframework plist's library order
changes; its entries are equal after sorting. WASM files, Kotlin native/wrapper
and JAR entries, and all three Android libraries are byte-identical. Android's
README changes revision references only. All three Android ELF ABIs expose
the strict generation reader and have four 16 KiB aligned LOAD segments each;
checked test/host exports are absent. The harness remains non-production,
Linux x86_64 fixed-flow tooling; its 23-event sample parses. No local Linux
harness execution is claimed.

An isolated staged Apple dependency passes all 19 production FFI checks,
including the 12 pinned raw verifyCommit examples. The checker installs and
re-verifies the exact package. The scheduled worker's SwiftPM attempt was
blocked before compilation by `sandbox-exec: sandbox_apply: Operation not permitted`.
The interactive follow-up installs the package in the real Astation worktree
and passes all 19 FFI checks, all 27 native adapter tests, and 111 selected
session/API/terminal tests after incorporating main's verification retry fix.
The full macOS application builds, and 35 identity/credential tests pass in a
provisioned Personal Team host, requiring real protected Keychain access.
These fresh results supersede the worker's blocked native run. No new iOS
runtime execution is claimed. ADB has no connected device and the SDK has no
emulator executable, so Android loading remains unrun.

Full live ceremony, protected native storage/signing, inbound/live routers,
durable push/provider ingress and platform/relay conformance still gate
admission. Keep the 2 MiB channel/262144-byte relay bounds and r9-only admission
with r8 operation semantics. Recovery/push/authentication choices remain settled.
No new product/security decision. No Atem checkout edit/build, live trust change,
merge or deployment.

Generated with SMT <smt@agora.build>
