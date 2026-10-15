# Astation webapp

This image owns browser UI for RTC sessions and remote-agent chat. Nginx serves
the pages and shared assets; the relay handles `/api/*`, authentication and `/ws`.

```text
webapp/
  index.html              RTC session view, served at /session/<id>
  css/style.css           RTC session styles
  js/app.mjs              RTC page controller and DOM updates
  chat/                   Agent chat view, styles, controller and protocol state
  lib/media/
    channel.mjs           Channel join/fallback, subscriptions, mic publishing
    codec.mjs             Common codec policy
    screen-share.mjs      Separate screen client, optional audio and cleanup
  tests/                  Media, chat, routing and nginx integration checks
```

The media library uses standard ES modules and accepts the Agora SDK/client
as an argument. Its modules do not access a page's DOM or automatically request media
permissions. The existing RTC page imports them; new media controls in chat can
import the same implementations. Keep UI state and rendering in page controllers,
and keep SDK behavior in the shared layer rather than copying it between pages.

Screen sharing uses its own server-allocated UID and matching token, preserves
the captured source dimensions, requests 60 fps and supports optional source
audio. Start it directly from a user gesture so the browser can open its picker.
Stop closes local tracks and leaves the screen client, including when the user
ends sharing from the browser. See [screen sharing](../docs/screen-sharing.md).

Chat authorization grants access to one selected agent. RTC participation uses
a separate session and credentials from `/api/rtc-sessions/*`; a chat link must
never be converted into RTC authorization. Adding media to chat requires an
explicit RTC session and user action. The chat page currently uses only the
agent protocol, with microphone/camera access disabled by its Permissions Policy.

The webapp Dockerfile packages both pages together, including shared modules.
Nginx preserves `/chat?preview=1` when redirecting to `/chat/`, serves `.mjs` as
JavaScript and returns 404 for missing chat assets. It serves `/session/*` using
the existing RTC view and proxies `/ws` and APIs to the configured relay.

See [testing](TESTING.md), [agent chat](../docs/agent-chat.md) and
[deployment](../DEPLOY.md) for local setup and production validation.
