# Android Device Sharing

Date: 2026-09-08

Status: Implemented. Local automated validation passes; physical phone, remote
network, and Android Studio debugger validation remain pending.

## Purpose and terminology

Build an Android application on your **development machine**, then install and
run it on an Android phone connected to the **Mac running Astation**. The Mac
provides the phone connection over USB or Android wireless debugging.

The development machine must be able to reach the Mac's selected IPv4 address and
sharing port. Tailscale, NetBird, ZeroTier, other VPNs, and reachable local networks
can provide that connection. Astation does not discover the development machine,
configure a VPN, or depend on a particular provider. IPv6-only connections are not
supported in this version.

## Architecture

```text
Development machine                  Mac running Astation
                                     Android Devices UI
Build APK
ADB client -- reachable IPv4/TCP ---> Sharing listener: selected IP + port
                                              |
                                              v
                                     Local ADB server: 127.0.0.1:5037
                                              |
                                       +------+------+
                                       |             |
                                      USB       Wireless ADB
                                       |             |
                                       +------v------+
                                          Android phone
```

Astation uses the standard ADB client/server protocol. Its NIO TCP proxy forwards
bytes between the selected network interface and the Mac's local ADB server.
It does not implement Android's device-side protocol.

The sharing port defaults to **5038** and is editable from **1024 to 65535**. The
chosen port is saved. Port **5037** remains the local ADB server port. Keeping the
listeners separate lets Astation stop remote access without restarting or
rebinding the ADB server used by local development tools. An occupied sharing
port produces an error; Astation does not silently choose another port.

The endpoint exposes the entire ADB server, including all connected devices and
emulators and server-level control commands. There is one global sharing control.
Use a device serial to target a phone; selecting a serial does not restrict other
clients' access to the remaining devices.

## User workflow

1. Install Android SDK Platform-Tools on the Mac and development machine. Use
   matching Platform-Tools across different machines.
2. On the Mac, open **Connections > Android Devices**. Astation searches common
   SDK/Homebrew locations for ADB; **Choose ADB** selects an executable explicitly.
3. Connect the phone and enable debugging. For USB, unlock the phone and accept
   its USB debugging authorization prompt.
4. Choose this Mac's IPv4 address on a network the development machine can reach,
   and enter the sharing port.
5. Allow only trusted machines to reach that port through your VPN or firewall
   rules, then select **Start Sharing**.
6. Copy the shell setup to the development machine and list the available devices.

The device list displays model, serial, transport, and authorization/offline
state. Separate USB and wireless transports remain separate rows, even for the
same physical phone. Switching transport can change its ADB serial.

The endpoint and copy actions appear after the listener starts and the local ADB
backend has passed its readiness check. Local readiness does not verify that a
remote computer can reach the endpoint. Sharing can run with no phones attached.

## Commands on the development machine

For a Mac with selected address `100.80.1.2` and sharing port `6107`:

```bash
export ADB_SERVER_SOCKET=tcp:100.80.1.2:6107
adb devices -l
adb -s <DEVICE_SERIAL> install -r ./app-debug.apk
adb -s <DEVICE_SERIAL> shell am start -n <PACKAGE>/<ACTIVITY>
adb -s <DEVICE_SERIAL> logcat

# Restore the default ADB server for this shell.
unset ADB_SERVER_SOCKET
```

A single command can target the server without changing the shell environment:

```bash
adb -H 100.80.1.2 -P 6107 devices -l
```

The example address and port are placeholders for the actual values selected in
Astation. Copied commands use the listener's bound address and port.

`adb connect <mac-ip>:<sharing-port>` is **not supported** by this endpoint.
`adb connect` expects a device-side ADB endpoint, while Astation exposes an ADB
server. It is used separately on the Mac to connect to a wireless phone.

## Wireless phone connection

Phones already connected wirelessly to the Mac's ADB server appear in the normal
device list. To pair a new phone, use **Connect Wireless Phone**:

1. On Android 11 or later, open Developer options > Wireless debugging and choose
   **Pair device with pairing code**.
