# Astation

macOS menubar hub that coordinates between [Chisel](https://github.com/Agora-Build/chisel), [Atem](https://github.com/Agora-Build/Atem), and AI agents. Receives annotation tasks from the browser, routes them to the right Atem instance, tracks task status, and relays voice-coding sessions -- talk to your coding agent from anywhere.

## Install

Download the `.pkg` installer from [Releases](https://github.com/Agora-Build/Astation/releases), or build from source.

### Build from source

Prerequisites: macOS 14+, Xcode Command Line Tools, CMake.

```bash
git clone git@github.com:Agora-Build/Astation.git
cd Astation

# 1. Build the C++ core library (CMake auto-downloads Agora SDK from SPM distribution)
mkdir -p build && cd build
cmake .. -DBUILD_TESTING=ON
make -j$(sysctl -n hw.ncpu)
cd ..

# 2. Build the Swift app (SPM auto-downloads Agora frameworks)
swift build -c release

# Binary at .build/release/astation
```

**What happens during build:**
- CMake detects missing Agora SDK and downloads 7 xcframeworks from `https://download.agora.io/swiftpm/AgoraRtcEngine_macOS/4.7.0/`
- CMake and Swift Package Manager use the same Agora SDK version (4.7.0).
- No manual SDK downloads needed!

**Troubleshooting:**
- If CMake fails with "SDK not found": Run `cmake ..` again to retry download
- If SPM fails: Try `swift package resolve --force-resolution`
- Clean build: `rm -rf build third_party/agora .build && swift build`

**Offline / pre-downloaded SDK**
- Skip auto-download and use a local SDK root:
  `cmake -S . -B build -DAGORA_SKIP_DOWNLOAD=ON -DAGORA_SDK_DIR=/path/to/sdk`
- Expected layout:
  `/path/to/sdk/rtc_mac/<Framework>.xcframework/...`

**Linux/Windows builds:**
- C++ core only (no Swift app on these platforms)
- CMake does NOT auto-download on Linux/Windows
- Download SDK manually:
  - Linux: https://docs.agora.io/en/sdks?platform=linux → extract to `third_party/agora/rtc_linux/`
  - Windows: https://docs.agora.io/en/sdks?platform=windows → extract to `third_party/agora/rtc_win/`

## How It Works

Astation runs as a macOS menubar app with direct and relay WebSocket transports. Multiple Atem instances can use loopback, LAN, and relay connections concurrently, and the hub routes work to the focused (or first available) authenticated Atem.

### Atem Connections

| Atem location | Transport | First connection | Offline behavior |
|---------------|-----------|------------------|------------------|
| Same Mac | `ws://127.0.0.1:8080/ws` | Transparent same-user proof | Works with all radios disabled |
| Another LAN machine | `ws://<astation-ip>:8080/ws` | User-approved pairing | Works without internet or relay |
| Remote network | Public `wss://` relay | User-approved pairing | Requires internet and relay |

Loopback is identified from the socket peer address, not from a client-supplied header. LAN and relay clients receive a random challenge and must prove possession of their saved session token with HMAC-SHA256 before Astation registers the client or sends credentials.

Direct LAN transport is currently plaintext WebSocket. The authentication protocol prevents session-ID-only impersonation, but LAN deployment is not production-ready until WSS certificate pinning is implemented. See [`docs/specs/2026-07-21-device-authentication-v2.md`](docs/specs/2026-07-21-device-authentication-v2.md).

### Android Device Sharing

Build an Android app on your **development machine** and use a phone connected to
the **Mac running Astation**. The development machine must be able to reach the
Mac's selected IPv4 address and sharing port. Tailscale, NetBird, ZeroTier, other
VPNs, and reachable local networks can provide that connection; Astation has no
VPN-provider dependency. IPv6-only connections are not supported yet.

The phone connects to the Mac by USB or Android wireless debugging.

1. Install Android SDK Platform-Tools on both computers. Use matching
   Platform-Tools across different machines.
2. On the Mac, open Astation's **Connections > Android Devices** tab. Astation finds ADB
   in common SDK/Homebrew locations, or use **Choose ADB** to select it.
3. Connect and authorize the phone. For USB, enable USB debugging and accept the
   authorization prompt on the unlocked phone.
4. Select **this Mac's IPv4 address** on the network your development machine can
   reach. Set a sharing port between **1024 and 65535**: **5038 is only the
   default**; your edited port is saved.
5. Allow only trusted development machines to reach that port through your VPN or
   firewall rules, then click **Start Sharing**. Copy the shell setup to a terminal
   on your development machine.

For example, with the Mac at `100.80.1.2` and a chosen sharing port of `6107`, run
these commands on your development machine:

```bash
export ADB_SERVER_SOCKET=tcp:100.80.1.2:6107
adb devices -l
adb -s <device-serial> install -r ./app-debug.apk
adb -s <device-serial> shell am start -n <package>/<activity>
adb -s <device-serial> logcat

# Return this terminal to its default local ADB server.
unset ADB_SERVER_SOCKET
```

For a single command, use `adb -H 100.80.1.2 -P 6107 devices -l`. Do not use
`adb connect` with Astation's sharing address: it is a remote **ADB server**,
not a phone's device-side endpoint.

Astation binds only the selected IPv4 address and forwards to the Mac's local ADB server
at `127.0.0.1:5037`. Sharing exposes **all devices and emulators** on that server,
including server-level ADB commands. This TCP endpoint does not use Atem pairing
or provide its own client authentication or encryption. Use a trusted network or
a VPN that provides encryption and peer access control. The interface list shows
assigned addresses; it does not identify VPN providers or configure their rules.

**Stop Sharing** and app quit close remote connections while leaving local ADB
running. Sharing starts off after each app launch. If the selected interface
address disappears, sharing stops without falling back to another interface.
An occupied sharing port produces an error; choose a different port and update
the development machine's command and relevant network rules. If local ADB is unavailable, use **Retry** after
resolving the error. Protocol version conflicts are reported instead of silently
restarting an existing ADB server.

**Wireless:** choose **Connect Wireless Phone**. On Android 11+, open Wireless
debugging and choose **Pair device with pairing code**. Enter that pairing
IPv4/port and code, then separately enter the debugging IPv4/port from the main
Wireless debugging screen. These ports may differ. For an already-paired phone,
disable **Pair this phone first**. The Mac must be able to reach the phone over
Wi-Fi; the development machine continues using the Mac's sharing address and
does not need a direct route to the phone. The device serial can change when switching
from USB to wireless, so select the new serial from `adb devices -l`.

Command-line APK installation, shell, file transfers, and logcat use this remote
server arrangement directly. For **scrcpy without SSH**, add a mapping under
**Forwarded Ports (scrcpy)** before starting sharing. The default suggestion is
shared port **27183** to local port **27183**. Start sharing, then choose
**Copy scrcpy Command** beside an authorized device and select its port mapping.
Run the copied command on the development machine, where scrcpy must be installed.
Both the ADB sharing port and the shared scrcpy port must be reachable.

For example, with ADB sharing on `100.80.1.2:6107` and a mapping from shared port
`31000` to local port `27183`, the command is:

```bash
ADB_SERVER_SOCKET='tcp:100.80.1.2:6107' scrcpy --serial 'DEVICE_SERIAL' \
  --force-adb-forward --port=27183 \
  --tunnel-host=100.80.1.2 --tunnel-port=31000
```

Mappings are saved but remain off until **Start Sharing**. All configured ports
start together; a conflict rolls back the start. **Stop Sharing**, app quit, or
loss of the selected network address closes all shared listeners and streams.
Use separate local ports for simultaneous scrcpy sessions. Full Android Studio
Run/Debug support still requires validation: forwarded debugger ports can use
these mappings, but `adb reverse` destinations are still on the Mac and may need
additional tunnels to reach the development machine. Real phone/network validation
is separate from the automated local TCP tests.

See the [Android sharing guide](docs/android-device-sharing.md)
for architecture, lifecycle behavior, and remaining hardware checks.

### Keyboard Shortcuts

Open **Settings > Keyboard Shortcuts** to bind keys for push-to-talk dictation and
RTC screen sharing. Click a binding, press a combination, and release the key to save.
Use Control, Option, or Command with a key, or a function key (F1-F20). Press
Escape or click **Cancel Recording** to cancel. Shortcuts pause during recording
and resume when you finish, switch tabs, close settings, or switch windows.

Bindings apply immediately and persist across launches. **Clear** removes a
binding; **Restore Defaults** restores **Ctrl+V** for dictation and **Ctrl+Shift+V**
for RTC screen sharing. Hold the dictation shortcut to speak and release it to
finish; the screen-sharing shortcut toggles the primary display in a joined RTC
channel, not the camera. Screen-sharing controls and the current binding appear
under **RTC Media** in the menu.

Astation rejects duplicate bindings, conflicts with its menu commands, enabled
macOS keyboard shortcuts, and combinations already registered by another app.
An unsuccessful change keeps your previous bindings. **Check Conflicts** rechecks
saved bindings and retries unavailable shortcuts after you free them elsewhere.
Other apps' local menu shortcuts and shortcuts intercepted by keyboard-remapping
tools cannot all be detected.

### Mark Task Routing

When a user draws annotations in [Chisel](https://github.com/Agora-Build/chisel) and clicks "Ask Agent to Work on It":

```
Chisel (browser)
  ↓ POST /api/dev/save-mark
Express middleware (saves .chisel/tasks/{id}.json + .png)
  ↓ WS markTaskNotify {taskId, status, description}
Astation hub
  ↓ picks target Atem (focused > first available)
  ↓ WS markTaskAssignment {taskId}
Atem
  ↓ reads task from local disk
  ↓ spawns Claude Code with prompt
  ↓ WS markTaskResult {taskId, success, message}
Astation hub
  ↓ updates task tracker
```

Messages carry only IDs, status, and descriptions -- no images or file lists flow through Astation.

### WebSocket Protocol

| Message | Direction | Purpose |
|---------|-----------|---------|
| `markTaskNotify` | Chisel -> Astation | New task available (with summary for display) |
| `markTaskAssignment` | Astation -> Atem | Route task to a specific Atem |
| `markTaskResult` | Atem -> Astation | Report task completion/failure |
| `statusUpdate` | Astation <-> Atem | Authentication challenge, proof, and connection status |
| `heartbeat` / `pong` | Atem <-> Astation | Keep-alive |
| `voice_toggle` | Astation -> Atem | Voice input state |
| `agentInput` | Astation -> Atem | Text or control-key input for a selected agent |
| `video_toggle` | Astation -> Atem | Video state |
| `atem_instance_list` | Astation -> Atem | Broadcast connected peers |
| `auth_request` / `auth_response` | Atem <-> Astation | Legacy browser/deep-link grant flow |

### Device Authentication

1. Astation sends `auth_required` with its identity, connection scope, protocol version, and a fresh challenge.
2. Same-Mac Atems prove access to the `0600` bootstrap secret without an interactive prompt.
3. Paired LAN and relay Atems send `session_id`, `atem_id`, and an HMAC proof. The session token itself is never sent during reconnect.
4. An unknown device displays an eight-digit code and waits for explicit approval in Astation.
5. Astation processes application messages and sends account credentials only after authentication succeeds.

### Remote Agent Control

Open **Connections > Clients & Agents**, select a connected Atem and an agent,
and open its remote-control window to send text or control keys. Input goes to
the selected client and agent; the agent's output remains in its Atem terminal.
The `agentInput` payload contains `agentId`, `kind` (`text` or `key`), and the
corresponding `text` or `key` field. Relay routing identifiers belong to the
transport envelope. Voice continues through the existing voice-coding flow.

### Local Audio Recording

Open **Settings > Audio & Recording** to select a microphone, selected
applications, or all system audio. A microphone can accompany either output
mode. Application capture records all associated audio, including browser tabs.
System mode excludes Astation's own playback.
System and application capture require macOS 14.2 or later; microphone capture
works on macOS 14.

Use **Start Preview** to check each source's real waveform, RMS/peak levels, and
clipping indicator before recording. Preview is visual only and creates no files.
Closing the page stops preview, but an active recording continues with a red
menu-bar indicator. **Pause** keeps preview live while excluding paused audio
from the recording.

Recordings are local, separate original Float PCM tracks in CAF or WAV. Choose
the output folder and 15/30/60 minute file splitting. Each session includes a
`session.json` manifest describing native formats, timing gaps, dropped frames,
and completion or failure. Use **Show Recording** to open the session folder.
No Agora account, RTC channel, SoX, or virtual audio device is needed.

Start/stop and pause/resume shortcuts can be bound in **Keyboard Shortcuts**;
they start unbound and use the same conflict checks as voice/video shortcuts.
Filters, AI noise removal, a virtual microphone, and an OBS filter are later
milestones; originals are currently saved without Astation processing.

See [audio recording validation](docs/audio-recording.md) for native capture
checks and the [implementation plan](docs/plans/2026-10-03-audio-recording.md).

### Live Transcription

**Settings > Live Transcription** is a standalone page with three downloadable
on-device models: Parakeet EOU (low-latency English, about 224 MB), Whisper large-v3
Turbo (faster multilingual, 1.64 GB), and full Whisper large-v3 (accuracy-oriented,
3.09 GB). Switch models in settings; these labels describe tradeoffs, not
guaranteed benchmark rankings.
Enable sources in **Audio & Recording**, then check mic, system audio, or one or
more selected apps for transcription. Mic can run alongside system audio or apps;
all-system and selected-app capture are alternative modes. Download the model
once, then transcribe offline with separate labeled captions per source.
Each source uses additional processing and memory. Original tracks are unchanged.

Record without captions, transcribe without saving audio, or run both together.
Their Start/Stop controls are independent: stopping one leaves the other running.

Floating captions support multiple lines and a rolling **20-second** history.
Drag the window anywhere, including an external monitor; updates keep its position
without stealing keyboard focus. Turn floating captions on or off in settings.
New speech restores the toast after automatic timeout. After Hide, use
**Show Floating Captions** in the Astation menu or settings. Bind **Toggle Floating
Captions** in **Keyboard Shortcuts** for global show/hide control (unbound by default).
Copy or save the session transcript as TXT or JSON. Optional auto-save keeps
finalized TXT and live JSONL history in `~/Documents/Astation/Transcripts`,
independently of audio recording.

For other languages or live translation, choose **Agora cloud** and explicitly
approve sending the checked sources to Agora. This uses the signed-in project
with Real-Time STT enabled; each source starts a separate potentially billed
cloud session. **Custom - OpenAI-compatible HTTP** supports your own full
`/v1/audio/transcriptions` endpoint, model name, optional Keychain API key, and
5/10/15-second speech upload windows. Remote modes require explicit audio-upload
consent. See the
[transcription guide](docs/live-transcription.md) for privacy, model mirrors,
publishing, and validation details.

### Voice Dictation

**Settings > Voice Dictation** configures local-microphone push-to-talk and Hands-Free
dictation, independently of RTC. It uses the installed local ASR profile selected
in Live Transcription. Mic transcription disables both dictation modes; system/app-only
transcription can run alongside them.

The **Polish** dial in settings and floating captions optionally adds an ASR-to-LLM
editing step. Choose Apple on-device, local Qwen through Ollama/llama.cpp, OpenAI
cloud, or a custom OpenAI-compatible endpoint. Polishing defaults off; remote text
uploads require endpoint-specific consent and API keys stay in Keychain. Local
Qwen requires a separately installed runtime/model; there is no silent cloud fallback.

Choose independent outputs: typing into the original active text field (default on,
Accessibility permission required; no Return/key/clipboard injection) and sending
to the active connected Atem (default off). Enable both to use the same result in
both places, or turn both off for captions only. Results always remain in floating
captions. If an output becomes unavailable, the other still works; polishing failure
keeps raw text local without typing or sending it. See the
[dictation guide](docs/live-transcription.md#voice-dictation-and-optional-llm-polishing).

RTC and local recording/dictation share native microphone capture by device but
use separate branches. RTC join/leave and mute gate publishing, not local capture;
Agora audio processing is enabled on RTC's custom track, while original recordings
stay unprocessed. Release RTC Microphone explicitly to relinquish its capture lease.

## Architecture

See the [architecture and feature guides](docs/README.md) for Android sharing,
SSO authentication, Vault storage, and the device-authentication protocol.

```
Sources/
  CStationCore/           # C shim for Swift-to-C++ bridge
  Menubar/
    main.swift             # App entry point
    AstationApp.swift      # App lifecycle, wiring handlers
    AstationHubManager.swift   # Business logic, task tracking, routing
    AstationMessage.swift      # Codable message types (encode/decode)
    AstationWebSocketServer.swift  # NIO WebSocket server
    AuthGrantController.swift  # Auth request approval flow
    SsoSessionStore.swift      # AES-GCM encrypted SSO session storage
    SsoAuthManager.swift       # Browser login with OAuth 2.0 + PKCE
    SsoTokenProvider.swift     # Lazy access-token refresh
    AgoraAPIClient.swift       # Agora REST API integration
    RTCManager.swift           # Agora RTC audio management
    HotkeyManager.swift        # Configurable global voice/video shortcuts
    StatusBarController.swift  # macOS menubar UI
core/
  src/astation_core.cpp    # C++ core (session management)
  src/astation_rtc.cpp     # RTC audio processing
  include/                 # C headers
relay-server/
  src/main.rs              # Rust relay and HTTP API server
  src/vault_routes.rs      # Vault API handlers
  src/vault_store.rs       # Postgres/in-memory Vault storage
  migrations/              # Postgres schema migrations
```

### Dependencies

- **Swift Package Manager**: WebSocketKit, SwiftNIO, AgoraRtcEngine_macOS (auto-downloaded)
- **C++ Core**: CMake, Agora RTC SDK (auto-downloaded from SPM distribution on macOS)
- **Rust Server**: Axum, Tokio

## Configuration

Sign in through Astation's menu or Settings. The app opens a browser for OAuth
2.0 + PKCE login and receives the callback on a local loopback listener. Its SSO
session is stored in `~/Library/Application Support/Astation/credentials.enc`
using AES-GCM with a key derived from the Mac's hardware UUID. Access tokens are
refreshed when needed; project requests use the Agora BFF. Legacy manual customer
credential files are removed during migration and require signing in again.

SSO configuration resolves environment variables first, then saved UserDefaults,
then the built-in defaults:

| Setting | Default | Environment override | UserDefaults key |
| --- | --- | --- | --- |
| SSO URL | `https://sso2.agora.io` | `ASTATION_SSO_URL` | `AstationSsoUrl` |
| BFF URL | `https://agora-cli.agora.io` | `ASTATION_BFF_URL` | `AstationBffUrl` |

For relay deployment, Vault storage, and API configuration, see the
[relay-server README](relay-server/README.md).

## Development

Use the local development script to build and run the menubar app:

```bash
# Rebuild all C++ and Swift build products, then launch.
./scripts/run-dev.sh --force-build

# Incrementally build Swift and launch; build the C++ core if missing.
./scripts/run-dev.sh

# Incrementally build both components without launching.
./scripts/run-dev.sh --build-only

# Rebuild everything without launching.
./scripts/run-dev.sh --force-build --build-only
```

Swift source changes are picked up on every run. Use `--force-build` after changing
C++ code to rebuild both components. Forced builds use CMake's `--clean-first`
and `swift package clean`, while retaining downloaded dependencies and Agora SDKs.
The script resolves the repo root from its own location: from another directory,
invoke it using its absolute path. Install CMake with `brew install cmake`, or set
`CMAKE=/path/to/cmake`. Existing CMake SDK settings are preserved; optional
`AGORA_SDK_DIR` and `AGORA_SKIP_DOWNLOAD` environment variables override them.
Quit any existing Astation instance before launching the development build.
The script creates a signed `.build/Astation Dev.app` and launches it through
LaunchServices so macOS attributes microphone/screen/audio permissions to Astation. Quit
from Astation's menu to stop it; Ctrl+C only stops the launcher.
A failed build stops the script without launching an older executable.

```bash
# Run these from the repo root after building both components.
ctest --test-dir build --output-on-failure
swift test
```

## Related Projects

- [Atem](https://github.com/Agora-Build/Atem) -- A terminal that connects people, Agora platform, and AI agents
- [Chisel](https://github.com/Agora-Build/chisel) -- Dev panel for visual annotation and UI editing by anyone, including AI agents
- [Vox](https://github.com/Agora-Build/Vox) -- AI latency evaluation platform

## License

MIT
