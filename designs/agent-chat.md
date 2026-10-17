# Agent browser app

## Product

The webapp serves this UI and its assets in production. This implementation
integrates the native bridge with Atem's published `chat-v1` host contract:
`Agora-Build/Atem`, commit `10d3ea8`, `designs/agent-chat-host.md` (PR 65).

Connections keeps Open Terminal and adds Open in Browser for each agent. The
new page is served by the webapp at `/agent/`, with a responsive layout for desktop
and mobile. Prompts are outgoing messages; structured agent replies are incoming
messages. Code blocks, safe links, copy actions and activity indicators belong to
the conversation. The terminal remains available for CLI-specific interactions.

This is a separate protocol from terminal-v1. ANSI redraws cannot establish
message boundaries, task completion or an approval request. A host must advertise
`chat-v1` in an agent's optional `capabilities` array before prompts are enabled.
Claude launched by an updated `atem agent launch claude` advertises this only
after its hooks become active. Codex and agents without an adapter remain
Unknown, with terminal access and no chat capability. Preview mode is labeled
and never contacts an agent. Atem releases are owned by the Atem agent.

## Lifecycle and security invariants

- Clicking Open in Browser locally authorizes one ephemeral browser session for
  exactly one authenticated Atem connection and agent ID. It grants no access to
  pairing, credentials, vaults, other agents or arbitrary terminal input.
- Astation creates a fresh 256-bit symmetric secret, kept in memory, and puts it
  in the URL fragment. It is never sent as a query parameter or stored in relay
  state. The browser proves possession with HMAC-SHA256 on every request.
- The existing relay routes the browser as an untrusted endpoint named
  `browser-<session UUID>`. It is never added to Astation's paired-device list.
  Relay presence and endpoint IDs do not authorize browser actions.
- Every request/response MAC covers a direction-specific label, session ID,
  browser nonce, increasing sequence and the exact base64-encoded JSON body.
  Encoding uses four-byte big-endian byte lengths for each UTF-8 field. The
  labels are `astation-browser-chat-request-v1` and
  `astation-browser-chat-response-v1`. Replay, altered content, wrong direction
  and unbound sources are rejected. A signed open binds a browser nonce and
  current relay connection; commands never fall back to another selected agent.
- Sessions expire after one hour or when Astation exits. Host disconnection,
  replacement or pairing revocation disables submission. Prompts are never
  automatically retried. A missing acceptance acknowledgment has an unknown
  delivery outcome. Browser reconnect only reopens the view.
- Local prompt text appears as Sending until the selected host acknowledges its
  request ID. Accepted means delivered, not completed. Working/Waiting/Ready
  require semantic host events; missing or stale activity becomes Unknown.
- Content is rendered using DOM text nodes, never remote HTML. Only explicit
  HTTPS/HTTP links are clickable. No externally hosted scripts, fonts, analytics or
  service worker. Content and capabilities are omitted from network logs.
- Session state is bounded to eight sessions, 32 browser nonces per session,
  256 submitted request IDs, 512 messages, 8 MiB of UTF-8 conversation content,
  and 16 MiB of serialized message data including part IDs and metadata.
  One prompt is at most 32 KiB and one accumulated message at most 128 KiB
  plus Atem's reserved truncation marker. Typed parts and wire frames also have
  explicit bounds. History replaces whole messages; repeated part IDs add no data.
  Exceeding a host event bound disables submission. No relay transcript is stored.
- HMAC authenticates the browser-to-Astation bridge; it does not encrypt content.
  The relay can read the payload; the webapp serves the browser code. Existing TLS and
  endpoint authentication apply to the Astation-to-Atem hop. Storage E2EE does
  not imply chat-stream E2EE. Browser-origin code is part of the trusted UI.

## Host contract: chat-v1

The approved host contract uses these event shapes:

- Messages carry `role`, `turnId`, `createdAt`, typed text/tool `parts`, optional
  `history` and `requestId`, and local/remote origin for user messages.
- Deltas append a typed part, deduplicated by part ID. History and reconnect send
  whole messages. `open.before` requests older history; the initial page contains
  at most 50 messages / 256 KB.
- Completion carries `turnId`, optional `requestId` and `outcome` (`done` or
  `interrupted`). Late content for a completed turn remains valid.
- Semantic status includes `since` and optional `detail`, refreshed every 15 s.
  Request IDs deduplicate across the agent session. The host refuses submission
  when local terminal input/control or non-ready state makes it unsafe.

All host traffic uses the existing authenticated connection and
`{"type":"agentChat","data":{...}}`. `data` always includes `v:1`, `op`,
`conversationId`, and `agentId`. No broadcast or focused-agent routing is allowed.

1. Astation sends `open` with a new opaque conversation ID and optional `before`
   message ID. A page contains at most 50 whole messages / 256 KiB of content.
