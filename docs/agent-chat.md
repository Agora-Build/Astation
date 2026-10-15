# Agent chat in a browser

The relay hosts this app at `https://station.agora.build/chat/`. The macOS
**Open in Browser** bridge is being implemented separately on
`feat/remote-terminal`, and live prompt/reply handling requires Atem's `chat-v1`
host support. These companion pieces are required for the live workflow below.

In Astation, open **Tools > Connections > Clients & Agents**, choose an online
Atem, then click **Open in Browser** on its agent. **Open Terminal** remains
beside it for the full CLI and provider permission prompts.

The responsive page shows your prompts on the right and agent replies on the
left. Replies support code blocks, syntax colors, safe HTTP/HTTPS links and
copy buttons. Scrolling up keeps your reading position during a reply;
**Latest messages** returns to the end. On a phone, use the send button.

## Atem support

Live chat requires an Atem host that advertises `chat-v1` for the selected agent.
Without that capability, the page explains that an Atem update is needed and
keeps sending disabled. The Astation UI and relay page are implemented locally;
the companion host implementation is handed off through shared Atem memory.
Live provider acceptance remains pending that work.

Terminal screen updates alone cannot reliably identify prompt/reply boundaries,
completion or agent readiness. The browser uses structured events from the
original agent session. **Delivered** means Atem acknowledged a prompt;
completion requires a separate event. **Ready**, **Working** and **Needs your
input** follow semantic host reports. Missing reports become **Unknown** after
30 seconds. The older registry's `Idle` value does not establish readiness.

## Sessions and recovery

The browser link authorizes one selected agent through Astation for one hour.
Keep it private. Astation must remain running and authenticated with that host.
Replacing a connection or revoking its pairing disables submission. Open a new
browser session from Astation after reconnecting.

Messages stay in tab memory. Reloading can reopen the same view while its link
is valid, but does not restore earlier messages or replay prompts. If a request
was pending at reload, open a new session after inspecting the original terminal.
When delivery is unknown, inspect the terminal before deciding to send again.
The application never retries a prompt automatically.

The relay serves the page at `/chat/`; its nginx proxy forwards this route and
the version-matched assets to the relay. No extra deployment environment variables
are needed. `?preview=1` opens a labeled, interactive sample conversation and
never connects to an agent.

The session key stays in the URL fragment, and requests and responses are
authenticated. Chat traffic is not end-to-end encrypted: the relay can read it
and serves the browser code. Storage encryption does not encrypt this stream.

## Verification

```sh
node --test webapp/tests/agent-chat.test.mjs
node webapp/tests/nginx.test.js
cd relay-server && cargo test --locked web::agent_chat
```

Local validation on 2026-10-14: all 448 runnable relay tests pass (109 database/Valkey
integration tests ignored locally). Browser crypto/state tests and desktop,
390px and 320px Chrome checks pass. Browser checks exercise streaming, code copy,
safe Markdown, scroll retention, mobile navigation and preview isolation. A
signed mock bridge verifies delivery, tamper rejection, unsupported hosts and
reload without replay. Live Atem/provider integration is a separate check.

The companion macOS worktree separately passes 798 Swift tests (11 skipped)
and its Release build; those sources are not included in this hosting change.

See the [protocol and security design](../designs/agent-chat.md).
