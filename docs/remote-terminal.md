# Remote terminal control

Control the original Claude Code or Codex process running on an authenticated
Atem, and see its responses in Astation. Opening a view preserves the existing
conversation and unfinished input.

## Start a session

This development branch requires an Atem host implementing
[atem-session v1 r7.1](../designs/protocol/atem-session-v1.md), in addition to
shared-terminal rendering. Earlier terminal-only hosts cannot provide control
through this build. Use the pinned runtime host in
[Atem PR #72](https://github.com/Agora-Build/Atem/pull/72); the published pairing
fixes alone do not imply session-protocol support. See the
[integration status](../designs/protocol/atem-implementation-handoff.md).

Use the same host binary for pairing and launch; see the
[pinned host handoff](../designs/protocol/atem-host-handoff.md) for build and
run instructions. On the serving machine:

```sh
atem agent launch claude
atem agent launch codex
```

Agent options can follow the provider, for example
`atem agent launch codex --profile oss`. Pair/authenticate Atem with Astation
as usual, then run `atem pair verify` if it is not already verified. Local agent
launch does not require pairing; remote viewing and control do. The chooser
addresses each original session separately.

## Open and control

1. Open **Tools > Connections > Clients & Agents** and select the online host.
2. Click **Open Terminal** on its agent, or **Terminals** in the panel header.
3. Select a session. **View** opens its current screen without taking control.
4. Click **Take Control** to type, paste, send Enter/Escape/Ctrl-C or operate
   the original CLI's approval prompts.
5. **Release** restores local input ownership. Closing the window detaches
   the viewer and leaves the agent running. **Stop Agent** requires confirmation
   and ends that selected original process.

Control expires after 15 seconds without renewal; Astation renews every five
seconds. Local input on the host takes priority and revokes remote control.
The Astation view then becomes read-only. Reconnecting always opens a fresh view
and requires another deliberate Take Control. A replacement process generation
requires choosing View again.

Command-C copies the terminal selection and Command-A selects the visible
screen. Command-V, the standard Edit menu and the terminal's right-click menu
paste once into the focused input, preserving multiline text and the CLI's
bracketed-paste mode. Ordinary paste does not submit. When the native prompt
field has focus, its normal clipboard actions edit that field.

**Paste & Go** explicitly pastes the clipboard into the selected remote
terminal and sends Enter, even when the native prompt field has focus. It
requires control and sends text, bracketed-paste framing and the final Enter
in one guarded write. Empty, oversized, stale or disabled pastes send nothing,
including no stray Enter. The toolbar has no separate Copy or Paste buttons.
Ctrl-C continues to mean interrupt. The maximum single input is 16 KiB,
including bracketed-paste framing and, for Paste & Go, the final Enter.

Only the active controller resizes the remote PTY. A viewing window preserves
the host dimensions and scrolls/clips a screen larger than its viewport.

### Scrolling and tmux

Scrolling a terminal application's own UI requires Take Control and the
application's terminal mouse support. With tmux's default bindings, hold Ctrl
and press B, release both, then press `[` to enter copy mode. This sequence is
forwarded as Control-B followed by a literal bracket; it is not three separate
key presses. Astation does not automatically insert tmux shortcuts when scrolling.

The shared terminal is the original agent PTY, not Atem's outer frontend or
the tmux pane containing Atem. If tmux wraps Atem, input to the shared agent
bypasses that outer tmux, so its copy-mode shortcut cannot access the pane's
history. A tmux instance inside the shared PTY can receive the shortcut.
Access to outer tmux or Atem frontend history needs host support; forwarding
more key sequences cannot expose that history in the current stream.

## Status and recovery

The prompt field sends a scoped submission to the selected session. Voice text,
the scoped interrupt shortcut and Stop Agent use the same authority and durable
receipt lifecycle. The receipt label distinguishes accepted, executing,
completed, rejected and outcome unknown. Disconnect never replays a prompt;
reconnect queries its original request ID. Inspect the agent before manually
trying again when the outcome is unknown. Closing the window releases control
while Astation continues receipt recovery.

**Written to terminal** confirms a PTY write; it does not mean the agent has
accepted a prompt or finished a response. Watch its live output for those states.
If an acknowledgment is lost or times out, the outcome is unknown. Astation
does not retry typing. Open a fresh View, inspect the screen, then decide whether
to take control and submit something again.

Refresh requests the shared session-v1 registry. Connections and terminal
windows reuse one client, so opening a window never sends a second hello. A missing response can mean an old
Atem build or a connection problem. No shared terminals means the host must
launch an agent through Atem. Unsupported versions/width profiles, malformed
frames and restore failures disable input and show an actionable status.
Removing the pairing disables terminal access; direct sockets authenticated
by that pairing close as well.

**Paired offline** means the pairing is saved but Astation has no authenticated
connection for that device. The Atem process and its local agent may still be
running. A live relay socket alone does not make the device online.

When Astation alone reconnects, it requests a fresh endpoint proof from the
relay's restored connections. Atem must handle that challenge on its existing
socket and discard previous remote streams and control leases before resuming.
Older Atem builds that ignore late authentication challenges can leave a running
Atem paired offline. That companion fix is coordinated with the Atem owner
through shared project memory. On 2026-10-14 at 17:17 PDT, the running Genie host
answered a fresh challenge and authenticated after Astation restarted. The new runtime owns independent workers, which survive its restart; preserve
active conversations while arranging host updates with the Atem owner.

## Rendering and privacy

The first protocol shares canonical visible-screen ANSI updates, preserving
colors, cursor and supported terminal modes. It provides no remote scrollback
or complete conversation history. The zero-scrollback renderer avoids presenting
incidental repaint scrolls as a transcript. Claude advertises `chat-v1`, which
allows durable prompt submissions; Codex currently accepts terminal input only.
Astation disables the prompt field for terminal-only sessions. Browser access
is disabled pending secure section 9 companion grants, regardless of whether
hello has started. There is no older browser bridge fallback.

xterm 6.0.0, addon-fit 0.11.0 and Atem's matching Unicode-width provider are
bundled locally. The viewer loads no CDN, permits no external navigation and
passes agent output as bytes rather than HTML. Copy/paste require user actions;
agent terminal output cannot request the native clipboard. Terminal input/output
is redacted from network debug logs and is not saved by this feature.

Transport uses the existing authenticated LAN/relay connection. Storage E2EE
does not make the terminal stream end-to-end encrypted. The relay routes
selected-host envelopes; endpoint pairing remains authoritative for device
identity and access.

## Verification

```sh
python3 scripts/setup-terminal-assets.py --verify
swift test --filter 'AtemSession|RemoteTerminal|AgentInputRouting|BrowserAgentChat'
```

Tests cover the serde-compatible wire format, real WebKit rendering and
bracketed paste, renderer credit and queue bounds, connection/process/stream
isolation, control revocation, unknown write outcomes, reconnects and pairing
revocation races. The full resource check also verifies that packaged apps
contain the viewer assets. Live provider tests must use independently owned
test sessions, preserving the user's active conversation.

The [current validation matrix](../designs/protocol/session-validation.md)
records passing native checks and confirmed Genie integration separately from
remaining physical terminal, IME/clipboard and real-provider approval checks.
WebKit regressions cover single-dispatch Command-V and native Edit/context-menu
paste, bracketed Paste & Go, and rejection without a stray Enter. They do not
replace the physical Cmd+V check against Claude's live input.

See [lifecycle and security invariants](../designs/remote-terminal.md) and
[Atem's current host handoff](../designs/protocol/atem-host-handoff.md).
