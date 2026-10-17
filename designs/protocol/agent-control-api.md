# Agent control API: Astation and Atem joint proposal

Status: proposal r1, 2026-10-17. This document records Brent's requested next
milestone: operate agents started with `atem agent launch` through APIs,
including conversations, approvals and notifications. Proposed endpoints and
wire additions below are not implemented or jointly approved yet.

Tracking: [Astation #52](https://github.com/Agora-Build/Astation/issues/52).
The existing API shipped in [Astation #50](https://github.com/Agora-Build/Astation/pull/50).
[Atem #72](https://github.com/Agora-Build/Atem/pull/72) is now merged; its main
merge commit is `1d79ab66b067464b7a93b549ef5d913c91b6275f`. Baseline contracts:
[session r7.1](https://github.com/Agora-Build/Atem/blob/1d79ab66b067464b7a93b549ef5d913c91b6275f/designs/protocol/atem-session-v1.md)
and [agent chat](https://github.com/Agora-Build/Atem/blob/1d79ab66b067464b7a93b549ef5d913c91b6275f/designs/agent-chat-host.md).
The session contract governs bindings, permissions and receipts where the
older chat document describes pre-runtime behavior.

## Required first milestone

| User operation | Ready today | Work needed |
| --- | --- | --- |
| Discover launched agents and their capabilities | Local session registry API | Expose explicit API feature support and actionable unsupported-feature errors. |
| Send a prompt to the original running agent | Claude, with control and chat-v1 | Codex structured chat adapter in Atem; no second provider session. |
| Read replies and earlier conversation | Claude host chat-v1 | Session-bound native chat coordinator, history API and live events in Astation; agree history completion/recovery semantics. |
| See and answer approvals | Local inbox and answer APIs | Joint live tests; render approval parts in structured chat and publish lifecycle events. |
| Be notified when action is needed or work ends | Native in-app approval notifications | API event subscription plus completion, failure and connection/control notifications; offline delivery is a separate gate. |
| Interrupt or stop an agent | Controlled submissions and durable receipts | Complete disposable-session live tests; keep interrupt and process stop distinct. |
| Recover an uncertain request | Scoped receipt query and durable UUID journal | Expose receipt updates in events; recover associated replies where host history still exists. |

Chat must include both prompts typed locally in the terminal and prompts sent
remotely, with their real origin. Return text and safe tool summaries as
structured parts. Do not reconstruct a conversation from ANSI screen output,
infer success from an idle indicator, or return private reasoning.

Read-only live check on 2026-10-17: the running provisioned Astation answers
status and session-list requests with r7.1, two running Claude sessions with
chat-v1 and one running Codex session with terminal-v1 only. All three have no
controller. This verifies discovery/capability reporting, not the proposed
history, event stream, offline delivery or the full approval acceptance matrix.

The initial API extends Astation's protected loopback service. The agent may
run on another machine through the existing authenticated Atem link. Native
UI, scripts and future clients should use the same session/chat services;
there should be no second agent-control authority in the relay or an
independent Atem HTTP server for this feature.

## Ownership

**Atem owns** the original agent process, provider adapters, authoritative
transcript and semantic lifecycle, history retention, pending approval hooks,
control leases and durable command outcomes. It advertises chat-v1 only when
the particular running provider's adapter is healthy. Codex approvals already
work without a Codex chat adapter; they are separate capabilities.

**Astation owns** the session-bound conversation coordinator, API admission,
REST operations, event stream, native conversation/approval views and local
notifications. It maps authenticated host events into a bounded read model;
it cannot invent an agent response, approval resolution or successful receipt.
The existing BrowserAgentChat bridge is not a native session chat service:
managed-session browser access remains gated by section 9.

**Joint work** is the chat history boundary, recovery/correlation contract,
provider capability expectations and shared fixtures. The Atem owner makes
all Atem implementation changes. Shared memory and published documents are
the handoff; Astation must not edit or build an Atem checkout.

## Proposed API surface

Retain the existing routes and their request shapes in
[the local API guide](../../docs/local-control-api.md): sessions, acquire,
release, submit, approvals, answer and receipt query. Submission remains
`kind: prompt | interrupt | stop`; approval answers use their dedicated route.
HTTP 202 means journaled locally, not delivered or completed by the agent.

Proposed additions, to be finalized after Atem review:

| Route | Purpose |
| --- | --- |
| POST /api/v1/chat/open | Accept client_id and full target; return an opaque local chat_id while opening a read subscription. Never acquire control or send a prompt. |
| POST /api/v1/chat/history | Accept chat_id and optional opaque before cursor; return a bounded page with sync state and an explicit continuation/retention boundary. Opening or paging may be pending; only an authenticated end marker can make it complete. |
| POST /api/v1/chat/close | Release the caller's view. Never interrupt, stop or restart the agent. Share one live host conversation per target among native/API readers where possible. |
| GET /api/v1/events | Server-sent events for session, chat, approval, receipt and connection/control changes, with replay cursors and explicit reset semantics. |

Every chat_id is bound to the full target: account_id, atem_device_id,
host_trust_gen, session_id and process_gen. It is an identifier, not a bearer
credential. A changed target cannot be supplied to retarget it. Prompts and
approval answers still go through the existing durable submission path;
there is no parallel chat write path with weaker checks.

History replies must distinguish pending, complete, truncated and unavailable.
They cannot claim that all messages were returned simply because the socket
was quiet. Use existing host page limits (50 messages / 256 KiB) and message
limits; return the available retention boundary rather than promising an
unlimited durable transcript. Pending pages complete through the event stream
and can be queried again. Separate pagination from the live conversation so
loading older history cannot lose live messages or reset their ordering.

API status should advertise implemented features, supported providers and
retention/recovery limits. Unsupported chat is a stable capability error;
clients can offer Open Terminal. Never silently type a structured prompt into
a provider that lacks a healthy adapter.

## Events, reconnect and notifications

The proposed event families are:

| Family | Events |
| --- | --- |
| Session | Snapshot/change/removal and process/activity updates. Process running and activity unknown are distinct facts. |
| Chat | Open/history page, whole message replacement, appended part, semantic status, turn completion, error and close. |
| Approval | Open/update/resolution and unavailable after loss of authority. |
| Command | Receipt state changes, including rejected and outcome_unknown. |
| Connection/control | Offline/reconnected, lease granted/lost/expired and authorization unavailable. |

An event envelope includes an API version, opaque replay cursor, event kind,
client_id, full target when applicable, chat_id when applicable, and the typed
payload. Preserve host messageId, part id, turnId, requestId and origin.
Notification IDs bind the full target and approval/turn ID, not hostname or
provider name. History and repeated catch-up must not create fresh alerts.

SSE is the connected API notification channel. The first subscription must
provide snapshots and then changes at one serialized sequence barrier; a
snapshot/subscription race must not lose approvals or messages. Authenticate
reconnects exactly like other API requests. Resume with Last-Event-ID, never
with a credential in the URL. Retain a bounded replay window; a process
restart, unknown cursor, evicted window or upstream sequence gap explicitly
requires resynchronization. A stale cursor is not silently treated as current.
At-least-once delivery requires deduplication, not another prompt or answer.

Bound stream count, event size, replay bytes/age and slow-reader queues. A slow
consumer must disconnect and resync rather than block native UI or grow memory
without limit. A stream reset cannot replay commands, restore a lease or
cancel accepted work. Exact bounds belong in the implementation contract.

Native notifications initially cover approval needed, turn completed,
request rejected/unknown and a relevant session/control connection lost.
Users can mute routine completion/status alerts. Avoid repeated notices for
heartbeats and backfilled messages. Resolve existing approval notifications
when the authenticated request closes. Opening a notice fetches current
authoritative state before offering any action.

APNs/FCM is the offline delivery channel and is not established by SSE or
in-app alerts. It still needs provisioned provider credentials, authenticated
host proof, recipient authorization and the durable relay outbox in
[the push proposal](approval-push-proof.md). Completion push, if desired,
needs its own agreed event and payload rules. No raw transcript belongs in
push metadata. API and native tests can run without mobile clients; actual
offline delivery requires a push-enabled test device and credentials.

## Lifecycle and security invariants

- Capture the verified host/device and connection generation before async
  dispatch. Recheck the current attachment, full target and permission at
  application and at every mutation. Late frames cannot retarget a chat.
- A read subscription never takes control. Explicit acquire/submit and
  approval answers follow r7.1 lease and atomic-acquire rules. The current
  local token represents the native Astation principal, not an independently
  enrolled device or controller. Native UI/API control ownership and renewal
  must be explicit so an abandoned automation client does not renew control
  forever. Reconnect never implicitly reacquires control.
- HTTP responses and a live event stream are not prerequisites for accepted
  host work to finish. Retry uncertain submissions only with the original
  UUID and unchanged content; recover receipts without dispatching again.
- A completed receipt means the operation's completion rule was met. It is
  not response text. A chat turn completion may precede late content for the
  same turn; merge that content. Failed, interrupted and unknown outcomes
  must remain distinguishable.
- Pending approvals arrive without requiring a held lease. Only an exact
  current snapshot is answerable; always allow uses an exact provider-offered
  rule, Claude only. Terminal/remote races, expiry and revocation disable the
  stale card. Push and chat display fields never supply answer authority.
- Inherit existing loopback peer checks, protected key file, bearer-header
  auth, no Origin/CORS and size limits. No token in URLs/logs; no transcript
  persistence in the command journal. Treat text/Markdown as untrusted data.
- Relay routing and account login are never device identity or control
  authority. Public remote/browser access stays behind section 9. Current
  compatibility transport does not promise relay confidentiality or chat
  E2EE; storage encryption does not establish either.

## Questions for the Atem owner

1. Confirm provider priorities: keep Claude's existing adapter and add Codex
   structured chat using its native events/logs; expose the same honest
   capability and status model. Which Codex versions can meet this contract?
2. Agree an explicit history-page end marker and metadata: conversation and
   process generation, last sequence, next-before cursor, retention/truncation
   boundary and how live events follow the page. The current opened/history
   message stream has no explicit history-end operation. This is a proposed
   wire change, not an existing guarantee.
3. Specify reconnect recovery of requestId -> turnId -> retained messages and
   final outcome, including broker adoption/restart and history eviction.
   Session receipts currently carry no turn ID or response text. If replies
   cannot be recovered, return unavailable/unknown with the receipt; never
   rerun the command to recreate them.
4. Confirm typed approval parts and their replacement lifecycle in history,
   correlation with session approval_request/approval_closed, provider error
   codes and capability withdrawal. Session inbox state remains authoritative
   for whether the user can answer.
5. Publish shared fixtures and an agreed contract revision/feature marker for
   additions before either side emits them. Keep existing r7.1 working without
   advertising unimplemented features.

## Implementation and acceptance order

1. Jointly settle the five points above. Astation can build the native chat
   coordinator and SSE infrastructure against existing events meanwhile;
   incomplete history must stay visibly pending/unavailable.
2. Expose Claude conversation history/events through the protected local API,
   then consume that service from the native chat view. Extend the CLI helper
   with watch/history so scripts can exercise the entire flow.
3. Add approval/receipt notifications and disposable-session integration
   tests. Atem adds Codex's structured adapter; run the same API contract
   against both providers before claiming both support chat.
4. Follow separately with files under
   [#51](https://github.com/Agora-Build/Astation/issues/51), remote launch or
   restart controls, and multi-device/browser/offline push after their gates.

The required shared tests cover: two simultaneous sessions with no crossed
messages; local and remote prompts in the same original session; history/live
overlap and pagination; duplicate/out-of-order parts and replacement approvals;
late content after completion; missing/withdrawn capability; API disconnect
immediately after submit; reconnect/reset and broker restart without replay;
an expired/unknown cursor; slow event consumers; lease expiry/local takeover;
real Claude allow once/exact always allow/deny and Codex allow once/deny;
terminal answer racing remote; expiry and duplicate catch-up; revocation while
events/answers are queued; and strict local API admission for every new route.
Assert actual agent effects and durable receipts, not only HTTP success.
