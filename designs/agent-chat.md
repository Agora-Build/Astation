# Browser agent chat

## Product

The relay hosting change serves this page and its assets in production. The
companion macOS bridge remains in the `feat/remote-terminal` worktree; Atem's
semantic host implementation is coordinated through shared project memory.

Connections keeps Open Terminal and adds Open in Browser for each agent. The
new page is served by the relay at `/chat/`, with a responsive layout for desktop
and mobile. Prompts are outgoing messages; structured agent replies are incoming
messages. Code blocks, safe links, copy actions and activity indicators belong to
the conversation. The terminal remains available for CLI-specific interactions.

This is a separate protocol from terminal-v1. ANSI redraws cannot establish
message boundaries, task completion or an approval request. A host must advertise
`chat-v1` in an agent's optional `capabilities` array before prompts are enabled.
Existing Atem hosts do not advertise this capability. Their browser page opens
with an explicit unsupported state. Preview mode is labeled and never contacts
an agent. Atem implementation is coordinated through shared project memory.

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
  HTTPS/HTTP links are clickable. No third-party scripts, fonts, analytics or
  service worker. Content and capabilities are omitted from network logs.
- Session state is bounded to eight sessions, 32 browser nonces per session,
  256 submitted request IDs, 512 messages and 2 MiB of UTF-8 conversation content.
  One prompt is at most 32 KiB and one accumulated reply at most 128 KiB.
  Exceeding a host event bound disables submission. No relay transcript is stored.
- HMAC authenticates the browser-to-Astation bridge; it does not encrypt content.
  The relay can read the payload and serves the browser code. Existing TLS and
  endpoint authentication apply to the Astation-to-Atem hop. Storage E2EE does
  not imply chat-stream E2EE. Browser-origin code is part of the trusted UI.

## Host contract: chat-v1

All host traffic uses the existing authenticated connection and
`{"type":"agentChat","data":{...}}`. `data` always includes `v:1`, `op`,
`conversationId`, and `agentId`. No broadcast or focused-agent routing is allowed.

1. Astation sends `open` with a new opaque conversation ID.
2. Host sends `opened` with its opaque process `generation` and `sequence:0`.
3. Astation sends `submit` with that generation, a unique `requestId` and `text`.
   The host must deduplicate request IDs for the lifetime of this conversation.
4. Host events carry the same generation and strictly increasing `sequence`:
   `accepted` includes `requestId`; `message` includes `messageId`, `requestId`,
   full Markdown `text`; `delta` appends `text` to that message; `status` includes
   `state` (`ready`, `working`, `waiting`, `unknown`); `complete` includes
   `requestId`; `error` includes a safe `text` and optional `requestId`.
5. A sequence gap disables submissions and requires a fresh view. Duplicate
   sequences are ignored. Unexpected conversations, agents and generations are
   rejected. Reconnect does not restore permission or replay prompts.

The host owns original-session attachment and semantic event collection. It
must not start an unrelated conversation, scrape ANSI repaint output as replies,
infer readiness from silence or auto-approve a provider's permission request.
Provider approvals continue through the terminal in this first version.

## Relay and browser

The relay embeds and serves the HTML/CSS/JavaScript with restrictive CSP,
no-store and no-referrer headers. Nginx proxies `/chat/` to the relay. No new
server-side account session or privileged WebSocket role is introduced.

The browser uses `/ws?role=atem&code=<station ID>&atem_id=browser-<session ID>`
solely as an untrusted transport to Astation. It sends `browserChat` frames with
`data:{sessionId,nonce,sequence,body,mac}`. `body` is base64 UTF-8 JSON; `mac` is
base64 HMAC. The fragment key uses unpadded base64url. Requests are `open`,
`submit` (requestId/text), and `refresh`.
Signed response bodies are `context`, `event`, or `notice`. The exact payloads
are defined by the coordinator and covered by cross-language MAC vectors.

Transcripts stay in tab memory; no localStorage, sessionStorage or transcript
database is used. The capability stays in the URL fragment, which browser
history may retain, until its local authorization expires. Reloading can
reuse its fragment until the local session expires, with a new browser nonce and
response sequence. It receives subsequent events without restoring previous tab
messages. A pending request at reload disables new submissions; inspect the
terminal and open a new native-authorized session. A separate `?preview=1`
mode uses sample data, is visibly labeled and has no live network connection.

## Validation

Test message routing, MAC vectors, tampering/replay, expiration, unauthorized
sources, host-generation changes, capability gating, duplicate/gapped events,
acceptance timeouts and no prompt replay. Browser checks cover safe Markdown,
scroll retention, narrow/mobile layout and explicit preview/live separation.
Production deployment and live Atem integration require separate acceptance;
no production deployment or Atem source change is part of the UI implementation.

See [user setup and validation](../docs/agent-chat.md). Atem project memory
contains the proposed host contract (`mem_b3ccce1f5afc4c558655e0f5db13eb60`)
and provider/activity requirements (`mem_0cf8ab492a6a4465b2dfb9434fb3a43f`).
