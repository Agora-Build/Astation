# Channel envelope, project scope and package review at edeb8f0

Current integration update: Atem [requests starting now](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306876197)
with the accepted edeb8f0 packages. The host-only quarantine fix is reviewed
separately when pinned; it does not extend the earlier client-package wait.
Actual Git staging now succeeds, superseding the historical metadata limitation
below. The task branch adds an integrity-checked Apple artifact consumer and
encoded-byte relay acknowledgment batching. Full ceremony/client/router and
durable push ingress/platform conformance still gate admission.


## Current Task 9b delta

See the [ade944f review](remote-agent-api-task9b-review.md) for current
findings and artifact evidence; it supersedes earlier pending Task 9b requests
below. The new source finding concerns revocation quarantine durability across
rewrite/restart. Android/harness archives are now supplied and statically
verified; the final corrected/rebased artifact set and complete Astation
integration remain pending. Older package/FFI results below retain their
original pins and scope.


Reply to #81 comment 6297266850. Reviewed immutable PR #89 head `edeb8f0fab71d4573e41c4ca7935aab207200caf` against previously reviewed `13ef1e08c183503038dbe2e216c3ee5ce9b64778`. **The final Task 7 source/package handoff is ready for Astation integration.** This closes the earlier wait for a final reviewed pin and matching green packages; it does not sign off all of #89 or open remote admission. PR #80 remains merged at signed-off `c685abab92535b167f5f2658c814f0f72541d9a1`; fresh #80/#89 reviews and inline comments remain empty.

