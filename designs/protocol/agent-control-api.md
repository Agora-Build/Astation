# Agent control API: Astation and Atem joint proposal

Status: proposal r3, 2026-10-17, incorporating
[Atem's response](https://github.com/Agora-Build/Astation/issues/52#issuecomment-6237260882)
and the baseline corrections in [Atem #74](https://github.com/Agora-Build/Atem/pull/74).
The [r2 response review](agent-control-api-atem-r2-review.md) signs off the r8
design for implementation and records two fixture corrections before its
conformance gate can pass. The earlier four contract findings are closed.
This document records
Brent's requested next milestone: operate agents started with `atem agent launch` through APIs,
including conversations, approvals and notifications. Proposed endpoints and
wire additions below are not implemented or jointly approved yet.

Tracking: [Astation #52](https://github.com/Agora-Build/Astation/issues/52).
The existing API shipped in [Astation #50](https://github.com/Agora-Build/Astation/pull/50).
[Atem #73](https://github.com/Agora-Build/Atem/pull/73) is merged after #72;
the current main baseline is `af56d39abf6394b8706e9eb8b9ea3f04b594197c`. Contracts:
[session r7.2](https://github.com/Agora-Build/Atem/blob/af56d39abf6394b8706e9eb8b9ea3f04b594197c/designs/protocol/atem-session-v1.md),
[agent chat](https://github.com/Agora-Build/Atem/blob/af56d39abf6394b8706e9eb8b9ea3f04b594197c/designs/agent-chat-host.md)
and the [developer guide](https://github.com/Agora-Build/Atem/blob/af56d39abf6394b8706e9eb8b9ea3f04b594197c/designs/agent-chat-api.md).
The session contract governs bindings, permissions and receipts where the
older chat document describes pre-runtime behavior.
Astation main still implements r7.1. A local `feat/codex-approval-rules`
worktree now implements r7.2 grants, rule lists/revoke and auto_allowed
activity; its personally provisioned build passes 920 tests (6 skipped).
That work is not yet merged or jointly verified through a live Codex rule cycle.

## Required first milestone

| User operation | Ready today | Work needed |
| --- | --- | --- |
| Discover launched agents and their capabilities | Local session registry API | Expose explicit API feature support and actionable unsupported-feature errors. |
| Send a prompt to the original running agent | Atem main supports Claude and Codex chat-v1; Astation has the capability-gated submit path | Verify both providers together; respect Codex's first-local-prompt prerequisite. No second provider session. |
| Read replies and earlier conversation | Both providers have host chat-v1 | Session-bound native chat coordinator, history API and live events in Astation; agree r8 history/recovery semantics. |
| See and answer approvals | Local inbox and answer APIs | Integrate r7.2 Codex session rules, rule lists/revoke and typed chat cards; run joint live tests. |
| Be notified when action is needed or work ends | Native in-app approval notifications | API event subscription plus completion, failure and connection/control notifications; offline delivery is a separate gate. |
| Interrupt or stop an agent | Controlled submissions and durable receipts | Complete disposable-session live tests; keep interrupt and process stop distinct. |
| Recover an uncertain request | Scoped receipt query and durable UUID journal | Expose receipt updates in events; recover associated replies where host history still exists. |

Chat must include both prompts typed locally in the terminal and prompts sent
remotely, with their real origin. Return text and safe tool summaries as
structured parts. Do not reconstruct a conversation from ANSI screen output,
infer success from an idle indicator, or return private reasoning.

Earlier read-only live check on 2026-10-17: the running provisioned Astation's
status identifies its implementation as r7.1, with two Claude chat-v1 sessions
and one Codex terminal-v1 session. All three have no controller. That observation
is specific to those running sessions; it does not establish the remote build
revision or contradict the Codex adapter now on Atem main. Discovery works;
the proposed history/events and joint approval matrix are not thereby verified.

Provider baseline: Claude Code 2.1.x (Atem verified 2.1.301) and Codex 0.162.1.
Codex needs enabled/trusted Atem hooks and a first prompt typed in the terminal
before remote prompts are accepted; until then chat may open with unknown
status and a prerequisite hint. Respect opened.unavailable: neither provider
streams partial text or reasoning; Codex also lacks error_details. Whole
content blocks arriving as parts are not token streaming.

The initial API extends Astation's protected loopback service. The agent may
run on another machine through the existing authenticated Atem link. Native
UI, scripts and future clients should use the same session/chat services;
there should be no second agent-control authority in the relay or an
independent Atem HTTP server for this feature.

## Ownership

**Atem owns** the original agent process, provider adapters, authoritative
transcript and semantic lifecycle, history retention, pending approval hooks,
control leases and durable command outcomes. It advertises chat-v1 only when
the particular running provider's adapter is healthy. Codex chat and approvals
are both built on Atem main; approval availability remains independent of chat.

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
| POST /api/v1/chat/history | Accept chat_id and a bounded cursor or request/turn filter; return one bounded host page with explicit continuation and retention coverage. |
| POST /api/v1/chat/close | Release the caller's view. Never interrupt, stop or restart the agent. Share exactly one live host conversation per full target and attachment among native/API readers. |
| GET /api/v1/approval-rules | List authoritative active session rules with client_id and full target; empty means no active rules. |
| POST /api/v1/approval-rules/revoke | Accept client_id, full target, rule_id and request_id; use a durable approval_rule_revoke submission. r7.2 requires a held lease. Planned r7.3 requires control permission only; adopt its exact wire/fixtures when published. |
| GET /api/v1/events | Server-sent events for session, chat, approval, receipt and connection/control changes, with replay cursors and explicit reset semantics. |

Every chat_id is bound to the full target: account_id, atem_device_id,
host_trust_gen, session_id and process_gen. It is an identifier, not a bearer
credential. A changed target cannot be supplied to retarget it. Prompts and
approval answers still go through the existing durable submission path;
there is no parallel chat write path with weaker checks.

The host sends a page as one batch; it does not provide a pending-page job.
Waiting for network delivery in Astation is not a host background operation.
Until an explicit boundary arrives the initial view is loading/unconfirmed,
never complete merely because the socket is quiet. A timeout is unavailable
or unconfirmed, not an empty completed page.

Use existing page bounds (50 messages / 256 KiB), message bounds and a
serialized-frame bound for every page, including lookup by request or turn.
Return continuation and retention coverage rather than promising unlimited
durable history. Separate pagination from live delivery and add an explicit
snapshot/version merge rule so a delayed page cannot replace newer parts or
resolved cards. History truncation is information to display, not an instruction
to reopen repeatedly. An actual live sequence gap requires resynchronization.

Atem retains 500 messages / 8 MiB per process. Response r2 reports that #75
restores the whole retained history and approval cards on broker adoption,
closing formerly pending cards. Full restart recovery still needs joint tests;
the older 200-message / 1 MiB adoption limit is historical.

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
| Approval | Open/update/resolution, active session rule changes/revocation and unavailable after loss of authority. |
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
Turn-ended notifications must distinguish done from interrupted, and neither
is proof that the user's requested task succeeded. Until receipt.result is
implemented, a completed receipt alone does not supply that distinction;
use authenticated chat outcome or an explicit receipt detail, else unknown.
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
  approval answers follow r7.2 lease and atomic-acquire rules. The current
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
  current snapshot is answerable. Always allow echoes an exact offered rule:
  Claude's provider rule or Codex's Atem session rule. Codex rules match the
  byte-exact shell command and cwd for this process, account/device/trust
  generation only; no glob/prefix or cross-session grant. Show session scope,
  active rules and revoke. auto_allowed cards are informational, not pending
  questions. Terminal/remote races, expiry and revocation disable stale cards.
  Push and chat display fields never supply answer authority.
- Inherit existing loopback peer checks, protected key file, bearer-header
  auth, no Origin/CORS and size limits. No token in URLs/logs; no transcript
  persistence in the command journal. Treat text/Markdown as untrusted data.
- Relay routing and account login are never device identity or control
  authority. Public remote/browser access stays behind section 9. Current
  compatibility transport does not promise relay confidentiality or chat
  E2EE; storage encryption does not establish either.

## Joint agreement status

1. Providers and ownership are answered by Atem #74; no Codex adapter build is
   needed from Astation. The r7.2 rules, unavailable flags, prerequisite hint
   and approval-part states need native/API integration and joint tests.
2. Accept the r8 appendix's sequenced history pages/history_end, bounded
   continuation and persistent coverage semantics. Astation implements the
   HTTP/SSE merge cursor and its delayed-page regression fixture.
3. Agree journaling the completed turn's identity and outcome without reply
   text. receipt.result availability/IDs are a current projection of retained
   history, not immutable text or a promise of successful work. Late content
   remains valid; unavailable replies never trigger command re-execution.
4. Accept typed approval states, rule_id/note and proposed final-card reason.
   Session approval_request/approval_closed remain authoritative. Implement
   rule revoke before exposing a complete session-rule management flow.
5. Build the approved r8 design with required hello revision, validated
   welcome revision/features and shared fixtures. Incompatible peers fail
   closed during admission.
   No new operation is emitted or advertised before its implementation and
   fixtures pass on both sides.

## Implementation and acceptance order

1. Implement the approved r8 contract and correct the two draft fixture
   inconsistencies. Astation can build the native chat coordinator and SSE
   infrastructure meanwhile; unavailable capabilities and unconfirmed history
   remain explicit. Adoption of the separate r7.3 revoke change waits for its
   exact published contract and tests.
2. Expose both providers' conversation history/events through the protected
   local API, then consume that service from the native chat view. Extend the CLI helper
   with watch/history so scripts can exercise the entire flow.
3. Add approval/receipt notifications and disposable-session integration
   tests. Run the same API contract against both providers, including Codex's
   first-prompt prerequisite, session-scoped rules and revoke.
4. Follow separately with files under
   [#51](https://github.com/Agora-Build/Astation/issues/51), remote launch or
   restart controls, and multi-device/browser/offline push after their gates.

The required shared tests cover: two simultaneous sessions with no crossed
messages; local and remote prompts in the same original session; history/live
overlap and pagination; duplicate/out-of-order parts and replacement approvals;
late content after completion; missing/withdrawn capability; API disconnect
immediately after submit; reconnect/reset and broker restart without replay;
an expired/unknown cursor; slow event consumers; lease expiry/local takeover;
real Claude allow once/exact always allow/deny and Codex allow once/session
always allow/deny/revoke; auto_allowed cards without a pending approval;
terminal answer racing remote; expiry and duplicate catch-up; revocation while
events/answers are queued; incompatible-revision rejection; and strict local
API admission for every new route. Include the four response-review fixtures.
Assert actual agent effects and durable receipts, not only HTTP success.
