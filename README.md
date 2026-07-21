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
| `video_toggle` | Astation -> Atem | Video state |
| `atem_instance_list` | Astation -> Atem | Broadcast connected peers |
| `auth_request` / `auth_response` | Atem <-> Astation | Legacy browser/deep-link grant flow |

### Device Authentication

1. Astation sends `auth_required` with its identity, connection scope, protocol version, and a fresh challenge.
2. Same-Mac Atems prove access to the `0600` bootstrap secret without an interactive prompt.
3. Paired LAN and relay Atems send `session_id`, `atem_id`, and an HMAC proof. The session token itself is never sent during reconnect.
4. An unknown device displays an eight-digit code and waits for explicit approval in Astation.
5. Astation processes application messages and sends account credentials only after authentication succeeds.

### Voice-Driven Coding

Astation captures mic audio via AVAudioEngine, runs WebRTC VAD, streams through Agora RTC, and pushes transcriptions via Agora RTM to the active Atem instance. See `designs/data-flow-between-atem-and-astation.md` in the Atem repo.

## Architecture

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
    CredentialManager.swift    # AES-GCM encrypted credential storage
    AgoraAPIClient.swift       # Agora REST API integration
    RTCManager.swift           # Agora RTC audio management
    HotkeyManager.swift        # Global hotkeys (Ctrl+V voice, Ctrl+Shift+V video)
    StatusBarController.swift  # macOS menubar UI
core/
  src/astation_core.cpp    # C++ core (session management)
  src/astation_rtc.cpp     # RTC audio processing
  include/                 # C headers
server/
  src/main.rs              # Rust HTTP server (auth web fallback)
```

### Dependencies

- **Swift Package Manager**: WebSocketKit, SwiftNIO, AgoraRtcEngine_macOS (auto-downloaded)
- **C++ Core**: CMake, Agora RTC SDK (auto-downloaded from SPM distribution on macOS)
- **Rust Server**: Axum, Tokio

## Configuration

Astation reads Agora credentials on first launch. Credentials are stored encrypted at `~/Library/Application Support/Astation/credentials.enc` using AES-GCM with a key derived from the machine's hardware UUID.

## Development

```bash
# Build and run core tests
cd build && cmake .. -DBUILD_TESTING=ON && make && ctest --output-on-failure

# Build Swift app
swift build

# Run
swift run astation
```

## Related Projects

- [Atem](https://github.com/Agora-Build/Atem) -- A terminal that connects people, Agora platform, and AI agents
- [Chisel](https://github.com/Agora-Build/chisel) -- Dev panel for visual annotation and UI editing by anyone, including AI agents
- [Vox](https://github.com/Agora-Build/Vox) -- AI latency evaluation platform

## License

MIT
