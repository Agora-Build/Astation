# Remote Agent Control — Astation side (v1)

Status: spec — 2026-05-28
Scope: **Astation (macOS) v1 only.** Mobile + screen-mirror are later phases.

> This spec is self-contained — you do not need the Atem repo to start. The
> Atem-side counterpart lives in the `Atem` repo at
> `designs/remote-agent-control.md`; this doc restates everything Astation
> needs and defines the wire contract both sides must match.

## What we're building (v1)

A user is running a coding agent (Claude Code / Codex) **under atem** on some
machine. atem owns that agent's terminal (PTY). We want Astation (this macOS
app) to act as a **remote control** that sends the agent input — **text**,
**voice**, or **control keys** — over the existing Astation↔atem channel
(direct or via the relay). atem injects that input into the agent's stdin.

**v1 is up-lane only.** Astation sends input; it does **not** mirror the
agent's screen. The user watches the agent's output in the terminal where atem
runs. (Screen mirroring is a later phase, for mobile, where there's no terminal
to look at.)

So v1 = "type/speak an instruction in Astation → it appears in the claude/codex
session running under atem on the target machine."

## Why this is small

The hard parts already exist in Astation:

- **Transport + targeting + relay envelope** — `AstationHubManager.sendHandler?(message, targetId)` is the universal send. For relay clients (`targetId == "relay-<atem_id>"`) it wraps the message with the Atem ID, the relay-assigned connection generation, and the payload; for direct clients it sends as-is. `routeToFocusedAtem()` picks the target Atem.
- **Voice** — `VoiceCodingManager` + `sendVoiceCommand(text:isFinal:)` already do mic → ConvoAI ASR → `voiceCommand` / `voiceRequest` → atem. **Reuse as-is.** No new voice work in v1.
- **Message plumbing** — `AstationMessage` (tagged `type`/`data` enum) with manual `Codable`. See CLAUDE.md → "Adding a New Message Type".

The genuinely new work is one message (`agentInput`) for **text + keys**, a send
method mirroring `sendVoiceCommand`, and a minimal UI to enter it.

## Wire contract (must match the Atem side exactly)

**Relay envelope** (already produced by `sendHandler` for relay clients; the relay
routes by `atem_id`):

```json
{ "atem_id": "<atem host id>", "connection_id": "<relay socket UUID>", "payload": <AstationMessage JSON> }
```

So **`atem_id` and `connection_id` are the envelope's job — do NOT put them inside the message payload.**
The `agentInput` payload carries only the agent selector + the input:

```json
{
  "type": "agentInput",
  "data": {
    "agentId": "<agent on that atem; optional in v1 — null/omitted = the atem's focused/only agent>",
    "kind": "text" | "key",
    "text": "refactor the auth module",          // when kind == "text"
    "key":  "enter|esc|ctrl-c|up|down|y|n"        // when kind == "key"
  }
}
```

- `kind:"text"` → atem writes `text` + `\n` to the agent PTY stdin.
- `kind:"key"` → atem writes the raw byte(s) for that key to the PTY
  (`enter`→`\r`, `esc`→`\x1b`, `ctrl-c`→`\x03`, `up`/`down`→CSI arrows, `y`/`n`→literal).

Voice does **not** use `agentInput` in v1 — it stays on the existing
`voiceCommand`/`voiceRequest` path (ConvoAI transcribes; the result reaches the
agent already). Folding voice into `agentInput` is a later cleanup, not v1.

## Astation implementation tasks (v1)

1. **Add the `agentInput` case to `AstationMessage`**
   - File: `Sources/Menubar/AstationMessage.swift`
   - Add `case agentInput(agentId: String?, kind: String, text: String?, key: String?)`
   - Add `agentInput` to the `MessageType` enum (raw value `"agentInput"`).
   - Implement `encode`/`decode` for it (nested `data` container with
     `agentId`, `kind`, `text`, `key`), following the existing cases. Encode
     omits nil fields (`encodeIfPresent`).
   - Follow CLAUDE.md → "Adding a New Message Type".

2. **Add a send method to `AstationHubManager`** (mirror `sendVoiceCommand`)
   - File: `Sources/Menubar/AstationHubManager.swift`
   - `func sendAgentText(_ text: String, agentId: String? = nil)`:
     ```swift
     guard let clientId = routeToFocusedAtem() else { Log.info("No Atem — dropped"); return }
     sendHandler?(.agentInput(agentId: agentId, kind: "text", text: text, key: nil), clientId)
     ```
   - `func sendAgentKey(_ key: String, agentId: String? = nil)`: same, `kind:"key", key:key, text:nil`.
   - `routeToFocusedAtem()` already returns the right `clientId` (relay or direct);
     the envelope wrapping is automatic.

3. **agent selection (`agentId`)**
   - v1 may leave `agentId = nil` (atem targets its focused/only agent).
   - If you want multi-agent now: Astation already has `agentListRequest` /
     `agentListResponse(agents:)` and `AtemAgentInfo`. Add a picker that sets a
     selected `agentId`; pass it into `sendAgentText/Key`. Otherwise defer.

4. **Minimal control UI**
   - A window/panel with: a **text field + Send** (calls `sendAgentText`), and a
     small **key bar** (Enter / Esc / Ctrl-C / ↑ / ↓ / y / n → `sendAgentKey`).
   - Wire the existing **mic** (PTT Ctrl+V / hands-free) as-is — it already sends
     voice. Optionally surface the focused-atem name so the user knows the target.
   - Keep it simple; this is a remote control, not a terminal.

5. **(No down-lane.)** Do not build screen mirroring in v1.

## Atem side (other repo — for awareness; do not implement here)

For the round-trip to work, the Atem side (`Atem` repo) must:
- Add a matching `AstationMessage::AgentInput { agent_id, kind, text, key }`
  (`#[serde(rename = "agentInput")]`, `data` fields matching the contract above).
- On receipt, resolve the target agent (focused/only in v1) and **write to its
  PTY stdin**: `kind:text` → `text` + `\n`; `kind:key` → the raw byte(s).
- Voice already handled via `pending_voice_request` / `voiceRequest`.

Reference: `Atem/designs/remote-agent-control.md`. (Note: that doc's `agentInput`
sketch put `atem_id` inside the message; the **authoritative** contract is here —
`atem_id` is the relay envelope, the payload carries `agentId` + input. The Atem
doc should be aligned.)

## Acceptance test

1. On a test machine, run atem and launch an agent under it (`atem agent launch`
   or the PTY claude/codex session atem manages).
2. Pair this Astation to that atem (direct on LAN, or via relay — the
   `wss://…/ws?role=astation&code=astation-<id>` identity room; atem joins with
   the same code).
3. In Astation, type "print working directory" → Send.
4. **Expect**: the text appears at the agent's prompt in atem's terminal and the
   agent acts on it.
5. Press **Ctrl-C** in the key bar while the agent is working → it interrupts.
6. Speak via PTT (Ctrl+V) → transcribed text reaches the agent (existing path).

## Build / test (macOS)

```bash
# C++ core (first time / after core changes)
cmake -S . -B build -DBUILD_TESTING=ON && cmake --build build -j

# Swift app
swift build                 # debug
swift build -c release      # release

# run tests
swift test
```

## Out of scope (later phases)

- Screen/TUI mirror (down lane) — mobile only; cell-grid diffs, transport
  decision (relay upgrade vs RTC data channel). See the Atem design doc.
- Multiple simultaneous Astations per relay room (relay currently allows one
  `astation_tx` per room).
- Folding voice into the unified `agentInput` path.
