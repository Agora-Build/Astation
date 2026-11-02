# Task 8 sealed push and seen review at 2f532b3

Current status: the cancellation finding below is closed in reviewed source at
`56c4489bde35e83460655f686e2eff8305b09010`; see the
[Task 9a follow-up](remote-agent-api-task9a-review.md). This document preserves
the earlier finding and evidence at 2f532b3.


Reply to #81 comment 6301600191. Reviewed immutable PR #89 head `2f532b37a5b14be4f3aad73547041015f40c4496` against accepted Task 7 pin `edeb8f0fab71d4573e41c4ca7935aab207200caf`. **The two R9.9 clarifications are accepted for implementation; Task 8 still has the cancellation finding below.** Original c685aba sign-off and settled product/security choices stand. This is not overall implementation/admission sign-off.

**Medium — the 65th tracked approval can lose an earlier approval's cancellation.** In [HostPush::opened](https://github.com/Agora-Build/Atem/blob/2f532b37a5b14be4f3aad73547041015f40c4496/src/session_protocol/r9/push.rs#L178), reaching 64 tracked approvals calls `forget(old)` regardless of whether that approval is still pending or its resolved hint remains unacknowledged. [forget](https://github.com/Agora-Build/Atem/blob/2f532b37a5b14be4f3aad73547041015f40c4496/src/session_protocol/r9/push.rs#L550) removes its state/outbox entries, and a later [resolved](https://github.com/Agora-Build/Atem/blob/2f532b37a5b14be4f3aad73547041015f40c4496/src/session_protocol/r9/push.rs#L218) returns without signing anything for that approval.

Concrete sequence: deliver and acknowledge approval A's open, keep A pending, open another 64 approvals, then answer A before its mobile deadline. The relay already has A's open, but will receive no resolved hint and can still send its 60-second escalation after the answer. Five sessions with 16/16/16/16/1 pending approvals fit the session host's existing [16-per-session limit](https://github.com/Agora-Build/Atem/blob/2f532b37a5b14be4f3aad73547041015f40c4496/src/session_protocol/host.rs#L3299); it is not a global 64 bound. Evicting an unacknowledged resolved similarly loses cancellation retry. The new capacity test expressly checks eviction, but does not check the old approval's later cancellation.

Please preserve reliable lifecycle/cancellation for already published approvals when bounding storage. Add coverage using the real session host across enough sessions: A's open acknowledged, capacity crossed, A answered, its resolved delivered and retried unchanged until acknowledged; also cover capacity pressure while a resolved acknowledgment is lost. This is a static source trace, not a locally executed Atem regression. It concerns notification delivery; the host's authoritative approval still closes.

Acknowledgements for Astation:

- **256 KiB relay messages:** accept the exact 262,144-byte serialized bound in both directions, including the wrapper. Astation must split `push_ack` by actual encoded byte size, preserve complete identities and acknowledge only after durable handling. It cannot use an approximate fixed identity count. A public-vector example is 339 bytes per identity: 770 copies produce a 261,841-byte wrapper, 771 produce 262,181 bytes. This is an independent sizing example, not a production splitter test. The separate 2 MiB virtual-channel envelope bound remains required.
- **Seen recipients:** accept signing only for the original open-hint recipients, subject to current control and exact pending session/process checks. Later-added devices, services and browser grants can receive the protocol reply without generating a relay seen. The native adapter still requires a rendered card, foreground focus and recent active use; background receipt never counts.

The changed host code uses the shared signed/sealed formats, original creation/expiry, identical-byte retries, partial acks, reconnect delivery and recipient removal/demotion. Inspected its new engine tests and Linux real-runtime/fake-router/fake-Claude tests, including the 700-second wall-clock jump with stationary monotonic time. These are valuable upstream tests, not actual Astation relay, mobile, biometric or APNs/FCM verification.

Validation: all 18 changed paths inventoried; 63 selected old/new Git blobs hash-verified; 12 selected fixture JSON files parse. No shared fixture/vector or binding/core source bytes changed in this delta. Fresh #80/#89 comments/reviews/inline were checked; #80 remains merged at c685aba. Upstream core run 39498375797 and bindings run 39498375961 succeed at this exact head; Test run 39498375827 is still in progress at review time. Automated reviews skipped. No new full scenario/runtime conformance or newly downloaded package verification is claimed. The previously verified edeb8f0 packages and 19 local production Swift FFI checks remain historical Task 7 evidence; Task 9/final artifact and Android ABI handoffs remain pending.

Astation's relay ingress, durable outbox/providers and native adapters remain unfinished and admission stays disabled, with no compatibility fallback. External worktree Git metadata remains outside this worker's writable roots; the review/documentation update is preserved under `/tmp/astation-review-task8`, with no new commit/push. Memory search is denied; live vault reads return the shared notes but warn of a credential-agent build mismatch. No lock/unlock, re-pairing or security bypass was attempted. No new user decision, live trust change, merge or deploy.

Generated with SMT <smt@agora.build>
