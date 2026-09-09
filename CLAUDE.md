# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Astation is a macOS menubar hub that routes tasks between Chisel (browser dev panel), Atem (terminal), and Claude Code. It acts as a central coordinator -- receives annotation tasks from the browser, picks the right Atem instance, and tracks task status.

## Build Commands

The local development runner resolves paths relative to the repository:

```bash
./scripts/run-dev.sh                           # Incremental Swift build, then launch; build C++ if missing
./scripts/run-dev.sh --force-build             # Clean/rebuild both C++ and Swift, then launch
./scripts/run-dev.sh --build-only              # Incremental C++ and Swift builds without launching
./scripts/run-dev.sh --force-build --build-only # Clean/rebuild both without launching
```

CMake is required when building the core (`brew install cmake`, or set `CMAKE`
to its executable path). The script preserves cached SDK settings; optional
`AGORA_SDK_DIR` and `AGORA_SKIP_DOWNLOAD` environment variables override them.
Forced builds retain downloaded dependencies and SDKs. Use `--force-build` after
changing C++ code. Run `ctest --test-dir build --output-on-failure` and `swift test`
from the repository root after building.

Manual build commands:

```bash
# 1. Build C++ core library
mkdir -p build && cd build
cmake .. -DBUILD_TESTING=ON
make -j$(sysctl -n hw.ncpu)
ctest --output-on-failure    # Run core tests
cd ..

# 2. Build Swift app
swift build                  # Debug build
swift build -c release       # Release build
swift run astation           # Run app

# 3. Build Rust relay server (optional)
cargo build --manifest-path relay-server/Cargo.toml
```

## Architecture

### Source Structure

```
Sources/
  CStationCore/                    # C shim for Swift-to-C++ bridge
    include/module.modulemap       # Module map for Swift interop
    shim.c                         # C wrapper functions
  Menubar/
    main.swift                     # App entry point (NSApplication)
    AstationApp.swift              # App lifecycle, wires handlers
    AstationHubManager.swift       # Business logic, task tracking, client routing
    AstationMessage.swift          # Codable message types (encode/decode)
    AstationWebSocketServer.swift  # NIO-based WebSocket server
    AuthGrantController.swift      # Auth request approval flow
    SsoSessionStore.swift          # AES-GCM encrypted SSO session storage
    SsoAuthManager.swift           # Browser OAuth 2.0 + PKCE login
    SsoTokenProvider.swift         # Lazy access-token refresh
    AgoraAPIClient.swift           # Agora REST API (projects, credentials)
    RTCManager.swift               # Agora RTC audio management
    HotkeyManager.swift            # Global hotkeys (Ctrl+V, Ctrl+Shift+V)
    StatusBarController.swift      # macOS menubar UI
    MachineIdentity.swift          # Hardware UUID for key derivation
core/
  src/astation_core.cpp            # C++ session management
  src/astation_rtc.cpp             # RTC audio processing hooks
  include/astation_core.h          # Public C header
  include/astation_rtc.h           # RTC C header
  tests/session_manager_test.cpp   # Core unit tests
relay-server/
  src/main.rs                      # Rust relay and HTTP API server
  src/routes.rs                    # Auth routes
  src/session_store.rs             # In-memory session storage
third_party/
  agora/                           # Vendored Agora SDKs (gitignored)
```

### Key Components

**Android Device Sharing** (`AndroidDeviceManager.swift`, `AndroidSharingServer.swift`,
`AndroidDevicesView.swift`): The Connections window includes an Android Devices tab.
The manager discovers the local ADB executable, polls devices, handles wireless
pairing, and owns sharing configuration. The NIO proxy forwards a selected local
IPv4 address/configurable port (default 5038) to `127.0.0.1:5037`. Remote development
machines use `adb -H <mac-ip> -P <sharing-port>` or `ADB_SERVER_SOCKET`; `adb connect`
is used only for the Mac-to-phone wireless connection. Access applies to the whole
local ADB server. The listener uses network/VPN access controls, independently of
Atem pairing. Sharing stops on address loss or app quit and starts off after
relaunch. Keep UI/docs network-neutral and refer to "this Mac" and "your development
machine". See `docs/android-device-sharing.md` for validation limits.

