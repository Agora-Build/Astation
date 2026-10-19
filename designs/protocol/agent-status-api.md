# Agent status: capture, normalization and API delivery

Review draft, 2026-10-19. This explains the existing implementation and the
agreed direction for independent mobile/bot clients. It introduces no new wire
operations and does not enable remote access.

Atem source inspected at immutable main
[`685e213e709a158541b4cca6f03d05379c71d28f`](https://github.com/Agora-Build/Atem/tree/685e213e709a158541b4cca6f03d05379c71d28f).
The r9 integration follows signed-off contract `c685aba` in PR #80. These
are different milestones: existing r8 agent capture works independently of
the unfinished r9 admission/client integration.

## 1. The design in one picture

```text
Claude Code                           Codex
  hooks + transcript JSONL              hooks + rollout JSONL
            |                                      |
       Claude adapter                         Codex adapter
            +-------------------+------------------+
                                |
                   AgentEvent / LogItem
                                |
             Shared ChatSession state machine
           status + Markdown messages + turn outcomes
                                |
              Per-agent worker -> Atem runtime/host
              process lifecycle + session registry
                                |
             authenticated session protocol
           snapshot, changes, chat, approvals, receipts
                                |
            controller's validated client state
                                |
              Mac UI / mobile UI / scoped bot
```

For the independent r9 path, the authenticated session protocol travels in
the end-to-end encrypted host channel over WSS through the relay. Each
controller connects to Atem itself; Mac Astation does not forward the phone's
requests. The relay routes ciphertext and stores the agreed records. It
cannot decide which agent is working or which device may control it.

## 2. Four facts that must remain separate

| Fact | Meaning | Authoritative evidence |
| --- | --- | --- |
| Connection | Can this controller currently exchange authenticated messages with Atem? | Client transport/channel and attachment state. |
| Process state | Is this agent process running, exited, interrupted or in recovery? | Atem's worker, PTY/process supervision and runtime registry. |
| Activity | Is the running agent ready, working, waiting or unknown? | Agent lifecycle events, transcript/rollout and approval tracking, normalized by Atem. |
| Request outcome | Was this particular command accepted, started, completed, rejected or uncertain? | Its durable request receipt and correlated turn/result. |

A running process with `activity: unknown` is still running. A disconnected
controller cannot conclude the remote process stopped. `ready` describes
activity; draft, permission and lease checks can still prevent a new prompt.
A green process dot is not a verification badge or a promise of responsiveness.

Current Mac rows already use process state for the dot: running is green;
stopped states are red; unavailable process state is gray. Activity supplies
the separate Idle / Working / Waiting / Unknown label.

## 3. How Atem captures Claude Code

When launching a Claude session, Atem supplies per-session hook settings.
Hook commands write event JSON into private per-session files using an atomic
write/rename. The adapter reads those events and follows the transcript JSONL
named by `SessionStart`. Lifecycle events establish activity; transcript
records provide actual messages and another source of turn completion.

| Claude evidence | Normalized behavior |
| --- | --- |
| `SessionStart` for a new conversation | Establish the session and report `ready`. |
| `UserPromptSubmit` | Report `working`; correlate the prompt with transcript evidence. |
| `PreToolUse` | Report `working`. |
| Permission `Notification` | Report `waiting`. A typed pending approval comes from the separate approval mechanism. |
| `PostToolUse` after a wait | Return to `working`; tool completion alone does not finish the whole turn. |
| `Stop`, transcript `end_turn`, or an interrupt marker | End the turn; report `ready`, with done/interrupted outcome where available. |
| Same-log compaction/resume during a turn | Preserve the turn instead of treating it as a fresh idle session. |

Claude's `PermissionRequest` hook is also used for actionable approvals.
The status notification and the exact approval request are related but
different: displaying Waiting does not itself authorize an Allow button.
The notification mapper prefers `notification_type: permission_prompt`; an
older notification without that field has a permission-keyword fallback.
That fallback is an activity hint, not a source of approval authority.

Without an active `SessionStart`, Claude chat is not advertised. After 15
seconds the adapter can explain that hooks are inactive, disabled, bypassed
by `--bare`, or unsupported. The process may still run in its terminal.

## 4. How Atem captures Codex

Codex uses consented/trusted Atem hooks and its structured rollout JSONL.
Hooks identify the conversation, prompt and tool lifecycle. Rollout records
provide messages and authoritative turn-start/end evidence.

| Codex evidence | Normalized behavior |
| --- | --- |
| Before the first hook | `unknown`, with a first-prompt-in-terminal explanation; remote chat submission is refused. |
| `UserPromptSubmit` or rollout `task_started` | Report `working`. |
| `PreToolUse` / `PostToolUse` | Track tool activity; a finished tool can clear a wait. |
| Outstanding remote approval or a released approval now waiting in Codex's own dialog | Report `waiting`. |
| Rollout `task_complete` / `turn_aborted` | Report `ready`; end the turn as done/interrupted. |
| `Stop` / `Interrupt` hook | Wake/update the reader and clear appropriate dialog tracking; rollout completion remains the turn-end authority. |
| `/new`, resume or another conversation | Validate and switch the pinned session, draining the old rollout first. |

Codex may produce no session hook until its first local prompt. Atem avoids
typing a remote prompt into an unrecognized startup dialog. Hooks must also
be trusted in Codex's `/hooks`; the exact requirement depends on that installed
Codex version/configuration.

The adapter checks hook process ancestry and pins the Codex session. A Codex
started inside a tool cannot replace its parent's status/chat. Its rollout
must be the session-named file under the resolved Codex sessions directory.
Unexpected formats can withdraw chat rather than invent a parsed response.

## 5. Normalization and timing

Provider adapters emit common `AgentEvent` and `LogItem` values. One
agent-neutral `ChatSession` state machine handles both. Adding another agent
requires an adapter; the registry, UI and API keep the same basic model.

```text
unknown -- valid session start --> ready
ready   -- prompt / turn start --> working
working -- permission wait -----> waiting
waiting -- tool continues ------> working
working/waiting -- turn end ----> ready
```

Process exit is handled separately by the worker/registry. It must not be
represented merely as Idle or as a guessed completed request.

Current workers poll adapter events/logs every **200 ms**. They feed ordinary
events, log records, and then hook turn-end events to the shared state machine,
so available transcript outcomes are considered before the hook completion.
Changed activity is forwarded to the broker, then the host's session registry.
The normal delivery delay includes agent hook/log publication, that poll,
runtime scheduling and network latency; 200 ms is not an end-to-end SLA.

An open chat conversation gets its current status again approximately every
**15 seconds**, preserving its original status `since`. This is a chat status
heartbeat, not a periodic process-existence proof. Registry changes are
separate. The **three-minute** developer coordination monitor is unrelated to
agent status capture or UI update frequency.

`activity_since` in the session descriptor is the host's wall-clock time when
the bridge applied activity. It can differ from the chat status `since`,
especially after adoption/reconnect. Neither timestamp is a last-seen value
or a monotonic elapsed-time guarantee. A long-running tool can remain Working
for a long time without new text; silence must not make it Idle.

## 6. How that becomes a consumable API

### Existing session protocol

1. Authenticate the endpoint and negotiate the supported contract revision.
2. Send session `hello`, validate `welcome`, then send `list`.
3. Receive a `sessions` snapshot containing full descriptors.
4. Apply complete `session_changed` descriptors as activity, process state,
   controller or capabilities change.
5. Subscribe to chat/history and approvals separately when needed.

A descriptor includes `session_id`, `process_gen`, `provider`, `cwd_label`,
`state`, `activity`, `activity_since`, `controller`, `capabilities` and
`created_at`. Surrounding messages carry runtime generation/epoch and sequence.
Those fields already describe both Claude and Codex. The relay does not need
provider-specific status parsers.

Snapshot/change ordering is per attachment. Duplicates are ignored; a gap
requires a fresh list. A newer runtime epoch fences older data. A new welcome
resets the attachment's registry state, retaining the host fencing floor.
`process_gen` distinguishes replacement processes; a session label alone is
not a safe target. Reconnect never restores control implicitly.

Chat delivers whole messages with stable IDs, Markdown text and typed
tool/approval parts. History, coverage and receipt results correlate responses
with requests; they are not flattened into the status string. The public
descriptor currently has no activity-reason/source/confidence fields. Some
explanations are available through chat status/capability notices instead.

### Existing Mac-local HTTP API

| Route | What it exposes |
| --- | --- |
| `GET /api/v1/sessions` | The validated registry descriptor, full target, connection phase/status, negotiated features and control ownership. |
| `POST /api/v1/chat/read` | A bounded chat snapshot, load state, sequence, messages and retention coverage. |
| `GET /api/v1/approvals` | Exact pending requests and whether this verified client can answer. |
| `POST /api/v1/receipts/query` | The latest authenticated outcome for one durable request identity. |

This optional loopback API uses the running Mac's verified r8 session and a
protected local bearer token. It currently supports polling, not a shipped
SSE event stream. It depends on that Mac being online. Its address/token must
not become the phone/bot credential or be exposed as a public relay API.
See [local API details](../../docs/local-control-api.md).

### Independent r9 mobile and bot API

The agreed high-level surface is `listSessions`, `watchEvents`, `readHistory`,
`sendPrompt`, `answerApproval`, `revokeRule` and `queryReceipt`, implemented
through Atem's shared `atem-client` and platform bindings. These are API
responsibilities, not a claim that all named methods/bindings have shipped.

Each native client or scoped service has its own enrolled identity and
encrypted channel. It decrypts/validates host events locally and presents
the same normalized read model. WSS carries foreground updates; a future
Agora Signaling adapter may carry the same protocol. APNs/FCM carries sealed
offline approval hints, followed by authenticated catch-up when opened.

The relay's `/api/remote/v1` is discovery, signed-record storage and encrypted
transport. It does not offer plaintext authoritative agent-status/chat
endpoints. On Astation PR #58 only `GET /api/remote/v1/capabilities` is built;
it reports `not_ready`, admission disabled and no supported transports. Other
unimplemented remote paths return 503. Independent r9 access still needs the
shared core, host/bindings, relay/platform integration and conformance gates.
See [current API readiness](../../docs/remote-api.md) and
[the aligned design](remote-agent-api.md).

## 7. Reliability and security limits

| Situation | Required interpretation |
| --- | --- |
| Missing/disabled hooks or unsupported agent | Keep activity Unknown; retain terminal access where supported. Do not invent Idle. |
| Active network, no recent output | The last observed activity remains an observation; it does not prove the agent is responsive. |
| Transport lost | Mark the view disconnected/stale. Preserve last-known information as such; do not claim the process exited. |
| UI says Working or Ready | Never use that alone to acknowledge, retry or complete a command. Consult its receipt. |
| Old approval card or duplicate catch-up | Resolve against exact pending approval/process identity. The first valid answer wins. |
| Process replaced or trust revoked | Fence old bindings, subscriptions, queued effects and raw terminal writes. |
| Untrusted message imitates a status/approval | Render it as content. Only validated typed host events create status/actions. |

The existing status sources are structured CLI hooks/logs, not model reasoning
or a universal agent SDK. They describe what the agent reported and Atem
observed. They cannot prove semantic progress or that a task succeeded.
Codex reasoning and detailed model/API errors are not exposed by this adapter;
whole-message delivery does not imply token streaming or file attachments.

## 8. Review notes and follow-up

The architecture is suitable for the API: keep provider capture in Atem,
normalization in one shared state machine, and presentation in clients.
Do not add separate Claude/Codex status guesses in Swift, a Discord gateway
or the relay. Raw PTY bytes support terminal viewing; this activity pipeline
does not classify an agent by scraping visible terminal text. Separate
approval/dialog mechanisms can have their own provider-specific evidence.

Useful follow-up, not new agreed wire fields: show local connection freshness
separately, expose safe unavailable explanations consistently, and consider
source/observation metadata in a reviewed future contract if users need to
inspect why a label appeared. Agree fields and fixtures with Atem before
emitting them. Do not add a timer that silently turns Working into Idle.

This document is a pinned source/design review. No live Claude/Codex mutation
tests or new runtime conformance results are claimed. Verification should
cover startup/no hooks, first Codex prompt, long silent tools, local/remote
prompts, approvals/terminal answers, interruption, `/new`/resume/compaction,
nested agents, format changes, process exit/adoption and reconnect ordering.

## Source references

- [Atem adapter interface and normalized events](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/chat/adapter.rs)
- [Claude hook mapping](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/chat/claude/hooks.rs#L270)
- [Claude adapter/capability handling](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/chat/claude/mod.rs)
- [Codex capture, ownership and known limits](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/chat/codex/adapter.rs)
- [Shared status state machine](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/chat/session.rs#L745)
- [Worker polling and activity publication](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/runtime/worker.rs#L1275)
- [Host registry synchronization](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/src/runtime/host_bridge.rs#L1439)
- [Session contract and authoritative r8 appendix](https://github.com/Agora-Build/Atem/blob/685e213e709a158541b4cca6f03d05379c71d28f/designs/protocol/atem-session-v1.md)
- [r9 signed-off contract](https://github.com/Agora-Build/Atem/blob/c685abab92535b167f5f2658c814f0f72541d9a1/designs/protocol/atem-session-v1.md)
