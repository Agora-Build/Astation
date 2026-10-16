# Agent

Open **Tools > Connections > Clients & Agents** in Astation, choose an online
Atem, and click **Open in Browser** on its agent. The responsive app is served
at `https://station.agora.build/agent/`. **Open Terminal** remains beside it
for the full CLI and provider permission prompts.

On the session-v1 development branch, starting a native terminal handshake
disables this older browser bridge for that exact host socket. New links explain
that managed sessions require the secure companion protocol. Existing links
stop sending. Browser access to v1 hosts remains gated on the joint security
contract and common leases; the behavior below applies to unupgraded connections.

Prompts appear on the right and replies on the left. Prompts typed directly in
the original terminal are labeled **You / Terminal**. Replies support CommonMark,
code blocks, syntax colors, safe HTTP/HTTPS links, copy actions, and compact tool
activity. Raw HTML and remote images never execute. Scrolling up keeps your
reading position; **Latest messages** returns to the end. On a phone, use Send.

## Atem support

Atem's host implementation is merged in
[PR 65](https://github.com/Agora-Build/Atem/pull/65), commit `10d3ea8`.
It supports **Claude Code launched by `atem agent launch claude`**, once its
per-session hooks are active. Hooks can activate after the workspace-trust
prompt is answered. Existing agent processes do not gain hooks from a binary
update. Preserve an active session and arrange a separate test session with
the Atem owner. At implementation time the latest release, `v0.6.19`, predates
this host change; use a release/build that includes PR 65.

The selected agent must advertise `capabilities:["chat-v1"]`. Codex and other
agents without a chat adapter keep their terminal access, report Unknown, and
cannot receive browser prompts. An unsupported page explains this and disables
sending. Preview mode (`?preview=1`) uses labeled sample data and opens no agent
connection.

The browser uses structured content from the original agent's transcript,
never terminal repaint text. **Delivered** means Atem confirmed acceptance.
**Turn finished** or **Interrupted** comes from an explicit completion event;
late transcript parts can still arrive for that turn. A refusal is displayed
separately from a task error after delivery. Provider approvals stay in the
terminal; chat cannot approve a tool request.

**Ready**, **Working**, **Needs your input**, and **Unknown** follow semantic
host reports. Atem refreshes status every 15 seconds with its original start
time. Astation uses receipt time to detect staleness: reports older than 30
seconds become Unknown. Only fresh Ready permits Send. A draft can be edited
while the agent works. The host also refuses submission while the terminal has
an unsent draft or a viewer holds control. Release terminal control before
sending in chat. Commands beginning with `/`, shell mode beginning with `!`,
control characters, empty prompts, and prompts over 32 KiB are unavailable.

## Sessions and recovery

A browser link authorizes one selected agent through Astation for one hour.
Keep it private. Astation must stay running and authenticated with that host.
Pairing revocation or a replaced authenticated connection disables the link;
open a new link from Astation after reconnecting. A changed process generation
also requires a new native-authorized link.

Opening or reloading reads the host's latest 50 messages / 256 KiB of history.
**Load earlier messages** asks for an older page and preserves the reading
position. Atem retains at most 500 messages / 8 MiB per process. Whole messages
replace prior copies by stable ID, and repeated part IDs never duplicate content.
Remote prompt history reconciles the Sending bubble by request ID. Astation
also limits serialized message data, including IDs and part metadata, to 16 MiB.

**Reopen conversation** restores the view after a closed or interrupted stream.
It sends only an `open` request, never an earlier prompt. No prompt is retried
on timeout, reload, history paging, reconnect, or reauthentication. If delivery
is unknown, inspect the terminal. Sending remains disabled until authenticated
history resolves that request or a new session is authorized. Ready after a
reopen may permit more work after known delivery; it does not invent a completion
outcome for an earlier turn.

The link key stays in the URL fragment; requests and responses carry
direction-bound HMACs and fresh browser nonces. No transcript is stored in
localStorage or on the relay by this feature. Chat traffic is **not end-to-end
encrypted**: the relay can read it and the webapp serves the browser code.
Storage encryption does not encrypt this stream. The relay supplies transport;
Astation's authenticated endpoint session establishes device identity.

The webapp owns `/agent/` and its assets; the relay owns `/ws` and APIs. RTC
functionality lives in Stoa under `webapp/stoa/rtc/`. No new deployment variables
are required. The removed `/chat/` and `/session/` routes remain 404.

## Verification

```sh
python3 scripts/setup-terminal-assets.py --verify
swift test --filter 'BrowserAgentChatTests|RemoteTerminal'
node --test webapp/tests/agent-chat.test.mjs webapp/tests/agent-markdown.test.mjs
node webapp/tests/nginx.test.js
# Against a local webapp nginx (also runs in CI against the Docker image):
WEBAPP_TEST_ORIGIN=http://localhost:8080 node --test webapp/tests/hosting.test.mjs
```

The shared synthetic wire fixture in
`Tests/AstationTests/Fixtures/agent-chat-v1.json` uses the published host shapes
and runs through both Swift and browser state tests. It covers local/remote
prompts, history, text/tool parts, explicit outcomes, and late content. Security
checks cover MAC vectors, tampering/replay, exact routes, revocation races,
connection replacement, close without sequence headers, pre-session errors,
size limits, status freshness, generation changes, and unknown delivery.

Local validation (2026-10-14): Debug and Release builds, bundled-resource and
packaged-app checks, pinned terminal assets, 97 browser/automation tests, and
Chrome checks at 1440, 390 and 320 pixels pass. The signed mock bridge covers
reload/history without resending, duplicate parts, late content and tampering.
The available Swift run executes 802 tests with seven expected skips and no
failures after excluding six checks that cannot pass in this local environment:
five protected Keychain/Secure Enclave tests return macOS error `-25308`, and
one synthetic caption-scroll test fails identically on unchanged main. No CI
exclusions or product changes were added for those checks. Provisioned signing
alone did not resolve the local protected-Keychain restriction.

Live acceptance requires a harmless prompt through the exact selected,
authenticated original Claude process, an actual reply and completion, and a
reopen without prompt replay. Synthetic fixtures, signed mock bridges, previews,
and deployment checks do not establish this. Preserve existing user processes.
Current validation results and any remaining acceptance step are recorded in
shared Astation/Atem memory.

See the [protocol and security design](../designs/agent-chat.md).
