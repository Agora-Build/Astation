# Astation and Atem coordination

## Current implementation, 2026-10-22

The Apple package and relay shared-library dependency now use Atem
`83c0776d21fa35c656eefaee25edd03cbbd203ee`, the [final host-route delivery](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6340237151).
The [review](../designs/protocol/remote-agent-api-host-route-review.md) checks
the corrected two-carrier contract, completed runtime regressions and all four
matching package archives. The binding API, generated Swift wrapper and Apple
manifest are unchanged from accepted 1493ca6; the new host-route verifier is
Rust-only. Astation builds its relay against the library and consumes the
prebuilt Apple package; it does not build the Atem host or FFI packages.

This increment passes the 19-assertion Apple consumer, builds the macOS app
and passes 505 relay tests (115 explicit environment ignores), including the
new real WebSocket relay-message interception cases. A bounded native run
passes 120 tests with one optional local issuer skip; the external `sysctl`
boot-ID test is excluded because this worker's sandbox denies the command.
The initial full run failed only that test's two assertions. The canonical
provisioned Local.app remains at 5aa3efd; it is not replaced by this work.

The app's v2 ceremony, mandatory kit, protected signing, relay CAS and K backup
are implemented. Protected coordinator/publication/backup/restore checkpoints
now include the shared durable snapshot with independent account/genesis anchors.
Load commits immediately; changes/clock advances commit before effects; failed
commits stop account operations. Exact writer state remains separately retained.
An OS boot-session identifier, 30-second timer and background/sleep checkpoints
preserve same-boot wait progress without trusting the relay or wall clock.
Recovery still refetches and requires a fresh host-signed proof after restart.

The current increment wires the shared r9 channel into native direct and
identity-relay socket dispatch. Session/chat/terminal data and the local API
now use revision 9 exclusively. Plaintext agent messages are refused, the
r8 handshake/fixtures and unused browser protocol replica are removed, and
unsupported hosts have no fallback. A fresh encrypted welcome alone admits
presentation state. Reconnect clears leases and queries uncertain receipts.

Independent controllers use their own outbound authenticated WebSocket at
`/api/remote/v1/channels?genesis=...&host=...`. Account authentication controls
routing privacy; the original Atem host verifies enrolled native/service
identity and scope. Per-controller handles bind to an exact host generation,
preserve inner JSON bytes, and isolate disconnects. Bounded frame/byte queues
and acknowledged replica delivery fail closed without ciphertext replay.
`AstationRemote.RemoteRelayClient` provides the reusable native transport.
See [API status and usage](remote-api.md) and the
[r9 client lifecycle](../designs/protocol/r9-client.md).

Controlled relay tests verify two independent controllers on one host with
no Mac online, account isolation, raw frame preservation, obsolete plaintext
rejection, both replica dispatchers/ACK loss and a real P-256 native proof,
signed host accept, encrypted welcome/registry and ciphertext replay refusal.
These consume the shared crate; they do not run an Atem checkout or prove a
live Claude/Codex workflow. At f99a7c1, the full suites passed: 988 app tests with
15 environment-dependent skips, 121 native tests without skips using the local
issuer, and 503 relay tests with 115 environment-gated ignores. Two additional
Postgres push tests run explicitly and pass. With the Mac unlocked, all 15
provisioned identity/Keychain/Enclave tests pass. The previous locked-screen
restriction and bounded app run are historical evidence, not current failures.
Web/automation/release validation from c679ed6 remains recorded on #58.

The new increment durably commits shared-verifier push hints/seen and ACKs
under the membership transaction lock. It adds sealed provider payloads,
protected native notification verification/dedup and actual foreground-card
attendance without acquiring a lease. Provider dispatch remains disabled:
durable stage jobs and a supported membership-key token-registration proof
are still required. Per the [latest user decision relayed by Atem](https://github.com/Agora-Build/Atem/issues/81#issuecomment-6337135672),
push is follow-up work and does not block the joint r9 release test.

The user deferred unavailable auth.agora.build so code and isolated tests
continue. #63's login implementation is retained; production registration,
configuration/deployment and live validation remain open. There is no alternate
storage authentication or legacy AGORA_ACCOUNT_* configuration. A valid account
login and the independently anchored membership are both required. The
[local validation runbook](r9-local-validation.md) supplies an isolated ES256
issuer with normal consent/PKCE/JWKS and a Postgres relay. The production native
client successfully logs in, refreshes, authenticates a relay key, registers
the synthetic account and writes/reads a signed genesis over actual HTTP and
WebSocket connections. This is a controlled account-path pass, not production
SSO, a GUI owner ceremony or a live agent pass. Use a dedicated macOS test user
for the GUI; changing only the bundle ID does not isolate saved app files.

Joint #58/#89 live testing remains the release gate. It includes real terminal,
chat/receipts, approval and independent-controller operations. End-to-end
testing also found [Astation #64](https://github.com/Agora-Build/Astation/issues/64):
the code-based host room is deleted when empty and can expire while ownerless.
Atem has now delivered the shared authenticated rejoin proof and host runtime.
This Astation increment intercepts relay-only messages from the room owner,
including targeted payloads, so a peer cannot inject challenges or verdicts.
Host relay messages already terminate at the relay's push ingress. The relay
now implements both carriers, isolated independent candidates, durable binding,
cross-replica fencing, verdicts and presence repair. The new controlled suite
passes 513 relay tests with 119 environment ignores; a separate isolated
Postgres run executes all 47 remote API cases without skips. Replacement also
fences older carrier-A channels, including delayed replies. Fixture room
recreation is no longer used for the encrypted registry/push reconnect tests.
Real Atem/Redis-replica execution and the owner ceremony remain pending. See the
[host lifecycle requirements](../designs/protocol/r9-host-routing-lifecycle.md).

Atem #89 remains unmerged; production access is not deployed. The user approved
merge/release after successful joint end-to-end tests, which have not yet passed.
Mobile/service platform and provider workflows remain separate validation.
The previous ced29ce provisioned build and Genie discovery were historical r8
checks and do not establish r9 conformance. No keys, trust floors, pairings or
credential agents were reset.

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
