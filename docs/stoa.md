# Stoa

Stoa is the agora.build app for voice, video and screen sharing. Its complete
browser source is `webapp/stoa/`, including the UI, page controller and reusable
RTC implementation. Agent chat is a separate app under `webapp/agent/`.

## Hosting in this change

After deployment, open `https://station.agora.build/stoa/` and paste a session
link or ID created by Astation. Joining still asks for your name and whether to enable your
microphone. Screen capture, optional source audio, microphone state and the
1:1 received-video view keep their existing behavior. See
[screen-sharing controls and limits](screen-sharing.md).

RTC session responses use `/stoa/session/<id>`. Stoa's start page accepts these
links or a session ID. The old `/session/<id>` route is removed; generate a new
share link from Astation. Opening the start page does not join a channel or
request microphone/screen access.

## Future agora.build destination

The product name and future subdomain/space are **Stoa**. The app is currently
packaged with Astation's webapp so it can be reviewed and tested before the
agora.build destination is available. DNS, the final hostname/path and the
destination's deployment are separate from this source move.

When connecting the new destination:

1. Move or package the entire `webapp/stoa/` app together, including its RTC
   modules. Keep the `/stoa/` asset/session paths reachable or update the app's
   paths and routing together if the destination mounts it at its root.
2. Provide same-origin `/api/rtc-sessions/*` proxying to the trusted relay. Keep
   the relay's public base URL configured for a hostname that serves the Stoa
   routes; existing links must remain reachable throughout migration.
3. Retain HTTPS and the current session authorization, UID/token allocation and
   microphone/screen consent. A new hostname changes browser permission scope.
4. Verify start, join, receive, microphone, optional screen audio, source
   resolution, browser Stop and Stoa links before changing the public origin.

Agent can reuse Stoa's DOM-independent RTC modules when media controls are
added. RTC credentials and the signed Agent capability remain separate trust
boundaries. The relay routes requests; it does not authorize an agent or make
encryption-state decisions.
