# Astation and Atem coordination

## Current implementation, 2026-10-21

Atem #93 supplies the supported durable MembershipLog API at
`1493ca6a5d704484bff7b30b09222cf20658fdcd`, accepted after memory/vault e66,
source review, completed CI logs and immutable package/hash verification.
The Apple package is consumed in #58; the relay retains its accepted eaaadc2
Cargo pin because signed wire/fixtures are unchanged. No Atem checkout is built.
See [the upstream delivery](https://github.com/Agora-Build/Atem/issues/93#issuecomment-6328508674)
and [review](https://github.com/Agora-Build/Atem/pull/80#issuecomment-6328353597).

The app's v2 ceremony, mandatory kit, protected signing, relay CAS and K backup
are implemented. Protected coordinator/publication/backup/restore checkpoints
now include the shared durable snapshot with independent account/genesis anchors.
Load commits immediately; changes/clock advances commit before effects; failed
commits stop account operations. Exact writer state remains separately retained.
An OS boot-session identifier, 30-second timer and background/sleep checkpoints
preserve same-boot wait progress without trusting the relay or wall clock.
Recovery still refetches and requires a fresh host-signed proof after restart.

Local validation: 982 app tests (14 environment-dependent skips), 94 native
tests and two provisioned recovery signing/storage tests pass. #63's earlier
23659d9 CI is fully green: 977 app, 87 native, 487 relay, plus all 49 Postgres
and 64 Valkey cases executed separately. The canonical provisioned app still
runs 23659d9 until explicitly rebuilt; no new live ceremony pass is claimed.

The user deferred unavailable auth.agora.build so r9 implementation and isolated
tests continue. #63's account-login implementation stays intact; production
registration/configuration/deployment and its live validation remain open.
The storage-authentication alternative requires the user's choice; Auth
unavailability grants no storage access. No legacy AGORA_ACCOUNT_* configuration.

Independent native/relay routers, durable sealed push/provider integration,
mobile/service conformance and the complete live ceremony remain #58 work.
Atem #89 remains unmerged and independent admission remains disabled. Main merges
and production deployment require user approval. Existing paired-host r8 remains
operational; no keys, trust floors, pairings or credential agents were reset.

## Historical corrected pin, 2026-10-21

Atem's [final handoff](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6311804983)
names `eaaadc23477d12f1e2a0caa56ccafb1dd45be571` and its five replacement
artifacts. The [review](../designs/protocol/remote-agent-api-eaaadc2-review.md)
accepts them for integration: host corruption/rollback findings are closed,
all three Test targets pass, and downloaded Linux logs execute 1,826 release
unit tests plus 63 debug-hook tests (zero debug failures/ignores). All five
archives/12 payloads verify. The interactive Apple consumer passes 19 FFI checks,
all 27 native adapter tests pass, and 111 selected session/API/terminal tests pass
after merging main's verification retry fix. The macOS app builds, and 37
identity/credential tests pass in the provisioned Personal Team test host,
including real protected Keychain storage. The dependency pin is updated
without enabling admission. Full ceremony/storage/signing, inbound/live routers,
durable push/provider and platform/relay conformance remain. No new user
product/security question. This supersedes the historical host/dependency/CI
status below. The scheduled worker prepared the dependency update outside its
worktree because shared Git metadata is not writable; an interactive session
applies and publishes it on the existing task branch.

Session welcome failures now identify the failed validation check, a regressed
host trust generation, or a journal storage failure. Logs contain fixed check
names and bounded counters, retaining session-payload redaction. The live Genie
5-to-3 regression belongs to [Atem #91](https://github.com/Agora-Build/Atem/issues/91);
the client's trust and runtime floors remain intact.

## Historical integration status, 2026-10-20

The [final-pin review](../designs/protocol/remote-agent-api-final-pin-review.md)
checks host/package pin `58fa1e92bb99fed1ce81a42fb63ac1226782705b`.
The original quarantine rewrite/restart finding is fixed; a second damaged
record after clock rollback can lose the earlier end and readmit a revoked
grant, so host approval remains withheld pending a technical correction.
All five final artifacts verify. Astation's Apple dependency now uses that
pin; client/fixture bytes are unchanged from ade944f. Actual app ceremony,
storage/signing/router/push wiring and conformance still gate admission.
No new user product/security question is pending. This supersedes the older
final-pin-wait and dependency status below. The scheduled worker could not
publish this follow-up because its sandbox omitted the shared worktree Git
metadata; [the failure and preserved patch](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6307616918)
are recorded. The interactive session publishes the tested changes from the
existing worktree; do not reapply the saved patch.

The interactive session has now published that follow-up as f9d6ac5 and
notified Atem in [#81](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6307930915).
The native outbound channel writer adds serialized envelope bounds,
generation fencing and bounded close/backpressure handling; 27 native tests
pass. Actual inbound/live socket routing remains unwired. Final-package CI
fails an existing verification UI timing assertion tracked separately in
[Astation #62](https://github.com/Agora-Build/Astation/issues/62); relay/webapp
pass. The same 32-test verification UI suite passes locally. Do not confuse
this with the earlier local caption scroll failure in #61 or report the current
full app CI as green.

Astation is starting the accepted client integration following
[Atem's request](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306876197).
The previously preserved reviews are now on the published task
branch. The first implementation prepares encoded-byte `push_ack` batches and
a repeatable check of the pinned prebuilt Apple package. Neither enables r9
admission, durable push ingress or the complete ceremony/client adapters.

The [Task 9b review](../designs/protocol/remote-agent-api-task9b-review.md)
records actual two-host source/regressions and statically verified
Android/harness packages. Fresh PR #89 head
`12c3c151a0d575ffcc3612357c32ce6c23cf7941` changes only daemon/PTY cleanup
from reviewed ade944f. The revocation-quarantine finding remains open at that
head. Atem reports a fix in final checks; review its actual final bytes and
matching artifacts when posted. This host correction does not block starting
with the accepted Task 7 client packages. No product/security choice is pending.

Working rule confirmed 2026-10-19 in
[Atem #81](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276913191).

- Read Atem memory and handoff vault `v-8ut37j7X` first (user preference,
  2026-10-19), then check linked GitHub activity. Record concise durable facts
  in memory and detailed progress/questions in the vault. Keep secrets out.
- Use [#81](https://github.com/Agora-Build/Atem/issues/81) for linked handoffs,
  answers, status and technical questions. The user need not carry messages.
- Use [Atem PR #80](https://github.com/Agora-Build/Atem/pull/80) for remote-API
  and r9 documents, shared formats/fixtures and their reviews.
- Give a new topic its own issue or PR and link it from #81.
- Bring new product/security choices to the user before posting a decision.
  Technical implementation questions and existing approved choices can be
  handled directly on GitHub. Do not invent an answer while waiting.
- Atem owns Atem source and the shared atem-client core. Astation owns its
  native/platform integration and relay. Do not edit/build an Atem checkout.

## Current decisions and implementation gate

The [policy reply](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6276488130)
confirms the immediate-desktop/60-second-mobile push policy with active-user
seen suppression, Recovery Kit restoration of K plus replacement-manager
enrollment into existing trust, five-minute routine authentication reuse and
fresh owner confirmation for enrollment/removal/recovery. It also confirms
v0.7.2 keeps the device ID. These answers are settled; do not ask the user
to repeat them. See [the aligned Astation plan](../designs/protocol/remote-agent-api.md).

PR #80's r9 contract is signed off for implementation at
`c685abab92535b167f5f2658c814f0f72541d9a1`; the
[r5 review](../designs/protocol/remote-agent-api-atem-r5-review.md) closes the
previous r4 findings. It supplies 69 fixtures; primitive checks pass 274 Python
and 41 CryptoKit assertions, with 148 symbolic references resolved. The 62
scenarios were NOT RUN at that sign-off; runtime security gates still apply.
Atem owns shared-core/host implementation and bindings; the current artifact
and integration handoff is below.

The 2026-10-20 [channel envelope review](../designs/protocol/remote-agent-api-channel-envelope-review.md)
now reviews final Task 7 pin `edeb8f0fab71d4573e41c4ca7935aab207200caf`.
The prior restart/status and per-kid project-scope findings are closed; the
requested mixed-current/retained/unavailable-key retry/lock regression is
present and upstream CI is green. Contract/fixtures/binding sources are
unchanged from reviewed 13ef1e0. Both Astation routers must enforce the
2 MiB serialized envelope bound before forwarding, isolating overflow to one
virtual channel. The strict original-JSON generation reader remains required.
All three packages from binding run 39465726081 verify against exactly
edeb8f0; 19 local Swift/static-library FFI checks pass. The final-pin/package
wait is closed. Android ABI packages have since passed static inspection in Task 9b; actual
device/emulator loading remains. Full Astation ceremony/adapters and
runtime/platform/provider conformance still gate admission. The narrow FFI
check does not establish SwiftPM/application or iOS execution.


The [Task 9a review](../designs/protocol/remote-agent-api-task9a-review.md)
checks PR #89 at `56c4489bde35e83460655f686e2eff8305b09010` and closes
the Task 8 cancellation finding in reviewed source. Accept retention of
published pending/unacknowledged resolved lifecycles, dropping a new hint when
capacity is full. Native channel lifetime is monotonic; service/browser expiry
and recovery's dual-clock wait remain separate. The r9 outbound link keeps
its independent channels past the unused r8 link-attachment deadline; r8
authorization is unchanged. All 75 fixture files are unchanged. The reported
48/48 runtime scenarios include 25 unexpressed items. Task 9b subsequently
supplies the supplementary two-host source test and built Android/harness
packages, as reviewed above; the original vector exclusions and engine-only
link-writer stall remain. Final corrected packages, an external adapter entry
point and Astation platform/relay/provider conformance remain. The
[adapter requirements](../designs/protocol/remote-agent-api-harness-adapter.md)
propose replaceable host/client routing I/O for a subsequent artifact; Astation's
actual public client ingress remains unimplemented. No new product/security
question is pending.

Recovery choices are settled: 24-hour host-clock wait with approve/veto,
replaceable kits, and no recovery publication without a reachable trusted
host-signed head. The kit now carries a genesis anchor/tag; older kits need
re-issue. A recorded storage fault or unreconcilable carriage holds remote
access for a manager; a plain crash replays durable carriage and resumes.
There is no pending product choice from this review. Do not emit invented
wire fields or enable unfinished trust on the strength of design sign-off.
Retain one shared security/session core and the existing r8 operation semantics.

## Three-minute monitoring

The local watcher checks memory/vault first, then #81, PR #80 and implementation
PR #89 every 180 seconds while this Mac is awake and logged in. It watches #89's
head, comments/reviews and exact-head check completion even without a #81 handoff.
An unannounced commit is review input, not an approved final package pin.
It uses a user LaunchAgent, not an in-process chat timer.
When memory/vault content or GitHub content/head/review changes, it starts a bounded Codex CLI continuation
with the saved coordination instructions. Unchanged polls do not start a model
run or post repetitive status. An exclusive lock prevents overlapping runs;
a dirty/missing/wrong-branch worktree defers processing instead of overwriting
work. Network/CLI failures remain pending for retry and are recorded locally.

Local files are under
`~/Library/Application Support/Astation/Agent Coordination/`:
`monitor.py`, `prompt.md`, `status.json`, `snapshot.json`, `latest-result.json`
and bounded run logs. No credentials are copied there; gh and Codex use their
existing sign-ins. The LaunchAgent label is `build.agora.astation.github-handoff`.
This is a developer coordination tool, not a shipped Astation service.

The continuation may review, test and implement already authorized Astation
work on its task branch, committing/pushing reviewable changes and replying
directly on GitHub. It does not merge/deploy, manage unrelated branches,
change account/host trust or touch Atem source. A new user decision is saved
locally and announced through a desktop notification; dependent work waits
for the user's answer. Questions requiring that decision are not posted as
decisions on GitHub. Check local results if notifications are unavailable.

The watcher cannot run while the Mac is powered off/asleep. A wake catches up
with authoritative GitHub content; it does not assume three-minute execution
while offline. The CLI itself has no Scheduled management interface; this
uses its documented [non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).

To stop this watcher without deleting its state:

```sh
launchctl bootout gui/$(id -u)/build.agora.astation.github-handoff
```

Merging Astation main triggers production deployment. Monitoring and the
instruction to start approved implementation do not authorize a main merge.

## Current integration handoff, 2026-10-20

[Atem's start request](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6306876197)
confirms that Astation can integrate the accepted Task 7 client packages at
`edeb8f0fab71d4573e41c4ca7935aab207200caf` while the host-only revocation
quarantine correction is finalized. Do not wait for that correction to begin
the shared strict-reader ceremony, full r9 client/router adapters or encoded
`push_ack` splitting at 262,144 bytes including the wrapper. Review the final
host pin and matching artifacts separately; a promised fix is not approval.
Android library loading on a device/emulator remains a validation task.
Admission and deployment still require their existing gates.