2. Host sends `opened` with its opaque process `generation`, `sequence:0` and
   `status:{state,since,detail?}`. The implemented host uses Unix milliseconds
   for `since` and `createdAt`; clients also accept RFC 3339 timestamps.
3. Astation sends `submit` with that generation, a unique `requestId` and `text`.
   The host deduplicates request IDs for the lifetime of the agent session.
4. Host events carry the same generation and strictly increasing `sequence`:
   `accepted` includes `requestId`. `message` includes `messageId`, `role`,
   `turnId`, `createdAt`, `parts`, optional `requestId` and `history:true`.
   User messages additionally carry `origin:local|remote`. Text parts are
   `{id,kind:"text",markdown}`; tool parts are `{id,kind:"tool",name,summary}`.
   `delta:{messageId,part}` appends a part once. `status` carries
   `state:ready|working|waiting|unknown`, `since` and optional `detail`.
   `complete` carries `turnId`, optional `requestId`, and `outcome:done|interrupted`.
   `error` carries safe `text` and optional `requestId`.
5. Two explicit exceptions have no generation/sequence: pre-session `error`,
   and host `close`. They are accepted only from the exact authenticated route,
   agent and currently opened conversation. They never grant readiness.
6. A sequence gap disables submissions and permits reopening history without
   replaying prompts. Duplicate sequences are ignored. Unexpected conversations,
   agents and process generations are rejected. A changed generation requires
   a new native-authorized link; a relay route never supplies device identity.

History and reload merge messages by stable message ID, reconcile optimistic
remote prompts by request ID, and retain locally typed terminal prompts as
distinct user messages. Completion ends an execution turn; late parts for that
turn are still accepted. A refusal is shown as refused, an already accepted
request's error as a task error, and "delivery unknown" remains uncertain.
Unknown delivery never triggers resend. Status freshness uses receipt time;
the original `since` remains unchanged on a heartbeat. Only fresh Ready permits
submission. Permission requests stay in the terminal.

Pagination and browser reload close the previous host conversation and open a
new conversation ID on the same authenticated route, pinned to the original
generation. This prevents delayed events from an earlier open corrupting the
new sequence. The host also supports reopening the same ID with `before`, but
the bridge uses fresh IDs. A host `close` (restart, capability withdrawal,
session switch or eviction) stops sending and offers an explicit history reopen.
The reopen action sends only `open`, never a prior `submit`.

The host owns original-session attachment and semantic event collection. It
must not start an unrelated conversation, scrape ANSI repaint output as replies,
infer readiness from silence or auto-approve a provider's permission request.
Provider approvals continue through the terminal in this first version.

## Relay and browser

The webapp owns HTML/CSS/JavaScript under `webapp/agent/`. Its nginx serves
these files with restrictive CSP, no-store and no-referrer headers. The relay
owns APIs and `/ws` transport. No new server-side account session or privileged
WebSocket role is introduced.

The Stoa app imports its reusable ES modules from `webapp/stoa/rtc/` for
channel setup, microphone publishing, subscriptions and screen sharing. These
modules take an SDK/client explicitly and do not depend on either page's DOM.
A page can reuse them when adding media controls. RTC session access and its
UID/token are separate from chat authorization; a chat capability never grants
RTC access. See [webapp structure](../webapp/README.md).

The browser uses `/ws?role=atem&code=<station ID>&atem_id=browser-<session ID>`
solely as an untrusted transport to Astation. It sends `browserChat` frames with
`data:{sessionId,nonce,sequence,body,mac}`. `body` is base64 UTF-8 JSON; `mac` is
base64 HMAC. The fragment key uses unpadded base64url. Requests are `open`,
`submit` (requestId/text), `history` (before), `reopen`, and `refresh`.
Signed response bodies are `context`, `event`, or `notice`. The exact payloads
are defined by the coordinator and covered by cross-language MAC vectors.

Transcripts stay in tab memory; no localStorage, sessionStorage or transcript
database is used. The capability stays in the URL fragment, which browser
history may retain, until its local authorization expires. Reloading can
reuse its fragment until the local session expires, with a new browser nonce and
response sequence. It reopens host history without sending earlier prompts.
A pending request with unresolved delivery keeps sending disabled; inspect the
terminal and open a new native-authorized session if history cannot resolve it.
A separate `?preview=1`
mode uses sample data, is visibly labeled and has no live network connection.

## Validation

Test message routing, MAC vectors, tampering/replay, expiration, unauthorized
sources, host-generation changes, capability gating, duplicate/gapped events,
acceptance timeouts and no prompt replay. Browser checks cover safe Markdown,
scroll retention, narrow/mobile layout and explicit preview/live separation.
Production deployment and live Atem integration require separate acceptance;
no production deployment or Atem source change is part of the UI implementation.

See [user setup and validation](../docs/agent-chat.md) and Atem's published
`designs/agent-chat-host.md`. Shared memory coordinates ownership and records
validation; the published wire contract supersedes the earlier flat-text draft.
