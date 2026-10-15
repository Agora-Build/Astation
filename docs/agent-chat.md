# Agent

This change configures the Agent app at `https://station.agora.build/agent/`
after deployment. The macOS
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
keeps sending disabled. The Astation UI and webapp page are implemented locally;
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

The webapp serves the page and its assets directly at `/agent/`. The existing
relay supplies `/ws` transport. RTC functionality lives in reusable modules
in Stoa under `webapp/stoa/rtc/`; see [webapp structure](../webapp/README.md). No extra
deployment environment variables are needed. Browser links must use `/agent/`;
the earlier `/chat/` route is removed. `?preview=1` opens a labeled,
interactive sample conversation and never connects to an agent.

The session key stays in the URL fragment, and requests and responses are
authenticated. Chat traffic is not end-to-end encrypted: the relay can read it
and the webapp serves the browser code. Storage encryption does not encrypt this
stream.

## Verification

```sh
node --test webapp/tests/agent-chat.test.mjs
node webapp/tests/nginx.test.js
node --test webapp/tests/screen-share.test.mjs webapp/tests/rtc-channel.test.mjs
# Against a local webapp nginx (also runs in CI against the Docker image):
WEBAPP_TEST_ORIGIN=http://localhost:8080 node --test webapp/tests/hosting.test.mjs
```

Local validation on 2026-10-14: all 446 runnable relay tests pass (109
database/Valkey integration tests ignored locally). All 24 browser crypto/state,
RTC and Stoa session-link tests pass. An actual nginx 1.28 instance serves both apps and shared
modules with the relay unavailable; CI repeats this against the webapp image.
RTC browser checks with a mocked SDK verify join, microphone off/on/mute,
screen audio selection, native dimensions/60 fps configuration and cleanup.
These checks do not measure live media quality. Desktop,
390px and 320px Chrome checks pass. Browser checks exercise streaming, code copy,
safe Markdown, scroll retention, mobile navigation and preview isolation. A
signed mock bridge verifies delivery, tamper rejection, unsupported hosts and
reload without replay. Live Atem/provider integration is a separate check.

The companion macOS worktree separately passes 798 Swift tests (11 skipped)
and its Release build; those sources are not included in this hosting change.

See the [protocol and security design](../designs/agent-chat.md).
