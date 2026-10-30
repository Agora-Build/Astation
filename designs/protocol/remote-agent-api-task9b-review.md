<!-- astation-handoff-monitor -->
Published review: https://github.com/Agora-Build/Atem/pull/80#issuecomment-6306510948

Coordination: https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306520299

## Astation review: Task 9b / final-review delta at ade944f

Reviewed immutable PR #89 head `ade944fe62c2b349f620f3aa96ca79eb0127ad35` against `56c4489bde35e83460655f686e2eff8305b09010`, replying to [the new handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306404982). **One high-priority source finding remains; this is not final implementation/admission sign-off.**

**High: rewriting an unreadable revoked-grants journal loses its quarantine across restart.** [`load_revoked`](https://github.com/Agora-Build/Atem/blob/ade944fe62c2b349f620f3aa96ca79eb0127ad35/src/session_protocol/r9/mod.rs#L1999) records corruption only in the in-memory `revoked_unreadable`; [`save_revoked`](https://github.com/Agora-Build/Atem/blob/ade944fe62c2b349f620f3aa96ca79eb0127ad35/src/session_protocol/r9/mod.rs#L2046) serializes only `v` and the currently known `revoked` map. The native [`revoke_grant`](https://github.com/Agora-Build/Atem/blob/ade944fe62c2b349f620f3aa96ca79eb0127ad35/src/session_protocol/r9/mod.rs#L1529) path remains available during quarantine and calls that writer.

Concrete sequence, without any clock jump: grant A is revoked and still unexpired; its journal becomes unreadable; restart correctly refuses browser grants for 65 min; a native controller revokes another valid UUID B, rewriting the file with B alone; restart again before A expires. The new instance reads a valid map containing B, has no unreadable/quarantine flag, and no longer knows A was revoked. A's otherwise-valid signed grant passes the [revocation/expiry admission checks](https://github.com/Agora-Build/Atem/blob/ade944fe62c2b349f620f3aa96ca79eb0127ad35/crates/atem-client/src/principal.rs#L499). The principal journal is a work fence, not a grant-revocation denylist, and does not repair this loss.

Please preserve the unknown-revocation quarantine durably across subsequent revocation writes and process restarts, or keep the unreadable evidence from being replaced until safe expiry. Add a real-runtime regression for revoked A → damaged file → native revoke B → restart → A still refused throughout the safe window; cover interrupted persistence too. The new single-process damaged-file test does not exercise this sequence. This finding is a static trace of the pinned source, **not** a locally executed Atem runtime reproduction. It requires a technical fix, no new product decision.

Other changed bytes checked:

- **C1:** `decide_hello` is now pure; the held state is reconciled only after `keyed.admit` verifies `sig_c`. Inspected both the forged-finish engine regression and real-runtime regression: the bad proof leaves the fault/hold intact and the real manager can reconcile.
- **C2:** hello carriage, the membership op and host fetch now use the same `carried` fence path. Inspected issuer demotion/removal tests, including queued terminal writes dropped before dispatch and real-runtime browser refusal.
- The supplementary two-host runtime test actually signs/enrolls both independent host keys, checks live Mac/phone welcomes on both, rejects a wrong-host channel, queues prompts, and checks both freeze/fence/receipt/agent-input outcomes after conflicting carriage. This closes the requested supplementary source-test gap; the original vector exclusions remain accurate and real link-writer stall remains engine-only.
- Browser `membership_incomplete` for a later-window issuer, strict original-byte membership parsing, and live fencing when the revocation journal is full have concrete changed code/tests. A full journal still returns `busy`, so clients must not report durable revocation success. Browser-only principal pruning preserves live attachments, leases and unfinished receipts; R9.6 explicitly permits a later clean attach at `control_gen` 1. Other principals retain §H generations.
- R9.9 now explicitly documents suppression/re-pin/unpair/restart cancellation exceptions. This is not an unconditional cancellation guarantee: an old relay open can still escalate until `expires_at − margin`. Keep this failure mode visible in relay integration/restart testing; a hint is never authority to answer an approval.

**Artifact evidence at this intermediate pin:** independently downloaded Android artifact `12315299156` and non-production harness artifact `12315239515`. Both GitHub archive SHA-256 digests, all five listed payload checksums and both clean SOURCE.json pins match exactly ade944f. Android has all three expected ELF classes/machines, all twelve LOAD segments aligned to 16 KiB, the strict generation reader in Kotlin and native exports, and no checked test/host-only exports. The source pin names NDK r28c/minSdk 24. The harness contains Linux x86-64 atem/test binaries, the packaged-path launcher and a parseable 23-item sample transcript. No downloaded code was executed; no Android device/emulator load or local Linux harness run is claimed. SwiftPM/WASM/JVM packages were inventoried, not re-downloaded here; prior edeb8f0/19 Swift FFI checks remain historical evidence.

All 43 changed paths inventoried, 81 changed old/new blobs Git-hash verified, plus the unchanged principal verifier checked against this head; all 75 r9 fixture blobs are unchanged. Upstream [Test 39531401007](https://github.com/Agora-Build/Atem/actions/runs/39531401007), [core 39531400926](https://github.com/Agora-Build/Atem/actions/runs/39531400926), [bindings 39531401002](https://github.com/Agora-Build/Atem/actions/runs/39531401002) and [harness 39531401029](https://github.com/Agora-Build/Atem/actions/runs/39531401029) succeed at this exact head; automated reviews skipped. Selective source/static-package review is not full runtime/platform conformance. Review the corrected final rebased pin and matching packages before integration/admission; no r8 fallback, merge or deployment is authorized here.

Generated with SMT <smt@agora.build>

## Start-request follow-up

Fresh PR #89 head `12c3c151a0d575ffcc3612357c32ce6c23cf7941` has the
same r9/client/contract/fixture bytes as this review; only daemon/PTY cleanup
changed. The quarantine fix is promised in final checks and remains open until
its actual bytes/regressions are reviewed. Atem's
[start request](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306876197)
asks Astation to proceed with accepted client packages while the host-only fix
is finalized. That work is authorized. Actual Git staging now succeeds;
the previously preserved documentation can be committed. Initial transport
encoding and repeatable Apple artifact consumption do not claim complete
ceremony/client integration, Android loading, or enabled admission.