2. Enter the phone's pairing IPv4 address/port and six-digit code in Astation.
3. Enter the debugging IPv4 address/port from the main Wireless debugging screen.
   The pairing and debugging ports can differ.
4. Select **Pair & Connect**. Astation runs `adb pair` with the code supplied over
   process input, followed by `adb connect` to the debugging endpoint.
5. Confirm that the phone appears as authorized. For an already-paired phone,
   turn off **Pair this phone first** and select **Connect**.

The Mac must be able to reach the phone's Wi-Fi address. The development machine
continues using the Mac's sharing endpoint and does not need that direct route.
Wi-Fi changes, phone restarts, or new debugging ports may require reconnecting.
The UI does not promise seamless transport switching.

Pairing codes are not persisted or logged. QR pairing, automatic mDNS discovery,
legacy `adb tcpip 5555`, and persistent reconnect policies are outside this version.

## Lifecycle and network behavior

- Sharing starts off after each app launch. Address/interface and port settings
  are retained for the next explicit Start Sharing action.
- The interface picker lists assigned, active, non-loopback IPv4 addresses with
  interface names. It does not infer a VPN provider from an address range or
  an interface name such as `utun`.
- The listener binds only the selected address, never wildcard `0.0.0.0`.
- Assigned addresses are checked every second. If the selected address disappears,
  sharing closes and an error asks the user to select an available address. There
  is no automatic fallback to another interface.
- Stop Sharing and app quit close the listener and remote streams. The local ADB
  server and its device connections remain available to local tools.
- Device polling normally checks local ADB every two seconds. If the backend
  becomes unavailable, sharing stops and Retry is offered. Device commands are
  serialized, bounded, and cancelled during shutdown.
- TCP forwarding uses backpressure and bounded read/write buffers, allows up to
  32 simultaneous client connections, and handles half-close without dropping
  queued response data. Long-lived shell/logcat streams have no command timeout.

The raw sharing endpoint provides no client authentication or encryption of its
own. Use a trusted network or a VPN that provides encryption and peer access
control, and restrict access to trusted development machines. Astation's existing
Atem pairing does not authenticate this separate listener. Remote clients can
issue server-level commands such as `kill-server`; there is no command filtering
or per-device isolation.

## Implementation components

All feature code lives in `Sources/Menubar` and uses existing SwiftNIO dependencies.

| File | Responsibility |
| --- | --- |
| `ADBClient.swift` | Executable discovery, isolated local-server environment, asynchronous process execution, timeout/cancellation/output bounds |
| `AndroidDevice.swift` | Device parsing, identity, transport and state, port/endpoint validation, shell command quoting |
| `AndroidDeviceManager.swift` | Observable device and sharing state, polling, pairing, interface monitoring, saved settings, Start/Stop coordination |
| `AndroidSharingServer.swift` | NIO TCP listener/proxy, backpressure, connection limit, half-close/shutdown, direct ADB server version probe |
| `AndroidNetworkInterfaces.swift` | Enumerate active non-loopback IPv4 addresses and validate IPv4 text |
| `AndroidDevicesView.swift` | Native device list, network/port selection, copy actions, wireless pairing sheet |
| `ConnectionsWindowController.swift` | Wrap existing Clients & Agents view and Android Devices view in tabs |
| `StatusBarController.swift` | Connections menu entry and manager injection |
| `AstationApp.swift` | Own the manager and shut it down at app quit |
| `Tests/AstationTests/AndroidDeviceTests.swift` | Device/command parsing, saved configuration, and process execution checks |
| `Tests/AstationTests/AndroidSharingServerTests.swift` | TCP integration, backend probing, and address-loss lifecycle checks |

Device and sharing coordination use a single manager. The existing
`ConnectionsView.swift` client/agent implementation is preserved. No additional
Atem WebSocket messages, relay features, or remote client software beyond ADB are
required for the command-line workflow.

### Local ADB ownership

