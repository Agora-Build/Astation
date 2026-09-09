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
- CMake detects missing Agora SDK and downloads 7 xcframeworks from `https://download.agora.io/swiftpm/AgoraRtcEngine_macOS/4.6.2/`
- Swift Package Manager resolves `AgoraRtcEngine_macOS` dependency automatically
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
server arrangement directly. Full Android Studio Run/Debug support still requires
validation with your computers and phone: `adb forward` listeners live on the Mac
running Astation, and `adb reverse` host destinations are also on that Mac, so
debugger/development-server connections may need additional tunnels. Real phone/network validation is separate
from the automated local TCP tests.

See the [Android sharing guide](docs/android-device-sharing.md)
for architecture, lifecycle behavior, and remaining hardware checks.

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

### Voice-Driven Coding

Astation captures mic audio via AVAudioEngine, runs WebRTC VAD, streams through Agora RTC, and pushes transcriptions via Agora RTM to the active Atem instance. See `designs/data-flow-between-atem-and-astation.md` in the Atem repo.

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
    HotkeyManager.swift        # Global hotkeys (Ctrl+V voice, Ctrl+Shift+V video)
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
Astation appears in the macOS menu bar; press Ctrl+C in the launching terminal to
stop it. A failed build stops the script without launching an older executable.

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
