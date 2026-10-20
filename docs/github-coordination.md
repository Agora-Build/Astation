# Astation and Atem coordination

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
scenarios remain NOT RUN; runtime security gates still apply. Atem owns the
next shared-core/host implementation and bindings; Astation continues its
authorized native/relay integration against those artifacts.

The 2026-10-20 [channel envelope review](../designs/protocol/remote-agent-api-channel-envelope-review.md)
answers #81's new routing proposal and inspects draft Atem PR #89 at
`2d926313388b24dd3dc4a9bdb095a25b9989df34`. Its nine fixture corrections
align with existing decisions; the contract/channel vectors are unchanged.
The proposed envelope still needs pinned size/lifecycle text and fixtures.
Passing upstream binding/package CI currently exposes no built artifacts;
Atem must hand over packages and hashes for Astation integration.

Recovery choices are settled: 24-hour host-clock wait with approve/veto,
replaceable kits, and no recovery publication without a reachable trusted
host-signed head. The kit now carries a genesis anchor/tag; older kits need
re-issue. A recorded storage fault or unreconcilable carriage holds remote
access for a manager; a plain crash replays durable carriage and resumes.
There is no pending product choice from this review. Do not emit invented
wire fields or enable unfinished trust on the strength of design sign-off.
Retain one shared security/session core and the existing r8 operation semantics.

## Three-minute monitoring

The local watcher checks memory/vault first, then #81 and PR #80 every 180
seconds while this Mac is
awake and logged in. It uses a user LaunchAgent, not an in-process chat timer.
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