**AstationHubManager** (`AstationHubManager.swift`): Central business logic:
- `connectedClients: [ConnectedClient]` - tracked Atem connections
- `markTasks: [MarkTask]` - task tracker (taskId, description, status, assignedTo)
- `broadcastHandler` - sends to all clients
- `sendHandler` - sends to specific client by ID
- `handleMessage(_:from:)` - dispatches incoming messages
- `routeMarkTask(taskId:)` - picks focused > first available Atem
- `focusedClient()` - returns the currently focused Atem

**AstationMessage** (`AstationMessage.swift`): Codable enum with manual encode/decode:
- Uses `type`/`data`/`timestamp` top-level keys
- Each case has its own nested CodingKeys enum (e.g., `MarkTaskNotifyKeys`)
- Pattern: add case to enum + `MessageType` + encode switch + decode switch + CodingKeys

Message types:
- `markTaskNotify(taskId:, status:, description:)` - from Chisel
- `markTaskAssignment(taskId:)` - to Atem
- `markTaskResult(taskId:, success:, message:)` - from Atem
- `projectListRequest/Response` - project management
- `tokenRequest/Response` - Agora token generation
- `claudeLaunchRequest/Response` - Claude Code spawning
- `authRequest/Response` - authentication grant flow
- `voiceToggle/videoToggle` - media state
- `heartbeat/pong` - keep-alive
- `statusUpdate` - connection status
- `commandRequest/Response` - user commands
- `atem_instance_list` - peer broadcast

**AstationWebSocketServer** (`AstationWebSocketServer.swift`):
- NIO-based WebSocket server with HTTP upgrade handler
- `sendMessageToClient(_:clientId:)` - targeted send
- `broadcastMessage(_:)` - send to all
- Listens on configurable host/port (default: 0.0.0.0:8080)

**SSO session management** (`SsoSessionStore.swift`, `SsoAuthManager.swift`, `SsoTokenProvider.swift`):
- Browser OAuth 2.0 + PKCE login with a loopback callback
- AES-GCM encryption using key derived via HKDF from hardware UUID
- Stores at `~/Library/Application Support/Astation/credentials.enc`
- Lazy access-token refresh; `SsoConfig` resolves SSO/BFF URLs from environment,
  UserDefaults, then defaults. See README for configuration keys.

### Dependencies

- **Swift Package Manager**: WebSocketKit (Vapor), SwiftNIO
- **C++ Core**: CMake build, links against Agora RTC SDK
- **Rust Server**: Axum, Tokio, Serde (auth web fallback)
- **Agora SDKs**: RTC + RTM macOS frameworks (vendored in `third_party/`, gitignored)

## Offline / pre-downloaded SDK

- Skip auto-download and use a local SDK root:
  `cmake -S . -B build -DAGORA_SKIP_DOWNLOAD=ON -DAGORA_SDK_DIR=/path/to/sdk`

## Mark Task Routing

```
Chisel (browser) ──WS markTaskNotify──→ Astation
  handleMarkTaskNotify():
    1. Store MarkTask in markTasks array
    2. routeMarkTask(): pick focusedClient() ?? first
    3. sendHandler?(markTaskAssignment, clientId)
    4. Update status to "assigned"

Atem ──WS markTaskResult──→ Astation
  handleMarkTaskResult():
    1. Find task by taskId
    2. Update status to "completed"/"failed"
    3. Store resultMessage
```

## Release Process

Push a git tag to trigger GitHub Actions:

```bash
git tag v0.2.0
git push origin v0.2.0
```

`.github/workflows/release.yml`:
1. Builds C++ core library on macOS (arm64)
2. Builds Swift package in release mode
3. Creates .app bundle + .pkg installer
4. Creates GitHub release with both artifacts

## Adding a New Message Type

1. Add case to `AstationMessage` enum
2. Add raw value to `MessageType` enum
3. Add encoding in `encode(to:)` switch
4. Add decoding in `init(from:)` switch
5. Add private CodingKeys enum for the nested data
6. Handle in `AstationHubManager.handleMessage(_:from:)`