The entire delta has two paths: a test-only `failure_of` accessor and the requested [real-cred-agent regression](https://github.com/Agora-Build/Atem/blob/edeb8f0fab71d4573e41c4ca7935aab207200caf/src/memory/k_agent_tests.rs#L750). It learns current and retained project hashes while a third kid is unavailable, leaves that kid pending without suppressing the others, learns it after installation/retry, and retains all learned matches after a later lock. This addresses the remaining mixed-key/retry coverage request. No production behavior, contract, binding-source or shared-fixture bytes changed from 13ef1e0. The per-kid isolation/wrong-kid refusal review and the accepted restart/router/strict-generation obligations stand. Four changed old/new blobs and twelve selected unchanged old/new blobs were Git-hash verified, plus the pinned pairing vector.

Downloaded all three artifacts from [binding run 39465726081](https://github.com/Agora-Build/Atem/actions/runs/39465726081). The GitHub archive SHA-256 digests, all seven payload checksums and all three clean `SOURCE.json` pins match exactly edeb8f0, including versions/toolchains and production feature selections. The strict generation reader is present in eleven inspected generated Swift/Kotlin/JS/declaration files. Apple's xcframework contains macOS arm64/Intel, iOS arm64 and simulator arm64/Intel slices. The Kotlin package remains Linux/JVM x86-64; Android ABI libraries are still a separate Atem handoff.

**First native artifact-consumer check passes:** compiled the supplied generated Swift wrapper against the supplied macOS static library with the local Swift compiler and ran **19 checks through the production FFI**: all twelve pinned exact-JSON verifyCommit examples, five extra negative inputs, the minimum generation and canonical JSON. Invalid inputs return typed `AtemError.Invalid` codes; 3.0/3e0/duplicate keys are refused. No Atem Rust source or checkout was built/edited, and no account/trust operation ran. SwiftPM itself could not run its manifest sandbox in this worker (`sandbox_apply: Operation not permitted`); direct compilation checks the generated wrapper/static-library FFI, not successful SwiftPM integration or iOS execution.

Upstream [Test 39465726184](https://github.com/Agora-Build/Atem/actions/runs/39465726184) passes Linux/macOS arm64/Intel, [core 39465726022](https://github.com/Agora-Build/Atem/actions/runs/39465726022) passes Linux/macOS/Windows, and the binding run passes Swift/Apple packaging plus Kotlin/WASM end to end at this exact head. Automated review workflows were skipped. The local 19 checks are a narrow native binding check, not full runtime/relay/Mac-off/platform/provider conformance. Sealed push/seen, the real-runtime fixture handoff, Android ABI packages and complete Astation ceremony/key/storage/router integration remain.

Astation implementation limitation: this worker cannot write the external worktree Git metadata, so it cannot publish the required integration commit. The task branch/worktree remains clean at `3b319bb`; a refreshed three-file documentation patch, commit message and native consumer evidence are preserved under `/tmp/astation-review-edeb8f0`. No new commit/push is claimed. Direct memory read/save remains denied; the live shared vault works. No product/security question is pending. Admission stays disabled with no compatibility fallback. No live trust/recovery, merge or deployment change.



## Later Task 8 / Task 9a handoff

The [Task 8 review](remote-agent-api-task8-review.md) at 2f532b3 accepts
the 256 KiB relay-message/ACK bound, separate from R9.7a's 2 MiB channel
envelope. Its cancellation finding is closed in reviewed source by the
[Task 9a follow-up](remote-agent-api-task9a-review.md) at
`56c4489bde35e83460655f686e2eff8305b09010`. The runtime runner's 25
unexpressed items, final artifact/harness/Android handoff and Astation
platform/relay/provider conformance remain. Task 7 package evidence above
continues to pin edeb8f0, with no new final artifact claim.

## Earlier reviewed pins

The following records earlier evidence. Current readiness and finding status are superseded above.

## Historical review through 13ef1e0

Published review: https://github.com/Agora-Build/Atem/pull/80#issuecomment-6296544817
Technical handoff: https://github.com/Agora-Build/Atem/issues/81#issuecomment-6296546983

**Latest follow-up: `13ef1e08c183503038dbe2e216c3ee5ce9b64778` (advanced after the dce36f6 review below).** Compared all five changed paths against dce36f6 and verified all ten old/new blob hashes. The unavailable-kid issue is now addressed in source: one kid per hash job, separate failure/retry state, and a regression proving an unheld kid cannot block a held one. A wrong-kid answer is rejected; expired membership services no longer contribute warm-up kids; unread worker records retry at five-second intervals. New in-process real-cred-agent coverage checks both current and retained K hashes against memory sync/HMAC, and the Mac-off test explicitly rejects the old attachment generation as `stale_target`. No contract or shared-fixture bytes changed in this delta. Source/regression review only: the new head's Test workflow is running and core/binding workflows were queued when checked; the verified packages below still pin **dce36f6**, not this new head. Await final reviewed pin, green CI and matching packages before integrating. The review request's extra mixed-key/retry cases can strengthen coverage, but no new product question is pending. [Per-kid source/regressions](https://github.com/Agora-Build/Atem/blob/13ef1e08c183503038dbe2e216c3ee5ce9b64778/src/runtime/project_scope.rs), [real-agent test](https://github.com/Agora-Build/Atem/blob/13ef1e08c183503038dbe2e216c3ee5ce9b64778/src/memory/k_agent_tests.rs#L697).

The following records the reviewed dce36f6 bytes and artifact evidence; the project-kid finding there is superseded by this follow-up.


Reviewed immutable PR #89 head `dce36f6bf8523e545fb63c957cb24b601df35dec` against `66ea5564f990e7c4d34d84f69f0ac1076de45dfb`, following #81 comment 6296000112. PR #80 remains merged at signed-off `c685abab92535b167f5f2658c814f0f72541d9a1`; no new reviews or inline comments on #80/#89. The original implementation sign-off and settled recovery/push/authentication direction stand.

Acknowledgements after inspecting the actual changes:

1. **Restart bound accepted; prior medium finding closed.** `open` counts live channels plus pending lifecycle closes against 64; `restart` retains those slots until `flush_closes` sends them. Refusals retain their separate 1,024 ceiling. The new repeated-restart test asserts at most 1,088 queued closes and a fixed byte ceiling, eventual ordering and released slots. New-generation closes are flushed/dropped before the new generation rather than carried into it. [Source](https://github.com/Agora-Build/Atem/blob/dce36f6bf8523e545fb63c957cb24b601df35dec/src/session_protocol/r9/mod.rs#L474), [regression](https://github.com/Agora-Build/Atem/blob/dce36f6bf8523e545fb63c957cb24b601df35dec/src/session_protocol/r9/tests.rs#L1373).
2. **Router responsibility accepted.** Both Astation relay and :8080 adapters must enforce the 2,097,152-byte serialized envelope bound before forwarding, including the generated wrapper and reassembled/fragmented input; overflow ends only that client's virtual channel (`too_large`). Atem's 4 MiB WebSocket cap is a whole-link safeguard, not the router limit. This is an implementation obligation: today's gated Astation routes do not yet enforce an r9 dispatcher. Maximum legal `rec`/`finish`, one-byte overflow, fragmentation and another channel remaining live belong in adapter tests before admission.
3. **Project-scope requirement acknowledged as existing R9.6.** Fail closed while the required per-kid launch-project hash cannot be computed (encryption off, unavailable retained K, or agent locked before first successful comparison). The pinned text says “until the first unlock”; `ProjectScopes` intentionally retains known hashes across a later lock. I am not agreeing to a new policy that locking revokes already-known project matches. Pre-build sessions without a recorded launch project remain outside project scopes until relaunched. Astation must re-issue service scopes before retiring their K generation.

**Final project-kid review remains necessary.** At this pin all missing `(session,kid)` hashes share one job. One unavailable kid makes `AccountKeys::crypt` return an error for its whole request; `hash_with` propagates it, and `ProjectScopes::spawn` commits no results from the job. Since the job includes kids from all membership services, a service scoped to an unavailable/retired kid can keep an unrelated service's valid current-kid comparison pending after startup. Please isolate failures by kid (with bounded batches) and include a regression where one unavailable kid coexists with valid current and retained kids, plus retry after the missing key becomes available. This corroborates the project-kid review you already flagged; no product decision is needed. [Hash request](https://github.com/Agora-Build/Atem/blob/dce36f6bf8523e545fb63c957cb24b601df35dec/src/runtime/project_scope.rs#L72), [aggregate job](https://github.com/Agora-Build/Atem/blob/dce36f6bf8523e545fb63c957cb24b601df35dec/src/runtime/project_scope.rs#L271).

The prior passive-status finding is also closed: leftover carriage/intent reports replay at next start; a recorded fault reports held/manager reconciliation. `lease_held.controller` now survives shared-client decoding for an explicitly confirmed takeover. The eleven fixture diffs align with the existing contract: top-level approval IDs, `forbidden` before a terminal effect, zero dropped writes for that refused request, `takeover`, and r8 receipt visibility. These amendments do not change product policy.

**Built packages verified, integration waits for your final pin.** Downloaded all three artifacts from [binding run 39457379385](https://github.com/Agora-Build/Atem/actions/runs/39457379385). All GitHub archive SHA-256 digests and all seven payload checksums match; all three SOURCE.json files name exactly this clean head, versions/toolchains and production feature selections. Inspected 12 generated binding source/declaration files: the strict generation reader is present and the checked test/host-only exports absent. Android ABI libraries are still not supplied by the Linux JVM artifact; Atem owns their builds too. No downloaded code was executed, and no Atem source was built.

Validation: 93 selected old/new Git blobs hash-verified across 47 changed paths and relevant unchanged fixtures; 13 selected fixture JSON files parse. Inspected the changed contract, all eleven fixture diffs, lifecycle/status/client/project paths and selected regressions. Upstream [Test](https://github.com/Agora-Build/Atem/actions/runs/39457379386) (Linux/macOS arm64/Intel), [core](https://github.com/Agora-Build/Atem/actions/runs/39457379634) and bindings succeed at this head; automated reviews were skipped. This is static/example/package-integrity review plus upstream CI evidence, not local runtime/FFI/platform conformance or overall PR #89 sign-off. The real-runtime tests use fake agents/router; actual Astation relay/Mac-off/platform/provider tests remain.

Admission stays disabled; no r8 compatibility fallback. Wait for the reviewed final pin and matching built packages before Astation integration. No new user question, live trust/recovery change, merge or deployment.


## Review history

The following findings and artifact limitations describe earlier pins. Their current status is superseded above.

## Historical review at 66ea556

Reviewed immutable Atem PR #89 head `66ea5564f990e7c4d34d84f69f0ac1076de45dfb` against `8aab768981347d56143bf976f07c1fc64b76d089`, following #81 comment 6291819357. PR #80 remains merged at signed-off `c685abab92535b167f5f2658c814f0f72541d9a1`; its previous r4 findings remain closed. This reviews the new contract/fixtures and selected implementation paths, not all of #89.

**The new R9.2 ceremony wire is agreed for implementation at this pin.** The existing `type/data` wrapper carries required `data.host_trust_gen`, a JSON integer in 1..2^53−1. The field is captured with the commitment, unchanged in the signed `add_host`, and the attempt is void after reconnect or re-pair. The pinned strict shared reader is exported to Swift/Kotlin/WASM; Astation will pass the original JSON bytes to it before a platform decoder can erase the distinction between `3`, `3.0` and `3e0`. Atem's host ID/key/generation checks remain required. No compatibility fallback. The twelve exact `verifyCommit` cases now exist; host-generation mismatch and attempt-invalidation cases are specified too. Upstream tests exercise the reader through all three bindings and a mismatching `add_host` refusal.

**The envelope correction is present.** The unchecked over-limit record now expects `too_large`. Largest compact `rec`/`finish` sizes are distinguished, and the 2 MiB outer bound accommodates the 1,398,279-byte maximum record envelope. The ordinary busy/unknown refusal paths now share a host-clock 16/s limit and 1,024-item queue; unknown handles stop at 1,024 without eviction. New stalled-output, 1,025th-handle/replay, shared-clock and fair-service regressions address the prior findings in those paths. Those original findings are closed for the paths tested; the new restart path below needs a separate bound.

Two remaining findings from the changed source:

1. **Medium: repeated live-socket restarts bypass the aggregate close bound.** [`R9Host::restart`, lines 520–528](https://github.com/Agora-Build/Atem/blob/66ea5564f990e7c4d34d84f69f0ac1076de45dfb/src/session_protocol/r9/mod.rs#L520) takes the pending `global` queue, appends every live handle's close without a cap/rate check, then restores it after `link_down`. `link_up` permits fresh opens while those closes are still blocked. With output stalled, fill the refusal queue, open 16 fresh handles, restart/link_up, and repeat with fresh handles: the queue grows by 16 per restart (1,024 → 1,040 → 1,056 → …). A single restart's ≤64 exception therefore supplies no aggregate bound across restarts. The new restart test covers one restart only. Please bound pending lifecycle closes across repeated restarts and define backpressure that preserves channel termination (for example, defer new opens until lifecycle-close capacity is available). Extend the stalled-output test across repeated restart/open cycles and assert a fixed item/byte ceiling and eventual close ordering. This is a static source trace, not a locally executed Atem test; I am not claiming an unauthenticated peer can trigger a re-pin.
2. **Low: passive status reports manager-required held after an ordinary crash.** [`passive_status`, lines 1965–1971](https://github.com/Agora-Build/Atem/blob/66ea5564f990e7c4d34d84f69f0ac1076de45dfb/src/session_protocol/membership/mod.rs#L1965) treats any carriage/intent file as `held` and says remote access waits for a managing device. A readable carriage or satisfied intent after a plain crash can replay and resume without a manager under settled R9.3. While the runtime is stopped, report replay/check pending until startup determines whether carriage is unreconcilable; reserve the manager requirement for a recorded fault or confirmed hold. This is a status wording/state issue; no changed recovery policy is requested.

**r8 lease clarification accepted:** replacement ends the old attachment's lease at once; a dropped transport stops renewal and leaves the old lease to expire after its existing deadline. Neither transfers a lease to a new attachment. This agrees with §5 and Astation's existing reconnect plan; the corrected link-loss fixture reference is consistent.

Validation: 67 selected old/new Git blobs hash-verified, including the changed wire/fixture/binding bytes and relevant source/tests; six selected fixture JSON files parse. **44 independent Python assertions pass** for the exact generation cases plus additional negative forms and envelope sizes/handle/reason bounds. These check examples against the contract; they do not execute Atem code, FFI or runtime scenarios. Upstream [Test](https://github.com/Agora-Build/Atem/actions/runs/39427279462), [atem-core](https://github.com/Agora-Build/Atem/actions/runs/39427279436) and [bindings](https://github.com/Agora-Build/Atem/actions/runs/39427279624) pass at this exact head; both automated review workflows are skipped. Binding artifact inventory remains **zero**. Built production SwiftPM/xcframework/WASM packages with digests/source pin, remaining runtime/multi-device/sealed-push work and Astation platform conformance still gate integration/admission. No overall implementation sign-off is given.

No new product/security decision is pending. Prior policy decisions and the original c685aba implementation sign-off stand.

## Historical initial review at 2d92631

The following records the earlier pin. Outstanding items here are superseded by the current follow-up above and the [8aab768 review](https://github.com/Agora-Build/Atem/pull/80#issuecomment-6290113944).


Reviewed 2026-10-20 in response to
[Atem #81 comment 6287830722](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6287830722).
The routing field names fit Astation's planned route family. This review
requests pinned transport text and fixtures before joint wire sign-off;
it does not approve the unfinished implementation or enable admission.

## Sources and current implementation

- Previously signed contract:
  [c685abab92535b167f5f2658c814f0f72541d9a1](https://github.com/Agora-Build/Atem/blob/c685abab92535b167f5f2658c814f0f72541d9a1/designs/protocol/atem-session-v1.md#r97-channel-atem-ch1),
  R9.7. PR #80 is merged at that unchanged head; fresh issue comments,
  reviews and inline comments contain no later contract pin.
- Discovered draft implementation:
  [Atem PR #89](https://github.com/Agora-Build/Atem/pull/89), inspected at
  `2d926313388b24dd3dc4a9bdb095a25b9989df34`.
  The contract Markdown and channel vectors are unchanged from c685aba.
  The proposed routing envelope is still only in the coordination comment.
- Astation's [remote_api.rs](../../relay-server/src/remote_api.rs) implements
  capabilities and a 503 fallback. There is no implemented
  `channels/{id}/frames` schema to conflict with these names.
- The existing relay identifies an Atem socket by `atem_id` and
  `connection_id`. The native direct listener decodes `AstationMessage`.
  Neither currently implements the proposed r9 channel dispatcher.

Atem reports the user's outbound-only direction: Atem connects to the relay
or Astation's existing :8080 listener; it opens no new listener. The relay
path remains usable without Mac Astation. Direct access uses the Mac while
it is available. This is routing of encrypted endpoint channels, independent
of the Mac's local agent-control API.

## Concrete response to the proposal

Keep the proposed top-level shapes:

```json
{"type":"channel","event":"open","channel":"opaque-id","transport":"relay"}
{"type":"channel","event":"frame","channel":"opaque-id","frame":{"ch":"atem-ch1","op":"rec","ct":"..."}}
{"type":"channel","event":"close","channel":"opaque-id","reason":"busy"}
```

`transport` is `relay` or `direct`, set by the routing adapter. No client IP,
claimed device identity, roles or other metadata is needed on `open`.
Routing hints never supply membership, host identity or authorization.
The signed handshake fields remain visible as specified in R9.7; application
records and the client's hello remain encrypted.

Pin these lifecycle details with the envelope and shared transport fixtures:

1. Scope lookup to the selected live Atem link and its local connection
   generation as well as `channel`. Validate the proposed 1-64 ASCII
   `[A-Za-z0-9_-]` characters. The routing handle differs from the
   cryptographic `channel_id = hex(th4[0..16])`; neither substitutes for the
   other. A stale HTTP handle or delayed callback cannot bind to a new link.
2. Queue `open` before the first frame; deliver each direction in order.
   A duplicate `open` cannot replace a live handshake, keys or attachment.
   Close releases that channel only. Repeated or unknown `close` is terminal
   and produces no answering close loop. An unknown frame may get the
   proposed bounded `unknown_channel` response; keep its bookkeeping bounded.
3. A link drop closes every channel on that link and fences their attachments.
   Reconnect starts fresh channels/handshakes and authoritative catch-up,
   without restoring leases or replaying prompts. Reordering, replay or bad
   AEAD tags close only the affected channel through the shared core.
4. Keep the one-init-per-second limit scoped to the live Atem link, with
   bounded open channels, pending handshakes and queued bytes. Overflow
   closes/refuses a channel explicitly; it cannot silently drop records or
   leave an unbounded queue. Limits and busy behavior need executable cases.
5. Demultiplex channel traffic before legacy native message dispatch or room
   broadcast. The Mac's own client uses the same r9 path; routing possession
   and a legacy paired link cannot bypass r9 admission once membership exists.
   In the binding adapter, use one `ClientConnection` per virtual channel;
   its instruction to close the transport closes that channel, not the shared
   outbound link and every other client's attachment.

## Size correction before pinning

The proposal's 1 MiB frame statement conflates plaintext and transport bytes.
R9.7 permits **1,048,576 bytes of plaintext** per record. Its 16-byte AEAD tag
and unpadded base64url produce **1,398,123 ciphertext characters**. Compact
JSON for `ch/op/ct` is 1,398,159 bytes; the proposed envelope with a 64-byte
channel handle is **1,398,279 bytes**. A 1 MiB outer limit rejects a legal
record.

Preserve the plaintext limit and separately bound the serialized inner frame,
outer envelope and queued bytes. A 2 MiB outer limit would accommodate the
current compact shape; it is a proposal for the next joint pin, not a shipped
limit. Document whether noncompact JSON is accepted within that outer cap.
Test the maximum legal record through actual relay and native adapters,
one-byte-over-limit plaintext and outer frames, and saturated queues. The
handshake/finish bounds must also be explicit; do not silently truncate
membership carriage to fit a transport limit.

## New fixture bytes inspected

Compared immutable Git trees rather than a merge-base diff: PR #80 was
squash-merged, so a history comparison incorrectly lists unchanged fixtures
as new. Verified all 18 old/new Git blob hashes for the nine changed files.
The changes align examples with the already settled contract:

- Five acquire messages add explicit `takeover:false`, retaining r8 behavior.
- Recovery-add now refuses `recovery_pending` before the existing 24-hour
  host-clock wait, then admits the new manager without another entry.
- The seen-retry scenario acknowledges initial open hints, isolating the
  intended seen retry from concurrent unacknowledged hint retries.
- Key-vector changes add explanatory notes only.
- Four negative push hints gain the existing sealed bytes so their named
  failure is reached; annotation fields move outside the strict seen object.
  Signed bodies, signatures and existing ciphertext bytes are unchanged.

No new product choice is introduced by these fixture corrections. This static
review does not run the scenarios or approve the rest of PR #89's code.
The previous 274 Python / 41 CryptoKit results apply to c685aba; they are
not presented as a fresh run against the implementation.

## Binding artifact handoff

Read the pinned
[binding/effect contract](https://github.com/Agora-Build/Atem/blob/2d926313388b24dd3dc4a9bdb095a25b9989df34/designs/protocol/atem-client-bindings.md),
Apple packaging script and CI workflow. They describe UniFFI Swift/Kotlin,
WASM, protected platform key callbacks, deferred signing and durable prepared
state. The
[binding CI run](https://github.com/Agora-Build/Atem/actions/runs/39399202806)
succeeded at exactly `2d926313388b24dd3dc4a9bdb095a25b9989df34`, including
Swift/Apple packaging and Linux Rust/Kotlin/WASM/end-to-end jobs. This is
upstream CI evidence, not local platform or real-runtime conformance.

That run exposes **zero downloadable artifacts**; the workflow performs a
package dry run without uploading it. Atem should provide its built SwiftPM
package/xcframework and WASM package with SHA-256 digests, the source pin and
production feature selection (without test/software-key/host features).
Astation consumes those artifacts; it does not build an Atem checkout.
Pin the envelope, bounds and executable multiplexing fixtures alongside them.
Then Astation can integrate its platform key/storage/network adapters and
relay using the shared core, retaining the runtime/platform admission gates.

Validation in this review: verified document/vector/fixture blob hashes,
inspected all nine fixture diffs and binding/packaging bytes, checked the
immutable CI head and empty artifact inventory, and reproduced the transport
size calculation locally. No Atem code was edited or built; no live trust,
account recovery, merge or deployment changed.
