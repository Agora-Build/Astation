# Astation review of Atem's agent API response r1

Historical review. The four contract findings are closed by the
[r2 response review and design sign-off](agent-control-api-atem-r2-review.md).

Reviewed 2026-10-17. Source:
[Atem PR #74](https://github.com/Agora-Build/Atem/pull/74), commit
`232dba7615a8e4eb16a19736587d65dcf96bbf84`,
`designs/protocol/agent-control-api-atem.md`.
Baseline: Atem main `af56d39abf6394b8706e9eb8b9ea3f04b594197c`, r7.2.
This is a contract/document review, not a claim of live r8 conformance or a
review of every implementation change in Atem #73. No Atem checkout was
edited or built.

The ownership split and proposed history-end, receipt-result and feature
directions are accepted. The four details below need agreement before r8
is implementation-ready. They concern the proposed protocol, not a claim
that these proposed features are already deployed.

## 1. High: welcome-only revision does not exclude incompatible clients

Reference: [response lines 233-248](https://github.com/Agora-Build/Atem/blob/232dba7615a8e4eb16a19736587d65dcf96bbf84/designs/protocol/agent-control-api-atem.md#L233).
The proposal changes paging semantics while retaining envelope v:1 and
introducing revision/features only in welcome. An r7 client is explicitly
allowed to ignore those unknown fields, so the host has no proof it can use
r8 semantics. Dropping open.before also risks an old paging request being
interpreted as an ordinary newest-page open.

Required resolution: make the client name the required revision in hello,
with an exact admission rule, or use an incompatible envelope version. An
r8 host must reject an absent/incompatible revision with unsupported_version
before admitting session work. The client must validate welcome revision and
required features before enabling new operations. Incompatible forms,
including the removed open.before, must be explicitly refused. This follows
the user's decision that both sides update together without legacy fallback.

Fixtures: r7/missing revision against an r8 host; r8 against an older host;
missing required feature; and open.before against r8. No command, control
grant or incorrectly interpreted page may result.

## 2. Medium: define page/live ordering through the API boundary

Reference: [response lines 101-105](https://github.com/Agora-Build/Atem/blob/232dba7615a8e4eb16a19736587d65dcf96bbf84/designs/protocol/agent-control-api-atem.md#L101).
history_page is unsequenced, while whole messages always replace cached
copies. The proposed API returns pages over HTTP and changes over SSE, so
the order of delivery across those two channels is not guaranteed.

Example: an API page snapshots an approval as pending; a live whole-message
update closes it over SSE; the older HTTP reply then arrives and replaces the
closed card with pending. The same race can remove assistant-message parts.
The session inbox still determines answerability, but the conversation/API
can show stale state and lose already received content.

Required resolution: guarantee that the host snapshots and enqueues each
page atomically at a defined position in the same ordered conversation
transport. Astation can then attach its own snapshot/replay cursor to the
HTTP page and compare cached message mutations against that cursor. If host
snapshot and enqueue can be separated or reordered, a host snapshot barrier
or message revision is needed instead. A host wire change is unnecessary if
the ordered-stream guarantee is explicit and sufficient. Reopening changes
the cursor context. A page must never replace a newer known version.

Fixture: delay the HTTP page reply containing a pending approval and a
partial assistant message, apply an SSE closed card and appended part, then
deliver the page. Both newer versions must survive, with no renewed alert or
actionability. This is an Astation API fixture; also confirm the host's
page/live enqueue ordering.

## 3. Medium: turn recovery needs bounded pagination too

Reference: [response lines 176-179](https://github.com/Agora-Build/Atem/blob/232dba7615a8e4eb16a19736587d65dcf96bbf84/designs/protocol/agent-control-api-atem.md#L176).
Lookup by turn_id or request_id promises one history_page containing that
turn's retained messages and end:start. One turn can exceed the ordinary
50-message / 256 KiB page bound, up to the retained 500 messages / 8 MiB.
Sending it in one reply can exceed the session/chat 1 MiB frame limit;
silently cutting it and returning start falsely claims complete recovery.

Required resolution: make before, turn_id and request_id mutually exclusive
query selectors with validation/size limits. A filtered lookup needs bounded
continuations tied to the same target, filter and snapshot context. Apply
message-count, content-byte and serialized-wire-byte bounds to every page.
Define end as exhaustion of the selected result and report partial/unavailable
coverage without claiming an entire turn was recovered. Bound reply_message_ids
and multi-receipt responses as well, with explicit continuation if needed.

Fixture: one turn with more than 50 messages and more than 256 KiB, plus
JSON-escaping overhead. Recover it in bounded pages with stable continuation;
no oversized frame, skipped/duplicated reply or premature end:start.

## 4. Medium: reopening on persistent truncation cannot repair history

Reference: [response lines 292-296](https://github.com/Agora-Build/Atem/blob/232dba7615a8e4eb16a19736587d65dcf96bbf84/designs/protocol/agent-control-api-atem.md#L292)
and [truncation semantics at line 120](https://github.com/Agora-Build/Atem/blob/232dba7615a8e4eb16a19736587d65dcf96bbf84/designs/protocol/agent-control-api-atem.md#L120).
The response says any truncated flag means reopen. Once messages are evicted,
every new page remains truncated, so this rule creates an endless reopen loop
without recovering the lost data. It can also repeatedly discard useful state.

Required resolution: distinguish persistent retention/coverage information
from a live-stream discontinuity. Display truncation and continue the valid
stream. Resynchronize only for an actual sequence gap, fenced conversation,
changed generation or explicit reset, with bounded recovery. A worker backlog
gap can be inside the retained timeline; do not describe every gap as only a
missing prefix before oldest_retained. Define how such incomplete coverage is
reported without suggesting that reopen can reconstruct evicted messages.

Fixture: reopen a truncated history once, then consume valid live events.
Assert no automatic reopen loop and no prompt replay. Include a backlog gap
between retained older messages and newer content.

## Accepted corrections and Astation tasks

- Atem #73 already implements Codex chat; qualifying baseline is Codex 0.162.1
  with enabled/trusted hooks. The first prompt must be typed in the terminal.
  Show the prerequisite and opened.unavailable rather than a working composer
  or an expectation of token streaming.
- Always allow is not Claude-only. Codex offers an Atem rule for the exact
  shell command/cwd, limited to this agent process and bound to the account,
  device and trust generation. Add active-rule display, revoke, auto_allowed
  cards and note handling on Astation. The native client and inbox still
  have explicit provider == claude guards; no implementation change is
  claimed by correcting the proposal.
- Share exactly one host conversation per full target and attachment across
  native/API readers; local chat_ids are views of it. A reader closing must
  not evict another reader or stop the agent.
- Host pages are sent as batches. Waiting asynchronously for a network reply
  does not mean Atem has a pending-page job. The missing explicit page-end
  signal remains a genuine contract gap.
- A completed prompt receipt can mean an interrupted turn; done means a turn
  ended normally, not that the user's task succeeded. Preserve semantic
  outcomes and unknown states in the API and notifications.
- receipt.result may journal stable IDs/outcome without response text.
  Availability and reply IDs are a projection of retained history and may
  change with late content/eviction. Never rerun a request to restore replies.
- Broker restart currently loses some history and approval cards. Treat the
  announced recovery fixes as in progress until published and jointly tested;
  recovered cards must not revive pending approvals the host released.

The [updated Astation proposal](agent-control-api.md) incorporates these
corrections. Native chat/SSE infrastructure and r7.2 integration can proceed
while the above r8 decisions and shared fixtures are finalized. No browser,
account-wide or offline-push gate is relaxed by this review.
