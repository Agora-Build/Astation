# Remote terminal control

This implementation consumes `terminal-v1` through Atem's session r7.1
contract, pinned to PR #72 at `6edda2490f4a4b7634edb446f64aa02748e29fa2`.
It attaches to the original Claude/Codex PTY; opening a window does not start
an agent or create another conversation. See the
[current host handoff](protocol/atem-implementation-handoff.md).

## Lifecycle and security invariants

- A window addresses one authenticated Atem connection and one process
  generation. Relay envelopes bind both `atem_id` and `connection_id`.
  Terminal traffic is never broadcast or routed by terminal focus.
- Subscribe always starts view-only. Typing, resizing and Stop require an
  explicitly acquired lease. Release, local reclaim, disconnect, window close
  and process exit disable input. Reconnect never restores a lease or retries
  uncertain input.
- A stream has its own byte offset and input sequence. Stale connections,
  processes, streams, renderer callbacks and leases cannot affect its successor.
  Input sequence numbers continue across control changes within a stream.
- `written` means bytes reached the PTY, not prompt acceptance or turn
  completion. A missing acknowledgment is an unknown outcome. Errors and
  timeouts are visible and require a fresh view before further control.
- Frames are canonical ANSI screen updates, not original PTY output or a chat
  transcript. The first restore begins with reset at offset zero. Gaps and
  malformed frames require a new subscription. Credit is returned only after
  xterm's write-completion callback consumes each frame.
- Frame, input and restore bounds match the host. Slow rendering retains at
  most one host credit window. Terminal content stays out of network debug
  logs. The viewer has no transcript recorder or remote scrollback.
- The renderer loads pinned local assets with a restrictive content security
  policy. Remote content is passed only as base64 bytes to xterm, never HTML
  or executable JavaScript. Navigation and unsolicited clipboard access are
  blocked. Copy and paste are explicit user actions.
- Existing endpoint authentication remains authoritative. Relay routing
  metadata does not establish a new device identity, release encryption keys
  or alter encryption state. Terminal transport uses the existing authenticated
  connection; storage E2EE does not imply terminal-content E2EE.
- A relay `connected` event starts a fresh endpoint challenge when that
  connection is unauthenticated, including after Astation alone reconnects.
  It never marks the device online. A racing `hello` reuses the pending
  challenge so an in-flight proof stays valid. Atem must handle a challenge
  received on an already open socket and revoke old terminal ownership while
  reauthenticating; socket liveness alone does not prove an endpoint session.

## Desktop interaction

Connections opens a resizable Remote Terminal window for the selected host.
The session chooser lists Claude/Codex process generations and final screens.
Selecting a different session releases the previous control lease and opens
the selected screen in viewing mode. Late attachments and frames from the
previous session cannot replace it. View retries the selected screen without
taking control. Take Control enables normal terminal
typing, IME, paste and control keys. Release restores local ownership. Stop
asks for confirmation before stopping that selected original process.

The viewport follows the host's canonical dimensions. Only the active remote
controller can resize the PTY to fit its window. View-only windows clip/scroll
an oversized screen without changing the host. Standard Edit actions,
Command-C/Command-V and a right-click Copy/Paste/Select All menu follow focus.
The terminal key handler cancels WebKit's default clipboard action as well as
xterm's handling, preventing one physical shortcut from requesting two pastes.
Ctrl-C remains a terminal interrupt.

The toolbar exposes Paste & Go instead of separate Copy and Paste buttons.
It explicitly targets the selected terminal, preserves bracketed paste and
adds Enter outside its markers in the same guarded write. Ownership epoch and
size checks apply to the entire write, including Enter. Rejected or empty
clipboard data cannot send an Enter, and losing control fences an already-open
clipboard menu. Ordinary paste never adds Enter.

Keyboard combinations are forwarded as terminal bytes only while controlling.
In particular, tmux's default Control-B then `[` sequence remains two inputs;
the viewer must not synthesize it in response to a wheel event or assume a
particular multiplexer prefix. A tmux wrapper outside Atem is not in the
shared agent PTY's input route. Its copy mode and history require host support
and cannot be reached by sending its shortcut directly to the agent.

The bundled xterm version is 6.0.0, with zero incidental scrollback and Atem's
`atem-unicode-width-0.1.14` provider. `Config/terminal-assets.json` records
upstream versions, archive integrity and individual asset hashes. Run
`python3 scripts/setup-terminal-assets.py --verify` to verify checked-in assets.

## Acceptance

Automated checks cover wire compatibility, selected-host routing, split UTF-8,
renderer credit, bounded queues, stale generations, ownership changes, input
acknowledgments, disconnect/reconnect, process exit and asset integrity.
Native WebKit checks exercise actual xterm rendering, selection and paste.
Synthesized keyboard events verify Control-B followed by `[` and the view-only
input gate; they do not verify physical keyboard delivery or a live tmux pane.
Live tests must use a separately owned test session, never inject prompts or
approvals into the user's existing agent. Cross-machine relay/LAN, physical
IME/clipboard, real provider approvals and latency validation are recorded
separately from synthetic protocol tests.

## Attachment composer follow-up

[GitHub issue #51](https://github.com/Agora-Build/Astation/issues/51) tracks
images, audio, PDFs and other file attachments in the separate prompt composer.
Plain text duplicates the original terminal input; previews, transfer progress
and provider-supported attachments would give the composer a distinct purpose.
Transfers must bind to the selected verified Atem/session and define provider
capabilities, limits, remote staging and cleanup with the Atem owner. Raw file
bytes must not be sent through PTY paste. This is a planned follow-up, separate
from the clipboard change.
