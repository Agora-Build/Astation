# Stoa and Agent

The webapp image hosts two browser apps. **Stoa** handles voice, video and screen
sharing. **Agent** provides chat with remote code agents. The root page links to
both apps. Nginx serves their UI; the relay handles `/api/*`, authentication and
`/ws` transport.

```text
webapp/
  index.html              App chooser
  index.css
  stoa/                   Complete meeting and sharing app
    index.html            Start page and RTC session UI
    style.css
    app.mjs               Page controller and controls
    session-link.mjs      Stoa share-link parsing
    rtc/                  Channel, codec and screen-sharing implementation
  agent/                  Agent chat app, styles and conversation state
  tests/                  Media, conversation, routing and hosting checks
```

Stoa is intended to move to the **Stoa** subdomain/space within agora.build.
The complete app is isolated in `webapp/stoa/` for that move. This change configures
`https://station.agora.build/stoa/` after deployment; the final agora.build destination has not
been deployed as part of this change. See [Stoa setup and migration](../docs/stoa.md).

The app's RTC modules take the Agora SDK/client as arguments and do not depend
on either app's DOM. Agent can import those implementations when adding media
controls. Keep page rendering in each app's controller and reuse RTC behavior
from `stoa/rtc/` rather than copying it.

Screen sharing allocates a separate server UID and matching token, preserves
captured source dimensions, requests 60 fps and supports optional source audio.
Start from a user gesture so the browser can open its picker. Stop closes tracks
and leaves the screen client, including when sharing ends from browser controls.
See [screen sharing](../docs/screen-sharing.md).

Agent authorization grants access to one selected code agent. Stoa participation
uses a separate RTC session and credentials from `/api/rtc-sessions/*`; an Agent
link never grants RTC access. Agent currently uses the agent protocol, with
camera/microphone access disabled by its Permissions Policy.

Nginx serves `.mjs` as JavaScript and returns 404 for missing app assets. Canonical
app routes are `/stoa/` and `/agent/`. Share links use `/stoa/session/<id>`.
The earlier `/session/...` and `/chat/...` routes are removed and return 404;
companion Astation browser links must use `/agent/`.

See [testing](TESTING.md), [Agent](../docs/agent-chat.md) and
[deployment](../DEPLOY.md) for local setup and production validation.