Astation prefers the saved ADB executable, then searches SDK environment variables,
`~/Library/Android/sdk/platform-tools/adb`, Homebrew locations, and PATH. GUI
launches may have a minimal PATH. A missing saved executable is reported rather
than silently replaced by a different SDK.

Commands explicitly target `127.0.0.1:5037` and clear inherited remote ADB settings.
Arguments are passed directly to `Process`. Before listing devices, Astation
queries `host:version` directly to check compatibility without invoking an ADB
client operation that could restart an incompatible server. It starts a missing
local server on initial setup or explicit Retry/Start operations and reports
protocol mismatches instead of intentionally replacing another tool's server.

ADB installation is a prerequisite; Astation does not download Platform-Tools.
Use **Choose ADB** to select the SDK used by local development tools.

## Build and run locally

From the repository root:

```bash
# Incremental Swift build, then launch; build C++ if its library is missing.
./scripts/run-dev.sh

# Clean/rebuild both C++ and Swift, then launch.
./scripts/run-dev.sh --force-build

# Clean/rebuild both without launching.
./scripts/run-dev.sh --force-build --build-only

# Run tests after building.
ctest --test-dir build --output-on-failure
swift test
```

Use `--force-build` after changing C++ code. Without it, normal launches reuse the
existing core library while Swift picks up changed sources. `--build-only` alone
runs incremental builds of both components and skips launch. Forced builds retain
downloaded dependencies and SDKs. See README for prerequisites and SDK overrides.

## Validation status and remaining acceptance checks

The implementation was validated with a successful app build, all **174 Swift
tests**, and all **3 C++ core tests**. Subsequent UI wording changes also compiled
successfully. The development script's full rebuild completed, and its argument,
path, and failure behavior was checked with isolated command fixtures. These are
recorded results, not evidence of physical device or remote network testing.

| Area | Recorded result or remaining check |
| --- | --- |
| Device parsing | Automated USB/wireless/emulator, authorization/offline, empty-list, and transport identity checks pass |
| Process execution | Automated literal argument, stderr/exit code, stdin, timeout, cancellation, and output-limit checks pass |
| Configuration | Automated configurable-port validation and persistence checks pass; sharing remains off for a new manager |
| TCP proxy | Concurrent 2 MB byte-for-byte transfers and half-close tests pass; stop/restart, port conflicts, and wildcard rejection pass |
| Backend and address loss | Fragmented version replies, missing backend, and selected-address-loss tests pass; stop preserves the backend |
| Existing Connections view | Client selection and session-model regression tests pass |
| Physical USB phone | Pending: authorization, unplug/reconnect, APK install/launch, logcat, and push/pull from the development machine |
| Wireless phone | Pending: real pairing, different pairing/debugging ports, USB unplug, reconnection, and remote APK/log workflows |
| VPN or other remote network | Pending: actual reachability/access rules, network loss, and sustained transfers between machines |
| Android Studio and framework tooling | Pending: device discovery, Run, breakpoint attachment, and development-server connectivity |
| Stress and UI behavior | Dedicated slow-consumer/resource-limit stress, window interaction, and real app-quit checks remain useful acceptance work |

No ADB installation, physical phone, or execution connection to the remote
development machine was available during implementation. Automated proxy tests
used loopback fixtures rather than enabling sharing on a real network interface.

For hardware acceptance, record Platform-Tools versions on both computers, the
selected Mac address and sharing port, phone transport/serial, and results for
listing devices, installing an APK built on the development machine, launching
it, streaming logcat, and transferring files. Repeat after switching to wireless.

### Android Studio and debugger limits

Remote ADB does not make every debugging port local to the development machine.
`adb forward` listeners live on the Mac running the ADB server. The host-side
endpoint of `adb reverse` is also that Mac. IDE debugger, JDWP, and framework
server workflows may therefore require additional tunnels or explicit routes.

Validate the actual tool versions before claiming full IDE support. The debugger
acceptance criterion is hitting a breakpoint from the development machine on the
phone connected to the Mac; a successful APK installation alone is insufficient.
